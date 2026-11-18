import AppKit
import Carbon.HIToolbox

/// App-wide Remote Desktop preferences (UserDefaults keys and defaults).
enum RemotePreferences {
  static let macShortcutsKey = "RemoteDesktopMacShortcuts"
  static let keyboardModeKey = "RemoteDesktopKeyboardMode"
  static let keyboardLayoutKey = "RemoteDesktopKeyboardLayout"
  static let viewStyleKey = "RemoteDesktopViewStyle"
  static let sortKey = "RemoteDesktopSort"

  /// ⌘C, ⌘V, ⌘Z… act as Ctrl shortcuts on the PC; ⌘ alone is the Windows key.
  static var macShortcuts: Bool {
    UserDefaults.standard.object(forKey: macShortcutsKey) as? Bool ?? true
  }

  static var keyboardMode: RemoteKeyboardMode {
    RemoteKeyboardMode(rawValue: UserDefaults.standard.string(forKey: keyboardModeKey) ?? "") ?? .keys
  }

  /// Windows keyboard layout id, 0 = follow the Mac's input source.
  static var keyboardLayout: UInt32 {
    UInt32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: keyboardLayoutKey))
  }
}

enum RemoteKeyboardMode: String, CaseIterable, Identifiable {
  /// Keys are sent by position; the PC's layout decides the characters (best for shortcuts).
  case keys
  /// Typed characters are sent as they appear on the Mac, whatever the PC's layout.
  case characters

  var id: String { rawValue }

  var title: String {
    switch self {
    case .keys: String(localized: "Keys (use the PC's keyboard layout)")
    case .characters: String(localized: "Characters (type what the Mac keyboard shows)")
    }
  }
}

/// Windows keyboard layouts offered in settings, and the Mac input sources they match.
enum RemoteKeyboardLayouts {
  struct Layout: Identifiable, Hashable {
    let id: UInt32
    let name: String
  }

  static var all: [Layout] {
    [
      Layout(id: 0x0000_041F, name: String(localized: "Turkish Q")),
      Layout(id: 0x0001_041F, name: String(localized: "Turkish F")),
      Layout(id: 0x0000_0409, name: String(localized: "US")),
      Layout(id: 0x0002_0409, name: String(localized: "US International")),
      Layout(id: 0x0000_0809, name: String(localized: "British")),
      Layout(id: 0x0000_0407, name: String(localized: "German")),
      Layout(id: 0x0000_0807, name: String(localized: "Swiss German")),
      Layout(id: 0x0000_040C, name: String(localized: "French")),
      Layout(id: 0x0000_0410, name: String(localized: "Italian")),
      Layout(id: 0x0000_040A, name: String(localized: "Spanish")),
      Layout(id: 0x0000_0413, name: String(localized: "Dutch")),
      Layout(id: 0x0000_0419, name: String(localized: "Russian")),
    ]
  }

  /// Mac input source id → Windows layout id.
  private static let macSources: [String: UInt32] = [
    "com.apple.keylayout.Turkish-QWERTY-PC": 0x0000_041F,
    "com.apple.keylayout.Turkish-QWERTY": 0x0000_041F,
    "com.apple.keylayout.Turkish-Standard": 0x0001_041F,
    "com.apple.keylayout.Turkish": 0x0001_041F,
    "com.apple.keylayout.US": 0x0000_0409,
    "com.apple.keylayout.ABC": 0x0000_0409,
    "com.apple.keylayout.USInternational-PC": 0x0002_0409,
    "com.apple.keylayout.ABC-QWERTZ": 0x0000_0407,
    "com.apple.keylayout.British": 0x0000_0809,
    "com.apple.keylayout.British-PC": 0x0000_0809,
    "com.apple.keylayout.German": 0x0000_0407,
    "com.apple.keylayout.Swiss German": 0x0000_0807,
    "com.apple.keylayout.French": 0x0000_040C,
    "com.apple.keylayout.French-PC": 0x0000_040C,
    "com.apple.keylayout.Italian": 0x0000_0410,
    "com.apple.keylayout.Italian-Pro": 0x0000_0410,
    "com.apple.keylayout.Spanish": 0x0000_040A,
    "com.apple.keylayout.Spanish-ISO": 0x0000_040A,
    "com.apple.keylayout.Dutch": 0x0000_0413,
    "com.apple.keylayout.Russian": 0x0000_0419,
    "com.apple.keylayout.RussianWin": 0x0000_0419,
    "com.apple.keylayout.Russian-Phonetic": 0x0000_0419,
  ]

  /// The layout to ask the PC for: the setting, or the one matching the Mac's input source.
  static func current() -> UInt32 {
    let chosen = RemotePreferences.keyboardLayout
    if chosen != 0 { return chosen }
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return 0 }
    let id = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    return macSources[id] ?? 0
  }

  /// ISO keyboards report the key left of 1 and the key right of left Shift swapped.
  static var isISOKeyboard: Bool {
    KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO
  }
}

/// Mac virtual key codes the session window treats specially.
enum MacKey {
  static let command: UInt16 = 0x37
  static let rightCommand: UInt16 = 0x36
  static let shift: UInt16 = 0x38
  static let rightShift: UInt16 = 0x3C
  static let option: UInt16 = 0x3A
  static let rightOption: UInt16 = 0x3D
  static let control: UInt16 = 0x3B
  static let rightControl: UInt16 = 0x3E
  static let capsLock: UInt16 = 0x39
  static let function: UInt16 = 0x3F
  static let isoSection: UInt16 = 0x0A
  static let grave: UInt16 = 0x32
  static let delete: UInt16 = 0x33

  static let modifiers: Set<UInt16> = [
    command, rightCommand, shift, rightShift, option, rightOption, control, rightControl, capsLock, function,
  ]

  /// Letters that turn ⌘ into Ctrl with Mac shortcuts on (A, B, C, F, I, N, O, P, S, T, U, V, W, X, Y, Z).
  static let controlShortcutKeys: Set<UInt16> = [
    0x00, 0x0B, 0x08, 0x03, 0x22, 0x2D, 0x1F, 0x23, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06,
  ]

  /// Device-dependent modifier bits (NX_DEVICE*KEYMASK) telling left and right apart.
  static func isDown(_ keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
    let raw = flags.rawValue
    switch keyCode {
    case control: return raw & 0x0000_0001 != 0
    case shift: return raw & 0x0000_0002 != 0
    case rightShift: return raw & 0x0000_0004 != 0
    case command: return raw & 0x0000_0008 != 0
    case rightCommand: return raw & 0x0000_0010 != 0
    case option: return raw & 0x0000_0020 != 0
    case rightOption: return raw & 0x0000_0040 != 0
    case rightControl: return raw & 0x0000_2000 != 0
    case capsLock: return flags.contains(.capsLock)
    default: return false
    }
  }
}
