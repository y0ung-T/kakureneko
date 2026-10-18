import Foundation

/// A parsed JSON (or JSONC) value that remembers where it lives in the source bytes, so edits can be spliced
/// into the original text instead of re-serializing it (brief §3.7.3: never re-serialize with sorted keys).
struct JSONNode: Sendable {
    indirect enum Kind: Sendable {
        case object([JSONMember])
        case array([JSONNode])
        case string(String)
        /// The literal number text.
        case number(String)
        case bool(Bool)
        case null
    }

    var kind: Kind
    /// Offset of the first byte of the value.
    var start: Int
    /// Offset one past the last byte of the value.
    var end: Int

    var members: [JSONMember]? {
        if case .object(let members) = kind { return members }
        return nil
    }

    var elements: [JSONNode]? {
        if case .array(let elements) = kind { return elements }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = kind { return s }
        return nil
    }

    /// The LAST member named `key` (duplicate keys: last one wins, as in JavaScript and serde_json).
    func member(_ key: String) -> JSONMember? {
        members?.last { $0.key == key }
    }

    /// Order-insensitive semantic value (for "is our entry already there" comparisons).
    var value: JSONValue {
        switch kind {
        case .object(let members):
            var dict: [String: JSONValue] = [:]
            for m in members { dict[m.key] = m.value.value }
            return .object(dict)
        case .array(let elements): return .array(elements.map(\.value))
        case .string(let s): return .string(s)
        case .number(let text): return .number(Double(text) ?? .nan)
        case .bool(let b): return .bool(b)
        case .null: return .null
        }
    }
}

/// One `"key": value` member of an object.
struct JSONMember: Sendable {
    var key: String
    /// Offset of the opening quote of the key.
    var keyStart: Int
    var value: JSONNode

    var start: Int { keyStart }
    var end: Int { value.end }
}

/// Semantic JSON value. Objects compare without regard to key order; numbers compare numerically.
indirect enum JSONValue: Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
}

/// Recursive-descent parser over UTF-8 bytes.
///
/// * `.strict`: RFC 8259 (what Codex/serde_json, Cursor and Copilot accept).
/// * `.jsonc`: also `//` and `/* */` comments and trailing commas (Gemini/Qwen settings, VS Code style files).
///
/// A leading UTF-8 BOM is skipped (offsets stay relative to the full byte array).
enum JSONSyntax {
    enum Dialect: Sendable, Equatable {
        case strict
        case jsonc
    }

    struct ParseError: Error, Sendable, Equatable, CustomStringConvertible {
        var offset: Int
        var line: Int
        var column: Int
        var message: String
        var description: String { "\(message) at line \(line), column \(column)" }
    }

    /// Maximum nesting depth (defends against pathological input).
    static let maxDepth = 256

    static func parse(_ bytes: [UInt8], dialect: Dialect) throws(ParseError) -> JSONNode {
        var parser = Parser(bytes: bytes, jsonc: dialect == .jsonc)
        return try parser.parseDocument()
    }

    static func parse(_ text: String, dialect: Dialect) throws(ParseError) -> JSONNode {
        try parse(Array(text.utf8), dialect: dialect)
    }

    /// True when the text has a UTF-8 BOM.
    static func hasBOM(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF
    }

    /// True when `bytes` contain nothing but whitespace (and a BOM).
    static func isBlank(_ bytes: [UInt8]) -> Bool {
        let body = hasBOM(bytes) ? bytes.dropFirst(3) : bytes[...]
        return body.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
    }

    private struct Parser {
        let bytes: [UInt8]
        let jsonc: Bool
        var index = 0
        var depth = 0

        init(bytes: [UInt8], jsonc: Bool) {
            self.bytes = bytes
            self.jsonc = jsonc
            if JSONSyntax.hasBOM(bytes) { index = 3 }
        }

        mutating func parseDocument() throws(ParseError) -> JSONNode {
            let value = try parseValue()
            try skipTrivia()
            guard index == bytes.count else { throw error("unexpected content after the JSON value") }
            return value
        }

        // MARK: Values

        mutating func parseValue() throws(ParseError) -> JSONNode {
            try skipTrivia()
            guard index < bytes.count else { throw error("unexpected end of input") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject()
            case UInt8(ascii: "["): return try parseArray()
            case UInt8(ascii: "\""):
                let start = index
                let s = try parseString()
                return JSONNode(kind: .string(s), start: start, end: index)
            case UInt8(ascii: "t"): return try parseLiteral("true", .bool(true))
            case UInt8(ascii: "f"): return try parseLiteral("false", .bool(false))
            case UInt8(ascii: "n"): return try parseLiteral("null", .null)
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
            default: throw error("unexpected character")
            }
        }

        mutating func parseObject() throws(ParseError) -> JSONNode {
            let start = index
            depth += 1
            guard depth <= JSONSyntax.maxDepth else { throw error("nesting too deep") }
            defer { depth -= 1 }
            index += 1
            var members: [JSONMember] = []
            try skipTrivia()
            if peek == UInt8(ascii: "}") {
                index += 1
                return JSONNode(kind: .object(members), start: start, end: index)
            }
            while true {
                try skipTrivia()
                guard peek == UInt8(ascii: "\"") else { throw error("expected a string key") }
                let keyStart = index
                let key = try parseString()
                try skipTrivia()
                guard peek == UInt8(ascii: ":") else { throw error("expected ':'") }
                index += 1
                let value = try parseValue()
                members.append(JSONMember(key: key, keyStart: keyStart, value: value))
                try skipTrivia()
                if peek == UInt8(ascii: ",") {
                    index += 1
                    try skipTrivia()
                    if peek == UInt8(ascii: "}") {
                        guard jsonc else { throw error("trailing comma") }
                        index += 1
                        break
                    }
                    continue
                }
                if peek == UInt8(ascii: "}") {
                    index += 1
                    break
                }
                throw error("expected ',' or '}'")
            }
            return JSONNode(kind: .object(members), start: start, end: index)
        }

        mutating func parseArray() throws(ParseError) -> JSONNode {
            let start = index
            depth += 1
            guard depth <= JSONSyntax.maxDepth else { throw error("nesting too deep") }
            defer { depth -= 1 }
            index += 1
            var elements: [JSONNode] = []
            try skipTrivia()
            if peek == UInt8(ascii: "]") {
                index += 1
                return JSONNode(kind: .array(elements), start: start, end: index)
            }
            while true {
                elements.append(try parseValue())
                try skipTrivia()
                if peek == UInt8(ascii: ",") {
                    index += 1
                    try skipTrivia()
                    if peek == UInt8(ascii: "]") {
                        guard jsonc else { throw error("trailing comma") }
                        index += 1
                        break
                    }
                    continue
                }
                if peek == UInt8(ascii: "]") {
                    index += 1
                    break
                }
                throw error("expected ',' or ']'")
            }
            return JSONNode(kind: .array(elements), start: start, end: index)
        }

        mutating func parseLiteral(_ word: String, _ kind: JSONNode.Kind) throws(ParseError) -> JSONNode {
            let start = index
            for expected in word.utf8 {
                guard index < bytes.count, bytes[index] == expected else { throw error("invalid literal") }
                index += 1
            }
            return JSONNode(kind: kind, start: start, end: index)
        }

        mutating func parseNumber() throws(ParseError) -> JSONNode {
            let start = index
            if peek == UInt8(ascii: "-") { index += 1 }
            guard let first = peek, isDigit(first) else { throw error("invalid number") }
            if first == UInt8(ascii: "0") {
                index += 1
            } else {
                while let c = peek, isDigit(c) { index += 1 }
            }
            if peek == UInt8(ascii: ".") {
                index += 1
                guard let c = peek, isDigit(c) else { throw error("invalid number") }
                while let c = peek, isDigit(c) { index += 1 }
            }
            if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
                index += 1
                if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { index += 1 }
                guard let c = peek, isDigit(c) else { throw error("invalid number") }
                while let c = peek, isDigit(c) { index += 1 }
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            return JSONNode(kind: .number(text), start: start, end: index)
        }

        /// Parses a string starting at the opening quote; leaves `index` after the closing quote.
        mutating func parseString() throws(ParseError) -> String {
            index += 1
            var out: [UInt8] = []
            while true {
                guard index < bytes.count else { throw error("unterminated string") }
                let c = bytes[index]
                if c == UInt8(ascii: "\"") {
                    index += 1
                    return String(decoding: out, as: UTF8.self)
                }
                if c < 0x20 { throw error("control character in string") }
                if c != UInt8(ascii: "\\") {
                    out.append(c)
                    index += 1
                    continue
                }
                index += 1
                guard index < bytes.count else { throw error("unterminated escape") }
                let e = bytes[index]
                index += 1
                switch e {
                case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): out.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try parseHex4()
                    if (0xD800...0xDBFF).contains(scalar) {
                        // High surrogate: combine with a following low surrogate when present.
                        if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                            let save = index
                            index += 2
                            let low = try parseHex4()
                            if (0xDC00...0xDFFF).contains(low) {
                                scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                index = save
                                scalar = 0xFFFD
                            }
                        } else {
                            scalar = 0xFFFD
                        }
                    } else if (0xDC00...0xDFFF).contains(scalar) {
                        scalar = 0xFFFD
                    }
                    let unicode = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                    out.append(contentsOf: Array(String(Character(unicode)).utf8))
                default:
                    throw error("invalid escape")
                }
            }
        }

        mutating func parseHex4() throws(ParseError) -> UInt32 {
            guard index + 4 <= bytes.count else { throw error("invalid unicode escape") }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let c = bytes[index]
                let digit: UInt32
                switch c {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(c - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(c - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(c - UInt8(ascii: "A") + 10)
                default: throw error("invalid unicode escape")
                }
                value = value * 16 + digit
                index += 1
            }
            return value
        }

        // MARK: Trivia

        mutating func skipTrivia() throws(ParseError) {
            while index < bytes.count {
                let c = bytes[index]
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                    index += 1
                    continue
                }
                if jsonc, c == UInt8(ascii: "/"), index + 1 < bytes.count {
                    if bytes[index + 1] == UInt8(ascii: "/") {
                        index += 2
                        while index < bytes.count, bytes[index] != 0x0A { index += 1 }
                        continue
                    }
                    if bytes[index + 1] == UInt8(ascii: "*") {
                        let start = index
                        index += 2
                        var closed = false
                        while index + 1 < bytes.count {
                            if bytes[index] == UInt8(ascii: "*"), bytes[index + 1] == UInt8(ascii: "/") {
                                index += 2
                                closed = true
                                break
                            }
                            index += 1
                        }
                        if !closed {
                            index = start
                            throw error("unterminated comment")
                        }
                        continue
                    }
                }
                return
            }
        }

        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }

        func error(_ message: String) -> ParseError {
            let upTo = min(index, bytes.count)
            var line = 1
            var column = 1
            for b in bytes[0..<upTo] {
                if b == 0x0A {
                    line += 1
                    column = 1
                } else if b & 0xC0 != 0x80 {
                    column += 1
                }
            }
            return ParseError(offset: index, line: line, column: column, message: message)
        }
    }
}
