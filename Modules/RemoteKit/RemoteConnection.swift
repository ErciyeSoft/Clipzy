import AppKit
import Foundation
internal import RDPBridge

/// What the session reports, always on the main actor.
@MainActor
protocol RemoteConnectionDelegate: AnyObject {
  func connection(_ connection: RemoteConnection, changedTo state: RemoteConnection.State)
  func connectionHasNewFrame(_ connection: RemoteConnection)
  func connection(_ connection: RemoteConnection, resizedTo size: CGSize)
  func connection(_ connection: RemoteConnection, cursorChanged cursor: RemoteConnection.Cursor)
  func connection(_ connection: RemoteConnection, copiedText text: String)
  func connection(_ connection: RemoteConnection, needsCredentials request: RemoteConnection.CredentialRequest,
                  reply: @escaping (RemoteConnection.Credentials?) -> Void)
  func connection(_ connection: RemoteConnection, needsTrustFor certificate: RemoteConnection.Certificate,
                  reply: @escaping (RemoteConnection.TrustDecision) -> Void)
}

/// One RDP connection on FreeRDP. It runs on its own thread; this class turns the C callbacks
/// into main-actor delegate calls and answers FreeRDP's blocking questions.
nonisolated final class RemoteConnection: @unchecked Sendable {
  enum State: Equatable, Sendable {
    case connecting
    case connected
    case reconnecting
    case disconnected(EndReason, code: UInt32, detail: String?)
  }

  enum EndReason: Sendable {
    case none, userDisconnect, cancelled, authentication, passwordExpired, accountProblem
    case hostNotFound, unreachable, security, otherConnection, idleTimeout, serverDenied
    case networkLost, other

    init(_ value: RDPBEndReason) {
      switch value {
      case RDPBEndNone: self = .none
      case RDPBEndUserDisconnect: self = .userDisconnect
      case RDPBEndCancelled: self = .cancelled
      case RDPBEndAuthentication: self = .authentication
      case RDPBEndPasswordExpired: self = .passwordExpired
      case RDPBEndAccountProblem: self = .accountProblem
      case RDPBEndHostNotFound: self = .hostNotFound
      case RDPBEndUnreachable: self = .unreachable
      case RDPBEndSecurity: self = .security
      case RDPBEndOtherConnection: self = .otherConnection
      case RDPBEndIdleTimeout: self = .idleTimeout
      case RDPBEndServerDenied: self = .serverDenied
      case RDPBEndNetworkLost: self = .networkLost
      default: self = .other
      }
    }
  }

  enum Cursor: Sendable {
    case hidden
    case standard
    case image(CGImage, hotSpot: CGPoint)
  }

  struct CredentialRequest: Sendable {
    var gateway: Bool
    var username: String
    var domain: String
  }

  struct Credentials: Sendable {
    var username: String
    var domain: String
    var password: String
  }

  struct Certificate: Sendable {
    var host: String
    var port: UInt16
    var commonName: String
    var subject: String
    var issuer: String
    var fingerprint: String
    /// Set when the PC presents a different certificate than the one trusted before.
    var previousFingerprint: String?
    var hostMismatch: Bool
  }

  enum TrustDecision: Sendable {
    case reject, trustOnce, trustAlways
  }

  /// Everything needed to start; turned into an `RDPBConfig`.
  struct Configuration: Sendable {
    var host: String
    var port: UInt16
    var username: String?
    var password: String?
    var gatewayHost: String?
    var gatewayPort: UInt16 = 443
    var gatewayUseSameCredentials = true
    var gatewayUsername: String?
    var gatewayPassword: String?
    var rdpText: String?
    var width: Int
    var height: Int
    var desktopScale: Int = 100
    var keyboardLayout: UInt32 = 0
    var dynamicResolution = true
    var audio = true
    var clipboard = true
    var adminSession = false
    var sharedFolder: String?
    var sharedFolderName: String?
  }

  @MainActor weak var delegate: RemoteConnectionDelegate?

  private var session: OpaquePointer?
  private let lock = NSLock()
  private var pendingPrompts: [PendingPrompt] = []
  private var closed = false
  private var cursorImages: [UInt: (CGImage, CGPoint)] = [:]
  private var frameSize = CGSize.zero

  /// Returns nil when FreeRDP rejects the configuration (no host, for example).
  init?(configuration c: Configuration) {
    let strings = CStrings()
    defer { strings.free() }

    var config = RDPBConfig()
    config.host = strings.make(c.host)
    config.port = c.port
    config.username = strings.make(c.username)
    config.password = strings.make(c.password)
    config.gatewayHost = strings.make(c.gatewayHost)
    config.gatewayPort = c.gatewayPort
    config.gatewayUseSameCredentials = c.gatewayUseSameCredentials
    config.gatewayUsername = strings.make(c.gatewayUsername)
    config.gatewayPassword = strings.make(c.gatewayPassword)
    config.rdpFileText = strings.make(c.rdpText)
    try? FileManager.default.createDirectory(at: RemotePaths.freeRDP, withIntermediateDirectories: true)
    config.configDirectory = strings.make(RemotePaths.freeRDP.path)
    config.width = UInt32(max(200, c.width))
    config.height = UInt32(max(200, c.height))
    config.desktopScale = UInt32(c.desktopScale)
    config.deviceScale = 100
    config.keyboardLayout = c.keyboardLayout
    config.dynamicResolution = c.dynamicResolution
    config.audio = c.audio
    config.clipboard = c.clipboard
    config.adminSession = c.adminSession
    config.autoReconnect = true
    config.sharedFolderPath = strings.make(c.sharedFolder)
    config.sharedFolderName = strings.make(c.sharedFolderName)

    // The C side keeps an unretained pointer; `close()` balances this retain once no
    // callback can run anymore.
    let context = Unmanaged.passRetained(self).toOpaque()
    var callbacks = Self.callbacks()
    callbacks.context = context
    guard let created = RDPBSessionCreate(&config, &callbacks) else {
      Unmanaged<RemoteConnection>.fromOpaque(context).release()
      return nil
    }
    session = created
  }

  func start() -> Bool {
    lock.withLock { session.map { RDPBSessionStart($0) } ?? false }
  }

  /// Ends the session; safe to call more than once. Cleanup waits for the connection
  /// thread off the main thread.
  func close() {
    let (session, prompts): (OpaquePointer?, [PendingPrompt]) = lock.withLock {
      guard !closed else { return (nil, []) }
      closed = true
      let prompts = pendingPrompts
      pendingPrompts.removeAll()
      return (self.session, prompts)
    }
    guard let session else { return }
    prompts.forEach { $0.cancel() }
    RDPBSessionStop(session)
    let retained = Unmanaged.passUnretained(self)
    nonisolated(unsafe) let handle = session
    DispatchQueue.global(qos: .userInitiated).async {
      RDPBSessionFree(handle)
      retained.release()
    }
  }

  // MARK: Frames

  /// A copy of the desktop as it is now.
  func copyFrame() -> CGImage? {
    guard let session = lock.withLock({ closed ? nil : self.session }) else { return nil }
    var width: UInt32 = 0
    var height: UInt32 = 0
    if frameSize == .zero {
      _ = RDPBSessionCopyFrame(session, nil, 0, &width, &height)
      frameSize = CGSize(width: Int(width), height: Int(height))
    }
    // A second try covers a desktop that grew between the two calls.
    for _ in 0..<2 {
      let capacity = Int(frameSize.width) * Int(frameSize.height) * 4
      guard capacity > 0, let buffer = malloc(capacity) else { return nil }
      if RDPBSessionCopyFrame(session, buffer.assumingMemoryBound(to: UInt8.self), capacity, &width, &height) {
        frameSize = CGSize(width: Int(width), height: Int(height))
        let data = Data(bytesNoCopy: buffer, count: capacity, deallocator: .free)
        return Self.image(from: data, width: Int(width), height: Int(height))
      }
      free(buffer)
      guard width > 0, height > 0 else { return nil }
      frameSize = CGSize(width: Int(width), height: Int(height))
    }
    return nil
  }

  private static func image(from data: Data, width: Int, height: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
      decode: nil, shouldInterpolate: true, intent: .defaultIntent
    )
  }

  // MARK: Input (desktop pixel coordinates)

  private func withSession(_ body: (OpaquePointer) -> Void) {
    lock.lock()
    let session = closed ? nil : self.session
    lock.unlock()
    if let session { body(session) }
  }

  func mouseMove(_ point: CGPoint) {
    withSession { RDPBSessionMouseMove($0, Self.clamp(point.x), Self.clamp(point.y)) }
  }

  func mouseButton(_ button: Int, down: Bool, at point: CGPoint) {
    withSession { RDPBSessionMouseButton($0, Int32(button), down, Self.clamp(point.x), Self.clamp(point.y)) }
  }

  func wheel(horizontal: Bool, delta: Int, at point: CGPoint) {
    withSession { RDPBSessionMouseWheel($0, horizontal, Int32(delta), Self.clamp(point.x), Self.clamp(point.y)) }
  }

  func macKey(_ keyCode: UInt16, down: Bool, repeat isRepeat: Bool = false) {
    withSession { RDPBSessionMacKey($0, keyCode, down, isRepeat) }
  }

  func scanCode(_ code: UInt8, extended: Bool = false, down: Bool) {
    withSession { RDPBSessionScanCode($0, code, extended, down) }
  }

  func unicode(_ text: String) {
    withSession { session in
      for unit in text.utf16 {
        RDPBSessionUnicode(session, unit, true)
        RDPBSessionUnicode(session, unit, false)
      }
    }
  }

  func synchronize(capsLock: Bool) {
    withSession { RDPBSessionSynchronize($0, capsLock ? 4 : 0) }
  }

  @discardableResult
  func resize(width: Int, height: Int, desktopScale: Int) -> Bool {
    var result = false
    withSession { result = RDPBSessionResize($0, UInt32(width), UInt32(height), UInt32(desktopScale), 100) }
    return result
  }

  func setClipboardText(_ text: String) {
    withSession { session in text.withCString { RDPBSessionSetClipboardText(session, $0) } }
  }

  private static func clamp(_ value: CGFloat) -> UInt16 {
    UInt16(max(0, min(CGFloat(UInt16.max), value.rounded(.down))))
  }

  // MARK: Delivering events

  private func post(_ body: @escaping @MainActor (RemoteConnection, RemoteConnectionDelegate) -> Void) {
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self, let delegate = self.delegate else { return }
        body(self, delegate)
      }
    }
  }

  /// Asks the main actor a question and blocks this (FreeRDP's) thread until it is answered
  /// or the connection is closed.
  private func ask<T: Sendable>(_ present: @escaping @MainActor (RemoteConnection, RemoteConnectionDelegate, @escaping (T?) -> Void) -> Void) -> T? {
    let prompt = PendingPrompt()
    let accepted = lock.withLock { () -> Bool in
      guard !closed else { return false }
      pendingPrompts.append(prompt)
      return true
    }
    guard accepted else { return nil }
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self, let delegate = self.delegate else {
          prompt.cancel()
          return
        }
        present(self, delegate) { answer in prompt.finish(answer) }
      }
    }
    let answer = prompt.wait() as? T
    lock.withLock { pendingPrompts.removeAll { $0 === prompt } }
    return answer
  }

  // MARK: C callbacks

  private static func connection(_ context: UnsafeMutableRawPointer?) -> RemoteConnection {
    Unmanaged<RemoteConnection>.fromOpaque(context!).takeUnretainedValue()
  }

  private static func callbacks() -> RDPBCallbacks {
    var c = RDPBCallbacks()
    c.state = { context, state, reason, code, message in
      let connection = RemoteConnection.connection(context)
      let detail = message.map { String(cString: $0) }
      let value: State
      switch state {
      case RDPBStateConnecting: value = .connecting
      case RDPBStateConnected: value = .connected
      case RDPBStateReconnecting: value = .reconnecting
      default: value = .disconnected(EndReason(reason), code: code, detail: detail)
      }
      connection.post { connection, delegate in delegate.connection(connection, changedTo: value) }
    }
    c.frame = { context in
      let connection = RemoteConnection.connection(context)
      connection.post { connection, delegate in delegate.connectionHasNewFrame(connection) }
    }
    c.resize = { context, width, height in
      let connection = RemoteConnection.connection(context)
      let size = CGSize(width: Int(width), height: Int(height))
      connection.post { connection, delegate in delegate.connection(connection, resizedTo: size) }
    }
    c.cursorNew = { context, id, rgba, width, height, hotX, hotY in
      guard let rgba, width > 0, height > 0 else { return }
      let connection = RemoteConnection.connection(context)
      let data = Data(bytes: rgba, count: Int(width) * Int(height) * 4)
      guard let provider = CGDataProvider(data: data as CFData),
            let image = CGImage(
              width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32,
              bytesPerRow: Int(width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            ) else { return }
      connection.lock.withLock {
        connection.cursorImages[UInt(id)] = (image, CGPoint(x: Int(hotX), y: Int(hotY)))
      }
    }
    c.cursorFree = { context, id in
      let connection = RemoteConnection.connection(context)
      _ = connection.lock.withLock { connection.cursorImages.removeValue(forKey: UInt(id)) }
    }
    c.cursorSet = { context, kind, id in
      let connection = RemoteConnection.connection(context)
      let cursor: Cursor
      switch kind {
      case RDPBCursorHidden: cursor = .hidden
      case RDPBCursorCustom:
        guard let entry = connection.lock.withLock({ connection.cursorImages[UInt(id)] }) else { return }
        cursor = .image(entry.0, hotSpot: entry.1)
      default: cursor = .standard
      }
      connection.post { connection, delegate in delegate.connection(connection, cursorChanged: cursor) }
    }
    c.clipboardText = { context, text in
      guard let text else { return }
      let connection = RemoteConnection.connection(context)
      let value = String(cString: text)
      connection.post { connection, delegate in delegate.connection(connection, copiedText: value) }
    }
    c.authenticate = { context, gateway, username, usernameSize, domain, domainSize, password, passwordSize in
      let connection = RemoteConnection.connection(context)
      let request = CredentialRequest(
        gateway: gateway,
        username: username.map { String(cString: $0) } ?? "",
        domain: domain.map { String(cString: $0) } ?? ""
      )
      let answer: Credentials? = connection.ask { connection, delegate, reply in
        delegate.connection(connection, needsCredentials: request, reply: reply)
      }
      guard let answer else { return false }
      RemoteConnection.copy(answer.username, into: username, size: usernameSize)
      RemoteConnection.copy(answer.domain, into: domain, size: domainSize)
      RemoteConnection.copy(answer.password, into: password, size: passwordSize)
      return true
    }
    c.verifyCertificate = { context, host, port, commonName, subject, issuer, fingerprint, oldFingerprint, mismatch in
      let connection = RemoteConnection.connection(context)
      func string(_ pointer: UnsafePointer<CChar>?) -> String { pointer.map { String(cString: $0) } ?? "" }
      let previous = string(oldFingerprint)
      let certificate = Certificate(
        host: string(host), port: port, commonName: string(commonName), subject: string(subject),
        issuer: string(issuer), fingerprint: string(fingerprint),
        previousFingerprint: previous.isEmpty ? nil : previous, hostMismatch: mismatch
      )
      let answer: TrustDecision? = connection.ask { connection, delegate, reply in
        delegate.connection(connection, needsTrustFor: certificate, reply: reply)
      }
      switch answer {
      case .trustAlways: return 1
      case .trustOnce: return 2
      default: return 0
      }
    }
    return c
  }

  private static func copy(_ value: String, into buffer: UnsafeMutablePointer<CChar>?, size: Int) {
    guard let buffer, size > 0 else { return }
    let bytes = Array(value.utf8.prefix(size - 1))
    for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[bytes.count] = 0
  }
}

/// A question FreeRDP's thread is waiting on.
nonisolated private final class PendingPrompt: @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var answer: Any?
  private var done = false

  func finish(_ value: Any?) {
    let first = lock.withLock { () -> Bool in
      guard !done else { return false }
      done = true
      answer = value
      return true
    }
    if first { semaphore.signal() }
  }

  func cancel() { finish(nil) }

  func wait() -> Any? {
    semaphore.wait()
    return lock.withLock { answer }
  }
}

/// C strings that live until `free()`.
nonisolated private final class CStrings {
  private var pointers: [UnsafeMutablePointer<CChar>] = []

  func make(_ value: String?) -> UnsafePointer<CChar>? {
    guard let value, !value.isEmpty, let pointer = strdup(value) else { return nil }
    pointers.append(pointer)
    return UnsafePointer(pointer)
  }

  func free() {
    pointers.forEach { Foundation.free($0) }
    pointers.removeAll()
  }
}
