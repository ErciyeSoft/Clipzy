import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
  static let captureArea = Self("captureArea", initial: Shortcut(.four, modifiers: [.option, .shift]))
  static let captureWindow = Self("captureWindow", initial: Shortcut(.five, modifiers: [.option, .shift]))
  static let captureScreen = Self("captureScreen", initial: Shortcut(.three, modifiers: [.option, .shift]))
  static let captureScrolling = Self("captureScrolling", initial: Shortcut(.six, modifiers: [.option, .shift]))
  static let recordScreen = Self("recordScreen", initial: Shortcut(.seven, modifiers: [.option, .shift]))
  static let pinClipboard = Self("pinClipboard", initial: Shortcut(.p, modifiers: [.option, .shift]))
  static let captureHistory = Self("captureHistory", initial: Shortcut(.h, modifiers: [.option, .shift]))
}

enum CaptureMode: String, CaseIterable {
  case area, window, screen
}

/// What happens right after a capture.
enum AfterCapture: String, CaseIterable {
  case openEditor, copy, save
}

enum RecordingFormat: String, CaseIterable {
  case mp4, gif
}

enum ImageFormat: String, CaseIterable {
  case png, jpeg, pdf

  var fileExtension: String {
    switch self {
    case .png: "png"
    case .jpeg: "jpg"
    case .pdf: "pdf"
    }
  }
}

/// Preferences of the screenshot tool (plain UserDefaults, prefixed with `capture.`).
enum CapturePrefs {
  static let menuBarIconKey = "capture.menuBarIcon"
  static let afterCaptureKey = "capture.afterCapture"
  static let saveFolderKey = "capture.saveFolder"
  static let formatKey = "capture.format"
  static let soundKey = "capture.playSound"
  static let windowShadowKey = "capture.windowShadow"
  static let customSelectionKey = "capture.customSelection"
  static let recordingFormatKey = "capture.recordingFormat"
  static let recordCursorKey = "capture.recordCursor"

  static func register() {
    UserDefaults.standard.register(defaults: [
      menuBarIconKey: true,
      afterCaptureKey: AfterCapture.openEditor.rawValue,
      saveFolderKey: defaultSaveFolder.path,
      formatKey: ImageFormat.png.rawValue,
      soundKey: true,
      windowShadowKey: true,
      customSelectionKey: true,
      recordingFormatKey: RecordingFormat.mp4.rawValue,
      recordCursorKey: true,
    ])
  }

  static var defaultSaveFolder: URL {
    FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
  }

  private static var defaults: UserDefaults { .standard }

  static var showMenuBarIcon: Bool { defaults.bool(forKey: menuBarIconKey) }
  static var afterCapture: AfterCapture {
    AfterCapture(rawValue: defaults.string(forKey: afterCaptureKey) ?? "") ?? .openEditor
  }
  static var saveFolder: URL {
    URL(fileURLWithPath: defaults.string(forKey: saveFolderKey) ?? defaultSaveFolder.path, isDirectory: true)
  }
  static var format: ImageFormat {
    ImageFormat(rawValue: defaults.string(forKey: formatKey) ?? "") ?? .png
  }
  static var playSound: Bool { defaults.bool(forKey: soundKey) }
  static var windowShadow: Bool { defaults.bool(forKey: windowShadowKey) }
  static var customSelection: Bool { defaults.bool(forKey: customSelectionKey) }
  static var recordCursor: Bool { defaults.bool(forKey: recordCursorKey) }
  static var recordingFormat: RecordingFormat {
    RecordingFormat(rawValue: defaults.string(forKey: recordingFormatKey) ?? "") ?? .mp4
  }
}

/// Takes screenshots with the system `screencapture` tool, which provides the native
/// selection UI (crosshair, space to switch to window mode, Esc to cancel).
enum CaptureService {
  /// Returns the captured image, or nil if the user cancelled.
  static func capture(_ mode: CaptureMode) async -> CGImage? {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("Kitzi-\(UUID().uuidString).png")
    var arguments: [String] = []
    if !CapturePrefs.playSound {
      arguments.append("-x")
    }
    switch mode {
    case .area:
      arguments.append("-i")
    case .window:
      arguments += ["-i", "-w"]
      if !CapturePrefs.windowShadow {
        arguments.append("-o")
      }
    case .screen:
      arguments += ["-D", String(displayNumberUnderPointer())]
    }
    arguments.append(url.path)

    await run("/usr/sbin/screencapture", arguments)
    defer { try? FileManager.default.removeItem(at: url) }
    // Read the file into memory and decode right away: an image backed by the file
    // would decode lazily and come out empty once the temporary file is deleted.
    guard let data = try? Data(contentsOf: url),
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
          ) else {
      return nil
    }
    return image
  }

  /// `screencapture -D` counts displays from 1 in the order Core Graphics lists them.
  private static func displayNumberUnderPointer() -> Int {
    let pointer = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }),
          let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
      return 1
    }
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &displays, &count)
    return (displays.firstIndex(of: number.uint32Value) ?? 0) + 1
  }

  private static func run(_ tool: String, _ arguments: [String]) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: tool)
      process.arguments = arguments
      process.terminationHandler = { _ in continuation.resume() }
      do {
        try process.run()
      } catch {
        continuation.resume()
      }
    }
  }
}

/// Saving and copying finished images.
enum ImageOutput {
  static func pngData(_ image: CGImage) -> Data? {
    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
  }

  static func data(_ image: CGImage, format: ImageFormat) -> Data? {
    let rep = NSBitmapImageRep(cgImage: image)
    switch format {
    case .png: return rep.representation(using: .png, properties: [:])
    case .jpeg: return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    case .pdf: return pdfData(image)
    }
  }

  /// One-page PDF the size of the image in points.
  static func pdfData(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    guard let consumer = CGDataConsumer(data: data),
          let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
    context.beginPDFPage(nil)
    context.draw(image, in: box)
    context.endPDFPage()
    context.closePDF()
    return data as Data
  }

  static func copy(_ image: CGImage) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    pasteboard.writeObjects([nsImage])
    if let png = pngData(image) {
      pasteboard.setData(png, forType: .png)
    }
  }

  /// Saves into the configured folder with a timestamped name; returns the file URL.
  @discardableResult
  static func save(_ image: CGImage) -> URL? {
    let format = CapturePrefs.format
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    let name = "Kitzi \(formatter.string(from: Date())).\(format.fileExtension)"
    let folder = CapturePrefs.saveFolder
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    guard let data = data(image, format: format), (try? data.write(to: url)) != nil else { return nil }
    return url
  }

  /// Writes a temporary PNG, e.g. for dragging the image into another app.
  static func temporaryFile(_ image: CGImage) -> URL? {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Kitzi Screenshot.png")
    guard let data = pngData(image), (try? data.write(to: url)) != nil else { return nil }
    return url
  }
}
