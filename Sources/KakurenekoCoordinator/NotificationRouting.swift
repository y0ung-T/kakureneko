// SessionEffect → NotificationIntent (ARCHITECTURE §9.8 "Notification routing", brief §8.4) and the small text /
// presence helpers the coordinator needs. Pure functions; KakurenekoNotify owns templates and policy.

import KakurenekoKit
import Foundation

enum NotificationRouting {
    /// The intent for one engine effect. `.ended` produces nothing by itself (a session that ended while waiting
    /// is resolved through the waiting-set diff, see `resolvedKeys`).
    /// - Parameters:
    ///   - workingCount: sessions still working after the effect (`finished` "N agents still running").
    ///   - awakeUntil: how long the Mac stays awake for a waiting session (nil when it does not, e.g. notifications only).
    ///   - sleepsAt: the running countdown's end (for "went quiet … sleeps in {m} min").
    static func intent(for effect: SessionEffect, workingCount: Int, awakeUntil: Date?, sleepsAt: Date?) -> NotificationIntent? {
        switch effect.kind {
        case .finished: .finished(effect, stillRunning: workingCount)
        case .needsInput: .needsInput(effect, awakeUntil: awakeUntil)
        case .stalled: .stalled(effect)
        case .wentQuiet: .wentQuiet(effect, sleepsAt: sleepsAt)
        case .ended: nil
        }
    }

    /// Keys that left `.waiting` between two observations (answered, working again, ended or dropped).
    /// The notification settings Notify gets: the user's, but switched off while Kakureneko itself is off (Notify then
    /// drops its pending reminders, batch, digest and queued pushes; the test message still goes out).
    static func effectiveNotificationSettings(_ settings: KakurenekoSettings) -> NotificationSettings {
        var notifications = settings.notifications
        notifications.enabled = notifications.enabled && settings.general.enabled
        return notifications
    }

    static func resolvedKeys(previouslyWaiting: Set<SessionKey>, nowWaiting: Set<SessionKey>) -> [SessionKey] {
        previouslyWaiting.subtracting(nowWaiting).sorted()
    }

    /// When a wait started: the `.waiting(_, since)` of the effect's session snapshot, else the effect time.
    static func waitingSince(_ effect: SessionEffect) -> Date {
        if case .waiting(_, let since) = effect.session.state { return since }
        return effect.at
    }

    /// The "Mac stays awake until" time for a wait that began at `since`: the needs-input window, extended by a
    /// longer keep-awake override. Nil when Kakureneko cannot keep the Mac awake (not armable).
    static func awakeUntil(waitingSince since: Date, timers: SessionTimers, keepAwakeUntil: Date?, canKeepAwake: Bool) -> Date? {
        guard canKeepAwake else { return nil }
        let window = since.addingTimeInterval(timers.needsInputCountdown)
        if let keepAwakeUntil, keepAwakeUntil > window { return keepAwakeUntil }
        return window
    }

    /// A `.needsInput` effect for a session that is still waiting (re-submitted on every present → away
    /// transition; KakurenekoNotify dedupes on `(sessionKey, waiting since)`).
    static func resubmittedNeedsInput(for session: AgentSession) -> SessionEffect? {
        guard case .waiting(let kind, let since) = session.state else { return nil }
        return SessionEffect(kind: .needsInput, session: session, at: since, needsInputKind: kind)
    }

    /// "<Agent> in <project> is busy again" for a sleep/shutdown command minted before the state version moved.
    /// Names the session that most recently (re)started a turn; falls back to a generic sentence.
    static func busyAgainReason(sessions: [AgentSession]) -> String {
        let live = sessions.filter { !$0.state.isEnded }
        let busy = live.filter { $0.state.isWorking || $0.state.isSettling || $0.state.isWaiting }
        let pool = busy.isEmpty ? live : busy
        let latest = pool.max { lhs, rhs in
            (lhs.turnStartedAt ?? .distantPast, lhs.key) < (rhs.turnStartedAt ?? .distantPast, rhs.key)
        }
        guard let session = latest else { return "An agent became busy again" }
        if let project = session.projectName { return "\(session.agent.displayName) in \(project) is busy again" }
        return "\(session.agent.displayName) is busy again"
    }

    /// Presence for notification gating (brief §8.5). Clamshell desktop (lid closed + external display) counts as
    /// lid OPEN, like everywhere else in the coordinator.
    static func presence(effectiveLidClosed: Bool, screenLocked: Bool?, secondsSinceUserInput: TimeInterval?,
                         hasLid: Bool = true) -> Presence {
        Presence(lidClosed: effectiveLidClosed, screenLocked: screenLocked ?? false, secondsSinceUserInput: secondsSinceUserInput,
                 hasLid: hasLid)
    }
}
