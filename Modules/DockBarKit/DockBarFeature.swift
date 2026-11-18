import AppKit
import KitziCore
import SwiftUI

/// Public entry point of the Kitzi Dock: a replacement Dock with magnification,
/// window previews and pinned items, optionally hiding the macOS Dock.
public final class DockBarFeature: KitziFeature {
  static let pageID = "dockBar.general"

  private let controller = DockBarController()
  private var defaultsObserver: NSObjectProtocol?

  public init() {
    DockBarPrefs.register()
  }

  public func applicationDidFinishLaunching() {
    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.applyPreferences() }
    }
    applyPreferences()
  }

  public func applicationWillTerminate() {
    if NativeDock.isHiddenByKitzi, DockBarPrefs.restoreOnQuit {
      NativeDock.restore()
    }
  }

  public var settingsGroups: [SettingsGroup] {
    [
      SettingsGroup(
        id: "dockBar",
        title: "Kitzi Dock",
        pages: [
          SettingsPage(
            id: Self.pageID,
            title: "Kitzi Dock",
            subtitle: String(localized: "Your own Dock with magnification and window previews"),
            systemImage: "dock.arrow.up.rectangle"
          ) { [controller] in
            DockBarSettingsView(onResetPinned: { controller.resetPinnedFromNativeDock() })
          }
        ]
      )
    ]
  }

  private func applyPreferences() {
    if DockBarPrefs.enabled {
      controller.show()
      controller.applyPreferences()
    } else {
      controller.hide()
    }

    // Hide the macOS Dock only while the Kitzi Dock is on and the user asked for it;
    // this also puts the macOS Dock back after a crash once the option is off.
    let wantsNativeHidden = DockBarPrefs.enabled && DockBarPrefs.hideNativeDock
    if wantsNativeHidden, !NativeDock.isHiddenByKitzi {
      NativeDock.hide()
    } else if !wantsNativeHidden, NativeDock.isHiddenByKitzi {
      NativeDock.restore()
    }
  }
}

struct DockBarSettingsView: View {
  let onResetPinned: () -> Void

  @AppStorage(DockBarPrefs.enabledKey) private var enabled = false
  @AppStorage(DockBarPrefs.hideNativeDockKey) private var hideNativeDock = false
  @AppStorage(DockBarPrefs.restoreOnQuitKey) private var restoreOnQuit = true
  @AppStorage(DockBarPrefs.edgeKey) private var edge = ScreenEdge.bottom.rawValue
  @AppStorage(DockBarPrefs.iconSizeKey) private var iconSize = 52.0
  @AppStorage(DockBarPrefs.magnifyKey) private var magnify = true
  @AppStorage(DockBarPrefs.maxScaleKey) private var maxScale = 1.8
  @AppStorage(DockBarPrefs.showRunningKey) private var showRunning = true
  @AppStorage(DockBarPrefs.showTrashKey) private var showTrash = true
  @AppStorage(DockBarPrefs.reserveSpaceKey) private var reserveSpace = true
  @AppStorage(DockBarPrefs.displayModeKey) private var displayMode = DockBarPrefs.DisplayMode.main.rawValue
  @AppStorage(DockBarPrefs.selectedDisplaysKey) private var selectedDisplays = ""
  @State private var screens = NSScreen.screens.map { (id: $0.dockBarDisplayID, name: $0.localizedName) }

  var body: some View {
    Form {
      Section {
        Toggle("Use Kitzi Dock", isOn: $enabled)
        Toggle("Hide the macOS Dock", isOn: $hideNativeDock)
          .disabled(!enabled)
        Toggle("Bring back the macOS Dock when Kitzi quits", isOn: $restoreOnQuit)
          .disabled(!enabled || !hideNativeDock)
        Toggle("Keep windows clear of Kitzi Dock", isOn: $reserveSpace)
          .disabled(!enabled)
          .help(String(localized: "Maximized windows end at the dock and new windows open above it, like with the macOS Dock."))
      } footer: {
        Text("Hiding turns on auto-hide for the macOS Dock with a very long delay. Your own Dock settings are put back when you turn this off.")
          .foregroundStyle(.secondary)
      }

      Section {
        Picker("Show Kitzi Dock on", selection: $displayMode) {
          Text("Main display").tag(DockBarPrefs.DisplayMode.main.rawValue)
          Text("All displays").tag(DockBarPrefs.DisplayMode.all.rawValue)
          Text("Selected displays").tag(DockBarPrefs.DisplayMode.selected.rawValue)
        }
        if displayMode == DockBarPrefs.DisplayMode.selected.rawValue {
          ForEach(screens, id: \.id) { screen in
            Toggle(screen.name, isOn: displayBinding(screen.id))
          }
        }
      } header: {
        Text("Displays")
      } footer: {
        Text("Each display gets its own dock; pinning or removing an item updates all of them.")
          .foregroundStyle(.secondary)
      }
      .disabled(!enabled)
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
        screens = NSScreen.screens.map { (id: $0.dockBarDisplayID, name: $0.localizedName) }
      }

      Section {
        Picker("Position on screen", selection: $edge) {
          Text("Bottom").tag(ScreenEdge.bottom.rawValue)
          Text("Left").tag(ScreenEdge.left.rawValue)
          Text("Right").tag(ScreenEdge.right.rawValue)
        }
        LabeledContent("Size") {
          Slider(value: $iconSize, in: 32...96, step: 2)
            .frame(width: 220)
        }
        Toggle("Magnification", isOn: $magnify)
        LabeledContent("Magnified size") {
          Slider(value: $maxScale, in: 1.2...2.6, step: 0.1)
            .frame(width: 220)
        }
        .disabled(!magnify)
      } header: {
        Text("Appearance")
      }
      .disabled(!enabled)

      Section {
        Toggle("Show apps that are open but not kept in the Dock", isOn: $showRunning)
        Toggle("Show Trash", isOn: $showTrash)
        LabeledContent("Items") {
          Button("Copy from the macOS Dock", action: onResetPinned)
        }
      } header: {
        Text("Items")
      } footer: {
        Text("Drag files or apps onto the Dock to add them, drag icons onto each other to reorder, and right-click an icon to remove it.")
          .foregroundStyle(.secondary)
      }
      .disabled(!enabled)
    }
    .formStyle(.grouped)
  }

  private func displayBinding(_ id: String) -> Binding<Bool> {
    Binding(
      get: { selectedDisplays.split(separator: "\n").contains(Substring(id)) },
      set: { isOn in
        var ids = Set(selectedDisplays.split(separator: "\n").map(String.init))
        if isOn { ids.insert(id) } else { ids.remove(id) }
        selectedDisplays = ids.sorted().joined(separator: "\n")
      }
    )
  }
}
