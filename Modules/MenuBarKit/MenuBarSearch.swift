import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Observation
import SwiftUI

/// The list behind the search panel: menu bar items of running apps, filtered as you type.
@Observable
final class MenuBarSearchModel {
  var query = ""
  var items: [MenuBarExtraItem] = []
  var selection = 0
  var isLoading = false
  var isTrusted = AXIsProcessTrusted()
  var onActivate: (MenuBarExtraItem) -> Void = { _ in }

  @ObservationIgnored private var icons: [Int32: NSImage] = [:]

  var results: [MenuBarExtraItem] {
    MenuBarSearchFilter.filter(items, query: query)
  }

  func reset() {
    query = ""
    selection = 0
  }

  func reload() async {
    isTrusted = AXIsProcessTrusted()
    guard isTrusted else {
      items = []
      return
    }
    isLoading = true
    let apps = RunningAppInfo.all()
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let controlTitles = MenuBarSections.controlTitles
    items = await MenuBarAX.extras(of: apps).filter { !($0.pid == ownPID && controlTitles.contains($0.title)) }
    isLoading = false
    selection = min(selection, max(0, results.count - 1))
  }

  func moveSelection(by delta: Int) {
    let count = results.count
    guard count > 0 else { return }
    selection = min(max(0, selection + delta), count - 1)
  }

  func activateSelection() {
    let results = results
    guard results.indices.contains(selection) else { return }
    onActivate(results[selection])
  }

  func icon(for pid: Int32) -> NSImage? {
    if let icon = icons[pid] { return icon }
    let icon = NSRunningApplication(processIdentifier: pid)?.icon
    icons[pid] = icon
    return icon
  }
}

/// A floating panel to find a menu bar item by name and open it, even a hidden one.
/// It takes keyboard focus without activating Kitzi, like Spotlight.
final class MenuBarSearchPanel: NSObject, NSWindowDelegate {
  private let model = MenuBarSearchModel()
  private var panel: KeyPanel?
  private var keyMonitor: Any?

  /// Called with the chosen item after the panel closed.
  var onActivate: (MenuBarExtraItem) -> Void = { _ in }

  override init() {
    super.init()
    model.onActivate = { [weak self] item in
      self?.close()
      self?.onActivate(item)
    }
  }

  var isVisible: Bool { panel?.isVisible ?? false }

  func toggle() {
    isVisible ? close() : show()
  }

  func show() {
    let panel = panel ?? makePanel()
    self.panel = panel
    model.reset()
    // A fresh view each time so the search field takes focus again.
    panel.contentView = NSHostingView(rootView: MenuBarSearchView(model: model))
    position(panel)
    panel.makeKeyAndOrderFront(nil)
    installKeyMonitor()
    Task { await model.reload() }
  }

  func close() {
    removeKeyMonitor()
    panel?.orderOut(nil)
  }

  func windowDidResignKey(_ notification: Notification) {
    close()
  }

  private func makePanel() -> KeyPanel {
    let panel = KeyPanel(
      contentRect: NSRect(x: 0, y: 0, width: MenuBarSearchView.width, height: MenuBarSearchView.height),
      styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    panel.titlebarAppearsTransparent = true
    panel.titleVisibility = .hidden
    for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      panel.standardWindowButton(button)?.isHidden = true
    }
    panel.isMovableByWindowBackground = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.delegate = self
    return panel
  }

  /// Near the top of the screen with the pointer, centered.
  private func position(_ panel: NSPanel) {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return }
    let size = panel.frame.size
    let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - visible.height * 0.15)
    panel.setFrameOrigin(origin)
  }

  private func installKeyMonitor() {
    removeKeyMonitor()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, let panel = self.panel, event.window === panel else { return event }
      switch Int(event.keyCode) {
      case kVK_DownArrow:
        self.model.moveSelection(by: 1)
      case kVK_UpArrow:
        self.model.moveSelection(by: -1)
      case kVK_Return, kVK_ANSI_KeypadEnter:
        self.model.activateSelection()
      case kVK_Escape:
        self.close()
      default:
        return event
      }
      return nil
    }
  }

  private func removeKeyMonitor() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
  }
}

/// A panel that can become key although it never activates the app.
final class KeyPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

struct MenuBarSearchView: View {
  static let width: CGFloat = 440
  static let height: CGFloat = 360

  @Bindable var model: MenuBarSearchModel
  @FocusState private var isFieldFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Search menu bar items", text: $model.query)
          .textFieldStyle(.plain)
          .font(.title3)
          .focused($isFieldFocused)
        if model.isLoading {
          ProgressView()
            .controlSize(.small)
        }
      }
      .padding(.horizontal, 14)
      .padding(.top, 14)
      .padding(.bottom, 10)
      Divider()
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(width: Self.width, height: Self.height)
    .onChange(of: model.query) { model.selection = 0 }
    .task { isFieldFocused = true }
  }

  @ViewBuilder private var content: some View {
    let results = model.results
    if !model.isTrusted {
      VStack(spacing: 10) {
        Text("Kitzi needs Accessibility access to find menu bar items.")
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
        Button("Open Privacy Settings…") { MenuBarSettingsView.openAccessibilitySettings() }
      }
      .padding()
    } else if results.isEmpty, !model.isLoading {
      Text("No menu bar items found")
        .foregroundStyle(.secondary)
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(Array(results.enumerated()), id: \.element.id) { offset, item in
              row(item, isSelected: offset == model.selection)
                .id(item.id)
                .onTapGesture { model.onActivate(item) }
            }
          }
          .padding(6)
        }
        .onChange(of: model.selection) {
          if results.indices.contains(model.selection) {
            proxy.scrollTo(results[model.selection].id)
          }
        }
      }
    }
  }

  private func row(_ item: MenuBarExtraItem, isSelected: Bool) -> some View {
    HStack(spacing: 10) {
      if let icon = model.icon(for: item.pid) {
        Image(nsImage: icon)
          .resizable()
          .frame(width: 20, height: 20)
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: item.title)
          .lineLimit(1)
        if item.title != item.appName {
          Text(verbatim: item.appName)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(isSelected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
    .contentShape(Rectangle())
  }
}
