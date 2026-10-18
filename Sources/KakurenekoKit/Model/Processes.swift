import Foundation

/// Race-free process identity (pid reuse is real: the pid space wraps every 2–6 h, brief §1.7).
///
/// Equality and hashing use **(pid, startSec, startUsec) only**; `uniqueID` (`p_uniqueid`, flavor 17)
/// and `pidVersion` (audit token `val[7]`) are optional enrichments for signalling and the journal.
public struct ProcessIdentity: Sendable, Codable, CustomStringConvertible {
    public var pid: Int32
    /// `p_starttime.tv_sec`
    public var startSec: Int64
    /// `p_starttime.tv_usec`
    public var startUsec: Int32
    /// `p_uniqueid`, never reused within a boot (optional).
    public var uniqueID: UInt64?
    /// `p_idversion` = audit token `val[7]` (optional; required before any signal).
    public var pidVersion: UInt32?

    public init(pid: Int32, startSec: Int64, startUsec: Int32, uniqueID: UInt64? = nil, pidVersion: UInt32? = nil) {
        self.pid = pid
        self.startSec = startSec
        self.startUsec = startUsec
        self.uniqueID = uniqueID
        self.pidVersion = pidVersion
    }

    /// Fallback session id used when an agent gives none (brief §5.1): `pid:<pid>:<startSec>.<usec>`.
    public var fallbackSessionID: String { "pid:\(pid):\(startSec).\(startUsec)" }

    /// Start time as `Date`.
    public var startDate: Date { Date(timeIntervalSince1970: TimeInterval(startSec) + TimeInterval(startUsec) / 1_000_000) }

    public var description: String { "\(pid)@\(startSec).\(startUsec)" }
}

extension ProcessIdentity: Hashable {
    public static func == (lhs: ProcessIdentity, rhs: ProcessIdentity) -> Bool {
        lhs.pid == rhs.pid && lhs.startSec == rhs.startSec && lhs.startUsec == rhs.startUsec
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(startSec)
        hasher.combine(startUsec)
    }
}

/// A process in an agent's ancestor chain (scanner view; richer than `InboxAncestor`).
public struct AncestorInfo: Sendable, Hashable, Codable {
    public var identity: ProcessIdentity
    /// `p_comm`
    public var comm: String?
    /// `proc_pidpath` (nil for other users' processes or replaced binaries).
    public var executablePath: String?
    /// Bundle identifier when this ancestor is the main executable of an app bundle.
    public var bundleID: String?
    /// True when the process is a GUI app's main process (e.g. Terminal, VS Code main).
    public var isApp: Bool

    public init(identity: ProcessIdentity, comm: String? = nil, executablePath: String? = nil, bundleID: String? = nil, isApp: Bool = false) {
        self.identity = identity
        self.comm = comm
        self.executablePath = executablePath
        self.bundleID = bundleID
        self.isApp = isApp
    }
}

/// Input to signature matching (brief §5.3: match on exe path + argv[0]/argv[1] basenames, never `p_comm` alone).
public struct ProcessDescriptor: Sendable, Hashable, Codable {
    /// `proc_pidpath` (nil after an auto-update replaced the binary — fall back to argv).
    public var executablePath: String?
    /// argv (argv[0] first). May be just `[argv0]` when built from an inbox ancestor.
    public var argv: [String]
    /// `p_comm`
    public var comm: String?
    /// Allow-listed environment if known (e.g. `VSCODE_ESM_ENTRYPOINT` for the VS Code agent host). Usually empty.
    public var environment: [String: String]

    public init(executablePath: String?, argv: [String], comm: String? = nil, environment: [String: String] = [:]) {
        self.executablePath = executablePath
        self.argv = argv
        self.comm = comm
        self.environment = environment
    }

    public var argv0Basename: String? { argv.first.map { ($0 as NSString).lastPathComponent } }
    public var argv1Basename: String? { argv.count > 1 ? (argv[1] as NSString).lastPathComponent : nil }
    public var executableBasename: String? { executablePath.map { ($0 as NSString).lastPathComponent } }
}

/// Result of signature matching.
public struct AgentMatch: Sendable, Hashable, Codable {
    public var agent: AgentID
    /// `claude daemon`, `claude bg-pty-host`, `claude bg-spare`, `goosed` …: protected from pausing but never a session.
    public var isInfrastructure: Bool
    /// IDE/app host processes such as `codex app-server` or the VS Code agent host.
    public var isIDEHost: Bool

    public init(agent: AgentID, isInfrastructure: Bool = false, isIDEHost: Bool = false) {
        self.agent = agent
        self.isInfrastructure = isInfrastructure
        self.isIDEHost = isIDEHost
    }
}

/// One matched agent process, as produced by the scanner every tick.
public struct AgentProcess: Sendable, Hashable, Codable, Identifiable {
    public var identity: ProcessIdentity
    public var id: ProcessIdentity { identity }
    public var agent: AgentID
    public var executablePath: String?
    /// argv[0] (never use for display without sanitizing; argv can contain prompt text).
    public var argv0: String
    /// argv, capped at 32 entries / 4 KiB total. Memory only — never log or persist.
    public var arguments: [String]
    /// Current working directory (`PROC_PIDVNODEPATHINFO`).
    public var cwd: String?
    /// Controlling tty (`e_tdev`); nil = none.
    public var ttyDevice: Int32?
    /// `devname(e_tdev, S_IFCHR)`, e.g. `ttys004`.
    public var ttyName: String?
    public var ppid: Int32
    /// Ancestors, nearest first, up to launchd (excluded).
    public var ancestors: [AncestorInfo]
    /// GUI host app (first `isApp` ancestor, or responsibility-derived) if any.
    public var hostApp: HostApp?
    /// Every same-uid descendant (children, grandchildren, …) at sample time.
    public var descendants: [ProcessIdentity]
    /// True for agent infrastructure (never a session; still protected from pausing).
    public var isInfrastructure: Bool
    /// True for IDE host processes (`codex app-server`, VS Code agent host).
    public var isIDEHost: Bool
    /// Evidence over the trailing window (brief §5.4).
    public var evidence: EvidenceSample
    /// When the scanner first saw this identity.
    public var firstSeen: Date

    public init(
        identity: ProcessIdentity,
        agent: AgentID,
        executablePath: String? = nil,
        argv0: String,
        arguments: [String] = [],
        cwd: String? = nil,
        ttyDevice: Int32? = nil,
        ttyName: String? = nil,
        ppid: Int32 = 1,
        ancestors: [AncestorInfo] = [],
        hostApp: HostApp? = nil,
        descendants: [ProcessIdentity] = [],
        isInfrastructure: Bool = false,
        isIDEHost: Bool = false,
        evidence: EvidenceSample,
        firstSeen: Date
    ) {
        self.identity = identity
        self.agent = agent
        self.executablePath = executablePath
        self.argv0 = argv0
        self.arguments = arguments
        self.cwd = cwd
        self.ttyDevice = ttyDevice
        self.ttyName = ttyName
        self.ppid = ppid
        self.ancestors = ancestors
        self.hostApp = hostApp
        self.descendants = descendants
        self.isInfrastructure = isInfrastructure
        self.isIDEHost = isIDEHost
        self.evidence = evidence
        self.firstSeen = firstSeen
    }
}

/// What `ProcessSampling.sample(now:)` returns each tick.
public struct ProcessSnapshot: Sendable, Hashable, Codable {
    public var takenAt: Date
    /// Matched agent processes (sessions and infrastructure), sorted by pid.
    public var agents: [AgentProcess]
    /// Number of same-uid processes scanned.
    public var scannedProcessCount: Int
    /// Wall time of the scan in milliseconds (diagnostics).
    public var scanMilliseconds: Double

    public init(takenAt: Date, agents: [AgentProcess], scannedProcessCount: Int = 0, scanMilliseconds: Double = 0) {
        self.takenAt = takenAt
        self.agents = agents
        self.scannedProcessCount = scannedProcessCount
        self.scanMilliseconds = scanMilliseconds
    }

    public static func empty(at date: Date) -> ProcessSnapshot { ProcessSnapshot(takenAt: date, agents: []) }

    /// Agent processes that can be sessions (non-infrastructure).
    public var sessionCandidates: [AgentProcess] { agents.filter { !$0.isInfrastructure } }

    public func process(for identity: ProcessIdentity) -> AgentProcess? { agents.first { $0.identity == identity } }
    public func process(pid: Int32) -> AgentProcess? { agents.first { $0.identity.pid == pid } }
}

/// Polling cadence (brief §5.3/§9.3): faster while the lid is closed.
public enum SamplingCadence: String, Sendable, Hashable, Codable {
    case lidOpen
    case lidClosed

    /// Process scan interval: 15 s open / 5 s closed.
    public var processScanInterval: Duration { self == .lidClosed ? .seconds(5) : .seconds(15) }
    /// `claude agents --json --all` poll interval: 60 s open / 15 s closed.
    public var claudeAgentsPollInterval: Duration { self == .lidClosed ? .seconds(15) : .seconds(60) }
}

/// Files/directories whose writes count as E3 progress for one agent process
/// (e.g. `~/.claude/projects/<slug>/<sessionId>.jsonl` and `<sessionId>/`). Supplied by the coordinator.
public struct SessionStoreHint: Sendable, Hashable, Codable {
    public var identity: ProcessIdentity
    public var paths: [String]

    public init(identity: ProcessIdentity, paths: [String]) {
        self.identity = identity
        self.paths = paths
    }
}
