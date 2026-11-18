import AppKit
import ApplicationServices
import Observation

/// What the settings page shows about the running module.
@Observable
final class MenuBarStatus {
  var isActive = false
  var hasOrderProblem = false
}

/// Decides when the menu bar sections show and hide: the toggle, hotkeys, hovering, clicking
/// and scrolling on the menu bar, and hiding again after a delay or a click elsewhere.
///
/// Mouse monitors only read the event and start a timer or a task; window lists and
/// Accessibility queries run off the main thread.
final class MenuBarController {
  static let hoverDelay: TimeInterval = 0.3

  let status = MenuBarStatus()
  var onSearch: () -> Void = {}
  var onSettings: () -> Void = {}

  private let sections = MenuBarSections()
  private var settings = MenuBarSettings()
  private var screens: [MenuBarScreen] = []
  private var shownAt = Date()
  /// On the very first run nothing hides by itself until the user has hidden once.
  private var awaitingFirstHide = false
  private var rehideTimer: Timer?
  /// Bumped whenever a pending rehide check becomes stale.
  private var rehideGeneration = 0
  private var hoverTimer: Timer?
  private var scrollGate = ScrollGate()
  private var monitors: [Any] = []
  private var screenObserver: NSObjectProtocol?

  init() {
    sections.onAction = { [weak self] action in self?.perform(action) }
    sections.onDividerClick = { [weak self] collapsed in self?.dividerClicked(collapsed: collapsed) }
    sections.onSearch = { [weak self] in self?.onSearch() }
    sections.onSettings = { [weak self] in self?.onSettings() }
    sections.onVisibilityChange = { [weak self] visibility in self?.visibilityDidChange(visibility) }
    sections.onOrderProblemChange = { [weak self] problem in self?.status.hasOrderProblem = problem }
  }

  var isActive: Bool { sections.isInstalled }
  var visibility: MenuBarVisibility { sections.visibility }

  // MARK: - Settings

  func update(_ new: MenuBarSettings) {
    guard new != settings else { return }
    let old = settings
    settings = new
    guard new.enabled else {
      if old.enabled { stop() }
      return
    }
    guard old.enabled else {
      start()
      return
    }
    if new.alwaysHidden != old.alwaysHidden {
      sections.setAlwaysHiddenSection(new.alwaysHidden)
    }
    if new.showOnHover != old.showOnHover || new.showOnScroll != old.showOnScroll {
      installMonitors()
    }
    if new.rehideDelay != old.rehideDelay {
      scheduleRehide()
    }
  }

  private func start() {
    screens = MenuBarScreen.all()
    awaitingFirstHide = sections.install(alwaysHidden: settings.alwaysHidden)
    status.isActive = true
    installMonitors()
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.screens = MenuBarScreen.all() }
    }
    // On the first run everything stays visible so the user sees the divider to arrange icons.
    sections.request(awaitingFirstHide ? .shown : .hidden)
    shownAt = Date()
    scheduleRehide()
  }

  private func stop() {
    removeMonitors()
    cancelHover()
    cancelRehide()
    if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    screenObserver = nil
    sections.uninstall()
    awaitingFirstHide = false
    status.isActive = false
    status.hasOrderProblem = false
  }

  /// Makes every icon visible before the app quits.
  func prepareForQuit() {
    removeMonitors()
    cancelHover()
    cancelRehide()
    sections.expandAll()
  }

  /// Puts the toggle and the divider back next to each other at the right end.
  func resetPositions() {
    guard isActive else { return }
    sections.resetPositions()
    awaitingFirstHide = true
    sections.request(.shown)
  }

  // MARK: - Showing and hiding

  func perform(_ action: MenuBarAction) {
    guard isActive else { return }
    let desired = visibility.applying(action, alwaysHiddenEnabled: settings.alwaysHidden)
    if desired == .hidden { awaitingFirstHide = false }
    sections.request(desired)
  }

  /// Shows everything before an item found by search is pressed. Returns true if anything moved.
  func revealAll() -> Bool {
    guard isActive else { return false }
    let before = visibility
    perform(.revealAll)
    return visibility != before
  }

  private func visibilityDidChange(_ visibility: MenuBarVisibility) {
    cancelHover()
    if visibility == .hidden {
      cancelRehide()
    } else {
      shownAt = Date()
      scheduleRehide()
    }
  }

  private func dividerClicked(collapsed: Bool) {
    // A collapsed divider is the empty part of the menu bar; a visible one acts like the toggle.
    if !collapsed || settings.showOnClick {
      perform(.toggle)
    }
  }

  // MARK: - Rehide

  private func scheduleRehide() {
    cancelRehide()
    guard isActive, visibility != .hidden, !awaitingFirstHide else { return }
    switch RehidePolicy.decide(now: Date(), shownAt: shownAt, delay: TimeInterval(settings.rehideDelay), isBusy: false) {
    case .never:
      return
    case .hide:
      startRehideTimer(0)
    case let .wait(seconds):
      startRehideTimer(seconds)
    }
  }

  private func startRehideTimer(_ seconds: TimeInterval) {
    rehideTimer?.invalidate()
    rehideTimer = Timer.scheduledTimer(withTimeInterval: max(seconds, 0.05), repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.rehideTimerFired() }
    }
  }

  private func cancelRehide() {
    rehideTimer?.invalidate()
    rehideTimer = nil
    rehideGeneration += 1
  }

  private func rehideTimerFired() {
    rehideTimer = nil
    rehideGeneration += 1
    let generation = rehideGeneration
    Task { [weak self] in
      guard let self else { return }
      let isBusy = await self.isBusy()
      guard generation == self.rehideGeneration, self.visibility != .hidden, !self.awaitingFirstHide else { return }
      let delay = TimeInterval(self.settings.rehideDelay)
      switch RehidePolicy.decide(now: Date(), shownAt: self.shownAt, delay: delay, isBusy: isBusy) {
      case .hide:
        self.perform(.hide)
      case let .wait(seconds):
        self.startRehideTimer(seconds)
      case .never:
        break
      }
    }
  }

  /// The pointer is on the menu bar, a mouse button is held or a menu is open.
  private func isBusy() async -> Bool {
    if NSEvent.pressedMouseButtons != 0 { return true }
    let bars = screens.map(\.rect)
    let point = MenuBarScreen.mouseLocation()
    if bars.contains(where: { $0.insetBy(dx: 0, dy: -2).contains(point) }) { return true }
    let windows = await WindowList.snapshotInBackground()
    return MenuBarGeometry.isMenuOpen(windows: windows, menuBars: bars)
  }

  // MARK: - Mouse

  private func installMonitors() {
    removeMonitors()
    var mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
    if settings.showOnHover { mask.insert(.mouseMoved) }
    if settings.showOnScroll { mask.insert(.scrollWheel) }
    // Events for other apps come to the global monitor, events for our own windows
    // (including the collapsed dividers) to the local one.
    if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
      self?.handle(event, isLocal: false)
    }) {
      monitors.append(monitor)
    }
    if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
      self?.handle(event, isLocal: true)
      return event
    }) {
      monitors.append(monitor)
    }
  }

  private func removeMonitors() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
  }

  private func handle(_ event: NSEvent, isLocal: Bool) {
    switch event.type {
    case .mouseMoved:
      mouseMoved()
    case .leftMouseDown, .rightMouseDown:
      // Clicks on our own items are handled by their actions.
      if isLocal, sections.controlWindowNumbers.contains(event.windowNumber) { return }
      mouseDown(isLeft: event.type == .leftMouseDown)
    case .scrollWheel:
      // Mouse wheels report lines; trackpads report points.
      let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
      scrolled(deltaY: delta, inverted: event.isDirectionInvertedFromDevice)
    default:
      break
    }
  }

  private func isOnMenuBar(_ point: CGPoint) -> Bool {
    screens.contains { $0.rect.contains(point) }
  }

  /// Called for every mouse move anywhere, so it only compares against cached rects.
  private func mouseMoved() {
    guard settings.showOnHover, visibility == .hidden, isOnMenuBar(MenuBarScreen.mouseLocation()) else {
      cancelHover()
      return
    }
    guard hoverTimer == nil else { return }
    hoverTimer = Timer.scheduledTimer(withTimeInterval: Self.hoverDelay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.hoverTimerFired() }
    }
  }

  private func cancelHover() {
    hoverTimer?.invalidate()
    hoverTimer = nil
  }

  private func hoverTimerFired() {
    hoverTimer = nil
    let point = MenuBarScreen.mouseLocation()
    guard settings.showOnHover, visibility == .hidden, isOnMenuBar(point) else { return }
    Task { [weak self] in
      guard let self, await self.isEmptySpot(point) else { return }
      // The pointer may have left while the window list was read.
      guard self.visibility == .hidden, self.isOnMenuBar(MenuBarScreen.mouseLocation()) else { return }
      self.perform(.reveal)
    }
  }

  private func mouseDown(isLeft: Bool) {
    screens = MenuBarScreen.all()
    let point = MenuBarScreen.mouseLocation()
    if isOnMenuBar(point) {
      guard isLeft, settings.showOnClick else { return }
      Task { [weak self] in
        guard let self, await self.isEmptySpot(point) else { return }
        self.perform(.toggle)
      }
    } else if visibility != .hidden, settings.rehideOnOutsideClick, !awaitingFirstHide {
      let bars = screens.map(\.rect)
      Task { [weak self] in
        let windows = await WindowList.snapshotInBackground()
        // A click inside the menu or popover of a shown item keeps the items visible.
        guard let self, self.visibility != .hidden, !self.awaitingFirstHide,
              !MenuBarGeometry.isInsideMenu(point, windows: windows, menuBars: bars) else { return }
        self.perform(.hide)
      }
    }
  }

  private func scrolled(deltaY: CGFloat, inverted: Bool) {
    guard settings.showOnScroll, isOnMenuBar(MenuBarScreen.mouseLocation()) else { return }
    switch scrollGate.feed(deltaY: deltaY, inverted: inverted, at: Date()) {
    case .show:
      perform(.reveal)
    case .hide:
      if visibility != .hidden { perform(.hide) }
    case nil:
      break
    }
  }

  /// Whether `point` is on the menu bar but not on an app menu or an icon. Without
  /// Accessibility the app menus can't be found, so only the right half of the bar counts.
  private func isEmptySpot(_ point: CGPoint) async -> Bool {
    guard let screen = screens.first(where: { $0.rect.contains(point) }) else { return false }
    let bars = screens.map(\.rect)
    let excluded = sections.dividerWindowNumbers
    let pid = AXIsProcessTrusted() ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil
    let (windows, extent) = await Task.detached(priority: .userInitiated) {
      (WindowList.snapshot(), pid.flatMap { MenuBarAX.appMenuExtent(pid: $0) })
    }.value
    let frames = MenuBarGeometry.statusItemFrames(in: screen.rect, windows: windows, excluding: excluded)
    let menusEnd = MenuBarGeometry.appMenuMaxX(on: screen.rect, extent: extent, menuBars: bars)
    return MenuBarGeometry.isEmptySpot(
      point, menuBar: screen.rect, itemFrames: frames, appMenuMaxX: menusEnd, notch: screen.notch
    )
  }
}
