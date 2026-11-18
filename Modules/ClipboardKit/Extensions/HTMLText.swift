import Foundation

/// Plain text from HTML without `NSAttributedString(html:)`, which runs WebKit on the main
/// thread and synchronously fetches remote resources (an `<img src="https://…">` copied from
/// a browser could freeze Kitzi for many seconds).
nonisolated enum HTMLText {
  static func plainText(from data: Data) -> String {
    guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
      return ""
    }
    return plainText(from: html)
  }

  static func plainText(from html: String) -> String {
    var text = html
    // Drop invisible parts.
    for tag in ["script", "style", "head", "title"] {
      text = text.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: "",
                                       options: [.regularExpression, .caseInsensitive])
    }
    text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
    // Line breaks for block elements, then strip every remaining tag.
    text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
    text = text.replacingOccurrences(of: "</(p|div|li|tr|h[1-6]|blockquote|pre|table|ul|ol)>", with: "\n",
                                     options: [.regularExpression, .caseInsensitive])
    text = text.replacingOccurrences(of: "</t[dh]>", with: "\t", options: [.regularExpression, .caseInsensitive])
    text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    text = decodeEntities(text)
    // Tidy whitespace: collapse runs of spaces, keep at most one empty line.
    let lines = text.components(separatedBy: .newlines).map {
      $0.replacingOccurrences(of: "[ \\t\\u{00A0}]+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    }
    var result: [String] = []
    for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) {
      result.append(line)
    }
    return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static let namedEntities: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
    "ndash": "–", "mdash": "—", "hellip": "…", "laquo": "«", "raquo": "»", "copy": "©",
    "reg": "®", "trade": "™", "euro": "€", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
    "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "ccedil": "ç", "Ccedil": "Ç",
    "szlig": "ß", "aacute": "á", "agrave": "à", "acirc": "â", "eacute": "é", "egrave": "è", "ecirc": "ê",
    "iacute": "í", "icirc": "î", "oacute": "ó", "ocirc": "ô", "uacute": "ú", "ucirc": "û", "ntilde": "ñ",
    "deg": "°", "times": "×", "middot": "·", "bull": "•",
  ]

  private static func decodeEntities(_ string: String) -> String {
    guard string.contains("&") else { return string }
    var result = ""
    var index = string.startIndex
    while index < string.endIndex {
      let character = string[index]
      guard character == "&", let semicolon = string[index...].prefix(12).firstIndex(of: ";") else {
        result.append(character)
        index = string.index(after: index)
        continue
      }
      let name = string[string.index(after: index)..<semicolon]
      if let decoded = decode(String(name)) {
        result.append(decoded)
        index = string.index(after: semicolon)
      } else {
        result.append(character)
        index = string.index(after: index)
      }
    }
    return result
  }

  private static func decode(_ name: String) -> String? {
    if name.hasPrefix("#x") || name.hasPrefix("#X") {
      return UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }
    if name.hasPrefix("#") {
      return UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }
    return namedEntities[name] ?? namedEntities[name.lowercased()]
  }
}
