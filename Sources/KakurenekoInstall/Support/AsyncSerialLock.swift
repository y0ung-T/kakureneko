import Foundation
import Synchronization

/// FIFO async mutex: serializes install/uninstall/repair/deploy so two operations never interleave their
/// reads and writes of the shared install manifest (protocol rule "one operation at a time per agent").
///
/// Unlike an actor, the lock is held across suspension points (subprocesses, file I/O) of the body.
final class AsyncSerialLock: Sendable {
    private struct State {
        var locked = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    init() {}

    /// Runs `body` while holding the lock. Waiters are resumed in arrival order.
    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let acquired = state.withLock { s -> Bool in
                if !s.locked {
                    s.locked = true
                    return true
                }
                s.waiters.append(continuation)
                return false
            }
            if acquired { continuation.resume() }
        }
    }

    private func release() {
        let next = state.withLock { s -> CheckedContinuation<Void, Never>? in
            if s.waiters.isEmpty {
                s.locked = false
                return nil
            }
            // Ownership passes directly to the next waiter; `locked` stays true.
            return s.waiters.removeFirst()
        }
        next?.resume()
    }

    /// True while some operation holds the lock (tests).
    var isLocked: Bool { state.withLock { $0.locked } }
}
