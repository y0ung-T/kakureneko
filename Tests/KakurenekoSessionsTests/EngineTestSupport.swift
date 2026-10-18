@testable import KakurenekoSessions
import KakurenekoKit
import Foundation
import Testing

/// Fixtures on a virtual timeline: every time is "seconds after `F.t0`".
enum F {
    static let t0 = TestClock.defaultStart

    static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// Epoch milliseconds of `at(seconds)` (record timestamps).
    static func ms(_ seconds: TimeInterval) -> Double { at(seconds).timeIntervalSince1970 * 1000 }

    static func identity(_ pid: Int32, start: Int64 = 1_791_800_000, usec: Int32 = 0) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startSec: start, startUsec: usec)
    }

    static func key(_ id: String, _ agent: AgentID = .claude) -> SessionKey { SessionKey(agent: agent, id: id) }

    static func evidence(_ kinds: Set<EvidenceKind>, at seconds: TimeInterval) -> EvidenceSample {
        EvidenceSample(sampledAt: at(seconds), active: kinds)
    }

    static func process(_ identity: ProcessIdentity, _ agent: AgentID, kinds: Set<EvidenceKind> = [],
                        at seconds: TimeInterval = 0, cwd: String? = "/Users/me/proj", descendants: [ProcessIdentity] = [],
                        ancestors: [ProcessIdentity] = [], infrastructure: Bool = false, ideHost: Bool = false,
                        host: HostApp? = nil) -> AgentProcess {
        AgentProcess(identity: identity, agent: agent, argv0: agent.rawValue, cwd: cwd, ppid: 1,
                     ancestors: ancestors.map { AncestorInfo(identity: $0) }, hostApp: host, descendants: descendants,
                     isInfrastructure: infrastructure, isIDEHost: ideHost,
                     evidence: evidence(kinds, at: seconds), firstSeen: at(0))
    }

    static func record(pid: Int32, session: String? = "s1", status: String? = "busy", statusAt: TimeInterval? = 0,
                       waitingFor: String? = nil, kind: String? = "interactive", cwd: String? = "/Users/me/proj",
                       name: String? = nil, nameSource: String? = nil, jobId: String? = nil, entrypoint: String? = "cli",
                       bridge: String? = nil, parked: String? = nil, spare: Bool? = nil) -> ClaudeSessionRecord {
        ClaudeSessionRecord(pid: pid, sessionId: session, cwd: cwd, startedAt: nil, procStart: nil, version: "2.1.296",
                            kind: kind, entrypoint: entrypoint, status: status, waitingFor: waitingFor,
                            statusUpdatedAt: statusAt.map(ms), updatedAt: statusAt.map(ms), name: name,
                            nameSource: nameSource, jobId: jobId, parkedJobId: parked, spare: spare,
                            bridgeSessionId: bridge)
    }

    static func observation(_ record: ClaudeSessionRecord, _ identity: ProcessIdentity?, transcript: String? = nil,
                            title: String? = nil, currentCwd: String? = nil, preview: String? = nil,
                            turnCompletedAt: TimeInterval? = nil, durationMs: Double? = nil,
                            pending: Int? = nil) -> ClaudeSessionObservation {
        ClaudeSessionObservation(record: record, identity: identity, transcriptPath: transcript, title: title,
                                 currentCwd: currentCwd, lastAssistantPreview: preview,
                                 lastTurnCompletedAt: turnCompletedAt.map(at), lastTurnDurationMs: durationMs,
                                 lastTurnPendingBackground: pending)
    }

    /// A live Claude record bound to `identity`, in one call.
    static func live(_ identity: ProcessIdentity, session: String = "s1", status: String? = "busy",
                     statusAt: TimeInterval? = 0, waitingFor: String? = nil, turnCompletedAt: TimeInterval? = nil,
                     durationMs: Double? = nil, pending: Int? = nil) -> ClaudeSessionObservation {
        observation(record(pid: identity.pid, session: session, status: status, statusAt: statusAt, waitingFor: waitingFor),
                    identity, turnCompletedAt: turnCompletedAt, durationMs: durationMs, pending: pending)
    }
}

/// Drives one `SessionEngine` along the virtual timeline and keeps every effect it returned.
final class EngineDriver {
    let engine: SessionEngine
    private(set) var effects: [SessionEffect] = []
    private var nextEventID = 0

    init(timers: SessionTimers = SessionTimers(), initialStateVersion: Int = 0) {
        engine = SessionEngine(timers: timers, initialStateVersion: initialStateVersion)
    }

    /// Drives a preconfigured engine (e.g. one with a liveness lookup).
    init(engine: SessionEngine) {
        self.engine = engine
    }

    @discardableResult
    func send(_ event: NormalizedEvent, at seconds: TimeInterval, agent: AgentID = .claude, session: String = "s1",
              key: SessionKey? = nil, process: ProcessIdentity? = nil, cwd: String? = nil, background: Bool = false,
              waitingFor: String? = nil, title: String? = nil, preview: String? = nil, transcriptPath: String? = nil,
              host: HostApp? = nil, metadata: [String: String] = [:], id: String? = nil) -> [SessionEffect] {
        nextEventID += 1
        let event = AgentEvent(
            id: id ?? "\(nextEventID)-event", agent: agent, event: event, rawEventName: event.typeName,
            sessionKey: key ?? SessionKey(agent: agent, id: session), agentProcess: process, host: host, cwd: cwd,
            title: title, messagePreview: preview, waitingFor: waitingFor, backgroundTasksRunning: background,
            transcriptPath: transcriptPath, occurredAt: F.at(seconds), receivedAt: F.at(seconds), metadata: metadata)
        return record(engine.ingest(event, now: F.at(seconds)))
    }

    @discardableResult
    func claude(at seconds: TimeInterval, _ observations: [ClaudeSessionObservation], agents: [ClaudeAgentsEntry]? = nil,
                polledAt: TimeInterval? = nil, readable: Bool = true, ignored: [ProcessIdentity] = []) -> [SessionEffect] {
        let snapshot = ClaudeStateSnapshot(takenAt: F.at(seconds), sessions: observations, agents: agents,
                                           agentsPolledAt: polledAt.map(F.at), sessionsDirectoryReadable: readable,
                                           ignoredIdentities: ignored)
        return record(engine.ingest(claudeState: snapshot, now: F.at(seconds)))
    }

    @discardableResult
    func processes(at seconds: TimeInterval, _ agents: [AgentProcess]) -> [SessionEffect] {
        record(engine.ingest(processes: ProcessSnapshot(takenAt: F.at(seconds), agents: agents), now: F.at(seconds)))
    }

    @discardableResult
    func tick(at seconds: TimeInterval) -> [SessionEffect] {
        record(engine.tick(now: F.at(seconds)))
    }

    /// Ticks at `from`, `from + step`, … ≤ `through`.
    @discardableResult
    func tick(from: TimeInterval, through: TimeInterval, step: TimeInterval = 1) -> [SessionEffect] {
        var out: [SessionEffect] = []
        var t = from
        while t <= through + 1e-9 {
            out += tick(at: t)
            t += step
        }
        return out
    }

    @discardableResult
    func dismiss(_ key: SessionKey, at seconds: TimeInterval) -> [SessionEffect] {
        record(engine.dismiss(key, now: F.at(seconds)))
    }

    func state(_ key: SessionKey = F.key("s1")) -> SessionState? { engine.session(for: key)?.state }
    func session(_ key: SessionKey = F.key("s1")) -> AgentSession? { engine.session(for: key) }
    var aggregate: SessionAggregate { engine.aggregate }
    var stateVersion: Int { engine.aggregate.stateVersion }
    func effects(_ kind: SessionEffect.Kind) -> [SessionEffect] { effects.filter { $0.kind == kind } }
    var kinds: [SessionEffect.Kind] { effects.map(\.kind) }

    private func record(_ new: [SessionEffect]) -> [SessionEffect] {
        effects += new
        return new
    }
}

extension SessionState {
    /// `.idle` with exactly this outcome.
    func isIdle(outcome expected: TurnOutcome?) -> Bool {
        if case .idle(_, let outcome) = self { return outcome == expected }
        return false
    }
}
