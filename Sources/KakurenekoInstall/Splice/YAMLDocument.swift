import Foundation

/// Line-oriented scanner for the top-level mapping of a simple YAML file (`~/.aider.conf.yml`; brief §3.7.3:
/// "TOML/YAML: line-oriented splice of one key"). It finds each top-level `key:` entry with the exact line range
/// it occupies and decodes scalar values (plain, single/double quoted, `|`/`>` block scalars). Anything that is
/// not a single block mapping at the top level (a top-level sequence, a flow mapping, several documents) is
/// refused, so the installer never edits a file it does not understand.
struct YAMLDocument: Sendable {
    struct Line: Sendable, Equatable {
        /// Offset of the first byte.
        var start: Int
        /// Offset of the terminator (`\n` or `\r\n`), or EOF.
        var contentEnd: Int
        /// Offset after the terminator.
        var end: Int
    }

    /// One top-level `key: value` entry.
    struct Entry: Sendable, Equatable {
        var key: String
        /// Line indices `[firstLine, lastLine]` (key line … last content line of the value).
        var firstLine: Int
        var lastLine: Int
        /// Offset of the key line's first byte.
        var start: Int
        /// Offset of the terminator of the last line.
        var contentEnd: Int
        /// Offset after the last line's terminator.
        var end: Int
    }

    /// A decoded value.
    enum Scalar: Sendable, Equatable {
        case null
        case string(String)
        /// A nested mapping or sequence (not a scalar).
        case collection
    }

    struct ParseError: Error, Sendable, Equatable, CustomStringConvertible {
        var line: Int
        var message: String
        var description: String { "\(message) at line \(line)" }
    }

    let bytes: [UInt8]
    let lines: [Line]
    let entries: [Entry]

    init(_ text: String) throws(ParseError) {
        let bytes = Array(text.utf8)
        self.bytes = bytes
        var lines: [Line] = []
        var i = JSONSyntax.hasBOM(bytes) ? 3 : 0
        while i < bytes.count {
            let start = i
            while i < bytes.count, bytes[i] != 0x0A { i += 1 }
            var contentEnd = i
            if contentEnd > start, i < bytes.count, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            if i < bytes.count { i += 1 }
            lines.append(Line(start: start, contentEnd: contentEnd, end: i))
        }
        self.lines = lines

        var entries: [Entry] = []
        var current: Entry?
        var sawDocumentStart = false
        for (n, line) in lines.enumerated() {
            let first = line.start < line.contentEnd ? bytes[line.start] : nil
            let isIndented = first == 0x20 || first == 0x09
            let blankOrComment = Self.isBlankOrComment(line, bytes)
            if blankOrComment || isIndented {
                if current != nil {
                    current!.lastLine = n
                } else if isIndented, !blankOrComment {
                    throw ParseError(line: n + 1, message: "indented content before the first key")
                }
                continue
            }
            // Column-0 content: a key, a document marker, or something we do not support.
            if let entry = current { entries.append(Self.closed(entry, lines: lines, bytes: bytes)) }
            current = nil
            let text = String(decoding: bytes[line.start..<line.contentEnd], as: UTF8.self)
            if Self.isMarker(text, "---") {
                // One leading `---` is fine; a second document is not.
                guard !sawDocumentStart, entries.isEmpty else {
                    throw ParseError(line: n + 1, message: "multiple YAML documents are not supported")
                }
                sawDocumentStart = true
                continue
            }
            if Self.isMarker(text, "...") {
                throw ParseError(line: n + 1, message: "YAML document end markers are not supported")
            }
            guard let key = Self.parseKey(text) else {
                throw ParseError(line: n + 1, message: "only a top-level block mapping is supported")
            }
            current = Entry(key: key, firstLine: n, lastLine: n, start: line.start, contentEnd: line.contentEnd, end: line.end)
        }
        if let entry = current { entries.append(Self.closed(entry, lines: lines, bytes: bytes)) }
        self.entries = entries
    }

    /// Trailing blank/comment lines belong to the gap after an entry, not to its value.
    private static func closed(_ entry: Entry, lines: [Line], bytes: [UInt8]) -> Entry {
        var entry = entry
        while entry.lastLine > entry.firstLine, isBlankOrComment(lines[entry.lastLine], bytes) { entry.lastLine -= 1 }
        entry.contentEnd = lines[entry.lastLine].contentEnd
        entry.end = lines[entry.lastLine].end
        return entry
    }

    private static func isMarker(_ text: String, _ marker: String) -> Bool {
        guard text.hasPrefix(marker) else { return false }
        let rest = text.dropFirst(marker.count)
        return rest.isEmpty || rest.first == " " || rest.first == "\t"
    }

    var text: String { String(decoding: bytes, as: UTF8.self) }

    /// Every top-level entry named `key` (normally zero or one).
    func entries(named key: String) -> [Entry] { entries.filter { $0.key == key } }

    /// Source text of `entry` without the last line's terminator.
    func content(of entry: Entry) -> String {
        String(decoding: bytes[entry.start..<entry.contentEnd], as: UTF8.self)
    }

    /// The text's line terminator style.
    var newline: String { JSONEditor.detectNewline(bytes) }

    /// Offset of the first byte after a leading BOM.
    var bodyStart: Int { JSONSyntax.hasBOM(bytes) ? 3 : 0 }

    /// Decodes the value of `entry`.
    func scalar(of entry: Entry) throws(ParseError) -> Scalar {
        let keyLine = lines[entry.firstLine]
        let keyText = String(decoding: bytes[keyLine.start..<keyLine.contentEnd], as: UTF8.self)
        guard let colon = Self.keyColonIndex(keyText) else { throw ParseError(line: entry.firstLine + 1, message: "missing ':'") }
        let rest = String(keyText[keyText.index(after: colon)...])
        var continuation: [String] = []
        if entry.lastLine > entry.firstLine {
            for n in (entry.firstLine + 1)...entry.lastLine {
                continuation.append(String(decoding: bytes[lines[n].start..<lines[n].contentEnd], as: UTF8.self))
            }
        }
        return try Self.decodeScalar(rest: rest, continuation: continuation, line: entry.firstLine + 1)
    }

    // MARK: - Line-oriented edits (each the exact inverse of the other)

    /// Replaces the entry's source lines (the last line's terminator is kept).
    func replacingContent(of entry: Entry, with text: String) -> String {
        splice(entry.start..<entry.contentEnd, with: text)
    }

    /// Removes the entry's lines. An entry that ends the file without a terminator takes the preceding line break
    /// with it (the inverse of `inserting(_:after:)` / `appending(_:)` at such a position).
    func removing(_ entry: Entry) -> String {
        var lower = entry.start
        if entry.end == entry.contentEnd {
            lower = TOMLDocument.startOfPrecedingLineBreak(bytes, before: lower, floor: bodyStart)
        }
        return splice(lower..<entry.end, with: "")
    }

    /// Inserts `line` (no terminator) right after `entry`.
    func inserting(_ line: String, after entry: Entry) -> String {
        if entry.end > entry.contentEnd {
            return splice(entry.end..<entry.end, with: line + newline)
        }
        return splice(entry.contentEnd..<entry.contentEnd, with: newline + line)
    }

    /// Appends `line` (no terminator) after the last line of the file.
    func appending(_ line: String) -> String {
        guard bytes.count > bodyStart else { return splice(bytes.count..<bytes.count, with: line + newline) }
        if bytes[bytes.count - 1] == 0x0A { return splice(bytes.count..<bytes.count, with: line + newline) }
        return splice(bytes.count..<bytes.count, with: newline + line)
    }

    private func splice(_ range: Range<Int>, with text: String) -> String {
        var updated = bytes
        updated.replaceSubrange(range, with: Array(text.utf8))
        return String(decoding: updated, as: UTF8.self)
    }

    // MARK: - Rendering

    /// A YAML double-quoted scalar.
    static func doubleQuoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    let hex = String(scalar.value, radix: 16, uppercase: true)
                    out += "\\x" + (hex.count < 2 ? "0" : "") + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// YAML 1.1/1.2 truthy plain scalars (`true`, `yes`, `on`, any case) — PyYAML (Aider) reads YAML 1.1.
    static func isTrue(_ scalar: Scalar) -> Bool {
        guard case .string(let s) = scalar else { return false }
        return ["true", "yes", "on", "y"].contains(s.lowercased())
    }

    // MARK: - Helpers

    static func isBlankOrComment(_ line: Line, _ bytes: [UInt8]) -> Bool {
        var i = line.start
        while i < line.contentEnd, bytes[i] == 0x20 || bytes[i] == 0x09 { i += 1 }
        return i == line.contentEnd || bytes[i] == UInt8(ascii: "#")
    }

    /// `key: …` at column 0 → `key` (plain or quoted).
    static func parseKey(_ text: String) -> String? {
        guard let colon = keyColonIndex(text) else { return nil }
        let raw = text[..<colon].trimmingCharacters(in: .whitespaces)
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
            if case .string(let s)? = try? decodeDoubleQuoted(raw, line: 0).value { return s }
            return nil
        }
        if raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'") {
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        guard let first = raw.first, !"-?[]{}#&*!|>'\"%@`,".contains(first) else { return nil }
        return raw
    }

    /// Index of the `:` that ends a column-0 key (followed by whitespace or end of line).
    static func keyColonIndex(_ text: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if let q = quote {
                if q == "\"", c == "\\", !escaped {
                    escaped = true
                } else {
                    if c == q, !escaped { quote = nil }
                    escaped = false
                }
            } else if (c == "\"" || c == "'") && i == text.startIndex {
                quote = c
            } else if c == "#" {
                return nil
            } else if c == ":" {
                let next = text.index(after: i)
                if next == text.endIndex || text[next] == " " || text[next] == "\t" { return i }
            }
            i = text.index(after: i)
        }
        return nil
    }

    static func decodeScalar(rest: String, continuation: [String], line: Int) throws(ParseError) -> Scalar {
        let head = rest.trimmingCharacters(in: .whitespaces)
        let body = continuation.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        if head.isEmpty || head.hasPrefix("#") {
            let content = body.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let first = content.first else { return .null }
            if first.hasPrefix("- ") || first == "-" || keyColonIndex(first) != nil { return .collection }
            return .string(content.map(stripPlainComment).joined(separator: " "))
        }
        if head.hasPrefix("|") || head.hasPrefix(">") {
            return .string(decodeBlock(header: head, lines: continuation))
        }
        if head.hasPrefix("\"") || head.hasPrefix("'") {
            let joined = ([head] + continuation).joined(separator: "\n")
            let (value, remainder) = head.hasPrefix("\"")
                ? try decodeDoubleQuoted(joined, line: line)
                : try decodeSingleQuoted(joined, line: line)
            let trailing = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trailing.isEmpty || trailing.hasPrefix("#") else {
                throw ParseError(line: line, message: "content after a quoted scalar")
            }
            return value
        }
        if head.hasPrefix("[") || head.hasPrefix("{") { return .collection }
        var parts = [stripPlainComment(head)]
        for raw in body {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { parts.append(stripPlainComment(t)) }
        }
        let value = parts.joined(separator: " ")
        if value == "~" || value.lowercased() == "null" || value.isEmpty { return .null }
        return .string(value)
    }

    private static func stripPlainComment(_ s: String) -> String {
        var previous: Character = " "
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "#", previous == " " || previous == "\t" {
                return String(s[..<i]).trimmingCharacters(in: .whitespaces)
            }
            previous = s[i]
            i = s.index(after: i)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Folds the line segments of a multi-line flow scalar: one break → space, n breaks → n-1 newlines; leading
    /// whitespace of continuation lines and trailing whitespace before a break are not content.
    private static func fold(_ segments: [String]) -> String {
        guard segments.count > 1 else { return segments.first ?? "" }
        var out = ""
        var pendingBreaks = 0
        for (n, raw) in segments.enumerated() {
            var t = raw
            if n > 0 { t = String(t.drop { $0 == " " || $0 == "\t" }) }
            if n < segments.count - 1 {
                while let last = t.last, last == " " || last == "\t" { t.removeLast() }
            }
            if n > 0 {
                if t.isEmpty, n < segments.count - 1 {
                    pendingBreaks += 1
                    continue
                }
                out += pendingBreaks == 0 ? " " : String(repeating: "\n", count: pendingBreaks)
                pendingBreaks = 0
            }
            out += t
        }
        return out
    }

    /// Decodes a double-quoted scalar starting at the first character of `text`; returns the value and the text
    /// after the closing quote.
    static func decodeDoubleQuoted(_ text: String, line: Int) throws(ParseError) -> (value: Scalar, remainder: Substring) {
        let scalars = text.unicodeScalars
        var i = scalars.startIndex
        guard i < scalars.endIndex, scalars[i] == "\"" else { throw ParseError(line: line, message: "expected '\"'") }
        i = scalars.index(after: i)
        var segments: [String] = [""]
        func append(_ s: Unicode.Scalar) { segments[segments.count - 1].unicodeScalars.append(s) }
        while i < scalars.endIndex {
            let c = scalars[i]
            if c == "\"" {
                let after = scalars.index(after: i)
                return (.string(fold(segments)), Substring(text.unicodeScalars[after...]))
            }
            if c == "\n" {
                segments.append("")
                i = scalars.index(after: i)
                continue
            }
            guard c == "\\" else {
                append(c)
                i = scalars.index(after: i)
                continue
            }
            i = scalars.index(after: i)
            guard i < scalars.endIndex else { break }
            let e = scalars[i]
            i = scalars.index(after: i)
            switch e {
            case "n": append("\n")
            case "t", "\t": append("\t")
            case "r": append("\r")
            case "0": append("\u{0}")
            case "a": append("\u{07}")
            case "b": append("\u{08}")
            case "e": append("\u{1B}")
            case "f": append("\u{0C}")
            case "v": append("\u{0B}")
            case "\"": append("\"")
            case "\\": append("\\")
            case "/": append("/")
            case " ": append(" ")
            case "N": append("\u{85}")
            case "_": append("\u{A0}")
            case "x", "u", "U":
                let digits = e == "x" ? 2 : (e == "u" ? 4 : 8)
                var hex = ""
                for _ in 0..<digits {
                    guard i < scalars.endIndex else { throw ParseError(line: line, message: "invalid escape") }
                    hex.unicodeScalars.append(scalars[i])
                    i = scalars.index(after: i)
                }
                guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
                    throw ParseError(line: line, message: "invalid escape")
                }
                append(scalar)
            case "\n":
                // Escaped line break: the lines join without a space; the next line's indentation is skipped.
                while i < scalars.endIndex, scalars[i] == " " || scalars[i] == "\t" { i = scalars.index(after: i) }
            default:
                throw ParseError(line: line, message: "invalid escape")
            }
        }
        throw ParseError(line: line, message: "unterminated double-quoted scalar")
    }

    static func decodeSingleQuoted(_ text: String, line: Int) throws(ParseError) -> (value: Scalar, remainder: Substring) {
        var segments: [String] = [""]
        var i = text.index(after: text.startIndex)
        while i < text.endIndex {
            let c = text[i]
            if c == "'" {
                let next = text.index(after: i)
                if next < text.endIndex, text[next] == "'" {
                    segments[segments.count - 1].append("'")
                    i = text.index(after: next)
                    continue
                }
                return (.string(fold(segments)), text[next...])
            }
            if c == "\n" {
                segments.append("")
            } else {
                segments[segments.count - 1].append(c)
            }
            i = text.index(after: i)
        }
        throw ParseError(line: line, message: "unterminated single-quoted scalar")
    }

    /// `|`/`>` block scalar with optional chomping (`-`/`+`) and indentation indicators.
    static func decodeBlock(header: String, lines: [String]) -> String {
        let literal = header.hasPrefix("|")
        let indicators = header.dropFirst().prefix { $0 != " " && $0 != "\t" && $0 != "#" }
        let chomp: Character? = indicators.first { $0 == "-" || $0 == "+" }
        let explicitIndent = indicators.first { $0.isNumber }.flatMap { Int(String($0)) }
        let width = explicitIndent
            ?? lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.prefix { $0 == " " }.count }
            ?? 0
        let content = lines.map { line -> String in
            line.count >= width && line.prefix(width).allSatisfy({ $0 == " " })
                ? String(line.dropFirst(width))
                : line.trimmingCharacters(in: .whitespaces)
        }
        var body: String
        if literal {
            body = content.joined(separator: "\n")
        } else {
            body = ""
            for (n, line) in content.enumerated() {
                if n > 0 { body += (line.isEmpty || content[n - 1].isEmpty) ? "\n" : " " }
                body += line
            }
        }
        let trimmed = String(body.reversed().drop { $0 == "\n" }.reversed())
        switch chomp {
        case "-": return trimmed
        case "+": return body + "\n"
        default: return trimmed + "\n"
        }
    }
}
