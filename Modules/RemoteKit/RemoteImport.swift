import AppKit
import Foundation
import SQLite3

/// A PC read from Windows App or an .rdp file, before it becomes a `RemoteDevice`.
nonisolated struct RemoteImportedDevice: Sendable {
  var address: String
  var friendlyName: String
  var groupName: String?
  var username: String?
  var gatewayAddress: String?
  var gatewayUsername: String?
  var isFavorite = false
  var adminMode = false
  var display: RemoteDisplaySettings?
  var redirection: RemoteRedirection?
  var extraRDP = ""
  var thumbnailPNG: Data?
}

nonisolated enum RemoteImportError: LocalizedError {
  case notInstalled
  case unreadable(String)
  case invalidFile

  var errorDescription: String? {
    switch self {
    case .notInstalled:
      String(localized: "Windows App has no saved PCs on this Mac.")
    case .unreadable(let detail):
      String(localized: "Windows App's saved PCs couldn't be read: \(detail)")
    case .invalidFile:
      String(localized: "This isn't a Remote Desktop (.rdp) file with a PC address.")
    }
  }
}

/// Reads the PCs saved in Microsoft's Windows App (formerly Microsoft Remote Desktop).
/// Passwords stay in Windows App's own keychain items and are never read.
nonisolated enum WindowsAppImporter {
  static var databaseURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Containers/com.microsoft.rdc.macos/Data/Library/Application Support")
      .appendingPathComponent("com.microsoft.rdc.macos/com.microsoft.rdc.application-data.sqlite")
  }

  static var isAvailable: Bool {
    FileManager.default.fileExists(atPath: databaseURL.path)
  }

  static func read() throws -> [RemoteImportedDevice] {
    let fm = FileManager.default
    guard fm.fileExists(atPath: databaseURL.path) else { throw RemoteImportError.notInstalled }

    // Work on a copy that includes the write-ahead log, so recent changes are there and the
    // live database is never touched.
    let temp = fm.temporaryDirectory.appendingPathComponent("KitziWindowsAppImport-\(UUID().uuidString)")
    try fm.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: temp) }
    let copy = temp.appendingPathComponent(databaseURL.lastPathComponent)
    do {
      try fm.copyItem(at: databaseURL, to: copy)
      for suffix in ["-wal", "-shm"] {
        let source = URL(fileURLWithPath: databaseURL.path + suffix)
        if fm.fileExists(atPath: source.path) {
          try fm.copyItem(at: source, to: URL(fileURLWithPath: copy.path + suffix))
        }
      }
    } catch {
      throw RemoteImportError.unreadable(error.localizedDescription)
    }

    var db: OpaquePointer?
    guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
      throw RemoteImportError.unreadable(String(cString: sqlite3_errstr(sqlite3_errcode(db))))
    }
    defer { sqlite3_close(db) }

    let favorites = pinnedDeviceIDs(db)
    let sql = """
      SELECT b.ZFRIENDLYNAME, b.ZHOSTNAME, f.ZTITLE, c.ZUSERNAME, g.ZHOSTNAME, gc.ZUSERNAME,
             b.ZADMINMODE, b.ZDYNAMICRESOLUTIONENABLED, b.ZENABLERETINA, b.ZSCREENTYPEWIDTH,
             b.ZSCREENTYPEHEIGHT, b.ZAUDIOPLAYBACKENUM, b.ZPASTEBOARDREDIRECTIONENABLED,
             b.ZTHUMBNAILIMAGE, b.ZID
      FROM ZBOOKMARKENTITY b
      LEFT JOIN ZBOOKMARKFOLDERENTITY f ON f.Z_PK = b.ZBOOKMARKFOLDER
      LEFT JOIN ZCREDENTIALENTITY c ON c.Z_PK = b.ZCREDENTIAL
      LEFT JOIN ZGATEWAYENTITY g ON g.Z_PK = b.ZGATEWAY
      LEFT JOIN ZCREDENTIALENTITY gc ON gc.Z_PK = g.ZCREDENTIAL
      ORDER BY f.ZTITLE, b.ZFRIENDLYNAME
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw RemoteImportError.unreadable(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }

    var result: [RemoteImportedDevice] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let host = text(statement, 1), !host.isEmpty else { continue }
      var item = RemoteImportedDevice(address: host, friendlyName: text(statement, 0) ?? host)
      item.groupName = text(statement, 2)
      item.username = text(statement, 3)
      item.gatewayAddress = text(statement, 4)
      item.gatewayUsername = text(statement, 5)
      item.adminMode = sqlite3_column_int(statement, 6) != 0

      var display = RemoteDisplaySettings()
      display.retina = sqlite3_column_int(statement, 8) != 0
      let width = Int(sqlite3_column_int(statement, 9))
      let height = Int(sqlite3_column_int(statement, 10))
      if sqlite3_column_int(statement, 7) == 0, width > 0, height > 0 {
        display.resolution = .fixed(width: width, height: height)
      }
      item.display = display

      var redirection = RemoteRedirection()
      // 0 plays sound on this Mac, 1 on the PC, 2 nowhere.
      redirection.audio = sqlite3_column_int(statement, 11) == 0
      redirection.clipboard = sqlite3_column_type(statement, 12) == SQLITE_NULL
        || sqlite3_column_int(statement, 12) != 0
      item.redirection = redirection

      item.thumbnailPNG = pngData(blob(statement, 13))
      if let id = text(statement, 14) { item.isFavorite = favorites.contains(id.uppercased()) }
      result.append(item)
    }
    return result
  }

  /// IDs of the PCs pinned to Favorites, from the archived PinnedResourceEntity list.
  private static func pinnedDeviceIDs(_ db: OpaquePointer) -> Set<String> {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT ZPINNEDDEVICES FROM ZPINNEDRESOURCESENTITY", -1, &statement, nil) == SQLITE_OK,
          let statement else { return [] }
    defer { sqlite3_finalize(statement) }
    var ids: Set<String> = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let data = blob(statement, 0),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let objects = plist["$objects"] as? [Any] else { continue }
      for case let string as String in objects where UUID(uuidString: string) != nil {
        ids.insert(string.uppercased())
      }
    }
    return ids
  }

  private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
    guard let pointer = sqlite3_column_text(statement, column) else { return nil }
    let value = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  private static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
    guard let pointer = sqlite3_column_blob(statement, column) else { return nil }
    let count = Int(sqlite3_column_bytes(statement, column))
    return count > 0 ? Data(bytes: pointer, count: count) : nil
  }

  private static func pngData(_ data: Data?) -> Data? {
    guard let data else { return nil }
    if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
    guard let image = NSImage(data: data), let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
  }
}

/// Reads and writes Remote Desktop (.rdp) files.
nonisolated enum RDPFile {
  /// Keys Kitzi keeps in its own fields; the rest of an imported file is kept as is.
  private static let managedKeys: Set<String> = [
    "full address", "alternate full address", "server port", "username", "domain",
    "password 51", "gatewayhostname", "gatewayusagemethod", "gatewayusername",
    "gatewaycredentialssource", "promptcredentialonce", "desktopwidth", "desktopheight",
    "screen mode id", "dynamic resolution", "smart sizing", "audiomode", "redirectclipboard",
    "drivestoredirect", "administrative session", "forcehidpioptimizations", "use multimon",
    "selectedmonitors", "winposstr",
  ]

  static func parse(_ text: String, name: String) throws -> RemoteImportedDevice {
    var values: [String: String] = [:]
    var extra: [String] = []
    for rawLine in text.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
      guard parts.count == 3 else { continue }
      let key = parts[0].lowercased()
      values[key] = String(parts[2])
      if !managedKeys.contains(key) { extra.append(line) }
    }
    guard var address = values["full address"]?.trimmingCharacters(in: .whitespaces), !address.isEmpty else {
      throw RemoteImportError.invalidFile
    }
    if let port = values["server port"], port != "3389", !address.contains(":") {
      address += ":\(port)"
    }

    var item = RemoteImportedDevice(address: address, friendlyName: name)
    if let user = values["username"], !user.isEmpty {
      if let domain = values["domain"], !domain.isEmpty, !user.contains("\\"), !user.contains("@") {
        item.username = "\(domain)\\\(user)"
      } else {
        item.username = user
      }
    }
    if let gateway = values["gatewayhostname"], !gateway.isEmpty, values["gatewayusagemethod"] != "0" {
      item.gatewayAddress = gateway
      item.gatewayUsername = values["gatewayusername"]
    }
    item.adminMode = values["administrative session"] == "1"

    var display = RemoteDisplaySettings()
    if values["dynamic resolution"] == "0",
       let w = Int(values["desktopwidth"] ?? ""), let h = Int(values["desktopheight"] ?? ""), w > 0, h > 0 {
      display.resolution = .fixed(width: w, height: h)
    }
    display.retina = values["forcehidpioptimizations"] == "1"
    display.startFullScreen = values["screen mode id"] == "2"
    item.display = display

    var redirection = RemoteRedirection()
    redirection.audio = (values["audiomode"] ?? "0") == "0"
    redirection.clipboard = values["redirectclipboard"] != "0"
    if let drives = values["drivestoredirect"], !drives.isEmpty {
      redirection.folder = .home
    }
    item.redirection = redirection
    item.extraRDP = extra.joined(separator: "\n")
    return item
  }

  static func read(_ url: URL) throws -> RemoteImportedDevice {
    let data = try Data(contentsOf: url)
    // Windows writes .rdp files as UTF-16 with a byte order mark; others use UTF-8.
    let isUTF16 = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
    let text = (isUTF16 ? String(data: data, encoding: .utf16) : String(data: data, encoding: .utf8))
      ?? String(decoding: data, as: UTF8.self)
    return try parse(text, name: url.deletingPathExtension().lastPathComponent)
  }

  /// A file Windows' Remote Desktop Connection and Windows App can open.
  static func export(_ device: RemoteDevice, account: RemoteAccount?, gatewayAccount: RemoteAccount?) -> String {
    var lines: [String] = []
    lines.append("full address:s:\(device.address)")
    if let account { lines.append("username:s:\(account.username)") }
    lines.append("prompt for credentials on client:i:0")
    lines.append("administrative session:i:\(device.adminMode ? 1 : 0)")
    switch device.display.resolution {
    case .matchWindow:
      lines.append("dynamic resolution:i:1")
    case .fixed(let width, let height):
      lines.append("dynamic resolution:i:0")
      lines.append("desktopwidth:i:\(width)")
      lines.append("desktopheight:i:\(height)")
    }
    lines.append("screen mode id:i:\(device.display.startFullScreen ? 2 : 1)")
    lines.append("forcehidpioptimizations:i:\(device.display.retina ? 1 : 0)")
    lines.append("audiomode:i:\(device.redirection.audio ? 0 : 2)")
    lines.append("redirectclipboard:i:\(device.redirection.clipboard ? 1 : 0)")
    if device.gateway.isEnabled {
      lines.append("gatewayhostname:s:\(device.gateway.address)")
      lines.append("gatewayusagemethod:i:1")
      if !device.gateway.useSameAccount, let gatewayAccount {
        lines.append("gatewayusername:s:\(gatewayAccount.username)")
      }
      lines.append("promptcredentialonce:i:\(device.gateway.useSameAccount ? 1 : 0)")
    }
    let extra = device.extraRDP.trimmingCharacters(in: .whitespacesAndNewlines)
    if !extra.isEmpty { lines.append(extra) }
    return lines.joined(separator: "\r\n") + "\r\n"
  }
}
