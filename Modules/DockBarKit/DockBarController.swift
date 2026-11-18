import AppKit
import KitziCore
import SwiftUI

/// Borderless, non-activating panel at Dock level that hosts one Kitzi Dock.
final class DockBarPanel: NSPanel {
  init() {
    super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isFloatingPanel = true
    level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
    backgroundColor = .clear
    isOpaque = false
    hasShadow = false
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = true
    ignoresMouseEvents = true
    collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
    isReleasedWhenClosed = false
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Hosting view that reacts to the first click even though the panel never becomes key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSScreen {
  /// Stable identifier of the display, kept across reconnects and restarts.
  var dockBarDisplayID: String {
    guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
          let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
          let string = CFUUIDCreateString(nil, uuid) as String? else {
      return localizedName
    }
    return string
  }
}

/// Owns one Kitzi Dock per chosen display and routes the pointer to them.
final class DockBarController {
  private var docks: [String: ScreenDock] = [:]
  private let fitter = WindowFitter()
  private var monitors: [Any] = []
  private var screenObserver: NSObjectProtocol?

  var isShowing: Bool { !docks.isEmpty }

  func show() {
    if monitors.isEmpty {
      let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
      if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
        MainActor.assumeIsolated { self?.updatePointer() }
      }) {
        monitors.append(global)
      }
      if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
        MainActor.assumeIsolated { self?.updatePointer() }
        return event
      }) {
        monitors.append(local)
      }
      screenObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.syncDocks() }
      }
    }
    syncDocks()
  }

  func hide() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors.removeAll()
    if let screenObserver {
      NotificationCenter.default.removeObserver(screenObserver)
    }
    screenObserver = nil
    docks.values.forEach { $0.close() }
    docks.removeAll()
    fitter.stop()
    fitter.reservations = []
    KitziServices.windowPreviews?.hidePreviews()
  }

  /// Picks up display, size, magnification and edge changes; cheap when nothing changed.
  func applyPreferences() {
    syncDocks()
    docks.values.forEach { $0.applyPreferences() }
    updateFitter()
  }

  /// Keeps windows out of each dock's strip when "Keep windows clear" is on.
  private func updateFitter() {
    if DockBarPrefs.reserveSpace, !docks.isEmpty {
      fitter.start()
      fitter.reservations = docks.values.map(\.reservation)
    } else {
      fitter.stop()
      fitter.reservations = []
    }
  }

  func resetPinnedFromNativeDock() {
    docks.values.first?.model.resetPinnedFromNativeDock()
  }

  /// Displays that should have a dock right now, per the "Show on" setting.
  static func targetScreens() -> [NSScreen] {
    let screens = NSScreen.screens
    switch DockBarPrefs.displayMode {
    case .main:
      return Array(screens.prefix(1))
    case .all:
      return screens
    case .selected:
      let chosen = DockBarPrefs.selectedDisplays
      let matching = screens.filter { chosen.contains($0.dockBarDisplayID) }
      // If none of the chosen displays is connected, fall back to the main one.
      return matching.isEmpty ? Array(screens.prefix(1)) : matching
    }
  }

  private func syncDocks() {
    var wanted: [String: NSScreen] = [:]
    for screen in Self.targetScreens() {
      wanted[screen.dockBarDisplayID] = screen
    }
    for (id, dock) in docks where wanted[id] == nil {
      dock.close()
      docks[id] = nil
    }
    for (id, screen) in wanted {
      if let dock = docks[id] {
        dock.screen = screen
        dock.layoutPanel()
      } else {
        docks[id] = ScreenDock(screen: screen)
      }
    }
    updateFitter()
  }

  private func updatePointer() {
    docks.values.forEach { $0.updatePointer() }
  }
}

/// The dock on one display: placement, pointer tracking (clicks elsewhere pass through),
/// window previews on hover and the item actions.
final class ScreenDock {
  let model = DockBarModel()
  var screen: NSScreen

  private let panel = DockBarPanel()
  private var previewTask: Task<Void, Never>?
  private var previewedID: String?

  init(screen: NSScreen) {
    self.screen = screen
    applyPreferences(force: true)
    model.start()
    panel.contentView = FirstMouseHostingView(rootView: DockBarRootView(model: model, actions: makeActions()))
    layoutPanel()
    panel.orderFrontRegardless()
  }

  /// The strip of this display the dock keeps clear of windows.
  var reservation: DockReservation {
    DockReservation(screenFrame: screen.frame, visibleFrame: screen.visibleFrame, edge: model.edge,
                    thickness: DockBarRootView.edgeMargin + model.thickness + 4)
  }

  func close() {
    previewTask?.cancel()
    panel.orderOut(nil)
    model.stop()
  }

  func applyPreferences(force: Bool = false) {
    let iconSize = DockBarPrefs.iconSize
    let maxScale = DockBarPrefs.maxScale
    let edge = DockBarPrefs.edge
    guard force || iconSize != model.preferredIconSize || maxScale != model.maxScale || edge != model.edge else {
      model.rebuild()
      return
    }
    model.preferredIconSize = iconSize
    model.maxScale = maxScale
    model.edge = edge
    model.rebuild()
    layoutPanel()
  }

  // MARK: - Placement

  func layoutPanel() {
    let usable = model.isHorizontal ? screen.frame.width : screen.visibleFrame.maxY - screen.frame.minY
    model.availableLength = usable - 2 * DockBarRootView.edgeMargin
    // Side docks show the name bubble beside the icon, so they need room for it.
    let labelRoom: CGFloat = model.isHorizontal ? 0 : 240
    let depth = DockBarRootView.edgeMargin + model.thickness + model.headroom + labelRoom
    let frame = screen.frame
    let visible = screen.visibleFrame
    let panelFrame: NSRect = switch model.edge {
    case .bottom:
      NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: depth)
    case .left:
      NSRect(x: frame.minX, y: frame.minY, width: depth, height: visible.maxY - frame.minY)
    case .right:
      NSRect(x: frame.maxX - depth, y: frame.minY, width: depth, height: visible.maxY - frame.minY)
    }
    panel.setFrame(panelFrame, display: true)
  }

  // MARK: - Pointer

  func updatePointer() {
    let mouse = NSEvent.mouseLocation
    let frame = panel.frame
    // Panel-local SwiftUI coordinates: origin top-left.
    let local = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
    let hovering = frame.contains(mouse) && activeRect(in: frame.size).contains(local)

    panel.ignoresMouseEvents = !hovering
    if hovering {
      let along = model.isHorizontal ? local.x : local.y
      let panelLength = model.isHorizontal ? frame.width : frame.height
      let barStart = (panelLength - model.baseTotalLength) / 2
      model.pointer = along - barStart
      model.hoveredID = model.items.first { item in
        guard item.isIcon, let itemFrame = model.itemFrames[item.id] else { return false }
        return model.isHorizontal
          ? (itemFrame.minX...itemFrame.maxX).contains(local.x)
          : (itemFrame.minY...itemFrame.maxY).contains(local.y)
      }?.id
    } else if model.pointer != nil {
      model.pointer = nil
      model.hoveredID = nil
    }
    updatePreviews()
  }

  /// Where the pointer counts as "on the dock": the bar itself, and while hovering also
  /// the room the magnified icons grow into.
  private func activeRect(in size: CGSize) -> CGRect {
    let margin = DockBarRootView.edgeMargin
    let isHovering = model.pointer != nil
    let length = isHovering ? model.magnifiedTotalLength + model.iconSize : model.baseTotalLength
    let depth = model.thickness + (isHovering ? model.iconSize * (model.maxScale - 1) + 8 : 0)
    switch model.edge {
    case .bottom:
      return CGRect(x: (size.width - length) / 2, y: size.height - margin - depth, width: length, height: depth + margin)
    case .left:
      return CGRect(x: 0, y: (size.height - length) / 2, width: margin + depth, height: length)
    case .right:
      return CGRect(x: size.width - margin - depth, y: (size.height - length) / 2, width: margin + depth, height: length)
    }
  }

  // MARK: - Window previews

  private func updatePreviews() {
    let hovered = model.items.first { $0.id == model.hoveredID }
    if let hovered, hovered.kind == .app, hovered.isRunning, let pid = hovered.pid {
      guard hovered.id != previewedID else { return }
      previewedID = hovered.id
      previewTask?.cancel()
      previewTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(120))
        guard let self, !Task.isCancelled, model.hoveredID == hovered.id,
              let app = NSRunningApplication(processIdentifier: pid),
              let iconFrame = screenFrame(of: hovered.id) else { return }
        KitziServices.windowPreviews?.showPreviews(for: app, iconFrame: iconFrame, edge: model.edge)
      }
    } else if previewedID != nil {
      previewedID = nil
      previewTask?.cancel()
      previewTask = Task {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        KitziServices.windowPreviews?.hidePreviews()
      }
    }
  }

  private func screenFrame(of itemID: String) -> CGRect? {
    guard let local = model.itemFrames[itemID] else { return nil }
    let frame = panel.frame
    return CGRect(x: frame.minX + local.minX, y: frame.maxY - local.maxY, width: local.width, height: local.height)
  }

  // MARK: - Actions

  private func makeActions() -> DockBarActions {
    DockBarActions(
      open: { [weak self] item in self?.open(item) },
      showInFinder: { item in
        if let url = item.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      },
      keepInDock: { [weak self] item in
        if let url = item.url { self?.model.pin([url]) }
      },
      removeFromDock: { [weak self] item in self?.model.unpin(item) },
      hide: { item in
        item.pid.flatMap(NSRunningApplication.init(processIdentifier:))?.hide()
      },
      quit: { item, force in
        guard let app = item.pid.flatMap(NSRunningApplication.init(processIdentifier:)) else { return }
        if force { app.forceTerminate() } else { app.terminate() }
      },
      emptyTrash: { Self.emptyTrash() },
      dropFiles: { [weak self] urls, target in self?.drop(urls, on: target) },
      movePinned: { [weak self] id, target in
        guard let targetID = target.pinnedID?.uuidString else { return }
        self?.model.movePinned(id: id, before: targetID)
      }
    )
  }

  private func open(_ item: DockBarItem) {
    KitziServices.windowPreviews?.hidePreviews()
    guard let url = item.url else { return }
    switch item.kind {
    case .app:
      NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    default:
      NSWorkspace.shared.open(url)
    }
  }

  private func drop(_ urls: [URL], on target: DockBarItem?) {
    guard let target else {
      model.pin(urls)
      return
    }
    switch target.kind {
    case .trash:
      for url in urls {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
      }
    case .app where urls.allSatisfy({ $0.pathExtension == "app" }):
      model.pin(urls, before: target.pinnedID?.uuidString)
    case .app:
      if let appURL = target.url {
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
      }
    default:
      model.pin(urls, before: target.pinnedID?.uuidString)
    }
  }

  private static func emptyTrash() {
    let alert = NSAlert()
    alert.messageText = String(localized: "Empty the Trash?")
    alert.informativeText = String(localized: "Items in the Trash will be deleted immediately. You can't undo this action.")
    alert.addButton(withTitle: String(localized: "Empty Trash"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    alert.alertStyle = .warning
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    var error: NSDictionary?
    NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
  }
}
