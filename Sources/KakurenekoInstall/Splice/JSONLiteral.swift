import Foundation

/// An ordered JSON value that Kakureneko writes (the snippets of brief §3.6). Unlike `JSONValue`, key order is
/// kept so rendered entries read like the documented snippets.
indirect enum JSONLiteral: Sendable {
    case object([JSONField])
    case array([JSONLiteral])
    case string(String)
    case int(Int)
    case bool(Bool)
    /// Always rendered on a single line (hook entries), whatever the surrounding layout.
    case compact(JSONLiteral)

    /// An object from ordered pairs: `.fields(["type": .string("command"), …])`.
    static func fields(_ pairs: KeyValuePairs<String, JSONLiteral>) -> JSONLiteral {
        .object(pairs.map { JSONField(key: $0.key, value: $0.value) })
    }

    /// Semantic value (for comparison with parsed nodes).
    var value: JSONValue {
        switch self {
        case .object(let fields):
            var dict: [String: JSONValue] = [:]
            for f in fields { dict[f.key] = f.value.value }
            return .object(dict)
        case .array(let items): return .array(items.map(\.value))
        case .string(let s): return .string(s)
        case .int(let i): return .number(Double(i))
        case .bool(let b): return .bool(b)
        case .compact(let inner): return inner.value
        }
    }

    /// Every string in the value (marker checks).
    var strings: [String] {
        switch self {
        case .object(let fields): fields.flatMap { [$0.key] + $0.value.strings }
        case .array(let items): items.flatMap(\.strings)
        case .string(let s): [s]
        case .int, .bool: []
        case .compact(let inner): inner.strings
        }
    }
}

/// One ordered `"key": value` pair of a `JSONLiteral.object`.
struct JSONField: Sendable {
    var key: String
    var value: JSONLiteral
}

/// Renders `JSONLiteral`s in the style of the file being edited.
struct JSONRenderer: Sendable {
    /// One level of indentation (detected from the file; two spaces for new files).
    var indentUnit: String = "  "
    /// `"\n"` or `"\r\n"` (detected from the file).
    var newline: String = "\n"

    /// Renders `literal` whose first character sits on a line indented by `indent`.
    /// - Parameter inline: render on one line (used inside single-line containers).
    func render(_ literal: JSONLiteral, indent: String, inline: Bool = false) -> String {
        switch literal {
        case .compact(let inner):
            return render(inner, indent: indent, inline: true)
        case .string(let s):
            return Self.quote(s)
        case .int(let i):
            return String(i)
        case .bool(let b):
            return b ? "true" : "false"
        case .object(let fields):
            if fields.isEmpty { return "{}" }
            if inline {
                return "{ " + fields.map { Self.quote($0.key) + ": " + render($0.value, indent: indent, inline: true) }
                    .joined(separator: ", ") + " }"
            }
            let inner = indent + indentUnit
            let body = fields.map { inner + Self.quote($0.key) + ": " + render($0.value, indent: inner) }
                .joined(separator: "," + newline)
            return "{" + newline + body + newline + indent + "}"
        case .array(let items):
            if items.isEmpty { return "[]" }
            if inline {
                return "[" + items.map { render($0, indent: indent, inline: true) }.joined(separator: ", ") + "]"
            }
            let inner = indent + indentUnit
            let body = items.map { inner + render($0, indent: inner) }.joined(separator: "," + newline)
            return "[" + newline + body + newline + indent + "]"
        }
    }

    /// A complete new document (`literal` + trailing newline).
    func renderDocument(_ literal: JSONLiteral) -> String {
        render(literal, indent: "") + newline
    }

    /// JSON string literal with the minimal escapes (`/` is not escaped).
    static func quote(_ s: String) -> String {
        var out = "\""
        out.reserveCapacity(s.utf8.count + 2)
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
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
