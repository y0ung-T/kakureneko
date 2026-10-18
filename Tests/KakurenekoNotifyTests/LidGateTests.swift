import KakurenekoCloud
@testable import KakurenekoNotify
import KakurenekoKit
import Foundation
import Testing

/// The iPhone's timing (`phoneTiming`): "only when the lid is closed" (default) and "when I'm away" keep alerts on the
/// Mac while the user is there; tests, answers to iPhone taps, shutdowns and safety stops always reach the iPhone; a
/// wait the Mac showed alone reaches the iPhone once the timing allows; presence comes from the latest submit
/// context (a status report updates the lid).
@Suite("iPhone timing", .timeLimit(.minutes(1)))
struct LidGateTests {
    static var lidGated: NotificationSettings {
        let settings = NotificationSettings()
        precondition(settings.phoneTiming == .lidClosed, "the default")
        return settings
    }

    static let lidOpen = Presence(lidClosed: false, screenLocked: false, secondsSinceUserInput: 0)

    static func stalled(_ id: String) -> NotificationIntent {
        .stalled(SessionEffect(kind: .stalled, session: Fixtures.claude(id: id), at: Fixtures.start))
    }

    static func report(lidClosed: Bool) -> MacStatusReport {
        MacStatusReport(phase: .working, headline: "1 agent working", lidClosed: lidClosed, stateVersion: 42)
    }

    @Test func anOpenLidKeepsAlertsOnTheMac() async throws {
        let h = try Harness(settings: Self.lidGated)
        defer { h.cleanup() }
        try await h.startReady()
        _ = await h.dispatcher.submit(Self.stalled("c-1"), context: Fixtures.context(presence: Self.lidOpen))
        #expect(await eventually { h.posted.count == 1 })
        await settle()
        #expect(await h.saved.isEmpty)
        #expect(await h.dispatcher.status().outboxCount == 0)
        #expect(h.logText.contains("stalled not sent to the iPhone: lid open"))

        _ = await h.dispatcher.submit(Self.stalled("c-2"), context: Fixtures.context(presence: .away))
        #expect(await eventually { await h.saved.count == 1 })
        #expect(h.posted.count == 2, "the Mac still shows it")
        await h.dispatcher.stop()
    }

    @Test func aMacWithoutALidSendsAlertsOnceTheUserIsAway() async throws {
        let h = try Harness(settings: Self.lidGated)
        defer { h.cleanup() }
        try await h.startReady()
        let atTheDesk = Presence(lidClosed: false, screenLocked: false, secondsSinceUserInput: 0, hasLid: false)
        _ = await h.dispatcher.submit(Self.stalled("c-1"), context: Fixtures.context(presence: atTheDesk))
        #expect(await eventually { h.posted.count == 1 })
        await settle()
        #expect(await h.saved.isEmpty, "at the Mac: the Mac shows it")

        let away = Presence(lidClosed: false, screenLocked: true, secondsSinceUserInput: 900, hasLid: false)
        _ = await h.dispatcher.submit(Self.stalled("c-2"), context: Fixtures.context(presence: away))
        #expect(await eventually { await h.saved.count == 1 }, "a lid that can never close must not hold alerts back forever")
        await h.dispatcher.stop()
    }

    @Test func turnedOffTheIPhoneGetsEverything() async throws {
        var settings = NotificationSettings()
        settings.phoneTiming = .always
        let h = try Harness(settings: settings)
        defer { h.cleanup() }
        try await h.startReady()
        _ = await h.dispatcher.submit(Self.stalled("c-1"), context: Fixtures.context(presence: Self.lidOpen))
        #expect(await eventually { await h.saved.count == 1 })
        await h.dispatcher.stop()
    }

    @Test func theTestAnswersToIPhoneTapsAndTheShutdownAlwaysGo() async throws {
        let h = try Harness(settings: Self.lidGated)
        defer { h.cleanup() }
        try await h.startReady()
        await h.dispatcher.updateMacStatus(Self.report(lidClosed: false))
        try await h.dispatcher.sendTest()
        _ = await h.dispatcher.submit(.commandIgnored(reason: "Codex in web is busy again"),
                                      context: Fixtures.context(presence: Self.lidOpen))
        _ = await h.dispatcher.submit(.shuttingDown(at: Fixtures.start.addingTimeInterval(60), requestedFromPhone: true),
                                      context: Fixtures.context(presence: Self.lidOpen))
        _ = await h.dispatcher.submit(.warning(title: "Hotspot", body: "b"), context: Fixtures.context(presence: Self.lidOpen))
        #expect(await eventually { await h.saved.count == 3 })
        await settle()
        #expect(await Set(h.saved.map(\.kind)) == ["test", "commandIgnored", "shuttingDown"], "the warning stays on the Mac")
        await h.dispatcher.stop()
    }

    @Test func theLatestStatusReportDecidesForTimedMessages() async throws {
        let h = try Harness(settings: Self.lidGated)
        defer { h.cleanup() }
        try await h.startReady()
        // A finish batched with the lid open, flushed after the lid closed: it goes to the iPhone.
        #expect(await h.dispatcher.submit(.finished(Fixtures.finished(), stillRunning: 0),
                                          context: Fixtures.context(presence: Self.lidOpen)) == .batched)
        await h.dispatcher.updateMacStatus(Self.report(lidClosed: true))
        #expect(await happensBy(h.clock, within: .seconds(NotificationPolicy.batchWindow + 2)) { await h.saved.count == 1 })

        // And the other way round: the lid opened before the flush.
        #expect(await h.dispatcher.submit(.finished(Fixtures.finished(Fixtures.claude(id: "c-2")), stillRunning: 0),
                                          context: Fixtures.context(h.clock.now(), presence: .away)) == .batched)
        await h.dispatcher.updateMacStatus(Self.report(lidClosed: false))
        #expect(await happensBy(h.clock, within: .seconds(NotificationPolicy.batchWindow + 2)) { h.posted.count == 2 })
        await settle()
        #expect(await h.saved.count == 1)
        await h.dispatcher.stop()
    }

    @Test func whenAwayTheIPhoneWaitsForTheUserToLeave() async throws {
        var settings = NotificationSettings()
        settings.phoneTiming = .away
        let h = try Harness(settings: settings)
        defer { h.cleanup() }
        try await h.startReady()
        let threshold = TimeInterval(settings.awayIdleSeconds)
        let present = Presence(lidClosed: false, screenLocked: false, secondsSinceUserInput: threshold - 1)
        _ = await h.dispatcher.submit(Self.stalled("c-1"), context: Fixtures.context(presence: present))
        #expect(await eventually { h.posted.count == 1 })
        await settle()
        #expect(await h.saved.isEmpty, "at the Mac: Mac only")
        #expect(h.logText.contains("stalled not sent to the iPhone: user at the Mac"))
        let idle = Presence(lidClosed: false, screenLocked: false, secondsSinceUserInput: threshold)
        let locked = Presence(lidClosed: false, screenLocked: true, secondsSinceUserInput: 0)
        _ = await h.dispatcher.submit(Self.stalled("c-2"), context: Fixtures.context(presence: idle))
        _ = await h.dispatcher.submit(Self.stalled("c-3"), context: Fixtures.context(presence: locked))
        _ = await h.dispatcher.submit(Self.stalled("c-4"), context: Fixtures.context(presence: .away))
        #expect(await eventually { await h.saved.count == 3 }, "idle, locked and lid closed all count as away")
        await h.dispatcher.stop()
    }

    @Test func aWaitTheMacShowedAloneReachesTheIPhoneWhenTheLidCloses() async throws {
        let h = try Harness(settings: Self.lidGated)
        defer { h.cleanup() }
        try await h.startReady()
        let intent = NotificationIntent.needsInput(Fixtures.needsInput(), awakeUntil: nil)
        #expect(isQueued(await h.dispatcher.submit(intent, context: Fixtures.context(presence: Self.lidOpen))))
        #expect(await eventually { h.posted.count == 1 })
        await settle()
        #expect(await h.saved.isEmpty)
        // The lid closes; the coordinator re-submits the still-waiting session: the iPhone gets its copy, the Mac
        // does not show it again.
        #expect(isQueued(await h.dispatcher.submit(intent, context: Fixtures.context(presence: .away))))
        #expect(await eventually { await h.saved.count == 1 })
        #expect(await h.saved[0].title == "Codex needs your input \u{00B7} web")
        await settle()
        #expect(h.posted.count == 1)
        #expect(await h.dispatcher.submit(intent, context: Fixtures.context(presence: .away)) == .suppressed("duplicate"))
        await settle()
        #expect(await h.saved.count == 1)
        // Muted in the meantime: no late copy.
        var muted = Self.lidGated
        muted.mutedKinds = [.needsInput]
        let other = NotificationIntent.needsInput(Fixtures.needsInput(Fixtures.codex(id: "x-2")), awakeUntil: nil)
        _ = await h.dispatcher.submit(other, context: Fixtures.context(presence: Self.lidOpen))
        await h.dispatcher.applySettings(muted)
        #expect(await h.dispatcher.submit(other, context: Fixtures.context(presence: .away)) == .suppressed("duplicate"))
        await h.dispatcher.stop()
    }

    func isQueued(_ d: NotificationDisposition) -> Bool { if case .queued = d { true } else { false } }

    @Test func withoutMacNotificationsAnOpenLidHoldsAlertsBack() async throws {
        let h = try Harness(settings: Self.lidGated, local: RecordingLocalNotifications(authorization: .denied))
        defer { h.cleanup() }
        try await h.startReady()
        let disposition = await h.dispatcher.submit(Self.stalled("c-1"), context: Fixtures.context(presence: Self.lidOpen))
        #expect(disposition == .suppressed("lidOpen"))
        #expect(await h.dispatcher.status().outboxCount == 0)

        // A needs-input push delivered with the lid closed: its reminder waits while the lid is open.
        let effect = Fixtures.needsInput(at: h.clock.now())
        _ = await h.dispatcher.submit(.needsInput(effect, awakeUntil: nil), context: Fixtures.context(h.clock.now(), presence: .away))
        #expect(await eventually { await h.saved.count == 1 })
        await h.dispatcher.updateMacStatus(Self.report(lidClosed: false))
        let reminderAfter = TimeInterval(h.settings.needsInputReminderMinutes * 60)
        for _ in 0..<Int((reminderAfter + 60) / 30) {
            h.clock.advance(by: .seconds(30))
            await settle()
        }
        #expect(await eventually { h.logText.contains("needs-input reminder held back: lid open") })
        #expect(await h.saved.count == 1)
        // The lid closes (the coordinator re-submits the wait): the held reminder goes out.
        _ = await h.dispatcher.submit(.needsInput(effect, awakeUntil: nil), context: Fixtures.context(h.clock.now(), presence: .away))
        #expect(await eventually { await h.saved.count == 2 })
        await h.dispatcher.stop()
    }
}
