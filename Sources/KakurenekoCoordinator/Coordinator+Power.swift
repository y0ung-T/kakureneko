// Executing the state machine's actions, the ONE wind-down task (ARCHITECTURE §9.8 "WindingDown", brief §7.3/
// §7.5), power events, remote commands (brief §8.3) and settings application (incl. the dry-run toggle, §6).
//
// Every flag / power mutation (arm, disarm, sleep, shutdown) runs under the FIFO power lock, so an `arm` decided
// after a cancelled wind-down can never interleave with that wind-down's in-flight `disarm`, and the order of
// execution is the order of the decisions.

import KakurenekoKit
import Foundation

extension KakurenekoCoordinator {
    // MARK: Locks

    /// FIFO: a waiter is handed the lock directly by `release` (no barging).
    func acquire(_ lock: CoordinatorLock) async {
        guard locks[lock].held else {
            locks[lock].held = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            locks[lock].waiters.append(continuation)
        }
    }

    func release(_ lock: CoordinatorLock) {
        if locks[lock].waiters.isEmpty {
            locks[lock].held = false
        } else {
            locks[lock].waiters.removeFirst().resume()
        }
    }

    func acquirePowerLock() async { await acquire(.power) }
    func releasePowerLock() { release(.power) }

    /// `power.disarm()` under the lock. Returns false (and marks the failure) when it threw.
    func disarmFlag(context: String) async -> Bool {
        await acquirePowerLock()
        defer { releasePowerLock() }
        return await disarmHoldingLock(context: context)
    }

    func disarmHoldingLock(context: String) async -> Bool {
        do {
            try await services.power.disarm()
            disarmFailed = false
            return true
        } catch {
            logger.error("disarm (\(context)) failed: \(error)")
            disarmFailed = true
            heartbeatSuppressed = true
            return false
        }
    }

    /// After a failed disarm: the heartbeat stays stopped (the root fail-safe clears the flag within 150 + 60 s)
    /// and the phone is told.
    func reportDisarmFailure() async {
        disarmFailed = true
        heartbeatSuppressed = true
        await submit(.warning(
            title: "Kakureneko could not re-enable sleep",
            body: "Clearing the sleep flag failed. The root fail-safe clears it within about 4 minutes."))
    }

    // MARK: Actions

    /// Executes the machine's actions in order.
    func execute(_ actions: [PowerAction]) async {
        for action in actions {
            switch action {
            case .arm:
                await performArm()
            case .disarm(let cause):
                await performDisarm(cause)
            case .lidClosedAwake:
                await performLidClosedAwake()
            case .lidOpened(let reason):
                await thaw(reason)
            case .countdownStarted(let endsAt, let reason, let stateVersion):
                await submitCountdown(endsAt: endsAt, reason: reason, stateVersion: stateVersion)
            case .countdownCancelled:
                logger.notice("countdown cancelled")
            case .shutdownPending(let at, let fromPhone):
                logger.notice("shutdown grace until \(KakurenekoJSON.iso8601String(from: at)) (\(fromPhone ? "phone" : "end action"))")
                await submit(.shuttingDown(at: at, requestedFromPhone: fromPhone))
            case .shutdownCancelled(let stale):
                logger.notice("shutdown grace cancelled\(stale ? ": an agent is busy again" : "")")
                if stale {
                    await submit(.commandIgnored(reason: NotificationRouting.busyAgainReason(sessions: services.sessions.sessions)))
                }
            case .safetyTripped(let trip):
                await submit(.safetyTrip(trip, runningAgents: services.sessions.aggregate.workingCount))
            case .windDown(let reason, let shutdown):
                // Decided before an await (the trip push); a lid-open / keep-awake / Cancel meanwhile ended it.
                guard machine.isWindingDown else {
                    logger.notice("wind-down (\(reason)) cancelled before it started")
                    continue
                }
                startWindDown(reason: reason, shutdown: shutdown)
            case .cancelWindDown:
                abandonWindDown()
            case .armingBlocked(let trip):
                if armingBlocked != trip { logger.notice("arming blocked: \(trip.userReason)") }
                armingBlocked = trip
            }
        }
    }

    func performArm() async {
        await acquirePowerLock()
        guard machine.phase.isArmed else {
            // Superseded while waiting for the lock (e.g. a wind-down began).
            releasePowerLock()
            return
        }
        var failure: (any Error)?
        do {
            try await services.power.arm()
        } catch {
            failure = error
        }
        releasePowerLock()
        let now = services.clock.now()
        if let failure {
            logger.error("arm failed: \(failure)")
            machine.armFailed()
            armBackoffUntil = now.addingTimeInterval(CoordinatorTiming.armRetryBackoff)
            // Usually the sudoers rule went missing: re-check so the mode reflects it.
            applyPrivilegedStatus(await services.privileged.healthCheck())
            return
        }
        logger.notice("armed (\(machine.phase.label))")
        armBackoffUntil = nil
        heartbeatSuppressed = false
        disarmFailed = false
        armingBlocked = nil
        touchHeartbeat(now: now)
    }

    func performDisarm(_ cause: DisarmCause) async {
        await acquirePowerLock()
        guard !machine.phase.isArmed else {
            // Re-armed while waiting: the queued arm decides.
            releasePowerLock()
            return
        }
        let ok = await disarmHoldingLock(context: "\(cause)")
        releasePowerLock()
        services.safety.reset()
        if ok {
            logger.notice("disarmed (\(cause))")
        } else {
            await reportDisarmFailure()
        }
    }

    /// Armed → ClosedAwake: panel off (no external display, setting on), chime (on battery unless set otherwise).
    func performLidClosedAwake() async {
        if settings.power.displaySleepOnLidClose, !externalDisplayConnected {
            do {
                try await services.power.displaySleepNow()
            } catch {
                logger.error("display sleep failed: \(error)")
            }
        }
        if settings.power.lidCloseSound.plays(onBattery: latestPower?.onBattery == true) {
            services.power.playLidCloseChime()
        }
        logger.notice("lid closed while armed: holding the Mac awake")
    }

    /// The countdown push, unless the countdown it announces is already over: it is executed after the session
    /// pushes of the same step were awaited, and an input handled meanwhile (another agent started a turn, the lid
    /// opened, keep-awake) may have cancelled it. Its buttons carry the decision-time `sv`.
    func submitCountdown(endsAt: Date, reason: CountdownReason, stateVersion: Int) async {
        guard case .countdown(let currentEndsAt, _, _) = machine.phase, currentEndsAt == endsAt else {
            logger.notice("countdown (\(reason.rawValue)) ended before its push went out; not sent")
            return
        }
        let sessions = services.sessions.sessions
        let waiting = sessions.filter { $0.state.isWaiting }
        let offerShutdown = settings.power.shutdownEnabled && waiting.isEmpty
        logger.notice("countdown (\(reason.rawValue)) until \(KakurenekoJSON.iso8601String(from: endsAt))")
        await submit(.countdown(endsAt: endsAt, reason: reason, finished: turnEndsSinceLidClosed,
                                waiting: waiting, offerShutdown: offerShutdown), stateVersion: stateVersion)
    }

    // MARK: Wind-down

    func startWindDown(reason: WindDownReason, shutdown: Bool) {
        windDown.generation &+= 1
        let generation = windDown.generation
        windDown.task?.cancel()
        windDown.progress = .running(disarmed: false)
        windDown.sleepConfirmed = false
        windDown.pendingSleepRecord = nil
        logger.notice("winding down (\(reason))\(shutdown ? " → shutdown" : "")")
        windDown.task = Task { [weak self] in
            await self?.runWindDown(generation: generation, reason: reason, shutdown: shutdown)
        }
    }

    func cancelWindDownTask() {
        windDown.generation &+= 1
        windDown.task?.cancel()
        windDown.task = nil
        windDown.progress = .none
        windDown.pendingSleepRecord = nil
        windDown.shutdownRequestedAt = nil
    }

    /// Still the current wind-down and nothing cancelled it (re-checked after EVERY await).
    func windDownIsCurrent(_ generation: UInt64) -> Bool {
        generation == windDown.generation && machine.isWindingDown && !Task.isCancelled
    }

    /// drain → thaw → 3 s → disarm → [resume.json → shutdown → 3 min] → sleep → wait for `willSleep`.
    func runWindDown(generation: UInt64, reason: WindDownReason, shutdown: Bool) async {
        let clock = services.clock
        await reportFinalStatus(shutdown ? .shutDown : .asleep, untilWake: false)
        _ = await services.notifications.drain(deadline: clock.now().addingTimeInterval(CoordinatorTiming.windDownDrainSeconds))
        guard windDownIsCurrent(generation) else { return }
        await thaw(.beforePowerAction)
        guard windDownIsCurrent(generation) else { return }
        do {
            try await clock.sleep(for: CoordinatorTiming.thawSettle)
        } catch {
            return
        }
        guard windDownIsCurrent(generation) else { return }

        // Disarm. Progress says "disarmed" BEFORE the await, so a cancel during the call returns to Disarmed (and a
        // re-arm queues behind this disarm on the lock). Still cancellable until `requestShutdown`/`sleepNow`.
        await acquirePowerLock()
        guard windDownIsCurrent(generation) else {
            releasePowerLock()
            return
        }
        windDown.progress = .running(disarmed: true)
        let disarmed = await disarmHoldingLock(context: "wind-down")
        releasePowerLock()
        services.safety.reset()
        if !disarmed { await reportDisarmFailure() }
        guard windDownIsCurrent(generation) else { return }
        publishIfChanged()

        // Brief §7.5: shutdown only when opted in and nobody waits for input; otherwise sleep.
        let doShutdown = shutdown && settings.power.shutdownEnabled && !services.sessions.aggregate.anyWaiting
        // Reported as "Mac slept …" after the wake; recorded only once the request is really out.
        var record = SleepRecord(startedAt: clock.now(), reason: reason, batteryPercentAtStart: latestPower?.batteryPercent,
                                 endAction: doShutdown ? .shutdown : .sleep)

        if doShutdown {
            await acquirePowerLock()
            guard windDownIsCurrent(generation) else {
                releasePowerLock()
                return
            }
            do {
                try ResumeManifest.write(ResumeManifest.entries(from: services.sessions.sessions), to: services.paths.resumeManifestFile)
                windDown.resumeManifestWritten = true
                resumeManifestDiscardAt = nil
            } catch {
                logger.error("could not write resume.json: \(error)")
            }
            windDown.progress = .awaitingShutdown
            windDown.shutdownRequestedAt = clock.now()
            // A keep-awake override must not outlive the shutdown/sleep it could no longer stop.
            keepAwakeUntil = nil
            record.startedAt = clock.now()
            windDown.pendingSleepRecord = record
            var requested = false
            do {
                try await services.power.requestShutdown()
                requested = true
            } catch {
                logger.error("shutdown request failed: \(error); sleeping instead")
            }
            releasePowerLock()
            if requested {
                do {
                    try await clock.sleep(for: CoordinatorTiming.shutdownFallback)
                } catch {
                    return
                }
                guard generation == windDown.generation, !Task.isCancelled else { return }
                logger.notice("still running 3 min after the shutdown request (blocked?): sleeping instead")
            } else {
                guard generation == windDown.generation, !Task.isCancelled else { return }
            }
            record.endAction = .sleep
        }

        await acquirePowerLock()
        guard windDownIsCurrent(generation) else {
            releasePowerLock()
            return
        }
        // From here on nothing cancels: the sleep request is out. A keep-awake override set earlier must not survive
        // the sleep (it would re-arm on the next dark wake once the re-arm latch is released).
        windDown.progress = .committed
        keepAwakeUntil = nil
        record.startedAt = clock.now()
        windDown.pendingSleepRecord = record
        var sleepError: (any Error)?
        do {
            try await services.power.sleepNow()
        } catch {
            sleepError = error
        }
        releasePowerLock()
        if let sleepError {
            logger.error("sleep failed: \(sleepError)")
            await sleepDidNotHappen(generation: generation)
            return
        }
        publishIfChanged()

        // The sleep is asynchronous: if `willSleep` never comes (dark-wake cancel, a vetoing assertion on AC),
        // go back to Disarmed and retry later while the lid stays closed.
        do {
            try await clock.sleep(for: CoordinatorTiming.sleepConfirmation)
        } catch {
            return
        }
        guard generation == windDown.generation, !windDown.sleepConfirmed else { return }
        logger.notice("no sleep within \(CoordinatorTiming.sleepConfirmation) of sleepNow()")
        await sleepDidNotHappen(generation: generation)
    }

    func sleepDidNotHappen(generation: UInt64) async {
        guard generation == windDown.generation else { return }
        windDown.generation &+= 1
        windDown.task = nil
        windDown.progress = .none
        windDown.pendingSleepRecord = nil
        discardResumeManifestOfThisWindDown()
        machine.sleepDidNotHappen(now: services.clock.now())
        await process([])
    }

    /// A user-driven cancellation (lid open, keep-awake, Cancel, Kakureneko off, uninstall): the task stops and a
    /// `resume.json` it wrote goes away — the Mac did not shut down, the sessions are still there. (Termination
    /// keeps it: quitting is how a real shutdown reaches the app.)
    func abandonWindDown() {
        let requestOut = windDown.progress == .awaitingShutdown
        let requestedAt = windDown.shutdownRequestedAt
        cancelWindDownTask()
        if requestOut, windDown.resumeManifestWritten {
            // The shutdown request cannot be recalled: loginwindow may still complete it (a dialog answered later,
            // or the request already being processed). Keep resume.json for the next launch; it goes away once the
            // fallback window has passed with Kakureneko still running, or after a wake (the Mac only slept), and a
            // launch in the same boot never offers it.
            windDown.resumeManifestWritten = false
            resumeManifestDiscardAt = (requestedAt ?? services.clock.now())
                .addingTimeInterval(CoordinatorTiming.shutdownFallback.timeInterval)
            logger.info("shutdown cancelled after the request went out: resume.json kept for now")
            return
        }
        discardResumeManifestOfThisWindDown()
    }

    /// Deletes a kept `resume.json` once its shutdown evidently did not happen (Kakureneko still running, or awake
    /// after a sleep).
    func discardKeptResumeManifestIfDue(now: Date, force: Bool = false) {
        guard let at = resumeManifestDiscardAt, force || now >= at else { return }
        resumeManifestDiscardAt = nil
        ResumeManifest.delete(at: services.paths.resumeManifestFile)
        logger.info("the cancelled shutdown did not happen: resume.json removed")
    }

    func discardResumeManifestOfThisWindDown() {
        guard windDown.resumeManifestWritten else { return }
        windDown.resumeManifestWritten = false
        ResumeManifest.delete(at: services.paths.resumeManifestFile)
        logger.info("shutdown abandoned: resume.json removed")
    }

    // MARK: Requests (menu / phone)

    func requestSleep(_ reason: WindDownReason) async {
        let actions = machine.requestSleep(reason, currentInputs())
        await execute(actions)
        publishIfChanged()
    }

    /// Keep-awake override (menu or phone): cancels a countdown, a shutdown grace and a wind-down not yet at
    /// `sleepNow` / the shutdown fallback.
    func requestKeepAwake(until: Date) async {
        keepAwakeUntil = until
        logger.notice("keep awake until \(until.ISO8601Format())")
        let actions = machine.keepAwakeRequested(currentInputs())
        await execute(actions)
        await process([])
    }

    // MARK: Inputs from streams

    func handleAgentEvent(_ event: AgentEvent) async {
        defer { handled.agentEvents += 1 }
        let integration = AgentID(label: event.argvAgentLabel)
        lastEventSeen[integration] = max(lastEventSeen[integration] ?? event.receivedAt, event.receivedAt)
        let effects = services.sessions.ingest(event, now: services.clock.now())
        await process(effects)
    }

    func handleClaudeSnapshot(_ snapshot: ClaudeStateSnapshot) async {
        defer { handled.claudeSnapshots += 1 }
        let effects = services.sessions.ingest(claudeState: snapshot, now: services.clock.now())
        await process(effects)
    }

    func handlePowerEvent(_ event: PowerEvent) async {
        defer { handled.powerEvents += 1 }
        switch event {
        case .lidChanged(let state):
            lid = state
            await process([])
        case .externalDisplayChanged(let connected):
            externalDisplayConnected = connected
            await process([])
        case .snapshot(let snapshot):
            absorb(snapshot)
            if pause.active, let idle = snapshot.secondsSinceUserInput, idle < CoordinatorTiming.userInputThawSeconds {
                await thaw(.userInput)
            }
            await process([])
        case .userActivity(let seconds):
            let at = services.clock.now().addingTimeInterval(-max(0, seconds))
            lastUserInputAt = max(lastUserInputAt ?? at, at)
            await thaw(.userInput)
            await process([])
        case .willSleep(let acknowledger):
            await handleWillSleep(acknowledger)
        case .didWake:
            await handleDidWake()
        case .willPowerOff:
            await thaw(.willPowerOff)
            publishIfChanged()
        case .sessionResignedActive:
            await thaw(.sessionResignedActive)
            publishIfChanged()
        case .sessionBecameActive:
            logger.info("user session active again")
        }
    }

    /// Takes a power snapshot as the latest truth (lid, display, input, flags).
    func absorb(_ snapshot: PowerSnapshot) {
        latestPower = snapshot
        if snapshot.lid != .unknown { lid = snapshot.lid }
        externalDisplayConnected = snapshot.externalDisplayConnected
        if let idle = snapshot.secondsSinceUserInput {
            lastUserInputAt = snapshot.takenAt.addingTimeInterval(-max(0, idle))
        }
        safetyEvaluationDue = true
        if let real = snapshot.kernelSleepDisabled {
            kernelSleepDisabledInDryRun = services.dryRun.isOn && real
        }
    }

    /// `kIOMessageSystemWillSleep`: thaw, flush the outbox ≤ 5 s, then allow the sleep (always).
    func handleWillSleep(_ acknowledger: PowerChangeAcknowledger) async {
        if machine.isWindingDown { windDown.sleepConfirmed = true }
        await thaw(.willSleep)
        await reportFinalStatus(.asleep, untilWake: true)
        let deadline = services.clock.now().addingTimeInterval(CoordinatorTiming.willSleepFlushSeconds)
        _ = await services.notifications.drain(deadline: deadline)
        acknowledger.allow()
        publishIfChanged()
    }

    /// Wake: Disarmed, report the sleep Kakureneko initiated, kick the outbox.
    func handleDidWake() async {
        let kernelArmed = services.power.kernelFlags().sleepDisabled
        let record = windDown.pendingSleepRecord
        let manifestWritten = windDown.resumeManifestWritten
        cancelWindDownTask()
        windDown.pendingSleepRecord = nil
        windDown.resumeManifestWritten = false
        windDown.sleepConfirmed = false
        finalStatus = nil // awake again: report what the Mac does now
        machine.didWake(kernelArmed: kernelArmed)
        logger.notice("woke up (\(machine.phase.label))")
        let fresh = await services.power.snapshot()
        absorb(fresh)
        if var record {
            record.endedAt = services.clock.now()
            lastSleep = record
            // The Mac only slept: the sessions are still alive, there is nothing to reopen.
            if manifestWritten { ResumeManifest.delete(at: services.paths.resumeManifestFile) }
            await submit(.asleep(record, batteryPercent: fresh.batteryPercent ?? record.batteryPercentAtStart))
        }
        // A resume.json kept after a cancelled shutdown: the Mac slept, so that shutdown did not happen.
        discardKeptResumeManifestIfDue(now: services.clock.now(), force: true)
        _ = await services.notifications.drain(deadline: services.clock.now().addingTimeInterval(CoordinatorTiming.wakeDrainSeconds))
        await process([])
    }

    // MARK: Remote commands

    /// Validated commands (right Mac, expiry, replay checked by Notify) from a Mac notification button or the
    /// iPhone; the `sv` check is ours.
    func handleRemoteCommand(_ command: RemoteCommand) async {
        defer { handled.remoteCommands += 1 }
        let aggregate = services.sessions.aggregate
        let sv = command.stateVersion.map(String.init) ?? "none"
        logger.notice("command \(command.kind.label) from \(command.source.label) (sv \(sv), current \(aggregate.stateVersion))")
        switch command.kind {
        case .keepAwake(let seconds):
            await requestKeepAwake(until: services.clock.now().addingTimeInterval(TimeInterval(seconds)))
        case .sleep:
            guard settings.general.enabled else { return await ignoreWhileOff() }
            guard command.stateVersion == aggregate.stateVersion else {
                return await submit(.commandIgnored(reason: NotificationRouting.busyAgainReason(sessions: services.sessions.sessions)))
            }
            await requestSleep(.remoteSleep)
        case .shutdown:
            guard settings.general.enabled else { return await ignoreWhileOff() }
            guard settings.power.shutdownEnabled else {
                return await submit(.commandIgnored(reason: "Shut down is turned off in Kakureneko's settings"))
            }
            guard command.stateVersion == aggregate.stateVersion else {
                return await submit(.commandIgnored(reason: NotificationRouting.busyAgainReason(sessions: services.sessions.sessions)))
            }
            let actions = machine.requestShutdown(fromPhone: command.source.isPhone, currentInputs())
            await execute(actions)
            publishIfChanged()
        }
    }

    /// Sleep / shut down while Kakureneko is switched off: not run, and the iPhone is told why.
    private func ignoreWhileOff() async {
        logger.notice("ignored: Kakureneko is off")
        await submit(.commandIgnored(reason: "Kakureneko is turned off on this Mac"))
    }

    // MARK: Privileged status and mode

    /// Stores the health check; in dry-run a missing install is simulated so every decision stays visible.
    func applyPrivilegedStatus(_ raw: PrivilegedStatus) {
        rawPrivileged = raw
        if !raw.isOperational, services.dryRun.isOn {
            privileged = PrivilegedStatus.simulatedForDryRun(at: services.clock.now())
        } else {
            privileged = raw
        }
        recomputeMode()
    }

    func recomputeMode() {
        guard privilegedChecked else { return }
        let next: OperatingMode = !settings.general.enabled ? .disabled : (privileged.isOperational ? .full : .notificationsOnly)
        if next != mode { logger.notice("mode \(mode.rawValue) → \(next.rawValue)") }
        mode = next
    }

    // MARK: Settings

    /// Normalize, persist, apply. A change of the effective dry-run first thaws and disarms UNDER THE OLD GATE
    /// (§6: undo always runs with the gate value that was used to act), then flips the gate, then re-steps.
    /// Serialized: concurrent updates apply in call order.
    func applySettings(_ proposed: KakurenekoSettings) async {
        await acquire(.settings)
        defer { release(.settings) }
        let next = proposed.normalized()
        let previous = settings
        let gate = services.dryRun
        let gateWillBeOn = gate.isForcedByEnvironment || next.general.dryRun
        let gateFlips = gateWillBeOn != gate.isOn
        let disabling = previous.general.enabled && !next.general.enabled

        let undo = gateFlips || disabling
        if undo {
            // While the undo awaits, other inputs run (actor re-entrancy): they must not arm or pause again
            // under the old gate. Notifications are still routed.
            decisionSuspensions += 1
            abandonWindDown()
            machine.forceDisarmed()
            await thaw(.pausingDisabled)
            if !(await disarmFlag(context: gateFlips ? "dry-run toggle" : "Kakureneko turned off")) {
                await reportDisarmFailure()
            }
            // A sleep request that arrived meanwhile started a wind-down under the old state: drop it.
            abandonWindDown()
            machine.forceDisarmed()
        }

        settings = next
        do {
            try next.save(to: services.paths.settingsFile)
        } catch {
            logger.error("could not save settings: \(error)")
        }
        gate.setRequested(next.general.dryRun)
        if gateFlips {
            logger.notice("dry-run \(gate.isOn ? "on" : "off")")
            if privilegedChecked {
                // At once (no await): with the gate off a simulated `.full` must never be stepped — a tick in the
                // await below would arm FOR REAL on a status the real install does not have. Decisions stay
                // suspended until the fresh health check is applied.
                applyPrivilegedStatus(rawPrivileged)
                applyPrivilegedStatus(await services.privileged.healthCheck())
            }
            kernelSleepDisabledInDryRun = gate.isOn && services.power.kernelFlags().kernelSleepDisabled == true
        }
        if undo { decisionSuspensions -= 1 }

        if previous.timers != next.timers { services.sessions.updateTimers(next.timers) }
        // Kakureneko off = Notify off too (its reminder timer, batch, digest and queue would keep pushing otherwise);
        // the test message still works. Back on → the real notification settings again.
        let effectiveNotifications = NotificationRouting.effectiveNotificationSettings(next)
        if NotificationRouting.effectiveNotificationSettings(previous) != effectiveNotifications {
            await services.notifications.applySettings(effectiveNotifications)
        }
        if previous.general.enabled != next.general.enabled {
            logger.notice("Kakureneko turned \(next.general.enabled ? "on" : "off")")
            recomputeMode()
        }
        if previous.pausing.enabled, !next.pausing.enabled, !disabling, !gateFlips {
            await thaw(.pausingDisabled)
        }
        await process([])
    }
}
