import KakurenekoKit
import Foundation

/// The whole session state machine as a value type (brief §5.1–5.6, ARCHITECTURE §9.3). `SessionEngine` owns one
/// inside a `Mutex`; every public call mutates it, then drains `effects` and `notes`.
///
/// Inputs are split by tier: `EngineState+Events` (T1), `+ClaudeState` (T2), `+Processes` (T3/T4 liveness and
/// heuristics), `+Timers` (settle expiry, stall guard, heuristic exit, retention, dismissal). The transition helpers
/// below are shared by all of them. Precedence: liveness > state record > hook edges > heuristics.
struct EngineState: Sendable {
    var timers: SessionTimers
    /// `SessionAggregate.stateVersion` (seeded per launch).
    var stateVersion: Int
    var lastFinishedAt: Date?
    var tracked: [SessionKey: TrackedSession] = [:]
    var recentEventIDs = RecentIDs(capacity: EngineState.eventIDMemory)
    /// Latest T3 snapshot (cwd binding, agents-only Claude entries by pid).
    var latestProcesses: ProcessSnapshot?
    /// Live identities of ignorable Claude records (parked / spare / daemon) from the latest T2 snapshot.
    var ignoredIdentities: Set<ProcessIdentity> = []
    /// Unbound T3 candidates currently meeting the heuristic threshold → first qualifying sample time.
    var heuristicCandidates: [ProcessIdentity: Date] = [:]
    /// Dismissed sessions (kept after the ended session itself is dropped) → no resurrection without new activity.
    var tombstones: [SessionKey: DismissalTombstone] = [:]
    /// Point liveness lookup for bound processes no process snapshot ever contained (`nil` = T3 alone decides, the
    /// pre-fix rule; production passes `LiveProcessLookup`).
    var liveness: (any ProcessLookup)?
    private(set) var effects: [SessionEffect] = []
    private(set) var notes: [EngineNote] = []

    /// Bounded memory of ingested `AgentEvent.id`s.
    static let eventIDMemory = 4096
    /// A finish edge arriving this long after the session went idle without a finish still belongs to that turn
    /// (the record's `idle` can race ahead of the `Stop` hook; the transcript `turn_duration` lags the record).
    static let lateFinishWindow: TimeInterval = 60
    /// Cap on `AgentSession.metadata` entries (producers send ≤ 16 per event).
    static let maxMetadataEntries = 32
    /// Cap on any string taken from an agent (untrusted input, ARCHITECTURE §8).
    static let maxFieldLength = 1024
    /// Dismissal tombstones: at most this many, each for at most `tombstoneLifetime`.
    static let maxTombstones = 256
    static let tombstoneLifetime: TimeInterval = 24 * 3600
    /// The evidence sampler's trailing window (brief §5.4: kinds hold "within a sliding 60 s window"). Evidence of a
    /// turn that just finished lingers this long, so it never starts the next heuristic turn.
    static let evidenceWindow: TimeInterval = EvidenceSample.window
    /// An event that sat in the inbox longer than this (written while Kakureneko was not running) is history: it never
    /// creates a session, changes a state or produces an effect.
    static let staleEventAge: TimeInterval = 10 * 60

    init(timers: SessionTimers, stateVersion: Int, liveness: (any ProcessLookup)? = nil) {
        self.timers = timers
        self.stateVersion = stateVersion
        self.liveness = liveness
    }

    // MARK: - Outputs

    mutating func drainOutputs() -> (effects: [SessionEffect], notes: [EngineNote]) {
        defer {
            effects.removeAll(keepingCapacity: true)
            notes.removeAll(keepingCapacity: true)
        }
        return (effects, notes)
    }

    mutating func note(_ level: LogLevel = .info, _ message: String) {
        notes.append(EngineNote(level: level, message: message))
    }

    mutating func emit(_ kind: SessionEffect.Kind, _ t: TrackedSession, at now: Date, outcome: TurnOutcome? = nil,
                       workedFor: TimeInterval? = nil, needsInputKind: NeedsInputKind? = nil) {
        effects.append(SessionEffect(kind: kind, session: t.session, at: now, outcome: outcome, workedFor: workedFor,
                                     needsInputKind: needsInputKind))
        var detail = ""
        if let outcome { detail += " outcome=\(outcome.rawValue)" }
        if let workedFor { detail += " workedFor=\(Int(workedFor.rounded()))s" }
        if let needsInputKind { detail += " kind=\(needsInputKind.rawValue)" }
        note(.notice, "effect \(kind.rawValue) \(t.key)\(detail)")
    }

    // MARK: - Read side

    /// Every non-dropped session: `displayRank`, then most recent activity, then key.
    var sessionList: [AgentSession] {
        tracked.values.sorted { a, b in
            let ra = a.state.displayRank
            let rb = b.state.displayRank
            if ra != rb { return ra < rb }
            if a.lastActivityAt != b.lastActivityAt { return a.lastActivityAt > b.lastActivityAt }
            return a.key < b.key
        }.map(\.session)
    }

    var aggregate: SessionAggregate {
        SessionAggregate.compute(from: tracked.values.map(\.session), stateVersion: stateVersion,
                                 lastFinishedAt: lastFinishedAt)
    }

    /// Keys in a stable order (deterministic effect order when one input touches several sessions).
    var sortedKeys: [SessionKey] { tracked.keys.sorted() }

    // MARK: - Transitions (shared by every tier)

    /// How a session enters `.working`.
    enum WorkEntry: String {
        /// A new turn: resets per-turn tracking and stamps `turnStartedAt`.
        case newTurn
        /// A continuation inside the settle window: the candidate finish is void, the turn and its start remain.
        case continuation
        /// Waiting exit or stall recovery: the same turn goes on.
        case resume
        /// Settle expiry while the record still says busy (or background tasks run): back to working for the same
        /// turn, without progress, without a new state version, keeping the pending outcome.
        case hold
    }

    /// Moves `t` into `.working`, or refreshes progress when it already is.
    ///
    /// `stateVersion += 1` on every entry into working from a state that does not count as working (idle, waiting,
    /// stalled, a new session) and on a new prompt that arrives while settling; never for a continuation or a
    /// settle-expiry hold (ARCHITECTURE §8 "State version").
    /// - Parameters:
    ///   - turnStart: start of a new turn when known earlier than `now` (first qualifying T3 sample).
    ///   - newPrompt: the trigger is a new prompt (`turnStarted`), which bumps the version even from `.settling`.
    mutating func enterWorking(_ t: inout TrackedSession, now: Date, entry: WorkEntry, cause: String,
                               turnStart: Date? = nil, newPrompt: Bool = false) {
        let previous = t.session.state
        guard !previous.isEnded else { return }
        t.lastActivityAt = now
        if previous.isWorking {
            if entry != .hold { t.session.lastProgressAt = now }
            return
        }
        let since: Date
        switch entry {
        case .newTurn:
            let start = turnStart ?? now
            t.turn = TurnTracking(startedAt: start)
            since = start
        case .continuation:
            Self.clearFinish(&t.turn)
            if t.turn.startedAt == nil { t.turn.startedAt = turnStart ?? now }
            since = t.turn.startedAt ?? now
        case .resume:
            t.turn.awaitingTurnDuration = false
            if t.turn.startedAt == nil { t.turn.startedAt = turnStart ?? now }
            since = now
        case .hold:
            since = t.turn.startedAt ?? now
        }
        t.session.turnStartedAt = t.turn.startedAt
        t.session.state = .working(since: since)
        if entry != .hold { t.session.lastProgressAt = now }
        if t.session.lastProgressAt == nil { t.session.lastProgressAt = now }
        t.session.waitingFor = nil
        t.waitingExit.reset()
        t.everWorked = true
        var versionNote = ""
        if entry != .hold && (!previous.isSettling || newPrompt) {
            stateVersion += 1
            versionNote = " sv=\(stateVersion)"
        }
        note(.info, "\(t.key) \(previous.label) → working (\(cause), \(entry.rawValue))\(versionNote)")
    }

    /// Clears the candidate finish of a turn (a continuation voided it).
    static func clearFinish(_ turn: inout TurnTracking) {
        turn.stopSeen = false
        turn.pendingOutcome = nil
        turn.backgroundTasksRunning = false
        turn.awaitingTurnDuration = false
    }

    /// A finish edge on a session that is not in a turn: reuse the turn that went idle without a finish moments ago
    /// (record `idle` raced ahead of the `Stop` hook), otherwise start an anonymous turn (start unknown).
    mutating func prepareFinishingTurn(_ t: inout TrackedSession, now: Date) {
        guard t.session.state.isIdle else { return }
        let recent = t.idleSince.map { now.timeIntervalSince($0) <= Self.lateFinishWindow } ?? false
        if t.turn.finishEmitted || !recent || t.turn.startedAt == nil {
            t.turn = TurnTracking(startedAt: nil)
        }
        t.turn.awaitingTurnDuration = false
    }

    /// `turnFinished(o)` → `.settling(until: now + settle, outcome: o)`; `rateLimited` → `.idle(.rateLimited)` +
    /// `finished` at once (it never counts as working).
    mutating func enterSettling(_ t: inout TrackedSession, outcome: TurnOutcome, backgroundTasks: Bool, now: Date,
                                cause: String) {
        guard !t.session.state.isEnded else { return }
        prepareFinishingTurn(&t, now: now)
        t.turn.stopSeen = true
        t.turn.pendingOutcome = outcome
        t.turn.backgroundTasksRunning = backgroundTasks
        t.session.turnStartedAt = t.turn.startedAt
        t.session.lastProgressAt = now
        t.lastActivityAt = now
        if outcome == .rateLimited {
            finish(&t, outcome: .rateLimited, now: now, cause: cause)
            return
        }
        let previous = t.session.state
        t.session.state = .settling(until: now.addingTimeInterval(timers.settle), outcome: outcome)
        t.session.waitingFor = nil
        t.waitingExit.reset()
        note(.info, "\(t.key) \(previous.label) → settling (\(cause), \(outcome.rawValue)\(backgroundTasks ? ", background tasks" : ""))")
    }

    /// → `.idle(outcome)`; emits `finished` once per turn for every outcome except `.interrupted`.
    /// `workedFor` defaults to `now − turnStartedAt`; `lastTurnDuration` is updated whenever it is known.
    mutating func finish(_ t: inout TrackedSession, outcome: TurnOutcome, now: Date, workedFor: TimeInterval? = nil,
                         cause: String) {
        let worked = workedFor ?? t.turn.startedAt.map { max(0, now.timeIntervalSince($0)) }
        let previous = t.session.state
        t.session.state = .idle(since: now, outcome: outcome)
        t.session.waitingFor = nil
        t.idleSince = now
        t.heuristic.reset()
        t.heuristicHoldoffUntil = now.addingTimeInterval(Self.evidenceWindow)
        t.waitingExit.reset()
        t.turn.awaitingTurnDuration = false
        t.lastActivityAt = now
        if let worked { t.session.lastTurnDuration = worked }
        note(.info, "\(t.key) \(previous.label) → idle(\(outcome.rawValue)) (\(cause))")
        guard outcome != .interrupted, !t.turn.finishEmitted else { return }
        t.turn.finishEmitted = true
        lastFinishedAt = now
        emit(.finished, t, at: now, outcome: outcome, workedFor: worked)
    }

    /// → `.idle(outcome)` without any effect (waiting resolved by the record, heuristic exit).
    mutating func becomeIdle(_ t: inout TrackedSession, outcome: TurnOutcome?, now: Date, cause: String) {
        let previous = t.session.state
        t.session.state = .idle(since: now, outcome: outcome)
        t.session.waitingFor = nil
        t.idleSince = now
        t.heuristic.reset()
        t.waitingExit.reset()
        t.lastActivityAt = now
        note(.info, "\(t.key) \(previous.label) → idle(\(outcome?.rawValue ?? "nil")) (\(cause))")
    }

    /// → `.waiting(kind)` + one `needsInput` effect per wait (another needsInput while waiting only refreshes the text).
    mutating func enterWaiting(_ t: inout TrackedSession, kind: NeedsInputKind, text: String?, now: Date, cause: String) {
        guard !t.session.state.isEnded else { return }
        t.lastActivityAt = now
        let text = text.flatMap { $0.isEmpty ? nil : Self.capped($0) }
        if t.session.state.isWaiting {
            if let text { t.session.waitingFor = text }
            return
        }
        let previous = t.session.state
        t.session.state = .waiting(kind: kind, since: now)
        t.session.waitingFor = text
        Self.clearFinish(&t.turn)
        t.waitingExit.reset()
        note(.info, "\(t.key) \(previous.label) → waiting(\(kind.rawValue)) (\(cause))")
        emit(.needsInput, t, at: now, needsInputKind: kind)
    }

    /// → `.stalled(since: now)` + one `stalled` effect.
    mutating func stall(_ t: inout TrackedSession, now: Date) {
        let previous = t.session.state
        t.session.state = .stalled(since: now)
        t.session.tiers.insert(.guardrail)
        t.lastActivityAt = now
        let idleFor = t.session.lastProgressAt.map { Int(now.timeIntervalSince($0).rounded()) } ?? -1
        note(.notice, "\(t.key) \(previous.label) → stalled (no progress for \(idleFor)s)")
        emit(.stalled, t, at: now)
    }

    /// → `.ended(at: now)` + one `ended` effect.
    mutating func end(_ t: inout TrackedSession, reason: EndReason, now: Date) {
        guard !t.session.state.isEnded else { return }
        let previous = t.session.state
        t.session.state = .ended(at: now)
        t.session.waitingFor = nil
        t.endReason = reason
        t.heuristic.reset()
        t.waitingExit.reset()
        t.lastActivityAt = now
        if reason == .processGone || reason == .recordDead { t.session.tiers.insert(.guardrail) }
        if let identity = t.session.agentProcess { heuristicCandidates[identity] = nil }
        note(.info, "\(t.key) \(previous.label) → ended (\(reason.rawValue))")
        emit(.ended, t, at: now)
    }

    /// Brings an ended session back to `.idle` for a new life (resumed conversation, liveness verdict overturned).
    mutating func revive(_ t: inout TrackedSession, now: Date, cause: String) {
        t.session.state = .idle(since: now, outcome: nil)
        t.endReason = nil
        t.turn = TurnTracking()
        t.idleSince = now
        t.heuristic.reset()
        t.heuristicHoldoffUntil = nil
        t.waitingExit.reset()
        t.t2 = T2Tracking()
        t.t3 = T3Liveness()
        t.hooksLive = false
        t.everWorked = false
        t.session.waitingFor = nil
        t.lastActivityAt = now
        tombstones[t.key] = nil
        note(.info, "\(t.key) ended → idle (revived: \(cause))")
    }

    // MARK: - Binding & merging

    /// Binds `t` to `identity` and merges the fallback-keyed session of that process into it (re-keying, §8).
    /// - Parameter adoptState: `t` was just created by this input, so it takes over the fallback session's state.
    mutating func bind(_ t: inout TrackedSession, to identity: ProcessIdentity, adoptState: Bool, now: Date) {
        if t.session.agentProcess != identity {
            if let old = t.session.agentProcess {
                note(.info, "\(t.key) rebound \(old) → \(identity)")
            }
            t.session.agentProcess = identity
            t.t3 = T3Liveness()
            t.waitingExit.reset()
            t.heuristic.reset()
            if let snapshot = latestProcesses, snapshot.process(for: identity) != nil { t.t3.seen = true }
        }
        var merged = mergeFallback(into: &t, identity: identity, adoptState: adoptState, now: now)
        // T3 keys a heuristic session by the OUTERMOST same-agent process of a tree, a hook binds the NEAREST matched
        // ancestor: npm Codex (node `codex.js` wrapper → native `codex`) and Gemini (two node processes) are one agent
        // seen as two processes. The tree's heuristic session is this session too.
        guard !t.key.isProcessFallback else { return }
        for relative in sameAgentRelatives(of: identity, agent: t.key.agent) {
            let adopt = adoptState && !merged
            if mergeFallback(into: &t, identity: relative, adoptState: adopt, now: now, sameProcess: false) {
                merged = true
            }
        }
    }

    /// Matched processes of `agent` in the same process tree as `identity` (its ancestors and descendants, and every
    /// process listing it as a descendant) in the latest process snapshot, in a stable order.
    func sameAgentRelatives(of identity: ProcessIdentity, agent: AgentID) -> [ProcessIdentity] {
        guard let snapshot = latestProcesses else { return [] }
        var relatives = Set<ProcessIdentity>()
        if let p = snapshot.process(for: identity) {
            relatives.formUnion(p.ancestors.map(\.identity))
            relatives.formUnion(p.descendants)
        }
        for q in snapshot.agents where q.descendants.contains(identity) { relatives.insert(q.identity) }
        relatives.remove(identity)
        let sameAgent = Set(snapshot.agents.filter { $0.agent == agent }.map(\.identity))
        return relatives.filter { sameAgent.contains($0) }
            .sorted { ($0.pid, $0.startSec, $0.startUsec) < ($1.pid, $1.startSec, $1.startUsec) }
    }

    /// Merges `SessionKey.fallback(agent:identity:)` into `t` (no second session, no second push). Keeps the earliest
    /// `turnStartedAt` of a turn in progress and the union of tiers.
    /// - Parameter sameProcess: `identity` is the process `t` is bound to (else a same-agent relative, whose T3
    ///   liveness bookkeeping is not `t`'s).
    /// - Returns: a non-ended fallback session was merged.
    @discardableResult
    mutating func mergeFallback(into t: inout TrackedSession, identity: ProcessIdentity, adoptState: Bool, now: Date,
                                sameProcess: Bool = true) -> Bool {
        let fallbackKey = SessionKey.fallback(agent: t.key.agent, identity: identity)
        guard fallbackKey != t.key, let f = tracked[fallbackKey] else { return false }
        tracked[fallbackKey] = nil
        heuristicCandidates[identity] = nil
        guard !f.session.state.isEnded else { return false }
        t.session.tiers.formUnion(f.session.tiers)
        if t.session.host == nil { t.session.host = f.session.host }
        if t.session.cwd == nil { t.session.cwd = f.session.cwd }
        if t.session.title == nil { t.session.title = f.session.title }
        if t.session.lastMessagePreview == nil { t.session.lastMessagePreview = f.session.lastMessagePreview }
        if t.session.lastTurnDuration == nil { t.session.lastTurnDuration = f.session.lastTurnDuration }
        if let fh = f.session.lastHookAt { t.session.lastHookAt = max(t.session.lastHookAt ?? fh, fh) }
        for (k, v) in f.session.metadata where t.session.metadata[k] == nil {
            t.session.metadata[k] = v
        }
        t.hooksLive = t.hooksLive || f.hooksLive
        t.hasStartEdge = t.hasStartEdge || f.hasStartEdge
        let fallbackMidTurn = !f.session.state.isIdle
        let takeState = adoptState || (t.session.state.isIdle && fallbackMidTurn)
        if takeState {
            t.session.state = f.session.state
            t.session.waitingFor = f.session.waitingFor ?? t.session.waitingFor
            t.turn = f.turn
            t.heuristic = f.heuristic
            t.heuristicHoldoffUntil = f.heuristicHoldoffUntil
            t.waitingExit = f.waitingExit
            t.idleSince = f.idleSince
            t.everWorked = t.everWorked || f.everWorked
        } else if fallbackMidTurn, !t.session.state.isIdle, let fs = f.turn.startedAt {
            // Both saw the same turn: keep its earliest start.
            t.turn.startedAt = min(t.turn.startedAt ?? fs, fs)
        }
        t.session.turnStartedAt = t.turn.startedAt ?? t.session.turnStartedAt
        if let fp = f.session.lastProgressAt {
            t.session.lastProgressAt = max(t.session.lastProgressAt ?? fp, fp)
        }
        if sameProcess, f.t3.seen { t.t3 = f.t3 }
        t.lastActivityAt = max(t.lastActivityAt, f.lastActivityAt)
        note(.info, "merged \(fallbackKey) into \(t.key) (\(takeState ? "adopted \(f.session.state.label)" : "kept \(t.session.state.label)"))")
        return true
    }

    /// The unique non-ended, real-keyed session of `agent` bound to `identity` (routing of fallback-keyed events).
    func uniqueRealSession(agent: AgentID, boundTo identity: ProcessIdentity) -> SessionKey? {
        let matches = tracked.values.filter {
            $0.key.agent == agent && !$0.key.isProcessFallback && $0.session.agentProcess == identity
                && !$0.session.state.isEnded
        }
        return matches.count == 1 ? matches[0].key : nil
    }

    /// Identities bound to non-ended sessions → their agents.
    var boundAgents: [ProcessIdentity: Set<AgentID>] {
        var map: [ProcessIdentity: Set<AgentID>] = [:]
        for t in tracked.values where !t.session.state.isEnded {
            if let p = t.session.agentProcess { map[p, default: []].insert(t.key.agent) }
        }
        return map
    }

    /// Identities bound to non-ended REAL-keyed sessions (a fallback-bound process may still be claimed by a real key).
    var realBoundIdentities: Set<ProcessIdentity> {
        Set(tracked.values.compactMap { t in
            (!t.session.state.isEnded && !t.key.isProcessFallback) ? t.session.agentProcess : nil
        })
    }

    /// The outermost-process rule: no other matched process of the same agent has `p` among its descendants.
    static func isOutermost(_ p: AgentProcess, in snapshot: ProcessSnapshot) -> Bool {
        !snapshot.agents.contains { $0.identity != p.identity && $0.agent == p.agent && $0.descendants.contains(p.identity) }
    }

    /// Binds a session without `agentProcess` to the UNIQUE unbound, non-infrastructure, outermost, non-ignored
    /// process with the same agent and cwd in the latest process snapshot.
    mutating func bindByCwdIfPossible(_ t: inout TrackedSession, now: Date) {
        guard t.session.agentProcess == nil, !t.session.state.isEnded, let snapshot = latestProcesses,
              let cwd = Self.normalizedPath(t.session.cwd) else { return }
        let claimed = realBoundIdentities
        let candidates = snapshot.agents.filter { p in
            p.agent == t.key.agent && !p.isInfrastructure && !claimed.contains(p.identity)
                && !ignoredIdentities.contains(p.identity)
                && Self.normalizedPath(p.cwd) == cwd && Self.isOutermost(p, in: snapshot)
        }
        guard candidates.count == 1 else { return }
        let p = candidates[0]
        bind(&t, to: p.identity, adoptState: false, now: now)
        if t.session.host == nil { t.session.host = p.hostApp }
        note(.info, "\(t.key) bound to \(p.identity) by cwd")
    }

    // MARK: - Tombstones

    mutating func addTombstone(for t: TrackedSession, now: Date) {
        tombstones[t.key] = DismissalTombstone(identity: t.session.agentProcess, at: now)
        pruneTombstones(now: now)
    }

    mutating func pruneTombstones(now: Date) {
        tombstones = tombstones.filter { now.timeIntervalSince($0.value.at) < Self.tombstoneLifetime }
        if tombstones.count > Self.maxTombstones {
            let keep = tombstones.sorted { $0.value.at > $1.value.at }.prefix(Self.maxTombstones)
            tombstones = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    /// Identities of dismissed sessions: T3 never builds a heuristic session for them.
    var tombstonedIdentities: Set<ProcessIdentity> { Set(tombstones.values.compactMap(\.identity)) }

    // MARK: - Field helpers

    static func normalizedPath(_ path: String?) -> String? {
        guard var path, !path.isEmpty else { return nil }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static func capped(_ value: String) -> String {
        value.count > maxFieldLength ? String(value.prefix(maxFieldLength)) : value
    }

    static func cappedOrNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return capped(value)
    }

    /// Sets `metadata[transcriptPath]` and `metadata[sessionStoreDirectory]` (the path minus `.jsonl`).
    static func setTranscriptPath(_ t: inout TrackedSession, _ path: String) {
        guard !path.isEmpty else { return }
        let value = capped(path)
        t.session.metadata[MetadataKey.transcriptPath] = value
        if value.hasSuffix(".jsonl") {
            t.session.metadata[MetadataKey.sessionStoreDirectory] = String(value.dropLast(".jsonl".count))
        } else {
            t.session.metadata[MetadataKey.sessionStoreDirectory] = nil
        }
    }

    /// Merges producer metadata (latest wins for existing keys; new keys only while under the cap).
    static func mergeMetadata(_ t: inout TrackedSession, _ extra: [String: String]) {
        for key in extra.keys.sorted() {
            guard let value = extra[key], !key.isEmpty else { continue }
            let k = capped(key)
            if t.session.metadata[k] == nil, t.session.metadata.count >= maxMetadataEntries { continue }
            t.session.metadata[k] = capped(value)
        }
    }

    static func setMetadata(_ t: inout TrackedSession, _ key: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        t.session.metadata[key] = capped(value)
    }
}
