import CoreServices
import Darwin
import Foundation
import UniformTypeIdentifiers

/// What "unchanged" means for the history: same modification time and size.
nonisolated struct FileSignature: Codable, Hashable, Sendable {
  var modified: Double
  var size: Int64
}

/// The attributes of one file or folder, read once and cached for a rule pass.
/// Expensive values (folder size, tags, Spotlight data) are read only when a rule asks.
nonisolated final class FileInfo {
  let url: URL
  let fullName: String
  let name: String
  let ext: String
  let isDirectory: Bool
  let isPackage: Bool
  /// Volume and inode, stable across renames and moves on the same volume.
  let identity: String
  let modified: Date?
  /// Last status change (data, name or attributes), from `stat`.
  let changed: Date?
  let created: Date?
  let added: Date?
  private let fileSize: Int64
  private let contentType: UTType?

  init?(url: URL) {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    let fresh = URL(fileURLWithPath: url.path)
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey, .isPackageKey, .contentModificationDateKey, .creationDateKey,
      .addedToDirectoryDateKey, .fileSizeKey, .contentTypeKey,
    ]
    let values = try? fresh.resourceValues(forKeys: keys)
    self.url = fresh
    fullName = fresh.lastPathComponent
    isDirectory = values?.isDirectory ?? ((info.st_mode & S_IFMT) == S_IFDIR)
    isPackage = values?.isPackage ?? false
    if isDirectory && !isPackage {
      name = fullName
      ext = ""
    } else {
      name = fresh.deletingPathExtension().lastPathComponent
      ext = fresh.pathExtension
    }
    identity = "\(info.st_dev):\(info.st_ino)"
    modified = values?.contentModificationDate ?? Date(timeIntervalSince1970: Self.seconds(info.st_mtimespec))
    changed = Date(timeIntervalSince1970: Self.seconds(info.st_ctimespec))
    created = values?.creationDate
    // Some volumes don't record the date added; the creation date is the closest stand-in.
    added = values?.addedToDirectoryDate ?? values?.creationDate
    fileSize = Int64(values?.fileSize ?? Int(info.st_size))
    contentType = values?.contentType
  }

  private static func seconds(_ time: timespec) -> Double {
    Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
  }

  var signature: FileSignature {
    FileSignature(modified: (modified?.timeIntervalSince1970 ?? 0).rounded(), size: isDirectory ? 0 : fileSize)
  }

  /// Size in bytes; folders and packages are added up (only when a rule asks).
  private(set) lazy var size: Int64 = isDirectory ? FileOps.allocatedSize(of: url) : fileSize

  private(set) lazy var kind: FileKindValue = FileKindValue.detect(
    contentType: contentType, ext: ext, isDirectory: isDirectory, isPackage: isPackage
  )

  private(set) lazy var tags: [String] = {
    (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
  }()

  /// The "Where from" list Safari, Chrome, Mail and AirDrop record on downloads.
  private(set) lazy var whereFroms: [String] = Self.readWhereFroms(url.path)

  /// The site the file came from, like "github.com".
  var sourceDomain: String? {
    for string in whereFroms {
      if let host = URL(string: string)?.host(), !host.isEmpty {
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
      }
    }
    return nil
  }

  /// Last opened, as Spotlight records it; nil if never opened.
  private(set) lazy var lastOpened: Date? = {
    guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
    return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
  }()

  enum BusyReason: Equatable {
    /// Changed a moment ago; settled after `remaining` seconds.
    case settling(remaining: TimeInterval)
    /// A Finder copy in progress; Finder fixes the date when it's done, which FSEvents reports.
    case copying
  }

  /// Why the file should be left alone for now, or nil if it's ready.
  func busyReason(now: Date) -> BusyReason? {
    // Finder gives files it is still copying a creation date of 24 January 1984.
    if let created, abs(created.timeIntervalSince1970 - 443_779_200) < 86_400 { return .copying }
    var remaining: TimeInterval = 0
    for date in [modified, changed].compactMap({ $0 }) {
      let age = now.timeIntervalSince(date)
      if age > -1 && age < FileOps.settleSeconds { remaining = max(remaining, FileOps.settleSeconds - age) }
    }
    return remaining > 0 ? .settling(remaining: remaining) : nil
  }

  private static func readWhereFroms(_ path: String) -> [String] {
    let attribute = "com.apple.metadata:kMDItemWhereFroms"
    let length = getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
    guard length > 0 else { return [] }
    var data = Data(count: length)
    let read = data.withUnsafeMutableBytes { buffer in
      getxattr(path, attribute, buffer.baseAddress, length, 0, XATTR_NOFOLLOW)
    }
    guard read > 0 else { return [] }
    let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
    if let list = plist as? [String] { return list.filter { !$0.isEmpty } }
    if let single = plist as? String, !single.isEmpty { return [single] }
    return []
  }
}

nonisolated extension FileKindValue {
  static func detect(contentType: UTType?, ext: String, isDirectory: Bool, isPackage: Bool) -> FileKindValue {
    if isDirectory && !isPackage { return .folder }
    let type = contentType ?? UTType(filenameExtension: ext.lowercased())
    guard let type else { return .other }
    if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return .application }
    if type.conforms(to: .pdf) { return .pdf }
    // Disk images also conform to public.archive, so they go first.
    if type.conforms(to: .diskImage) { return .diskImage }
    if type.conforms(to: .image) { return .image }
    if type.conforms(to: .audio) { return .audio }
    if type.conforms(to: .movie) || type.conforms(to: .video) { return .movie }
    if type.conforms(to: .archive) || FileOps.archiveExtensions.contains(ext.lowercased()) { return .archive }
    if type.conforms(to: .text) { return .text }
    return .other
  }
}

// MARK: - File helpers

nonisolated enum FileOps {
  /// Files changed more recently than this are left for the next pass.
  static let settleSeconds: TimeInterval = 3

  /// Extensions of downloads and copies that aren't finished yet.
  static let partialExtensions: Set<String> = [
    "download", "crdownload", "part", "partial", "tmp", "opdownload", "filepart",
  ]

  static let archiveExtensions: Set<String> = [
    "zip", "tar", "tgz", "tbz", "tbz2", "txz", "gz", "bz2", "xz", "7z", "xar",
  ]

  /// Hidden files, Finder files, Office lock files and unfinished downloads are never touched.
  static func isIgnored(name: String) -> Bool {
    if name.hasPrefix(".") || name.hasPrefix("~$") || name == "Icon\r" { return true }
    let ext = (name as NSString).pathExtension.lowercased()
    return partialExtensions.contains(ext)
  }

  /// Items a pass looks at: the folder's top level, or everything below it with subfolders on.
  /// Deeper items come first, so a folder's contents are handled before the folder itself.
  static func candidates(in folder: WatchedFolder, limit: Int = 20_000) -> [URL] {
    let fm = FileManager.default
    let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
    var result: [URL] = []
    if folder.includeSubfolders {
      guard let enumerator = fm.enumerator(at: folder.url, includingPropertiesForKeys: keys,
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
      while let url = enumerator.nextObject() as? URL, result.count < limit {
        if isIgnored(name: url.lastPathComponent) {
          enumerator.skipDescendants()
          continue
        }
        result.append(url)
      }
      return result.sorted { lhs, rhs in
        let left = lhs.pathComponents.count, right = rhs.pathComponents.count
        return left != right ? left > right : lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
      }
    }
    let items = (try? fm.contentsOfDirectory(at: folder.url, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles])) ?? []
    result = items.filter { !isIgnored(name: $0.lastPathComponent) }
    return Array(result.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
      .prefix(limit))
  }

  /// Items to look at after FSEvents reported `paths`: the changed items themselves (a package
  /// stands for anything inside it) and, with subfolders on, everything in a changed folder.
  /// Nil means "scan the whole folder", for when the watched folder itself changed.
  static func candidates(in folder: WatchedFolder, near paths: Set<String>, limit: Int = 20_000) -> [URL]? {
    let root = canonicalPath(folder.path)
    let rootLower = root.lowercased()
    var result: [URL] = []
    var seen = Set<String>()
    func append(_ url: URL) {
      if result.count < limit, seen.insert(url.path.lowercased()).inserted { result.append(url) }
    }
    for path in paths {
      let lower = path.lowercased()
      if lower == rootLower { return nil }
      guard lower.hasPrefix(rootLower + "/"), path.count > root.count + 1 else { continue }
      let components = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
      guard !components.isEmpty, !components.contains(where: isIgnored(name:)),
            folder.includeSubfolders || components.count == 1 else { continue }
      var url = URL(fileURLWithPath: root, isDirectory: true)
      var item: URL?
      for component in components {
        url.appendPathComponent(component)
        guard exists(url) else {
          item = nil
          break
        }
        item = url
        if isPackage(url) { break }
      }
      guard let item else { continue }
      if folder.includeSubfolders, isDirectory(item), !isPackage(item) {
        let enumerator = FileManager.default.enumerator(at: item, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let inner = enumerator?.nextObject() as? URL {
          if isIgnored(name: inner.lastPathComponent) {
            enumerator?.skipDescendants()
            continue
          }
          append(inner)
        }
      }
      append(item)
    }
    return result.sorted { lhs, rhs in
      let left = lhs.pathComponents.count, right = rhs.pathComponents.count
      return left != right ? left > right : lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }
  }

  static func isPackage(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
  }

  static func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
  }

  static func exists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
  }

  /// The real path, for comparing folders (`/tmp` and `/private/tmp` are the same).
  static func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
    canonicalPath(lhs.path).lowercased() == canonicalPath(rhs.path).lowercased()
  }

  /// Whether `url` is `folder` or somewhere inside it.
  static func isInside(_ url: URL, _ folder: URL) -> Bool {
    let path = canonicalPath(url.path).lowercased()
    let root = canonicalPath(folder.path).lowercased()
    return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
  }

  /// `name` in `folder`, or `name 2`, `name 3`… like Finder when it's taken.
  static func uniqueURL(in folder: URL, fullName: String, isFolder: Bool = false) -> URL {
    var url = folder.appendingPathComponent(fullName, isDirectory: isFolder)
    guard exists(url) else { return url }
    let base = isFolder ? fullName : (fullName as NSString).deletingPathExtension
    let ext = isFolder ? "" : (fullName as NSString).pathExtension
    var counter = 2
    repeat {
      let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
      url = folder.appendingPathComponent(candidate, isDirectory: isFolder)
      counter += 1
    } while exists(url)
    return url
  }

  /// A safe single path component: no slashes or colons, no control characters, not too long.
  static func sanitizedName(_ name: String) -> String {
    var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    cleaned = String(cleaned.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    while cleaned.utf8.count > 255 { cleaned.removeLast() }
    return cleaned
  }

  /// The archive name without archive extensions: "photos.tar.gz" → "photos".
  static func archiveBaseName(_ fullName: String) -> String {
    var name = fullName
    for _ in 0..<2 {
      let ext = (name as NSString).pathExtension.lowercased()
      guard archiveExtensions.contains(ext) else { break }
      name = (name as NSString).deletingPathExtension
    }
    return name.isEmpty ? fullName : name
  }

  /// Bytes on disk of a file or everything inside a folder.
  static func allocatedSize(of url: URL, limit: Int = 200_000) -> Int64 {
    let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
    if let values = try? url.resourceValues(forKeys: keys), values.isDirectory != true {
      return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
    guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                          options: [], errorHandler: { _, _ in true }) else { return 0 }
    var total: Int64 = 0
    var count = 0
    while let item = enumerator.nextObject() as? URL, count < limit {
      count += 1
      if let values = try? item.resourceValues(forKeys: keys) {
        total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
      }
    }
    return total
  }
}
