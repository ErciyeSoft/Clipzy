import Foundation

// MARK: - Folders and rules

/// A folder Kitzi watches, with the rules that run on its files from top to bottom.
nonisolated struct WatchedFolder: Codable, Identifiable, Hashable, Sendable {
  var id = UUID()
  var path: String
  var isEnabled = true
  var includeSubfolders = false
  var rules: [FolderRule] = []

  init(path: String) {
    self.path = path
  }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = c.value(.id, default: UUID())
    path = try c.decode(String.self, forKey: .path)
    isEnabled = c.value(.isEnabled, default: true)
    includeSubfolders = c.value(.includeSubfolders, default: false)
    rules = try c.decodeIfPresent([FolderRule].self, forKey: .rules) ?? []
  }

  var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
  var name: String { FileManager.default.displayName(atPath: path) }
  /// Whether anything can run here at all.
  var isActive: Bool { isEnabled && rules.contains(where: \.isRunnable) }
}

/// One rule: if all/any of the conditions match, run the actions in order.
nonisolated struct FolderRule: Codable, Identifiable, Hashable, Sendable {
  var id = UUID()
  var name: String
  var isEnabled = true
  var matchAll = true
  var conditions: [RuleCondition]
  var actions: [RuleAction]

  init(name: String, conditions: [RuleCondition] = [RuleCondition()], actions: [RuleAction] = [RuleAction()]) {
    self.name = name
    self.conditions = conditions
    self.actions = actions
  }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = c.value(.id, default: UUID())
    name = c.value(.name, default: "")
    isEnabled = c.value(.isEnabled, default: true)
    matchAll = c.value(.matchAll, default: true)
    conditions = try c.decodeIfPresent([RuleCondition].self, forKey: .conditions) ?? []
    actions = try c.decodeIfPresent([RuleAction].self, forKey: .actions) ?? []
  }

  var continuesMatching: Bool { actions.contains { $0.kind == .continueMatching } }
  /// Enabled and complete; incomplete rules never run.
  var isRunnable: Bool { isEnabled && problems.isEmpty }

  /// What is missing before the rule can be saved or run.
  var problems: [String] {
    var result: [String] = []
    if name.trimmingCharacters(in: .whitespaces).isEmpty { result.append(String(localized: "Give the rule a name.")) }
    if conditions.isEmpty { result.append(String(localized: "Add at least one condition.")) }
    if actions.isEmpty { result.append(String(localized: "Add at least one action.")) }
    if conditions.contains(where: \.isIncomplete) { result.append(String(localized: "Fill in every condition.")) }
    if conditions.contains(where: \.hasInvalidRegex) { result.append(String(localized: "One of the regular expressions isn't valid.")) }
    result += actions.compactMap(\.problem)
    var seen = Set<String>()
    return result.filter { seen.insert($0).inserted }
  }

  /// One line for the rule list, like "Extension is pdf → Move to folder".
  var summary: String {
    guard let first = conditions.first else { return actions.map(\.kind.title).joined(separator: ", ") }
    var text = first.summary
    if conditions.count > 1 { text = String(localized: "\(text) and \(conditions.count - 1) more") }
    return "\(text) → \(actions.map(\.kind.title).joined(separator: ", "))"
  }
}

// MARK: - Conditions

/// The file attribute a condition looks at.
nonisolated enum ConditionAttribute: String, Codable, CaseIterable, Identifiable, Sendable {
  case anyFile, name, fullName, fileExtension = "extension", kind
  case dateAdded, dateModified, dateCreated, dateLastOpened
  case size, tags, sourceURL

  var id: String { rawValue }

  enum ValueType { case none, text, kind, date, size, tags }

  var valueType: ValueType {
    switch self {
    case .anyFile: .none
    case .name, .fullName, .fileExtension, .sourceURL: .text
    case .kind: .kind
    case .dateAdded, .dateModified, .dateCreated, .dateLastOpened: .date
    case .size: .size
    case .tags: .tags
    }
  }

  var operators: [ConditionOperator] {
    switch valueType {
    case .none: []
    case .text: [.equals, .notEquals, .contains, .doesNotContain, .startsWith, .endsWith, .matchesRegex]
    case .kind: [.equals, .notEquals]
    case .date: [.inLast, .notInLast, .isToday]
    case .size: [.greaterThan, .lessThan]
    case .tags: [.hasTag, .lacksTag, .hasNoTags]
    }
  }

  var title: String {
    switch self {
    case .anyFile: String(localized: "Any file")
    case .name: String(localized: "Name")
    case .fullName: String(localized: "Full name")
    case .fileExtension: String(localized: "Extension")
    case .kind: String(localized: "Kind")
    case .dateAdded: String(localized: "Date added")
    case .dateModified: String(localized: "Date modified")
    case .dateCreated: String(localized: "Date created")
    case .dateLastOpened: String(localized: "Date last opened")
    case .size: String(localized: "Size")
    case .tags: String(localized: "Tags")
    case .sourceURL: String(localized: "Source URL")
    }
  }
}

nonisolated enum ConditionOperator: String, Codable, CaseIterable, Identifiable, Sendable {
  case equals = "is", notEquals = "isNot", contains, doesNotContain, startsWith, endsWith, matchesRegex
  case inLast, notInLast, isToday
  case greaterThan, lessThan
  case hasTag, lacksTag, hasNoTags

  var id: String { rawValue }

  var title: String {
    switch self {
    case .equals: String(localized: "is")
    case .notEquals: String(localized: "is not")
    case .contains: String(localized: "contains")
    case .doesNotContain: String(localized: "doesn't contain")
    case .startsWith: String(localized: "starts with")
    case .endsWith: String(localized: "ends with")
    case .matchesRegex: String(localized: "matches regex")
    case .inLast: String(localized: "is in the last")
    case .notInLast: String(localized: "is not in the last")
    case .isToday: String(localized: "is today")
    case .greaterThan: String(localized: "is greater than")
    case .lessThan: String(localized: "is less than")
    case .hasTag: String(localized: "include")
    case .lacksTag: String(localized: "don't include")
    case .hasNoTags: String(localized: "are empty")
    }
  }
}

nonisolated enum DateUnit: String, Codable, CaseIterable, Identifiable, Sendable {
  case minutes, hours, days, weeks, months

  var id: String { rawValue }

  var title: String {
    switch self {
    case .minutes: String(localized: "minutes")
    case .hours: String(localized: "hours")
    case .days: String(localized: "days")
    case .weeks: String(localized: "weeks")
    case .months: String(localized: "months")
    }
  }

  /// `now` minus `amount` of this unit.
  func date(goingBack amount: Int, from now: Date) -> Date {
    let calendar = Calendar.current
    let component: Calendar.Component
    var value = amount
    switch self {
    case .minutes: component = .minute
    case .hours: component = .hour
    case .days: component = .day
    case .weeks: component = .day; value *= 7
    case .months: component = .month
    }
    return calendar.date(byAdding: component, value: -value, to: now) ?? now
  }
}

nonisolated enum SizeUnit: String, Codable, CaseIterable, Identifiable, Sendable {
  case kilobytes, megabytes, gigabytes

  var id: String { rawValue }
  var title: String {
    switch self {
    case .kilobytes: "KB"
    case .megabytes: "MB"
    case .gigabytes: "GB"
    }
  }
  /// Decimal units, like Finder.
  var bytes: Int64 {
    switch self {
    case .kilobytes: 1_000
    case .megabytes: 1_000_000
    case .gigabytes: 1_000_000_000
    }
  }
}

/// File kinds a condition can test, worked out from the file's UTType.
nonisolated enum FileKindValue: String, Codable, CaseIterable, Identifiable, Sendable {
  case image, movie, audio, pdf, text, archive, application, diskImage, folder, other

  var id: String { rawValue }

  var title: String {
    switch self {
    case .image: String(localized: "Image")
    case .movie: String(localized: "Movie")
    case .audio: String(localized: "Audio")
    case .pdf: "PDF"
    case .text: String(localized: "Text")
    case .archive: String(localized: "Archive")
    case .application: String(localized: "Application")
    case .diskImage: String(localized: "Disk image")
    case .folder: String(localized: "Folder")
    case .other: String(localized: "Other")
    }
  }

  /// Plural name used by the `{kind}` token, handy for "Sort into subfolders".
  var folderName: String {
    switch self {
    case .image: String(localized: "Images")
    case .movie: String(localized: "Movies")
    case .audio: String(localized: "Audio Files")
    case .pdf: String(localized: "PDFs")
    case .text: String(localized: "Text Files")
    case .archive: String(localized: "Archives")
    case .application: String(localized: "Applications")
    case .diskImage: String(localized: "Disk Images")
    case .folder: String(localized: "Folders")
    case .other: String(localized: "Other")
    }
  }
}

/// One "attribute operator value" row.
nonisolated struct RuleCondition: Codable, Identifiable, Hashable, Sendable {
  var id = UUID()
  var attribute: ConditionAttribute = .fileExtension
  var op: ConditionOperator = .equals
  var text = ""
  var number = 1
  var dateUnit: DateUnit = .days
  var sizeUnit: SizeUnit = .megabytes
  var kind: FileKindValue = .image

  init(attribute: ConditionAttribute = .fileExtension, op: ConditionOperator? = nil, text: String = "") {
    self.attribute = attribute
    self.op = op ?? attribute.operators.first ?? .equals
    self.text = text
  }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = c.value(.id, default: UUID())
    // An unknown attribute falls back to an empty name test, which never matches.
    attribute = c.value(.attribute, default: .name)
    op = c.value(.op, default: .contains)
    text = c.value(.text, default: "")
    number = c.value(.number, default: 1)
    dateUnit = c.value(.dateUnit, default: .days)
    sizeUnit = c.value(.sizeUnit, default: .megabytes)
    kind = c.value(.kind, default: .image)
    if !attribute.operators.isEmpty, !attribute.operators.contains(op) { op = attribute.operators[0] }
  }

  /// Switches the attribute and picks an operator that fits it.
  mutating func setAttribute(_ newValue: ConditionAttribute) {
    guard newValue != attribute else { return }
    let oldType = attribute.valueType
    attribute = newValue
    if !newValue.operators.contains(op) { op = newValue.operators.first ?? .equals }
    if oldType != newValue.valueType { text = "" }
  }

  var needsText: Bool {
    switch attribute.valueType {
    case .text: true
    case .tags: op != .hasNoTags
    default: false
    }
  }

  var isIncomplete: Bool {
    needsText && text.trimmingCharacters(in: .whitespaces).isEmpty
  }

  var hasInvalidRegex: Bool {
    attribute.valueType == .text && op == .matchesRegex && !text.isEmpty
      && (try? NSRegularExpression(pattern: text, options: [.caseInsensitive])) == nil
  }

  var summary: String {
    switch attribute.valueType {
    case .none: return attribute.title
    case .text, .tags:
      return op == .hasNoTags ? "\(attribute.title) \(op.title)" : "\(attribute.title) \(op.title) “\(text)”"
    case .kind: return "\(attribute.title) \(op.title) \(kind.title)"
    case .date:
      return op == .isToday ? "\(attribute.title) \(op.title)" : "\(attribute.title) \(op.title) \(number) \(dateUnit.title)"
    case .size: return "\(attribute.title) \(op.title) \(number) \(sizeUnit.title)"
    }
  }
}

// MARK: - Actions

nonisolated enum ActionKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case moveToFolder, copyToFolder, rename, sortIntoSubfolders
  case addTags, removeTags
  case trash
  case open, openWith, revealInFinder
  case runScript, notify
  case compress, extract
  case continueMatching, ignore

  var id: String { rawValue }

  var title: String {
    switch self {
    case .moveToFolder: String(localized: "Move to folder")
    case .copyToFolder: String(localized: "Copy to folder")
    case .rename: String(localized: "Rename")
    case .sortIntoSubfolders: String(localized: "Sort into subfolders")
    case .addTags: String(localized: "Add tags")
    case .removeTags: String(localized: "Remove tags")
    case .trash: String(localized: "Move to Trash")
    case .open: String(localized: "Open")
    case .openWith: String(localized: "Open with app")
    case .revealInFinder: String(localized: "Show in Finder")
    case .runScript: String(localized: "Run shell script")
    case .notify: String(localized: "Show notification")
    case .compress: String(localized: "Compress to ZIP")
    case .extract: String(localized: "Extract archive")
    case .continueMatching: String(localized: "Continue matching other rules")
    case .ignore: String(localized: "Leave the file alone")
    }
  }

  /// Groups for the action menu, separated by dividers.
  static let menuGroups: [[ActionKind]] = [
    [.moveToFolder, .copyToFolder, .rename, .sortIntoSubfolders],
    [.addTags, .removeTags],
    [.open, .openWith, .revealInFinder, .notify],
    [.compress, .extract, .runScript],
    [.trash],
    [.continueMatching, .ignore],
  ]
}

/// One action row. Only the fields its kind uses matter.
nonisolated struct RuleAction: Codable, Identifiable, Hashable, Sendable {
  var id = UUID()
  var kind: ActionKind = .moveToFolder
  var folderPath = ""
  var pattern = ""
  /// Comma-separated, as typed.
  var tags = ""
  var allTags = false
  var appPath = ""
  var script = ""
  var timeout = 30
  var trashOriginal = false

  init(kind: ActionKind = .moveToFolder) {
    self.kind = kind
    applyDefaults()
  }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = c.value(.id, default: UUID())
    // An unknown action from a newer version does nothing rather than something unexpected.
    kind = c.value(.kind, default: .ignore)
    folderPath = c.value(.folderPath, default: "")
    pattern = c.value(.pattern, default: "")
    tags = c.value(.tags, default: "")
    allTags = c.value(.allTags, default: false)
    appPath = c.value(.appPath, default: "")
    script = c.value(.script, default: "")
    timeout = c.value(.timeout, default: 30)
    trashOriginal = c.value(.trashOriginal, default: false)
  }

  /// Switches the kind and fills in a sensible starting pattern.
  mutating func setKind(_ newValue: ActionKind) {
    guard newValue != kind else { return }
    kind = newValue
    pattern = ""
    applyDefaults()
  }

  private mutating func applyDefaults() {
    guard pattern.isEmpty else { return }
    switch kind {
    case .rename: pattern = "{added:yyyy-MM-dd} {name}"
    case .sortIntoSubfolders: pattern = "{year}/{month}"
    default: break
    }
  }

  var tagList: [String] {
    tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  var problem: String? {
    switch kind {
    case .moveToFolder, .copyToFolder:
      folderPath.isEmpty ? String(localized: "Choose a folder for every move or copy.") : nil
    case .rename, .sortIntoSubfolders:
      pattern.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "Fill in every pattern.") : nil
    case .addTags:
      tagList.isEmpty ? String(localized: "Type at least one tag.") : nil
    case .removeTags:
      !allTags && tagList.isEmpty ? String(localized: "Type at least one tag.") : nil
    case .openWith:
      appPath.isEmpty ? String(localized: "Choose an app to open files with.") : nil
    case .runScript:
      script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "Write the shell script to run.") : nil
    default:
      nil
    }
  }
}

// MARK: - Activity and preview

/// One line of the activity log.
nonisolated struct ActivityEntry: Codable, Identifiable, Hashable, Sendable {
  var id = UUID()
  var date: Date
  var fileName: String
  var path: String
  var ruleName: String
  var summary: String
  var error: String?
}

/// A file a rule would act on right now, for the editor's Preview.
nonisolated struct PreviewItem: Identifiable, Hashable, Sendable {
  enum Status: Hashable, Sendable {
    case willRun
    case alreadyHandled
    case earlierRule(String)
  }

  var id: String { path }
  var path: String
  var name: String
  var steps: [String]
  var status: Status
}

// MARK: - Decoding helpers

nonisolated extension KeyedDecodingContainer {
  /// The decoded value, or `fallback` when it is missing or unreadable (for example an
  /// enum case from a newer version).
  func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
    ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
  }
}
