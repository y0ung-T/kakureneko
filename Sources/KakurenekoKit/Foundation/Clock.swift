import Foundation
import Synchronization

/// Wall-clock + sleeping abstraction. Every timer-driven service takes `any KakurenekoClock`
/// so tests can drive time deterministically with `TestClock`.
///
/// Named `KakurenekoClock` (not `Clock`) to avoid shadowing `Swift.Clock`.
/// Engines that are pure state machines take `now: Date` parameters instead of a clock.
public protocol KakurenekoClock: Sendable {
    /// Current wall-clock time.
    func now() -> Date
    /// Suspends for `duration`. Throws `CancellationError` when the task is cancelled.
    func sleep(for duration: Duration) async throws
}

/// The real clock (`Date()` + `Task.sleep` with 10 % tolerance so the OS can coalesce wakeups).
public struct SystemClock: KakurenekoClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration, tolerance: duration / 10)
    }
}

/// A manually advanced clock for tests and previews.
///
/// * `now()` returns the virtual time.
/// * `sleep(for:)` suspends until `advance(by:)`/`set(_:)` moves the virtual time past the deadline.
/// * Cancellation of a sleeping task resumes it with `CancellationError`.
public final class TestClock: KakurenekoClock {
    private struct Sleeper {
        let id: UInt64
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }
    private struct State {
        var now: Date
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
        var cancelledBeforeRegistration: Set<UInt64> = []
    }
    private let state: Mutex<State>

    /// Default start: 2026-10-12T22:00:00Z (a fixed, readable epoch for fixtures).
    public static let defaultStart = Date(timeIntervalSince1970: 1_791_842_400)

    public init(start: Date = TestClock.defaultStart) {
        state = Mutex(State(now: start))
    }

    public func now() -> Date { state.withLock { $0.now } }

    /// Number of tasks currently suspended in `sleep(for:)`.
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let id: UInt64 = state.withLock { s in
            s.nextID += 1
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Outcome { case wait, resume, cancel }
                let outcome: Outcome = state.withLock { s in
                    if s.cancelledBeforeRegistration.remove(id) != nil { return .cancel }
                    let deadline = s.now.addingTimeInterval(duration.timeInterval)
                    if deadline <= s.now { return .resume }
                    s.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .wait
                }
                switch outcome {
                case .wait: break
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, any Error>? = state.withLock { s in
                if let index = s.sleepers.firstIndex(where: { $0.id == id }) {
                    return s.sleepers.remove(at: index).continuation
                }
                s.cancelledBeforeRegistration.insert(id)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Moves virtual time forward and resumes every sleeper whose deadline has passed (earliest first).
    public func advance(by duration: Duration) {
        let target = now().addingTimeInterval(duration.timeInterval)
        set(target)
    }

    /// Sets virtual time (never moves backwards) and resumes due sleepers.
    public func set(_ date: Date) {
        let due: [CheckedContinuation<Void, any Error>] = state.withLock { s in
            if date > s.now { s.now = date }
            let ready = s.sleepers.filter { $0.deadline <= s.now }.sorted { $0.deadline < $1.deadline }
            s.sleepers.removeAll { $0.deadline <= s.now }
            return ready.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
    }

    /// Deadlines of the tasks currently suspended in `sleep(for:)`, earliest first.
    public var sleeperDeadlines: [Date] { state.withLock { $0.sleepers.map(\.deadline).sorted() } }

    /// Waits until at least `count` tasks are sleeping, bounded by WALL-CLOCK time (default 5 s), returning as soon
    /// as it holds. Test helper: unlike a yield count, the bound does not shrink when the whole suite saturates the
    /// CPU (a yield returns at once when nothing else is runnable on this thread, and hundreds of yields can pass
    /// before a starved task gets to register its sleep).
    @discardableResult
    public func waitForSleepers(_ count: Int = 1, timeout: Duration = .seconds(5)) async -> Bool {
        await waitUntil(timeout: timeout) { sleeperCount >= count }
    }

    /// Waits (wall-clock bounded, default 5 s) until some task sleeps with a deadline at or before `deadline` —
    /// e.g. a retry timer due at a known instant — so a test can advance virtual time knowing the timer is armed.
    @discardableResult
    public func waitForSleeper(dueBy deadline: Date, timeout: Duration = .seconds(5)) async -> Bool {
        await waitUntil(timeout: timeout) { sleeperDeadlines.contains { $0 <= deadline } }
    }

    /// Yields until at least `count` tasks are sleeping (or `maxYields` is exhausted). Prefer the wall-clock
    /// bounded `waitForSleepers(_:timeout:)`.
    @discardableResult
    public func waitForSleepers(_ count: Int, maxYields: Int) async -> Bool {
        for _ in 0..<maxYields {
            if sleeperCount >= count { return true }
            await Task.yield()
        }
        return sleeperCount >= count
    }

    private func waitUntil(timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let wall = ContinuousClock()
        let end = wall.now.advanced(by: timeout)
        while !condition() {
            if wall.now >= end { return condition() }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }
}

extension Duration {
    /// The duration as `TimeInterval` (seconds, Double).
    public var timeInterval: TimeInterval {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    /// Creates a duration from a `TimeInterval` (seconds).
    public static func interval(_ seconds: TimeInterval) -> Duration {
        .milliseconds(Int64((seconds * 1000).rounded()))
    }
}
