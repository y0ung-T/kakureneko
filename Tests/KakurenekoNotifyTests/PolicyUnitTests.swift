@testable import KakurenekoNotify
import KakurenekoKit
import Foundation
import Testing

/// `NotificationPolicy` as a pure state machine (the dispatcher-level behaviour is in PolicyTests).
@Suite("NotificationPolicy (pure)", .timeLimit(.minutes(1)))
struct PolicyUnitTests {
    let now = Fixtures.start

    @Test func gateOrder() {
        var settings = NotificationSettings()
        settings.enabled = false
        var policy = NotificationPolicy(settings: settings)
        let finished = NotificationIntent.finished(Fixtures.finished(), stillRunning: 0)
        #expect(policy.gate(finished, context: Fixtures.context(), hasChannel: true) == .suppress("disabled"))
        #expect(policy.gate(.test, context: Fixtures.context(presence: .present), hasChannel: true) == .proceed)
        #expect(policy.gate(.test, context: Fixtures.context(), hasChannel: false) == .suppress("noChannel"))

        settings.enabled = true
        settings.mutedKinds = [.finished]
        policy.settings = settings
        #expect(policy.gate(finished, context: Fixtures.context(), hasChannel: true) == .suppress("muted"))
        #expect(policy.gate(finished, context: Fixtures.context(), hasChannel: false) == .suppress("noChannel"))
    }

    @Test func theIPhoneAlwaysGetsTestsAnswersShutdownsAndSafetyStops() {
        #expect(NotificationPolicy.phoneTimingBypass == [.safetyTrip, .test, .commandIgnored, .shuttingDown])
    }

    @Test func aWaitShownOnTheMacOnlyIsOwedToTheIPhone() {
        var policy = NotificationPolicy(settings: NotificationSettings())
        let effect = Fixtures.needsInput()
        let key = effect.session.key
        let since = Fixtures.at(21, 50)
        #expect(policy.gate(.needsInput(effect, awakeUntil: nil), context: Fixtures.context(), hasChannel: true) == .proceed)
        #expect(!policy.isDeliveredWithoutPhone(key, since: since), "not delivered yet")
        policy.markDelivered(key, since: since, at: now, toPhone: false)
        #expect(policy.isDeliveredWithoutPhone(key, since: since))
        #expect(!policy.isDeliveredWithoutPhone(key, since: Fixtures.at(22, 0)), "another wait")
        policy.markPhoneDelivered(key)
        #expect(!policy.isDeliveredWithoutPhone(key, since: since))
        var both = NotificationPolicy(settings: NotificationSettings())
        _ = both.gate(.needsInput(effect, awakeUntil: nil), context: Fixtures.context(), hasChannel: true)
        both.markDelivered(key, since: since, at: now, toPhone: true)
        #expect(!both.isDeliveredWithoutPhone(key, since: since))
    }

    @Test func remoteControlSkipOnlyForClaude() {
        var settings = NotificationSettings()
        settings.skipClaudeRemoteControlSessions = true
        let policy = NotificationPolicy(settings: settings)
        #expect(policy.isSkippedRemoteControl(Fixtures.claude(remoteControl: true)))
        #expect(!policy.isSkippedRemoteControl(Fixtures.claude(remoteControl: false)))
        var codex = Fixtures.codex()
        codex.remoteControlConnected = true
        #expect(!policy.isSkippedRemoteControl(codex))
        #expect(!NotificationPolicy(settings: NotificationSettings()).isSkippedRemoteControl(Fixtures.claude(remoteControl: true)))
    }

    @Test func needsInputDedupeAndSingleReminder() {
        var policy = NotificationPolicy(settings: NotificationSettings())
        let effect = Fixtures.needsInput()
        let key = effect.session.key
        let since = Fixtures.at(21, 50)
        let intent = NotificationIntent.needsInput(effect, awakeUntil: nil)
        // First attempt with no channel (only the iPhone, and its timing holds it back): nothing is remembered.
        #expect(policy.gate(intent, context: Fixtures.context(presence: .present), hasChannel: false) == .suppress("noChannel"))
        #expect(policy.waits[key] == nil)
        // Re-submitted once a channel takes it: proceeds; once delivered, further re-submits are duplicates.
        #expect(policy.gate(intent, context: Fixtures.context(), hasChannel: true) == .proceed)
        #expect(policy.waits[key]?.delivered == false)
        policy.markDelivered(key, since: since, at: now, toPhone: true)
        #expect(policy.gate(intent, context: Fixtures.context(), hasChannel: true) == .suppress("duplicate"))
        // One reminder, after needsInputReminderMinutes.
        #expect(policy.nextReminderDue(after: now) == now.addingTimeInterval(600))
        #expect(policy.dueReminders(at: now.addingTimeInterval(599)).isEmpty)
        #expect(policy.dueReminders(at: now.addingTimeInterval(600)).map(\.effect.session.key) == [key])
        policy.markReminderSent(key)
        #expect(policy.dueReminders(at: now.addingTimeInterval(3600)).isEmpty)
        #expect(policy.nextReminderDue(after: now) == nil)
        // A NEW wait of the same session is a new push (and a new reminder).
        var later = effect.session
        later.state = .waiting(kind: .question, since: Fixtures.at(22, 30))
        let second = NotificationIntent.needsInput(SessionEffect(kind: .needsInput, session: later, at: Fixtures.at(22, 30)), awakeUntil: nil)
        #expect(policy.gate(second, context: Fixtures.context(Fixtures.at(22, 30)), hasChannel: true) == .proceed)
    }

    @Test func resolvedForgetsTheWait() {
        var policy = NotificationPolicy(settings: NotificationSettings())
        let effect = Fixtures.needsInput()
        _ = policy.gate(.needsInput(effect, awakeUntil: nil), context: Fixtures.context(), hasChannel: true)
        policy.markDelivered(effect.session.key, since: Fixtures.at(21, 50), at: now, toPhone: true)
        policy.resolve(effect.session.key)
        #expect(policy.waits.isEmpty)
        #expect(policy.nextReminderDue(after: now) == nil)
    }

    @Test func rateLimitFoldsOverflowIntoADigest() {
        var settings = NotificationSettings()
        settings.rateLimitPerTenMinutes = 2
        var policy = NotificationPolicy(settings: settings)
        let stalled = (0..<4).map { i in
            OutgoingNotification(kind: .stalled, title: "s\(i)", body: "", groupKey: "stalled:\(i)", createdAt: now)
        }
        let admitted = [
            policy.admit(stalled[0], now: now),
            policy.admit(stalled[1], now: now.addingTimeInterval(60)),
            policy.admit(stalled[2], now: now.addingTimeInterval(120)),
            policy.admit(stalled[3], now: now.addingTimeInterval(180)),
        ]
        #expect(admitted == [true, true, false, false])
        // Exempt kinds always pass (and still count); user-initiated ones do not count.
        let safety = policy.admit(OutgoingNotification(kind: .safetyTrip, title: "", body: "", groupKey: "safety", createdAt: now), now: now)
        let test = policy.admit(OutgoingNotification(kind: .test, title: "", body: "", groupKey: "test", createdAt: now), now: now)
        #expect(safety && test)
        #expect(policy.admissions.count == 3)
        #expect(policy.digestCount == 2)
        // The digest goes out when a token frees up: the 2nd-oldest admission (t+0 safety, t+0, t+60) → t+600.
        #expect(policy.nextDigestTime(now: now.addingTimeInterval(200)) == now.addingTimeInterval(600))
        #expect(policy.takeDigest(now: now.addingTimeInterval(599)) == nil)
        #expect(policy.takeDigest(now: now.addingTimeInterval(600))?.map(\.title) == ["s2", "s3"])
        #expect(policy.digestCount == 0)
        #expect(policy.nextDigestTime(now: now.addingTimeInterval(600)) == nil)
    }

    @Test func forcedDigestIgnoresTheBucketAndCountdownDropsFoldedFinishes() {
        var settings = NotificationSettings()
        settings.rateLimitPerTenMinutes = 1
        var policy = NotificationPolicy(settings: settings)
        _ = policy.admit(OutgoingNotification(kind: .stalled, title: "a", body: "", groupKey: "a", createdAt: now), now: now)
        _ = policy.admit(OutgoingNotification(kind: .finished, title: "f", body: "", groupKey: "f", createdAt: now), now: now)
        _ = policy.admit(OutgoingNotification(kind: .stalled, title: "b", body: "", groupKey: "b", createdAt: now), now: now)
        #expect(policy.digestCount == 2)
        policy.dropFoldedFinishes()
        #expect(policy.digestCount == 1)
        #expect(policy.takeDigest(now: now) == nil)
        #expect(policy.takeDigest(now: now, force: true)?.map(\.title) == ["b"])
    }

    @Test func quietHoursDowngradeButNeverDrop() {
        var settings = NotificationSettings()
        settings.quietHours = QuietHours(enabled: true, startMinute: 21 * 60, endMinute: 7 * 60)
        let policy = NotificationPolicy(settings: settings)
        var input = OutgoingNotification(kind: .needsInput, title: "", body: "", groupKey: "i", createdAt: now)
        policy.applyQuietHours(to: &input, now: now, timeZone: Fixtures.utc)
        #expect(input.priority == .low)
        var asleep = OutgoingNotification(kind: .asleep, title: "", body: "", priority: .min, groupKey: "a", createdAt: now)
        policy.applyQuietHours(to: &asleep, now: now, timeZone: Fixtures.utc)
        #expect(asleep.priority == .min)
        var outside = OutgoingNotification(kind: .needsInput, title: "", body: "", groupKey: "i", createdAt: now)
        policy.applyQuietHours(to: &outside, now: Fixtures.at(12, 0), timeZone: Fixtures.utc)
        #expect(outside.priority == .high)
        var test = OutgoingNotification(kind: .test, title: "", body: "", groupKey: "t", createdAt: now)
        policy.applyQuietHours(to: &test, now: now, timeZone: Fixtures.utc)
        #expect(test.priority == .default, "the user asked for the test: never silenced")
    }

    @Test func batchCollectsUntilTaken() {
        var policy = NotificationPolicy(settings: NotificationSettings())
        let opened = policy.addToBatch(BatchedFinish(kind: .finished, effect: Fixtures.finished()), stillRunning: 2,
                                       context: Fixtures.context(), now: now)
        let reopened = policy.addToBatch(BatchedFinish(kind: .wentQuiet(sleepsAt: nil), effect: Fixtures.finished(Fixtures.aider())),
                                         stillRunning: nil, context: Fixtures.context(), now: now)
        #expect(opened && !reopened)
        let batch = policy.takeBatch()
        #expect(batch?.items.count == 2)
        #expect(batch?.stillRunning == 2)
        #expect(batch?.deadline == now.addingTimeInterval(15))
        #expect(policy.takeBatch() == nil)
    }

    @Test func settingsAreNormalized() {
        var settings = NotificationSettings()
        settings.rateLimitPerTenMinutes = 0
        settings.awayIdleSeconds = 1
        settings.needsInputReminderMinutes = 10_000
        let normalized = NotificationPolicy.normalized(settings)
        #expect(normalized.rateLimitPerTenMinutes == 1)
        #expect(normalized.awayIdleSeconds == 60)
        #expect(normalized.needsInputReminderMinutes == 120)
    }
}
