import KakurenekoCloud
@testable import KakurenekoNotify
import KakurenekoKit
import Foundation
import Synchronization
import Testing

/// Delivery through the dispatcher: both channels (Mac notification at once, iCloud through the outbox), retry
/// classes, persistence across relaunches, TTL, drain(deadline:). iCloud is `InMemoryCloudStore` only.
@Suite("Delivery and outbox", .timeLimit(.minutes(1)))
struct DeliveryTests {
    static func stalled(_ id: String = "c-1") -> NotificationIntent {
        .stalled(SessionEffect(kind: .stalled, session: Fixtures.claude(id: id), at: Fixtures.start))
    }

    func warning(_ group: String, expires: Date? = nil) -> OutgoingNotification {
        OutgoingNotification(kind: .warning, title: "Warning \(group)", body: "b", groupKey: group, createdAt: Fixtures.start, expiresAt: expires)
    }

    // MARK: Channels

    @Test func showsOnTheMacAndSavesForTheIPhone() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        _ = await h.dispatcher.submit(Self.stalled(), context: Fixtures.context())
        #expect(await eventually { await h.dispatcher.status().lastDeliveredAt != nil })
        let status = await h.dispatcher.status()
        #expect(status.outboxCount == 0)
        #expect(status.lastDeliveredAt == h.clock.now())
        #expect(status.lastError == nil)
        let saved = await h.saved
        #expect(saved.count == 1)
        let alert = try #require(saved.first)
        #expect(alert.macID == (await h.dispatcher.macIDForTesting))
        #expect(alert.macName == "Studio")
        #expect(alert.kind == "stalled" && alert.title == "Claude Code looks stuck \u{00B7} api")
        #expect(alert.threadID == "stalled:claude/c-1")
        #expect(alert.interruption == .active)
        #expect(alert.actions == [.keepAwake(seconds: 3600)])
        #expect(alert.stateVersion == 42)
        #expect(alert.expiresAt == Fixtures.start.addingTimeInterval(NotificationKind.stalled.actionTTL))
        #expect(await eventually { h.posted.count == 1 })
        #expect(h.posted.first == alert, "the Mac shows exactly the alert the iPhone gets")
        await h.dispatcher.stop()
    }

    @Test func aBuildWithoutICloudShowsOnTheMacOnly() async throws {
        let h = try Harness(noCloud: true)
        defer { h.cleanup() }
        await h.dispatcher.start()
        #expect(await h.dispatcher.status().iCloud == .unavailableInThisBuild)
        _ = await h.dispatcher.submit(Self.stalled(), context: Fixtures.context())
        #expect(await eventually { h.posted.count == 1 })
        #expect(await h.dispatcher.status().outboxCount == 0)
        await h.dispatcher.stop()
    }

    @Test func eachChannelFollowsItsSetting() async throws {
        var phoneOnly = NotificationSettings()
        phoneOnly.macAlerts = false
        let a = try Harness(settings: phoneOnly)
        defer { a.cleanup() }
        try await a.startReady()
        _ = await a.dispatcher.submit(Self.stalled(), context: Fixtures.context())
        #expect(await eventually { await a.saved.count == 1 })
        await settle()
        #expect(a.posted.isEmpty)
        await a.dispatcher.stop()

        var macOnly = NotificationSettings()
        macOnly.phoneAlerts = false
        let b = try Harness(settings: macOnly)
        defer { b.cleanup() }
        try await b.startReady()
        _ = await b.dispatcher.submit(Self.stalled(), context: Fixtures.context())
        #expect(await eventually { b.posted.count == 1 })
        await settle()
        #expect(await b.saved.isEmpty)
        #expect(await b.dispatcher.status().outboxCount == 0)
        await b.dispatcher.stop()
    }

    @Test func deniedMacNotificationsStillReachTheIPhone() async throws {
        let h = try Harness(local: RecordingLocalNotifications(authorization: .denied))
        defer { h.cleanup() }
        try await h.startReady()
        #expect(await h.dispatcher.status().macAuthorization == .denied)
        _ = await h.dispatcher.submit(Self.stalled(), context: Fixtures.context())
        #expect(await eventually { await h.saved.count == 1 })
        await settle()
        #expect(h.posted.isEmpty)
        // Allowed later in System Settings: the 60 s tick notices, the next alert shows on the Mac too.
        h.local.setAuthorization(.authorized)
        #expect(await happensBy(h.clock, within: .seconds(60)) { await h.dispatcher.status().macAuthorization == .authorized })
        _ = await h.dispatcher.submit(Self.stalled("c-2"), context: Fixtures.context(h.clock.now()))
        #expect(await eventually { h.posted.count == 1 })
        await h.dispatcher.stop()
    }

    @Test func aMacPostFailureDoesNotStopTheIPhone() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        h.local.setPostError(CocoaError(.featureUnsupported))
        try await h.startReady()
        _ = await h.dispatcher.submit(Self.stalled(), context: Fixtures.context())
        #expect(await eventually { await h.saved.count == 1 })
        #expect(await eventually { h.logText.contains("Mac notification stalled not shown") })
        await h.dispatcher.stop()
    }

    @Test func macNotificationsKeepTheSubmitOrderAndTheirReplaceKeys() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        for group in ["a", "b", "c", "d"] { await h.dispatcher.enqueue(warning(group)) }
        var countdown = warning("countdown")
        countdown.replaceKey = "countdown"
        await h.dispatcher.enqueue(countdown)
        #expect(await eventually { h.posted.count == 5 })
        #expect(h.posted.map(\.title) == ["Warning a", "Warning b", "Warning c", "Warning d", "Warning countdown"])
        #expect(h.posted.last?.replaceKey == "countdown")
        await h.dispatcher.stop()
    }

    @Test func categoriesFollowTheKeepAwakeDuration() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        #expect(await eventually { h.local.categoryRegistrations == [3600] })
        _ = await h.dispatcher.submit(Self.stalled(), context: Fixtures.context(keepAwake: 1800))
        #expect(await eventually { h.local.categoryRegistrations == [3600, 1800] })
        _ = await h.dispatcher.submit(Self.stalled("c-2"), context: Fixtures.context(keepAwake: 1800))
        await settle()
        #expect(h.local.categoryRegistrations == [3600, 1800], "registered again only when the duration changes")
        await h.dispatcher.stop()
    }

    // MARK: iCloud retry classes

    @Test func retryableErrorsBackOffAndRecover() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        await h.cloud?.setPersistentFailure(.save, .network(retryAfter: nil))
        _ = await h.dispatcher.submit(Self.stalled(), context: Fixtures.context())
        #expect(await eventually { await h.dispatcher.outboxItemsForTesting.first?.attempts == 1 })
        // Jitter is pinned to the lower bound (2 s) in tests: the retry goes out exactly 2 s after the failure.
        #expect(await h.dispatcher.outboxItemsForTesting.first?.nextAttemptAt == Fixtures.start.addingTimeInterval(2))
        #expect(await happensAt(h.clock, after: .seconds(2)) { await h.dispatcher.outboxItemsForTesting.first?.attempts == 2 })
        await h.cloud?.setPersistentFailure(.save, nil)
        // Second failure → full jitter over 2…4 s, pinned to 2 s.
        #expect(await h.dispatcher.outboxItemsForTesting.first?.nextAttemptAt == Fixtures.start.addingTimeInterval(4))
        #expect(await happensAt(h.clock, after: .seconds(2)) { await h.dispatcher.status().outboxCount == 0 })
        #expect(await h.saved.count == 1)
        #expect(await h.dispatcher.status().lastError == nil)
        await h.dispatcher.stop()
    }

    @Test func rateLimitedSavesWaitForRetryAfter() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        await h.cloud?.failNext(.save, with: .rateLimited(retryAfter: 120))
        _ = await h.dispatcher.submit(Self.stalled(), context: Fixtures.context())
        #expect(await eventually { await h.dispatcher.outboxItemsForTesting.first?.attempts == 1 })
        let item = try #require(await h.dispatcher.outboxItemsForTesting.first)
        #expect(item.nextAttemptAt == Fixtures.start.addingTimeInterval(120))
        // Other messages wait for iCloud too.
        _ = await h.dispatcher.submit(Self.stalled("c-2"), context: Fixtures.context())
        h.clock.advance(by: .seconds(119))
        await settle()
        #expect(await h.saved.isEmpty)
        #expect(await h.cloud?.count(.save) == 1)
        h.clock.advance(by: .seconds(1))
        #expect(await eventually { await h.saved.count == 2 })
        await h.dispatcher.stop()
    }

    @Test func permanentFailuresAreDroppedReportedAndClearedBySuccess() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        await h.cloud?.failNext(.save, with: .permanent("bad record"))
        _ = await h.dispatcher.submit(Self.stalled(), context: Fixtures.context())
        #expect(await eventually { await h.dispatcher.status().lastError != nil })
        let status = await h.dispatcher.status()
        #expect(status.lastError == CloudError.permanent("bad record").userMessage)
        #expect(status.outboxCount == 0)
        h.clock.advance(by: .seconds(600))
        await settle()
        #expect(await h.cloud?.count(.save) == 1, "never retried")
        _ = await h.dispatcher.submit(Self.stalled("c-2"), context: Fixtures.context(h.clock.now()))
        #expect(await eventually { await h.dispatcher.status().lastError == nil })
        await h.dispatcher.stop()
    }

    @Test func aFullICloudKeepsAlertsAndRetriesEveryTenMinutes() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        await h.cloud?.setPersistentFailure(.save, .quotaExceeded)
        _ = await h.dispatcher.submit(Self.stalled(), context: Fixtures.context())
        #expect(await eventually { await h.dispatcher.status().lastError == CloudError.quotaExceeded.userMessage })
        #expect(await h.dispatcher.status().outboxCount == 1, "kept, not dropped")
        #expect(await h.dispatcher.outboxItemsForTesting.first?.nextAttemptAt == Fixtures.start.addingTimeInterval(600))
        await h.cloud?.setPersistentFailure(.save, nil) // the user freed some storage
        #expect(await happensBy(h.clock, within: .seconds(610), step: .seconds(10)) { await h.saved.count == 1 })
        #expect(await eventually { await h.dispatcher.status().lastError == nil })
        await h.dispatcher.stop()
    }

    @Test func aFullICloudDoesNotRetryTheStatusEveryMinute() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        await h.cloud?.setPersistentFailure(.save, .quotaExceeded)
        await h.dispatcher.updateMacStatus(MacStatusReport(phase: .idle, headline: "Idle"))
        #expect(await eventually { await (h.cloud?.count(.save) ?? 0) >= 1 })
        let first = await h.cloud?.count(.save) ?? 0
        for _ in 0..<9 { // nine 60 s ticks
            h.clock.advance(by: .seconds(60))
            await settle()
        }
        #expect(await h.cloud?.count(.save) == first, "no heartbeat retry before 10 min")
        h.clock.advance(by: .seconds(70))
        await settle()
        #expect(await eventually { await (h.cloud?.count(.save) ?? 0) > first })
        await h.dispatcher.stop()
    }

    @Test func aSignedOutSaveRechecksTheAccountAtOnceInsteadOfDropping() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        let checks = await h.cloud?.count(.accountStatus) ?? 0
        await h.cloud?.failNext(.save, with: .notSignedIn)
        _ = await h.dispatcher.submit(Self.stalled(), context: Fixtures.context())
        // The account is fine again (a transient error): the loop is woken, sets iCloud up again, and the alert goes out
        // within seconds — no 10 min hold.
        #expect(await happensBy(h.clock, within: .seconds(20)) { await h.saved.count == 1 })
        #expect((await h.cloud?.count(.accountStatus) ?? 0) > checks)
        #expect(await h.dispatcher.status().iCloud == .available)
        await h.dispatcher.stop()
    }

    @Test func outboxSurvivesARelaunch() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        await h.cloud?.setPersistentFailure(.save, .network(retryAfter: nil))
        _ = await h.dispatcher.submit(Self.stalled(), context: Fixtures.context())
        #expect(await eventually { await h.dispatcher.outboxItemsForTesting.first?.attempts == 1 })
        await h.dispatcher.stop()
        #expect(NotifyStore(paths: h.paths).loadOutbox().count == 1)

        await h.cloud?.setPersistentFailure(.save, nil)
        let relaunched = h.relaunch()
        #expect(await relaunched.status().outboxCount == 1)
        await relaunched.start()
        #expect(await advance(h.clock, limit: .seconds(10)) { await h.saved.count == 1 } != nil)
        #expect(await h.savedTitles == ["Claude Code looks stuck \u{00B7} api"])
        #expect(await eventually { await relaunched.status().outboxCount == 0 })
        #expect(await relaunched.macIDForTesting == (await h.dispatcher.macIDForTesting), "the Mac keeps its id")
        await relaunched.stop()
    }

    @Test func expiredItemsAreDroppedNotSent() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        await h.cloud?.setPersistentFailure(.save, .network(retryAfter: nil))
        await h.dispatcher.enqueue(warning("w", expires: Fixtures.start.addingTimeInterval(5)))
        #expect(await eventually { await h.cloud?.count(.save) == 1 })
        #expect(await advance(h.clock, limit: .seconds(10)) { await h.dispatcher.status().outboxCount == 0 } != nil)
        let attempts = await h.cloud?.count(.save) ?? 0
        #expect(attempts <= 3)
        h.clock.advance(by: .seconds(120))
        await settle()
        #expect(await h.cloud?.count(.save) == attempts)
        await h.dispatcher.stop()
    }

    @Test func expiredItemsAreDroppedOnLoad() async throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        try NotifyStore(paths: paths).saveOutbox([
            OutboxItem(notification: warning("old", expires: Fixtures.start.addingTimeInterval(-1)), enqueuedAt: Fixtures.start.addingTimeInterval(-60)),
            OutboxItem(notification: warning("fresh"), enqueuedAt: Fixtures.start),
        ])
        let h = try Harness(paths: paths)
        #expect(await h.dispatcher.status().outboxCount == 1)
        #expect(await h.dispatcher.outboxItemsForTesting.map(\.notification.groupKey) == ["fresh"])
    }

    @Test func sameGroupKeyReplacesTheQueuedItem() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        await h.cloud?.setPersistentFailure(.save, .network(retryAfter: nil))
        var first = warning("g")
        first.title = "first"
        var second = warning("g")
        second.title = "second"
        await h.dispatcher.enqueue(first)
        await h.dispatcher.enqueue(second)
        #expect(await eventually { await h.dispatcher.outboxItemsForTesting.map(\.notification.title) == ["second"] })
        await h.dispatcher.stop()
    }

    // MARK: drain(deadline:)

    @Test func drainDeliversEverythingBeforeTheDeadline() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        h.pathMonitor.set(satisfied: false) // no background delivery: only the explicit drain saves
        await settle()
        for group in ["a", "b", "c"] { await h.dispatcher.enqueue(warning(group)) }
        await settle()
        #expect(await h.saved.isEmpty)
        let result = await h.dispatcher.drain(deadline: h.clock.now().addingTimeInterval(10))
        #expect(result == DrainResult(delivered: 3, remaining: 0, permanentFailures: 0, hitDeadline: false))
        #expect(await h.savedTitles == ["Warning a", "Warning b", "Warning c"])
        await h.dispatcher.stop()
    }

    @Test func drainStopsAtTheDeadline() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        h.pathMonitor.set(satisfied: false)
        await h.cloud?.setPersistentFailure(.save, .network(retryAfter: nil))
        await h.dispatcher.enqueue(warning("a"))
        await h.dispatcher.enqueue(warning("b"))
        let deadline = h.clock.now().addingTimeInterval(10)
        let box = Mutex<DrainResult?>(nil)
        let dispatcher = h.dispatcher
        let task = Task {
            let result = await dispatcher.drain(deadline: deadline)
            box.withLock { $0 = result }
        }
        #expect(await happensBy(h.clock, within: .seconds(11)) { box.withLock { $0 } != nil })
        await task.value
        let result = try #require(box.withLock { $0 })
        #expect(result.hitDeadline)
        #expect(result.delivered == 0)
        #expect(result.remaining == 2)
        #expect((await h.cloud?.count(.save) ?? 0) >= 2) // both items attempted (and retried with backoff) until the deadline
        await h.dispatcher.stop()
    }

    @Test func drainFlushesTheBatchAndCountsPermanentFailures() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        h.pathMonitor.set(satisfied: false)
        #expect(await h.dispatcher.submit(.finished(Fixtures.finished(), stillRunning: 0), context: Fixtures.context()) == .batched)
        let result = await h.dispatcher.drain(deadline: h.clock.now().addingTimeInterval(10))
        #expect(result == DrainResult(delivered: 1, remaining: 0, permanentFailures: 0, hitDeadline: false))
        #expect(await h.savedTitles == ["Claude Code finished \u{00B7} api"])

        await h.cloud?.failNext(.save, with: .permanent("bad record"))
        await h.dispatcher.enqueue(warning("x"))
        let failed = await h.dispatcher.drain(deadline: h.clock.now().addingTimeInterval(10))
        #expect(failed == DrainResult(delivered: 0, remaining: 0, permanentFailures: 1, hitDeadline: false))
        #expect(await h.dispatcher.status().lastError == "iCloud rejected the request: bad record")
        await h.dispatcher.stop()
    }

    @Test func drainBeforeICloudIsReadyReportsWhatRemains() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        await h.dispatcher.enqueue(warning("a")) // not started: iCloud is not set up yet
        let result = await h.dispatcher.drain(deadline: h.clock.now().addingTimeInterval(10))
        #expect(result.delivered == 0)
        #expect(result.remaining == 1)
        #expect(await h.cloud?.count(.save) == 0)
    }

    @Test func offlinePathPausesBackgroundDeliveryUntilSatisfied() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        h.pathMonitor.set(satisfied: false)
        await settle()
        _ = await h.dispatcher.submit(Self.stalled(), context: Fixtures.context())
        await settle()
        #expect(await h.saved.isEmpty)
        #expect(h.posted.count == 1, "the Mac notification needs no network")
        h.pathMonitor.set(satisfied: true)
        #expect(await eventually { await h.saved.count == 1 })
        await h.dispatcher.stop()
    }

    @Test func drainReturnsAtTheDeadlineWhileABackgroundSaveHangs() async throws {
        let cloud = InMemoryCloudStore()
        let hanging = SuspendingCloudStore(wrapping: cloud)
        let h = try Harness(cloud: cloud, store: hanging)
        defer { h.cleanup() }
        try await h.startReady()
        await h.dispatcher.enqueue(warning("w"))
        #expect(await eventually { hanging.pendingCount == 1 }) // the background attempt is stuck on the network

        let start = h.clock.now()
        let box = Mutex<DrainResult?>(nil)
        let dispatcher = h.dispatcher
        let task = Task {
            let result = await dispatcher.drain(deadline: start.addingTimeInterval(10))
            box.withLock { $0 = result }
        }
        // Returns exactly at the deadline (never later), although the background save never completes.
        #expect(await happensAt(h.clock, after: .seconds(10)) { box.withLock { $0 } != nil })
        await task.value
        let result = try #require(box.withLock { $0 })
        #expect(result == DrainResult(delivered: 0, remaining: 1, permanentFailures: 0, hitDeadline: true))
        #expect(hanging.saveCount == 1) // the in-flight item is not saved twice
        hanging.release()
        #expect(await eventually { await h.dispatcher.status().outboxCount == 0 })
        await h.dispatcher.stop()
    }

    @Test func drainWaitsForAnAttemptInFlightThatSucceeds() async throws {
        let cloud = InMemoryCloudStore()
        let hanging = SuspendingCloudStore(wrapping: cloud)
        let h = try Harness(cloud: cloud, store: hanging)
        defer { h.cleanup() }
        try await h.startReady()
        await h.dispatcher.enqueue(warning("w"))
        #expect(await eventually { hanging.pendingCount == 1 })
        let box = Mutex<DrainResult?>(nil)
        let dispatcher = h.dispatcher
        let deadline = h.clock.now().addingTimeInterval(10)
        let task = Task {
            let result = await dispatcher.drain(deadline: deadline)
            box.withLock { $0 = result }
        }
        await settle()
        #expect(box.withLock { $0 } == nil)
        hanging.release() // the background attempt completes before the deadline
        await task.value
        let result = try #require(box.withLock { $0 })
        #expect(result.remaining == 0)
        #expect(!result.hitDeadline)
        #expect(h.clock.now() < deadline)
        await h.dispatcher.stop()
    }

    @Test func aHangingSaveTimesOutAndIsRetried() async throws {
        let cloud = InMemoryCloudStore()
        let hanging = SuspendingCloudStore(wrapping: cloud)
        let h = try Harness(cloud: cloud, store: hanging)
        defer { h.cleanup() }
        try await h.startReady()
        await h.dispatcher.enqueue(warning("w"))
        #expect(await eventually { hanging.pendingCount == 1 })
        h.clock.advance(by: .seconds(29))
        await settle()
        #expect(await h.dispatcher.outboxItemsForTesting.first?.attempts == 0)
        h.clock.advance(by: .seconds(1)) // NotifyEnvironment.sendTimeout = 30 s
        #expect(await eventually { await h.dispatcher.outboxItemsForTesting.first?.attempts == 1 })
        #expect(await h.dispatcher.outboxItemsForTesting.first?.lastError == "timed out")
        #expect(await eventually { hanging.cancelledCount == 1 }) // the stuck save was cancelled, not leaked
        // The retry (2 s backoff) goes out and succeeds.
        #expect(await eventually { hanging.pendingCount == 0 })
        #expect(await happensAt(h.clock, after: .seconds(2)) { hanging.pendingCount == 1 })
        hanging.release()
        #expect(await eventually { await h.dispatcher.status().outboxCount == 0 })
        await h.dispatcher.stop()
    }

    // MARK: Dry run, timers, stop

    @Test func dryRunSavesNothingButStillReads() async throws {
        let cloud = InMemoryCloudStore(zoneExists: true)
        let ledger = DryRunLedger(clock: TestClock())
        let gated = DryRunCloudStore(passthrough: cloud, gate: .alwaysOn(), ledger: ledger)
        let h = try Harness(cloud: cloud, store: gated)
        defer { h.cleanup() }
        try await h.startReady()
        _ = await h.dispatcher.submit(Self.stalled(), context: Fixtures.context())
        #expect(await eventually { await h.dispatcher.status().lastDeliveredAt != nil })
        #expect(await cloud.allItems.isEmpty, "nothing was saved for real")
        #expect(await cloud.subscriptions.isEmpty)
        #expect(ledger.entries(action: "cloud.save").first?.detail == "would save 1 iCloud record(s) (Alert)")
        #expect(ledger.entries(action: "cloud.subscribe").count == 1)
        #expect(await cloud.count(.fetchChanges) >= 1, "reads still go to iCloud")
        await h.dispatcher.stop()
    }

    @Test func theSixtySecondTickDropsExpiredItemsWhileOffline() async throws {
        let h = try Harness(online: false)
        defer { h.cleanup() }
        try await h.startReady()
        await h.dispatcher.enqueue(warning("w", expires: Fixtures.start.addingTimeInterval(30)))
        await settle()
        #expect(await h.saved.isEmpty) // offline: no background attempt
        #expect(await h.dispatcher.status().outboxCount == 1)
        h.clock.advance(by: .seconds(59))
        await settle()
        #expect(await h.dispatcher.status().outboxCount == 1)
        h.clock.advance(by: .seconds(1))
        #expect(await eventually { await h.dispatcher.status().outboxCount == 0 })
        #expect(NotifyStore(paths: h.paths).loadOutbox().isEmpty)
        #expect(await h.saved.isEmpty)
        await h.dispatcher.stop()
    }

    @Test func stopKeepsBatchedMessagesForTheNextLaunch() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        _ = await h.dispatcher.submit(.finished(Fixtures.finished(), stillRunning: 0), context: Fixtures.context())
        await h.dispatcher.stop()
        #expect(NotifyStore(paths: h.paths).loadOutbox().map(\.notification.kind) == [.finished])
        #expect(await h.saved.isEmpty)
    }

    @Test func turningPhoneAlertsOffDropsWhatIsQueued() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        await h.cloud?.setPersistentFailure(.save, .network(retryAfter: nil))
        _ = await h.dispatcher.submit(Self.stalled(), context: Fixtures.context())
        #expect(await eventually { await h.dispatcher.status().outboxCount == 1 })
        var settings = NotificationSettings()
        settings.phoneAlerts = false
        await h.dispatcher.applySettings(settings)
        #expect(await h.dispatcher.status().outboxCount == 0)
        await h.dispatcher.stop()
    }
}
