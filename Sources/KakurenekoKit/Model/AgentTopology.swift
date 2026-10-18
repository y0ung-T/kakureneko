import Foundation

/// Everything app-pausing needs to know about agents (brief §6.3 rules P-A…P-E), produced by
/// `ProcessSampling.topology(for:now:)` in KakurenekoProcesses and consumed by KakurenekoPause.
///
/// Rule P-A(1) ("an agent process or descendant is *responsible to* the app") is evaluated by
/// KakurenekoPause itself with its responsibility-based `ProcessGrouping` over `allAgentTreePIDs`.
public struct AgentTopology: Sendable, Hashable, Codable {
    // Codable: in-memory/diagnostics only (never persisted), so synthesized coding is fine.
    public var builtAt: Date
    /// Agent processes (sessions + infrastructure).
    public var agentIdentities: Set<ProcessIdentity>
    /// All descendants of agent processes (MCP servers, Bash-tool shells, builds, caffeinate …).
    public var descendantIdentities: Set<ProcessIdentity>
    /// Controlling ttys (`e_tdev`) of agents and their descendants.
    public var ttyDevices: Set<Int32>
    /// P-A(2): pids holding the pty master (`/dev/ptmx` fd with matching minor) of any of `ttyDevices`.
    public var ptyMasterHolderPIDs: Set<Int32>
    /// P-A(3): every pid in any agent's ancestor chain (Terminal, login, zsh, VS Code helpers, …).
    public var ancestorPIDs: Set<Int32>
    /// P-B: main pids of GUI apps that have an agent ancestor (Playwright/CDP browsers).
    public var agentLaunchedAppPIDs: Set<Int32>
    /// P-C/P-D: processes connected to an agent tree (Unix socket peer, loopback TCP peer, pipe peer,
    /// or owner of a LISTEN socket an agent-tree socket connects to).
    public var ipcPeers: [IPCPeerHint]
    /// P-E: automation helpers running inside agent trees.
    public var automationHelpers: [AutomationHelperHint]
    /// P-A: host-app MAIN pids of live T1/T2 sessions (`AgentSession.host?.pid`, hook ancestry). Covers agents
    /// that run inside an app process with no separately matched agent process (VS Code Local/Copilot agent,
    /// Cursor IDE agent, Trae, Kiro IDE, Void, Antigravity IDE …). Filled by the COORDINATOR before every
    /// `pause`/`recheck` (KakurenekoProcesses leaves it empty).
    public var sessionHostPIDs: Set<Int32>
    /// False when some probes failed (EPERM, timeouts): KakurenekoPause must then be conservative
    /// (protect anything uncertain; never freeze).
    public var isComplete: Bool

    public init(
        builtAt: Date,
        agentIdentities: Set<ProcessIdentity> = [],
        descendantIdentities: Set<ProcessIdentity> = [],
        ttyDevices: Set<Int32> = [],
        ptyMasterHolderPIDs: Set<Int32> = [],
        ancestorPIDs: Set<Int32> = [],
        agentLaunchedAppPIDs: Set<Int32> = [],
        ipcPeers: [IPCPeerHint] = [],
        automationHelpers: [AutomationHelperHint] = [],
        isComplete: Bool = true,
        sessionHostPIDs: Set<Int32> = []
    ) {
        self.builtAt = builtAt
        self.agentIdentities = agentIdentities
        self.descendantIdentities = descendantIdentities
        self.ttyDevices = ttyDevices
        self.ptyMasterHolderPIDs = ptyMasterHolderPIDs
        self.ancestorPIDs = ancestorPIDs
        self.agentLaunchedAppPIDs = agentLaunchedAppPIDs
        self.ipcPeers = ipcPeers
        self.automationHelpers = automationHelpers
        self.isComplete = isComplete
        self.sessionHostPIDs = sessionHostPIDs
    }

    public static func empty(at date: Date) -> AgentTopology { AgentTopology(builtAt: date) }

    /// pids of agents and all their descendants.
    public var allAgentTreePIDs: Set<Int32> {
        Set(agentIdentities.map(\.pid)).union(descendantIdentities.map(\.pid))
    }

    /// pids that must never be paused regardless of grouping (agents, descendants, ancestors,
    /// pty-master holders, agent-launched apps, IPC peers, session host apps).
    public var directlyProtectedPIDs: Set<Int32> {
        allAgentTreePIDs
            .union(ancestorPIDs)
            .union(ptyMasterHolderPIDs)
            .union(agentLaunchedAppPIDs)
            .union(ipcPeers.map(\.peerPID))
            .union(sessionHostPIDs)
    }

    /// True if no agent PROCESS was matched. Diagnostics only: KakurenekoPause must NEVER infer "no agent is
    /// working" from this (in-app agents have no matched process); only the coordinator decides `holdAwake`.
    public var isEmpty: Bool { agentIdentities.isEmpty && sessionHostPIDs.isEmpty }
}

/// A process connected to an agent tree.
public struct IPCPeerHint: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case unixSocket
        case loopbackTCP
        case pipe
        /// The peer owns a LISTEN socket (TCP port or Unix path) that an agent-tree socket connects to (P-D).
        case listener
    }
    public var peerPID: Int32
    public var kind: Kind
    /// The agent-tree process on the other end.
    public var agentSidePID: Int32
    /// e.g. `127.0.0.1:9222`, `/tmp/cc-daemon-501/…/control.sock`. Diagnostics only.
    public var detail: String?

    public init(peerPID: Int32, kind: Kind, agentSidePID: Int32, detail: String? = nil) {
        self.peerPID = peerPID
        self.kind = kind
        self.agentSidePID = agentSidePID
        self.detail = detail
    }
}

/// An automation helper (`osascript`, `open`, `shortcuts`, `mcpbridge`, `simctl`, `xcodebuild`) seen in an agent tree (P-E).
public struct AutomationHelperHint: Sendable, Hashable, Codable {
    public var helper: ProcessIdentity
    /// Basename of the helper executable.
    public var tool: String
    /// Likely targets (`com.apple.dt.Xcode`, `com.apple.iphonesimulator`, the default browser …).
    /// Empty = unknown target → KakurenekoPause thaws everything.
    public var likelyTargetBundleIDs: [String]

    public init(helper: ProcessIdentity, tool: String, likelyTargetBundleIDs: [String] = []) {
        self.helper = helper
        self.tool = tool
        self.likelyTargetBundleIDs = likelyTargetBundleIDs
    }
}
