import KakurenekoCloud
import KakurenekoKit
import Foundation

/// The Mac's state as the iPhone app shows it (docs/NATIVE-NOTIFICATIONS.md §4.3): a `MacStatusReport` built from
/// the published snapshot. Pure; the coordinator hands every changed report to Notify, which saves it debounced.
enum PhoneStatusBuilder {
    /// A phase the snapshot cannot know yet: the coordinator reports it right before the Mac goes dark.
    enum Final: Sendable, Hashable {
        case asleep
        case shutDown
        case quit
    }

    static func report(from snapshot: AppSnapshot, effectiveLidClosed: Bool, final: Final? = nil) -> MacStatusReport {
        let aggregate = snapshot.aggregate
        // The Private detail level names no project or app on the iPhone either: only which agents do what.
        let hideNames = snapshot.settings.notifications.detailLevel == .private
        let agents = snapshot.sessions.filter { !$0.state.isEnded }.map { session in
            var summary = agentSummary(session)
            if hideNames {
                summary.project = nil
                summary.host = nil
            }
            return summary
        }
        let phase = self.phase(snapshot, final: final)
        let power = snapshot.power
        return MacStatusReport(
            phase: phase,
            headline: headline(phase, aggregate: aggregate, keepAwakeUntil: snapshot.keepAwakeUntil),
            detail: detail(phase, snapshot: snapshot),
            countdownEndsAt: countdownEnd(phase, snapshot: snapshot),
            keepAwakeUntil: final == nil ? snapshot.keepAwakeUntil : nil,
            agents: final == nil ? agents : [],
            batteryPercent: power?.batteryPercent,
            onBattery: power.map { $0.batteryPercent != nil && !$0.onAC } ?? false,
            lidClosed: effectiveLidClosed,
            stateVersion: aggregate.stateVersion,
            keepAwakeSeconds: snapshot.settings.power.keepAwakeButtonSeconds,
            shutdownEnabled: snapshot.settings.power.shutdownEnabled,
            canSleep: final == nil && snapshot.mode != .disabled && snapshot.mode != .starting)
    }

    /// When the countdown on the phone ends: the sleep countdown, or the shutdown grace.
    static func countdownEnd(_ phase: MacPhase, snapshot: AppSnapshot) -> Date? {
        switch (phase, snapshot.powerPhase) {
        case (.countdown, .countdown(let endsAt, _, _)): endsAt
        case (.shutdownPending, .shutdownPending(let at, _)): at
        default: nil
        }
    }

    static func phase(_ snapshot: AppSnapshot, final: Final?) -> MacPhase {
        switch final {
        case .asleep: return .asleep
        case .shutDown: return .shutDown
        case .quit: return .off
        case nil: break
        }
        if snapshot.mode == .disabled { return .off }
        switch snapshot.powerPhase {
        case .closedAwake: return .lidClosedAwake
        case .countdown: return .countdown
        case .shutdownPending: return .shutdownPending
        case .windingDown: return .windingDown
        case .armed, .disarmed:
            let aggregate = snapshot.aggregate
            return aggregate.anyWorking || aggregate.anyWaiting || aggregate.stalledCount > 0 ? .working : .idle
        }
    }

    static func headline(_ phase: MacPhase, aggregate: SessionAggregate, keepAwakeUntil: Date?) -> String {
        let activity = activityText(aggregate)
        switch phase {
        case .off: return "\(KakurenekoID.appName) is off"
        case .idle: return keepAwakeUntil == nil ? "No agents working" : "Keeping awake"
        case .working: return activity ?? "Agents active"
        case .lidClosedAwake: return "Lid closed · " + (activity ?? "keeping awake")
        case .countdown: return "Going to sleep soon"
        case .shutdownPending: return "Shutting down soon"
        case .windingDown: return "Going to sleep"
        case .asleep: return "Asleep"
        case .shutDown: return "Shut down"
        }
    }

    /// "2 agents working · 1 waiting" (nil when nothing is active).
    static func activityText(_ aggregate: SessionAggregate) -> String? {
        var parts: [String] = []
        if aggregate.workingCount > 0 { parts.append(aggregate.workingCount == 1 ? "1 agent working" : "\(aggregate.workingCount) agents working") }
        if aggregate.waitingCount > 0 { parts.append("\(aggregate.waitingCount) waiting") }
        if aggregate.stalledCount > 0 { parts.append("\(aggregate.stalledCount) stuck") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func detail(_ phase: MacPhase, snapshot: AppSnapshot) -> String? {
        let paused = snapshot.pausedApps.count
        let pausedText = paused == 0 ? nil : (paused == 1 ? "1 app slowed down." : "\(paused) apps slowed down.")
        switch phase {
        case .lidClosedAwake:
            return ["Keeping your Mac awake for the agents.", pausedText].compactMap { $0 }.joined(separator: " ")
        case .countdown:
            guard case .countdown(_, let reason, _) = snapshot.powerPhase else { return nil }
            switch reason {
            case .finished: return "All agents are done."
            case .needsInput: return "An agent is waiting for you."
            case .wentQuiet: return "The agents went quiet."
            }
        case .working:
            switch snapshot.mode {
            case .full: return "Close the lid any time: \(KakurenekoID.appName) keeps the Mac awake."
            case .notificationsOnly: return "Closed-lid mode isn't installed on this Mac."
            case .starting, .disabled: return nil
            }
        case .shutdownPending, .windingDown:
            return snapshot.settings.power.shutdownEnabled && phase == .shutdownPending ? "Tap Keep awake to cancel." : nil
        case .off, .idle, .asleep, .shutDown:
            return nil
        }
    }

    static func agentSummary(_ session: AgentSession) -> AgentSummary {
        let activity: AgentSummary.Activity
        var since: Date?
        var note: String?
        switch session.state {
        case .working(let start):
            activity = .working
            since = session.turnStartedAt ?? start
        case .settling:
            activity = .working
            since = session.turnStartedAt
        case .waiting(let kind, let start):
            activity = .waiting
            since = start
            note = waitingNote(kind)
        case .idle(let start, let outcome):
            activity = outcome == nil ? .idle : .finished
            since = start
        case .stalled(let start):
            activity = .stalled
            since = start
        case .ended(let at):
            activity = .idle
            since = at
        }
        return AgentSummary(agent: session.agent.displayName, project: session.projectName, host: session.host?.name,
                            activity: activity, since: since, note: note)
    }

    static func waitingNote(_ kind: NeedsInputKind) -> String {
        switch kind {
        case .permission: "Needs permission"
        case .question: "Asked a question"
        case .dialog: "Waiting in a dialog"
        case .unknown: "Waiting for you"
        }
    }
}
