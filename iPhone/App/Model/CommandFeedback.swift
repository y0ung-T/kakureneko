// "Sent → done / Mac didn't respond": what became of the last command the user sent to each Mac. The phone cannot
// ask the Mac directly, so it infers the outcome from the zone: the Mac deletes a command once it handled it, a
// handled keep awake / sleep / shut down changes the Mac's status, a handled test produces a "test" alert, and an
// ignored button produces a "commandIgnored" alert. Pure value logic, driven by `PhoneStore`.

import KakurenekoCloud
import Foundation

/// Which feedback line a command updates.
enum FeedbackChannel: Hashable, Sendable {
    /// The Keep awake / Sleep now / Shut down buttons (in the app or on a notification).
    case controls
    /// "Send test alert" in Settings.
    case test
}

/// One feedback line: a Mac and a channel.
struct FeedbackSlot: Hashable, Sendable {
    var macID: String
    var channel: FeedbackChannel
}

/// The parts of a status a command is expected to change (a heartbeat republish changes none of them).
struct StatusFingerprint: Hashable, Sendable {
    var stateVersion: Int
    var phase: MacPhase
    var keepAwakeUntil: Date?
    var countdownEndsAt: Date?

    init(_ status: MacStatus) {
        stateVersion = status.stateVersion
        phase = status.phase
        keepAwakeUntil = status.keepAwakeUntil
        countdownEndsAt = status.countdownEndsAt
    }
}

struct CommandFeedback: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case sending
        /// Saved to iCloud; waiting for the Mac.
        case sent
        /// The Mac picked it up (deleted the record) but its status has not changed yet. Shown as a finished line
        /// (it may still turn into done / ignored while visible), so it never waits forever.
        case received
        /// The Mac's status changed (or its test alert arrived).
        case done
        /// The Mac refused it (its "commandIgnored" alert text).
        case ignored(String)
        /// Nothing from the Mac within `FeedbackBoard.confirmationTimeout`. Still watched until the command expires:
        /// a Mac that wakes up later and runs it turns the line into received / done.
        case noResponse
        /// iCloud unreachable: kept and retried on the next launch / return to the app.
        case queued
        /// Not sent (expired while queued, or iCloud rejected it).
        case failed(String)
    }

    /// Finished lines disappear this long after their last change.
    static let visibleFor: TimeInterval = 3 * 60

    var commandID: String
    var request: CloudRequest
    var phase: Phase
    var issuedAt: Date
    /// When `phase` last changed (the timeout and the visibility count from here).
    var changedAt: Date
    /// The Mac's state when the command reached iCloud (nil when unknown): a different state confirms the command.
    var baseline: StatusFingerprint?
    /// When the Mac stops accepting the command (nil = unknown: `FeedbackBoard.defaultLifetime` after `issuedAt`).
    var expiresAt: Date?

    /// Still waiting for an outcome.
    var isPending: Bool {
        switch phase {
        case .sending, .sent, .queued: true
        case .received, .done, .ignored, .noResponse, .failed: false
        }
    }

    /// The Mac may still pick it up (a sent or unanswered command that has not expired).
    func mayStillArrive(at now: Date) -> Bool {
        (phase == .sent || phase == .noResponse)
            && now < (expiresAt ?? issuedAt.addingTimeInterval(FeedbackBoard.defaultLifetime))
    }

    func isVisible(at now: Date) -> Bool {
        isPending || now.timeIntervalSince(changedAt) < Self.visibleFor
    }
}

/// The feedback lines of every Mac.
struct FeedbackBoard: Equatable, Sendable {
    /// "No response" after this long without a sign from the Mac.
    static let confirmationTimeout: TimeInterval = 30
    /// Tolerated difference between the phone's and the Mac's clocks when matching alerts to a command.
    static let clockSkew: TimeInterval = 10
    /// How long a command without a known expiry is watched (the in-app command lifetime).
    static let defaultLifetime: TimeInterval = 10 * 60

    private(set) var entries: [FeedbackSlot: CommandFeedback] = [:]

    subscript(slot: FeedbackSlot) -> CommandFeedback? { entries[slot] }

    /// Starts a new line for `command` (replacing the slot's previous one).
    mutating func begin(_ command: CloudCommand, in slot: FeedbackSlot, at now: Date) {
        entries[slot] = CommandFeedback(commandID: command.id, request: command.request, phase: .sending,
                                        issuedAt: command.issuedAt, changedAt: now, baseline: nil,
                                        expiresAt: command.expiresAt)
    }

    /// Moves the line that tracks `commandID` (if it is still the slot's latest) to `phase`.
    mutating func update(commandID: String, to phase: CommandFeedback.Phase, at now: Date) {
        guard let slot = slot(of: commandID), entries[slot]?.phase != phase else { return }
        entries[slot]?.phase = phase
        entries[slot]?.changedAt = now
    }

    /// The command reached iCloud; `baseline` is the Mac's state at that moment (a later change confirms it).
    mutating func markSent(commandID: String, baseline: StatusFingerprint?, at now: Date) {
        guard let slot = slot(of: commandID) else { return }
        entries[slot]?.phase = .sent
        entries[slot]?.changedAt = now
        entries[slot]?.baseline = baseline
    }

    private func slot(of commandID: String) -> FeedbackSlot? {
        entries.first { $0.value.commandID == commandID }?.key
    }

    /// Commands sent and not yet confirmed by their Mac (also unanswered ones that have not expired), with when they
    /// last changed (reached iCloud, or timed out: either way past the query index lag).
    func awaitingCommands(at now: Date) -> [String: Date] {
        Dictionary(entries.values.filter { $0.mayStillArrive(at: now) }.map { ($0.commandID, $0.changedAt) },
                   uniquingKeysWith: max)
    }

    /// The Mac deleted these commands: it handled them.
    mutating func commandsHandled(_ ids: Set<String>, at now: Date) {
        for (slot, entry) in entries where entry.mayStillArrive(at: now) && ids.contains(entry.commandID) {
            entries[slot]?.phase = .received
            entries[slot]?.changedAt = now
        }
    }

    /// Confirms lines from the zone's current state and times out the ones the Mac never picked up.
    mutating func evaluate(_ zone: ZoneSnapshot, now: Date) {
        for (slot, entry) in entries where entry.phase == .received || entry.mayStillArrive(at: now) {
            if let outcome = Self.outcome(of: entry, in: slot, zone: zone) {
                entries[slot]?.phase = outcome
                entries[slot]?.changedAt = now
            } else if entry.phase == .sent, now.timeIntervalSince(entry.changedAt) >= Self.confirmationTimeout {
                entries[slot]?.phase = .noResponse
                entries[slot]?.changedAt = now
            }
        }
    }

    private static func outcome(of entry: CommandFeedback, in slot: FeedbackSlot, zone: ZoneSnapshot) -> CommandFeedback.Phase? {
        let earliest = entry.issuedAt.addingTimeInterval(-clockSkew)
        func newAlert(kind: String) -> CloudAlert? {
            zone.alerts.first { $0.macID == slot.macID && $0.kind == kind && $0.createdAt >= earliest }
        }
        switch slot.channel {
        case .controls:
            if let ignored = newAlert(kind: AlertKind.commandIgnored) {
                return .ignored(ignored.body.isEmpty ? ignored.title : ignored.body)
            }
            guard let baseline = entry.baseline, let status = zone.statuses[slot.macID] else { return nil }
            let current = StatusFingerprint(status)
            // Only the change the command asks for confirms it (an agent finishing also changes `sv`).
            switch entry.request {
            case .keepAwake:
                let extended = current.keepAwakeUntil != nil && current.keepAwakeUntil != baseline.keepAwakeUntil
                let cancelled = baseline.countdownEndsAt != nil && current.countdownEndsAt == nil
                return extended || cancelled ? .done : nil
            case .sleepNow:
                let sleeping: Set<MacPhase> = [.countdown, .windingDown, .asleep]
                return current.phase != baseline.phase && sleeping.contains(current.phase) ? .done : nil
            case .shutDown:
                let stopping: Set<MacPhase> = [.shutdownPending, .windingDown, .shutDown, .asleep]
                return current.phase != baseline.phase && stopping.contains(current.phase) ? .done : nil
            case .sendTest, .refreshStatus:
                return current != baseline ? .done : nil
            }
        case .test:
            return newAlert(kind: AlertKind.test) == nil ? nil : .done
        }
    }
}
