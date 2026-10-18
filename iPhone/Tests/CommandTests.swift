// PhoneStore commands: building (sv, expiry, identity), which buttons the Mac's state allows, "sent → done / no
// response" feedback, the persistent queue (retry on launch / foreground, dropping expired commands), status
// refresh requests, and notification button taps.

import KakurenekoCloud
import Foundation
import Testing
import UserNotifications

@MainActor
@Suite("Commands")
struct CommandTests {
    /// A harness whose zone holds one Mac, and a store that has synced it.
    func ready(_ status: (Date) -> MacStatus = { Fixture.status(sv: 7, updatedAt: $0, keepAwakeSeconds: 1800) })
        async throws -> (Harness, PhoneStore) {
        let h = Harness()
        try await h.macSaves(.status(status(h.clock.now)))
        let store = h.makeStore()
        await store.sync()
        return (h, store)
    }

    let controls = FeedbackSlot(macID: "mac-1", channel: .controls)

    @Test func keepAwakeCarriesTheStatusVersionAndThisPhone() async throws {
        let (h, store) = try await ready()
        await store.keepAwake(macID: "mac-1")

        let command = try #require(await h.commands().first)
        #expect(command.macID == "mac-1")
        #expect(command.request == .keepAwake(seconds: 1800), "the Mac's own keep-awake duration")
        #expect(command.stateVersion == 7)
        #expect(command.alertID == nil)
        #expect(command.issuedAt == h.clock.now)
        #expect(command.expiresAt == h.clock.now.addingTimeInterval(600))
        #expect(command.deviceID == store.deviceID)
        #expect(command.deviceName == "iPhone")
        #expect(store.feedback[controls]?.phase == .sent)
        #expect(store.pendingCommands.isEmpty)
    }

    @Test func sleepAndShutDownFollowTheMacsState() async throws {
        let (h, store) = try await ready { Fixture.status(sv: 3, updatedAt: $0, canSleep: false) }
        await store.sleepNow(macID: "mac-1")
        await store.shutDown(macID: "mac-1")
        #expect(await h.commands().isEmpty, "canSleep is false and shutdown is not enabled")

        try await h.macSaves(.status(Fixture.status(sv: 4, updatedAt: h.clock.now, shutdownEnabled: true)))
        await store.sync()
        await store.sleepNow(macID: "mac-1")
        await store.shutDown(macID: "mac-1")
        let requests = await h.commands().map { "\($0.request.wireValue)@\($0.stateVersion ?? -1)" }.sorted()
        #expect(requests == ["shutdown@4", "sleep@4"])

        h.clock.advance(MacStatus.staleAfter + 1)
        await h.cloud.clearOperations()
        await store.sleepNow(macID: "mac-1")
        #expect(await !h.cloud.operations.contains(.save), "never for a Mac that stopped responding")
    }

    @Test func aChangedMacStateConfirmsTheCommand() async throws {
        let (h, store) = try await ready()
        await store.keepAwake(macID: "mac-1")
        h.clock.advance(5)
        try await h.macSaves(.status(Fixture.status(sv: 7, updatedAt: h.clock.now, keepAwakeSeconds: 1800)))
        await store.sync()
        #expect(store.feedback[controls]?.phase == .sent, "a heartbeat with the same state confirms nothing")

        try await h.macSaves(.status(Fixture.status(sv: 8, updatedAt: h.clock.now, keepAwakeSeconds: 1800,
                                                    keepAwakeUntil: h.clock.now.addingTimeInterval(1800))))
        await store.sync()
        #expect(store.feedback[controls]?.phase == .done)
        let feedback = try #require(store.feedback[controls])
        #expect(feedback.message(macName: "Studio") == "Studio will stay awake.")
        #expect(feedback.isVisible(at: h.clock.now))
        #expect(!feedback.isVisible(at: h.clock.now.addingTimeInterval(CommandFeedback.visibleFor)))
    }

    @Test func onlyTheRequestedChangeConfirmsACommand() async throws {
        let (h, store) = try await ready()
        await store.sleepNow(macID: "mac-1")
        // An agent finished: sv moved on, but the Mac is not going to sleep.
        try await h.macSaves(.status(Fixture.status(sv: 8, updatedAt: h.clock.now, keepAwakeSeconds: 1800)))
        await store.sync()
        #expect(store.feedback[controls]?.phase == .sent, "another change of the Mac's state is no confirmation")

        try await h.macSaves(.status(Fixture.status(phase: .windingDown, sv: 8, updatedAt: h.clock.now, keepAwakeSeconds: 1800)))
        await store.sync()
        #expect(store.feedback[controls]?.phase == .done)
    }

    @Test func aMacThatAnswersAfterTheTimeoutStillConfirms() async throws {
        let (h, store) = try await ready()
        await store.keepAwake(macID: "mac-1")
        h.clock.advance(30)
        await store.pollTick()
        #expect(store.feedback[controls]?.phase == .noResponse)

        h.clock.advance(120)
        try await h.macSaves(.status(Fixture.status(sv: 7, updatedAt: h.clock.now, keepAwakeSeconds: 1800,
                                                    keepAwakeUntil: h.clock.now.addingTimeInterval(1800))))
        await store.sync()
        #expect(store.feedback[controls]?.phase == .done, "the Mac woke up and ran it: the line says so")
    }

    @Test func receivedIsNotLeftPendingForever() async throws {
        let (h, store) = try await ready()
        await store.keepAwake(macID: "mac-1")
        let command = try #require(await h.commands().first)
        try await h.cloud.delete([CloudItemID.command(command.id)])
        h.clock.advance(10)
        await store.sync()
        let line = try #require(store.feedback[controls])
        #expect(line.phase == .received)
        #expect(!line.isPending)
        #expect(!line.isVisible(at: h.clock.now.addingTimeInterval(CommandFeedback.visibleFor)))
    }

    @Test func silenceTimesOutAfterThirtySeconds() async throws {
        let (h, store) = try await ready()
        await store.keepAwake(macID: "mac-1")
        h.clock.advance(29)
        await store.pollTick()
        #expect(store.feedback[controls]?.phase == .sent)
        h.clock.advance(1)
        await store.pollTick()
        #expect(store.feedback[controls]?.phase == .noResponse)
    }

    @Test func aHandledCommandIsReceivedNotTimedOut() async throws {
        let (h, store) = try await ready()
        await store.keepAwake(macID: "mac-1")
        let command = try #require(await h.commands().first)
        try await h.cloud.delete([CloudItemID.command(command.id)])
        await store.sync()
        #expect(store.feedback[controls]?.phase == .sent, "not yet: right after the save it may just not be indexed")
        h.clock.advance(10)
        await store.sync()
        #expect(store.feedback[controls]?.phase == .received, "gone from iCloud: the Mac took it")
        h.clock.advance(60)
        await store.pollTick()
        #expect(store.feedback[controls]?.phase == .received)
    }

    @Test func anIgnoredCommandShowsTheMacsReason() async throws {
        let (h, store) = try await ready()
        await store.sleepNow(macID: "mac-1")
        try await h.macSaves(.alert(Fixture.alert("ign", kind: AlertKind.commandIgnored, title: "Command ignored",
                                                  body: "Codex is busy again.", createdAt: h.clock.now)))
        await store.sync()
        #expect(store.feedback[controls]?.phase == .ignored("Codex is busy again."))
    }

    @Test func theTestAlertConfirmsSendTest() async throws {
        let (h, store) = try await ready()
        await store.sendTestAlert()
        let slot = FeedbackSlot(macID: "mac-1", channel: .test)
        #expect(store.feedback[slot]?.phase == .sent)
        #expect(store.feedback[controls] == nil, "its own line")
        #expect(await h.commands().map(\.request) == [.sendTest])
        try await h.macSaves(.alert(Fixture.alert("t", kind: AlertKind.test, createdAt: h.clock.now)))
        await store.sync()
        #expect(store.feedback[slot]?.phase == .done)
    }

    @Test func anUnreachableCommandIsQueuedPersistedAndSentAtTheNextLaunch() async throws {
        let (h, store) = try await ready()
        await h.cloud.failNext(.save, with: .network(retryAfter: nil))
        await store.keepAwake(macID: "mac-1")
        #expect(store.pendingCommands.count == 1)
        #expect(store.feedback[controls]?.phase == .queued)
        #expect(await h.commands().isEmpty)

        let relaunched = h.makeStore()
        #expect(relaunched.pendingCommands.map(\.id) == store.pendingCommands.map(\.id))
        h.clock.advance(60)
        await relaunched.start()
        #expect(relaunched.pendingCommands.isEmpty)
        #expect(await h.commands().map(\.id) == store.pendingCommands.map(\.id), "the same command, not a new one")
    }

    @Test func queuedCommandsAreRetriedOnReturningToTheApp() async throws {
        let (h, store) = try await ready()
        await h.cloud.failNext(.save, with: .network(retryAfter: nil))
        await store.keepAwake(macID: "mac-1")
        await store.sceneDidBecomeActive()
        store.sceneDidEnterBackground()
        #expect(store.pendingCommands.isEmpty)
        #expect(await h.commands().count == 1)
        #expect(store.feedback[controls]?.phase == .sent)
    }

    @Test func expiredQueuedCommandsAreDropped() async throws {
        let (h, store) = try await ready()
        await h.cloud.failNext(.save, with: .network(retryAfter: nil))
        await store.keepAwake(macID: "mac-1")
        h.clock.advance(PhoneStore.Timing.commandLifetime)
        await store.retryPendingCommands()
        #expect(store.pendingCommands.isEmpty)
        #expect(await h.commands().isEmpty)
        guard case .failed = store.feedback[controls]?.phase else {
            Issue.record("expected a failure line, got \(String(describing: store.feedback[controls]))")
            return
        }
    }

    @Test func rejectedCommandsAreNotQueued() async throws {
        let (h, store) = try await ready()
        await h.cloud.failNext(.save, with: .permanent("bad request"))
        await store.keepAwake(macID: "mac-1")
        #expect(store.pendingCommands.isEmpty)
        #expect(store.feedback[controls]?.phase == .failed(CloudError.permanent("bad request").userMessage))
    }

    @Test func aMissingZoneIsRecreatedBeforeSending() async throws {
        let (h, store) = try await ready()
        await h.cloud.deleteZone()
        await store.keepAwake(macID: "mac-1")
        #expect(await h.cloud.zoneExists)
        #expect(await h.commands().count == 1)
    }

    @Test func statusRefreshGoesToMacsOlderThanAMinute() async throws {
        let h = Harness()
        try await h.macSaves(.status(Fixture.status("mac-1", updatedAt: h.clock.now.addingTimeInterval(-10))),
                             .status(Fixture.status("mac-2", name: "Mini", sv: 5, updatedAt: h.clock.now.addingTimeInterval(-300))))
        let store = h.makeStore()
        await store.sync()
        await store.requestStatusRefresh()
        var commands = await h.commands()
        #expect(commands.map(\.macID) == ["mac-2"])
        #expect(commands.first?.request == .refreshStatus)
        #expect(commands.first?.stateVersion == 5)
        #expect(store.feedback.entries.isEmpty, "no feedback line for automatic refreshes")

        await store.requestStatusRefresh()
        #expect(await h.commands().count == 1, "at most one per Mac per minute")

        h.clock.advance(61)
        await store.requestStatusRefresh()
        commands = await h.commands()
        #expect(commands.filter { $0.macID == "mac-2" }.count == 2)
        #expect(commands.filter { $0.macID == "mac-1" }.count == 1)
    }

    @Test func failedRefreshesAreNotQueued() async throws {
        let (h, store) = try await ready { Fixture.status(updatedAt: $0.addingTimeInterval(-600)) }
        await h.cloud.failNext(.save, with: .network(retryAfter: nil))
        await store.requestStatusRefresh()
        #expect(store.pendingCommands.isEmpty)
    }

    // MARK: Notification buttons

    func countdownAlert(_ h: Harness) -> CloudAlert {
        Fixture.alert("A9", kind: AlertKind.countdown, title: "Sleeping in 5 min", createdAt: h.clock.now, expiresIn: 300,
                      actions: [.keepAwake(seconds: 5400), .sleepNow], sv: 9)
    }

    func tap(_ actionID: String, on alert: CloudAlert) throws -> (AlertPresentation.ButtonTap, String?) {
        let action = NotificationResponseAction(actionIdentifier: actionID, userInfo: AlertPresentation.userInfo(for: alert))
        guard case .button(let tap, let macName) = action else { throw ExpectedButton() }
        return (tap, macName)
    }

    struct ExpectedButton: Error {}

    @Test func aButtonTapSendsTheAlertsCommand() async throws {
        let (h, store) = try await ready()
        let alert = countdownAlert(h)
        h.clock.advance(20)
        let (keep, macName) = try tap(NotificationIDs.Action.keepAwake, on: alert)
        #expect(macName == "Studio")
        #expect(await store.handleButtonTap(keep, macName: macName) == .sent)

        let command = try #require(await h.commands().first)
        #expect(command.request == .keepAwake(seconds: 5400), "the alert's duration, not the status'")
        #expect(command.stateVersion == 9, "the alert's sv")
        #expect(command.alertID == "A9")
        #expect(command.issuedAt == h.clock.now)
        #expect(command.expiresAt == alert.expiresAt)
        #expect(command.deviceID == store.deviceID)

        let (sleep, _) = try tap(NotificationIDs.Action.sleepNow, on: alert)
        #expect(store.command(for: sleep).request == .sleepNow)
        #expect(store.command(for: sleep).stateVersion == 9)
        #expect(h.notifications.posted.isEmpty)
    }

    @Test func tappingTheNotificationOpensItsMac() async throws {
        let (h, store) = try await ready()
        let info = AlertPresentation.userInfo(for: countdownAlert(h))
        let open = NotificationResponseAction(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: info)
        #expect(open == .open(macID: "mac-1"))
        #expect(NotificationResponseAction(actionIdentifier: UNNotificationDismissActionIdentifier, userInfo: info) == .ignore)
        #expect(NotificationResponseAction(actionIdentifier: NotificationIDs.Action.sleepNow, userInfo: [:]) == .ignore, "not ours")

        store.selectedTab = .settings
        store.open(macID: "mac-1")
        #expect(store.selectedTab == .macs)
        #expect(store.requestedMacID == "mac-1")
        store.requestedMacID = nil
        store.open(macID: "unknown-mac")
        #expect(store.requestedMacID == nil)
    }

    @Test func anUnreachableTapIsQueuedAndTheUserIsTold() async throws {
        let (h, store) = try await ready()
        await h.cloud.failNext(.save, with: .network(retryAfter: nil))
        let (keep, macName) = try tap(NotificationIDs.Action.keepAwake, on: countdownAlert(h))
        #expect(await store.handleButtonTap(keep, macName: macName) == .queued)
        #expect(store.pendingCommands.count == 1)
        #expect(h.notifications.posted == [.couldNotReach(macID: "mac-1", macName: "Studio")])
        #expect(h.notifications.posted.first?.title == "Couldn't reach Studio")
    }

    @Test func anExpiredAlertsButtonSendsNothing() async throws {
        let (h, store) = try await ready()
        let alert = countdownAlert(h)
        h.clock.advance(300)
        let (sleep, macName) = try tap(NotificationIDs.Action.sleepNow, on: alert)
        #expect(await store.handleButtonTap(sleep, macName: macName) == .expired)
        #expect(await h.commands().isEmpty)
        #expect(h.notifications.posted == [.expiredAlert(macID: "mac-1", macName: "Studio")])
    }

    @Test func aTapWithoutExpiryLastsTenMinutes() async throws {
        let (h, store) = try await ready()
        var info = AlertPresentation.userInfo(for: countdownAlert(h)) as [AnyHashable: Any]
        info[NotificationIDs.UserInfo.expiresAt] = nil
        guard case .button(let tap, _) = NotificationResponseAction(actionIdentifier: NotificationIDs.Action.keepAwake, userInfo: info) else {
            Issue.record("expected a button")
            return
        }
        #expect(store.command(for: tap).expiresAt == h.clock.now.addingTimeInterval(600))
    }
}
