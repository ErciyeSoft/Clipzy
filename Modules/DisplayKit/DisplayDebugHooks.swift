#if DEBUG
import AppKit
import CoreGraphics

/// Test hook for Debug builds: drive the display manager from a script.
///
///     /usr/bin/swift -e 'import Foundation; DistributedNotificationCenter.default()
///       .postNotificationName(.init("com.erciyesoft.Kitzi.debug.display"), object: "dump:/tmp/d.json",
///       userInfo: nil, deliverImmediately: true)'
///
/// Commands (the notification's object): `dump:<path>`, `menu`, `brightness:<id>:<0-1>`,
/// `key:<up|down>` (posts a real brightness key event), `mode:<id>:<modeID>`, `keep`, `revert`,
/// `mirror:<id>:<masterID or 0>`, `main:<id>`, `virtual:add`, `virtual:remove-all`,
/// `pref:<id>:<automatic|ddc|software>`.
@MainActor
final class DisplayDebugHooks {
  private let manager: DisplayManager
  private let store: VirtualDisplayStore
  private let openMenu: () -> Void
  private let isKeyTapRunning: () -> Bool
  private var observer: NSObjectProtocol?

  init(manager: DisplayManager, store: VirtualDisplayStore, openMenu: @escaping () -> Void, isKeyTapRunning: @escaping () -> Bool) {
    self.manager = manager
    self.store = store
    self.openMenu = openMenu
    self.isKeyTapRunning = isKeyTapRunning
    observer = DistributedNotificationCenter.default().addObserver(
      forName: .init("com.erciyesoft.Kitzi.debug.display"), object: nil, queue: .main
    ) { [weak self] note in
      let command = note.object as? String ?? ""
      MainActor.assumeIsolated { self?.run(command) }
    }
  }

  private func run(_ command: String) {
    let parts = command.split(separator: ":", maxSplits: 2).map(String.init)
    let id = parts.count > 1 ? CGDirectDisplayID(parts[1]) ?? 0 : 0
    switch parts.first {
    case "dump" where parts.count > 1:
      dump(to: command.dropFirst(5).description)
    case "menu":
      openMenu()
    case "brightness" where parts.count == 3:
      manager.setBrightness(Double(parts[2]) ?? 1, for: id)
    case "key" where parts.count == 2:
      postBrightnessKey(up: parts[1] == "up")
    case "mode" where parts.count == 3:
      let mode = manager.info(id)?.resolutions.flatMap(\.modes).first { $0.id == Int32(parts[2]) }
      if let mode { manager.apply(mode, to: id) }
    case "keep":
      manager.confirmer.finish(keep: true)
    case "revert":
      manager.confirmer.finish(keep: false)
    case "mirror" where parts.count == 3:
      let master = CGDirectDisplayID(parts[2]) ?? 0
      manager.setMirroring(id, of: master == 0 ? nil : master)
    case "main":
      manager.makeMain(id)
    case "virtual" where parts.count == 2 && parts[1] == "add":
      store.add(VirtualDisplayConfig(name: "Kitzi Test Display", aspect: .wide16x9,
                                     largest: VirtualSize(width: 1920, height: 1080), hiDPI: true, refreshRate: 60))
    case "virtual" where parts.count == 2 && parts[1] == "remove-all":
      store.configs.forEach(store.remove)
    case "pref" where parts.count == 3:
      if let display = manager.info(id), let preference = BrightnessPreference(rawValue: parts[2]) {
        manager.setPreference(preference, for: display)
      }
    default:
      NSLog("DisplayDebugHooks: unknown command %@", command)
    }
  }

  /// Media keys arrive as NX_SYSDEFINED events with subtype 8; post one at the HID level.
  private func postBrightnessKey(up: Bool) {
    let code = up ? 2 : 3
    for state in [0x0A, 0x0B] {
      let event = NSEvent.otherEvent(
        with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, subtype: 8, data1: (code << 16) | (state << 8), data2: -1
      )
      event?.cgEvent?.post(tap: .cghidEventTap)
    }
  }

  private func dump(to path: String) {
    let displays = manager.displays.map { display -> [String: Any] in
      let state = manager.controls[display.id]
      var gammaSample: Double = -1
      var red = [CGGammaValue](repeating: 0, count: 256), green = red, blue = red
      var count: UInt32 = 0
      if CGGetDisplayTransferByTable(display.id, 256, &red, &green, &blue, &count) == .success, count > 0 {
        gammaSample = Double(red[Int(count) - 1])
      }
      return [
        "id": display.id,
        "name": display.name,
        "builtin": display.isBuiltin,
        "main": display.isMain,
        "virtual": display.isVirtual,
        "mirrorOf": display.mirrorOf ?? 0,
        "bounds": NSStringFromRect(display.bounds),
        "current": display.current.map { "\($0.id) \($0.size.title) \(formattedRefreshRate($0.refreshRate)) px \($0.pixelWidth)x\($0.pixelHeight)" } ?? "",
        "resolutions": display.resolutions.count,
        "hiddenResolutions": display.resolutions.filter(\.isHidden).count,
        "modes": display.resolutions.flatMap(\.modes).map { "\($0.id) \($0.width)x\($0.height)\($0.isHiDPI ? "@2x" : "") \($0.refreshRate)\($0.isHidden ? " hidden" : "")" },
        "control": state.map { "\($0.control)" } ?? "",
        "brightness": state?.brightness ?? -1,
        "nativeBrightness": PrivateDisplayAPI.nativeBrightness(display.id) ?? -1,
        "contrast": state?.contrast ?? -1,
        "volume": state?.volume ?? -1,
        "gammaTop": gammaSample,
        "ddcStatus": manager.ddcStatus[display.key].map { "\($0)" } ?? "",
      ]
    }
    let info: [String: Any] = [
      "displays": displays,
      "pending": manager.confirmer.isPending,
      "pendingSummary": manager.confirmer.summary,
      "secondsLeft": manager.confirmer.secondsLeft,
      "virtualConfigs": store.configs.map { "\($0.name) \($0.summary) connected=\($0.isConnected) id=\(store.displayID(for: $0) ?? 0)" },
      "keyTapRunning": isKeyTapRunning(),
      "trusted": AXIsProcessTrusted(),
    ]
    if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: URL(fileURLWithPath: path))
    }
  }
}
#endif
