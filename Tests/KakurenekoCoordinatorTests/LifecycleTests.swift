@testable import KakurenekoCoordinator
import KakurenekoKit
import Foundation
import Testing

/// ARCHITECTURE §9.8 `start()` order, launch reconcile, dry-run, settings, snapshots, termination.
@Suite("Coordinator lifecycle", .timeLimit(.minutes(1)))
struct LifecycleTests {
    // MARK: start()

    @Test func startRunsEveryStepInTheCardOrderAndSubscribesBeforeStarting() async throws {
        let helper = URL(filePath: "/nonexistent/Kakureneko.app/Contents/Helpers/kakureneko-hook")
        var settings = KakurenekoSettings.default
        settings.timers.finishCountdownMinutes = 7
        settings.notifications.awayIdleSeconds = 600
        try await withHarness(settings: settings, configure: { services, _ in services.bundledHookHelper = helper }) { h in
            await h.start()
            let order = ["pause.installCrashHandlers", "pause.recover", "install.deployHelper", "pause.selfTest",
                         "events.start", "claude.start", "processes.start", "power.start", "powerEvents.start",
                         "notify.start", "pause.startGuard"]
            #expect(h.log.filtered(Set(order)) == order)
            #expect(h.fakes.sessions.timers == settings.timers)
            #expect(h.fakes.notifications.appliedSettings == settings.notifications)
            #expect(h.fakes.events.subscriberCount == 1)
            #expect(h.fakes.powerEvents.subscriberCount == 1)
            #expect(!h.log.entries.contains("power.disarm")) // no stale flag to clear
            #expect(!h.log.entries.contains("events.drain")) // ingest only from the stream
            #expect(await h.coordinator.isRunning)
            #expect(await h.snapshot().mode == .full)
            #expect(await h.snapshot().groupingSelfTest?.method == .responsibility)
            #expect(FileManager.default.fileExists(atPath: h.paths.inboxDirectory.path(percentEncoded: false)))
            #expect(FileManager.default.fileExists(atPath: h.paths.appSupport.path(percentEncoded: false)))
        }
    }

    @Test func helperDeploymentIsSkippedOutsideABundle() async throws {
        try await withHarness { h in
            await h.start()
            #expect(!h.log.entries.contains("install.deployHelper"))
            #expect(h.log.entries.contains("pause.selfTest"))
        }
    }

    @Test func startIsIdempotentEvenWhenCalledConcurrently() async throws {
        try await withHarness { h in
            let coordinator = h.coordinator
            async let first: Void = coordinator.start()
            async let second: Void = coordinator.start()
            _ = await (first, second)
            await h.start()
            #expect(h.fakes.events.startCount == 1)
            #expect(h.log.entries.filter { $0 == "pause.recover" }.count == 1)
            #expect(h.fakes.pausing.calls.filter { $0 == .startGuard }.count == 1)
            #expect(h.fakes.events.subscriberCount == 1)
        }
    }

    @Test func noSignalSourcesAreInstalledWhenTheServicesDoNotHandleTerminationSignals() async throws {
        try await withHarness { h in
            #expect(h.services.handlesTerminationSignals == false)
            await h.start()
            #expect(await h.coordinator.signalSources == nil)
            // The (fake) crash handler is still installed through the pausing service.
            #expect(h.fakes.pausing.calls.contains(.installCrashHandlers))
        }
    }

    // MARK: Launch reconcile

    @Test func launchReconcileRecoversTheJournalFirstThenClearsAStaleRealFlag() async throws {
        try await withHarness { h in
            h.fakes.power.setSleepDisabled(true) // left behind by a killed run
            h.fakes.pausing.setRecoverCount(3)
            await h.start()
            let entries = h.log.entries
            let recover = try #require(entries.firstIndex(of: "pause.recover"))
            let disarm = try #require(entries.firstIndex(of: "power.disarm"))
            let eventsStart = try #require(entries.firstIndex(of: "events.start"))
            #expect(Array(entries.prefix(recover)) == ["pause.installCrashHandlers"])
            #expect(recover < disarm && disarm < eventsStart)
            #expect(h.fakes.power.kernelFlags().kernelSleepDisabled == false)
            #expect(await h.phase() == .disarmed)
            #expect(await !h.snapshot().warnings.contains { $0.id == "kernel-sleep-disabled" })
        }
    }

    @Test func launchReconcileKeepsTheFlagWhenAnAgentIsAlreadyWorking() async throws {
        try await withHarness { h in
            h.fakes.power.setSleepDisabled(true)
            h.setSessions([Fixture.session("s1", state: .working(since: h.now))])
            await h.start()
            #expect(!h.log.entries.contains("power.disarm"))
            #expect(await h.phase().isArmed)
        }
    }

    @Test func launchReconcileInDryRunWarnsAboutARealFlagAndNeverTouchesIt() async throws {
        try await withHarness(dryRun: .alwaysOn()) { h in
            h.fakes.power.setSimulatedFlags(simulated: false, kernel: true)
            await h.start()
            #expect(!h.log.entries.contains("power.disarm"))
            let snapshot = await h.snapshot()
            #expect(snapshot.isDryRun && snapshot.isDryRunForced)
            #expect(snapshot.warnings.first?.id == "kernel-sleep-disabled")
            #expect(snapshot.warnings.first?.severity == .critical)
            #expect(snapshot.warnings.contains { $0.id == "dry-run" })
        }
    }

    // MARK: Privileged status and dry-run

    @Test func dryRunWithoutThePrivilegedInstallSimulatesFullMode() async throws {
        try await withHarness(dryRun: .alwaysOn(), privileged: notInstalled) { h in
            await h.start()
            let snapshot = await h.snapshot()
            #expect(snapshot.mode == .full)
            #expect(snapshot.privileged.simulated && snapshot.privileged.isOperational)
            #expect(snapshot.warnings.contains { $0.id == "dry-run-privileged-simulated" })
            #expect(!snapshot.warnings.contains { $0.id == "privileged-missing" })
            _ = await h.startWorking()
            #expect(h.fakes.power.count(.arm) == 1) // every decision stays visible ("would arm")
        }
    }

    @Test func dryRunRequestedBySettingsAppliesAtStartAndSimulatesThePrivilegedInstall() async throws {
        var settings = KakurenekoSettings.default
        settings.general.dryRun = true
        try await withHarness(settings: settings, privileged: notInstalled) { h in
            #expect(!h.fakes.dryRun.isOn)
            await h.start()
            #expect(h.fakes.dryRun.isOn && !h.fakes.dryRun.isForcedByEnvironment)
            let snapshot = await h.snapshot()
            #expect(snapshot.isDryRun && !snapshot.isDryRunForced)
            #expect(snapshot.mode == .full && snapshot.privileged.simulated)
        }
    }

    /// LiveComposition rule 7: a dry-run requested only by SETTINGS is applied at start step 6 — after journal
    /// recovery and the kernel-flag reconcile ran under the real gate, so a crashed REAL run's frozen apps and stale
    /// `SleepDisabled` are undone for real (ARCHITECTURE §6: undo runs under the gate that acted).
    @Test func settingsRequestedDryRunUndoesACrashedRealRunBeforeTheGateFlips() async throws {
        var settings = KakurenekoSettings.default
        settings.general.dryRun = true
        let power = Ref<GateObservingPower>()
        let pausing = Ref<GateObservingPausing>()
        try await withHarness(settings: settings, configure: { services, fakes in
            let observedPower = GateObservingPower(base: fakes.power, gate: fakes.dryRun)
            let observedPausing = GateObservingPausing(base: fakes.pausing, gate: fakes.dryRun)
            services.power = observedPower
            services.pausing = observedPausing
            power.value = observedPower
            pausing.value = observedPausing
        }) { h in
            let power = try #require(power.value)
            let pausing = try #require(pausing.value)
            h.fakes.power.setSleepDisabled(true) // left behind by a killed REAL run
            h.fakes.pausing.setRecoverCount(2)
            await h.start()
            #expect(pausing.observed.first == "recoverFromJournal gate=false")
            #expect(power.observed.first == "disarm gate=false")
            #expect(h.fakes.power.kernelFlags().kernelSleepDisabled == false)
            #expect(h.fakes.dryRun.isOn && !h.fakes.dryRun.isForcedByEnvironment)
            let snapshot = await h.snapshot()
            #expect(snapshot.isDryRun)
            #expect(!snapshot.warnings.contains { $0.id == "kernel-sleep-disabled" })
        }
    }

    @Test func notificationsOnlyModeNeverArmsOrPausesButStillPushes() async throws {
        try await withHarness(privileged: notInstalled) { h in
            await h.start()
            #expect(await h.snapshot().mode == .notificationsOnly)
            #expect(await h.snapshot().warnings.contains { $0.id == "privileged-missing" })
            let session = await h.startWorking()
            await h.closeLid(lastInputAgo: 900)
            await h.run(for: 200, step: 5)
            #expect(h.fakes.power.count(.arm) == 0)
            #expect(h.pauseCount() == 0)
            #expect(await h.phase() == .disarmed)

            var waiting = session
            waiting.state = .waiting(kind: .permission, since: h.now)
            h.setSessions([waiting])
            h.fakes.sessions.queueEffects([Fixture.effect(.needsInput, waiting, at: h.now)])
            await h.tick()
            guard case .needsInput(_, let awakeUntil)? = h.intents.first(where: { $0.kind == .needsInput }) else {
                Issue.record("no needsInput push")
                return
            }
            #expect(awakeUntil == nil) // Kakureneko cannot keep the Mac awake
            #expect(!h.intentKinds.contains(.countdown))
            #expect(h.fakes.power.count(.arm) == 0)
        }
    }

    @Test func installingAndUninstallingClosedLidModeSwitchesTheMode() async throws {
        try await withHarness(privileged: notInstalled) { h in
            await h.start()
            #expect(await h.snapshot().mode == .notificationsOnly)

            h.fakes.privileged.setInstallError(.failed("User cancelled"))
            await #expect(throws: SideEffectError.self) { try await h.coordinator.installPrivilegedHelper() }
            #expect(await h.snapshot().mode == .notificationsOnly)

            h.fakes.privileged.setInstallError(nil)
            try await h.coordinator.installPrivilegedHelper()
            #expect(await h.snapshot().mode == .full)
            _ = await h.startWorking()
            #expect(h.fakes.power.count(.arm) == 1)

            h.log.removeAll()
            try await h.coordinator.uninstallPrivilegedHelper()
            #expect(h.log.filtered(["pause.thawAll(pausingDisabled)", "power.disarm", "privileged.uninstall"])
                    == ["pause.thawAll(pausingDisabled)", "power.disarm", "privileged.uninstall"])
            #expect(await h.snapshot().mode == .notificationsOnly)
            #expect(await h.phase() == .disarmed)
            #expect(h.fakes.power.count(.arm) == 1) // never re-armed in between
        }
    }

    @Test func dryRunToggleThawsAndDisarmsUnderTheOldGateBeforeFlippingIt() async throws {
        let power = Ref<GateObservingPower>()
        let pausing = Ref<GateObservingPausing>()
        try await withHarness(configure: { services, fakes in
            let observedPower = GateObservingPower(base: fakes.power, gate: fakes.dryRun)
            let observedPausing = GateObservingPausing(base: fakes.pausing, gate: fakes.dryRun)
            services.power = observedPower
            services.pausing = observedPausing
            power.value = observedPower
            pausing.value = observedPausing
        }) { h in
            let power = try #require(power.value)
            let pausing = try #require(pausing.value)
            await h.start()
            _ = await h.startWorking()
            #expect(power.observed == ["arm gate=false"])

            h.log.removeAll()
            var settings = await h.snapshot().settings
            settings.general.dryRun = true
            await h.coordinator.updateSettings(settings)
            #expect(power.observed == ["arm gate=false", "disarm gate=false", "arm gate=true"])
            #expect(pausing.observed == ["recoverFromJournal gate=false", "thawAll(pausingDisabled) gate=false"])
            #expect(h.log.filtered(["pause.thawAll(pausingDisabled)", "power.disarm", "power.arm"])
                    == ["pause.thawAll(pausingDisabled)", "power.disarm", "power.arm"])
            #expect(h.fakes.dryRun.isOn)
            #expect(await h.snapshot().isDryRun)
            #expect(await h.phase().isArmed) // re-stepped under the new gate

            settings.general.dryRun = false
            await h.coordinator.updateSettings(settings)
            #expect(Array(power.observed.suffix(2)) == ["disarm gate=true", "arm gate=false"])
            #expect(pausing.observed.last == "thawAll(pausingDisabled) gate=true")
            #expect(!h.fakes.dryRun.isOn)
        }
    }

    @Test func aForcedDryRunIgnoresTheSettingsToggle() async throws {
        try await withHarness(dryRun: .alwaysOn()) { h in
            await h.start()
            _ = await h.startWorking()
            h.log.removeAll()
            var settings = await h.snapshot().settings
            settings.general.dryRun = false
            await h.coordinator.updateSettings(settings)
            #expect(h.fakes.dryRun.isOn)
            #expect(!h.log.entries.contains("power.disarm")) // the effective gate did not change
        }
    }

    // MARK: Events and settings

    @Test func eventsQueuedBeforeStartAreIngestedExactlyOnce() async throws {
        try await withHarness { h in
            let events = (1...3).map { Fixture.agentEvent("e\($0)", session: "s\($0)", at: h.now) }
            h.fakes.events.queueForDrain(events)
            await h.start()
            #expect(await waitUntil { await h.coordinator.handled.agentEvents == 3 })
            await h.run(for: 3)
            let late = Fixture.agentEvent("e4", session: "s4", at: h.now)
            h.fakes.events.emit(late)
            #expect(await waitUntil { await h.coordinator.handled.agentEvents == 4 })
            #expect(h.fakes.sessions.ingestedEvents.map(\.id) == ["e1", "e2", "e3", "e4"])
            #expect(!h.log.entries.contains("events.drain"))
            #expect(await h.coordinator.lastEventSeen[.claude] == late.receivedAt)
        }
    }

    @Test func claudeStateSnapshotsAreIngested() async throws {
        try await withHarness { h in
            await h.start()
            h.fakes.claudeState.emit(.empty(at: h.now))
            #expect(await waitUntil { await h.coordinator.handled.claudeSnapshots == 1 })
            #expect(h.fakes.sessions.ingestedClaudeStates.count == 1)
        }
    }

    @Test func settingsAreNormalizedPersistedAndReapplied() async throws {
        try await withHarness { h in
            await h.start()
            var proposed = KakurenekoSettings.default
            proposed.timers.finishCountdownMinutes = 999
            proposed.notifications.awayIdleSeconds = 900
            proposed.power.keepAwakeButtonSeconds = 7200
            await h.coordinator.updateSettings(proposed)
            let expected = proposed.normalized()
            #expect(expected.timers.finishCountdownMinutes == SessionTimers.finishCountdownMinutesRange.upperBound)
            #expect(KakurenekoSettings.load(from: h.paths.settingsFile) == expected)
            #expect(h.fakes.sessions.timers == expected.timers)
            #expect(h.fakes.notifications.appliedSettings == expected.notifications)
            #expect(await h.snapshot().settings == expected)

            await h.coordinator.setNeverPause(bundleID: "com.spotify.client", true)
            await h.coordinator.completeOnboarding()
            let saved = KakurenekoSettings.load(from: h.paths.settingsFile)
            #expect(saved.pausing.neverPauseBundleIDs == ["com.spotify.client"])
            #expect(saved.general.onboardingCompleted)
            await h.coordinator.setNeverPause(bundleID: "com.spotify.client", false)
            #expect(KakurenekoSettings.load(from: h.paths.settingsFile).pausing.neverPauseBundleIDs.isEmpty)

            // A pushed context carries the keep-awake button length.
            h.setSessions([Fixture.session("s1", state: .stalled(since: h.now))])
            h.fakes.sessions.queueEffects([Fixture.effect(.stalled, Fixture.session("s1", state: .stalled(since: h.now)), at: h.now)])
            await h.tick()
            #expect(h.fakes.notifications.submittedContexts.last?.keepAwakeSeconds == 7200)

            // A fresh coordinator without explicit settings loads what was saved.
            let relaunched = KakurenekoCoordinator(services: h.services)
            let reloaded = KakurenekoSettings.load(from: h.paths.settingsFile)
            #expect(await relaunched.settings == reloaded)
            #expect(await relaunched.currentSnapshot().settings == reloaded)
        }
    }

    @Test func anOlderSettingsFileIsWrittenBackMigrated() async throws {
        try await withHarness { h in
            try FileManager.default.createDirectory(at: h.paths.settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"version":1,"notifications":{"provider":"ntfy","presenceGating":"awayOnly"}}"#.utf8).write(to: h.paths.settingsFile)
            #expect(KakurenekoSettings.storedVersion(at: h.paths.settingsFile) == 1)
            await h.start()
            #expect(KakurenekoSettings.storedVersion(at: h.paths.settingsFile) == KakurenekoSettings.currentVersion)
            let text = try String(contentsOf: h.paths.settingsFile, encoding: .utf8)
            #expect(!text.contains("ntfy"))
            // Up to date already: not rewritten.
            let before = try FileManager.default.attributesOfItem(atPath: h.paths.settingsFile.path)[.modificationDate] as? Date
            await h.coordinator.performStart()
            let after = try FileManager.default.attributesOfItem(atPath: h.paths.settingsFile.path)[.modificationDate] as? Date
            #expect(before == after)
        }
    }

    @Test func turningKakurenekoOffAndOnAgain() async throws {
        try await withHarness { h in
            await h.start()
            _ = await h.startWorking()
            await h.coordinator.setEnabled(false)
            #expect(await h.snapshot().mode == .disabled)
            #expect(await h.phase() == .disarmed)
            #expect(h.thawReasons().contains(.pausingDisabled))
            #expect(KakurenekoSettings.load(from: h.paths.settingsFile).general.enabled == false)
            await h.advanceAndTick(5)
            #expect(h.fakes.power.count(.arm) == 1)
            await h.coordinator.setEnabled(true)
            #expect(await h.snapshot().mode == .full)
            #expect(await h.phase().isArmed)
            #expect(h.fakes.power.count(.arm) == 2)
        }
    }

    @Test func concurrentSettingsUpdatesApplyInOrder() async throws {
        try await withHarness { h in
            await h.start()
            _ = await h.startWorking()
            let coordinator = h.coordinator
            var dryRunOn = KakurenekoSettings.default
            dryRunOn.general.dryRun = true
            var dryRunOff = dryRunOn
            dryRunOff.general.dryRun = false
            dryRunOff.timers.finishCountdownMinutes = 9
            let on = dryRunOn
            let off = dryRunOff
            h.log.removeAll()
            async let first: Void = coordinator.updateSettings(on)
            async let second: Void = coordinator.updateSettings(off)
            _ = await (first, second)
            // Either order is fine, but each update ran its full undo before the next one looked at the gate:
            // the gate matches the settings that won, and every flip paired one thaw with one disarm.
            let final = await h.snapshot().settings
            #expect(final == on.normalized() || final == off.normalized())
            #expect(h.fakes.dryRun.isOn == final.general.dryRun)
            let thaws = h.log.entries.filter { $0 == "pause.thawAll(pausingDisabled)" }.count
            let disarms = h.log.entries.filter { $0 == "power.disarm" }.count
            #expect(thaws == disarms && (1...2).contains(thaws))
            #expect(await h.coordinator.decisionSuspensions == 0)
            #expect(await h.phase().isArmed)
        }
    }

    // MARK: Snapshots

    @Test func snapshotsPublishOnChangeWithoutAdvancingTheClock() async throws {
        try await withHarness { h in
            let collector = SnapshotCollector(h.coordinator.snapshots())
            defer { collector.stop() }
            #expect(await waitUntil { collector.count >= 1 }) // the replayed initial snapshot
            #expect(collector.snapshots.first?.mode == .starting)
            await h.start()
            #expect(await waitUntil { collector.snapshots.last?.mode == .full })

            let t = h.now
            let published = await h.coordinator.publisher.count
            await h.coordinator.keepAwake(for: 600)
            #expect(h.now == t)
            #expect(await h.coordinator.publisher.count == published + 1) // leading edge: at once
            #expect(await waitUntil { collector.snapshots.last?.keepAwakeUntil == t.addingTimeInterval(600) })

            // A second change inside the 250 ms window is only marked dirty …
            await h.coordinator.cancelKeepAwake()
            #expect(await h.coordinator.publisher.count == published + 1)
            #expect(await h.coordinator.publisher.dirty)
            // … and the next tick flushes it.
            await h.coordinator.tick()
            #expect(await h.coordinator.publisher.count == published + 2)
            #expect(await waitUntil { collector.snapshots.last?.keepAwakeUntil == nil })

            // An unchanged state publishes nothing.
            let settled = await h.coordinator.publisher.count
            await h.coordinator.tick()
            await h.coordinator.tick()
            #expect(await h.coordinator.publisher.count == settled)

            // ≥ 250 ms later a change publishes at once again.
            h.advance(0.3)
            await h.coordinator.keepAwake(for: 60)
            #expect(await h.coordinator.publisher.count == settled + 1)
        }
    }

    @Test func snapshotExcludesEndedSessionsAndCarriesTheDryRunLedgerTail() async throws {
        try await withHarness(dryRun: .alwaysOn()) { h in
            await h.start()
            h.setSessions([
                Fixture.session("live", state: .working(since: h.now)),
                Fixture.session("gone", state: .ended(at: h.now)),
            ])
            for index in 0..<60 { h.fakes.ledger.record(.power, action: "power.arm", detail: "would arm #\(index)") }
            await h.tick()
            let snapshot = await h.snapshot()
            #expect(snapshot.sessions.map(\.key.id) == ["live"])
            #expect(snapshot.dryRunLog.count == 50)
            #expect(snapshot.dryRunLog.last?.detail == "would arm #59")
        }
    }

    @Test func resumeOfferIsReadAtLaunchAndCanBeCleared() async throws {
        try await withHarness { h in
            let entry = ResumeEntry(agent: .claude, sessionId: "abc", cwd: "/Users/tester/code/api", title: "api")
            try ResumeManifest.write([entry], to: h.paths.resumeManifestFile)
            await h.start()
            #expect(await h.snapshot().resumeOffer == [entry])
            await h.coordinator.clearResumeOffer()
            #expect(await h.snapshot().resumeOffer.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: h.paths.resumeManifestFile.path(percentEncoded: false)))
        }
    }

    @Test func integrationsCarryLastEventSeenAndRepairWarnings() async throws {
        try await withHarness { h in
            h.fakes.integrations.setStatuses([
                IntegrationStatus(agent: .claude, supported: true, configDirExists: true, installed: true),
                IntegrationStatus(agent: .codex, supported: true, configDirExists: true, installed: true, needsRepair: true),
            ])
            await h.start()
            let event = Fixture.agentEvent("e1", session: "s1", at: h.now)
            h.fakes.events.emit(event)
            #expect(await waitUntil { await h.coordinator.handled.agentEvents == 1 })
            await h.coordinator.refreshIntegrations()
            var snapshot = await h.snapshot()
            #expect(snapshot.integrations.first { $0.agent == .claude }?.lastEventSeen == event.receivedAt)
            #expect(snapshot.warnings.contains { $0.id == "integration-repair:codex" })

            h.fakes.integrations.setStatuses([
                IntegrationStatus(agent: .claude, supported: true, configDirExists: true, installed: true),
                IntegrationStatus(agent: .codex, supported: true, configDirExists: true, installed: true),
            ])
            _ = try await h.coordinator.repairIntegration(.codex)
            snapshot = await h.snapshot()
            #expect(!snapshot.warnings.contains { $0.id == "integration-repair:codex" })
            #expect(h.fakes.integrations.calls.contains(.repair(.codex)))
            _ = try await h.coordinator.previewIntegration(.gemini, operation: .install)
            #expect(h.fakes.integrations.calls.contains(.preview(.gemini, .install)))
        }
    }

    @Test func dismissingASessionGoesThroughTheEngine() async throws {
        try await withHarness { h in
            await h.start()
            let stuck = Fixture.session("s1", state: .working(since: h.now))
            h.setSessions([stuck])
            await h.tick()
            await h.coordinator.dismissSession(stuck.key)
            #expect(h.fakes.sessions.dismissedKeys == [stuck.key])
            #expect(await h.snapshot().sessions.isEmpty)
        }
    }

    // MARK: Termination

    @Test func prepareForTerminationCancelsTheWindDownThawsDisarmsDrainsThenStops() async throws {
        try await withHarness { h in
            await h.start()
            _ = await h.startWorking()
            await h.closeLid()
            await h.coordinator.sleepNow()
            #expect(await h.waitForSleepers()) // the wind-down waits its 3 s
            h.log.removeAll()
            await h.coordinator.prepareForTermination()
            let expected = ["pause.thawAll(appQuitting)", "power.disarm", "notify.drain", "pause.stopGuard",
                            "events.stop", "claude.stop", "processes.stop", "powerEvents.stop", "notify.stop"]
            #expect(h.log.filtered(Set(expected)) == expected)
            #expect(h.fakes.notifications.drainDeadlines.last == h.now.addingTimeInterval(2))
            #expect(h.clock.sleeperCount == 0)

            h.advance(10)
            await h.coordinator.tick()
            #expect(h.fakes.power.count(.sleep) == 0)
            #expect(await h.phase() == .disarmed)

            let count = h.log.entries.count
            await h.coordinator.prepareForTermination()
            await h.coordinator.start()
            #expect(h.log.entries.count == count)
        }
    }
}
