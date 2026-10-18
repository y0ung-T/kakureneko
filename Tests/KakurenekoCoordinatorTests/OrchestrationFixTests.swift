@testable import KakurenekoCoordinator
import KakurenekoKit
import Foundation
import Synchronization
import Testing

/// Regression tests for the orchestration / remote-command review (each failed before its fix).
@Suite("Orchestration fixes", .timeLimit(.minutes(1)))
struct OrchestrationFixTests {

    // MARK: A Kakureneko-initiated sleep is not undone by the next dark wake in the bag

    /// Menu "Sleep now" while an agent is mid-turn, the lid closed during the sleep, a dark wake an hour later: the
    /// agent is still `.working` (same turn), Kakureneko stays Disarmed (no arm, no heartbeat). A new turn re-arms.
    @Test func menuSleepNowThenDarkWakeInTheBagDoesNotRearm() async throws {
        try await withHarness { h in
            await h.start()
            let t0 = h.now
            h.setSessions([Fixture.session("s1", state: .working(since: t0), turnStartedAt: t0)], sv: 7)
            await h.tick()
            #expect(h.fakes.power.count(.arm) == 1)

            await h.coordinator.sleepNow()
            await h.passThawSettle()
            #expect(await waitUntil { h.fakes.power.count(.sleep) == 1 })
            await h.emitPower(.willSleep(PowerChangeAcknowledger(onAllow: {})))

            h.power.lid = .closed
            h.power.lastInputAt = t0
            h.advance(3600)
            await h.emitPower(.didWake)
            let heartbeats = h.fakes.power.count(.heartbeat)
            await h.run(for: 60)
            #expect(h.fakes.power.count(.arm) == 1)
            #expect(h.fakes.power.kernelFlags().sleepDisabled == false)
            #expect(await h.phase() == .disarmed)
            #expect(h.fakes.power.count(.heartbeat) == heartbeats)

            // New work (the state version moves on): re-arms although the lid stays closed.
            h.setSessions([Fixture.session("s1", state: .working(since: h.now), turnStartedAt: h.now)], sv: 8)
            await h.tick()
            #expect(h.fakes.power.count(.arm) == 2)
            #expect((await h.phase()).label == "closedAwake")
        }
    }

    /// The phone's "Sleep now" (valid sv) with the lid closed, then a dark wake.
    @Test func phoneSleepThenDarkWakeDoesNotRearm() async throws {
        try await withHarness { h in
            await h.start()
            let t0 = h.now
            h.setSessions([Fixture.session("s1", state: .working(since: t0), turnStartedAt: t0)], sv: 7)
            await h.tick()
            await h.closeLid(lastInputAgo: 900)
            #expect(await h.phase() == .closedAwake(since: t0))

            await h.command(.sleep, sv: 7)
            await h.passThawSettle()
            #expect(await waitUntil { h.fakes.power.count(.sleep) == 1 })
            await h.emitPower(.willSleep(PowerChangeAcknowledger(onAllow: {})))
            h.advance(1800)
            await h.emitPower(.didWake)
            await h.run(for: 30)

            #expect(h.fakes.power.count(.arm) == 1)
            #expect(await h.phase() == .disarmed)
            // Opening the lid (the user is back) re-arms for the agent that still works.
            await h.openLid()
            #expect(h.fakes.power.count(.arm) == 2)
            #expect(await h.phase() == .armed(since: h.now))
        }
    }

    /// After a safety trip (12 h cap) the Mac must not re-arm, re-trip and push again on every dark wake — not even
    /// for a new turn. Only the lid opening releases it.
    @Test func aSafetyTripIsNotReArmedOnTheNextDarkWake() async throws {
        try await withHarness { h in
            await h.start()
            let t0 = h.now
            h.setSessions([Fixture.session("s1", state: .working(since: t0), turnStartedAt: t0)], sv: 7)
            await h.tick()
            await h.closeLid(lastInputAgo: 900)
            h.fakes.safety.setTrip(.maxDuration(hours: 12))
            await h.advanceAndTick(15)
            await h.passThawSettle()
            #expect(await waitUntil { h.fakes.power.count(.sleep) == 1 })
            await h.emitPower(.willSleep(PowerChangeAcknowledger(onAllow: {})))
            h.advance(900)
            await h.emitPower(.didWake)
            await h.run(for: 30)
            h.setSessions([Fixture.session("s1", state: .working(since: h.now), turnStartedAt: h.now)], sv: 8)
            await h.run(for: 30)

            #expect(h.fakes.power.count(.arm) == 1)
            #expect(h.fakes.power.count(.sleep) == 1)
            #expect(h.intentKinds.filter { $0 == .safetyTrip }.count == 1)
            #expect(await h.phase() == .disarmed)

            h.fakes.safety.setTrip(nil)
            await h.openLid()
            #expect(h.fakes.power.count(.arm) == 2)
        }
    }

    /// A keep-awake override that was set before the sleep went out does not survive it.
    @Test func aKeepAwakeOverrideDoesNotSurviveACommittedSleep() async throws {
        try await withHarness { h in
            await h.start()
            _ = await h.startWorking()
            await h.closeLid()
            await h.coordinator.keepAwake(for: 3600)
            #expect(await h.snapshot().keepAwakeUntil != nil)
            await h.coordinator.sleepNow()
            await h.passThawSettle()
            #expect(await waitUntil { h.fakes.power.count(.sleep) == 1 })
            #expect(await h.snapshot().keepAwakeUntil == nil)
        }
    }

    // MARK: Decisions made before an await, executed after it

    /// Battery-floor trip with the lid closed; the lid opens while the trip push is being submitted (before the
    /// wind-down task exists). The flag used to stay set with the machine in Disarmed and nobody disarming.
    @Test func lidOpenDuringTheSafetyTripPushDoesNotLeaveTheFlagSet() async throws {
        let gate = PushGate()
        try await withHarness(configure: { services, fakes in
            services.notifications = GatingDispatcher(inner: fakes.notifications, gate: gate, kind: .safetyTrip)
        }) { h in
            await h.start()
            let t0 = h.now
            h.setSessions([Fixture.session("s1", state: .working(since: t0), turnStartedAt: t0)], sv: 7)
            await h.tick()
            await h.closeLid(lastInputAgo: 900)
            #expect(h.fakes.power.kernelFlags().sleepDisabled == true)

            h.power.batteryPercent = 15
            h.power.onAC = false
            h.fakes.safety.setTrip(.batteryFloor(percent: 15))
            h.fakes.safety.setArmingBlocker(.batteryFloor(percent: 15))
            h.advance(15)
            let coordinator = h.coordinator
            let tickTask = Task { await coordinator.tick() }
            #expect(await waitUntil { gate.isBlocked })
            #expect((await h.phase()).label == "windingDown")

            await h.openLid()
            gate.release()
            await tickTask.value
            await h.run(for: 30)

            #expect(await h.phase() == .disarmed)
            #expect(h.fakes.power.count(.disarm) >= 1)
            #expect(h.fakes.power.kernelFlags().sleepDisabled == false)
            #expect(h.fakes.power.count(.sleep) == 0)
        }
    }

    /// Session a finishes (Countdown decided), its `.finished` push is in flight, and agent b starts a turn (sv 7 → 8)
    /// which cancels the countdown. The countdown push used to go out anyway, with Sleep-now signed for sv 8.
    @Test func aCountdownCancelledBeforeItsPushWentOutIsNotPushed() async throws {
        let gate = PushGate()
        try await withHarness(configure: { services, fakes in
            services.notifications = GatingDispatcher(inner: fakes.notifications, gate: gate, kind: .finished)
        }) { h in
            await h.start()
            let t0 = h.now
            let a = Fixture.session("a", state: .working(since: t0), turnStartedAt: t0)
            h.setSessions([a], sv: 7)
            await h.tick()
            await h.closeLid(lastInputAgo: 900)

            h.advance(30)
            let done = Fixture.session("a", state: .idle(since: h.now, outcome: .completed), turnStartedAt: t0)
            h.setSessions([done], sv: 7)
            h.fakes.sessions.queueEffects([Fixture.effect(.finished, done, at: h.now, outcome: .completed)])
            let coordinator = h.coordinator
            let tickTask = Task { await coordinator.tick() }
            #expect(await waitUntil { gate.isBlocked })
            #expect((await h.phase()).label == "countdown")

            let b = Fixture.session("b", state: .working(since: h.now), turnStartedAt: h.now)
            h.setSessions([done, b], sv: 8)
            await h.emitSnapshot()
            #expect((await h.phase()).label == "closedAwake")

            gate.release()
            await tickTask.value
            #expect(!h.intentKinds.contains(.countdown))
            #expect((await h.phase()).label == "closedAwake")
        }
    }

    /// The countdown push carries the `sv` the countdown was decided at.
    @Test func theCountdownPushIsSignedWithTheDecisionTimeStateVersion() async throws {
        try await withHarness { h in
            await h.start()
            _ = await h.startWorking(sv: 7)
            await h.closeLid(lastInputAgo: 900)
            let done = Fixture.session("s1", state: .idle(since: h.now, outcome: .completed), turnStartedAt: h.now)
            h.setSessions([done], sv: 7)
            await h.tick()
            let countdowns = zip(h.intents, h.fakes.notifications.submittedContexts).filter { $0.0.kind == .countdown }
            #expect(countdowns.count == 1)
            #expect(countdowns.first?.1.stateVersion == 7)
        }
    }

    // MARK: Master switch off

    /// `.resolved` sends nothing and cancels Notify's reminder: it is forwarded while Kakureneko is off, and Notify itself
    /// is switched off (its reminder timer, batch and queue dropped) until Kakureneko is on again.
    @Test func resolvedStillReachesNotifyWhileDisabledAndNotifyIsSwitchedOff() async throws {
        try await withHarness { h in
            await h.start()
            let t0 = h.now
            let waiting = Fixture.session("s1", state: .waiting(kind: .permission, since: t0), turnStartedAt: t0)
            h.setSessions([waiting], sv: 7)
            h.fakes.sessions.queueEffects([Fixture.effect(.needsInput, waiting, at: t0)])
            await h.tick()
            #expect(h.intentKinds.contains(.needsInput))
            #expect(h.fakes.notifications.appliedSettings?.enabled == true)

            await h.coordinator.setEnabled(false)
            #expect(h.fakes.notifications.appliedSettings?.enabled == false)
            h.setSessions([Fixture.session("s1", state: .working(since: h.now), turnStartedAt: t0)], sv: 8)
            await h.advanceAndTick(1)
            #expect(h.intents.contains { if case .resolved(let key) = $0 { key == waiting.key } else { false } })

            await h.coordinator.setEnabled(true)
            #expect(h.fakes.notifications.appliedSettings?.enabled == true)
        }
    }

    // MARK: Shutdown: the request is out

    /// Opt-in shutdown; the user opens the lid after the request went out (loginwindow shows a dialog), then the
    /// shutdown completes (the app is quit): resume.json must still be there for "Reopen sessions".
    @Test func lidOpenAfterTheShutdownRequestKeepsTheResumeManifest() async throws {
        var settings = KakurenekoSettings.default
        settings.power.endAction = .shutdown
        try await withHarness(settings: settings) { h in
            let path = h.paths.resumeManifestFile.path(percentEncoded: false)
            try await Self.reachTheShutdownRequest(h)
            #expect(FileManager.default.fileExists(atPath: path))
            await h.openLid()
            await h.coordinator.prepareForTermination()
            #expect(FileManager.default.fileExists(atPath: path))
        }
    }

    /// Quitting while the shutdown request is out (loginwindow quits apps first): the rest of the 3 min sleep
    /// fallback goes to a detached helper, because an aborted shutdown leaves nothing of Kakureneko to run it.
    @Test func quittingWhileTheShutdownIsPendingHandsTheSleepFallbackOff() async throws {
        var settings = KakurenekoSettings.default
        settings.power.endAction = .shutdown
        try await withHarness(settings: settings) { h in
            try await Self.reachTheShutdownRequest(h)
            #expect(await h.waitForSleepers()) // the in-app 3 min fallback
            h.advance(30)
            await h.coordinator.prepareForTermination()
            #expect(h.fakes.power.scheduledSleepDelays == [.seconds(150)])
            #expect(h.fakes.power.count(.sleep) == 0)
            #expect(h.log.filtered(["power.shutdown", "power.scheduleSleep"]) == ["power.shutdown", "power.scheduleSleep"])
        }
    }

    /// An ordinary quit never leaves a sleeper behind.
    @Test func anOrdinaryQuitSchedulesNoSleep() async throws {
        try await withHarness { h in
            await h.start()
            _ = await h.startWorking()
            await h.closeLid()
            await h.coordinator.prepareForTermination()
            #expect(h.fakes.power.count(.scheduleSleep) == 0)
        }
    }

    /// A resume.json written during the CURRENT boot describes sessions that survived (no shutdown happened since):
    /// it is not offered and is removed. One from before this boot is offered.
    @Test func theLaunchOfferIgnoresAManifestWrittenDuringThisBoot() async throws {
        let entries = [ResumeEntry(agent: .claude, sessionId: "abc", cwd: "/tmp/p", title: "t", kind: nil, jobId: nil, host: nil)]
        try await withHarness(bootTime: { Date().addingTimeInterval(-3600) }) { h in
            try ResumeManifest.write(entries, to: h.paths.resumeManifestFile)
            await h.start()
            #expect(await h.snapshot().resumeOffer.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: h.paths.resumeManifestFile.path(percentEncoded: false)))
        }
        try await withHarness(bootTime: { Date().addingTimeInterval(3600) }) { h in
            try ResumeManifest.write(entries, to: h.paths.resumeManifestFile)
            await h.start()
            #expect(await h.snapshot().resumeOffer == entries)
        }
    }

    /// Prompt → lid close → finished → phone "Shut down" → grace → wind-down → `requestShutdown` (fallback pending).
    static func reachTheShutdownRequest(_ h: Harness) async throws {
        await h.start()
        let session = Fixture.session("abc-123", state: .working(since: h.now), turnStartedAt: h.now)
        h.setSessions([session], sv: 5)
        await h.tick()
        await h.closeLid()
        var done = session
        done.state = .idle(since: h.now, outcome: .completed)
        h.setSessions([done], sv: 5)
        await h.tick()
        h.advance(30)
        await h.command(.shutdown, sv: 5)
        await h.advanceAndTick(60)
        await h.passThawSettle()
        #expect(await waitUntil { h.fakes.power.count(.shutdown) == 1 })
    }
}

// MARK: - Support

/// Suspends the first submit of one notification kind until released.
final class PushGate: Sendable {
    private struct State { var blocked = false; var released = false; var waiter: CheckedContinuation<Void, Never>? }
    private let state = Mutex(State())

    var isBlocked: Bool { state.withLock { $0.blocked } }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { s -> Bool in
                if s.released { return true }
                s.blocked = true
                s.waiter = c
                return false
            }
            if resumeNow { c.resume() }
        }
    }

    func release() {
        let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.released = true
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume()
    }
}

/// A dispatcher whose `submit` of one kind waits on a `PushGate` (forwards everything to the fake).
final class GatingDispatcher: NotificationDispatching {
    let inner: FakeNotificationDispatcher
    let gate: PushGate
    let gatedKind: NotificationKind

    init(inner: FakeNotificationDispatcher, gate: PushGate, kind: NotificationKind) {
        self.inner = inner
        self.gate = gate
        self.gatedKind = kind
    }

    func start() async { await inner.start() }
    func stop() async { await inner.stop() }
    func applySettings(_ settings: NotificationSettings) async { await inner.applySettings(settings) }
    func submit(_ intent: NotificationIntent, context: NotificationContext) async -> NotificationDisposition {
        if intent.kind == gatedKind { await gate.wait() }
        return await inner.submit(intent, context: context)
    }
    func enqueue(_ notification: OutgoingNotification) async { await inner.enqueue(notification) }
    func drain(deadline: Date) async -> DrainResult { await inner.drain(deadline: deadline) }
    func remoteCommands() -> AsyncStream<RemoteCommand> { inner.remoteCommands() }
    func status() async -> NotificationStatus { await inner.status() }
    func updateMacStatus(_ report: MacStatusReport) async { await inner.updateMacStatus(report) }
    func requestMacAuthorization() async -> MacAlertAuthorization { await inner.requestMacAuthorization() }
    func sendTest() async throws { try await inner.sendTest() }
    func forgetPhone(deviceID: String) async { await inner.forgetPhone(deviceID: deviceID) }
    func lookForPhones() async { await inner.lookForPhones() }
    func cloudDidNotify() async { await inner.cloudDidNotify() }
}
