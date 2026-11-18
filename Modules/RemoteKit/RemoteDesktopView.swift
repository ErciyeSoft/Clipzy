import AppKit
import QuartzCore

/// Shows the remote desktop and sends mouse and keyboard input to it.
final class RemoteDesktopView: NSView {
  weak var connection: RemoteConnection?
  /// Input goes out only while connected.
  var isInputEnabled = false {
    didSet { if !isInputEnabled { releaseAllKeys(send: false) } }
  }
  /// Called for ⌃⌘F.
  var onToggleFullScreen: (() -> Void)?

  private(set) var desktopSize = CGSize.zero
  private(set) var lastImage: CGImage?
  private let imageLayer = CALayer()
  private var currentCursor = NSCursor.arrow
  private var remoteCursor: RemoteConnection.Cursor = .standard

  // Keyboard state
  private var pressedKeys: Set<UInt16> = []
  private var modifiersDown: Set<UInt16> = []
  private var heldLazyModifiers: Set<UInt16> = []
  private var commandKey: UInt16?
  private var commandSentAsWindows = false
  private var commandUsed = false
  private var controlInjected = false
  private var scrollRemainder = CGPoint.zero

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    imageLayer.contentsGravity = .resizeAspect
    imageLayer.magnificationFilter = .linear
    imageLayer.minificationFilter = .trilinear
    imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    layer?.addSublayer(imageLayer)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func layout() {
    super.layout()
    imageLayer.frame = bounds
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    imageLayer.contentsScale = window?.backingScaleFactor ?? 2
  }

  // MARK: Picture

  func show(_ image: CGImage) {
    lastImage = image
    let size = CGSize(width: image.width, height: image.height)
    if size != desktopSize {
      desktopSize = size
      updateCursorImage()
    }
    imageLayer.contents = image
  }

  /// Where the desktop is drawn inside the view (aspect fit).
  var contentRect: CGRect {
    guard desktopSize.width > 0, desktopSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
    let scale = min(bounds.width / desktopSize.width, bounds.height / desktopSize.height)
    let size = CGSize(width: desktopSize.width * scale, height: desktopSize.height * scale)
    return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                  width: size.width, height: size.height)
  }

  private func desktopPoint(_ event: NSEvent) -> CGPoint {
    let point = convert(event.locationInWindow, from: nil)
    let rect = contentRect
    guard rect.width > 0, rect.height > 0, desktopSize.width > 0 else { return .zero }
    let x = (point.x - rect.minX) / rect.width * desktopSize.width
    let y = (point.y - rect.minY) / rect.height * desktopSize.height
    return CGPoint(x: min(max(0, x), desktopSize.width - 1), y: min(max(0, y), desktopSize.height - 1))
  }

  // MARK: Cursor

  private static let blankCursor: NSCursor = {
    let image = NSImage(size: NSSize(width: 1, height: 1))
    return NSCursor(image: image, hotSpot: .zero)
  }()

  func setRemoteCursor(_ cursor: RemoteConnection.Cursor) {
    remoteCursor = cursor
    updateCursorImage()
  }

  private func updateCursorImage() {
    switch remoteCursor {
    case .hidden:
      currentCursor = Self.blankCursor
    case .standard:
      currentCursor = .arrow
    case .image(let image, let hotSpot):
      // Remote cursors are in desktop pixels; draw them at the desktop's scale on screen.
      let rect = contentRect
      let scale = desktopSize.width > 0 ? rect.width / desktopSize.width : 1
      let size = NSSize(width: max(1, CGFloat(image.width) * scale), height: max(1, CGFloat(image.height) * scale))
      let nsImage = NSImage(cgImage: image, size: size)
      currentCursor = NSCursor(image: nsImage, hotSpot: NSPoint(x: hotSpot.x * scale, y: hotSpot.y * scale))
    }
    window?.invalidateCursorRects(for: self)
    if let window, window.isKeyWindow,
       bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
      currentCursor.set()
    }
  }

  override func resetCursorRects() {
    addCursorRect(visibleRect, cursor: currentCursor)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(
      rect: .zero,
      options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited],
      owner: self, userInfo: nil
    ))
  }

  override func cursorUpdate(with event: NSEvent) {
    currentCursor.set()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    if case .image = remoteCursor { updateCursorImage() }
  }

  // MARK: Mouse

  override func mouseMoved(with event: NSEvent) {
    guard isInputEnabled else { return }
    connection?.mouseMove(desktopPoint(event))
  }

  override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
  override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
  override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    button(0, down: true, event)
  }

  override func mouseUp(with event: NSEvent) { button(0, down: false, event) }
  override func rightMouseDown(with event: NSEvent) { button(1, down: true, event) }
  override func rightMouseUp(with event: NSEvent) { button(1, down: false, event) }

  override func otherMouseDown(with event: NSEvent) {
    button(min(event.buttonNumber, 4), down: true, event)
  }

  override func otherMouseUp(with event: NSEvent) {
    button(min(event.buttonNumber, 4), down: false, event)
  }

  private func button(_ number: Int, down: Bool, _ event: NSEvent) {
    guard isInputEnabled else { return }
    if commandKey != nil { commandUsed = true }
    flushLazyModifiers()
    connection?.mouseButton(number, down: down, at: desktopPoint(event))
  }

  override func scrollWheel(with event: NSEvent) {
    guard isInputEnabled, let connection else { return }
    let point = desktopPoint(event)
    // A wheel notch is 120 units; trackpads report points, about 30 per notch.
    let factor: CGFloat = event.hasPreciseScrollingDeltas ? 4 : 120
    scrollRemainder.y += event.scrollingDeltaY * factor
    scrollRemainder.x += event.scrollingDeltaX * factor
    let vertical = Int(scrollRemainder.y.rounded(.towardZero))
    let horizontal = Int(scrollRemainder.x.rounded(.towardZero))
    scrollRemainder.y -= CGFloat(vertical)
    scrollRemainder.x -= CGFloat(horizontal)
    if vertical != 0 { connection.wheel(horizontal: false, delta: vertical, at: point) }
    // Windows scrolls right for positive values; the Mac's delta points the other way.
    if horizontal != 0 { connection.wheel(horizontal: true, delta: -horizontal, at: point) }
  }

  // MARK: Keyboard

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard isInputEnabled, window?.isKeyWindow == true, window?.firstResponder === self else {
      return super.performKeyEquivalent(with: event)
    }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "q" {
      return false
    }
    if flags.contains([.command, .control]), event.keyCode == 0x03 { // ⌃⌘F
      onToggleFullScreen?()
      return true
    }
    keyDown(with: event)
    return true
  }

  override func keyDown(with event: NSEvent) {
    guard isInputEnabled, let connection else { return }
    let key = fixedKeyCode(event.keyCode)

    // With ⌘ held AppKit never sends the key-up, so these keys are tapped.
    if event.modifierFlags.contains(.command) {
      if let commandKey, RemotePreferences.macShortcuts {
        if MacKey.controlShortcutKeys.contains(key) && !commandSentAsWindows {
          if !controlInjected {
            flushLazyModifiers()
            connection.macKey(MacKey.control, down: true)
            controlInjected = true
          }
        } else if !commandSentAsWindows && !controlInjected {
          connection.macKey(commandKey, down: true)
          commandSentAsWindows = true
        }
        commandUsed = true
      }
      flushLazyModifiers()
      connection.macKey(key, down: true, repeat: event.isARepeat)
      connection.macKey(key, down: false)
      return
    }

    if RemotePreferences.keyboardMode == .characters, !event.modifierFlags.contains(.control),
       let text = event.characters {
      if text.isEmpty { return } // a dead key; the composed character comes with the next key
      if Self.isPrintable(text) {
        connection.unicode(text)
        return
      }
    }

    flushLazyModifiers()
    pressedKeys.insert(key)
    connection.macKey(key, down: true, repeat: event.isARepeat)
  }

  override func keyUp(with event: NSEvent) {
    guard isInputEnabled else { return }
    let key = fixedKeyCode(event.keyCode)
    if pressedKeys.remove(key) != nil {
      connection?.macKey(key, down: false)
    }
  }

  override func flagsChanged(with event: NSEvent) {
    guard isInputEnabled, let connection else { return }
    let key = event.keyCode
    guard MacKey.modifiers.contains(key), key != MacKey.function else { return }

    if key == MacKey.capsLock {
      // Each change toggles Caps Lock on the PC.
      connection.macKey(key, down: true)
      connection.macKey(key, down: false)
      return
    }

    let down = MacKey.isDown(key, flags: event.modifierFlags)
    if key == MacKey.command || key == MacKey.rightCommand {
      command(key, down: down)
      return
    }

    let lazy = RemotePreferences.keyboardMode == .characters
      && [MacKey.shift, MacKey.rightShift, MacKey.option, MacKey.rightOption].contains(key)
    if lazy {
      // Shift and Option shape the typed character; they reach the PC only with other keys.
      if down {
        heldLazyModifiers.insert(key)
      } else {
        heldLazyModifiers.remove(key)
        if modifiersDown.remove(key) != nil { connection.macKey(key, down: false) }
      }
      return
    }

    if down {
      if modifiersDown.insert(key).inserted { connection.macKey(key, down: true) }
    } else if modifiersDown.remove(key) != nil {
      connection.macKey(key, down: false)
    }
  }

  private func command(_ key: UInt16, down: Bool) {
    guard let connection else { return }
    guard RemotePreferences.macShortcuts else {
      if down {
        if modifiersDown.insert(key).inserted { connection.macKey(key, down: true) }
      } else if modifiersDown.remove(key) != nil {
        connection.macKey(key, down: false)
      }
      return
    }
    if down {
      commandKey = key
      commandSentAsWindows = false
      commandUsed = false
      return
    }
    guard commandKey != nil else { return }
    if controlInjected {
      connection.macKey(MacKey.control, down: false)
      controlInjected = false
    }
    if commandSentAsWindows {
      connection.macKey(key, down: false)
    } else if !commandUsed {
      // ⌘ pressed alone: the Windows key (Start menu).
      connection.macKey(key, down: true)
      connection.macKey(key, down: false)
    }
    commandKey = nil
    commandSentAsWindows = false
    commandUsed = false
  }

  private func flushLazyModifiers() {
    guard let connection else { return }
    for key in heldLazyModifiers where modifiersDown.insert(key).inserted {
      connection.macKey(key, down: true)
    }
  }

  /// Lets go of everything held, e.g. when the window loses focus mid-shortcut.
  func releaseAllKeys(send: Bool = true) {
    if send, let connection {
      pressedKeys.forEach { connection.macKey($0, down: false) }
      modifiersDown.forEach { connection.macKey($0, down: false) }
      if controlInjected { connection.macKey(MacKey.control, down: false) }
      if commandSentAsWindows, let commandKey { connection.macKey(commandKey, down: false) }
    }
    pressedKeys.removeAll()
    modifiersDown.removeAll()
    heldLazyModifiers.removeAll()
    commandKey = nil
    commandSentAsWindows = false
    commandUsed = false
    controlInjected = false
  }

  override func resignFirstResponder() -> Bool {
    releaseAllKeys()
    return super.resignFirstResponder()
  }

  private func fixedKeyCode(_ keyCode: UInt16) -> UInt16 {
    guard RemoteKeyboardLayouts.isISOKeyboard else { return keyCode }
    if keyCode == MacKey.grave { return MacKey.isoSection }
    if keyCode == MacKey.isoSection { return MacKey.grave }
    return keyCode
  }

  private static func isPrintable(_ text: String) -> Bool {
    guard let scalar = text.unicodeScalars.first else { return false }
    let value = scalar.value
    if value < 0x20 || value == 0x7F { return false }
    if (0xF700...0xF8FF).contains(value) { return false } // function and arrow keys
    return true
  }

  // MARK: Special keys

  func sendControlAltDelete() {
    guard isInputEnabled, let connection else { return }
    connection.scanCode(0x1D, down: true)               // Ctrl
    connection.scanCode(0x38, down: true)               // Alt
    connection.scanCode(0x53, extended: true, down: true) // Delete
    connection.scanCode(0x53, extended: true, down: false)
    connection.scanCode(0x38, down: false)
    connection.scanCode(0x1D, down: false)
  }
}
