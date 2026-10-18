import KakurenekoKit
import Foundation

/// `~/.aider.conf.yml` (brief §3.6 H): `notifications: true` + `notifications-command`, line-oriented.
///
/// Aider runs ONE command (`subprocess.run(cmd, shell=True)`), so an existing command `X` is chained:
/// `<hook> aider waiting --chain -- /bin/sh -c 'X' 2>/dev/null; exit 0` (the hook spawns it detached, which also
/// stops a slow user command from blocking Aider's prompt). With `notifications: true` and no command Aider used
/// its own macOS notification; we chain the same `osascript` call so the local alert keeps working.
/// The original lines of both keys go to the manifest (`chainedOriginal`, a small JSON object) and uninstall
/// restores them byte for byte.
struct AiderConfigSplicer: ConfigSplicer {
    /// For error messages.
    let path: String
    let hook: HookCommand

    static let notificationsKey = "notifications"
    static let commandKey = "notifications-command"
    /// Aider's own notification on macOS when no command is configured (`aider/io.py`).
    static let defaultNotificationChain =
        "/usr/bin/osascript -e 'display notification \"Aider is waiting for your input\" with title \"Aider\"'"

    private var marker: String { KakurenekoID.ownershipMarker }

    /// The original lines of both keys (nil = the key did not exist), JSON-encoded into `chainedOriginal`.
    struct Originals: Codable, Equatable {
        var notifications: String?
        var command: String?

        enum CodingKeys: String, CodingKey {
            case notifications
            case command = "notifications-command"
        }

        var encoded: String? {
            guard let data = try? KakurenekoJSON.encode(self, pretty: false) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }

        static func decode(_ text: String?) -> Originals? {
            guard let text else { return nil }
            return try? KakurenekoJSON.decode(Originals.self, from: Data(text.utf8))
        }
    }

    /// The command we write, chaining `chain` (shell text) when given.
    func command(chaining chain: String?) -> String {
        guard let chain else { return hook.shell(.aider, "waiting") }
        return hook.shell(.aider, "waiting", chaining: chain)
    }

    func commandLine(chaining chain: String?) -> String {
        "\(Self.commandKey): " + YAMLDocument.doubleQuoted(command(chaining: chain))
    }

    static let notificationsLine = "\(notificationsKey): true"

    func install(into text: String?, previous: InstallManifestEntry?) throws -> SpliceOutcome {
        var text = text ?? ""
        var document = try parse(text)
        var originals = Originals()
        let notifications = try single(Self.notificationsKey, in: document)
        let command = try single(Self.commandKey, in: document)
        let commandValue = try command.map { try scalar(of: $0, in: document) }

        if let command, case .string(let value)? = commandValue, value.contains(marker) {
            // Ours already: keep what it chains, but with the CURRENT hook command (a moved home, a new
            // KAKURENEKO_HOME or a newer command format leaves a stale entry that runs a missing binary), and make sure
            // notifications are on. The originals come from the manifest when they agree with the chain; otherwise
            // (manifest lost or stale) they are rebuilt from the chain itself — never recorded empty.
            let notificationsLine = notifications.map { document.content(of: $0) }
            originals = Self.reconciledOriginals(previous: previous, chainedIn: value, notificationsLine: notificationsLine)
            let desired = commandLine(chaining: Self.chain(in: value))
            if document.content(of: command) != desired {
                text = document.replacingContent(of: command, with: desired)
                document = try parse(text)
            }
            if let notifications = try single(Self.notificationsKey, in: document) {
                if !YAMLDocument.isTrue(try scalar(of: notifications, in: document)) {
                    text = document.replacingContent(of: notifications, with: Self.notificationsLine)
                }
            } else if let command = try single(Self.commandKey, in: document) {
                text = document.inserting(Self.notificationsLine + document.newline, before: command)
            }
            _ = try parse(text)
            return SpliceOutcome(text: text, chainedOriginal: originals.encoded)
        }

        // What the user's setup did before us. A command only runs while `notifications: true` (R03 §8(c)): a
        // DORMANT one (notifications off) is kept in the manifest and restored on uninstall, never chained — chaining
        // it would start running it on every bell.
        let wasOn = try notifications.map { YAMLDocument.isTrue(try scalar(of: $0, in: document)) } ?? false
        var chain: String?
        if case .string(let existing)? = commandValue, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if wasOn { chain = "/bin/sh -c " + ShellQuote.quote(existing) }
        } else if commandValue == .collection {
            throw InstallError.unexpectedStructure(path: path, reason: "\"\(Self.commandKey)\" is not a string")
        } else if wasOn {
            chain = Self.defaultNotificationChain
        }
        originals.command = command.map { document.content(of: $0) }
        originals.notifications = notifications.map { document.content(of: $0) }

        // 1. notifications: true
        if let notifications {
            if !wasOn { text = document.replacingContent(of: notifications, with: Self.notificationsLine) }
        } else {
            text = document.appending(Self.notificationsLine)
        }
        document = try parse(text)
        // 2. notifications-command
        if let command = try single(Self.commandKey, in: document) {
            text = document.replacingContent(of: command, with: commandLine(chaining: chain))
        } else if let notifications = try single(Self.notificationsKey, in: document) {
            text = document.inserting(commandLine(chaining: chain), after: notifications)
        } else {
            text = document.appending(commandLine(chaining: chain))
        }
        _ = try parse(text)
        return SpliceOutcome(text: text, chainedOriginal: originals.encoded)
    }

    func uninstall(from text: String, previous: InstallManifestEntry?) throws -> String? {
        var text = text
        var document = try parse(text)
        guard let command = try single(Self.commandKey, in: document),
              case .string(let value) = try scalar(of: command, in: document), value.contains(marker) else { return text }

        if let previous {
            // The manifest's originals, unless they disagree with what our command chains (manifest rebuilt empty
            // after a loss, or the user edited the chained part since): the chain is the truth then.
            let notificationsLine = try single(Self.notificationsKey, in: document).map { document.content(of: $0) }
            let originals = Self.reconciledOriginals(previous: previous, chainedIn: value, notificationsLine: notificationsLine)
            // 1. notifications-command
            if let original = originals.command {
                text = document.replacingContent(of: command, with: original)
            } else {
                text = document.removing(command)
            }
            document = try parse(text)
            // 2. notifications (only while it is still the value we set)
            if let notifications = try single(Self.notificationsKey, in: document),
               YAMLDocument.isTrue(try scalar(of: notifications, in: document)) {
                if let original = originals.notifications {
                    if document.content(of: notifications) != original {
                        text = document.replacingContent(of: notifications, with: original)
                    }
                } else {
                    text = document.removing(notifications)
                }
            }
        } else if let chained = Self.userCommand(chainedIn: value) {
            // No manifest: restore the chained command from our own argv.
            text = document.replacingContent(of: command, with: "\(Self.commandKey): " + YAMLDocument.doubleQuoted(chained))
        } else {
            text = document.removing(command)
        }
        _ = try parse(text)
        if createdByUs(previous), text.allSatisfy(\.isWhitespace) { return nil }
        return text
    }

    func containsOurs(_ text: String) -> Bool {
        guard let document = try? YAMLDocument(text) else { return false }
        for entry in document.entries(named: Self.commandKey) {
            if case .string(let value)? = try? document.scalar(of: entry), value.contains(marker) { return true }
        }
        return false
    }

    func validate(_ text: String) throws {
        let document = try parse(text)
        for entry in document.entries {
            _ = try scalar(of: entry, in: document)
        }
    }

    /// What our command chains: `/bin/sh -c 'X'` for a user command, the osascript default, or nothing.
    static func chain(in command: String) -> String? {
        if let user = userCommand(chainedIn: command) { return "/bin/sh -c " + ShellQuote.quote(user) }
        if command.contains("--chain -- " + defaultNotificationChain) { return defaultNotificationChain }
        return nil
    }

    /// The originals to restore for an entry of ours whose command is `value`: the manifest's when they are
    /// consistent with the chain, else rebuilt from the chain (a chained command `X` was the user's
    /// `notifications-command: "X"` with notifications on; the osascript default means notifications were on
    /// without a command; no chain means no command was in effect).
    static func reconciledOriginals(previous: InstallManifestEntry?, chainedIn value: String,
                                    notificationsLine: String?) -> Originals {
        let user = userCommand(chainedIn: value)
        let defaultChained = value.contains("--chain -- " + defaultNotificationChain)
        if let decoded = Originals.decode(previous?.chainedOriginal) {
            let decodedValue = commandValue(ofLine: decoded.command)
            if let user {
                if decodedValue == user { return decoded }
            } else if defaultChained {
                if decoded.command == nil || decodedValue?.isEmpty == true { return decoded }
            } else if decoded.command == nil || !(decoded.notifications.map(Self.isTrueLine) ?? false) {
                return decoded // hook only: no command ran before (a dormant one is kept in the manifest)
            }
        }
        var rebuilt = Originals()
        if let user {
            rebuilt.command = "\(commandKey): " + YAMLDocument.doubleQuoted(user)
            rebuilt.notifications = notificationsLine ?? Self.notificationsLine
        } else if defaultChained {
            rebuilt.notifications = notificationsLine ?? Self.notificationsLine
        }
        return rebuilt
    }

    /// The string value of a `notifications-command: …` line (nil when absent or not a string).
    static func commandValue(ofLine line: String?) -> String? {
        guard let line, let document = try? YAMLDocument(line + "\n"),
              let entry = document.entries(named: commandKey).first,
              case .string(let value)? = try? document.scalar(of: entry) else { return nil }
        return value
    }

    static func isTrueLine(_ line: String) -> Bool {
        guard let document = try? YAMLDocument(line + "\n"), let entry = document.entries(named: notificationsKey).first,
              let scalar = try? document.scalar(of: entry) else { return false }
        return YAMLDocument.isTrue(scalar)
    }

    /// `X` from `… --chain -- /bin/sh -c 'X' 2>/dev/null; exit 0` (nil for the osascript default or no chain).
    static func userCommand(chainedIn command: String) -> String? {
        let prefix = "--chain -- /bin/sh -c '"
        guard let start = command.range(of: prefix), command.hasSuffix("'" + HookCommand.shellSuffix) else { return nil }
        let quoted = command[start.upperBound..<command.index(command.endIndex, offsetBy: -(HookCommand.shellSuffix.count + 1))]
        return quoted.replacingOccurrences(of: "'\\''", with: "'")
    }

    // MARK: - Helpers

    private func parse(_ text: String) throws -> YAMLDocument {
        do {
            return try YAMLDocument(text)
        } catch {
            throw InstallError.unparseable(path: path, reason: error.description)
        }
    }

    private func scalar(of entry: YAMLDocument.Entry, in document: YAMLDocument) throws -> YAMLDocument.Scalar {
        do {
            return try document.scalar(of: entry)
        } catch {
            throw InstallError.unparseable(path: path, reason: error.description)
        }
    }

    private func single(_ key: String, in document: YAMLDocument) throws -> YAMLDocument.Entry? {
        let found = document.entries(named: key)
        guard found.count <= 1 else {
            throw InstallError.unexpectedStructure(path: path, reason: "\"\(key)\" appears more than once")
        }
        return found.first
    }
}

extension YAMLDocument {
    /// Inserts `text` (with its own terminator) right before `entry`.
    func inserting(_ text: String, before entry: Entry) -> String {
        var updated = bytes
        updated.replaceSubrange(entry.start..<entry.start, with: Array(text.utf8))
        return String(decoding: updated, as: UTF8.self)
    }
}
