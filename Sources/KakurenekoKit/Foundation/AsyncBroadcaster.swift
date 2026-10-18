import Foundation
import Synchronization

/// Multi-subscriber `AsyncStream` fan-out. Every service that exposes a stream (`events()`,
/// `snapshots()`, `remoteCommands()`, …) uses one of these so that each call returns an
/// independent stream (AsyncStream itself is single-consumer).
///
/// * `replayLatest`: a new subscriber immediately receives the most recent value (snapshots).
/// * `replayFilter`: only elements passing it are remembered for replay (e.g. `PowerMonitor` replays only
///   `.snapshot`, never a stale `.lidChanged`/`.willSleep` edge). nil = every element.
/// * `bufferLimit`: per-subscriber buffer (`.bufferingNewest`); slow consumers drop the oldest. Event sources
///   that can burst (the inbox drains ≤ 500 files per pass) use `InboxFile.maxQueuedFiles`.
/// * Subscriptions end when the consuming task is cancelled or `finish()` is called.
public final class AsyncBroadcaster<Element: Sendable>: Sendable {
    private struct State {
        var nextID: UInt64 = 0
        var continuations: [UInt64: AsyncStream<Element>.Continuation] = [:]
        var latest: Element?
        var finished = false
    }
    private let state = Mutex(State())
    private let replayLatest: Bool
    private let bufferLimit: Int
    private let replayFilter: (@Sendable (Element) -> Bool)?

    public init(replayLatest: Bool = false, bufferLimit: Int = 256, replayFilter: (@Sendable (Element) -> Bool)? = nil) {
        self.replayLatest = replayLatest
        self.bufferLimit = max(1, bufferLimit)
        self.replayFilter = replayFilter
    }

    /// A new independent subscription.
    public func stream() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: .bufferingNewest(bufferLimit))
        let (id, replay, finished): (UInt64, Element?, Bool) = state.withLock { s in
            if s.finished { return (0, nil, true) }
            s.nextID += 1
            s.continuations[s.nextID] = continuation
            return (s.nextID, replayLatest ? s.latest : nil, false)
        }
        if finished {
            continuation.finish()
            return stream
        }
        if let replay { continuation.yield(replay) }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    /// Delivers `element` to every current subscriber and remembers it as `latest` (if it passes `replayFilter`).
    public func yield(_ element: Element) {
        let remember = replayFilter?(element) ?? true
        let targets: [AsyncStream<Element>.Continuation] = state.withLock { s in
            guard !s.finished else { return [] }
            if remember { s.latest = element }
            return Array(s.continuations.values)
        }
        for continuation in targets { continuation.yield(element) }
    }

    /// Ends every subscription; later `stream()` calls return finished streams.
    public func finish() {
        let targets: [AsyncStream<Element>.Continuation] = state.withLock { s in
            s.finished = true
            defer { s.continuations.removeAll() }
            return Array(s.continuations.values)
        }
        for continuation in targets { continuation.finish() }
    }

    public var latest: Element? { state.withLock { $0.latest } }
    public var subscriberCount: Int { state.withLock { $0.continuations.count } }
}
