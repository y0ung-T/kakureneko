import KakurenekoCloud
@testable import KakurenekoCoordinator
import KakurenekoKit
import Foundation
import Testing

/// What the iPhone app shows for this Mac (pure, docs/NATIVE-NOTIFICATIONS.md §4.3).
@Suite("Phone status builder (pure)")
struct PhoneStatusBuilderTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func snapshot(_ phase: PowerPhase = .disarmed, sessions: [AgentSession] = [], mode: OperatingMode = .full) -> AppSnapshot {
        var s = AppSnapshot(generatedAt: now, mode: mode, sessions: sessions,
                            aggregate: SessionAggregate.compute(from: sessions, stateVersion: 9, lastFinishedAt: nil),
                            powerPhase: phase,
                            power: PowerSnapshot(takenAt: now, lid: .open, batteryPercent: 64, onAC: false))
        s.settings.power.keepAwakeButtonSeconds = 1800
        return s
    }

    var working: AgentSession {
        Fixture.session("w", state: .working(since: now.addingTimeInterval(-60)), hostPID: 7, turnStartedAt: now.addingTimeInterval(-600))
    }

    @Test func phasesFollowThePowerPhaseAndTheMode() {
        #expect(PhoneStatusBuilder.phase(snapshot(), final: nil) == .idle)
        #expect(PhoneStatusBuilder.phase(snapshot(sessions: [working]), final: nil) == .working)
        #expect(PhoneStatusBuilder.phase(snapshot(.armed(since: now), sessions: [working]), final: nil) == .working)
        #expect(PhoneStatusBuilder.phase(snapshot(.closedAwake(since: now)), final: nil) == .lidClosedAwake)
        #expect(PhoneStatusBuilder.phase(snapshot(.countdown(endsAt: now, reason: .finished, closedSince: now)), final: nil) == .countdown)
        #expect(PhoneStatusBuilder.phase(snapshot(.shutdownPending(at: now, requestedFromPhone: true)), final: nil) == .shutdownPending)
        #expect(PhoneStatusBuilder.phase(snapshot(.windingDown(reason: .remoteSleep, since: now)), final: nil) == .windingDown)
        #expect(PhoneStatusBuilder.phase(snapshot(.closedAwake(since: now), mode: .disabled), final: nil) == .off)
        #expect(PhoneStatusBuilder.phase(snapshot(sessions: [working]), final: .asleep) == .asleep)
        #expect(PhoneStatusBuilder.phase(snapshot(), final: .shutDown) == .shutDown)
        #expect(PhoneStatusBuilder.phase(snapshot(), final: .quit) == .off)
    }

    @Test func aWorkingMacWithTheLidClosed() {
        var s = snapshot(.closedAwake(since: now), sessions: [working])
        s.pausedApps = [PausedApp(appPID: 1, bundleID: "a", name: "Arc", mode: .throttle, memberCount: 3, pausedAt: now),
                        PausedApp(appPID: 2, bundleID: "b", name: "Slack", mode: .throttle, memberCount: 1, pausedAt: now)]
        s.keepAwakeUntil = now.addingTimeInterval(3600)
        let report = PhoneStatusBuilder.report(from: s, effectiveLidClosed: true)
        #expect(report.phase == .lidClosedAwake)
        #expect(report.headline == "Lid closed · 1 agent working")
        #expect(report.detail == "Keeping your Mac awake for the agents. 2 apps slowed down.")
        #expect(report.lidClosed && report.onBattery && report.batteryPercent == 64)
        #expect(report.keepAwakeUntil == now.addingTimeInterval(3600))
        #expect(report.stateVersion == 9 && report.keepAwakeSeconds == 1800 && report.canSleep)
        #expect(report.agents == [AgentSummary(agent: "Claude Code", project: "api", host: "VS Code", activity: .working,
                                               since: now.addingTimeInterval(-600))])
    }

    @Test func thePrivateDetailLevelNamesNoProjectOrApp() {
        var s = snapshot(.closedAwake(since: now), sessions: [working])
        s.settings.notifications.detailLevel = .private
        let report = PhoneStatusBuilder.report(from: s, effectiveLidClosed: true)
        #expect(report.agents == [AgentSummary(agent: "Claude Code", project: nil, host: nil, activity: .working,
                                               since: now.addingTimeInterval(-600))])
        #expect(report.headline == "Lid closed · 1 agent working")
    }

    @Test func countdownReasonsAndEnd() {
        let ends = now.addingTimeInterval(300)
        for (reason, detail) in [(CountdownReason.finished, "All agents are done."), (.needsInput, "An agent is waiting for you."),
                                 (.wentQuiet, "The agents went quiet.")] {
            let report = PhoneStatusBuilder.report(from: snapshot(.countdown(endsAt: ends, reason: reason, closedSince: now)),
                                                   effectiveLidClosed: true)
            #expect(report.headline == "Going to sleep soon")
            #expect(report.detail == detail)
            #expect(report.countdownEndsAt == ends)
        }
        #expect(PhoneStatusBuilder.report(from: snapshot(), effectiveLidClosed: false).countdownEndsAt == nil)
        let grace = PhoneStatusBuilder.report(from: snapshot(.shutdownPending(at: ends, requestedFromPhone: true)), effectiveLidClosed: true)
        #expect(grace.phase == .shutdownPending && grace.countdownEndsAt == ends, "the phone counts down to the shutdown too")
    }

    @Test func headlinesAndDetails() {
        let waiting = Fixture.session("q", agent: .codex, state: .waiting(kind: .permission, since: now))
        let stalled = Fixture.session("s", state: .stalled(since: now))
        let busy = snapshot(sessions: [working, waiting, stalled])
        #expect(PhoneStatusBuilder.report(from: busy, effectiveLidClosed: false).headline == "1 agent working · 1 waiting · 1 stuck")
        #expect(PhoneStatusBuilder.report(from: busy, effectiveLidClosed: false).detail
                == "Close the lid any time: Kakureneko keeps the Mac awake.")
        #expect(PhoneStatusBuilder.report(from: snapshot(sessions: [working], mode: .notificationsOnly), effectiveLidClosed: false).detail
                == "Closed-lid mode isn't installed on this Mac.")
        var keepingAwake = snapshot()
        keepingAwake.keepAwakeUntil = now.addingTimeInterval(60)
        #expect(PhoneStatusBuilder.report(from: keepingAwake, effectiveLidClosed: false).headline == "Keeping awake")
        #expect(PhoneStatusBuilder.report(from: snapshot(), effectiveLidClosed: false).headline == "No agents working")
        #expect(PhoneStatusBuilder.report(from: snapshot(mode: .disabled), effectiveLidClosed: false).headline == "Kakureneko is off")
        #expect(PhoneStatusBuilder.report(from: snapshot(mode: .disabled), effectiveLidClosed: false).canSleep == false)
    }

    @Test func agentActivities() {
        let finished = Fixture.session("f", state: .idle(since: now, outcome: .completed))
        let idle = Fixture.session("i", state: .idle(since: now, outcome: nil))
        let waiting = Fixture.session("q", agent: .codex, state: .waiting(kind: .question, since: now))
        let settling = Fixture.session("t", state: .settling(until: now, outcome: .completed), turnStartedAt: now.addingTimeInterval(-5))
        let agents = [finished, idle, waiting, settling].map(PhoneStatusBuilder.agentSummary)
        #expect(agents.map(\.activity) == [.finished, .idle, .waiting, .working])
        #expect(agents[2].note == "Asked a question" && agents[2].agent == "Codex")
        #expect(agents[3].since == now.addingTimeInterval(-5))
        #expect(PhoneStatusBuilder.waitingNote(.permission) == "Needs permission")
    }

    @Test func theFinalStatusIsBare() {
        var s = snapshot(.windingDown(reason: .countdownElapsed, since: now), sessions: [working])
        s.keepAwakeUntil = now.addingTimeInterval(60)
        let report = PhoneStatusBuilder.report(from: s, effectiveLidClosed: true, final: .asleep)
        #expect(report.phase == .asleep && report.headline == "Asleep")
        #expect(report.agents.isEmpty && report.keepAwakeUntil == nil && !report.canSleep)
        #expect(PhoneStatusBuilder.report(from: s, effectiveLidClosed: true, final: .shutDown).headline == "Shut down")
        #expect(PhoneStatusBuilder.report(from: s, effectiveLidClosed: true, final: .quit).headline == "Kakureneko is off")
    }

    @Test func pluggedInIsNotOnBattery() {
        var s = snapshot()
        s.power = PowerSnapshot(takenAt: now, lid: .open, batteryPercent: 100, onAC: true)
        #expect(!PhoneStatusBuilder.report(from: s, effectiveLidClosed: false).onBattery)
        s.power = PowerSnapshot(takenAt: now, lid: .open, batteryPercent: nil, onAC: false) // a desktop Mac
        #expect(!PhoneStatusBuilder.report(from: s, effectiveLidClosed: false).onBattery)
    }
}
