import Foundation
import IOKit.ps
import Observation

/// The Mac's own battery, for the header and the plug-in / unplug notices.
@Observable
final class NotchBatteryModel {
  private(set) var hasBattery = false
  /// Percent, 0...100.
  private(set) var level = 0
  private(set) var isCharging = false
  private(set) var onACPower = false

  @ObservationIgnored var onNotice: ((BatteryNotice) -> Void)?
  @ObservationIgnored private var source: CFRunLoopSource?
  /// Low battery notices are shown once when the level drops past each threshold.
  @ObservationIgnored private static let lowThresholds = [20, 10]

  func start() {
    guard source == nil else { return }
    refresh(notify: false)
    let context = Unmanaged.passUnretained(self).toOpaque()
    guard let created = IOPSNotificationCreateRunLoopSource(powerSourceCallback, context)?.takeRetainedValue() else { return }
    CFRunLoopAddSource(CFRunLoopGetMain(), created, .defaultMode)
    source = created
  }

  func stop() {
    guard let source else { return }
    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
    self.source = nil
  }

  fileprivate func refresh(notify: Bool) {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
    for source in sources {
      guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
            (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
            let current = description[kIOPSCurrentCapacityKey] as? Int,
            let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
      let newLevel = min(100, current * 100 / maximum)
      let newAC = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
      let newCharging = description[kIOPSIsChargingKey] as? Bool ?? false
      let oldLevel = level
      let wasAC = onACPower
      let hadBattery = hasBattery

      hasBattery = true
      level = newLevel
      onACPower = newAC
      isCharging = newCharging

      guard notify, hadBattery else { return }
      if newAC != wasAC {
        onNotice?(BatteryNotice(kind: newAC ? .charging : .onBattery, level: newLevel))
      } else if !newAC, Self.lowThresholds.contains(where: { oldLevel > $0 && newLevel <= $0 }) {
        onNotice?(BatteryNotice(kind: .low, level: newLevel))
      }
      return
    }
    hasBattery = false
  }
}

nonisolated private func powerSourceCallback(_ context: UnsafeMutableRawPointer?) {
  guard let context else { return }
  let model = Unmanaged<NotchBatteryModel>.fromOpaque(context).takeUnretainedValue()
  // Added to the main run loop, so this runs on the main thread.
  MainActor.assumeIsolated { model.refresh(notify: true) }
}
