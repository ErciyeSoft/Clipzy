import CoreServices
import Foundation

/// Watches folders with FSEvents (file-level events) and hands the changed paths to
/// `handler` on a background queue. All stream state lives on that queue.
nonisolated final class FolderWatcher: @unchecked Sendable {
  private let latency: CFTimeInterval
  private let fileEvents: Bool
  private let handler: @Sendable ([String]) -> Void
  private let queue = DispatchQueue(label: "com.erciyesoft.Kitzi.FolderWatcher", qos: .utility)
  private var stream: FSEventStreamRef?
  private var paths: [String] = []

  /// With `fileEvents` off, FSEvents reports only the folders that changed, which is
  /// plenty for the Applications folders and much quieter during app installs.
  init(latency: CFTimeInterval, fileEvents: Bool = true, handler: @escaping @Sendable ([String]) -> Void) {
    self.latency = latency
    self.fileEvents = fileEvents
    self.handler = handler
  }

  deinit {
    if let stream { Self.close(stream) }
  }

  /// Watches exactly these folders; restarts the stream only when the set changes.
  func watch(_ newPaths: [String]) {
    let sorted = Array(Set(newPaths.map(FileOps.canonicalPath))).sorted()
    queue.async { [self] in
      guard sorted != paths || (stream == nil && !sorted.isEmpty) else { return }
      if let stream {
        Self.close(stream)
        self.stream = nil
      }
      paths = sorted
      if !sorted.isEmpty { open() }
    }
  }

  func stop() {
    watch([])
  }

  private func open() {
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
    )
    let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
      guard let info else { return }
      let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
      let array = unsafeBitCast(eventPaths, to: NSArray.self)
      let paths = (0..<min(count, array.count)).compactMap { array[$0] as? String }
      if !paths.isEmpty { watcher.handler(paths) }
    }
    var flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
    if fileEvents { flags |= FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents) }
    guard let created = FSEventStreamCreate(
      kCFAllocatorDefault, callback, &context, paths as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
    ) else { return }
    FSEventStreamSetDispatchQueue(created, queue)
    guard FSEventStreamStart(created) else {
      FSEventStreamInvalidate(created)
      FSEventStreamRelease(created)
      return
    }
    stream = created
  }

  private static func close(_ stream: FSEventStreamRef) {
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }
}
