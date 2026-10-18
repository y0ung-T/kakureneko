import KakurenekoKit
import Foundation

/// Notification policy (brief §8.5, R07 §16.3–16.4, ARCHITECTURE §9.6): enable switch, a channel, muted kinds,
/// Remote-Control skip, short turns, needs-input dedupe on `(sessionKey, waiting since)` with one reminder,
/// the 15 s batch, the global rate-limit bucket with a digest, and quiet hours.
///
/// Pure state (no clock, no I/O): the dispatcher passes `now` and owns the timers.
struct NotificationPolicy: Sendable {
    /// Rate-limit window (10 min).
    static let rateWindow: TimeInterval = 600
    /// The batch window (brief §5.6 `notifyBatch`, fixed 15 s).
    static let batchWindow: TimeInterval = 15
    /// Wait records older than this are forgotten even without a `.resolved` (bounded memory).
    static let maximumWaitAge: TimeInterval = 24 * 3600

    /// Kinds never folded into a digest (time-critical buttons, safety, answers to a tap). They still consume
    /// rate-limit tokens, except the test, which is user-initiated and uncounted.
    static let rateLimitExempt: Set<NotificationKind> = [.safetyTrip, .countdown, .shuttingDown, .commandIgnored, .test]
    /// Kinds that bypass the enable switch, mutes, the rate limit and quiet hours (the user asked for them: the
    /// test, and the answer to a tapped button the Mac did not run, which the iPhone's tap feedback waits for).
    static let userInitiated: Set<NotificationKind> = [.test, .commandIgnored]
    /// Kinds the iPhone gets whatever its timing (`phoneTiming`) says: the test the user asked for, direct answers
    /// to an iPhone tap (`commandIgnored` — the iPhone's tap feedback reads it — and `shuttingDown`, possibly
    /// requested from the iPhone; the Mac goes out of reach either way) and safety stops.
    static let phoneTimingBypass: Set<NotificationKind> = [.safetyTrip, .test, .commandIgnored, .shuttingDown]

    /// One needs-input wait of one session.
    struct WaitRecord: Sendable, Hashable {
        var since: Date
        /// A push for this wait was queued (or folded into a digest). False = suppressed (e.g. no channel): a
        /// re-submit of the same wait is evaluated again.
        var delivered: Bool
        /// It went to the iPhone too. False while the iPhone's timing held it back (shown on the Mac only): a
        /// re-submit once the timing allows sends the iPhone its copy.
        var phoneDelivered = false
        var reminderDue: Date?
        var reminderSent: Bool
        /// Latest effect (re-rendered for the reminder).
        var effect: SessionEffect
        var awakeUntil: Date?
    }

    /// The open 15 s batch.
    struct Batch: Sendable, Hashable {
        var items: [BatchedFinish]
        var deadline: Date
        /// "N agents still running" from the latest `finished` intent.
        var stillRunning: Int
        var context: NotificationContext
    }

    enum Gate: Sendable, Hashable {
        case proceed
        case suppress(String)
    }

    var settings: NotificationSettings
    private(set) var waits: [SessionKey: WaitRecord] = [:]
    private(set) var batch: Batch?
    /// Times at which counted messages were admitted (sliding 10 min window).
    private(set) var admissions: [Date] = []
    /// Messages folded by the rate limit, awaiting the digest.
    private(set) var digest: [OutgoingNotification] = []
    /// The most recent submit context (presence and `sv` for timer-driven messages).
    private(set) var lastContext: NotificationContext?

    init(settings: NotificationSettings) {
        self.settings = Self.normalized(settings)
    }

    mutating func noteContext(_ context: NotificationContext) {
        if let last = lastContext, last.now > context.now { return }
        lastContext = context
    }

    // MARK: Admission

    /// Enable switch, a usable channel (Mac notifications, or the iPhone when its timing allows), mutes,
    /// Remote-Control skip, short turns and needs-input dedupe for one intent (`.resolved` is handled by `resolve`).
    mutating func gate(_ intent: NotificationIntent, context: NotificationContext, hasChannel: Bool) -> Gate {
        let kind = intent.kind
        let userInitiated = Self.userInitiated.contains(kind)
        if !userInitiated && !settings.enabled { return .suppress("disabled") }
        guard hasChannel else { return .suppress("noChannel") }
        if !userInitiated && settings.isMuted(kind) { return .suppress("muted") }
        if let session = Self.session(of: intent), isSkippedRemoteControl(session) { return .suppress("remoteControl") }
        if isShortTurn(intent) { return .suppress("shortTurn") }
        if case .needsInput(let effect, let awakeUntil) = intent {
            pruneWaits(now: context.now)
            let key = effect.session.key
            let since = NotificationTemplates.waitingSince(effect)
            if var record = waits[key], record.since == since {
                if record.delivered { return .suppress("duplicate") }
                record.effect = effect
                record.awakeUntil = awakeUntil
                waits[key] = record
            } else {
                waits[key] = WaitRecord(since: since, delivered: false, reminderDue: nil, reminderSent: false,
                                        effect: effect, awakeUntil: awakeUntil)
            }
        }
        return .proceed
    }

    /// "Only when the agent worked at least …": a finish (or went-quiet) of a shorter turn. Unknown durations go out.
    func isShortTurn(_ intent: NotificationIntent) -> Bool {
        guard settings.minimumWorkSeconds > 0 else { return false }
        let effect: SessionEffect
        switch intent {
        case .finished(let finished, _): effect = finished
        case .wentQuiet(let quiet, _): effect = quiet
        default: return false
        }
        guard let worked = NotificationTemplates.workedFor(effect) else { return false }
        return worked < TimeInterval(settings.minimumWorkSeconds)
    }

    /// "Don't push for Claude sessions with Remote Control connected" (brief §8.5).
    func isSkippedRemoteControl(_ session: AgentSession) -> Bool {
        settings.skipClaudeRemoteControlSessions && session.agent == .claude && session.remoteControlConnected
    }

    /// The needs-input push for `key` (wait `since`) was queued (`toPhone`: for the iPhone too): schedule its
    /// single reminder.
    mutating func markDelivered(_ key: SessionKey, since: Date, at now: Date, toPhone: Bool) {
        guard var record = waits[key], record.since == since else { return }
        record.delivered = true
        if toPhone { record.phoneDelivered = true }
        if !record.reminderSent && record.reminderDue == nil {
            record.reminderDue = now.addingTimeInterval(TimeInterval(settings.needsInputReminderMinutes * 60))
        }
        waits[key] = record
    }

    /// The wait `key` / `since` was shown on the Mac only: the iPhone's timing held it back.
    func isDeliveredWithoutPhone(_ key: SessionKey, since: Date) -> Bool {
        guard let record = waits[key], record.since == since else { return false }
        return record.delivered && !record.phoneDelivered
    }

    mutating func markPhoneDelivered(_ key: SessionKey) {
        waits[key]?.phoneDelivered = true
    }

    /// Waits whose reminder is due at `now` (delivered, unresolved, not yet reminded), oldest wait first.
    func dueReminders(at now: Date) -> [WaitRecord] {
        waits.values
            .filter { $0.delivered && !$0.reminderSent && ($0.reminderDue.map { $0 <= now } ?? false) }
            .sorted { ($0.since, $0.effect.session.key) < ($1.since, $1.effect.session.key) }
    }

    /// Earliest reminder strictly after `now`. Overdue reminders held back by presence are re-checked on the
    /// next submit instead (no timer spin).
    func nextReminderDue(after now: Date) -> Date? {
        waits.values
            .filter { $0.delivered && !$0.reminderSent }
            .compactMap(\.reminderDue)
            .filter { $0 > now }
            .min()
    }

    mutating func markReminderSent(_ key: SessionKey) {
        waits[key]?.reminderSent = true
    }

    /// `.resolved(key)`: forget the wait (cancels the reminder) and drop its digest entries.
    mutating func resolve(_ key: SessionKey) {
        waits.removeValue(forKey: key)
        let group = NotificationTemplates.inputGroupKey(key)
        digest.removeAll { $0.groupKey == group }
    }

    private mutating func pruneWaits(now: Date) {
        waits = waits.filter { now.timeIntervalSince($0.value.since) < Self.maximumWaitAge }
    }

    // MARK: Batch (15 s; N finishes → one message; a countdown absorbs it)

    /// Adds an item; returns true when this opened a new batch (the caller schedules the flush).
    /// `stillRunning` comes from `finished` intents only (`wentQuiet` does not carry it).
    mutating func addToBatch(_ item: BatchedFinish, stillRunning: Int?, context: NotificationContext, now: Date) -> Bool {
        if var open = batch {
            open.items.append(item)
            if let stillRunning { open.stillRunning = stillRunning }
            open.context = context
            batch = open
            return false
        }
        batch = Batch(items: [item], deadline: now.addingTimeInterval(Self.batchWindow), stillRunning: stillRunning ?? 0, context: context)
        return true
    }

    mutating func takeBatch() -> Batch? {
        defer { batch = nil }
        return batch
    }

    // MARK: Rate limit (global bucket, overflow → digest)

    /// Whether `notification` may go out now. Counted kinds consume a token; non-exempt kinds over the limit
    /// are folded into the digest (returns false).
    mutating func admit(_ notification: OutgoingNotification, now: Date) -> Bool {
        let kind = notification.kind
        if Self.userInitiated.contains(kind) { return true }
        pruneAdmissions(now: now)
        if admissions.count < settings.rateLimitPerTenMinutes || Self.rateLimitExempt.contains(kind) {
            admissions.append(now)
            return true
        }
        digest.removeAll { $0.groupKey == notification.groupKey }
        digest.append(notification)
        return false
    }

    /// When a token frees up for the digest (nil when the digest is empty).
    func nextDigestTime(now: Date) -> Date? {
        guard !digest.isEmpty else { return nil }
        let window = admissions.filter { $0 > now.addingTimeInterval(-Self.rateWindow) }.sorted()
        if window.count < settings.rateLimitPerTenMinutes { return now }
        let index = window.count - settings.rateLimitPerTenMinutes
        return window[index].addingTimeInterval(Self.rateWindow)
    }

    /// Takes the digest when a token is available (consuming it), dropping expired entries. `force` takes it
    /// regardless of the bucket (before a Kakureneko-initiated sleep and on stop: one message, nothing lost).
    mutating func takeDigest(now: Date, force: Bool = false) -> [OutgoingNotification]? {
        digest.removeAll { $0.expiresAt <= now }
        guard !digest.isEmpty else { return nil }
        pruneAdmissions(now: now)
        guard force || admissions.count < settings.rateLimitPerTenMinutes else { return nil }
        admissions.append(now)
        defer { digest.removeAll() }
        return digest
    }

    /// Number of messages currently folded into the pending digest.
    var digestCount: Int { digest.count }

    /// A countdown lists the finished sessions itself: folded `finished` / `wentQuiet` messages are dropped.
    mutating func dropFoldedFinishes() {
        digest.removeAll { $0.kind == .finished || $0.kind == .wentQuiet }
    }

    private mutating func pruneAdmissions(now: Date) {
        admissions.removeAll { $0 <= now.addingTimeInterval(-Self.rateWindow) }
    }

    // MARK: Quiet hours

    /// Inside quiet hours: priority ≤ 2 (never dropped). The test is left alone.
    func applyQuietHours(to notification: inout OutgoingNotification, now: Date, timeZone: TimeZone) {
        guard !Self.userInitiated.contains(notification.kind), settings.quietHours.contains(now, timeZone: timeZone) else { return }
        notification.priority = min(notification.priority, .low)
    }

    // MARK: Settings / reset

    /// Drops all pending policy state (notifications disabled).
    mutating func reset() {
        waits.removeAll()
        batch = nil
        digest.removeAll()
    }

    /// Removes batched and folded items of the kinds matching `predicate` (newly muted kinds).
    mutating func removeFromBatchAndDigest(where predicate: (NotificationKind) -> Bool) {
        if var open = batch {
            open.items.removeAll { predicate($0.isWentQuiet ? .wentQuiet : .finished) }
            batch = open.items.isEmpty ? nil : open
        }
        digest.removeAll { predicate($0.kind) }
    }

    // MARK: Helpers

    /// Clamps the ranges the policy depends on (the coordinator normalizes too, but a zero rate limit must never
    /// reach the bucket arithmetic).
    static func normalized(_ settings: NotificationSettings) -> NotificationSettings {
        var s = settings
        s.awayIdleSeconds = s.awayIdleSeconds.clamped(to: NotificationSettings.awayIdleSecondsRange)
        s.rateLimitPerTenMinutes = s.rateLimitPerTenMinutes.clamped(to: NotificationSettings.rateLimitPerTenMinutesRange)
        s.needsInputReminderMinutes = s.needsInputReminderMinutes.clamped(to: NotificationSettings.needsInputReminderMinutesRange)
        s.minimumWorkSeconds = s.minimumWorkSeconds.clamped(to: NotificationSettings.minimumWorkSecondsRange)
        s.quietHours.startMinute = s.quietHours.startMinute.clamped(to: QuietHours.minuteRange)
        s.quietHours.endMinute = s.quietHours.endMinute.clamped(to: QuietHours.minuteRange)
        return s
    }

    /// The session an intent is about (for the Remote-Control skip).
    static func session(of intent: NotificationIntent) -> AgentSession? {
        switch intent {
        case .finished(let effect, _), .needsInput(let effect, _), .wentQuiet(let effect, _), .stalled(let effect):
            effect.session
        default:
            nil
        }
    }
}
