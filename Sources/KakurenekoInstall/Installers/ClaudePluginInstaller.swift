import KakurenekoKit
import Foundation

/// Claude Code (brief §3.6 A, C3/C4/C5; R02 §2): a local plugin marketplace under `~/.kakureneko/claude-plugin`
/// installed with the `claude` CLI — never a `~/.claude/settings.json` edit (Cursor, Devin, Grok, Continue and
/// VS Code also load hooks from that file and would fire ours with the wrong attribution).
///
/// Hooks are exec form (`command` = the hook path, `args` = [agent, event]), synchronous, `timeout` 5 (SessionEnd
/// 1, its budget is 1.5 s anyway); never `async`/`asyncRewake`/`onFailure`, never `PermissionRequest`.
struct ClaudePluginInstaller: IntegrationInstaller {
    let agent = AgentID.claude

    /// Every `notification_type` we listen to (brief snippet A; R02 §1.4).
    static let notificationMatcher = [
        "permission_prompt", "idle_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input",
        "agent_completed", "quota_auto_resume_fired", "quota_auto_resume_stale", "quota_auto_resume_disabled",
    ].joined(separator: "|")

    /// `(event, timeout, matcher)` in snippet order.
    static let events: [(name: String, timeout: Int, matcher: String?)] = [
        ("SessionStart", 5, nil),
        ("UserPromptSubmit", 5, nil),
        ("Stop", 5, nil),
        ("StopFailure", 5, nil),
        ("Notification", 5, notificationMatcher),
        ("SessionEnd", 1, nil),
    ]

    static let followUp = "Open Claude Code sessions pick this up after /reload-plugins or a restart."

    // MARK: Layout

    func root(_ context: InstallContext) -> URL { context.paths.claudePluginDirectory }
    func marketplaceFile(_ context: InstallContext) -> URL {
        root(context).appending(path: ".claude-plugin/marketplace.json", directoryHint: .notDirectory)
    }
    func pluginDirectory(_ context: InstallContext) -> URL {
        root(context).appending(path: "plugins/\(KakurenekoID.claudePluginName)", directoryHint: .isDirectory)
    }
    func pluginFile(_ context: InstallContext) -> URL {
        pluginDirectory(context).appending(path: ".claude-plugin/plugin.json", directoryHint: .notDirectory)
    }
    func hooksFile(_ context: InstallContext) -> URL {
        pluginDirectory(context).appending(path: "hooks/hooks.json", directoryHint: .notDirectory)
    }

    // MARK: IntegrationInstaller

    func configDirectories(_ context: InstallContext) -> [URL] { [context.paths.claudeConfigDirectory] }

    func managedFiles(_ context: InstallContext) -> [ManagedFile] {
        [
            owned(marketplaceFile(context), marketplaceDocument, context),
            owned(pluginFile(context), pluginDocument, context),
            owned(hooksFile(context), hooksDocument(context), context),
        ]
    }

    func ownedDirectories(_ context: InstallContext) -> [URL] { [root(context)] }

    func notes(_ context: InstallContext) -> [String] {
        var notes = ["Installed as the Claude Code plugin \(KakurenekoID.claudePluginReference). \(Self.followUp)"]
        let settings = context.paths.claudeConfigDirectory.appending(path: "settings.json", directoryHint: .notDirectory)
        if let off = HooksSwitch.note(settings, rules: [HooksSwitch.disableAllHooks, HooksSwitch.allowManagedHooksOnly], context: context) {
            notes.append(off)
        }
        return notes
    }

    var followUpNote: String? { Self.followUp }

    private func owned(_ url: URL, _ document: JSONLiteral, _ context: InstallContext) -> ManagedFile {
        ManagedFile(
            url: url,
            kind: .cliPlugin,
            splicer: OwnedFileSplicer(
                path: context.path(url),
                content: JSONRenderer().renderDocument(document),
                validation: .json,
                locationIsOwned: true
            )
        )
    }

    // MARK: Documents (snippet A, renamed)

    var marketplaceDocument: JSONLiteral {
        .fields([
            "name": .string(KakurenekoID.claudeMarketplaceName),
            "owner": .compact(.fields(["name": .string(KakurenekoID.appName)])),
            "description": .string("Local marketplace installed by the Kakureneko menu-bar app"),
            "plugins": .array([
                .fields([
                    "name": .string(KakurenekoID.claudePluginName),
                    "source": .string("./plugins/\(KakurenekoID.claudePluginName)"),
                    "description": .string("Reports agent activity to Kakureneko. Never blocks Claude."),
                ]),
            ]),
        ])
    }

    var pluginDocument: JSONLiteral {
        .fields([
            "name": .string(KakurenekoID.claudePluginName),
            "version": .string("1.0.0"),
            "description": .string("Notifies the Kakureneko menu-bar app about session start/stop/needs-input. Never blocks."),
            "author": .compact(.fields(["name": .string(KakurenekoID.appName)])),
        ])
    }

    func hooksDocument(_ context: InstallContext) -> JSONLiteral {
        let hooks = Self.events.map { event -> JSONField in
            let handler: [JSONField] = [
                JSONField(key: "type", value: .string("command")),
                JSONField(key: "command", value: .string(context.hookPath)),
                JSONField(key: "args", value: .array([.string(agent.rawValue), .string(event.name)])),
                JSONField(key: "timeout", value: .int(event.timeout)),
            ]
            var group: [JSONField] = []
            if let matcher = event.matcher { group.append(JSONField(key: "matcher", value: .string(matcher))) }
            group.append(JSONField(key: "hooks", value: .array([.object(handler)])))
            return JSONField(key: event.name, value: .array([.compact(.object(group))]))
        }
        return .fields([
            "description": .string("Kakureneko activity reporter (always exit 0, no stdout)"),
            "hooks": .object(hooks),
        ])
    }

    // MARK: CLI (brief §3.6 A; R02 §2)

    struct Command: Sendable, Equatable {
        var arguments: [String]
        var purpose: String
        var effect: SideEffectKind
        /// Lower-cased substrings of a non-zero exit's output that still mean "done" (idempotent re-runs).
        var benignFailures: [String]
    }

    func marketplaceAdd(_ context: InstallContext) -> Command {
        Command(
            arguments: ["plugin", "marketplace", "add", context.path(root(context)).trimmingTrailingSlashForCLI, "--scope", "user", "--json"],
            purpose: "Register the local Kakureneko marketplace with Claude Code",
            effect: .mutating,
            benignFailures: ["already"]
        )
    }

    var pluginInstall: Command {
        Command(
            arguments: ["plugin", "install", KakurenekoID.claudePluginReference, "--scope", "user", "--json"],
            purpose: "Install the Kakureneko plugin",
            effect: .mutating,
            benignFailures: ["already installed"]
        )
    }

    var pluginEnable: Command {
        Command(
            arguments: ["plugin", "enable", KakurenekoID.claudePluginReference, "--scope", "user"],
            purpose: "Re-enable the Kakureneko plugin",
            effect: .mutating,
            benignFailures: ["already enabled"]
        )
    }

    var pluginUninstall: Command {
        Command(
            arguments: ["plugin", "uninstall", KakurenekoID.claudePluginReference, "--scope", "user", "--json"],
            purpose: "Uninstall the Kakureneko plugin",
            effect: .mutating,
            benignFailures: ["not installed", "not found", "no plugin", "does not exist", "unknown plugin"]
        )
    }

    var marketplaceRemove: Command {
        Command(
            arguments: ["plugin", "marketplace", "remove", KakurenekoID.claudeMarketplaceName, "--json"],
            purpose: "Remove the local Kakureneko marketplace",
            effect: .mutating,
            benignFailures: ["not found", "no marketplace", "does not exist", "unknown marketplace", "not configured"]
        )
    }

    var pluginList: Command {
        Command(arguments: ["plugin", "list", "--json"], purpose: "Verify the plugin is installed and enabled", effect: .readOnly, benignFailures: [])
    }
}

extension String {
    /// `"/a/b/"` → `"/a/b"` for CLI arguments.
    var trimmingTrailingSlashForCLI: String {
        guard count > 1, hasSuffix("/") else { return self }
        return String(dropLast())
    }
}

/// What `claude plugin list --json` says about `kakureneko@kakureneko-local`.
enum ClaudePluginState: Sendable, Equatable {
    case enabled
    case disabled
    case absent
    /// The CLI failed or printed something we cannot read.
    case unknown

    /// Parses the CLI result leniently: `--json` prints one JSON value on the last stdout line (R02 §2); its exact
    /// shape is not documented, so any object naming our plugin (`"kakureneko@kakureneko-local"`, or name `kakureneko` +
    /// marketplace `kakureneko-local`) counts, with its `enabled` flag when present.
    static func parse(_ result: SubprocessResult) -> ClaudePluginState {
        guard result.succeeded else { return .unknown }
        let stdout = result.stdoutString
        let candidates = [stdout] + stdout.split(whereSeparator: \.isNewline).reversed().map(String.init)
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
                  let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed]) else { continue }
            if let enabled = find(in: json) { return enabled ? .enabled : .disabled }
            return .absent
        }
        return stdout.contains(KakurenekoID.claudePluginReference) ? .enabled : .unknown
    }

    /// `enabled` of the first object describing our plugin, or nil when none does.
    private static func find(in json: Any, depth: Int = 0) -> Bool? {
        guard depth < 16 else { return nil }
        if let array = json as? [Any] {
            for item in array { if let found = find(in: item, depth: depth + 1) { return found } }
            return nil
        }
        guard let object = json as? [String: Any] else { return nil }
        if describesOurPlugin(object) { return (object["enabled"] as? Bool) ?? (object["isEnabled"] as? Bool) ?? true }
        if let nested = object[KakurenekoID.claudePluginReference] {
            if let flag = nested as? Bool { return flag }
            if let inner = nested as? [String: Any] { return (inner["enabled"] as? Bool) ?? (inner["isEnabled"] as? Bool) ?? true }
            return true
        }
        for value in object.values {
            if let found = find(in: value, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func describesOurPlugin(_ object: [String: Any]) -> Bool {
        let reference = KakurenekoID.claudePluginReference
        for key in ["id", "name", "plugin", "pluginId", "fullName", "reference"] where (object[key] as? String) == reference {
            return true
        }
        let name = object["name"] as? String
        let marketplace = (object["marketplace"] as? String) ?? (object["marketplaceName"] as? String)
        return name == KakurenekoID.claudePluginName && marketplace == KakurenekoID.claudeMarketplaceName
    }
}
