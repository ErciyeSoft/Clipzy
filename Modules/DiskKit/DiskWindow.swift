import AppKit
import KitziCore
import Combine
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

/// The Disk Analyzer window: pick a disk or folder, scan it, look around, clean up.
final class DiskAnalyzerWindow: NSObject, NSWindowDelegate {
  private static var shared: DiskAnalyzerWindow?
  private let model = DiskAnalyzerModel()
  private var window: NSWindow?

  static func show() {
    let controller = shared ?? DiskAnalyzerWindow()
    shared = controller
    if controller.window == nil {
      let window = PreviewingWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
      )
      window.title = String(localized: "Disk Analyzer")
      window.isReleasedWhenClosed = false
      window.contentViewController = NSHostingController(rootView: DiskAnalyzerView(model: controller.model))
      window.delegate = controller
      window.center()
      window.setFrameAutosaveName("KitziDiskAnalyzer")
      controller.window = window
      KitziWindows.didOpen()
    }
    controller.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) {
    model.cancelScan()
    if let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil, panel.isVisible {
      panel.orderOut(nil)
    }
    window?.contentViewController = nil
    window = nil
    KitziWindows.didClose()
    Self.shared = nil
  }
}

/// A window that takes control of the Quick Look panel while it is key.
/// AppKit calls these on the main thread; the SDK just doesn't mark them so.
private final class PreviewingWindow: NSWindow {
  nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

  nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
    MainActor.assumeIsolated { panel.dataSource = DiskQuickLook.shared }
  }

  nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
    MainActor.assumeIsolated { panel.dataSource = nil }
  }
}

/// Feeds the Quick Look panel with the files to preview.
final class DiskQuickLook: NSObject, QLPreviewPanelDataSource {
  static let shared = DiskQuickLook()
  private var urls: [URL] = []

  /// Shows the files in Quick Look; the same files again close it, like Space in Finder.
  func show(_ urls: [URL]) {
    guard let panel = QLPreviewPanel.shared() else { return }
    if panel.isVisible, urls == self.urls {
      panel.orderOut(nil)
      return
    }
    self.urls = urls
    if panel.isVisible {
      panel.reloadData()
    } else {
      panel.makeKeyAndOrderFront(nil)
    }
  }

  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    urls.count
  }

  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
    urls[index] as NSURL
  }
}

struct DiskAnalyzerView: View {
  let model: DiskAnalyzerModel

  var body: some View {
    Group {
      switch model.phase {
      case .start: DiskStartView(model: model)
      case .scanning: DiskScanningView(model: model)
      case .result: DiskResultView(model: model)
      }
    }
    .frame(minWidth: 820, minHeight: 560)
    .overlay(alignment: .top) {
      if let notice = model.notice {
        Text(notice)
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
          .background(.regularMaterial, in: Capsule())
          .padding(.top, 10)
          .task(id: notice) {
            try? await Task.sleep(for: .seconds(4))
            if model.notice == notice { model.notice = nil }
          }
      }
    }
  }
}

// MARK: - Start

/// The list of disks with a Scan button each, plus "Scan a Folder…" and folder drops.
private struct DiskStartView: View {
  let model: DiskAnalyzerModel
  @State private var dropTargeted = false

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          Text("Choose a disk to scan")
            .font(.title2.weight(.semibold))
          Text("Find out what takes up space. Nothing is deleted unless you collect it and confirm.")
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
          if model.volumes.isEmpty {
            ProgressView()
              .frame(maxWidth: .infinity, minHeight: 120)
          }
          ForEach(model.volumes) { volume in
            VolumeRow(volume: volume) { model.scan(volume.url) }
          }
        }
        .padding(24)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
      }
      Divider()
      HStack(spacing: 12) {
        Button("Scan a Folder…", action: chooseFolder)
        Text("or drop a folder anywhere in this window")
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(16)
    }
    .overlay {
      if dropTargeted {
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(Color.accentColor, lineWidth: 2)
          .padding(6)
          .allowsHitTesting(false)
      }
    }
    .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
      guard let provider = providers.first else { return false }
      _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
        guard let url = (object as? NSURL) as URL? else { return }
        Task { @MainActor in model.scan(url) }
      }
      return true
    }
    .task { await model.reloadVolumes() }
    .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
      Task { await model.reloadVolumes() }
    }
    .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
      Task { await model.reloadVolumes() }
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = String(localized: "Scan")
    if panel.runModal() == .OK, let url = panel.url {
      model.scan(url)
    }
  }
}

private struct VolumeRow: View {
  let volume: VolumeInfo
  let scan: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: volume.url.path))
        .resizable()
        .frame(width: 44, height: 44)
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline) {
          Text(volume.name)
            .font(.headline)
          if volume.isStartup {
            Text("Startup disk")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Text("\(DiskFormat.bytes(volume.available)) free of \(DiskFormat.bytes(volume.total))")
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        CapacityBar(volume: volume)
        if volume.purgeable > 0 {
          Text("\(DiskFormat.bytes(volume.purgeable)) purgeable")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Space macOS frees on its own when it is needed, such as local snapshots and caches.")
        }
      }
      Button("Scan", action: scan)
        .controlSize(.large)
    }
    .padding(14)
    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
  }
}

/// Used, purgeable and free space as one bar.
private struct CapacityBar: View {
  let volume: VolumeInfo

  var body: some View {
    GeometryReader { proxy in
      let total = Double(max(volume.total, 1))
      HStack(spacing: 0) {
        Rectangle()
          .fill(tint)
          .frame(width: proxy.size.width * Double(volume.used) / total)
        Rectangle()
          .fill(tint.opacity(0.4))
          .frame(width: proxy.size.width * Double(volume.purgeable) / total)
        Spacer(minLength: 0)
      }
      .background(Color.secondary.opacity(0.15))
      .clipShape(Capsule())
    }
    .frame(height: 10)
  }

  /// Like a fuel gauge: calm while there is room, warning when space runs low.
  private var tint: Color {
    let free = Double(volume.available + volume.purgeable) / Double(max(volume.total, 1))
    if free < 0.1 { return .red }
    if free < 0.25 { return .orange }
    return .accentColor
  }
}

// MARK: - Scanning

private struct DiskScanningView: View {
  let model: DiskAnalyzerModel

  var body: some View {
    VStack(spacing: 14) {
      ProgressView()
        .controlSize(.large)
      Text("Scanning \(model.scanName)…")
        .font(.title3)
      ScanNumbers(progress: model.progress)
      Button("Cancel") { model.cancelScan() }
        .keyboardShortcut(.cancelAction)
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Items, bytes and the folder being read.
struct ScanNumbers: View {
  let progress: ScanProgress

  var body: some View {
    VStack(spacing: 6) {
      Text("\(progress.items.formatted()) items · \(DiskFormat.bytes(progress.bytes))")
        .monospacedDigit()
      Text(progress.currentPath)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 520)
    }
  }
}
