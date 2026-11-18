import AppKit
import CoreGraphics

/// One way a display can run: a size in points, the pixels behind it and a refresh rate.
struct DisplayModeOption: Identifiable, Hashable {
  let id: Int32
  let width: Int
  let height: Int
  let pixelWidth: Int
  let pixelHeight: Int
  let refreshRate: Double
  /// macOS's own pick for this display.
  let isNative: Bool
  /// Left out of System Settings: low-resolution duplicates and modes not meant for the desktop.
  /// HiDPI modes a display can use for the desktop always count as shown; macOS leaves the
  /// ones of virtual displays out of its standard list.
  let isHidden: Bool
  let mode: CGDisplayMode

  var isHiDPI: Bool { pixelWidth > width }
  var size: ResolutionKey { ResolutionKey(width: width, height: height, hiDPI: isHiDPI) }

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }

  // ioFlags from IOGraphicsTypes.h
  private static let nativeFlag: UInt32 = 0x0200_0000

  init(_ mode: CGDisplayMode, isHidden: Bool) {
    id = mode.ioDisplayModeID
    width = mode.width
    height = mode.height
    pixelWidth = mode.pixelWidth
    pixelHeight = mode.pixelHeight
    refreshRate = mode.refreshRate
    isNative = mode.ioFlags & Self.nativeFlag != 0
    let isHiDPI = mode.pixelWidth > mode.width
    self.isHidden = !mode.isUsableForDesktopGUI() || (isHidden && !isHiDPI)
    self.mode = mode
  }
}

/// A resolution as the user picks it; its refresh rates are separate choices.
struct ResolutionKey: Hashable, Comparable {
  let width: Int
  let height: Int
  let hiDPI: Bool

  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.width != rhs.width { return lhs.width > rhs.width }
    if lhs.height != rhs.height { return lhs.height > rhs.height }
    return lhs.hiDPI && !rhs.hiDPI
  }

  var title: String {
    let size = "\(width) × \(height)"
    return hiDPI ? String(localized: "\(size) (HiDPI)") : size
  }
}

/// A resolution and the modes (refresh rates) that offer it.
struct ResolutionChoice: Identifiable, Hashable {
  let key: ResolutionKey
  let modes: [DisplayModeOption]
  var id: ResolutionKey { key }
  var isHidden: Bool { modes.allSatisfy(\.isHidden) }
  var isNative: Bool { modes.contains(where: \.isNative) }
}

enum DisplayModeCatalog {
  /// Every mode of a display, including the ones System Settings hides.
  static func modes(of display: CGDirectDisplayID) -> [DisplayModeOption] {
    let all = copyModes(display, options: [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary)
    let standard = Set(copyModes(display, options: nil).map(\.ioDisplayModeID))
    var seen = Set<String>()
    return all.compactMap { mode in
      let option = DisplayModeOption(mode, isHidden: !standard.contains(mode.ioDisplayModeID))
      // Some displays list the same mode twice under different ids.
      let signature = "\(option.width)x\(option.height)/\(option.pixelWidth)x\(option.pixelHeight)@\(option.refreshRate)"
      guard seen.insert(signature).inserted else { return nil }
      return option
    }
  }

  static func current(of display: CGDirectDisplayID) -> DisplayModeOption? {
    guard let mode = CGDisplayCopyDisplayMode(display) else { return nil }
    return DisplayModeOption(mode, isHidden: false)
  }

  static func resolutions(from modes: [DisplayModeOption]) -> [ResolutionChoice] {
    Dictionary(grouping: modes, by: \.size)
      .map { key, modes in
        ResolutionChoice(key: key, modes: modes.sorted {
          // Prefer modes System Settings lists, then the higher refresh rate.
          if $0.isHidden != $1.isHidden { return !$0.isHidden }
          return $0.refreshRate > $1.refreshRate
        })
      }
      .sorted { $0.key < $1.key }
  }

  /// The mode to switch to for a resolution: keep the current refresh rate when possible.
  static func bestMode(in choice: ResolutionChoice, matching current: DisplayModeOption?) -> DisplayModeOption? {
    if let current, let same = choice.modes.first(where: { abs($0.refreshRate - current.refreshRate) < 0.01 && !$0.isHidden }) {
      return same
    }
    if let current, let same = choice.modes.first(where: { abs($0.refreshRate - current.refreshRate) < 0.01 }) {
      return same
    }
    return choice.modes.first
  }

  private static func copyModes(_ display: CGDirectDisplayID, options: CFDictionary?) -> [CGDisplayMode] {
    (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
  }
}

func formattedRefreshRate(_ rate: Double) -> String {
  guard rate > 0 else { return String(localized: "Default rate") }
  let rounded = (rate * 100).rounded() / 100
  let number = rounded.formatted(.number.precision(.fractionLength(0...2)))
  return String(localized: "\(number) Hz")
}
