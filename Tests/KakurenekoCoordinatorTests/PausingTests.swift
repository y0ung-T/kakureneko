@testable import KakurenekoCoordinator
import KakurenekoKit
import Foundation
import Testing

/// ARCHITECTURE §9.8 "Pausing": the pause gate (brief §6.1), the topology the coordinator augments, recheck,
/// and every thaw trigger of brief §6.5.5 (plus the hard cap and the CPU watchdog).
@Suite("Coordinator pausing", .timeLimit(.minutes(1)))
struct PausingTests {
    /// Starts, arms with a working session, closes the lid (idle for 10 min) and runs until the 90 s settle
    /// elapsed and `pause` ran. Returns the paused app list.
    @discardableResult
    static func pauseApps(_ h: Harness, mode: PauseMode = .throttle) async -> [PausedApp] {
        await h.start()
        _ = await h.startWorking()
        await h.closeLid(lastInputAgo: 600)
        let pausedAt = h.now.addingTimeInterval(90)
        let apps = [Fixture.pausedApp("Spotify", pid: 900, mode: mode, at: pausedAt)]
        h.fakes.pausing.setNextReport(PauseReport(at: pausedAt, paused: apps))
        await h.run(for: 90, step: 10)
        #expect(h.pauseCount() == 1)
        #expect(await h.snapshot().pausedApps == apps)
        return apps
    }

    @Test func pauseWaitsForTheSettleDelayAndCarriesTheSessionHostPIDs() async throws {
        try await withHarness { h in
            await h.start()
            h.fakes.processes.setTopology(AgentTopology(builtAt: h.now, agentIdentities: [Fixture.identity(55)]))
            _ = await h.startWorking()
            await h.closeLid(lastInputAgo: 600)
            await h.run(for: 89, step: 10)
            #expect(h.pauseCount() == 0)
            await h.advanceAndTick(1)
            #expect(h.pauseCount() == 1)
            let topology = try #require(h.fakes.pausing.receivedTopologies.last)
            #expect(topology.sessionHostPIDs == [4242])
            #expect(topology.agentIdentities == [Fixture.identity(55), Fixture.identity(100)])
            // A fresh topology right before `pause`.
            #expect(Array(h.log.filtered(["processes.topology", "pause.pause"]).suffix(2)) == ["processes.topology", "pause.pause"])
            #expect(await h.coordinator.pause.active)
        }
    }

    @Test func recentUserInputDelaysPausingUntilSixtySecondsOfIdle() async throws {
        try await withHarness { h in
            await h.start()
            _ = await h.startWorking()
            await h.closeLid(lastInputAgo: 600)
            await h.run(for: 80, step: 10)
            await h.userActivity() // Screen Sharing input 10 s before the settle ends
            #expect(h.thawReasons().last == .userInput)
            await h.advanceAndTick(10) // settle reached, idle 10 s
            #expect(h.pauseCount() == 0)
            await h.run(for: 49, step: 7) // idle 59 s
            #expect(h.pauseCount() == 0)
            await h.advanceAndTick(1) // idle 60 s
            #expect(h.pauseCount() == 1)
        }
    }

    @Test func noPausingWithAnExternalDisplayAndTheSettleRestartsWhenItDisconnects() async throws {
        try await withHarness { h in
            await h.start()
            _ = await h.startWorking()
            await h.closeLid(lastInputAgo: 600, external: true)
            await h.run(for: 300, step: 10)
            #expect(h.pauseCount() == 0)

            h.power.externalDisplay = false
            h.scriptPower()
            await h.emitPower(.externalDisplayChanged(connected: false))
            await h.run(for: 80, step: 10)
            #expect(h.pauseCount() == 0)
            await h.run(for: 10, step: 10)
            #expect(h.pauseCount() == 1)
        }
    }

    @Test func noPausingWhenPausingIsOff() async throws {
        var settings = KakurenekoSettings.default
        settings.pausing.enabled = false
        try await withHarness(settings: settings) { h in
            await h.start()
            _ = await h.startWorking()
            await h.closeLid(lastInputAgo: 600)
            await h.run(for: 200, step: 10)
            #expect(h.pauseCount() == 0)
            #expect(await h.phase() == .closedAwake(since: h.now.addingTimeInterval(-200)))
        }
    }

    @Test func noPausingWhenNothingIsWorkingTheMacWindsDownInstead() async throws {
        try await withHarness { h in
            await h.start()
            _ = await h.startWorking()
            await h.closeLid(lastInputAgo: 600)
            h.setSessions([Fixture.session("s1", state: .idle(since: h.now, outcome: .completed))])
            await h.run(for: 200, step: 10)
            #expect(h.pauseCount() == 0)
            guard case .countdown = await h.phase() else {
                Issue.record("expected a countdown")
                return
            }
        }
    }

    @Test func pausingKeepsAWaitingSessionsGraceButStopsWithIt() async throws {
        try await withHarness { h in
            await h.start()
            _ = await h.startWorking()
            await h.closeLid(lastInputAgo: 600)
            let waitingSince = h.now
            h.setSessions([Fixture.session("s1", state: .waiting(kind: .permission, since: waitingSince), agentPID: 100, hostPID: 4242)])
            await h.run(for: 90, step: 10)
            #expect(h.pauseCount() == 1) // shouldStayArmed: the waiting grace holds
            await h.run(for: 510, step: 30) // the needs-input grace (10 min) ends
            #expect(h.thawReasons().contains(.noAgentWorking))
        }
    }

    @Test func recheckRunsEveryRecheckIntervalWithAFreshAugmentedTopology() async throws {
        try await withHarness { h in
            await Self.pauseApps(h)
            let topologies = h.fakes.processes.topologyCount
            await h.run(for: 14, step: 7)
            #expect(!h.fakes.pausing.calls.contains(.recheck))
            await h.advanceAndTick(1)
            #expect(h.fakes.pausing.calls.filter { $0 == .recheck }.count == 1)
            #expect(h.fakes.processes.topologyCount == topologies + 1)
            #expect(h.fakes.pausing.receivedTopologies.last?.sessionHostPIDs == [4242])
            #expect(h.fakes.pausing.receivedTopologies.last?.agentIdentities.contains(Fixture.identity(100)) == true)
            await h.run(for: 15, step: 5)
            #expect(h.fakes.pausing.calls.filter { $0 == .recheck }.count == 2)
            #expect(h.pauseCount() == 1)
        }
    }

    enum ThawTrigger: String, CaseIterable, Sendable {
        case lidOpens, externalDisplayConnects, userActivity, freshInputInASnapshot, willSleep, willPowerOff
        case sessionResignsActive, beforePowerAction, appQuitting, pausingTurnedOff, kakurenekoTurnedOff
        case noAgentWorking, resumeAll

        var reason: ThawReason {
            switch self {
            case .lidOpens: .lidOpened
            case .externalDisplayConnects: .externalDisplay
            case .userActivity, .freshInputInASnapshot: .userInput
            case .willSleep: .willSleep
            case .willPowerOff: .willPowerOff
            case .sessionResignsActive: .sessionResignedActive
            case .beforePowerAction: .beforePowerAction
            case .appQuitting: .appQuitting
            case .pausingTurnedOff, .kakurenekoTurnedOff: .pausingDisabled
            case .noAgentWorking: .noAgentWorking
            case .resumeAll: .userRequest
            }
        }
    }

    @Test(arguments: ThawTrigger.allCases)
    func everyThawTriggerCallsThawAllWithItsReason(_ trigger: ThawTrigger) async throws {
        try await withHarness { h in
            await Self.pauseApps(h)
            let before = h.thawReasons().count
            switch trigger {
            case .lidOpens:
                await h.openLid()
            case .externalDisplayConnects:
                h.power.externalDisplay = true
                h.scriptPower()
                await h.emitPower(.externalDisplayChanged(connected: true))
            case .userActivity:
                await h.userActivity()
            case .freshInputInASnapshot:
                h.power.lastInputAt = h.now.addingTimeInterval(-2)
                await h.emitSnapshot()
            case .willSleep:
                let ack = PowerChangeAcknowledger(onAllow: {})
                await h.emitPower(.willSleep(ack))
                #expect(ack.isAllowed)
            case .willPowerOff:
                await h.emitPower(.willPowerOff)
            case .sessionResignsActive:
                await h.emitPower(.sessionResignedActive)
            case .beforePowerAction:
                await h.coordinator.sleepNow()
                #expect(await waitUntil { h.thawReasons().contains(.beforePowerAction) })
            case .appQuitting:
                await h.coordinator.prepareForTermination()
            case .pausingTurnedOff:
                var settings = await h.snapshot().settings
                settings.pausing.enabled = false
                await h.coordinator.updateSettings(settings)
            case .kakurenekoTurnedOff:
                await h.coordinator.setEnabled(false)
            case .noAgentWorking:
                h.setSessions([Fixture.session("s1", state: .idle(since: h.now, outcome: .completed))])
                await h.advanceAndTick(1)
            case .resumeAll:
                await h.coordinator.resumeAllApps()
            }
            #expect(Array(h.thawReasons().dropFirst(before)).first == trigger.reason)
            #expect(await h.snapshot().pausedApps.isEmpty)
            #expect(await h.coordinator.pause.active == false)
        }
    }

    @Test func resumeAllSuppressesPausingUntilTheNextLidEdge() async throws {
        try await withHarness { h in
            await Self.pauseApps(h)
            await h.coordinator.resumeAllApps()
            await h.run(for: 200, step: 10)
            #expect(h.pauseCount() == 1)
            await h.openLid()
            h.power.lastInputAt = h.now.addingTimeInterval(-600)
            await h.closeLid(lastInputAgo: 600)
            await h.run(for: 90, step: 10)
            #expect(h.pauseCount() == 2)
        }
    }

    @Test func theHardCapThawsAndStopsPausingForThisClosedLidPeriod() async throws {
        var settings = KakurenekoSettings.default
        settings.pausing.maxPausedHours = 1
        try await withHarness(settings: settings) { h in
            await Self.pauseApps(h)
            await h.advanceAndTick(3599)
            #expect(!h.thawReasons().contains(.hardCap))
            await h.advanceAndTick(1)
            #expect(h.thawReasons().last == .hardCap)
            await h.run(for: 300, step: 30)
            #expect(h.pauseCount() == 1)
        }
    }

    @Test func theWatchdogThawsWhenAWorkingAgentsCPUStallsWhileAppsAreFrozen() async throws {
        var settings = KakurenekoSettings.default
        settings.pausing.mode = .freeze
        try await withHarness(settings: settings) { h in
            // Agent pid 100's tree CPU never advances.
            h.fakes.processes.setSnapshot(ProcessSnapshot(takenAt: h.now, agents: [Fixture.agentProcess(100, cpuSeconds: 12, at: h.now)]))
            let apps = await Self.pauseApps(h, mode: .freeze)
            let frozenSince = try #require(apps.first?.pausedAt)
            h.clock.set(frozenSince.addingTimeInterval(295))
            await h.tick()
            #expect(!h.thawReasons().contains(.watchdog))
            await h.run(for: 5, step: 5) // 5 min (watchdogMinutes) since the freeze
            #expect(h.thawReasons().last == .watchdog)
            await h.run(for: 120, step: 10)
            #expect(h.pauseCount() == 1) // suppressed until the next lid edge
        }
    }

    @Test func theWatchdogStaysQuietWhileTheAgentsCPUAdvances() async throws {
        var settings = KakurenekoSettings.default
        settings.pausing.mode = .freeze
        try await withHarness(settings: settings) { h in
            h.fakes.processes.setSnapshot(ProcessSnapshot(takenAt: h.now, agents: [Fixture.agentProcess(100, cpuSeconds: 1, at: h.now)]))
            await Self.pauseApps(h, mode: .freeze)
            for step in 1...40 {
                h.fakes.processes.setSnapshot(ProcessSnapshot(takenAt: h.now, agents: [Fixture.agentProcess(100, cpuSeconds: 1 + Double(step), at: h.now)]))
                await h.advanceAndTick(10)
            }
            #expect(!h.thawReasons().contains(.watchdog))
            #expect(await h.coordinator.pause.active)
        }
    }

    @Test func aThawRequestedWhilePauseRunsWaitsForItAndThawsWhatItPaused() async throws {
        let slow = Ref<SlowPausing>()
        try await withHarness(configure: { services, fakes in
            let pausing = SlowPausing(base: fakes.pausing, clock: fakes.clock)
            services.pausing = pausing
            slow.value = pausing
        }) { h in
            _ = try #require(slow.value)
            await h.start()
            _ = await h.startWorking()
            await h.closeLid(lastInputAgo: 600)
            h.fakes.pausing.setNextReport(PauseReport(at: h.now, paused: [Fixture.pausedApp("Spotify", pid: 900, at: h.now)]))
            await h.run(for: 85, step: 5)
            h.advance(5)
            let coordinator = h.coordinator
            let tick = Task { await coordinator.tick() }
            #expect(await h.waitForSleepers()) // `pause` is in flight

            // The lid opens meanwhile: the thaw is decided but must wait for the in-flight `pause`.
            h.power.lid = .open
            h.power.lastInputAt = h.now
            h.scriptPower()
            h.fakes.powerEvents.emit(.lidChanged(.open))
            #expect(await waitUntil { await coordinator.pause.lastThawReason == .lidOpened })
            #expect(!h.thawReasons().contains(.lidOpened))

            h.advance(2) // `pause` returns
            await tick.value
            #expect(await waitUntil { h.thawReasons().contains(.lidOpened) })
            #expect(h.log.filtered(["pause.pause", "pause.thawAll(lidOpened)"]) == ["pause.pause", "pause.thawAll(lidOpened)"])
            #expect(await waitUntil { await coordinator.handled.powerEvents >= 3 })
            #expect(await h.snapshot().pausedApps.isEmpty)
            #expect(await coordinator.pause.active == false)
            #expect(await h.phase().isArmed)
        }
    }

    @Test func pausingObservesProcessesOnlyWhileTheLidIsClosed() async throws {
        try await withHarness { h in
            await h.start()
            _ = await h.startWorking()
            await h.run(for: 30, step: 15)
            #expect(!h.fakes.pausing.calls.contains(.observe))
            await h.closeLid(lastInputAgo: 600)
            await h.run(for: 10, step: 5)
            #expect(h.fakes.pausing.calls.contains(.observe))
        }
    }
}
