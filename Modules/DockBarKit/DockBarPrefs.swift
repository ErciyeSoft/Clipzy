import KitziCore
import Foundation

/// Preferences of the Kitzi Dock (plain UserDefaults, prefixed with `dockBar.`).
enum DockBarPrefs {
  static let enabledKey = "dockBar.enabled"
  static let hideNativeDockKey = "dockBar.hideNativeDock"
  static let restoreOnQuitKey = "dockBar.restoreNativeDockOnQuit"
  static let edgeKey = "dockBar.edge"
  static let iconSizeKey = "dockBar.iconSize"
  static let magnifyKey = "dockBar.magnify"
  static let maxScaleKey = "dockBar.maxScale"
  static let showRunningKey = "dockBar.showRunningApps"
  static let showTrashKey = "dockBar.showTrash"
  static let pinnedKey = "dockBar.pinnedItems"
  static let savedNativeDockKey = "dockBar.savedNativeDock"
  static let displayModeKey = "dockBar.displayMode"
  static let selectedDisplaysKey = "dockBar.selectedDisplays"
  static let reserveSpaceKey = "dockBar.reserveSpace"

  enum DisplayMode: String, CaseIterable {
    case main, all, selected
  }

  static func register() {
    UserDefaults.standard.register(defaults: [
      enabledKey: false,
      hideNativeDockKey: false,
      restoreOnQuitKey: true,
      edgeKey: ScreenEdge.bottom.rawValue,
      iconSizeKey: 52.0,
      magnifyKey: true,
      maxScaleKey: 1.8,
      showRunningKey: true,
      showTrashKey: true,
      displayModeKey: DisplayMode.main.rawValue,
      selectedDisplaysKey: "",
      reserveSpaceKey: true,
    ])
  }

  private static var defaults: UserDefaults { .standard }

  static var enabled: Bool { defaults.bool(forKey: enabledKey) }
  static var hideNativeDock: Bool { defaults.bool(forKey: hideNativeDockKey) }
  static var restoreOnQuit: Bool { defaults.bool(forKey: restoreOnQuitKey) }
  static var showRunningApps: Bool { defaults.bool(forKey: showRunningKey) }
  static var showTrash: Bool { defaults.bool(forKey: showTrashKey) }
  static var reserveSpace: Bool { defaults.bool(forKey: reserveSpaceKey) }

  static var displayMode: DisplayMode {
    DisplayMode(rawValue: defaults.string(forKey: displayModeKey) ?? "") ?? .main
  }

  /// Displays chosen in "Selected displays" mode (stable display UUIDs, newline separated).
  static var selectedDisplays: Set<String> {
    Set((defaults.string(forKey: selectedDisplaysKey) ?? "").split(separator: "\n").map(String.init))
  }

  static var edge: ScreenEdge {
    ScreenEdge(rawValue: defaults.string(forKey: edgeKey) ?? "") ?? .bottom
  }

  static var iconSize: CGFloat {
    min(128, max(24, CGFloat(defaults.double(forKey: iconSizeKey))))
  }

  /// Largest scale an icon reaches under the pointer; 1 when magnification is off.
  static var maxScale: CGFloat {
    guard defaults.bool(forKey: magnifyKey) else { return 1 }
    return min(3, max(1, CGFloat(defaults.double(forKey: maxScaleKey))))
  }
}
