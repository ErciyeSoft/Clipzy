import AppKit
import SwiftUI

/// One page in the unified Kitzi settings window.
public struct SettingsPage: Identifiable {
  public let id: String
  public let title: String
  public let subtitle: String
  public let systemImage: String
  private let makeContent: @MainActor () -> AnyView

  public init<Content: View>(
    id: String,
    title: String,
    subtitle: String = "",
    systemImage: String,
    @ViewBuilder content: @escaping @MainActor () -> Content
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.systemImage = systemImage
    self.makeContent = { AnyView(content()) }
  }

  @MainActor
  public func makeView() -> AnyView {
    makeContent()
  }
}

/// A sidebar section of the settings window, contributed by one feature.
public struct SettingsGroup: Identifiable {
  public let id: String
  public let title: String
  public let pages: [SettingsPage]

  public init(id: String, title: String, pages: [SettingsPage]) {
    self.id = id
    self.title = title
    self.pages = pages
  }
}

/// A self-contained feature module hosted by the Kitzi app (clipboard, dock, battery, ...).
@MainActor
public protocol KitziFeature: AnyObject {
  var settingsGroups: [SettingsGroup] { get }
  func applicationWillFinishLaunching()
  func applicationDidFinishLaunching()
  func applicationWillTerminate()
  /// Called when the unified settings window closes, so a feature can drop caches.
  func settingsWindowDidClose()
}

public extension KitziFeature {
  func applicationWillFinishLaunching() {}
  func applicationWillTerminate() {}
  func settingsWindowDidClose() {}
}

/// Services the host app provides to feature modules.
@MainActor
public enum KitziHost {
  /// Opens the unified settings window, optionally on a specific page id.
  public static var openSettings: (_ pageID: String?) -> Void = { _ in }

  public static func quit() {
    NSApplication.shared.terminate(nil)
  }

  public static func restart() {
    let path = Bundle.main.bundlePath
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-n", path]
    try? task.run()
    quit()
  }
}

// MARK: - Cross-module services

/// The screen edge a dock-like surface sits on; used to place window previews.
public enum ScreenEdge: String, CaseIterable, Sendable {
  case bottom, left, right
}

/// Shows window previews for an app anchored to an icon (implemented by DockKit).
@MainActor
public protocol WindowPreviewProviding: AnyObject {
  /// `iconFrame` is in Cocoa screen coordinates (origin at the bottom-left of the main screen).
  func showPreviews(for app: NSRunningApplication, iconFrame: CGRect, edge: ScreenEdge)
  func hidePreviews()
  var isPointerInPreviews: Bool { get }
}

/// Registry where modules publish services for each other, without importing each other.
@MainActor
public enum KitziServices {
  public static weak var windowPreviews: (any WindowPreviewProviding)?
}

// MARK: - Regular windows

/// Kitzi runs as a menu bar app; while any real window (settings, editor) is open it
/// becomes a regular app so the window can take keyboard focus and show in ⌘Tab.
@MainActor
public enum KitziWindows {
  private static var openCount = 0

  public static func didOpen() {
    openCount += 1
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  public static func didClose() {
    openCount = max(0, openCount - 1)
    if openCount == 0 {
      NSApp.setActivationPolicy(.accessory)
    }
  }
}
