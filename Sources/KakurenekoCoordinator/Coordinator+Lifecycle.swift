// start() order (ARCHITECTURE §9.8), launch reconcile (brief §7.3 "On launch"), stream subscriptions,
// prepareForTermination().

import KakurenekoKit
import Foundation

extension KakurenekoCoordinator {
    var isRunning: Bool { if case .running = lifecycle { true } else { false } }
    var isTerminated: Bool { if case .terminated = lifecycle { true } else { false } }

    // MARK: start

    /// Idempotent: a second call waits for the first to finish; calls after termination do nothing.
    public func start() async {
        switch lifecycle {
        case .idle:
            let task = Task { await self.performStart() }
            lifecycle = .starting(task)
            await task.value
        case .starting(let task):
            await task.value
        case .running, .terminated:
            return
        }
    }

    func performStart() async {
        let paths = services.paths
        logger.notice("starting (dry-run \(services.dryRun.isOn), forced \(services.dryRun.isForcedByEnvironment))")

        // 1. Own directories, crash handler, termination signals (live only).
        do {
            try DirectoryLayout.ensureUserDirectories(paths)
        } catch {
            logger.error("could not create Kakureneko's directories: \(error)")
        }
        // A settings file of an older version was migrated in memory (`normalized()`); write it back once so the file
        // matches what Kakureneko does (e.g. v1 → v2: native notifications).
        if let stored = KakurenekoSettings.storedVersion(at: paths.settingsFile), stored < KakurenekoSettings.currentVersion {
            do {
                try settings.save(to: paths.settingsFile)
                logger.notice("settings migrated from version \(stored) to \(KakurenekoSettings.currentVersion)")
            } catch {
                logger.error("could not write the migrated settings: \(error)")
            }
        }
        services.pausing.installCrashHandlers()
        if services.handlesTerminationSignals, signalSources == nil {
            signalSources = TerminationSignals.install(pausing: services.pausing, power: services.power, logger: logger)
        }

        // 2. Journal recovery FIRST (a previous run may have left apps paused).
        let recovered = await services.pausing.recoverFromJournal()
        if recovered > 0 { logger.notice("launch recovery thawed \(recovered) process(es)") }
        guard !isTerminated else { return }

        // 3. Reconcile with the REAL kernel flag. The display state is read here too: it decides the EFFECTIVE lid (a
        //    clamshell desk counts as open), and a session ingested while step 7 starts the services (the first
        //    Claude record scan) must never be evaluated as "lid closed, no display" on a clamshell Mac.
        let flags = services.power.kernelFlags()
        lid = flags.lid
        externalDisplayConnected = await services.power.snapshot().externalDisplayConnected
        guard !isTerminated else { return }
        effectiveLidClosed = PowerPredicates.effectiveLidClosed(lid: lid, externalDisplayConnected: externalDisplayConnected)
        machine = PowerStateMachine(effectiveLidClosed: effectiveLidClosed, now: services.clock.now())
        await reconcileKernelFlag(flags)
        guard !isTerminated else { return }

        // 4. Privileged health → mode (simulated `.full` in dry-run).
        let status = await services.privileged.healthCheck()
        privilegedChecked = true
        applyPrivilegedStatus(status)
        guard !isTerminated else { return }

        // 5. Hook helper deployment, grouping self-test.
        if let helper = services.bundledHookHelper {
            do {
                let deployment = try await services.integrations.deployHelper(from: helper)
                logger.info("hook helper \(deployment.copied ? "deployed" : "up to date")")
            } catch {
                logger.error("hook helper deployment failed: \(error)")
            }
        }
        groupingSelfTest = await services.pausing.selfTest()
        guard !isTerminated else { return }

        // 6. Apply settings (nothing is armed or paused yet).
        services.sessions.updateTimers(settings.timers)
        await services.notifications.applySettings(NotificationRouting.effectiveNotificationSettings(settings))
        let gateBefore = services.dryRun.isOn
        services.dryRun.setRequested(settings.general.dryRun)
        if gateBefore != services.dryRun.isOn { applyPrivilegedStatus(rawPrivileged) }
        resumeOffer = ResumeManifest.launchOffer(at: paths.resumeManifestFile, bootTime: options.bootTime())
        guard !isTerminated else { return }

        // 7. Subscribe, then start (nothing is buffered for subscribers that do not exist yet).
        subscribeToStreams()
        do {
            try await services.events.start()
        } catch {
            logger.error("event inbox failed to start: \(error)")
        }
        await services.claudeState.start()
        await services.processes.start()
        await services.power.start()
        await services.powerEvents.start()
        await services.notifications.start()
        guard !isTerminated else { return }

        absorb(await services.power.snapshot())
        notificationStatus = await services.notifications.status()
        lastIntegrationRefreshAt = services.clock.now()
        integrationStatuses = await services.integrations.statuses()
        lastEventSeen.merge(await services.events.lastEventSeen()) { max($0, $1) }
        checkConflictingApps(now: services.clock.now())
        guard !isTerminated else { return }

        // 8. Guard, main loop.
        do {
            try services.pausing.startGuard()
        } catch {
            logger.error("pause guard failed to start: \(error)")
        }
        lifecycle = .running
        await updateCadenceAndHints()
        await process([])
        publishIfChanged(force: true, opensWindow: false)
        // The launch publishes are lifecycle, not changes: the first change after start publishes at once.
        publisher.lastPublishAt = nil
        startMainLoop()
        logger.notice("started: mode \(mode.rawValue), privileged operational \(privileged.isOperational)\(privileged.simulated ? " (simulated)" : "")")
    }

    /// Launch reconcile: a REAL `SleepDisabled` left by a crashed or killed run is cleared when the gate is off
    /// (nothing can be working yet: no session was ingested); with the gate on it is only reported (the heartbeat
    /// is never touched in dry-run, so the root fail-safe clears it).
    func reconcileKernelFlag(_ flags: KernelPowerFlags) async {
        guard flags.kernelSleepDisabled == true else {
            kernelSleepDisabledInDryRun = false
            return
        }
        if services.dryRun.isOn {
            kernelSleepDisabledInDryRun = true
            logger.error("the REAL kernel SleepDisabled flag is set while dry-run is on; not touching it (the root fail-safe clears it)")
            return
        }
        guard !services.sessions.aggregate.anyWorking else { return }
        logger.notice("launch reconcile: clearing a stale SleepDisabled flag")
        if !(await disarmFlag(context: "launch reconcile")) {
            await reportDisarmFailure()
        }
    }

    /// Obtains every stream and spawns its consumer BEFORE any service starts.
    func subscribeToStreams() {
        guard consumerTasks.isEmpty else { return }
        let agentEvents = services.events.events()
        let commands = services.notifications.remoteCommands()
        let powerEvents = services.powerEvents.events()
        let claudeSnapshots = services.claudeState.snapshots()
        consumerTasks = [
            Task { [weak self] in
                for await event in agentEvents {
                    guard let self else { return }
                    await self.handleAgentEvent(event)
                }
            },
            Task { [weak self] in
                for await command in commands {
                    guard let self else { return }
                    await self.handleRemoteCommand(command)
                }
            },
            Task { [weak self] in
                for await event in powerEvents {
                    guard let self else { return }
                    await self.handlePowerEvent(event)
                }
            },
            Task { [weak self] in
                for await snapshot in claudeSnapshots {
                    guard let self else { return }
                    await self.handleClaudeSnapshot(snapshot)
                }
            },
        ]
    }

    func startMainLoop() {
        guard options.runsMainLoop, mainLoopTask == nil else { return }
        let clock = services.clock
        let interval = options.tickInterval
        mainLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: interval)
                } catch {
                    return
                }
                guard let self else { return }
                await self.tick()
            }
        }
    }

    // MARK: Termination

    /// `applicationShouldTerminate`: cancel the wind-down, thaw, disarm (in that order), flush the outbox briefly,
    /// stop the guard (after the thaw) and every service. Idempotent.
    /// The synchronous last resort (the app's quit watchdog, `applicationWillTerminate`): thaw from the journal,
    /// then clear a flag this process really set — never through the actor (it may be the thing that hangs).
    public nonisolated func terminateSynchronously() {
        TerminationSignals.terminate(pausing: services.pausing, power: services.power,
                                     logger: services.logger(.coordinator), context: "synchronous termination")
    }

    public func prepareForTermination() async {
        if isTerminated { return }
        lifecycle = .terminated
        logger.notice("preparing for termination")
        // Quitting because a shutdown is under way (loginwindow terminates apps): the phone should read "Shut down".
        let shuttingDown: Bool = if case .awaitingShutdown = windDown.progress { true } else { finalStatus?.final == .shutDown }
        mainLoopTask?.cancel()
        mainLoopTask = nil
        // Quitting while a polite shutdown is pending is how loginwindow shuts down: if another app (Terminal's
        // "terminate running processes?") aborts it, nothing of Kakureneko is left to run the 3 min sleep fallback.
        // Hand the rest of it to a detached helper that outlives this process (it dies with the session when the
        // shutdown goes through, and sleeps only if the lid is still closed).
        if case .awaitingShutdown = windDown.progress {
            let now = services.clock.now()
            let elapsed = windDown.shutdownRequestedAt.map { now.timeIntervalSince($0) } ?? 0
            let remaining = max(CoordinatorTiming.detachedSleepMinimumDelay,
                                CoordinatorTiming.shutdownFallback.timeInterval - elapsed)
            do {
                try services.power.scheduleDetachedSleep(after: .seconds(remaining))
                logger.notice("shutdown pending at quit: sleep fallback handed off (\(Int(remaining)) s)")
            } catch {
                logger.error("could not hand off the sleep fallback: \(error)")
            }
        }
        cancelWindDownTask()
        machine.forceDisarmed()
        keepAwakeUntil = nil

        await thaw(.appQuitting)
        if !(await disarmFlag(context: "termination")) {
            logger.error("disarm failed at termination; the root fail-safe clears the flag")
        }
        await reportFinalStatus(shuttingDown ? .shutDown : .quit, untilWake: true)
        let deadline = services.clock.now().addingTimeInterval(CoordinatorTiming.terminationDrainSeconds)
        _ = await services.notifications.drain(deadline: deadline)
        services.pausing.stopGuard()

        await services.events.stop()
        await services.claudeState.stop()
        await services.processes.stop()
        await services.powerEvents.stop()
        await services.notifications.stop()
        for task in consumerTasks { task.cancel() }
        consumerTasks = []
        publishIfChanged(force: true)
    }
}
