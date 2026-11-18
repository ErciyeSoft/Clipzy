import AppKit
import SwiftUI

/// The borderless panel that hangs from the top edge of a screen. It never becomes key,
/// so using it doesn't take focus from the app in front.
final class NotchPanel: NSPanel {
  init(frame: CGRect) {
    super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isFloatingPanel = true
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isMovable = false
    isReleasedWhenClosed = false
    // Above the menu bar, like boring.notch.
    level = .mainMenu + 3
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    // Clicks go through until the pointer is over the notch.
    ignoresMouseEvents = true
    animationBehavior = .none
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// A hosting view that takes the first click even though its window is never key.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The panel of one screen: shows it and opens or closes it as the pointer comes and goes.
final class NotchScreenController {
  let model: NotchViewModel
  private let panel: NotchPanel
  private var openWork: DispatchWorkItem?
  private var closeWork: DispatchWorkItem?
  private var trackingTimer: Timer?
  /// A panel opened from settings or a shortcut stays open until the pointer has been over it
  /// and left again, or until a click elsewhere.
  private var pointerHasEntered = false

  init(screen: NotchScreen, services: NotchServices, settings: NotchSettings) {
    model = NotchViewModel(screen: screen, services: services, settings: settings)
    panel = NotchPanel(frame: screen.windowFrame)
    let host = NotchHostingView(rootView: NotchRootView(model: model))
    host.sizingOptions = []
    host.frame = CGRect(origin: .zero, size: screen.windowFrame.size)
    host.autoresizingMask = [.width, .height]
    panel.contentView = host
    panel.orderFrontRegardless()
    model.openHandler = { [weak self] tab in self?.open(tab: tab) }
  }

  var screen: NotchScreen { model.screen }

  func tearDown() {
    openWork?.cancel()
    closeWork?.cancel()
    trackingTimer?.invalidate()
    panel.orderOut(nil)
    panel.close()
  }

  func update(settings: NotchSettings) {
    model.settings = settings
    if !settings.shelf, model.tab == .shelf { model.tab = .home }
  }

  /// The area that reacts to the pointer, in Cocoa screen coordinates.
  private var activeRect: CGRect {
    if model.isOpen {
      return model.screen.topRect(NotchMetrics.openSize).insetBy(dx: -8, dy: -8)
    }
    // A little wider and lower than the shape, so the edge of the screen is easy to hit.
    return model.screen.topRect(model.closedSize).insetBy(dx: -6, dy: -4)
  }

  /// Called for every pointer move (from event monitors), and on a timer while open.
  func pointerMoved(to point: CGPoint, isDraggingFiles: Bool) {
    let inside = activeRect.contains(point)
    if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }

    if inside {
      closeWork?.cancel()
      closeWork = nil
      if model.isOpen { pointerHasEntered = true }
      guard !model.isOpen else { return }
      if isDraggingFiles {
        openWork?.cancel()
        openWork = nil
        // Open right away so the shelf can take the drop.
        open(tab: model.settings.shelf ? .shelf : nil)
      } else if model.settings.openOnHover, openWork == nil {
        let work = DispatchWorkItem { [weak self] in
          MainActor.assumeIsolated {
            guard let self else { return }
            self.openWork = nil
            guard self.activeRect.contains(NSEvent.mouseLocation) else { return }
            self.open()
            self.pointerHasEntered = true
          }
        }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
      }
    } else {
      openWork?.cancel()
      openWork = nil
      guard model.isOpen, pointerHasEntered, closeWork == nil else { return }
      let work = DispatchWorkItem { [weak self] in
        MainActor.assumeIsolated { self?.closeIfPointerLeft() }
      }
      closeWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
  }

  /// Opens the panel (a click on the notch, the settings page, a keyboard shortcut).
  func open(tab: NotchViewModel.Tab? = nil) {
    pointerHasEntered = activeRect.contains(NSEvent.mouseLocation)
    model.open(tab: tab)
    panel.ignoresMouseEvents = false
    startTracking()
  }

  /// A click outside the open panel closes it.
  func mouseDown(at point: CGPoint) {
    guard model.isOpen, !activeRect.contains(point) else { return }
    closeWork?.cancel()
    closeWork = nil
    close()
  }

  private func close() {
    model.close()
    pointerHasEntered = false
    panel.ignoresMouseEvents = !activeRect.contains(NSEvent.mouseLocation)
    trackingTimer?.invalidate()
    trackingTimer = nil
  }

  private func closeIfPointerLeft() {
    closeWork = nil
    guard model.isOpen else { return }
    if activeRect.contains(NSEvent.mouseLocation) || model.isDropTargeted { return }
    // A context menu of the panel is open: wait until it closes.
    if RunLoop.main.currentMode == .eventTracking {
      let work = DispatchWorkItem { [weak self] in
        MainActor.assumeIsolated { self?.closeIfPointerLeft() }
      }
      closeWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
      return
    }
    close()
  }

  /// Event monitors can miss the pointer leaving quickly; a light timer catches it while open.
  private func startTracking() {
    guard trackingTimer == nil else { return }
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        guard self.model.isOpen else {
          self.trackingTimer?.invalidate()
          self.trackingTimer = nil
          return
        }
        self.pointerMoved(to: NSEvent.mouseLocation, isDraggingFiles: false)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    trackingTimer = timer
  }
}

/// Owns the panels of all screens, the shared models, the media key tap and the monitors.
final class NotchController {
  private(set) var settings = NotchSettings()
  private var screens: [NotchScreenController] = []
  let services = NotchServices(
    media: NowPlayingModel(),
    shelf: NotchShelfModel(),
    calendar: NotchCalendarModel(),
    battery: NotchBatteryModel()
  )
  private lazy var keyTap = MediaKeyTap { [weak self] event in self?.showHUD(event) }
  private var monitors: [Any] = []
  private var screenObserver: NSObjectProtocol?
  /// Change count of the drag pasteboard at the last mouse down, to tell a new file drag.
  private var dragChangeCount = NSPasteboard(name: .drag).changeCount
  private var isPlayingObservation = false

  init() {
    services.battery.onNotice = { [weak self] notice in self?.showBattery(notice) }
  }

  var isHUDWaitingForAccess: Bool { keyTap.isWaitingForAccess }
  var isHUDRunning: Bool { keyTap.isRunning }
  var panelCount: Int { screens.count }

  func apply(_ new: NotchSettings) {
    let old = settings
    settings = new
    let wanted = new.enabled ? NotchScreen.screens(for: new.screens) : []
    if wanted != screens.map(\.screen) || old.enabled != new.enabled {
      rebuildPanels(wanted)
    } else {
      screens.forEach { $0.update(settings: new) }
    }

    let active = !screens.isEmpty
    if active { startMonitors() } else { stopMonitors() }

    if active && new.nowPlaying { services.media.start() } else if services.media.isRunning { services.media.stop() }
    if active && new.calendar { services.calendar.start() } else { services.calendar.stop() }
    if active && new.battery { services.battery.start() } else { services.battery.stop() }
    // The keys are only taken over while there is a panel to show the level in.
    if active && new.hud { keyTap.start() } else { keyTap.stop() }
    if active { observePlayback() }
  }

  func shutdown() {
    keyTap.stop()
    services.media.stop()
    services.battery.stop()
    stopMonitors()
    screens.forEach { $0.tearDown() }
    screens = []
  }

  /// Opens the panel on the screen with the pointer (or the first one).
  func openPanel(tab: NotchViewModel.Tab? = nil) {
    preferredScreen()?.open(tab: tab)
  }

  // MARK: Panels

  private func rebuildPanels(_ wanted: [NotchScreen]) {
    screens.forEach { $0.tearDown() }
    screens = wanted.map { NotchScreenController(screen: $0, services: services, settings: settings) }
    if screenObserver == nil {
      screenObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.screensChanged() }
      }
    }
  }

  private func screensChanged() {
    let wanted = settings.enabled ? NotchScreen.screens(for: settings.screens) : []
    guard wanted != screens.map(\.screen) else { return }
    // Rebuild through apply so the tap and readers follow the new panel count.
    apply(settings)
  }

  private func preferredScreen() -> NotchScreenController? {
    let mouse = NSEvent.mouseLocation
    return screens.first { $0.screen.screen.frame.contains(mouse) }
      ?? screens.first { $0.screen.hasNotch }
      ?? screens.first
  }

  private func showHUD(_ event: NotchHUDEvent) {
    preferredScreen()?.model.show(event)
  }

  private func showBattery(_ notice: BatteryNotice) {
    guard settings.battery else { return }
    preferredScreen()?.model.show(notice)
  }

  /// Keeps the closed view's "paused" grace period in step with playback.
  private func observePlayback() {
    guard !isPlayingObservation else { return }
    isPlayingObservation = true
    withObservationTracking {
      _ = services.media.isPlaying
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self else { return }
          self.isPlayingObservation = false
          let playing = self.services.media.isPlaying
          self.screens.forEach { $0.model.playbackChanged(isPlaying: playing) }
          if !self.screens.isEmpty { self.observePlayback() }
        }
      }
    }
  }

  // MARK: Pointer

  private func startMonitors() {
    guard monitors.isEmpty else { return }
    let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown]
    if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
      let type = event.type
      MainActor.assumeIsolated { self?.handlePointer(type) }
    }) {
      monitors.append(global)
    }
    if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
      self?.handlePointer(event.type)
      return event
    }) {
      monitors.append(local)
    }
  }

  private func stopMonitors() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
  }

  private func handlePointer(_ type: NSEvent.EventType) {
    let drag = NSPasteboard(name: .drag)
    let point = NSEvent.mouseLocation
    if type == .leftMouseDown {
      dragChangeCount = drag.changeCount
      screens.forEach { $0.mouseDown(at: point) }
      return
    }
    var draggingFiles = false
    if type == .leftMouseDragged, settings.shelf, drag.changeCount != dragChangeCount {
      draggingFiles = drag.types?.contains(.fileURL) == true || drag.types?.contains(.string) == true
    }
    for screen in screens {
      screen.pointerMoved(to: point, isDraggingFiles: draggingFiles)
    }
  }
}
