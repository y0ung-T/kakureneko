// PhoneStore sync: setup, change application (placeholders, retention, deletions), persistence across relaunches,
// zone loss, expired tokens, backoff, sign-out and silent pushes. All against InMemoryCloudStore.

import KakurenekoCloud
import Foundation
import Testing

@MainActor
@Suite("Sync")
struct SyncTests {
    @Test func firstActivationPreparesTheZoneSubscribesAndFetches() async throws {
        let h = Harness(cloud: InMemoryCloudStore(zoneExists: false))
        await h.cloud.setRequiresSchemaBootstrap(true)
        let store = h.makeStore()
        await store.sceneDidBecomeActive()
        defer { store.sceneDidEnterBackground() }

        #expect(store.account == .available)
        #expect(store.connection == .online)
        #expect(await h.cloud.zoneExists)
        #expect(await h.cloud.subscriptions == [.alerts, .phoneInbox])
        #expect(await h.cloud.schemaBootstrapped, "a fresh development schema is bootstrapped")
        #expect(store.macs.isEmpty)

        try await h.macSaves(.status(Fixture.status(updatedAt: h.clock.now)),
                             .alert(Fixture.alert("a1", createdAt: h.clock.now)))
        #expect(await store.sync() == .changed)
        #expect(store.macs.map(\.macID) == ["mac-1"])
        #expect(store.alerts.map(\.id) == ["a1"])
        #expect(await store.sync() == .unchanged)
    }

    @Test func setupIsNotRepeatedWithinADay() async throws {
        let h = Harness()
        let store = h.makeStore()
        await store.sync()
        await h.cloud.clearOperations()
        h.clock.advance(3600)
        await store.sync()
        #expect(await !h.cloud.operations.contains(.saveSubscription))
        h.clock.advance(24 * 3600)
        await store.sync()
        #expect(await h.cloud.operations.contains(.saveSubscription))
    }

    @Test func placeholdersAndCommandsAreNotShown() async throws {
        let h = Harness()
        try await h.cloud.save(CloudSchemaBootstrap.placeholders(now: h.clock.now))
        let otherPhone = CloudCommand(macID: "mac-1", request: .refreshStatus, stateVersion: nil, issuedAt: h.clock.now,
                                      expiresAt: h.clock.now.addingTimeInterval(60), deviceID: "other", deviceName: "iPhone")
        try await h.macSaves(.command(otherPhone))
        let store = h.makeStore()
        #expect(await store.sync() == .unchanged)
        #expect(store.macs.isEmpty)
        #expect(store.alerts.isEmpty)
    }

    @Test func alertsCoverThreeDaysNewestFirst() async throws {
        let h = Harness()
        let now = h.clock.now
        try await h.macSaves(.alert(Fixture.alert("4d", createdAt: now.addingTimeInterval(-4 * 86400))),
                             .alert(Fixture.alert("2d", createdAt: now.addingTimeInterval(-2 * 86400))),
                             .alert(Fixture.alert("1h", createdAt: now.addingTimeInterval(-3600))),
                             .alert(Fixture.alert("10m", createdAt: now.addingTimeInterval(-600))))
        let store = h.makeStore()
        await store.sync()
        #expect(store.alerts.map(\.id) == ["10m", "1h", "2d"])

        h.clock.advance(86400 + 3600)
        await store.sync()
        #expect(store.alerts.map(\.id) == ["10m", "1h"], "pruned as they age, even without new changes")
    }

    /// The public database reports no deletions: the Macs are read whole, so one that left iCloud leaves the list at
    /// the next sync; a deleted alert just ages out of the 3-day Activity like the rest.
    @Test func aMacThatLeftICloudLeavesTheList() async throws {
        let h = Harness()
        let now = h.clock.now
        let second = Fixture.status("mac-2", name: "Mini", updatedAt: now)
        let alert = Fixture.alert("a1", createdAt: now)
        try await h.macSaves(.status(Fixture.status(updatedAt: now)), .status(second), .alert(alert))
        let store = h.makeStore()
        await store.sync()
        #expect(store.macs.map(\.macID) == ["mac-2", "mac-1"], "sorted by name: Mini, Studio")

        try await h.cloud.delete([CloudItem.status(second).id, CloudItem.alert(alert).id])
        #expect(await store.sync() == .changed)
        #expect(store.macs.map(\.macID) == ["mac-1"])
        #expect(store.alerts.map(\.id) == ["a1"], "kept until it ages out")
    }

    @Test func aMacSilentForAWeekMovesApartAndCanBeRemoved() async throws {
        let h = Harness()
        let now = h.clock.now
        try await h.macSaves(.status(Fixture.status("mac-1", name: "Studio", updatedAt: now)),
                             .status(Fixture.status("old", name: "Old Mac", updatedAt: now.addingTimeInterval(-8 * 86_400))))
        let store = h.makeStore()
        await store.sync()
        #expect(store.macs.map(\.macID) == ["mac-1"], "the app only talks to Macs seen this week")
        #expect(store.formerMacs.map(\.macID) == ["old"])
        await store.removeMac("old")
        #expect(store.formerMacs.isEmpty)
        #expect(await h.cloud.contains(CloudItem.status(Fixture.status("old", updatedAt: now)).id) == false, "its record left iCloud")
        await store.sync()
        #expect(store.formerMacs.isEmpty, "and stays gone")
    }

    @Test func openingTheAppAsksOnlyLiveMacsForTheirStatus() async throws {
        let h = Harness()
        let now = h.clock.now
        try await h.macSaves(.status(Fixture.status("live", updatedAt: now.addingTimeInterval(-300))),
                             .status(Fixture.status("quiet", updatedAt: now.addingTimeInterval(-2 * 86_400))),
                             .status(Fixture.status("asleep", phase: .asleep, updatedAt: now.addingTimeInterval(-300))))
        let store = h.makeStore()
        await store.sync()
        await store.requestStatusRefresh()
        #expect(await h.commands().map(\.macID) == ["live"], "not a Mac quiet for a day, not one asleep")
    }

    @Test func oldRecordsArePrunedOnceADay() async throws {
        let h = Harness()
        let now = h.clock.now
        let old = Fixture.alert("old", createdAt: now.addingTimeInterval(-5 * 86_400))
        try await h.macSaves(.alert(old), .alert(Fixture.alert("new", createdAt: now)))
        await h.cloud.setModified(CloudItem.alert(old).id, at: now.addingTimeInterval(-5 * 86_400))
        let store = h.makeStore()
        await store.sceneDidBecomeActive()
        store.sceneDidEnterBackground()
        let left = await h.cloud.items(ofType: CloudSchema.RecordType.alert).map(\.id.recordName)
        #expect(left == [CloudItem.alert(Fixture.alert("new", createdAt: now)).id.recordName], "an alert no Mac pruned goes")
        let prunes = await h.cloud.count(.deleteOwned)
        await store.sceneDidBecomeActive()
        store.sceneDidEnterBackground()
        #expect(await h.cloud.count(.deleteOwned) == prunes, "at most once a day")
    }

    @Test func aBackgroundPushKeepsThisIPhoneSeen() async throws {
        let h = Harness()
        let store = h.makeStore()
        await store.sceneDidBecomeActive()
        store.sceneDidEnterBackground()
        let first = try #require(await h.deviceRecord()).lastSeenAt
        h.clock.advance(7 * 3600) // past the 6-hour policy, the app never opened
        _ = await store.handleZonePush()
        #expect(try #require(await h.deviceRecord()).lastSeenAt > first)
    }

    @Test func cacheAndTokenSurviveARelaunch() async throws {
        let h = Harness()
        try await h.macSaves(.status(Fixture.status(sv: 4, updatedAt: h.clock.now)), .alert(Fixture.alert("a1", createdAt: h.clock.now)))
        let first = h.makeStore()
        await first.sync()
        let token = try #require(first.changeToken)

        let relaunched = h.makeStore()
        #expect(relaunched.changeToken == token)
        #expect(relaunched.status(for: "mac-1")?.stateVersion == 4, "shown before the first sync")
        #expect(relaunched.alerts.map(\.id) == ["a1"])

        try await h.macSaves(.alert(Fixture.alert("a2", createdAt: h.clock.now.addingTimeInterval(1))))
        #expect(await relaunched.sync() == .changed)
        #expect(relaunched.alerts.map(\.id) == ["a2", "a1"])
        #expect(relaunched.changeToken != token)
    }

    @Test func aLostZoneIsRecreatedAndRefetched() async throws {
        let h = Harness()
        try await h.macSaves(.status(Fixture.status(updatedAt: h.clock.now)))
        let store = h.makeStore()
        await store.sync()
        #expect(!store.macs.isEmpty)

        await h.cloud.deleteZone()
        #expect(await store.sync() == .changed)
        #expect(await h.cloud.zoneExists, "zone recreated")
        #expect(await h.cloud.subscriptions == [.alerts, .phoneInbox])
        #expect(store.macs.isEmpty, "everything the zone held is gone")
        #expect(store.connection == .online)
    }

    @Test func anExpiredTokenRefetchesEverything() async throws {
        let h = Harness()
        try await h.macSaves(.status(Fixture.status(updatedAt: h.clock.now)), .alert(Fixture.alert("a1", createdAt: h.clock.now)))
        let store = h.makeStore()
        await store.sync()

        // The zone is replaced behind the token's back; only a fetch from scratch can tell what is left.
        await h.cloud.deleteZone()
        try await h.cloud.prepare()
        try await h.macSaves(.status(Fixture.status("mac-2", name: "Mini", updatedAt: h.clock.now)))
        await h.cloud.failNext(.fetchChanges, with: .changeTokenExpired)
        #expect(await store.sync() == .changed)
        #expect(store.macs.map(\.macID) == ["mac-2"])
        #expect(store.alerts.isEmpty)
    }

    @Test func networkFailuresBackOff() async throws {
        let h = Harness()
        let store = h.makeStore()
        await store.sync()

        await h.cloud.failNext(.fetchChanges, with: .network(retryAfter: nil), .network(retryAfter: nil))
        #expect(await store.sync() == .failed)
        #expect(store.connection == .offline(retryAt: h.clock.now.addingTimeInterval(5)))
        #expect(await store.sync() == .skipped, "automatic syncs wait for the backoff")

        h.clock.advance(5)
        #expect(await store.sync() == .failed)
        #expect(store.connection == .offline(retryAt: h.clock.now.addingTimeInterval(10)), "exponential")

        h.clock.advance(10)
        #expect(await store.sync() == .unchanged)
        #expect(store.connection == .online)

        await h.cloud.failNext(.fetchChanges, with: .rateLimited(retryAfter: 42))
        await store.sync()
        #expect(store.connection == .offline(retryAt: h.clock.now.addingTimeInterval(42)), "CloudKit's hint wins")
        #expect(await store.sync(force: true) == .unchanged, "pull-to-refresh and pushes do not wait")
    }

    @Test func permanentErrorsAreReportedAndBackedOff() async throws {
        let h = Harness()
        let store = h.makeStore()
        await store.sync()
        await h.cloud.failNext(.fetchChanges, with: .quotaExceeded)
        #expect(await store.sync() == .failed)
        #expect(store.connection == .failed(message: CloudError.quotaExceeded.userMessage, retryAt: h.clock.now.addingTimeInterval(5)))
    }

    @Test func signingOutForgetsTheAccountsData() async throws {
        let h = Harness()
        try await h.macSaves(.status(Fixture.status(updatedAt: h.clock.now)))
        let store = h.makeStore()
        await store.sync()
        #expect(!store.macs.isEmpty)

        await h.cloud.setAccount(.noAccount)
        await store.accountDidChange()
        #expect(store.account == .noAccount)
        #expect(store.macs.isEmpty)
        #expect(await store.sync() == .unavailable)
        #expect(h.makeStore().macs.isEmpty, "the cache was cleared too")

        await h.cloud.setAccount(.available)
        await store.accountDidChange()
        #expect(store.macs.map(\.macID) == ["mac-1"])
    }

    @Test func anotherAppleAccountFoundAtLaunchStartsOver() async throws {
        let h = Harness()
        try await h.macSaves(.status(Fixture.status(updatedAt: h.clock.now)))
        let store = h.makeStore()
        await store.sync()
        await h.cloud.failNext(.save, with: .network(retryAfter: nil))
        await store.keepAwake(macID: "mac-1")
        #expect(store.pendingCommands.count == 1)

        // Switched while the app was not running: no CKAccountChanged reaches the next launch.
        await h.cloud.setAccountTag("account-b")
        await h.cloud.clearOperations()
        let relaunched = h.makeStore()
        #expect(await relaunched.sync() == .changed)
        #expect(relaunched.pendingCommands.isEmpty, "the other account's queued taps are dropped")
        #expect(await h.cloud.operations.contains(.saveSubscription), "the new account gets its own subscriptions")

        await h.cloud.clearOperations()
        #expect(await h.makeStore().sync() == .unchanged)
        #expect(await !h.cloud.operations.contains(.saveSubscription), "the same account again: nothing to redo")
    }

    @Test func anInconclusiveAccountCheckIsRetried() async throws {
        let h = Harness()
        await h.cloud.setAccount(.couldNotDetermine)
        let store = h.makeStore()
        #expect(await store.sync() == .unavailable)
        await h.cloud.setAccount(.available)
        #expect(await store.sync() != .unavailable, "a later poll or push asks iCloud again")
        #expect(store.account == .available)
    }

    @Test func resolvedAlertsLeaveNotificationCenter() async throws {
        let h = Harness()
        let created = h.clock.now
        try await h.macSaves(.status(Fixture.status(phase: .countdown, updatedAt: created, countdownEndsAt: created.addingTimeInterval(300))),
                             .alert(Fixture.alert("cd", kind: AlertKind.countdown, createdAt: created)),
                             .alert(Fixture.alert("done", kind: AlertKind.finished, createdAt: created)))
        let store = h.makeStore()
        await store.sync()
        h.notifications.delivered = [
            DeliveredAlert(identifier: "n-cd", alertID: "cd", macID: "mac-1", kind: AlertKind.countdown),
            DeliveredAlert(identifier: "n-done", alertID: "done", macID: "mac-1", kind: AlertKind.finished),
        ]
        await store.withdrawResolvedAlerts()
        #expect(h.notifications.delivered.count == 2, "the countdown is still running")

        h.clock.advance(20)
        try await h.macSaves(.status(Fixture.status(phase: .working, updatedAt: h.clock.now)))
        await store.sync()
        await store.withdrawResolvedAlerts()
        #expect(h.notifications.delivered.map(\.identifier) == ["n-done"], "a cancelled countdown's buttons go; other alerts stay")
    }

    @Test func zonePushesSync() async throws {
        let h = Harness()
        let store = h.makeStore()
        #expect(await store.handleZonePush() == .unchanged)
        try await h.macSaves(.status(Fixture.status(updatedAt: h.clock.now)))
        #expect(await store.handleZonePush() == .changed)
        await h.cloud.failNext(.fetchChanges, with: .network(retryAfter: nil))
        #expect(await store.handleZonePush() == .failed)
    }

    @Test func pagedChangesAreFetchedCompletely() async throws {
        let h = Harness(cloud: InMemoryCloudStore(zoneExists: true, pageSize: 2))
        for index in 0..<7 {
            try await h.macSaves(.alert(Fixture.alert("a\(index)", createdAt: h.clock.now.addingTimeInterval(TimeInterval(index)))))
        }
        let store = h.makeStore()
        await store.sync()
        #expect(store.alerts.count == 7)
    }
}
