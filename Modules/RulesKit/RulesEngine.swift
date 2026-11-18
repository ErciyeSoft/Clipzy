import Foundation

// MARK: - History

/// Which rules already ran on which files, so a rule doesn't run twice on an unchanged file.
/// Files are keyed by volume and inode, so renaming or moving them on the same disk keeps
/// their history. Saved as `history.json`.
nonisolated struct RuleHistory: Codable, Sendable {
  var items: [String: HandledFile] = [:]
  /// `{counter}` values, by rule id.
  var counters: [String: Int] = [:]
}

nonisolated struct HandledFile: Codable, Sendable {
  var path: String
  var lastSeen: Date
  /// By rule id.
  var runs: [String: HandledRun] = [:]
}

nonisolated struct HandledRun: Codable, Sendable {
  var signature: FileSignature
  var date: Date
  var failed = false
}

/// What a pass did, for tests and logging.
nonisolated struct PassSummary: Sendable {
  var examined = 0
  var busy = 0
  var actions = 0
  var errors = 0
}

// MARK: - Engine

/// Runs folder rules. All file work happens here, off the main thread, one folder at a time.
actor RulesEngine {
  /// More automatic actions than this in a minute pauses everything: probably a loop.
  static let actionsPerMinuteLimit = 300
  private static let forgetAfter: TimeInterval = 30 * 86_400
  private static let historyLimit = 50_000

  let environment: ActionEnvironment
  let matcher = ConditionMatcher()
  var history = RuleHistory()

  private var folders: [WatchedFolder] = []
  private var revision = -1
  private let historyURL: URL
  private let report: @MainActor @Sendable (ActivityEntry) -> Void
  private var historyDirty = false
  private var lastPrune = Date.distantPast
  private var pending: [UUID] = []
  private var pendingManual: Set<UUID> = []
  /// Folders that need a full scan; the others in `pending` only look at `pendingPaths`.
  private var pendingFull: Set<UUID> = []
  private var pendingPaths: [UUID: Set<String>] = [:]
  private var isDraining = false
  private var delayedArmed: Set<UUID> = []
  private var delayedFull: Set<UUID> = []
  private var delayedPaths: [UUID: Set<String>] = [:]
  private var recentActions: [Date] = []
  private var pausedUntil: Date?

  init(directory: URL, environment: ActionEnvironment, report: @escaping @MainActor @Sendable (ActivityEntry) -> Void) {
    historyURL = directory.appendingPathComponent("history.json")
    self.environment = environment
    self.report = report
  }

  func loadHistory() {
    guard let data = try? Data(contentsOf: historyURL),
          let decoded = try? JSONDecoder().decode(RuleHistory.self, from: data) else { return }
    history = decoded
  }

  /// Takes the latest folders and rules; older snapshots that arrive late are ignored.
  func update(folders: [WatchedFolder], revision: Int) {
    guard revision > self.revision else { return }
    self.revision = revision
    self.folders = folders
  }

  // MARK: Scheduling

  /// Queues full passes over these folders. Manual runs also retry files whose rule failed.
  func schedule(_ ids: [UUID], manual: Bool = false) {
    pendingFull.formUnion(ids)
    enqueue(ids, manual: manual)
  }

  private func enqueue(_ ids: [UUID], manual: Bool) {
    for id in ids where !pending.contains(id) { pending.append(id) }
    if manual { pendingManual.formUnion(ids) }
    guard !isDraining, !pending.isEmpty else { return }
    isDraining = true
    Task { await drain() }
  }

  func scheduleAll(manual: Bool = false) {
    schedule(folders.filter(\.isActive).map(\.id), manual: manual)
  }

  /// FSEvents reported these paths; queue a pass over just those items in their folders.
  func handle(eventPaths: [String]) {
    for folder in folders where folder.isActive {
      let root = FileOps.canonicalPath(folder.path).lowercased()
      let hits = eventPaths.filter { raw in
        let path = raw.lowercased()
        guard path == root || path.hasPrefix(root + "/") else { return false }
        return folder.includeSubfolders || path == root || (path as NSString).deletingLastPathComponent == root
      }
      guard !hits.isEmpty else { continue }
      pendingPaths[folder.id, default: []].formUnion(hits)
      enqueue([folder.id], manual: false)
    }
  }

  /// Waits until every queued pass is done (for tests and Run Now feedback).
  func waitUntilIdle() async {
    while isDraining || !pending.isEmpty {
      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  private func drain() async {
    while !pending.isEmpty {
      let id = pending.removeFirst()
      let manual = pendingManual.remove(id) != nil
      let full = pendingFull.remove(id) != nil
      let paths = pendingPaths.removeValue(forKey: id)
      await runPass(folderID: id, manual: manual, paths: full ? nil : paths)
    }
    isDraining = false
  }

  /// Files that are still being written get another look once they have settled.
  /// `paths` nil means the whole folder.
  private func scheduleLater(_ id: UUID, seconds: Double, paths: Set<String>?) {
    if let paths { delayedPaths[id, default: []].formUnion(paths) } else { delayedFull.insert(id) }
    guard delayedArmed.insert(id).inserted else { return }
    Task {
      try? await Task.sleep(for: .seconds(seconds))
      delayedPassFired(id)
    }
  }

  private func delayedPassFired(_ id: UUID) {
    delayedArmed.remove(id)
    let paths = delayedPaths.removeValue(forKey: id)
    if delayedFull.remove(id) != nil {
      schedule([id])
    } else if let paths {
      pendingPaths[id, default: []].formUnion(paths)
      enqueue([id], manual: false)
    }
  }

  // MARK: Passes

  /// Runs the folder's rules over its files once, or only over the items near `paths`.
  @discardableResult
  func runPass(folderID: UUID, manual: Bool, paths: Set<String>? = nil) async -> PassSummary {
    var summary = PassSummary()
    guard let folder = folders.first(where: { $0.id == folderID }), folder.isEnabled else { return summary }
    let rules = folder.rules.filter(\.isRunnable)
    guard !rules.isEmpty, FileOps.isDirectory(folder.url) else { return summary }
    if manual {
      pausedUntil = nil
    } else if let pausedUntil, pausedUntil > Date() {
      return summary
    }

    var settleWait: TimeInterval?
    var settlingPaths = Set<String>()
    let candidates = paths.flatMap { FileOps.candidates(in: folder, near: $0) } ?? FileOps.candidates(in: folder)
    for url in candidates {
      guard let info = FileInfo(url: url) else { continue }  // moved away by an earlier action
      summary.examined += 1
      if let reason = info.busyReason(now: Date()) {
        summary.busy += 1
        if case let .settling(remaining) = reason {
          settleWait = max(settleWait ?? 0, remaining)
          settlingPaths.insert(url.path)
        }
        continue
      }
      touch(info)
      await apply(rules, to: info, in: folder, manual: manual, summary: &summary)
      if !manual, let pausedUntil, pausedUntil > Date() { break }
    }
    if let settleWait { scheduleLater(folderID, seconds: settleWait + 0.3, paths: paths == nil ? nil : settlingPaths) }
    prune(now: Date())
    saveHistory()
    return summary
  }

  /// First matching rule wins; "Continue matching" hands the file on to the next rules.
  private func apply(_ rules: [FolderRule], to start: FileInfo, in folder: WatchedFolder, manual: Bool,
                     summary: inout PassSummary) async {
    var info = start
    for rule in rules {
      guard matcher.matches(rule, info, now: Date()) else { continue }
      if let run = history.items[info.identity]?.runs[rule.id.uuidString],
         run.signature == info.signature, !(manual && run.failed) {
        // Already done and the file hasn't changed since.
        if rule.continuesMatching { continue }
        return
      }
      let outcome = await perform(rule, on: info, in: folder)
      summary.actions += outcome.actionCount
      if outcome.failed { summary.errors += 1 }
      record(rule, original: info, outcome: outcome)
      if !manual { countActions(outcome.actionCount, folder: folder) }
      guard rule.continuesMatching, !outcome.failed, let url = outcome.url,
            FileOps.isInside(url, folder.url), let next = FileInfo(url: url) else { return }
      info = next
    }
  }

  nonisolated private struct RuleOutcome {
    var url: URL?
    var outputs: [URL] = []
    var failed = false
    var actionCount = 0
  }

  /// Runs the rule's actions in order and logs each one. Stops at the first error.
  private func perform(_ rule: FolderRule, on info: FileInfo, in folder: WatchedFolder) async -> RuleOutcome {
    var outcome = RuleOutcome(url: info.url)
    var current = info
    var isFirst = true
    for action in rule.actions where action.kind != .continueMatching && action.kind != .ignore {
      guard let url = outcome.url else { break }  // in the Trash; nothing left to do
      if !isFirst {
        guard let fresh = FileInfo(url: url) else { break }
        current = fresh
      }
      isFirst = false
      do {
        let result = try await perform(action, on: current, rule: rule, folder: folder)
        outcome.url = result.url
        outcome.outputs += result.outputs
        outcome.actionCount += 1
        await log(rule, file: current, path: result.url?.path ?? current.url.path, summary: result.summary, error: nil)
      } catch {
        outcome.failed = true
        await log(rule, file: current, path: current.url.path, summary: action.kind.title, error: error.localizedDescription)
        break
      }
    }
    return outcome
  }

  private func log(_ rule: FolderRule, file: FileInfo, path: String, summary: String, error: String?) async {
    let entry = ActivityEntry(date: Date(), fileName: file.fullName, path: path,
                              ruleName: rule.name, summary: summary, error: error)
    await report(entry)
  }

  /// Pauses automatic runs when rules act far too often, which usually means two rules
  /// keep handing files back and forth.
  private func countActions(_ count: Int, folder: WatchedFolder) {
    guard count > 0 else { return }
    let now = Date()
    recentActions.append(contentsOf: repeatElement(now, count: count))
    recentActions.removeAll { now.timeIntervalSince($0) > 60 }
    guard recentActions.count > Self.actionsPerMinuteLimit else { return }
    recentActions = []
    pausedUntil = now.addingTimeInterval(600)
    let entry = ActivityEntry(
      date: now, fileName: folder.name, path: folder.path, ruleName: String(localized: "Folder Rules"),
      summary: String(localized: "Paused for 10 minutes"),
      error: String(localized: "More than \(Self.actionsPerMinuteLimit) actions in a minute. Check your rules for a loop.")
    )
    let report = report
    Task { await report(entry) }
  }

  // MARK: History

  private func touch(_ info: FileInfo) {
    guard var item = history.items[info.identity] else { return }
    // Saving every pass would rewrite the file constantly; a day's precision is plenty.
    if item.path != info.url.path || Date().timeIntervalSince(item.lastSeen) > 86_400 {
      item.path = info.url.path
      item.lastSeen = Date()
      history.items[info.identity] = item
      historyDirty = true
    }
  }

  private func record(_ rule: FolderRule, original: FileInfo, outcome: RuleOutcome) {
    let key = rule.id.uuidString
    let final = outcome.url.flatMap { FileInfo(url: $0) }
    if let final, final.identity == original.identity {
      // Same file, maybe renamed or retagged: remember how it looks now.
      setRun(final, rule: key, failed: outcome.failed)
    } else {
      setRun(original, rule: key, failed: outcome.failed)
      if let final { setRun(final, rule: key, failed: outcome.failed) }
    }
    // Copies, ZIPs and extracted files count as handled by this rule, so it doesn't
    // pick up its own output.
    for output in outcome.outputs {
      if let made = FileInfo(url: output) { setRun(made, rule: key, failed: false) }
    }
  }

  private func setRun(_ info: FileInfo, rule: String, failed: Bool) {
    let now = Date()
    var item = history.items[info.identity] ?? HandledFile(path: info.url.path, lastSeen: now)
    item.path = info.url.path
    item.lastSeen = now
    item.runs[rule] = HandledRun(signature: info.signature, date: now, failed: failed)
    history.items[info.identity] = item
    historyDirty = true
  }

  /// Lets the rule run again on files it already handled.
  func forget(ruleID: UUID) {
    let key = ruleID.uuidString
    for (identity, var item) in history.items where item.runs[key] != nil {
      item.runs[key] = nil
      history.items[identity] = item.runs.isEmpty ? nil : item
    }
    historyDirty = true
    saveHistory()
  }

  /// Drops files not seen for a month and rules that no longer exist.
  private func prune(now: Date) {
    guard revision >= 0, now.timeIntervalSince(lastPrune) > 3_600 else { return }
    lastPrune = now
    let ruleIDs = Set(folders.flatMap { $0.rules.map(\.id.uuidString) })
    var items: [String: HandledFile] = [:]
    for (identity, var item) in history.items where now.timeIntervalSince(item.lastSeen) < Self.forgetAfter {
      item.runs = item.runs.filter { ruleIDs.contains($0.key) }
      if !item.runs.isEmpty { items[identity] = item }
    }
    if items.count > Self.historyLimit {
      let kept = items.sorted { $0.value.lastSeen > $1.value.lastSeen }.prefix(Self.historyLimit)
      items = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
    history.items = items
    history.counters = history.counters.filter { ruleIDs.contains($0.key) }
    historyDirty = true
  }

  private func saveHistory() {
    guard historyDirty else { return }
    historyDirty = false
    guard let data = try? JSONEncoder().encode(history) else { return }
    try? FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: historyURL, options: .atomic)
  }

  // MARK: Preview

  /// Files in the folder the rule matches right now, and what it would do. Changes nothing.
  func preview(rule: FolderRule, in folder: WatchedFolder, limit: Int = 500) -> [PreviewItem] {
    let index = folder.rules.firstIndex { $0.id == rule.id } ?? folder.rules.count
    let earlier = folder.rules.prefix(index).filter { $0.isRunnable && !$0.continuesMatching }
    let now = Date()
    var counter = history.counters[rule.id.uuidString] ?? 0
    var items: [PreviewItem] = []
    for url in FileOps.candidates(in: folder) where items.count < limit {
      guard let info = FileInfo(url: url), matcher.matches(rule, info, now: now) else { continue }
      let status: PreviewItem.Status
      if let first = earlier.first(where: { matcher.matches($0, info, now: now) }) {
        status = .earlierRule(first.name)
      } else if let run = history.items[info.identity]?.runs[rule.id.uuidString],
                run.signature == info.signature, !run.failed {
        status = .alreadyHandled
      } else {
        status = .willRun
      }
      let steps = rule.actions.map { action in
        ActionPlanner.describe(action, info: info, folder: folder, now: now) { counter += 1; return counter }
      }
      items.append(PreviewItem(path: url.path, name: info.fullName, steps: steps, status: status))
    }
    return items
  }
}
