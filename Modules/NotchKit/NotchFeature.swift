import AppKit
import ApplicationServices
import KitziCore
import Combine
import SwiftUI

/// Public entry point of the notch module: a panel in the MacBook notch (a pill at the top
/// center of other screens) that opens on hover and shows what is playing, today's events
/// and a file shelf, and can stand in for the volume and brightness HUD.
/// Modelled on boring.notch (GPL-3.0); see the README for what was taken from it.
public final class NotchFeature: KitziFeature {
  static let pageID = "notch.general"

  private let controller = NotchController()
  private var defaultsObserver: NSObjectProtocol?
  private var applied: NotchSettings?

  public init() {
    NotchPrefs.register()
  }

  public func applicationDidFinishLaunching() {
    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.applyPreferences() }
    }
    applyPreferences()

    #if DEBUG
    // Test hook: `open Kitzi.app --args -KitziOpenNotch shelf`
    if let tab = UserDefaults.standard.string(forKey: "KitziOpenNotch") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [controller] in
        controller.openPanel(tab: tab == "shelf" ? .shelf : .home)
      }
    }
    #endif
  }

  public func applicationWillTerminate() {
    controller.shutdown()
  }

  public var settingsGroups: [SettingsGroup] {
    [
      SettingsGroup(
        id: "notch",
        title: String(localized: "Notch"),
        pages: [
          SettingsPage(
            id: Self.pageID,
            title: String(localized: "Notch"),
            subtitle: String(localized: "Now playing, a file shelf and HUDs in the notch"),
            systemImage: "rectangle.topthird.inset.filled"
          ) { [controller] in
            NotchSettingsView(controller: controller)
          }
        ]
      )
    ]
  }

  private func applyPreferences() {
    // Any default change posts this (the shelf saves its items too); only act on ours.
    let settings = NotchSettings.current()
    guard settings != applied else { return }
    applied = settings
    controller.apply(settings)
  }
}

struct NotchSettingsView: View {
  let controller: NotchController

  @AppStorage(NotchPrefs.enabledKey) private var enabled = true
  @AppStorage(NotchPrefs.screensKey) private var screens = NotchScreenChoice.notchScreens.rawValue
  @AppStorage(NotchPrefs.openOnHoverKey) private var openOnHover = true
  @AppStorage(NotchPrefs.nowPlayingKey) private var nowPlaying = true
  @AppStorage(NotchPrefs.nowPlayingClosedKey) private var nowPlayingClosed = true
  @AppStorage(NotchPrefs.shelfKey) private var shelf = true
  @AppStorage(NotchPrefs.calendarKey) private var calendar = true
  @AppStorage(NotchPrefs.hudKey) private var hud = false
  @AppStorage(NotchPrefs.batteryKey) private var battery = true
  @State private var isTrusted = AXIsProcessTrusted()

  private let accessTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

  var body: some View {
    Form {
      Section {
        Toggle("Show the notch panel", isOn: $enabled)
        Picker("Show on", selection: $screens) {
          Text("Screens with a notch").tag(NotchScreenChoice.notchScreens.rawValue)
          Text("Main screen").tag(NotchScreenChoice.mainScreen.rawValue)
          Text("All screens").tag(NotchScreenChoice.allScreens.rawValue)
        }
        .disabled(!enabled)
        Toggle("Open when the pointer is over the notch", isOn: $openOnHover)
          .disabled(!enabled)
        LabeledContent("Panel") {
          Button("Open the Panel") { controller.openPanel() }
            .disabled(!enabled || controller.panelCount == 0)
        }
      } footer: {
        Text(footerText)
          .foregroundStyle(.secondary)
      }

      Section {
        Toggle("Now playing", isOn: $nowPlaying)
        Toggle("Show artwork beside the closed notch while playing", isOn: $nowPlayingClosed)
          .disabled(!nowPlaying)
        Toggle("Today's events", isOn: $calendar)
      } header: {
        Text("Home")
      } footer: {
        Text("Works with any app that shows up in Control Center's Now Playing: Music, Spotify, browsers, QuickTime and more. Calendar access is asked for the first time you click Show Calendar Events in the panel.")
          .foregroundStyle(.secondary)
      }
      .disabled(!enabled)

      Section {
        Toggle("File shelf", isOn: $shelf)
        LabeledContent("Files on the shelf") {
          HStack {
            Text(verbatim: "\(controller.services.shelf.items.count)")
              .monospacedDigit()
            Button("Clear Shelf") { controller.services.shelf.clear() }
              .disabled(controller.services.shelf.items.isEmpty)
          }
        }
      } header: {
        Text("Shelf")
      } footer: {
        Text("Drag files onto the notch to keep them at hand, then drag them out into any app or folder. The shelf only remembers where the files are; text you drop is saved as a file.")
          .foregroundStyle(.secondary)
      }
      .disabled(!enabled)

      Section {
        Toggle("Show volume and brightness in the notch", isOn: $hud)
        if hud && !isTrusted {
          LabeledContent("Accessibility access is needed") {
            Button("Open Privacy Settings…") { openAccessibilitySettings() }
          }
        }
        Toggle("Show charging and low battery notices", isOn: $battery)
      } header: {
        Text("HUD")
      } footer: {
        Text("Kitzi takes over the volume, mute and brightness keys and shows the level in the notch instead of the macOS overlay. Keys it can't apply, such as an output without volume control or an external display, keep working as before. Hold ⌥ to use the macOS behavior, ⌥⇧ for finer steps.")
          .foregroundStyle(.secondary)
      }
      .disabled(!enabled)
    }
    .formStyle(.grouped)
    .onReceive(accessTimer) { _ in
      let trusted = AXIsProcessTrusted()
      if trusted != isTrusted { isTrusted = trusted }
    }
  }

  private var footerText: LocalizedStringKey {
    if NSScreen.screens.contains(where: { NotchScreen(screen: $0).hasNotch }) {
      return "The panel opens from the notch when you point at it or drag files to it. Closed, it is as black as the notch, so it stays out of the way."
    }
    return "This Mac has no screen with a notch. Choose Main screen or All screens to show the panel as a pill at the top center of the menu bar."
  }

  private func openAccessibilitySettings() {
    // The value of kAXTrustedCheckOptionPrompt; the global itself is not concurrency-safe.
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
      NSWorkspace.shared.open(url)
    }
  }
}
