import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Sauce

/// Windows-style cut and paste for files in Finder.
///
/// Finder can't cut files, but it can copy them and later "Move Item Here" (⌥⌘V).
/// So ⌘X on selected files is sent to Finder as ⌘C and remembered as a cut; the next ⌘V in
/// Finder, while the clipboard still holds those files, is sent as ⌥⌘V and moves them.
/// While text is being edited (renaming, the search field) both keys behave as usual.
///
/// The event tap runs on its own thread so a busy main thread never delays typing.
nonisolated final class FinderCutPaste: @unchecked Sendable {
  private enum CutState {
    case none
    /// ⌘C was sent and the clipboard still had this change count.
    case copying(from: Int)
    /// The clipboard holds the cut files at this change count.
    case ready(at: Int)
  }

  private struct Keys {
    var x = Int64(kVK_ANSI_X)
    var c = Int64(kVK_ANSI_C)
    var v = Int64(kVK_ANSI_V)
  }

  private struct Tap: @unchecked Sendable {
    let port: CFMachPort
    let source: CFRunLoopSource
  }

  // Shared with the tap thread, guarded by `lock`.
  private let lock = NSLock()
  private var state = CutState.none
  private var lastMove = Date.distantPast
  /// Finder's process while it is the frontmost app.
  private var finderPID: pid_t?
  /// Key codes of X, C and V in the current keyboard layout.
  private var keys = Keys()
  private var tapPort: CFMachPort?
  private var tapRunLoop: CFRunLoop?

  // Main thread only.
  private var tap: Tap?
  private var retryTimer: Timer?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  private let notice: CutNotice
  private let pasteboard: NSPasteboard

  @MainActor init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
    notice = CutNotice()
  }

  @MainActor var isRunning: Bool { tap != nil }

  @MainActor func start() {
    guard tap == nil, retryTimer == nil else { return }
    guard let port = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
      callback: finderCutPasteCallback,
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
      // Needs Accessibility access; try again until it is granted.
      scheduleRetry()
      return
    }
    let tap = Tap(port: port, source: source)
    self.tap = tap
    lock.withLock { tapPort = port }
    observeFinderAndKeyboard()

    let thread = Thread { [self] in runTap(tap) }
    thread.name = "Kitzi Finder cut and paste"
    thread.qualityOfService = .userInteractive
    thread.start()
  }

  @MainActor func stop() {
    retryTimer?.invalidate()
    retryTimer = nil
    observers.forEach { center, observer in center.removeObserver(observer) }
    observers = []
    guard let tap else { return }
    CGEvent.tapEnable(tap: tap.port, enable: false)
    CFMachPortInvalidate(tap.port)
    let runLoop = lock.withLock {
      defer { tapPort = nil; tapRunLoop = nil; state = .none }
      return tapRunLoop
    }
    if let runLoop { CFRunLoopStop(runLoop) }
    self.tap = nil
    notice.hide()
  }

  private func runTap(_ tap: Tap) {
    let runLoop = CFRunLoopGetCurrent()
    lock.withLock { tapRunLoop = runLoop }
    CFRunLoopAddSource(runLoop, tap.source, .commonModes)
    CGEvent.tapEnable(tap: tap.port, enable: true)
    CFRunLoopRun()
  }

  @MainActor private func scheduleRetry() {
    retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, AXIsProcessTrusted() else { return }
        self.retryTimer?.invalidate()
        self.retryTimer = nil
        self.start()
      }
    }
  }

  @MainActor private func observeFinderAndKeyboard() {
    let workspace = NSWorkspace.shared.notificationCenter
    let activation = workspace.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      self?.setFrontmost(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }
    let layout = NotificationCenter.default.addObserver(
      forName: .SauceSelectedKeyboardKeyCodesChanged, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateKeys() }
    }
    observers = [(workspace, activation), (NotificationCenter.default, layout)]
    setFrontmost(NSWorkspace.shared.frontmostApplication)
    updateKeys()
  }

  private func setFrontmost(_ app: NSRunningApplication?) {
    setFinderPID(app?.bundleIdentifier == "com.apple.finder" ? app?.processIdentifier : nil)
  }

  func setFinderPID(_ pid: pid_t?) {
    lock.withLock { finderPID = pid }
  }

  @MainActor private func updateKeys() {
    let sauce = Sauce.shared
    let keys = Keys(
      x: Int64(sauce.keyCode(for: .x)),
      c: Int64(sauce.keyCode(for: .c)),
      v: Int64(sauce.keyCode(for: .v))
    )
    lock.withLock { self.keys = keys }
  }

  // MARK: - Tap thread

  /// Returns false to drop the event.
  func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      if let port = lock.withLock({ tapPort }) { CGEvent.tapEnable(tap: port, enable: true) }
      return true
    case .keyDown:
      break
    default:
      return true
    }

    let (finderPID, keys) = lock.withLock { (self.finderPID, self.keys) }
    guard let finderPID else { return true }
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])

    if flags.isEmpty, keyCode == Int64(kVK_Escape) {
      cancelCut()
      return true
    }
    guard flags == .maskCommand, keyCode == keys.x || keyCode == keys.v else { return true }
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

    if keyCode == keys.v {
      // Holding ⌘V after a move would paste copies of the moved files.
      if isRepeat, lock.withLock({ Date().timeIntervalSince(lastMove) < 2 }) { return false }
      // Only ask Finder about its focus when a cut is waiting, so a plain paste is never slowed.
      guard hasCut(), !isEditingText(in: finderPID), takeCut() else { return true }
      event.flags = event.flags.union(.maskAlternate)
      Task { @MainActor [notice] in notice.hide() }
      return true
    }

    // ⌘X
    guard !isEditingText(in: finderPID) else { return true }
    if isRepeat { return false }
    let start = pasteboard.changeCount
    lock.withLock { state = .copying(from: start) }
    event.setIntegerValueField(.keyboardEventKeycode, value: keys.c)
    Task { @MainActor [self] in await watchCopy(from: start) }
    return true
  }

  /// Whether the files of the last ⌘X are still on the clipboard; if so, the cut is used up.
  private func takeCut() -> Bool {
    let now = pasteboard.changeCount
    return lock.withLock {
      switch state {
      case .none:
        return false
      case let .copying(from):
        // The copy landed but hasn't been noticed yet.
        guard now != from, Self.fileCount(on: pasteboard) > 0 else { return false }
      case let .ready(at):
        guard now == at else {
          state = .none
          return false
        }
      }
      state = .none
      lastMove = Date()
      return true
    }
  }

  private func hasCut() -> Bool {
    lock.withLock {
      if case .none = state { return false }
      return true
    }
  }

  private func cancelCut() {
    let hadCut = lock.withLock {
      defer { state = .none }
      if case .none = state { return false }
      return true
    }
    if hadCut {
      Task { @MainActor [notice] in notice.hide() }
    }
  }

  /// True while a text field in Finder has the keyboard focus, e.g. while renaming a file.
  private func isEditingText(in pid: pid_t) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.25)
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXRoleAttribute as CFString, &role)
    return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role as? String ?? "")
  }

  private static func fileCount(on pasteboard: NSPasteboard) -> Int {
    let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    return files?.count ?? 0
  }

  // MARK: - Main thread

  /// Waits for Finder to put the selection on the clipboard, then shows the notice.
  @MainActor private func watchCopy(from start: Int) async {
    for _ in 0..<40 {
      try? await Task.sleep(for: .milliseconds(25))
      guard pasteboard.changeCount != start else { continue }
      let count = Self.fileCount(on: pasteboard)
      let changeCount = pasteboard.changeCount
      let isOurs = lock.withLock {
        guard case let .copying(from) = state, from == start else { return false }
        state = count > 0 ? .ready(at: changeCount) : .none
        return count > 0
      }
      if isOurs { notice.show(count: count) }
      return
    }
    // Nothing was selected, so nothing was copied.
    lock.withLock {
      if case let .copying(from) = state, from == start { state = .none }
    }
  }
}

nonisolated private func finderCutPasteCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  let controller = Unmanaged<FinderCutPaste>.fromOpaque(userInfo).takeUnretainedValue()
  return controller.handle(type, event) ? Unmanaged.passUnretained(event) : nil
}
