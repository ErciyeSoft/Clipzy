#if DEBUG
import AppKit
import Foundation

/// Test hook for debug builds: connects to a test server without any UI, sends some input,
/// writes the last picture as PNG and quits. Nothing is saved to the library or keychain.
///
///     open -n Kitzi.app --args -KitziOnlyFeatures remote \
///       -RemoteDesktopSelfTest 127.0.0.1:3399 -RemoteDesktopSelfTestOutput /tmp/frame.png
final class RemoteSelfTest: RemoteConnectionDelegate {
  private static var running: RemoteSelfTest?
  private var connection: RemoteConnection?
  private let output: URL
  private var frames = 0
  private var sentInput = false
  private var lastImage: CGImage?
  private var log: [String] = []

  static func runIfRequested() {
    let defaults = UserDefaults.standard
    if let snapshots = defaults.string(forKey: "RemoteDesktopSnapshot") {
      RemoteHomeWindow.snapshot(to: URL(fileURLWithPath: snapshots, isDirectory: true),
                                importWindowsApp: defaults.bool(forKey: "RemoteDesktopSnapshotImport"))
      return
    }
    guard let address = defaults.string(forKey: "RemoteDesktopSelfTest") else { return }
    let output = URL(fileURLWithPath: defaults.string(forKey: "RemoteDesktopSelfTestOutput") ?? "/tmp/kitzi-remote-selftest.png")
    let test = RemoteSelfTest(output: output)
    running = test
    test.start(address)
  }

  private init(output: URL) {
    self.output = output
  }

  private func start(_ address: String) {
    let (host, port) = RemoteAddress.parse(address, defaultPort: 3389)
    var configuration = RemoteConnection.Configuration(host: host, port: port, width: 1280, height: 800)
    configuration.username = "selftest"
    configuration.password = "selftest"
    configuration.keyboardLayout = RemoteKeyboardLayouts.current()
    configuration.clipboard = true
    guard let connection = RemoteConnection(configuration: configuration) else { return finish("config rejected") }
    connection.delegate = self
    self.connection = connection
    record("start \(host):\(port) layout=0x\(String(RemoteKeyboardLayouts.current(), radix: 16))")
    guard connection.start() else { return finish("start failed") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
      MainActor.assumeIsolated { self?.finish("timeout") }
    }
  }

  private func record(_ line: String) {
    log.append(line)
    print("[RemoteSelfTest] \(line)")
  }

  private func finish(_ result: String) {
    guard Self.running === self else { return }
    record("result: \(result) frames=\(frames)")
    if let lastImage {
      let rep = NSBitmapImageRep(cgImage: lastImage)
      try? rep.representation(using: .png, properties: [:])?.write(to: output)
    }
    try? log.joined(separator: "\n").write(to: output.deletingPathExtension().appendingPathExtension("log"),
                                          atomically: true, encoding: .utf8)
    connection?.close()
    Self.running = nil
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
  }

  func connection(_ connection: RemoteConnection, changedTo state: RemoteConnection.State) {
    record("state \(state)")
    if case .disconnected = state { finish("disconnected") }
  }

  func connectionHasNewFrame(_ connection: RemoteConnection) {
    guard let image = connection.copyFrame() else { return }
    frames += 1
    lastImage = image
    if frames == 1 { record("first frame \(image.width)x\(image.height)") }
    if frames >= 1 && !sentInput {
      sentInput = true
      // Move, click, scroll, type and copy something, like a person would.
      connection.mouseMove(CGPoint(x: 200, y: 150))
      connection.mouseButton(0, down: true, at: CGPoint(x: 200, y: 150))
      connection.mouseButton(0, down: false, at: CGPoint(x: 200, y: 150))
      connection.wheel(horizontal: false, delta: -120, at: CGPoint(x: 200, y: 150))
      for key: UInt16 in [0x04, 0x22] { // h, i
        connection.macKey(key, down: true)
        connection.macKey(key, down: false)
      }
      connection.unicode("ş")
      connection.setClipboardText("Kitzi self test\nline 2")
      _ = connection.resize(width: 1024, height: 700, desktopScale: 100)
      record("sent input")
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
        MainActor.assumeIsolated { self?.finish("ok") }
      }
    }
  }

  func connection(_ connection: RemoteConnection, resizedTo size: CGSize) {
    record("desktop \(Int(size.width))x\(Int(size.height))")
  }

  func connection(_ connection: RemoteConnection, cursorChanged cursor: RemoteConnection.Cursor) {
    switch cursor {
    case .image(let image, let hotSpot): record("cursor image \(image.width)x\(image.height) hot \(hotSpot)")
    case .hidden: record("cursor hidden")
    case .standard: record("cursor standard")
    }
  }

  func connection(_ connection: RemoteConnection, copiedText text: String) {
    record("remote clipboard: \(text)")
  }

  func connection(_ connection: RemoteConnection, needsCredentials request: RemoteConnection.CredentialRequest,
                  reply: @escaping (RemoteConnection.Credentials?) -> Void) {
    record("credentials asked (gateway=\(request.gateway))")
    reply(.init(username: "selftest", domain: "", password: "selftest"))
  }

  func connection(_ connection: RemoteConnection, needsTrustFor certificate: RemoteConnection.Certificate,
                  reply: @escaping (RemoteConnection.TrustDecision) -> Void) {
    record("certificate asked: cn=\(certificate.commonName) fp=\(certificate.fingerprint.prefix(20))… changed=\(certificate.previousFingerprint != nil)")
    reply(UserDefaults.standard.bool(forKey: "RemoteDesktopSelfTestTrustAlways") ? .trustAlways : .trustOnce)
  }
}
#endif
