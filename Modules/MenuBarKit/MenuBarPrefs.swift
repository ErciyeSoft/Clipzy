import AppKit

/// User defaults of the menu bar module.
enum MenuBarPrefs {
  static let enabledKey = "menubar.enabled"
  static let alwaysHiddenKey = "menubar.alwaysHidden"
  static let rehideDelayKey = "menubar.rehideDelay"
  static let rehideOnOutsideClickKey = "menubar.rehideOnOutsideClick"
  static let showOnHoverKey = "menubar.showOnHover"
  static let showOnClickKey = "menubar.showOnClick"
  static let showOnScrollKey = "menubar.showOnScroll"

  static func register() {
    UserDefaults.standard.register(defaults: [
      enabledKey: false,
      alwaysHiddenKey: false,
      rehideDelayKey: 10,
      rehideOnOutsideClickKey: true,
      showOnHoverKey: false,
      showOnClickKey: false,
      showOnScrollKey: false,
    ])
  }
}

/// A snapshot of the preferences, compared to find out what changed.
struct MenuBarSettings: Equatable {
  var enabled = false
  var alwaysHidden = false
  /// Seconds; 0 means never.
  var rehideDelay = 10
  var rehideOnOutsideClick = true
  var showOnHover = false
  var showOnClick = false
  var showOnScroll = false

  static func current(_ defaults: UserDefaults = .standard) -> MenuBarSettings {
    MenuBarSettings(
      enabled: defaults.bool(forKey: MenuBarPrefs.enabledKey),
      alwaysHidden: defaults.bool(forKey: MenuBarPrefs.alwaysHiddenKey),
      rehideDelay: max(0, defaults.integer(forKey: MenuBarPrefs.rehideDelayKey)),
      rehideOnOutsideClick: defaults.bool(forKey: MenuBarPrefs.rehideOnOutsideClickKey),
      showOnHover: defaults.bool(forKey: MenuBarPrefs.showOnHoverKey),
      showOnClick: defaults.bool(forKey: MenuBarPrefs.showOnClickKey),
      showOnScroll: defaults.bool(forKey: MenuBarPrefs.showOnScrollKey)
    )
  }
}

/// The menu bar strip of one screen, in Quartz coordinates.
struct MenuBarScreen {
  var rect: CGRect
  /// The camera housing, if the screen has one.
  var notch: CGRect?

  static func all() -> [MenuBarScreen] {
    guard let main = NSScreen.screens.first else { return [] }
    let mainHeight = main.frame.height
    return NSScreen.screens.map { screen in
      let fallback = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
      let rect = MenuBarGeometry.menuBarRect(
        screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
        fallbackHeight: fallback, mainScreenHeight: mainHeight
      )
      var notch: CGRect?
      let left = screen.auxiliaryTopLeftArea ?? .zero
      let right = screen.auxiliaryTopRightArea ?? .zero
      if !left.isEmpty, !right.isEmpty, right.minX > left.maxX {
        let cocoa = CGRect(x: left.maxX, y: left.minY, width: right.minX - left.maxX, height: left.height)
        notch = MenuBarGeometry.quartzRect(fromCocoa: cocoa, mainScreenHeight: mainHeight)
      }
      return MenuBarScreen(rect: rect, notch: notch)
    }
  }

  /// The current mouse location in Quartz coordinates.
  static func mouseLocation() -> CGPoint {
    let height = NSScreen.screens.first?.frame.height ?? 0
    return MenuBarGeometry.quartzPoint(fromCocoa: NSEvent.mouseLocation, mainScreenHeight: height)
  }
}
