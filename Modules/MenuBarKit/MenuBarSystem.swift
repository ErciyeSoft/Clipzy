import AppKit
import ApplicationServices

// Reads of system state that may take a while (window server, other apps over Accessibility).
// Everything here is nonisolated and meant to run off the main thread.

/// On-screen windows from CGWindowList. Bounds and owners need no Screen Recording access.
nonisolated enum WindowList {
  static func snapshot() -> [WindowSnapshot] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.compactMap { info in
      guard let id = info[kCGWindowNumber as String] as? Int,
            let layer = info[kCGWindowLayer as String] as? Int,
            let bounds = info[kCGWindowBounds as String] as? NSDictionary,
            let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
      return WindowSnapshot(
        id: id,
        pid: info[kCGWindowOwnerPID as String] as? Int32 ?? 0,
        layer: layer,
        frame: frame,
        ownerName: info[kCGWindowOwnerName as String] as? String ?? ""
      )
    }
  }

  /// Runs `snapshot()` on a background thread.
  static func snapshotInBackground() async -> [WindowSnapshot] {
    await Task.detached(priority: .userInitiated) { snapshot() }.value
  }
}

/// A running app, reduced to values that can cross threads.
struct RunningAppInfo: Sendable {
  var pid: Int32
  var name: String
  var bundleID: String?

  @MainActor static func all() -> [RunningAppInfo] {
    NSWorkspace.shared.runningApplications.compactMap { app in
      guard !app.isTerminated, app.processIdentifier > 0 else { return nil }
      return RunningAppInfo(
        pid: app.processIdentifier,
        name: app.localizedName ?? app.bundleIdentifier ?? "",
        bundleID: app.bundleIdentifier
      )
    }
  }
}

/// Menu bars of other apps over Accessibility: the frontmost app's menus and every app's
/// menu bar items ("menu extras"). All calls fail quietly without Accessibility access.
nonisolated enum MenuBarAX {
  /// Identifiers set on our own control items, so search can skip them.
  static let controlIdentifierPrefix = "KitziMenuBar."

  /// Horizontal extent of the app's menus (Apple menu to the last menu title), in Quartz coordinates.
  static func appMenuExtent(pid: Int32) -> ClosedRange<CGFloat>? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.2)
    guard let menuBar = element(app, kAXMenuBarAttribute) else { return nil }
    var minX = CGFloat.infinity
    var maxX = -CGFloat.infinity
    for item in children(of: menuBar) {
      guard let frame = frame(of: item), frame.width > 0 else { continue }
      minX = min(minX, frame.minX)
      maxX = max(maxX, frame.maxX)
    }
    return minX < maxX ? minX...maxX : nil
  }

  /// Menu bar items of all apps, in the order the apps are given.
  static func extras(of apps: [RunningAppInfo]) async -> [MenuBarExtraItem] {
    await withTaskGroup(of: (Int, [MenuBarExtraItem]).self) { group in
      for (offset, app) in apps.enumerated() {
        group.addTask { (offset, extras(of: app)) }
      }
      var found: [(Int, [MenuBarExtraItem])] = []
      for await result in group { found.append(result) }
      return found.sorted { $0.0 < $1.0 }.flatMap(\.1)
    }
  }

  static func extras(of app: RunningAppInfo) -> [MenuBarExtraItem] {
    extraElements(pid: app.pid).enumerated().compactMap { index, element in
      if let identifier = string(element, kAXIdentifierAttribute), identifier.hasPrefix(controlIdentifierPrefix) {
        return nil
      }
      return MenuBarExtraItem(
        pid: app.pid,
        index: index,
        title: title(of: element) ?? app.name,
        appName: app.name,
        bundleID: app.bundleID
      )
    }
  }

  /// Presses the item (opens its menu). The item is looked up again because it may have moved.
  @discardableResult
  static func press(_ item: MenuBarExtraItem) -> Bool {
    let elements = extraElements(pid: item.pid)
    let byIndex = elements.indices.contains(item.index) ? elements[item.index] : nil
    let target = byIndex.flatMap { (title(of: $0) ?? item.appName) == item.title ? $0 : nil }
      ?? elements.first { (title(of: $0) ?? item.appName) == item.title }
      ?? byIndex
    guard let target else { return false }
    // Some apps only answer once their menu closes; the press still goes through.
    AXUIElementSetMessagingTimeout(target, 0.5)
    let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
    return result == .success || result == .cannotComplete
  }

  // MARK: - Helpers

  private static func extraElements(pid: Int32) -> [AXUIElement] {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.2)
    guard let extras = element(app, kAXExtrasMenuBarAttribute) else { return [] }
    return children(of: extras)
  }

  /// A readable name: the title, else the description (most system items), else the tooltip.
  private static func title(of element: AXUIElement) -> String? {
    for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
      if let text = string(element, attribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
        return text
      }
    }
    return nil
  }

  private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
  }

  private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
  }

  private static func children(of element: AXUIElement) -> [AXUIElement] {
    value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
  }

  private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    value(element, attribute) as? String
  }

  private static func frame(of element: AXUIElement) -> CGRect? {
    guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
          AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
    return CGRect(origin: origin, size: extent)
  }
}
