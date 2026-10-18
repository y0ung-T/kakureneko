@testable import KakurenekoNotify
import KakurenekoCloud
import KakurenekoKit
import Foundation
import Testing

/// Policy behaviour end to end through `NotificationDispatcher` (InMemoryCloudStore + recording Mac notifications + TestClock).
@Suite("Policy through the dispatcher", .timeLimit(.minutes(1)))
struct PolicyTests {
    func isQueued(_ d: NotificationDisposition) -> Bool { if case .queued = d { true } else { false } }

    @Test func presentIsSuppressedThenAwayResubmitIsDeliveredOnce() async throws {
        let h = try Harness(settings: Fixtures.phoneWhenAway)
        defer { h.cleanup() }
        try await h.startReady()
        let intent = NotificationIntent.needsInput(Fixtures.needsInput(), awakeUntil: Fixtures.at(22, 30))
        #expect(await h.dispatcher.submit(intent, context: Fixtures.context(presence: .present)) == .suppressed("present"))
        await settle()
        #expect(await h.saved.isEmpty)
        // The coordinator re-submits on present → away: now it goes out.
        #expect(isQueued(await h.dispatcher.submit(intent, context: Fixtures.context())))
        #expect(await eventually { await h.saved.count == 1 })
        #expect(await h.saved[0].title == "Codex needs your input \u{00B7} web")
        #expect(await h.saved[0].interruption == .timeSensitive)
        // Any further re-submit of the same wait is a duplicate.
        #expect(await h.dispatcher.submit(intent, context: Fixtures.context()) == .suppressed("duplicate"))
        await settle()
        #expect(await h.saved.count == 1)
        await h.dispatcher.stop()
    }

    @Test func finishedIsFoldedIntoACountdownOfTheSameBatch() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        #expect(await h.dispatcher.submit(.finished(Fixtures.finished(), stillRunning: 0), context: Fixtures.context()) == .batched)
        h.clock.advance(by: .seconds(5))
        let countdown = NotificationIntent.countdown(endsAt: h.clock.now().addingTimeInterval(300), reason: .finished,
                                                     finished: [], waiting: [], offerShutdown: false)
        #expect(isQueued(await h.dispatcher.submit(countdown, context: Fixtures.context(h.clock.now()))))
        #expect(await eventually { await h.saved.count == 1 })
        h.clock.advance(by: .seconds(30))
        await settle()
        #expect(await h.saved.count == 1) // only the countdown
        let json = await h.saved[0]
        #expect(json.title == "All agents done, sleeping in 5 min")
        #expect(json.body == "Finished: api (Claude Code, 42m).")
        await h.dispatcher.stop()
    }

    @Test func finishesWithinFifteenSecondsBecomeOneMessage() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        let sessions = [Fixtures.claude(), Fixtures.claude(id: "c-2", cwd: "/w/docs"), Fixtures.claude(id: "c-3", cwd: "/w/infra")]
        for (i, session) in sessions.enumerated() {
            #expect(await h.dispatcher.submit(.finished(Fixtures.finished(session, workedFor: 600), stillRunning: 2 - i),
                                              context: Fixtures.context(h.clock.now())) == .batched)
            h.clock.advance(by: .seconds(4))
        }
        h.clock.advance(by: .seconds(2)) // t + 14 s
        await settle()
        #expect(await h.saved.isEmpty)
        h.clock.advance(by: .seconds(1)) // t + 15 s
        #expect(await eventually { await h.saved.count == 1 })
        let json = await h.saved[0]
        #expect(json.title == "3 agents finished")
        #expect(json.body == "Finished: api (Claude Code, 10m), docs (Claude Code, 10m), infra (Claude Code, 10m). No other agents running.")
        await h.dispatcher.stop()
    }

    @Test func rateLimitOverflowGoesIntoADigest() async throws {
        var settings = NotificationSettings()
        settings.rateLimitPerTenMinutes = 2
        let h = try Harness(settings: settings)
        defer { h.cleanup() }
        try await h.startReady()
        var dispositions: [NotificationDisposition] = []
        for i in 0..<4 {
            let session = Fixtures.claude(id: "c\(i)", cwd: "/w/p\(i)")
            dispositions.append(await h.dispatcher.submit(.stalled(SessionEffect(kind: .stalled, session: session, at: Fixtures.start)),
                                                          context: Fixtures.context()))
        }
        #expect(dispositions.map(isQueued) == [true, true, false, false])
        #expect(dispositions[2] == .folded && dispositions[3] == .folded)
        #expect(await eventually { await h.saved.count == 2 })
        #expect(await h.dispatcher.digestCountForTesting == 2)
        h.clock.advance(by: .seconds(599))
        await settle()
        #expect(await h.saved.count == 2)
        h.clock.advance(by: .seconds(1))
        #expect(await eventually { await h.saved.count == 3 })
        let digest = await h.saved[2]
        #expect(digest.title == "2 more updates")
        #expect(digest.body == "\u{2022} Claude Code looks stuck \u{00B7} p2\n\u{2022} Claude Code looks stuck \u{00B7} p3")
        await h.dispatcher.stop()
    }

    @Test func quietHoursDowngradeToLowPriorityAndNeverDrop() async throws {
        var settings = NotificationSettings()
        settings.quietHours = QuietHours(enabled: true, startMinute: 21 * 60, endMinute: 7 * 60) // now = 22:00 UTC
        let h = try Harness(settings: settings)
        defer { h.cleanup() }
        try await h.startReady()
        _ = await h.dispatcher.submit(.needsInput(Fixtures.needsInput(), awakeUntil: nil), context: Fixtures.context())
        _ = await h.dispatcher.submit(.safetyTrip(.thermalCritical, runningAgents: 1), context: Fixtures.context())
        _ = await h.dispatcher.submit(.asleep(SleepRecord(startedAt: Fixtures.at(21, 0), endedAt: Fixtures.start, reason: .countdownElapsed),
                                              batteryPercent: 50), context: Fixtures.context())
        #expect(await eventually { await h.saved.count == 3 })
        #expect(await h.saved.map(\.interruption) == [.passive, .passive, .passive])
        await h.dispatcher.stop()
    }

    @Test func needsInputGetsExactlyOneReminder() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        let intent = NotificationIntent.needsInput(Fixtures.needsInput(), awakeUntil: nil)
        _ = await h.dispatcher.submit(intent, context: Fixtures.context())
        #expect(await eventually { await h.saved.count == 1 })
        h.clock.advance(by: .seconds(599))
        await settle()
        #expect(await h.saved.count == 1)
        h.clock.advance(by: .seconds(1))
        #expect(await eventually { await h.saved.count == 2 })
        #expect(await h.saved[1].title == "Reminder: Codex needs your input \u{00B7} web")
        let alerts = await h.saved
        #expect(alerts[1].replaceKey == alerts[0].replaceKey)
        h.clock.advance(by: .seconds(1800))
        await settle()
        #expect(await h.saved.count == 2)
        #expect(await h.dispatcher.submit(intent, context: Fixtures.context(h.clock.now())) == .suppressed("duplicate"))
        await h.dispatcher.stop()
    }

    @Test func resolvedCancelsTheReminderAndNeverSends() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        let effect = Fixtures.needsInput()
        _ = await h.dispatcher.submit(.needsInput(effect, awakeUntil: nil), context: Fixtures.context())
        #expect(await eventually { await h.saved.count == 1 })
        #expect(await h.dispatcher.submit(.resolved(effect.session.key), context: Fixtures.context()) == .suppressed("resolved"))
        h.clock.advance(by: .seconds(1200))
        await settle()
        #expect(await h.saved.count == 1)
        await h.dispatcher.stop()
    }

    @Test func resolvedDropsQueuedNeedsInputMessages() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        await h.cloud?.setPersistentFailure(.save, .network(retryAfter: nil))
        try await h.startReady()
        let effect = Fixtures.needsInput()
        _ = await h.dispatcher.submit(.needsInput(effect, awakeUntil: nil), context: Fixtures.context())
        #expect(await eventually { await h.cloud?.count(.save) == 1 })
        #expect(await eventually { await h.dispatcher.outboxItemsForTesting.first?.attempts == 1 })
        _ = await h.dispatcher.submit(.resolved(effect.session.key), context: Fixtures.context())
        #expect(await h.dispatcher.status().outboxCount == 0)
        await h.cloud?.setPersistentFailure(.save, nil)
        h.clock.advance(by: .seconds(10))
        await settle()
        #expect(await h.cloud?.count(.save) == 1, "the withdrawn wait is never retried")
        #expect(await h.saved.isEmpty)
        await h.dispatcher.stop()
    }

    @Test func reminderHeldWhilePresentGoesOutOnTheAwayResubmit() async throws {
        let h = try Harness(settings: Fixtures.phoneWhenAway)
        defer { h.cleanup() }
        try await h.startReady()
        let intent = NotificationIntent.needsInput(Fixtures.needsInput(), awakeUntil: nil)
        _ = await h.dispatcher.submit(intent, context: Fixtures.context())
        #expect(await eventually { await h.saved.count == 1 })
        // The user came back: a later submit carries a "present" context.
        _ = await h.dispatcher.submit(.stalled(SessionEffect(kind: .stalled, session: Fixtures.claude(), at: Fixtures.start)),
                                      context: Fixtures.context(presence: .present))
        h.clock.advance(by: .seconds(600))
        await settle()
        #expect(await h.saved.count == 1)
        // They leave again: the coordinator re-submits the still-waiting session → duplicate, but the reminder goes.
        #expect(await h.dispatcher.submit(intent, context: Fixtures.context(h.clock.now())) == .suppressed("duplicate"))
        #expect(await eventually { await h.saved.count == 2 })
        #expect(await h.saved[1].title.hasPrefix("Reminder: "))
        await h.dispatcher.stop()
    }

    @Test func resolvingAWaitNeverReleasesItsHeldReminder() async throws {
        let h = try Harness(settings: Fixtures.phoneWhenAway)
        defer { h.cleanup() }
        try await h.startReady()
        let effect = Fixtures.needsInput()
        _ = await h.dispatcher.submit(.needsInput(effect, awakeUntil: nil), context: Fixtures.context())
        #expect(await eventually { await h.saved.count == 1 })
        _ = await h.dispatcher.submit(.stalled(SessionEffect(kind: .stalled, session: Fixtures.claude(), at: Fixtures.start)),
                                      context: Fixtures.context(presence: .present))
        h.clock.advance(by: .seconds(600)) // the reminder is due but held: the user is present
        await settle()
        // The user answered and walked away: the resolved submit carries an "away" context.
        #expect(await h.dispatcher.submit(.resolved(effect.session.key), context: Fixtures.context(h.clock.now())) == .suppressed("resolved"))
        await settle()
        #expect(await h.saved.count == 1)
        await h.dispatcher.stop()
    }

    @Test func wentQuietIsBatchedAndAbsorbedByItsCountdown() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        let quiet = SessionEffect(kind: .wentQuiet, session: Fixtures.aider(), at: Fixtures.start)
        #expect(await h.dispatcher.submit(.wentQuiet(quiet, sleepsAt: Fixtures.at(22, 5)), context: Fixtures.context()) == .batched)
        let countdown = NotificationIntent.countdown(endsAt: Fixtures.at(22, 5), reason: .wentQuiet, finished: [], waiting: [],
                                                     offerShutdown: false)
        #expect(isQueued(await h.dispatcher.submit(countdown, context: Fixtures.context())))
        #expect(await eventually { await h.saved.count == 1 })
        h.clock.advance(by: .seconds(20))
        await settle()
        #expect(await h.savedTitles == ["Aider went quiet, sleeping in 5 min"])
        #expect(await h.saved[0].body == "Finished or waiting for you: proj (Aider).")
        await h.dispatcher.stop()
    }

    @Test func aLoneWentQuietIsSentAfterTheBatchWindow() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        let quiet = SessionEffect(kind: .wentQuiet, session: Fixtures.aider(), at: Fixtures.start)
        #expect(await h.dispatcher.submit(.wentQuiet(quiet, sleepsAt: Fixtures.at(22, 5)), context: Fixtures.context()) == .batched)
        h.clock.advance(by: .seconds(14))
        await settle()
        #expect(await h.saved.isEmpty)
        h.clock.advance(by: .seconds(1)) // the 15 s batch window closes
        #expect(await eventually { await h.saved.count == 1 })
        let json = await h.saved[0]
        #expect(json.title == "Aider went quiet \u{00B7} proj")
        // Rendered when the batch flushed (22:00:15): "sleeps in 5 min" rounds the remaining 4 m 45 s.
        #expect(json.body == "Finished or waiting for you. Mac sleeps in 5 min.")
        #expect(json.actions.count == 2)
        await h.dispatcher.stop()
    }

    @Test func mutingAKindDropsWhatIsQueuedOrBatched() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        await h.cloud?.setPersistentFailure(.save, .network(retryAfter: nil))
        try await h.startReady()
        _ = await h.dispatcher.submit(.stalled(SessionEffect(kind: .stalled, session: Fixtures.claude(), at: Fixtures.start)),
                                      context: Fixtures.context())
        #expect(await h.dispatcher.submit(.finished(Fixtures.finished(Fixtures.claude(id: "c-2")), stillRunning: 0),
                                          context: Fixtures.context()) == .batched)
        #expect(await eventually { await h.dispatcher.outboxItemsForTesting.first?.attempts == 1 })
        var settings = NotificationSettings()
        settings.mutedKinds = [.stalled, .finished]
        await h.dispatcher.applySettings(settings)
        #expect(await h.dispatcher.status().outboxCount == 0)
        await h.cloud?.setPersistentFailure(.save, nil)
        h.clock.advance(by: .seconds(30))
        await settle()
        #expect(await h.dispatcher.status().outboxCount == 0)
        #expect(await h.cloud?.count(.save) == 1, "only the failed attempt made before muting")
        #expect(await h.saved.isEmpty)
        await h.dispatcher.stop()
    }

    @Test func resolvedAlsoDropsAWaitFoldedIntoTheDigest() async throws {
        var settings = NotificationSettings()
        settings.rateLimitPerTenMinutes = 1
        let h = try Harness(settings: settings)
        defer { h.cleanup() }
        try await h.startReady()
        _ = await h.dispatcher.submit(.stalled(SessionEffect(kind: .stalled, session: Fixtures.claude(), at: Fixtures.start)),
                                      context: Fixtures.context())
        let effect = Fixtures.needsInput()
        #expect(await h.dispatcher.submit(.needsInput(effect, awakeUntil: nil), context: Fixtures.context()) == .folded)
        #expect(await h.dispatcher.digestCountForTesting == 1)
        _ = await h.dispatcher.submit(.resolved(effect.session.key), context: Fixtures.context())
        #expect(await h.dispatcher.digestCountForTesting == 0)
        h.clock.advance(by: .seconds(1200))
        await settle()
        #expect(await h.saved.count == 1)
        await h.dispatcher.stop()
    }

    @Test func remoteControlSessionsAreSkippedForEveryAgentIntent() async throws {
        var settings = NotificationSettings()
        settings.skipClaudeRemoteControlSessions = true
        let h = try Harness(settings: settings)
        defer { h.cleanup() }
        try await h.startReady()
        let session = Fixtures.claude(state: .waiting(kind: .permission, since: Fixtures.at(21, 58)), remoteControl: true)
        let intents: [NotificationIntent] = [
            .needsInput(SessionEffect(kind: .needsInput, session: session, at: Fixtures.at(21, 58)), awakeUntil: nil),
            .stalled(SessionEffect(kind: .stalled, session: session, at: Fixtures.start)),
            .wentQuiet(SessionEffect(kind: .wentQuiet, session: session, at: Fixtures.start), sleepsAt: nil),
        ]
        for intent in intents {
            #expect(await h.dispatcher.submit(intent, context: Fixtures.context()) == .suppressed("remoteControl"))
        }
        // Power-level messages are not about one session and still go out.
        #expect(isQueued(await h.dispatcher.submit(.safetyTrip(.thermalCritical, runningAgents: 1), context: Fixtures.context())))
        await h.dispatcher.stop()
    }

    @Test func shortTurnsFinishSilentlyWhenAMinimumIsSet() async throws {
        var settings = NotificationSettings()
        settings.minimumWorkSeconds = 120
        let h = try Harness(settings: settings)
        defer { h.cleanup() }
        try await h.startReady()
        func finished(_ id: String, _ worked: TimeInterval?) -> NotificationIntent {
            var session = Fixtures.claude(id: id)
            session.lastTurnDuration = nil
            return .finished(Fixtures.finished(session, workedFor: worked), stillRunning: 0)
        }
        #expect(await h.dispatcher.submit(finished("a", 119), context: Fixtures.context()) == .suppressed("shortTurn"))
        #expect(await h.dispatcher.submit(.wentQuiet(Fixtures.finished(Fixtures.claude(id: "q"), workedFor: 30), sleepsAt: nil),
                                          context: Fixtures.context()) == .suppressed("shortTurn"))
        #expect(await h.dispatcher.submit(finished("b", 120), context: Fixtures.context()) == .batched)
        #expect(await h.dispatcher.submit(finished("c", nil), context: Fixtures.context()) == .batched, "unknown duration: alert")
        // The session's last turn stands in for a missing effect duration.
        var known = Fixtures.claude(id: "d")
        known.lastTurnDuration = 10
        #expect(await h.dispatcher.submit(.finished(Fixtures.finished(known, workedFor: nil), stillRunning: 0),
                                          context: Fixtures.context()) == .suppressed("shortTurn"))
        // Waiting agents always alert.
        #expect(isQueued(await h.dispatcher.submit(.needsInput(Fixtures.needsInput(), awakeUntil: nil), context: Fixtures.context())))
        await h.dispatcher.stop()

        let off = try Harness()
        defer { off.cleanup() }
        try await off.startReady()
        #expect(await off.dispatcher.submit(finished("a", 1), context: Fixtures.context()) == .batched, "off by default")
        await off.dispatcher.stop()
    }

    @Test func commandAnswersReachAPresentUser() async throws {
        let h = try Harness(settings: Fixtures.phoneWhenAway)
        defer { h.cleanup() }
        try await h.startReady()
        // The user tapped a phone button while at the Mac: the answer to that tap must still arrive.
        #expect(isQueued(await h.dispatcher.submit(.commandIgnored(reason: "Codex in web is busy again"),
                                                   context: Fixtures.context(presence: .present))))
        #expect(isQueued(await h.dispatcher.submit(.shuttingDown(at: Fixtures.start.addingTimeInterval(60), requestedFromPhone: true),
                                                   context: Fixtures.context(presence: .present))))
        #expect(await h.dispatcher.submit(.warning(title: "Hotspot", body: "b"), context: Fixtures.context(presence: .present))
            == .suppressed("present"))
        #expect(await eventually { await h.saved.count == 2 })
        #expect(await h.savedTitles == ["Command ignored", "Mac is shutting down"])
        await h.dispatcher.stop()
    }

    @Test func disabledSuppressesEverythingButTest() async throws {
        var settings = NotificationSettings()
        settings.enabled = false
        let h = try Harness(settings: settings)
        defer { h.cleanup() }
        try await h.startReady()
        #expect(await h.dispatcher.submit(.finished(Fixtures.finished(), stillRunning: 0), context: Fixtures.context()) == .suppressed("disabled"))
        #expect(await h.dispatcher.submit(.safetyTrip(.thermalCritical, runningAgents: 0), context: Fixtures.context()) == .suppressed("disabled"))
        #expect(isQueued(await h.dispatcher.submit(.test, context: Fixtures.context(presence: .present))))
        #expect(await eventually { await h.saved.count == 1 })
        #expect(await h.savedTitles == ["Kakureneko test"])
        #expect(h.posted.map(\.title) == ["Kakureneko test"], "shown on the Mac too")
        await h.dispatcher.stop()
    }

    @Test func disablingDropsQueuedMessages() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        await h.cloud?.setPersistentFailure(.save, .network(retryAfter: nil))
        try await h.startReady()
        _ = await h.dispatcher.submit(.stalled(SessionEffect(kind: .stalled, session: Fixtures.claude(), at: Fixtures.start)), context: Fixtures.context())
        #expect(await eventually { await h.dispatcher.status().outboxCount == 1 })
        var disabled = NotificationSettings()
        disabled.enabled = false
        await h.dispatcher.applySettings(disabled)
        #expect(await h.dispatcher.status().outboxCount == 0)
        await h.dispatcher.stop()
    }

    @Test func mutedKindsRemoteControlAndNoChannel() async throws {
        var settings = NotificationSettings()
        settings.mutedKinds = [.stalled]
        settings.skipClaudeRemoteControlSessions = true
        // No iCloud in this build and Mac notifications not allowed yet: nothing can show a message.
        let h = try Harness(settings: settings, noCloud: true, local: RecordingLocalNotifications(authorization: .notDetermined))
        defer { h.cleanup() }
        await h.dispatcher.start()
        #expect(await h.dispatcher.submit(.finished(Fixtures.finished(), stillRunning: 0), context: Fixtures.context()) == .suppressed("noChannel"))
        #expect(await h.dispatcher.requestMacAuthorization() == .authorized)
        let stalled = NotificationIntent.stalled(SessionEffect(kind: .stalled, session: Fixtures.claude(), at: Fixtures.start))
        #expect(await h.dispatcher.submit(stalled, context: Fixtures.context()) == .suppressed("muted"))
        let rc = NotificationIntent.finished(Fixtures.finished(Fixtures.claude(remoteControl: true)), stillRunning: 0)
        #expect(await h.dispatcher.submit(rc, context: Fixtures.context()) == .suppressed("remoteControl"))
        #expect(await h.dispatcher.submit(.finished(Fixtures.finished(), stillRunning: 0), context: Fixtures.context()) == .batched)
        await h.dispatcher.stop()
        #expect(await h.dispatcher.submit(.test, context: Fixtures.context()) == .suppressed("stopped"))
    }

    @Test func alwaysPushIgnoresPresence() async throws {
        var settings = NotificationSettings()
        settings.phoneTiming = .always
        let h = try Harness(settings: settings)
        defer { h.cleanup() }
        try await h.startReady()
        #expect(isQueued(await h.dispatcher.submit(.stalled(SessionEffect(kind: .stalled, session: Fixtures.claude(), at: Fixtures.start)),
                                                   context: Fixtures.context(presence: .present))))
        #expect(await eventually { await h.saved.count == 1 })
        await h.dispatcher.stop()
    }

    @Test func detailLevelFollowsSettings() async throws {
        var settings = NotificationSettings()
        settings.detailLevel = .private
        let h = try Harness(settings: settings)
        defer { h.cleanup() }
        try await h.startReady()
        _ = await h.dispatcher.submit(.stalled(SessionEffect(kind: .stalled, session: Fixtures.claude(), at: Fixtures.start)), context: Fixtures.context())
        #expect(await eventually { await h.saved.count == 1 })
        #expect(await h.savedTitles == ["An agent looks stuck"])
        settings.detailLevel = .detailed
        await h.dispatcher.applySettings(settings)
        _ = await h.dispatcher.submit(.stalled(SessionEffect(kind: .stalled, session: Fixtures.claude(id: "c-9"), at: Fixtures.start)), context: Fixtures.context())
        #expect(await eventually { await h.saved.count == 2 })
        #expect(await h.saved[1].body.contains(Fixtures.preview))
        await h.dispatcher.stop()
    }
}
