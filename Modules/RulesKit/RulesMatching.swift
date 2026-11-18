import Foundation

/// Decides whether a file meets a rule's conditions. Text comparisons ignore case.
/// An unfinished condition (empty text) never matches, so a half-made rule does nothing.
nonisolated final class ConditionMatcher {
  private var regexCache: [String: NSRegularExpression] = [:]

  func matches(_ rule: FolderRule, _ info: FileInfo, now: Date) -> Bool {
    guard !rule.conditions.isEmpty else { return false }
    if rule.matchAll {
      return rule.conditions.allSatisfy { matches($0, info, now: now) }
    }
    return rule.conditions.contains { matches($0, info, now: now) }
  }

  func matches(_ condition: RuleCondition, _ info: FileInfo, now: Date) -> Bool {
    switch condition.attribute {
    case .anyFile:
      return true
    case .name:
      return matchesText([info.name], condition)
    case .fullName:
      return matchesText([info.fullName], condition)
    case .fileExtension:
      return matchesExtension(info.ext, condition)
    case .sourceURL:
      return matchesText(info.whereFroms, condition)
    case .kind:
      return condition.op == .notEquals ? info.kind != condition.kind : info.kind == condition.kind
    case .dateAdded:
      return matchesDate(info.added, condition, now: now, missingMeansNever: false)
    case .dateModified:
      return matchesDate(info.modified, condition, now: now, missingMeansNever: false)
    case .dateCreated:
      return matchesDate(info.created, condition, now: now, missingMeansNever: false)
    case .dateLastOpened:
      return matchesDate(info.lastOpened, condition, now: now, missingMeansNever: true)
    case .size:
      let limit = Int64(max(0, condition.number)) * condition.sizeUnit.bytes
      return condition.op == .greaterThan ? info.size > limit : info.size < limit
    case .tags:
      return matchesTags(info.tags, condition)
    }
  }

  // MARK: Text

  /// Positive operators match if any value matches; negative ones if none does.
  private func matchesText(_ values: [String], _ condition: RuleCondition) -> Bool {
    let needle = condition.text
    guard !needle.isEmpty else { return false }
    switch condition.op {
    case .notEquals:
      return !values.contains { $0.compare(needle, options: .caseInsensitive) == .orderedSame }
    case .doesNotContain:
      return !values.contains { $0.range(of: needle, options: .caseInsensitive) != nil }
    default:
      return values.contains { test($0, needle, condition.op) }
    }
  }

  private func test(_ value: String, _ needle: String, _ op: ConditionOperator) -> Bool {
    switch op {
    case .equals:
      return value.compare(needle, options: .caseInsensitive) == .orderedSame
    case .contains:
      return value.range(of: needle, options: .caseInsensitive) != nil
    case .startsWith:
      return value.range(of: needle, options: [.caseInsensitive, .anchored]) != nil
    case .endsWith:
      return value.range(of: needle, options: [.caseInsensitive, .anchored, .backwards]) != nil
    case .matchesRegex:
      guard let regex = regex(needle) else { return false }
      return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    default:
      return false
    }
  }

  /// "is" and "is not" take a comma-separated list for extensions: "jpg, jpeg, png".
  private func matchesExtension(_ ext: String, _ condition: RuleCondition) -> Bool {
    guard condition.op == .equals || condition.op == .notEquals else {
      var trimmed = condition
      trimmed.text = Self.stripDot(condition.text)
      return matchesText([ext], trimmed)
    }
    let wanted = condition.text.split(separator: ",").map { Self.stripDot(String($0)) }.filter { !$0.isEmpty }
    guard !wanted.isEmpty else { return false }
    let found = wanted.contains { ext.compare($0, options: .caseInsensitive) == .orderedSame }
    return condition.op == .equals ? found : !found
  }

  private static func stripDot(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    return trimmed.hasPrefix(".") ? String(trimmed.dropFirst()) : trimmed
  }

  private func regex(_ pattern: String) -> NSRegularExpression? {
    if let cached = regexCache[pattern] { return cached }
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
    regexCache[pattern] = regex
    return regex
  }

  // MARK: Dates, tags

  /// A missing date never matches, except "last opened": a file never opened is
  /// "not opened in the last N days".
  private func matchesDate(_ date: Date?, _ condition: RuleCondition, now: Date, missingMeansNever: Bool) -> Bool {
    guard let date else {
      return missingMeansNever && condition.op == .notInLast
    }
    switch condition.op {
    case .isToday:
      return Calendar.current.isDate(date, inSameDayAs: now)
    case .inLast:
      return date >= condition.dateUnit.date(goingBack: max(0, condition.number), from: now)
    case .notInLast:
      return date < condition.dateUnit.date(goingBack: max(0, condition.number), from: now)
    default:
      return false
    }
  }

  private func matchesTags(_ tags: [String], _ condition: RuleCondition) -> Bool {
    if condition.op == .hasNoTags { return tags.isEmpty }
    let wanted = condition.text.trimmingCharacters(in: .whitespaces)
    guard !wanted.isEmpty else { return false }
    let found = tags.contains { $0.compare(wanted, options: .caseInsensitive) == .orderedSame }
    return condition.op == .hasTag ? found : !found
  }
}

// MARK: - Patterns

nonisolated struct PatternToken: Identifiable, Sendable {
  var id: String { token }
  var token: String
  var meaning: String
}

/// Fills in `{token}` patterns for Rename, Sort into subfolders, tags and notifications.
nonisolated enum PatternExpander {
  /// Tokens and what they mean, for the help popover.
  static var tokenHelp: [PatternToken] {
    [
      PatternToken(token: "{name}", meaning: String(localized: "Name without extension")),
      PatternToken(token: "{ext}", meaning: String(localized: "Extension")),
      PatternToken(token: "{fullname}", meaning: String(localized: "Full name with extension")),
      PatternToken(token: "{folder}", meaning: String(localized: "Name of the folder the file is in")),
      PatternToken(token: "{kind}", meaning: String(localized: "Kind, like Images or PDFs")),
      PatternToken(token: "{source}", meaning: String(localized: "Site the file was downloaded from")),
      PatternToken(token: "{added:yyyy-MM-dd}", meaning: String(localized: "Date added, in any date format")),
      PatternToken(token: "{modified:…} {created:…}", meaning: String(localized: "Date modified, date created")),
      PatternToken(token: "{now:HH.mm}", meaning: String(localized: "Current date and time")),
      PatternToken(token: "{year} {month} {day}", meaning: String(localized: "Parts of the date added")),
      PatternToken(token: "{counter} {counter:3}", meaning: String(localized: "A number that goes up each time, with digits")),
    ]
  }

  /// `counter` hands out the next counter value; it is called only if the pattern uses it.
  static func expand(_ pattern: String, info: FileInfo, now: Date, counter: () -> Int) -> String {
    var result = ""
    var rest = pattern[...]
    while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
      result += rest[..<open]
      let token = String(rest[rest.index(after: open)..<close])
      result += value(for: token, info: info, now: now, counter: counter) ?? String(rest[open...close])
      rest = rest[rest.index(after: close)...]
    }
    return result + rest
  }

  /// Whether the pattern contains `{token}` or `{token:…}`.
  static func uses(_ token: String, in pattern: String) -> Bool {
    pattern.range(of: "{\(token)}", options: .caseInsensitive) != nil
      || pattern.range(of: "{\(token):", options: .caseInsensitive) != nil
  }

  private static func value(for token: String, info: FileInfo, now: Date, counter: () -> Int) -> String? {
    let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let key = parts.first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    let argument = parts.count > 1 ? String(parts[1]) : nil
    let dated = info.added ?? info.created ?? now
    switch key {
    case "name": return info.name
    case "ext", "extension": return info.ext
    case "fullname": return info.fullName
    case "folder": return info.url.deletingLastPathComponent().lastPathComponent
    case "kind": return info.kind.folderName
    case "source": return info.sourceDomain ?? FileKindValue.other.title
    case "added": return format(dated, argument)
    case "modified": return format(info.modified ?? now, argument)
    case "created": return format(info.created ?? now, argument)
    case "now": return format(now, argument)
    case "year": return format(dated, "yyyy")
    case "month": return format(dated, "MM")
    case "day": return format(dated, "dd")
    case "counter":
      let digits = min(10, max(1, argument.flatMap { Int($0) } ?? 1))
      let number = String(counter())
      return String(repeating: "0", count: max(0, digits - number.count)) + number
    default: return nil
    }
  }

  private static func format(_ date: Date, _ pattern: String?) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    let trimmed = pattern?.trimmingCharacters(in: .whitespaces) ?? ""
    formatter.dateFormat = trimmed.isEmpty ? "yyyy-MM-dd" : trimmed
    return formatter.string(from: date)
  }
}
