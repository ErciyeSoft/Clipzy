import AppKit
import BatteryKit
import CaptureKit
import ClipboardKit
import KitziCore
import ConvertKit
import DiskKit
import DisplayKit
import DockBarKit
import DockKit
import MenuBarKit
import NotchKit
import RemoteKit
import RulesKit
import VolumeKit
import WindowsKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let clipboard = ClipboardFeature()
  private let dock = DockFeature()
  private let battery = BatteryFeature()
  private let dockBar = DockBarFeature()
  private let capture = CaptureFeature()
  private let volume = VolumeFeature()
  private let convert = ConvertFeature()
  private let windows = WindowsFeature()
  private let menuBar = MenuBarFeature()
  private let disk = DiskFeature()
  private let rules = RulesFeature()
  private let remote = RemoteFeature()
  private let notch = NotchFeature()
  private let display = DisplayFeature()

  private lazy var features: [KitziFeature] = [clipboard, dock, dockBar, menuBar, notch, capture, volume, convert, disk, rules, remote, display, windows, battery]
  private lazy var settings = SettingsWindowController { [unowned self] in
    features.flatMap(\.settingsGroups)
  } onClose: { [unowned self] in
    features.forEach { $0.settingsWindowDidClose() }
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    #if DEBUG
    // Test hook: `open -n Kitzi.app --args -KitziOnlyFeatures notch` starts only the features
    // with these settings group ids, so a test build can run next to the installed app.
    if let only = UserDefaults.standard.string(forKey: "KitziOnlyFeatures") {
      let ids = Set(only.split(separator: ",").map(String.init))
      features = features.filter { feature in feature.settingsGroups.contains { ids.contains($0.id) } }
    }
    #endif
    KitziHost.openSettings = { [unowned self] pageID in
      settings.show(pageID: pageID)
    }
    installMainMenu()
    features.forEach { $0.applicationWillFinishLaunching() }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    features.forEach { $0.applicationDidFinishLaunching() }

    #if DEBUG
    // Test hook: `open Kitzi.app --args -KitziOpenSettingsPage dock.DockPreviews`
    if let pageID = UserDefaults.standard.string(forKey: "KitziOpenSettingsPage") {
      settings.show(pageID: pageID)
    }
    #endif
  }

  func applicationWillTerminate(_ notification: Notification) {
    features.forEach { $0.applicationWillTerminate() }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    settings.show(pageID: nil)
    return false
  }

  // MARK: - Main menu (only visible while the settings window is in front)

  private func installMainMenu() {
    let mainMenu = NSMenu()

    let appMenu = NSMenu()
    appMenu.addItem(withTitle: String(localized: "About Kitzi"),
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
      .target = self
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: String(localized: "Quit Kitzi"),
                    action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    mainMenu.addItem(submenuItem(appMenu))

    let editMenu = NSMenu(title: String(localized: "Edit"))
    editMenu.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    mainMenu.addItem(submenuItem(editMenu))

    let windowMenu = NSMenu(title: String(localized: "Window"))
    windowMenu.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowMenu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    mainMenu.addItem(submenuItem(windowMenu))

    NSApp.mainMenu = mainMenu
    NSApp.windowsMenu = windowMenu
  }

  private func submenuItem(_ menu: NSMenu) -> NSMenuItem {
    let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
    item.submenu = menu
    return item
  }

  @objc private func openSettings() {
    settings.show(pageID: nil)
  }
}
