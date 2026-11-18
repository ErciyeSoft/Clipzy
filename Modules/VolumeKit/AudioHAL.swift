import AppKit
import AudioToolbox
import CoreAudio

/// Small typed wrappers around the Core Audio HAL property API.
nonisolated enum AudioHAL {
  static let system = AudioObjectID(kAudioObjectSystemObject)

  static func address(_ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
  }

  static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                       default fallback: T) -> T {
    var address = address(selector, scope: scope, element: element)
    var result = fallback
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &result) {
      AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
    }
    return status == noErr ? result : fallback
  }

  static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = address(selector)
    var result: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result)
    guard status == noErr, let result else { return nil }
    return result.takeRetainedValue() as String
  }

  static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
    var address = address(selector)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
  }

  /// Number of streams a device has in a scope (input or output).
  static func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
    var address = address(kAudioDevicePropertyStreams, scope: scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
    return Int(size) / MemoryLayout<AudioObjectID>.size
  }

  static var defaultOutputDevice: AudioObjectID {
    value(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(kAudioObjectUnknown))
  }

  static func deviceUID(_ device: AudioObjectID) -> String? {
    string(device, kAudioDevicePropertyDeviceUID)
  }

  static func deviceName(_ device: AudioObjectID) -> String? {
    string(device, kAudioObjectPropertyName)
  }

  // MARK: Output volume

  /// Main volume of a device as 0...1, as the menu bar volume control sees it.
  static func mainVolume(_ device: AudioObjectID) -> Float? {
    var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
    guard AudioObjectHasProperty(device, &address) else { return nil }
    var volume: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr ? volume : nil
  }

  static func setMainVolume(_ device: AudioObjectID, _ volume: Float) {
    var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
    var value = Float32(max(0, min(1, volume)))
    AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
  }

  static func isMuted(_ device: AudioObjectID) -> Bool {
    value(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, default: UInt32(0)) != 0
  }

  static func setMuted(_ device: AudioObjectID, _ muted: Bool) {
    var address = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
    var value = UInt32(muted ? 1 : 0)
    AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
  }

  // MARK: Listening

  /// Calls `handler` on the main queue whenever the property changes. Keep the returned token.
  static func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     handler: @escaping @Sendable () -> Void) -> AudioListenerToken {
    var address = address(selector, scope: scope)
    let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
    AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block)
    return AudioListenerToken(object: object, address: address, block: block)
  }
}

/// Removes its Core Audio property listener when released.
nonisolated final class AudioListenerToken: @unchecked Sendable {
  private let object: AudioObjectID
  private var address: AudioObjectPropertyAddress
  private let block: AudioObjectPropertyListenerBlock

  init(object: AudioObjectID, address: AudioObjectPropertyAddress, block: @escaping AudioObjectPropertyListenerBlock) {
    self.object = object
    self.address = address
    self.block = block
  }

  deinit {
    AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
  }
}

/// One process that has audio I/O open, as Core Audio reports it.
nonisolated struct AudioProcess: Sendable {
  let objectID: AudioObjectID
  let pid: pid_t
  let isPlaying: Bool

  static func all() -> [AudioProcess] {
    AudioHAL.objects(AudioHAL.system, kAudioHardwarePropertyProcessObjectList).compactMap { object in
      let pid = AudioHAL.value(object, kAudioProcessPropertyPID, default: pid_t(-1))
      guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
      let playing = AudioHAL.value(object, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
      return AudioProcess(objectID: object, pid: pid, isPlaying: playing)
    }
  }

  /// The app a process belongs to: helpers like "Google Chrome Helper" live inside
  /// Google Chrome.app, so the outermost `.app` in the executable path is the app.
  var appURL: URL? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    // System services (Control Center, Siri, WebKit helpers) are not apps the user would mix.
    guard !path.hasPrefix("/System/Library/"), !path.hasPrefix("/usr/") else { return nil }
    var url = URL(fileURLWithPath: "/")
    for component in URL(fileURLWithPath: path).pathComponents.dropFirst() {
      url.appendPathComponent(component)
      if component.hasSuffix(".app") { return url }
    }
    return nil
  }
}
