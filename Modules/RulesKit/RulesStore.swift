import AppKit
import Foundation
import Observation

/// Where Folder Rules keeps its files.
enum RulesPaths {
  static var directory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Kitzi", isDirectory: true)
      .appendingPathComponent("FolderRules", isDirectory: true)
  }
}

/// The contents of rules.json.
nonisolated struct RulesFile: Codable, Sendable {
  var version = 1
  var folders: [WatchedFolder]
}

/// Reading and writing the module's JSON files, off the main thread.
nonisolated enum RulesDisk {
  static let activityLimit = 200

  struct Loaded: Sendable {
    var folders: [WatchedFolder] = []
    var activity: [ActivityEntry] = []
    var problem: String?
  }

  static func load(from directory: URL) -> Loaded {
    var loaded = Loaded()
    let fm = FileManager.default
    try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let rulesURL = directory.appendingPathComponent("rules.json")
    if let data = try? Data(contentsOf: rulesURL) {
      do {
        loaded.folders = try JSONDecoder().decode(RulesFile.self, from: data).folders
      } catch {
        // Keep the unreadable file instead of overwriting it with an empty list.
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = directory.appendingPathComponent("rules-unreadable-\(stamp).json")
        try? fm.moveItem(at: rulesURL, to: backup)
        loaded.problem = String(localized: "Your folder rules couldn't be read. The file was kept as \(backup.lastPathComponent).")
      }
    }
    let activityURL = directory.appendingPathComponent("activity.json")
    if let data = try? Data(contentsOf: activityURL),
       let entries = try? JSONDecoder().decode([ActivityEntry].self, from: data) {
      loaded.activity = Array(entries.prefix(activityLimit))
    }
    return loaded
  }
}

/// Writes files in order on a background queue; an older write that arrives late is dropped.
actor JSONFileWriter {
  private var latest: [String: Int] = [:]

  func write(_ data: Data, to url: URL, sequence: Int) {
    guard sequence > latest[url.path, default: -1] else { return }
    latest[url.path] = sequence
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
  }
}

/// Lets the engine report activity to the store without a retain cycle.
final class RulesStoreRelay {
  weak var store: RulesStore?
}

/// The folders, rules and activity log the settings page shows. Every change is saved,
/// handed to the engine and reflected in the FSEvents stream.
@Observable
final class RulesStore {
  private(set) var folders: [WatchedFolder] = []
  private(set) var activity: [ActivityEntry] = []
  private(set) var isLoaded = false
  private(set) var loadProblem: String?
  var selectedFolderID: UUID?

  @ObservationIgnored let engine: RulesEngine
  @ObservationIgnored private let directory: URL
  @ObservationIgnored private let watcher: FolderWatcher
  @ObservationIgnored private let writer = JSONFileWriter()
  @ObservationIgnored private var revision = 0
  @ObservationIgnored private var writeSequence = 0
  @ObservationIgnored private var activitySave: Task<Void, Never>?

  init(directory: URL) {
    self.directory = directory
    let relay = RulesStoreRelay()
    let engine = RulesEngine(directory: directory, environment: .live) { entry in
      relay.store?.append(entry)
    }
    self.engine = engine
    watcher = FolderWatcher(latency: 2) { paths in
      Task { await engine.handle(eventPaths: paths) }
    }
    relay.store = self
  }

  var selectedFolder: WatchedFolder? {
    folders.first { $0.id == selectedFolderID } ?? folders.first
  }

  func folder(_ id: UUID) -> WatchedFolder? {
    folders.first { $0.id == id }
  }

  // MARK: Loading and saving

  /// Reads the saved rules, then checks every folder once for files added while Kitzi was off.
  func load() async {
    guard !isLoaded else { return }
    let directory = directory
    let loaded = await Task.detached { RulesDisk.load(from: directory) }.value
    folders = loaded.folders
    activity = loaded.activity
    loadProblem = loaded.problem
    selectedFolderID = folders.first?.id
    await engine.loadHistory()
    isLoaded = true
    commit(save: false)
    let snapshot = folders, revision = revision
    await engine.update(folders: snapshot, revision: revision)
    await engine.scheduleAll()
  }

  /// Saves and applies the current folders; optionally runs one folder right after.
  private func commit(save: Bool = true, run folderID: UUID? = nil) {
    guard isLoaded else { return }
    revision += 1
    let snapshot = folders, revision = revision, engine = engine
    Task {
      await engine.update(folders: snapshot, revision: revision)
      if let folderID { await engine.schedule([folderID]) }
    }
    watcher.watch(folders.filter(\.isActive).map(\.path))
    if save, let data = try? Self.encoder.encode(RulesFile(folders: folders)) {
      write(data, to: "rules.json")
    }
  }

  private func write(_ data: Data, to name: String) {
    writeSequence += 1
    let url = directory.appendingPathComponent(name), sequence = writeSequence, writer = writer
    Task { await writer.write(data, to: url, sequence: sequence) }
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()

  /// Writes the activity log right away, for quitting.
  func flush() {
    activitySave?.cancel()
    guard isLoaded, let data = try? Self.encoder.encode(activity) else { return }
    try? data.write(to: directory.appendingPathComponent("activity.json"), options: .atomic)
  }

  func stop() {
    watcher.stop()
  }

  // MARK: Folders

  func addFolder(_ url: URL) {
    let path = url.standardizedFileURL.path
    if let existing = folders.first(where: { FileOps.samePath($0.url, url) }) {
      selectedFolderID = existing.id
      return
    }
    let folder = WatchedFolder(path: path)
    folders.append(folder)
    selectedFolderID = folder.id
    commit()
  }

  func removeFolder(_ id: UUID) {
    let removedRules = folder(id)?.rules.map(\.id) ?? []
    folders.removeAll { $0.id == id }
    if selectedFolderID == id { selectedFolderID = folders.first?.id }
    commit()
    let engine = engine
    Task { for rule in removedRules { await engine.forget(ruleID: rule) } }
  }

  func setFolderEnabled(_ id: UUID, _ enabled: Bool) {
    mutateFolder(id) { $0.isEnabled = enabled }
    commit(run: enabled ? id : nil)
  }

  func setIncludeSubfolders(_ id: UUID, _ include: Bool) {
    mutateFolder(id) { $0.includeSubfolders = include }
    commit(run: id)
  }

  /// Checks the folder now. Rules still skip files they already handled unless the file
  /// changed; files whose rule failed get another try.
  func runNow(_ id: UUID) {
    let engine = engine
    Task { await engine.schedule([id], manual: true) }
  }

  /// The periodic check and the check after waking, for date conditions.
  func runAutomaticCheck() {
    guard isLoaded else { return }
    let engine = engine
    Task { await engine.scheduleAll() }
  }

  private func mutateFolder(_ id: UUID, _ change: (inout WatchedFolder) -> Void) {
    guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
    change(&folders[index])
  }

  // MARK: Rules

  /// Adds the rule or replaces the one with the same id, then runs the folder so existing
  /// files are handled too.
  func saveRule(_ rule: FolderRule, in folderID: UUID) {
    mutateFolder(folderID) { folder in
      if let index = folder.rules.firstIndex(where: { $0.id == rule.id }) {
        folder.rules[index] = rule
      } else {
        folder.rules.append(rule)
      }
    }
    commit(run: folderID)
  }

  func setRuleEnabled(_ ruleID: UUID, in folderID: UUID, _ enabled: Bool) {
    mutateFolder(folderID) { folder in
      guard let index = folder.rules.firstIndex(where: { $0.id == ruleID }) else { return }
      folder.rules[index].isEnabled = enabled
    }
    commit(run: enabled ? folderID : nil)
  }

  func deleteRule(_ ruleID: UUID, in folderID: UUID) {
    mutateFolder(folderID) { $0.rules.removeAll { $0.id == ruleID } }
    commit()
    let engine = engine
    Task { await engine.forget(ruleID: ruleID) }
  }

  func duplicateRule(_ ruleID: UUID, in folderID: UUID) {
    mutateFolder(folderID) { folder in
      guard let index = folder.rules.firstIndex(where: { $0.id == ruleID }) else { return }
      var copy = folder.rules[index]
      copy.id = UUID()
      copy.name = String(localized: "\(copy.name) copy")
      // A copy starts switched off so it doesn't act twice on the same files.
      copy.isEnabled = false
      folder.rules.insert(copy, at: index + 1)
    }
    commit()
  }

  func moveRule(_ ruleID: UUID, in folderID: UUID, by offset: Int) {
    mutateFolder(folderID) { folder in
      guard let index = folder.rules.firstIndex(where: { $0.id == ruleID }) else { return }
      let target = index + offset
      guard folder.rules.indices.contains(target) else { return }
      folder.rules.swapAt(index, target)
    }
    commit()
  }

  /// Lets the rule run again on files it already handled.
  func forgetHandledFiles(_ ruleID: UUID, in folderID: UUID) {
    let engine = engine
    Task {
      await engine.forget(ruleID: ruleID)
      await engine.schedule([folderID])
    }
  }

  func preview(_ rule: FolderRule, in folderID: UUID) async -> [PreviewItem] {
    guard let folder = folder(folderID) else { return [] }
    return await engine.preview(rule: rule, in: folder)
  }

  // MARK: Activity

  func append(_ entry: ActivityEntry) {
    activity.insert(entry, at: 0)
    if activity.count > RulesDisk.activityLimit { activity.removeLast(activity.count - RulesDisk.activityLimit) }
    scheduleActivitySave()
  }

  func clearActivity() {
    activity = []
    scheduleActivitySave()
  }

  private func scheduleActivitySave() {
    activitySave?.cancel()
    activitySave = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled, let self, let data = try? Self.encoder.encode(self.activity) else { return }
      self.write(data, to: "activity.json")
    }
  }
}
