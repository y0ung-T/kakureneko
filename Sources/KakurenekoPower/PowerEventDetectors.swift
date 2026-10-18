// KakurenekoPower — small deterministic state machines used by PowerMonitor (unit-tested on their own).
// OWNER: agent "power". Spec card: docs/ARCHITECTURE.md §9.4 (`PowerMonitor`). Brief §7.2; R01 §6.2; R07 §14.

import KakurenekoKit
import Foundation
import Synchronization

/// Lid edge detection against the last known `AppleClamshellState`. The clamshell interest message also fires on AC
/// plug/unplug and desktop-mode changes with an unchanged bit 0, and the 1 Hz poll re-reads the same state: only a
/// change of the known state is an edge. Priming (at start) never emits; after that, a lid that was unreadable at start
/// and is then read as closed (or open) DOES emit, so a close is never missed.
struct LidEdgeDetector: Sendable, Hashable {
    /// Last known state (nil = unknown, or a Mac without a lid).
    private(set) var closed: Bool?
    /// When the lid was last seen closing (or first seen closed).
    private(set) var closedSince: Date?
    /// True once the initial state was recorded.
    private(set) var isPrimed = false

    /// Sets the initial state without an edge.
    mutating func prime(_ closed: Bool?, now: Date) {
        self.closed = closed
        closedSince = closed == true ? now : nil
        isPrimed = true
    }

    /// Feeds a reading; returns the edge when the state changed. nil readings (unreadable / no lid) keep the last state.
    mutating func observe(_ reading: Bool?, now: Date) -> LidState? {
        guard let reading else { return nil }
        guard isPrimed else {
            prime(reading, now: now)
            return nil
        }
        guard closed != reading else { return nil }
        closed = reading
        closedSince = reading ? now : nil
        return reading ? .closed : .open
    }

    /// The lid as a `LidState` (nil when unknown).
    var state: LidState? { closed.map { $0 ? .closed : .open } }
}

/// Edge detection for a boolean (external display presence).
struct BoolEdgeDetector: Sendable, Hashable {
    private(set) var value: Bool?

    mutating func prime(_ value: Bool?) { self.value = value }

    /// Returns the new value when it changed from a known value; the first value primes silently.
    mutating func observe(_ reading: Bool) -> Bool? {
        guard let previous = value else {
            value = reading
            return nil
        }
        guard previous != reading else { return nil }
        value = reading
        return reading
    }
}

/// Closed-lid user activity (e.g. Screen Sharing): emitted when `secondsSinceUserInput` drops below `threshold` while
/// the lid is closed, for input that happened AFTER the lid closed, at most once per `minimumInterval`.
struct UserActivityDetector: Sendable, Hashable {
    var threshold: TimeInterval = 2
    var minimumInterval: TimeInterval = 10
    private(set) var lastEmittedAt: Date?

    /// - Parameters:
    ///   - lidClosedSince: nil while the lid is open (nothing is emitted).
    /// - Returns: the seconds since input to emit, or nil.
    mutating func observe(secondsSinceInput: TimeInterval?, lidClosedSince: Date?, now: Date) -> TimeInterval? {
        guard let closedSince = lidClosedSince, let seconds = secondsSinceInput, seconds >= 0, seconds < threshold else {
            return nil
        }
        // Input from before the lid closed (typing, then closing the lid) is not closed-lid activity.
        guard now.timeIntervalSince(closedSince) > seconds else { return nil }
        if let last = lastEmittedAt, now.timeIntervalSince(last) < minimumInterval { return nil }
        lastEmittedAt = now
        return seconds
    }
}

/// `kIOMessageSystemWillSleep` acknowledgement with a deadline: the consumer calls `allow()` when ready; otherwise it
/// is allowed automatically after `deadline` (≤ 8 s, well inside the kernel's 30 s acknowledgement window).
enum SleepAcknowledgement {
    /// Creates the acknowledger and arms its auto-allow timer on `clock`. Whoever allows first (consumer, timer, or
    /// the owner on `stop()`) runs `allow` exactly once; the timer is cancelled as soon as the change is allowed.
    /// - Parameters:
    ///   - allow: the real acknowledgement (`IOAllowPowerChange` for this notification).
    ///   - onTimeout: called (before allowing) when the deadline fires with the change still pending.
    ///   - onSettled: called once, right after `allow` (the owner forgets the pending acknowledger).
    static func make(
        deadline: Duration,
        clock: any KakurenekoClock,
        allow: @escaping @Sendable () -> Void,
        onTimeout: @escaping @Sendable () -> Void = {},
        onSettled: @escaping @Sendable () -> Void = {}
    ) -> PowerChangeAcknowledger {
        let slot = TimerSlot()
        let acknowledger = PowerChangeAcknowledger(onAllow: {
            slot.cancel()
            allow()
            onSettled()
        })
        let timer = Task {
            do {
                try await clock.sleep(for: deadline)
            } catch {
                return // cancelled: the change was allowed already
            }
            guard !acknowledger.isAllowed else { return }
            onTimeout()
            acknowledger.allow()
        }
        slot.install(timer)
        return acknowledger
    }

    /// Holds the auto-allow timer so the acknowledger can cancel it (an allow that races the installation cancels the
    /// timer as soon as it is installed).
    private final class TimerSlot: Sendable {
        private struct State {
            var task: Task<Void, Never>?
            var cancelled = false
        }
        private let state = Mutex(State())

        func install(_ task: Task<Void, Never>) {
            let cancelNow = state.withLock { s -> Bool in
                if s.cancelled { return true }
                s.task = task
                return false
            }
            if cancelNow { task.cancel() }
        }

        func cancel() {
            let task = state.withLock { s -> Task<Void, Never>? in
                s.cancelled = true
                defer { s.task = nil }
                return s.task
            }
            task?.cancel()
        }
    }
}
