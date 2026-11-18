import AppKit
import CoreGraphics
import Observation

/// A connected display as the menu shows it.
struct DisplayInfo: Identifiable, Equatable {
  let id: CGDirectDisplayID
  var name: String
  var isBuiltin: Bool
  var isMain: Bool
  /// A virtual display Kitzi created.
  var isVirtual: Bool
  /// The display whose picture this one shows, while mirroring.
  var mirrorOf: CGDirectDisplayID?
  var bounds: CGRect
  var current: DisplayModeOption?
  var resolutions: [ResolutionChoice]
  /// Stable across reconnects: vendor, model and serial number.
  var key: String

  var symbolName: String {
    if isVirtual { return "rectangle.dashed" }
    return isBuiltin ? "laptopcomputer" : "display"
  }
}

/// How Kitzi changes a display's brightness.
enum BrightnessControl: Equatable {
  /// macOS drives the backlight (built-in display, Apple displays).
  case native
  /// DDC/CI: the monitor answered, so its real value and range are known.
  case ddc
  /// DDC/CI without answers: commands are sent, the value is Kitzi's last one.
  case ddcWriteOnly
  /// The picture is darkened through the display's gamma table.
  case software
  /// Still asking the monitor whether it speaks DDC/CI.
  case checking
  /// Nothing to control (virtual displays).
  case unavailable
}

/// What the user picked for an external display in settings.
enum BrightnessPreference: String, CaseIterable, Identifiable {
  case automatic, ddc, software
  var id: String { rawValue }

  var title: String {
    switch self {
    case .automatic: String(localized: "Automatic")
    case .ddc: String(localized: "DDC/CI (monitor's own brightness)")
    case .software: String(localized: "Software dimming")
    }
  }
}

struct DisplayControlState: Equatable {
  var control: BrightnessControl
  var brightness: Double
  var contrast: Double?
  var volume: Double?
  var isMuted: Bool?
}

/// Lists displays and their modes, and changes brightness, resolution and arrangement.
/// Nothing on a display changes until the user asks for it.
@Observable
final class DisplayManager {
  private(set) var displays: [DisplayInfo] = []
  private(set) var controls: [CGDirectDisplayID: DisplayControlState] = [:]
  /// What a display's DDC check found, for settings.
  private(set) var ddcStatus: [String: DDCStatus] = [:]
  let confirmer = DisplayChangeConfirmer()
  let virtualDisplays: VirtualDisplayStore

  enum DDCStatus: Equatable {
    case noChannel, checking, answers, noAnswer
  }

  /// Displays whose brightness keys Kitzi handles (not the ones macOS handles itself).
  @ObservationIgnored var onKeyTargetsChanged: (([BrightnessKeyTap.Target]) -> Void)?

  @ObservationIgnored private var channels: [CGDirectDisplayID: DDCChannel] = [:]
  @ObservationIgnored private var channelDisplays: Set<CGDirectDisplayID> = []
  /// DDC readings per display key; kept while the app runs so reconnecting is instant.
  @ObservationIgnored private var readings: [String: [VCPCode: VCPValue]] = [:]
  @ObservationIgnored private var probing: Set<String> = []
  @ObservationIgnored private var softwareLevels: [CGDirectDisplayID: Double] = [:]
  @ObservationIgnored private let gamma = GammaDimmer()
  @ObservationIgnored private var pendingWrites: [WriteKey: UInt16] = [:]
  @ObservationIgnored private var writesInFlight: Set<WriteKey> = []
  @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

  private struct WriteKey: Hashable {
    let display: CGDirectDisplayID
    let code: VCPCode
  }

  private static let preferencePrefix = "display.brightnessControl."
  private static let lastDDCPrefix = "display.lastDDCBrightness."
  /// Software dimming never goes fully black, so the display stays readable.
  private static let softwareFloor = 0.12

  init(virtualDisplays: VirtualDisplayStore) {
    self.virtualDisplays = virtualDisplays
  }

  func start() {
    guard observers.isEmpty else { return }
    let screens = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    // Monitors may forget DDC/CI state while asleep; ask them again.
    let wake = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.readings = [:]
        self?.channelDisplays = []
        self?.refresh()
      }
    }
    observers = [(NotificationCenter.default, screens), (NSWorkspace.shared.notificationCenter, wake)]
    refresh()
  }

  func stop() {
    observers.forEach { center, observer in center.removeObserver(observer) }
    observers = []
    gamma.restoreAll()
    softwareLevels = [:]
  }

  // MARK: - Listing

  func refresh() {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    ids = Array(ids.prefix(Int(count)))

    let screenNames = Dictionary(NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
      return (number.uint32Value, screen.localizedName)
    }, uniquingKeysWith: { first, _ in first })

    let external = Set(ids.filter { CGDisplayIsBuiltin($0) == 0 && !virtualDisplays.isOurs($0) })
    if external != channelDisplays { discoverChannels(for: external) }

    displays = ids.map { id in
      let isVirtual = virtualDisplays.isOurs(id)
      let mirror = CGDisplayMirrorsDisplay(id)
      let isBuiltin = CGDisplayIsBuiltin(id) != 0
      let modes = DisplayModeCatalog.modes(of: id)
      return DisplayInfo(
        id: id,
        name: virtualDisplays.name(for: id) ?? screenNames[id]
          ?? (isBuiltin ? String(localized: "Built-in Display") : String(localized: "External Display \(Int(id))")),
        isBuiltin: isBuiltin,
        isMain: CGDisplayIsMain(id) != 0,
        isVirtual: isVirtual,
        mirrorOf: mirror == kCGNullDirectDisplay ? nil : mirror,
        bounds: CGDisplayBounds(id),
        current: DisplayModeCatalog.current(of: id),
        resolutions: DisplayModeCatalog.resolutions(from: modes),
        key: Self.key(for: id, builtin: isBuiltin)
      )
    }
    .sorted { lhs, rhs in
      if lhs.isMain != rhs.isMain { return lhs.isMain }
      if lhs.isBuiltin != rhs.isBuiltin { return lhs.isBuiltin }
      return lhs.bounds.minX < rhs.bounds.minX
    }

    let online = Set(ids)
    for id in softwareLevels.keys where !online.contains(id) {
      softwareLevels.removeValue(forKey: id)
      gamma.forget(id)
    }
    // A mode change resets the gamma table; put software dimming back.
    for (id, level) in softwareLevels { gamma.set(Self.gammaFactor(level), for: id) }

    updateControls()
  }

  func info(_ id: CGDirectDisplayID) -> DisplayInfo? {
    displays.first { $0.id == id }
  }

  /// Picks up brightness changed elsewhere (keys, Control Center, auto-brightness).
  func refreshBrightness() {
    for display in displays {
      guard controls[display.id]?.control == .native,
            let value = PrivateDisplayAPI.nativeBrightness(display.id) else { continue }
      controls[display.id]?.brightness = value
    }
  }

  private static func key(for id: CGDirectDisplayID, builtin: Bool) -> String {
    builtin ? "builtin" : "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
  }

  private func discoverChannels(for external: Set<CGDirectDisplayID>) {
    channelDisplays = external
    channels = [:]
    guard !external.isEmpty else { return }
    let endpoints = DDCDiscovery.externalEndpoints()
    var claimed = Set<Int>()
    for id in external.sorted() {
      guard let index = DDCDiscovery.match(id, in: endpoints, claimed: claimed) else { continue }
      claimed.insert(index)
      channels[id] = endpoints[index].channel
    }
  }

  // MARK: - Brightness, contrast, volume

  func preference(for display: DisplayInfo) -> BrightnessPreference {
    UserDefaults.standard.string(forKey: Self.preferencePrefix + display.key).flatMap(BrightnessPreference.init) ?? .automatic
  }

  func setPreference(_ preference: BrightnessPreference, for display: DisplayInfo) {
    UserDefaults.standard.set(preference.rawValue, forKey: Self.preferencePrefix + display.key)
    if preference != .software, softwareLevels.removeValue(forKey: display.id) != nil {
      gamma.restore(display.id)
    }
    updateControls()
  }

  /// Asks the monitor again, e.g. after DDC/CI was turned on in its own menu.
  func recheckDDC(for display: DisplayInfo) {
    readings.removeValue(forKey: display.key)
    channelDisplays = []
    refresh()
  }

  func setBrightness(_ value: Double, for id: CGDirectDisplayID) {
    guard var state = controls[id] else { return }
    let value = min(1, max(0, value))
    state.brightness = value
    controls[id] = state
    switch state.control {
    case .native:
      PrivateDisplayAPI.setNativeBrightness(id, value)
    case .ddc, .ddcWriteOnly:
      guard let display = info(id) else { return }
      let maximum = readings[display.key]?[.brightness]?.maximum ?? 100
      queueWrite(.brightness, UInt16((value * Double(maximum)).rounded()), to: id)
      UserDefaults.standard.set(value, forKey: Self.lastDDCPrefix + display.key)
    case .software:
      softwareLevels[id] = value
      gamma.set(Self.gammaFactor(value), for: id)
    case .checking, .unavailable:
      break
    }
  }

  /// One brightness key press: 1/16 of the range, or 1/64 with ⌥⇧ like macOS.
  @discardableResult
  func stepBrightness(for id: CGDirectDisplayID, up: Bool, fine: Bool) -> Double? {
    guard let state = controls[id], state.control != .checking, state.control != .unavailable else { return nil }
    let step = fine ? 1.0 / 64 : 1.0 / 16
    let next = ((state.brightness + (up ? step : -step)) / step).rounded() * step
    setBrightness(next, for: id)
    return controls[id]?.brightness
  }

  func setContrast(_ value: Double, for id: CGDirectDisplayID) {
    guard let display = info(id), let maximum = readings[display.key]?[.contrast]?.maximum else { return }
    controls[id]?.contrast = value
    queueWrite(.contrast, UInt16((value * Double(maximum)).rounded()), to: id)
  }

  func setVolume(_ value: Double, for id: CGDirectDisplayID) {
    guard let display = info(id), let maximum = readings[display.key]?[.volume]?.maximum else { return }
    controls[id]?.volume = value
    queueWrite(.volume, UInt16((value * Double(maximum)).rounded()), to: id)
  }

  func toggleMute(for id: CGDirectDisplayID) {
    guard let muted = controls[id]?.isMuted else { return }
    controls[id]?.isMuted = !muted
    queueWrite(.mute, muted ? 2 : 1, to: id)
  }

  private static func gammaFactor(_ level: Double) -> Double {
    softwareFloor + (1 - softwareFloor) * level
  }

  private func updateControls() {
    var next: [CGDirectDisplayID: DisplayControlState] = [:]
    var status: [String: DDCStatus] = [:]
    for display in displays {
      if display.isVirtual {
        next[display.id] = DisplayControlState(control: .unavailable, brightness: 1)
        continue
      }
      if PrivateDisplayAPI.canChangeNativeBrightness(display.id) {
        next[display.id] = DisplayControlState(
          control: .native, brightness: PrivateDisplayAPI.nativeBrightness(display.id) ?? 1
        )
        continue
      }
      let preference = preference(for: display)
      let channel = channels[display.id]
      let found = readings[display.key]
      status[display.key] = channel == nil ? .noChannel
        : found == nil ? .checking
        : found?[.brightness] != nil ? .answers : .noAnswer
      if channel != nil, found == nil, preference != .software {
        next[display.id] = DisplayControlState(control: .checking, brightness: controls[display.id]?.brightness ?? 1)
        probe(display)
        continue
      }
      var state = DisplayControlState(control: .software, brightness: softwareLevels[display.id] ?? 1)
      if preference != .software, channel != nil {
        if let brightness = found?[.brightness] {
          state.control = .ddc
          state.brightness = Double(brightness.current) / Double(brightness.maximum)
        } else if preference == .ddc {
          state.control = .ddcWriteOnly
          state.brightness = UserDefaults.standard.object(forKey: Self.lastDDCPrefix + display.key) as? Double ?? 0.5
        }
      }
      if state.control == .ddc, let found {
        state.contrast = found[.contrast].map { Double($0.current) / Double($0.maximum) }
        state.volume = found[.volume].map { Double($0.current) / Double($0.maximum) }
        state.isMuted = found[.mute].map { $0.current == 1 }
      }
      // Keep values just set by the user over what the monitor last reported.
      if let old = controls[display.id], old.control == state.control, state.control != .software {
        state.brightness = old.brightness
        state.contrast = state.contrast.map { old.contrast ?? $0 }
        state.volume = state.volume.map { old.volume ?? $0 }
        state.isMuted = state.isMuted.map { old.isMuted ?? $0 }
      }
      if state.control != .software, softwareLevels.removeValue(forKey: display.id) != nil {
        gamma.restore(display.id)
      }
      next[display.id] = state
    }
    controls = next
    ddcStatus = status
    publishKeyTargets()
  }

  private func probe(_ display: DisplayInfo) {
    guard let channel = channels[display.id], probing.insert(display.key).inserted else { return }
    let key = display.key
    DDCChannel.queue.async { [weak self] in
      var found: [VCPCode: VCPValue] = [:]
      if let brightness = channel.read(.brightness) {
        found[.brightness] = brightness
        for code in [VCPCode.contrast, .volume, .mute] {
          if let value = channel.read(code, attempts: 2) { found[code] = value }
        }
      }
      Task { @MainActor [weak self, found] in
        guard let self else { return }
        self.probing.remove(key)
        self.readings[key] = found
        self.updateControls()
      }
    }
  }

  /// Slider moves arrive faster than a monitor takes them; only the latest value is sent.
  private func queueWrite(_ code: VCPCode, _ value: UInt16, to display: CGDirectDisplayID) {
    let key = WriteKey(display: display, code: code)
    pendingWrites[key] = value
    flushWrite(key)
  }

  private func flushWrite(_ key: WriteKey) {
    guard !writesInFlight.contains(key), let channel = channels[key.display],
          let value = pendingWrites.removeValue(forKey: key) else { return }
    writesInFlight.insert(key)
    DDCChannel.queue.async { [weak self] in
      channel.write(key.code, value)
      Task { @MainActor [weak self] in
        self?.writesInFlight.remove(key)
        self?.flushWrite(key)
      }
    }
  }

  private func publishKeyTargets() {
    let targets = displays.compactMap { display -> BrightnessKeyTap.Target? in
      guard display.mirrorOf == nil, let control = controls[display.id]?.control,
            [.ddc, .ddcWriteOnly, .software].contains(control) else { return nil }
      return BrightnessKeyTap.Target(id: display.id, bounds: display.bounds)
    }
    onKeyTargetsChanged?(targets)
  }

  // MARK: - Resolution and arrangement (each one waits for "Keep")

  var canChangeArrangement: Bool { !confirmer.isPending }

  func apply(_ choice: ResolutionChoice, to id: CGDirectDisplayID) {
    guard let display = info(id),
          let mode = DisplayModeCatalog.bestMode(in: choice, matching: display.current) else { return }
    apply(mode, to: id)
  }

  func apply(_ mode: DisplayModeOption, to id: CGDirectDisplayID) {
    guard canChangeArrangement, let display = info(id), let old = CGDisplayCopyDisplayMode(id),
          old.ioDisplayModeID != mode.id else { return }
    let summary = "\(display.name): \(mode.size.title), \(formattedRefreshRate(mode.refreshRate))"
    run(summary: summary, change: {
      DisplayConfigurator.setMode(mode.mode, for: id)
    }, revert: {
      DisplayConfigurator.setMode(old, for: id)
    })
  }

  /// `master` nil stops mirroring.
  func setMirroring(_ id: CGDirectDisplayID, of master: CGDirectDisplayID?) {
    guard canChangeArrangement, let display = info(id) else { return }
    let old = display.mirrorOf
    guard old != master else { return }
    let summary = master.flatMap { self.info($0) }.map { String(localized: "\(display.name) mirrors \($0.name)") }
      ?? String(localized: "\(display.name) stops mirroring")
    run(summary: summary, change: {
      DisplayConfigurator.setMirror(id, of: master)
    }, revert: {
      DisplayConfigurator.setMirror(id, of: old)
    })
  }

  func makeMain(_ id: CGDirectDisplayID) {
    guard canChangeArrangement, let display = info(id), !display.isMain else { return }
    let old = DisplayConfigurator.origins()
    run(summary: String(localized: "\(display.name) becomes the main display"), change: {
      DisplayConfigurator.makeMain(id)
    }, revert: {
      DisplayConfigurator.setOrigins(old)
    })
  }

  private func run(summary: String, change: @escaping () -> Bool, revert: @escaping () -> Bool) {
    guard change() else {
      NSSound.beep()
      return
    }
    confirmer.ask(summary: summary) { [weak self] keep in
      if !keep { _ = revert() }
      self?.refresh()
    }
  }
}

/// Darkens a display through its gamma table; macOS puts the table back when Kitzi quits.
final class GammaDimmer {
  private struct Table {
    var red: [CGGammaValue]
    var green: [CGGammaValue]
    var blue: [CGGammaValue]
  }

  private var originals: [CGDirectDisplayID: Table] = [:]

  func set(_ factor: Double, for display: CGDirectDisplayID) {
    if factor >= 0.999 {
      restore(display)
      return
    }
    guard let original = originals[display] ?? capture(display) else { return }
    originals[display] = original
    let scale = CGGammaValue(factor)
    var red = original.red.map { $0 * scale }
    var green = original.green.map { $0 * scale }
    var blue = original.blue.map { $0 * scale }
    CGSetDisplayTransferByTable(display, UInt32(red.count), &red, &green, &blue)
  }

  func restore(_ display: CGDirectDisplayID) {
    guard var original = originals.removeValue(forKey: display) else { return }
    CGSetDisplayTransferByTable(display, UInt32(original.red.count), &original.red, &original.green, &original.blue)
  }

  func forget(_ display: CGDirectDisplayID) {
    originals.removeValue(forKey: display)
  }

  func restoreAll() {
    guard !originals.isEmpty else { return }
    originals = [:]
    CGDisplayRestoreColorSyncSettings()
  }

  private func capture(_ display: CGDirectDisplayID) -> Table? {
    let capacity = CGDisplayGammaTableCapacity(display)
    guard capacity > 0 else { return nil }
    var red = [CGGammaValue](repeating: 0, count: Int(capacity))
    var green = red
    var blue = red
    var count: UInt32 = 0
    guard CGGetDisplayTransferByTable(display, capacity, &red, &green, &blue, &count) == .success, count > 0 else { return nil }
    return Table(red: Array(red.prefix(Int(count))), green: Array(green.prefix(Int(count))), blue: Array(blue.prefix(Int(count))))
  }
}
