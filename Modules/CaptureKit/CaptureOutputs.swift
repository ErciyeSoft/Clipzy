import AppKit
import KitziCore
import ImageIO
import SwiftUI
import Translation
import Vision

// MARK: - Finishing a capture

/// The things a finished screenshot can turn into, shared by the inline toolbar,
/// the editor window and pins.
enum CaptureActions {
  static func copy(_ image: CGImage) {
    ImageOutput.copy(image)
    CaptureHistory.add(image)
  }

  static func save(_ image: CGImage) {
    ImageOutput.save(image)
    CaptureHistory.add(image)
  }

  static func pin(_ image: CGImage, frame: CGRect? = nil) {
    PinnedImageWindow.show(image, frame: frame)
    CaptureHistory.add(image)
  }

  static func share(_ image: CGImage, from view: NSView) {
    guard let url = ImageOutput.temporaryFile(image) else { return }
    NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
  }

  static func recognizeText(_ image: CGImage) {
    Task {
      let text = await TextRecognizer.recognize(in: image)
      TextResultWindow.show(text)
    }
  }
}

/// On-device text recognition with Vision, preferring the user's languages.
enum TextRecognizer {
  static func recognize(in image: CGImage) async -> String {
    await Task.detached(priority: .userInitiated) {
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      let supported = Set((try? request.supportedRecognitionLanguages()) ?? [])
      let preferred = Locale.preferredLanguages.compactMap { code -> String? in
        let language = Locale(identifier: code).language.languageCode?.identifier ?? code
        return supported.first { $0.hasPrefix(language + "-") || $0 == language }
      }
      var languages: [String] = []
      for language in preferred + ["en-US"] where !languages.contains(language) {
        languages.append(language)
      }
      request.recognitionLanguages = languages
      let handler = VNImageRequestHandler(cgImage: image)
      try? handler.perform([request])
      return (request.results ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
    }.value
  }
}

// MARK: - History

/// The last screenshots, kept as PNG files in Application Support.
enum CaptureHistory {
  static let limit = 60
  static let didChange = Notification.Name("KitziCaptureHistoryDidChange")

  static var folder: URL {
    URL.applicationSupportDirectory.appending(path: "Kitzi/Captures", directoryHint: .isDirectory)
  }

  static func add(_ image: CGImage) {
    guard let data = ImageOutput.pngData(image) else { return }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
    try? data.write(to: folder.appending(path: "\(formatter.string(from: Date())).png"))
    for old in items().dropFirst(limit) {
      try? FileManager.default.removeItem(at: old)
    }
    NotificationCenter.default.post(name: didChange, object: nil)
  }

  /// Newest first.
  static func items() -> [URL] {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
  }

  static func image(at url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
  }

  static func thumbnail(at url: URL, maxPixels: Int = 480) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ] as CFDictionary)
  }

  static func delete(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
    NotificationCenter.default.post(name: didChange, object: nil)
  }

  static func clear() {
    items().forEach { try? FileManager.default.removeItem(at: $0) }
    NotificationCenter.default.post(name: didChange, object: nil)
  }
}

/// Grid of recent screenshots: pin, copy, edit, show in Finder, delete.
final class HistoryWindow: NSObject, NSWindowDelegate {
  private static var shared: HistoryWindow?
  private var window: NSWindow?

  static func show() {
    if let shared, let window = shared.window {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let controller = HistoryWindow()
    shared = controller
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.title = String(localized: "Screenshot History")
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(rootView: HistoryView())
    window.delegate = controller
    window.center()
    controller.window = window
    KitziWindows.didOpen()
    window.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    window?.contentViewController = nil
    window = nil
    KitziWindows.didClose()
    Self.shared = nil
  }
}

private struct HistoryView: View {
  @State private var items = CaptureHistory.items()

  var body: some View {
    Group {
      if items.isEmpty {
        ContentUnavailableView("No screenshots yet", systemImage: "photo.on.rectangle",
                               description: Text("Screenshots you copy, save or pin show up here."))
      } else {
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
            ForEach(items, id: \.self) { url in
              HistoryTile(url: url)
            }
          }
          .padding(16)
        }
      }
    }
    .frame(minWidth: 480, minHeight: 320)
    .toolbar {
      ToolbarItem {
        Button(role: .destructive) { CaptureHistory.clear() } label: { Label("Clear History", systemImage: "trash") }
          .disabled(items.isEmpty)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: CaptureHistory.didChange)) { _ in
      items = CaptureHistory.items()
    }
  }
}

private struct HistoryTile: View {
  let url: URL
  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ZStack {
        RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .underPageBackgroundColor))
        if let thumbnail = CaptureHistory.thumbnail(at: url) {
          Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(contentMode: .fit).padding(6)
        }
        if hovering {
          HStack(spacing: 6) {
            tileButton("pin", String(localized: "Pin to Screen")) { image.map { PinnedImageWindow.show($0) } }
            tileButton("doc.on.doc", String(localized: "Copy")) { image.map(ImageOutput.copy) }
            tileButton("pencil.tip.crop.circle", String(localized: "Edit")) { image.map(EditorWindowController.present) }
            tileButton("folder", String(localized: "Show in Finder")) {
              NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            tileButton("trash", String(localized: "Delete")) { CaptureHistory.delete(url) }
          }
          .padding(6)
          .background(.regularMaterial, in: Capsule())
        }
      }
      .frame(height: 140)
      Text(url.deletingPathExtension().lastPathComponent)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .onHover { hovering = $0 }
    .onTapGesture(count: 2) { image.map(EditorWindowController.present) }
    .contextMenu {
      Button("Pin to Screen") { image.map { PinnedImageWindow.show($0) } }
      Button("Copy") { image.map(ImageOutput.copy) }
      Button("Edit") { image.map(EditorWindowController.present) }
      Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      Divider()
      Button("Delete", role: .destructive) { CaptureHistory.delete(url) }
    }
  }

  private var image: CGImage? { CaptureHistory.image(at: url) }

  private func tileButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 22) }
      .buttonStyle(.plain)
      .help(label)
      .accessibilityLabel(label)
  }
}

// MARK: - Recognized text

/// Shows the recognized text, editable, with Copy and Translate.
final class TextResultWindow: NSObject, NSWindowDelegate {
  private static var open: Set<TextResultWindow> = []
  private var window: NSWindow?

  static func show(_ text: String) {
    let controller = TextResultWindow()
    open.insert(controller)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = String(localized: "Recognized Text")
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(rootView: TextResultView(text: text) { [weak window] in
      window?.close()
    })
    window.delegate = controller
    window.center()
    controller.window = window
    KitziWindows.didOpen()
    window.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    window?.contentViewController = nil
    window = nil
    KitziWindows.didClose()
    Self.open.remove(self)
  }
}

private struct TextResultView: View {
  @State var text: String
  let close: () -> Void
  @State private var translating = false
  @State private var copied = false

  var body: some View {
    VStack(spacing: 12) {
      if text.isEmpty {
        ContentUnavailableView("No text found", systemImage: "text.viewfinder")
      } else {
        TextEditor(text: $text)
          .font(.body)
          .scrollContentBackground(.hidden)
          .padding(8)
          .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
      }
      HStack {
        Button {
          translating = true
        } label: {
          Label("Translate", systemImage: "translate")
        }
        .disabled(text.isEmpty)
        .translationPresentation(isPresented: $translating, text: text)
        Spacer()
        Button(copied ? String(localized: "Copied") : String(localized: "Copy")) {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
          copied = true
        }
        .disabled(text.isEmpty)
        .keyboardShortcut("c", modifiers: [.command, .shift])
        Button("Done", action: close)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(16)
    .frame(minWidth: 380, minHeight: 260)
  }
}

// MARK: - Pins

/// A screenshot floating above other windows. Drag to move, scroll to zoom, ⌥-scroll for
/// opacity, double-click or Esc to close; right-click for more.
final class PinnedImageWindow: NSPanel {
  private static var pinned: [PinnedImageWindow] = []
  private static var hidden = false
  private let image: CGImage

  static var count: Int { pinned.count }

  /// `frame` is where the pin appears (global Cocoa points); defaults to the screen's center.
  static func show(_ image: CGImage, frame: CGRect? = nil) {
    if hidden { setAllHidden(false) }
    let window = PinnedImageWindow(image: image, frame: frame)
    pinned.append(window)
    window.orderFrontRegardless()
  }

  static func pinClipboardImage() {
    guard let image = NSImage(pasteboard: .general),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      NSSound.beep()
      return
    }
    show(cgImage)
  }

  static func closeAll() {
    pinned.forEach { $0.orderOut(nil) }
    pinned.removeAll()
  }

  static func toggleAllHidden() {
    setAllHidden(!hidden)
  }

  private static func setAllHidden(_ value: Bool) {
    hidden = value
    pinned.forEach { value ? $0.orderOut(nil) : $0.orderFrontRegardless() }
  }

  private init(image: CGImage, frame: CGRect?) {
    self.image = image
    let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    let scale = screen?.backingScaleFactor ?? 2
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let rect: NSRect
    if let frame {
      rect = frame
    } else {
      var size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
      let fit = min(1, visible.width * 0.6 / size.width, visible.height * 0.6 / size.height)
      size = NSSize(width: size.width * fit, height: size.height * fit)
      let offset = CGFloat(Self.pinned.count % 8) * 24
      rect = NSRect(x: visible.midX - size.width / 2 + offset, y: visible.midY - size.height / 2 - offset,
                    width: size.width, height: size.height)
    }
    super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel, .resizable],
               backing: .buffered, defer: false)
    level = .floating
    isMovableByWindowBackground = true
    hasShadow = true
    backgroundColor = .clear
    isOpaque = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isReleasedWhenClosed = false
    contentAspectRatio = rect.size

    let imageView = NSImageView(image: NSImage(cgImage: image, size: rect.size))
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.wantsLayer = true
    imageView.layer?.borderWidth = 1
    imageView.layer?.borderColor = NSColor(calibratedRed: 0.25, green: 0.55, blue: 1, alpha: 0.9).cgColor
    imageView.menu = makeMenu()
    contentView = imageView
  }

  override var canBecomeKey: Bool { true }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      dismiss()
    } else {
      super.mouseDown(with: event)
    }
  }

  override func keyDown(with event: NSEvent) {
    let command = event.modifierFlags.contains(.command)
    switch (event.keyCode, command) {
    case (53, _): dismiss()
    case (8, true): copyImage()
    case (1, true): saveImage()
    default: super.keyDown(with: event)
    }
  }

  override func scrollWheel(with event: NSEvent) {
    if event.modifierFlags.contains(.option) {
      alphaValue = max(0.2, min(1, alphaValue + event.scrollingDeltaY * 0.01))
      return
    }
    let factor = 1 + event.scrollingDeltaY * 0.01
    var frame = self.frame
    let newSize = NSSize(width: max(60, frame.width * factor), height: max(60, frame.height * factor))
    frame.origin.x -= (newSize.width - frame.width) / 2
    frame.origin.y -= (newSize.height - frame.height) / 2
    frame.size = newSize
    setFrame(frame, display: true)
  }

  private func makeMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(item(String(localized: "Copy"), #selector(copyImage)))
    menu.addItem(item(String(localized: "Save"), #selector(saveImage)))
    menu.addItem(item(String(localized: "Edit"), #selector(editImage)))
    menu.addItem(item(String(localized: "Recognize Text"), #selector(recognizeText)))
    let opacity = NSMenuItem(title: String(localized: "Opacity"), action: nil, keyEquivalent: "")
    let opacityMenu = NSMenu()
    for percent in [100, 80, 60, 40] {
      let entry = item("\(percent)%", #selector(setOpacity(_:)))
      entry.tag = percent
      opacityMenu.addItem(entry)
    }
    opacity.submenu = opacityMenu
    menu.addItem(opacity)
    menu.addItem(.separator())
    menu.addItem(item(String(localized: "Close"), #selector(closeImage)))
    menu.addItem(item(String(localized: "Close All Pins"), #selector(closeAllPins)))
    return menu
  }

  private func item(_ title: String, _ action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  @objc private func copyImage() { ImageOutput.copy(image) }
  @objc private func saveImage() { ImageOutput.save(image).map { NSWorkspace.shared.activateFileViewerSelecting([$0]) } }
  @objc private func editImage() {
    EditorWindowController.present(image)
    dismiss()
  }
  @objc private func recognizeText() { CaptureActions.recognizeText(image) }
  @objc private func setOpacity(_ sender: NSMenuItem) { alphaValue = CGFloat(sender.tag) / 100 }
  @objc private func closeImage() { dismiss() }
  @objc private func closeAllPins() { Self.closeAll() }

  private func dismiss() {
    orderOut(nil)
    Self.pinned.removeAll { $0 === self }
  }
}
