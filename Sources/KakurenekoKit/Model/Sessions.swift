import Foundation

/// Session identity (brief §5.1). `id` = session_id | thread-id | conversation_id | taskId |
/// trajectory_id; fallback `pid:<pid>:<startSec>.<usec>`.
public struct SessionKey: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public var agent: AgentID
    public var id: String

    public init(agent: AgentID, id: String) {
        self.agent = agent
        self.id = id
    }

    /// Process-bound fallback key.
    public static func fallback(agent: AgentID, identity: ProcessIdentity) -> SessionKey {
        SessionKey(agent: agent, id: identity.fallbackSessionID)
    }

    /// True for `pid:…` fallback keys (the engine may re-key them when a real id appears for the same process).
    public var isProcessFallback: Bool { id.hasPrefix("pid:") }

    public var description: String { "\(agent.rawValue)/\(id)" }

    public static func < (lhs: SessionKey, rhs: SessionKey) -> Bool {
        (lhs.agent.rawValue, lhs.id) < (rhs.agent.rawValue, rhs.id)
    }
}

/// Per-session state (brief §5.1; `settling` carries the pending outcome, `ended` its time).
public enum SessionState: Sendable, Hashable, Codable {
    case working(since: Date)
    /// turnFinished seen; waiting `settle` (5 s) for a continuation before becoming idle.
    case settling(until: Date, outcome: TurnOutcome)
    case waiting(kind: NeedsInputKind, since: Date)
    case idle(since: Date, outcome: TurnOutcome?)
    /// Claims busy, no progress ≥ stall threshold. Counts as NOT working.
    case stalled(since: Date)
    /// Dropped from the list 10 min after `at`.
    case ended(at: Date)

    public var isWorking: Bool { if case .working = self { true } else { false } }
    public var isSettling: Bool { if case .settling = self { true } else { false } }
    public var isWaiting: Bool { if case .waiting = self { true } else { false } }
    public var isIdle: Bool { if case .idle = self { true } else { false } }
    public var isStalled: Bool { if case .stalled = self { true } else { false } }
    public var isEnded: Bool { if case .ended = self { true } else { false } }

    /// Short label for UI and logs: `working`, `settling`, `waiting`, `idle`, `stalled`, `ended`.
    public var label: String {
        switch self {
        case .working: "working"
        case .settling: "settling"
        case .waiting: "waiting"
        case .idle: "idle"
        case .stalled: "stalled"
        case .ended: "ended"
        }
    }

    /// Sort rank for the UI: working, settling, waiting, stalled, idle, ended.
    public var displayRank: Int {
        switch self {
        case .working: 0
        case .settling: 1
        case .waiting: 2
        case .stalled: 3
        case .idle: 4
        case .ended: 5
        }
    }
}

/// One agent session as the engine sees it (brief §5.1).
public struct AgentSession: Sendable, Hashable, Codable, Identifiable {
    public var key: SessionKey
    public var id: SessionKey { key }
    /// Bound from ancestry / `CLAUDE_PID` / record pid.
    public var agentProcess: ProcessIdentity?
    public var host: HostApp?
    /// Current cwd (for Claude: last transcript entry's cwd beats the record's launch cwd).
    public var cwd: String?
    public var title: String?
    public var state: SessionState
    public var turnStartedAt: Date?
    public var lastHookAt: Date?
    public var lastProgressAt: Date?
    /// Tiers that have seen this session.
    public var tiers: Set<Tier>
    /// Sanitized ≤ 140 chars; shown only at `DetailLevel.detailed`.
    public var lastMessagePreview: String?
    /// Needs-input text while waiting.
    public var waitingFor: String?
    /// Duration of the last finished turn, if known.
    public var lastTurnDuration: TimeInterval?
    /// Claude Remote Control connected (`bridgeSessionId` present) — notify policy may skip.
    public var remoteControlConnected: Bool
    /// Agent-specific extras (`claude.kind`, `claude.jobId`, `claude.entrypoint`, …).
    public var metadata: [String: String]

    public init(
        key: SessionKey,
        agentProcess: ProcessIdentity? = nil,
        host: HostApp? = nil,
        cwd: String? = nil,
        title: String? = nil,
        state: SessionState,
        turnStartedAt: Date? = nil,
        lastHookAt: Date? = nil,
        lastProgressAt: Date? = nil,
        tiers: Set<Tier> = [],
        lastMessagePreview: String? = nil,
        waitingFor: String? = nil,
        lastTurnDuration: TimeInterval? = nil,
        remoteControlConnected: Bool = false,
        metadata: [String: String] = [:]
    ) {
        self.key = key
        self.agentProcess = agentProcess
        self.host = host
        self.cwd = cwd
        self.title = title
        self.state = state
        self.turnStartedAt = turnStartedAt
        self.lastHookAt = lastHookAt
        self.lastProgressAt = lastProgressAt
        self.tiers = tiers
        self.lastMessagePreview = lastMessagePreview
        self.waitingFor = waitingFor
        self.lastTurnDuration = lastTurnDuration
        self.remoteControlConnected = remoteControlConnected
        self.metadata = metadata
    }

    public var agent: AgentID { key.agent }
    /// `{project}` = basename of cwd.
    public var projectName: String? { KakurenekoFormat.projectName(fromCwd: cwd) }
    /// Title for display: title → project → agent display name.
    public var displayTitle: String { title ?? projectName ?? key.agent.displayName }
    /// Only T3 has ever seen it (push wording "went quiet").
    public var isHeuristicOnly: Bool { tiers.subtracting([.heuristic, .guardrail]).isEmpty }
}

/// Global aggregation (brief §5.6).
public struct SessionAggregate: Sendable, Hashable, Codable {
    /// ∃ session in `.working` (stalled excluded; settling counts as working).
    public var anyWorking: Bool
    /// ∃ session in `.waiting`.
    public var anyWaiting: Bool
    public var workingCount: Int
    public var waitingCount: Int
    public var stalledCount: Int
    public var idleCount: Int
    /// Sessions that are not `.ended`.
    public var liveCount: Int
    /// Monotonic counter incremented every time any session (re)enters `.working` as a NEW turn.
    /// Embedded as `sv` in signed phone commands: sleep/shutdown execute only if unchanged (brief §8.3).
    /// Seeded per launch (`SessionEngine(initialStateVersion:)` = launch epoch ms in production) so a button
    /// minted before a relaunch can never match a later, unrelated state.
    public var stateVersion: Int
    /// Earliest `since` among waiting sessions.
    public var oldestWaitingSince: Date?
    /// Most recent finish (`idle` entered with a pushable outcome).
    public var lastFinishedAt: Date?

    public init(
        anyWorking: Bool = false,
        anyWaiting: Bool = false,
        workingCount: Int = 0,
        waitingCount: Int = 0,
        stalledCount: Int = 0,
        idleCount: Int = 0,
        liveCount: Int = 0,
        stateVersion: Int = 0,
        oldestWaitingSince: Date? = nil,
        lastFinishedAt: Date? = nil
    ) {
        self.anyWorking = anyWorking
        self.anyWaiting = anyWaiting
        self.workingCount = workingCount
        self.waitingCount = waitingCount
        self.stalledCount = stalledCount
        self.idleCount = idleCount
        self.liveCount = liveCount
        self.stateVersion = stateVersion
        self.oldestWaitingSince = oldestWaitingSince
        self.lastFinishedAt = lastFinishedAt
    }

    public static let empty = SessionAggregate()

    /// Reference computation from a list of sessions (the engine may use it; `stateVersion` is passed through).
    public static func compute(from sessions: [AgentSession], stateVersion: Int, lastFinishedAt: Date?) -> SessionAggregate {
        var a = SessionAggregate(stateVersion: stateVersion, lastFinishedAt: lastFinishedAt)
        for s in sessions {
            switch s.state {
            case .working, .settling:
                a.workingCount += 1
            case .waiting(_, let since):
                a.waitingCount += 1
                a.oldestWaitingSince = min(a.oldestWaitingSince ?? since, since)
            case .stalled:
                a.stalledCount += 1
            case .idle:
                a.idleCount += 1
            case .ended:
                continue
            }
            a.liveCount += 1
        }
        a.anyWorking = a.workingCount > 0
        a.anyWaiting = a.waitingCount > 0
        return a
    }
}

/// Something the engine wants the coordinator to act on (notify, countdown, resume manifest).
public struct SessionEffect: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        /// working → idle after settle, with a pushable outcome (completed, error, rateLimited, ambiguous).
        /// Never emitted for `.interrupted`.
        case finished
        /// Entered `.waiting` (once per wait).
        case needsInput
        /// Entered `.stalled` (once per stall).
        case stalled
        /// T3-only session went from working to idle after the heuristic exit window.
        case wentQuiet
        /// Session ended (sessionEnded, NOTE_EXIT, start mismatch, record deleted).
        case ended
    }

    public var kind: Kind
    /// Session snapshot at emission time.
    public var session: AgentSession
    public var at: Date
    public var outcome: TurnOutcome?
    /// turnStartedAt → finish, when known.
    public var workedFor: TimeInterval?
    public var needsInputKind: NeedsInputKind?

    public init(kind: Kind, session: AgentSession, at: Date, outcome: TurnOutcome? = nil, workedFor: TimeInterval? = nil, needsInputKind: NeedsInputKind? = nil) {
        self.kind = kind
        self.session = session
        self.at = at
        self.outcome = outcome
        self.workedFor = workedFor
        self.needsInputKind = needsInputKind
    }
}

/// Well-known keys for `AgentEvent.metadata` / `AgentSession.metadata` (shared by Events, Sessions,
/// Coordinator, Notify). Producers may add other namespaced keys (`<agent>.<name>`), ≤ 16 per value.
public enum MetadataKey {
    /// Absolute transcript path (Claude `transcript_path`, resolved `projects/*/<sessionId>.jsonl`). The engine
    /// copies it from `AgentEvent.transcriptPath` / `ClaudeSessionObservation.transcriptPath` (latest wins); the
    /// coordinator builds E3 `SessionStoreHint`s from it.
    public static let transcriptPath = "transcriptPath"
    /// Claude per-session store directory `<projects>/<slug>/<sessionId>/` (subagents/, workflows/): E3 hint.
    /// Set by the engine next to `transcriptPath` (the transcript path minus `.jsonl`).
    public static let sessionStoreDirectory = "sessionStoreDirectory"
    /// Claude record `kind` (`interactive` | `bg`).
    public static let claudeKind = "claude.kind"
    /// Claude background job short id.
    public static let claudeJobID = "claude.jobId"
    /// `CLAUDE_CODE_ENTRYPOINT` / record `entrypoint` (`cli`, `claude-vscode`, `claude-desktop`, …).
    public static let claudeEntrypoint = "claude.entrypoint"
    /// Codex `client` from the notify payload.
    public static let codexClient = "codex.client"
    /// opencode child (subagent) session id that produced the event.
    public static let opencodeChildSession = "opencode.childSession"
    /// opencode session id from the payload (opencode sessions are keyed by the opencode PROCESS, §8).
    public static let opencodeSessionID = "opencode.sessionId"
    /// Claude `SessionStart.source` (`startup`, `resume`, `clear`, `compact`).
    public static let claudeSessionStartSource = "claude.sessionStartSource"
    /// The session was relabelled from the argv agent (e.g. copilot → vscode by ancestry).
    public static let relabelledFrom = "relabelledFrom"

    // Informational extras KakurenekoEvents copies from hook payloads (no module acts on them today; UI/diagnostics
    // may show them). Values are capped untrusted strings.

    /// Claude hook `permission_mode` (`default`, `acceptEdits`, `plan`, `bypassPermissions`, …).
    public static let claudePermissionMode = "claude.permissionMode"
    /// Claude hook `agent_type` (subagent type of a `SubagentStop`-style payload).
    public static let claudeAgentType = "claude.agentType"
    /// `SessionEnd`/`sessionEnd` `reason` (Claude, Copilot, Cursor).
    public static let sessionEndReason = "sessionEndReason"
    /// Codex `SessionStart` `source`.
    public static let codexSessionStartSource = "codex.sessionStartSource"
    /// Gemini `SessionStart` `source`.
    public static let geminiSessionStartSource = "gemini.sessionStartSource"
    /// Copilot `sessionStart` `source`.
    public static let copilotSessionStartSource = "copilot.sessionStartSource"
    /// Cursor `composer_mode`.
    public static let cursorComposerMode = "cursor.composerMode"
    /// Antigravity (`agy`) `terminationReason`.
    public static let agyTerminationReason = "agy.terminationReason"
    /// Auggie `agent_stop_cause`.
    public static let auggieStopCause = "auggie.stopCause"
}
