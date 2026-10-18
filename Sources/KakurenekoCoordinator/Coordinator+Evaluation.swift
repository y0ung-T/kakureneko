// The main loop and the central re-evaluation (ARCHITECTURE §9.8 "Main loop", "Predicates", "Notification
// routing", "Pausing", "Snapshot"). Every input — a stream element, a tick, a user action — ends in `process()`.

import KakurenekoCloud
import KakurenekoKit
import Foundation

extension KakurenekoCoordinator {
    // MARK: Tick

    /// One main-loop iteration at `clock.now()`: process scan (5 s closed / 15 s open) → session timers → route →
    /// step → act; then pausing, heartbeat, cadence/hints, notification status, conflicting apps, integration
    /// statuses (every 10 min), snapshot flush.
    func tick() async {
        guard isRunning else { return }
        handled.ticks += 1
        let clock = services.clock
        var now = clock.now()
        if let until = keepAwakeUntil, until <= now {
            keepAwakeUntil = nil
            logger.info("keep-awake override expired")
        }
        discardKeptResumeManifestIfDue(now: now)

        var effects: [SessionEffect] = []
        if nextScanAt.map({ now >= $0 }) ?? true {
            effects += await scanProcesses(now: now)
            now = clock.now()
        }
        effects += services.sessions.tick(now: now)
        await refreshStaleSnapshotForSafety(now: now)
        await process(effects)

        now = clock.now()
        await updatePausing(now: now)
        touchHeartbeatIfDue(now: clock.now())
        await updateCadenceAndHints()
        await refreshNotificationStatus()
        if lastConflictingAppCheckAt.map({ clock.now().timeIntervalSince($0) >= CoordinatorTiming.conflictingAppCheckInterval }) ?? true {
            checkConflictingApps(now: clock.now())
        }
        if lastIntegrationRefreshAt.map({ clock.now().timeIntervalSince($0) >= CoordinatorTiming.integrationRefreshInterval }) ?? true {
            await refreshIntegrations()
        }
        publishIfChanged(force: true)
    }

    /// T3 scan → sessions, CPU watchdog, `pausing.observe` (lid closed only).
    func scanProcesses(now: Date) async -> [SessionEffect] {
        let snapshot = await services.processes.sample(now: now)
        let after = services.clock.now()
        latestProcessSnapshot = snapshot
        watchdog.observe(snapshot, now: after)
        let effects = services.sessions.ingest(processes: snapshot, now: after)
        if effectiveLidClosed { await services.pausing.observe(now: after) }
        nextScanAt = after.addingTimeInterval(currentCadence.processScanInterval.timeInterval)
        return effects
    }

    var currentCadence: SamplingCadence { effectiveLidClosed ? .lidClosed : .lidOpen }

    /// Backup for the 15 s SafetyMonitor cadence when the power monitor's periodic snapshots stop arriving.
    func refreshStaleSnapshotForSafety(now: Date) async {
        guard effectiveLidClosed || lid == .closed, machine.phase.isArmed else { return }
        if let latest = latestPower, now.timeIntervalSince(latest.takenAt) < CoordinatorTiming.staleSnapshotAge { return }
        absorb(await services.power.snapshot())
    }

    // MARK: Process

    /// Routes `effects`, steps the power state machine, executes its actions, handles presence, publishes.
    func process(_ effects: [SessionEffect]) async {
        guard !isTerminated else { return }
        let now = services.clock.now()
        noteEffectiveLidState(now: now)
        notePhysicalLidState(now: now)
        if effectiveLidClosed {
            turnEndsSinceLidClosed.append(contentsOf: effects.filter { $0.kind == .finished || $0.kind == .wentQuiet })
        }
        for effect in effects {
            logger.info("session \(effect.session.key) → \(effect.kind.rawValue)\(effect.outcome.map { " (\($0.rawValue))" } ?? "")")
        }

        let sessions = services.sessions.sessions
        let aggregate = services.sessions.aggregate
        let nowWaiting = Set(sessions.filter { $0.state.isWaiting }.map(\.key))
        let resolved = NotificationRouting.resolvedKeys(previouslyWaiting: waitingKeys, nowWaiting: nowWaiting)
        waitingKeys = nowWaiting

        let trip = evaluateSafetyIfDue(now: now)
        let inputs = makeInputs(now: now, sessions: sessions, aggregate: aggregate, safetyTrip: trip)
        let before = machine.phase
        // While an undo runs under the old state nothing is decided; the machine catches up (edges included:
        // it compares against its own last-seen lid state) on the first step afterwards.
        let actions = decisionsSuspended ? [] : machine.step(inputs)
        if machine.phase != before { logger.notice("power: \(before.label) → \(machine.phase.label)") }
        if inputs.armingBlocker == nil || !inputs.shouldStayArmed { armingBlocked = nil }

        // Session pushes first: a countdown submitted after them absorbs the finishes of the same batch.
        let sleepsAt: Date? = if case .countdown(let endsAt, _, _) = machine.phase { endsAt } else { nil }
        for effect in effects {
            let awake = NotificationRouting.awakeUntil(
                waitingSince: NotificationRouting.waitingSince(effect), timers: settings.timers,
                keepAwakeUntil: keepAwakeUntil, canKeepAwake: armingAllowed)
            if let intent = NotificationRouting.intent(for: effect, workingCount: aggregate.workingCount, awakeUntil: awake, sleepsAt: sleepsAt) {
                await submit(intent)
            }
        }
        for key in resolved { await submit(.resolved(key)) }

        await execute(actions)
        await handlePresenceTransition()
        publishIfChanged()
    }

    /// Effective lid edges (lid, or an external display while closed): reset the per-closed-period bookkeeping.
    func noteEffectiveLidState(now: Date) {
        let closed = PowerPredicates.effectiveLidClosed(lid: lid, externalDisplayConnected: externalDisplayConnected)
        guard closed != effectiveLidClosed else { return }
        effectiveLidClosed = closed
        services.safety.reset()
        lastSafetyEvaluationAt = nil
        safetyEvaluationDue = closed
        turnEndsSinceLidClosed = []
        pause.suppressedUntilLidEdge = false
        pause.nextRecheckAt = nil
        hotspotAtLidClose = closed && latestPower?.networkExpensive == true
        nextScanAt = now
        logger.notice("effective lid \(closed ? "closed" : "open") (lid \(lid.rawValue), external display \(externalDisplayConnected))")
    }

    /// Physical lid edges while a display keeps the lid effectively open (a dummy/virtual, AirPlay or Sidecar display
    /// counts as "external"): the closed-lid guards run on the physical period, so it has its own start and resets.
    func notePhysicalLidState(now: Date) {
        let closed = lid == .closed
        guard closed != (physicalLidClosedSince != nil) else { return }
        physicalLidClosedSince = closed ? now : nil
        if !effectiveLidClosed {
            services.safety.reset()
            lastSafetyEvaluationAt = nil
            safetyEvaluationDue = closed
        }
    }

    /// The SafetyMonitor runs while the lid is closed and the Mac held awake: on every new snapshot and at least
    /// every 15 s. (fix) Also while the PHYSICAL lid is closed and a display keeps it effectively open: a virtual or
    /// AirPlay display in a bag must not switch off the 12 h cap, the network and the sustained-thermal guards (the
    /// machine acts on such a trip only while nobody uses the Mac).
    func evaluateSafetyIfDue(now: Date) -> SafetyTrip? {
        guard effectiveLidClosed || lid == .closed, machine.phase.isArmed, let snapshot = latestPower else { return nil }
        let cadenceDue = lastSafetyEvaluationAt.map { now.timeIntervalSince($0) >= CoordinatorTiming.safetyInterval } ?? true
        guard safetyEvaluationDue || cadenceDue else { return nil }
        safetyEvaluationDue = false
        lastSafetyEvaluationAt = now
        let closedSince = effectiveLidClosed ? (machine.closedSince ?? now) : (physicalLidClosedSince ?? now)
        let trip = services.safety.evaluate(snapshot, closedSince: closedSince, settings: settings.safety, now: now)
        if let trip { logger.notice("safety trip: \(trip.userReason)") }
        return trip
    }

    // MARK: Inputs and predicates

    /// Closed-lid mode is possible: `.full` (real or simulated privileged), master switch on, setting on.
    var armingAllowed: Bool {
        mode == .full && settings.general.enabled && settings.power.keepAwakeWithLidClosed
    }

    func secondsSinceUserInput(now: Date) -> TimeInterval? {
        lastUserInputAt.map { max(0, now.timeIntervalSince($0)) }
    }

    func userPresent(now: Date) -> Bool {
        PowerPredicates.userPresent(secondsSinceUserInput: secondsSinceUserInput(now: now),
                                    awayIdleSeconds: settings.notifications.awayIdleSeconds,
                                    effectiveLidClosed: effectiveLidClosed)
    }

    func currentPresence(now: Date) -> Presence {
        NotificationRouting.presence(effectiveLidClosed: effectiveLidClosed, screenLocked: latestPower?.screenLocked,
                                     secondsSinceUserInput: secondsSinceUserInput(now: now),
                                     hasLid: latestPower?.lid != .noLid)
    }

    func shouldStayArmed(now: Date, sessions: [AgentSession], aggregate: SessionAggregate) -> Bool {
        PowerPredicates.shouldStayArmed(
            anyWorking: aggregate.anyWorking,
            waitingGraceActive: PowerPredicates.waitingGraceActive(sessions: sessions, timers: settings.timers, now: now),
            keepAwakeUntil: keepAwakeUntil, now: now)
    }

    func makeInputs(now: Date, sessions: [AgentSession], aggregate: SessionAggregate, safetyTrip: SafetyTrip?) -> PowerInputs {
        let timers = settings.timers
        let blocker = latestPower.flatMap { services.safety.armingBlocker($0, settings: settings.safety) }
        return PowerInputs(
            now: now,
            lid: lid,
            externalDisplayConnected: externalDisplayConnected,
            anyWorking: aggregate.anyWorking,
            anyWaiting: aggregate.anyWaiting,
            waitingGraceActive: PowerPredicates.waitingGraceActive(sessions: sessions, timers: timers, now: now),
            keepAwakeUntil: keepAwakeUntil,
            userPresent: userPresent(now: now),
            armingAllowed: armingAllowed,
            armBackoff: armBackoffUntil.map { $0 > now } ?? false,
            armingBlocker: blocker,
            safetyTrip: safetyTrip,
            timers: timers,
            countdownReason: PowerPredicates.countdownReason(anyWaiting: aggregate.anyWaiting,
                                                             endedTurnsSinceLidClosed: turnEndsSinceLidClosed),
            endAction: settings.power.endAction,
            stateVersion: aggregate.stateVersion,
            windDown: windDown.progress
        )
    }

    /// Inputs at `now` without a safety evaluation (requests from the menu or the phone).
    func currentInputs() -> PowerInputs {
        makeInputs(now: services.clock.now(), sessions: services.sessions.sessions,
                   aggregate: services.sessions.aggregate, safetyTrip: nil)
    }

    // MARK: Notifications

    /// Policy-gated push (Notify decides presence, batching, dedupe). Nothing is pushed while Kakureneko is off —
    /// except `.resolved`, which never sends anything and cancels Notify's reminder for a wait that ended.
    /// - Parameter stateVersion: the `sv` the push's buttons are signed with (default: the current one).
    func submit(_ intent: NotificationIntent, stateVersion: Int? = nil) async {
        var isResolution = false
        if case .resolved = intent { isResolution = true }
        // Switched off, only answers go out: a resolution, and why a tapped button was not run.
        var isAnswer = false
        if case .commandIgnored = intent { isAnswer = true }
        guard settings.general.enabled || isResolution || isAnswer else { return }
        let now = services.clock.now()
        let context = NotificationContext(
            now: now,
            presence: currentPresence(now: now),
            stateVersion: stateVersion ?? services.sessions.aggregate.stateVersion,
            keepAwakeSeconds: settings.power.keepAwakeButtonSeconds
        )
        let disposition = await services.notifications.submit(intent, context: context)
        logger.debug("push \(intent.kind.rawValue): \(disposition)")
    }

    /// On every present → away transition and every lid close, re-submit `.needsInput` for every still-waiting
    /// session: what the iPhone's timing held back (`phoneTiming`) then reaches it; Notify dedupes the rest.
    func handlePresenceTransition() async {
        let now = services.clock.now()
        let presence = currentPresence(now: now)
        let away = presence.isAway(idleThreshold: TimeInterval(settings.notifications.awayIdleSeconds))
        let previous = wasAway
        let previousLid = wasLidClosed
        wasAway = away
        wasLidClosed = presence.lidClosed
        let becameAway = previous == false && away
        let lidJustClosed = previousLid == false && presence.lidClosed
        guard becameAway || lidJustClosed else { return }
        let waiting = services.sessions.sessions.compactMap(NotificationRouting.resubmittedNeedsInput(for:))
        guard !waiting.isEmpty else { return }
        logger.info("\(becameAway ? "present → away" : "lid closed"): re-submitting \(waiting.count) needs-input push(es)")
        for effect in waiting {
            let awake = NotificationRouting.awakeUntil(
                waitingSince: NotificationRouting.waitingSince(effect), timers: settings.timers,
                keepAwakeUntil: keepAwakeUntil, canKeepAwake: armingAllowed)
            await submit(.needsInput(effect, awakeUntil: awake))
        }
    }

    func refreshNotificationStatus() async {
        notificationStatus = await services.notifications.status()
        publishIfChanged()
    }

    // MARK: Pausing

    /// Pause / recheck / level-triggered thaws (brief §6.1, §6.3, §6.5.5).
    func updatePausing(now: Date) async {
        guard isRunning, !pause.inFlight, !decisionsSuspended else { return }
        let sessions = services.sessions.sessions
        let aggregate = services.sessions.aggregate
        let stayArmed = shouldStayArmed(now: now, sessions: sessions, aggregate: aggregate)
        let allowed = PausePolicy.pausingAllowed(mode: mode, kakurenekoEnabled: settings.general.enabled, settings: settings.pausing)

        if pause.active {
            if !allowed { return await thaw(.pausingDisabled) }
            if !effectiveLidClosed { return await thaw(.lidOpened) }
            if !stayArmed { return await thaw(.noAgentWorking) }
            if PausePolicy.hardCapReached(pausedSince: pause.startedAt, now: now, settings: settings.pausing) {
                pause.suppressedUntilLidEdge = true
                return await thaw(.hardCap)
            }
            let frozen = pause.pausedApps.filter { $0.mode == .freeze }
            if let frozenSince = frozen.map(\.pausedAt).min(),
               watchdog.tripped(workingSessions: sessions, frozenSince: frozenSince, now: now,
                                limit: TimeInterval(settings.pausing.watchdogMinutes) * 60) {
                logger.notice("watchdog: an agent claims working but its CPU has not advanced while apps are frozen")
                pause.suppressedUntilLidEdge = true
                return await thaw(.watchdog)
            }
            if !pause.pausedApps.isEmpty, pause.nextRecheckAt.map({ now >= $0 }) ?? true {
                await recheckPaused(now: now)
            }
            return
        }

        let gate = PausePolicy.Inputs(
            now: now,
            effectiveLidClosed: effectiveLidClosed,
            closedSince: machine.closedSince,
            secondsSinceUserInput: secondsSinceUserInput(now: now),
            shouldStayArmed: stayArmed,
            heldAwakeWithLidClosed: heldAwakeWithLidClosed,
            mode: mode,
            kakurenekoEnabled: settings.general.enabled,
            settings: settings.pausing
        )
        guard !pause.suppressedUntilLidEdge, PausePolicy.shouldPause(gate) else { return }
        await pauseApps(now: now)
    }

    /// ClosedAwake or Countdown with the lid effectively closed (never during a shutdown grace or a wind-down).
    var heldAwakeWithLidClosed: Bool {
        guard machine.effectiveLidClosed else { return false }
        switch machine.phase {
        case .closedAwake, .countdown: return true
        case .disarmed, .armed, .shutdownPending, .windingDown: return false
        }
    }

    func pauseApps(now: Date) async {
        pause.inFlight = true
        defer { pause.inFlight = false }
        let epoch = pause.epoch
        let snapshot = latestProcessSnapshot ?? .empty(at: now)
        let topology = PausePolicy.augment(await services.processes.topology(for: snapshot, now: now),
                                           with: services.sessions.sessions)
        guard epoch == pause.epoch, effectiveLidClosed, heldAwakeWithLidClosed, !decisionsSuspended else { return }
        await acquire(.pause)
        guard epoch == pause.epoch else {
            release(.pause)
            return
        }
        let report = await services.pausing.pause(topology: topology, settings: settings.pausing, now: now)
        release(.pause)
        // A thaw trigger that fired while `pause` ran bumped the epoch and is queued on the pause lock right
        // behind this call: it thaws what was just paused (under the same gate). Nothing to record.
        guard epoch == pause.epoch else { return }
        pause.active = true
        pause.startedAt = now
        pause.nextRecheckAt = services.clock.now().addingTimeInterval(TimeInterval(settings.pausing.recheckSeconds))
        pause.lastReport = report
        pause.pausedApps = report.paused
        logger.notice("paused: \(report.summary) (\(report.protected.count) protected, \(report.failures.count) failure(s))")
        publishIfChanged()
    }

    func recheckPaused(now: Date) async {
        pause.inFlight = true
        defer { pause.inFlight = false }
        let epoch = pause.epoch
        let snapshot = latestProcessSnapshot ?? .empty(at: now)
        let topology = PausePolicy.augment(await services.processes.topology(for: snapshot, now: now),
                                           with: services.sessions.sessions)
        guard epoch == pause.epoch else { return }
        await acquire(.pause)
        guard epoch == pause.epoch else {
            release(.pause)
            return
        }
        let report = await services.pausing.recheck(topology: topology, settings: settings.pausing, now: now)
        release(.pause)
        guard epoch == pause.epoch else { return }
        pause.lastReport = report
        pause.pausedApps = report.paused
        pause.nextRecheckAt = services.clock.now().addingTimeInterval(TimeInterval(settings.pausing.recheckSeconds))
        if !report.thawed.isEmpty { logger.notice("recheck thawed \(report.thawed.map(\.name))") }
        publishIfChanged()
    }

    /// Thaws everything (every trigger of brief §6.5.5 goes through here). Always calls `thawAll` — the journal,
    /// not our bookkeeping, is the truth about what is paused. Waits for an in-flight `pause`/`recheck`.
    func thaw(_ reason: ThawReason) async {
        pause.epoch &+= 1
        pause.active = false
        pause.startedAt = nil
        pause.nextRecheckAt = nil
        pause.lastThawReason = reason
        if reason == .userRequest, effectiveLidClosed { pause.suppressedUntilLidEdge = true }
        await acquire(.pause)
        let thawed = await services.pausing.thawAll(reason: reason)
        release(.pause)
        pause.pausedApps = []
        if thawed > 0 { logger.notice("thawed \(thawed) process(es): \(reason.rawValue)") }
    }

    // MARK: Heartbeat, cadence, hints, conflicting apps

    /// `touchHeartbeat()` every 15 s while armed (a no-op unless REALLY armed; stopped after a failed disarm).
    func touchHeartbeatIfDue(now: Date) {
        guard machine.phase.isArmed, !heartbeatSuppressed else { return }
        guard nextHeartbeatAt.map({ now >= $0 }) ?? true else { return }
        touchHeartbeat(now: now)
    }

    func touchHeartbeat(now: Date) {
        do {
            try services.power.touchHeartbeat()
        } catch {
            logger.error("heartbeat failed: \(error)")
        }
        nextHeartbeatAt = now.addingTimeInterval(CoordinatorTiming.heartbeatInterval)
    }

    /// Claude poll cadence follows the effective lid; E3 hints follow the sessions' transcript paths.
    func updateCadenceAndHints() async {
        let cadence = currentCadence
        if appliedCadence != cadence {
            appliedCadence = cadence
            await services.claudeState.setCadence(cadence)
        }
        let hints = SessionStoreHints.build(from: services.sessions.sessions)
        if appliedHints != hints {
            appliedHints = hints
            await services.processes.updateSessionStoreHints(hints)
        }
    }

    func checkConflictingApps(now: Date) {
        lastConflictingAppCheckAt = now
        let running = options.isApplicationRunning(KakurenekoID.appTamerBundleIdentifier)
        if running != appTamerRunning {
            appTamerRunning = running
            if running { logger.notice("App Tamer is running: it resumes processes others paused") }
        }
    }

    // MARK: Snapshot

    func buildSnapshot(now: Date) -> AppSnapshot {
        let integrations = integrationStatuses.map { status -> IntegrationStatus in
            var merged = status
            merged.lastEventSeen = lastEventSeen[status.agent] ?? status.lastEventSeen
            return merged
        }
        let warnings = WarningsBuilder.warnings(WarningInputs(
            mode: mode,
            privileged: privileged,
            rawPrivileged: rawPrivileged,
            privilegedChecked: privilegedChecked,
            settings: settings,
            power: latestPower,
            effectiveLidClosed: effectiveLidClosed,
            isDryRun: services.dryRun.isOn,
            appTamerRunning: appTamerRunning,
            groupingSelfTest: groupingSelfTest,
            notifications: notificationStatus,
            kernelSleepDisabledInDryRun: kernelSleepDisabledInDryRun,
            disarmFailed: disarmFailed,
            armingBlocked: armingBlocked,
            hotspotAtLidClose: hotspotAtLidClose,
            integrations: integrations
        ))
        return AppSnapshot(
            generatedAt: now,
            mode: mode,
            isDryRun: services.dryRun.isOn,
            isDryRunForced: services.dryRun.isForcedByEnvironment,
            dryRunLog: Array(services.ledger.entries.suffix(CoordinatorTiming.dryRunLogLimit)),
            sessions: services.sessions.sessions.filter { !$0.state.isEnded },
            aggregate: services.sessions.aggregate,
            powerPhase: machine.phase,
            power: latestPower,
            privileged: privileged,
            keepAwakeUntil: keepAwakeUntil,
            lastSleep: lastSleep,
            pausedApps: pause.pausedApps,
            lastPauseReport: pause.lastReport,
            groupingSelfTest: groupingSelfTest,
            notifications: notificationStatus,
            integrations: integrations,
            resumeOffer: resumeOffer,
            settings: settings,
            warnings: warnings
        )
    }

    /// Leading-edge coalescing: a change publishes at once when ≥ 250 ms passed since the last publish, else it
    /// is marked dirty and the 1 s tick flushes it (`force`). Never sleeps.
    /// - Parameter opensWindow: false for lifecycle publishes, which must not delay the first real change.
    func publishIfChanged(force: Bool = false, opensWindow: Bool = true) {
        let now = services.clock.now()
        let snapshot = buildSnapshot(now: now)
        if snapshot.isEquivalent(to: publisher.lastPublished) {
            publisher.dirty = false
            return
        }
        let elapsed = publisher.lastPublishAt.map { now.timeIntervalSince($0) } ?? .infinity
        guard force || elapsed >= CoordinatorTiming.minimumPublishInterval else {
            publisher.dirty = true
            return
        }
        publisher.lastPublished = snapshot
        if opensWindow { publisher.lastPublishAt = now }
        publisher.dirty = false
        publisher.count += 1
        broadcaster.yield(snapshot)
        reportStatus(PhoneStatusBuilder.report(from: snapshot, effectiveLidClosed: effectiveLidClosed, final: currentFinalStatus()))
    }

    // MARK: Status for the iPhone app

    /// Hands a changed report to Notify (in order; Notify debounces the iCloud saves).
    func reportStatus(_ report: MacStatusReport) {
        guard report != lastStatusReport else { return }
        lastStatusReport = report
        let previous = statusReportTail
        let notifications = services.notifications
        statusReportTail = Task {
            await previous?.value
            await notifications.updateMacStatus(report)
        }
    }

    /// The last status before the Mac goes dark (sleep, shutdown, quit), handed over and awaited, so the following
    /// `drain(deadline:)` saves it. It stays the reported status (`finalStatus`): the publishes that still follow
    /// (after the disarm, a battery change during a dark wake) must not replace "asleep" with "going to sleep".
    func reportFinalStatus(_ final: PhoneStatusBuilder.Final, untilWake: Bool) async {
        finalStatus = (final, untilWake || (finalStatus?.untilWake ?? false))
        let snapshot = buildSnapshot(now: services.clock.now())
        reportStatus(PhoneStatusBuilder.report(from: snapshot, effectiveLidClosed: effectiveLidClosed, final: final))
        await statusReportTail?.value
    }

    /// The sticky final status, or nil once it no longer applies (a wind-down cancelled before the sleep).
    func currentFinalStatus() -> PhoneStatusBuilder.Final? {
        guard let finalStatus else { return nil }
        if finalStatus.untilWake || machine.isWindingDown { return finalStatus.final }
        self.finalStatus = nil
        return nil
    }
}
