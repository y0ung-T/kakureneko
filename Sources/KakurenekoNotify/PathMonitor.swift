import KakurenekoKit
import Dispatch
import Foundation
import Network
import Synchronization

/// Network reachability as Notify needs it: "is the path satisfied?" (R07 §14: drain and reconnect
/// immediately when the path becomes satisfied; skip background attempts while it is not).
protocol NetworkPathMonitoring: Sendable {
    /// Satisfied/unsatisfied updates (the current value is replayed to each new subscriber once known).
    func updates() -> AsyncStream<Bool>
    func start()
    func cancel()
}

/// `NWPathMonitor`-backed implementation. Its handler closure is created here, in the nonisolated library
/// (R08 pitfall 1), and only touches Sendable state.
final class LivePathMonitor: NetworkPathMonitoring {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.kakureneko.notify.path")
    private let broadcaster = AsyncBroadcaster<Bool>(replayLatest: true, bufferLimit: 8)
    private let started = Mutex(false)

    init() {}

    func updates() -> AsyncStream<Bool> { broadcaster.stream() }

    func start() {
        let shouldStart = started.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        guard shouldStart else { return }
        let broadcaster = self.broadcaster
        monitor.pathUpdateHandler = { @Sendable path in
            broadcaster.yield(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
        broadcaster.finish()
    }
}

/// Manually driven monitor for tests and previews.
final class ManualPathMonitor: NetworkPathMonitoring {
    private let broadcaster = AsyncBroadcaster<Bool>(replayLatest: true, bufferLimit: 8)

    init(initial: Bool? = nil) {
        if let initial { broadcaster.yield(initial) }
    }

    func updates() -> AsyncStream<Bool> { broadcaster.stream() }
    func start() {}
    func cancel() { broadcaster.finish() }

    /// Publishes a new path status.
    func set(satisfied: Bool) { broadcaster.yield(satisfied) }
}
