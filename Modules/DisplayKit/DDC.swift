import CoreGraphics
import Foundation
import IOKit

/// VESA MCCS controls Kitzi uses over DDC/CI.
nonisolated enum VCPCode: UInt8, Sendable, CaseIterable {
  case brightness = 0x10
  case contrast = 0x12
  case volume = 0x62
  /// 1 = muted, 2 = not muted.
  case mute = 0x8D
}

/// One reading of a VCP control.
nonisolated struct VCPValue: Sendable, Equatable {
  var current: UInt16
  var maximum: UInt16
}

/// DDC/CI to one external display over I²C (`IOAVService` on Apple silicon).
///
/// Monitors are slow and sometimes drop a message, so every call retries a few times and
/// all calls must run on `DDCChannel.queue`, never on the main thread.
nonisolated final class DDCChannel: @unchecked Sendable {
  static let queue = DispatchQueue(label: "com.erciyesoft.Kitzi.ddc", qos: .userInitiated)

  private static let displayAddress: UInt32 = 0x37
  private static let hostAddress: UInt32 = 0x51
  /// 0x6E is the display's write address (0x37 << 1); it starts every checksum.
  private static let checksumSeed: UInt8 = 0x6E

  private let service: CFTypeRef

  init(service: CFTypeRef) {
    self.service = service
  }

  func read(_ code: VCPCode, attempts: Int = 3) -> VCPValue? {
    dispatchPrecondition(condition: .onQueue(Self.queue))
    var request: [UInt8] = [0x82, 0x01, code.rawValue]
    request.append(Self.checksum(request))
    for attempt in 0..<attempts {
      if attempt > 0 { usleep(40_000) }
      guard PrivateDisplayAPI.avWrite(service, chip: Self.displayAddress, offset: Self.hostAddress, request) else { continue }
      // The display needs at least 40 ms to prepare its answer.
      usleep(50_000)
      let started = Date()
      if let reply = PrivateDisplayAPI.avRead(service, chip: Self.displayAddress, offset: Self.hostAddress, count: 12),
         let value = Self.parse(reply, code: code) {
        return value
      }
      // A monitor that doesn't speak DDC/CI lets the read time out (seconds); asking again won't help.
      if Date().timeIntervalSince(started) > 1 { return nil }
    }
    return nil
  }

  @discardableResult
  func write(_ code: VCPCode, _ value: UInt16, attempts: Int = 2) -> Bool {
    dispatchPrecondition(condition: .onQueue(Self.queue))
    var message: [UInt8] = [0x84, 0x03, code.rawValue, UInt8(value >> 8), UInt8(value & 0xFF)]
    message.append(Self.checksum(message))
    for attempt in 0..<attempts {
      if attempt > 0 { usleep(20_000) }
      if PrivateDisplayAPI.avWrite(service, chip: Self.displayAddress, offset: Self.hostAddress, message) {
        // Back-to-back messages get lost on some monitors.
        usleep(10_000)
        return true
      }
    }
    return false
  }

  private static func checksum(_ bytes: [UInt8]) -> UInt8 {
    bytes.reduce(checksumSeed ^ UInt8(hostAddress), ^)
  }

  /// Reply: 0x6E, 0x88, 0x02 (VCP reply), result, code, type, max hi, max lo, cur hi, cur lo, checksum.
  static func parse(_ reply: [UInt8], code: VCPCode) -> VCPValue? {
    guard let start = reply.indices.first(where: { index in
      index + 7 < reply.count && reply[index] == 0x02 && reply[index + 2] == code.rawValue
    }) else { return nil }
    guard reply[start + 1] == 0x00 else { return nil } // 0x01 = unsupported control
    let maximum = UInt16(reply[start + 4]) << 8 | UInt16(reply[start + 5])
    let current = UInt16(reply[start + 6]) << 8 | UInt16(reply[start + 7])
    guard maximum > 0 else { return nil }
    return VCPValue(current: min(current, maximum), maximum: maximum)
  }
}

/// Finds the I²C channel of each external display and the CoreGraphics display it belongs to.
nonisolated enum DDCDiscovery {
  struct Endpoint: Sendable {
    var vendor: UInt32?
    var product: UInt32?
    var serial: UInt32?
    var name: String?
    var channel: DDCChannel
  }

  /// On Apple silicon each display controller (`dispext0`, …) has an `IOMobileFramebufferShim`
  /// that describes the attached display. The `DCPAVServiceProxy` that talks to that display
  /// lives in the controller's coprocessor subtree, under an entry named after the controller
  /// (`dispext0:dcpav-service-epic:0`), so the two are paired by that name.
  static func externalEndpoints() -> [Endpoint] {
    guard PrivateDisplayAPI.supportsAVService else { return [] }
    var proxies = externalProxies()
    defer { proxies.values.forEach { IOObjectRelease($0) } }
    guard !proxies.isEmpty else { return [] }

    var endpoints: [Endpoint] = []
    var framebuffers: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &framebuffers) == KERN_SUCCESS else {
      return []
    }
    defer { IOObjectRelease(framebuffers) }
    while case let framebuffer = IOIteratorNext(framebuffers), framebuffer != 0 {
      defer { IOObjectRelease(framebuffer) }
      guard let attributes = property(framebuffer, "DisplayAttributes") as? [String: Any],
            let product = attributes["ProductAttributes"] as? [String: Any],
            let controller = parentName(of: framebuffer),
            let proxy = proxies.removeValue(forKey: controller) else { continue }
      defer { IOObjectRelease(proxy) }
      guard let service = PrivateDisplayAPI.makeAVService(for: proxy) else { continue }
      endpoints.append(Endpoint(
        vendor: (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
        product: (product["ProductID"] as? NSNumber)?.uint32Value,
        serial: (product["SerialNumber"] as? NSNumber)?.uint32Value,
        name: product["ProductName"] as? String,
        channel: DDCChannel(service: service)
      ))
    }
    return endpoints
  }

  /// The best endpoint for a display: same vendor, model and serial, or the only unclaimed one.
  static func match(_ display: CGDirectDisplayID, in endpoints: [Endpoint], claimed: Set<Int>) -> Int? {
    let vendor = CGDisplayVendorNumber(display)
    let model = CGDisplayModelNumber(display)
    let serial = CGDisplaySerialNumber(display)
    let scored = endpoints.indices.filter { !claimed.contains($0) }.map { index -> (Int, Int) in
      let endpoint = endpoints[index]
      var score = 0
      if endpoint.vendor == vendor { score += 1 }
      if endpoint.product == model { score += 1 }
      if endpoint.serial == serial, serial != 0 { score += 2 }
      return (index, score)
    }
    if let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 2 { return best.0 }
    return scored.count == 1 ? scored[0].0 : nil
  }

  /// External `DCPAVServiceProxy` entries by controller name (`dispext0`).
  private static func externalProxies() -> [String: io_service_t] {
    var proxies: [String: io_service_t] = [:]
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else {
      return [:]
    }
    defer { IOObjectRelease(iterator) }
    while case let proxy = IOIteratorNext(iterator), proxy != 0 {
      guard property(proxy, "Location") as? String == "External",
            let parent = parentName(of: proxy),
            let controller = parent.split(separator: ":").first.map(String.init),
            proxies[controller] == nil else {
        IOObjectRelease(proxy)
        continue
      }
      proxies[controller] = proxy
    }
    return proxies
  }

  private static func parentName(of entry: io_registry_entry_t) -> String? {
    var parent: io_registry_entry_t = 0
    guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(parent) }
    var name = [CChar](repeating: 0, count: 128) // io_name_t
    guard IORegistryEntryGetName(parent, &name) == KERN_SUCCESS else { return nil }
    return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
  }
}
