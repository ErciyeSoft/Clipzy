import AppKit
import KitziCore
import Observation
import SwiftUI

/// Watches /Applications and ~/Applications; when an app disappears, it lists what the app
/// left in ~/Library and asks before moving anything to the Trash.
final class AppSweeper {
  private let scanner: AppSweepScanner
  private let applicationFolders: [URL]
  private var isEnabled = false
  private lazy var watcher = FolderWatcher(latency: 3, fileEvents: false) { [weak self] _ in
    Task { @MainActor in self?.appsChanged() }
  }

  init(directory: URL) {
    let home = FileManager.default.homeDirectoryForCurrentUser
    applicationFolders = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                          home.appendingPathComponent("Applications", isDirectory: true)]
    scanner = AppSweepScanner(applicationFolders: applicationFolders,
                              library: home.appendingPathComponent("Library", isDirectory: true),
                              directory: directory)
  }

  func setEnabled(_ enabled: Bool) {
    guard enabled != isEnabled else { return }
    isEnabled = enabled
    if enabled {
      watcher.watch(applicationFolders.filter(FileOps.isDirectory).map(\.path))
      Task { [scanner] in present(await scanner.start()) }
    } else {
      watcher.stop()
      Task { [scanner] in await scanner.reset() }
    }
  }

  func stop() {
    watcher.stop()
  }

  private func appsChanged() {
    guard isEnabled else { return }
    Task { [scanner] in present(await scanner.check()) }
  }

  private func present(_ found: [AppLeftovers]) {
    guard isEnabled, !found.isEmpty else { return }
    AppSweepWindow.show(found)
  }
}

// MARK: - Window

@Observable
final class AppSweepModel {
  var groups: [AppLeftovers] = []
  var selected: Set<String> = []
  var isWorking = false
  var message: String?

  func add(_ found: [AppLeftovers]) {
    for group in found where !groups.contains(where: { $0.id == group.id }) {
      groups.append(group)
      selected.formUnion(group.items.map(\.id))
    }
  }

  var selectedSize: Int64 {
    groups.flatMap(\.items).filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size }
  }

  /// Moves the checked items to the Trash; returns true when everything went.
  func trashSelected() async -> Bool {
    let urls = groups.flatMap(\.items).filter { selected.contains($0.id) }.map(\.url)
    guard !urls.isEmpty else { return true }
    isWorking = true
    message = nil
    let failed = await Task.detached { () -> [String] in
      var failed: [String] = []
      for url in urls {
        do {
          try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
          failed.append(url.path)
        }
      }
      return failed
    }.value
    isWorking = false
    // Keep only what is still there, so the list shows what's left.
    for index in groups.indices {
      groups[index].items.removeAll { item in selected.contains(item.id) && !failed.contains(item.id) }
    }
    groups.removeAll { $0.items.isEmpty }
    selected = Set(failed)
    guard !failed.isEmpty else { return true }
    let names = failed.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
    message = String(localized: "Couldn't move \(failed.count) items to the Trash: \(names)")
    return false
  }
}

final class AppSweepWindow: NSObject, NSWindowDelegate {
  private static var shared: AppSweepWindow?
  private let model = AppSweepModel()
  private var window: NSWindow?

  static func show(_ found: [AppLeftovers]) {
    let controller = shared ?? AppSweepWindow()
    shared = controller
    controller.model.add(found)
    if controller.window == nil {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.title = String(localized: "App Sweep")
      window.isReleasedWhenClosed = false
      window.contentViewController = NSHostingController(
        rootView: AppSweepView(model: controller.model) { [weak controller] in controller?.window?.close() }
      )
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

private struct AppSweepView: View {
  @Bindable var model: AppSweepModel
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "trash.circle")
          .font(.system(size: 30))
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 3) {
          if model.groups.count == 1, let group = model.groups.first {
            Text("“\(group.app.name)” was removed")
              .font(.headline)
          } else {
            Text("Apps were removed")
              .font(.headline)
          }
          Text("These files were left behind in your Library. Choose what to move to the Trash; you can put it back from there.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      List {
        ForEach(model.groups) { group in
          Section(group.app.name) {
            ForEach(group.items) { item in
              LeftoverRow(item: item, isOn: selection(for: item))
            }
          }
        }
      }
      .listStyle(.inset)

      if let message = model.message {
        Text(verbatim: message)
          .foregroundStyle(.red)
          .font(.callout)
      }

      HStack {
        Text("Selected: \(model.selectedSize.formatted(.byteCount(style: .file)))")
          .foregroundStyle(.secondary)
          .monospacedDigit()
        if model.isWorking {
          ProgressView().controlSize(.small)
        }
        Spacer()
        Button("Keep All", action: close)
          .keyboardShortcut(.cancelAction)
        Button("Move to Trash") {
          Task {
            if await model.trashSelected() { close() }
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(model.selected.isEmpty || model.isWorking)
      }
    }
    .padding(16)
    .frame(minWidth: 560, minHeight: 380)
  }

  private func selection(for item: Leftover) -> Binding<Bool> {
    Binding(
      get: { model.selected.contains(item.id) },
      set: { isOn in
        if isOn { model.selected.insert(item.id) } else { model.selected.remove(item.id) }
      }
    )
  }
}

private struct LeftoverRow: View {
  let item: Leftover
  @Binding var isOn: Bool

  var body: some View {
    HStack(spacing: 8) {
      Toggle("", isOn: $isOn)
        .labelsHidden()
        .toggleStyle(.checkbox)
      Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
        .resizable()
        .frame(width: 18, height: 18)
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: item.url.lastPathComponent)
          .lineLimit(1)
          .truncationMode(.middle)
        HStack(spacing: 4) {
          Text(verbatim: item.location)
          if item.matchedByName {
            Text(verbatim: "·")
            Text("Matched by name")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Text(item.size.formatted(.byteCount(style: .file)))
        .monospacedDigit()
        .foregroundStyle(.secondary)
      Button {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
      } label: {
        Image(systemName: "magnifyingglass")
      }
      .buttonStyle(.borderless)
      .help("Show in Finder")
    }
    .help(item.url.path)
  }
}
