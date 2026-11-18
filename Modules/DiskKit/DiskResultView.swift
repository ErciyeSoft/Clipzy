import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The scan result: path bar, ring chart, the current folder's contents and the collector.
struct DiskResultView: View {
  let model: DiskAnalyzerModel

  var body: some View {
    VStack(spacing: 0) {
      DiskPathBar(model: model)
      Divider()
      if let scan = model.scan, scan.unreadableCount > 0 {
        UnreadableBanner(model: model, scan: scan)
        Divider()
      }
      HStack(spacing: 0) {
        SunburstView(model: model)
          .padding(18)
          .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        Divider()
        DiskItemList(model: model)
          .frame(width: 360)
      }
      Divider()
      CollectorBar(model: model)
    }
    .overlay {
      if model.isRescanning {
        RescanOverlay(model: model)
      }
    }
  }
}

// MARK: - Path bar

private struct DiskPathBar: View {
  let model: DiskAnalyzerModel

  var body: some View {
    HStack(spacing: 10) {
      Button {
        model.backToStart()
      } label: {
        Label("Disks", systemImage: "chevron.left")
      }
      .help("Back to the list of disks")

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
          ForEach(Array(model.path.enumerated()), id: \.offset) { index, node in
            if index > 0 {
              Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Button(node.name) { model.open(node) }
              .buttonStyle(.plain)
              .fontWeight(node === model.current ? .semibold : .regular)
              .foregroundStyle(node === model.current ? .primary : .secondary)
          }
        }
      }

      Button {
        model.goUp()
      } label: {
        Image(systemName: "arrow.up")
      }
      .help("Enclosing folder")
      .keyboardShortcut(.upArrow, modifiers: .command)
      .disabled(model.current?.parent == nil)

      Button {
        model.rescanCurrent()
      } label: {
        Label("Rescan", systemImage: "arrow.clockwise")
      }
      .help("Scan this folder again")
      .keyboardShortcut("r", modifiers: .command)
      .disabled(model.isBusy)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
  }
}

// MARK: - Unreadable folders

private struct UnreadableBanner: View {
  let model: DiskAnalyzerModel
  let scan: DiskScan
  @State private var showsList = false

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "lock.fill")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 1) {
        Text("\(scan.unreadableCount) folders couldn't be read")
        Text("Their size counts as hidden space. Give Kitzi Full Disk Access, then rescan.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Button("Show") { showsList = true }
        .buttonStyle(.link)
        .popover(isPresented: $showsList) {
          UnreadableList(model: model, scan: scan)
        }
      Spacer()
      Button("Open Full Disk Access Settings…") {
        DiskAnalyzerModel.openFullDiskAccessSettings()
      }
    }
    .font(.callout)
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(Color.orange.opacity(0.08))
  }
}

private struct UnreadableList: View {
  let model: DiskAnalyzerModel
  let scan: DiskScan

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(scan.unreadable.enumerated()), id: \.offset) { _, node in
          Text(model.url(of: node).path)
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
        if scan.unreadableCount > scan.unreadable.count {
          Text("and \(scan.unreadableCount - scan.unreadable.count) more")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
    }
    .frame(width: 480, height: 300)
  }
}

// MARK: - List

/// The current folder's contents, largest first. Double-click opens a folder.
private struct DiskItemList: View {
  @Bindable var model: DiskAnalyzerModel

  var body: some View {
    let items = model.items.prefix(DiskAnalyzerModel.listLimit)
    let total = Double(max(model.layout.total, 1))
    List(selection: $model.selection) {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        DiskItemRow(
          item: item,
          url: model.url(of: item),
          color: SunburstPalette.color(for: item, branch: index, ring: 1),
          fraction: Double(item.size) / total
        )
        .tag(item.id)
        .onDrag { model.dragProvider(for: item) }
      }
      if model.items.count > items.count {
        Text("\((model.items.count - items.count).formatted()) more items")
          .foregroundStyle(.secondary)
          .selectionDisabled()
      }
    }
    .contextMenu(forSelectionType: DiskItem.ID.self) { ids in
      DiskItemMenu(model: model, items: model.items(for: ids))
    } primaryAction: { ids in
      model.activate(ids)
    }
    .onKeyPress(.space) {
      model.quickLook(model.items(for: model.selection))
      return .handled
    }
    .onDeleteCommand {
      model.collect(model.items(for: model.selection))
    }
  }
}

private struct DiskItemRow: View {
  let item: DiskItem
  let url: URL?
  let color: Color
  let fraction: Double

  var body: some View {
    HStack(spacing: 8) {
      icon
        .frame(width: 20, height: 20)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 4) {
          Text(item.name)
            .lineLimit(1)
            .truncationMode(.middle)
          if item.folder?.isUnreadable == true {
            Image(systemName: "lock.fill")
              .font(.caption2)
              .foregroundStyle(.orange)
              .help("Kitzi couldn't read this folder")
          }
        }
        if case .hiddenSpace = item, let note = SunburstView.explanation(for: item) {
          Text(note)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        } else {
          GeometryReader { proxy in
            Capsule()
              .fill(color)
              .frame(width: max(2, proxy.size.width * min(1, fraction)))
          }
          .frame(height: 4)
        }
      }
      Text(DiskFormat.bytes(item.size))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
    .help(url?.path ?? SunburstView.explanation(for: item) ?? "")
  }

  @ViewBuilder
  private var icon: some View {
    switch item {
    case .folder, .file:
      if let url {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
          .resizable()
      }
    case .smallerFiles, .smallObjects:
      Image(systemName: "doc.on.doc")
        .foregroundStyle(.secondary)
    case .hiddenSpace:
      Image(systemName: "eye.slash")
        .foregroundStyle(.secondary)
    case .freeSpace:
      Image(systemName: "circle")
        .foregroundStyle(.secondary)
    }
  }
}

/// Right-click menu for the selected rows.
private struct DiskItemMenu: View {
  let model: DiskAnalyzerModel
  let items: [DiskItem]

  var body: some View {
    let real = items.filter(\.isReal)
    Button("Open") { model.openInApps(real) }
      .disabled(real.isEmpty)
    Button("Reveal in Finder") { model.reveal(real) }
      .disabled(real.isEmpty)
    Button("Quick Look") { model.quickLook(real) }
      .disabled(real.isEmpty)
    Button("Copy Path") { model.copyPaths(real) }
      .disabled(real.isEmpty)
    Divider()
    Button("Add to Collector") { model.collect(real) }
      .disabled(real.isEmpty)
    if real.count == 1, let folder = real[0].folder {
      Divider()
      Button("Rescan This Folder") { model.rescan(folder) }
        .disabled(model.isBusy)
    }
  }
}

// MARK: - Collector

/// Items waiting to go to the Trash. Drop list rows or chart pieces here.
private struct CollectorBar: View {
  let model: DiskAnalyzerModel
  @State private var dropTargeted = false
  @State private var confirming = false

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: model.collected.isEmpty ? "tray" : "tray.full")
        .font(.title3)
        .foregroundStyle(.secondary)
      if model.collected.isEmpty {
        Text("Drag files and folders here to collect them for the Trash")
          .foregroundStyle(.secondary)
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(model.collected) { entry in
              CollectedChip(entry: entry) { model.uncollect(entry.id) }
            }
          }
        }
      }
      Spacer(minLength: 8)
      if !model.collected.isEmpty {
        Text(DiskFormat.bytes(model.collectedSize))
          .monospacedDigit()
        if model.isTrashing {
          ProgressView()
            .controlSize(.small)
        }
        Button("Move to Trash…") { confirming = true }
          .disabled(model.isBusy)
      }
    }
    .padding(.horizontal, 14)
    .frame(height: 54)
    .background(dropTargeted ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.06))
    .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
      for provider in providers {
        _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
          guard let url = (object as? NSURL) as URL? else { return }
          Task { @MainActor in model.acceptDrop([url]) }
        }
      }
      return !providers.isEmpty
    }
    .alert(Text("Move \(model.collected.count) items to the Trash?"), isPresented: $confirming) {
      Button("Move to Trash", role: .destructive) { model.trashCollected() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("\(DiskFormat.bytes(model.collectedSize)) in total. The space is freed once you empty the Trash.")
    }
    .alert(Text("Some items couldn't be moved to the Trash"), isPresented: failuresShown) {
      Button("OK") { model.trashFailures = [] }
    } message: {
      Text(model.trashFailures.joined(separator: "\n"))
    }
  }

  private var failuresShown: Binding<Bool> {
    Binding(
      get: { !model.trashFailures.isEmpty },
      set: { if !$0 { model.trashFailures = [] } }
    )
  }
}

private struct CollectedChip: View {
  let entry: CollectedItem
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 5) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
        .resizable()
        .frame(width: 16, height: 16)
      Text(entry.name)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 150, alignment: .leading)
      Text(DiskFormat.bytes(entry.size))
        .foregroundStyle(.secondary)
        .monospacedDigit()
      Button(action: remove) {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Remove from the collector")
    }
    .font(.callout)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.secondary.opacity(0.12), in: Capsule())
    .help(entry.url.path)
  }
}

// MARK: - Rescan

private struct RescanOverlay: View {
  let model: DiskAnalyzerModel

  var body: some View {
    ZStack {
      Color.black.opacity(0.08)
      VStack(spacing: 10) {
        ProgressView()
        Text("Rescanning \(model.scanName)…")
          .font(.headline)
        ScanNumbers(progress: model.progress)
        Button("Cancel") { model.cancelScan() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(24)
      .frame(maxWidth: 460)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
  }
}
