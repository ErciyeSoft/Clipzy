import AppKit
import ApplicationServices
import KitziCore

/// The strip along a screen edge that one Kitzi Dock keeps for itself.
struct DockReservation: Equatable {
  let screenFrame: CGRect
  let visibleFrame: CGRect
  let edge: ScreenEdge
  let thickness: CGFloat

  /// Where windows may go: the visible frame minus the dock's strip, across the whole edge
  /// (the same gap the macOS Dock leaves on both sides of itself).
  var usableFrame: CGRect {
    var frame = visibleFrame
    switch edge {
    case .bottom:
      let top = max(frame.minY, screenFrame.minY + thickness)
      frame.size.height = frame.maxY - top
      frame.origin.y = top
    case .left:
      let left = max(frame.minX, screenFrame.minX + thickness)
      frame.size.width = frame.maxX - left
      frame.origin.x = left
    case .right:
      frame.size.width = min(frame.maxX, screenFrame.maxX - thickness) - frame.minX
    }
    return frame
  }
}

/// Keeps other apps' windows out of the Kitzi Dock's strip, like the macOS Dock does:
/// maximized / filled windows end at the dock, new windows are placed clear of it, while a
/// window the user drags under the dock is left alone. Uses the Accessibility API.
final class WindowFitter {
  var reservations: [DockReservation] = [] {
    didSet {
      guard reservations != oldValue else { return }
      fitAllApps()
    }
  }

  private var observer: AXObserver?
  private var observedPID: pid_t = 0
  private var activationObserver: NSObjectProtocol?
  private var pending: Task<Void, Never>?
  private var createdWindowPending = false

  var isRunning: Bool { activationObserver != nil }

  func start() {
    guard activationObserver == nil else { return }
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] notification in
      let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
      MainActor.assumeIsolated { self?.observe(pid: pid) }
    }
    observe(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    fitAllApps()
  }

  func stop() {
    if let activationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
    }
    activationObserver = nil
    stopObserving()
    pending?.cancel()
  }

  // MARK: - Watching the frontmost app

  private static let callback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let fitter = Unmanaged<WindowFitter>.fromOpaque(refcon).takeUnretainedValue()
    let created = (notification as String) == kAXWindowCreatedNotification
    MainActor.assumeIsolated { fitter.windowsChanged(created: created) }
  }

  private func observe(pid: pid_t?) {
    stopObserving()
    guard let pid, pid != ProcessInfo.processInfo.processIdentifier else { return }
    var newObserver: AXObserver?
    guard AXObserverCreate(pid, Self.callback, &newObserver) == .success, let newObserver else { return }
    let app = AXUIElementCreateApplication(pid)
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    for name in [kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
                 kAXFocusedWindowChangedNotification] {
      AXObserverAddNotification(newObserver, app, name as CFString, refcon)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .defaultMode)
    observer = newObserver
    observedPID = pid
    windowsChanged(created: false)
  }

  private func stopObserving() {
    if let observer {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
    observer = nil
    observedPID = 0
  }

  /// Waits until the window stops moving and the mouse is up, so we never fight a drag.
  private func windowsChanged(created: Bool) {
    createdWindowPending = createdWindowPending || created
    pending?.cancel()
    pending = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      while NSEvent.pressedMouseButtons != 0, !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(150))
      }
      guard let self, !Task.isCancelled, observedPID != 0 else { return }
      fitWindows(of: observedPID, includeNewlyPlaced: createdWindowPending)
      createdWindowPending = false
    }
  }

  private func fitAllApps() {
    guard !reservations.isEmpty else { return }
    for app in NSWorkspace.shared.runningApplications
    where app.activationPolicy == .regular && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
      fitWindows(of: app.processIdentifier, includeNewlyPlaced: false)
    }
  }

  // MARK: - Fitting

  private func fitWindows(of pid: pid_t, includeNewlyPlaced: Bool) {
    guard !reservations.isEmpty else { return }
    let app = AXUIElementCreateApplication(pid)
    guard let windows = Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return }
    for window in windows {
      fit(window, moveIfOverlapping: includeNewlyPlaced)
    }
  }

  private func fit(_ window: AXUIElement, moveIfOverlapping: Bool) {
    guard (Self.attribute(window, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole,
          (Self.attribute(window, kAXMinimizedAttribute) as? Bool) != true,
          (Self.attribute(window, "AXFullScreen") as? Bool) != true,
          let frame = Self.frame(of: window) else { return }
    let center = CGPoint(x: frame.midX, y: frame.midY)
    guard let reservation = reservations.first(where: { $0.screenFrame.contains(center) }) else { return }
    let usable = reservation.usableFrame
    let slack: CGFloat = 4
    var target = frame

    switch reservation.edge {
    case .bottom:
      guard frame.minY < usable.minY - 1 else { return }
      if frame.maxY >= usable.maxY - slack {
        // Maximized or filled: end at the dock.
        target.origin.y = usable.minY
        target.size.height = usable.maxY - usable.minY
      } else if moveIfOverlapping, frame.height <= usable.height {
        target.origin.y = usable.minY
      } else {
        return
      }
    case .left:
      guard frame.minX < usable.minX - 1 else { return }
      if frame.maxX >= usable.maxX - slack {
        target.origin.x = usable.minX
        target.size.width = usable.width
      } else if moveIfOverlapping, frame.width <= usable.width {
        target.origin.x = usable.minX
      } else {
        return
      }
    case .right:
      guard frame.maxX > usable.maxX + 1 else { return }
      if frame.minX <= usable.minX + slack {
        target.size.width = usable.width
      } else if moveIfOverlapping, frame.width <= usable.width {
        target.origin.x = usable.maxX - frame.width
      } else {
        return
      }
    }
    Self.setFrame(target, of: window)
  }

  // MARK: - Accessibility helpers

  private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
  }

  private static var primaryScreenHeight: CGFloat {
    NSScreen.screens.first?.frame.maxY ?? 0
  }

  /// Window frame in Cocoa coordinates (Accessibility uses a top-left origin).
  private static func frame(of window: AXUIElement) -> CGRect? {
    guard let positionValue = attribute(window, kAXPositionAttribute),
          let sizeValue = attribute(window, kAXSizeAttribute) else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    // swiftlint:disable force_cast
    AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    // swiftlint:enable force_cast
    return CGRect(x: position.x, y: primaryScreenHeight - position.y - size.height, width: size.width, height: size.height)
  }

  private static func setFrame(_ frame: CGRect, of window: AXUIElement) {
    var position = CGPoint(x: frame.minX, y: primaryScreenHeight - frame.maxY)
    var size = frame.size
    // Size first so a shrinking window never pokes past the screen while moving.
    if let sizeValue = AXValueCreate(.cgSize, &size) {
      AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    }
    if let positionValue = AXValueCreate(.cgPoint, &position) {
      AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
    }
    if let sizeValue = AXValueCreate(.cgSize, &size) {
      AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    }
  }
}
