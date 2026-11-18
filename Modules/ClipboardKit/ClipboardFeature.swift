import AppKit
import KitziCore
import SwiftUI

/// Public entry point of the clipboard history module (forked from Maccy).
public final class ClipboardFeature: KitziFeature {
  static let generalPageID = "clipboard.general"

  private let controller = ClipboardController()

  public init() {}

  public func applicationWillFinishLaunching() {
    controller.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
  }

  public func applicationDidFinishLaunching() {
    controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
  }

  public func applicationWillTerminate() {
    controller.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
  }

  /// Toggles the clipboard history popup.
  public func togglePopup() {
    controller.togglePopup()
  }

  public var settingsGroups: [SettingsGroup] {
    [
      SettingsGroup(
        id: "clipboard",
        title: String(localized: "Clipboard"),
        pages: [
          SettingsPage(
            id: Self.generalPageID,
            title: Self.title("GeneralSettings"),
            systemImage: "doc.on.clipboard"
          ) { ScrollView { GeneralSettingsPane().frame(maxWidth: .infinity) } },
          SettingsPage(
            id: "clipboard.storage",
            title: Self.title("StorageSettings"),
            systemImage: "externaldrive"
          ) { ScrollView { StorageSettingsPane().frame(maxWidth: .infinity) } },
          SettingsPage(
            id: "clipboard.appearance",
            title: Self.title("AppearanceSettings"),
            systemImage: "paintpalette"
          ) { ScrollView { AppearanceSettingsPane().frame(maxWidth: .infinity) } },
          SettingsPage(
            id: "clipboard.ignore",
            title: Self.title("IgnoreSettings"),
            systemImage: "nosign"
          ) { ScrollView { IgnoreSettingsPane().frame(maxWidth: .infinity) } },
          SettingsPage(
            id: "clipboard.advanced",
            title: Self.title("AdvancedSettings"),
            systemImage: "gearshape.2"
          ) { ScrollView { AdvancedSettingsPane().frame(maxWidth: .infinity) } }
        ]
      )
    ]
  }

  private static func title(_ table: String) -> String {
    NSLocalizedString("Title", tableName: table, comment: "")
  }
}
