import AppKit
import ApplicationServices
import KeyboardShortcuts
import SwiftUI

struct MenuBarSettingsView: View {
  let status: MenuBarStatus
  let resetPositions: () -> Void
  let openSearch: () -> Void

  @AppStorage(MenuBarPrefs.enabledKey) private var enabled = false
  @AppStorage(MenuBarPrefs.alwaysHiddenKey) private var alwaysHidden = false
  @AppStorage(MenuBarPrefs.rehideDelayKey) private var rehideDelay = 10
  @AppStorage(MenuBarPrefs.rehideOnOutsideClickKey) private var rehideOnOutsideClick = true
  @AppStorage(MenuBarPrefs.showOnHoverKey) private var showOnHover = false
  @AppStorage(MenuBarPrefs.showOnClickKey) private var showOnClick = false
  @AppStorage(MenuBarPrefs.showOnScrollKey) private var showOnScroll = false
  @State private var isTrusted = AXIsProcessTrusted()

  var body: some View {
    Form {
      Section {
        Toggle("Hide menu bar icons", isOn: $enabled)
      } footer: {
        Text("Adds a Kitzi icon (‹) and a divider (|) to the right of your menu bar icons. Click the Kitzi icon to show or hide the icons left of the divider. To choose which icons stay visible, show them, then hold ⌘ and drag icons across the divider.")
          .foregroundStyle(.secondary)
      }

      if enabled {
        if status.hasOrderProblem {
          Section {
            LabeledContent("The divider is right of the Kitzi icon") {
              Button("Reset Positions") { resetPositions() }
            }
          } footer: {
            Text("Nothing is hidden until the | divider is left of the Kitzi icon. Hold ⌘ and drag it there, or reset the positions.")
              .foregroundStyle(.secondary)
          }
        }

        Section {
          Toggle("Always hidden section", isOn: $alwaysHidden)
        } footer: {
          Text("Adds a second divider (‖). Icons left of it stay hidden until you ⌥-click the Kitzi icon.")
            .foregroundStyle(.secondary)
        }

        Section {
          Picker("Hide icons again after", selection: $rehideDelay) {
            ForEach(RehidePolicy.delayChoices, id: \.self) { seconds in
              if seconds == 0 {
                Text("Never").tag(seconds)
              } else {
                Text("\(seconds) seconds").tag(seconds)
              }
            }
          }
          Toggle("Hide when clicking outside the menu bar", isOn: $rehideOnOutsideClick)
        } header: {
          Text("Hide Again")
        } footer: {
          Text("Icons stay visible while the pointer is on the menu bar or one of their menus is open.")
            .foregroundStyle(.secondary)
        }

        Section {
          Toggle("When hovering over an empty part of the menu bar", isOn: $showOnHover)
          Toggle("When clicking an empty part of the menu bar", isOn: $showOnClick)
          Toggle("When scrolling or swiping down on the menu bar", isOn: $showOnScroll)
        } header: {
          Text("Show Hidden Icons")
        } footer: {
          if (showOnHover || showOnClick) && !isTrusted {
            Text("Without Accessibility access Kitzi can't see where the app menus end, so only the right half of the menu bar counts as empty.")
              .foregroundStyle(.secondary)
          }
        }

        Section("Keyboard Shortcuts") {
          KeyboardShortcuts.Recorder("Show or hide hidden icons", name: .menuBarToggleHidden)
          if alwaysHidden {
            KeyboardShortcuts.Recorder("Show or hide always hidden icons", name: .menuBarToggleAlwaysHidden)
          }
        }
      }

      Section {
        KeyboardShortcuts.Recorder("Search menu bar items", name: .menuBarSearch)
        LabeledContent("Menu bar items") {
          Button("Search…") { openSearch() }
        }
      } header: {
        Text("Menu Bar Search")
      } footer: {
        Text("Type part of a name to find any menu bar item, even a hidden one, then press Return to open it.")
          .foregroundStyle(.secondary)
      }

      if !isTrusted {
        Section {
          LabeledContent("Accessibility") {
            Button("Open Privacy Settings…") { Self.openAccessibilitySettings() }
          }
        } footer: {
          Text("Kitzi needs Accessibility access to search menu bar items and to find the empty part of the menu bar.")
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .task {
      while !Task.isCancelled {
        isTrusted = AXIsProcessTrusted()
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  static func openAccessibilitySettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
      NSWorkspace.shared.open(url)
    }
  }
}
