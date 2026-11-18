import AppKit
import KitziCore
import SwiftUI

/// Public entry point of the battery module: a menu bar item with the levels of the Mac
/// and connected Bluetooth accessories, plus a settings page to turn it on or off.
public final class BatteryFeature: KitziFeature {
  static let pageID = "battery.general"

  private let monitor = BatteryMonitor()
  private var statusItem: NSStatusItem?
  private var labelView: PassthroughHostingView<BatteryMenuBarLabel>?
  private let popover = NSPopover()
  private var defaultsObserver: NSObjectProtocol?

  public init() {
    BatteryPrefs.register()
  }

  public func applicationDidFinishLaunching() {
    monitor.onUpdate = { [weak self] in self?.updateStatusItem() }
    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.applyPreferences() }
    }
    applyPreferences()
  }

  public func applicationWillTerminate() {
    monitor.stop()
  }

  public var settingsGroups: [SettingsGroup] {
    [
      SettingsGroup(
        id: "battery",
        title: String(localized: "Battery"),
        pages: [
          SettingsPage(
            id: Self.pageID,
            title: String(localized: "Battery"),
            subtitle: String(localized: "Battery levels of your Mac and Bluetooth devices"),
            systemImage: "battery.75percent"
          ) { [monitor] in
            BatterySettingsView(monitor: monitor)
          }
        ]
      )
    ]
  }

  private func applyPreferences() {
    if BatteryPrefs.enabled {
      if !monitor.isRunning { monitor.start() }
    } else if monitor.isRunning {
      monitor.stop()
    }
    updateStatusItem()
  }

  private func updateStatusItem() {
    guard BatteryPrefs.enabled else {
      if let statusItem {
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        labelView = nil
      }
      popover.performClose(nil)
      return
    }

    let item = statusItem ?? makeStatusItem()
    let label = BatteryMenuBarLabel(
      devices: monitor.devices.filter(BatteryPrefs.isShownInMenuBar),
      showPercent: BatteryPrefs.showPercent,
      threshold: BatteryPrefs.threshold
    )
    labelView?.rootView = label
    // Measure with a throwaway view: the one in the button has sizing disabled on purpose.
    let width = NSHostingView(rootView: label).fittingSize.width
    item.length = max(24, ceil(width))
    item.button?.setAccessibilityLabel(accessibilitySummary())
  }

  private func makeStatusItem() -> NSStatusItem {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.autosaveName = "KitziBattery"
    if let button = item.button {
      button.target = self
      button.action = #selector(togglePopover(_:))
      // Frame-based with SwiftUI sizing off: the button keeps the status bar's size
      // and the label is centered inside it.
      let view = PassthroughHostingView(rootView: BatteryMenuBarLabel(devices: [], showPercent: true, threshold: 20))
      view.sizingOptions = []
      view.frame = button.bounds
      view.autoresizingMask = [.width, .height]
      button.addSubview(view)
      labelView = view
    }
    popover.behavior = .transient
    statusItem = item
    return item
  }

  @objc private func togglePopover(_ sender: NSStatusBarButton) {
    if popover.isShown {
      popover.performClose(sender)
      return
    }
    monitor.poll()
    let controller = NSHostingController(
      rootView: BatteryListView(monitor: monitor, threshold: BatteryPrefs.threshold) { [weak self] in
        self?.popover.performClose(nil)
        KitziHost.openSettings(Self.pageID)
      }
    )
    // Size the popover before showing it. Otherwise it is placed for a default square
    // size and then shrinks from the top, opening far below the menu bar.
    controller.sizingOptions = .preferredContentSize
    popover.contentViewController = controller
    popover.contentSize = controller.view.fittingSize
    popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
  }

  private func accessibilitySummary() -> String {
    let parts = monitor.devices.map { "\($0.name) \($0.formattedPercent)" }
    return ([String(localized: "Battery")] + parts).joined(separator: ", ")
  }
}

/// Hosting view that lets clicks fall through to the status bar button underneath.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}
