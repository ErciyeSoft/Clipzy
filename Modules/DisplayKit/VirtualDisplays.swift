import AppKit
import CoreGraphics
import Observation

/// Aspect ratios offered for virtual displays, with the usual sizes of each (in points).
enum VirtualAspect: String, Codable, CaseIterable, Identifiable {
  case wide16x9, wide16x10, ultrawide21x9, superwide32x9, classic4x3, tall3x2

  var id: String { rawValue }

  var title: String {
    switch self {
    case .wide16x9: "16:9"
    case .wide16x10: "16:10"
    case .ultrawide21x9: "21:9"
    case .superwide32x9: "32:9"
    case .classic4x3: "4:3"
    case .tall3x2: "3:2"
    }
  }

  var sizes: [VirtualSize] {
    let list: [(Int, Int)] = switch self {
    case .wide16x9: [(1280, 720), (1600, 900), (1920, 1080), (2048, 1152), (2304, 1296), (2560, 1440), (2880, 1620), (3200, 1800), (3840, 2160)]
    case .wide16x10: [(1280, 800), (1440, 900), (1680, 1050), (1920, 1200), (2240, 1400), (2560, 1600), (2880, 1800), (3360, 2100), (3840, 2400)]
    case .ultrawide21x9: [(1720, 720), (2560, 1080), (3440, 1440), (3840, 1600)]
    case .superwide32x9: [(2560, 720), (3840, 1080), (5120, 1440)]
    case .classic4x3: [(1024, 768), (1280, 960), (1400, 1050), (1600, 1200), (2048, 1536)]
    case .tall3x2: [(1440, 960), (1800, 1200), (2160, 1440), (2400, 1600), (3000, 2000)]
    }
    return list.map { VirtualSize(width: $0.0, height: $0.1) }
  }
}

struct VirtualSize: Codable, Hashable, Identifiable {
  var width: Int
  var height: Int
  var id: String { "\(width)x\(height)" }
  var title: String { "\(width) × \(height)" }
}

/// A virtual display the user made. It exists only while Kitzi runs; connected ones come
/// back when Kitzi starts.
struct VirtualDisplayConfig: Codable, Identifiable, Equatable {
  var id = UUID()
  var name: String
  var aspect: VirtualAspect
  /// The largest resolution, in points; every smaller size of the aspect is offered too.
  var largest: VirtualSize
  var hiDPI: Bool
  var refreshRate: Double
  var serialNumber: UInt32 = .random(in: 1...UInt32.max)
  var isConnected = true

  /// Backing store of a HiDPI mode is twice as wide; Kitzi stops at 8K.
  static let maxBackingWidth = 7680

  var modes: [VirtualSize] {
    aspect.sizes.filter { $0.width <= largest.width }
  }

  var summary: String {
    let size = hiDPI ? String(localized: "\(largest.title) (HiDPI)") : largest.title
    return "\(aspect.title) · \(size) · \(formattedRefreshRate(refreshRate))"
  }

  static func allowedSizes(for aspect: VirtualAspect, hiDPI: Bool) -> [VirtualSize] {
    aspect.sizes.filter { !hiDPI || $0.width * 2 <= maxBackingWidth }
  }
}

@Observable
final class VirtualDisplayStore {
  private(set) var configs: [VirtualDisplayConfig] = []
  /// Why a display couldn't be created, by config id.
  private(set) var failures: Set<UUID> = []

  @ObservationIgnored private var live: [UUID: (object: NSObject, displayID: CGDirectDisplayID)] = [:]

  private static let storageKey = "display.virtualDisplays"
  /// Vendor id written into virtual displays so they can be told apart.
  static let vendorID: UInt32 = 0xC1A0

  var isSupported: Bool { PrivateDisplayAPI.supportsVirtualDisplays }

  init() {
    if let data = UserDefaults.standard.data(forKey: Self.storageKey),
       let saved = try? JSONDecoder().decode([VirtualDisplayConfig].self, from: data) {
      configs = saved
    }
  }

  /// Brings back the displays that were connected when Kitzi last quit.
  func connectSaved() {
    for config in configs where config.isConnected { connect(config) }
  }

  func disconnectAll() {
    live = [:]
  }

  func isOurs(_ display: CGDirectDisplayID) -> Bool {
    live.values.contains { $0.displayID == display }
  }

  func name(for display: CGDirectDisplayID) -> String? {
    guard let id = live.first(where: { $0.value.displayID == display })?.key else { return nil }
    return configs.first { $0.id == id }?.name
  }

  func displayID(for config: VirtualDisplayConfig) -> CGDirectDisplayID? {
    live[config.id]?.displayID
  }

  func add(_ config: VirtualDisplayConfig) {
    configs.append(config)
    save()
    guard config.isConnected else { return }
    connect(config)
    // macOS starts a new display at its largest pixel size; start a HiDPI one at its largest
    // HiDPI size instead. Later macOS remembers whatever the user picks.
    guard config.hiDPI, let displayID = live[config.id]?.displayID else { return }
    Task {
      // The window server picks its own mode right after the display appears; go after it.
      try? await Task.sleep(for: .seconds(1))
      let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
      let modes = (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
      if let mode = modes.first(where: {
        $0.width == config.largest.width && $0.height == config.largest.height && $0.pixelWidth == config.largest.width * 2
      }) {
        _ = DisplayConfigurator.setMode(mode, for: displayID)
      }
    }
  }

  func remove(_ config: VirtualDisplayConfig) {
    live.removeValue(forKey: config.id)
    failures.remove(config.id)
    configs.removeAll { $0.id == config.id }
    save()
  }

  func setConnected(_ connected: Bool, for config: VirtualDisplayConfig) {
    guard let index = configs.firstIndex(where: { $0.id == config.id }) else { return }
    configs[index].isConnected = connected
    save()
    if connected {
      connect(configs[index])
    } else {
      live.removeValue(forKey: config.id)
      failures.remove(config.id)
    }
  }

  private func connect(_ config: VirtualDisplayConfig) {
    guard live[config.id] == nil else { return }
    let scale = config.hiDPI ? 2 : 1
    // Sized like a ~110 ppi desktop monitor at the largest resolution.
    let millimeters = CGSize(width: Double(config.largest.width) / 110 * 25.4,
                             height: Double(config.largest.height) / 110 * 25.4)
    let spec = PrivateDisplayAPI.VirtualDisplaySpec(
      name: config.name,
      maxPixelsWide: UInt32(config.largest.width * scale),
      maxPixelsHigh: UInt32(config.largest.height * scale),
      sizeInMillimeters: millimeters,
      vendorID: Self.vendorID,
      productID: UInt32(VirtualAspect.allCases.firstIndex(of: config.aspect) ?? 0) + 1,
      serialNumber: config.serialNumber,
      hiDPI: config.hiDPI,
      modes: config.modes.map { (UInt32($0.width), UInt32($0.height), config.refreshRate) }
    )
    if let created = PrivateDisplayAPI.makeVirtualDisplay(spec) {
      live[config.id] = created
      failures.remove(config.id)
    } else {
      failures.insert(config.id)
    }
  }

  private func save() {
    if let data = try? JSONEncoder().encode(configs) {
      UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
  }
}
