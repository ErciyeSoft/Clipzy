import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio

/// A level change shown in the notch instead of the system HUD.
struct NotchHUDEvent: Equatable, Sendable {
  enum Kind: Sendable {
    case volume
    case brightness
  }

  var kind: Kind
  /// 0...1
  var value: Float
  var muted = false
}

/// Takes over the volume and brightness keys: applies the change itself and reports the new
/// level, so the notch shows it instead of the system HUD. Keys it can't apply (an output
/// device without a volume control, a display whose brightness can't be set) go on to macOS
/// unchanged, as do keys pressed with ⌥ alone (⌥ + volume opens Sound settings).
/// The key handling follows boring.notch's MediaKeyInterceptor (GPL-3.0).
///
/// The event tap runs on its own thread so a busy main thread never delays the keys.
nonisolated final class MediaKeyTap: @unchecked Sendable {
  private enum Key: Int {
    case soundUp = 0
    case soundDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7
  }

  private struct Tap: @unchecked Sendable {
    let port: CFMachPort
    let source: CFRunLoopSource
  }

  /// One press moves the level by a sixteenth, like macOS; ⌥⇧ moves it by a quarter of that.
  private static let step: Float = 1.0 / 16.0

  private let onEvent: @MainActor @Sendable (NotchHUDEvent) -> Void

  // Shared with the tap thread, guarded by `lock`.
  private let lock = NSLock()
  private var tapPort: CFMachPort?
  private var tapRunLoop: CFRunLoop?

  // Main thread only.
  private var tap: Tap?
  private var retryTimer: Timer?

  @MainActor init(onEvent: @escaping @MainActor @Sendable (NotchHUDEvent) -> Void) {
    self.onEvent = onEvent
  }

  @MainActor var isRunning: Bool { tap != nil }
  /// Started, but waiting for Accessibility access.
  @MainActor var isWaitingForAccess: Bool { retryTimer != nil }

  @MainActor func start() {
    guard tap == nil, retryTimer == nil else { return }
    let mask = CGEventMask(1 << 14) // NX_SYSDEFINED: media and brightness keys
    guard let port = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: mask,
      callback: mediaKeyTapCallback,
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
      // Needs Accessibility access; try again until it is granted.
      scheduleRetry()
      return
    }
    let tap = Tap(port: port, source: source)
    self.tap = tap
    lock.withLock { tapPort = port }
    let thread = Thread { [self] in runTap(tap) }
    thread.name = "Kitzi notch media keys"
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

  @MainActor private func scheduleRetry() {
    retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, AXIsProcessTrusted() else { return }
        self.retryTimer?.invalidate()
        self.retryTimer = nil
        self.start()
      }
    }
  }

  // MARK: Tap thread

  /// Returns true to pass the event on to macOS.
  fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let port = lock.withLock({ tapPort }) { CGEvent.tapEnable(tap: port, enable: true) }
      return true
    }
    guard type.rawValue == 14,
          let nsEvent = NSEvent(cgEvent: event),
          nsEvent.type == .systemDefined, nsEvent.subtype.rawValue == 8 else { return true }

    let data = nsEvent.data1
    guard let key = Key(rawValue: (data & 0xFFFF_0000) >> 16) else { return true }
    let state = (data & 0xFF00) >> 8
    let isDown = state == 0xA
    let isRepeat = data & 0x1 != 0
    let flags = nsEvent.modifierFlags
    let option = flags.contains(.option)
    let shift = flags.contains(.shift)
    // ⌥ alone keeps its macOS meaning (open the settings pane).
    if option && !shift { return true }
    let step = option && shift ? Self.step / 4 : Self.step

    switch key {
    case .soundUp, .soundDown, .mute:
      guard let device = SystemVolume.defaultOutputDevice(), SystemVolume.canSetVolume(device) else { return true }
      // The key up of a press we handled is swallowed too.
      guard isDown else { return false }
      let event: NotchHUDEvent
      if key == .mute {
        let muted = !SystemVolume.isMuted(device)
        SystemVolume.setMuted(device, muted)
        event = NotchHUDEvent(kind: .volume, value: SystemVolume.volume(device) ?? 0, muted: muted)
      } else {
        let current = SystemVolume.volume(device) ?? 0
        let target = Self.stepped(current, by: key == .soundUp ? step : -step, grid: step)
        SystemVolume.setVolume(device, target)
        let muted = target <= 0.001
        SystemVolume.setMuted(device, muted)
        event = NotchHUDEvent(kind: .volume, value: target, muted: muted)
        if !isRepeat { SystemVolume.playFeedbackIfEnabled() }
      }
      report(event)
      return false

    case .brightnessUp, .brightnessDown:
      guard let display = DisplayBrightness.builtInDisplay(),
            let current = DisplayBrightness.brightness(of: display) else { return true }
      guard isDown else { return false }
      let target = Self.stepped(current, by: key == .brightnessUp ? step : -step, grid: step)
      guard DisplayBrightness.setBrightness(target, of: display) else { return true }
      report(NotchHUDEvent(kind: .brightness, value: target))
      return false
    }
  }

  private func report(_ event: NotchHUDEvent) {
    let onEvent = onEvent
    DispatchQueue.main.async { onEvent(event) }
  }

  /// Moves `value` by `delta` and snaps it to the nearest step, clamped to 0...1.
  private static func stepped(_ value: Float, by delta: Float, grid: Float) -> Float {
    let moved = ((value + delta) / grid).rounded() * grid
    return min(1, max(0, moved))
  }
}

nonisolated private func mediaKeyTapCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  let tap = Unmanaged<MediaKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
  return tap.handle(type, event) ? Unmanaged.passUnretained(event) : nil
}

// MARK: - Volume (Core Audio)

/// The main volume of the default output device. Safe to call from any thread.
nonisolated enum SystemVolume {
  private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                               mElement: kAudioObjectPropertyElementMain)
  }

  static func defaultOutputDevice() -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return status == noErr && device != kAudioObjectUnknown ? device : nil
  }

  static func canSetVolume(_ device: AudioObjectID) -> Bool {
    var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    guard AudioObjectHasProperty(device, &address) else { return false }
    var settable = DarwinBoolean(false)
    return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
  }

  static func volume(_ device: AudioObjectID) -> Float? {
    var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    var volume = Float32(0)
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return nil }
    return volume
  }

  static func setVolume(_ device: AudioObjectID, _ value: Float) {
    var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    var volume = Float32(min(1, max(0, value)))
    AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
  }

  static func isMuted(_ device: AudioObjectID) -> Bool {
    var address = address(kAudioDevicePropertyMute)
    var muted = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else { return false }
    return muted != 0
  }

  static func setMuted(_ device: AudioObjectID, _ muted: Bool) {
    var address = address(kAudioDevicePropertyMute)
    guard AudioObjectHasProperty(device, &address) else { return }
    var value = UInt32(muted ? 1 : 0)
    AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
  }

  /// "Play feedback when volume is changed" in Sound settings.
  static func playFeedbackIfEnabled() {
    let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
    guard (global?["com.apple.sound.beep.feedback"] as? Int) == 1 else { return }
    DispatchQueue.main.async {
      let path = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
      if FileManager.default.fileExists(atPath: path) {
        NSSound(contentsOfFile: path, byReference: true)?.play()
      } else {
        NSSound.beep()
      }
    }
  }
}

// MARK: - Brightness (DisplayServices, private)

/// Brightness of the built-in display through the private DisplayServices framework,
/// which macOS itself uses for the brightness keys. Safe to call from any thread.
nonisolated enum DisplayBrightness {
  private typealias Getter = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
  private typealias Setter = @convention(c) (CGDirectDisplayID, Float) -> Int32

  private struct Functions: @unchecked Sendable {
    let get: Getter
    let set: Setter
  }

  private static let functions: Functions? = {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
          let get = dlsym(handle, "DisplayServicesGetBrightness"),
          let set = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
    return Functions(get: unsafeBitCast(get, to: Getter.self), set: unsafeBitCast(set, to: Setter.self))
  }()

  static func builtInDisplay() -> CGDirectDisplayID? {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
    return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsAsleep($0) == 0 }
  }

  static func brightness(of display: CGDirectDisplayID) -> Float? {
    guard let functions else { return nil }
    var value: Float = 0
    return functions.get(display, &value) == 0 ? value : nil
  }

  static func setBrightness(_ value: Float, of display: CGDirectDisplayID) -> Bool {
    guard let functions else { return false }
    return functions.set(display, min(1, max(0, value))) == 0
  }
}
