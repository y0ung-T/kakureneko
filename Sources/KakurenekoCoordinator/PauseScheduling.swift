// When to pause other apps, what topology to hand KakurenekoPause, and the "agent CPU not advancing" watchdog
// (ARCHITECTURE §9.8 "Pausing", brief §6.1 / §6.3 / §6.5). Pure value types: the coordinator feeds them the
// latest state and executes the decisions.

import KakurenekoKit
import Foundation

// MARK: - Policy

/// The pause gate of ARCHITECTURE §9.8 (brief §6.1): everything must hold.
enum PausePolicy {
    /// Inputs of one gate evaluation.
    struct Inputs: Sendable, Hashable {
        var now: Date
        /// `lid == .closed && !externalDisplayConnected`.
        var effectiveLidClosed: Bool
        /// Start of the current effective closed-lid period (the 90 s settle is measured from it).
        var closedSince: Date?
        /// `CGEventSource` idle time at `now`; nil = unknown (treated as "no input").
        var secondsSinceUserInput: TimeInterval?
        /// `shouldStayArmed` (anyWorking ∨ waitingGrace ∨ keep-awake): nothing to protect → wind down, never pause.
        var shouldStayArmed: Bool
        /// Closed-lid phase in which the Mac is held awake on purpose (ClosedAwake or Countdown).
        var heldAwakeWithLidClosed: Bool
        var mode: OperatingMode
        var kakurenekoEnabled: Bool
        var settings: PauseSettings
    }

    /// True when `pause(topology:settings:now:)` may run now.
    static func shouldPause(_ i: Inputs) -> Bool {
        guard pausingAllowed(mode: i.mode, kakurenekoEnabled: i.kakurenekoEnabled, settings: i.settings) else { return false }
        guard i.effectiveLidClosed, i.heldAwakeWithLidClosed, i.shouldStayArmed, let closedSince = i.closedSince else {
            return false
        }
        guard i.now.timeIntervalSince(closedSince) >= TimeInterval(i.settings.lidCloseSettleSeconds) else { return false }
        let idle = i.secondsSinceUserInput ?? .infinity
        return idle >= TimeInterval(i.settings.userInputGraceSeconds)
    }

    /// Pausing needs closed-lid mode (`.full`), the master switch and the pausing switch (rule P-K global).
    static func pausingAllowed(mode: OperatingMode, kakurenekoEnabled: Bool, settings: PauseSettings) -> Bool {
        mode == .full && kakurenekoEnabled && settings.enabled
    }

    /// The hard cap (`maxPausedHours`) since the first pause of this closed-lid period.
    static func hardCapReached(pausedSince: Date?, now: Date, settings: PauseSettings) -> Bool {
        guard let pausedSince else { return false }
        return now.timeIntervalSince(pausedSince) >= TimeInterval(settings.maxPausedHours) * 3600
    }

    /// Adds what only the coordinator knows to a fresh topology, before EVERY `pause` and `recheck`:
    /// the bound agent processes of live sessions (in-app agents have no matched process; T1/T2 binding may know
    /// one the scanner missed) and the host-app main pids of live sessions (P-A for VS Code / Cursor / … agents).
    static func augment(_ topology: AgentTopology, with sessions: [AgentSession]) -> AgentTopology {
        var topology = topology
        let live = sessions.filter { !$0.state.isEnded }
        topology.agentIdentities.formUnion(live.compactMap(\.agentProcess))
        topology.sessionHostPIDs = Set(live.compactMap { $0.host?.pid })
        return topology
    }
}

// MARK: - Watchdog

/// "An agent claims working but its tree CPU has not advanced for `watchdogMinutes` while apps are frozen →
/// thaw everything" (brief §6.3; we may be the reason it is stuck). Tracks `EvidenceSample.treeCPUSeconds` per
/// agent process from every process scan.
struct CPUWatchdog: Sendable, Hashable {
    /// Below this the cumulative CPU counts as "not advanced" (rounding in rusage conversions).
    static let epsilonSeconds: Double = 0.01

    struct Progress: Sendable, Hashable {
        var cpuSeconds: Double
        var lastAdvancedAt: Date
    }

    private(set) var progress: [ProcessIdentity: Progress] = [:]

    /// Records the CPU counters of one scan. Processes absent from the scan are forgotten.
    mutating func observe(_ snapshot: ProcessSnapshot, now: Date) {
        var next: [ProcessIdentity: Progress] = [:]
        for agent in snapshot.agents {
            guard let seconds = agent.evidence.treeCPUSeconds else { continue }
            if let previous = progress[agent.identity], seconds <= previous.cpuSeconds + Self.epsilonSeconds {
                next[agent.identity] = previous
            } else {
                next[agent.identity] = Progress(cpuSeconds: seconds, lastAdvancedAt: now)
            }
        }
        progress = next
    }

    /// True when some WORKING session's bound process has not advanced its tree CPU for `limit`, counting only
    /// time since `frozenSince` (the freeze cannot be blamed for earlier silence). Sessions whose process has no
    /// CPU counter cannot be judged and never trip it.
    func tripped(workingSessions: [AgentSession], frozenSince: Date, now: Date, limit: TimeInterval) -> Bool {
        for session in workingSessions {
            guard session.state.isWorking, let identity = session.agentProcess, let entry = progress[identity] else {
                continue
            }
            let since = max(entry.lastAdvancedAt, frozenSince)
            if now.timeIntervalSince(since) >= limit { return true }
        }
        return false
    }
}

// MARK: - E3 hints

/// `SessionStoreHint`s for KakurenekoProcesses' E3 evidence, from the sessions' bound process and the
/// `MetadataKey.transcriptPath` / `MetadataKey.sessionStoreDirectory` the engine fills.
///
/// Claude: only the session-store subtree (`<sessionId>/` — subagents, workflows, tool results), never the main
/// `<sessionId>.jsonl` (brief §5.4: "the main transcript mtime alone is not used: idle sessions rewrite metadata on
/// wake"; R02 §4: Claude appends `away_summary` ~3 min after a turn and metadata on wake, which would refresh the stall
/// guard or revive a stalled session). Other agents' transcripts (Codex rollouts, Gemini chats) ARE their session
/// store and are hinted as given.
enum SessionStoreHints {
    static func build(from sessions: [AgentSession]) -> [SessionStoreHint] {
        var paths: [ProcessIdentity: Set<String>] = [:]
        for session in sessions where !session.state.isEnded {
            guard let identity = session.agentProcess else { continue }
            let transcript = session.key.agent == .claude ? nil : session.metadata[MetadataKey.transcriptPath]
            let candidates = [transcript, session.metadata[MetadataKey.sessionStoreDirectory]]
            let found = candidates.compactMap { $0 }.filter { !$0.isEmpty }
            guard !found.isEmpty else { continue }
            paths[identity, default: []].formUnion(found)
        }
        return paths
            .map { SessionStoreHint(identity: $0.key, paths: $0.value.sorted()) }
            .sorted { ($0.identity.pid, $0.identity.startSec, $0.identity.startUsec) < ($1.identity.pid, $1.identity.startSec, $1.identity.startUsec) }
    }
}
