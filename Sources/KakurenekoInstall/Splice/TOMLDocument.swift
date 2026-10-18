import Foundation

/// A TOML value as far as the Codex installer needs it: strings and arrays are decoded, everything else is kept
/// as raw text.
indirect enum TOMLValue: Sendable, Equatable {
    case string(String)
    case array([TOMLValue])
    case inlineTable
    /// Numbers, booleans, dates (raw text).
    case other(String)

    /// The decoded strings when this is an array of strings only.
    var stringArray: [String]? {
        guard case .array(let items) = self else { return nil }
        var out: [String] = []
        for item in items {
            guard case .string(let s) = item else { return nil }
            out.append(s)
        }
        return out
    }
}

/// Statement-level scanner for line-oriented TOML edits (brief §3.7.3: "TOML: line-oriented splice of one
/// key"). It understands every TOML string form, multi-line arrays, inline tables and comments, so a `[` on a
/// continuation line of an array is never mistaken for a table header. It does not build a full document model.
struct TOMLDocument: Sendable {
    enum Kind: Sendable, Equatable {
        case blank
        case comment
        /// `[a.b]` or `[[a.b]]` (keys decoded).
        case table(path: [String], isArrayTable: Bool)
        /// `a.b = value` (keys decoded).
        case keyValue(key: [String], value: TOMLValue)
    }

    struct Statement: Sendable, Equatable {
        var kind: Kind
        /// Offset of the first byte of the statement's first line.
        var start: Int
        /// Offset of the line terminator that ends the statement (== `end` at EOF without newline).
        var contentEnd: Int
        /// Offset after the terminating newline (or EOF).
        var end: Int
    }

    struct ParseError: Error, Sendable, Equatable, CustomStringConvertible {
        var line: Int
        var message: String
        var description: String { "\(message) at line \(line)" }
    }

    let bytes: [UInt8]
    let statements: [Statement]

    init(_ text: String) throws(ParseError) {
        let bytes = Array(text.utf8)
        var scanner = Scanner(bytes: bytes)
        statements = try scanner.scanAll()
        self.bytes = bytes
    }

    var text: String { String(decoding: bytes, as: UTF8.self) }

    /// Statements before the first table header (the root table).
    var rootStatements: ArraySlice<Statement> {
        let firstTable = statements.firstIndex { if case .table = $0.kind { true } else { false } } ?? statements.endIndex
        return statements[..<firstTable]
    }

    /// Index of the first table header, if any.
    var firstTableIndex: Int? {
        statements.firstIndex { if case .table = $0.kind { true } else { false } }
    }

    /// The root-level `key = …` statement for a single bare key.
    func rootKeyValue(_ key: String) -> Statement? {
        rootStatements.last { if case .keyValue(let k, _) = $0.kind { k == [key] } else { false } }
    }

    /// The source text of a statement without its line terminator.
    func content(of statement: Statement) -> String {
        String(decoding: bytes[statement.start..<statement.contentEnd], as: UTF8.self)
    }

    /// The text's line terminator style.
    var newline: String { JSONEditor.detectNewline(bytes) }

    /// Offset of the first byte after a leading BOM.
    var bodyStart: Int { JSONSyntax.hasBOM(bytes) ? 3 : 0 }

    /// Every key-value statement with its key path resolved against the enclosing table header
    /// (`[hooks.state."x"]` + `trusted_hash = …` → `["hooks", "state", "x", "trusted_hash"]`).
    var resolvedKeyValues: [(path: [String], value: TOMLValue)] {
        var table: [String] = []
        var out: [(path: [String], value: TOMLValue)] = []
        for statement in statements {
            switch statement.kind {
            case .table(let path, _): table = path
            case .keyValue(let key, let value): out.append((table + key, value))
            case .blank, .comment: break
            }
        }
        return out
    }

    /// Every table header path (`[a.b]`, `[[a.b]]`).
    var tablePaths: [[String]] {
        statements.compactMap { if case .table(let path, _) = $0.kind { path } else { nil } }
    }

    // MARK: - Line-oriented edits (each the exact inverse of the other)

    /// Replaces the statement's source text (its line terminator is kept).
    func replacingContent(of statement: Statement, with text: String) -> String {
        splice(statement.start..<statement.contentEnd, with: text)
    }

    /// Removes the statement's lines. A statement that ends the file without a terminator takes the preceding line
    /// break with it (the inverse of `inserting(_:after:)` at such a position).
    func removing(_ statement: Statement) -> String {
        var lower = statement.start
        if statement.end == statement.contentEnd {
            lower = Self.startOfPrecedingLineBreak(bytes, before: lower, floor: bodyStart)
        }
        return splice(lower..<statement.end, with: "")
    }

    /// Inserts `line` (no terminator) as a new statement right after `statement`, or at the top of the file when
    /// `statement` is nil.
    func inserting(_ line: String, after statement: Statement?) -> String {
        guard let statement else {
            return splice(bodyStart..<bodyStart, with: line + newline)
        }
        if statement.end > statement.contentEnd {
            return splice(statement.end..<statement.end, with: line + newline)
        }
        return splice(statement.contentEnd..<statement.contentEnd, with: newline + line)
    }

    private func splice(_ range: Range<Int>, with text: String) -> String {
        var updated = bytes
        updated.replaceSubrange(range, with: Array(text.utf8))
        return String(decoding: updated, as: UTF8.self)
    }

    /// `offset` moved back over one `\n` or `\r\n` (never below `floor`).
    static func startOfPrecedingLineBreak(_ bytes: [UInt8], before offset: Int, floor: Int) -> Int {
        guard offset > floor, bytes[offset - 1] == 0x0A else { return offset }
        if offset - 1 > floor, bytes[offset - 2] == 0x0D { return offset - 2 }
        return offset - 1
    }

    /// A TOML basic string literal.
    static func basicString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    let hex = String(scalar.value, radix: 16, uppercase: true)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// `["a", "b"]` as TOML.
    static func stringArray(_ items: [String]) -> String {
        "[" + items.map(basicString).joined(separator: ", ") + "]"
    }

    // MARK: - Scanner

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        var depth = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
            if JSONSyntax.hasBOM(bytes) { index = 3 }
        }

        mutating func scanAll() throws(ParseError) -> [Statement] {
            var statements: [Statement] = []
            while index < bytes.count {
                // A leading BOM is skipped in `init`, so it never belongs to the first statement.
                let start = index
                skipSpaces()
                let kind: Kind
                if atLineEnd {
                    kind = .blank
                } else if bytes[index] == UInt8(ascii: "#") {
                    skipComment()
                    kind = .comment
                } else if bytes[index] == UInt8(ascii: "[") {
                    kind = try scanHeader()
                } else {
                    kind = try scanKeyValue()
                }
                try finishLine()
                let contentEnd = index
                consumeNewline()
                statements.append(Statement(kind: kind, start: start, contentEnd: contentEnd, end: index))
            }
            return statements
        }

        mutating func scanHeader() throws(ParseError) -> Kind {
            index += 1
            let isArray = peek == UInt8(ascii: "[")
            if isArray { index += 1 }
            skipSpaces()
            let path = try scanKey()
            skipSpaces()
            guard peek == UInt8(ascii: "]") else { throw error("expected ']'") }
            index += 1
            if isArray {
                guard peek == UInt8(ascii: "]") else { throw error("expected ']]'") }
                index += 1
            }
            return .table(path: path, isArrayTable: isArray)
        }

        mutating func scanKeyValue() throws(ParseError) -> Kind {
            let key = try scanKey()
            skipSpaces()
            guard peek == UInt8(ascii: "=") else { throw error("expected '='") }
            index += 1
            skipSpaces()
            let value = try scanValue()
            return .keyValue(key: key, value: value)
        }

        /// Dotted key: `a.b."c d".'e'`.
        mutating func scanKey() throws(ParseError) -> [String] {
            var parts: [String] = []
            while true {
                skipSpaces()
                guard let c = peek else { throw error("expected a key") }
                if c == UInt8(ascii: "\"") {
                    parts.append(try scanBasicString())
                } else if c == UInt8(ascii: "'") {
                    parts.append(try scanLiteralString())
                } else {
                    let start = index
                    while let c = peek, isBareKeyChar(c) { index += 1 }
                    guard index > start else { throw error("invalid key") }
                    parts.append(String(decoding: bytes[start..<index], as: UTF8.self))
                }
                skipSpaces()
                if peek == UInt8(ascii: ".") {
                    index += 1
                    continue
                }
                return parts
            }
        }

        mutating func scanValue() throws(ParseError) -> TOMLValue {
            guard let c = peek else { throw error("expected a value") }
            switch c {
            case UInt8(ascii: "\""):
                if hasPrefix("\"\"\"") { return .string(try scanMultilineBasicString()) }
                return .string(try scanBasicString())
            case UInt8(ascii: "'"):
                if hasPrefix("'''") { return .string(try scanMultilineLiteralString()) }
                return .string(try scanLiteralString())
            case UInt8(ascii: "["):
                return try scanArray()
            case UInt8(ascii: "{"):
                try scanInlineTable()
                return .inlineTable
            default:
                let start = index
                while let c = peek, !isValueTerminator(c) { index += 1 }
                guard index > start else { throw error("expected a value") }
                // A date-time may use a space instead of `T` (`1979-05-27 07:32:00Z`).
                if index - start == 10, bytes[start + 4] == UInt8(ascii: "-"), bytes[start + 7] == UInt8(ascii: "-"),
                   peek == 0x20, index + 1 < bytes.count, bytes[index + 1] >= UInt8(ascii: "0"), bytes[index + 1] <= UInt8(ascii: "9") {
                    index += 1
                    while let c = peek, !isValueTerminator(c) { index += 1 }
                }
                return .other(String(decoding: bytes[start..<index], as: UTF8.self))
            }
        }

        mutating func scanArray() throws(ParseError) -> TOMLValue {
            depth += 1
            guard depth <= 128 else { throw error("nesting too deep") }
            defer { depth -= 1 }
            index += 1
            var items: [TOMLValue] = []
            while true {
                try skipArrayTrivia()
                guard let c = peek else { throw error("unterminated array") }
                if c == UInt8(ascii: "]") {
                    index += 1
                    return .array(items)
                }
                items.append(try scanValue())
                try skipArrayTrivia()
                guard let next = peek else { throw error("unterminated array") }
                if next == UInt8(ascii: ",") {
                    index += 1
                } else if next != UInt8(ascii: "]") {
                    throw error("expected ',' or ']'")
                }
            }
        }

        mutating func scanInlineTable() throws(ParseError) {
            depth += 1
            guard depth <= 128 else { throw error("nesting too deep") }
            defer { depth -= 1 }
            index += 1
            while true {
                try skipArrayTrivia()
                guard let c = peek else { throw error("unterminated inline table") }
                if c == UInt8(ascii: "}") {
                    index += 1
                    return
                }
                _ = try scanKey()
                skipSpaces()
                guard peek == UInt8(ascii: "=") else { throw error("expected '='") }
                index += 1
                skipSpaces()
                _ = try scanValue()
                try skipArrayTrivia()
                guard let next = peek else { throw error("unterminated inline table") }
                if next == UInt8(ascii: ",") {
                    index += 1
                } else if next != UInt8(ascii: "}") {
                    throw error("expected ',' or '}'")
                }
            }
        }

        mutating func scanBasicString() throws(ParseError) -> String {
            index += 1
            var out: [UInt8] = []
            while true {
                guard let c = peek, c != 0x0A else { throw error("unterminated string") }
                if c == UInt8(ascii: "\"") {
                    index += 1
                    return String(decoding: out, as: UTF8.self)
                }
                if c == UInt8(ascii: "\\") {
                    index += 1
                    try appendEscape(into: &out)
                    continue
                }
                out.append(c)
                index += 1
            }
        }

        mutating func scanLiteralString() throws(ParseError) -> String {
            index += 1
            let start = index
            while true {
                guard let c = peek, c != 0x0A else { throw error("unterminated string") }
                if c == UInt8(ascii: "'") {
                    let s = String(decoding: bytes[start..<index], as: UTF8.self)
                    index += 1
                    return s
                }
                index += 1
            }
        }

        mutating func scanMultilineBasicString() throws(ParseError) -> String {
            index += 3
            skipImmediateNewline()
            var out: [UInt8] = []
            while true {
                guard let c = peek else { throw error("unterminated string") }
                if hasPrefix("\"\"\"") {
                    // Up to two extra quotes belong to the content (`""""` ends with one quote).
                    var quotes = 3
                    while quotes < 5, index + quotes < bytes.count, bytes[index + quotes] == UInt8(ascii: "\"") { quotes += 1 }
                    out.append(contentsOf: Array(repeating: UInt8(ascii: "\""), count: quotes - 3))
                    index += quotes
                    return String(decoding: out, as: UTF8.self)
                }
                if c == UInt8(ascii: "\\") {
                    index += 1
                    // Line-ending backslash: trim whitespace and newlines up to the next content.
                    var probe = index
                    while probe < bytes.count, bytes[probe] == 0x20 || bytes[probe] == 0x09 { probe += 1 }
                    if probe < bytes.count, bytes[probe] == 0x0A || bytes[probe] == 0x0D {
                        index = probe
                        while let w = peek, w == 0x20 || w == 0x09 || w == 0x0A || w == 0x0D { index += 1 }
                        continue
                    }
                    try appendEscape(into: &out)
                    continue
                }
                out.append(c)
                index += 1
            }
        }

        mutating func scanMultilineLiteralString() throws(ParseError) -> String {
            index += 3
            skipImmediateNewline()
            let start = index
            while index < bytes.count {
                if hasPrefix("'''") {
                    var quotes = 3
                    while quotes < 5, index + quotes < bytes.count, bytes[index + quotes] == UInt8(ascii: "'") { quotes += 1 }
                    let s = String(decoding: bytes[start..<(index + quotes - 3)], as: UTF8.self)
                    index += quotes
                    return s
                }
                index += 1
            }
            throw error("unterminated string")
        }

        mutating func appendEscape(into out: inout [UInt8]) throws(ParseError) {
            guard let e = peek else { throw error("unterminated escape") }
            index += 1
            switch e {
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "e"): out.append(0x1B)
            case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
            case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
            case UInt8(ascii: "x"): try appendHexScalar(digits: 2, into: &out)
            case UInt8(ascii: "u"): try appendHexScalar(digits: 4, into: &out)
            case UInt8(ascii: "U"): try appendHexScalar(digits: 8, into: &out)
            default: throw error("invalid escape")
            }
        }

        mutating func appendHexScalar(digits: Int, into out: inout [UInt8]) throws(ParseError) {
            guard index + digits <= bytes.count,
                  let value = UInt32(String(decoding: bytes[index..<(index + digits)], as: UTF8.self), radix: 16),
                  let scalar = Unicode.Scalar(value) else { throw error("invalid unicode escape") }
            index += digits
            out.append(contentsOf: Array(String(Character(scalar)).utf8))
        }

        // MARK: Trivia

        /// After a statement: spaces, an optional comment, then a line end.
        mutating func finishLine() throws(ParseError) {
            skipSpaces()
            if peek == UInt8(ascii: "#") { skipComment() }
            guard atLineEnd else { throw error("unexpected content after the statement") }
        }

        mutating func skipArrayTrivia() throws(ParseError) {
            while let c = peek {
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                    index += 1
                } else if c == UInt8(ascii: "#") {
                    skipComment()
                } else {
                    return
                }
            }
        }

        mutating func skipSpaces() {
            while let c = peek, c == 0x20 || c == 0x09 { index += 1 }
        }

        mutating func skipComment() {
            while let c = peek, c != 0x0A, !(c == 0x0D && index + 1 < bytes.count && bytes[index + 1] == 0x0A) { index += 1 }
        }

        mutating func skipImmediateNewline() {
            if peek == 0x0A {
                index += 1
            } else if peek == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                index += 2
            }
        }

        mutating func consumeNewline() {
            if peek == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                index += 2
            } else if peek == 0x0A {
                index += 1
            }
        }

        var atLineEnd: Bool {
            guard let c = peek else { return true }
            return c == 0x0A || (c == 0x0D && index + 1 < bytes.count && bytes[index + 1] == 0x0A)
        }

        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        func hasPrefix(_ s: String) -> Bool {
            let u = Array(s.utf8)
            guard index + u.count <= bytes.count else { return false }
            return Array(bytes[index..<(index + u.count)]) == u
        }

        func isBareKeyChar(_ c: UInt8) -> Bool {
            (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
                || (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) || c == UInt8(ascii: "_") || c == UInt8(ascii: "-")
        }

        func isValueTerminator(_ c: UInt8) -> Bool {
            c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == UInt8(ascii: ",") || c == UInt8(ascii: "]")
                || c == UInt8(ascii: "}") || c == UInt8(ascii: "#")
        }

        func error(_ message: String) -> ParseError {
            let line = bytes[0..<min(index, bytes.count)].reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
            return ParseError(line: line, message: message)
        }
    }
}
