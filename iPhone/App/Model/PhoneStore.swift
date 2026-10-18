// The iPhone app's model (docs/IPHONE-APP.md, docs/NATIVE-NOTIFICATIONS.md §5): one main-actor object that owns
// the `CloudStore` and everything the screens show.
//
//   * Sync: account check → prepare + `alerts-v1` / `phone-statuses-v1` subscriptions (re-ensured daily) → changes since the
//     persisted token, applied to `ZoneSnapshot` (zone loss and expired tokens refetch from scratch; network errors
//     back off). Runs on launch, on every return to the foreground, in the foreground every 5 s while a command
//     waits for its Mac (else every 20 s), on each `phone-statuses-v1` silent push and on pull-to-refresh.
//   * Commands: built with this phone's identity and the status / alert `sv`, written ahead into a persistent queue,
//     saved, and retried on the next launch / foreground while not expired. `FeedbackBoard` turns the zone's
//     reaction into "sent → done / didn't respond".
//   * This phone: its `PhoneDevice` record (launch, permission changes, else every 6 h) and the notification
//     categories (titled with the latest status' keep-awake duration).
//
// Views read it from the environment; `AppDelegate` drives it from pushes and notification taps. Every dependency
// (CloudStore, clock, cache file, defaults, device, notification center) is injected: tests and previews run it on
// `InMemoryCloudStore` and `RecordingNotificationCenter`.

import KakurenekoCloud
import Foundation
import Observation
import os
import UserNotifications

private let log = Logger(subsystem: "com.kakureneko.Kakureneko", category: "PhoneStore")

/// The tabs of the main screen.
enum MainTab: Hashable, Sendable {
    case macs, activity, settings
}

/// What became of a command.
enum CommandResult: Equatable, Sendable {
    case sent
    /// Kept in the queue (iCloud unreachable); retried later.
    case queued
    case failed
    /// The tapped notification's buttons had already expired: nothing was sent.
    case expired
}

@MainActor
@Observable
final class PhoneStore {
    enum Timing {
        static let foregroundPoll: Duration = .seconds(5)
        /// With nothing waiting for a Mac, only every this many polls fetch (status changes also arrive by push;
        /// the public database's request budget is shared by every user).
        static let idlePollEvery = 4
        /// Opening the app asks Macs with an older status to republish it.
        static let refreshStatusOlderThan: TimeInterval = 60
        /// In-app commands (and taps on alerts without an expiry) are honoured this long.
        static let commandLifetime: TimeInterval = 10 * 60
        /// The zone and subscriptions are re-ensured this often (and whenever the zone went missing).
        static let setupValidity: TimeInterval = 24 * 3600
        static let maximumFetchRounds = 10
        static let maximumPendingCommands = 50
        /// A Mac that hasn't saved its status for this long moves to "Not seen recently" (Remove).
        static let formerMacAfter: TimeInterval = 7 * 24 * 3600
        /// Macs silent for longer aren't asked to republish their status on every open.
        static let refreshSkipAfter: TimeInterval = 24 * 3600
        /// Old records are pruned from iCloud at most this often (the Macs do it too; this covers no Mac left).
        static let pruneInterval: TimeInterval = 24 * 3600
        static let alertPruneAge: TimeInterval = ZoneSnapshot.alertRetention + 12 * 3600
        static let commandPruneAge: TimeInterval = 3600
        static let devicePruneAge: TimeInterval = 30 * 24 * 3600
        /// How far the public database's query index can lag behind a save.
        static let queryIndexLag: TimeInterval = 10
    }

    // MARK: State the screens observe

    /// iCloud account (nil until checked).
    private(set) var account: CloudAccountStatus?
    private(set) var connection: ConnectionState = .unknown
    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?
    private(set) var zone: ZoneSnapshot
    /// Commands waiting for iCloud, oldest first.
    private(set) var pendingCommands: [CloudCommand]
    private(set) var feedback = FeedbackBoard()
    /// Notification permission (nil until read).
    private(set) var notificationAuthorization: NotificationAuthorization?
    /// The 5-second foreground poll is running.
    private(set) var isPolling = false
    private(set) var hasCompletedOnboarding: Bool
    var selectedTab: MainTab = .macs
    /// A Mac a notification tap asked to show; the Macs tab navigates to it and clears it.
    var requestedMacID: String?

    /// This iPhone (its `PhoneDevice` record and the name on its commands).
    let device: DeviceInfo
    /// This install's random id.
    let deviceID: String

    // MARK: Dependencies

    @ObservationIgnored private let cloud: any CloudStore
    @ObservationIgnored private let clock: PhoneClock
    @ObservationIgnored private let cacheFile: PhoneCacheFile
    @ObservationIgnored private let preferences: PhonePreferences
    @ObservationIgnored private let notifications: any NotificationCenterClient

    // MARK: Bookkeeping

    /// Token of the last applied fetch (readable for diagnostics and tests).
    @ObservationIgnored private(set) var changeToken: CloudChangeToken?
    @ObservationIgnored private var setupCompletedAt: Date?
    /// The Apple Account the cached data belongs to (another one found at sync time starts over).
    @ObservationIgnored private var accountTag: String?
    @ObservationIgnored private var deviceRecord: DeviceRecordStamp?
    /// The first foreground activation of this process still has to save the device record.
    @ObservationIgnored private var launchSavePending = true
    @ObservationIgnored private var isSavingDevice = false
    @ObservationIgnored private var backoff = RetryBackoff()
    @ObservationIgnored private var syncTask: Task<SyncOutcome, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// The Keep awake duration the registered categories carry (nil inside: a neutral title); nil: not registered.
    @ObservationIgnored private var registeredKeepAwakeSeconds: Int??
    @ObservationIgnored private var refreshRequestedAt: [String: Date] = [:]
    /// Commands awaiting their Mac that a fetch has seen in iCloud (gone afterwards = handled).
    @ObservationIgnored private var commandsSeenInCloud = Set<String>()
    @ObservationIgnored private var isRetryingPending = false
    /// Commands being saved right now (the retry loop skips them).
    @ObservationIgnored private var inFlight: Set<String> = []
    /// Button taps whose outcome the user has not been told yet, with the notice to post if they fail.
    @ObservationIgnored private var tapsAwaitingOutcome: [String: LocalNotice] = [:]

    init(cloud: any CloudStore, clock: PhoneClock = .system, cacheFile: PhoneCacheFile, defaults: UserDefaults,
         persistentID: (any DeviceIDStoring)? = nil, device: DeviceInfo, notifications: any NotificationCenterClient) {
        self.cloud = cloud
        self.clock = clock
        self.cacheFile = cacheFile
        self.notifications = notifications
        self.device = device
        preferences = PhonePreferences(defaults: defaults, persistentID: persistentID)
        deviceID = preferences.deviceID()
        hasCompletedOnboarding = preferences.onboardingComplete
        let cache = cacheFile.load()
        zone = ZoneSnapshot(statuses: cache.statuses, alerts: cache.alerts, now: clock.now())
        pendingCommands = cache.pendingCommands
        changeToken = cache.changeToken
        deviceRecord = cache.deviceRecord
        setupCompletedAt = cache.setupCompletedAt
        accountTag = cache.accountTag
    }

    // MARK: - Reading

    /// The Macs that saved their status in the last week, by name: the ones the app shows and talks to.
    var macs: [MacStatus] { sortedMacs.filter { !isFormer($0) } }

    /// Macs not seen for a week (uninstalled, sold, a Mac that is off for good): listed apart, with Remove.
    var formerMacs: [MacStatus] { sortedMacs.filter(isFormer) }

    private var sortedMacs: [MacStatus] {
        zone.statuses.values.sorted {
            let order = $0.macName.localizedStandardCompare($1.macName)
            return order == .orderedSame ? $0.macID < $1.macID : order == .orderedAscending
        }
    }

    private func isFormer(_ status: MacStatus) -> Bool {
        clock.now().timeIntervalSince(status.updatedAt) > Timing.formerMacAfter
    }

    /// Recent alerts, newest first.
    var alerts: [CloudAlert] { zone.alerts }

    func status(for macID: String) -> MacStatus? { zone.statuses[macID] }

    /// The feedback line to show for `macID` / `channel` at `now`, if any.
    func visibleFeedback(for macID: String, channel: FeedbackChannel, at now: Date) -> CommandFeedback? {
        feedback[FeedbackSlot(macID: macID, channel: channel)].flatMap { $0.isVisible(at: now) ? $0 : nil }
    }

    // MARK: - Lifecycle

    /// Process launch (in the foreground, or in the background for a push or a notification button).
    func start() async {
        registerCategoriesIfNeeded()
        await retryPendingCommands()
    }

    /// The app came to the foreground (also right after a foreground launch).
    func sceneDidBecomeActive() async {
        startPolling()
        await refreshNotificationAuthorization()
        await refreshAccount()
        await sync(force: true)
        await retryPendingCommands()
        await saveDeviceRecordIfNeeded()
        await requestStatusRefresh()
        await pruneIfDue()
    }

    /// The app went to the background: no polling there (silent pushes still sync).
    func sceneDidEnterBackground() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
    }

    /// Pull to refresh.
    func refresh() async {
        if account != .available { await refreshAccount() }
        await sync(force: true)
        await retryPendingCommands()
        await requestStatusRefresh()
    }

    /// A `phone-statuses-v1` silent push. Also keeps this iPhone's record fresh (at most every 6 h), so the Mac sees a
    /// phone that gets alerts but is rarely opened as still here.
    func handleZonePush() async -> SyncOutcome {
        let outcome = await sync(force: true)
        await refreshNotificationAuthorization()
        await saveDeviceRecordIfNeeded()
        return outcome
    }

    /// `CKAccountChanged`: possibly another Apple Account. Starts over from scratch (the next full fetch replaces
    /// the cached Macs and alerts).
    func accountDidChange() async {
        await cloud.resetIdentity()
        changeToken = nil
        setupCompletedAt = nil
        // What belonged to the previous account: its queued taps, its device stamp (save this iPhone again).
        pendingCommands = []
        deviceRecord = nil
        feedback = FeedbackBoard()
        backoff.reset()
        connection = .unknown
        persist()
        await refreshAccount()
        await sync(force: true)
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        preferences.onboardingComplete = true
    }

    /// "Not seen recently" → Remove: the Mac's status leaves iCloud and the list (a Mac that runs Kakureneko again
    /// comes back with its next status).
    func removeMac(_ macID: String) async {
        var next = zone
        next.removeStatus(macID)
        zone = next
        persist()
        let id = CloudItemID(recordType: CloudSchema.RecordType.macStatus, recordName: CloudSchema.RecordNamePrefix.macStatus + macID)
        do throws(CloudError) {
            try await cloud.delete([id])
        } catch {
            log.notice("could not remove the Mac from iCloud: \(error.description, privacy: .public)")
        }
    }

    /// At most daily: deletes by server age what nobody needs any more (alerts past the Activity window, commands no
    /// Mac read, Macs and iPhones not seen for a month), also when no Mac is left to do it.
    func pruneIfDue() async {
        guard account == .available else { return }
        let now = clock.now()
        if let last = preferences.lastPrunedAt, now.timeIntervalSince(last) < Timing.pruneInterval { return }
        preferences.lastPrunedAt = now
        let rules: [(String, TimeInterval)] = [
            (CloudSchema.RecordType.alert, Timing.alertPruneAge), (CloudSchema.RecordType.command, Timing.commandPruneAge),
            (CloudSchema.RecordType.macStatus, Timing.devicePruneAge), (CloudSchema.RecordType.phoneDevice, Timing.devicePruneAge),
        ]
        for (recordType, age) in rules {
            do throws(CloudError) {
                _ = try await cloud.deleteOwned(recordType, modifiedBefore: now.addingTimeInterval(-age))
            } catch {
                log.notice("could not prune old \(recordType, privacy: .public) records: \(error.description, privacy: .public)")
            }
        }
        if let superseded = preferences.supersededDeviceID {
            let id = CloudItemID(recordType: CloudSchema.RecordType.phoneDevice, recordName: CloudSchema.RecordNamePrefix.phoneDevice + superseded)
            if (try? await cloud.delete([id])) != nil { preferences.supersededDeviceID = nil }
        }
    }

    /// A tap on a notification: show that Mac.
    func open(macID: String?) {
        selectedTab = .macs
        if let macID, zone.statuses[macID] != nil { requestedMacID = macID }
    }

    /// One foreground poll: sync (unless backing off), time out feedback, flush the queue once iCloud answers.
    func pollTick() async {
        let outcome = await sync()
        evaluateFeedback()
        if outcome == .changed || outcome == .unchanged, !pendingCommands.isEmpty { await retryPendingCommands() }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        isPolling = true
        pollTask = Task { [weak self] in
            var skipped = 0
            while true {
                try? await Task.sleep(for: Timing.foregroundPoll)
                guard !Task.isCancelled, let self else { return }
                if !self.needsFastPolling && skipped + 1 < Timing.idlePollEvery {
                    skipped += 1
                    continue
                }
                skipped = 0
                await self.pollTick()
            }
        }
    }

    /// A command is on its way (or queued, or waiting for its Mac's answer): poll every 5 s.
    private var needsFastPolling: Bool {
        !pendingCommands.isEmpty || feedback.entries.values.contains { $0.isPending }
            || !feedback.awaitingCommands(at: clock.now()).isEmpty
    }

    // MARK: - Account

    func refreshAccount() async {
        apply(account: await cloud.accountStatus())
    }

    private func apply(account status: CloudAccountStatus) {
        let previous = account
        account = status
        guard status != previous else { return }
        switch status {
        case .noAccount:
            forgetAccountData()
        case .available where previous != nil:
            setupCompletedAt = nil // signed in again: ensure the zone and subscriptions now
        default:
            break
        }
    }

    /// Signed out: the cached Macs, alerts and queued commands belong to that account.
    private func forgetAccountData() {
        changeToken = nil
        setupCompletedAt = nil
        deviceRecord = nil
        zone = ZoneSnapshot(now: clock.now())
        pendingCommands = []
        feedback = FeedbackBoard()
        persist()
    }

    // MARK: - Sync

    /// Fetches and applies zone changes. Concurrent calls share one fetch. Without `force`, does nothing while
    /// backing off after a failure.
    @discardableResult
    func sync(force: Bool = false) async -> SyncOutcome {
        if let running = syncTask { return await running.value }
        let task = Task { await performSync(force: force) }
        syncTask = task
        return await task.value
    }

    private func performSync(force: Bool) async -> SyncOutcome {
        defer {
            syncTask = nil
            if isSyncing { isSyncing = false }
        }
        if !force, let retryAt = connection.retryAt, clock.now() < retryAt { return .skipped }
        // Unknown, or iCloud could not answer last time: ask again (a push or a poll must not stay stuck on it).
        if account == nil || account == .couldNotDetermine || account == .temporarilyUnavailable { await refreshAccount() }
        guard account == .available else { return .unavailable }
        isSyncing = true
        do throws(CloudError) {
            try await checkAccountTag()
            try await ensureSetUp()
            let changed = try await fetchChanges()
            backoff.reset()
            if connection != .online { connection = .online }
            lastSyncedAt = clock.now()
            return changed ? .changed : .unchanged
        } catch {
            record(error)
            return .failed
        }
    }

    /// The cache belongs to one Apple Account. Another one (switched while the app was not running, so no
    /// `CKAccountChanged` reached it) starts over: its subscriptions, Macs and alerts are not the cached ones.
    private func checkAccountTag() async throws(CloudError) {
        let tag = try await cloud.accountTag()
        guard tag != accountTag else { return }
        if accountTag != nil {
            log.notice("another Apple Account: starting over with its iCloud records")
            forgetAccountData()
        }
        accountTag = tag
        persist()
    }

    /// Creates the zone and both subscriptions (bootstrapping a fresh development schema) unless done recently.
    private func ensureSetUp() async throws(CloudError) {
        let now = clock.now()
        if let done = setupCompletedAt, done <= now, now.timeIntervalSince(done) < Timing.setupValidity { return }
        try await cloud.prepare()
        try await cloud.ensureSubscription(.alerts, now: now)
        try await cloud.ensureSubscription(.phoneInbox, now: now)
        setupCompletedAt = now
        persist()
    }

    /// Fetches since the token; recovers once from a lost zone (recreate, refetch everything) or an expired token.
    private func fetchChanges() async throws(CloudError) -> Bool {
        var recovered = false
        while true {
            do throws(CloudError) {
                return try await fetchAllRounds()
            } catch .zoneMissing where !recovered {
                recovered = true
                log.notice("the Kakureneko zone is gone: recreating it and fetching from scratch")
                changeToken = nil
                setupCompletedAt = nil
                try await ensureSetUp()
            } catch .changeTokenExpired where !recovered {
                recovered = true
                log.notice("change token expired: fetching from scratch")
                changeToken = nil
            }
        }
    }

    /// Alerts since the token; the Macs' statuses read whole (they replace the list, so a Mac that left iCloud
    /// leaves it: the public database reports no deletions); and, while a tap waits for its Mac, the commands, to
    /// tell "the Mac took it" (it deletes a command once handled).
    private func fetchAllRounds() async throws(CloudError) -> Bool {
        let fromScratch = changeToken == nil
        var items: [CloudItem] = []
        var deleted: [CloudItemID] = []
        var token = changeToken
        for _ in 0..<Timing.maximumFetchRounds {
            let batch = try await cloud.fetchAllChanges(since: token, types: [CloudSchema.RecordType.alert])
            items += batch.items
            deleted += batch.deleted
            token = batch.token ?? token
            if !batch.moreComing { break }
        }
        let statuses = try await cloud.fetchAll(CloudSchema.RecordType.macStatus)
        var handled = Set<String>()
        let awaiting = feedback.awaitingCommands(at: clock.now())
        if !awaiting.isEmpty {
            let inCloud = Set(try await cloud.fetchAll(CloudSchema.RecordType.command).compactMap { item -> String? in
                if case .command(let command) = item { command.id } else { nil }
            })
            // Gone from iCloud: the Mac took it. Unless just saved: the query index lags a few seconds behind a save,
            // so a command not seen there yet counts only once it is older than that (or was seen before).
            let settled = Set(awaiting.filter { clock.now().timeIntervalSince($0.value) >= Timing.queryIndexLag }.keys)
            handled = settled.union(commandsSeenInCloud).intersection(awaiting.keys).subtracting(inCloud)
            commandsSeenInCloud = commandsSeenInCloud.union(inCloud).intersection(awaiting.keys)
        } else {
            commandsSeenInCloud = []
        }
        return apply(items, deleted: deleted, statuses: statuses, handled: handled, fromScratch: fromScratch, token: token)
    }

    /// Applies fetched changes; returns whether any status or alert changed.
    private func apply(_ items: [CloudItem], deleted: [CloudItemID], statuses: [CloudItem], handled: Set<String>,
                       fromScratch: Bool, token: CloudChangeToken?) -> Bool {
        let now = clock.now()
        var next = zone
        var handledCommands = next.apply(items, deleted: deleted, fromScratch: fromScratch, now: now)
        next.replaceStatuses(statuses)
        handledCommands.formUnion(handled)
        let changed = next != zone
        if changed { zone = next }
        let tokenChanged = token != changeToken
        changeToken = token
        if !handledCommands.isEmpty { updateFeedback { $0.commandsHandled(handledCommands, at: now) } }
        evaluateFeedback()
        registerCategoriesIfNeeded()
        if changed || tokenChanged { persist() }
        if changed { Task { await withdrawResolvedAlerts() } }
        return changed
    }

    /// Takes alerts out of Notification Center once their Mac reported that they are over (a cancelled countdown, a
    /// shutdown called off, no agent waiting any more), so their buttons don't linger after the Mac or another
    /// device dealt with them. Only a status saved after the alert decides.
    func withdrawResolvedAlerts() async {
        let delivered = await notifications.deliveredAlerts()
        let alerts = Dictionary(zone.alerts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let resolved = delivered.filter { item in
            guard let alert = alerts[item.alertID], let status = zone.statuses[item.macID],
                  status.updatedAt > alert.createdAt else { return false }
            switch item.kind {
            case AlertKind.countdown: return status.phase != .countdown
            case AlertKind.shuttingDown: return status.phase != .shutdownPending && status.phase != .windingDown
            case AlertKind.needsInput: return !status.agents.contains { $0.activity == .waiting }
            default: return false
            }
        }
        notifications.removeDelivered(identifiers: resolved.map(\.identifier))
    }

    private func record(_ error: CloudError) {
        let now = clock.now()
        log.notice("sync failed: \(error.description, privacy: .public)")
        switch error {
        case .notSignedIn:
            apply(account: .noAccount)
            connection = .unknown
        case .network, .rateLimited:
            connection = .offline(retryAt: now.addingTimeInterval(backoff.nextDelay(hint: error.retryAfter)))
        case .zoneMissing, .changeTokenExpired, .quotaExceeded, .unknownRecordType, .permanent:
            connection = .failed(message: error.userMessage, retryAt: now.addingTimeInterval(backoff.nextDelay(hint: nil)))
        }
    }

    // MARK: - Commands

    func keepAwake(macID: String) async {
        guard let status = zone.statuses[macID], presentation(of: status).canKeepAwake else { return }
        await send(.keepAwake(seconds: status.keepAwakeSeconds), to: status, channel: .controls)
    }

    func sleepNow(macID: String) async {
        guard let status = zone.statuses[macID], presentation(of: status).canSleep else { return }
        await send(.sleepNow, to: status, channel: .controls)
    }

    func shutDown(macID: String) async {
        guard let status = zone.statuses[macID], presentation(of: status).canShutDown else { return }
        await send(.shutDown, to: status, channel: .controls)
    }

    /// Asks every Mac to send a test notification.
    func sendTestAlert() async {
        for status in macs { await send(.sendTest, to: status, channel: .test) }
    }

    /// A command from this phone, issued now; it expires with the alert it answers, else after `commandLifetime`.
    func makeCommand(_ request: CloudRequest, macID: String, stateVersion: Int?, alertID: String? = nil,
                     expiresAt: Date? = nil) -> CloudCommand {
        let now = clock.now()
        return CloudCommand(macID: macID, request: request, stateVersion: stateVersion, alertID: alertID, issuedAt: now,
                            expiresAt: expiresAt ?? now.addingTimeInterval(Timing.commandLifetime),
                            deviceID: deviceID, deviceName: device.name)
    }

    /// The command a notification button sends (the alert's `sv`, id and expiry).
    func command(for tap: AlertPresentation.ButtonTap) -> CloudCommand {
        makeCommand(tap.request, macID: tap.macID, stateVersion: tap.stateVersion, alertID: tap.alertID, expiresAt: tap.expiresAt)
    }

    /// A button on a notification (the app delegate runs this inside a background task). On failure the command
    /// stays queued and a local notification asks the user to open the app.
    @discardableResult
    func handleButtonTap(_ tap: AlertPresentation.ButtonTap, macName: String?) async -> CommandResult {
        let name = macName ?? zone.statuses[tap.macID]?.macName ?? "your Mac"
        if let expiresAt = tap.expiresAt, expiresAt <= clock.now() {
            notifications.post(.expiredAlert(macID: tap.macID, macName: name))
            return .expired
        }
        let command = command(for: tap)
        tapsAwaitingOutcome[command.id] = .couldNotReach(macID: tap.macID, macName: name)
        let result = await deliver(command, slot: FeedbackSlot(macID: tap.macID, channel: .controls), queueOnFailure: true)
        // Already reported if the background task expired while this was saving.
        if let notice = tapsAwaitingOutcome.removeValue(forKey: command.id), result != .sent { notifications.post(notice) }
        return result
    }

    /// The background task around a button tap is about to expire: tell the user about every tap still being
    /// saved (each stays queued and is retried when the app runs again).
    func backgroundTimeWillExpire() {
        for notice in tapsAwaitingOutcome.values { notifications.post(notice) }
        tapsAwaitingOutcome = [:]
    }

    /// Saves every queued command that is still valid, oldest first; stops at the first sign iCloud is unreachable.
    func retryPendingCommands() async {
        guard !isRetryingPending, !pendingCommands.isEmpty else { return }
        isRetryingPending = true
        defer { isRetryingPending = false }
        dropUndeliverablePendingCommands()
        for command in pendingCommands where !inFlight.contains(command.id) {
            inFlight.insert(command.id)
            defer { inFlight.remove(command.id) }
            do throws(CloudError) {
                try await saveCommand(command)
                dequeue(command.id)
                markSent(command)
            } catch {
                log.notice("queued \(command.request.wireValue, privacy: .public) still unsent: \(error.description, privacy: .public)")
                if error.isWorthRetryingLater { return }
                dequeue(command.id)
                updateFeedback { $0.update(commandID: command.id, to: .failed(error.userMessage), at: clock.now()) }
            }
        }
    }

    /// Opening the app (or pulling to refresh) asks every Mac whose status is older than a minute to republish it.
    func requestStatusRefresh() async {
        guard account == .available else { return }
        let now = clock.now()
        // Not Macs that went quiet for a day or are asleep or off: the request would wait unanswered.
        for status in macs where now.timeIntervalSince(status.updatedAt) > Timing.refreshStatusOlderThan
            && now.timeIntervalSince(status.updatedAt) < Timing.refreshSkipAfter
            && !MacStatusPresentation(status: status, now: now).isDormant {
            if let last = refreshRequestedAt[status.macID], now.timeIntervalSince(last) < Timing.refreshStatusOlderThan { continue }
            refreshRequestedAt[status.macID] = now
            let command = makeCommand(.refreshStatus, macID: status.macID, stateVersion: status.stateVersion)
            await deliver(command, slot: nil, queueOnFailure: false)
        }
    }

    private func send(_ request: CloudRequest, to status: MacStatus, channel: FeedbackChannel) async {
        let command = makeCommand(request, macID: status.macID, stateVersion: status.stateVersion)
        await deliver(command, slot: FeedbackSlot(macID: status.macID, channel: channel), queueOnFailure: true)
    }

    /// Saves `command`, written ahead into the queue when `queueOnFailure` so a failure (or the process being
    /// suspended mid-save) keeps it for a retry. Saving the same command twice is harmless: the Mac's replay cache
    /// runs a command id once.
    @discardableResult
    private func deliver(_ command: CloudCommand, slot: FeedbackSlot?, queueOnFailure: Bool) async -> CommandResult {
        if let slot { updateFeedback { $0.begin(command, in: slot, at: clock.now()) } }
        if queueOnFailure { enqueue(command) }
        inFlight.insert(command.id)
        defer { inFlight.remove(command.id) }
        do throws(CloudError) {
            try await saveCommand(command)
            dequeue(command.id)
            markSent(command)
            return .sent
        } catch {
            log.notice("could not send \(command.request.wireValue, privacy: .public): \(error.description, privacy: .public)")
            if queueOnFailure && error.isWorthRetryingLater {
                updateFeedback { $0.update(commandID: command.id, to: .queued, at: clock.now()) }
                return .queued
            }
            dequeue(command.id)
            updateFeedback { $0.update(commandID: command.id, to: .failed(error.userMessage), at: clock.now()) }
            return .failed
        }
    }

    /// Saves one command; a missing zone is recreated once.
    private func saveCommand(_ command: CloudCommand) async throws(CloudError) {
        do throws(CloudError) {
            try await cloud.save([.command(command)])
        } catch .zoneMissing {
            changeToken = nil
            setupCompletedAt = nil
            try await ensureSetUp()
            try await cloud.save([.command(command)])
        }
    }

    /// The command reached iCloud: from now on a change of the Mac's state confirms it.
    private func markSent(_ command: CloudCommand) {
        let baseline = zone.statuses[command.macID].map(StatusFingerprint.init)
        updateFeedback { $0.markSent(commandID: command.id, baseline: baseline, at: clock.now()) }
    }

    private func enqueue(_ command: CloudCommand) {
        guard !pendingCommands.contains(where: { $0.id == command.id }) else { return }
        pendingCommands.append(command)
        if pendingCommands.count > Timing.maximumPendingCommands {
            pendingCommands.removeFirst(pendingCommands.count - Timing.maximumPendingCommands)
        }
        persist()
    }

    private func dequeue(_ commandID: String) {
        guard let index = pendingCommands.firstIndex(where: { $0.id == commandID }) else { return }
        pendingCommands.remove(at: index)
        persist()
    }

    /// Drops queued commands the Mac would reject anyway (expired, or issued too long ago).
    private func dropUndeliverablePendingCommands() {
        let now = clock.now()
        let dropped = pendingCommands.filter { $0.rejection(forMac: $0.macID, now: now) != nil }
        guard !dropped.isEmpty else { return }
        let droppedIDs = Set(dropped.map(\.id))
        pendingCommands.removeAll { droppedIDs.contains($0.id) }
        persist()
        log.notice("dropped \(dropped.count) expired queued command(s)")
        updateFeedback { board in
            for command in dropped {
                board.update(commandID: command.id, to: .failed("It expired before iCloud could be reached."), at: now)
            }
        }
    }

    // MARK: - Feedback

    private func evaluateFeedback() {
        updateFeedback { $0.evaluate(zone, now: clock.now()) }
    }

    /// Mutates a copy and publishes it only when it changed (keeps the 5-second poll from redrawing the screens).
    private func updateFeedback(_ change: (inout FeedbackBoard) -> Void) {
        var board = feedback
        change(&board)
        if board != feedback { feedback = board }
    }

    // MARK: - This iPhone

    func refreshNotificationAuthorization() async {
        let current = await notifications.authorization()
        if current != notificationAuthorization { notificationAuthorization = current }
    }

    /// Shows the system prompt (onboarding / Settings) and tells the Mac the outcome.
    func requestNotificationAuthorization() async {
        notificationAuthorization = await notifications.requestAuthorization()
        await saveDeviceRecordIfNeeded()
    }

    /// Saves the `PhoneDevice` record when `DeviceRecordPolicy` says so.
    func saveDeviceRecordIfNeeded() async {
        guard account == .available, let authorization = notificationAuthorization, !isSavingDevice else { return }
        let now = clock.now()
        guard DeviceRecordPolicy.isDue(last: deviceRecord, authorization: authorization, device: device,
                                       launchPending: launchSavePending, now: now) else { return }
        isSavingDevice = true
        defer { isSavingDevice = false }
        let record = PhoneDevice(deviceID: deviceID, name: device.name, model: device.model, systemVersion: device.systemVersion,
                                 appVersion: device.appVersion, alertsAuthorized: authorization.alertsAllowed,
                                 timeSensitiveAllowed: authorization.timeSensitive, lastSeenAt: now)
        do throws(CloudError) {
            try await cloud.save([.device(record)])
            deviceRecord = DeviceRecordStamp(savedAt: now, authorization: authorization, device: device)
            launchSavePending = false
            persist()
        } catch {
            log.notice("could not save the device record: \(error.description, privacy: .public)")
        }
    }

    /// Registers the notification buttons (at launch, and whenever the Macs' keep-awake duration changes, since the
    /// Keep awake button's title carries it). Categories are shared by every Mac: Macs set to different durations
    /// get a plain "Keep awake" (each tap still sends its own alert's duration).
    func registerCategoriesIfNeeded() {
        let durations = Set(macs.map(\.keepAwakeSeconds))
        let seconds: Int? = switch durations.count {
        case 0: zone.latestStatus?.keepAwakeSeconds ?? ZoneSnapshot.defaultKeepAwakeSeconds
        case 1: durations.first
        default: nil
        }
        guard registeredKeepAwakeSeconds != .some(seconds) else { return }
        registeredKeepAwakeSeconds = seconds
        notifications.setCategories(AlertPresentation.categories(keepAwakeSeconds: seconds))
    }

    // MARK: - Helpers

    func presentation(of status: MacStatus) -> MacStatusPresentation {
        MacStatusPresentation(status: status, now: clock.now())
    }

    private func persist() {
        let cache = PhoneCache(changeToken: changeToken,
                               statuses: zone.statuses.values.sorted { $0.macID < $1.macID },
                               alerts: zone.alerts, pendingCommands: pendingCommands, deviceRecord: deviceRecord,
                               setupCompletedAt: setupCompletedAt, accountTag: accountTag)
        do {
            try cacheFile.save(cache)
        } catch {
            log.error("could not write the cache: \(error.localizedDescription, privacy: .public)")
        }
    }
}
