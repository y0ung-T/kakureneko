import Darwin

/// Parsed argv: `kakureneko-hook <agent> <event> [--chain -- <argv…>] [<payload JSON>]`.
///
/// * The trailing JSON object (Codex `notify` appends exactly one argv) is the payload and is never part of the
///   chained argv.
/// * Labels are restricted to `[A-Za-z0-9._-]` (first character alphanumeric, ≤ 64 bytes) because they become
///   path components of recordings; anything else means "bad arguments" → exit 0 without a file.
struct HookInvocation {
    let agent: String
    let event: String
    /// Chained argv (`--chain -- <argv…>`), without the trailing payload. Empty = nothing to chain.
    let chain: [String]
    /// The trailing JSON-object argv, if any.
    let argvPayload: [UInt8]?
    /// The complete argv (for `KAKURENEKO_RECORD`).
    let arguments: [String]

    init?(arguments: [String]) {
        guard arguments.count >= 3 else { return nil }
        self.arguments = arguments
        agent = arguments[1]
        event = arguments[2]
        var rest = Array(arguments.dropFirst(3))
        if let last = rest.last, Self.looksLikeJSONObject(last) {
            argvPayload = Array(last.utf8)
            rest.removeLast()
        } else {
            argvPayload = nil
        }
        if let marker = rest.firstIndex(of: "--chain") {
            var chained = Array(rest[(marker + 1)...])
            if chained.first == "--" { chained.removeFirst() }
            chain = chained
        } else {
            chain = []
        }
    }

    var hasValidLabels: Bool { Self.isValidLabel(agent) && Self.isValidLabel(event) }

    static func isValidLabel(_ label: String) -> Bool {
        let bytes = Array(label.utf8)
        guard let first = bytes.first, bytes.count <= HookConstants.maxLabelBytes, isAlphanumeric(first) else {
            return false
        }
        return bytes.allSatisfy { isAlphanumeric($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
    }

    /// First non-whitespace byte `{` and last non-whitespace byte `}`.
    static func looksLikeJSONObject(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        let isSpace: (UInt8) -> Bool = { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
        guard let first = bytes.first(where: { !isSpace($0) }), let last = bytes.last(where: { !isSpace($0) }) else {
            return false
        }
        return first == UInt8(ascii: "{") && last == UInt8(ascii: "}")
    }
}
