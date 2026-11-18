import AppKit
import KitziCore
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
  static let menuBarToggleHidden = Self("menuBarToggleHidden")
  static let menuBarToggleAlwaysHidden = Self("menuBarToggleAlwaysHidden")
  static let menuBarSearch = Self("menuBarSearch")
}

/// Public entry point of the menu bar module: hides menu bar icons behind a Kitzi toggle,
/// Bartender-style, and finds any menu bar item by name. Off until turned on in settings.
public final class MenuBarFeature: KitziFeature {
  static let pageID = "menubar.general"

  private let controller = MenuBarController()
  private let search = MenuBarSearchPanel()
  private var defaultsObserver: NSObjectProtocol?
  private var hotkeysEnabled: Bool?

  public init() {
    MenuBarPrefs.register()
  }

  public func applicationDidFinishLaunching() {
    controller.onSearch = { [weak self] in self?.search.show() }
    controller.onSettings = { KitziHost.openSettings(Self.pageID) }
    search.onActivate = { [weak self] item in self?.press(item) }

    KeyboardShortcuts.onKeyUp(for: .menuBarToggleHidden) { [weak self] in
      self?.controller.perform(.toggle)
    }
    KeyboardShortcuts.onKeyUp(for: .menuBarToggleAlwaysHidden) { [weak self] in
      self?.controller.perform(.toggleAll)
    }
    KeyboardShortcuts.onKeyUp(for: .menuBarSearch) { [weak self] in
      self?.search.toggle()
    }

    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.applyPreferences() }
    }
    applyPreferences()
  }

  public func applicationWillTerminate() {
    controller.prepareForQuit()
  }

  public var settingsGroups: [SettingsGroup] {
    [
      SettingsGroup(
        id: "menubar",
        title: String(localized: "Menu Bar"),
        pages: [
          SettingsPage(
            id: Self.pageID,
            title: String(localized: "Menu Bar"),
            subtitle: String(localized: "Hide and find menu bar icons"),
            systemImage: "menubar.rectangle"
          ) { [controller, search] in
            MenuBarSettingsView(
              status: controller.status,
              resetPositions: { controller.resetPositions() },
              openSearch: { search.show() }
            )
          }
        ]
      )
    ]
  }

  /// Runs on every defaults change, including macOS saving item positions, so it only acts
  /// on what actually changed.
  private func applyPreferences() {
    let settings = MenuBarSettings.current()
    controller.update(settings)
    guard hotkeysEnabled != settings.enabled else { return }
    hotkeysEnabled = settings.enabled
    let names: [KeyboardShortcuts.Name] = [.menuBarToggleHidden, .menuBarToggleAlwaysHidden]
    if settings.enabled {
      KeyboardShortcuts.enable(names)
    } else {
      KeyboardShortcuts.disable(names)
    }
  }

  /// Shows the hidden sections so the item is on screen, then presses it.
  private func press(_ item: MenuBarExtraItem) {
    let moved = controller.revealAll()
    Task {
      // Give the menu bar a moment to lay the revealed items out.
      try? await Task.sleep(for: .milliseconds(moved ? 350 : 60))
      _ = await Task.detached(priority: .userInitiated) { MenuBarAX.press(item) }.value
    }
  }
}
