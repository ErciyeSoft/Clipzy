import AppKit
import SwiftUI

/// The Folder Rules settings page: watched folders, the selected folder's rules,
/// App Sweep and the activity log.
struct RulesSettingsView: View {
  let store: RulesStore

  @AppStorage(RulesPrefs.appSweepKey) private var appSweep = true
  @State private var folderToRemove: WatchedFolder?
  @State private var ruleToDelete: FolderRule?

  var body: some View {
    Form {
      if let problem = store.loadProblem {
        Section {
          Label {
            Text(verbatim: problem)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          }
        }
      }
      foldersSection
      if let folder = store.selectedFolder {
        rulesSection(folder)
      }
      appSweepSection
      activitySection
    }
    .formStyle(.grouped)
    .alert(
      Text("Remove “\(folderToRemove?.name ?? "")”?"),
      isPresented: Binding(get: { folderToRemove != nil }, set: { if !$0 { folderToRemove = nil } }),
      presenting: folderToRemove
    ) { folder in
      Button("Remove", role: .destructive) { store.removeFolder(folder.id) }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("Its rules are deleted too. Files in the folder stay as they are.")
    }
    .alert(
      Text("Delete the rule “\(ruleToDelete?.name ?? "")”?"),
      isPresented: Binding(get: { ruleToDelete != nil }, set: { if !$0 { ruleToDelete = nil } }),
      presenting: ruleToDelete
    ) { rule in
      Button("Delete", role: .destructive) {
        if let folder = store.selectedFolder { store.deleteRule(rule.id, in: folder.id) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("Files it already handled stay as they are.")
    }
  }

  // MARK: Folders

  private var foldersSection: some View {
    Section {
      if store.folders.isEmpty {
        Text("No folders yet. Add a folder like Downloads or Desktop, then give it rules.")
          .foregroundStyle(.secondary)
      }
      ForEach(store.folders) { folder in
        FolderRow(
          folder: folder,
          isSelected: folder.id == store.selectedFolder?.id,
          isEnabled: Binding(get: { folder.isEnabled }, set: { store.setFolderEnabled(folder.id, $0) }),
          select: { store.selectedFolderID = folder.id },
          runNow: { store.runNow(folder.id) },
          remove: { folderToRemove = folder }
        )
      }
      HStack {
        Button("Add Folder…", action: addFolder)
        Spacer()
      }
    } header: {
      Text("Watched folders")
    } footer: {
      Text("Kitzi watches these folders and runs their rules on new and changed files. Nothing happens until a folder has a rule.")
        .foregroundStyle(.secondary)
    }
  }

  private func addFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = String(localized: "Watch Folder")
    panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    if panel.runModal() == .OK, let url = panel.url {
      store.addFolder(url)
    }
  }

  // MARK: Rules

  private func rulesSection(_ folder: WatchedFolder) -> some View {
    Section {
      Toggle("Include subfolders", isOn: Binding(
        get: { folder.includeSubfolders },
        set: { store.setIncludeSubfolders(folder.id, $0) }
      ))
      if folder.rules.isEmpty {
        Text("No rules yet. Add one to tell Kitzi what to do with files in this folder.")
          .foregroundStyle(.secondary)
      }
      ForEach(Array(folder.rules.enumerated()), id: \.element.id) { index, rule in
        RuleRow(
          rule: rule,
          isEnabled: Binding(get: { rule.isEnabled }, set: { store.setRuleEnabled(rule.id, in: folder.id, $0) }),
          canMoveUp: index > 0,
          canMoveDown: index < folder.rules.count - 1,
          edit: { RuleEditorWindow.show(store: store, folderID: folder.id, rule: rule, isNew: false) },
          duplicate: { store.duplicateRule(rule.id, in: folder.id) },
          move: { store.moveRule(rule.id, in: folder.id, by: $0) },
          forget: { store.forgetHandledFiles(rule.id, in: folder.id) },
          delete: { ruleToDelete = rule }
        )
      }
      HStack {
        Button("Add Rule…") {
          RuleEditorWindow.show(store: store, folderID: folder.id,
                                rule: FolderRule(name: String(localized: "New Rule")), isNew: true)
        }
        Spacer()
        Button("Run Now") { store.runNow(folder.id) }
          .disabled(!folder.isActive)
          .help("Check the folder now. Rules skip files they already handled unless the file changed.")
      }
    } header: {
      Text("Rules for “\(folder.name)”")
    } footer: {
      Text("Rules run from top to bottom. The first rule that matches a file wins, unless it continues matching. A rule doesn't run again on a file that hasn't changed.")
        .foregroundStyle(.secondary)
    }
  }

  // MARK: App Sweep

  private var appSweepSection: some View {
    Section {
      Toggle("Offer to clean up after you delete an app", isOn: $appSweep)
    } header: {
      Text("App Sweep")
    } footer: {
      Text("When an app disappears from Applications, Kitzi looks for the files it left in your Library and lists them. Nothing goes to the Trash unless you choose it.")
        .foregroundStyle(.secondary)
    }
  }

  // MARK: Activity

  private var activitySection: some View {
    Section {
      if store.activity.isEmpty {
        Text("Nothing has happened yet.")
          .foregroundStyle(.secondary)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(store.activity) { entry in
              ActivityRow(entry: entry)
            }
          }
          .padding(.vertical, 4)
        }
        .frame(height: 220)
      }
    } header: {
      HStack {
        Text("Activity")
        Spacer()
        if !store.activity.isEmpty {
          Button("Clear") { store.clearActivity() }
            .buttonStyle(.link)
            .font(.callout)
        }
      }
    }
  }
}

// MARK: - Rows

private struct FolderRow: View {
  let folder: WatchedFolder
  let isSelected: Bool
  @Binding var isEnabled: Bool
  let select: () -> Void
  let runNow: () -> Void
  let remove: () -> Void

  var body: some View {
    let exists = FileOps.isDirectory(folder.url)
    HStack(spacing: 10) {
      Toggle("", isOn: $isEnabled)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
      Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
        .resizable()
        .frame(width: 20, height: 20)
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: folder.name)
          .lineLimit(1)
        Text(verbatim: (folder.path as NSString).abbreviatingWithTildeInPath)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      if !exists {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .help("This folder can't be found.")
      }
      Text("Rules: \(folder.rules.count)")
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
      Menu {
        Button("Run Now", action: runNow)
          .disabled(!folder.isActive)
        Button("Show in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([folder.url])
        }
        Divider()
        Button("Remove Folder…", role: .destructive, action: remove)
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
    .padding(.vertical, 3)
    .padding(.horizontal, 6)
    .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    .contentShape(Rectangle())
    .onTapGesture(perform: select)
  }
}

private struct RuleRow: View {
  let rule: FolderRule
  @Binding var isEnabled: Bool
  let canMoveUp: Bool
  let canMoveDown: Bool
  let edit: () -> Void
  let duplicate: () -> Void
  let move: (Int) -> Void
  let forget: () -> Void
  let delete: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Toggle("", isOn: $isEnabled)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: rule.name)
          .lineLimit(1)
        Text(verbatim: rule.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer()
      if !rule.problems.isEmpty {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .help("This rule is incomplete and won't run.")
      }
      Button(action: edit) {
        Image(systemName: "pencil")
      }
      .buttonStyle(.borderless)
      .help("Edit Rule")
      Menu {
        Button("Edit…", action: edit)
        Button("Duplicate", action: duplicate)
        Divider()
        Button("Move Up") { move(-1) }
          .disabled(!canMoveUp)
        Button("Move Down") { move(1) }
          .disabled(!canMoveDown)
        Divider()
        Button("Forget Handled Files", action: forget)
          .help("Let the rule run again on files it already handled.")
        Divider()
        Button("Delete Rule…", role: .destructive, action: delete)
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
    .contentShape(Rectangle())
    .onTapGesture(count: 2, perform: edit)
  }
}

private struct ActivityRow: View {
  let entry: ActivityEntry

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: entry.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(entry.error == nil ? Color.green : Color.orange)
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: entry.fileName)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(verbatim: "\(entry.ruleName) › \(entry.summary)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if let error = entry.error {
          Text(verbatim: error)
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(3)
        }
      }
      Spacer()
      Text(entry.date, format: .dateTime.day().month(.abbreviated).hour().minute())
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .contentShape(Rectangle())
    .contextMenu {
      Button("Show in Finder") {
        let url = URL(fileURLWithPath: entry.path)
        if FileOps.exists(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      }
      .disabled(!FileOps.exists(URL(fileURLWithPath: entry.path)))
    }
  }
}
