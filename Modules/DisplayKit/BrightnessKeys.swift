import AppKit
import ApplicationServices
import SwiftUI

/// Sends the brightness keys to the display under the pointer when Kitzi controls that
/// display (DDC/CI or software dimming). Displays macOS controls itself keep the keys.
///
/// The event tap runs on its own thread so a busy main thread never holds up media keys.
nonisolated final class BrightnessKeyTap: @unchecked Sendable {
  struct Target: Sendable, Equatable {
    let id: CGDirectDisplayID
    /// Global display coordinates (origin at the top left of the main display).
    let bounds: CGRect
  }

  private struct Tap: @unchecked Sendable {
    let port: CFMachPort
    let source: CFRunLoopSource
  }

  // NX_SYSDEFINED events carry the media keys; these codes are from IOKit's ev_keymap.h.
  private static let systemDefinedType: UInt32 = 14
  private static let auxControlButtons: Int16 = 8
  private static let brightnessUpKey = 2
  private static let brightnessDownKey = 3

  // Shared with the tap thread, guarded by `lock`.
  private let lock = NSLock()
  private var targets: [Target] = []
  private var tapPort: CFMachPort?
  private var tapRunLoop: CFRunLoop?

  // Main thread only.
  private var tap: Tap?
  private var retryTimer: Timer?
  private let onKey: @MainActor (_ display: CGDirectDisplayID, _ up: Bool, _ fine: Bool) -> Void

  @MainActor init(onKey: @escaping @MainActor (_ display: CGDirectDisplayID, _ up: Bool, _ fine: Bool) -> Void) {
    self.onKey = onKey
  }

  @MainActor var isRunning: Bool { tap != nil }

  func setTargets(_ targets: [Target]) {
    lock.withLock { self.targets = targets }
  }

  @MainActor func start() {
    guard tap == nil, retryTimer == nil else { return }
    guard let port = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: CGEventMask(1) << CGEventMask(Self.systemDefinedType),
      callback: brightnessKeyCallback,
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
      // Needs Accessibility access; try again until it is granted.
      retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, AXIsProcessTrusted() else { return }
          self.retryTimer?.invalidate()
          self.retryTimer = nil
          self.start()
        }
      }
      return
    }
    let tap = Tap(port: port, source: source)
    self.tap = tap
    lock.withLock { tapPort = port }
    let thread = Thread { [self] in runTap(tap) }
    thread.name = "Kitzi brightness keys"
    thread.qualityOfService = .userInteractive
    thread.start()
  }

  @MainActor func stop() {
    retryTimer?.invalidate()
    retryTimer = nil
    guard let tap else { return }
    CGEvent.tapEnable(tap: tap.port, enable: false)
    CFMachPortInvalidate(tap.port)
    let runLoop = lock.withLock {
      defer { tapPort = nil; tapRunLoop = nil }
      return tapRunLoop
    }
    if let runLoop { CFRunLoopStop(runLoop) }
    self.tap = nil
  }

  private func runTap(_ tap: Tap) {
    let runLoop = CFRunLoopGetCurrent()
    lock.withLock { tapRunLoop = runLoop }
    CFRunLoopAddSource(runLoop, tap.source, .commonModes)
    CGEvent.tapEnable(tap: tap.port, enable: true)
    CFRunLoopRun()
  }

  /// Returns false to swallow the event.
  fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let port = lock.withLock({ tapPort }) { CGEvent.tapEnable(tap: port, enable: true) }
      return true
    }
    guard type.rawValue == Self.systemDefinedType,
          let key = NSEvent(cgEvent: event), key.subtype.rawValue == Self.auxControlButtons else { return true }
    let code = (key.data1 & 0xFFFF_0000) >> 16
    guard code == Self.brightnessUpKey || code == Self.brightnessDownKey else { return true }
    let isDown = (key.data1 & 0xFF00) >> 8 == 0x0A
    let pointer = CGEvent(source: nil)?.location ?? event.location
    guard let target = lock.withLock({ targets.first { $0.bounds.contains(pointer) } }) else { return true }
    if isDown {
      let up = code == Self.brightnessUpKey
      let fine = key.modifierFlags.contains([.option, .shift])
      let onKey = self.onKey
      let display = target.id
      Task { @MainActor in onKey(display, up, fine) }
    }
    return false
  }
}

nonisolated private func brightnessKeyCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  let tap = Unmanaged<BrightnessKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
  return tap.handle(type, event) ? Unmanaged.passUnretained(event) : nil
}

// MARK: - On-screen level

/// A small brightness level shown on the display that changed, since macOS shows none for it.
final class BrightnessHUD {
  private var panel: NSPanel?
  private var hosting: NSHostingView<BrightnessHUDView>?
  private var hideTask: Task<Void, Never>?

  func show(level: Double, name: String, on display: CGDirectDisplayID) {
    let panel = panel ?? makePanel()
    hosting?.rootView = BrightnessHUDView(level: level, name: name)
    let size = hosting?.fittingSize ?? NSSize(width: 240, height: 90)
    let screen = NSScreen.screens.first {
      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
    } ?? NSScreen.main
    if let frame = screen?.visibleFrame {
      panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 120,
                            width: size.width, height: size.height), display: true)
    }
    panel.alphaValue = 1
    panel.orderFrontRegardless()
    hideTask?.cancel()
    hideTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.4))
      guard !Task.isCancelled, let panel = self?.panel else { return }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.3
        panel.animator().alphaValue = 0
      } completionHandler: {
        MainActor.assumeIsolated {
          if panel.alphaValue == 0 { panel.orderOut(nil) }
        }
      }
    }
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]

    let background = NSVisualEffectView()
    background.material = .hudWindow
    background.blendingMode = .behindWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 14
    background.layer?.masksToBounds = true
    let hosting = NSHostingView(rootView: BrightnessHUDView(level: 1, name: ""))
    hosting.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(hosting)
    NSLayoutConstraint.activate([
      hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
      hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
      hosting.topAnchor.constraint(equalTo: background.topAnchor),
      hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
    ])
    panel.contentView = background
    self.panel = panel
    self.hosting = hosting
    return panel
  }
}

struct BrightnessHUDView: View {
  let level: Double
  let name: String

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 10) {
        Image(systemName: "sun.max.fill")
          .font(.title3)
        ProgressView(value: level)
          .progressViewStyle(.linear)
          .frame(width: 160)
        Text(level.formatted(.percent.precision(.fractionLength(0))))
          .font(.callout.monospacedDigit())
          .frame(width: 44, alignment: .trailing)
      }
      Text(name)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
  }
}
