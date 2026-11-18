import AppKit
import KitziCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable
final class ConverterModel {
  var files: [URL] = [] {
    didSet {
      let available = ConversionAction.available(for: files)
      if action.map(available.contains) != true { action = available.first }
      results = []
      errorMessage = nil
      foundText = nil
    }
  }
  var action: ConversionAction?
  var options = ConversionOptions()
  /// nil means "next to each file".
  var outputFolder: URL?
  var isWorking = false
  var progress: Double = 0
  var results: [URL] = []
  var errorMessage: String?
  var foundText: String?

  var availableActions: [ConversionAction] { ConversionAction.available(for: files) }

  func add(_ urls: [URL]) {
    files += urls.filter { url in !files.contains(url) }
  }

  func run() {
    guard let action, !files.isEmpty, !isWorking else { return }
    isWorking = true
    progress = 0
    results = []
    errorMessage = nil
    foundText = nil
    let files = files
    let options = options
    let outputFolder = outputFolder
    Task {
      do {
        let result = try await Task.detached(priority: .userInitiated) {
          try await ConversionRunner.run(action, files: files, options: options, outputFolder: outputFolder) { value in
            Task { @MainActor [weak self] in self?.progress = value }
          }
        }.value
        results = result.outputs
        if let text = result.text {
          foundText = text.isEmpty ? String(localized: "No QR code found.") : text
        }
      } catch {
        errorMessage = error.localizedDescription
      }
      progress = 1
      isWorking = false
    }
  }
}

/// The converter window: drop files, pick what to do, convert.
final class ConverterWindow: NSObject, NSWindowDelegate {
  private static var shared: ConverterWindow?
  private let model = ConverterModel()
  private var window: NSWindow?

  static func show(with files: [URL] = []) {
    let controller = shared ?? ConverterWindow()
    shared = controller
    controller.model.add(files)
    if controller.window == nil {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
      window.title = String(localized: "Converter")
      window.isReleasedWhenClosed = false
      window.contentViewController = NSHostingController(rootView: ConverterView(model: controller.model))
      window.delegate = controller
      window.center()
      controller.window = window
      KitziWindows.didOpen()
    }
    controller.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) {
    window?.contentViewController = nil
    window = nil
    KitziWindows.didClose()
    Self.shared = nil
  }
}

private struct ConverterView: View {
  @Bindable var model: ConverterModel
  @State private var dropTargeted = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      fileList
      if !model.files.isEmpty {
        actionPicker
        if let action = model.action {
          optionsView(for: action)
        }
        outputRow
        runRow
        resultView
      }
    }
    .padding(18)
    .frame(minWidth: 560, minHeight: 460, alignment: .top)
  }

  // MARK: Files

  private var fileList: some View {
    VStack(spacing: 8) {
      if model.files.isEmpty {
        VStack(spacing: 10) {
          Image(systemName: "arrow.down.doc")
            .font(.system(size: 34))
            .foregroundStyle(.secondary)
          Text("Drop files here")
            .font(.headline)
          Text("Images, PDFs, videos, audio, documents or ZIP files")
            .foregroundStyle(.secondary)
          Button("Choose Files…", action: chooseFiles)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
      } else {
        ScrollView {
          VStack(spacing: 4) {
            ForEach(model.files, id: \.self) { file in
              HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                  .resizable()
                  .frame(width: 22, height: 22)
                Text(file.lastPathComponent)
                  .lineLimit(1)
                  .truncationMode(.middle)
                Spacer()
                Button {
                  model.files.removeAll { $0 == file }
                } label: {
                  Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Remove"))
              }
            }
          }
        }
        .frame(maxHeight: 130)
        HStack {
          Button("Add Files…", action: chooseFiles)
          Button("Clear") { model.files = [] }
          Spacer()
        }
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                      style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: model.files.isEmpty ? [6] : []))
    )
    .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
      for provider in providers {
        _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
          guard let url = (object as? NSURL) as URL? else { return }
          Task { @MainActor in model.add([url]) }
        }
      }
      return true
    }
  }

  private func chooseFiles() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    if panel.runModal() == .OK {
      model.add(panel.urls)
    }
  }

  // MARK: Action

  private var actionPicker: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
      ForEach(model.availableActions) { action in
        Button {
          model.action = action
        } label: {
          Label(action.title, systemImage: action.systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(model.action == action ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
              .strokeBorder(model.action == action ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
  }

  @ViewBuilder
  private func optionsView(for action: ConversionAction) -> some View {
    switch action {
    case .convertImage:
      Form {
        Picker("Format", selection: $model.options.imageFormat) {
          ForEach(ImageFormat.allCases) { Text($0.title).tag($0) }
        }
        if model.options.imageFormat.isLossy {
          LabeledContent("Quality") {
            HStack {
              Slider(value: $model.options.quality, in: 0.3...1)
              Text((model.options.quality).formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                .frame(width: 44)
            }
          }
        }
        Picker("Size", selection: $model.options.maxPixels) {
          Text("Original").tag(Int?.none)
          ForEach([3840, 2560, 1920, 1280, 800], id: \.self) { Text("\($0) px").tag(Int?.some($0)) }
        }
        Toggle("Remove location and camera details", isOn: $model.options.stripMetadata)
      }
      .formStyle(.grouped)
      .frame(maxHeight: 200)
    case .pdfToImages:
      Picker("Format", selection: $model.options.pageImageFormat) {
        ForEach([ImageFormat.png, .jpeg, .heic, .tiff]) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
    case .convertVideo:
      HStack {
        Picker("Format", selection: $model.options.videoFormat) {
          ForEach(VideoFormat.allCases) { Text($0.title).tag($0) }
        }
        Picker("Quality", selection: $model.options.videoQuality) {
          ForEach(VideoQuality.allCases) { Text($0.title).tag($0) }
        }
      }
    case .videoToGIF:
      Picker("Width", selection: $model.options.gifWidth) {
        ForEach([480, 640, 960], id: \.self) { Text("\($0) px").tag($0) }
      }
      .pickerStyle(.segmented)
    case .convertAudio:
      Picker("Format", selection: $model.options.audioFormat) {
        ForEach(AudioFormat.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
    case .convertDocument:
      Picker("Format", selection: $model.options.documentFormat) {
        ForEach(DocumentFormat.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
    default:
      EmptyView()
    }
  }

  // MARK: Output and run

  private var outputRow: some View {
    HStack {
      Text("Save to")
      Text(model.outputFolder.map { FileManager.default.displayName(atPath: $0.path) } ?? String(localized: "Next to the original files"))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer()
      Button("Choose…") {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK { model.outputFolder = panel.url }
      }
      if model.outputFolder != nil {
        Button("Reset") { model.outputFolder = nil }
      }
    }
  }

  private var runRow: some View {
    HStack {
      if model.isWorking {
        ProgressView(value: model.progress)
      }
      Spacer()
      Button {
        model.run()
      } label: {
        Text(model.action == .readQRCode ? String(localized: "Read") : String(localized: "Convert"))
          .frame(minWidth: 90)
      }
      .keyboardShortcut(.defaultAction)
      .disabled(model.action == nil || model.isWorking)
    }
  }

  @ViewBuilder
  private var resultView: some View {
    if let error = model.errorMessage {
      Label(error, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
    }
    if let text = model.foundText {
      VStack(alignment: .leading, spacing: 6) {
        Text(text)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
          .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        Button("Copy") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        }
      }
    }
    if !model.results.isEmpty {
      HStack {
        Label(String(localized: "\(model.results.count) file(s) ready"), systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        Spacer()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(model.results) }
      }
    }
  }
}
