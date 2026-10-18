@testable import KakurenekoCoordinator
import KakurenekoKit
import Foundation
import Testing

/// Main-loop duties, lid-close actions, sleep/wake handling and the warnings the actor derives (ARCHITECTURE §9.8).
@Suite("Coordinator behaviour", .timeLimit(.minutes(1)))
struct CoordinatorBehaviourTests {
    // MARK: Countdown variants

    @Test func shutdownEndActionWithAWaitingSessionSleepsWithoutAGrace() async throws {
        var settings = KakurenekoSettings.default
        settings.power.endAction = .shutdown
        try await withHarness(settings: settings) { h in
            await h.start()
            _ = await h.startWorking()
            await h.closeLid(lastInputAgo: 900)
            let waiting = Fixture.session("s1", state: .waiting(kind: .permission, since: h.now), agentPID: 100)
            h.setSessions([waiting])
            h.fakes.sessions.queueEffects([Fixture.effect(.needsInput, waiting, at: h.now)])
            await h.tick()
            guard case .countdown(_, let reason, _, _, let offerShutdown)? = h.intents.last else {
                Issue.record("no countdown")
                return
            }
            #expect(reason == .needsInput && !offerShutdown)
            await h.advanceAndTick(600)
            #expect(await h.phase() == .windingDown(reason: .countdownElapsed, since: h.now))
            #expect(!h.intentKinds.contains(.shuttingDown))
            await h.passThawSettle()
            #expect(await waitUntil { h.fakes.power.count(.sleep) == 1 })
            #expect(h.fakes.power.count(.shutdown) == 0)
            #expect(!FileManager.default.fileExists(atPath: h.paths.resumeManifestFile.path(percentEncoded: false)))
        }
    }

    @Test func aSessionStartingToWaitDuringAFinishCountdownExtendsItToTheNeedsInputLength() async throws {
        try await withHarness { h in
            await h.start()
            let t0 = h.now
            _ = await h.startWorking()
            await h.closeLid(lastInputAgo: 900)
            h.setSessions([Fixture.session("s1", state: .idle(since: h.now, outcome: .completed))])
            await h.tick()
            #expect(await h.phase() == .countdown(endsAt: t0.addingTimeInterval(300), reason: .finished, closedSince: t0))

            h.advance(60)
            let other = Fixture.session("s2", agent: .codex, state: .waiting(kind: .permission, since: h.now))
            h.setSessions([Fixture.session("s1", state: .idle(since: t0, outcome: .completed)), other])
            await h.tick()
            let endsAt = h.now.addingTimeInterval(600)
            #expect(await h.phase() == .countdown(endsAt: endsAt, reason: .needsInput, closedSince: t0))
            guard case .countdown(let pushedEnd, let reason, _, let waitingList, _)? = h.intents.last else {
                Issue.record("no updated countdown")
                return
            }
            #expect(pushedEnd == endsAt && reason == .needsInput && waitingList.map(\.key) == [other.key])
            await h.advanceAndTick(300)
            #expect(h.fakes.power.count(.sleep) == 0)
            #expect(await h.phase().isArmed)
        }
    }

    @Test func cancellingAMenuSleepStartedWhileDisarmedReturnsToDisarmed() async throws {
        try await withHarness { h in
            await h.start()
            await h.coordinator.sleepNow()
            #expect(await h.waitForSleepers())
            await h.coordinator.cancelWindDown()
            #expect(await h.phase() == .disarmed)
            h.advance(5)
            await h.tick()
            #expect(h.fakes.power.count(.sleep) == 0)
            #expect(h.fakes.power.count(.arm) == 0)
            #expect(await h.snapshot().powerPhase == .disarmed)

            // A later sleep the user started is not reported as one Kakureneko initiated.
            await h.emitPower(.willSleep(PowerChangeAcknowledger(onAllow: {})))
            h.advance(3600)
            await h.emitPower(.didWake)
            #expect(!h.intentKinds.contains(.asleep))
            #expect(await h.snapshot().lastSleep == nil)
        }
    }

    /// The shutdown request is out and cannot be recalled: opening the lid abandons the sleep fallback but keeps
    /// resume.json until the fallback window has passed with Kakureneko still running (then the shutdown evidently
    /// did not happen and it is removed).
    @Test func lidOpenDuringTheShutdownFallbackKeepsTheMacUpAndForgetsTheResumeManifestOnceTheShutdownDidNotHappen() async throws {
        var settings = KakurenekoSettings.default
        settings.power.endAction = .shutdown
        try await withHarness(settings: settings) { h in
            await h.start()
            _ = await h.startWorking(sv: 5)
            await h.closeLid()
            h.setSessions([Fixture.session("s1", state: .idle(since: h.now, outcome: .completed))], sv: 5)
            await h.tick()
            await h.command(.shutdown, sv: 5)
            await h.advanceAndTick(60)
            await h.passThawSettle()
            #expect(await waitUntil { h.fakes.power.count(.shutdown) == 1 })
            #expect(FileManager.default.fileExists(atPath: h.paths.resumeManifestFile.path(percentEncoded: false)))
            #expect(await h.waitForSleepers()) // the 3 min sleep fallback

            await h.openLid() // e.g. Terminal asked "terminate running processes?" and the user came back
            #expect(await h.phase() == .disarmed)
            #expect(FileManager.default.fileExists(atPath: h.paths.resumeManifestFile.path(percentEncoded: false)))
            h.advance(200)
            await h.tick()
            #expect(h.fakes.power.count(.sleep) == 0)
            #expect(h.clock.sleeperCount == 0)
            #expect(!FileManager.default.fileExists(atPath: h.paths.resumeManifestFile.path(percentEncoded: false)))
        }
    }

    @Test func quittingDuringAShutdownKeepsTheResumeManifestForTheNextLaunch() async throws {
        var settings = KakurenekoSettings.default
        settings.power.endAction = .shutdown
        try await withHarness(settings: settings) { h in
            await h.start()
            _ = await h.startWorking(sv: 5)
            await h.closeLid()
            h.setSessions([Fixture.session("s1", state: .idle(since: h.now, outcome: .completed))], sv: 5)
            await h.tick()
            await h.command(.shutdown, sv: 5)
            await h.advanceAndTick(60)
            await h.passThawSettle()
            #expect(await waitUntil { h.fakes.power.count(.shutdown) == 1 })
            #expect(await h.waitForSleepers())
            await h.coordinator.prepareForTermination() // loginwindow quits the app on the way down
            #expect(ResumeManifest.read(from: h.paths.resumeManifestFile).map(\.sessionId) == ["s1"])
            h.advance(200)
            #expect(h.fakes.power.count(.sleep) == 0)
        }
    }

    @Test func integrationStatusesAreReReadEveryTenMinutes() async throws {
        try await withHarness { h in
            await h.start()
            let reads = { h.fakes.integrations.calls.filter { $0 == .statuses }.count }
            #expect(reads() == 1)
            await h.run(for: 599, step: 60)
            #expect(reads() == 1)
            await h.advanceAndTick(1)
            #expect(reads() == 2)
        }
    }

    // MARK: Lid close

    @Test func lidCloseSleepsThePanelAndChimesOnBattery() async throws {
        try await withHarness { h in
            await h.start()
            h.power.onAC = false
            await h.emitSnapshot()
            _ = await h.startWorking()
            await h.closeLid()
            #expect(h.log.filtered(["power.displaySleep", "power.chime"]) == ["power.displaySleep", "power.chime"])
        }
    }

    @Test func lidCloseActionsFollowTheSettings() async throws {
        var settings = KakurenekoSettings.default
        settings.power.displaySleepOnLidClose = false
        settings.power.lidCloseSound = .off
        try await withHarness(settings: settings) { h in
            await h.start()
            h.power.onAC = false
            await h.emitSnapshot()
            _ = await h.startWorking()
            await h.closeLid()
            #expect(await h.phase() == .closedAwake(since: h.now))
            #expect(h.fakes.power.count(.displaySleep) == 0)
            #expect(h.fakes.power.count(.chime) == 0)
        }
    }

    @Test func noChimeOnACAndASafetyTripAtLidCloseWindsDownAtOnce() async throws {
        try await withHarness { h in
            await h.start()
            _ = await h.startWorking()
            h.fakes.safety.setTrip(.onBatteryNotAllowed(percent: 70))
            await h.closeLid()
            #expect(h.fakes.power.count(.chime) == 0)
            #expect(await h.phase() == .windingDown(reason: .safetyTrip(.onBatteryNotAllowed(percent: 70)), since: h.now))
            #expect(h.intents.contains(.safetyTrip(.onBatteryNotAllowed(percent: 70), runningAgents: 1)))
        }
    }

    @Test func lidCloseChimesOnACWhenSetToAlways() async throws {
        var settings = KakurenekoSettings.default
        settings.power.lidCloseSound = .always
        try await withHarness(settings: settings) { h in
            await h.start()
            h.power.onAC = true
            await h.emitSnapshot()
            _ = await h.startWorking()
            await h.closeLid()
            #expect(await h.phase() == .closedAwake(since: h.now))
            #expect(h.fakes.power.count(.chime) == 1)
        }
    }

    @Test func hotspotAtLidCloseWarnsWhileClosed() async throws {
        try await withHarness { h in
            await h.start()
            _ = await h.startWorking()
            h.power.networkExpensive = true
            await h.emitSnapshot()
            #expect(await !h.snapshot().warnings.contains { $0.id == "hotspot" })
            await h.closeLid()
            #expect(await h.snapshot().warnings.contains { $0.id == "hotspot" })
            await h.openLid()
            #expect(await !h.snapshot().warnings.contains { $0.id == "hotspot" })
        }
    }

    // MARK: Sleep and wake

    @Test func willSleepThawsFlushesTheOutboxThenAllows() async throws {
        try await withHarness { h in
            await h.start()
            h.log.removeAll()
            let ack = PowerChangeAcknowledger(onAllow: {})
            await h.emitPower(.willSleep(ack))
            #expect(ack.isAllowed)
            #expect(h.log.filtered(["pause.thawAll(willSleep)", "notify.drain"]) == ["pause.thawAll(willSleep)", "notify.drain"])
            #expect(h.fakes.notifications.drainDeadlines.last == h.now.addingTimeInterval(5))
        }
    }

    @Test func aWakeKicksTheOutboxAndReportsOnlySleepsKakurenekoStarted() async throws {
        try await withHarness { h in
            await h.start()
            // The user's own sleep (lid closed while disarmed): no "Mac slept" push.
            await h.emitPower(.willSleep(PowerChangeAcknowledger(onAllow: {})))
            h.advance(3600)
            await h.emitPower(.didWake)
            #expect(h.fakes.notifications.drainDeadlines.last == h.now.addingTimeInterval(10))
            #expect(!h.intentKinds.contains(.asleep))
            #expect(await h.phase() == .disarmed)
        }
    }

    /// The user asked to sleep although an agent works; a dark wake in the bag finds it still working (same turn):
    /// Kakureneko stays Disarmed. Opening the lid re-arms.
    @Test func aWakeWithTheLidClosedAfterASleepRequestDoesNotRearmForTheSameTurn() async throws {
        try await withHarness { h in
            await h.start()
            _ = await h.startWorking()
            await h.closeLid()
            await h.coordinator.sleepNow() // the user asked, although an agent works
            await h.passThawSettle()
            #expect(await waitUntil { h.fakes.power.count(.sleep) == 1 })
            await h.emitPower(.willSleep(PowerChangeAcknowledger(onAllow: {})))
            h.advance(600)
            h.fakes.power.setSleepDisabled(false)
            await h.emitPower(.didWake)
            await h.run(for: 30)
            #expect(await h.phase() == .disarmed)
            #expect(h.fakes.power.count(.arm) == 1)
            #expect(h.fakes.power.kernelFlags().sleepDisabled == false)
            #expect(h.intentKinds.contains(.asleep))

            await h.openLid()
            #expect(await h.phase() == .armed(since: h.now))
            #expect(h.fakes.power.count(.arm) == 2)
        }
    }

    // MARK: Main loop

    @Test func processScansFollowTheLidCadenceAndFeedTheEngine() async throws {
        try await withHarness { h in
            await h.start()
            #expect(h.fakes.claudeState.cadence == .lidOpen)
            await h.tick()
            #expect(h.fakes.processes.sampleCount == 1)
            await h.run(for: 14)
            #expect(h.fakes.processes.sampleCount == 1)
            await h.advanceAndTick(1)
            #expect(h.fakes.processes.sampleCount == 2)
            #expect(h.fakes.sessions.ingestedProcessSnapshots.count == 2)
            #expect(h.fakes.sessions.ticks.count == 16)

            _ = await h.startWorking()
            await h.closeLid()
            await h.tick()
            #expect(h.fakes.claudeState.cadence == .lidClosed)
            let afterClose = h.fakes.processes.sampleCount
            await h.run(for: 5)
            #expect(h.fakes.processes.sampleCount == afterClose + 1)
            await h.run(for: 5)
            #expect(h.fakes.processes.sampleCount == afterClose + 2)

            await h.openLid()
            await h.tick()
            #expect(h.fakes.claudeState.cadence == .lidOpen)
        }
    }

    @Test func sessionStoreHintsFollowTheSessions() async throws {
        try await withHarness { h in
            await h.start()
            let session = Fixture.session("s1", state: .working(since: h.now), agentPID: 100,
                                          metadata: [MetadataKey.transcriptPath: "/tmp/fake/s1.jsonl",
                                                     MetadataKey.sessionStoreDirectory: "/tmp/fake/s1"])
            h.setSessions([session])
            await h.tick()
            #expect(h.fakes.processes.lastHints == [SessionStoreHint(identity: Fixture.identity(100), paths: ["/tmp/fake/s1"])])
            h.setSessions([])
            await h.tick()
            #expect(h.fakes.processes.lastHints.isEmpty)
        }
    }

    @Test func theHeartbeatStopsAfterAFailedDisarmUntilTheNextArm() async throws {
        try await withHarness { h in
            await h.start()
            _ = await h.startWorking()
            h.fakes.power.setDisarmError(.notPermitted("sudo"))
            await h.coordinator.setEnabled(false)
            #expect(await h.coordinator.heartbeatSuppressed)
            let beats = h.fakes.power.count(.heartbeat)
            h.fakes.power.setDisarmError(nil)
            await h.coordinator.setEnabled(true)
            #expect(h.fakes.power.count(.heartbeat) == beats + 1) // touched right after the re-arm
            #expect(await !h.coordinator.heartbeatSuppressed)
            #expect(await !h.snapshot().warnings.contains { $0.id == "disarm-failed" })
        }
    }

    // MARK: Warnings derived by the actor

    @Test func appTamerRunningIsWarned() async throws {
        try await withHarness(appRunning: { $0 == KakurenekoID.appTamerBundleIdentifier }) { h in
            await h.start()
            #expect(await h.snapshot().warnings.contains { $0.id == "app-tamer" })
        }
    }

    @Test func aHeartbeatPathMismatchIsCriticalAndMeansNotificationsOnly() async throws {
        let mismatch = PrivilegedStatus(sudoRuleInstalled: true, failsafeLoaded: true,
                                        failsafeHeartbeatPath: "/Users/other/.kakureneko/run/heartbeat", heartbeatPathMismatch: true)
        try await withHarness(privileged: mismatch) { h in
            await h.start()
            let snapshot = await h.snapshot()
            #expect(snapshot.mode == .notificationsOnly)
            #expect(snapshot.warnings.first?.id == "heartbeat-path-mismatch")
            #expect(snapshot.warnings.first?.severity == .critical)
        }
    }

    @Test func lowPowerModeOnBatteryIsWarned() async throws {
        try await withHarness { h in
            await h.start()
            h.power.onAC = false
            h.power.lowPowerMode = true
            await h.emitSnapshot()
            #expect(await h.snapshot().warnings.contains { $0.id == "low-power-mode" })
        }
    }

    @Test func theArmingBlockedWarningClearsWhenNothingNeedsArming() async throws {
        try await withHarness { h in
            await h.start()
            h.fakes.safety.setArmingBlocker(.batteryFloor(percent: 15))
            _ = await h.startWorking()
            #expect(await h.snapshot().warnings.contains { $0.id == "arming-blocked" })
            h.setSessions([Fixture.session("s1", state: .idle(since: h.now, outcome: .completed))])
            await h.tick()
            #expect(await !h.snapshot().warnings.contains { $0.id == "arming-blocked" })
        }
    }
}
