import KakurenekoKit
import Foundation

/// A parsed JSON value: a `Sendable` mirror of `JSONSerialization` output.
///
/// Numbers keep their textual form (`NSNumber.stringValue`), so integer identifiers larger than 2^53 survive
/// exactly; booleans stay booleans (a JSON `true` is never rendered as the identifier `"1"`).
enum JSONValue: Sendable, Equatable {
    case string(String)
    case number(String)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    /// Nesting deeper than this reads as `null` (hostile payloads cannot exhaust the drain queue's stack).
    static let maxDepth = 48

    init(foundation value: Any, depth: Int = 0) {
        guard depth < Self.maxDepth else {
            self = .null
            return
        }
        switch value {
        case let text as String:
            self = .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.stringValue)
            }
        case let array as [Any]:
            self = .array(array.map { JSONValue(foundation: $0, depth: depth + 1) })
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues { JSONValue(foundation: $0, depth: depth + 1) })
        default:
            self = .null
        }
    }

    /// Non-empty strings and numbers (rendered); `nil` for everything else.
    var stringValue: String? {
        switch self {
        case .string(let text): text.isEmpty ? nil : text
        case .number(let text): text
        default: nil
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }
}

/// Read-only view of an untrusted agent payload (a top-level JSON object). Unknown keys are ignored, values of
/// the wrong type read as absent, and nothing here ever throws: a malformed payload is an empty payload.
struct RawPayload: Sendable, Equatable {
    let fields: [String: JSONValue]

    init(fields: [String: JSONValue]) {
        self.fields = fields
    }

    /// Parses `data` as a JSON object (anything else, or more than `InboxFile.maxPayloadBytes`, → empty).
    init(data: Data) {
        guard !data.isEmpty, data.count <= InboxFile.maxPayloadBytes,
              let value = try? JSONSerialization.jsonObject(with: data, options: []),
              let dictionary = value as? [String: Any]
        else {
            self.fields = [:]
            return
        }
        self.fields = dictionary.mapValues { JSONValue(foundation: $0, depth: 1) }
    }

    var isEmpty: Bool { fields.isEmpty }

    /// True when `key` is present with a non-null value.
    func has(_ key: String) -> Bool {
        guard let value = fields[key] else { return false }
        return value != .null
    }

    /// First key whose value is a non-empty string (numbers are rendered; booleans are not strings).
    func string(_ keys: String...) -> String? { string(keys) }

    func string(_ keys: [String]) -> String? {
        for key in keys {
            if let value = fields[key]?.stringValue { return value }
        }
        return nil
    }

    /// A JSON boolean, or the strings `"true"` / `"false"`.
    func bool(_ key: String) -> Bool? {
        switch fields[key] {
        case .bool(let value): return value
        case .string(let text):
            switch text.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        default: return nil
        }
    }

    func array(_ key: String) -> [JSONValue]? {
        if case .array(let values) = fields[key] { return values }
        return nil
    }

    func object(_ key: String) -> RawPayload? {
        fields[key]?.objectValue.map(RawPayload.init(fields:))
    }

    /// Objects of an array value (other elements are skipped).
    func objects(_ key: String) -> [RawPayload] {
        (array(key) ?? []).compactMap { $0.objectValue.map(RawPayload.init(fields:)) }
    }

    /// Strings of an array value (`workspace_roots`, `workspacePaths`, …).
    func strings(_ key: String) -> [String] {
        (array(key) ?? []).compactMap(\.stringValue)
    }
}

/// Caps applied to every untrusted string before it leaves KakurenekoEvents (ARCHITECTURE §8: ≤ 1 KiB per field,
/// previews ≤ 140 characters via `TextSanitizer`).
enum FieldLimits {
    /// Per-field cap for identifiers, paths and metadata values.
    static let maxFieldBytes = 1_024
    /// `AgentEvent.metadata` holds at most this many entries.
    static let maxMetadataEntries = 16
    /// Display text is cut to this many bytes before `TextSanitizer` runs (bounds the regex work).
    static let maxSanitizerInputBytes = 16 * 1_024

    /// Trimmed, capped at `maxBytes` UTF-8 bytes on a character boundary; nil when empty.
    static func capped(_ value: String?, maxBytes: Int = maxFieldBytes) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.utf8.count > maxBytes else { return trimmed }
        var result = ""
        var used = 0
        for character in trimmed {
            let size = character.utf8.count
            if used + size > maxBytes { break }
            result.append(character)
            used += size
        }
        return result.isEmpty ? nil : result
    }

    /// Display text (previews, waiting text, errors, titles): `TextSanitizer` (ANSI strip, secret redaction,
    /// path → basename, whitespace collapse, 140-character cap). nil when nothing printable is left.
    static func sanitized(_ value: String?) -> String? {
        guard let value, let bounded = capped(value, maxBytes: maxSanitizerInputBytes) else { return nil }
        let clean = TextSanitizer.sanitize(bounded)
        return clean.isEmpty ? nil : clean
    }

    /// Caps keys/values and keeps at most `maxMetadataEntries` entries (sorted keys win, deterministic).
    static func metadata(_ values: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for key in values.keys.sorted() {
            guard result.count < maxMetadataEntries,
                  let cappedKey = capped(key, maxBytes: 128),
                  let cappedValue = capped(values[key])
            else { continue }
            result[cappedKey] = cappedValue
        }
        return result
    }
}
