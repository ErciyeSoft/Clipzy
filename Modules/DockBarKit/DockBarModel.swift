import AppKit
import KitziCore
import Observation

struct DockBarItem: Identifiable, Equatable {
  enum Kind: Equatable {
    case app, folder, file, spacer, separator, trash
  }

  let id: String
  let kind: Kind
  let title: String
  let url: URL?
  /// Set for items the user pinned; nil for running apps that are only shown while open.
  let pinnedID: UUID?
  var isRunning: Bool
  var pid: pid_t?

  var isIcon: Bool {
    kind != .spacer && kind != .separator
  }
}

/// Items of the Kitzi Dock and the magnification state.
@Observable
final class DockBarModel {
  private(set) var items: [DockBarItem] = []
  /// Icon size actually used: the preferred size, shrunk when the dock would not fit.
  private(set) var iconSize: CGFloat = 52
  @ObservationIgnored var preferredIconSize: CGFloat = 52 {
    didSet { fitIconSize() }
  }
  /// Room along the screen edge, set by the controller from the screen size.
  @ObservationIgnored var availableLength: CGFloat = .greatestFiniteMagnitude {
    didSet { fitIconSize() }
  }
  var maxScale: CGFloat = 1.8
  var edge: ScreenEdge = .bottom

  /// Pointer position along the dock, measured on the unmagnified layout; nil when outside.
  var pointer: CGFloat?
  var hoveredID: String?

  /// Item frames in the panel's SwiftUI coordinates (top-left origin), reported by the view.
  @ObservationIgnored var itemFrames: [String: CGRect] = [:]

  @ObservationIgnored private(set) var pinned: [PinnedItem] = []
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var pinnedObserver: NSObjectProtocol?

  /// Posted when one dock changes the pinned items, so docks on other displays follow.
  static let pinnedDidChange = Notification.Name("KitziDockPinnedDidChange")
  @ObservationIgnored private var iconCache: [String: NSImage] = [:]

  let spacing: CGFloat = 4
  var padding: CGFloat { max(6, (iconSize * 0.14).rounded()) }
  /// Thickness of the dock background across the screen edge.
  var thickness: CGFloat { iconSize + padding * 2 }
  /// Extra room across the edge needed by magnified icons and the name label.
  var headroom: CGFloat { iconSize * (maxScale - 1) + 40 }

  var isHorizontal: Bool { edge == .bottom }

  // MARK: - Lifecycle

  func start() {
    guard observers.isEmpty else { return }
    pinned = PinnedStore.load()
    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.didLaunchApplicationNotification,
      NSWorkspace.didTerminateApplicationNotification,
    ] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.rebuild() }
      })
    }
    pinnedObserver = NotificationCenter.default.addObserver(
      forName: Self.pinnedDidChange, object: nil, queue: .main
    ) { [weak self] notification in
      let sender = (notification.object as AnyObject?).map(ObjectIdentifier.init)
      MainActor.assumeIsolated {
        guard let self, sender != ObjectIdentifier(self) else { return }
        self.pinned = PinnedStore.load()
        self.rebuild()
      }
    }
    rebuild()
  }

  func stop() {
    if let pinnedObserver {
      NotificationCenter.default.removeObserver(pinnedObserver)
    }
    pinnedObserver = nil
    observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    observers.removeAll()
    pointer = nil
    hoveredID = nil
  }

  // MARK: - Items

  func rebuild() {
    let running = NSWorkspace.shared.runningApplications.filter {
      $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier
    }
    var runningByPath: [String: NSRunningApplication] = [:]
    for app in running {
      if let path = app.bundleURL?.standardizedFileURL.path {
        runningByPath[path] = app
      }
    }

    var result: [DockBarItem] = []
    var pinnedAppPaths = Set<String>()

    // The macOS Dock always starts with Finder, which is not stored with the pinned apps.
    let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
    if !pinned.contains(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == finderURL.path }) {
      pinnedAppPaths.insert(finderURL.path)
      let finder = runningByPath[finderURL.path]
      result.append(DockBarItem(id: "finder", kind: .app, title: Self.displayName(finderURL), url: finderURL,
                                pinnedID: nil, isRunning: finder != nil, pid: finder?.processIdentifier))
    }
    for item in pinned where item.kind == .app || item.kind == .spacer {
      if item.kind == .spacer {
        result.append(DockBarItem(id: item.id.uuidString, kind: .spacer, title: "", url: nil,
                                  pinnedID: item.id, isRunning: false))
        continue
      }
      let url = URL(fileURLWithPath: item.path).standardizedFileURL
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      pinnedAppPaths.insert(url.path)
      let app = runningByPath[url.path]
      result.append(DockBarItem(id: item.id.uuidString, kind: .app, title: Self.displayName(url), url: url,
                                pinnedID: item.id, isRunning: app != nil, pid: app?.processIdentifier))
    }

    if DockBarPrefs.showRunningApps {
      let unpinned = running
        .filter { app in app.bundleURL.map { !pinnedAppPaths.contains($0.standardizedFileURL.path) } ?? false }
        .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
      for app in unpinned {
        guard let url = app.bundleURL else { continue }
        result.append(DockBarItem(id: "running:\(app.processIdentifier)", kind: .app,
                                  title: app.localizedName ?? Self.displayName(url), url: url,
                                  pinnedID: nil, isRunning: true, pid: app.processIdentifier))
      }
    }

    let others = pinned.filter { $0.kind == .folder || $0.kind == .file }
      .filter { FileManager.default.fileExists(atPath: $0.path) }
    if !others.isEmpty || DockBarPrefs.showTrash {
      result.append(DockBarItem(id: "separator", kind: .separator, title: "", url: nil, pinnedID: nil, isRunning: false))
    }
    for item in others {
      let url = URL(fileURLWithPath: item.path)
      result.append(DockBarItem(id: item.id.uuidString, kind: item.kind == .folder ? .folder : .file,
                                title: Self.displayName(url), url: url, pinnedID: item.id, isRunning: false))
    }
    if DockBarPrefs.showTrash {
      result.append(DockBarItem(id: "trash", kind: .trash, title: String(localized: "Trash"),
                                url: Self.trashURL, pinnedID: nil, isRunning: false))
    }

    if result != items {
      items = result
    }
    fitIconSize()
  }

  /// Shrinks icons so the whole dock fits on screen, like the macOS Dock does.
  private func fitIconSize() {
    let iconCount = items.filter(\.isIcon).count
    let spacerCount = items.filter { $0.kind == .spacer }.count
    let separatorCount = items.filter { $0.kind == .separator }.count
    let padding = max(6, (preferredIconSize * 0.14).rounded())
    let fixed = padding * 2 + spacing * CGFloat(max(0, items.count - 1)) + 13 * CGFloat(separatorCount)
    let units = CGFloat(iconCount) + 0.5 * CGFloat(spacerCount)
    let fitting = units > 0 ? ((availableLength - fixed) / units).rounded(.down) : preferredIconSize
    let size = max(16, min(preferredIconSize, fitting))
    if size != iconSize {
      iconSize = size
    }
  }

  static let trashURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")

  private static func displayName(_ url: URL) -> String {
    FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
  }

  func icon(for item: DockBarItem) -> NSImage {
    if item.kind == .trash {
      return NSImage(named: NSImage.trashEmptyName) ?? NSImage()
    }
    guard let path = item.url?.path else { return NSImage() }
    if let cached = iconCache[path] { return cached }
    let image = NSWorkspace.shared.icon(forFile: path)
    iconCache[path] = image
    return image
  }

  // MARK: - Pinning

  func pin(_ urls: [URL], before targetID: String? = nil) {
    let newItems = urls.map { url -> PinnedItem in
      let path = url.standardizedFileURL.path
      var isDirectory: ObjCBool = false
      FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      let kind: PinnedItem.Kind = path.hasSuffix(".app") ? .app : (isDirectory.boolValue ? .folder : .file)
      return PinnedItem(kind: kind, path: path)
    }.filter { item in !pinned.contains { $0.path == item.path } }
    guard !newItems.isEmpty else { return }
    if let targetID, let index = pinned.firstIndex(where: { $0.id.uuidString == targetID }) {
      pinned.insert(contentsOf: newItems, at: index)
    } else {
      let firstOther = pinned.firstIndex { $0.kind == .folder || $0.kind == .file } ?? pinned.endIndex
      let apps = newItems.filter { $0.kind == .app }
      pinned.insert(contentsOf: apps, at: firstOther)
      pinned.append(contentsOf: newItems.filter { $0.kind != .app })
    }
    savePinned()
  }

  func unpin(_ item: DockBarItem) {
    guard let pinnedID = item.pinnedID else { return }
    pinned.removeAll { $0.id == pinnedID }
    savePinned()
  }

  /// Moves a pinned item in front of another pinned item (drag to reorder).
  func movePinned(id: String, before targetID: String) {
    guard id != targetID,
          let from = pinned.firstIndex(where: { $0.id.uuidString == id }) else { return }
    let moving = pinned.remove(at: from)
    let to = pinned.firstIndex { $0.id.uuidString == targetID } ?? pinned.endIndex
    pinned.insert(moving, at: to)
    savePinned()
  }

  func resetPinnedFromNativeDock() {
    pinned = PinnedStore.resetFromNativeDock()
    rebuild()
    NotificationCenter.default.post(name: Self.pinnedDidChange, object: self)
  }

  private func savePinned() {
    PinnedStore.save(pinned)
    rebuild()
    NotificationCenter.default.post(name: Self.pinnedDidChange, object: self)
  }

  // MARK: - Layout and magnification

  func baseLength(of item: DockBarItem) -> CGFloat {
    switch item.kind {
    case .separator: return 13
    case .spacer: return iconSize * 0.5
    default: return iconSize
    }
  }

  /// Length of the whole dock along its edge without magnification (padding included).
  var baseTotalLength: CGFloat {
    items.map(baseLength).reduce(0, +) + spacing * CGFloat(max(0, items.count - 1)) + padding * 2
  }

  /// Scale of each item; icons near the pointer grow with a smooth falloff.
  func scales() -> [CGFloat] {
    guard let pointer, maxScale > 1 else {
      return Array(repeating: 1, count: items.count)
    }
    let reach = iconSize * 2.6
    var position = padding
    return items.map { item in
      let length = baseLength(of: item)
      let center = position + length / 2
      position += length + spacing
      guard item.kind != .separator else { return 1 }
      let t = max(0, 1 - abs(center - pointer) / reach)
      let eased = t * t * (3 - 2 * t)
      return 1 + (maxScale - 1) * eased
    }
  }

  /// Length of the dock along its edge with the current magnification.
  var magnifiedTotalLength: CGFloat {
    let scales = scales()
    return zip(items, scales).map { baseLength(of: $0) * $1 }.reduce(0, +)
      + spacing * CGFloat(max(0, items.count - 1)) + padding * 2
  }
}
