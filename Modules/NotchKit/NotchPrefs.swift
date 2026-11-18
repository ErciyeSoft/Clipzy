import Foundation

/// Which screens get a notch panel.
enum NotchScreenChoice: String, CaseIterable {
  /// Only screens with a camera housing (MacBook displays). Nothing shows on other screens.
  case notchScreens
  /// The main screen; a pill at the top center when it has no notch.
  case mainScreen
  /// Every screen.
  case allScreens
}

/// User defaults of the notch module.
enum NotchPrefs {
  static let enabledKey = "notch.enabled"
  static let screensKey = "notch.screens"
  static let openOnHoverKey = "notch.openOnHover"
  static let nowPlayingKey = "notch.nowPlaying"
  static let nowPlayingClosedKey = "notch.nowPlayingClosed"
  static let shelfKey = "notch.shelf"
  static let calendarKey = "notch.calendar"
  static let hudKey = "notch.hud"
  static let batteryKey = "notch.battery"
  static let shelfItemsKey = "notch.shelfItems"

  static func register() {
    UserDefaults.standard.register(defaults: [
      // On a notch screen the closed panel is black on black, so it doesn't get in the way.
      enabledKey: true,
      screensKey: NotchScreenChoice.notchScreens.rawValue,
      openOnHoverKey: true,
      nowPlayingKey: true,
      nowPlayingClosedKey: true,
      shelfKey: true,
      calendarKey: true,
      // Replacing the system HUD swallows the volume and brightness keys: off until asked for.
      hudKey: false,
      batteryKey: true,
    ])
  }
}

/// A snapshot of the preferences, compared to find out what changed.
struct NotchSettings: Equatable {
  var enabled = true
  var screens = NotchScreenChoice.notchScreens
  var openOnHover = true
  var nowPlaying = true
  var nowPlayingClosed = true
  var shelf = true
  var calendar = true
  var hud = false
  var battery = true

  static func current(_ defaults: UserDefaults = .standard) -> NotchSettings {
    NotchSettings(
      enabled: defaults.bool(forKey: NotchPrefs.enabledKey),
      screens: NotchScreenChoice(rawValue: defaults.string(forKey: NotchPrefs.screensKey) ?? "") ?? .notchScreens,
      openOnHover: defaults.bool(forKey: NotchPrefs.openOnHoverKey),
      nowPlaying: defaults.bool(forKey: NotchPrefs.nowPlayingKey),
      nowPlayingClosed: defaults.bool(forKey: NotchPrefs.nowPlayingClosedKey),
      shelf: defaults.bool(forKey: NotchPrefs.shelfKey),
      calendar: defaults.bool(forKey: NotchPrefs.calendarKey),
      hud: defaults.bool(forKey: NotchPrefs.hudKey),
      battery: defaults.bool(forKey: NotchPrefs.batteryKey)
    )
  }
}
