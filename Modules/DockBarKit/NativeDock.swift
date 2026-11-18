import AppKit

/// One user-pinned entry of the Kitzi Dock.
struct PinnedItem: Codable, Hashable, Identifiable {
  enum Kind: String, Codable {
    case app, folder, file, spacer
  }

  var id = UUID()
  var kind: Kind
  var path: String
}

/// Persists the pinned items; the first time, copies them from the macOS Dock.
enum PinnedStore {
  static func load() -> [PinnedItem] {
    if let data = UserDefaults.standard.data(forKey: DockBarPrefs.pinnedKey),
       let items = try? JSONDecoder().decode([PinnedItem].self, from: data) {
      return items
    }
    let items = NativeDock.pinnedItems()
    save(items)
    return items
  }

  static func save(_ items: [PinnedItem]) {
    guard let data = try? JSONEncoder().encode(items) else { return }
    UserDefaults.standard.set(data, forKey: DockBarPrefs.pinnedKey)
  }

  static func resetFromNativeDock() -> [PinnedItem] {
    let items = NativeDock.pinnedItems()
    save(items)
    return items
  }
}

/// Reads and adjusts the built-in macOS Dock (`com.apple.dock` preferences).
enum NativeDock {
  private static let domain = "com.apple.dock"

  static func pinnedItems() -> [PinnedItem] {
    let defaults = UserDefaults(suiteName: domain)
    let apps = defaults?.array(forKey: "persistent-apps") as? [[String: Any]] ?? []
    let others = defaults?.array(forKey: "persistent-others") as? [[String: Any]] ?? []
    return (apps + others).compactMap(parse)
  }

  private static func parse(_ tile: [String: Any]) -> PinnedItem? {
    let type = tile["tile-type"] as? String ?? ""
    if type.contains("spacer") {
      return PinnedItem(kind: .spacer, path: "")
    }
    guard let data = tile["tile-data"] as? [String: Any],
          let file = data["file-data"] as? [String: Any],
          let raw = file["_CFURLString"] as? String else {
      return nil
    }
    let url = (file["_CFURLStringType"] as? Int) == 15
      ? (URL(string: raw) ?? URL(fileURLWithPath: raw))
      : URL(fileURLWithPath: raw)
    guard url.isFileURL else { return nil }
    let path = url.standardizedFileURL.path
    if path.hasSuffix(".app") {
      return PinnedItem(kind: .app, path: path)
    }
    var isDirectory: ObjCBool = false
    FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    return PinnedItem(kind: isDirectory.boolValue ? .folder : .file, path: path)
  }

  // MARK: - Hiding

  /// What the user had before Kitzi changed it, so it can be put back exactly.
  private struct SavedState: Codable {
    var autohide: Bool?
    var autohideDelay: Double?
  }

  static var isHiddenByKitzi: Bool {
    UserDefaults.standard.data(forKey: DockBarPrefs.savedNativeDockKey) != nil
  }

  /// Keeps the macOS Dock out of the way: auto-hide with a very long reveal delay.
  static func hide() {
    if !isHiddenByKitzi {
      let defaults = UserDefaults(suiteName: domain)
      let state = SavedState(
        autohide: defaults?.object(forKey: "autohide") as? Bool,
        autohideDelay: (defaults?.object(forKey: "autohide-delay") as? NSNumber)?.doubleValue
      )
      UserDefaults.standard.set(try? JSONEncoder().encode(state), forKey: DockBarPrefs.savedNativeDockKey)
    }
    run("/usr/bin/defaults", ["write", domain, "autohide", "-bool", "true"])
    run("/usr/bin/defaults", ["write", domain, "autohide-delay", "-float", "1000"])
    restartDock()
  }

  /// Puts back the user's own auto-hide settings.
  static func restore() {
    guard let data = UserDefaults.standard.data(forKey: DockBarPrefs.savedNativeDockKey),
          let state = try? JSONDecoder().decode(SavedState.self, from: data) else {
      return
    }
    if let autohide = state.autohide {
      run("/usr/bin/defaults", ["write", domain, "autohide", "-bool", autohide ? "true" : "false"])
    } else {
      run("/usr/bin/defaults", ["delete", domain, "autohide"])
    }
    if let delay = state.autohideDelay {
      run("/usr/bin/defaults", ["write", domain, "autohide-delay", "-float", String(delay)])
    } else {
      run("/usr/bin/defaults", ["delete", domain, "autohide-delay"])
    }
    UserDefaults.standard.removeObject(forKey: DockBarPrefs.savedNativeDockKey)
    restartDock()
  }

  private static func restartDock() {
    run("/usr/bin/killall", ["Dock"])
  }

  private static func run(_ tool: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
  }
}
