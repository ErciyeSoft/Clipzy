import AppKit
import KitziCore
import KeyboardShortcuts
import SwiftUI

/// Public entry point of the screenshot tool: area, window, screen and scrolling captures,
/// screen recording, an annotation editor, pinning and text recognition.
public final class CaptureFeature: KitziFeature {
  static let pageID = "capture.general"

  private var statusItem: NSStatusItem?
  private var defaultsObserver: NSObjectProtocol?
  private var isBusy = false

  private var recorder: ScreenRecorder?
  private var recordingStarted: Date?
  private var recordingTimer: Task<Void, Never>?

  public init() {
    CapturePrefs.register()
  }

  public func applicationDidFinishLaunching() {
    KeyboardShortcuts.onKeyUp(for: .captureArea) { [weak self] in self?.capture(.area) }
    KeyboardShortcuts.onKeyUp(for: .captureWindow) { [weak self] in self?.capture(.window) }
    KeyboardShortcuts.onKeyUp(for: .captureScreen) { [weak self] in self?.capture(.screen) }
    KeyboardShortcuts.onKeyUp(for: .captureScrolling) { [weak self] in self?.captureScrolling() }
    KeyboardShortcuts.onKeyUp(for: .recordScreen) { [weak self] in self?.toggleRecording() }
    KeyboardShortcuts.onKeyUp(for: .pinClipboard) { PinnedImageWindow.pinClipboardImage() }
    KeyboardShortcuts.onKeyUp(for: .captureHistory) { HistoryWindow.show() }
    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateStatusItem() }
    }
    updateStatusItem()
  }

  public func applicationWillTerminate() {
    if let recorder {
      let semaphore = DispatchSemaphore(value: 0)
      Task.detached {
        _ = try? await recorder.stop()
        semaphore.signal()
      }
      _ = semaphore.wait(timeout: .now() + 3)
    }
  }

  public var settingsGroups: [SettingsGroup] {
    [
      SettingsGroup(
        id: "capture",
        title: String(localized: "Screenshots"),
        pages: [
          SettingsPage(
            id: Self.pageID,
            title: String(localized: "Screenshots"),
            subtitle: String(localized: "Capture, mark up, copy, save and pin screenshots"),
            systemImage: "camera.viewfinder"
          ) {
            CaptureSettingsView()
          }
        ]
      )
    ]
  }

  // MARK: - Screenshots

  func capture(_ mode: CaptureMode) {
    guard !isBusy, recorder == nil else { return }
    isBusy = true
    Task { [weak self] in
      if mode == .area, CapturePrefs.customSelection {
        // The selection overlay handles marking up, copying, saving and pinning itself.
        _ = await SelectionSession.run(.screenshot)
        self?.isBusy = false
        return
      }
      let image = await CaptureService.capture(mode)
      self?.isBusy = false
      if let image {
        Self.deliver(image)
      }
    }
  }

  func captureScrolling() {
    guard !isBusy, recorder == nil else { return }
    isBusy = true
    Task { [weak self] in
      defer { self?.isBusy = false }
      guard let region = await SelectionSession.run(.scrolling),
            let image = await ScrollingCapture.run(region) else { return }
      Self.deliver(image)
    }
  }

  private static func deliver(_ image: CGImage) {
    switch CapturePrefs.afterCapture {
    case .openEditor: EditorWindowController.present(image)
    case .copy: CaptureActions.copy(image)
    case .save: CaptureActions.save(image)
    }
  }

  // MARK: - Recording

  func toggleRecording() {
    if recorder != nil {
      stopRecording()
    } else {
      startRecording()
    }
  }

  private func startRecording() {
    guard !isBusy else { return }
    isBusy = true
    Task { [weak self] in
      defer { self?.isBusy = false }
      guard let self, let region = await SelectionSession.run(.recording),
            let displayID = region.screen.displayID else { return }
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("Kitzi-\(UUID().uuidString).mp4")
      let recorder = ScreenRecorder(outputURL: url)
      do {
        try await recorder.start(
          displayID: displayID,
          sourceRect: region.screen.displayLocalRect(for: region.rect),
          scale: region.screen.backingScaleFactor,
          showsCursor: CapturePrefs.recordCursor
        )
      } catch {
        Self.alert(String(localized: "Couldn't start recording."), error)
        return
      }
      self.recorder = recorder
      recordingStarted = Date()
      showRecordingState()
    }
  }

  @objc private func stopRecording() {
    guard let recorder else { return }
    self.recorder = nil
    recordingTimer?.cancel()
    recordingTimer = nil
    if let statusItem {
      NSStatusBar.system.removeStatusItem(statusItem)
      self.statusItem = nil
    }
    updateStatusItem(force: true)
    Task {
      do {
        let video = try await recorder.stop()
        let saved = try await Self.saveRecording(video)
        NSWorkspace.shared.activateFileViewerSelecting([saved])
      } catch {
        Self.alert(String(localized: "Couldn't save the recording."), error)
      }
    }
  }

  private static func saveRecording(_ video: URL) async throws -> URL {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    let folder = CapturePrefs.saveFolder
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let base = folder.appendingPathComponent("Kitzi Recording \(formatter.string(from: Date()))")
    defer { try? FileManager.default.removeItem(at: video) }
    switch CapturePrefs.recordingFormat {
    case .mp4:
      let destination = base.appendingPathExtension("mp4")
      try FileManager.default.copyItem(at: video, to: destination)
      return destination
    case .gif:
      let destination = base.appendingPathExtension("gif")
      try await GIFMaker.convert(video, to: destination)
      return destination
    }
  }

  private static func alert(_ message: String, _ error: Error) {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = error.localizedDescription
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }

  // MARK: - Menu bar

  private func updateStatusItem(force: Bool = false) {
    guard recorder == nil || force else { return }
    if CapturePrefs.showMenuBarIcon {
      if statusItem == nil {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.autosaveName = "KitziCapture"
      }
      statusItem?.length = NSStatusItem.squareLength
      statusItem?.button?.title = ""
      // A filled camera at a readable size; the thin viewfinder glyph was hard to make out.
      let icon = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: String(localized: "Screenshots"))?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
      icon?.isTemplate = true
      statusItem?.button?.image = icon
      statusItem?.button?.contentTintColor = nil
      statusItem?.button?.action = nil
      statusItem?.menu = makeMenu()
    } else if let statusItem {
      NSStatusBar.system.removeStatusItem(statusItem)
      self.statusItem = nil
    }
  }

  /// While recording a separate red timer item replaces the camera; clicking it stops.
  /// (Changing the existing item's length made it disappear from the menu bar.)
  private func showRecordingState() {
    if let statusItem {
      NSStatusBar.system.removeStatusItem(statusItem)
    }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem = item
    guard let button = item.button else { return }
    // A coloured (non-template) image: the menu bar draws template images and plain titles monochrome.
    let red = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
    let dot = NSImage(systemSymbolName: "record.circle.fill",
                      accessibilityDescription: String(localized: "Stop Recording"))?.withSymbolConfiguration(red)
    dot?.isTemplate = false
    button.image = dot
    button.imagePosition = .imageLeading
    button.target = self
    button.action = #selector(stopRecording)
    button.toolTip = String(localized: "Stop Recording")
    updateTimerTitle()
    recordingTimer = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(500))
        self?.updateTimerTitle()
      }
    }
  }

  private func updateTimerTitle() {
    guard let started = recordingStarted, let button = statusItem?.button else { return }
    let seconds = Int(Date().timeIntervalSince(started))
    button.attributedTitle = NSAttributedString(
      string: String(format: " %d:%02d", seconds / 60, seconds % 60),
      attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)]
    )
  }

  private func makeMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(menuItem(String(localized: "Capture Area"), "rectangle.dashed", .captureArea, #selector(captureArea)))
    menu.addItem(menuItem(String(localized: "Capture Window"), "macwindow", .captureWindow, #selector(captureWindow)))
    menu.addItem(menuItem(String(localized: "Capture Screen"), "display", .captureScreen, #selector(captureScreen)))
    menu.addItem(menuItem(String(localized: "Scrolling Capture"), "arrow.up.and.down.text.horizontal",
                          .captureScrolling, #selector(scrollingCapture)))
    menu.addItem(.separator())
    menu.addItem(menuItem(String(localized: "Record Screen"), "record.circle", .recordScreen, #selector(recordScreen)))
    menu.addItem(.separator())
    menu.addItem(menuItem(String(localized: "Pin Clipboard Image"), "pin", .pinClipboard, #selector(pinClipboard)))
    let pins = NSMenuItem(title: String(localized: "Show or Hide Pins"), action: #selector(togglePins), keyEquivalent: "")
    pins.target = self
    pins.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
    menu.addItem(pins)
    let closePins = NSMenuItem(title: String(localized: "Close All Pins"), action: #selector(closePins), keyEquivalent: "")
    closePins.target = self
    closePins.image = NSImage(systemSymbolName: "pin.slash", accessibilityDescription: nil)
    menu.addItem(closePins)
    menu.addItem(.separator())
    menu.addItem(menuItem(String(localized: "Screenshot History…"), "photo.stack", .captureHistory, #selector(showHistory)))
    menu.addItem(.separator())
    let settings = NSMenuItem(title: String(localized: "Screenshot Settings…"), action: #selector(openSettings),
                              keyEquivalent: "")
    settings.target = self
    menu.addItem(settings)
    return menu
  }

  private func menuItem(_ title: String, _ symbol: String, _ name: KeyboardShortcuts.Name, _ action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    item.setShortcut(for: name)
    return item
  }

  @objc private func captureArea() { capture(.area) }
  @objc private func captureWindow() { capture(.window) }
  @objc private func captureScreen() { capture(.screen) }
  @objc private func scrollingCapture() { captureScrolling() }
  @objc private func recordScreen() { toggleRecording() }
  @objc private func pinClipboard() { PinnedImageWindow.pinClipboardImage() }
  @objc private func togglePins() { PinnedImageWindow.toggleAllHidden() }
  @objc private func closePins() { PinnedImageWindow.closeAll() }
  @objc private func showHistory() { HistoryWindow.show() }
  @objc private func openSettings() { KitziHost.openSettings(Self.pageID) }
}

struct CaptureSettingsView: View {
  @AppStorage(CapturePrefs.menuBarIconKey) private var menuBarIcon = true
  @AppStorage(CapturePrefs.afterCaptureKey) private var afterCapture = AfterCapture.openEditor.rawValue
  @AppStorage(CapturePrefs.saveFolderKey) private var saveFolder = CapturePrefs.defaultSaveFolder.path
  @AppStorage(CapturePrefs.formatKey) private var format = ImageFormat.png.rawValue
  @AppStorage(CapturePrefs.soundKey) private var sound = true
  @AppStorage(CapturePrefs.windowShadowKey) private var windowShadow = true
  @AppStorage(CapturePrefs.customSelectionKey) private var customSelection = true
  @AppStorage(CapturePrefs.recordingFormatKey) private var recordingFormat = RecordingFormat.mp4.rawValue
  @AppStorage(CapturePrefs.recordCursorKey) private var recordCursor = true

  var body: some View {
    Form {
      Section {
        KeyboardShortcuts.Recorder("Capture area", name: .captureArea)
        KeyboardShortcuts.Recorder("Capture window", name: .captureWindow)
        KeyboardShortcuts.Recorder("Capture screen", name: .captureScreen)
        KeyboardShortcuts.Recorder("Scrolling capture", name: .captureScrolling)
        KeyboardShortcuts.Recorder("Start or stop recording", name: .recordScreen)
        KeyboardShortcuts.Recorder("Pin clipboard image", name: .pinClipboard)
        KeyboardShortcuts.Recorder("Screenshot history", name: .captureHistory)
      } header: {
        Text("Shortcuts")
      }

      Section {
        Toggle("Use Kitzi's selection with magnifier and size", isOn: $customSelection)
      } header: {
        Text("Selecting")
      } footer: {
        Text("Drag to select, click a window, Enter for the whole screen, C to copy the color under the pointer, Esc to cancel. Turn this off to use the macOS selection instead.")
          .foregroundStyle(.secondary)
      }

      Section {
        Picker("After capturing", selection: $afterCapture) {
          Text("Open the editor").tag(AfterCapture.openEditor.rawValue)
          Text("Copy to the clipboard").tag(AfterCapture.copy.rawValue)
          Text("Save to the folder").tag(AfterCapture.save.rawValue)
        }
        LabeledContent("Save to") {
          HStack {
            Text(URL(fileURLWithPath: saveFolder).lastPathComponent)
              .foregroundStyle(.secondary)
            Button("Choose…", action: chooseFolder)
          }
        }
        Picker("Format", selection: $format) {
          Text("PNG").tag(ImageFormat.png.rawValue)
          Text("JPEG").tag(ImageFormat.jpeg.rawValue)
          Text("PDF").tag(ImageFormat.pdf.rawValue)
        }
        .pickerStyle(.segmented)
      } header: {
        Text("Saving")
      }

      Section {
        Picker("Recording format", selection: $recordingFormat) {
          Text("MP4 video").tag(RecordingFormat.mp4.rawValue)
          Text("GIF animation").tag(RecordingFormat.gif.rawValue)
        }
        .pickerStyle(.segmented)
        Toggle("Show the pointer in recordings", isOn: $recordCursor)
      } header: {
        Text("Screen recording")
      } footer: {
        Text("While recording, a red timer shows in the menu bar; click it or press the shortcut again to stop.")
          .foregroundStyle(.secondary)
      }

      Section {
        Toggle("Show the screenshot icon in the menu bar", isOn: $menuBarIcon)
        Toggle("Play the capture sound", isOn: $sound)
        Toggle("Include the window shadow", isOn: $windowShadow)
      } header: {
        Text("Options")
      }
    }
    .formStyle(.grouped)
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.directoryURL = URL(fileURLWithPath: saveFolder)
    if panel.runModal() == .OK, let url = panel.url {
      saveFolder = url.path
    }
  }
}
