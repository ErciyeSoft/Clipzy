import Foundation
import Observation
import UserNotifications

/// User preferences for the battery module (plain UserDefaults, prefixed with `battery.`).
enum BatteryPrefs {
  static let enabledKey = "battery.enabled"
  static let showPercentKey = "battery.showPercent"
  static let includeMacKey = "battery.includeMacInMenuBar"
  static let hiddenDevicesKey = "battery.hiddenDeviceIDs"
  static let lowAlertKey = "battery.lowBatteryAlert"
  static let thresholdKey = "battery.lowBatteryThreshold"

  static func register() {
    UserDefaults.standard.register(defaults: [
      enabledKey: true,
      showPercentKey: true,
      includeMacKey: false,
      hiddenDevicesKey: "",
      lowAlertKey: true,
      thresholdKey: 20,
    ])
  }

  static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
  static var showPercent: Bool { UserDefaults.standard.bool(forKey: showPercentKey) }
  static var includeMac: Bool { UserDefaults.standard.bool(forKey: includeMacKey) }
  static var lowAlert: Bool { UserDefaults.standard.bool(forKey: lowAlertKey) }
  static var threshold: Int { UserDefaults.standard.integer(forKey: thresholdKey) }

  static var hiddenDeviceIDs: Set<String> {
    get { Set((UserDefaults.standard.string(forKey: hiddenDevicesKey) ?? "").split(separator: "\n").map(String.init)) }
    set { UserDefaults.standard.set(newValue.sorted().joined(separator: "\n"), forKey: hiddenDevicesKey) }
  }

  static func isShownInMenuBar(_ device: BatteryDevice) -> Bool {
    if device.kind == .mac && !includeMac { return false }
    return !hiddenDeviceIDs.contains(device.id)
  }
}

/// Collects battery levels from every source and refreshes them periodically.
@Observable
final class BatteryMonitor {
  private(set) var devices: [BatteryDevice] = []
  @ObservationIgnored var onUpdate: (() -> Void)?

  @ObservationIgnored private var mac: BatteryDevice?
  @ObservationIgnored private var registryDevices: [BatteryDevice] = []
  @ObservationIgnored private var bluetoothDevices: [BatteryDevice] = []
  @ObservationIgnored private let bluetooth = BluetoothBatterySource()
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var alertedDeviceIDs: Set<String> = []

  var isRunning: Bool { pollTask != nil }

  func start() {
    guard pollTask == nil else { return }
    bluetooth.onChange = { [weak self] devices in
      self?.bluetoothDevices = devices
      self?.rebuild()
    }
    bluetooth.start()
    poll()
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        self?.poll()
      }
    }
  }

  func stop() {
    pollTask?.cancel()
    pollTask = nil
    bluetooth.stop()
    mac = nil
    registryDevices = []
    bluetoothDevices = []
    rebuild()
  }

  func poll() {
    mac = MacBatterySource.read()
    registryDevices = RegistryBatterySource.read()
    bluetooth.refresh()
    rebuild()
  }

  private func rebuild() {
    // The same accessory can show up in the registry and over BLE; keep the first by name.
    var seenNames = Set<String>()
    let all = ([mac].compactMap { $0 } + registryDevices + bluetoothDevices).filter {
      seenNames.insert($0.name.lowercased()).inserted
    }
    if all != devices {
      devices = all
    }
    checkLowBattery()
    onUpdate?()
  }

  private func checkLowBattery() {
    guard BatteryPrefs.lowAlert else { return }
    let threshold = BatteryPrefs.threshold
    for device in devices where !device.isCharging {
      if device.percent <= threshold, !alertedDeviceIDs.contains(device.id) {
        alertedDeviceIDs.insert(device.id)
        notifyLow(device)
      } else if device.percent > threshold + 5 {
        alertedDeviceIDs.remove(device.id)
      }
    }
  }

  private func notifyLow(_ device: BatteryDevice) {
    let title = String(localized: "Low battery")
    let body = String(localized: "\(device.name) is at \(device.formattedPercent).")
    let identifier = "battery.low.\(device.id)"
    Task {
      let center = UNUserNotificationCenter.current()
      guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
  }
}
