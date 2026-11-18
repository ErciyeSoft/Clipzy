import AppKit
import KitziCore
import SwiftUI

/// Public entry point of the dock module (forked from DockDoor): dock previews,
/// window switcher, Cmd+Tab enhancements, gestures and widgets.
public final class DockFeature: KitziFeature {
    static let generalPageID = "dock.general"

    private let controller = DockController()
    private let previewService = DockPreviewService()

    public init() {}

    public func applicationDidFinishLaunching() {
        KitziServices.windowPreviews = previewService
        controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    }

    public func applicationWillTerminate() {
        controller.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }

    public func settingsWindowDidClose() {
        let pid = ProcessInfo.processInfo.processIdentifier
        WindowUtil.purgeAppCache(with: pid)
        SettingsMockPreview.releaseCaches()
    }

    public var settingsGroups: [SettingsGroup] {
        var groups = [
            SettingsGroup(
                id: "dock",
                title: "Dock",
                pages: [page(for: .general)] + SettingsTab.tabs(in: .features).map(page(for:))
            ),
        ]
        for section in [SettingsTab.Section.customization, .system] {
            groups.append(SettingsGroup(
                id: "dock.\(section)",
                title: "Dock · \(section.localizedTitle)",
                pages: SettingsTab.tabs(in: section).map(page(for:))
            ))
        }
        return groups
    }

    private func page(for tab: SettingsTab) -> SettingsPage {
        let updaterState = controller.updaterState
        return SettingsPage(
            id: tab == .general ? Self.generalPageID : "dock.\(tab.rawValue)",
            title: tab.localizedTitle,
            subtitle: tab.localizedSubtitle,
            systemImage: tab.systemImage
        ) {
            switch tab {
            case .general: MainSettingsView()
            case .dockPreviews: DockPreviewsSettingsView()
            case .windowSwitcher: WindowSwitcherBehaviorSettingsView()
            case .gestures: GesturesSettingsView()
            case .keybinds: KeybindsSettingsView()
            case .cmdTab: CmdTabSettingsView()
            case .appearance: AppearanceSettingsView()
            case .filters: FiltersSettingsView()
            case .widgets: WidgetSettingsView()
            case .advanced: AdvancedSettingsView()
            case .support: SupportSettingsView(updaterState: updaterState)
            }
        }
    }
}
