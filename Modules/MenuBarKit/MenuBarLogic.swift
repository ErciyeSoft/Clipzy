import CoreGraphics
import Foundation

// Pure decisions of the menu bar module, free of AppKit so they can be unit tested.

// MARK: - Visibility

/// Which sections of the menu bar are visible right now.
enum MenuBarVisibility: Sendable, Equatable {
  /// Only the items right of the hidden divider are visible.
  case hidden
  /// The hidden section is visible; the always hidden section is not.
  case shown
  /// Both the hidden and the always hidden sections are visible.
  case showingAll

  var hidesHiddenSection: Bool { self == .hidden }
  var hidesAlwaysHiddenSection: Bool { self != .showingAll }

  /// The state after `action`. Without an always hidden section, "all" means "shown".
  func applying(_ action: MenuBarAction, alwaysHiddenEnabled: Bool) -> MenuBarVisibility {
    let all: MenuBarVisibility = alwaysHiddenEnabled ? .showingAll : .shown
    switch action {
    case .toggle:
      return self == .hidden ? .shown : .hidden
    case .toggleAll:
      return self == all ? .hidden : all
    case .reveal:
      return self == .hidden ? .shown : self
    case .revealAll:
      return all
    case .hide:
      return .hidden
    }
  }
}

/// Things that change which sections are visible.
enum MenuBarAction: Sendable, Equatable {
  /// Click on the toggle, hotkey, click in an empty part of the menu bar.
  case toggle
  /// ⌥-click on the toggle or the always hidden hotkey.
  case toggleAll
  /// Hover or scroll: show the hidden section, never hide.
  case reveal
  /// Show everything, e.g. before pressing an item found by search.
  case revealAll
  /// Auto-rehide or a click outside the menu bar.
  case hide
}

// MARK: - Rehide

enum RehideDecision: Sendable, Equatable {
  case hide
  /// Check again after this many seconds.
  case wait(TimeInterval)
  /// Nothing to schedule.
  case never
}

enum RehidePolicy {
  /// How often a postponed rehide is checked again.
  static let retryInterval: TimeInterval = 1

  /// Whether items shown since `shownAt` should be hidden now.
  /// - Parameters:
  ///   - delay: seconds after which items hide again; 0 or less means never.
  ///   - isBusy: the mouse is over the menu bar, a button is held or a menu is open.
  static func decide(now: Date, shownAt: Date, delay: TimeInterval, isBusy: Bool) -> RehideDecision {
    guard delay > 0 else { return .never }
    let remaining = delay - now.timeIntervalSince(shownAt)
    if remaining > 0 { return .wait(remaining) }
    return isBusy ? .wait(retryInterval) : .hide
  }

  /// Delays offered on the settings page, in seconds (0 = never).
  static let delayChoices = [5, 10, 15, 30, 0]
}

// MARK: - Section order

/// Checks that the control items are in the order the hiding trick needs:
/// always hidden divider, hidden divider, toggle (left to right).
///
/// A divider hides what is left of it by growing to the left; its right edge stays put, so
/// right edges are compared. A divider right of the toggle would push the toggle off screen.
enum SectionOrder {
  enum Check: Sendable, Equatable {
    case ok
    case wrong
    /// A frame isn't known yet (item not laid out or off screen).
    case unknown
  }

  static let tolerance: CGFloat = 1

  static func checkHidden(toggle: CGRect?, hidden: CGRect?) -> Check {
    guard let toggle, let hidden, !toggle.isEmpty, !hidden.isEmpty else { return .unknown }
    return hidden.maxX <= toggle.minX + tolerance ? .ok : .wrong
  }

  static func checkAlwaysHidden(toggle: CGRect?, hidden: CGRect?, always: CGRect?) -> Check {
    let hiddenCheck = checkHidden(toggle: toggle, hidden: hidden)
    guard hiddenCheck == .ok else { return hiddenCheck }
    guard let hidden, let always, !always.isEmpty else { return .unknown }
    return always.maxX < hidden.maxX - tolerance ? .ok : .wrong
  }
}

// MARK: - Geometry

/// Menu bar geometry in Quartz coordinates (origin at the top-left of the main screen, y down),
/// the space used by CGWindowList and Accessibility.
enum MenuBarGeometry {
  /// Converts a Cocoa rect (origin bottom-left of the main screen) to Quartz coordinates.
  static func quartzRect(fromCocoa rect: CGRect, mainScreenHeight: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: mainScreenHeight - rect.maxY, width: rect.width, height: rect.height)
  }

  static func quartzPoint(fromCocoa point: CGPoint, mainScreenHeight: CGFloat) -> CGPoint {
    CGPoint(x: point.x, y: mainScreenHeight - point.y)
  }

  /// The menu bar strip of a screen, given its Cocoa frame and visible frame.
  /// `fallbackHeight` is used when the menu bar hides itself (full screen, auto-hide).
  static func menuBarRect(
    screenFrame: CGRect, visibleFrame: CGRect, fallbackHeight: CGFloat, mainScreenHeight: CGFloat
  ) -> CGRect {
    var height = screenFrame.maxY - visibleFrame.maxY
    if height < 10 || height > 80 { height = fallbackHeight }
    let cocoa = CGRect(x: screenFrame.minX, y: screenFrame.maxY - height, width: screenFrame.width, height: height)
    return quartzRect(fromCocoa: cocoa, mainScreenHeight: mainScreenHeight)
  }

  /// Frames of status item windows inside `menuBar`, without our own control items and without
  /// windows too wide to be a single item (an expanded divider).
  static func statusItemFrames(in menuBar: CGRect, windows: [WindowSnapshot], excluding ids: Set<Int>) -> [CGRect] {
    windows.compactMap { window in
      guard window.layer == WindowSnapshot.statusLayer, !ids.contains(window.id),
            window.frame.intersects(menuBar),
            window.frame.height <= menuBar.height + 2,
            window.frame.width < menuBar.width / 2 else { return nil }
      return window.frame
    }
  }

  /// Where the frontmost app's menus end on `menuBar`, given their extent on the screen they
  /// were read from. App menus start at the left edge of every menu bar with the same width.
  static func appMenuMaxX(on menuBar: CGRect, extent: ClosedRange<CGFloat>?, menuBars: [CGRect]) -> CGFloat? {
    guard let extent else { return nil }
    let source = menuBars.first { $0.minX <= extent.lowerBound && extent.lowerBound < $0.maxX }
    guard let source else { return nil }
    return menuBar.minX + (extent.upperBound - source.minX)
  }

  /// True when `point` is on the menu bar but not on an app menu, a status item or the notch.
  /// Without the app menus' extent (no Accessibility), only the right half counts as empty.
  static func isEmptySpot(
    _ point: CGPoint, menuBar: CGRect, itemFrames: [CGRect], appMenuMaxX: CGFloat?, notch: CGRect?
  ) -> Bool {
    guard menuBar.contains(point) else { return false }
    if let notch, notch.insetBy(dx: -4, dy: 0).contains(CGPoint(x: point.x, y: notch.midY)) { return false }
    let menusEnd = appMenuMaxX.map { $0 + 8 } ?? max(menuBar.midX, notch?.maxX ?? 0)
    guard point.x > menusEnd else { return false }
    return !itemFrames.contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
  }

  /// Whether a menu or a popover-like window hangs below the menu bar, e.g. the menu of an item
  /// that is being shown. Best effort: such windows sit just under the menu bar.
  static func isMenuOpen(windows: [WindowSnapshot], menuBars: [CGRect]) -> Bool {
    windows.contains { window in
      if window.layer == WindowSnapshot.popUpMenuLayer { return true }
      guard window.layer >= WindowSnapshot.floatingLayer, window.layer < WindowSnapshot.screenSaverLayer,
            !WindowSnapshot.systemOwners.contains(window.ownerName) else { return false }
      return menuBars.contains { bar in
        let isStatusItem = window.frame.height <= bar.height + 2
        let isOverlay = window.frame.width > bar.width * 0.9
        let hangsBelow = abs(window.frame.minY - bar.maxY) <= 12 && window.frame.intersects(bar.insetBy(dx: 0, dy: -14))
        return !isStatusItem && !isOverlay && hangsBelow
      }
    }
  }

  /// True when `point` is inside a menu or a window that hangs below the menu bar.
  static func isInsideMenu(_ point: CGPoint, windows: [WindowSnapshot], menuBars: [CGRect]) -> Bool {
    windows.contains { window in
      window.frame.contains(point) && isMenuOpen(windows: [window], menuBars: menuBars)
    }
  }
}

/// One on-screen window from CGWindowList, reduced to what the module needs.
struct WindowSnapshot: Sendable, Equatable {
  static let floatingLayer = 3
  static let statusLayer = 25
  static let popUpMenuLayer = 101
  static let screenSaverLayer = 1000
  static let systemOwners: Set<String> = ["Window Server", "Dock"]

  var id: Int
  var pid: Int32
  var layer: Int
  /// Quartz coordinates.
  var frame: CGRect
  var ownerName: String
}

// MARK: - Scrolling

/// Turns scroll events over the menu bar into show and hide gestures.
/// Deltas are summed until they pass a threshold; after a gesture fires, the rest of the
/// swipe is ignored for a moment so one swipe never toggles twice.
struct ScrollGate: Sendable {
  enum Gesture: Sendable, Equatable { case show, hide }

  var threshold: CGFloat = 6
  var quietInterval: TimeInterval = 0.35
  var cooldown: TimeInterval = 0.6

  private var total: CGFloat = 0
  private var lastEvent = Date.distantPast
  private var blockedUntil = Date.distantPast

  init() {}

  /// - Parameters:
  ///   - deltaY: `scrollingDeltaY` of the event.
  ///   - inverted: `isDirectionInvertedFromDevice` (natural scrolling).
  mutating func feed(deltaY: CGFloat, inverted: Bool, at now: Date) -> Gesture? {
    if now.timeIntervalSince(lastEvent) > quietInterval { total = 0 }
    lastEvent = now
    guard now >= blockedUntil else { return nil }
    // Positive = fingers (or wheel) moving down, whatever the scrolling direction setting.
    total += inverted ? deltaY : -deltaY
    guard abs(total) >= threshold else { return nil }
    let gesture: Gesture = total > 0 ? .show : .hide
    total = 0
    blockedUntil = now.addingTimeInterval(cooldown)
    return gesture
  }
}

// MARK: - Search

/// A menu bar item of a running app, as listed in the search panel.
struct MenuBarExtraItem: Sendable, Identifiable, Equatable {
  var pid: Int32
  /// Position among the app's menu bar items, used to find it again.
  var index: Int
  var title: String
  var appName: String
  var bundleID: String?

  var id: String { "\(pid)-\(index)" }
}

enum MenuBarSearchFilter {
  /// Items matching every word of `query` in their title or app name, best matches first.
  /// Case and diacritics are ignored ("cikti" finds "Çıktı").
  static func filter(_ items: [MenuBarExtraItem], query: String) -> [MenuBarExtraItem] {
    let words = normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty else { return items }
    let scored: [(item: MenuBarExtraItem, score: Int, offset: Int)] = items.enumerated().compactMap { offset, item in
      let title = normalize(item.title)
      let haystack = title + " " + normalize(item.appName)
      guard words.allSatisfy({ haystack.contains($0) }) else { return nil }
      var score = 0
      if title.hasPrefix(words[0]) { score += 2 }
      if title.split(separator: " ").contains(where: { $0.hasPrefix(words[0]) }) { score += 1 }
      return (item, score, offset)
    }
    return scored
      .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
      .map(\.item)
  }

  static func normalize(_ text: String) -> String {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .replacingOccurrences(of: "ı", with: "i")
  }
}
