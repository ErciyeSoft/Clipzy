import AppKit
import KitziCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The state of one open rule editor: a draft that only reaches the store on Save.
@Observable
final class RuleEditorModel {
  var draft: FolderRule
  let isNew: Bool
  let folderID: UUID
  var preview: [PreviewItem]?
  var isPreviewing = false

  @ObservationIgnored let store: RulesStore
  @ObservationIgnored var close: () -> Void = {}

  init(store: RulesStore, folderID: UUID, rule: FolderRule, isNew: Bool) {
    self.store = store
    self.folderID = folderID
    draft = rule
    self.isNew = isNew
  }

  var folder: WatchedFolder? { store.folder(folderID) }

  func save() {
    var rule = draft
    rule.name = rule.name.trimmingCharacters(in: .whitespaces)
    // The switch in the rule list may have changed while the editor was open.
    if let current = folder?.rules.first(where: { $0.id == rule.id }) { rule.isEnabled = current.isEnabled }
    store.saveRule(rule, in: folderID)
    close()
  }

  func runPreview() {
    isPreviewing = true
    let draft = draft
    Task {
      preview = await store.preview(draft, in: folderID)
      isPreviewing = false
    }
  }

  func addCondition(after id: UUID?) {
    let index = id.flatMap { id in draft.conditions.firstIndex { $0.id == id } }.map { $0 + 1 } ?? draft.conditions.count
    draft.conditions.insert(RuleCondition(), at: index)
  }

  func removeCondition(_ id: UUID) {
    draft.conditions.removeAll { $0.id == id }
  }

  func addAction(after id: UUID?) {
    let index = id.flatMap { id in draft.actions.firstIndex { $0.id == id } }.map { $0 + 1 } ?? draft.actions.count
    draft.actions.insert(RuleAction(), at: index)
  }

  func removeAction(_ id: UUID) {
    draft.actions.removeAll { $0.id == id }
  }

  func moveAction(_ id: UUID, by offset: Int) {
    guard let index = draft.actions.firstIndex(where: { $0.id == id }),
          draft.actions.indices.contains(index + offset) else { return }
    draft.actions.swapAt(index, index + offset)
  }
}

/// A standalone window per rule, like Hazel's detachable editor.
final class RuleEditorWindow: NSObject, NSWindowDelegate {
  private static var openWindows: [UUID: RuleEditorWindow] = [:]
  private let ruleID: UUID
  private var window: NSWindow?

  private init(ruleID: UUID) {
    self.ruleID = ruleID
  }

  static func show(store: RulesStore, folderID: UUID, rule: FolderRule, isNew: Bool) {
    if let existing = openWindows[rule.id], let window = existing.window {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let controller = RuleEditorWindow(ruleID: rule.id)
    let model = RuleEditorModel(store: store, folderID: folderID, rule: rule, isNew: isNew)
    model.close = { [weak controller] in controller?.window?.close() }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.title = isNew ? String(localized: "New Rule") : String(localized: "Edit Rule")
    if let folder = store.folder(folderID) { window.subtitle = folder.name }
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(rootView: RuleEditorView(model: model))
    window.delegate = controller
    window.center()
    controller.window = window
    openWindows[rule.id] = controller
    KitziWindows.didOpen()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) {
    window?.contentViewController = nil
    window = nil
    KitziWindows.didClose()
    Self.openWindows[ruleID] = nil
  }
}

// MARK: - Editor

private struct RuleEditorView: View {
  @Bindable var model: RuleEditorModel

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          HStack {
            Text("Name:")
            TextField("Rule name", text: $model.draft.name)
              .textFieldStyle(.roundedBorder)
          }
          conditions
          actions
        }
        .padding(18)
      }
      if let items = model.preview {
        Divider()
        PreviewPanel(items: items) { model.preview = nil }
          .frame(height: 200)
      }
      Divider()
      footer
    }
    .frame(minWidth: 720, minHeight: 540)
  }

  private var conditions: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker("", selection: $model.draft.matchAll) {
        Text("If all of the following conditions are met").tag(true)
        Text("If any of the following conditions are met").tag(false)
      }
      .labelsHidden()
      .fixedSize()
      VStack(spacing: 6) {
        ForEach($model.draft.conditions) { $condition in
          ConditionRow(
            condition: $condition,
            canRemove: model.draft.conditions.count > 1,
            add: { model.addCondition(after: condition.id) },
            remove: { model.removeCondition(condition.id) }
          )
        }
        if model.draft.conditions.isEmpty {
          Button("Add Condition") { model.addCondition(after: nil) }
        }
      }
      .padding(10)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
  }

  private var actions: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Do the following:")
      VStack(spacing: 8) {
        ForEach($model.draft.actions) { $action in
          let isFirst = model.draft.actions.first?.id == action.id
          let isLast = model.draft.actions.last?.id == action.id
          ActionRow(
            action: $action,
            canMoveUp: !isFirst,
            canMoveDown: !isLast,
            canRemove: model.draft.actions.count > 1,
            add: { model.addAction(after: action.id) },
            remove: { model.removeAction(action.id) },
            move: { model.moveAction(action.id, by: $0) }
          )
          if !isLast {
            Divider()
          }
        }
        if model.draft.actions.isEmpty {
          Button("Add Action") { model.addAction(after: nil) }
        }
      }
      .padding(10)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Button {
        model.runPreview()
      } label: {
        Label("Preview", systemImage: "eye")
      }
      .help("Show which files in the folder match this rule right now. Nothing is changed.")
      .disabled(model.isPreviewing || model.draft.conditions.isEmpty)
      if model.isPreviewing {
        ProgressView().controlSize(.small)
      }
      if let problem = model.draft.problems.first {
        Text(verbatim: problem)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      Button("Cancel") { model.close() }
        .keyboardShortcut(.cancelAction)
      Button {
        model.save()
      } label: {
        if model.isNew { Text("Add Rule") } else { Text("Save") }
      }
      .keyboardShortcut(.defaultAction)
      .disabled(!model.draft.problems.isEmpty)
    }
    .padding(12)
  }
}

// MARK: - Conditions

private struct ConditionRow: View {
  @Binding var condition: RuleCondition
  let canRemove: Bool
  let add: () -> Void
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Picker("", selection: Binding(get: { condition.attribute }, set: { condition.setAttribute($0) })) {
        ForEach(ConditionAttribute.allCases) { attribute in
          Text(attribute.title).tag(attribute)
        }
      }
      .labelsHidden()
      .frame(width: 150)
      if !condition.attribute.operators.isEmpty {
        Picker("", selection: $condition.op) {
          ForEach(condition.attribute.operators) { op in
            Text(op.title).tag(op)
          }
        }
        .labelsHidden()
        .frame(width: 150)
      }
      value
      Spacer(minLength: 0)
      RowButtons(canRemove: canRemove, add: add, remove: remove)
    }
  }

  @ViewBuilder private var value: some View {
    switch condition.attribute.valueType {
    case .none:
      EmptyView()
    case .text:
      TextField(placeholder, text: $condition.text)
        .textFieldStyle(.roundedBorder)
      if condition.hasInvalidRegex {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .help("This regular expression isn't valid.")
      }
    case .kind:
      Picker("", selection: $condition.kind) {
        ForEach(FileKindValue.allCases) { kind in
          Text(kind.title).tag(kind)
        }
      }
      .labelsHidden()
      .frame(width: 150)
    case .date:
      if condition.op != .isToday {
        NumberField(value: $condition.number)
        Picker("", selection: $condition.dateUnit) {
          ForEach(DateUnit.allCases) { unit in
            Text(unit.title).tag(unit)
          }
        }
        .labelsHidden()
        .frame(width: 100)
      }
    case .size:
      NumberField(value: $condition.number)
      Picker("", selection: $condition.sizeUnit) {
        ForEach(SizeUnit.allCases) { unit in
          Text(verbatim: unit.title).tag(unit)
        }
      }
      .labelsHidden()
      .frame(width: 70)
    case .tags:
      if condition.op != .hasNoTags {
        TextField(String(localized: "Tag name"), text: $condition.text)
          .textFieldStyle(.roundedBorder)
      }
    }
  }

  private var placeholder: String {
    if condition.attribute == .fileExtension, condition.op == .equals || condition.op == .notEquals {
      return String(localized: "pdf, or jpg, png")
    }
    if condition.op == .matchesRegex { return String(localized: "Regular expression") }
    return String(localized: "Text")
  }
}

private struct NumberField: View {
  @Binding var value: Int

  var body: some View {
    TextField("", value: $value, format: .number)
      .textFieldStyle(.roundedBorder)
      .multilineTextAlignment(.trailing)
      .frame(width: 64)
  }
}

private struct RowButtons: View {
  let canRemove: Bool
  let add: () -> Void
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 2) {
      Button(action: remove) {
        Image(systemName: "minus.circle")
      }
      .disabled(!canRemove)
      .help("Remove")
      Button(action: add) {
        Image(systemName: "plus.circle")
      }
      .help("Add")
    }
    .buttonStyle(.borderless)
  }
}

// MARK: - Actions

private struct ActionRow: View {
  @Binding var action: RuleAction
  let canMoveUp: Bool
  let canMoveDown: Bool
  let canRemove: Bool
  let add: () -> Void
  let remove: () -> Void
  let move: (Int) -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Picker("", selection: Binding(get: { action.kind }, set: { action.setKind($0) })) {
        ForEach(Array(ActionKind.menuGroups.enumerated()), id: \.offset) { index, group in
          if index > 0 { Divider() }
          ForEach(group) { kind in
            Text(kind.title).tag(kind)
          }
        }
      }
      .labelsHidden()
      .frame(width: 210)
      parameters
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 2) {
        Button { move(-1) } label: { Image(systemName: "chevron.up") }
          .disabled(!canMoveUp)
          .help("Move Up")
        Button { move(1) } label: { Image(systemName: "chevron.down") }
          .disabled(!canMoveDown)
          .help("Move Down")
        RowButtons(canRemove: canRemove, add: add, remove: remove)
      }
      .buttonStyle(.borderless)
    }
  }

  @ViewBuilder private var parameters: some View {
    switch action.kind {
    case .moveToFolder:
      FolderChooser(path: $action.folderPath, emptyTitle: String(localized: "No folder chosen"))
    case .copyToFolder:
      VStack(alignment: .leading, spacing: 4) {
        FolderChooser(path: $action.folderPath, emptyTitle: String(localized: "No folder chosen"))
        Text("The next actions work on the original.").captionStyle()
      }
    case .rename:
      VStack(alignment: .leading, spacing: 4) {
        PatternField(pattern: $action.pattern, placeholder: "{added:yyyy-MM-dd} {name}")
        Text("The extension stays unless the pattern uses {ext}.").captionStyle()
      }
    case .sortIntoSubfolders:
      VStack(alignment: .leading, spacing: 6) {
        PatternField(pattern: $action.pattern, placeholder: "{year}/{month}")
        HStack(spacing: 6) {
          Text("Inside:").foregroundStyle(.secondary)
          FolderChooser(path: $action.folderPath, emptyTitle: String(localized: "The watched folder"), allowsClear: true)
        }
      }
    case .addTags:
      TextField(String(localized: "Tags, separated by commas"), text: $action.tags)
        .textFieldStyle(.roundedBorder)
    case .removeTags:
      HStack {
        TextField(String(localized: "Tags, separated by commas"), text: $action.tags)
          .textFieldStyle(.roundedBorder)
          .disabled(action.allTags)
        Toggle("All tags", isOn: $action.allTags)
      }
    case .openWith:
      AppChooser(path: $action.appPath)
    case .runScript:
      VStack(alignment: .leading, spacing: 4) {
        TextEditor(text: $action.script)
          .font(.system(.body, design: .monospaced))
          .frame(height: 84)
          .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
        HStack {
          Text("Runs with zsh; the file's path is in $1.").captionStyle()
          Spacer()
          Stepper(value: $action.timeout, in: 5...600, step: 5) {
            Text("Time limit: \(action.timeout) s")
              .monospacedDigit()
          }
        }
      }
    case .notify:
      PatternField(pattern: $action.pattern, placeholder: "{fullname}")
    case .compress:
      VStack(alignment: .leading, spacing: 4) {
        Toggle("Then move the original to the Trash", isOn: $action.trashOriginal)
        Text("The next actions work on the ZIP file.").captionStyle()
      }
    case .extract:
      VStack(alignment: .leading, spacing: 4) {
        Toggle("Then move the archive to the Trash", isOn: $action.trashOriginal)
        Text("ZIP and tar archives. The next actions work on what comes out.").captionStyle()
      }
    case .trash:
      Text("You can put files back from the Trash.").captionStyle()
    case .continueMatching:
      Text("The rules below this one also get a chance at the file.").captionStyle()
    case .ignore:
      Text("Keeps matching files away from the rules below.").captionStyle()
    case .open, .revealInFinder:
      EmptyView()
    }
  }
}

private extension Text {
  func captionStyle() -> some View {
    font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

private struct PatternField: View {
  @Binding var pattern: String
  let placeholder: String
  @State private var showsHelp = false

  var body: some View {
    HStack(spacing: 4) {
      TextField(placeholder, text: $pattern)
        .textFieldStyle(.roundedBorder)
        .font(.system(.body, design: .monospaced))
      Button {
        showsHelp.toggle()
      } label: {
        Image(systemName: "questionmark.circle")
      }
      .buttonStyle(.borderless)
      .help("Pattern tokens")
      .popover(isPresented: $showsHelp, arrowEdge: .bottom) {
        TokenHelp()
      }
    }
  }
}

private struct TokenHelp: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Pattern tokens")
        .font(.headline)
      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
        ForEach(PatternExpander.tokenHelp) { item in
          GridRow {
            Text(verbatim: item.token)
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
            Text(verbatim: item.meaning)
              .foregroundStyle(.secondary)
          }
        }
      }
      Text("Dates use letters like yyyy, MM, dd, HH and mm. In Sort into subfolders, / makes nested folders. On a name clash, Kitzi adds 2, 3… like Finder.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .frame(width: 440)
  }
}

private struct FolderChooser: View {
  @Binding var path: String
  let emptyTitle: String
  var allowsClear = false

  var body: some View {
    HStack(spacing: 6) {
      if path.isEmpty {
        Text(verbatim: emptyTitle)
          .foregroundStyle(.secondary)
      } else {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
          .resizable()
          .frame(width: 16, height: 16)
        Text(verbatim: FileManager.default.displayName(atPath: path))
          .lineLimit(1)
          .truncationMode(.middle)
          .help(path)
      }
      Button("Choose…", action: choose)
      if allowsClear, !path.isEmpty {
        Button {
          path = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .help("Use the watched folder")
      }
    }
  }

  private func choose() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true) }
    if panel.runModal() == .OK, let url = panel.url {
      path = url.path
    }
  }
}

private struct AppChooser: View {
  @Binding var path: String

  var body: some View {
    HStack(spacing: 6) {
      if path.isEmpty {
        Text("No app chosen")
          .foregroundStyle(.secondary)
      } else {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
          .resizable()
          .frame(width: 16, height: 16)
        Text(verbatim: ActionPlanner.displayName(path))
          .lineLimit(1)
          .help(path)
      }
      Button("Choose App…", action: choose)
    }
  }

  private func choose() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    if panel.runModal() == .OK, let url = panel.url {
      path = url.path
    }
  }
}

// MARK: - Preview

private struct PreviewPanel: View {
  let items: [PreviewItem]
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text("Matching files: \(items.count)")
          .font(.headline)
        Text("Preview doesn't change anything.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button(action: close) {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .help("Close Preview")
      }
      if items.isEmpty {
        Text("No files in the folder match this rule right now.")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(items) { item in
          PreviewRow(item: item)
        }
        .listStyle(.inset)
      }
    }
    .padding(.horizontal, 14)
    .padding(.top, 10)
  }
}

private struct PreviewRow: View {
  let item: PreviewItem

  var body: some View {
    HStack(spacing: 8) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
        .resizable()
        .frame(width: 18, height: 18)
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: item.name)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(verbatim: item.steps.joined(separator: " → "))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer()
      status
        .font(.caption)
    }
    .help(item.path)
  }

  @ViewBuilder private var status: some View {
    switch item.status {
    case .willRun:
      Text("Will run").foregroundStyle(.green)
    case .alreadyHandled:
      Text("Already handled").foregroundStyle(.secondary)
    case let .earlierRule(name):
      Text("“\(name)” comes first").foregroundStyle(.orange)
    }
  }
}
