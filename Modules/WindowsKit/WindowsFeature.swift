import AppKit
import ApplicationServices
import KitziCore
import SwiftUI

enum WindowsPrefs {
  static let finderCutPasteKey = "windows.finderCutPaste"

  static func register() {
    UserDefaults.standard.register(defaults: [finderCutPasteKey: true])
  }

  static var finderCutPaste: Bool { UserDefaults.standard.bool(forKey: finderCutPasteKey) }
}

/// Public entry point of the Windows habits module: keys that work the way they do on Windows,
/// each one turned on or off on its own. For now: cut and paste files in Finder.
public final class WindowsFeature: KitziFeature {
  static let pageID = "windows.general"

  private let cutPaste = FinderCutPaste()
  private var defaultsObserver: NSObjectProtocol?

  public init() {
    WindowsPrefs.register()
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
    cutPaste.stop()
  }

  public var settingsGroups: [SettingsGroup] {
    [
      SettingsGroup(
        id: "windows",
        title: String(localized: "Windows Habits"),
        pages: [
          SettingsPage(
            id: Self.pageID,
            title: String(localized: "Windows Habits"),
            subtitle: String(localized: "Keys that work like they do on Windows"),
            systemImage: "pc"
          ) {
            WindowsSettingsView()
          }
        ]
      )
    ]
  }

  private func applyPreferences() {
    if WindowsPrefs.finderCutPaste {
      cutPaste.start()
    } else {
      cutPaste.stop()
    }
  }
}

struct WindowsSettingsView: View {
  @AppStorage(WindowsPrefs.finderCutPasteKey) private var finderCutPaste = true
  @State private var isTrusted = AXIsProcessTrusted()

  var body: some View {
    Form {
      Section {
        Toggle("Cut and paste files with ⌘X and ⌘V", isOn: $finderCutPaste)
      } header: {
        Text(verbatim: "Finder")
      } footer: {
        Text("⌘X marks the selected files; ⌘V in another folder moves them there instead of copying. Esc cancels. While you rename a file, ⌘X cuts text as usual.")
          .foregroundStyle(.secondary)
      }
      if finderCutPaste, !isTrusted {
        Section {
          LabeledContent("Accessibility") {
            Button("Open Privacy Settings…") {
              if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
              }
            }
          }
        } footer: {
          Text("Kitzi needs Accessibility access to change ⌘X and ⌘V in Finder.")
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
}
