import Foundation

/// T2 source for Claude Code: `~/.claude/sessions/*.json` (read-only watcher) + `claude agents --json --all`
/// poller (R02 §3, §8.1). Implemented by `KakurenekoSessions.ClaudeStateWatcher`.
///
/// Isolation: `final class … : Sendable` (Mutex state, private DispatchQueue for the FSEvents stream,
/// a Task for the poller). Never writes under `~/.claude`; never reads `*.key`; runs the CLI with
/// stdin `/dev/null`, `extraEnvironment: paths.agentSubprocessEnvironment` + `DISABLE_AUTOUPDATER=1` +
/// `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, via `SubprocessRunning` (`effect: .readOnly`).
///
/// Watching: Claude rewrites `<pid>.json` IN PLACE, which a directory vnode source does not report. Use FSEvents
/// on `paths.claudeSessionsDirectory` with `kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer`
/// (latency 0.2 s; or per-record `O_EVTONLY` vnode sources re-armed on directory changes), debounce 250 ms, PLUS
/// a cheap mtime sweep of `*.json` every `SamplingCadence.processScanInterval`.
public protocol ClaudeStateSource: Sendable {
    /// Starts the watcher (debounced ≥ 250 ms) and the poller. Idempotent. Callers subscribe first.
    func start() async
    func stop() async
    /// Fan-out stream of full snapshots: on start, on every `sessions/` change, and after every poll.
    func snapshots() -> AsyncStream<ClaudeStateSnapshot>
    /// Reads everything now (records + liveness + titles), without polling the CLI.
    func current() async -> ClaudeStateSnapshot
    /// Poll cadence for `claude agents --json --all` (15 s lid closed / 60 s open).
    func setCadence(_ cadence: SamplingCadence) async
}

/// The session state machine + timers + stall guard + aggregation (brief §5.1–5.6).
/// Implemented by `KakurenekoSessions.SessionEngine`.
///
/// Isolation: SYNCHRONOUS, deterministic, `final class … : Sendable` with a Mutex around all state.
/// No I/O, no clock reads, no tasks: every method takes `now`. The coordinator calls it from its
/// actor and acts on the returned effects. (Being synchronous is what makes replay tests possible,
/// e.g. the "13 h busy" record → `stalled` after 20 min.)
///
/// Transition precedence: liveness > state record > hook edges > heuristics (brief §5.2).
public protocol SessionTracking: Sendable {
    /// T1 event (from `AgentEventSource`). An `AgentEvent.id` already ingested (bounded set of the last 4,096
    /// ids) is ignored.
    func ingest(_ event: AgentEvent, now: Date) -> [SessionEffect]
    /// T2 Claude state (records + `agents --json`).
    func ingest(claudeState: ClaudeStateSnapshot, now: Date) -> [SessionEffect]
    /// T3 processes: liveness (NOTE_EXIT / start mismatch → ended), progress evidence (stall guard),
    /// heuristic sessions for hook-less agents (≥ 2 evidence kinds sustained 20 s → working; < 2 for the
    /// exit window → idle + `wentQuiet`).
    func ingest(processes: ProcessSnapshot, now: Date) -> [SessionEffect]
    /// Timers: settle expiry (→ finished), stall (→ stalled), heuristic exit, ended-retention drop.
    /// Call at least every 5 s (the coordinator's tick).
    func tick(now: Date) -> [SessionEffect]
    /// Applies new timer settings (takes effect for future deadlines).
    func updateTimers(_ timers: SessionTimers)
    /// User dismissed a session in the UI (e.g. a stuck one): mark it ended.
    func dismiss(_ key: SessionKey, now: Date) -> [SessionEffect]
    /// All non-dropped sessions (ended ones are kept for `endedRetention`).
    var sessions: [AgentSession] { get }
    var aggregate: SessionAggregate { get }
    func session(for key: SessionKey) -> AgentSession?
}
