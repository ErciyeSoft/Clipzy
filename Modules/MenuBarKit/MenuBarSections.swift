import AppKit

/// The control status items: the Kitzi toggle, the hidden divider (|) and the optional
/// always hidden divider (‖), left to right: ‖ … | … toggle.
///
/// A divider hides everything left of it by growing so wide that those items no longer fit
/// in the menu bar. macOS remembers each item's position by its autosave name, so the user
/// arranges icons by ⌘-dragging them across the dividers.
final class MenuBarSections: NSObject {
  enum Name {
    static let toggle = "KitziMenuBarToggle"
    static let hidden = "KitziMenuBarHidden"
    static let alwaysHidden = "KitziMenuBarAlwaysHidden"
  }

  /// Wide enough to push everything left of a divider off any screen.
  static let collapsedLength: CGFloat = 10_000
  static let dividerLength: CGFloat = 14
  private static let maxRetries = 5
  private static let retryInterval: TimeInterval = 0.4

  /// What the user picked on the toggle or its menu.
  var onAction: (MenuBarAction) -> Void = { _ in }
  /// A click on a divider. A collapsed divider covers the empty part of the menu bar.
  var onDividerClick: (_ collapsed: Bool) -> Void = { _ in }
  var onSearch: () -> Void = {}
  var onSettings: () -> Void = {}
  /// The visible sections changed (also when a request could only be partly applied).
  var onVisibilityChange: (MenuBarVisibility) -> Void = { _ in }
  var onOrderProblemChange: (Bool) -> Void = { _ in }

  private var toggle: NSStatusItem?
  private var hiddenDivider: NSStatusItem?
  private var alwaysDivider: NSStatusItem?
  private(set) var visibility = MenuBarVisibility.shown
  private var requested = MenuBarVisibility.shown
  private var retries = 0
  private var retryTimer: Timer?
  private var verifyTimer: Timer?
  private(set) var hasOrderProblem = false

  var isInstalled: Bool { toggle != nil }

  /// Accessibility names of the control items, so search can leave them out even where
  /// macOS doesn't pass the identifier on.
  static var controlTitles: Set<String> {
    [Labels.show, Labels.hide, Labels.hiddenDivider, Labels.alwaysHiddenDivider]
  }

  private enum Labels {
    static var show: String { String(localized: "Show hidden menu bar icons") }
    static var hide: String { String(localized: "Hide menu bar icons") }
    static var hiddenDivider: String { String(localized: "Hidden icons divider") }
    static var alwaysHiddenDivider: String { String(localized: "Always hidden icons divider") }
  }

  /// Windows of the dividers; hit-testing treats them as empty menu bar.
  var dividerWindowNumbers: Set<Int> {
    Set([hiddenDivider, alwaysDivider].compactMap { $0?.button?.window?.windowNumber })
  }

  /// Windows of all control items, whose clicks are handled by their own actions.
  var controlWindowNumbers: Set<Int> {
    Set([toggle, hiddenDivider, alwaysDivider].compactMap { $0?.button?.window?.windowNumber })
  }

  // MARK: - Lifecycle

  /// Creates the items. Returns true on the very first run, when the dividers were just placed.
  @discardableResult
  func install(alwaysHidden: Bool) -> Bool {
    guard toggle == nil else { return false }
    let isFirstRun = Self.position(of: Name.hidden) == nil
    if isFirstRun {
      // The toggle goes to the right end of the app icons and the divider right next to it.
      // Positions count from the right edge of the screen.
      let togglePosition = Self.position(of: Name.toggle) ?? 0
      Self.setPosition(togglePosition, of: Name.toggle)
      Self.setPosition(togglePosition + 1, of: Name.hidden)
    }
    // A new always hidden divider has no position yet; macOS puts it at the left end.
    toggle = makeToggle()
    hiddenDivider = makeDivider(Name.hidden)
    if alwaysHidden { alwaysDivider = makeDivider(Name.alwaysHidden) }
    // Nothing is collapsed yet; the caller requests what it wants next.
    visibility = alwaysHidden ? .showingAll : .shown
    requested = visibility
    updateToggle()
    return isFirstRun
  }

  /// Removes the items, which makes every hidden icon visible again.
  func uninstall() {
    cancelRetry()
    if let alwaysDivider { remove(alwaysDivider, name: Name.alwaysHidden) }
    if let hiddenDivider { remove(hiddenDivider, name: Name.hidden) }
    if let toggle { remove(toggle, name: Name.toggle) }
    toggle = nil
    hiddenDivider = nil
    alwaysDivider = nil
    visibility = .shown
    requested = .shown
    setOrderProblem(false)
  }

  /// Shows every section without removing the items, e.g. right before the app quits.
  func expandAll() {
    cancelRetry()
    for divider in [hiddenDivider, alwaysDivider].compactMap({ $0 }) {
      divider.length = Self.dividerLength
    }
  }

  func setAlwaysHiddenSection(_ enabled: Bool) {
    guard isInstalled, enabled != (alwaysDivider != nil) else { return }
    if enabled {
      alwaysDivider = makeDivider(Name.alwaysHidden)
    } else if let alwaysDivider {
      remove(alwaysDivider, name: Name.alwaysHidden)
      self.alwaysDivider = nil
    }
    request(requested == .showingAll && !enabled ? .shown : requested)
  }

  /// Puts the toggle back at the right end with the divider next to it.
  func resetPositions() {
    let wasInstalled = isInstalled
    let hadAlwaysHidden = alwaysDivider != nil
    uninstall()
    for name in [Name.toggle, Name.hidden, Name.alwaysHidden] {
      UserDefaults.standard.removeObject(forKey: Self.positionKey(name))
    }
    if wasInstalled { install(alwaysHidden: hadAlwaysHidden) }
  }

  // MARK: - Visibility

  /// Shows or hides sections. A divider only collapses once it is known to sit left of the
  /// toggle; otherwise it would push the toggle itself off the menu bar.
  func request(_ desired: MenuBarVisibility) {
    requested = desired
    retries = 0
    applyRequested()
  }

  private func applyRequested() {
    cancelRetry()
    guard let toggle, let hiddenDivider else { return }
    var collapseHidden = false
    var collapseAlways = false
    var isPending = false
    var isWrong = false

    if requested.hidesHiddenSection {
      if isCollapsed(hiddenDivider) {
        collapseHidden = true
      } else {
        switch SectionOrder.checkHidden(toggle: frame(of: toggle), hidden: frame(of: hiddenDivider)) {
        case .ok: collapseHidden = true
        case .wrong: isWrong = true; isPending = true
        case .unknown: isPending = true
        }
      }
    }
    if requested.hidesAlwaysHiddenSection, let alwaysDivider {
      if isCollapsed(alwaysDivider) {
        collapseAlways = true
      } else {
        let check = SectionOrder.checkAlwaysHidden(
          toggle: frame(of: toggle), hidden: frame(of: hiddenDivider), always: frame(of: alwaysDivider)
        )
        switch check {
        case .ok: collapseAlways = true
        case .wrong: isWrong = true; isPending = true
        case .unknown: isPending = true
        }
      }
    }

    let didCollapse = (collapseHidden && !isCollapsed(hiddenDivider))
      || (collapseAlways && alwaysDivider.map { !isCollapsed($0) } ?? false)
    setCollapsed(hiddenDivider, collapseHidden, double: false)
    if let alwaysDivider { setCollapsed(alwaysDivider, collapseAlways, double: true) }
    if didCollapse { scheduleVerify() }

    let applied: MenuBarVisibility
    if collapseHidden {
      applied = .hidden
    } else if alwaysDivider != nil, !collapseAlways {
      applied = .showingAll
    } else {
      applied = .shown
    }
    if applied != visibility {
      visibility = applied
      updateToggle()
      onVisibilityChange(applied)
    }

    if isPending, retries < Self.maxRetries {
      // Frames settle a moment after items are created or moved.
      retries += 1
      retryTimer = Timer.scheduledTimer(withTimeInterval: Self.retryInterval, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated { self?.applyRequested() }
      }
    } else {
      setOrderProblem(isWrong)
    }
  }

  private func cancelRetry() {
    retryTimer?.invalidate()
    retryTimer = nil
    verifyTimer?.invalidate()
    verifyTimer = nil
  }

  private func scheduleVerify() {
    verifyTimer?.invalidate()
    verifyTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.verifyCollapsed() }
    }
  }

  /// Safety net after a collapse: if the toggle was pushed off the menu bar (frames were
  /// stale, or the order changed), show everything again and report the problem.
  private func verifyCollapsed() {
    verifyTimer = nil
    guard let toggle else { return }
    let toggleFrame = frame(of: toggle)
    let collapsed = [hiddenDivider, alwaysDivider].compactMap { $0 }.filter(isCollapsed)
    guard !collapsed.isEmpty else { return }
    let isBroken = toggleFrame == nil || collapsed.contains {
      SectionOrder.checkHidden(toggle: toggleFrame, hidden: frame(of: $0)) == .wrong
    }
    guard isBroken else { return }
    cancelRetry()
    for divider in collapsed {
      setCollapsed(divider, false, double: divider === alwaysDivider)
    }
    requested = alwaysDivider == nil ? .shown : .showingAll
    if visibility != requested {
      visibility = requested
      updateToggle()
      onVisibilityChange(requested)
    }
    setOrderProblem(true)
  }

  private func setOrderProblem(_ value: Bool) {
    guard value != hasOrderProblem else { return }
    hasOrderProblem = value
    onOrderProblemChange(value)
  }

  private func isCollapsed(_ item: NSStatusItem) -> Bool {
    item.length >= Self.collapsedLength - 1
  }

  private func setCollapsed(_ item: NSStatusItem, _ collapsed: Bool, double: Bool) {
    let length = collapsed ? Self.collapsedLength : Self.dividerLength
    if item.length != length { item.length = length }
    item.button?.image = collapsed ? nil : Self.dividerImage(double: double)
  }

  /// The item's window frame in screen coordinates, or nil when it isn't laid out or was
  /// pushed off the side of every screen. Only x counts: in full screen the menu bar slides away.
  private func frame(of item: NSStatusItem) -> CGRect? {
    guard let frame = item.button?.window?.frame, frame.width > 0 else { return nil }
    let isOnAScreen = NSScreen.screens.contains { $0.frame.minX < frame.maxX && frame.minX < $0.frame.maxX }
    return isOnAScreen ? frame : nil
  }

  // MARK: - Items

  private func makeItem(_ name: String, length: CGFloat) -> NSStatusItem {
    let item = NSStatusBar.system.statusItem(withLength: length)
    // Restores the position macOS saved for this name; no removal by ⌘-dragging it out.
    item.autosaveName = name
    item.behavior = []
    item.isVisible = true
    return item
  }

  private func makeToggle() -> NSStatusItem {
    let item = makeItem(Name.toggle, length: NSStatusItem.variableLength)
    if let button = item.button {
      button.target = self
      button.action = #selector(toggleClicked(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
      button.setAccessibilityIdentifier(MenuBarAX.controlIdentifierPrefix + "toggle")
    }
    return item
  }

  private func makeDivider(_ name: String) -> NSStatusItem {
    let item = makeItem(name, length: Self.dividerLength)
    if let button = item.button {
      button.image = Self.dividerImage(double: name == Name.alwaysHidden)
      button.target = self
      button.action = #selector(dividerClicked(_:))
      button.sendAction(on: [.leftMouseUp])
      // A collapsed divider spans the empty menu bar; don't paint a highlight across it.
      (button.cell as? NSButtonCell)?.highlightsBy = []
      button.setAccessibilityIdentifier(MenuBarAX.controlIdentifierPrefix + name)
      button.setAccessibilityLabel(name == Name.alwaysHidden ? Labels.alwaysHiddenDivider : Labels.hiddenDivider)
    }
    return item
  }

  private func remove(_ item: NSStatusItem, name: String) {
    let key = Self.positionKey(name)
    let saved = UserDefaults.standard.object(forKey: key)
    NSStatusBar.system.removeStatusItem(item)
    // macOS may forget the position of a removed item; keep it for the next time.
    if let saved { UserDefaults.standard.set(saved, forKey: key) }
  }

  private func updateToggle() {
    guard let button = toggle?.button else { return }
    let isHidden = visibility == .hidden
    let label = isHidden ? Labels.show : Labels.hide
    let symbol = isHidden ? "chevron.compact.left" : "chevron.compact.right"
    let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
      .withSymbolConfiguration(configuration)
    image?.isTemplate = true
    button.image = image
    button.toolTip = label
  }

  /// A thin vertical bar, or two for the always hidden divider. Drawn here rather than taken
  /// from SF Symbols so it looks the same on every macOS version.
  nonisolated private static func dividerImage(double: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: double ? 7 : 4, height: 16), flipped: false) { _ in
      NSColor.black.setFill()
      for x in double ? [1.0, 4.5] : [1.25] {
        NSBezierPath(roundedRect: NSRect(x: x, y: 2, width: 1.5, height: 12), xRadius: 0.75, yRadius: 0.75).fill()
      }
      return true
    }
    image.isTemplate = true
    return image
  }

  // MARK: - Actions

  @objc private func toggleClicked(_ sender: NSStatusBarButton) {
    let event = NSApp.currentEvent
    let flags = event?.modifierFlags ?? []
    if event?.type == .rightMouseUp || flags.contains(.control) {
      showMenu()
    } else {
      onAction(flags.contains(.option) ? .toggleAll : .toggle)
    }
  }

  @objc private func dividerClicked(_ sender: NSStatusBarButton) {
    let divider = [hiddenDivider, alwaysDivider].compactMap { $0 }.first { $0.button === sender }
    onDividerClick(divider.map(isCollapsed) ?? false)
  }

  private func showMenu() {
    guard let toggle else { return }
    toggle.menu = makeMenu()
    toggle.button?.performClick(nil)
    toggle.menu = nil
  }

  private func makeMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let showTitle = visibility == .hidden ? String(localized: "Show Hidden Icons") : String(localized: "Hide Icons")
    menu.addItem(actionItem(showTitle, #selector(menuToggle)))
    if alwaysDivider != nil {
      let allTitle = visibility == .showingAll
        ? String(localized: "Hide Always Hidden Icons") : String(localized: "Show Always Hidden Icons")
      menu.addItem(actionItem(allTitle, #selector(menuToggleAll)))
    }
    menu.addItem(actionItem(String(localized: "Search Menu Bar…"), #selector(menuSearch)))
    menu.addItem(.separator())
    menu.addItem(hintItem(String(localized: "⌘-drag icons left of the | to hide them")))
    if alwaysDivider != nil {
      menu.addItem(hintItem(String(localized: "Icons left of the ‖ show only on ⌥-click")))
    }
    if hasOrderProblem {
      menu.addItem(hintItem(String(localized: "The | must be left of this icon")))
    }
    menu.addItem(.separator())
    menu.addItem(actionItem(String(localized: "Menu Bar Settings…"), #selector(menuSettings)))
    return menu
  }

  private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  private func hintItem(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  @objc private func menuToggle() { onAction(.toggle) }
  @objc private func menuToggleAll() { onAction(.toggleAll) }
  @objc private func menuSearch() { onSearch() }
  @objc private func menuSettings() { onSettings() }

  // MARK: - Saved positions

  static func positionKey(_ name: String) -> String {
    "NSStatusItem Preferred Position \(name)"
  }

  static func position(of name: String) -> Double? {
    (UserDefaults.standard.object(forKey: positionKey(name)) as? NSNumber)?.doubleValue
  }

  static func setPosition(_ value: Double, of name: String) {
    UserDefaults.standard.set(value, forKey: positionKey(name))
  }
}
