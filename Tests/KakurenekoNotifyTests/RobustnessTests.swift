import KakurenekoCloud
@testable import KakurenekoNotify
import KakurenekoKit
import Foundation
import Synchronization
import Testing

/// Regression tests for the review of the native notifications (2026-10-17): loops that must back off, timeouts that
/// must hold, work that must stop with the dispatcher, and lists that must be rebuilt.
@Suite("Robustness", .timeLimit(.minutes(1)))
struct RobustnessTests {
    static func stalled(_ id: String = "c-1", at: Date = Fixtures.start) -> NotificationIntent {
        .stalled(SessionEffect(kind: .stalled, session: Fixtures.claude(id: id), at: at))
    }

    func report(_ headline: String = "1 agent working") -> MacStatusReport {
        MacStatusReport(phase: .working, headline: headline, stateVersion: 42, canSleep: true)
    }

    @Test func dryRunWithoutAZoneDoesNotSpin() async throws {
        // An entitled build in dry-run on a store that is not prepared: prepare is only logged, so every
        // fetch would report the zone missing. The loop must neither spin nor keep setting iCloud up.
        let cloud = InMemoryCloudStore(zoneExists: false)
        let gated = DryRunCloudStore(passthrough: cloud, gate: .alwaysOn(), ledger: DryRunLedger(clock: TestClock()))
        let h = try Harness(cloud: cloud, store: gated)
        defer { h.cleanup() }
        try await h.startReady()
        await settle()
        try? await Task.sleep(for: .milliseconds(200)) // real time passes; virtual time does not
        #expect(await cloud.count(.fetchChanges) <= 2)
        #expect(await cloud.count(.accountStatus) <= 2)
        #expect(await h.dispatcher.cloudReadyForTesting)
        await h.dispatcher.stop()
    }

    @Test func failingFetchesBackOffEvenWhenSetupSucceeds() async throws {
        let h = try Harness(configure: { $0.random = { $0.upperBound } }) // full jitter at its top: the growth shows
        defer { h.cleanup() }
        try await h.startReady()
        // Every fetch says "not signed in" while the account check says "available": set up, fail, set up, fail …
        await h.cloud?.setPersistentFailure(.fetchChanges, .notSignedIn)
        await h.dispatcher.cloudDidNotify()
        for _ in 0..<24 {
            h.clock.advance(by: .seconds(5))
            await settle()
        }
        // Backoff 15 s, 30 s, 60 s → about 4 fetches in two minutes (it never resets to 15 s after a "good" setup).
        let fetches = await h.cloud?.count(.fetchChanges) ?? 0
        #expect(fetches <= 6, "\(fetches) fetches")
        await h.dispatcher.stop()
    }

    @Test func anActionableAlertMakesThePollFastAtOnce() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        let collector = CommandCollector(h.dispatcher.remoteCommands())
        // The loop is in its 5 min wait. An alert with buttons is saved; the phone taps Keep awake; no push arrives.
        _ = await h.dispatcher.submit(Self.stalled(), context: Fixtures.context())
        #expect(await eventually { await h.saved.count == 1 })
        try await h.phoneCommand(.keepAwake(seconds: 3600), sv: nil)
        #expect(await happensBy(h.clock, within: .seconds(16)) { collector.commands.count == 1 })
        await h.dispatcher.stop()
    }

    @Test func aSaveThatIgnoresCancellationStillTimesOut() async throws {
        let cloud = InMemoryCloudStore(seed: [.device(Fixtures.phone)])
        let hanging = SuspendingCloudStore(wrapping: cloud, ignoresCancellation: true)
        let h = try Harness(cloud: cloud, store: hanging)
        defer { h.cleanup() }
        try await h.startReady()
        h.pathMonitor.set(satisfied: false) // only the explicit drain saves
        await h.dispatcher.enqueue(OutgoingNotification(kind: .warning, title: "w", body: "b", groupKey: "g", createdAt: Fixtures.start))
        let box = Mutex<DrainResult?>(nil)
        let dispatcher = h.dispatcher
        let deadline = h.clock.now().addingTimeInterval(10)
        let task = Task {
            let result = await dispatcher.drain(deadline: deadline)
            box.withLock { $0 = result }
        }
        #expect(await happensBy(h.clock, within: .seconds(11)) { box.withLock { $0 } != nil })
        #expect(box.withLock { $0 }?.hitDeadline == true)
        hanging.release()
        await task.value
        await h.dispatcher.stop()
    }

    @Test func stoppingDuringASaveKeepsTheAlertForTheNextLaunch() async throws {
        let cloud = InMemoryCloudStore(seed: [.device(Fixtures.phone)])
        let hanging = SuspendingCloudStore(wrapping: cloud)
        let h = try Harness(cloud: cloud, store: hanging)
        defer { h.cleanup() }
        try await h.startReady()
        await h.dispatcher.enqueue(OutgoingNotification(kind: .warning, title: "w", body: "b", groupKey: "g", createdAt: Fixtures.start))
        #expect(await eventually { hanging.pendingCount == 1 })
        await h.dispatcher.stop()
        hanging.release()
        await settle()
        #expect(NotifyStore(paths: h.paths).loadOutbox().count == 1, "the cancelled attempt never removed it")
    }

    @Test func nothingIsSavedAfterStop() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        await h.dispatcher.updateMacStatus(report())
        #expect(await eventually { await h.statuses.count == 1 })
        await h.dispatcher.updateMacStatus(report("2 agents working")) // debounced: pending for 5 s
        await h.dispatcher.stop()
        let saves = await h.cloud?.count(.save) ?? 0
        await h.dispatcher.updateMacStatus(report("after stop"))
        h.clock.advance(by: .seconds(30))
        await settle()
        #expect(await h.cloud?.count(.save) == saves)
        #expect(await h.statuses.first?.headline == "1 agent working")
    }

    @Test func aHeartbeatReplacesAPendingDebouncedSave() async throws {
        let h = try Harness(configure: { $0.statusDebounce = 120 })
        defer { h.cleanup() }
        try await h.startReady()
        await h.dispatcher.updateMacStatus(report())
        #expect(await eventually { await h.statuses.count == 1 })
        h.clock.advance(by: .seconds(290)) // the 60 s tick skips ahead: next at t+350
        await settle()
        await h.dispatcher.updateMacStatus(report("changed")) // debounced until t+410
        #expect(await happensBy(h.clock, within: .seconds(70)) { await h.statuses.first?.headline == "changed" }, "the heartbeat saved it")
        let saves = await h.cloud?.count(.save) ?? 0
        h.clock.advance(by: .seconds(130)) // past the old debounce deadline
        await settle()
        #expect(await h.cloud?.count(.save) == saves, "the superseded debounced save did not run again")
        await h.dispatcher.stop()
    }

    @Test func aFullRefetchForgetsDeletedPhones() async throws {
        let h = try Harness(phone: false)
        defer { h.cleanup() }
        try await h.startReady()
        func phone(_ id: String) -> PhoneDevice {
            PhoneDevice(deviceID: id, name: "iPhone", model: "iPhone18,3", systemVersion: "26", appVersion: "1",
                        alertsAuthorized: true, lastSeenAt: Fixtures.start)
        }
        try await h.cloud?.save([.device(phone("p1")), .device(phone("p2"))])
        await h.dispatcher.cloudDidNotify()
        #expect(await eventually { await h.dispatcher.status().phones.count == 2 })
        // p2 is deleted, but the token expires before its deletion is seen: the from-scratch fetch rebuilds the list.
        try await h.cloud?.delete([CloudItem.device(phone("p2")).id])
        await h.cloud?.failNext(.fetchChanges, with: .changeTokenExpired)
        await h.dispatcher.cloudDidNotify()
        #expect(await eventually { await h.dispatcher.status().phones.map(\.deviceID) == ["p1"] })
        await h.dispatcher.stop()
    }

    @Test func otherMacsAlertsAreClearedOnPushesAndTicks() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        await h.dispatcher.cloudDidNotify()
        #expect(h.local.remoteAlertRemovals == 1)
        #expect(await happensBy(h.clock, within: .seconds(60)) { h.local.remoteAlertRemovals == 2 })
        await h.dispatcher.stop()
    }

    @Test func aButtonTapThatLaunchedTheAppIsNotLost() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        let mac = await h.dispatcher.macIDForTesting
        let collector = CommandCollector(h.dispatcher.remoteCommands())
        // macOS delivers the tap before the dispatcher subscribed.
        h.local.tap(AlertPresentation.ButtonTap(request: .keepAwake(seconds: 600), alertID: "A", macID: mac, stateVersion: nil,
                                                expiresAt: Fixtures.start.addingTimeInterval(300)))
        await h.dispatcher.start()
        #expect(await eventually { collector.kinds == [.keepAwake(seconds: 600)] })
        await h.dispatcher.stop()
    }
}
