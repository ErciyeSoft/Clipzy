import AppKit
import Foundation
import UserNotifications

/// The parts of an action that need the app (notifications, opening files). Tests swap them out.
nonisolated struct ActionEnvironment: Sendable {
  var notify: @MainActor @Sendable (_ title: String, _ body: String) -> Void
  var open: @MainActor @Sendable (_ file: URL, _ app: URL?) async throws -> Void
  var reveal: @MainActor @Sendable (_ file: URL) -> Void

  static let live = ActionEnvironment(
    notify: { title, body in
      Task {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await center.add(UNNotificationRequest(identifier: "rules.\(UUID().uuidString)", content: content, trigger: nil))
      }
    },
    open: { file, app in
      if let app {
        _ = try await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
      } else if !NSWorkspace.shared.open(file) {
        throw RulesError.failed(String(localized: "Couldn't open the file."))
      }
    },
    reveal: { file in
      NSWorkspace.shared.activateFileViewerSelecting([file])
    }
  )
}

nonisolated enum RulesError: LocalizedError {
  case folderMissing(String)
  case appMissing(String)
  case emptyName
  case notArchive
  case intoItself
  case scriptFailed(Int32, String)
  case timedOut(Int)
  case failed(String)

  var errorDescription: String? {
    switch self {
    case let .folderMissing(name): String(localized: "The folder “\(name)” can't be found.")
    case let .appMissing(name): String(localized: "The app “\(name)” can't be found.")
    case .emptyName: String(localized: "The pattern gave an empty name.")
    case .notArchive: String(localized: "This file isn't an archive Kitzi can extract.")
    case .intoItself: String(localized: "A folder can't be moved or copied into itself.")
    case let .scriptFailed(status, output):
      output.isEmpty
        ? String(localized: "The script ended with code \(Int(status)).")
        : String(localized: "The script ended with code \(Int(status)): \(output)")
    case let .timedOut(seconds): String(localized: "The script was stopped after \(seconds) seconds.")
    case let .failed(message): message
    }
  }
}

/// What one action did: where the file is now (nil once it's in the Trash), new files it made,
/// and a line for the activity log.
nonisolated struct ActionResult: Sendable {
  var url: URL?
  var outputs: [URL] = []
  var summary: String
}

// MARK: - Describing actions

/// Describes actions in the same words for Preview and the activity log.
nonisolated enum ActionPlanner {
  static func describe(_ action: RuleAction, info: FileInfo, folder: WatchedFolder, now: Date, counter: () -> Int) -> String {
    switch action.kind {
    case .moveToFolder:
      return String(localized: "Move to “\(displayName(action.folderPath))”")
    case .copyToFolder:
      return String(localized: "Copy to “\(displayName(action.folderPath))”")
    case .rename:
      return String(localized: "Rename to “\(renamedName(action, info: info, now: now, counter: counter))”")
    case .sortIntoSubfolders:
      let components = subfolders(action, info: info, now: now, counter: counter)
      return String(localized: "Move to “\(components.joined(separator: "/"))”")
    case .addTags:
      let tags = action.tagList.map { PatternExpander.expand($0, info: info, now: now, counter: counter) }
      return String(localized: "Add tags: \(tags.joined(separator: ", "))")
    case .removeTags:
      return action.allTags
        ? String(localized: "Remove all tags")
        : String(localized: "Remove tags: \(action.tagList.joined(separator: ", "))")
    case .openWith:
      return String(localized: "Open with \(displayName(action.appPath))")
    default:
      return action.kind.title
    }
  }

  static func displayName(_ path: String) -> String {
    let name = FileManager.default.displayName(atPath: path)
    return (name as NSString).pathExtension == "app" ? (name as NSString).deletingPathExtension : name
  }

  /// The new name for Rename. The extension is kept unless the pattern uses `{ext}` or `{fullname}`.
  static func renamedName(_ action: RuleAction, info: FileInfo, now: Date, counter: () -> Int) -> String {
    let expanded = PatternExpander.expand(action.pattern, info: info, now: now, counter: counter)
    var name = FileOps.sanitizedName(expanded)
    let keepsOwnExtension = ["ext", "extension", "fullname"].contains { PatternExpander.uses($0, in: action.pattern) }
    if !name.isEmpty, !keepsOwnExtension, !info.ext.isEmpty {
      name += "." + info.ext
    }
    return name
  }

  /// Folder names for Sort into subfolders; "/" in the pattern makes nested folders.
  static func subfolders(_ action: RuleAction, info: FileInfo, now: Date, counter: () -> Int) -> [String] {
    let expanded = PatternExpander.expand(action.pattern, info: info, now: now, counter: counter)
    return expanded.split(separator: "/").map { FileOps.sanitizedName(String($0)) }
      .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
}

// MARK: - Running actions

extension RulesEngine {
  /// Runs one action on the file. Everything here runs on the engine, off the main thread.
  func perform(_ action: RuleAction, on info: FileInfo, rule: FolderRule, folder: WatchedFolder) async throws -> ActionResult {
    let fm = FileManager.default
    let parent = info.url.deletingLastPathComponent()
    let now = Date()
    let isFolder = info.isDirectory && !info.isPackage

    switch action.kind {
    case .moveToFolder, .copyToFolder:
      let destination = URL(fileURLWithPath: action.folderPath, isDirectory: true)
      let label = ActionPlanner.displayName(action.folderPath)
      guard FileOps.isDirectory(destination) else { throw RulesError.folderMissing(label) }
      if info.isDirectory, FileOps.isInside(destination, info.url) { throw RulesError.intoItself }
      if action.kind == .moveToFolder {
        if FileOps.samePath(destination, parent) {
          return ActionResult(url: info.url, summary: String(localized: "Already in “\(label)”"))
        }
        let target = FileOps.uniqueURL(in: destination, fullName: info.fullName, isFolder: isFolder)
        try fm.moveItem(at: info.url, to: target)
        return ActionResult(url: target, summary: String(localized: "Move to “\(label)”"))
      }
      let target = FileOps.uniqueURL(in: destination, fullName: info.fullName, isFolder: isFolder)
      try fm.copyItem(at: info.url, to: target)
      return ActionResult(url: info.url, outputs: [target], summary: String(localized: "Copy to “\(label)”"))

    case .rename:
      var counter = history.counters[rule.id.uuidString] ?? 0
      let newName = ActionPlanner.renamedName(action, info: info, now: now) { counter += 1; return counter }
      history.counters[rule.id.uuidString] = counter
      guard !newName.isEmpty else { throw RulesError.emptyName }
      if newName == info.fullName {
        return ActionResult(url: info.url, summary: String(localized: "Rename to “\(newName)”"))
      }
      let target: URL
      if newName.lowercased() == info.fullName.lowercased() {
        // Only the case changes; on a case-insensitive disk the name counts as taken already.
        target = parent.appendingPathComponent(newName)
        guard Darwin.rename(info.url.path, target.path) == 0 else {
          throw RulesError.failed(String(cString: strerror(errno)))
        }
      } else {
        target = FileOps.uniqueURL(in: parent, fullName: newName, isFolder: isFolder)
        try fm.moveItem(at: info.url, to: target)
      }
      return ActionResult(url: target, summary: String(localized: "Rename to “\(target.lastPathComponent)”"))

    case .sortIntoSubfolders:
      let base = action.folderPath.isEmpty ? folder.url : URL(fileURLWithPath: action.folderPath, isDirectory: true)
      guard FileOps.isDirectory(base) else { throw RulesError.folderMissing(ActionPlanner.displayName(base.path)) }
      var counter = history.counters[rule.id.uuidString] ?? 0
      let components = ActionPlanner.subfolders(action, info: info, now: now) { counter += 1; return counter }
      history.counters[rule.id.uuidString] = counter
      guard !components.isEmpty else { throw RulesError.emptyName }
      let destination = components.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
      let label = components.joined(separator: "/")
      if FileOps.samePath(destination, parent) {
        return ActionResult(url: info.url, summary: String(localized: "Already in “\(label)”"))
      }
      if info.isDirectory, FileOps.isInside(destination, info.url) { throw RulesError.intoItself }
      try fm.createDirectory(at: destination, withIntermediateDirectories: true)
      let target = FileOps.uniqueURL(in: destination, fullName: info.fullName, isFolder: isFolder)
      try fm.moveItem(at: info.url, to: target)
      return ActionResult(url: target, summary: String(localized: "Move to “\(label)”"))

    case .addTags:
      var counter = 0
      let wanted = action.tagList.map { PatternExpander.expand($0, info: info, now: now) { counter += 1; return counter } }
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
      var tags = info.tags
      for tag in wanted where !tags.contains(where: { $0.compare(tag, options: .caseInsensitive) == .orderedSame }) {
        tags.append(tag)
      }
      try (info.url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
      return ActionResult(url: info.url, summary: String(localized: "Add tags: \(wanted.joined(separator: ", "))"))

    case .removeTags:
      let unwanted = action.tagList
      let tags = action.allTags ? [] : info.tags.filter { tag in
        !unwanted.contains { $0.compare(tag, options: .caseInsensitive) == .orderedSame }
      }
      try (info.url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
      let summary = action.allTags
        ? String(localized: "Remove all tags")
        : String(localized: "Remove tags: \(unwanted.joined(separator: ", "))")
      return ActionResult(url: info.url, summary: summary)

    case .trash:
      try fm.trashItem(at: info.url, resultingItemURL: nil)
      return ActionResult(url: nil, summary: action.kind.title)

    case .open:
      try await environment.open(info.url, nil)
      return ActionResult(url: info.url, summary: action.kind.title)

    case .openWith:
      let app = URL(fileURLWithPath: action.appPath)
      guard FileOps.exists(app) else { throw RulesError.appMissing(ActionPlanner.displayName(action.appPath)) }
      try await environment.open(info.url, app)
      return ActionResult(url: info.url, summary: String(localized: "Open with \(ActionPlanner.displayName(action.appPath))"))

    case .revealInFinder:
      await environment.reveal(info.url)
      return ActionResult(url: info.url, summary: action.kind.title)

    case .runScript:
      let seconds = min(600, max(1, action.timeout))
      let result = try await ToolRunner.run("/bin/zsh", ["-c", action.script, "zsh", info.url.path],
                                            in: parent, timeout: TimeInterval(seconds))
      if result.timedOut { throw RulesError.timedOut(seconds) }
      guard result.status == 0 else { throw RulesError.scriptFailed(result.status, result.output) }
      return ActionResult(url: FileOps.exists(info.url) ? info.url : nil, summary: action.kind.title)

    case .notify:
      var counter = 0
      let pattern = action.pattern.trimmingCharacters(in: .whitespaces).isEmpty ? "{fullname}" : action.pattern
      let body = PatternExpander.expand(pattern, info: info, now: now) { counter += 1; return counter }
      await environment.notify(rule.name, body)
      return ActionResult(url: info.url, summary: action.kind.title)

    case .compress:
      let target = FileOps.uniqueURL(in: parent, fullName: info.fullName + ".zip")
      // --keepParent keeps a folder's name inside the ZIP, like Finder; on a single file it
      // would add the enclosing folder instead, so files go without it.
      let keepParent = info.isDirectory ? ["--keepParent"] : []
      try await ToolRunner.check("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc"] + keepParent + [info.url.path, target.path])
      if action.trashOriginal {
        try fm.trashItem(at: info.url, resultingItemURL: nil)
      }
      return ActionResult(url: target, outputs: [target], summary: String(localized: "Compress to “\(target.lastPathComponent)”"))

    case .extract:
      let target = try await extract(info, into: parent)
      if action.trashOriginal {
        try fm.trashItem(at: info.url, resultingItemURL: nil)
      }
      return ActionResult(url: target, outputs: [target], summary: String(localized: "Extract to “\(target.lastPathComponent)”"))

    case .continueMatching, .ignore:
      return ActionResult(url: info.url, summary: action.kind.title)
    }
  }

  /// Extracts next to the archive. A single top-level item lands there directly, like
  /// Archive Utility does; several items go into a folder named after the archive.
  private func extract(_ info: FileInfo, into parent: URL) async throws -> URL {
    let ext = info.ext.lowercased()
    guard !info.isDirectory, FileOps.archiveExtensions.contains(ext) || info.kind == .archive else {
      throw RulesError.notArchive
    }
    let fm = FileManager.default
    // Hidden, so passes skip it while it fills up.
    let temporary = parent.appendingPathComponent(".kitzi-extract-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
    do {
      if ext == "zip" {
        try await ToolRunner.check("/usr/bin/ditto", ["-x", "-k", info.url.path, temporary.path])
      } else {
        try await ToolRunner.check("/usr/bin/tar", ["-xf", info.url.path, "-C", temporary.path])
      }
      try? fm.removeItem(at: temporary.appendingPathComponent("__MACOSX"))
      let items = try fm.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent != ".DS_Store" }
      let target: URL
      if items.count == 1 {
        let item = items[0]
        target = FileOps.uniqueURL(in: parent, fullName: item.lastPathComponent, isFolder: FileOps.isDirectory(item))
        try fm.moveItem(at: item, to: target)
        try fm.removeItem(at: temporary)
      } else {
        target = FileOps.uniqueURL(in: parent, fullName: FileOps.archiveBaseName(info.fullName), isFolder: true)
        try fm.moveItem(at: temporary, to: target)
      }
      return target
    } catch {
      try? fm.removeItem(at: temporary)
      throw error
    }
  }
}

// MARK: - Running tools

/// Runs a command-line tool without blocking a thread while it works, with a time limit.
nonisolated enum ToolRunner {
  struct Result: Sendable {
    var status: Int32
    var output: String
    var timedOut: Bool
  }

  /// Throws if the tool fails; for built-in tools like ditto and tar.
  static func check(_ path: String, _ arguments: [String], timeout: TimeInterval = 600) async throws {
    let result = try await run(path, arguments, in: nil, timeout: timeout)
    if result.timedOut { throw RulesError.timedOut(Int(timeout)) }
    guard result.status == 0 else {
      throw RulesError.failed(result.output.isEmpty ? String(localized: "The command failed.") : result.output)
    }
  }

  static func run(_ path: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval) async throws -> Result {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    if let directory { process.currentDirectoryURL = directory }
    var environment = ProcessInfo.processInfo.environment
    // Apps start with a short PATH; add the usual Homebrew places so scripts find their tools.
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
    process.environment = environment

    // Output goes to a file, so a chatty tool can't fill a pipe and stall.
    let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("kitzi-rules-\(UUID().uuidString).log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let log = try FileHandle(forWritingTo: logURL)
    defer {
      try? log.close()
      try? FileManager.default.removeItem(at: logURL)
    }
    process.standardOutput = log
    process.standardError = log
    process.standardInput = FileHandle.nullDevice

    let watchdog = ProcessWatchdog(process)
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { finished in
        continuation.resume(returning: finished.terminationStatus)
      }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
        return
      }
      watchdog.arm(after: timeout)
    }
    let data = (try? Data(contentsOf: logURL)) ?? Data()
    let output = String(decoding: data.suffix(2_000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return Result(status: status, output: output, timedOut: watchdog.didTimeOut)
  }
}

/// Stops a process that runs past its time limit: SIGTERM first, SIGKILL a few seconds later.
nonisolated final class ProcessWatchdog: @unchecked Sendable {
  private let process: Process
  private let lock = NSLock()
  private var timedOut = false

  init(_ process: Process) {
    self.process = process
  }

  var didTimeOut: Bool { lock.withLock { timedOut } }

  func arm(after seconds: TimeInterval) {
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [self] in
      lock.withLock {
        guard process.isRunning else { return }
        timedOut = true
        process.terminate()
      }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [self] in
        lock.withLock {
          if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
      }
    }
  }
}
