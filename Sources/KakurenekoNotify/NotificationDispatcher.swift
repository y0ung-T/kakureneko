// KakurenekoNotify — native notifications (brief §8; docs/NATIVE-NOTIFICATIONS.md). OWNER: agent "notify".
//
// NotificationTemplates (§8.4, three detail levels) and NotificationPolicy (presence, batch, dedupe + reminder,
// rate limit + digest, quiet hours) decide WHAT to say; every admitted message is then shown at once as a macOS
// notification (`LocalNotificationPosting`) and saved for the iPhone as a CloudKit `Alert` through the persistent
// Outbox (retry, TTL, coalescing, drain with a deadline). The same actor keeps the iCloud side in sync: zone and
// Mac inbox subscriptions, change-token fetches (push-triggered + polling) that bring phone commands and devices,
// command validation (right Mac, expiry, replay), the Mac's `MacStatus` record, and pruning of old alerts.
//
// Public surface (ARCHITECTURE §9.6): `NotificationDispatcher`, `UserNotificationCenterPoster`, `MacIdentity`;
// everything else is internal.

import KakurenekoCloud
import KakurenekoKit
import Foundation

/// Templates + policy + Mac notifications + iCloud relay (outbox, commands, status) (ARCHITECTURE §9.6).
///
/// Isolation: an actor; `remoteCommands()` is nonisolated. Persists `outbox.json` and `notify-state.json`
/// atomically. Every timer runs on the injected clock. Side effects go only through the injected (dry-run gated)
/// `LocalNotificationPosting` and `CloudStore`. Never logs message titles, bodies or record contents.
///
/// Timers (all on the injected clock, all cancelled by `stop()`): the 60 s tick (drain, digest, permission refresh,
/// status heartbeat, pruning), the per-item retry timer, the 15 s batch, the needs-input reminder, the digest, the
/// status debounce, and the iCloud loop (setup with backoff, then fetches every 15 s / 5 min or on a push).
public actor NotificationDispatcher: NotificationDispatching {
    private enum Lifecycle { case idle, running, stopped }

    private let paths: Paths
    private let clock: any KakurenekoClock
    private let logger: KakurenekoLogger
    private let environment: NotifyEnvironment
    private let store: NotifyStore
    private let local: any LocalNotificationPosting
    private let cloud: (any CloudStore)?
    private let identity: MacIdentity
    private nonisolated let commands = AsyncBroadcaster<RemoteCommand>(bufferLimit: 64)

    private var settings: NotificationSettings
    private var policy: NotificationPolicy
    private var lifecycle: Lifecycle = .idle
    private var loaded = false

    // Persistent state.
    private var state = NotifyPersistentState()
    private var outbox = Outbox()

    // Mac notifications.
    private var macAuthorization: MacAlertAuthorization = .notDetermined
    private var macTimeSensitive: Bool?
    private var registeredKeepAwakeSeconds: Int?
    /// Serializes local posts (each waits for the previous one), so notifications appear in submit order.
    private var localTail: Task<Void, Never>?
    private var tapTask: Task<Void, Never>?

    // iCloud.
    private var accountStatus: CloudAccountStatus
    /// Zone + Mac inbox subscriptions prepared during this launch.
    private var cloudReady = false
    private var cloudTask: Task<Void, Never>?
    /// `CKAccountChanged` (the Apple Account may have changed).
    private var accountTask: Task<Void, Never>?
    /// Signalled by a CloudKit push, a phone's refresh, the network coming back: fetch now.
    private let pollSignal = AsyncSignal()
    private var cloudFailures = 0
    private var fastPollUntil: Date?
    /// Quick re-fetches left after a push: a record saved a moment ago can take seconds to show up in queries.
    private var burstPolls = 0
    private var lastCloudError: String?

    // Mac status for the iPhone.
    private var latestReport: MacStatusReport?
    /// Presence as last reported (submit context; a status report updates the lid); nil until the first.
    private var presence: Presence?
    private var savedReport: MacStatusReport?
    /// Phase of the newest report already being saved or saved: a different phase is saved at once, the rest debounced.
    private var reportedPhase: MacPhase?
    private var statusSavedAt: Date?
    /// After a failed status save, the heartbeat waits until then (iCloud full: 10 min; else its retry hint or 1 min).
    private var statusRetryAt: Date?
    private var statusTask: Task<Void, Never>?

    // Delivery (outbox → iCloud).
    private var inFlight: Set<UUID> = []
    /// Signalled after every save attempt (lets `drain(deadline:)` wait for an attempt another pass owns).
    private let attemptFinished = AsyncSignal()
    private var backgroundDrainTask: Task<Void, Never>?
    private var backgroundDrainRerun = false
    private var lastPublishError: String?
    /// iCloud asked us to wait (`retryAfter`): no save attempt at all before this.
    private var serverHoldUntil: Date?
    /// Set by a retryable failure: background passes (enqueue, timers) wait until then so a failing network is
    /// not hammered item by item. `drain(deadline:)` ignores it. Cleared by a successful delivery.
    private var backgroundHoldUntil: Date?
    private var isOnline = true
    private var deliveredCount = 0
    private var permanentFailureCount = 0

    // Timers.
    private var pathMonitor: (any NetworkPathMonitoring)?
    private var pathTask: Task<Void, Never>?
    private var drainTimerTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var batchTask: Task<Void, Never>?
    private var reminderTask: Task<Void, Never>?
    private var digestTask: Task<Void, Never>?

    /// Binding signature. `localNotifications` and `cloud` are the dry-run gated side effects
    /// (`SideEffects.localNotifications` / `.cloud`; `cloud == nil` when the build has no iCloud entitlement).
    public init(
        paths: Paths,
        settings: NotificationSettings,
        localNotifications: any LocalNotificationPosting,
        cloud: (any CloudStore)?,
        clock: any KakurenekoClock = SystemClock(),
        logger: KakurenekoLogger = KakurenekoLogger(.notify)
    ) {
        self.init(paths: paths, settings: settings, localNotifications: localNotifications, cloud: cloud, clock: clock,
                  logger: logger, environment: .live)
    }

    /// Full initializer (tests inject the time zone, jitter, path monitor, identity and intervals).
    init(
        paths: Paths,
        settings: NotificationSettings,
        localNotifications: any LocalNotificationPosting,
        cloud: (any CloudStore)?,
        clock: any KakurenekoClock,
        logger: KakurenekoLogger,
        environment: NotifyEnvironment
    ) {
        let normalized = NotificationPolicy.normalized(settings)
        self.paths = paths
        self.settings = normalized
        self.clock = clock
        self.logger = logger
        self.environment = environment
        self.store = NotifyStore(paths: paths)
        self.policy = NotificationPolicy(settings: normalized)
        self.local = localNotifications
        self.cloud = cloud
        self.identity = environment.identity()
        self.accountStatus = cloud == nil ? .unavailableInThisBuild : .couldNotDetermine
    }

    // MARK: - Lifecycle

    public func start() async {
        ensureLoaded()
        guard lifecycle == .idle else { return }
        lifecycle = .running
        let monitor = environment.makePathMonitor()
        pathMonitor = monitor
        let updates = monitor.updates()
        pathTask = Task { [weak self] in
            for await satisfied in updates {
                guard let dispatcher = self else { return }
                await dispatcher.pathChanged(satisfied: satisfied)
            }
        }
        monitor.start()
        let clock = self.clock
        let interval = environment.drainInterval
        var nextTick = clock.now().addingTimeInterval(interval)
        drainTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(until: nextTick) } catch { return }
                nextTick = nextTick.addingTimeInterval(interval)
                let now = clock.now()
                if nextTick <= now { nextTick = now.addingTimeInterval(interval) } // e.g. after a system sleep
                guard let dispatcher = self else { return }
                await dispatcher.drainTimerFired()
            }
        }
        let taps = local.buttonTaps()
        tapTask = Task { [weak self] in
            for await tap in taps {
                guard let dispatcher = self else { return }
                await dispatcher.handleButtonTap(tap)
            }
        }
        await refreshMacAuthorization()
        registerCategoriesIfNeeded(keepAwakeSeconds: policy.lastContext?.keepAwakeSeconds ?? 3600)
        await localTail?.value
        if cloud != nil {
            cloudTask = Task { [weak self] in await self?.runCloudLoop() }
            // CloudKit's account-change notification (by name: this module doesn't import CloudKit).
            let changes = NotificationCenter.default.notifications(named: Notification.Name("CKAccountChanged"))
            accountTask = Task { [weak self] in
                for await _ in changes.map({ _ in () }) {
                    guard let dispatcher = self else { return }
                    await dispatcher.accountMayHaveChanged()
                }
            }
        }
        logger.info("notify started: outbox \(outbox.count), Mac notifications \(macAuthorization.rawValue), iCloud \(cloud == nil ? "not in this build" : "checking")")
        scheduleBackgroundDrain()
        scheduleReminderTimer()
        scheduleDigestTimer()
    }

    public func stop() async {
        ensureLoaded()
        guard lifecycle != .stopped else { return }
        lifecycle = .stopped
        // Keep batched and rate-limited messages for the next launch instead of losing them.
        flushBatch(drainNow: false)
        flushDigest(force: true, drainNow: false)
        accountTask?.cancel()
        accountTask = nil
        for task in [backgroundDrainTask, pathTask, drainTimerTask, retryTask, batchTask, reminderTask, digestTask, tapTask,
                     cloudTask, statusTask] {
            task?.cancel()
        }
        backgroundDrainTask = nil
        pathTask = nil
        drainTimerTask = nil
        retryTask = nil
        batchTask = nil
        reminderTask = nil
        digestTask = nil
        tapTask = nil
        cloudTask = nil
        statusTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        persistOutbox()
        persistState()
        commands.finish()
        logger.info("notify stopped: outbox \(outbox.count)")
    }

    public func applySettings(_ newSettings: NotificationSettings) async {
        ensureLoaded()
        let newSettings = NotificationPolicy.normalized(newSettings)
        let old = settings
        settings = newSettings
        policy.settings = newSettings
        if old.enabled && !newSettings.enabled {
            policy.reset()
            batchTask?.cancel()
            batchTask = nil
            let dropped = outbox.removeAll { !NotificationPolicy.userInitiated.contains($0.notification.kind) }
            if !dropped.isEmpty { persistOutbox() }
            scheduleReminderTimer()
            scheduleDigestTimer()
            logger.notice("notifications disabled: dropped \(dropped.count) queued")
        }
        if old.phoneAlerts && !newSettings.phoneAlerts {
            let dropped = outbox.removeAll { _ in true }
            if !dropped.isEmpty { persistOutbox() }
            logger.notice("iPhone alerts turned off: dropped \(dropped.count) queued")
            await removeCloudData()
        } else if !old.phoneAlerts && newSettings.phoneAlerts {
            state.pendingCloudRemoval = false
            persistState()
            if latestReport != nil { scheduleStatusSave(immediately: true) }
        }
        if newSettings.mutedKinds != old.mutedKinds {
            policy.removeFromBatchAndDigest { newSettings.isMuted($0) }
            let dropped = outbox.removeAll { newSettings.isMuted($0.notification.kind) && !NotificationPolicy.userInitiated.contains($0.notification.kind) }
            if !dropped.isEmpty { persistOutbox() }
            scheduleDigestTimer()
        }
    }

    // MARK: - Submitting

    @discardableResult
    public func submit(_ intent: NotificationIntent, context: NotificationContext) async -> NotificationDisposition {
        ensureLoaded()
        guard lifecycle != .stopped else { return .suppressed("stopped") }
        policy.noteContext(context)
        presence = context.presence
        registerCategoriesIfNeeded(keepAwakeSeconds: context.keepAwakeSeconds)
        // Resolve first: a wait that just ended must never release its held-back reminder.
        if case .resolved(let key) = intent {
            resolve(key)
            if !policy.dueReminders(at: clock.now()).isEmpty { processDueReminders() }
            return .suppressed("resolved")
        }
        // A reminder held back while the user was present goes out once a submit says they left.
        if !policy.dueReminders(at: clock.now()).isEmpty { processDueReminders() }
        if case .needsInput(let effect, let awakeUntil) = intent,
           policy.isDeliveredWithoutPhone(effect.session.key, since: NotificationTemplates.waitingSince(effect)) {
            return sendPhoneCopy(effect, awakeUntil: awakeUntil, context: context)
        }
        if case .suppress(var reason) = policy.gate(intent, context: context, hasChannel: hasChannel(for: intent.kind)) {
            // Only the iPhone could show it, and its timing holds it back (lid open / user at the Mac).
            if reason == "noChannel" && canQueueForPhone { reason = phoneWaitReason }
            logger.info("suppressed \(intent.kind.rawValue): \(reason)")
            return .suppressed(reason)
        }
        let template = templateContext(context)
        let now = context.now
        switch intent {
        case .finished(let effect, let stillRunning):
            return addToBatch(BatchedFinish(kind: .finished, effect: effect), stillRunning: stillRunning, context: context)
        case .wentQuiet(let effect, let sleepsAt):
            return addToBatch(BatchedFinish(kind: .wentQuiet(sleepsAt: sleepsAt), effect: effect), stillRunning: nil, context: context)
        case .needsInput(let effect, let awakeUntil):
            let notification = NotificationTemplates.needsInput(effect, awakeUntil: awakeUntil, context: template)
            let disposition = admitAndDeliver(notification, now: now)
            policy.markDelivered(effect.session.key, since: NotificationTemplates.waitingSince(effect), at: clock.now(),
                                 toPhone: canQueueForPhone && phoneTakes(.needsInput))
            scheduleReminderTimer()
            return disposition
        case .countdown(let endsAt, let reason, let finished, let waiting, let offerShutdown):
            var listed = finished
            if let batch = policy.takeBatch() {
                batchTask?.cancel()
                batchTask = nil
                let known = Set(finished.map(\.session.key))
                listed += batch.items.map(\.effect).filter { !known.contains($0.session.key) }
                logger.info("folded \(batch.items.count) batched finish(es) into the countdown")
            }
            // The countdown lists the finished sessions itself: rate-limited finish messages are obsolete.
            policy.dropFoldedFinishes()
            let notification = NotificationTemplates.countdown(
                endsAt: endsAt, reason: reason, finished: listed, waiting: waiting, offerShutdown: offerShutdown, context: template)
            return admitAndDeliver(notification, now: now)
        case .stalled(let effect):
            return admitAndDeliver(NotificationTemplates.stalled(effect, context: template), now: now)
        case .safetyTrip(let trip, let runningAgents):
            return admitAndDeliver(NotificationTemplates.safetyTrip(trip, runningAgents: runningAgents, context: template), now: now)
        case .asleep(let record, let batteryPercent):
            return admitAndDeliver(NotificationTemplates.asleep(record, batteryPercent: batteryPercent, context: template), now: now)
        case .shuttingDown(let at, let requestedFromPhone):
            return admitAndDeliver(NotificationTemplates.shuttingDown(at: at, requestedFromPhone: requestedFromPhone, context: template), now: now)
        case .commandIgnored(let reason):
            return admitAndDeliver(NotificationTemplates.commandIgnored(reason: reason, context: template), now: now)
        case .warning(let title, let body):
            return admitAndDeliver(NotificationTemplates.warning(title: title, body: body, context: template), now: now)
        case .test:
            let notification = NotificationTemplates.test(context: template)
            deliver(notification)
            return .queued(notification.id)
        case .resolved:
            return .suppressed("resolved")
        }
    }

    public func enqueue(_ notification: OutgoingNotification) async {
        ensureLoaded()
        guard lifecycle != .stopped else { return }
        deliver(notification)
    }

    @discardableResult
    public func drain(deadline: Date) async -> DrainResult {
        ensureLoaded()
        let deliveredBefore = deliveredCount
        let permanentBefore = permanentFailureCount
        // Before a Kakureneko-initiated sleep everything pending goes out: the open batch and the digest too.
        flushBatch(drainNow: false)
        flushDigest(force: true, drainNow: false)
        // The phone should see the latest status (e.g. "asleep") before the Mac goes dark.
        if let latestReport, latestReport != savedReport {
            await saveStatusNow(limit: min(environment.sendTimeout, deadline.timeIntervalSince(clock.now())))
        }
        var hitDeadline = false
        var respectBackoff = false
        while !Task.isCancelled {
            if await drainPass(respectBackoff: respectBackoff, background: false, deadline: deadline) {
                hitDeadline = true
                break
            }
            respectBackoff = true
            guard canSaveToCloud, !outbox.isEmpty else { break }
            let now = clock.now()
            if now >= deadline {
                hitDeadline = true
                break
            }
            guard var next = outbox.earliestAttempt(excluding: inFlight) else {
                // Only items another pass is sending remain: wait for one of those attempts to finish, bounded by
                // the deadline (the generation is read without a suspension point, so no completion is missed).
                if await !waitForAttempt(after: attemptFinished.generation, until: deadline) {
                    hitDeadline = true
                    break
                }
                continue
            }
            if let serverHoldUntil, serverHoldUntil > next { next = serverHoldUntil }
            guard next < deadline else {
                hitDeadline = true
                break
            }
            if next > now {
                do { try await clock.sleep(until: next) } catch { break }
            }
        }
        let result = DrainResult(
            delivered: deliveredCount - deliveredBefore,
            remaining: outbox.count,
            permanentFailures: permanentFailureCount - permanentBefore,
            hitDeadline: hitDeadline && !outbox.isEmpty)
        logger.info("drain: delivered \(result.delivered), remaining \(result.remaining), permanent \(result.permanentFailures)\(result.hitDeadline ? ", hit deadline" : "")")
        scheduleRetryTimer()
        return result
    }

    public nonisolated func remoteCommands() -> AsyncStream<RemoteCommand> { commands.stream() }

    public func status() async -> NotificationStatus {
        ensureLoaded()
        let recent = clock.now().addingTimeInterval(-Self.phoneForgetAfter)
        let phones = state.phones.values
            .filter { $0.lastSeenAt >= recent }
            .sorted { ($0.lastSeenAt, $0.deviceID) > ($1.lastSeenAt, $1.deviceID) }
        return NotificationStatus(
            macAuthorization: macAuthorization,
            macTimeSensitive: macTimeSensitive,
            iCloud: accountStatus,
            phones: phones,
            outboxCount: outbox.count,
            lastDeliveredAt: state.lastDeliveredAt,
            lastCommandAt: state.lastCommandAt,
            lastError: lastPublishError ?? lastCloudError)
    }

    public func updateMacStatus(_ report: MacStatusReport) async {
        ensureLoaded()
        latestReport = report
        presence = Presence(lidClosed: report.lidClosed, screenLocked: presence?.screenLocked ?? false,
                            secondsSinceUserInput: presence?.secondsSinceUserInput, hasLid: presence?.hasLid ?? true)
        guard report != savedReport, lifecycle == .running else { return }
        let phaseChanged = report.phase != reportedPhase
        if phaseChanged { reportedPhase = report.phase }
        scheduleStatusSave(immediately: phaseChanged)
    }

    public func requestMacAuthorization() async -> MacAlertAuthorization {
        ensureLoaded()
        let result = await local.requestAuthorization()
        await refreshMacAuthorization()
        if result.canPost {
            registeredKeepAwakeSeconds = nil
            registerCategoriesIfNeeded(keepAwakeSeconds: policy.lastContext?.keepAwakeSeconds ?? 3600)
            await localTail?.value
        }
        logger.notice("Mac notification permission: \(result.rawValue)")
        return result
    }

    public func sendTest() async throws {
        ensureLoaded()
        await refreshMacAuthorization()
        let onMac = settings.macAlerts && macAuthorization.canPost
        guard onMac || canQueueForPhone else {
            throw SideEffectError.unavailable(
                "Allow notifications for \(KakurenekoID.appName) in System Settings → Notifications, or set up the \(KakurenekoID.appName) iPhone app")
        }
        deliver(NotificationTemplates.test(context: defaultTemplateContext()))
    }

    public func cloudDidNotify() async {
        guard lifecycle == .running else { return }
        logger.notice("iCloud push: fetching changes")
        burstPolls = Self.pushBurstPolls
        pollSignal.signal()
        await local.removeRemoteAlerts()
    }

    /// How long one `lookForPhones` keeps the quick fetches going.
    static let phoneLookoutWindow: TimeInterval = 10 * 60

    public func lookForPhones() async {
        guard lifecycle == .running else { return }
        let now = clock.now()
        if fastPollUntil.map({ $0 > now }) != true { logger.info("looking for an iPhone in iCloud") }
        extendFastPolling(until: now.addingTimeInterval(Self.phoneLookoutWindow), now: now, wake: false)
        pollSignal.signal() // fetch now, then every fastPollInterval
    }

    // MARK: - Channels

    /// Phones whose record wasn't saved for this long are no longer listed (an iPhone saves it when the app opens and
    /// with background pushes, at most every 6 h); their records go after `deviceRetention`.
    static let phoneForgetAfter: TimeInterval = 14 * 24 * 3600

    /// At least one channel can show a `kind` message now (else the policy suppresses with `noChannel`).
    private func hasChannel(for kind: NotificationKind) -> Bool {
        canShowOnMac || (canQueueForPhone && phoneTakes(kind))
    }

    private var canShowOnMac: Bool { settings.macAlerts && macAuthorization.canPost }

    /// The iPhone's timing (`phoneTiming`) lets a `kind` message go now. Unknown presence (before the first submit or
    /// report) counts as away, so nothing is lost.
    private func phoneTakes(_ kind: NotificationKind) -> Bool {
        if NotificationPolicy.phoneTimingBypass.contains(kind) { return true }
        guard let presence else { return true }
        switch settings.phoneTiming {
        case .always: return true
        // A Mac without a lid can never close it: there "only with the lid closed" means "while you're away".
        case .lidClosed where !presence.hasLid, .away:
            return presence.isAway(idleThreshold: TimeInterval(settings.awayIdleSeconds))
        case .lidClosed: return presence.lidClosed
        }
    }

    private var waitsForLid: Bool { settings.phoneTiming == .lidClosed && presence?.hasLid != false }

    /// Why the iPhone waits: the suppression reason, and the same in words for the log.
    private var phoneWaitReason: String { waitsForLid ? "lidOpen" : "present" }
    private var phoneWaitText: String { waitsForLid ? "lid open" : "user at the Mac" }

    /// A wait already shown on the Mac while the iPhone's timing held it back: once the timing allows (the
    /// coordinator re-submits waits when the lid closes and when the user leaves), the iPhone gets its copy.
    private func sendPhoneCopy(_ effect: SessionEffect, awakeUntil: Date?, context: NotificationContext) -> NotificationDisposition {
        guard settings.enabled, !settings.isMuted(.needsInput), canQueueForPhone, phoneTakes(.needsInput),
              !policy.isSkippedRemoteControl(effect.session) else { return .suppressed("duplicate") }
        var notification = NotificationTemplates.needsInput(effect, awakeUntil: awakeUntil, context: templateContext(context))
        policy.applyQuietHours(to: &notification, now: context.now, timeZone: environment.timeZone)
        deliver(notification, to: .phone)
        policy.markPhoneDelivered(effect.session.key)
        logger.info("needs-input: the iPhone gets the wait the Mac already showed")
        return .queued(notification.id)
    }

    /// Alerts may be queued for the iPhone: the setting is on, this build has iCloud, and the account is not known
    /// to be missing (while it is being checked, alerts wait in the outbox).
    private var canQueueForPhone: Bool {
        guard settings.phoneAlerts, cloud != nil else { return false }
        switch accountStatus {
        case .noAccount, .restricted, .unavailableInThisBuild: return false
        case .available, .temporarilyUnavailable, .couldNotDetermine: return true
        }
    }

    /// The outbox may be saved to iCloud now.
    private var canSaveToCloud: Bool { cloud != nil && cloudReady && settings.phoneAlerts && accountStatus.isAvailable }

    private func refreshMacAuthorization() async {
        let (authorization, timeSensitive) = await local.authorization()
        if authorization != macAuthorization { logger.info("Mac notification permission: \(authorization.rawValue)") }
        macAuthorization = authorization
        macTimeSensitive = timeSensitive
    }

    /// Registers the button categories when the Keep awake duration changed, in line with the local posts (a
    /// notification posted after a change already shows the new title).
    private func registerCategoriesIfNeeded(keepAwakeSeconds: Int) {
        guard registeredKeepAwakeSeconds != keepAwakeSeconds else { return }
        registeredKeepAwakeSeconds = keepAwakeSeconds
        let previous = localTail
        let local = self.local
        localTail = Task {
            await previous?.value
            await local.registerCategories(keepAwakeSeconds: keepAwakeSeconds)
        }
    }

    // MARK: - Policy plumbing

    private func addToBatch(_ item: BatchedFinish, stillRunning: Int?, context: NotificationContext) -> NotificationDisposition {
        let opened = policy.addToBatch(item, stillRunning: stillRunning, context: context, now: clock.now())
        if opened, let deadline = policy.batch?.deadline {
            let clock = self.clock
            batchTask = Task { [weak self] in
                do { try await clock.sleep(until: deadline) } catch { return }
                await self?.batchTimerFired()
            }
        }
        return .batched
    }

    private func batchTimerFired() {
        batchTask = nil
        flushBatch(drainNow: true)
    }

    /// Renders the open batch (one message for N finishes) and delivers it.
    private func flushBatch(drainNow: Bool) {
        guard let batch = policy.takeBatch() else { return }
        batchTask?.cancel()
        batchTask = nil
        var template = templateContext(batch.context)
        template.now = clock.now()
        guard let notification = NotificationTemplates.batch(batch.items, stillRunning: batch.stillRunning, context: template) else { return }
        _ = admitAndDeliver(notification, now: template.now, drainNow: drainNow)
    }

    /// Rate limit (overflow → digest), quiet hours, then both channels.
    private func admitAndDeliver(_ notification: OutgoingNotification, now: Date, drainNow: Bool = true) -> NotificationDisposition {
        guard policy.admit(notification, now: now) else {
            logger.info("rate limit: folded \(notification.kind.rawValue) into the digest")
            scheduleDigestTimer()
            return .folded
        }
        var adjusted = notification
        policy.applyQuietHours(to: &adjusted, now: now, timeZone: environment.timeZone)
        deliver(adjusted, drainNow: drainNow)
        return .queued(adjusted.id)
    }

    /// `.resolved(key)`: cancel the reminder, drop the queued (and folded) needs-input messages. Never sends.
    private func resolve(_ key: SessionKey) {
        policy.resolve(key)
        let group = NotificationTemplates.inputGroupKey(key)
        // An in-flight copy cannot be withdrawn, but removing it here keeps it from being retried.
        let dropped = outbox.removeAll { $0.notification.groupKey == group }
        if !dropped.isEmpty {
            persistOutbox()
            logger.info("resolved wait: dropped \(dropped.count) queued needs-input message(s)")
        }
        scheduleReminderTimer()
        scheduleDigestTimer()
    }

    private func scheduleReminderTimer() {
        reminderTask?.cancel()
        reminderTask = nil
        let now = clock.now()
        guard lifecycle != .stopped, let due = policy.nextReminderDue(after: now) else { return }
        let clock = self.clock
        reminderTask = Task { [weak self] in
            do { try await clock.sleep(until: due) } catch { return }
            await self?.reminderTimerFired()
        }
    }

    private func reminderTimerFired() {
        reminderTask = nil
        processDueReminders()
    }

    /// Sends the single reminder of every delivered, unresolved wait whose time has come. A reminder that
    /// presence holds back stays due and is re-checked on the next submit (the coordinator re-submits on every
    /// present → away transition); one whose channel is gone (disabled, muted, no channel) is dropped.
    private func processDueReminders() {
        let now = clock.now()
        for record in policy.dueReminders(at: now) {
            let key = record.effect.session.key
            guard settings.enabled, !settings.isMuted(.needsInput), canShowOnMac || canQueueForPhone,
                  !policy.isSkippedRemoteControl(record.effect.session) else {
                policy.markReminderSent(key)
                continue
            }
            if !hasChannel(for: .needsInput) {
                logger.info("needs-input reminder held back: \(phoneWaitText)")
                continue
            }
            policy.markReminderSent(key)
            if canQueueForPhone && phoneTakes(.needsInput) { policy.markPhoneDelivered(key) }
            let awakeUntil = record.awakeUntil.flatMap { $0 > now ? $0 : nil }
            let notification = NotificationTemplates.needsInput(
                record.effect, awakeUntil: awakeUntil, reminder: true, context: defaultTemplateContext(now: now))
            _ = admitAndDeliver(notification, now: now)
            logger.info("needs-input reminder queued")
        }
        scheduleReminderTimer()
    }

    private func scheduleDigestTimer() {
        digestTask?.cancel()
        digestTask = nil
        let now = clock.now()
        guard lifecycle != .stopped, let due = policy.nextDigestTime(now: now) else { return }
        let clock = self.clock
        digestTask = Task { [weak self] in
            do { try await clock.sleep(until: due) } catch { return }
            await self?.digestTimerFired()
        }
    }

    private func digestTimerFired() {
        digestTask = nil
        flushDigest(force: false, drainNow: true)
        scheduleDigestTimer()
    }

    /// Delivers the digest of rate-limited messages when a token is free (or regardless, with `force`).
    private func flushDigest(force: Bool, drainNow: Bool) {
        let now = clock.now()
        guard let folded = policy.takeDigest(now: now, force: force),
              var digest = NotificationTemplates.digest(folded, context: defaultTemplateContext(now: now)) else { return }
        policy.applyQuietHours(to: &digest, now: now, timeZone: environment.timeZone)
        deliver(digest, drainNow: drainNow)
        logger.info("rate limit: digest of \(folded.count) queued")
    }

    private func templateContext(_ context: NotificationContext) -> TemplateContext {
        TemplateContext(detail: settings.detailLevel, now: context.now, timeZone: environment.timeZone,
                        stateVersion: context.stateVersion, keepAwakeSeconds: context.keepAwakeSeconds)
    }

    /// For timer-driven and test messages: the latest submit context's `sv` / keep-awake, at `now`.
    private func defaultTemplateContext(now: Date? = nil) -> TemplateContext {
        let last = policy.lastContext
        return TemplateContext(detail: settings.detailLevel, now: now ?? clock.now(), timeZone: environment.timeZone,
                               stateVersion: last?.stateVersion ?? 0, keepAwakeSeconds: last?.keepAwakeSeconds ?? 3600)
    }

    // MARK: - Delivery

    /// The alert both channels show for `notification` (same id, so a tap on either refers to one alert).
    private func cloudAlert(for notification: OutgoingNotification) -> CloudAlert {
        CloudAlert(
            id: notification.id.uuidString, macID: state.macID, macName: identity.name, kind: notification.kind.rawValue,
            title: notification.title, body: notification.body, threadID: notification.groupKey,
            replaceKey: notification.replaceKey, interruption: notification.priority.interruption,
            actions: notification.actions.map(\.cloudAction), stateVersion: notification.stateVersion,
            createdAt: notification.createdAt, expiresAt: notification.createdAt.addingTimeInterval(notification.actionTTL))
    }

    enum Channels { case all, phone }

    /// Shows `notification` on the Mac now (when allowed) and queues it for the iPhone (when possible and its timing
    /// allows); `.phone` skips the Mac (it already showed the message).
    private func deliver(_ notification: OutgoingNotification, to channels: Channels = .all, drainNow: Bool = true) {
        let alert = cloudAlert(for: notification)
        if channels == .all && canShowOnMac {
            let previous = localTail
            let local = self.local
            let logger = self.logger
            let kind = notification.kind.rawValue
            localTail = Task {
                await previous?.value
                do {
                    try await local.post(alert)
                } catch {
                    logger.notice("Mac notification \(kind) not shown: \(type(of: error))")
                }
            }
        }
        guard canQueueForPhone else { return }
        guard phoneTakes(notification.kind) else {
            logger.info("\(notification.kind.rawValue) not sent to the iPhone: \(phoneWaitText)")
            return
        }
        // An item being saved right now cannot be withdrawn by a replacement; it simply completes.
        let replaced = outbox.enqueue(notification, now: clock.now())
        persistOutbox()
        logger.info("queued \(notification.kind.rawValue) for iCloud (priority \(notification.priority.rawValue), \(notification.actions.count) button(s))\(replaced.isEmpty ? "" : ", replaced \(replaced.count)")")
        if drainNow { scheduleBackgroundDrain() }
    }

    /// Background delivery runs only while started (`start()` drains whatever is queued);
    /// `drain(deadline:)` is explicit and works in any state.
    private func scheduleBackgroundDrain() {
        guard lifecycle == .running else { return }
        if backgroundDrainTask != nil {
            backgroundDrainRerun = true
            return
        }
        retryTask?.cancel()
        retryTask = nil
        backgroundDrainTask = Task { [weak self] in
            await self?.runBackgroundDrains()
        }
    }

    private func runBackgroundDrains() async {
        repeat {
            backgroundDrainRerun = false
            _ = await drainPass(respectBackoff: true, background: true, deadline: nil)
        } while backgroundDrainRerun && !Task.isCancelled && lifecycle != .stopped
        backgroundDrainTask = nil
        scheduleRetryTimer()
    }

    /// Wakes the background drain when the earliest queued item (or a hold) becomes due.
    private func scheduleRetryTimer() {
        retryTask?.cancel()
        retryTask = nil
        guard lifecycle == .running, isOnline, backgroundDrainTask == nil, canSaveToCloud else { return }
        guard var due = outbox.earliestAttempt(excluding: inFlight) else { return }
        for hold in [serverHoldUntil, backgroundHoldUntil].compactMap({ $0 }) where hold > due { due = hold }
        due = max(due, clock.now().addingTimeInterval(environment.minimumRetryDelay))
        let clock = self.clock
        retryTask = Task { [weak self] in
            do { try await clock.sleep(until: due) } catch { return }
            await self?.retryTimerFired()
        }
    }

    private func retryTimerFired() {
        retryTask = nil
        scheduleBackgroundDrain()
    }

    /// The 60 s tick: expire, digest, drain, re-read the Mac permission, status heartbeat, pruning.
    private func drainTimerFired() async {
        let now = clock.now()
        dropExpired(now: now)
        flushDigest(force: false, drainNow: false)
        scheduleDigestTimer()
        scheduleBackgroundDrain()
        await refreshMacAuthorization()
        await local.removeRemoteAlerts()
        if latestReport != nil, canSaveStatus, statusRetryAt.map({ now >= $0 }) ?? true,
           statusSavedAt.map({ now.timeIntervalSince($0) >= environment.statusHeartbeat }) ?? true {
            await saveStatusNow()
        }
        await pruneIfDue(now: now)
    }

    private func dropExpired(now: Date) {
        let expired = outbox.removeExpired(now: now)
        if !expired.isEmpty {
            persistOutbox()
            logger.info("outbox: dropped \(expired.count) expired")
        }
    }

    /// One pass over the outbox in FIFO order; stops at the first retryable failure. Background passes (enqueue,
    /// timers, path) respect per-item backoff, the network path and the background hold; `drain(deadline:)`
    /// forces its first pass. Every pass respects a server-requested hold. Returns true when the pass stopped
    /// because of `deadline`.
    private func drainPass(respectBackoff: Bool, background: Bool, deadline: Date?) async -> Bool {
        let start = clock.now()
        dropExpired(now: start)
        guard let cloud, canSaveToCloud else { return false }
        if background {
            if !isOnline { return false }
            if let backgroundHoldUntil, backgroundHoldUntil > start { return false }
        }
        let candidates = outbox.items
            .filter { !inFlight.contains($0.id) && (!respectBackoff || $0.nextAttemptAt <= start) }
            .map(\.id)
        for id in candidates {
            if Task.isCancelled { return false }
            let now = clock.now()
            if let deadline, now >= deadline { return true }
            if let serverHoldUntil, serverHoldUntil > now { return false }
            guard canSaveToCloud else { return false }
            guard let item = outbox.item(id: id), !inFlight.contains(id) else { continue }
            if item.notification.expiresAt <= now {
                outbox.remove(id: id)
                persistOutbox()
                continue
            }
            let limit = deadline.map { min(environment.sendTimeout, $0.timeIntervalSince(now)) } ?? environment.sendTimeout
            let outcome = await attempt(item, cloud: cloud, limit: limit)
            if outcome != .delivered, let deadline, clock.now() >= deadline { return true }
            switch outcome {
            case .delivered, .permanent: continue
            case .retryable, .timedOut: return false
            }
        }
        return false
    }

    /// Saves one item (marking it in flight) and applies the outcome to the outbox.
    private func attempt(_ item: OutboxItem, cloud: any CloudStore, limit: TimeInterval) async -> DeliveryOutcome {
        let id = item.id
        let alert = cloudAlert(for: item.notification)
        inFlight.insert(id)
        // Listed before the save: one that reaches iCloud but times out here is still removed with the rest.
        state.noteSavedAlert(alert.id, createdAt: alert.createdAt)
        let saved = await Self.save([.alert(alert)], to: cloud, clock: clock, limit: limit)
        inFlight.remove(id)
        defer { attemptFinished.signal() }
        // Stopped (or cancelled) meanwhile: `stop()` already persisted the outbox with this item; leave it for the
        // next launch instead of recording an outcome that is only an artefact of the cancellation.
        if Task.isCancelled || lifecycle == .stopped { return .timedOut }
        let now = clock.now()
        let kind = item.notification.kind.rawValue
        let outcome: DeliveryOutcome
        switch saved {
        case .some(.success):
            outcome = .delivered
        case .some(.failure(let error)):
            outcome = noteCloudFailure(error, wakeLoop: true)
        case .none:
            outcome = .timedOut
        }
        switch outcome {
        case .delivered:
            outbox.remove(id: id)
            deliveredCount += 1
            lastPublishError = nil
            lastCloudError = nil
            serverHoldUntil = nil
            backgroundHoldUntil = nil
            state.lastDeliveredAt = now
            state.noteSavedAlert(alert.id, createdAt: alert.createdAt)
            if !alert.actions.isEmpty { extendFastPolling(until: alert.expiresAt, now: now) }
            persistOutbox()
            persistState()
            logger.info("saved \(kind) to iCloud after \(item.attempts + 1) attempt(s)")
            // iPhone alerts were turned off while this save was in flight: it leaves iCloud with the rest.
            if !settings.phoneAlerts { await removeCloudData() }
        case .permanent(let description):
            outbox.remove(id: id)
            permanentFailureCount += 1
            lastPublishError = description
            persistOutbox()
            logger.error("dropped \(kind): \(description)")
        case .retryable(let after):
            let delay = after ?? BackoffPolicy.outbox.delay(afterFailures: item.attempts + 1, random: environment.random)
            let retryAt = now.addingTimeInterval(delay)
            if after != nil { serverHoldUntil = retryAt }
            backgroundHoldUntil = retryAt
            outbox.recordRetryableFailure(id: id, retryAt: retryAt, error: after == nil ? "retryable" : "retry after \(Int(delay.rounded())) s")
            persistOutbox()
            logger.notice("saving \(kind) to iCloud failed (retryable), next attempt in \(Int(delay.rounded())) s")
        case .timedOut:
            let delay = BackoffPolicy.outbox.delay(afterFailures: item.attempts + 1, random: environment.random)
            let retryAt = now.addingTimeInterval(delay)
            backgroundHoldUntil = retryAt
            outbox.recordRetryableFailure(id: id, retryAt: retryAt, error: "timed out")
            persistOutbox()
            logger.notice("saving \(kind) to iCloud timed out, next attempt in \(Int(delay.rounded())) s")
        }
        return outcome
    }

    /// `cloud.save` raced against `limit` on the injected clock (nil = timed out or cancelled). Returns at the limit
    /// even when the save ignores cancellation: the save and the timer run as unstructured tasks and the first to
    /// finish resumes the caller (a task group would wait for the hanging child). A save that completes after the
    /// timeout is harmless: the item is retried and saving the same record again is an upsert.
    private static func save(_ items: [CloudItem], to cloud: any CloudStore, clock: any KakurenekoClock,
                             limit: TimeInterval) async -> Result<Void, CloudError>? {
        await bounded(clock: clock, limit: limit) { () async throws(CloudError) in try await cloud.save(items) }
    }

    /// Runs one iCloud operation within `limit` seconds: nil when it timed out (or `limit` ≤ 0).
    private static func bounded(clock: any KakurenekoClock, limit: TimeInterval,
                                _ operation: @escaping @Sendable () async throws(CloudError) -> Void) async -> Result<Void, CloudError>? {
        guard limit > 0 else { return nil }
        // Fixed before any task runs: a timer task that starts late must not stretch the timeout.
        let deadline = clock.now().addingTimeInterval(limit)
        let race = FirstResult<Result<Void, CloudError>?>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, CloudError>?, Never>) in
                race.begin(continuation)
                let saveTask = Task {
                    do throws(CloudError) {
                        try await operation()
                        race.finish(.success(()))
                    } catch {
                        race.finish(.failure(error))
                    }
                }
                let timer = Task {
                    try? await clock.sleep(until: deadline)
                    race.finish(nil)
                }
                race.onFinish { saveTask.cancel(); timer.cancel() }
            }
        } onCancel: {
            race.finish(nil)
        }
    }

    /// Classifies an iCloud failure for the outbox and updates the iCloud state it reveals. `wakeLoop`: the failure
    /// came from outside the iCloud loop (an outbox save) and needs the loop to set iCloud up again now; the loop's
    /// own failures never wake it (it backs off instead — waking it would make a tight loop).
    private func noteCloudFailure(_ error: CloudError, wakeLoop: Bool = false) -> DeliveryOutcome {
        lastCloudError = error.userMessage
        switch error {
        case .network(let after), .rateLimited(let after):
            return .retryable(after: after)
        case .zoneMissing:
            // Someone deleted Kakureneko's iCloud data: set the zone up again, then retry.
            cloudReady = false
            state.changeToken = nil
            if wakeLoop { pollSignal.signal() }
            return .retryable(after: nil)
        case .notSignedIn:
            // The loop re-checks the account (and sets iCloud up again if it is back); no long hold on the outbox:
            // `canSaveToCloud` stops background saves until then.
            accountStatus = .noAccount
            cloudReady = false
            if wakeLoop { pollSignal.signal() }
            return .retryable(after: nil)
        case .quotaExceeded:
            // Only the user can free iCloud storage: keep the alert (until it expires) and retry now and then.
            return .retryable(after: environment.quotaRetryInterval)
        case .permanent, .unknownRecordType, .changeTokenExpired:
            return .permanent(error.userMessage)
        }
    }

    /// Waits until a save attempt finishes after `generation` of `attemptFinished`, or until `deadline`,
    /// whichever comes first. True when an attempt finished. Both waits are cancellable, so this returns at the
    /// deadline even while a save is still hanging (`drain(deadline:)` must never overrun it).
    private func waitForAttempt(after generation: UInt64, until deadline: Date) async -> Bool {
        guard deadline > clock.now() else { return false }
        let clock = self.clock
        let signal = attemptFinished
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await signal.wait(unlessChangedFrom: generation)
                return true
            }
            group.addTask {
                try? await clock.sleep(until: deadline)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func pathChanged(satisfied: Bool) {
        let wasOnline = isOnline
        isOnline = satisfied
        guard satisfied else {
            if wasOnline { logger.info("network path unsatisfied: background delivery paused") }
            retryTask?.cancel()
            retryTask = nil
            return
        }
        guard !wasOnline else { return }
        logger.info("network path satisfied: draining and fetching")
        backgroundHoldUntil = nil
        scheduleBackgroundDrain()
        pollSignal.signal()
    }

    // MARK: - iCloud loop (setup, fetch, commands)

    /// Until stopped: set up the zone and subscription (backoff on failure, slow re-checks while there is no
    /// account), then fetch changes on every push / signal and on the poll interval.
    private func runCloudLoop() async {
        guard let cloud else { return }
        while lifecycle == .running, !Task.isCancelled {
            // Read before working: a push that arrives during this round triggers the next one at once.
            let generation = pollSignal.generation
            var delay: TimeInterval
            if !cloudReady {
                if await setUpCloud(cloud) {
                    scheduleBackgroundDrain()
                    if latestReport != nil { await saveStatusNow() }
                    continue // fetch right away
                }
                switch accountStatus {
                case .noAccount, .restricted, .unavailableInThisBuild: delay = environment.accountRecheckInterval
                case .available, .temporarilyUnavailable, .couldNotDetermine: delay = cloudBackoff()
                }
            } else if await fetchChanges(from: cloud) {
                cloudFailures = 0
                delay = nextPollDelay()
            } else {
                delay = cloudBackoff() // also after losing the zone: set up again after the backoff
            }
            if delay > 0 { await waitForPoll(after: generation, seconds: delay) }
        }
    }

    private func cloudBackoff() -> TimeInterval {
        cloudFailures += 1
        return BackoffPolicy.cloudPoll.delay(afterFailures: cloudFailures, random: environment.random)
    }

    /// After a push: this many quick re-fetches `pushBurstInterval` apart (the query index lags behind saves).
    static let pushBurstPolls = 2
    static let pushBurstInterval: TimeInterval = 3

    private func currentPollInterval() -> TimeInterval {
        if let fastPollUntil, fastPollUntil > clock.now() { return environment.fastPollInterval }
        return environment.slowPollInterval
    }

    /// The wait before the next fetch (consumes one burst re-fetch).
    private func nextPollDelay() -> TimeInterval {
        if burstPolls > 0 {
            burstPolls -= 1
            return Self.pushBurstInterval
        }
        return currentPollInterval()
    }

    /// Polls every `fastPollInterval` until `until` (≤ 2 h). `wake`: when the loop is in a slow wait, cut it short so
    /// the fast interval starts now (the loop itself passes false: it recomputes its delay right after).
    private func extendFastPolling(until: Date, now: Date, wake: Bool = true) {
        let wasFast = fastPollUntil.map { $0 > now } ?? false
        let capped = min(until, now.addingTimeInterval(2 * 3600))
        fastPollUntil = max(fastPollUntil ?? capped, capped)
        if wake && !wasFast && lifecycle == .running { pollSignal.signal() }
    }

    /// Sleeps `seconds`, or less when `pollSignal` fires after `generation`.
    private func waitForPoll(after generation: UInt64, seconds: TimeInterval) async {
        let clock = self.clock
        let signal = pollSignal
        let deadline = clock.now().addingTimeInterval(seconds)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await signal.wait(unlessChangedFrom: generation) }
            group.addTask { try? await clock.sleep(until: deadline) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Account → zone → Mac inbox subscriptions. True when iCloud is ready.
    private func setUpCloud(_ cloud: any CloudStore) async -> Bool {
        let status = await cloud.accountStatus()
        if status != accountStatus { logger.notice("iCloud account: \(status.rawValue)") }
        accountStatus = status
        guard status.isAvailable else {
            cloudReady = false
            lastCloudError = status.explanation
            return false
        }
        do throws(CloudError) {
            try await cloud.prepare()
            let tag = try await cloud.accountTag()
            if let previous = state.accountTag, previous != tag {
                logger.notice("another Apple Account: starting over with its iCloud records")
                state.resetForAccount(tag)
                savedReport = nil
                statusSavedAt = nil
            } else if state.accountTag == nil {
                state.accountTag = tag
            }
            persistState()
            try await cloud.ensureSubscription(.macInbox, now: clock.now())
        } catch {
            _ = noteCloudFailure(error)
            logger.notice("iCloud setup failed: \(error)")
            return false
        }
        cloudReady = true
        lastCloudError = nil
        serverHoldUntil = nil
        backgroundHoldUntil = nil
        logger.notice("iCloud ready")
        if state.pendingCloudRemoval {
            if settings.phoneAlerts {
                state.pendingCloudRemoval = false
                persistState()
            } else {
                await removeCloudData()
            }
        }
        return true
    }

    /// `CKAccountChanged`: forget the cached identity and set iCloud up again (a new account resets the state).
    private func accountMayHaveChanged() async {
        guard let cloud, lifecycle == .running else { return }
        logger.notice("the iCloud account may have changed: setting up again")
        await cloud.resetIdentity()
        cloudReady = false
        pollSignal.signal()
    }

    /// One complete fetch since the stored token (from scratch when the token expired). True on success.
    private func fetchChanges(from cloud: any CloudStore) async -> Bool {
        var batch: CloudChangeBatch?
        var fromScratch = false
        for attempt in 0..<2 where batch == nil {
            do throws(CloudError) {
                fromScratch = state.changeToken == nil
                batch = try await cloud.fetchAllChanges(since: state.changeToken, types: [CloudSchema.RecordType.command])
            } catch .changeTokenExpired where attempt == 0 {
                logger.notice("iCloud change token expired: fetching everything again")
                state.changeToken = nil
                persistState()
            } catch {
                _ = noteCloudFailure(error)
                logger.notice("iCloud fetch failed: \(error)")
                return false
            }
        }
        guard let batch else { return false }
        // The iPhones are read whole every round and replace the list: one deleted (a Remove, a prune) leaves it,
        // which a change fetch could never tell (the public database reports no deletions).
        let devices: [CloudItem]
        do throws(CloudError) {
            devices = try await cloud.fetchAll(CloudSchema.RecordType.phoneDevice)
        } catch {
            _ = noteCloudFailure(error)
            logger.notice("iCloud fetch of the iPhones failed: \(error)")
            return false
        }
        replacePhones(devices)
        await apply(batch, cloud: cloud, fromScratch: fromScratch)
        lastCloudError = nil
        return true
    }

    private func replacePhones(_ items: [CloudItem]) {
        var phones: [String: PhoneDevice] = [:]
        for case .device(let device) in items where !CloudSchemaBootstrap.isPlaceholder(.device(device)) {
            if state.phones[device.deviceID] == nil { logger.notice("iPhone connected: \(device.model)") }
            phones[device.deviceID] = device
        }
        for gone in state.phones.keys where phones[gone] == nil { logger.notice("an iPhone left the list") }
        state.phones = phones
    }

    /// Settings → Notifications → an iPhone → Remove: its record leaves iCloud (it comes back if that iPhone opens
    /// the app again).
    public func forgetPhone(deviceID: String) async {
        ensureLoaded()
        state.phones[deviceID] = nil
        persistState()
        guard let cloud, canReachCloud else { return }
        let id = CloudItemID(recordType: CloudSchema.RecordType.phoneDevice, recordName: CloudSchema.RecordNamePrefix.phoneDevice + deviceID)
        do throws(CloudError) {
            try await cloud.delete([id])
            logger.notice("removed an iPhone from iCloud")
        } catch {
            logger.notice("could not remove the iPhone from iCloud: \(error)")
        }
    }

    /// Applies fetched changes: phone devices, commands for this Mac (validated, executed once, deleted). A fetch from
    /// scratch lists every phone that still exists, so the list is rebuilt from it (deleted ones disappear).
    private func apply(_ batch: CloudChangeBatch, cloud: any CloudStore, fromScratch: Bool) async {
        let now = clock.now()
        state.pruneSeenCommands(now: now)
        var handled: [CloudItemID] = []
        var accepted: [RemoteCommand] = []
        var tests = 0
        var refresh = false
        var rejections: [String] = []
        for item in batch.items where !CloudSchemaBootstrap.isPlaceholder(item) {
            switch item {
            case .command(let command):
                if let rejection = command.rejection(forMac: state.macID, now: now) {
                    guard rejection != .otherMac else { continue } // another Mac's: leave it for that Mac
                    logger.notice("ignored iPhone command \(command.request.wireValue): \(rejection.rawValue)")
                    handled.append(item.id)
                    // A button the user tapped gets an answer (the iPhone would otherwise say "received").
                    if command.request != .refreshStatus, settings.phoneAlerts, state.seenCommands[command.id] == nil,
                       let reason = Self.explanation(of: rejection), !rejections.contains(reason) {
                        state.seenCommands[command.id] = max(command.expiresAt, now.addingTimeInterval(CloudSchema.Limits.commandMaximumAge))
                        rejections.append(reason)
                    }
                    continue
                }
                // iPhone alerts off: this Mac isn't on the iPhone any more (its status left iCloud); a tap from an
                // iPhone that still shows it is not acted on.
                guard settings.phoneAlerts else {
                    logger.notice("ignored iPhone command \(command.request.wireValue): iPhone alerts are off")
                    handled.append(item.id)
                    continue
                }
                handled.append(item.id)
                guard state.seenCommands[command.id] == nil else { continue }
                state.seenCommands[command.id] = command.expiresAt
                state.lastCommandAt = now
                logger.notice("iPhone command \(command.request.wireValue) from \(command.deviceName)")
                switch command.request {
                case .keepAwake(let seconds):
                    accepted.append(remote(.keepAwake(seconds: seconds), command: command, now: now))
                case .sleepNow:
                    accepted.append(remote(.sleep, command: command, now: now))
                case .shutDown:
                    accepted.append(remote(.shutdown, command: command, now: now))
                case .sendTest:
                    tests += 1
                case .refreshStatus:
                    refresh = true
                }
            case .alert, .status, .device:
                continue // not fetched here (iPhones are read whole) or written by Macs
            }
        }
        if let token = batch.token { state.changeToken = token }
        // Persist the replay cache BEFORE acting, so a crash cannot run a command twice.
        persistState()
        for command in accepted { commands.yield(command) }
        for reason in rejections {
            deliver(NotificationTemplates.commandIgnored(reason: reason, context: defaultTemplateContext(now: now)))
        }
        if tests > 0 { deliver(NotificationTemplates.test(context: defaultTemplateContext(now: now))) }
        if refresh {
            extendFastPolling(until: now.addingTimeInterval(environment.refreshFastPollWindow), now: now, wake: false)
            await saveStatusNow()
        }
        if !handled.isEmpty {
            do throws(CloudError) {
                try await cloud.delete(handled)
            } catch {
                logger.notice("could not delete \(handled.count) handled command(s): \(error)") // the replay cache covers it
            }
        }
    }

    /// Why a rejected iPhone command was not run, in words (nil: nothing the user can act on).
    static func explanation(of rejection: CloudCommand.Rejection) -> String? {
        switch rejection {
        case .expired, .tooOld: "It reached this Mac too late (the Mac was asleep or offline)"
        case .issuedInFuture: "Your iPhone's clock is ahead of this Mac's. Turn on Set Automatically in Date & Time on both"
        case .missingStateVersion: "Update Kakureneko on your iPhone"
        case .otherMac: nil
        }
    }

    private func remote(_ kind: RemoteCommandKind, command: CloudCommand, now: Date) -> RemoteCommand {
        RemoteCommand(kind: kind, commandID: command.id, stateVersion: command.stateVersion, expiresAt: command.expiresAt,
                      receivedAt: now, source: .phone(name: command.deviceName))
    }

    /// A button on one of this Mac's own notifications.
    private func handleButtonTap(_ tap: AlertPresentation.ButtonTap) {
        let now = clock.now()
        guard tap.macID == state.macID else { return logger.notice("ignored a notification button of another Mac") }
        if let expiresAt = tap.expiresAt, expiresAt <= now { return logger.notice("ignored an expired notification button") }
        let kind: RemoteCommandKind
        switch tap.request {
        case .keepAwake(let seconds): kind = .keepAwake(seconds: seconds)
        case .sleepNow: kind = .sleep
        case .shutDown: kind = .shutdown
        case .sendTest, .refreshStatus: return
        }
        if kind.requiresStateVersionMatch && tap.stateVersion == nil { return logger.notice("ignored a notification button without sv") }
        let commandID = "mac:\(tap.alertID ?? "unknown"):\(tap.request.wireValue)"
        guard state.seenCommands[commandID] == nil else { return }
        let expiresAt = tap.expiresAt ?? now.addingTimeInterval(CloudSchema.Limits.commandMaximumAge)
        state.seenCommands[commandID] = expiresAt
        persistState()
        commands.yield(RemoteCommand(kind: kind, commandID: commandID, stateVersion: tap.stateVersion, expiresAt: expiresAt,
                                     receivedAt: now, source: .macNotification))
    }

    // MARK: - Mac status

    /// iCloud is usable: only while running (after `stop()` nothing is saved: a late task must not overwrite the
    /// final status), set up, with an account.
    private var canReachCloud: Bool { lifecycle == .running && cloud != nil && cloudReady && accountStatus.isAvailable }

    /// The Mac's status goes to iCloud only while "Send alerts to your iPhone" is on: with it off, nothing about this
    /// Mac is stored there.
    private var canSaveStatus: Bool { canReachCloud && settings.phoneAlerts }

    private func scheduleStatusSave(immediately: Bool) {
        if immediately {
            statusTask?.cancel()
            statusTask = Task { [weak self] in await self?.statusTaskFired() }
            return
        }
        guard statusTask == nil else { return }
        let clock = self.clock
        // The deadline is fixed now (not when the task first runs), so a busy machine cannot stretch the debounce.
        let due = clock.now().addingTimeInterval(environment.statusDebounce)
        statusTask = Task { [weak self] in
            do { try await clock.sleep(until: due) } catch { return }
            await self?.statusTaskFired()
        }
    }

    /// The scheduled save (immediate or debounced) runs.
    private func statusTaskFired() async {
        statusTask = nil
        await saveStatus(limit: nil)
    }

    /// A save outside the schedule (heartbeat, drain, refresh, setup): it supersedes a pending scheduled one, which
    /// is cancelled rather than left to save again.
    private func saveStatusNow(limit: TimeInterval? = nil) async {
        statusTask?.cancel()
        statusTask = nil
        await saveStatus(limit: limit)
    }

    /// Saves the latest report as this Mac's `MacStatus` within `limit` seconds (no-op until iCloud is ready;
    /// setup saves it then).
    private func saveStatus(limit: TimeInterval?) async {
        guard let cloud, canSaveStatus, let report = latestReport else { return }
        reportedPhase = report.phase
        let now = clock.now()
        let status = MacStatus(
            macID: state.macID, macName: identity.name, model: identity.model, phase: report.phase, headline: report.headline,
            detail: report.detail, countdownEndsAt: report.countdownEndsAt, keepAwakeUntil: report.keepAwakeUntil,
            agents: report.agents, batteryPercent: report.batteryPercent, onBattery: report.onBattery, lidClosed: report.lidClosed,
            stateVersion: report.stateVersion, keepAwakeSeconds: report.keepAwakeSeconds, shutdownEnabled: report.shutdownEnabled,
            canSleep: report.canSleep, updatedAt: now, appVersion: identity.appVersion)
        switch await Self.save([.status(status)], to: cloud, clock: clock, limit: limit ?? environment.sendTimeout) {
        case .some(.success):
            savedReport = report
            statusSavedAt = now
            statusRetryAt = nil
            // A change that arrived while this save was in flight is saved by the next round.
            if let latestReport, latestReport != report { scheduleStatusSave(immediately: latestReport.phase != report.phase) }
        case .some(.failure(let error)):
            _ = noteCloudFailure(error)
            let wait = error == .quotaExceeded ? environment.quotaRetryInterval : (error.retryAfter ?? 60)
            statusRetryAt = now.addingTimeInterval(wait)
            logger.notice("could not save the Mac status: \(error)")
        case .none:
            statusRetryAt = now.addingTimeInterval(60)
            logger.notice("saving the Mac status timed out")
        }
    }

    // MARK: - Pruning

    /// At most every `pruneInterval`, deletes by age on the server (any Mac's or iPhone's, so records whose writer
    /// is gone go too): alerts past the iPhone's 3-day window (plus half a day), commands no Mac read within
    /// `commandRetention`, and Mac statuses and iPhones not saved for `deviceRetention`. Also while iPhone alerts are
    /// off.
    private func pruneIfDue(now: Date) async {
        guard let cloud, canReachCloud else { return }
        if let last = state.lastPrunedAt, now.timeIntervalSince(last) < environment.pruneInterval { return }
        state.lastPrunedAt = now
        let rules: [(String, TimeInterval)] = [
            (CloudSchema.RecordType.alert, environment.alertRetention + environment.alertPruneMargin),
            (CloudSchema.RecordType.command, environment.commandRetention),
            (CloudSchema.RecordType.macStatus, environment.deviceRetention),
            (CloudSchema.RecordType.phoneDevice, environment.deviceRetention),
        ]
        var removed = 0
        for (recordType, age) in rules {
            do throws(CloudError) {
                removed += try await cloud.deleteOwned(recordType, modifiedBefore: now.addingTimeInterval(-age))
            } catch {
                logger.notice("could not prune old \(recordType) records: \(error)")
            }
        }
        let cutoff = now.addingTimeInterval(-(environment.alertRetention + environment.alertPruneMargin))
        state.savedAlerts.removeAll { $0.createdAt < cutoff }
        if removed > 0 { logger.info("pruned \(removed) old record(s) from iCloud") }
        persistState()
    }

    /// iPhone alerts turned off (also Uninstall's first step): this Mac's status and every alert it saved leave
    /// iCloud, within `sendTimeout`. Alerts that couldn't be deleted stay listed; the prune removes them later.
    private func removeCloudData() async {
        statusTask?.cancel()
        statusTask = nil
        guard let cloud, canReachCloud else {
            // Done as soon as iCloud is back (setUpCloud), unless iPhone alerts are on again by then.
            state.pendingCloudRemoval = cloud != nil
            persistState()
            return
        }
        let alertIDs = state.savedAlerts.map(\.id)
        let status = CloudItemID(recordType: CloudSchema.RecordType.macStatus,
                                 recordName: CloudSchema.RecordNamePrefix.macStatus + state.macID)
        let items = alertIDs.map(CloudItemID.alert) + [status]
        switch await Self.bounded(clock: clock, limit: environment.sendTimeout, { () async throws(CloudError) in
            try await cloud.delete(items)
        }) {
        case .some(.success):
            let removed = Set(alertIDs)
            state.savedAlerts.removeAll { removed.contains($0.id) }
            state.pendingCloudRemoval = false
            savedReport = nil
            statusSavedAt = nil
            logger.notice("removed this Mac's status and \(alertIDs.count) alert(s) from iCloud")
        case .some(.failure(let error)):
            logger.notice("could not remove this Mac's records from iCloud: \(error)")
        case .none:
            logger.notice("removing this Mac's records from iCloud timed out")
        }
        persistState()
    }

    // MARK: - Persistence

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        let now = clock.now()
        state = store.loadState()
        if let machine = environment.machineMacID(), machine != state.macID {
            // One id per machine and user (MachineIdentity): reinstalls and wiped state keep it.
            state.macID = machine
        }
        state.pruneSeenCommands(now: now)
        outbox = Outbox(items: store.loadOutbox())
        let expired = outbox.removeExpired(now: now)
        if !expired.isEmpty { persistOutbox() }
        if store.removeLegacySecrets() { logger.notice("removed the ntfy secrets of an earlier version") }
        persistState() // a new Mac id is written at once
    }

    private func persistOutbox() {
        do {
            try store.saveOutbox(outbox.items)
        } catch {
            logger.error("could not write the outbox: \(type(of: error))")
        }
    }

    private func persistState() {
        do {
            try store.saveState(state)
        } catch {
            logger.error("could not write notify state: \(type(of: error))")
        }
    }
}

// MARK: - Test and diagnostics hooks (internal)

extension NotificationDispatcher {
    /// Items currently queued (tests).
    var outboxItemsForTesting: [OutboxItem] { outbox.items }
    /// Messages folded by the rate limit and not yet sent as a digest (tests).
    var digestCountForTesting: Int { policy.digestCount }
    /// This Mac's id (tests; loads the persisted state first, like every public entry point).
    var macIDForTesting: String {
        ensureLoaded()
        return state.macID
    }
    /// iCloud set up during this launch (tests).
    var cloudReadyForTesting: Bool { cloudReady }
    /// Current poll interval (tests).
    var pollIntervalForTesting: TimeInterval { currentPollInterval() }
}
