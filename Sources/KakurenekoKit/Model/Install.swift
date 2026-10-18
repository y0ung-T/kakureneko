import Foundation

/// Per-agent integration status shown in onboarding/settings (brief §3.7.6 "proof of life").
public struct IntegrationStatus: Sendable, Hashable, Codable, Identifiable {
    public var agent: AgentID
    public var id: AgentID { agent }
    /// An installer exists in this build.
    public var supported: Bool
    /// The agent's config dir exists (only those get offered — never create `~/.<tool>`).
    public var configDirExists: Bool
    /// Our entries are present.
    public var installed: Bool
    /// Manifest says installed but our entry is missing/changed (the agent rewrote the file).
    public var needsRepair: Bool
    /// Codex hooks need the one-time `/hooks` trust step (detected read-only).
    public var needsTrustStep: Bool
    /// Last event received from this agent (filled by the coordinator from the event source).
    public var lastEventSeen: Date?
    /// Files we touch / own (display paths).
    public var configFiles: [String]
    /// Human notes ("Open sessions pick it up after /reload-plugins", "notify-only until trusted", …).
    public var notes: [String]

    public init(
        agent: AgentID,
        supported: Bool,
        configDirExists: Bool,
        installed: Bool = false,
        needsRepair: Bool = false,
        needsTrustStep: Bool = false,
        lastEventSeen: Date? = nil,
        configFiles: [String] = [],
        notes: [String] = []
    ) {
        self.agent = agent
        self.supported = supported
        self.configDirExists = configDirExists
        self.installed = installed
        self.needsRepair = needsRepair
        self.needsTrustStep = needsTrustStep
        self.lastEventSeen = lastEventSeen
        self.configFiles = configFiles
        self.notes = notes
    }

    /// "Installed" is not "working" until an event has arrived.
    public var isProvenWorking: Bool { installed && lastEventSeen != nil }
}

/// One file change in an install/uninstall plan.
public struct FileChange: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable { case create, modify, delete }
    /// Absolute path.
    public var path: String
    public var kind: Kind
    /// Full text before (nil for create).
    public var before: String?
    /// Full text after (nil for delete).
    public var after: String?
    /// Unified diff for the preview UI.
    public var unifiedDiff: String

    public init(path: String, kind: Kind, before: String?, after: String?, unifiedDiff: String) {
        self.path = path
        self.kind = kind
        self.before = before
        self.after = after
        self.unifiedDiff = unifiedDiff
    }
}

/// A subprocess the installer will run (e.g. `claude plugin install kakureneko@kakureneko-local --scope user --json`).
public struct PlannedCommand: Sendable, Hashable, Codable {
    public var executable: String
    public var arguments: [String]
    public var purpose: String

    public init(executable: String, arguments: [String], purpose: String) {
        self.executable = executable
        self.arguments = arguments
        self.purpose = purpose
    }

    public var displayString: String { ([executable] + arguments).joined(separator: " ") }
}

/// Diff preview shown before anything is written (brief §3.7.1).
public struct InstallPlan: Sendable, Hashable, Codable {
    public enum Operation: String, Sendable, Hashable, Codable { case install, uninstall, repair }
    public var agent: AgentID
    public var operation: Operation
    public var changes: [FileChange]
    public var commands: [PlannedCommand]
    public var warnings: [String]
    /// e.g. "Open Claude sessions pick this up after /reload-plugins or a restart."
    public var followUpNote: String?

    public init(agent: AgentID, operation: Operation, changes: [FileChange] = [], commands: [PlannedCommand] = [], warnings: [String] = [], followUpNote: String? = nil) {
        self.agent = agent
        self.operation = operation
        self.changes = changes
        self.commands = commands
        self.warnings = warnings
        self.followUpNote = followUpNote
    }

    public var isEmpty: Bool { changes.isEmpty && commands.isEmpty }
}

/// Result of applying a plan.
public struct InstallResult: Sendable, Hashable, Codable {
    public var plan: InstallPlan
    /// Backup files written (absolute paths).
    public var backups: [String]
    /// True if nothing was written because dry-run is on.
    public var dryRun: Bool
    public var messages: [String]
    public var status: IntegrationStatus

    public init(plan: InstallPlan, backups: [String] = [], dryRun: Bool = false, messages: [String] = [], status: IntegrationStatus) {
        self.plan = plan
        self.backups = backups
        self.dryRun = dryRun
        self.messages = messages
        self.status = status
    }
}

/// One manifest entry (brief §3.7.5).
public struct InstallManifestEntry: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// We spliced entries into a user file.
        case spliced
        /// We own the whole file (`~/.copilot/hooks/kakureneko.json`, opencode plugin) — uninstall deletes it.
        case ownedFile
        /// Installed through an agent CLI (Claude plugin).
        case cliPlugin
    }
    public var agent: AgentID
    /// Absolute path.
    public var file: String
    public var kind: Kind
    public var sha256Before: String?
    public var sha256After: String
    /// Original value we chained (Codex `notify`, Aider `notifications-command`), restored byte for byte.
    public var chainedOriginal: String?
    public var installedAt: Date
    public var helperVersion: String

    public init(agent: AgentID, file: String, kind: Kind, sha256Before: String?, sha256After: String, chainedOriginal: String? = nil, installedAt: Date, helperVersion: String = KakurenekoKit.marketingVersion) {
        self.agent = agent
        self.file = file
        self.kind = kind
        self.sha256Before = sha256Before
        self.sha256After = sha256After
        self.chainedOriginal = chainedOriginal
        self.installedAt = installedAt
        self.helperVersion = helperVersion
    }
}

/// `~/.kakureneko/install-manifest.json`.
public struct InstallManifest: Sendable, Hashable, Codable {
    public static let currentVersion = 1
    public var version: Int
    public var entries: [InstallManifestEntry]

    public init(version: Int = InstallManifest.currentVersion, entries: [InstallManifestEntry] = []) {
        self.version = version
        self.entries = entries
    }

    public func entries(for agent: AgentID) -> [InstallManifestEntry] { entries.filter { $0.agent == agent } }
}

/// Result of deploying the hook helper to `~/.kakureneko/bin/kakureneko-hook`.
public struct HelperDeployment: Sendable, Hashable, Codable {
    public var path: String
    public var sha256: String
    /// False when the existing copy already matched.
    public var copied: Bool

    public init(path: String, sha256: String, copied: Bool) {
        self.path = path
        self.sha256 = sha256
        self.copied = copied
    }
}
