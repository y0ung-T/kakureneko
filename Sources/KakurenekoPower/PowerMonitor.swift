// KakurenekoPower — PowerMonitor: lid edges, sleep/wake (with acknowledger), power-off, session switches, external
// displays, closed-lid user activity and periodic snapshots, as one fan-out `PowerEvent` stream.
// OWNER: agent "power". Spec card: docs/ARCHITECTURE.md §9.4 (`PowerMonitor`). Brief §7.2, §6.5; R01 §6.2; R07 §14;
// R08 §8–9.
//
// Inputs:
//   * the live observers (PowerObservers.swift) push `PowerObservation`s from their own threads: IOKit clamshell
//     interest + `IORegisterForSystemPower`, NSWorkspace/ProcessInfo notifications, CoreGraphics display
//     reconfiguration, Darwin power-source / thermal-pressure notifications;
//   * a 1 Hz poll of `AppleClamshellState` (through `PowerControlling.kernelFlags()`) backs up the lid message and, while
//     the lid is closed, detects user input (Screen Sharing) and external-display changes;
//   * a snapshot worker takes `PowerControlling.snapshot()` every 15 s and whenever something changed (coalesced).
//
// Ordering (by construction): every detector update and every emission runs on ONE private serial queue. A snapshot is
// re-aligned there with fresh lid/display reads before it is published, so a consumer never receives a snapshot that
// contradicts the last edge, and a stale reading can never produce a false reverse edge. Repeated messages, the
// AC-triggered clamshell message and the poll are filtered by the detectors (PowerEventDetectors.swift). Only
// `.snapshot` is replayed to late subscribers.

import KakurenekoKit
import Dispatch
import Foundation
import Synchronization

/// Power/lid/sleep event source (brief §7.2).
public final class PowerMonitor: PowerEventSource {
    /// Intervals (all measured on the injected clock; tests keep the defaults and drive a `TestClock`).
    struct Timing: Sendable, Hashable {
        /// `AppleClamshellState` backup poll (also closed-lid input + display check).
        var lidPollInterval: Duration = .seconds(1)
        /// Periodic snapshot.
        var snapshotInterval: Duration = .seconds(15)
        /// `kIOMessageSystemWillSleep` is allowed automatically after this if the consumer has not (kernel: 30 s).
        var sleepAcknowledgementDeadline: Duration = .seconds(8)
    }

    private enum Phase: Sendable { case idle, running, stopped }

    private struct State {
        var phase: Phase = .idle
        // Detectors: mutated only on `queue`.
        var lid = LidEdgeDetector()
        var display = BoolEdgeDetector()
        var activity = UserActivityDetector()
        /// `willSleep` acknowledgers not yet allowed (settled on wake, on stop and on deinit at the latest).
        var pendingAcknowledgers: [PowerChangeAcknowledger] = []
        var tasks: [Task<Void, Never>] = []
    }

    private let power: any PowerControlling
    private let clock: any KakurenekoClock
    private let logger: KakurenekoLogger
    private let observers: [any PowerObserving]
    private let displays: any ExternalDisplayReading
    private let input: any UserInputIdleReading
    private let timing: Timing
    /// Dry-run-only developer tool; while it says `closed`, clamshell messages carry the simulated value.
    private let lidSimulation: LidSimulation?
    /// Serializes detector updates and emissions (total order of everything a subscriber sees).
    private let queue = DispatchQueue(label: "com.kakureneko.power.monitor", qos: .userInitiated)
    private let broadcaster = AsyncBroadcaster<PowerEvent>(replayLatest: true, replayFilter: { $0.isSnapshot })
    /// Snapshot requests; `.bufferingNewest(1)` coalesces bursts into one pending request.
    private let snapshotRequests: AsyncStream<Void>
    private let snapshotRequester: AsyncStream<Void>.Continuation
    private let state = Mutex(State())

    /// Binding signature. `power` supplies the lid reading (`kernelFlags()`) and the snapshots.
    /// - Parameter lidSimulation: developer tool, dry-run only (`LidSimulation.fromEnvironment`). Pass the SAME object
    ///   to the `PowerController` that is `power`: display and input reads follow its control file here, the lid
    ///   reading follows it there, and a real clamshell message never contradicts a simulated closed lid.
    public convenience init(
        power: any PowerControlling,
        clock: any KakurenekoClock = SystemClock(),
        logger: KakurenekoLogger = KakurenekoLogger(.power),
        lidSimulation: LidSimulation? = nil
    ) {
        let displays: any ExternalDisplayReading = lidSimulation.map { SimulatedDisplayReader(base: LiveDisplayReader(), simulation: $0) }
            ?? LiveDisplayReader()
        let input: any UserInputIdleReading = lidSimulation.map { SimulatedInputReader(base: LiveUserInputIdleReader(), simulation: $0) }
            ?? LiveUserInputIdleReader()
        self.init(
            power: power,
            clock: clock,
            logger: logger,
            observers: [
                IOKitPowerObserver(logger: logger),
                WorkspaceObserver(),
                DisplayReconfigurationObserver(),
                PowerNotifyObserver(),
            ],
            displays: displays,
            input: input,
            lidSimulation: lidSimulation
        )
    }

    /// Designated (internal) initializer: tests inject manual observers and fake display / input readers.
    init(
        power: any PowerControlling,
        clock: any KakurenekoClock,
        logger: KakurenekoLogger,
        observers: [any PowerObserving],
        displays: any ExternalDisplayReading,
        input: any UserInputIdleReading,
        timing: Timing = Timing(),
        lidSimulation: LidSimulation? = nil
    ) {
        self.lidSimulation = lidSimulation
        self.power = power
        self.clock = clock
        self.logger = logger
        self.observers = observers
        self.displays = displays
        self.input = input
        self.timing = timing
        (snapshotRequests, snapshotRequester) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        let (tasks, pending) = state.withLock { s -> ([Task<Void, Never>], [PowerChangeAcknowledger]) in
            s.phase = .stopped
            return (s.tasks, s.pendingAcknowledgers)
        }
        for task in tasks { task.cancel() }
        for observer in observers { observer.stop() }
        for acknowledger in pending { acknowledger.allow() }
        snapshotRequester.finish()
        broadcaster.finish()
    }

    // MARK: - PowerEventSource

    /// Primes the detectors with the current lid/display state (no edge), registers every observer, starts the 1 Hz
    /// poll, the 15 s snapshot timer and the snapshot worker, and requests a first snapshot. Idempotent; a stopped
    /// monitor stays stopped (its streams are finished).
    @concurrent
    public func start() async {
        let begin = state.withLock { s -> Bool in
            guard s.phase == .idle else { return false }
            s.phase = .running
            return true
        }
        guard begin else { return }

        let now = clock.now()
        let closed = power.kernelFlags().clamshellClosed
        let external = displays.externalDisplayConnected()
        state.withLock { s in
            s.lid.prime(closed, now: now)
            s.display.prime(external)
        }

        let sink = PowerObservationSink { [weak self] observation in
            if let self {
                self.handle(observation)
            } else if case .systemWillSleep(let allow) = observation {
                allow() // never leave the kernel waiting 30 s
            }
        }
        var registered: [String] = []
        for observer in observers {
            if observer.start(sink) {
                registered.append(observer.name)
            } else {
                logger.warning("power observer \(observer.name) unavailable")
            }
        }

        let tasks = [makePollTask(), makeSnapshotTimerTask(), makeSnapshotWorker()]
        let stillRunning = state.withLock { s -> Bool in
            guard s.phase == .running else { return false }
            s.tasks = tasks
            return true
        }
        guard stillRunning else {
            for task in tasks { task.cancel() } // stop() raced this start
            return
        }
        requestSnapshot()
        let lid = closed.map { $0 ? "closed" : "open" } ?? "none"
        logger.notice("power monitor started: lid \(lid), external display \(external), observers \(registered.joined(separator: ","))")
        if let lidSimulation {
            logger.warning("LID SIMULATION (dry-run only): lid follows \(lidSimulation.controlFile.path(percentEncoded: false)) (`closed` = closed)")
        }
    }

    /// Tears everything down (`IODeregisterForSystemPower`, `IONotificationPortDestroy`, observers removed), allows every
    /// pending `willSleep`, and finishes every stream.
    public func stop() async {
        let (tasks, pending, wasRunning) = state.withLock { s -> ([Task<Void, Never>], [PowerChangeAcknowledger], Bool) in
            let running = s.phase == .running
            s.phase = .stopped
            defer {
                s.tasks = []
                s.pendingAcknowledgers = []
            }
            return (s.tasks, s.pendingAcknowledgers, running)
        }
        for task in tasks { task.cancel() }
        for observer in observers { observer.stop() }
        for acknowledger in pending { acknowledger.allow() }
        snapshotRequester.finish()
        broadcaster.finish()
        if wasRunning { logger.notice("power monitor stopped") }
    }

    public func events() -> AsyncStream<PowerEvent> { broadcaster.stream() }

    // MARK: - Observations

    /// Entry point for observers (any thread): hops to the monitor queue. A `willSleep` that arrives when the monitor is
    /// not running is allowed at once.
    func handle(_ observation: PowerObservation) {
        guard isRunning else {
            if case .systemWillSleep(let allow) = observation { allow() }
            return
        }
        queue.async { self.process(observation) }
    }

    /// Waits until every observation queued so far has been processed (tests).
    func drain() async {
        await onQueue {}
    }

    /// Runs on `queue`.
    private func process(_ observation: PowerObservation) {
        guard isRunning else {
            if case .systemWillSleep(let allow) = observation { allow() }
            return
        }
        switch observation {
        case .clamshellMessage(let real):
            let closed = lidSimulation?.clamshellClosed(real: real) ?? real
            let now = clock.now()
            if let edge = state.withLock({ $0.lid.observe(closed, now: now) }) {
                logger.notice("lid \(edge.rawValue) (interest message)")
                emit(.lidChanged(edge))
            }
            // Also sent on AC plug/unplug: the snapshot picks up the new power source.
            requestSnapshot()
        case .systemWillSleep(let allow):
            willSleep(allow)
        case .systemDidWake:
            // Acknowledgements of the sleep we just woke from are moot now: settle them (cancels their timers).
            allowPendingAcknowledgers()
            logger.notice("system did wake")
            emit(.didWake)
            requestSnapshot()
        case .willPowerOff:
            logger.notice("will power off")
            emit(.willPowerOff)
        case .sessionResignedActive:
            logger.notice("console session resigned active")
            emit(.sessionResignedActive)
            requestSnapshot()
        case .sessionBecameActive:
            logger.notice("console session became active")
            emit(.sessionBecameActive)
            requestSnapshot()
        case .displaysReconfigured:
            checkDisplays()
            requestSnapshot()
        case .powerConditionsChanged:
            requestSnapshot()
        }
    }

    /// `kIOMessageSystemWillSleep` (on `queue`): hand the consumer an acknowledger that auto-allows after the deadline.
    /// Without any subscriber the change is allowed at once (nobody would ever acknowledge it).
    private func willSleep(_ allow: @escaping @Sendable () -> Void) {
        guard broadcaster.subscriberCount > 0 else {
            logger.notice("system will sleep: no subscriber, allowed at once")
            allow()
            return
        }
        let deadline = timing.sleepAcknowledgementDeadline
        let logger = self.logger
        let acknowledger = SleepAcknowledgement.make(
            deadline: deadline,
            clock: clock,
            allow: allow,
            onTimeout: { logger.warning("system will sleep: not acknowledged within \(deadline); allowing") },
            onSettled: { [weak self] in self?.prunePendingAcknowledgers() }
        )
        let tracked = state.withLock { s -> Bool in
            guard s.phase == .running else { return false }
            s.pendingAcknowledgers.append(acknowledger)
            return true
        }
        guard tracked else {
            acknowledger.allow()
            return
        }
        logger.notice("system will sleep")
        emit(.willSleep(acknowledger))
    }

    // MARK: - Poll (1 Hz, on `queue`)

    /// One backup poll: lid edge from `AppleClamshellState`; while the lid is closed, closed-lid user input
    /// (`.userActivity`, ≤ once per 10 s) and external-display presence.
    private func pollOnce() {
        guard isRunning else { return }
        let now = clock.now()
        var changed = false
        if lidEdge(now: now, source: "poll") != nil { changed = true }
        let closedSince = state.withLock { s in s.lid.closed == true ? s.lid.closedSince : nil }
        if let closedSince {
            let seconds = input.secondsSinceUserInput()
            let activity = state.withLock {
                $0.activity.observe(secondsSinceInput: seconds, lidClosedSince: closedSince, now: now)
            }
            if let activity {
                logger.notice("user input with the lid closed (\(String(format: "%.1f", activity)) s ago)")
                emit(.userActivity(secondsSinceInput: activity))
            }
            if checkDisplays() { changed = true }
        }
        if changed { requestSnapshot() }
    }

    // MARK: - Snapshots

    /// Publishes a snapshot (on `queue`): fresh lid and display reads first (emitting any edge they reveal), then the
    /// snapshot with `lid` / `externalDisplayConnected` aligned to the detectors, so it never contradicts an edge.
    private func publish(_ snapshot: PowerSnapshot) {
        guard isRunning else { return }
        var aligned = snapshot
        lidEdge(now: clock.now(), source: "snapshot")
        checkDisplays()
        state.withLock { s in
            if let lid = s.lid.state { aligned.lid = lid }
            if let connected = s.display.value { aligned.externalDisplayConnected = connected }
        }
        emit(.snapshot(aligned))
    }

    /// Requests a snapshot (coalesced with any request still pending).
    func requestSnapshot() {
        snapshotRequester.yield(())
    }

    // MARK: - Helpers

    private var isRunning: Bool { state.withLock { $0.phase == .running } }

    private func emit(_ event: PowerEvent) {
        broadcaster.yield(event)
    }

    /// Reads `AppleClamshellState` now and emits `.lidChanged` on an edge (on `queue`).
    @discardableResult
    private func lidEdge(now: Date, source: String) -> LidState? {
        let reading = power.kernelFlags().clamshellClosed
        guard let edge = state.withLock({ $0.lid.observe(reading, now: now) }) else { return nil }
        logger.notice("lid \(edge.rawValue) (\(source))")
        emit(.lidChanged(edge))
        return edge
    }

    /// Re-reads external-display presence; emits `.externalDisplayChanged` on an edge (on `queue`). True on an edge.
    @discardableResult
    private func checkDisplays() -> Bool {
        let connected = displays.externalDisplayConnected()
        guard let edge = state.withLock({ $0.display.observe(connected) }) else { return false }
        logger.notice("external display \(edge ? "connected" : "disconnected")")
        emit(.externalDisplayChanged(connected: edge))
        return true
    }

    private func prunePendingAcknowledgers() {
        state.withLock { $0.pendingAcknowledgers.removeAll { $0.isAllowed } }
    }

    /// Allows (outside the lock: `allow()` re-enters `prunePendingAcknowledgers`) every pending acknowledger.
    private func allowPendingAcknowledgers() {
        let pending = state.withLock { s -> [PowerChangeAcknowledger] in
            defer { s.pendingAcknowledgers = [] }
            return s.pendingAcknowledgers
        }
        for acknowledger in pending { acknowledger.allow() }
    }

    /// Runs `body` on `queue` and returns when it finished.
    private func onQueue(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                body()
                continuation.resume()
            }
        }
    }

    private func makePollTask() -> Task<Void, Never> {
        let clock = self.clock
        let interval = timing.lidPollInterval
        return Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: interval) } catch { return }
                guard let self else { return }
                await self.onQueue { self.pollOnce() }
            }
        }
    }

    private func makeSnapshotTimerTask() -> Task<Void, Never> {
        let clock = self.clock
        let interval = timing.snapshotInterval
        return Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: interval) } catch { return }
                guard let self else { return }
                self.requestSnapshot()
            }
        }
    }

    private func makeSnapshotWorker() -> Task<Void, Never> {
        let requests = snapshotRequests
        return Task.detached(priority: .utility) { [weak self] in
            for await _ in requests {
                guard let self else { return }
                guard self.isRunning else { continue }
                let snapshot = await self.power.snapshot()
                await self.onQueue { self.publish(snapshot) }
            }
        }
    }
}
