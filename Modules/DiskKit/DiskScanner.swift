import Darwin
import Foundation
import os

/// Live numbers while a scan runs.
nonisolated struct ScanProgress: Sendable {
  var items = 0
  var bytes: Int64 = 0
  var currentPath = ""
}

/// What a finished scan hands back.
nonisolated struct ScanOutput: Sendable {
  let root: DiskNode
  let itemCount: Int
  let unreadableCount: Int
  /// The first folders that couldn't be read.
  let unreadable: [DiskNode]
}

/// Walks a folder tree with a few parallel workers and builds a `DiskNode` tree.
///
/// Sizes are allocated sizes (what files really take on disk). Symbolic links are not
/// followed, hard-linked files count once, other mounted volumes are not entered and each
/// folder keeps only its largest files by name; the rest become one "smaller files" item.
nonisolated enum DiskScanner {
  static let filesPerFolder = 200
  static let unreadableLimit = 500

  /// Folders never entered below "/" (and "/System"): other volumes and virtual file systems.
  /// The startup disk's data volume is reached through its firmlinks (/Users, /Library, ...).
  static let excludedNames: [String: Set<String>] = [
    "/": ["dev", "Volumes", "Network", "net", "home", ".vol", ".nofollow", ".resolve"],
    "/System": ["Volumes"],
  ]

  private static let workerCount = min(max(ProcessInfo.processInfo.activeProcessorCount, 2), 8)
  private static let queue = DispatchQueue(
    label: "com.erciyesoft.Kitzi.disk-scan", qos: .userInitiated,
    attributes: .concurrent, autoreleaseFrequency: .workItem
  )
  private static let entryKeys: [URLResourceKey] = [
    .isDirectoryKey, .isSymbolicLinkKey, .isVolumeKey,
    .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .linkCountKey,
  ]
  private static let entryKeySet = Set(entryKeys)
  private static let packageKeySet: Set<URLResourceKey> = [.isPackageKey]

  /// Scans `url` and everything below it. Throws `CancellationError` when the task is cancelled.
  @concurrent
  static func scan(
    _ url: URL, name: String, progress: @escaping @Sendable (ScanProgress) -> Void
  ) async throws -> ScanOutput {
    let root = DiskNode(name: name, parent: nil)
    let shared = ScanShared()
    var pending = [Job(node: root, url: url, depth: 0)]
    var running = 0
    var stats = ScanProgress()
    var unreadableCount = 0
    var unreadable: [DiskNode] = []
    let clock = ContinuousClock()
    var lastReport = clock.now

    await withTaskCancellationHandler {
      await withTaskGroup(of: Finished.self) { group in
        while true {
          while running < workerCount, let job = pending.popLast() {
            running += 1
            group.addTask { Finished(job: job, listing: await list(job, shared: shared)) }
          }
          guard let finished = await group.next() else { break }
          running -= 1
          if shared.isCancelled {
            pending.removeAll()
            continue
          }

          let node = finished.job.node
          let listing = finished.listing
          node.files = listing.files
          node.smallerCount = listing.smallerCount
          node.smallerSize = listing.smallerSize
          node.size = listing.fileBytes
          node.fileCount = listing.fileCount
          if listing.unreadable {
            node.flags.insert(.unreadable)
            unreadableCount += 1
            if unreadable.count < unreadableLimit { unreadable.append(node) }
          }
          node.folders.reserveCapacity(listing.subfolders.count)
          for subfolder in listing.subfolders {
            let child = DiskNode(name: subfolder.name, parent: node, flags: subfolder.isPackage ? .package : [])
            node.folders.append(child)
            pending.append(Job(node: child, url: subfolder.url, depth: finished.job.depth + 1))
          }

          stats.items += listing.fileCount + listing.subfolders.count
          stats.bytes += listing.fileBytes
          if clock.now - lastReport > .milliseconds(100) {
            lastReport = clock.now
            stats.currentPath = finished.job.url.path
            progress(stats)
          }
        }
      }
    } onCancel: {
      shared.cancel()
    }
    try Task.checkCancellation()

    finalize(root)
    return ScanOutput(root: root, itemCount: stats.items, unreadableCount: unreadableCount, unreadable: unreadable)
  }

  /// Adds subfolder sizes into their parents and sorts every folder's contents, largest first.
  static func finalize(_ root: DiskNode) {
    var order: [DiskNode] = []
    var stack = [root]
    while let node = stack.popLast() {
      order.append(node)
      stack.append(contentsOf: node.folders)
    }
    // Parents come before their children in `order`, so walking it backwards
    // sees every child before its parent.
    for node in order.reversed() {
      for child in node.folders {
        node.size += child.size
        node.fileCount += child.fileCount
      }
      node.folders.sort { $0.size > $1.size }
      node.files.sort { $0.size > $1.size }
    }
  }

  // MARK: Listing one folder

  private struct Job: Sendable {
    let node: DiskNode
    let url: URL
    let depth: Int
  }

  private struct Finished: Sendable {
    let job: Job
    let listing: Listing
  }

  struct Subfolder: Sendable {
    let name: String
    let url: URL
    let isPackage: Bool
  }

  /// The direct contents of one folder.
  struct Listing: Sendable {
    var files: [DiskFile] = []
    var subfolders: [Subfolder] = []
    var fileCount = 0
    var fileBytes: Int64 = 0
    var smallerCount = 0
    var smallerSize: Int64 = 0
    var unreadable = false
  }

  /// Lists a folder on the scan queue, so blocking file system calls stay off the
  /// cooperative thread pool. At most `workerCount` of these run at once.
  private static func list(_ job: Job, shared: ScanShared) async -> Listing {
    let excluded = job.depth <= 1 ? excludedNames[job.url.path] ?? [] : []
    return await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(returning: listFolder(job.url, excluded: excluded, shared: shared))
      }
    }
  }

  /// Reads one folder's entries with their sizes. Subfolders are returned, not entered.
  static func listFolder(_ url: URL, excluded: Set<String>, shared: ScanShared) -> Listing {
    var listing = Listing()
    let failed = Flag()
    let enumerator = FileManager.default.enumerator(
      at: url, includingPropertiesForKeys: entryKeys, options: [.skipsSubdirectoryDescendants]
    ) { errorURL, _ in
      if errorURL.path == url.path { failed.set() }
      return true
    }
    guard let enumerator else {
      listing.unreadable = true
      return listing
    }

    var top = TopFiles(capacity: filesPerFolder)
    var finished = false
    while !finished, !shared.isCancelled {
      // Drain autoreleased URLs in chunks: a folder can hold hundreds of thousands of files.
      autoreleasepool {
        for _ in 0..<512 {
          guard let entry = enumerator.nextObject() as? URL else {
            finished = true
            return
          }
          add(entry, to: &listing, top: &top, excluded: excluded, shared: shared)
        }
      }
    }
    listing.files = top.files
    listing.unreadable = failed.isSet
    return listing
  }

  private static func add(
    _ entry: URL, to listing: inout Listing, top: inout TopFiles, excluded: Set<String>, shared: ScanShared
  ) {
    guard let values = try? entry.resourceValues(forKeys: entryKeySet) else { return }
    let isLink = values.isSymbolicLink == true
    if values.isDirectory == true, !isLink {
      // A mount point inside the tree is another volume: leave it out.
      if values.isVolume == true { return }
      let name = entry.lastPathComponent
      if excluded.contains(name) { return }
      let isPackage = (try? entry.resourceValues(forKeys: packageKeySet))?.isPackage == true
      listing.subfolders.append(Subfolder(name: name, url: entry, isPackage: isPackage))
      return
    }

    var size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    if !isLink, let links = values.linkCount, links > 1, !shared.claimHardLink(at: entry) {
      size = 0
    }
    listing.fileCount += 1
    listing.fileBytes += size
    if top.keeps(size) {
      if let dropped = top.insert(DiskFile(name: entry.lastPathComponent, size: size)) {
        listing.smallerCount += 1
        listing.smallerSize += dropped.size
      }
    } else {
      listing.smallerCount += 1
      listing.smallerSize += size
    }
  }
}

/// State shared by all workers of one scan.
nonisolated final class ScanShared: Sendable {
  private struct FileKey: Hashable, Sendable {
    let device: Int32
    let inode: UInt64
  }

  private let cancelled = OSAllocatedUnfairLock(initialState: false)
  private let hardLinks = OSAllocatedUnfairLock(initialState: Set<FileKey>())

  var isCancelled: Bool { cancelled.withLock { $0 } }

  func cancel() {
    cancelled.withLock { $0 = true }
  }

  /// True the first time a hard-linked file is seen; later links to it count as zero bytes.
  func claimHardLink(at url: URL) -> Bool {
    var info = stat()
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return lstat(path, &info)
    }
    guard result == 0 else { return true }
    let key = FileKey(device: info.st_dev, inode: info.st_ino)
    return hardLinks.withLock { $0.insert(key).inserted }
  }
}

/// A flag set from the enumerator's error handler.
nonisolated private final class Flag {
  private(set) var isSet = false
  func set() { isSet = true }
}

/// Keeps the largest `capacity` files of a folder in a min-heap.
nonisolated struct TopFiles {
  let capacity: Int
  private var heap: [DiskFile] = []

  init(capacity: Int) {
    self.capacity = capacity
  }

  var files: [DiskFile] { heap }

  /// Whether a file of this size would be kept (checked before building its name).
  func keeps(_ size: Int64) -> Bool {
    heap.count < capacity || size > heap[0].size
  }

  /// Adds a file and returns the one pushed out, if any.
  mutating func insert(_ file: DiskFile) -> DiskFile? {
    if heap.count < capacity {
      heap.append(file)
      siftUp(heap.count - 1)
      return nil
    }
    guard file.size > heap[0].size else { return file }
    let dropped = heap[0]
    heap[0] = file
    siftDown(0)
    return dropped
  }

  private mutating func siftUp(_ index: Int) {
    var child = index
    while child > 0 {
      let parent = (child - 1) / 2
      guard heap[child].size < heap[parent].size else { return }
      heap.swapAt(child, parent)
      child = parent
    }
  }

  private mutating func siftDown(_ index: Int) {
    var parent = index
    while true {
      let left = parent * 2 + 1
      let right = left + 1
      var smallest = parent
      if left < heap.count, heap[left].size < heap[smallest].size { smallest = left }
      if right < heap.count, heap[right].size < heap[smallest].size { smallest = right }
      guard smallest != parent else { return }
      heap.swapAt(parent, smallest)
      parent = smallest
    }
  }
}
