import KakurenekoKit
import Foundation
import Synchronization

/// T2 source for Claude Code (R02 §3, §8.1; ARCHITECTURE §9.3): a read-only watcher on
/// `<claude config>/sessions/*.json` plus a `claude agents --json --all` poller, emitting full
/// `ClaudeStateSnapshot`s on start, after every change and after every poll.
///
/// * Watching: FSEvents with file events (Claude rewrites `<pid>.json` IN PLACE) debounced 250 ms, plus an mtime
///   sweep every `SamplingCadence.processScanInterval`; a missing directory is re-checked every 60 s.
/// * Polling: at `SamplingCadence.claudeAgentsPollInterval` (15 s lid closed / 60 s open), via the injected
///   `SubprocessRunning` only (stdin `/dev/null`, `paths.agentSubprocessEnvironment` + `DISABLE_AUTOUPDATER=1` +
///   `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, `.readOnly`, 10 s timeout).
/// * Transcript tails are re-read 1.5 s and 5 s after a busy → idle change (`turn_duration` lags the record).
///
/// Isolation: reads, polls and emission run on the `ClaudeStateCore` actor; timers are tasks on the injected clock;
/// the FSEvents callback arrives on a private serial queue. `stop()` is final: it finishes every stream.
public final class ClaudeStateWatcher: ClaudeStateSource {
    private let runtime: ClaudeWatchRuntime

    /// Binding signature.
    public convenience init(paths: Paths, subprocess: any SubprocessRunning, processes: any ProcessLookup,
                            clock: any KakurenekoClock = SystemClock(), logger: KakurenekoLogger = KakurenekoLogger(.sessions)) {
        self.init(paths: paths, subprocess: subprocess, processes: processes, clock: clock, logger: logger,
                  files: PosixClaudeFileAccess())
    }

    /// Designated initializer with an injectable file access layer (tests).
    init(paths: Paths, subprocess: any SubprocessRunning, processes: any ProcessLookup, clock: any KakurenekoClock,
         logger: KakurenekoLogger, files: any ClaudeFileAccess) {
        let core = ClaudeStateCore(paths: paths, subprocess: subprocess, processes: processes, files: files,
                                   clock: clock, logger: logger)
        runtime = ClaudeWatchRuntime(core: core, directory: paths.claudeSessionsDirectory, files: files, clock: clock,
                                     logger: logger)
    }

    deinit { runtime.shutdown(finishStreams: true) }

    public func start() async { await runtime.start() }

    public func stop() async { runtime.shutdown(finishStreams: true) }

    public func snapshots() -> AsyncStream<ClaudeStateSnapshot> { runtime.core.broadcaster.stream() }

    public func current() async -> ClaudeStateSnapshot { await runtime.core.snapshot() }

    public func setCadence(_ cadence: SamplingCadence) async { await runtime.setCadence(cadence) }

    // MARK: - Internal (tests)

    var isWatchingDirectory: Bool { runtime.isWatchingDirectory }
    var cadence: SamplingCadence { runtime.cadence }
}

/// Owns the watcher's tasks and the FSEvents stream. Tasks hold the runtime only while they run; `shutdown`
/// cancels all of them.
final class ClaudeWatchRuntime: Sendable {
    /// Debounce for FSEvents bursts (ARCHITECTURE §9.3).
    static let debounce: Duration = .milliseconds(250)
    /// A missing `sessions/` directory is looked for again this often.
    static let directoryRecheck: Duration = .seconds(60)
    /// Transcript re-reads after a busy → idle change (`turn_duration` is written just after the turn).
    static let tailRereadDelays: [Duration] = [.milliseconds(1500), .seconds(5)]

    private struct Control {
        var started = false
        var stopped = false
        var cadence: SamplingCadence = .lidOpen
        var poll: Task<Void, Never>?
        var sweep: Task<Void, Never>?
        var directoryCheck: Task<Void, Never>?
        var debounce: Task<Void, Never>?
        var reread: Task<Void, Never>?
        var watcher: FSEventsDirectoryWatcher?

        mutating func takeTasks() -> [Task<Void, Never>] {
            defer { poll = nil; sweep = nil; directoryCheck = nil; debounce = nil; reread = nil }
            return [poll, sweep, directoryCheck, debounce, reread].compactMap { $0 }
        }
    }

    let core: ClaudeStateCore
    private let directory: URL
    private let files: any ClaudeFileAccess
    private let clock: any KakurenekoClock
    private let logger: KakurenekoLogger
    private let control = Mutex(Control())

    init(core: ClaudeStateCore, directory: URL, files: any ClaudeFileAccess, clock: any KakurenekoClock,
         logger: KakurenekoLogger) {
        self.core = core
        self.directory = directory
        self.files = files
        self.clock = clock
        self.logger = logger
    }

    var isWatchingDirectory: Bool { control.withLock { $0.watcher?.isRunning ?? false } }
    var cadence: SamplingCadence { control.withLock { $0.cadence } }

    // MARK: - Lifecycle

    func start() async {
        let begin = control.withLock { c -> Bool in
            guard !c.started, !c.stopped else { return false }
            c.started = true
            return true
        }
        guard begin else { return }
        // Arm the watcher before the first read so no change can slip between them.
        let watching = armDirectoryWatcherIfPossible()
        handle(await core.refresh(reason: "start", force: true))
        control.withLock { c in
            guard c.started, !c.stopped else { return }
            c.poll = Task { [weak self] in await self?.pollLoop(initialDelay: .zero) }
            c.sweep = Task { [weak self] in await self?.sweepLoop() }
            if !watching {
                c.directoryCheck = Task { [weak self] in await self?.directoryCheckLoop() }
            }
        }
        logger.info("claude state watcher started (\(watching ? "watching" : "waiting for") sessions directory)")
    }

    func shutdown(finishStreams: Bool) {
        let (tasks, watcher, wasRunning) = control.withLock { c -> ([Task<Void, Never>], FSEventsDirectoryWatcher?, Bool) in
            let wasRunning = c.started
            c.stopped = true
            c.started = false
            let watcher = c.watcher
            c.watcher = nil
            return (c.takeTasks(), watcher, wasRunning)
        }
        for task in tasks { task.cancel() }
        watcher?.stop()
        if finishStreams { core.broadcaster.finish() }
        if wasRunning { logger.info("claude state watcher stopped") }
    }

    func setCadence(_ cadence: SamplingCadence) async {
        let restart = control.withLock { c -> Bool in
            let changed = c.cadence != cadence
            c.cadence = cadence
            return changed && c.started && !c.stopped
        }
        guard restart else { return }
        // Keep the poll phase: the next poll comes one NEW interval after the last one (immediately if overdue).
        let lastPoll = await core.lastPollAt
        let interval = cadence.claudeAgentsPollInterval.timeInterval
        let delay = lastPoll.map { max(0, interval - clock.now().timeIntervalSince($0)) } ?? 0
        control.withLock { c in
            guard c.started, !c.stopped else { return }
            c.poll?.cancel()
            c.sweep?.cancel()
            c.poll = Task { [weak self] in await self?.pollLoop(initialDelay: .interval(delay)) }
            c.sweep = Task { [weak self] in await self?.sweepLoop() }
        }
        logger.info("claude state cadence \(cadence.rawValue)")
    }

    // MARK: - Change handling

    /// FSEvents (or a retry) asked for a read: one refresh 250 ms later, absorbing everything that arrives meanwhile.
    func scheduleRefresh() {
        control.withLock { c in
            guard c.started, !c.stopped, c.debounce == nil else { return }
            c.debounce = Task { [weak self] in await self?.debouncedRefresh() }
        }
    }

    private func debouncedRefresh() async {
        do {
            try await clock.sleep(for: Self.debounce)
        } catch {
            return
        }
        control.withLock { $0.debounce = nil }
        handle(await core.refresh(reason: "change", force: false))
    }

    private func handle(_ outcome: ClaudeStateCore.RefreshOutcome) {
        if outcome.retryWanted { scheduleRefresh() }
        if outcome.tailRereadWanted { scheduleTailRereads() }
    }

    private func scheduleTailRereads() {
        control.withLock { c in
            guard c.started, !c.stopped else { return }
            c.reread?.cancel()
            c.reread = Task { [weak self] in await self?.tailRereads() }
        }
    }

    private func tailRereads() async {
        var elapsed: Duration = .zero
        for delay in Self.tailRereadDelays {
            do {
                try await clock.sleep(for: delay - elapsed)
            } catch {
                return
            }
            elapsed = delay
            let outcome = await core.refresh(reason: "turn_duration re-read", force: false)
            if outcome.retryWanted { scheduleRefresh() }
        }
    }

    // MARK: - Loops

    private func pollLoop(initialDelay: Duration) async {
        if initialDelay > .zero {
            do { try await clock.sleep(for: initialDelay) } catch { return }
        }
        while !Task.isCancelled {
            handle(await core.pollAndRefresh())
            let interval = control.withLock { $0.cadence.claudeAgentsPollInterval }
            do { try await clock.sleep(for: interval) } catch { return }
        }
    }

    private func sweepLoop() async {
        while !Task.isCancelled {
            let interval = control.withLock { $0.cadence.processScanInterval }
            do { try await clock.sleep(for: interval) } catch { return }
            if await core.recordFilesChanged() {
                handle(await core.refresh(reason: "mtime sweep", force: false))
            }
        }
    }

    private func directoryCheckLoop() async {
        while !Task.isCancelled {
            do { try await clock.sleep(for: Self.directoryRecheck) } catch { return }
            if armDirectoryWatcherIfPossible() {
                handle(await core.refresh(reason: "directory appeared", force: false))
                control.withLock { $0.directoryCheck = nil }
                return
            }
        }
    }

    /// Starts FSEvents on the sessions directory if it exists. True when watching.
    private func armDirectoryWatcherIfPossible() -> Bool {
        guard files.stamp(directory)?.isDirectory == true else { return false }
        let path = directory.path(percentEncoded: false)
        return control.withLock { c -> Bool in
            guard !c.stopped else { return false }
            if let existing = c.watcher, existing.isRunning { return true }
            let watcher = FSEventsDirectoryWatcher(path: path) { [weak self] in self?.scheduleRefresh() }
            guard watcher.start() else {
                logger.warning("FSEvents refused the claude sessions directory; relying on the mtime sweep")
                return false
            }
            c.watcher = watcher
            return true
        }
    }
}
