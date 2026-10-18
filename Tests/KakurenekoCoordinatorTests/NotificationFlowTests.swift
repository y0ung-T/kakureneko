@testable import KakurenekoCoordinator
import KakurenekoCloud
import KakurenekoKit
import Foundation
import Testing

/// ARCHITECTURE §9.8 "Notification routing", presence re-submission, remote commands (brief §8.3) and the
/// notification status the snapshot carries.
@Suite("Coordinator notifications", .timeLimit(.minutes(1)))
struct NotificationFlowTests {
    func needsInputCount(_ h: Harness) -> Int {
        h.intents.filter { if case .needsInput = $0 { true } else { false } }.count
    }

    @Test func effectsAreRoutedToTheirIntentsWithTheCurrentContext() async throws {
        try await withHarness { h in
            await h.start()
            let a = Fixture.session("a", state: .working(since: h.now))
            let b = Fixture.session("b", state: .working(since: h.now))
            h.setSessions([a, b], sv: 3)
            await h.tick()

            let aDone = Fixture.session("a", state: .idle(since: h.now, outcome: .completed))
            h.setSessions([aDone, b], sv: 3)
            let finished = Fixture.effect(.finished, aDone, at: h.now, outcome: .completed)
            h.fakes.sessions.queueEffects([finished])
            await h.tick()
            #expect(h.intents.last == .finished(finished, stillRunning: 1))
            let context = try #require(h.fakes.notifications.submittedContexts.last)
            #expect(context.now == h.now)
            #expect(context.stateVersion == 3)
            #expect(context.keepAwakeSeconds == KakurenekoSettings.default.power.keepAwakeButtonSeconds)
            #expect(context.presence.lidClosed == false)

            let stalledSession = Fixture.session("b", state: .stalled(since: h.now))
            let stalled = Fixture.effect(.stalled, stalledSession, at: h.now)
            h.setSessions([aDone, stalledSession], sv: 3)
            h.fakes.sessions.queueEffects([stalled])
            await h.tick()
            #expect(h.intents.last == .stalled(stalled))

            let count = h.intents.count
            h.fakes.sessions.queueEffects([Fixture.effect(.ended, Fixture.session("a", state: .ended(at: h.now)), at: h.now)])
            await h.tick()
            #expect(h.intents.count == count) // `.ended` pushes nothing by itself
        }
    }

    @Test func wentQuietWithTheLidOpenCarriesNoSleepTime() async throws {
        try await withHarness { h in
            await h.start()
            let quiet = Fixture.session("pid:1:2.3", agent: .goose, state: .idle(since: h.now, outcome: nil), tiers: [.heuristic])
            h.setSessions([quiet])
            h.fakes.sessions.queueEffects([Fixture.effect(.wentQuiet, quiet, at: h.now)])
            await h.tick()
            guard case .wentQuiet(_, let sleepsAt)? = h.intents.last else {
                Issue.record("no wentQuiet push")
                return
            }
            #expect(sleepsAt == nil)
        }
    }

    @Test func leavingWaitingSubmitsResolved() async throws {
        try await withHarness { h in
            await h.start()
            let waiting = Fixture.session("s1", state: .waiting(kind: .permission, since: h.now))
            h.setSessions([waiting])
            h.fakes.sessions.queueEffects([Fixture.effect(.needsInput, waiting, at: h.now)])
            await h.tick()
            #expect(!h.intents.contains(.resolved(waiting.key)))

            h.advance(5)
            let answered = Fixture.session("s1", state: .working(since: h.now))
            h.setSessions([answered], sv: 8)
            await h.tick()
            #expect(h.intents.last == .resolved(waiting.key))

            // A waiting session that ends (killed, dismissed) is resolved too — once.
            let other = Fixture.session("s2", state: .waiting(kind: .question, since: h.now))
            h.setSessions([answered, other], sv: 8)
            await h.tick()
            h.setSessions([answered, Fixture.session("s2", state: .ended(at: h.now))], sv: 8)
            await h.tick()
            await h.tick()
            #expect(h.intents.filter { $0 == .resolved(other.key) }.count == 1)
        }
    }

    @Test func presentToAwayResubmitsNeedsInputForStillWaitingSessions() async throws {
        try await withHarness { h in
            await h.start()
            h.power.lastInputAt = h.now
            await h.emitSnapshot() // the user is at the Mac
            let since = h.now
            let waiting = Fixture.session("s1", state: .waiting(kind: .question, since: since))
            h.setSessions([waiting])
            h.fakes.sessions.queueEffects([Fixture.effect(.needsInput, waiting, at: since)])
            await h.tick()
            #expect(needsInputCount(h) == 1)

            await h.run(for: 299, step: 23)
            #expect(needsInputCount(h) == 1)
            await h.advanceAndTick(1) // 300 s without input: away
            #expect(needsInputCount(h) == 2)
            guard case .needsInput(let effect, let awakeUntil)? = h.intents.last else {
                Issue.record("no re-submitted needsInput")
                return
            }
            #expect(effect.session.key == waiting.key)
            #expect(effect.at == since) // Notify dedupes on (session, waiting since)
            #expect(effect.needsInputKind == .question)
            #expect(awakeUntil == since.addingTimeInterval(600))
            #expect(h.fakes.notifications.submittedContexts.last?.presence.isAway() == true)

            await h.run(for: 60, step: 30)
            #expect(needsInputCount(h) == 2) // only on the transition

            // Back at the Mac, then the lid closes: away again → re-submitted again.
            h.power.lastInputAt = h.now
            await h.emitSnapshot()
            await h.tick()
            #expect(needsInputCount(h) == 2)
            await h.closeLid(lastInputAgo: 0)
            #expect(needsInputCount(h) == 3)
        }
    }

    @Test func closingTheLidResubmitsWaitsEvenWhenAlreadyAway() async throws {
        try await withHarness { h in
            await h.start()
            h.power.lastInputAt = h.now.addingTimeInterval(-900)
            await h.emitSnapshot() // idle at an open Mac: already away
            let since = h.now
            let waiting = Fixture.session("s1", state: .waiting(kind: .question, since: since))
            h.setSessions([waiting])
            h.fakes.sessions.queueEffects([Fixture.effect(.needsInput, waiting, at: since)])
            await h.tick()
            #expect(needsInputCount(h) == 1)
            // Away → away, but the lid closed: re-submitted (an iPhone waiting for the lid may take it now).
            await h.closeLid(lastInputAgo: 900)
            #expect(needsInputCount(h) == 2)
            #expect(h.fakes.notifications.submittedContexts.last?.presence.lidClosed == true)
            await h.tick()
            #expect(needsInputCount(h) == 2, "only on the transition")
        }
    }

    @Test func theCountdownListsEveryFinishSinceTheLidClosedAndForgetsThemWhenItOpens() async throws {
        try await withHarness { h in
            await h.start()
            let a = Fixture.session("a", state: .working(since: h.now))
            let b = Fixture.session("b", state: .working(since: h.now))
            h.setSessions([a, b])
            await h.tick()
            // A finish before the lid closes is not part of the closed-lid summary.
            let early = Fixture.effect(.finished, Fixture.session("z", state: .idle(since: h.now, outcome: .completed)), at: h.now)
            h.fakes.sessions.queueEffects([early])
            await h.tick()
            await h.closeLid(lastInputAgo: 900)

            h.advance(60)
            let aDone = Fixture.session("a", state: .idle(since: h.now, outcome: .completed))
            let first = Fixture.effect(.finished, aDone, at: h.now, outcome: .completed)
            h.setSessions([aDone, b])
            h.fakes.sessions.queueEffects([first])
            await h.tick()
            #expect(!h.intentKinds.contains(.countdown)) // b still works

            h.advance(60)
            let bDone = Fixture.session("b", state: .idle(since: h.now, outcome: .error))
            let second = Fixture.effect(.finished, bDone, at: h.now, outcome: .error)
            h.setSessions([aDone, bDone])
            h.fakes.sessions.queueEffects([second])
            await h.tick()
            guard case .countdown(_, let reason, let finished, let waiting, _)? = h.intents.last else {
                Issue.record("no countdown")
                return
            }
            #expect(reason == .finished)
            #expect(finished == [first, second])
            #expect(waiting.isEmpty)
            #expect(await h.coordinator.turnEndsSinceLidClosed == [first, second])
            await h.openLid()
            #expect(await h.coordinator.turnEndsSinceLidClosed.isEmpty)
        }
    }

    // MARK: Remote commands

    @Test func notificationCallsAreForwardedAndRepublished() async throws {
        try await withHarness { h in
            await h.start()
            #expect(await h.coordinator.requestNotificationPermission() == .authorized)
            #expect(h.fakes.notifications.authorizationRequestCount == 1)
            #expect(await h.snapshot().notifications.macAuthorization == .authorized)
            #expect(await h.coordinator.publisher.lastPublished.notifications.macAuthorization == .authorized)
            await h.coordinator.handleCloudPush()
            #expect(h.fakes.notifications.cloudPushCount == 1)
            try await h.coordinator.sendTestNotification()
            #expect(h.fakes.notifications.testCount == 1)
        }
    }

    @Test func theTickPollsTheNotificationStatusAndWarnsAboutICloudErrors() async throws {
        try await withHarness { h in
            await h.start()
            h.fakes.notifications.setStatus(NotificationStatus(iCloud: .available, lastError: "Your iCloud storage is full."))
            await h.advanceAndTick(1)
            let snapshot = await h.coordinator.publisher.lastPublished
            #expect(snapshot.notifications.lastError == "Your iCloud storage is full.")
            #expect(snapshot.warnings.contains { $0.id == "phone-alerts-error" && $0.message == "Your iCloud storage is full." })
        }
    }

    // MARK: Status for the iPhone app

    @Test func everyPublishedChangeReachesNotifyAsAStatusReport() async throws {
        try await withHarness { h in
            await h.start()
            #expect(await waitUntil { h.fakes.notifications.statusReports.last?.phase == .idle })
            _ = await h.startWorking(sv: 12)
            #expect(await waitUntil { h.fakes.notifications.statusReports.last?.phase == .working })
            #expect(h.fakes.notifications.statusReports.last?.stateVersion == 12)
            #expect(h.fakes.notifications.statusReports.last?.agents.count == 1)
            await h.closeLid()
            await h.tick() // the lid change at the same virtual instant is coalesced into the next tick's publish
            #expect(await waitUntil { h.fakes.notifications.statusReports.last?.phase == .lidClosedAwake })
            #expect(h.fakes.notifications.statusReports.last?.lidClosed == true)
            // Unchanged snapshots are not reported again.
            await settleTasks()
            let count = h.fakes.notifications.statusReports.count
            await h.tick()
            await settleTasks()
            #expect(h.fakes.notifications.statusReports.count == count)
        }
    }

    @Test func theFinalStatusIsReportedBeforeTheWindDownDrain() async throws {
        try await withHarness { h in
            await h.start()
            _ = await h.startWorking(sv: 12)
            await h.closeLid()
            h.setSessions([Fixture.session("s1", state: .idle(since: h.now, outcome: .completed))], sv: 12)
            await h.tick()
            await h.command(.sleep, sv: 12)
            #expect(await waitUntil { h.log.entries.contains("notify.drain") })
            #expect(h.fakes.notifications.statusReports.last?.phase == .asleep, "handed over (and awaited) before the drain")
            #expect(h.fakes.notifications.statusReports.last?.agents.isEmpty == true)
            #expect(h.fakes.notifications.statusReports.last?.canSleep == false)
        }
    }

    @Test func theFinalStatusSurvivesLaterPublishesUntilTheMacWakes() async throws {
        try await withHarness { h in
            await h.start()
            _ = await h.startWorking(sv: 12)
            await h.closeLid()
            h.setSessions([Fixture.session("s1", state: .idle(since: h.now, outcome: .completed))], sv: 12)
            await h.tick()
            await h.command(.sleep, sv: 12)
            #expect(await waitUntil { h.fakes.notifications.statusReports.last?.phase == .asleep })
            let first = h.fakes.notifications.statusReports.count - 1
            await h.passThawSettle() // disarm + sleep publish again
            #expect(await waitUntil { h.fakes.power.count(.sleep) == 1 })
            await h.emitPower(.willSleep(PowerChangeAcknowledger(onAllow: {})))
            // A dark wake: the battery changes and the tick publishes, still before didWake.
            h.power.batteryPercent = 61
            await h.emitSnapshot()
            await h.advanceAndTick(1)
            await settleTasks()
            let since = h.fakes.notifications.statusReports[first...]
            #expect(since.allSatisfy { $0.phase == .asleep }, "\(since.map(\.phase))")
            #expect(since.contains { $0.batteryPercent == 61 }, "still reported, as asleep")
            await h.emitPower(.didWake)
            await h.advanceAndTick(1)
            #expect(await waitUntil { h.fakes.notifications.statusReports.last.map { $0.phase != .asleep } ?? false })
        }
    }

    @Test func aCancelledWindDownStopsReportingAsleep() async throws {
        try await withHarness { h in
            await h.start()
            await h.coordinator.sleepNow()
            #expect(await waitUntil { h.fakes.notifications.statusReports.last?.phase == .asleep })
            await h.coordinator.cancelWindDown()
            await h.advanceAndTick(1)
            #expect(await waitUntil { h.fakes.notifications.statusReports.last?.phase == .idle })
        }
    }

    @Test func quittingReportsOffUnlessAShutdownIsUnderWay() async throws {
        try await withHarness { h in
            await h.start()
            await h.coordinator.reportFinalStatus(.shutDown, untilWake: false) // the shutdown wind-down reported it
            await h.coordinator.prepareForTermination()
            #expect(h.fakes.notifications.statusReports.last?.phase == .shutDown)
        }
        try await withHarness { h in
            await h.start()
            await h.coordinator.prepareForTermination()
            #expect(h.fakes.notifications.statusReports.last?.phase == .off)
        }
    }

    @Test func phoneKeepAwakeArmsAndCancelsAShutdownGrace() async throws {
        var settings = KakurenekoSettings.default
        settings.power.endAction = .shutdown
        try await withHarness(settings: settings) { h in
            await h.start()
            _ = await h.startWorking(sv: 4)
            await h.closeLid()
            await h.command(.shutdown, sv: 4)
            guard case .shutdownPending = await h.phase() else {
                Issue.record("expected the shutdown grace")
                return
            }
            await h.command(.keepAwake(seconds: 3600), sv: 0) // keep-awake needs no sv
            #expect(await h.phase() == .closedAwake(since: h.now))
            #expect(await h.snapshot().keepAwakeUntil == h.now.addingTimeInterval(3600))
            await h.advanceAndTick(61)
            #expect(h.fakes.power.count(.shutdown) == 0)
            #expect(!h.log.entries.contains("notify.drain"))
        }
    }

    @Test func phoneKeepAwakeArmsAnIdleMac() async throws {
        try await withHarness { h in
            await h.start()
            await h.command(.keepAwake(seconds: 1800), sv: 0)
            #expect(await h.phase().isArmed)
            #expect(h.fakes.power.count(.arm) == 1)
        }
    }

    @Test func lidOpenCancelsAShutdownGrace() async throws {
        var settings = KakurenekoSettings.default
        settings.power.endAction = .shutdown
        try await withHarness(settings: settings) { h in
            await h.start()
            _ = await h.startWorking(sv: 4)
            await h.closeLid()
            await h.command(.shutdown, sv: 4)
            await h.openLid()
            #expect(await h.phase() == .armed(since: h.now))
            await h.advanceAndTick(61)
            #expect(h.fakes.power.count(.shutdown) == 0)
        }
    }

    @Test func commandsWhileKakurenekoIsOffAreNotRunAndTheIPhoneIsTold() async throws {
        try await withHarness { h in
            await h.start()
            h.setSessions([], sv: 5)
            await h.coordinator.setEnabled(false)
            let pushes = h.intents.count
            await h.command(.sleep, sv: 5)
            await h.command(.shutdown, sv: 5)
            // Only the answers to the taps (the iPhone's feedback waits for them), nothing else.
            let answers = h.intents.dropFirst(pushes).map { intent -> String? in
                if case .commandIgnored(let reason) = intent { reason } else { nil }
            }
            #expect(answers == ["Kakureneko is turned off on this Mac", "Kakureneko is turned off on this Mac"])
            #expect(h.fakes.power.count(.shutdown) == 0)
            #expect(await h.phase() == .disarmed)
            #expect(!h.log.entries.contains("notify.drain"))
        }
    }

    @Test func aMatchingSleepCommandWindsDownWithTheRemoteReason() async throws {
        try await withHarness { h in
            await h.start()
            _ = await h.startWorking(sv: 12)
            await h.closeLid()
            h.setSessions([Fixture.session("s1", state: .idle(since: h.now, outcome: .completed))], sv: 12)
            await h.tick()
            await h.command(.sleep, sv: 12)
            #expect(await h.phase() == .windingDown(reason: .remoteSleep, since: h.now))
            await h.passThawSettle()
            #expect(await waitUntil { h.fakes.power.count(.sleep) == 1 })
            #expect(h.log.filtered(["notify.drain", "pause.thawAll(beforePowerAction)", "power.disarm", "power.sleep"])
                    == ["notify.drain", "pause.thawAll(beforePowerAction)", "power.disarm", "power.sleep"])
        }
    }
}
