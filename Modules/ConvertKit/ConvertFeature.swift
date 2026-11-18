import AppKit
import KitziCore
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
  static let convertFinderSelection = Self("convertFinderSelection", initial: Shortcut(.d, modifiers: [.option, .shift]))
}

/// Public entry point of the file converter: a window, the Finder "Convert with Kitzi"
/// service and a shortcut that converts what is selected in Finder.
public final class ConvertFeature: KitziFeature {
  static let pageID = "convert.general"
  private let services = ConvertServiceProvider()

  public init() {}

  public func applicationDidFinishLaunching() {
    NSApp.servicesProvider = services
    NSUpdateDynamicServices()
    KeyboardShortcuts.onKeyUp(for: .convertFinderSelection) {
      ConverterWindow.show(with: FinderSelection.current())
    }
  }

  public var settingsGroups: [SettingsGroup] {
    [
      SettingsGroup(
        id: "convert",
        title: String(localized: "Files"),
        pages: [
          SettingsPage(
            id: Self.pageID,
            title: String(localized: "Converter"),
            subtitle: String(localized: "Convert images, PDFs, videos, audio and documents"),
            systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard"
          ) {
            ConvertSettingsView()
          }
        ]
      )
    ]
  }
}

/// Handles "Convert with Kitzi" from Finder's Services menu (declared in Info.plist).
final class ConvertServiceProvider: NSObject {
  @objc func convertFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>?) {
    let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    ConverterWindow.show(with: urls)
  }
}

/// The files selected in the frontmost Finder window (asks once for permission to control Finder).
enum FinderSelection {
  static func current() -> [URL] {
    let source = """
    tell application "Finder"
      set output to ""
      repeat with anItem in (get selection)
        set output to output & POSIX path of (anItem as alias) & linefeed
      end repeat
      return output
    end tell
    """
    var error: NSDictionary?
    let paths = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue ?? ""
    return paths.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
  }
}

struct ConvertSettingsView: View {
  var body: some View {
    Form {
      Section {
        LabeledContent("Converter") {
          Button("Open Converter…") { ConverterWindow.show() }
        }
        KeyboardShortcuts.Recorder("Convert files selected in Finder", name: .convertFinderSelection)
      } footer: {
        Text("In Finder you can also right-click files and choose Services › Convert with Kitzi. Everything is converted on this Mac with built-in macOS tools; nothing is downloaded.")
          .foregroundStyle(.secondary)
      }
      Section {
        LabeledContent("Images") { Text("JPEG, PNG, HEIC, TIFF, GIF, BMP, PDF").foregroundStyle(.secondary) }
        LabeledContent("PDF") { Text(String(localized: "Merge, split, pages to images")).foregroundStyle(.secondary) }
        LabeledContent("Video") { Text("MP4, MOV (HEVC), GIF, M4A").foregroundStyle(.secondary) }
        LabeledContent("Audio") { Text("M4A, WAV, AIFF").foregroundStyle(.secondary) }
        LabeledContent("Documents") { Text("PDF, DOCX, RTF, HTML, TXT, ODT").foregroundStyle(.secondary) }
        LabeledContent("Archives") { Text("ZIP").foregroundStyle(.secondary) }
      } header: {
        Text("What it can do")
      }
    }
    .formStyle(.grouped)
  }
}
