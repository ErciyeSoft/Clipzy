import AppKit
import Foundation
import Observation
import Security

/// Where Remote Desktop keeps its files.
nonisolated enum RemotePaths {
  static var directory: URL {
    #if DEBUG
    // Test hook: keeps test runs out of the real library.
    if let path = UserDefaults.standard.string(forKey: "RemoteDesktopDataDirectory") {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    #endif
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Kitzi", isDirectory: true)
      .appendingPathComponent("RemoteDesktop", isDirectory: true)
  }

  static var libraryFile: URL { directory.appendingPathComponent("library.json") }
  static var thumbnails: URL { directory.appendingPathComponent("Thumbnails", isDirectory: true) }
  /// FreeRDP's own files: the certificates you chose to trust.
  static var freeRDP: URL { directory.appendingPathComponent("FreeRDP", isDirectory: true) }

  static func thumbnail(for id: UUID) -> URL {
    thumbnails.appendingPathComponent("\(id.uuidString).png")
  }
}

/// Passwords of user accounts, in the login keychain.
nonisolated enum RemoteKeychain {
  private static let service = "com.erciyesoft.Kitzi.RemoteDesktop"

  static func password(for accountID: UUID) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: accountID.uuidString,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func setPassword(_ password: String?, for accountID: UUID, label: String) {
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: accountID.uuidString,
    ]
    guard let password, !password.isEmpty else {
      SecItemDelete(base as CFDictionary)
      return
    }
    let data = Data(password.utf8)
    let update: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: label]
    if SecItemUpdate(base as CFDictionary, update as CFDictionary) == errSecItemNotFound {
      var add = base
      add[kSecValueData as String] = data
      add[kSecAttrLabel as String] = label
      add[kSecAttrDescription as String] = "Kitzi Remote Desktop"
      SecItemAdd(add as CFDictionary, nil)
    }
  }
}

/// The saved PCs, groups and accounts. Every change is written to library.json.
@Observable
final class RemoteStore {
  static let shared = RemoteStore()

  private(set) var devices: [RemoteDevice] = []
  private(set) var groups: [RemoteGroup] = []
  private(set) var accounts: [RemoteAccount] = []
  /// Bumped when a thumbnail file changes so views reload it.
  private(set) var thumbnailRevision = 0
  private(set) var loadProblem: String?

  private init() {
    load()
  }

  // MARK: Loading and saving

  private func load() {
    let url = RemotePaths.libraryFile
    guard let data = try? Data(contentsOf: url) else { return }
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let library = try decoder.decode(RemoteLibrary.self, from: data)
      devices = library.devices
      groups = library.groups
      accounts = library.accounts
    } catch {
      // Keep the unreadable file instead of overwriting it with an empty list.
      let stamp = Int(Date().timeIntervalSince1970)
      let backup = RemotePaths.directory.appendingPathComponent("library-unreadable-\(stamp).json")
      try? FileManager.default.moveItem(at: url, to: backup)
      loadProblem = String(localized: "Your saved PCs couldn't be read. The file was kept as \(backup.lastPathComponent).")
    }
  }

  private func save() {
    let library = RemoteLibrary(devices: devices, groups: groups, accounts: accounts)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(library) else { return }
    try? FileManager.default.createDirectory(at: RemotePaths.directory, withIntermediateDirectories: true)
    try? data.write(to: RemotePaths.libraryFile, options: .atomic)
  }

  // MARK: Devices

  func device(_ id: UUID) -> RemoteDevice? {
    devices.first { $0.id == id }
  }

  func upsert(_ device: RemoteDevice) {
    if let index = devices.firstIndex(where: { $0.id == device.id }) {
      devices[index] = device
    } else {
      devices.append(device)
    }
    save()
  }

  func duplicate(_ id: UUID) {
    guard var copy = device(id) else { return }
    copy.id = UUID()
    copy.friendlyName = String(localized: "\(copy.displayName) copy")
    copy.lastConnected = nil
    copy.createdAt = Date()
    devices.append(copy)
    save()
  }

  func delete(_ ids: Set<UUID>) {
    devices.removeAll { ids.contains($0.id) }
    for id in ids {
      try? FileManager.default.removeItem(at: RemotePaths.thumbnail(for: id))
    }
    save()
  }

  func toggleFavorite(_ id: UUID) {
    guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
    devices[index].isFavorite.toggle()
    save()
  }

  func move(_ ids: Set<UUID>, to groupID: UUID?) {
    for index in devices.indices where ids.contains(devices[index].id) {
      devices[index].groupID = groupID
    }
    save()
  }

  func markConnected(_ id: UUID) {
    guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
    devices[index].lastConnected = Date()
    save()
  }

  // MARK: Thumbnails

  @ObservationIgnored private var thumbnailCache: [UUID: NSImage] = [:]
  @ObservationIgnored private var missingThumbnails: Set<UUID> = []

  func thumbnail(for id: UUID) -> NSImage? {
    _ = thumbnailRevision
    if let image = thumbnailCache[id] { return image }
    if missingThumbnails.contains(id) { return nil }
    guard let image = NSImage(contentsOf: RemotePaths.thumbnail(for: id)) else {
      missingThumbnails.insert(id)
      return nil
    }
    thumbnailCache[id] = image
    return image
  }

  private func thumbnailChanged(_ id: UUID) {
    thumbnailCache[id] = nil
    missingThumbnails.remove(id)
    thumbnailRevision += 1
  }

  /// Saves a small copy of the last picture of a session.
  func saveThumbnail(_ image: CGImage, for id: UUID) {
    let maxWidth = 480.0
    let scale = min(1, maxWidth / Double(image.width))
    let width = max(1, Int(Double(image.width) * scale))
    let height = max(1, Int(Double(image.height) * scale))
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let small = context.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: small)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? FileManager.default.createDirectory(at: RemotePaths.thumbnails, withIntermediateDirectories: true)
    try? png.write(to: RemotePaths.thumbnail(for: id), options: .atomic)
    thumbnailChanged(id)
  }

  fileprivate func saveThumbnailData(_ data: Data, for id: UUID) {
    try? FileManager.default.createDirectory(at: RemotePaths.thumbnails, withIntermediateDirectories: true)
    try? data.write(to: RemotePaths.thumbnail(for: id), options: .atomic)
    thumbnailChanged(id)
  }

  // MARK: Groups

  func group(_ id: UUID?) -> RemoteGroup? {
    guard let id else { return nil }
    return groups.first { $0.id == id }
  }

  @discardableResult
  func addGroup(named name: String) -> RemoteGroup {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    if let existing = groups.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
      return existing
    }
    let group = RemoteGroup(name: trimmed)
    groups.append(group)
    save()
    return group
  }

  func renameGroup(_ id: UUID, to name: String) {
    guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    groups[index].name = trimmed
    save()
  }

  /// Removes the group; its PCs stay, without a group.
  func deleteGroup(_ id: UUID) {
    groups.removeAll { $0.id == id }
    for index in devices.indices where devices[index].groupID == id {
      devices[index].groupID = nil
    }
    save()
  }

  func setGroupCollapsed(_ id: UUID, _ collapsed: Bool) {
    guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
    groups[index].isCollapsed = collapsed
    save()
  }

  // MARK: Accounts

  func account(_ id: UUID?) -> RemoteAccount? {
    guard let id else { return nil }
    return accounts.first { $0.id == id }
  }

  func upsert(_ account: RemoteAccount, password: String?) {
    if let index = accounts.firstIndex(where: { $0.id == account.id }) {
      accounts[index] = account
    } else {
      accounts.append(account)
    }
    if let password {
      RemoteKeychain.setPassword(password, for: account.id, label: "Kitzi: \(account.username)")
    }
    save()
  }

  /// Finds an account with this user name or creates one.
  func account(forUsername username: String) -> RemoteAccount {
    let trimmed = username.trimmingCharacters(in: .whitespaces)
    if let existing = accounts.first(where: { $0.username.caseInsensitiveCompare(trimmed) == .orderedSame }) {
      return existing
    }
    let account = RemoteAccount(username: trimmed)
    accounts.append(account)
    save()
    return account
  }

  func deleteAccount(_ id: UUID) {
    accounts.removeAll { $0.id == id }
    for index in devices.indices {
      if devices[index].accountID == id { devices[index].accountID = nil }
      if devices[index].gateway.accountID == id { devices[index].gateway.accountID = nil }
    }
    RemoteKeychain.setPassword(nil, for: id, label: "")
    save()
  }

  func usageCount(of accountID: UUID) -> Int {
    devices.filter { $0.accountID == accountID || $0.gateway.accountID == accountID }.count
  }

  // MARK: Import

  struct ImportResult {
    var added = 0
    var skipped = 0
  }

  /// Adds PCs read elsewhere, skipping ones already saved with the same address and account.
  func importDevices(_ items: [RemoteImportedDevice]) -> ImportResult {
    var result = ImportResult()
    for item in items {
      var device = RemoteDevice(address: item.address)
      device.friendlyName = item.friendlyName == item.address ? "" : item.friendlyName
      if let groupName = item.groupName, !groupName.isEmpty {
        device.groupID = addGroup(named: groupName).id
      }
      if let username = item.username, !username.isEmpty {
        device.accountID = account(forUsername: username).id
      }
      if let gateway = item.gatewayAddress, !gateway.isEmpty {
        device.gateway.address = gateway
        if let gatewayUser = item.gatewayUsername, !gatewayUser.isEmpty, gatewayUser != item.username {
          device.gateway.useSameAccount = false
          device.gateway.accountID = account(forUsername: gatewayUser).id
        }
      }
      device.isFavorite = item.isFavorite
      device.adminMode = item.adminMode
      if let display = item.display { device.display = display }
      if let redirection = item.redirection { device.redirection = redirection }
      device.extraRDP = item.extraRDP

      let duplicate = devices.contains {
        $0.address.caseInsensitiveCompare(device.address) == .orderedSame
          && $0.accountID == device.accountID
          && $0.displayName.caseInsensitiveCompare(device.displayName) == .orderedSame
      }
      if duplicate {
        result.skipped += 1
        continue
      }
      devices.append(device)
      if let thumbnail = item.thumbnailPNG {
        saveThumbnailData(thumbnail, for: device.id)
      }
      result.added += 1
    }
    save()
    return result
  }
}
