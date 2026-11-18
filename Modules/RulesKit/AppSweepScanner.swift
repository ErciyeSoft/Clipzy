import AppKit
import Foundation

/// An app found in an Applications folder.
nonisolated struct InstalledApp: Codable, Hashable, Sendable {
  var bundleID: String
  /// File name without ".app".
  var name: String
  var bundleName: String?
  var path: String
}

/// A file or folder in ~/Library that a removed app probably left behind.
nonisolated struct Leftover: Identifiable, Hashable, Sendable {
  var id: String { url.path }
  var url: URL
  /// The Library folder it is in, like "Caches".
  var location: String
  var size: Int64
  /// Found by the app's name rather than its bundle ID, so worth a second look.
  var matchedByName: Bool
}

nonisolated struct AppLeftovers: Identifiable, Hashable, Sendable {
  var id: String { app.bundleID }
  var app: InstalledApp
  var items: [Leftover]
}

/// Keeps a map of installed apps by bundle ID and, when one disappears, looks for its
/// leftovers in ~/Library. It only reports what it finds; it never deletes anything.
/// The Trash itself is never read (that would need Full Disk Access).
actor AppSweepScanner {
  /// More apps than this vanishing at once looks like an unmounted disk, not a cleanup.
  private static let suspiciousRemovals = 10

  private let applicationFolders: [URL]
  private let library: URL
  private let mapURL: URL
  private let confirmDelay: Duration
  private let isInstalledElsewhere: @Sendable (String) -> Bool
  private var known: [String: InstalledApp] = [:]
  private var isChecking = false
  private var needsAnotherCheck = false

  init(applicationFolders: [URL], library: URL, directory: URL, confirmDelay: Duration = .seconds(8),
       isInstalledElsewhere: @escaping @Sendable (String) -> Bool = AppSweepScanner.launchServicesKnows) {
    self.applicationFolders = applicationFolders
    self.library = library
    mapURL = directory.appendingPathComponent("apps.json")
    self.confirmDelay = confirmDelay
    self.isInstalledElsewhere = isInstalledElsewhere
  }

  /// Whether Launch Services still knows a copy of the app outside the Trash.
  static let launchServicesKnows: @Sendable (String) -> Bool = { bundleID in
    NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).contains { url in
      !url.path.contains("/.Trash/") && FileManager.default.fileExists(atPath: url.path)
    }
  }

  /// Loads the saved map and reports apps removed while Kitzi wasn't running.
  func start() async -> [AppLeftovers] {
    if known.isEmpty, let data = try? Data(contentsOf: mapURL),
       let saved = try? JSONDecoder().decode([String: InstalledApp].self, from: data) {
      known = saved
    }
    if known.isEmpty {
      if let current = Self.scanApps(in: applicationFolders) {
        known = current
        save()
      }
      return []
    }
    return await check()
  }

  /// Forgets the map, for when App Sweep is turned off.
  func reset() {
    known = [:]
    try? FileManager.default.removeItem(at: mapURL)
  }

  /// Rescans the Applications folders and returns leftovers of apps that are gone.
  func check() async -> [AppLeftovers] {
    if isChecking {
      needsAnotherCheck = true
      return []
    }
    isChecking = true
    defer { isChecking = false }
    var found: [AppLeftovers] = []
    repeat {
      needsAnotherCheck = false
      guard var current = Self.scanApps(in: applicationFolders) else { return found }
      let missing = known.keys.filter { current[$0] == nil }
      if !missing.isEmpty {
        // Updaters often remove the old copy a moment before the new one lands.
        try? await Task.sleep(for: confirmDelay)
        guard let again = Self.scanApps(in: applicationFolders) else { return found }
        current = again
        let gone = missing.filter { current[$0] == nil }
        if gone.count <= Self.suspiciousRemovals {
          for id in gone {
            guard let app = known[id], !id.hasPrefix("com.apple."), !isInstalledElsewhere(id) else { continue }
            let items = Self.findLeftovers(for: app, library: library, installed: current)
            if !items.isEmpty { found.append(AppLeftovers(app: app, items: items)) }
          }
        }
      }
      known = current
      save()
    } while needsAnotherCheck
    return found
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(known) else { return }
    try? FileManager.default.createDirectory(at: mapURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: mapURL, options: .atomic)
  }

  // MARK: Scanning

  /// Apps at the top of each folder and one level down (like /Applications/Utilities).
  /// Nil if a folder that exists can't be read, so a hiccup never looks like a mass removal.
  static func scanApps(in folders: [URL]) -> [String: InstalledApp]? {
    let fm = FileManager.default
    var apps: [String: InstalledApp] = [:]
    func add(_ url: URL) {
      guard let app = readApp(url), apps[app.bundleID] == nil else { return }
      apps[app.bundleID] = app
    }
    for folder in folders where FileOps.isDirectory(folder) {
      guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles]) else { return nil }
      for item in items {
        if item.pathExtension == "app" {
          add(item)
        } else if FileOps.isDirectory(item) {
          let inner = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
          inner.filter { $0.pathExtension == "app" }.forEach(add)
        }
      }
    }
    return apps
  }

  static func readApp(_ url: URL) -> InstalledApp? {
    let plistURL = url.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: plistURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let id = plist["CFBundleIdentifier"] as? String, !id.isEmpty else { return nil }
    let bundleName = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
    return InstalledApp(bundleID: id, name: url.deletingPathExtension().lastPathComponent,
                        bundleName: bundleName, path: url.path)
  }

  // MARK: Leftovers

  /// Looks in the usual ~/Library places for items named after the bundle ID, and in
  /// Application Support, Caches and Logs also for the app's name. Anything that also
  /// belongs to an installed app is left out.
  static func findLeftovers(for app: InstalledApp, library: URL, installed: [String: InstalledApp]) -> [Leftover] {
    let fm = FileManager.default
    let id = app.bundleID
    let lowerID = id.lowercased()
    let installedIDs = Set(installed.keys.map { $0.lowercased() })
    let installedNames = Set(installed.values.flatMap { [$0.name, $0.bundleName].compactMap { $0?.lowercased() } })
    let names = Set([app.name, app.bundleName].compactMap { $0 }.filter {
      $0.count >= 3 && !installedNames.contains($0.lowercased()) && $0.lowercased() != lowerID
    })
    var results: [Leftover] = []
    var seen = Set<String>()

    func add(_ url: URL, byName: Bool = false) {
      guard FileOps.exists(url), seen.insert(url.path.lowercased()).inserted else { return }
      let location = fm.displayName(atPath: url.deletingLastPathComponent().path)
      results.append(Leftover(url: url, location: location, size: FileOps.allocatedSize(of: url), matchedByName: byName))
    }
    /// `stem` is the app's ID or starts with it, and no installed app with a longer ID owns it.
    func ownsStem(_ stem: String) -> Bool {
      let lower = stem.lowercased()
      guard lower == lowerID || lower.hasPrefix(lowerID + ".") else { return false }
      return !installedIDs.contains { $0.count > lowerID.count && (lower == $0 || lower.hasPrefix($0 + ".")) }
    }
    func folder(_ path: String) -> URL { library.appendingPathComponent(path, isDirectory: true) }

    for place in ["Application Support", "Caches", "Logs", "Containers", "HTTPStorages", "WebKit", "Application Scripts"] {
      add(folder(place).appendingPathComponent(id))
    }
    for place in ["Application Support", "Caches", "Logs"] {
      for name in names.sorted() { add(folder(place).appendingPathComponent(name), byName: true) }
    }
    add(folder("Saved Application State").appendingPathComponent("\(id).savedState"))
    add(folder("HTTPStorages").appendingPathComponent("\(id).binarycookies"))
    add(folder("Cookies").appendingPathComponent("\(id).binarycookies"))

    // Preference and launch agent files: "<id>.plist", "<id>.something.plist".
    for place in ["Preferences", "Preferences/ByHost", "LaunchAgents"] {
      for name in (try? fm.contentsOfDirectory(atPath: folder(place).path)) ?? [] where name.hasSuffix(".plist") {
        if ownsStem(String(name.dropLast(".plist".count))) { add(folder(place).appendingPathComponent(name)) }
      }
    }
    // Group containers are named "<team or group>.<id>".
    for name in (try? fm.contentsOfDirectory(atPath: folder("Group Containers").path)) ?? [] {
      let lower = name.lowercased()
      guard lower == lowerID || lower.hasSuffix("." + lowerID) else { continue }
      add(folder("Group Containers").appendingPathComponent(name))
    }
    return results.sorted {
      ($0.location, $0.url.lastPathComponent.lowercased()) < ($1.location, $1.url.lastPathComponent.lowercased())
    }
  }
}
