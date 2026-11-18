import AppKit
import KitziCore
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
  /// No default: the user picks one in settings.
  static let openDiskAnalyzer = Self("openDiskAnalyzer")
}

/// Public entry point of the disk analyzer: a window that scans a disk or folder, shows
/// what takes up space as rings and moves what you collect to the Trash.
public final class DiskFeature: KitziFeature {
  static let pageID = "disk.general"

  public init() {}

  public func applicationDidFinishLaunching() {
    KeyboardShortcuts.onKeyUp(for: .openDiskAnalyzer) {
      DiskAnalyzerWindow.show()
    }
  }

  public var settingsGroups: [SettingsGroup] {
    [
      SettingsGroup(
        id: "disk",
        title: String(localized: "Disk"),
        pages: [
          SettingsPage(
            id: Self.pageID,
            title: String(localized: "Disk Analyzer"),
            subtitle: String(localized: "See what takes up space on your disks"),
            systemImage: "chart.pie"
          ) {
            DiskSettingsView()
          }
        ]
      )
    ]
  }
}

struct DiskSettingsView: View {
  var body: some View {
    Form {
      Section {
        LabeledContent("Disk Analyzer") {
          Button("Open Disk Analyzer…") { DiskAnalyzerWindow.show() }
        }
        KeyboardShortcuts.Recorder("Open Disk Analyzer", name: .openDiskAnalyzer)
      } footer: {
        Text("Scan a disk or a folder and see what takes up space as rings. Drag what you don't need to the collector at the bottom and move it to the Trash; nothing is removed until you confirm.")
          .foregroundStyle(.secondary)
      }
      Section {
        LabeledContent("Full Disk Access") {
          Button("Open Privacy Settings…") { DiskAnalyzerModel.openFullDiskAccessSettings() }
        }
      } footer: {
        Text("Without Full Disk Access, macOS keeps some folders (Mail, Safari, other apps' data) closed. Their size shows up as hidden space. After you allow Kitzi, quit and reopen it, then scan again.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}
