import AppKit
import KitziCore
import KeyboardShortcuts
internal import RDPBridge
import SwiftUI

extension KeyboardShortcuts.Name {
  /// No default: the user picks one in settings.
  static let openRemoteDesktop = Self("openRemoteDesktop")
}

/// Public entry point of Remote Desktop: saved PCs in groups and RDP sessions in Kitzi
/// windows, built on FreeRDP.
public final class RemoteFeature: KitziFeature {
  static let pageID = "remote.general"

  public init() {}

  public func applicationDidFinishLaunching() {
    KeyboardShortcuts.onKeyUp(for: .openRemoteDesktop) {
      RemoteHomeWindow.show()
    }
    #if DEBUG
    RemoteSelfTest.runIfRequested()
    #endif
  }

  public func applicationWillTerminate() {
    RemoteSessions.shared.closeAll()
  }

  public var settingsGroups: [SettingsGroup] {
    [
      SettingsGroup(
        id: "remote",
        title: String(localized: "Remote Desktop"),
        pages: [
          SettingsPage(
            id: Self.pageID,
            title: String(localized: "Remote Desktop"),
            subtitle: String(localized: "Connect to Windows PCs over RDP"),
            systemImage: "display.2"
          ) {
            RemoteSettingsView()
          }
        ]
      )
    ]
  }
}

struct RemoteSettingsView: View {
  @AppStorage(RemotePreferences.macShortcutsKey) private var macShortcuts = true
  @AppStorage(RemotePreferences.keyboardModeKey) private var keyboardMode = RemoteKeyboardMode.keys.rawValue
  @AppStorage(RemotePreferences.keyboardLayoutKey) private var keyboardLayout = 0

  var body: some View {
    Form {
      Section {
        LabeledContent("Remote Desktop") {
          Button("Open Remote Desktop…") { RemoteHomeWindow.show() }
        }
        KeyboardShortcuts.Recorder("Open Remote Desktop", name: .openRemoteDesktop)
      } footer: {
        Text("Save Windows PCs, sort them into groups and connect in a Kitzi window. PCs saved in Windows App can be imported from the + menu.")
          .foregroundStyle(.secondary)
      }

      Section {
        Toggle("Mac shortcuts (⌘C, ⌘V, ⌘Z… work as Ctrl on the PC)", isOn: $macShortcuts)
        Picker("Keyboard input", selection: $keyboardMode) {
          ForEach(RemoteKeyboardMode.allCases) { mode in
            Text(mode.title).tag(mode.rawValue)
          }
        }
        Picker("PC keyboard layout", selection: $keyboardLayout) {
          Text("Same as this Mac").tag(0)
          Divider()
          ForEach(RemoteKeyboardLayouts.all) { layout in
            Text(layout.name).tag(Int(layout.id))
          }
        }
      } header: {
        Text("Keyboard")
      } footer: {
        Text("With Mac shortcuts on, ⌘ pressed alone opens the Start menu and ⌘ with other keys (R, E, L…) works as the Windows key. Right Option is AltGr. Characters mode helps when the Mac and the PC use different layouts. Changes apply to new connections.")
          .foregroundStyle(.secondary)
      }

      Section {
        LabeledContent("Engine") {
          Text(verbatim: "FreeRDP \(String(cString: RDPBVersion()))")
            .foregroundStyle(.secondary)
        }
        LabeledContent("Trusted certificates") {
          Button("Show in Finder") {
            try? FileManager.default.createDirectory(at: RemotePaths.freeRDP, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([RemotePaths.freeRDP])
          }
        }
      } footer: {
        Text("Remote Desktop uses FreeRDP (Apache License 2.0) and OpenSSL. Passwords are kept in your login keychain; certificates you trust are kept in the folder above.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}
