import KakurenekoKit
import Foundation

/// Everything an installer needs to describe its files. Installers never read or write the disk themselves except
/// for existence checks through `fileSystem` (e.g. Droid's `hooks.json`-vs-`settings.json` choice).
struct InstallContext: Sendable {
    let paths: Paths
    let fileSystem: any InstallFileSystem
    /// `opencode --version` of the installed opencode (nil = unknown / not installed): opencode v1 before 1.18.29
    /// loads only the function-export plugin form (brief §3.6 G).
    var opencodeVersion: OpenCodeVersion? = nil

    /// `paths.hookBinary` as the literal absolute path written into every entry (brief C2: never `~`/`$HOME`).
    var hookPath: String { paths.hookBinary.path(percentEncoded: false) }
    var hook: HookCommand { HookCommand(hookPath: hookPath) }

    func display(_ url: URL) -> String { paths.displayPath(url) }
    func path(_ url: URL) -> String { url.path(percentEncoded: false) }
}

/// One file an installer edits or owns.
struct ManagedFile: Sendable {
    enum Role: Sendable, Equatable {
        /// Install writes our entries here.
        case target
        /// Install/uninstall only REMOVE our entries here (e.g. Droid's inactive hooks location).
        case cleanupOnly
    }

    let url: URL
    let kind: InstallManifestEntry.Kind
    let splicer: any ConfigSplicer
    let role: Role

    init(url: URL, kind: InstallManifestEntry.Kind, splicer: any ConfigSplicer, role: Role = .target) {
        self.url = url
        self.kind = kind
        self.splicer = splicer
        self.role = role
    }

    var path: String { url.path(percentEncoded: false) }
}

/// One agent's integration (brief §3.6–3.7). Implementations are pure descriptions: which files, which splice,
/// which notes. `IntegrationManager` owns every side effect (backups, atomic writes, re-parse + rollback,
/// manifest, dry-run, CLI calls).
protocol IntegrationInstaller: Sendable {
    var agent: AgentID { get }
    /// The agent's own directories. The agent is offered (and installable) only when one of them exists — the
    /// phantom-install rule: never create `~/.<tool>`.
    func configDirectories(_ context: InstallContext) -> [URL]
    /// True when the agent is set up on this Mac (default: one of `configDirectories` exists).
    func isAvailable(_ context: InstallContext) -> Bool
    /// Files this installer manages, in apply order.
    func managedFiles(_ context: InstallContext) -> [ManagedFile]
    /// Kakureneko-owned directories removed after an uninstall (the Claude plugin marketplace).
    func ownedDirectories(_ context: InstallContext) -> [URL]
    /// Short, static notes for the settings UI.
    func notes(_ context: InstallContext) -> [String]
    /// Codex: our hooks still wait for the one-time `/hooks` review (read-only check).
    func needsTrustStep(_ context: InstallContext) -> Bool
    /// Shown after install/repair ("Open Claude sessions pick this up after /reload-plugins …").
    var followUpNote: String? { get }
}

extension IntegrationInstaller {
    func isAvailable(_ context: InstallContext) -> Bool {
        configDirectories(context).contains { context.fileSystem.directoryExists($0) }
    }

    func ownedDirectories(_ context: InstallContext) -> [URL] { [] }
    func notes(_ context: InstallContext) -> [String] { [] }
    func needsTrustStep(_ context: InstallContext) -> Bool { false }
    var followUpNote: String? { nil }

    /// Display paths of the files install writes.
    func displayFiles(_ context: InstallContext) -> [String] {
        managedFiles(context).filter { $0.role == .target }.map { context.display($0.url) }
    }
}

/// Builders for the hook entries of brief §3.6 (every command contains the ownership marker).
enum HookEntries {
    /// Claude-style group: `{ "matcher"?: …, "hooks": [ { "type": "command", "command": <shell>, "timeout": n, … } ] }`.
    static func claudeStyleGroup(
        command: String,
        timeout: Int,
        matcher: String? = nil,
        name: String? = nil,
        nameFirst: Bool = false
    ) -> JSONLiteral {
        var handler: [JSONField] = []
        if let name, nameFirst { handler.append(JSONField(key: "name", value: .string(name))) }
        handler.append(JSONField(key: "type", value: .string("command")))
        handler.append(JSONField(key: "command", value: .string(command)))
        handler.append(JSONField(key: "timeout", value: .int(timeout)))
        if let name, !nameFirst { handler.append(JSONField(key: "name", value: .string(name))) }
        var group: [JSONField] = []
        if let matcher { group.append(JSONField(key: "matcher", value: .string(matcher))) }
        group.append(JSONField(key: "hooks", value: .array([.object(handler)])))
        return .compact(.object(group))
    }
}
