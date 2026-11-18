import AppKit
import KitziCore
import SwiftUI

enum DisplayPrefs {
  static let menuBarKey = "display.menuBar"
  static let brightnessKeysKey = "display.brightnessKeys"

  static func register() {
    UserDefaults.standard.register(defaults: [menuBarKey: true, brightnessKeysKey: true])
  }

  static var showInMenuBar: Bool { UserDefaults.standard.bool(forKey: menuBarKey) }
  static var brightnessKeys: Bool { UserDefaults.standard.bool(forKey: brightnessKeysKey) }
}

/// Public entry point of the display manager (BetterDisplay-style): resolutions including
/// HiDPI and hidden modes, brightness for external monitors over DDC/CI or software dimming,
/// brightness keys for the display under the pointer, mirroring, main display and virtual
/// displays. Nothing on a display changes until the user asks for it.
public final class DisplayFeature: KitziFeature {
  static let pageID = "display.general"
  static let virtualPageID = "display.virtual"

  private let store = VirtualDisplayStore()
  private let manager: DisplayManager
  private let hud = BrightnessHUD()
  private var keyTap: BrightnessKeyTap?
  private var hasKeyTargets = false
  private var statusItem: NSStatusItem?
  private let popover = NSPopover()
  private var observers: [NSObjectProtocol] = []
  private var refreshTask: Task<Void, Never>?
  #if DEBUG
  private var debugHooks: DisplayDebugHooks?
  #endif

  public init() {
    DisplayPrefs.register()
    manager = DisplayManager(virtualDisplays: store)
  }

  public func applicationDidFinishLaunching() {
    let tap = BrightnessKeyTap { [weak self] display, up, fine in
      self?.brightnessKey(display, up: up, fine: fine)
    }
    keyTap = tap
    manager.onKeyTargetsChanged = { [weak self] targets in
      tap.setTargets(targets)
      self?.hasKeyTargets = !targets.isEmpty
      self?.applyKeyTap()
    }
    store.connectSaved()
    manager.start()
    observers.append(NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.applyPreferences() }
    })
    applyPreferences()
    #if DEBUG
    debugHooks = DisplayDebugHooks(manager: manager, store: store, openMenu: { [weak self] in
      if let button = self?.statusItem?.button { self?.togglePopover(button) }
    }, isKeyTapRunning: { [weak self] in self?.keyTap?.isRunning ?? false })
    #endif
  }

  public func applicationWillTerminate() {
    keyTap?.stop()
    manager.stop()
    store.disconnectAll()
  }

  public var settingsGroups: [SettingsGroup] {
    [
      SettingsGroup(
        id: "display",
        title: String(localized: "Displays"),
        pages: [
          SettingsPage(
            id: Self.pageID,
            title: String(localized: "Displays"),
            subtitle: String(localized: "Resolution, brightness and arrangement of your displays"),
            systemImage: "display"
          ) { [manager] in
            DisplaySettingsView(manager: manager)
          },
          SettingsPage(
            id: Self.virtualPageID,
            title: String(localized: "Virtual Displays"),
            subtitle: String(localized: "Displays that aren't there, for custom HiDPI sizes"),
            systemImage: "rectangle.dashed"
          ) { [store] in
            VirtualDisplaysSettingsView(store: store)
          },
        ]
      )
    ]
  }

  private func applyPreferences() {
    if DisplayPrefs.showInMenuBar {
      if statusItem == nil { statusItem = makeStatusItem() }
    } else {
      if let statusItem {
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
      }
      popover.performClose(nil)
    }
    applyKeyTap()
  }

  /// The tap only runs while a display needs it, so Accessibility is asked for only then.
  private func applyKeyTap() {
    guard let keyTap else { return }
    if DisplayPrefs.brightnessKeys, hasKeyTargets {
      keyTap.start()
    } else {
      keyTap.stop()
    }
  }

  private func brightnessKey(_ display: CGDirectDisplayID, up: Bool, fine: Bool) {
    guard let level = manager.stepBrightness(for: display, up: up, fine: fine),
          let info = manager.info(display) else { return }
    hud.show(level: level, name: info.name, on: display)
  }

  private func makeStatusItem() -> NSStatusItem {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.autosaveName = "KitziDisplays"
    let icon = NSImage(systemSymbolName: "display", accessibilityDescription: String(localized: "Displays"))?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
    icon?.isTemplate = true
    item.button?.image = icon
    item.button?.target = self
    item.button?.action = #selector(togglePopover(_:))
    popover.behavior = .transient
    return item
  }

  @objc private func togglePopover(_ sender: NSStatusBarButton) {
    if popover.isShown {
      popover.performClose(sender)
      return
    }
    manager.refresh()
    let controller = NSHostingController(rootView: DisplayMenuView(manager: manager) { [weak self] pageID in
      self?.popover.performClose(nil)
      KitziHost.openSettings(pageID)
    })
    // Size before showing so the popover opens right under the menu bar.
    controller.sizingOptions = .preferredContentSize
    popover.contentViewController = controller
    popover.contentSize = controller.view.fittingSize
    popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
    // Follow brightness changed with the keys or Control Center while the menu is open.
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      while !Task.isCancelled, self?.popover.isShown == true {
        try? await Task.sleep(for: .seconds(1))
        self?.manager.refreshBrightness()
      }
    }
  }
}
