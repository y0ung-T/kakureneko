import KakurenekoCloud
import KakurenekoKit
import Foundation
import Synchronization

/// Injectable collaborators and tunables of `NotificationDispatcher`. Production uses `.live`; tests inject a
/// fixed time zone, deterministic jitter, a manual path monitor and a fixed Mac identity (all timers run on the
/// injected clock).
struct NotifyEnvironment: Sendable {
    /// Time zone for `{hh:mm}` in templates and for quiet hours.
    var timeZone: TimeZone = .current
    /// Jitter source for the backoffs (`Double.random(in:)` in production).
    var random: @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    /// Network path monitor factory (`NWPathMonitor` in production).
    var makePathMonitor: @Sendable () -> any NetworkPathMonitoring = { LivePathMonitor() }
    /// This Mac as the iPhone shows it.
    var identity: @Sendable () -> MacIdentity = { MacIdentity.current() }
    /// Periodic tick: outbox drain, digest, Mac permission refresh, status heartbeat, pruning (brief §8.5).
    var drainInterval: TimeInterval = 60
    /// Bound on one iCloud save attempt.
    var sendTimeout: TimeInterval = 30
    /// Smallest delay of the outbox retry timer (never a tight loop when an item is already due).
    var minimumRetryDelay: TimeInterval = 1
    /// iCloud polls while a button on a recent alert may still be tapped, or after a phone's refresh request.
    var fastPollInterval: TimeInterval = 15
    /// iCloud polls otherwise (pushes trigger a fetch at once in between).
    var slowPollInterval: TimeInterval = 300
    /// How long a phone's `refresh` request keeps the fast polling on.
    var refreshFastPollWindow: TimeInterval = 120
    /// Status changes are saved at most this often (a phase change is saved at once).
    var statusDebounce: TimeInterval = 5
    /// The status is saved at least this often while running.
    var statusHeartbeat: TimeInterval = MacStatus.heartbeatInterval
    /// While iCloud is not available, its account status is checked again after this long.
    var accountRecheckInterval: TimeInterval = 600
    /// While the user's iCloud storage is full, saves are retried this often (an alert until it expires).
    var quotaRetryInterval: TimeInterval = 600
    /// Alerts this Mac saved are deleted from iCloud after this long (the iPhone's Activity shows 3 days).
    var alertRetention: TimeInterval = 3 * 24 * 3600
    /// Old records are pruned at most this often.
    var pruneInterval: TimeInterval = 6 * 3600
    /// Alerts are pruned this long after `alertRetention` (the iPhone's 3-day window must never lose one early).
    var alertPruneMargin: TimeInterval = 12 * 3600
    /// Commands left in iCloud this long are deleted (they expire after 30 min; a Mac that is gone never reads them).
    var commandRetention: TimeInterval = 3600
    /// Mac statuses and iPhone records not saved for this long are deleted (a Mac or iPhone that is gone).
    var deviceRetention: TimeInterval = 30 * 24 * 3600
    /// This Mac's id, derived from the machine (`MachineIdentity`); nil keeps the stored random id (tests).
    var machineMacID: @Sendable () -> String? = { nil }

    static var live: NotifyEnvironment {
        var environment = NotifyEnvironment()
        environment.machineMacID = { MachineIdentity.macID() }
        return environment
    }
}

extension KakurenekoClock {
    /// Sleeps until the absolute `deadline` (a timer task that starts late does not drift; a deadline already
    /// in the past returns at once unless the task is cancelled).
    func sleep(until deadline: Date) async throws {
        let remaining = deadline.timeIntervalSince(now())
        guard remaining > 0 else {
            try Task.checkCancellation()
            return
        }
        try await sleep(for: .interval(remaining))
    }
}

/// A generation-counted wake-up signal (no clock involved): `wait(unlessChangedFrom:)` returns as soon as
/// `signal()` ran after the caller read `generation`, or when the waiting task is cancelled. Used by
/// `drain(deadline:)` to wait for an attempt another drain has in flight without polling.
final class AsyncSignal: Sendable {
    private enum Slot { case pending, waiting(CheckedContinuation<Void, Never>), cancelled }
    private struct State {
        var generation: UInt64 = 0
        var nextID: UInt64 = 0
        var slots: [UInt64: Slot] = [:]
    }
    private let state = Mutex(State())

    init() {}

    /// Incremented by every `signal()`.
    var generation: UInt64 { state.withLock { $0.generation } }

    /// Suspends until the generation differs from `generation` (immediately if it already does) or the task
    /// is cancelled.
    func wait(unlessChangedFrom generation: UInt64) async {
        let id: UInt64? = state.withLock { s in
            guard s.generation == generation else { return nil }
            s.nextID += 1
            s.slots[s.nextID] = .pending
            return s.nextID
        }
        guard let id else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = state.withLock { s in
                    switch s.slots[id] {
                    case .pending:
                        if s.generation != generation {
                            s.slots.removeValue(forKey: id)
                            return true
                        }
                        s.slots[id] = .waiting(continuation)
                        return false
                    case .cancelled, .waiting, nil:
                        s.slots.removeValue(forKey: id)
                        return true
                    }
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, Never>? = state.withLock { s in
                switch s.slots[id] {
                case .waiting(let c):
                    s.slots.removeValue(forKey: id)
                    return c
                case .pending:
                    s.slots[id] = .cancelled
                    return nil
                case .cancelled, nil:
                    return nil
                }
            }
            continuation?.resume()
        }
    }

    /// Bumps the generation and resumes every waiter.
    func signal() {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { s in
            s.generation &+= 1
            var resumed: [CheckedContinuation<Void, Never>] = []
            for (id, slot) in s.slots {
                if case .waiting(let c) = slot {
                    resumed.append(c)
                    s.slots.removeValue(forKey: id)
                }
            }
            return resumed
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// The first of several racing producers decides the result: it resumes the waiting caller exactly once (also when
/// it finished before the caller started waiting) and runs the `onFinish` clean-up that cancels the losers. Later
/// results are ignored. Used to bound an operation by a timeout even when it ignores cancellation.
final class FirstResult<Value: Sendable>: Sendable {
    private enum Outcome {
        case undecided
        case decided(Value)
    }
    private struct State {
        var continuation: CheckedContinuation<Value, Never>?
        var outcome: Outcome = .undecided
        var cleanup: (@Sendable () -> Void)?
    }
    private let state = Mutex(State())

    init() {}

    func begin(_ continuation: CheckedContinuation<Value, Never>) {
        let outcome: Outcome = state.withLock { s in
            if case .undecided = s.outcome { s.continuation = continuation }
            return s.outcome
        }
        if case .decided(let value) = outcome { continuation.resume(returning: value) }
    }

    func finish(_ value: Value) {
        let (continuation, cleanup) = state.withLock { s -> (CheckedContinuation<Value, Never>?, (@Sendable () -> Void)?) in
            guard case .undecided = s.outcome else { return (nil, nil) }
            s.outcome = .decided(value)
            defer {
                s.continuation = nil
                s.cleanup = nil
            }
            return (s.continuation, s.cleanup)
        }
        continuation?.resume(returning: value)
        cleanup?()
    }

    /// Runs `cleanup` once the result is decided (at once if it already is).
    func onFinish(_ cleanup: @escaping @Sendable () -> Void) {
        let runNow: Bool = state.withLock { s in
            if case .decided = s.outcome { return true }
            s.cleanup = cleanup
            return false
        }
        if runNow { cleanup() }
    }
}

/// Result of one iCloud save attempt.
enum DeliveryOutcome: Sendable, Hashable {
    case delivered
    case permanent(String)
    case retryable(after: TimeInterval?)
    case timedOut
}
