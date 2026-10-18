import KakurenekoKit
import Foundation

/// T1: normalized hook/plugin events (brief §5.2 rows "turnStarted", "activity", "turnFinished", "needsInput",
/// "idleReminder", "sessionEnded").
extension EngineState {
    mutating func ingest(_ event: AgentEvent, now: Date) {
        guard recentEventIDs.insert(event.id) else {
            note(.debug, "event \(event.id) already ingested; ignored")
            return
        }
        var key = event.sessionKey

        // Launch drain: an inbox file written while Kakureneko was not running describes the past (up to 5,000 files,
        // possibly days old). It may refresh the descriptive fields of a session that exists, but it never creates a
        // session, changes a state or produces an effect — a 3-day-old `Stop` would push a fresh "finished", a dead
        // agent's `turnStarted` would count as working.
        let age = event.receivedAt.timeIntervalSince(event.occurredAt)
        if age > Self.staleEventAge {
            if tracked[key] == nil, key.isProcessFallback, let process = event.agentProcess,
               let real = uniqueRealSession(agent: key.agent, boundTo: process) {
                key = real
            }
            if var t = tracked[key], !t.state.isEnded {
                Self.applyEventFields(&t, event)
                tracked[key] = t
            }
            note(.info, "\(key) \(event.rawEventName) from \(Int(age)) s ago (replayed): history only, no transition")
            return
        }

        // A fallback-keyed event from a process that a real-keyed session already owns belongs to that session.
        if key.isProcessFallback, tracked[key] == nil, let process = event.agentProcess,
           let real = uniqueRealSession(agent: key.agent, boundTo: process) {
            key = real
        }

        // Codex sub-threads: a finish for a thread that never worked, while another thread of the same process works,
        // is progress of that other thread (no phantom session, no finish push).
        if case .turnFinished = event.event, let process = event.agentProcess,
           !(tracked[key]?.everWorked ?? false),
           let siblingKey = workingSibling(of: key, process: process), var sibling = tracked[siblingKey] {
            sibling.hooksLive = true
            sibling.heuristic.belowSince = nil
            enterWorking(&sibling, now: now, entry: .continuation, cause: "sub-thread \(event.rawEventName)")
            tracked[siblingKey] = sibling
            note(.info, "\(key) finish treated as activity of \(siblingKey) (sub-thread)")
            return
        }

        var created = false
        var t: TrackedSession
        if let existing = tracked[key] {
            t = existing
        } else {
            if case .sessionEnded = event.event {
                note(.debug, "\(key) sessionEnded for an unknown session; ignored")
                return
            }
            t = TrackedSession(key: key, now: now)
            created = true
        }

        if t.state.isEnded {
            switch event.event {
            case .sessionEnded, .idleReminder:
                return
            default:
                if let reason = t.endReason, reason == .processGone || reason == .recordDead,
                   let process = event.agentProcess, process == t.session.agentProcess {
                    note(.debug, "\(key) late \(event.rawEventName) from the dead process; ignored")
                    return
                }
                revive(&t, now: now, cause: "T1 \(event.rawEventName)")
            }
        }

        if event.tier == .hook {
            t.hooksLive = true
            t.session.lastHookAt = now
        }
        t.session.tiers.insert(event.tier)
        t.lastActivityAt = now
        Self.applyEventFields(&t, event)
        if let process = event.agentProcess {
            bind(&t, to: process, adoptState: created, now: now)
        } else {
            bindByCwdIfPossible(&t, now: now)
        }

        let cause = "\(event.agent.rawValue) \(event.rawEventName)"
        switch event.event {
        case .sessionStarted:
            // Never changes the state of an existing session (`SessionStart source: compact` fires mid-turn).
            if t.state.isWorking || t.state.isSettling { t.session.lastProgressAt = now }
        case .turnStarted:
            t.hasStartEdge = true
            t.heuristic.belowSince = nil
            if t.state.isSettling {
                enterWorking(&t, now: now, entry: .continuation, cause: cause, newPrompt: true)
            } else {
                enterWorking(&t, now: now, entry: .newTurn, cause: cause, newPrompt: true)
            }
        case .activity:
            t.heuristic.belowSince = nil
            switch t.state {
            case .working:
                t.session.lastProgressAt = now
            case .settling:
                enterWorking(&t, now: now, entry: .continuation, cause: cause)
            case .waiting, .stalled:
                enterWorking(&t, now: now, entry: .resume, cause: cause)
            case .idle:
                if EngineAgentTraits.activityStartsTurn.contains(t.key.agent) || t.usesHeuristicTurns {
                    enterWorking(&t, now: now, entry: .newTurn, cause: cause)
                }
            case .ended:
                break
            }
        case .turnFinished(let outcome):
            enterSettling(&t, outcome: outcome, backgroundTasks: event.backgroundTasksRunning, now: now, cause: cause)
        case .needsInput(let kind):
            enterWaiting(&t, kind: kind, text: event.waitingFor, now: now, cause: cause)
        case .idleReminder:
            break // "still waiting": never a transition, never a second push
        case .sessionEnded:
            end(&t, reason: .sessionEnded, now: now)
        }
        tracked[key] = t
    }

    /// Another real-keyed `.working` session of the same agent bound to `process` (most recently active first).
    func workingSibling(of key: SessionKey, process: ProcessIdentity) -> SessionKey? {
        tracked.values
            .filter {
                $0.key != key && $0.key.agent == key.agent && !$0.key.isProcessFallback
                    && $0.session.agentProcess == process && $0.state.isWorking
            }
            .sorted { a, b in
                a.lastActivityAt != b.lastActivityAt ? a.lastActivityAt > b.lastActivityAt : a.key < b.key
            }
            .first?.key
    }

    /// Copies the descriptive fields of a T1 event (latest wins). Every string is capped (untrusted input).
    static func applyEventFields(_ t: inout TrackedSession, _ event: AgentEvent) {
        if let host = event.host { t.session.host = host }
        if let cwd = cappedOrNil(event.cwd) { t.session.cwd = cwd }
        if let title = cappedOrNil(event.title) { t.session.title = title }
        if let preview = cappedOrNil(event.messagePreview) {
            t.session.lastMessagePreview = TextSanitizer.truncate(preview, limit: TextSanitizer.defaultLimit)
        }
        if let path = event.transcriptPath { setTranscriptPath(&t, path) }
        mergeMetadata(&t, event.metadata)
    }
}
