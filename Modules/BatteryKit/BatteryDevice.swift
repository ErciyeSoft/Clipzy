import Foundation

enum BatteryDeviceKind: String, Sendable {
  case mac, keyboard, mouse, trackpad, headphones, gamepad, other

  var systemImage: String {
    switch self {
    case .mac: "laptopcomputer"
    case .keyboard: "keyboard"
    case .mouse: "computermouse"
    case .trackpad: "rectangle.and.hand.point.up.left"
    case .headphones: "headphones"
    case .gamepad: "gamecontroller"
    case .other: "dot.radiowaves.left.and.right"
    }
  }

  /// Best-effort guess from the product name; Bluetooth LE gives us nothing better.
  static func guess(fromName name: String) -> BatteryDeviceKind {
    let name = name.lowercased()
    let rules: [(BatteryDeviceKind, [String])] = [
      (.keyboard, ["keyboard", "keys", "klavye", "k380", "k780", "k860"]),
      (.trackpad, ["trackpad"]),
      (.mouse, ["mouse", "fare", "pebble", "mx master", "mx anywhere", "lift", "m350", "m720", "ergo"]),
      (.headphones, ["airpods", "buds", "headphone", "headset", "beats", "wh-", "wf-", "earbuds"]),
      (.gamepad, ["controller", "dualsense", "dualshock", "xbox", "joy-con"]),
    ]
    return rules.first { _, words in words.contains { name.contains($0) } }?.0 ?? .other
  }
}

struct BatteryDevice: Identifiable, Equatable, Sendable {
  let id: String
  var name: String
  var kind: BatteryDeviceKind
  var percent: Int
  var isCharging: Bool

  var formattedPercent: String {
    (Double(percent) / 100).formatted(.percent.precision(.fractionLength(0)))
  }
}
