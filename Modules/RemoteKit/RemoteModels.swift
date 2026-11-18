import Foundation

/// A saved PC: where to connect, as whom and how the session should look.
nonisolated struct RemoteDevice: Codable, Identifiable, Hashable, Sendable {
  var id = UUID()
  /// Host name or IP address, optionally with `:port`.
  var address: String
  /// Shown instead of the address when set.
  var friendlyName = ""
  var groupID: UUID?
  var accountID: UUID?
  var isFavorite = false
  var gateway = RemoteGateway()
  var display = RemoteDisplaySettings()
  var redirection = RemoteRedirection()
  /// Connect to the console (admin) session.
  var adminMode = false
  /// Settings from an imported .rdp file that have no field here; applied before the fields above.
  var extraRDP = ""
  var lastConnected: Date?
  var createdAt = Date()

  init(address: String) {
    self.address = address
  }

  var displayName: String {
    let name = friendlyName.trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? address : name
  }

  /// `address` split into host and port (3389 when none is given).
  var hostAndPort: (host: String, port: UInt16) {
    RemoteAddress.parse(address, defaultPort: 3389)
  }

  // Decode leniently so files written by newer versions still load.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    address = try c.decode(String.self, forKey: .address)
    friendlyName = try c.decodeIfPresent(String.self, forKey: .friendlyName) ?? ""
    groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
    accountID = try c.decodeIfPresent(UUID.self, forKey: .accountID)
    isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    gateway = try c.decodeIfPresent(RemoteGateway.self, forKey: .gateway) ?? RemoteGateway()
    display = try c.decodeIfPresent(RemoteDisplaySettings.self, forKey: .display) ?? RemoteDisplaySettings()
    redirection = try c.decodeIfPresent(RemoteRedirection.self, forKey: .redirection) ?? RemoteRedirection()
    adminMode = try c.decodeIfPresent(Bool.self, forKey: .adminMode) ?? false
    extraRDP = try c.decodeIfPresent(String.self, forKey: .extraRDP) ?? ""
    lastConnected = try c.decodeIfPresent(Date.self, forKey: .lastConnected)
    createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
  }
}

nonisolated enum RemoteAddress {
  /// Splits `host:port`, `[v6]:port` or a bare host.
  static func parse(_ value: String, defaultPort: UInt16) -> (host: String, port: UInt16) {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
      let host = String(text[text.index(after: text.startIndex)..<close])
      let rest = text[text.index(after: close)...]
      if rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) { return (host, port) }
      return (host, defaultPort)
    }
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    if parts.count == 2, let port = UInt16(parts[1]) {
      return (String(parts[0]), port)
    }
    return (text, defaultPort)
  }
}

nonisolated struct RemoteGateway: Codable, Hashable, Sendable {
  /// Empty when no RD Gateway is used.
  var address = ""
  var useSameAccount = true
  var accountID: UUID?

  var isEnabled: Bool { !address.trimmingCharacters(in: .whitespaces).isEmpty }
}

nonisolated struct RemoteDisplaySettings: Codable, Hashable, Sendable {
  enum Resolution: Codable, Hashable, Sendable {
    /// The desktop follows the window size.
    case matchWindow
    case fixed(width: Int, height: Int)
  }

  var resolution = Resolution.matchWindow
  /// Use every Retina pixel (sharper, with Windows scaled to 200%).
  var retina = false
  var startFullScreen = false

  static let fixedSizes: [(Int, Int)] = [
    (1280, 720), (1280, 800), (1366, 768), (1440, 900), (1600, 900), (1680, 1050),
    (1920, 1080), (1920, 1200), (2560, 1440), (2560, 1600), (3840, 2160),
  ]
}

nonisolated struct RemoteRedirection: Codable, Hashable, Sendable {
  enum Folder: Codable, Hashable, Sendable {
    case none
    case home
    case custom(path: String)
  }

  var audio = true
  var clipboard = true
  var folder = Folder.none
}

/// A user account that several PCs can share; its password lives in the keychain.
nonisolated struct RemoteAccount: Codable, Identifiable, Hashable, Sendable {
  var id = UUID()
  /// `DOMAIN\user`, `user@domain` or `user`.
  var username: String
  var friendlyName = ""

  var displayName: String {
    let name = friendlyName.trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? username : name
  }
}

/// A named section on the Devices page.
nonisolated struct RemoteGroup: Codable, Identifiable, Hashable, Sendable {
  var id = UUID()
  var name: String
  var isCollapsed = false
}

/// Everything the Remote Desktop window shows, as stored on disk.
nonisolated struct RemoteLibrary: Codable, Sendable {
  var devices: [RemoteDevice] = []
  var groups: [RemoteGroup] = []
  var accounts: [RemoteAccount] = []
}
