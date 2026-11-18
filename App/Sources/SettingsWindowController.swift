import AppKit
import KitziCore
import SwiftUI

@Observable
final class SettingsSelection {
  var pageID: String?
}

/// The single settings window that hosts every feature's pages in one sidebar.
///
/// The sidebar and the page are AppKit split view items, each with its own hosting controller.
/// SwiftUI's NavigationSplitView builds its split view controller in the middle of a view graph
/// update; on macOS 26.6 that crashed Kitzi while the window sized itself for the first time.
final class SettingsWindowController: NSObject, NSWindowDelegate {
  private static let contentSize = NSSize(width: 920, height: 640)
  private static let sidebarWidth: CGFloat = 230

  private var window: NSWindow?
  private let selection = SettingsSelection()
  private let groups: () -> [SettingsGroup]
  private let onClose: () -> Void

  init(groups: @escaping () -> [SettingsGroup], onClose: @escaping () -> Void) {
    self.groups = groups
    self.onClose = onClose
  }

  func show(pageID: String?) {
    let groups = groups()
    let knownIDs = Set(groups.flatMap(\.pages).map(\.id))
    if let pageID, knownIDs.contains(pageID) {
      selection.pageID = pageID
    } else if selection.pageID.map(knownIDs.contains) != true {
      selection.pageID = groups.first?.pages.first?.id
    }

    if window == nil {
      KitziWindows.didOpen()
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: Self.contentSize),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
      )
      window.minSize = NSSize(width: 760, height: 460)
      window.isReleasedWhenClosed = false
      window.title = "Kitzi"
      window.toolbarStyle = .unified
      window.toolbar = NSToolbar(identifier: "KitziSettingsToolbar")
      let split = makeSplitView(groups: groups, window: window)
      window.contentViewController = split
      window.setContentSize(Self.contentSize)
      window.layoutIfNeeded()
      split.splitView.setPosition(Self.sidebarWidth, ofDividerAt: 0)
      window.delegate = self
      window.center()
      self.window = window
    }

    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) {
    window?.contentViewController = nil
    window = nil
    KitziWindows.didClose()
    onClose()
  }

  private func makeSplitView(groups: [SettingsGroup], window: NSWindow) -> NSSplitViewController {
    // The window sets its own size limits; the hosting controllers must not resize it.
    let sidebar = NSHostingController(rootView: SettingsSidebarView(groups: groups, selection: selection))
    sidebar.sizingOptions = []
    let detail = NSHostingController(
      rootView: SettingsDetailView(groups: groups, selection: selection) { [weak window] page in
        window?.title = page?.title ?? "Kitzi"
        window?.subtitle = page?.subtitle ?? ""
      }
    )
    detail.sizingOptions = []

    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
    sidebarItem.minimumThickness = 210
    sidebarItem.maximumThickness = 280
    sidebarItem.canCollapse = false

    let split = NSSplitViewController()
    split.splitViewItems = [sidebarItem, NSSplitViewItem(viewController: detail)]
    return split
  }
}

struct SettingsSidebarView: View {
  let groups: [SettingsGroup]
  @Bindable var selection: SettingsSelection

  var body: some View {
    List(selection: $selection.pageID) {
      ForEach(groups) { group in
        Section(group.title) {
          ForEach(group.pages) { page in
            Label(page.title, systemImage: page.systemImage)
              .tag(Optional(page.id))
          }
        }
      }
    }
    .listStyle(.sidebar)
  }
}

struct SettingsDetailView: View {
  let groups: [SettingsGroup]
  let selection: SettingsSelection
  /// Puts the page's title and subtitle in the window's title bar.
  let showTitle: (SettingsPage?) -> Void

  private var currentPage: SettingsPage? {
    groups.lazy.flatMap(\.pages).first { $0.id == selection.pageID }
  }

  var body: some View {
    Group {
      if let page = currentPage {
        page.makeView()
          .id(page.id)
      } else {
        ContentUnavailableView("Kitzi", systemImage: "gearshape")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onChange(of: selection.pageID, initial: true) {
      showTitle(currentPage)
    }
  }
}
