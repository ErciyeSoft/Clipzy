import AppKit
import SwiftUI

/// Adds or edits a saved PC.
struct RemoteDeviceEditor: View {
  @State private var device: RemoteDevice
  let isNew: Bool
  let store: RemoteStore
  let completion: (RemoteDevice?) -> Void

  @State private var addingAccountFor: AccountTarget?
  @State private var addingGroup = false
  @State private var newGroupName = ""

  enum AccountTarget: Identifiable {
    case pc, gateway
    var id: Self { self }
  }

  init(device: RemoteDevice, isNew: Bool, store: RemoteStore, completion: @escaping (RemoteDevice?) -> Void) {
    _device = State(initialValue: device)
    self.isNew = isNew
    self.store = store
    self.completion = completion
  }

  private var isValid: Bool {
    !device.hostAndPort.host.isEmpty && !device.address.contains(" ")
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          TextField("PC name", text: $device.address, prompt: Text(verbatim: "pc.example.com, 10.0.0.5:3390"))
          Picker("User account", selection: accountBinding(\.accountID, target: .pc)) {
            Text("Ask when required").tag(AccountChoice.none)
            if !store.accounts.isEmpty { Divider() }
            ForEach(store.accounts) { account in
              Text(account.displayName).tag(AccountChoice.account(account.id))
            }
            Divider()
            Text("Add User Account…").tag(AccountChoice.add)
          }
        }

        Section("General") {
          TextField("Friendly name", text: $device.friendlyName, prompt: Text("Optional"))
          Picker("Group", selection: groupBinding) {
            Text("None").tag(GroupChoice.none)
            if !store.groups.isEmpty { Divider() }
            ForEach(store.groups) { group in
              Text(group.name).tag(GroupChoice.group(group.id))
            }
            Divider()
            Text("New Group…").tag(GroupChoice.add)
          }
          Toggle("Show in Favorites", isOn: $device.isFavorite)
        }

        Section {
          TextField("Gateway", text: $device.gateway.address, prompt: Text("None"))
          if device.gateway.isEnabled {
            Toggle("Sign in to the gateway with the PC's account", isOn: $device.gateway.useSameAccount)
            if !device.gateway.useSameAccount {
              Picker("Gateway account", selection: accountBinding(\.gateway.accountID, target: .gateway)) {
                Text("Ask when required").tag(AccountChoice.none)
                ForEach(store.accounts) { account in
                  Text(account.displayName).tag(AccountChoice.account(account.id))
                }
                Divider()
                Text("Add User Account…").tag(AccountChoice.add)
              }
            }
          }
        } header: {
          Text("Remote Desktop Gateway")
        } footer: {
          Text("Only needed when the PC is reached through an RD Gateway server.")
            .foregroundStyle(.secondary)
        }

        Section("Display") {
          Picker("Resolution", selection: resolutionBinding) {
            Text("Match the window").tag(ResolutionChoice.matchWindow)
            Divider()
            ForEach(Array(RemoteDisplaySettings.fixedSizes.enumerated()), id: \.offset) { _, size in
              Text(verbatim: "\(size.0) × \(size.1)").tag(ResolutionChoice.fixed(size.0, size.1))
            }
            if case .fixed(let width, let height) = device.display.resolution,
               !RemoteDisplaySettings.fixedSizes.contains(where: { $0 == (width, height) }) {
              Text(verbatim: "\(width) × \(height)").tag(ResolutionChoice.fixed(width, height))
            }
          }
          Toggle("Use full Retina resolution", isOn: $device.display.retina)
          Toggle("Start in full screen", isOn: $device.display.startFullScreen)
        }

        Section("Devices and Audio") {
          Toggle("Play sound on this Mac", isOn: $device.redirection.audio)
          Toggle("Share the clipboard (text)", isOn: $device.redirection.clipboard)
          Picker("Shared folder", selection: folderBinding) {
            Text("None").tag(FolderChoice.none)
            Text("Home folder").tag(FolderChoice.home)
            if case .custom(let path) = device.redirection.folder {
              Text(verbatim: URL(fileURLWithPath: path).lastPathComponent).tag(FolderChoice.custom(path))
            }
            Divider()
            Text("Choose…").tag(FolderChoice.choose)
          }
          Toggle("Connect to the admin session", isOn: $device.adminMode)
        }
      }
      .formStyle(.grouped)

      Divider()
      HStack {
        Spacer()
        Button("Cancel") { completion(nil) }
          .keyboardShortcut(.cancelAction)
        Button(isNew ? "Add" : "Save") {
          device.address = device.address.trimmingCharacters(in: .whitespacesAndNewlines)
          device.gateway.address = device.gateway.address.trimmingCharacters(in: .whitespacesAndNewlines)
          completion(device)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!isValid)
      }
      .padding(16)
    }
    .frame(width: 520, height: 640)
    .sheet(item: $addingAccountFor) { target in
      RemoteAccountEditor(account: RemoteAccount(username: ""), isNew: true) { account, password in
        if let account {
          store.upsert(account, password: password)
          switch target {
          case .pc: device.accountID = account.id
          case .gateway: device.gateway.accountID = account.id
          }
        }
        addingAccountFor = nil
      }
    }
    .alert("New Group", isPresented: $addingGroup) {
      TextField("Name", text: $newGroupName)
      Button("Add") {
        let name = newGroupName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { device.groupID = store.addGroup(named: name).id }
        newGroupName = ""
      }
      Button("Cancel", role: .cancel) { newGroupName = "" }
    }
  }

  // MARK: Picker bindings

  private enum AccountChoice: Hashable { case none, account(UUID), add }
  private enum GroupChoice: Hashable { case none, group(UUID), add }
  private enum ResolutionChoice: Hashable { case matchWindow, fixed(Int, Int) }
  private enum FolderChoice: Hashable { case none, home, custom(String), choose }

  private func accountBinding(_ keyPath: WritableKeyPath<RemoteDevice, UUID?>, target: AccountTarget) -> Binding<AccountChoice> {
    Binding {
      device[keyPath: keyPath].map { .account($0) } ?? .none
    } set: { choice in
      switch choice {
      case .none: device[keyPath: keyPath] = nil
      case .account(let id): device[keyPath: keyPath] = id
      case .add: addingAccountFor = target
      }
    }
  }

  private var groupBinding: Binding<GroupChoice> {
    Binding {
      device.groupID.map { .group($0) } ?? .none
    } set: { choice in
      switch choice {
      case .none: device.groupID = nil
      case .group(let id): device.groupID = id
      case .add: addingGroup = true
      }
    }
  }

  private var resolutionBinding: Binding<ResolutionChoice> {
    Binding {
      switch device.display.resolution {
      case .matchWindow: .matchWindow
      case .fixed(let width, let height): .fixed(width, height)
      }
    } set: { choice in
      switch choice {
      case .matchWindow: device.display.resolution = .matchWindow
      case .fixed(let width, let height): device.display.resolution = .fixed(width: width, height: height)
      }
    }
  }

  private var folderBinding: Binding<FolderChoice> {
    Binding {
      switch device.redirection.folder {
      case .none: .none
      case .home: .home
      case .custom(let path): .custom(path)
      }
    } set: { choice in
      switch choice {
      case .none: device.redirection.folder = .none
      case .home: device.redirection.folder = .home
      case .custom(let path): device.redirection.folder = .custom(path: path)
      case .choose:
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = String(localized: "Choose a folder the PC can open as a drive.")
        if panel.runModal() == .OK, let url = panel.url {
          device.redirection.folder = .custom(path: url.path)
        }
      }
    }
  }
}

/// Adds or edits a user account; the password goes to the keychain.
struct RemoteAccountEditor: View {
  @State private var account: RemoteAccount
  @State private var password = ""
  let isNew: Bool
  /// (account, new password or nil to keep the stored one); a nil account means cancelled.
  let completion: (RemoteAccount?, String?) -> Void

  init(account: RemoteAccount, isNew: Bool, completion: @escaping (RemoteAccount?, String?) -> Void) {
    _account = State(initialValue: account)
    self.isNew = isNew
    self.completion = completion
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(isNew ? "Add User Account" : "Edit User Account").font(.headline)
      Form {
        TextField("User name", text: $account.username, prompt: Text(verbatim: "DOMAIN\\user"))
        SecureField("Password", text: $password, prompt: Text(isNew ? "Ask when required" : "Unchanged"))
        TextField("Friendly name", text: $account.friendlyName, prompt: Text("Optional"))
      }
      .formStyle(.columns)
      Text("Passwords are kept in your login keychain.")
        .font(.callout)
        .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancel") { completion(nil, nil) }
          .keyboardShortcut(.cancelAction)
        Button(isNew ? "Add" : "Save") {
          account.username = account.username.trimmingCharacters(in: .whitespaces)
          completion(account, password.isEmpty ? nil : password)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(account.username.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 420)
  }
}

/// The user accounts saved PCs sign in with.
struct RemoteAccountsSheet: View {
  let store: RemoteStore
  let done: () -> Void
  @State private var editing: RemoteAccount?
  @State private var editingIsNew = false
  @State private var deleting: RemoteAccount?

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("User Accounts").font(.headline)
        Spacer()
        Button {
          editingIsNew = true
          editing = RemoteAccount(username: "")
        } label: {
          Label("Add", systemImage: "plus")
        }
      }
      .padding(16)
      Divider()
      if store.accounts.isEmpty {
        ContentUnavailableView("No User Accounts", systemImage: "person.crop.circle",
                               description: Text("Accounts you add or save while signing in appear here."))
          .frame(maxHeight: .infinity)
      } else {
        List {
          ForEach(store.accounts) { account in
            HStack {
              Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
              VStack(alignment: .leading) {
                Text(account.displayName)
                let count = store.usageCount(of: account.id)
                Text(account.friendlyName.isEmpty
                     ? String(localized: "Used by \(count) PCs")
                     : "\(account.username) · " + String(localized: "Used by \(count) PCs"))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Button("Edit…") {
                editingIsNew = false
                editing = account
              }
              Button(role: .destructive) { deleting = account } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 2)
          }
        }
      }
      Divider()
      HStack {
        Spacer()
        Button("Done", action: done).keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(width: 520, height: 420)
    .sheet(item: $editing) { account in
      RemoteAccountEditor(account: account, isNew: editingIsNew) { updated, password in
        if let updated { store.upsert(updated, password: password) }
        editing = nil
      }
    }
    .confirmationDialog(
      String(localized: "Delete “\(deleting?.displayName ?? "")”?"),
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    ) {
      Button("Delete", role: .destructive) {
        if let account = deleting { store.deleteAccount(account.id) }
        deleting = nil
      }
    } message: {
      Text("PCs that use it will ask for a user name and password. Its password is removed from the keychain.")
    }
  }
}
