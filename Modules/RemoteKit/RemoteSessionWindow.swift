import AppKit
import KitziCore
import Observation
import SwiftUI

/// The open sessions, one window per PC.
@Observable
final class RemoteSessions {
  static let shared = RemoteSessions()

  /// PCs with a session window, and whether each is connected right now.
  private(set) var states: [UUID: Bool] = [:]
  @ObservationIgnored private var controllers: [UUID: RemoteSessionController] = [:]

  func connect(_ device: RemoteDevice) {
    if let controller = controllers[device.id] {
      controller.bringToFront()
      return
    }
    let controller = RemoteSessionController(device: device)
    controllers[device.id] = controller
    states[device.id] = false
    controller.onConnectedChange = { [weak self] connected in
      self?.states[device.id] = connected
    }
    controller.onClose = { [weak self] in
      self?.controllers[device.id] = nil
      self?.states[device.id] = nil
    }
    controller.start()
  }

  func isOpen(_ id: UUID) -> Bool { states[id] != nil }
  func isConnected(_ id: UUID) -> Bool { states[id] == true }

  func closeAll() {
    controllers.values.forEach { $0.close() }
  }
}

/// What the overlay over the desktop shows.
@Observable
final class RemoteSessionStatus {
  enum Phase: Equatable {
    case connecting
    case reconnecting
    case connected
    case ended(title: String, message: String, retryTitle: String?)
  }

  var phase = Phase.connecting
  var name = ""
}

/// One session window: the desktop view, the connection and the prompts it needs.
final class RemoteSessionController: NSObject, NSWindowDelegate, RemoteConnectionDelegate {
  #if DEBUG
  /// Test hook: used for PCs without an account, instead of asking.
  static var testCredentials: (username: String, password: String)?
  #endif

  var onConnectedChange: ((Bool) -> Void)?
  var onClose: (() -> Void)?

  private var device: RemoteDevice
  private var connection: RemoteConnection?
  private let window: NSWindow
  private let desktopView = RemoteDesktopView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
  private let overlay: NSHostingView<RemoteSessionOverlay>
  private let status = RemoteSessionStatus()
  private var isConnected = false
  private var promptForPassword = false
  private var lastSignInFailed = false
  private var isClosing = false

  private var resizeWork: DispatchWorkItem?
  private var lastRequestedSize: (Int, Int)?
  private var clipboardTimer: Timer?
  private var pasteboardChangeCount = NSPasteboard.general.changeCount
  private var sheetQueue: [() -> Void] = []

  init(device: RemoteDevice) {
    self.device = device
    status.name = device.displayName
    overlay = NSHostingView(rootView: RemoteSessionOverlay(status: status, retry: {}, close: {}))

    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    var size: NSSize
    switch device.display.resolution {
    case .matchWindow:
      size = NSSize(width: 1280, height: 800)
    case .fixed(let width, let height):
      let factor = device.display.retina ? (NSScreen.main?.backingScaleFactor ?? 2) : 1
      size = NSSize(width: CGFloat(width) / factor, height: CGFloat(height) / factor)
    }
    let maxSize = NSSize(width: screen.width * 0.92, height: screen.height * 0.9)
    let shrink = min(1, maxSize.width / size.width, maxSize.height / size.height)
    size = NSSize(width: (size.width * shrink).rounded(), height: (size.height * shrink).rounded())

    window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false
    )
    super.init()

    overlay.rootView = RemoteSessionOverlay(
      status: status,
      retry: { [weak self] in self?.retry() },
      close: { [weak self] in self?.close() }
    )

    window.title = device.displayName
    window.subtitle = device.address
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.fullScreenPrimary]
    window.acceptsMouseMovedEvents = true
    window.minSize = NSSize(width: 480, height: 320)
    window.delegate = self
    if case .fixed(let width, let height) = device.display.resolution {
      window.contentAspectRatio = NSSize(width: width, height: height)
    }

    let container = NSView(frame: NSRect(origin: .zero, size: size))
    desktopView.frame = container.bounds
    desktopView.autoresizingMask = [.width, .height]
    overlay.frame = container.bounds
    overlay.autoresizingMask = [.width, .height]
    container.addSubview(desktopView)
    container.addSubview(overlay)
    window.contentView = container
    desktopView.onToggleFullScreen = { [weak self] in self?.window.toggleFullScreen(nil) }
    window.addTitlebarAccessoryViewController(makeAccessory())

    let autosave = "KitziRemote-\(device.id.uuidString)"
    window.center()
    if case .matchWindow = device.display.resolution {
      window.setFrameAutosaveName(autosave)
    }
  }

  // MARK: Lifecycle

  func start() {
    KitziWindows.didOpen()
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(desktopView)
    NSApp.activate(ignoringOtherApps: true)
    if device.display.startFullScreen {
      window.toggleFullScreen(nil)
    }
    connect()
  }

  func bringToFront() {
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func close() {
    window.performClose(nil)
  }

  private func connect() {
    connection?.close()
    connection = nil
    lastRequestedSize = nil
    setConnected(false)
    status.phase = .connecting

    // Pick up edits made while the window was open.
    if let latest = RemoteStore.shared.device(device.id) { device = latest }
    guard let configuration = makeConfiguration(),
          let connection = RemoteConnection(configuration: configuration) else {
      status.phase = .ended(
        title: String(localized: "Couldn't Connect"),
        message: String(localized: "“\(device.address)” isn't a valid PC name."),
        retryTitle: nil
      )
      return
    }
    connection.delegate = self
    desktopView.connection = connection
    self.connection = connection
    promptForPassword = false
    if !connection.start() {
      status.phase = .ended(title: String(localized: "Couldn't Connect"),
                            message: String(localized: "The connection couldn't be started."),
                            retryTitle: String(localized: "Try Again"))
    }
  }

  private func retry() {
    connect()
  }

  private func makeConfiguration() -> RemoteConnection.Configuration? {
    let store = RemoteStore.shared
    let (host, port) = device.hostAndPort
    guard !host.isEmpty else { return nil }

    let (width, height, scale) = desiredDesktopSize()
    var c = RemoteConnection.Configuration(host: host, port: port, width: width, height: height)
    c.desktopScale = scale
    if let account = store.account(device.accountID) {
      c.username = account.username
      if !promptForPassword { c.password = RemoteKeychain.password(for: account.id) }
    }
    #if DEBUG
    if c.username == nil, let test = Self.testCredentials {
      c.username = test.username
      c.password = test.password
    }
    #endif
    if device.gateway.isEnabled {
      let (gatewayHost, gatewayPort) = RemoteAddress.parse(device.gateway.address, defaultPort: 443)
      c.gatewayHost = gatewayHost
      c.gatewayPort = gatewayPort
      c.gatewayUseSameCredentials = device.gateway.useSameAccount
      if !device.gateway.useSameAccount, let account = store.account(device.gateway.accountID) {
        c.gatewayUsername = account.username
        c.gatewayPassword = RemoteKeychain.password(for: account.id)
      }
    }
    c.rdpText = device.extraRDP.isEmpty ? nil : device.extraRDP
    c.keyboardLayout = RemoteKeyboardLayouts.current()
    if case .matchWindow = device.display.resolution {
      c.dynamicResolution = true
    } else {
      c.dynamicResolution = false
    }
    c.audio = device.redirection.audio
    c.clipboard = device.redirection.clipboard
    c.adminSession = device.adminMode
    switch device.redirection.folder {
    case .none:
      break
    case .home:
      c.sharedFolder = FileManager.default.homeDirectoryForCurrentUser.path
      c.sharedFolderName = Host.current().localizedName ?? "Mac"
    case .custom(let path):
      c.sharedFolder = path
      c.sharedFolderName = URL(fileURLWithPath: path).lastPathComponent
    }
    return c
  }

  /// The desktop size in pixels and the Windows scale for the current window.
  private func desiredDesktopSize() -> (Int, Int, Int) {
    let backing = window.backingScaleFactor
    switch device.display.resolution {
    case .fixed(let width, let height):
      return (width, height, device.display.retina ? Int((backing * 100).rounded()) : 100)
    case .matchWindow:
      let size = window.contentLayoutRect.size
      let factor = device.display.retina ? backing : 1
      let width = Int((size.width * factor).rounded()) & ~1
      let height = Int((size.height * factor).rounded())
      return (max(200, width), max(200, height), device.display.retina ? Int((backing * 100).rounded()) : 100)
    }
  }

  private func setConnected(_ connected: Bool) {
    guard connected != isConnected else { return }
    isConnected = connected
    desktopView.isInputEnabled = connected
    overlay.isHidden = connected
    onConnectedChange?(connected)
    clipboardTimer?.invalidate()
    clipboardTimer = nil
    if connected, device.redirection.clipboard {
      pasteboardChangeCount = -1
      sendClipboardIfChanged()
      clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.sendClipboardIfChanged() }
      }
    }
  }

  // MARK: RemoteConnectionDelegate

  func connection(_ connection: RemoteConnection, changedTo state: RemoteConnection.State) {
    guard connection === self.connection else { return }
    switch state {
    case .connecting:
      status.phase = .connecting
    case .connected:
      setConnected(true)
      lastSignInFailed = false
      status.phase = .connected
      RemoteStore.shared.markConnected(device.id)
      window.makeFirstResponder(desktopView)
      connection.synchronize(capsLock: NSEvent.modifierFlags.contains(.capsLock))
      // The display channel is ready a moment after connecting.
      for delay in [1.0, 3.0] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
          MainActor.assumeIsolated { self?.applyWindowSize() }
        }
      }
    case .reconnecting:
      setConnected(false)
      overlay.isHidden = false
      status.phase = .reconnecting
    case .disconnected(let reason, let code, let detail):
      let wasConnected = isConnected
      setConnected(false)
      saveThumbnail()
      self.connection = nil
      desktopView.connection = nil
      connection.close()
      if isClosing { return }
      if reason == .userDisconnect && wasConnected {
        // Signed out or disconnected on the PC: nothing more to show.
        window.performClose(nil)
        return
      }
      status.phase = Self.endPhase(reason, code: code, detail: detail, host: device.hostAndPort.host)
      if reason == .authentication {
        promptForPassword = true
        lastSignInFailed = true
      }
    }
  }

  func connectionHasNewFrame(_ connection: RemoteConnection) {
    guard connection === self.connection, let image = connection.copyFrame() else { return }
    desktopView.show(image)
  }

  func connection(_ connection: RemoteConnection, resizedTo size: CGSize) {
    guard connection === self.connection else { return }
    if case .fixed = device.display.resolution, size.width > 0, size.height > 0 {
      window.contentAspectRatio = size
    }
  }

  func connection(_ connection: RemoteConnection, cursorChanged cursor: RemoteConnection.Cursor) {
    guard connection === self.connection else { return }
    desktopView.setRemoteCursor(cursor)
  }

  func connection(_ connection: RemoteConnection, copiedText text: String) {
    guard connection === self.connection, device.redirection.clipboard else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    pasteboardChangeCount = pasteboard.changeCount
  }

  func connection(_ connection: RemoteConnection, needsCredentials request: RemoteConnection.CredentialRequest,
                  reply: @escaping (RemoteConnection.Credentials?) -> Void) {
    guard connection === self.connection, !isClosing else { return reply(nil) }
    let store = RemoteStore.shared
    let accountID = request.gateway && !device.gateway.useSameAccount ? device.gateway.accountID : device.accountID
    var username = request.username
    if !request.domain.isEmpty, !username.isEmpty, !username.contains("\\"), !username.contains("@") {
      username = "\(request.domain)\\\(username)"
    }
    if username.isEmpty { username = store.account(accountID)?.username ?? "" }

    let prompt = RemoteCredentialPrompt(
      title: request.gateway
        ? String(localized: "Sign in to the gateway for “\(device.displayName)”")
        : String(localized: "Sign in to “\(device.displayName)”"),
      username: username,
      remember: true,
      failed: lastSignInFailed
    )
    presentCredentialSheet(prompt) { [weak self] result in
      guard let self, let result else { return reply(nil) }
      if result.remember {
        let account = store.account(forUsername: result.username)
        store.upsert(account, password: result.password)
        var updated = store.device(self.device.id) ?? self.device
        if request.gateway && !updated.gateway.useSameAccount {
          updated.gateway.accountID = account.id
        } else {
          updated.accountID = account.id
        }
        store.upsert(updated)
        self.device = updated
      }
      reply(Self.split(result.username, password: result.password))
    }
  }

  func connection(_ connection: RemoteConnection, needsTrustFor certificate: RemoteConnection.Certificate,
                  reply: @escaping (RemoteConnection.TrustDecision) -> Void) {
    guard connection === self.connection, !isClosing else { return reply(.reject) }
    let alert = NSAlert()
    let host = certificate.host
    if let previous = certificate.previousFingerprint {
      alert.alertStyle = .critical
      alert.messageText = String(localized: "The certificate of “\(host)” has changed")
      alert.informativeText = String(localized: "This can happen after the PC was set up again, but it can also mean someone is intercepting the connection. Continue only if you expected this.\n\nNew fingerprint: \(certificate.fingerprint)\nPrevious fingerprint: \(previous)")
    } else {
      alert.alertStyle = .warning
      alert.messageText = String(localized: "Kitzi can't verify the identity of “\(host)”")
      var text = String(localized: "The PC's certificate isn't from an authority this Mac trusts. Most PCs on a company network use such certificates.")
      if certificate.hostMismatch {
        text += "\n\n" + String(localized: "The certificate was issued for “\(certificate.commonName)”, not for this name.")
      }
      text += "\n\n" + String(localized: "Issued by: \(certificate.issuer)\nFingerprint: \(certificate.fingerprint)")
      alert.informativeText = text
      alert.showsSuppressionButton = true
      alert.suppressionButton?.title = String(localized: "Don't ask again for this PC")
    }
    alert.addButton(withTitle: String(localized: "Continue"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    runAlert(alert) { response in
      guard response == .alertFirstButtonReturn else { return reply(.reject) }
      reply(alert.suppressionButton?.state == .on && certificate.previousFingerprint == nil ? .trustAlways : .trustOnce)
    }
  }

  private static func split(_ username: String, password: String) -> RemoteConnection.Credentials {
    if let slash = username.firstIndex(of: "\\") {
      return .init(username: String(username[username.index(after: slash)...]),
                   domain: String(username[..<slash]), password: password)
    }
    return .init(username: username, domain: "", password: password)
  }

  private static func endPhase(_ reason: RemoteConnection.EndReason, code: UInt32, detail: String?,
                               host: String) -> RemoteSessionStatus.Phase {
    let tryAgain = String(localized: "Try Again")
    let reconnect = String(localized: "Reconnect")
    switch reason {
    case .none, .userDisconnect:
      return .ended(title: String(localized: "Disconnected"),
                    message: String(localized: "The session has ended."), retryTitle: reconnect)
    case .cancelled:
      return .ended(title: String(localized: "Connection Cancelled"), message: "", retryTitle: tryAgain)
    case .authentication:
      return .ended(title: String(localized: "Couldn't Sign In"),
                    message: String(localized: "The user name or password is incorrect."),
                    retryTitle: String(localized: "Enter Password…"))
    case .passwordExpired:
      return .ended(title: String(localized: "Password Expired"),
                    message: String(localized: "The password has expired or must be changed before you can sign in. Change it on a PC or ask your administrator."),
                    retryTitle: tryAgain)
    case .accountProblem:
      return .ended(title: String(localized: "Couldn't Sign In"),
                    message: String(localized: "The account is locked out, disabled, expired or not allowed to sign in now."),
                    retryTitle: tryAgain)
    case .hostNotFound:
      return .ended(title: String(localized: "PC Not Found"),
                    message: String(localized: "“\(host)” couldn't be found. Check the PC name and that you're on the right network or VPN."),
                    retryTitle: tryAgain)
    case .unreachable:
      return .ended(title: String(localized: "Couldn't Connect"),
                    message: String(localized: "“\(host)” didn't answer. Check that the PC is on, Remote Desktop is turned on and you're on the right network or VPN."),
                    retryTitle: tryAgain)
    case .security:
      return .ended(title: String(localized: "Couldn't Connect Securely"),
                    message: String(localized: "A secure connection to “\(host)” couldn't be set up.") + Self.suffix(detail),
                    retryTitle: tryAgain)
    case .otherConnection:
      return .ended(title: String(localized: "Disconnected"),
                    message: String(localized: "Someone else connected to this session."), retryTitle: reconnect)
    case .idleTimeout:
      return .ended(title: String(localized: "Disconnected"),
                    message: String(localized: "The session ended because it was idle for too long."), retryTitle: reconnect)
    case .serverDenied:
      return .ended(title: String(localized: "Connection Refused"),
                    message: String(localized: "The PC refused the connection. Your account may not be allowed to use Remote Desktop on it."),
                    retryTitle: tryAgain)
    case .networkLost:
      return .ended(title: String(localized: "Connection Lost"),
                    message: String(localized: "The connection to the PC was lost."), retryTitle: reconnect)
    case .other:
      return .ended(title: String(localized: "Disconnected"),
                    message: String(localized: "The connection ended unexpectedly.") + Self.suffix(detail) + String(format: " (0x%08X)", code),
                    retryTitle: reconnect)
    }
  }

  private static func suffix(_ detail: String?) -> String {
    guard let detail, !detail.isEmpty else { return "" }
    return "\n" + detail
  }

  // MARK: Sheets and alerts

  private func presentCredentialSheet(_ prompt: RemoteCredentialPrompt,
                                      completion: @escaping (RemoteCredentialResult?) -> Void) {
    enqueue { [weak self] in
      guard let self else { return completion(nil) }
      var sheet: NSWindow?
      let view = RemoteCredentialSheet(prompt: prompt) { [weak self] result in
        completion(result)
        if let sheet { self?.window.endSheet(sheet) }
      }
      let controller = NSHostingController(rootView: view)
      let window = NSWindow(contentViewController: controller)
      window.styleMask = [.titled]
      sheet = window
      self.window.beginSheet(window) { [weak self] _ in self?.showNextSheet() }
    }
  }

  private func runAlert(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
    enqueue { [weak self] in
      guard let self else { return completion(.cancel) }
      alert.beginSheetModal(for: self.window) { [weak self] response in
        completion(response)
        self?.showNextSheet()
      }
    }
  }

  private func enqueue(_ show: @escaping () -> Void) {
    if window.attachedSheet == nil && sheetQueue.isEmpty {
      show()
    } else {
      sheetQueue.append(show)
    }
  }

  private func showNextSheet() {
    guard !sheetQueue.isEmpty else { return }
    let next = sheetQueue.removeFirst()
    DispatchQueue.main.async { next() }
  }

  // MARK: Clipboard

  private func sendClipboardIfChanged() {
    guard isConnected, window.isKeyWindow || pasteboardChangeCount == -1, let connection else { return }
    let pasteboard = NSPasteboard.general
    guard pasteboard.changeCount != pasteboardChangeCount else { return }
    pasteboardChangeCount = pasteboard.changeCount
    if let text = pasteboard.string(forType: .string), !text.isEmpty {
      connection.setClipboardText(text)
    }
  }

  // MARK: Resizing

  private func scheduleResize(after delay: TimeInterval = 0.35) {
    resizeWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.applyWindowSize() }
    }
    resizeWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func applyWindowSize() {
    guard isConnected, case .matchWindow = device.display.resolution, let connection else { return }
    let (width, height, scale) = desiredDesktopSize()
    let current = desktopView.desktopSize
    if Int(current.width) == width && Int(current.height) == height { return }
    if let last = lastRequestedSize, last == (width, height) { return }
    if connection.resize(width: width, height: height, desktopScale: scale) {
      lastRequestedSize = (width, height)
    }
  }

  func windowDidResize(_ notification: Notification) {
    lastRequestedSize = nil
    scheduleResize()
  }

  func windowDidEndLiveResize(_ notification: Notification) { scheduleResize(after: 0.05) }
  func windowDidEnterFullScreen(_ notification: Notification) { scheduleResize(after: 0.1) }
  func windowDidExitFullScreen(_ notification: Notification) { scheduleResize(after: 0.1) }
  func windowDidChangeBackingProperties(_ notification: Notification) { scheduleResize() }

  func windowDidBecomeKey(_ notification: Notification) {
    window.makeFirstResponder(desktopView)
    if isConnected {
      connection?.synchronize(capsLock: NSEvent.modifierFlags.contains(.capsLock))
      sendClipboardIfChanged()
    }
  }

  func windowDidResignKey(_ notification: Notification) {
    desktopView.releaseAllKeys()
  }

  // MARK: Closing

  func windowWillClose(_ notification: Notification) {
    isClosing = true
    resizeWork?.cancel()
    clipboardTimer?.invalidate()
    clipboardTimer = nil
    saveThumbnail()
    desktopView.isInputEnabled = false
    desktopView.connection = nil
    connection?.close()
    connection = nil
    if isConnected { isConnected = false }
    window.delegate = nil
    KitziWindows.didClose()
    onClose?()
  }

  private func saveThumbnail() {
    if let image = desktopView.lastImage {
      RemoteStore.shared.saveThumbnail(image, for: device.id)
    }
  }

  // MARK: Title bar menu

  private func makeAccessory() -> NSTitlebarAccessoryViewController {
    let button = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 44, height: 24), pullsDown: true)
    button.bezelStyle = .accessoryBarAction
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.toolTip = String(localized: "Session")
    let menu = NSMenu()
    let icon = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    icon.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: String(localized: "Session"))
    menu.addItem(icon)
    menu.addItem(item(String(localized: "Send Ctrl+Alt+Del"), #selector(sendControlAltDelete)))
    menu.addItem(item(String(localized: "Enter or Exit Full Screen"), #selector(toggleFullScreen)))
    menu.addItem(.separator())
    menu.addItem(item(String(localized: "Disconnect"), #selector(disconnectFromMenu)))
    button.menu = menu

    let holder = NSView(frame: NSRect(x: 0, y: 0, width: 52, height: 28))
    button.frame.origin = NSPoint(x: 4, y: 2)
    holder.addSubview(button)
    let accessory = NSTitlebarAccessoryViewController()
    accessory.view = holder
    accessory.layoutAttribute = .trailing
    return accessory
  }

  private func item(_ title: String, _ action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  @objc private func sendControlAltDelete() { desktopView.sendControlAltDelete() }
  @objc private func toggleFullScreen() { window.toggleFullScreen(nil) }
  @objc private func disconnectFromMenu() { close() }
}

/// Connecting, reconnecting and "the session ended" on top of the desktop.
struct RemoteSessionOverlay: View {
  let status: RemoteSessionStatus
  let retry: () -> Void
  let close: () -> Void

  var body: some View {
    ZStack {
      switch status.phase {
      case .connected:
        Color.clear
      case .connecting, .reconnecting:
        Color.black.opacity(status.phase == .reconnecting ? 0.55 : 1)
        VStack(spacing: 14) {
          ProgressView().controlSize(.large)
          Text(status.phase == .reconnecting
               ? String(localized: "Reconnecting to \(status.name)…")
               : String(localized: "Connecting to \(status.name)…"))
            .font(.title3)
          Button("Cancel", action: close)
        }
        .foregroundStyle(.white)
        .colorScheme(.dark)
      case .ended(let title, let message, let retryTitle):
        Color.black.opacity(0.85)
        VStack(spacing: 12) {
          Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 34))
            .foregroundStyle(.yellow)
          Text(title).font(.title2.weight(.semibold))
          if !message.isEmpty {
            Text(message)
              .multilineTextAlignment(.center)
              .frame(maxWidth: 440)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          HStack {
            Button("Close", action: close)
            if let retryTitle {
              Button(retryTitle, action: retry).keyboardShortcut(.defaultAction)
            }
          }
          .padding(.top, 6)
        }
        .padding(30)
        .colorScheme(.dark)
      }
    }
  }
}

struct RemoteCredentialPrompt {
  var title: String
  var username: String
  var remember: Bool
  var failed: Bool
}

struct RemoteCredentialResult {
  var username: String
  var password: String
  var remember: Bool
}

/// Asks for a user name and password while FreeRDP waits.
struct RemoteCredentialSheet: View {
  @State private var username: String
  @State private var password = ""
  @State private var remember: Bool
  private let prompt: RemoteCredentialPrompt
  private let completion: (RemoteCredentialResult?) -> Void
  @State private var answered = false

  init(prompt: RemoteCredentialPrompt, completion: @escaping (RemoteCredentialResult?) -> Void) {
    self.prompt = prompt
    self.completion = completion
    _username = State(initialValue: prompt.username)
    _remember = State(initialValue: prompt.remember)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(prompt.title).font(.headline)
      if prompt.failed {
        Text("The last attempt didn't work. Check the user name and password.")
          .font(.callout)
          .foregroundStyle(.red)
      }
      Form {
        TextField("User name", text: $username, prompt: Text(verbatim: "DOMAIN\\user"))
        SecureField("Password", text: $password)
        Toggle("Remember in the keychain", isOn: $remember)
      }
      .formStyle(.columns)
      HStack {
        Spacer()
        Button("Cancel") { finish(nil) }
          .keyboardShortcut(.cancelAction)
        Button("Connect") {
          finish(RemoteCredentialResult(username: username.trimmingCharacters(in: .whitespaces),
                                        password: password, remember: remember))
        }
        .keyboardShortcut(.defaultAction)
        .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 420)
  }

  private func finish(_ result: RemoteCredentialResult?) {
    guard !answered else { return }
    answered = true
    completion(result)
  }
}
