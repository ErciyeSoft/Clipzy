import Foundation

/// A file kept by name in its folder. Each folder keeps only its largest files this way.
nonisolated struct DiskFile: Sendable {
  let name: String
  let size: Int64
}

/// One scanned folder. Kept small on purpose: a whole-disk scan creates hundreds of thousands.
///
/// The scanner builds the tree off the main thread and hands it over when it is done;
/// from then on it is only read and changed on the main actor.
nonisolated final class DiskNode: @unchecked Sendable {
  struct Flags: OptionSet, Sendable {
    let rawValue: UInt8
    static let package = Flags(rawValue: 1 << 0)
    static let unreadable = Flags(rawValue: 1 << 1)
    /// Moved to the Trash or replaced by a rescan; no longer part of the tree.
    static let removed = Flags(rawValue: 1 << 2)
  }

  let name: String
  weak var parent: DiskNode?
  /// Subfolders, largest first.
  var folders: [DiskNode] = []
  /// The largest files directly in this folder, largest first.
  var files: [DiskFile] = []
  /// Files folded into one "smaller files" item to keep memory bounded.
  var smallerCount = 0
  var smallerSize: Int64 = 0
  /// Allocated bytes of everything inside.
  var size: Int64 = 0
  /// Number of files inside, at any depth.
  var fileCount = 0
  var flags: Flags

  init(name: String, parent: DiskNode?, flags: Flags = []) {
    self.name = name
    self.parent = parent
    self.flags = flags
  }

  var isPackage: Bool { flags.contains(.package) }
  var isUnreadable: Bool { flags.contains(.unreadable) }

  /// This folder followed by its parents up to the scanned root.
  var ancestry: UnfoldFirstSequence<DiskNode> { sequence(first: self) { $0.parent } }

  /// False once the folder or one of its parents was trashed or replaced by a rescan.
  var isAttached: Bool { !ancestry.contains { $0.flags.contains(.removed) } }

  /// The closest folder on the way up that is still part of the tree.
  var nearestAttached: DiskNode {
    var result = self
    for node in ancestry where node.flags.contains(.removed) {
      if let parent = node.parent { result = parent }
    }
    return result
  }

  /// True when `other` is this folder or one of its parents.
  func isInside(_ other: DiskNode) -> Bool {
    ancestry.contains { $0 === other }
  }

  // MARK: Children

  /// Files and folders inside, counting each folded small file.
  var objectCount: Int { folders.count + files.count + smallerCount }

  /// Folders, files and the "smaller files" item, largest first.
  func sortedItems() -> [DiskItem] {
    var result: [DiskItem] = []
    result.reserveCapacity(folders.count + files.count + 1)
    forEachItemBySize { item in
      result.append(item)
      return true
    }
    return result
  }

  /// Calls `body` with each child, largest first, until it returns false.
  /// Folders and files are each kept sorted, so this is a merge of the two lists.
  func forEachItemBySize(_ body: (DiskItem) -> Bool) {
    var folderIndex = 0
    var fileIndex = 0
    var smallerPending = smallerCount > 0
    while folderIndex < folders.count || fileIndex < files.count || smallerPending {
      let folderSize = folderIndex < folders.count ? folders[folderIndex].size : -1
      let fileSize = fileIndex < files.count ? files[fileIndex].size : -1
      let smallerSize = smallerPending ? self.smallerSize : -1
      let item: DiskItem
      if folderSize >= fileSize, folderSize >= smallerSize {
        item = .folder(folders[folderIndex])
        folderIndex += 1
      } else if fileSize >= smallerSize {
        item = .file(files[fileIndex], in: self)
        fileIndex += 1
      } else {
        item = .smallerFiles(self)
        smallerPending = false
      }
      if !body(item) { return }
    }
  }

  // MARK: Changes (main actor only)

  /// Takes a subfolder out of the tree and updates the sizes above it.
  func removeFolder(_ child: DiskNode) {
    guard let index = folders.firstIndex(where: { $0 === child }) else { return }
    folders.remove(at: index)
    child.flags.insert(.removed)
    applyChange(bytes: -child.size, files: -child.fileCount)
  }

  /// Takes a file out of this folder and updates the sizes above it.
  @discardableResult
  func removeFile(named name: String) -> Bool {
    guard let index = files.firstIndex(where: { $0.name == name }) else { return false }
    let file = files.remove(at: index)
    applyChange(bytes: -file.size, files: -1)
    return true
  }

  /// Swaps a subfolder for a freshly scanned copy of it.
  func replaceFolder(_ old: DiskNode, with new: DiskNode) {
    guard let index = folders.firstIndex(where: { $0 === old }) else { return }
    folders[index] = new
    new.parent = self
    old.flags.insert(.removed)
    folders.sort { $0.size > $1.size }
    applyChange(bytes: new.size - old.size, files: new.fileCount - old.fileCount)
  }

  /// Adds a size change to this folder and every parent, keeping each folder list sorted.
  private func applyChange(bytes: Int64, files: Int) {
    for node in ancestry {
      node.size += bytes
      node.fileCount += files
      node.parent?.folders.sort { $0.size > $1.size }
    }
  }

  /// Folders at or below this one that couldn't be read; at most `limit` are returned.
  func unreadableFolders(limit: Int) -> (count: Int, first: [DiskNode]) {
    var count = 0
    var first: [DiskNode] = []
    var stack = [self]
    while let node = stack.popLast() {
      if node.isUnreadable {
        count += 1
        if first.count < limit { first.append(node) }
      }
      stack.append(contentsOf: node.folders)
    }
    return (count, first)
  }
}

/// Something shown in the list or the chart: a real folder or file, or a stand-in for many.
nonisolated enum DiskItem: Identifiable, Sendable {
  case folder(DiskNode)
  case file(DiskFile, in: DiskNode)
  /// Files the scanner folded together in a folder.
  case smallerFiles(DiskNode)
  /// Chart only: neighbours too thin to draw one by one.
  case smallObjects(count: Int, size: Int64, in: DiskNode)
  case freeSpace(Int64)
  case hiddenSpace(Int64)

  nonisolated enum ID: Hashable, Sendable {
    case folder(ObjectIdentifier)
    case file(ObjectIdentifier, String)
    case smallerFiles(ObjectIdentifier)
    case smallObjects(ObjectIdentifier)
    case freeSpace
    case hiddenSpace
  }

  var id: ID {
    switch self {
    case .folder(let node): .folder(ObjectIdentifier(node))
    case .file(let file, let parent): .file(ObjectIdentifier(parent), file.name)
    case .smallerFiles(let parent): .smallerFiles(ObjectIdentifier(parent))
    case .smallObjects(_, _, let parent): .smallObjects(ObjectIdentifier(parent))
    case .freeSpace: .freeSpace
    case .hiddenSpace: .hiddenSpace
    }
  }

  var name: String {
    switch self {
    case .folder(let node): node.name
    case .file(let file, _): file.name
    case .smallerFiles(let parent): String(localized: "\(parent.smallerCount) smaller files")
    case .smallObjects(let count, _, _): String(localized: "\(count) smaller objects")
    case .freeSpace: String(localized: "Free space")
    case .hiddenSpace: String(localized: "Hidden space")
    }
  }

  var size: Int64 {
    switch self {
    case .folder(let node): node.size
    case .file(let file, _): file.size
    case .smallerFiles(let parent): parent.smallerSize
    case .smallObjects(_, let size, _): size
    case .freeSpace(let size), .hiddenSpace(let size): size
    }
  }

  /// A real file or folder on disk (it can be opened, revealed or collected).
  var isReal: Bool {
    switch self {
    case .folder, .file: true
    default: false
    }
  }

  var folder: DiskNode? {
    if case .folder(let node) = self { return node }
    return nil
  }

  /// How many files and folders this item stands for.
  var objectCount: Int {
    switch self {
    case .folder, .file: 1
    case .smallerFiles(let parent): parent.smallerCount
    case .smallObjects(let count, _, _): count
    case .freeSpace, .hiddenSpace: 0
    }
  }

  /// The folder this item sits in.
  var container: DiskNode? {
    switch self {
    case .folder(let node): node.parent
    case .file(_, let parent), .smallerFiles(let parent), .smallObjects(_, _, let parent): parent
    case .freeSpace, .hiddenSpace: nil
    }
  }

  /// True when this item is `folder` itself or lies somewhere inside it.
  func isWithin(_ folder: DiskNode) -> Bool {
    switch self {
    case .folder(let node): node.isInside(folder)
    default: container?.isInside(folder) ?? false
    }
  }
}

/// Sizes and percentages as people read them.
nonisolated enum DiskFormat {
  static func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
  }

  static func percent(_ fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(fraction < 0.1 ? 1 : 0)))
  }
}
