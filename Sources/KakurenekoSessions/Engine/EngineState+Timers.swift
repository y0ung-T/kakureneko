import KakurenekoKit
import Foundation

/// Time-driven transitions: settle expiry, the late `turn_duration` window, heuristic exit, the stall guard
/// (brief §5.5) and the ended-retention drop; plus user dismissal.
extension EngineState {
    mutating func tick(now: Date) {
        for key in sortedKeys {
            guard var t = tracked[key] else { continue }
            settleExpiry(&t, now: now)
            if t.turn.awaitingTurnDuration, let idleSince = t.idleSince,
               now.timeIntervalSince(idleSince) > Self.lateFinishWindow {
                t.turn.awaitingTurnDuration = false
            }
            heuristicExitIfQuiet(&t, now: now)
            stallGuard(&t, now: now)
            tracked[key] = t
        }
        dropExpiredEndedSessions(now: now)
        pruneTombstones(now: now)
    }

    /// Settle expiry (ARCHITECTURE §9.3): a continuation already moved the session to working; background tasks keep
    /// it working; a Claude record that is still busy holds it in working (same turn, no effect, no new state
    /// version, pending outcome kept — the record going idle finishes it); otherwise `.idle(o)` + `finished`.
    private mutating func settleExpiry(_ t: inout TrackedSession, now: Date) {
        guard case .settling(let until, let outcome) = t.state, now >= until else { return }
        if t.turn.backgroundTasksRunning {
            enterWorking(&t, now: now, entry: .hold, cause: "background tasks running")
        } else if t.t2.present, t.t2.status == .busy {
            enterWorking(&t, now: now, entry: .hold, cause: "record still busy")
        } else {
            finish(&t, outcome: outcome, now: now, cause: "settle expired")
        }
    }

    /// `(working ∨ settling) ∧ now − lastProgressAt ≥ stall` → `.stalled` + one `stalled` effect.
    private mutating func stallGuard(_ t: inout TrackedSession, now: Date) {
        guard t.state.isWorking || t.state.isSettling else { return }
        let lastProgress = t.session.lastProgressAt ?? t.session.turnStartedAt ?? now
        guard now.timeIntervalSince(lastProgress) >= timers.stall else { return }
        stall(&t, now: now)
    }

    private mutating func dropExpiredEndedSessions(now: Date) {
        for key in sortedKeys {
            guard let endedAt = tracked[key]?.endedAt, now.timeIntervalSince(endedAt) >= timers.endedRetention else { continue }
            tracked[key] = nil
            note(.debug, "\(key) dropped (ended \(Int(now.timeIntervalSince(endedAt)))s ago)")
        }
    }

    /// User dismissal: `.ended` + `ended` effect; a tombstone keeps T2/T3 from resurrecting the same process.
    mutating func dismiss(_ key: SessionKey, now: Date) {
        guard var t = tracked[key], !t.state.isEnded else { return }
        end(&t, reason: .dismissed, now: now)
        addTombstone(for: t, now: now)
        tracked[key] = t
    }
}
