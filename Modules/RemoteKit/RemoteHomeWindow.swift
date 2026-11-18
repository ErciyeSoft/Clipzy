import AppKit
import KitziCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The page, filters and sheets of the Remote Desktop window.
@Observable
final class RemoteHomeModel {
  enum Section: String, CaseIterable, Identifiable {
    case favorites, devices
    var id: String { rawValue }
  }

  enum ViewStyle: String { case tiles, list }
  enum Sort: String { case name, recent }

  var section = Section.devices
  var search = ""
  var viewStyle = ViewStyle(rawValue: UserDefaults.standard.string(forKey: RemotePreferences.viewStyleKey) ?? "") ?? .list {
    didSet { UserDefaults.standard.set(viewStyle.rawValue, forKey: RemotePreferences.viewStyleKey) }
  }
  var sort = Sort(rawValue: UserDefaults.standard.string(forKey: RemotePreferences.sortKey) ?? "") ?? .name {
    didSet { UserDefaults.standard.set(sort.rawValue, forKey: RemotePreferences.sortKey) }
  }
  var selection: UUID?
  /// The PC being added or edited.
  var editing: RemoteDevice?
  var editingIsNew = false
  var showingAccounts = false
  var addingGroup = false
  var renamingGroup: RemoteGroup?
  var confirmingDelete: RemoteDevice?
  var notice: String?

  func addDevice(groupID: UUID? = nil) {
    var device = RemoteDevice(address: "")
    device.groupID = groupID
    if section == .favorites { device.isFavorite = true }
    editingIsNew = true
    editing = device
  }

  func edit(_ device: RemoteDevice) {
    editingIsNew = false
    editing = device
  }

  func importFromWindowsApp() {
    do {
      let items = try WindowsAppImporter.read()
      let result = RemoteStore.shared.importDevices(items)
      notice = Self.describe(result)
    } catch {
      notice = error.localizedDescription
    }
  }

  func importRDPFiles(_ urls: [URL]) {
    var items: [RemoteImportedDevice] = []
    var failed = 0
    for url in urls {
      if let item = try? RDPFile.read(url) { items.append(item) } else { failed += 1 }
    }
    var text = Self.describe(RemoteStore.shared.importDevices(items))
    if failed > 0 { text += " " + String(localized: "\(failed) files couldn't be read.") }
    notice = text
  }

  func chooseRDPFiles() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [UTType(filenameExtension: "rdp") ?? .data]
    panel.message = String(localized: "Choose Remote Desktop (.rdp) files to add.")
    guard panel.runModal() == .OK else { return }
    importRDPFiles(panel.urls)
  }

  func export(_ device: RemoteDevice) {
    let store = RemoteStore.shared
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "rdp") ?? .data]
    panel.nameFieldStringValue = "\(device.displayName).rdp"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let text = RDPFile.export(device, account: store.account(device.accountID),
                              gatewayAccount: store.account(device.gateway.accountID))
    do {
      try text.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      notice = error.localizedDescription
    }
  }

  private static func describe(_ result: RemoteStore.ImportResult) -> String {
    if result.added == 0 && result.skipped == 0 { return String(localized: "No PCs were found to import.") }
    var text = String(localized: "Added \(result.added) PCs.")
    if result.skipped > 0 { text += " " + String(localized: "\(result.skipped) were already here.") }
    return text
  }
}

/// The Remote Desktop window: saved PCs in groups, like Windows App's Devices page.
///
/// Like the settings window, the sidebar and the page are AppKit split view items with their
/// own hosting controllers, and the toolbar is AppKit's.
final class RemoteHomeWindow: NSObject, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
  private static var shared: RemoteHomeWindow?
  private static let contentSize = NSSize(width: 1100, height: 680)

  private let model = RemoteHomeModel()
  private var window: NSWindow?
  private var viewStyleGroup: NSToolbarItemGroup?
  private var sortItem: NSMenuToolbarItem?

  static func show() {
    let controller = shared ?? RemoteHomeWindow()
    shared = controller
    controller.open()
  }

  private func open() {
    if window == nil {
      KitziWindows.didOpen()
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: Self.contentSize),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false
      )
      window.minSize = NSSize(width: 680, height: 420)
      window.isReleasedWhenClosed = false
      window.title = String(localized: "Remote Desktop")
      window.toolbarStyle = .unified
      let toolbar = NSToolbar(identifier: "KitziRemoteDesktopToolbar")
      toolbar.delegate = self
      toolbar.displayMode = .iconOnly
      toolbar.allowsUserCustomization = false
      window.toolbar = toolbar

      let split = makeSplitView()
      window.contentViewController = split
      window.setContentSize(Self.contentSize)
      window.layoutIfNeeded()
      split.splitView.setPosition(200, ofDividerAt: 0)
      window.delegate = self
      window.center()
      window.setFrameAutosaveName("KitziRemoteDesktop")
      self.window = window
      observeModel()
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.viewStyleGroup?.selectedIndex = self.model.viewStyle == .tiles ? 0 : 1
        }
      }
    }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  #if DEBUG
  /// Test hook: draws the window in both styles, plus the editor, into PNG files.
  static func snapshot(to directory: URL, importWindowsApp: Bool) {
    show()
    guard let controller = shared, let window = controller.window else { return }
    if importWindowsApp { controller.model.importFromWindowsApp() }
    func save(_ view: NSView?, _ name: String) {
      guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
      view.cacheDisplay(in: view.bounds, to: rep)
      try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
      // Also capture the real window with screencapture, which draws scroll views too.
      let target = directory.appendingPathComponent("window-" + name).path
      let windowNumber = (view.window ?? window).windowNumber
      let task = Process()
      task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      task.arguments = ["-x", "-o", "-l\(windowNumber)", target]
      try? task.run()
      task.waitUntilExit()
    }
    let steps: [(TimeInterval, () -> Void)] = [
      (1.5, { controller.model.viewStyle = .list }),
      (1.0, { save(window.contentView, "home-list.png"); controller.model.viewStyle = .tiles }),
      (1.0, { save(window.contentView, "home-tiles.png"); controller.model.section = .favorites }),
      (1.0, { save(window.contentView, "home-favorites.png"); controller.model.section = .devices
              if let device = RemoteStore.shared.devices.first { controller.model.edit(device) } }),
      (1.5, { save(window.attachedSheet?.contentView, "editor.png"); controller.model.editing = nil }),
    ]
    // A session against a local test server: the certificate question, the sign-in sheet,
    // then a connected desktop with test credentials.
    var sessionSteps: [(TimeInterval, () -> Void)] = []
    if let address = UserDefaults.standard.string(forKey: "RemoteDesktopSnapshotConnect") {
      var device = RemoteDevice(address: address)
      device.friendlyName = "Test PC"
      func sessionWindow() -> NSWindow? { NSApp.windows.first { $0.title == "Test PC" && $0.isVisible } }
      func tickAndContinue() {
        guard let window = sessionWindow(), let sheet = window.attachedSheet else { return }
        // Tick "Don't ask again" like a person would, then press Continue.
        func checkbox(in view: NSView) -> NSButton? {
          if let button = view as? NSButton, button.title == String(localized: "Don't ask again for this PC") {
            return button
          }
          return view.subviews.lazy.compactMap(checkbox(in:)).first
        }
        if let content = sheet.contentView { checkbox(in: content)?.performClick(nil) }
        save(sheet.contentView, "session-certificate-alert.png")
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
      }
      sessionSteps = [
        // TLS servers ask for the password first, then for the certificate.
        (1.0, {
          RemoteSessionController.testCredentials = ("selftest", "selftest")
          RemoteSessions.shared.connect(device)
        }),
        (2.5, { save(sessionWindow()?.contentView, "session-certificate.png"); tickAndContinue() }),
        (2.5, { save(sessionWindow()?.contentView, "session-connected.png"); sessionWindow()?.close() }),
        // Trusted now: the second connection must not ask again.
        (1.5, { RemoteSessions.shared.connect(device) }),
        (2.5, { save(sessionWindow()?.contentView, "session-reconnected.png"); sessionWindow()?.close() }),
        (1.5, {
          RemoteSessionController.testCredentials = nil
          RemoteSessions.shared.connect(device)
        }),
        (2.0, { save(sessionWindow()?.contentView, "session-signin.png"); sessionWindow()?.close() }),
      ]
    }
    let all = steps + sessionSteps + [(1.0, { NSApp.terminate(nil) })]
    var delay: TimeInterval = 0
    for (wait, step) in all {
      delay += wait
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { step() } }
    }
  }
  #endif

  func windowWillClose(_ notification: Notification) {
    window?.contentViewController = nil
    window?.toolbar = nil
    window = nil
    KitziWindows.didClose()
    Self.shared = nil
  }

  private func makeSplitView() -> NSSplitViewController {
    let sidebar = NSHostingController(rootView: RemoteSidebarView(model: model))
    sidebar.sizingOptions = []
    let page = NSHostingController(rootView: RemoteDevicesPage(model: model, store: .shared, sessions: .shared))
    page.sizingOptions = []

    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
    sidebarItem.minimumThickness = 170
    sidebarItem.maximumThickness = 260
    sidebarItem.canCollapse = true

    let split = NSSplitViewController()
    split.splitViewItems = [sidebarItem, NSSplitViewItem(viewController: page)]
    return split
  }

  // MARK: Toolbar

  private static let addID = NSToolbarItem.Identifier("remote.add")
  private static let styleID = NSToolbarItem.Identifier("remote.style")
  private static let sortID = NSToolbarItem.Identifier("remote.sort")
  private static let searchID = NSToolbarItem.Identifier("remote.search")

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.addID, Self.styleID, Self.sortID, Self.searchID]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
               willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    switch id {
    case Self.addID:
      let item = NSMenuToolbarItem(itemIdentifier: id)
      item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
      item.label = String(localized: "Add")
      item.toolTip = String(localized: "Add a PC, a group or import PCs")
      item.showsIndicator = false
      let menu = NSMenu()
      menu.addItem(menuItem(String(localized: "Add PC…"), #selector(addPC)))
      menu.addItem(menuItem(String(localized: "Add Group…"), #selector(addGroup)))
      menu.addItem(.separator())
      let windowsApp = menuItem(String(localized: "Import from Windows App"), #selector(importWindowsApp))
      menu.addItem(windowsApp)
      menu.addItem(menuItem(String(localized: "Import .rdp Files…"), #selector(importFiles)))
      menu.addItem(.separator())
      menu.addItem(menuItem(String(localized: "User Accounts…"), #selector(showAccounts)))
      item.menu = menu
      return item

    case Self.styleID:
      let group = NSToolbarItemGroup(
        itemIdentifier: id,
        images: [
          NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: String(localized: "Tiles"))!,
          NSImage(systemSymbolName: "list.bullet", accessibilityDescription: String(localized: "List"))!,
        ],
        selectionMode: .selectOne,
        labels: [String(localized: "Tiles"), String(localized: "List")],
        target: self, action: #selector(changeStyle(_:))
      )
      group.label = String(localized: "View")
      group.selectedIndex = model.viewStyle == .tiles ? 0 : 1
      viewStyleGroup = group
      return group

    case Self.sortID:
      let item = NSMenuToolbarItem(itemIdentifier: id)
      item.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)
      item.label = String(localized: "Sort")
      item.toolTip = String(localized: "Sort PCs")
      item.showsIndicator = false
      sortItem = item
      updateSortMenu()
      return item

    case Self.searchID:
      let item = NSSearchToolbarItem(itemIdentifier: id)
      item.searchField.delegate = self
      item.searchField.placeholderString = String(localized: "Search PCs")
      return item

    default:
      return nil
    }
  }

  private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  private func updateSortMenu() {
    let menu = NSMenu()
    let byName = menuItem(String(localized: "Sort by Name"), #selector(sortByName))
    byName.state = model.sort == .name ? .on : .off
    let byRecent = menuItem(String(localized: "Sort by Last Connected"), #selector(sortByRecent))
    byRecent.state = model.sort == .recent ? .on : .off
    menu.addItem(byName)
    menu.addItem(byRecent)
    sortItem?.menu = menu
  }

  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSSearchField else { return }
    model.search = field.stringValue
  }

  @objc private func addPC() { model.addDevice() }
  @objc private func addGroup() { model.addingGroup = true }
  @objc private func importWindowsApp() { model.importFromWindowsApp() }
  @objc private func importFiles() { model.chooseRDPFiles() }
  @objc private func showAccounts() { model.showingAccounts = true }

  @objc private func changeStyle(_ sender: NSToolbarItemGroup) {
    model.viewStyle = sender.selectedIndex == 0 ? .tiles : .list
  }

  /// Keeps the toolbar's view and sort controls in step with the model.
  private func observeModel() {
    withObservationTracking {
      _ = model.viewStyle
      _ = model.sort
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self else { return }
          self.viewStyleGroup?.selectedIndex = self.model.viewStyle == .tiles ? 0 : 1
          self.updateSortMenu()
          self.observeModel()
        }
      }
    }
  }

  @objc private func sortByName() {
    model.sort = .name
    updateSortMenu()
  }

  @objc private func sortByRecent() {
    model.sort = .recent
    updateSortMenu()
  }
}

// MARK: - Sidebar

struct RemoteSidebarView: View {
  @Bindable var model: RemoteHomeModel

  var body: some View {
    // Drawn by hand so the selected page stays marked even while the window isn't key.
    VStack(alignment: .leading, spacing: 2) {
      row(.favorites, title: String(localized: "Favorites"), icon: "star")
      row(.devices, title: String(localized: "Devices"), icon: "desktopcomputer")
      Spacer()
    }
    .padding(.horizontal, 10)
    .padding(.top, 8)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func row(_ section: RemoteHomeModel.Section, title: String, icon: String) -> some View {
    let selected = model.section == section
    return Button {
      model.section = section
    } label: {
      Label(title, systemImage: icon)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? Color.primary.opacity(0.09) : Color.clear)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Devices page

struct RemoteDevicesPage: View {
  @Bindable var model: RemoteHomeModel
  let store: RemoteStore
  let sessions: RemoteSessions
  @State private var groupName = ""
  @State private var dropTargeted = false

  private struct SectionData: Identifiable {
    let id: String
    let title: String
    let group: RemoteGroup?
    let devices: [RemoteDevice]
  }

  private var matchingDevices: [RemoteDevice] {
    let query = model.search.trimmingCharacters(in: .whitespaces)
    var list = store.devices
    if model.section == .favorites { list = list.filter(\.isFavorite) }
    if !query.isEmpty {
      list = list.filter { device in
        device.displayName.localizedCaseInsensitiveContains(query)
          || device.address.localizedCaseInsensitiveContains(query)
          || (store.account(device.accountID)?.username.localizedCaseInsensitiveContains(query) ?? false)
      }
    }
    switch model.sort {
    case .name:
      list.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    case .recent:
      list.sort { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
    }
    return list
  }

  private var sections: [SectionData] {
    let devices = matchingDevices
    if model.section == .favorites {
      return devices.isEmpty ? [] : [SectionData(id: "favorites", title: String(localized: "Favorites"), group: nil, devices: devices)]
    }
    var result: [SectionData] = []
    let groups = store.groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    for group in groups {
      let members = devices.filter { $0.groupID == group.id }
      // Empty groups stay visible so you can add PCs to them, except while searching.
      if !members.isEmpty || model.search.isEmpty {
        result.append(SectionData(id: group.id.uuidString, title: group.name, group: group, devices: members))
      }
    }
    let knownGroups = Set(store.groups.map(\.id))
    let ungrouped = devices.filter { $0.groupID.map { !knownGroups.contains($0) } ?? true }
    if !ungrouped.isEmpty {
      result.append(SectionData(id: "ungrouped", title: String(localized: "Saved PCs"), group: nil, devices: ungrouped))
    }
    return result
  }

  var body: some View {
    let sections = sections
    Group {
      if store.devices.isEmpty {
        emptyLibrary
      } else if sections.isEmpty {
        ContentUnavailableView(
          model.section == .favorites && model.search.isEmpty ? String(localized: "No Favorites") : String(localized: "No Matches"),
          systemImage: model.section == .favorites ? "star" : "magnifyingglass",
          description: Text(model.section == .favorites && model.search.isEmpty
                            ? String(localized: "Choose Add to Favorites on a PC to keep it here.")
                            : String(localized: "No saved PC matches your search."))
        )
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
            ForEach(sections) { section in
              sectionView(section)
            }
          }
          .padding(.horizontal, 20)
          .padding(.vertical, 16)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selection = nil }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .bottom) { noticeView }
    .overlay {
      if dropTargeted {
        RoundedRectangle(cornerRadius: 12)
          .stroke(Color.accentColor, lineWidth: 3)
          .padding(6)
          .allowsHitTesting(false)
      }
    }
    .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
      loadDroppedFiles(providers)
      return true
    }
    .sheet(item: $model.editing) { device in
      RemoteDeviceEditor(device: device, isNew: model.editingIsNew, store: store) { saved in
        if let saved { store.upsert(saved) }
        model.editing = nil
      }
    }
    .sheet(isPresented: $model.showingAccounts) {
      RemoteAccountsSheet(store: store) { model.showingAccounts = false }
    }
    .alert("New Group", isPresented: $model.addingGroup) {
      TextField("Name", text: $groupName)
      Button("Add") {
        let name = groupName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { store.addGroup(named: name) }
        groupName = ""
      }
      Button("Cancel", role: .cancel) { groupName = "" }
    }
    .alert("Rename Group", isPresented: Binding(get: { model.renamingGroup != nil }, set: { if !$0 { model.renamingGroup = nil } })) {
      TextField("Name", text: $groupName)
      Button("Rename") {
        if let group = model.renamingGroup { store.renameGroup(group.id, to: groupName) }
        groupName = ""
      }
      Button("Cancel", role: .cancel) { groupName = "" }
    }
    .confirmationDialog(
      String(localized: "Delete “\(model.confirmingDelete?.displayName ?? "")”?"),
      isPresented: Binding(get: { model.confirmingDelete != nil }, set: { if !$0 { model.confirmingDelete = nil } })
    ) {
      Button("Delete", role: .destructive) {
        if let device = model.confirmingDelete {
          store.delete([device.id])
          if model.selection == device.id { model.selection = nil }
        }
        model.confirmingDelete = nil
      }
    } message: {
      Text("The saved PC is removed from Kitzi. Its user account stays.")
    }
    .onKeyPress(.return) {
      guard let id = model.selection, let device = store.device(id) else { return .ignored }
      sessions.connect(device)
      return .handled
    }
    .onDeleteCommand {
      if let id = model.selection, let device = store.device(id) { model.confirmingDelete = device }
    }
  }

  @ViewBuilder
  private func sectionView(_ section: SectionData) -> some View {
    let collapsed = section.group?.isCollapsed ?? false
    VStack(alignment: .leading, spacing: 10) {
      Button {
        if let group = section.group { store.setGroupCollapsed(group.id, !collapsed) }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .rotationEffect(.degrees(collapsed ? -90 : 0))
            .foregroundStyle(.secondary)
            .opacity(section.group == nil ? 0 : 1)
          Text(section.title).font(.title3.weight(.semibold))
          Text("\(section.devices.count)")
            .font(.callout)
            .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .contextMenu {
        if let group = section.group {
          Button("Add PC to This Group…") { model.addDevice(groupID: group.id) }
          Button("Rename Group…") {
            groupName = group.name
            model.renamingGroup = group
          }
          Button("Delete Group", role: .destructive) { store.deleteGroup(group.id) }
        }
      }

      if !collapsed {
        if section.devices.isEmpty {
          Button("Add a PC to this group") { model.addDevice(groupID: section.group?.id) }
            .buttonStyle(.link)
            .padding(.leading, 18)
        } else {
          LazyVGrid(columns: columns, alignment: .leading, spacing: model.viewStyle == .tiles ? 20 : 14) {
            ForEach(section.devices) { device in
              tile(device)
            }
          }
        }
      }
    }
  }

  private var columns: [GridItem] {
    switch model.viewStyle {
    case .tiles: [GridItem(.adaptive(minimum: 210, maximum: 260), spacing: 20, alignment: .top)]
    case .list: [GridItem(.adaptive(minimum: 230, maximum: 300), spacing: 18, alignment: .leading)]
    }
  }

  private func tile(_ device: RemoteDevice) -> some View {
    RemoteDeviceTile(
      device: device,
      username: store.account(device.accountID)?.username,
      thumbnail: store.thumbnail(for: device.id),
      style: model.viewStyle,
      isSelected: model.selection == device.id,
      isOpen: sessions.isOpen(device.id),
      isConnected: sessions.isConnected(device.id)
    )
    .onTapGesture(count: 2) { sessions.connect(device) }
    .simultaneousGesture(TapGesture().onEnded { model.selection = device.id })
    .contextMenu {
      Button("Connect") { sessions.connect(device) }
      Button("Edit…") { model.edit(device) }
      Button("Duplicate") { store.duplicate(device.id) }
      Button(device.isFavorite ? "Remove from Favorites" : "Add to Favorites") { store.toggleFavorite(device.id) }
      Menu("Move to Group") {
        Button("No Group") { store.move([device.id], to: nil) }
        if !store.groups.isEmpty { Divider() }
        ForEach(store.groups) { group in
          Button(group.name) { store.move([device.id], to: group.id) }
        }
      }
      Button("Export as .rdp File…") { model.export(device) }
      Divider()
      Button("Delete…", role: .destructive) { model.confirmingDelete = device }
    }
  }

  private var emptyLibrary: some View {
    ContentUnavailableView {
      Label("No PCs Yet", systemImage: "desktopcomputer")
    } description: {
      Text("Add a PC by its name or IP address, or bring over the PCs saved in Windows App. You can also drop .rdp files here.")
    } actions: {
      Button("Add PC…") { model.addDevice() }
        .buttonStyle(.borderedProminent)
      if WindowsAppImporter.isAvailable {
        Button("Import from Windows App") { model.importFromWindowsApp() }
      }
    }
  }

  @ViewBuilder
  private var noticeView: some View {
    if let notice = model.notice {
      Text(notice)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 14)
        .task(id: notice) {
          try? await Task.sleep(for: .seconds(5))
          if model.notice == notice { model.notice = nil }
        }
    }
  }

  private func loadDroppedFiles(_ providers: [NSItemProvider]) {
    let group = DispatchGroup()
    let collected = DroppedURLs()
    for provider in providers {
      group.enter()
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        if let url, url.pathExtension.lowercased() == "rdp" { collected.append(url) }
        group.leave()
      }
    }
    group.notify(queue: .main) {
      MainActor.assumeIsolated {
        let urls = collected.all
        if !urls.isEmpty { model.importRDPFiles(urls) }
      }
    }
  }
}

nonisolated private final class DroppedURLs: @unchecked Sendable {
  private let lock = NSLock()
  private var urls: [URL] = []
  func append(_ url: URL) { lock.withLock { urls.append(url) } }
  var all: [URL] { lock.withLock { urls } }
}

// MARK: - Tile

struct RemoteDeviceTile: View {
  let device: RemoteDevice
  let username: String?
  let thumbnail: NSImage?
  let style: RemoteHomeModel.ViewStyle
  let isSelected: Bool
  let isOpen: Bool
  let isConnected: Bool

  var body: some View {
    switch style {
    case .list:
      HStack(spacing: 10) {
        preview(width: 80, height: 50, radius: 9)
        labels
        Spacer(minLength: 0)
      }
      .padding(5)
      .background(selection)
    case .tiles:
      VStack(alignment: .leading, spacing: 8) {
        preview(width: nil, height: 130, radius: 12)
        labels.padding(.horizontal, 2)
      }
      .padding(6)
      .background(selection)
    }
  }

  private var labels: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(device.displayName)
        .font(.system(size: 12.5, weight: .semibold))
        .lineLimit(1)
      Text(username ?? device.address)
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .help(device.address)
  }

  private var selection: some View {
    RoundedRectangle(cornerRadius: 12)
      .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
  }

  private func preview(width: CGFloat?, height: CGFloat, radius: CGFloat) -> some View {
    ZStack {
      if let thumbnail {
        Image(nsImage: thumbnail)
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        RemotePlaceholderArt(seed: device.id)
      }
    }
    .frame(width: width, height: height)
    .frame(maxWidth: width == nil ? .infinity : nil)
    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08))
    )
    .overlay(alignment: .bottomLeading) {
      if device.isFavorite {
        Image(systemName: "star.fill")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(.white)
          .padding(3)
          .background(Circle().fill(Color.pink.opacity(0.85)))
          .offset(x: -4, y: 4)
      }
    }
    .overlay(alignment: .topTrailing) {
      if isOpen {
        Circle()
          .fill(isConnected ? Color.green : Color.orange)
          .frame(width: 9, height: 9)
          .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
          .padding(5)
          .help(isConnected ? String(localized: "Connected") : String(localized: "Connecting"))
      }
    }
  }
}

/// A calm gradient for PCs without a picture yet; the colors vary per PC.
struct RemotePlaceholderArt: View {
  let seed: UUID

  var body: some View {
    let hue = Double(seed.uuid.0) / 255
    let first = Color(hue: hue, saturation: 0.45, brightness: 0.95)
    let second = Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.65, brightness: 0.7)
    ZStack {
      LinearGradient(colors: [first, second], startPoint: .topLeading, endPoint: .bottomTrailing)
      Image(systemName: "display")
        .font(.system(size: 20, weight: .light))
        .foregroundStyle(.white.opacity(0.85))
    }
  }
}
