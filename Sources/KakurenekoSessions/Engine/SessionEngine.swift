import KakurenekoKit
import Foundation
import Synchronization

/// The session state machine + timers + stall guard + aggregation (brief §5.1–5.6, ARCHITECTURE §9.3).
///
/// Synchronous and deterministic: no clock reads, no I/O, no tasks — every input carries `now`, which makes replay
/// tests possible (the "13 h busy" record → `.stalled` exactly 20 min later). All state is one `EngineState` value in
/// a `Mutex`; log lines produced under the lock are written after it is released.
///
/// Precedence: liveness > state record > hook edges > heuristics. `aggregate.stateVersion` starts at
/// `initialStateVersion` (launch epoch ms in production) and increments on every entry into `.working` for a new turn.
public final class SessionEngine: SessionTracking {
    private let state: Mutex<EngineState>
    private let logger: KakurenekoLogger

    /// Binding signature (+ `processes`, appended with a default).
    /// - Parameter processes: point liveness lookup for a bound process that no process snapshot ever contained
    ///   (brief §3.2 T4: start-time match). `nil` keeps the T3-only rule (such a session is never ended by T3).
    public init(timers: SessionTimers = SessionTimers(), logger: KakurenekoLogger = KakurenekoLogger(.sessions),
                initialStateVersion: Int = 0, processes: (any ProcessLookup)? = nil) {
        state = Mutex(EngineState(timers: timers, stateVersion: initialStateVersion, liveness: processes))
        self.logger = logger
    }

    public func ingest(_ event: AgentEvent, now: Date) -> [SessionEffect] {
        mutate { $0.ingest(event, now: now) }
    }

    public func ingest(claudeState: ClaudeStateSnapshot, now: Date) -> [SessionEffect] {
        mutate { $0.ingest(claudeState: claudeState, now: now) }
    }

    public func ingest(processes: ProcessSnapshot, now: Date) -> [SessionEffect] {
        mutate { $0.ingest(processes: processes, now: now) }
    }

    public func tick(now: Date) -> [SessionEffect] {
        mutate { $0.tick(now: now) }
    }

    public func updateTimers(_ timers: SessionTimers) {
        state.withLock { $0.timers = timers }
        logger.info("timers updated: stall \(timers.stallMinutes) min, heuristic exit \(timers.heuristicExitMinutes) min")
    }

    public func dismiss(_ key: SessionKey, now: Date) -> [SessionEffect] {
        mutate { $0.dismiss(key, now: now) }
    }

    public var sessions: [AgentSession] { state.withLock { $0.sessionList } }

    public var aggregate: SessionAggregate { state.withLock { $0.aggregate } }

    public func session(for key: SessionKey) -> AgentSession? { state.withLock { $0.tracked[key]?.session } }

    // MARK: - Internal (tests)

    /// Runs `body` under the lock, then logs its notes and returns its effects.
    private func mutate(_ body: (inout EngineState) -> Void) -> [SessionEffect] {
        let (effects, notes) = state.withLock { s -> ([SessionEffect], [EngineNote]) in
            body(&s)
            return s.drainOutputs()
        }
        for note in notes { logger.log(note.level, note.message) }
        return effects
    }

    /// Read access to the engine's private per-session state (tests only).
    func withState<R: Sendable>(_ body: (EngineState) -> R) -> R { state.withLock { body($0) } }
}
