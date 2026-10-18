@testable import KakurenekoCoordinator
import KakurenekoKit
import Foundation
import Testing

/// ARCHITECTURE §9.8 acceptance tests for the power state machine as driven by the actor (FakeServiceSet +
/// TestClock; cross-service order through `fakes.log`).
@Suite("Coordinator power flows", .timeLimit(.minutes(1)))
struct PowerFlowTests {
    /// Brief T7: prompt → lid close → finished → 5 min countdown push → sleep (→ wake).
    @Test func fullFlowPromptLidCloseFinishCountdownSleep() async throws {
        try await withHarness { h in
            await h.start()
            let t0 = h.now
            h.setSessions([Fixture.session("s1", state: .working(since: t0), turnStartedAt: t0)], sv: 7)
            await h.tick()
            #expect(h.fakes.power.count(.arm) == 1)
            #expect(await h.phase() == .armed(since: t0))

            await h.closeLid(lastInputAgo: 600)
            #expect(await h.phase() == .closedAwake(since: t0))
            #expect(h.fakes.power.count(.displaySleep) == 1)

            h.advance(30)
            let done = Fixture.session("s1", state: .idle(since: h.now, outcome: .completed), turnStartedAt: t0)
            h.setSessions([done], sv: 7)
            let finished = Fixture.effect(.finished, done, at: h.now, outcome: .completed)
            h.fakes.sessions.queueEffects([finished])
            await h.tick()

            let countdownStart = h.now
            #expect(await h.phase() == .countdown(endsAt: countdownStart.addingTimeInterval(300), reason: .finished, closedSince: t0))
            #expect(Array(h.intentKinds.suffix(2)) == [.finished, .countdown])
            guard case .countdown(let endsAt, let reason, let finishedList, let waiting, let offerShutdown)? = h.intents.last else {
                Issue.record("no countdown intent")
                return
            }
            #expect(endsAt == countdownStart.addingTimeInterval(300))
            #expect(reason == .finished)
            #expect(finishedList == [finished])
            #expect(waiting.isEmpty)
            #expect(offerShutdown == false)
            guard case .finished(let routed, let stillRunning)? = h.intents.dropLast().last else {
                Issue.record("no finished intent")
                return
            }
            #expect(routed == finished && stillRunning == 0)

            await h.advanceAndTick(299)
            #expect(await h.phase() == .countdown(endsAt: endsAt, reason: .finished, closedSince: t0))
            await h.advanceAndTick(1)
            #expect(await h.phase() == .windingDown(reason: .countdownElapsed, since: endsAt))

            await h.passThawSettle()
            #expect(await waitUntil { h.fakes.power.count(.sleep) == 1 })
            #expect(h.log.filtered(["notify.drain", "pause.thawAll(beforePowerAction)", "power.disarm", "power.sleep"])
                    == ["notify.drain", "pause.thawAll(beforePowerAction)", "power.disarm", "power.sleep"])
            #expect(h.fakes.notifications.drainDeadlines.first == endsAt.addingTimeInterval(10))
            #expect(h.fakes.power.count(.shutdown) == 0)

            let ack = PowerChangeAcknowledger(onAllow: {})
            await h.emitPower(.willSleep(ack))
            #expect(ack.isAllowed)
            h.advance(6 * 3600)
            await h.emitPower(.didWake)
            #expect(await h.phase() == .disarmed)
            guard case .asleep(let record, _)? = h.intents.last else {
                Issue.record("no asleep intent after wake")
                return
            }
            #expect(record.reason == .countdownElapsed)
            #expect(record.endAction == .sleep)
            #expect(record.endedAt == h.now)
            #expect(await h.snapshot().lastSleep?.endedAt == h.now)
        }
    }

    @Test func needsInputStartsTenMinuteCountdownWithTheWaitingSession() async throws {
        try await withHarness { h in
            await h.start()
            let t0 = h.now
            h.setSessions([Fixture.session("s1", state: .working(since: t0), turnStartedAt: t0)])
            await h.tick()
            await h.closeLid(lastInputAgo: 900)

            h.advance(20)
            let waiting = Fixture.session("s1", state: .waiting(kind: .permission, since: h.now), turnStartedAt: t0)
            h.setSessions([waiting])
            h.fakes.sessions.queueEffects([Fixture.effect(.needsInput, waiting, at: h.now)])
            await h.tick()

            #expect(await h.phase() == .countdown(endsAt: h.now.addingTimeInterval(600), reason: .needsInput, closedSince: t0))
            guard case .needsInput(let effect, let awakeUntil)? = h.intents.first(where: { $0.kind == .needsInput }) else {
                Issue.record("no needsInput intent")
                return
            }
            #expect(effect.session.key == waiting.key)
            #expect(awakeUntil == h.now.addingTimeInterval(600))
            guard case .countdown(_, let reason, _, let waitingList, let offerShutdown)? = h.intents.last else {
                Issue.record("no countdown intent")
                return
            }
            #expect(reason == .needsInput)
            #expect(waitingList.map(\.key) == [waiting.key])
            #expect(offerShutdown == false)
        }
    }

    @Test func waitingSessionKeepsTheMacArmedWithTheLidOpenThenDisarmsTwoMinutesLater() async throws {
        try await withHarness { h in
            await h.start()
            let t0 = h.now
            h.setSessions([Fixture.session("s1", state: .waiting(kind: .question, since: t0))])
            await h.tick()
            #expect(await h.phase() == .armed(since: t0))

            await h.advanceAndTick(599)
            #expect(await h.phase().isArmed)
            await h.advanceAndTick(1) // waiting grace over: the 2 min lid-open disarm timer starts
            #expect(await h.phase().isArmed)
            await h.advanceAndTick(119)
            #expect(await h.phase().isArmed)
            #expect(h.fakes.power.count(.disarm) == 0)
            await h.advanceAndTick(1)
            #expect(await h.phase() == .disarmed)
            #expect(h.fakes.power.count(.disarm) == 1)
            #expect(h.fakes.power.count(.arm) == 1)
        }
    }

    @Test func keepAwakeCommandCancelsTheCountdown() async throws {
        try await withHarness { h in
            await h.start()
            let t0 = h.now
            h.setSessions([Fixture.session("s1", state: .working(since: t0))])
            await h.tick()
            await h.closeLid()
            h.setSessions([Fixture.session("s1", state: .idle(since: h.now, outcome: .completed))])
            await h.tick()
            guard case .countdown = await h.phase() else {
                Issue.record("expected a countdown")
                return
            }
            let countdowns = h.intentKinds.filter { $0 == .countdown }.count

            await h.command(.keepAwake(seconds: 3600), sv: 7)
            #expect(await h.phase() == .closedAwake(since: t0))
            #expect(await h.snapshot().keepAwakeUntil == h.now.addingTimeInterval(3600))

            await h.advanceAndTick(3599)
            #expect(await h.phase() == .closedAwake(since: t0))
            #expect(h.intentKinds.filter { $0 == .countdown }.count == countdowns)
            await h.advanceAndTick(1) // override expired → a fresh countdown
            guard case .countdown = await h.phase() else {
                Issue.record("expected a new countdown after the override")
                return
            }
            #expect(h.fakes.power.count(.sleep) == 0)
        }
    }

    @Test func sleepCommandWithStaleStateVersionIsIgnoredWithAPush() async throws {
        try await withHarness { h in
            await h.start()
            let t0 = h.now
            h.setSessions([Fixture.session("s1", state: .working(since: t0), turnStartedAt: t0)], sv: 42)
            await h.tick()
            await h.closeLid()

            await h.command(.sleep, sv: 41)
            #expect(await h.phase() == .closedAwake(since: t0))
            guard case .commandIgnored(let reason)? = h.intents.last else {
                Issue.record("no commandIgnored push")
                return
            }
            #expect(reason == "Claude Code in api is busy again")
            #expect(!h.log.entries.contains("notify.drain"))

            await h.command(.sleep, sv: 42)
            #expect(await h.phase() == .windingDown(reason: .remoteSleep, since: h.now))
            await h.passThawSettle()
            #expect(await waitUntil { h.fakes.power.count(.sleep) == 1 })
        }
    }

    @Test func shutdownCommandRefusedWhenNotEnabledAndCancellableWhenAccepted() async throws {
        try await withHarness { h in
            await h.start()
            let t0 = h.now
            h.setSessions([Fixture.session("s1", state: .working(since: t0), turnStartedAt: t0)], sv: 9)
            await h.tick()
            await h.closeLid()

            await h.command(.shutdown, sv: 9)
            #expect(await h.phase() == .closedAwake(since: t0))
            guard case .commandIgnored(let reason)? = h.intents.last else {
                Issue.record("no commandIgnored push")
                return
            }
            #expect(reason.contains("Shut down is turned off"))

            var settings = KakurenekoSettings.default
            settings.power.endAction = .shutdown
            await h.coordinator.updateSettings(settings)
            await h.command(.shutdown, sv: 9)
            #expect(await h.phase() == .shutdownPending(at: h.now.addingTimeInterval(60), requestedFromPhone: true))
            guard case .shuttingDown(let at, let fromPhone)? = h.intents.last else {
                Issue.record("no shuttingDown push")
                return
            }
            #expect(at == h.now.addingTimeInterval(60) && fromPhone)
            #expect(await h.snapshot().powerPhase == .shutdownPending(at: at, requestedFromPhone: true))

            await h.coordinator.cancelWindDown()
            #expect(await h.phase() == .closedAwake(since: t0))
            await h.advanceAndTick(61)
            #expect(await h.phase() == .closedAwake(since: t0))
            #expect(h.fakes.power.count(.shutdown) == 0)
            #expect(h.fakes.power.count(.sleep) == 0)
            #expect(!h.log.entries.contains("notify.drain"))
        }
    }

    @Test func acceptedShutdownWritesResumeManifestShutsDownThenFallsBackToSleep() async throws {
        var settings = KakurenekoSettings.default
        settings.power.endAction = .shutdown
        try await withHarness(settings: settings) { h in
            await h.start()
            let t0 = h.now
            let session = Fixture.session("abc-123", state: .working(since: t0), turnStartedAt: t0,
                                          metadata: [MetadataKey.claudeKind: "interactive"])
            h.setSessions([session], sv: 5)
            await h.tick()
            await h.closeLid()
            // The turn ends → countdown push with a "Shut down" button minted at sv 5 → the phone taps it.
            var done = session
            done.state = .idle(since: h.now, outcome: .completed)
            h.setSessions([done], sv: 5)
            await h.tick()
            guard case .countdown(_, _, _, _, let offerShutdown)? = h.intents.last else {
                Issue.record("no countdown push")
                return
            }
            #expect(offerShutdown)
            h.advance(30)
            await h.command(.shutdown, sv: 5)
            let graceEnd = h.now.addingTimeInterval(60)
            #expect(await h.phase() == .shutdownPending(at: graceEnd, requestedFromPhone: true))

            await h.advanceAndTick(60)
            #expect(await h.phase() == .windingDown(reason: .remoteShutdown, since: h.now))
            await h.passThawSettle()
            #expect(await waitUntil { h.fakes.power.count(.shutdown) == 1 })
            #expect(h.fakes.power.count(.sleep) == 0)
            let manifest = ResumeManifest.read(from: h.paths.resumeManifestFile)
            #expect(manifest.map(\.sessionId) == ["abc-123"])
            #expect(manifest.first?.resumeCommand == "cd '\(Fixture.project)' && claude --resume abc-123")
            #expect(h.log.filtered(["power.disarm", "power.shutdown"]) == ["power.disarm", "power.shutdown"])

            // Still running 3 min later (blocked by "Ask before closing"): sleep instead.
            #expect(await h.waitForSleepers())
            h.advance(180)
            #expect(await waitUntil { h.fakes.power.count(.sleep) == 1 })
            #expect(h.log.filtered(["power.shutdown", "power.sleep"]) == ["power.shutdown", "power.sleep"])

            let ack = PowerChangeAcknowledger(onAllow: {})
            await h.emitPower(.willSleep(ack))
            #expect(ack.isAllowed)
            await h.emitPower(.didWake)
            // On wake: Disarmed (nothing works, so nothing re-arms).
            #expect(await h.phase() == .disarmed)
            // The Mac only slept: the sessions survived, nothing to reopen.
            #expect(!FileManager.default.fileExists(atPath: h.paths.resumeManifestFile.path(percentEncoded: false)))
            guard case .asleep(let record, _)? = h.intents.last else {
                Issue.record("no asleep intent")
                return
            }
            #expect(record.endAction == .sleep && record.reason == .remoteShutdown)
        }
    }

    @Test func shutdownGraceWithAStaleStateVersionIsCancelledWithAPush() async throws {
        var settings = KakurenekoSettings.default
        settings.power.endAction = .shutdown
        try await withHarness(settings: settings) { h in
            await h.start()
            let t0 = h.now
            h.setSessions([Fixture.session("s1", state: .working(since: t0), turnStartedAt: t0)], sv: 5)
            await h.tick()
            await h.closeLid()
            await h.command(.shutdown, sv: 5)
            h.advance(30)
            h.setSessions([Fixture.session("s1", state: .working(since: h.now), turnStartedAt: h.now)], sv: 6)
            await h.advanceAndTick(30)
            #expect(await h.phase() == .closedAwake(since: t0))
            guard case .commandIgnored(let reason)? = h.intents.last else {
                Issue.record("no commandIgnored push")
                return
            }
            #expect(reason == "Claude Code in api is busy again")
            #expect(h.fakes.power.count(.shutdown) == 0)
        }
    }

    @Test func countdownWithShutdownEndActionGoesThroughTheGraceAndOffersShutdown() async throws {
        var settings = KakurenekoSettings.default
        settings.power.endAction = .shutdown
        try await withHarness(settings: settings) { h in
            await h.start()
            h.setSessions([Fixture.session("s1", state: .working(since: h.now))])
            await h.tick()
            await h.closeLid()
            h.setSessions([Fixture.session("s1", state: .idle(since: h.now, outcome: .completed))])
            await h.tick()
            guard case .countdown(_, _, _, _, let offerShutdown)? = h.intents.last else {
                Issue.record("no countdown")
                return
            }
            #expect(offerShutdown)
            await h.advanceAndTick(300)
            #expect(await h.phase() == .shutdownPending(at: h.now.addingTimeInterval(60), requestedFromPhone: false))
            #expect(h.intentKinds.last == .shuttingDown)
            await h.advanceAndTick(60)
            #expect(await h.phase() == .windingDown(reason: .countdownElapsed, since: h.now))
        }
    }

    @Test func safetyTripPushesFirstThenWindsDown() async throws {
        try await withHarness { h in
            await h.start()
            h.setSessions([Fixture.session("s1", state: .working(since: h.now))])
            await h.tick()
            await h.closeLid()
            h.log.removeAll()
            h.fakes.safety.setTrip(.batteryFloor(percent: 19))
            h.power.batteryPercent = 19
            h.power.onAC = false
            await h.emitSnapshot()

            #expect(await h.phase() == .windingDown(reason: .safetyTrip(.batteryFloor(percent: 19)), since: h.now))
            guard case .safetyTrip(let trip, let running)? = h.intents.last else {
                Issue.record("no safetyTrip push")
                return
            }
            #expect(trip == .batteryFloor(percent: 19) && running == 1)
            await h.passThawSettle()
            #expect(await waitUntil { h.fakes.power.count(.sleep) == 1 })
            #expect(h.log.filtered(["notify.submit(safetyTrip)", "notify.drain", "power.disarm", "power.sleep"])
                    == ["notify.submit(safetyTrip)", "notify.drain", "power.disarm", "power.sleep"])
        }
    }

    @Test func safetyIsEvaluatedEveryFifteenSecondsWhileClosedLidAwake() async throws {
        try await withHarness { h in
            await h.start()
            h.setSessions([Fixture.session("s1", state: .working(since: h.now))])
            await h.tick()
            #expect(h.fakes.safety.evaluationCount == 0) // lid open: armingBlocker only
            await h.closeLid()
            let afterClose = h.fakes.safety.evaluationCount
            #expect(afterClose >= 1)
            await h.advanceAndTick(5)
            #expect(h.fakes.safety.evaluationCount == afterClose)
            await h.advanceAndTick(10)
            #expect(h.fakes.safety.evaluationCount == afterClose + 1)
            #expect(h.fakes.safety.resetCount >= 1)
        }
    }

    @Test func lidOpenDuringCountdownReturnsToArmedAndThaws() async throws {
        try await withHarness { h in
            await h.start()
            h.setSessions([Fixture.session("s1", state: .working(since: h.now))])
            await h.tick()
            await h.closeLid()
            h.setSessions([Fixture.session("s1", state: .idle(since: h.now, outcome: .completed))])
            await h.tick()
            guard case .countdown = await h.phase() else {
                Issue.record("expected a countdown")
                return
            }
            h.advance(10)
            await h.openLid()
            #expect(await h.phase() == .armed(since: h.now))
            #expect(h.thawReasons().contains(.lidOpened))
            await h.advanceAndTick(300)
            #expect(h.fakes.power.count(.sleep) == 0)
            #expect(!h.log.entries.contains("notify.drain"))
        }
    }

    @Test func lidOpenWhileWindingDownBeforeSleepNowCancelsIt() async throws {
        try await withHarness { h in
            await h.start()
            h.setSessions([Fixture.session("s1", state: .working(since: h.now))])
            await h.tick()
            await h.closeLid()
            h.setSessions([Fixture.session("s1", state: .idle(since: h.now, outcome: .completed))])
            await h.tick()
            await h.advanceAndTick(300)
            guard case .windingDown = await h.phase() else {
                Issue.record("expected a wind-down")
                return
            }
            #expect(await h.waitForSleepers()) // inside the 3 s thaw settle
            await h.openLid()
            #expect(await h.phase() == .armed(since: h.now))
            h.advance(5)
            await h.tick()
            #expect(h.fakes.power.count(.sleep) == 0)
            #expect(h.fakes.power.count(.disarm) == 0)
            #expect(h.clock.sleeperCount == 0)
        }
    }

    @Test func keepAwakeFromTheMenuCancelsAWindDownBeforeSleepNow() async throws {
        try await withHarness { h in
            await h.start()
            h.setSessions([Fixture.session("s1", state: .working(since: h.now))])
            await h.tick()
            await h.closeLid()
            h.setSessions([Fixture.session("s1", state: .idle(since: h.now, outcome: .completed))])
            await h.coordinator.sleepNow()
            #expect(await h.waitForSleepers())
            await h.coordinator.keepAwake(for: 900)
            #expect(await h.phase().isArmed)
            h.advance(5)
            await h.tick()
            #expect(h.fakes.power.count(.sleep) == 0)
            #expect(h.fakes.power.count(.disarm) == 0)
        }
    }

    @Test func armingBlockerPreventsArmingAndDisarmsWhileArmedWithTheLidOpen() async throws {
        try await withHarness { h in
            await h.start()
            h.fakes.safety.setArmingBlocker(.onBatteryNotAllowed(percent: 55))
            h.setSessions([Fixture.session("s1", state: .working(since: h.now))])
            await h.tick()
            await h.advanceAndTick(15)
            #expect(h.fakes.power.count(.arm) == 0)
            #expect(await h.phase() == .disarmed)
            #expect(await h.snapshot().warnings.contains { $0.id == "arming-blocked" })

            h.fakes.safety.setArmingBlocker(nil)
            await h.advanceAndTick(15)
            #expect(h.fakes.power.count(.arm) == 1)
            #expect(await h.phase().isArmed)
            #expect(await !h.snapshot().warnings.contains { $0.id == "arming-blocked" })

            h.fakes.safety.setArmingBlocker(.thermalPressure(.heavy))
            await h.emitSnapshot()
            #expect(await h.phase() == .disarmed)
            #expect(h.fakes.power.count(.disarm) == 1)
            #expect(h.fakes.power.count(.sleep) == 0)
            #expect(await h.snapshot().warnings.contains { $0.id == "arming-blocked" })
        }
    }

    @Test func clamshellDesktopCountsAsLidOpenSoAFinishStartsNoCountdown() async throws {
        try await withHarness { h in
            await h.start()
            let t0 = h.now
            h.setSessions([Fixture.session("s1", state: .working(since: t0))])
            await h.tick()
            await h.closeLid(lastInputAgo: 900, external: true)
            #expect(await h.phase() == .armed(since: t0))
            #expect(h.fakes.power.count(.displaySleep) == 0)

            let done = Fixture.session("s1", state: .idle(since: h.now, outcome: .completed))
            h.setSessions([done])
            h.fakes.sessions.queueEffects([Fixture.effect(.finished, done, at: h.now, outcome: .completed)])
            await h.tick()
            #expect(await h.phase().isArmed)
            #expect(!h.intentKinds.contains(.countdown))
            await h.advanceAndTick(120)
            #expect(await h.phase() == .disarmed)

            // Display disconnected with the lid closed while armed → ClosedAwake.
            h.setSessions([Fixture.session("s1", state: .working(since: h.now))])
            await h.tick()
            #expect(await h.phase().isArmed)
            h.power.externalDisplay = false
            h.scriptPower()
            await h.emitPower(.externalDisplayChanged(connected: false))
            #expect(await h.phase() == .closedAwake(since: h.now))
            #expect(h.fakes.power.count(.displaySleep) == 1)
        }
    }

    @Test func externalDisplayConnectingWhileClosedReturnsToArmedAndThaws() async throws {
        try await withHarness { h in
            await h.start()
            h.setSessions([Fixture.session("s1", state: .working(since: h.now))])
            await h.tick()
            await h.closeLid()
            #expect(await h.phase() == .closedAwake(since: h.now))
            h.power.externalDisplay = true
            h.scriptPower()
            await h.emitPower(.externalDisplayChanged(connected: true))
            #expect(await h.phase() == .armed(since: h.now))
            #expect(h.thawReasons().contains(.externalDisplay))
        }
    }

    @Test func recentUserInputPreventsTheCountdownUntilTheUserIsAway() async throws {
        try await withHarness { h in
            await h.start()
            let t0 = h.now
            h.setSessions([Fixture.session("s1", state: .working(since: t0))])
            await h.tick()
            await h.closeLid(lastInputAgo: 10) // e.g. Screen Sharing
            h.setSessions([Fixture.session("s1", state: .idle(since: h.now, outcome: .completed))])
            await h.tick()
            #expect(await h.phase() == .closedAwake(since: t0))
            #expect(!h.intentKinds.contains(.countdown))

            await h.advanceAndTick(289) // 299 s since input
            #expect(await h.phase() == .closedAwake(since: t0))
            await h.advanceAndTick(1) // 300 s: away
            #expect(await h.phase() == .countdown(endsAt: h.now.addingTimeInterval(300), reason: .finished, closedSince: t0))
        }
    }

    @Test func wentQuietCountdownWhenOnlyHeuristicSessionsEnded() async throws {
        try await withHarness { h in
            await h.start()
            let t0 = h.now
            let heuristic = Fixture.session("pid:1:2.3", agent: .goose, state: .working(since: t0), tiers: [.heuristic])
            h.setSessions([heuristic])
            await h.tick()
            await h.closeLid()
            let quiet = Fixture.session("pid:1:2.3", agent: .goose, state: .idle(since: h.now, outcome: nil), tiers: [.heuristic])
            h.setSessions([quiet])
            h.fakes.sessions.queueEffects([Fixture.effect(.wentQuiet, quiet, at: h.now)])
            await h.tick()
            #expect(await h.phase() == .countdown(endsAt: h.now.addingTimeInterval(300), reason: .wentQuiet, closedSince: t0))
            guard case .wentQuiet(_, let sleepsAt)? = h.intents.first(where: { $0.kind == .wentQuiet }) else {
                Issue.record("no wentQuiet push")
                return
            }
            #expect(sleepsAt == h.now.addingTimeInterval(300))
        }
    }

    @Test func menuSleepNowWindsDownEvenWithTheLidOpen() async throws {
        try await withHarness { h in
            await h.start()
            await h.coordinator.sleepNow()
            #expect(await h.phase() == .windingDown(reason: .userSleepNow, since: h.now))
            await h.passThawSettle()
            #expect(await waitUntil { h.fakes.power.count(.sleep) == 1 })
        }
    }

    @Test func sleepThatNeverHappensFallsBackToDisarmedAndRetriesWhileTheLidStaysClosed() async throws {
        try await withHarness { h in
            await h.start()
            h.setSessions([Fixture.session("s1", state: .working(since: h.now))])
            await h.tick()
            await h.closeLid()
            // Nothing working any more (a working session would simply re-arm after the failed sleep).
            h.setSessions([Fixture.session("s1", state: .idle(since: h.now, outcome: .completed))])
            await h.coordinator.sleepNow()
            await h.passThawSettle()
            #expect(await waitUntil { h.fakes.power.count(.sleep) == 1 })
            #expect(await h.waitForSleepers()) // waiting for willSleep
            h.advance(60)
            #expect(await waitUntil { await h.phase() == .disarmed })
            await h.advanceAndTick(59)
            #expect(await h.phase() == .disarmed)
            await h.advanceAndTick(1)
            #expect(await h.phase() == .windingDown(reason: .countdownElapsed, since: h.now))
        }
    }

    @Test func failedSleepGoesBackToDisarmed() async throws {
        try await withHarness { h in
            await h.start()
            h.fakes.power.setSleepError(.notPermitted("kIOReturnNotPermitted"))
            await h.coordinator.sleepNow()
            await h.passThawSettle()
            #expect(await waitUntil { await h.phase() == .disarmed })
            #expect(h.fakes.power.count(.sleep) == 1)
        }
    }

    @Test func disarmFailureStopsTheHeartbeatWarnsAndStillTriesToSleep() async throws {
        try await withHarness { h in
            await h.start()
            h.setSessions([Fixture.session("s1", state: .working(since: h.now))])
            await h.tick()
            await h.closeLid()
            h.fakes.power.setDisarmError(.notPermitted("sudo: a password is required"))
            await h.coordinator.sleepNow()
            await h.passThawSettle()
            #expect(await waitUntil { h.fakes.power.count(.sleep) == 1 })
            guard case .warning(let title, _)? = h.intents.first(where: { $0.kind == .warning }) else {
                Issue.record("no warning push")
                return
            }
            #expect(title.contains("could not re-enable sleep"))
            #expect(await h.snapshot().warnings.contains { $0.id == "disarm-failed" && $0.severity == .critical })
            #expect(await h.coordinator.heartbeatSuppressed)
        }
    }

    @Test func heartbeatEveryFifteenSecondsWhileArmedOnly() async throws {
        try await withHarness { h in
            await h.start()
            h.setSessions([Fixture.session("s1", state: .working(since: h.now))])
            await h.tick()
            #expect(h.fakes.power.count(.heartbeat) == 1) // right after arming
            await h.advanceAndTick(14)
            #expect(h.fakes.power.count(.heartbeat) == 1)
            await h.advanceAndTick(1)
            #expect(h.fakes.power.count(.heartbeat) == 2)
            h.setSessions([Fixture.session("s1", state: .idle(since: h.now, outcome: .completed))])
            await h.tick() // the 2 min lid-open disarm timer starts
            await h.advanceAndTick(120)
            #expect(await h.phase() == .disarmed)
            let count = h.fakes.power.count(.heartbeat)
            await h.advanceAndTick(60)
            #expect(h.fakes.power.count(.heartbeat) == count)
        }
    }

    @Test func armFailureBacksOffForAMinute() async throws {
        try await withHarness { h in
            await h.start()
            h.fakes.power.setArmError(.notPermitted("sudo: a password is required"))
            h.setSessions([Fixture.session("s1", state: .working(since: h.now))])
            await h.tick()
            #expect(h.fakes.power.count(.arm) == 1)
            #expect(await h.phase() == .disarmed)
            await h.advanceAndTick(59)
            #expect(h.fakes.power.count(.arm) == 1)
            h.fakes.power.setArmError(nil)
            await h.advanceAndTick(1)
            #expect(h.fakes.power.count(.arm) == 2)
            #expect(await h.phase().isArmed)
        }
    }

    @Test func setEnabledFalseCancelsTheWindDownThawsDisarmsAndStopsPushes() async throws {
        try await withHarness { h in
            await h.start()
            h.setSessions([Fixture.session("s1", state: .working(since: h.now))])
            await h.tick()
            await h.closeLid()
            await h.coordinator.sleepNow()
            #expect(await h.waitForSleepers())
            await h.coordinator.setEnabled(false)
            #expect(await h.phase() == .disarmed)
            #expect(await h.snapshot().mode == .disabled)
            #expect(h.thawReasons().contains(.pausingDisabled))
            h.advance(5)
            await h.tick()
            #expect(h.fakes.power.count(.sleep) == 0)
            let pushes = h.intents.count
            h.fakes.sessions.queueEffects([Fixture.effect(.finished, Fixture.session("s1", state: .idle(since: h.now, outcome: .completed)), at: h.now)])
            await h.advanceAndTick(1)
            #expect(h.intents.count == pushes)
            #expect(h.fakes.power.count(.arm) == 1)

            await h.coordinator.setEnabled(true)
            #expect(await h.snapshot().mode == .full)
        }
    }

    @Test func keepAwakeFromTheMenuArmsWithoutAgentsAndExpires() async throws {
        try await withHarness { h in
            await h.start()
            await h.coordinator.keepAwake(for: 600)
            #expect(await h.phase().isArmed)
            #expect(h.fakes.power.count(.arm) == 1)
            await h.advanceAndTick(600)
            #expect(await h.snapshot().keepAwakeUntil == nil)
            await h.advanceAndTick(120)
            #expect(await h.phase() == .disarmed)
        }
    }
}
