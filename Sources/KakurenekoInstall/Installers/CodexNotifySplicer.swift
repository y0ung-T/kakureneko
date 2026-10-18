import KakurenekoKit
import Foundation

/// Codex `notify` in `config.toml` (brief §3.6 B1, C8): a top-level key placed before the first `[table]`.
///
/// `notify` is ONE argv array, so an existing value is chained: `["X", "a"]` becomes
/// `[hook, "codex", "notify", "--chain", "--", "X", "a"]` (the hook re-runs it with the JSON payload appended).
/// The original statement text — comments, quoting, line breaks — goes to the manifest as `chainedOriginal`
/// and uninstall puts it back byte for byte. Everything else in the file is untouched (line-oriented splice).
struct CodexNotifySplicer: ConfigSplicer {
    /// For error messages.
    let path: String
    let hookPath: String

    static let key = "notify"

    private var marker: String { KakurenekoID.ownershipMarker }

    /// `[hook, "codex", "notify"]` + optional chain.
    func argv(chaining original: [String]) -> [String] {
        let base = [hookPath, AgentID.codex.rawValue, "notify"]
        return original.isEmpty ? base : base + ["--chain", "--"] + original
    }

    /// `notify = [...]`
    func statement(chaining original: [String]) -> String {
        "\(Self.key) = " + TOMLDocument.stringArray(argv(chaining: original))
    }

    /// The argv our entry chains (`[]` when it chains nothing).
    static func chainedArgv(of argv: [String]) -> [String] {
        guard let chain = argv.firstIndex(of: "--chain"), chain + 1 < argv.count, argv[chain + 1] == "--" else { return [] }
        return Array(argv[(chain + 2)...])
    }

    func install(into text: String?, previous: InstallManifestEntry?) throws -> SpliceOutcome {
        let text = text ?? ""
        let document = try parse(text)
        guard let existing = document.rootKeyValue(Self.key) else {
            let lastRootValue = document.rootStatements.last { if case .keyValue = $0.kind { true } else { false } }
            return SpliceOutcome(text: document.inserting(statement(chaining: []), after: lastRootValue))
        }
        let current = try notifyArgv(existing)
        if current.contains(where: { $0.contains(marker) }) {
            // Ours already (possibly stale): keep whatever it chains.
            let chained = Self.chainedArgv(of: current)
            let original = originalText(chaining: chained, previous: previous)
            let desired = statement(chaining: chained)
            if document.content(of: existing) == desired { return SpliceOutcome(text: text, chainedOriginal: original) }
            return SpliceOutcome(text: document.replacingContent(of: existing, with: desired), chainedOriginal: original)
        }
        let original = document.content(of: existing)
        return SpliceOutcome(
            text: document.replacingContent(of: existing, with: statement(chaining: current)),
            chainedOriginal: original
        )
    }

    func uninstall(from text: String, previous: InstallManifestEntry?) throws -> String? {
        let document = try parse(text)
        guard let existing = document.rootKeyValue(Self.key) else { return text }
        let current = try notifyArgv(existing)
        guard current.contains(where: { $0.contains(marker) }) else { return text }
        let restored: String
        if let original = originalText(chaining: Self.chainedArgv(of: current), previous: previous) {
            restored = document.replacingContent(of: existing, with: original)
        } else {
            restored = document.removing(existing)
        }
        if createdByUs(previous), restored.allSatisfy(\.isWhitespace) { return nil }
        return restored
    }

    func containsOurs(_ text: String) -> Bool {
        guard let document = try? TOMLDocument(text), let existing = document.rootKeyValue(Self.key) else { return false }
        guard case .keyValue(_, let value) = existing.kind, let argv = value.stringArray else {
            return document.content(of: existing).contains(marker)
        }
        return argv.contains { $0.contains(marker) }
    }

    func validate(_ text: String) throws {
        _ = try parse(text)
    }

    // MARK: - Helpers

    private func parse(_ text: String) throws -> TOMLDocument {
        do {
            return try TOMLDocument(text)
        } catch {
            throw InstallError.unparseable(path: path, reason: error.description)
        }
    }

    private func notifyArgv(_ statement: TOMLDocument.Statement) throws -> [String] {
        guard case .keyValue(_, let value) = statement.kind, let argv = value.stringArray else {
            throw InstallError.unexpectedStructure(path: path, reason: "\"notify\" is not an array of strings")
        }
        return argv
    }

    /// The original statement to restore for an entry of ours that chains `chained`: the manifest's exact text when
    /// it still describes the same argv, else a statement rebuilt from the argv (manifest lost), else nil (we
    /// chained nothing — uninstall removes the line).
    private func originalText(chaining chained: [String], previous: InstallManifestEntry?) -> String? {
        if let saved = previous?.chainedOriginal,
           let document = try? TOMLDocument(saved),
           let statement = document.rootKeyValue(Self.key),
           case .keyValue(_, let value) = statement.kind,
           value.stringArray == chained {
            return saved
        }
        return chained.isEmpty ? nil : "\(Self.key) = " + TOMLDocument.stringArray(chained)
    }
}

/// Read-only detection of the one-time Codex hook trust step (brief §3.3: "Detect trust read-only by checking
/// for `[hooks.state."…"]` in config.toml"; never forge `trusted_hash`).
///
/// Codex records an approval as `[hooks.state."<source>:<event>:<group>:<handler>"] trusted_hash = "…"`. Our
/// handlers count as trusted when, for every event we installed, some state key names that event (compared
/// case-insensitively without `_`/`-`) and — when the key ends in numeric indices — the group/handler position
/// of our entry in `hooks.json`.
enum CodexTrust {
    struct Handler: Equatable {
        var event: String
        var group: Int
        var handler: Int
    }

    /// Positions of our handlers in a `hooks.json` text.
    static func ourHandlers(inHooksJSON text: String) -> [Handler] {
        guard let editor = try? JSONEditor(text: text, dialect: .strict, path: "hooks.json"),
              let events = editor.node(at: ["hooks"])?.members else { return [] }
        var result: [Handler] = []
        for event in events {
            guard let groups = event.value.elements else { continue }
            for (g, group) in groups.enumerated() {
                guard let handlers = group.member("hooks")?.value.elements else { continue }
                for (h, handler) in handlers.enumerated() where editor.contains(KakurenekoID.ownershipMarker, in: handler) {
                    result.append(Handler(event: event.key, group: g, handler: h))
                }
            }
        }
        return result
    }

    /// The `hooks.state` keys that carry an approval in `config.toml`.
    static func trustedStateKeys(inConfig text: String) -> [String] {
        guard let document = try? TOMLDocument(text) else { return [] }
        var keys: [String] = []
        for (path, value) in document.resolvedKeyValues where path.count >= 3 && path[0] == "hooks" && path[1] == "state" {
            if path.count == 4, path[3] == "trusted_hash" {
                keys.append(path[2])
            } else if path.count == 3, value == .inlineTable {
                keys.append(path[2])
            }
        }
        return keys
    }

    /// True when every handler in `handlers` has a matching approval key.
    static func isTrusted(_ handlers: [Handler], stateKeys: [String]) -> Bool {
        handlers.allSatisfy { handler in stateKeys.contains { matches($0, handler) } }
    }

    static func matches(_ key: String, _ handler: Handler) -> Bool {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let event = normalize(handler.event)
        if parts.count >= 3, let group = Int(parts[parts.count - 2]), let index = Int(parts[parts.count - 1]) {
            return normalize(parts[parts.count - 3]) == event && group == handler.group && index == handler.handler
        }
        // Unknown key layout: accept any key that names the event.
        return parts.contains { normalize($0) == event }
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0 != "_" && $0 != "-" }
    }
}
