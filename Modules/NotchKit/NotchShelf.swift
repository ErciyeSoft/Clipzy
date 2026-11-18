import AppKit
import Observation
import QuickLookThumbnailing

/// A file kept on the shelf. The bookmark follows the file if it is moved or renamed.
struct ShelfItem: Codable, Identifiable, Equatable {
  var id = UUID()
  var bookmark: Data
  var path: String

  var url: URL { URL(fileURLWithPath: path) }
  var name: String { FileManager.default.displayName(atPath: path) }
}

/// Files dropped on the notch, kept until removed (also across restarts).
@Observable
final class NotchShelfModel {
  private(set) var items: [ShelfItem] = []

  init() {
    load()
  }

  func add(_ urls: [URL]) {
    var changed = false
    for url in urls where url.isFileURL {
      let standardized = url.standardizedFileURL
      guard !items.contains(where: { $0.path == standardized.path }),
            let bookmark = try? standardized.bookmarkData() else { continue }
      items.append(ShelfItem(bookmark: bookmark, path: standardized.path))
      changed = true
    }
    if changed { save() }
  }

  /// Saves dropped text as a file so it can be dragged out like any other item.
  func addText(_ text: String) {
    let folder = Self.textFolder
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    let cleaned = firstLine
      .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
      .joined()
      .trimmingCharacters(in: .whitespaces)
    let base = cleaned.isEmpty ? String(localized: "Text") : String(cleaned.prefix(40))
    var url = folder.appendingPathComponent(base).appendingPathExtension("txt")
    var counter = 2
    while FileManager.default.fileExists(atPath: url.path) {
      url = folder.appendingPathComponent("\(base) \(counter)").appendingPathExtension("txt")
      counter += 1
    }
    guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
    add([url])
  }

  func remove(_ item: ShelfItem) {
    items.removeAll { $0.id == item.id }
    deleteIfOurs(item)
    save()
  }

  func clear() {
    items.forEach(deleteIfOurs)
    items = []
    save()
  }

  func open(_ item: ShelfItem) {
    NSWorkspace.shared.open(item.url)
  }

  func reveal(_ item: ShelfItem) {
    NSWorkspace.shared.activateFileViewerSelecting([item.url])
  }

  func copy(_ item: ShelfItem) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects([item.url as NSURL])
  }

  /// Drops items whose file is gone and follows moved ones.
  func revalidate() {
    var changed = false
    items = items.compactMap { item in
      var stale = false
      guard let url = try? URL(resolvingBookmarkData: item.bookmark, bookmarkDataIsStale: &stale),
            FileManager.default.fileExists(atPath: url.path) else {
        changed = true
        return nil
      }
      var updated = item
      if url.path != item.path || stale {
        updated.path = url.path
        if let bookmark = try? url.bookmarkData() { updated.bookmark = bookmark }
        changed = true
      }
      return updated
    }
    if changed { save() }
  }

  // MARK: Storage

  /// Text drops are saved here; their files are deleted when they leave the shelf.
  private static var textFolder: URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("Kitzi/Shelf", isDirectory: true)
  }

  private func deleteIfOurs(_ item: ShelfItem) {
    guard item.url.deletingLastPathComponent().standardizedFileURL.path == Self.textFolder.standardizedFileURL.path else { return }
    try? FileManager.default.removeItem(at: item.url)
  }

  private func load() {
    guard let data = UserDefaults.standard.data(forKey: NotchPrefs.shelfItemsKey),
          let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
    items = decoded
    revalidate()
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(items) else { return }
    UserDefaults.standard.set(data, forKey: NotchPrefs.shelfItemsKey)
  }
}

/// Makes Quick Look thumbnails for shelf items, with the Finder icon as a fallback.
enum ShelfThumbnails {
  nonisolated private final class Box: @unchecked Sendable {
    var image: CGImage?
  }

  static func thumbnail(for url: URL, size: CGFloat) async -> NSImage {
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    let request = QLThumbnailGenerator.Request(
      fileAt: url, size: CGSize(width: size, height: size), scale: scale, representationTypes: .thumbnail
    )
    let box = await withCheckedContinuation { (continuation: CheckedContinuation<Box, Never>) in
      QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
        let box = Box()
        box.image = representation?.cgImage
        continuation.resume(returning: box)
      }
    }
    if let image = box.image {
      return NSImage(cgImage: image, size: CGSize(width: size, height: size))
    }
    return NSWorkspace.shared.icon(forFile: url.path)
  }
}
