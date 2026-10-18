import KakurenekoKit
import Foundation

/// The result of splicing Kakureneko's entries into a config text.
struct SpliceOutcome: Sendable, Equatable {
    /// The complete desired file text.
    var text: String
    /// The user's value that our entry now chains (Codex `notify`, Aider `notifications-command`), kept in the
    /// install manifest so uninstall can restore it byte for byte.
    var chainedOriginal: String?
}

/// Pure, format-preserving text transforms for one config file (brief §3.7.3). A splicer never touches the disk:
/// `IntegrationManager` reads, backs up, writes, re-parses and rolls back.
///
/// Rules every implementation keeps:
/// * `install` leaves a text that already holds exactly our entries unchanged (idempotent re-install) and
///   otherwise replaces stale entries of ours instead of duplicating them;
/// * `uninstall` removes only entries containing `KakurenekoID.ownershipMarker`, restores chained originals, and
///   is the textual inverse of `install` for an untouched file;
/// * neither re-serializes the user's document.
protocol ConfigSplicer: Sendable {
    /// Desired text after installing our entries into `text` (`nil` = the file does not exist yet).
    /// - Parameter previous: this file's manifest entry from an earlier install (chained originals live there).
    func install(into text: String?, previous: InstallManifestEntry?) throws -> SpliceOutcome
    /// Text after removing our entries; `nil` = delete the file (we own it, or we created it and nothing of the
    /// user's is left).
    func uninstall(from text: String, previous: InstallManifestEntry?) throws -> String?
    /// True when `text` holds any entry of ours.
    func containsOurs(_ text: String) -> Bool
    /// The re-parse check run on the bytes read back after writing. Throws when the text would not load.
    func validate(_ text: String) throws
}

extension ConfigSplicer {
    /// True when `previous` proves Kakureneko created the file (no content existed before the first install).
    func createdByUs(_ previous: InstallManifestEntry?) -> Bool {
        guard let previous else { return false }
        return previous.sha256Before == nil
    }
}

/// A whole file Kakureneko owns (`~/.copilot/hooks/kakureneko.json`, the opencode plugin, the Claude plugin files).
/// Uninstall deletes it.
struct OwnedFileSplicer: ConfigSplicer {
    enum Validation: Sendable {
        case json
        case text
    }

    /// For error messages.
    let path: String
    let content: String
    let validation: Validation
    /// True when the location itself is Kakureneko's (inside `~/.kakureneko`); otherwise an existing file counts as
    /// ours only when it contains the ownership marker.
    let locationIsOwned: Bool

    func install(into text: String?, previous: InstallManifestEntry?) throws -> SpliceOutcome {
        if let text, !locationIsOwned, !containsOurs(text),
           !text.allSatisfy({ $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r\n" }) {
            throw InstallError.conflict(path: path, reason: "a file Kakureneko did not write already exists here")
        }
        return SpliceOutcome(text: content)
    }

    func uninstall(from text: String, previous: InstallManifestEntry?) throws -> String? { nil }

    func containsOurs(_ text: String) -> Bool {
        locationIsOwned || text.contains(KakurenekoID.ownershipMarker)
    }

    func validate(_ text: String) throws {
        switch validation {
        case .json:
            do {
                _ = try JSONSyntax.parse(text, dialect: .strict)
            } catch {
                throw InstallError.unparseable(path: path, reason: error.description)
            }
        case .text:
            break
        }
    }
}

/// Splices hook entries into one container object of a JSON/JSONC document (`hooks` of Gemini/Qwen/Cursor/…,
/// the top level of Droid's `hooks.json`, agy's `"kakureneko"` key).
struct JSONHookSplicer: ConfigSplicer {
    /// For error messages.
    let path: String
    let dialect: JSONSyntax.Dialect
    /// Keys from the document root to the object keyed by event name (`["hooks"]`, `[]`, `["kakureneko"]`).
    let containerKeys: [String]
    /// Our entries, in snippet order.
    let events: [HookEventEntries]
    /// Top-level members (before the hooks container) of a document we create, e.g. `"version": 1` for Cursor or
    /// `"description"` for Codex.
    let preamble: [JSONField]

    init(path: String, dialect: JSONSyntax.Dialect, containerKeys: [String], events: [HookEventEntries], preamble: [JSONField] = []) {
        self.path = path
        self.dialect = dialect
        self.containerKeys = containerKeys
        self.events = events
        self.preamble = preamble
    }

    private var marker: String { KakurenekoID.ownershipMarker }

    /// Number of handlers we install (each event entry carries one).
    private var handlerCount: Int { events.reduce(0) { $0 + $1.entries.count } }

    /// The document we write when the file does not exist (or is blank).
    var newDocument: JSONLiteral {
        var container = JSONLiteral.object(events.map { JSONField(key: $0.event, value: .array($0.entries)) })
        for key in containerKeys.reversed() { container = .object([JSONField(key: key, value: container)]) }
        guard case .object(let fields) = container else { return container }
        return .object(preamble + fields)
    }

    /// What a document we created looks like once our entries are gone.
    private var emptyDocumentValue: JSONValue { JSONLiteral.object(preamble).value }

    func install(into text: String?, previous: InstallManifestEntry?) throws -> SpliceOutcome {
        guard let text, !JSONSyntax.isBlank(Array(text.utf8)) else {
            return SpliceOutcome(text: JSONRenderer().renderDocument(newDocument))
        }
        var editor = try JSONEditor(text: text, dialect: dialect, path: path)
        guard editor.root.members != nil else {
            throw InstallError.unexpectedStructure(path: path, reason: "the top level is not an object")
        }
        if isComplete(editor) { return SpliceOutcome(text: text) }
        try editor.removeMarkedEntries(marker, containerKeys: containerKeys)
        try editor.appendHookEntries(events, containerKeys: containerKeys)
        return SpliceOutcome(text: editor.text)
    }

    func uninstall(from text: String, previous: InstallManifestEntry?) throws -> String? {
        var editor = try JSONEditor(text: text, dialect: dialect, path: path)
        try editor.removeMarkedEntries(marker, containerKeys: containerKeys)
        if createdByUs(previous), editor.root.value == emptyDocumentValue { return nil }
        return editor.text
    }

    func containsOurs(_ text: String) -> Bool {
        guard let editor = try? JSONEditor(text: text, dialect: dialect, path: path) else {
            return text.contains(marker)
        }
        guard let container = editor.node(at: containerKeys) else { return false }
        return editor.contains(marker, in: container)
    }

    func validate(_ text: String) throws {
        do {
            _ = try JSONSyntax.parse(text, dialect: dialect)
        } catch {
            throw InstallError.unparseable(path: path, reason: error.description)
        }
    }

    /// Every entry of ours is present exactly once and nothing stale of ours is left.
    func isComplete(_ editor: JSONEditor) -> Bool {
        editor.containsAll(events, in: containerKeys) && editor.markedEntryCount(marker, in: containerKeys) == handlerCount
    }
}
