// KakurenekoEvents — T1 hook inbox, per-agent normalizers, attribution, dedupe.
// OWNER: agent "events" (also owns Sources/KakurenekoHook and Tests/KakurenekoEventsTests).
// Spec card: docs/ARCHITECTURE.md §9.1. Brief §3.3, §3.4, §3.6, §4.1–4.4.
//
// Public surface (binding): `EventInbox` only. Everything else is internal.
//
// Files: EventInbox (lifecycle, drains, watching, persistence) in this file; InboxStore.swift (directory listing,
// bounded reads, quarantine, GC); DirectoryWatcher.swift (vnode sources); LastEventStore.swift (proof of life);
// EventPipeline.swift (normalize → attribute → session key → roll-ups → dedupe); Normalizer*.swift (one table per
// agent family); Attribution.swift; Dedupe.swift; RawPayload.swift (untrusted JSON view + field caps).

import KakurenekoKit
import Dispatch
import Foundation
import notify
import Synchronization

/// Watches `~/.kakureneko/inbox` + the per-user temp-dir fallback inbox and emits normalized, attributed, deduplicated
/// `AgentEvent`s (brief §4.4, ARCHITECTURE §9.1).
///
/// * **Lifecycle:** obtain `events()` BEFORE `start()`. `start()` creates both inboxes (+ `.tmp/`, `bad/`, 0700),
///   loads `Paths.lastEventsFile`, arms a vnode watcher per inbox and the optional `com.kakureneko.inbox` Darwin
///   notification hint, garbage-collects `bad/` and `.tmp/`, then performs the launch drain (yielded to the
///   subscribers that exist at that point) before returning. A safety re-drain runs every 30 s on the injected
///   clock (it also re-arms a watcher that could not be armed and flushes proof of life). `stop()` tears everything
///   down, persists proof of life and finishes every stream. `start()` is idempotent.
/// * **Drains** (launch, vnode, timer, notify hint, `drainNow`) all run on ONE private serial queue: list both
///   inboxes, merge, sort globally by file name, ≤ 500 files per pass (passes repeat until the inboxes are empty),
///   then per file: bounded read → `InboxFile.parse` → `EventPipeline` → yield → delete. Unparseable or unusable
///   entries move to `bad/`. Nothing here blocks the caller's actor.
/// * **Proof of life** (`lastEventSeen()`): every parsed file counts for the integration named in its argv, persisted
///   atomically at most once per minute (and on `stop()`).
public final class EventInbox: AgentEventSource {
    /// Tunables (internal; tests shorten nothing that matters for production behaviour).
    struct Options: Sendable {
        /// Safety re-drain period (brief §4.4).
        var safetyInterval: Duration = .seconds(30)
        /// Files processed per drain pass (ARCHITECTURE §9.1).
        var maxFilesPerPass = 500
        /// Passes per drain before yielding the queue: one drain yields at most `InboxFile.maxQueuedFiles` events, the
        /// broadcaster's per-subscriber buffer, so a backlog never overflows a subscriber. Any remainder is picked up by
        /// the drain that the deletions' vnode events schedule right after (or the safety tick).
        var maxPassesPerDrain = InboxFile.maxQueuedFiles / 500
        /// Minimum spacing of `lastEventsFile` writes (except on `stop()`).
        var persistInterval: TimeInterval = 60
        /// `bad/` and `.tmp/` entries older than this are deleted.
        var garbageAge: TimeInterval = InboxFile.garbageCollectionAge
        /// How often garbage collection runs after the one at `start()`.
        var garbageCollectionInterval: TimeInterval = 3_600
        /// Register the `com.kakureneko.inbox` Darwin notification as an extra wake-up hint.
        var observeDarwinNotification = true
        /// Wall clock for file ages (mtimes are kernel wall-clock times, independent of the injected clock).
        var wallClock: @Sendable () -> Date = { Date() }
        /// `.app` bundle path → bundle identifier, for host attribution.
        var bundleIdentifierLookup: EventPipeline.BundleIdentifierLookup = EventPipeline.liveBundleIdentifier
    }

    enum DrainTrigger: String, Sendable {
        case launch, vnode, timer, notify, manual
    }

    private enum Phase { case idle, starting, running, stopped }

    private struct State {
        var phase: Phase = .idle
        var pipeline: EventPipeline
        var lastSeenDirty = false
        /// `Paths.lastEventsFile` has been merged into `pipeline.lastSeen`.
        var lastSeenLoaded = false
        var lastPersistedAt: Date?
        var lastGarbageCollection: Date?
        /// A coalesced drain is queued and has not started yet.
        var drainScheduled = false
        var watchers: [DirectoryWatcher] = []
        var notifyToken: Int32?
        var timer: Task<Void, Never>?
        /// Files that could not be deleted after processing (never re-processed; bounded).
        var undeletable: Set<String> = []
    }

    private let paths: Paths
    private let clock: any KakurenekoClock
    private let logger: KakurenekoLogger
    private let options: Options
    private let store: InboxStore
    private let lastEventStore: LastEventStore
    /// Large enough for a full drain pass (never truncates the launch drain).
    private let broadcaster = AsyncBroadcaster<AgentEvent>(bufferLimit: InboxFile.maxQueuedFiles)
    /// The one serial queue for every drain, watcher callback and file operation.
    private let queue = DispatchQueue(label: "com.kakureneko.events.inbox", qos: .utility)
    private let state: Mutex<State>

    static let maxUndeletableEntries = 1_024

    /// Binding signature.
    public convenience init(
        paths: Paths,
        matcher: any AgentSignatureMatching = BasicAgentSignatureMatcher(),
        clock: any KakurenekoClock = SystemClock(),
        logger: KakurenekoLogger = KakurenekoLogger(.events)
    ) {
        self.init(paths: paths, matcher: matcher, clock: clock, logger: logger, options: Options())
    }

    init(paths: Paths, matcher: any AgentSignatureMatching, clock: any KakurenekoClock, logger: KakurenekoLogger, options: Options) {
        self.paths = paths
        self.clock = clock
        self.logger = logger
        self.options = options
        self.store = InboxStore(paths: paths)
        self.lastEventStore = LastEventStore(file: paths.lastEventsFile)
        self.state = Mutex(State(pipeline: EventPipeline(matcher: matcher, bundleIdentifierLookup: options.bundleIdentifierLookup)))
    }

    deinit {
        let (timer, watchers, token) = state.withLock { s in (s.timer, s.watchers, s.notifyToken) }
        timer?.cancel()
        for watcher in watchers { watcher.disarm() }
        if let token { notify_cancel(token) }
        broadcaster.finish()
    }

    // MARK: - AgentEventSource

    /// Never throws: an inbox that cannot be created or watched right now (e.g. a permissions problem) is logged and
    /// retried by the 30 s safety tick, so a transient filesystem problem never aborts the app's start sequence.
    public func start() async throws {
        let proceed = state.withLock { s -> Bool in
            guard s.phase == .idle else { return false }
            s.phase = .starting
            return true
        }
        guard proceed else { return }

        let armed = await onQueue { self.prepare() }
        if armed == 0 {
            logger.error("inbox: no inbox directory could be created or watched; retrying every \(options.safetyInterval)")
        }
        let launched = await onQueue { () -> Int in
            let stopped = self.state.withLock { s -> Bool in
                guard s.phase == .starting else { return true }
                s.phase = .running
                return false
            }
            guard !stopped else { return 0 }
            self.collectGarbageIfDue(force: true)
            return self.drain(.launch).count
        }
        startSafetyTimer()
        logger.info("inbox: started (\(armed) inbox(es) watched, launch drain accepted \(launched))")
    }

    public func stop() async {
        let resources = state.withLock { s -> (Task<Void, Never>?, [DirectoryWatcher], Int32?)? in
            guard s.phase != .stopped else { return nil }
            s.phase = .stopped
            defer {
                s.timer = nil
                s.watchers = []
                s.notifyToken = nil
            }
            return (s.timer, s.watchers, s.notifyToken)
        }
        guard let (timer, watchers, token) = resources else { return }
        timer?.cancel()
        await onQueue {
            for watcher in watchers { watcher.disarm() }
            if let token { notify_cancel(token) }
            self.persistLastSeen(force: true)
        }
        broadcaster.finish()
        logger.info("inbox: stopped")
    }

    public func events() -> AsyncStream<AgentEvent> { broadcaster.stream() }

    @discardableResult
    public func drainNow() async -> [AgentEvent] {
        await onQueue { self.drain(.manual) }
    }

    public func lastEventSeen() async -> [AgentID: Date] {
        if !state.withLock({ $0.lastSeenLoaded }) {
            await onQueue { self.loadLastSeenIfNeeded() } // asked before start(): read the file off the caller's actor
        }
        return state.withLock { $0.pipeline.lastSeen }
    }

    // MARK: - Start-up (on the queue)

    /// Creates both inboxes, loads proof of life, arms the watchers and the notify hint. Returns the number of
    /// inboxes being watched.
    private func prepare() -> Int {
        loadLastSeenIfNeeded()

        var watchers: [DirectoryWatcher] = []
        var armed = 0
        for inbox in store.inboxes {
            let watcher = DirectoryWatcher(directory: inbox, queue: queue) { [weak self] in self?.scheduleDrain(.vnode) }
            if watcher.arm() {
                armed += 1
            } else {
                logger.warning("inbox: cannot watch \(paths.displayPath(inbox)) (errno \(errno)); the safety re-drain retries")
            }
            watchers.append(watcher)
        }

        var token: Int32?
        if options.observeDarwinNotification {
            var raw: Int32 = 0
            let status = notify_register_dispatch(KakurenekoID.inboxDarwinNotification, &raw, queue) { [weak self] _ in
                self?.scheduleDrain(.notify)
            }
            if status == UInt32(NOTIFY_STATUS_OK) { token = raw } else { logger.debug("inbox: notify_register_dispatch status \(status)") }
        }
        let keep = state.withLock { s -> Bool in
            guard s.phase == .starting else { return false } // stop() won the race: tear down what we armed
            s.watchers = watchers
            s.notifyToken = token
            return true
        }
        if !keep {
            for watcher in watchers { watcher.disarm() }
            if let token { notify_cancel(token) }
        }
        return armed
    }

    /// Merges `Paths.lastEventsFile` into proof of life once (newest date wins). On the queue.
    private func loadLastSeenIfNeeded() {
        guard !state.withLock({ $0.lastSeenLoaded }) else { return }
        let loaded = lastEventStore.load()
        if let failure = loaded.failure {
            logger.warning("inbox: \(paths.displayPath(paths.lastEventsFile)) unreadable (\(failure)); starting empty")
        }
        state.withLock { s in
            guard !s.lastSeenLoaded else { return }
            s.lastSeenLoaded = true
            for (agent, date) in loaded.values where date > (s.pipeline.lastSeen[agent] ?? .distantPast) {
                s.pipeline.lastSeen[agent] = date
            }
        }
    }

    private func startSafetyTimer() {
        let interval = options.safetyInterval
        let clock = self.clock
        let task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: interval) } catch { return }
                guard let self else { return }
                self.queue.async { self.safetyTick() }
            }
        }
        let keep = state.withLock { s -> Bool in
            guard s.phase == .running else { return false }
            s.timer = task
            return true
        }
        if !keep { task.cancel() }
    }

    /// Timer body (on the queue): re-arm missing watchers, drain, GC when due, flush proof of life.
    private func safetyTick() {
        let watchers = state.withLock { $0.phase == .running ? $0.watchers : [] }
        for watcher in watchers where !watcher.isArmed {
            if watcher.arm() { logger.info("inbox: re-armed watcher for \(paths.displayPath(watcher.directory))") }
        }
        guard !watchers.isEmpty else { return }
        drain(.timer)
        collectGarbageIfDue(force: false)
        persistLastSeen(force: false)
    }

    // MARK: - Draining (on the queue)

    /// Coalesces bursts of vnode / notify callbacks into one queued drain.
    private func scheduleDrain(_ trigger: DrainTrigger) {
        let enqueue = state.withLock { s -> Bool in
            guard s.phase == .running, !s.drainScheduled else { return false }
            s.drainScheduled = true
            return true
        }
        guard enqueue else { return }
        queue.async {
            self.state.withLock { $0.drainScheduled = false }
            self.drain(trigger)
        }
    }

    /// Drains both inboxes in passes of ≤ `maxFilesPerPass` files until they are empty. Returns the accepted events
    /// (already yielded to every subscriber).
    @discardableResult
    func drain(_ trigger: DrainTrigger) -> [AgentEvent] {
        dispatchPrecondition(condition: .onQueue(queue))
        guard state.withLock({ $0.phase != .stopped }) else { return [] }
        loadLastSeenIfNeeded() // a drainNow() before start() must never persist proof of life without the file's
        var accepted: [AgentEvent] = []
        var tally = DrainTally()
        for _ in 0..<max(1, options.maxPassesPerDrain) {
            let more = drainPass(into: &accepted, tally: &tally)
            if !more { break }
        }
        if tally.files > 0 {
            logger.debug("inbox: \(trigger.rawValue) drain: \(tally.files) file(s), \(accepted.count) accepted, \(tally.dropped) dropped, \(tally.quarantined) to bad/")
        }
        persistLastSeen(force: false)
        return accepted
    }

    private struct DrainTally {
        var files = 0
        var dropped = 0
        var quarantined = 0
    }

    /// One pass. Returns true when more candidates remain.
    private func drainPass(into accepted: inout [AgentEvent], tally: inout DrainTally) -> Bool {
        let skip = state.withLock { $0.undeletable }
        let listing = store.list()
        for junk in listing.junk.prefix(options.maxFilesPerPass) {
            InboxStore.quarantine(junk)
            tally.quarantined += 1
            logger.debug("inbox: moved non-event entry \(junk.name) to bad/")
        }
        let candidates = skip.isEmpty ? listing.candidates : listing.candidates.filter { !skip.contains($0.path) }
        let batch = candidates.prefix(max(1, options.maxFilesPerPass))
        for entry in batch {
            guard state.withLock({ $0.phase != .stopped }) else { return false }
            tally.files += 1
            process(entry, accepted: &accepted, tally: &tally)
        }
        return candidates.count > batch.count
    }

    private func process(_ entry: InboxStore.Entry, accepted: inout [AgentEvent], tally: inout DrainTally) {
        let data: Data
        switch InboxStore.read(entry.path) {
        case .vanished:
            return
        case .unusable(let reason):
            quarantine(entry, reason: reason, tally: &tally)
            return
        case .data(let contents):
            data = contents
        }
        let parsed: (header: InboxHeader, payload: Data)
        do {
            parsed = try InboxFile.parse(data)
        } catch {
            quarantine(entry, reason: "unparseable (\(error))", tally: &tally)
            return
        }
        let receivedAt = clock.now()
        let outcome = state.withLock { s -> EventPipeline.Outcome in
            let before = s.pipeline.lastSeen
            let outcome = s.pipeline.process(id: entry.name, header: parsed.header, payload: parsed.payload, receivedAt: receivedAt)
            if s.pipeline.lastSeen != before { s.lastSeenDirty = true }
            return outcome
        }
        switch outcome {
        case .accepted(let event):
            broadcaster.yield(event)
            accepted.append(event)
        case .dropped(let reason):
            tally.dropped += 1
            logger.debug("inbox: dropped \(entry.name): \(reason)")
        }
        if !InboxStore.remove(entry) {
            let code = errno
            logger.error("inbox: cannot delete processed \(entry.name) (errno \(code)); it will be skipped")
            state.withLock { s in
                if s.undeletable.count >= Self.maxUndeletableEntries { s.undeletable.removeAll() }
                s.undeletable.insert(entry.path)
            }
        }
    }

    private func quarantine(_ entry: InboxStore.Entry, reason: String, tally: inout DrainTally) {
        tally.quarantined += 1
        logger.notice("inbox: \(entry.name) moved to bad/: \(reason)")
        InboxStore.quarantine(entry)
    }

    // MARK: - Housekeeping (on the queue)

    private func collectGarbageIfDue(force: Bool) {
        let now = options.wallClock()
        let due = state.withLock { s -> Bool in
            if !force, let last = s.lastGarbageCollection,
               now.timeIntervalSince(last) < options.garbageCollectionInterval, now >= last {
                return false
            }
            s.lastGarbageCollection = now
            return true
        }
        guard due else { return }
        let removed = store.collectGarbage(now: now, maxAge: options.garbageAge)
        if removed > 0 { logger.info("inbox: garbage-collected \(removed) stale bad/ or .tmp/ entr\(removed == 1 ? "y" : "ies")") }
    }

    /// Writes proof of life when it changed and the last write is at least `persistInterval` old (or `force`).
    private func persistLastSeen(force: Bool) {
        let now = clock.now()
        let snapshot = state.withLock { s -> [AgentID: Date]? in
            guard s.lastSeenDirty else { return nil }
            if !force, let last = s.lastPersistedAt, now.timeIntervalSince(last) < options.persistInterval, now >= last {
                return nil
            }
            s.lastSeenDirty = false
            s.lastPersistedAt = now
            return s.pipeline.lastSeen
        }
        guard let snapshot else { return }
        do {
            try lastEventStore.save(snapshot)
        } catch {
            state.withLock { $0.lastSeenDirty = true }
            logger.warning("inbox: cannot write \(paths.displayPath(paths.lastEventsFile)): \(error)")
        }
    }

    // MARK: - Queue hop

    /// Runs `work` on the serial queue without blocking the caller's executor.
    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
