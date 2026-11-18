import AppKit
import Observation

/// A finished scan shown in the window.
struct DiskScan {
  var root: DiskNode
  let url: URL
  /// A whole volume was scanned, so free and hidden space can be shown.
  let isVolume: Bool
  var freeSpace: Int64 = 0
  var hiddenSpace: Int64 = 0
  var unreadableCount = 0
  var unreadable: [DiskNode] = []

  /// Gray stand-ins next to the root of a volume scan.
  var extraItems: [DiskItem] {
    guard isVolume else { return [] }
    var items: [DiskItem] = []
    if hiddenSpace > 0 { items.append(.hiddenSpace(hiddenSpace)) }
    if freeSpace > 0 { items.append(.freeSpace(freeSpace)) }
    return items
  }

  /// Used space minus what the scan found: system files, snapshots, other APFS volumes,
  /// folders without access.
  mutating func apply(_ volume: VolumeInfo) {
    freeSpace = volume.available
    hiddenSpace = max(0, volume.occupied - root.size)
  }
}

/// Something waiting in the collector to go to the Trash.
struct CollectedItem: Identifiable {
  let item: DiskItem
  let url: URL
  var id: DiskItem.ID { item.id }
  var name: String { item.name }
  var size: Int64 { item.size }
}

/// State of the Disk Analyzer window: volumes, the running scan, the result and the collector.
@Observable
final class DiskAnalyzerModel {
  enum Phase { case start, scanning, result }

  static let listLimit = 2000

  private(set) var phase = Phase.start
  private(set) var volumes: [VolumeInfo] = []
  private(set) var progress = ScanProgress()
  /// Name of the disk or folder being scanned.
  private(set) var scanName = ""
  private(set) var scan: DiskScan?
  private(set) var current: DiskNode?
  /// Children of `current`, largest first (free and hidden space last at a volume's root).
  private(set) var items: [DiskItem] = []
  private(set) var layout = SunburstLayout()
  var selection: Set<DiskItem.ID> = []
  private(set) var collected: [CollectedItem] = []
  private(set) var isRescanning = false
  private(set) var isTrashing = false
  /// A short message shown over the window for a few seconds.
  var notice: String?
  var trashFailures: [String] = []

  @ObservationIgnored private var scanTask: Task<Void, Never>?
  @ObservationIgnored private var generation = 0

  var isBusy: Bool { isRescanning || isTrashing }
  var isAtRoot: Bool { current != nil && current === scan?.root }
  var collectedSize: Int64 { collected.reduce(0) { $0 + $1.size } }
  /// From the scanned root down to the current folder.
  var path: [DiskNode] { current.map { Array($0.ancestry.reversed()) } ?? [] }

  // MARK: Volumes

  func reloadVolumes() async {
    volumes = await DiskVolumes.load()
  }

  // MARK: Scanning

  /// Scans a folder, or a whole volume when `url` is the root of one.
  func scan(_ url: URL) {
    let url = url.resolvingSymlinksInPath()
    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isVolumeKey, .volumeLocalizedNameKey])
    guard values?.isDirectory == true else {
      notice = String(localized: "Choose a folder or a disk to scan.")
      return
    }
    let isVolume = values?.isVolume == true
    let name = isVolume
      ? values?.volumeLocalizedName ?? FileManager.default.displayName(atPath: url.path)
      : FileManager.default.displayName(atPath: url.path)

    let generation = startScan(named: name)
    phase = .scanning
    scanTask = Task {
      do {
        let output = try await DiskScanner.scan(url, name: name, progress: progressHandler(generation))
        var scan = DiskScan(root: output.root, url: url, isVolume: isVolume)
        scan.unreadableCount = output.unreadableCount
        scan.unreadable = output.unreadable
        if isVolume, let volume = await DiskVolumes.freshInfo(for: url) {
          scan.apply(volume)
        }
        guard generation == self.generation else { return }
        show(scan)
      } catch {
        guard generation == self.generation else { return }
        phase = self.scan == nil ? .start : .result
      }
    }
  }

  /// Scans one folder of the result again and swaps it into the tree.
  func rescan(_ node: DiskNode) {
    guard let scan, !isBusy, node.isAttached else { return }
    let url = url(of: node)
    let isRoot = node === scan.root
    let generation = startScan(named: node.name)
    isRescanning = true
    scanTask = Task {
      defer { if generation == self.generation { isRescanning = false } }
      do {
        let output = try await DiskScanner.scan(url, name: node.name, progress: progressHandler(generation))
        let volume = isRoot && scan.isVolume ? await DiskVolumes.freshInfo(for: url) : nil
        guard generation == self.generation else { return }
        replace(node, with: output.root, volume: volume)
      } catch {
        // Cancelled: keep the old result.
      }
    }
  }

  func rescanCurrent() {
    if let current { rescan(current) }
  }

  func cancelScan() {
    scanTask?.cancel()
    scanTask = nil
    generation += 1
    isRescanning = false
    if phase == .scanning { phase = scan == nil ? .start : .result }
  }

  /// Drops the result and goes back to the list of disks.
  func backToStart() {
    cancelScan()
    scan = nil
    current = nil
    items = []
    layout = SunburstLayout()
    selection = []
    collected = []
    phase = .start
    Task { await reloadVolumes() }
  }

  private func startScan(named name: String) -> Int {
    scanTask?.cancel()
    generation += 1
    scanName = name
    progress = ScanProgress()
    return generation
  }

  private func progressHandler(_ generation: Int) -> @Sendable (ScanProgress) -> Void {
    { [weak self] value in
      Task { @MainActor in
        guard let self, self.generation == generation else { return }
        self.progress = value
      }
    }
  }

  private func show(_ scan: DiskScan) {
    self.scan = scan
    current = scan.root
    selection = []
    collected = []
    phase = .result
    refresh()
  }

  private func replace(_ old: DiskNode, with new: DiskNode, volume: VolumeInfo?) {
    guard var scan else { return }
    let wasInside = current?.isInside(old) ?? false
    if old === scan.root {
      old.flags.insert(.removed)
      scan.root = new
      if let volume { scan.apply(volume) }
    } else {
      old.parent?.replaceFolder(old, with: new)
    }
    self.scan = scan
    if wasInside { current = new }
    afterTreeChange()
  }

  // MARK: Navigation

  func open(_ node: DiskNode) {
    guard node !== current, node.isAttached else { return }
    current = node
    selection = []
    refresh()
  }

  func goUp() {
    if let parent = current?.parent { open(parent) }
  }

  /// Double-click in the list: folders open in place, files show in Quick Look.
  func activate(_ ids: Set<DiskItem.ID>) {
    let chosen = items(for: ids)
    if chosen.count == 1, let folder = chosen[0].folder {
      open(folder)
    } else {
      quickLook(chosen)
    }
  }

  func items(for ids: Set<DiskItem.ID>) -> [DiskItem] {
    items.filter { ids.contains($0.id) }
  }

  /// Rebuilds the list and the chart for the current folder.
  func refresh() {
    guard let scan, let current else {
      items = []
      layout = SunburstLayout()
      return
    }
    let extras = current === scan.root ? scan.extraItems : []
    items = current.sortedItems() + extras
    layout = SunburstLayout(center: current, extras: extras)
    let ids = Set(items.map(\.id))
    selection = selection.filter(ids.contains)
  }

  private func afterTreeChange() {
    if let current, !current.isAttached { self.current = current.nearestAttached }
    collected.removeAll { !isPresent($0.item) }
    if var scan {
      let unreadable = scan.root.unreadableFolders(limit: DiskScanner.unreadableLimit)
      scan.unreadableCount = unreadable.count
      scan.unreadable = unreadable.first
      self.scan = scan
    }
    refresh()
  }

  // MARK: Paths

  func url(of node: DiskNode) -> URL {
    guard let scan else { return URL(fileURLWithPath: "/") }
    var names: [String] = []
    var node = node
    while let parent = node.parent {
      names.append(node.name)
      node = parent
    }
    return names.reversed().reduce(scan.url) { $0.appending(path: $1, directoryHint: .isDirectory) }
  }

  func url(of item: DiskItem) -> URL? {
    switch item {
    case .folder(let node): url(of: node)
    case .file(let file, let parent): url(of: parent).appending(path: file.name, directoryHint: .notDirectory)
    default: nil
    }
  }

  // MARK: Finder actions

  func reveal(_ items: [DiskItem]) {
    let urls = items.compactMap(url(of:))
    if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
  }

  func openInApps(_ items: [DiskItem]) {
    for url in items.compactMap(url(of:)) { NSWorkspace.shared.open(url) }
  }

  func copyPaths(_ items: [DiskItem]) {
    let paths = items.compactMap(url(of:)).map(\.path)
    guard !paths.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
  }

  func quickLook(_ items: [DiskItem]) {
    let urls = items.compactMap(url(of:))
    if !urls.isEmpty { DiskQuickLook.shared.show(urls) }
  }

  static func openFullDiskAccessSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
      NSWorkspace.shared.open(url)
    }
  }

  // MARK: Collector

  /// Adds items to the collector. Protected locations and the scanned root are refused,
  /// and items already covered by a collected folder are skipped.
  func collect(_ items: [DiskItem]) {
    for item in items where item.isReal {
      guard let url = url(of: item) else { continue }
      if item.folder === scan?.root || Self.isProtected(url.path) {
        notice = String(localized: "\(item.name) is protected and can't be collected.")
        continue
      }
      let covered = collected.contains { entry in
        guard let folder = entry.item.folder else { return entry.id == item.id }
        return item.isWithin(folder)
      }
      if covered { continue }
      if let folder = item.folder {
        collected.removeAll { $0.item.isWithin(folder) }
      }
      collected.append(CollectedItem(item: item, url: url))
    }
  }

  func uncollect(_ id: DiskItem.ID) {
    collected.removeAll { $0.id == id }
  }

  /// Moves everything in the collector to the Trash, then takes it out of the tree.
  func trashCollected() {
    guard !collected.isEmpty, !isBusy else { return }
    isTrashing = true
    let entries = collected
    Task {
      let errors = await DiskTrash.moveToTrash(entries.map(\.url))
      var failed: [CollectedItem] = []
      var messages: [String] = []
      for (entry, error) in zip(entries, errors) {
        if let error {
          failed.append(entry)
          messages.append("\(entry.name): \(error)")
        } else {
          remove(entry.item)
        }
      }
      collected = failed
      trashFailures = messages
      isTrashing = false
      afterTreeChange()
    }
  }

  private func remove(_ item: DiskItem) {
    switch item {
    case .folder(let node): node.parent?.removeFolder(node)
    case .file(let file, let parent): parent.removeFile(named: file.name)
    default: break
    }
  }

  /// Whether a collected item is still in the tree (a rescan may have replaced it).
  private func isPresent(_ item: DiskItem) -> Bool {
    switch item {
    case .folder(let node): node.isAttached
    case .file(let file, let parent): parent.isAttached && parent.files.contains { $0.name == file.name }
    default: false
    }
  }

  /// Folders macOS or the user account depend on. Their contents can still be collected.
  static func isProtected(_ path: String) -> Bool {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let exact: Set<String> = [
      "/", "/System", "/Library", "/Applications", "/Users", "/Volumes", "/private", "/private/var",
      "/private/etc", "/private/tmp", "/usr", "/usr/local", "/bin", "/sbin", "/opt", "/cores",
      "/etc", "/var", "/tmp", "/dev", "/Network",
      home, home + "/Library", home + "/Desktop", home + "/Documents", home + "/Downloads",
      home + "/Pictures", home + "/Movies", home + "/Music", home + "/Applications",
    ]
    if exact.contains(path) { return true }
    if path.hasPrefix("/usr/") { return !path.hasPrefix("/usr/local/") }
    return ["/System/", "/bin/", "/sbin/", "/private/var/db/", "/private/etc/"].contains { path.hasPrefix($0) }
  }

  // MARK: Dragging to the collector

  /// Drag payload for a list row or chart segment: the file itself, like a drag from Finder.
  func dragProvider(for item: DiskItem?) -> NSItemProvider {
    guard let item, let url = url(of: item) else { return NSItemProvider() }
    return NSItemProvider(object: url as NSURL)
  }

  /// Files dropped on the collector, from this window or from Finder. Only files and
  /// folders the scan knows about are taken.
  func acceptDrop(_ urls: [URL]) {
    let found = urls.compactMap(item(at:))
    if found.count < urls.count {
      notice = String(localized: "Only files and folders from this scan can be collected.")
    }
    collect(found)
  }

  /// The scanned file or folder at `url`, if the scan kept it by name.
  func item(at url: URL) -> DiskItem? {
    guard let scan else { return nil }
    // Resolve links in the folders above (/tmp → /private/tmp) but not in the item itself.
    let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
    let path = parent == "/" ? "/" + url.lastPathComponent : parent + "/" + url.lastPathComponent
    let rootPath = scan.url.path
    if path == rootPath { return .folder(scan.root) }
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    guard path.hasPrefix(prefix) else { return nil }
    let names = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
    guard let last = names.last else { return nil }
    var node = scan.root
    for name in names.dropLast() {
      guard let next = node.folders.first(where: { $0.name == name }) else { return nil }
      node = next
    }
    if let folder = node.folders.first(where: { $0.name == last }) { return .folder(folder) }
    if let file = node.files.first(where: { $0.name == last }) { return .file(file, in: node) }
    return nil
  }
}
