import CoreBluetooth
import Foundation
import IOKit
import IOKit.ps

/// The Mac's internal battery, from the power sources API.
enum MacBatterySource {
  static func read() -> BatteryDevice? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
      return nil
    }
    for source in sources {
      guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
            (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
            let current = description[kIOPSCurrentCapacityKey] as? Int,
            let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else {
        continue
      }
      return BatteryDevice(
        id: "mac",
        name: Host.current().localizedName ?? "Mac",
        kind: .mac,
        percent: min(100, current * 100 / maximum),
        isCharging: description[kIOPSIsChargingKey] as? Bool ?? false
      )
    }
    return nil
  }
}

/// Apple accessories (Magic Keyboard, Mouse, Trackpad) publish `BatteryPercent` in the IO registry.
enum RegistryBatterySource {
  static func read() -> [BatteryDevice] {
    var iterator: io_iterator_t = 0
    let matching = IOServiceMatching("AppleDeviceManagementHIDEventService")
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
      return []
    }
    defer { IOObjectRelease(iterator) }

    var devices: [BatteryDevice] = []
    while case let service = IOIteratorNext(iterator), service != 0 {
      defer { IOObjectRelease(service) }
      guard let percent = property(service, "BatteryPercent") as? Int else { continue }
      let name = property(service, "Product") as? String ?? "Bluetooth"
      let identifier = property(service, "SerialNumber") as? String
        ?? property(service, "DeviceAddress") as? String
        ?? name
      devices.append(BatteryDevice(
        id: "hid:\(identifier)",
        name: name,
        kind: .guess(fromName: name),
        percent: percent,
        isCharging: false
      ))
    }
    return devices
  }

  private static func property(_ service: io_object_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
  }
}

/// Bluetooth LE accessories (e.g. Logitech) expose the standard Battery Service (0x180F).
/// We attach to the connection the system already has and read Battery Level (0x2A19).
final class BluetoothBatterySource: NSObject {
  nonisolated private static let serviceID = "180F"
  nonisolated private static let levelID = "2A19"

  var onChange: (([BatteryDevice]) -> Void)?

  private var central: CBCentralManager?
  private var peripherals: [UUID: CBPeripheral] = [:]
  private var levels: [UUID: Int] = [:]

  func start() {
    guard central == nil else {
      refresh()
      return
    }
    central = CBCentralManager(delegate: self, queue: .main)
  }

  func stop() {
    for peripheral in peripherals.values {
      central?.cancelPeripheralConnection(peripheral)
    }
    peripherals.removeAll()
    levels.removeAll()
    central = nil
    publish()
  }

  func refresh() {
    guard let central, central.state == .poweredOn else { return }
    let connected = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: Self.serviceID)])
    let connectedIDs = Set(connected.map(\.identifier))
    for id in peripherals.keys where !connectedIDs.contains(id) {
      peripherals[id] = nil
      levels[id] = nil
    }
    for peripheral in connected {
      if peripherals[peripheral.identifier] == nil {
        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
      }
      if peripheral.state == .connected {
        readLevel(of: peripheral)
      } else {
        central.connect(peripheral)
      }
    }
    publish()
  }

  private func readLevel(of peripheral: CBPeripheral) {
    let service = peripheral.services?.first { $0.uuid == CBUUID(string: Self.serviceID) }
    if let level = service?.characteristics?.first(where: { $0.uuid == CBUUID(string: Self.levelID) }) {
      peripheral.readValue(for: level)
    } else {
      peripheral.discoverServices([CBUUID(string: Self.serviceID)])
    }
  }

  private func record(level: Int, for id: UUID) {
    levels[id] = level
    publish()
  }

  private func publish() {
    let devices = peripherals.values.compactMap { peripheral -> BatteryDevice? in
      guard let level = levels[peripheral.identifier] else { return nil }
      let name = peripheral.name ?? "Bluetooth"
      return BatteryDevice(
        id: "ble:\(peripheral.identifier.uuidString)",
        name: name,
        kind: .guess(fromName: name),
        percent: level,
        isCharging: false
      )
    }
    onChange?(devices.sorted { $0.name.localizedCompare($1.name) == .orderedAscending })
  }
}

extension BluetoothBatterySource: CBCentralManagerDelegate, CBPeripheralDelegate {
  nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
    MainActor.assumeIsolated { refresh() }
  }

  nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    peripheral.discoverServices([CBUUID(string: Self.serviceID)])
  }

  nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: Self.serviceID) }) else {
      return
    }
    peripheral.discoverCharacteristics([CBUUID(string: Self.levelID)], for: service)
  }

  nonisolated func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    guard let level = service.characteristics?.first(where: { $0.uuid == CBUUID(string: Self.levelID) }) else {
      return
    }
    peripheral.readValue(for: level)
    if level.properties.contains(.notify) {
      peripheral.setNotifyValue(true, for: level)
    }
  }

  nonisolated func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard characteristic.uuid == CBUUID(string: Self.levelID), let byte = characteristic.value?.first else {
      return
    }
    let id = peripheral.identifier
    MainActor.assumeIsolated { record(level: min(100, Int(byte)), for: id) }
  }
}
