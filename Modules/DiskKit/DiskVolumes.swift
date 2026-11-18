import Foundation

/// A mounted volume with its capacity numbers.
nonisolated struct VolumeInfo: Identifiable, Sendable {
  let url: URL
  let name: String
  let total: Int64
  /// Free right now.
  let available: Int64
  /// Free once macOS purges what it can (snapshots, caches); never less than `available`.
  let availableForImportantUsage: Int64
  let isStartup: Bool

  var id: URL { url }
  /// Space macOS can free up on its own.
  var purgeable: Int64 { max(0, availableForImportantUsage - available) }
  /// Used and not purgeable.
  var used: Int64 { max(0, total - available - purgeable) }
  /// Everything that isn't free right now, purgeable included.
  var occupied: Int64 { max(0, total - available) }
}

/// Lists the volumes worth scanning and reads their capacity.
nonisolated enum DiskVolumes {
  private static let keys: [URLResourceKey] = [
    .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
    .volumeAvailableCapacityForImportantUsageKey, .volumeIsBrowsableKey, .volumeIsLocalKey,
    .volumeIsRootFileSystemKey,
  ]

  /// Local, visible volumes, the startup disk first. System volumes (/System/Volumes/*)
  /// and network shares are left out.
  @concurrent
  static func load() async -> [VolumeInfo] {
    let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
    let volumes = urls.compactMap { url -> VolumeInfo? in
      guard !url.path.hasPrefix("/System/Volumes/"),
            let values = try? url.resourceValues(forKeys: Set(keys)),
            values.volumeIsBrowsable != false,
            values.volumeIsLocal != false
      else { return nil }
      return info(url, values)
    }
    return volumes.sorted { lhs, rhs in
      if lhs.isStartup != rhs.isStartup { return lhs.isStartup }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
  }

  /// Fresh numbers for the volume rooted at `url` (resource values are cached per URL object).
  @concurrent
  static func freshInfo(for url: URL) async -> VolumeInfo? {
    let fresh = URL(fileURLWithPath: url.path, isDirectory: true)
    guard let values = try? fresh.resourceValues(forKeys: Set(keys)) else { return nil }
    return info(fresh, values)
  }

  private static func info(_ url: URL, _ values: URLResourceValues) -> VolumeInfo? {
    guard let total = values.volumeTotalCapacity, total > 0 else { return nil }
    let available = Int64(values.volumeAvailableCapacity ?? 0)
    let important = values.volumeAvailableCapacityForImportantUsage ?? available
    return VolumeInfo(
      url: url,
      name: values.volumeLocalizedName ?? FileManager.default.displayName(atPath: url.path),
      total: Int64(total),
      available: available,
      availableForImportantUsage: max(available, important),
      isStartup: values.volumeIsRootFileSystem == true
    )
  }
}

/// Moves files to the Trash off the main thread.
nonisolated enum DiskTrash {
  /// One entry per URL: nil when it went to the Trash, otherwise the reason it didn't.
  @concurrent
  static func moveToTrash(_ urls: [URL]) async -> [String?] {
    urls.map { url in
      do {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        return nil
      } catch {
        return error.localizedDescription
      }
    }
  }
}
