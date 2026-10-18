import KakurenekoKit
import Foundation

/// Why a session reached `.ended` (decides whether a later T1/T2 observation may revive it).
enum EndReason: String, Sendable, Hashable {
    /// T1 `sessionEnded`.
    case sessionEnded
    /// The Claude record's process is gone or its start time does not match (`identity == nil`).
    case recordDead
    /// The Claude record disappeared from `sessions/` (or the alive `agents --json` entry vanished).
    case recordDeleted
    /// T3: the bound process was absent from two consecutive process snapshots.
    case processGone
    /// The user dismissed the session in the UI.
    case dismissed

    /// Ends decided by a liveness probe. A later observation proving the process alive (T2 identity check)
    /// overrides them; ends decided by the agent or the user need NEW activity to be undone.
    var isLivenessVerdict: Bool {
        switch self {
        case .recordDead, .recordDeleted, .processGone: true
        case .sessionEnded, .dismissed: false
        }
    }
}

/// Effective T2 status of one Claude session after merging its record with `claude agents --json`.
enum ClaudeT2Status: Hashable, Sendable {
    case busy
    /// Carries `waitingFor` (`permission prompt`, `input needed`, …), capped.
    case waiting(String?)
    case idle
    /// Idle with a background shell alive — NOT working (dev servers run forever).
    case shell

    var isIdleLike: Bool { self == .idle || self == .shell }
    var isWaiting: Bool { if case .waiting = self { true } else { false } }

    /// Same status ignoring the waiting text.
    func sameKind(as other: ClaudeT2Status?) -> Bool {
        switch (self, other) {
        case (.busy, .busy?), (.idle, .idle?), (.shell, .shell?), (.waiting, .waiting?): true
        default: false
        }
    }

    var label: String {
        switch self {
        case .busy: "busy"
        case .waiting: "waiting"
        case .idle: "idle"
        case .shell: "shell"
        }
    }
}

/// Per-turn bookkeeping. Reset whenever a NEW turn enters `.working`.
struct TurnTracking: Sendable, Hashable {
    /// Start of the current turn (`nil` = unknown, e.g. a finish edge without a seen start).
    var startedAt: Date?
    /// A T1 `turnFinished` arrived this turn (`stopSeenThisTurn`).
    var stopSeen = false
    /// Outcome of that `turnFinished`, kept while a still-busy record holds the session in `.working`.
    var pendingOutcome: TurnOutcome?
    /// A `finished` effect was emitted for this turn (never twice).
    var finishEmitted = false
    /// The finishing event reported running background work (subagents, workflows, crons…).
    var backgroundTasksRunning = false
    /// T2-only busy → idle without a matching `turn_duration` yet: a later transcript `turn_duration` upgrades the
    /// `.idle(.interrupted)` to `.idle(.completed)` + `finished` (exactly once, within `lateFinishWindow`).
    var awaitingTurnDuration = false

    init(startedAt: Date? = nil) {
        self.startedAt = startedAt
    }
}

/// "Condition sustained for X / absent for Y" bookkeeping over process-evidence samples.
struct SustainWindow: Sendable, Hashable {
    /// First sample of the current run that met the condition.
    var aboveSince: Date?
    /// First sample of the current run that did not meet it.
    var belowSince: Date?

    mutating func reset() {
        aboveSince = nil
        belowSince = nil
    }

    /// Records one sample.
    mutating func record(meets: Bool, at now: Date) {
        if meets {
            belowSince = nil
            if aboveSince == nil { aboveSince = now }
        } else {
            aboveSince = nil
            if belowSince == nil { belowSince = now }
        }
    }

    func sustained(for duration: TimeInterval, at now: Date) -> Bool {
        guard let aboveSince else { return false }
        return now.timeIntervalSince(aboveSince) >= duration
    }

    func quiet(for duration: TimeInterval, at now: Date) -> Bool {
        guard let belowSince else { return false }
        return now.timeIntervalSince(belowSince) >= duration
    }
}

/// What the engine knows about a session's Claude T2 sources.
struct T2Tracking: Sendable, Hashable {
    /// Last applied effective status (`nil` = no status seen yet).
    var status: ClaudeT2Status?
    /// `statusUpdatedAt` of the record behind `status` (a rewrite with the same status is still an edge).
    var recordStatusAt: Date?
    /// `statusUpdatedAt` of the record when it was last applied as `busy` (T2-only turn start reference).
    var busyStatusAt: Date?
    /// The latest T2 snapshot contained this session (live record or alive `agents --json` entry).
    var present = false
    /// The session has been seen with a record file (vs. only as an `agents --json` entry).
    var hasRecord = false
    /// `takenAt` of the last snapshot that contained the record (a stale poll cannot outlive a deleted record).
    var recordLastSeenAt: Date?
}

/// T3 liveness of the bound `agentProcess`.
struct T3Liveness: Sendable, Hashable {
    /// The bound process was seen in at least one process snapshot.
    var seen = false
    /// Consecutive snapshots it was missing from.
    var misses = 0
}

/// Last values taken from a Claude observation, so an unchanged (possibly stale) transcript tail never overwrites a
/// fresher T1 value ("latest wins").
struct ObservedFields: Sendable, Hashable {
    var title: String?
    var cwd: String?
    var preview: String?
    var transcriptPath: String?
}

/// One session plus the engine's private per-session state.
struct TrackedSession: Sendable {
    var session: AgentSession
    /// A T1 `turnStarted`, a T2 record `busy` or a bg `working` was seen: the agent reports turn starts.
    var hasStartEdge = false
    /// Any T1 event was seen for this session.
    var hooksLive = false
    /// The session has been `.working` at least once (Codex sub-thread rule).
    var everWorked = false
    var turn = TurnTracking()
    /// When the session last entered `.idle` (bounds the late-finish reuse of the previous turn).
    var idleSince: Date?
    /// ≥ 2 evidence kinds sustained → working / < 2 for the exit window → idle (sessions without a start edge).
    var heuristic = SustainWindow()
    /// Evidence sampled before this does not count toward a new heuristic turn: the sampler's trailing window still
    /// holds the turn that a finish just ended (`EngineState.evidenceWindow`).
    var heuristicHoldoffUntil: Date?
    /// T3 waiting exit (≥ 2 kinds incl. E1/E2/E4 sustained, sampled after `since`).
    var waitingExit = SustainWindow()
    var t2 = T2Tracking()
    var t3 = T3Liveness()
    var endReason: EndReason?
    var observed = ObservedFields()
    /// Most recent time anything touched this session (secondary sort key).
    var lastActivityAt: Date

    init(key: SessionKey, now: Date) {
        session = AgentSession(key: key, state: .idle(since: now, outcome: nil))
        lastActivityAt = now
        idleSince = now
    }

    var key: SessionKey { session.key }
    var state: SessionState { session.state }

    /// Sessions whose turns are driven by process evidence: no start edge (Codex notify-only, agy, Aider, Auggie,
    /// Cursor `-p`, T3-only agents) and no Claude T2 status (a record outranks heuristics).
    var usesHeuristicTurns: Bool { !hasStartEdge && !t2.present }

    /// When the session reached `.ended`, if it did.
    var endedAt: Date? {
        if case .ended(let at) = session.state { return at }
        return nil
    }
}

/// A dismissed session's process: neither T2 nor T3 may resurrect it without new activity.
struct DismissalTombstone: Sendable, Hashable {
    var identity: ProcessIdentity?
    var at: Date
}

/// Bounded set of recently ingested `AgentEvent.id`s (FIFO eviction).
struct RecentIDs: Sendable {
    private var members: Set<String> = []
    private var ring: [String] = []
    private var next = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        ring.reserveCapacity(self.capacity)
    }

    /// Inserts `id`; returns false when it was already present.
    mutating func insert(_ id: String) -> Bool {
        guard !members.contains(id) else { return false }
        if ring.count < capacity {
            ring.append(id)
        } else {
            members.remove(ring[next])
            ring[next] = id
            next = (next + 1) % capacity
        }
        members.insert(id)
        return true
    }

    func contains(_ id: String) -> Bool { members.contains(id) }
    var count: Int { members.count }
}

/// A log line produced while the engine lock is held; written after unlocking.
struct EngineNote: Sendable {
    var level: LogLevel
    var message: String
}

/// Agent-specific knowledge the engine needs.
enum EngineAgentTraits {
    /// Agents whose `activity` hook may start a turn from `.idle` because they have no turnStarted event (brief
    /// §5.2). Any session that has not shown a start edge yet is treated the same way.
    static let activityStartsTurn: Set<AgentID> = [.crush, .auggie, .vibe]

    /// Record / bg `waitingFor` text → kind (ARCHITECTURE §9.3).
    static func needsInputKind(forWaitingFor text: String?) -> NeedsInputKind {
        switch text?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "permission prompt": .permission
        case "input needed": .question
        case "dialog open": .dialog
        default: .unknown
        }
    }

    /// E1/E2/E4: the kinds that prove the agent itself is doing work (the T3 waiting exit requires one of them).
    static let workKinds: Set<EvidenceKind> = [.treeCPU, .childChurn, .modelAPISocket]
}
