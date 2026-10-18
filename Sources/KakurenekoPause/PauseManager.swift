import Darwin
import KakurenekoKit
import Foundation
import Synchronization

/// Pauses/thaws regular apps around agents (brief §6, R06; ARCHITECTURE §9.5).
///
/// * **Throttle** (default): `PRIO_DARWIN_BG` on every group member; **Freeze** (experimental, `settings.mode ==
///   .freeze` + self-test + complete topology): SIGSTOP via audit token; **Quit** (opt-in, memory pressure, clean
///   apps only): `terminate()`, relaunched on lid open.
/// * Groups come from the responsibility API (→ coalition → ppid); protection rules P-A…P-K decide what is touched.
/// * The journal (`paused.json`) is written (F_FULLFSYNC) BEFORE every signal or priority change, only for enriched
///   identities, with `simulated: true` in dry-run. Thaw is LIFO per group. `kakureneko-guard`, the crash handler and
///   launch recovery are the safety nets.
///
/// Isolation: `final class … : Sendable`; state in `Mutex`es. Heavy methods are `@concurrent`; `pause`, `recheck`,
/// `thawAll` and `recoverFromJournal` are serialized by an async lock, and a `thawAll`/termination arriving while a
/// pause runs aborts it before its next signal.
public final class PauseManager: AppPausing {
    let paths: Paths
    let signaller: any ProcessSignalling
    let processes: any ProcessLookup
    let dryRun: DryRunGate
    let guardExecutable: URL?
    let clock: any KakurenekoClock
    let logger: KakurenekoLogger
    let probe: any SystemProbing
    let candidates: any CandidateProviding
    let groupingResolver: any GroupingResolving
    let crashBuffer: any CrashThawPublishing
    /// Kakureneko's own pid (never paused; the guard watches it).
    let selfPID: pid_t
    /// Environment handed to `kakureneko-guard`.
    let guardEnvironment: [String: String]
    /// Extra guard arguments (tests: `--hang-timeout-ms`).
    let guardExtraArguments: [String]
    /// Where this module's own dry-run decisions go (`pause.guard`); signals/priorities are recorded by the gated
    /// signaller itself.
    let ledger: DryRunLedger?

    let journal: JournalStore
    let recovery: PauseRecovery
    let operations = AsyncSerialLock()

    /// Session-scoped decisions (one lid-closed pausing period).
    struct Session: Sendable {
        var began: Date?
        /// Apps thawed by a recheck match: protected for the rest of the session (keyed by the main's identity).
        var protected: [ProcessIdentity: ProtectedApp] = [:]
        /// Set by a hard-cap or watchdog thaw: `pause` refuses until a session-ending thaw.
        var latch: String?
        var lastRescan: Date?
    }

    struct State: Sendable {
        var selection: GroupingSelection?
        var session = Session()
        /// Display data per paused app (the journal is authoritative for WHAT is paused).
        var metadata: [Int32: PausedApp] = [:]
        /// Main identity per paused app (the main itself may be absent from the journal when it was already darwinbg).
        var mains: [Int32: ProcessIdentity] = [:]
        var crashHandlersInstalled = false
    }

    /// Serializes "check abort conditions, then signal" against `thawAll`/termination.
    struct SignalGate: Sendable {
        var terminating = false
        var generation: UInt64 = 0
    }

    struct GuardState: Sendable {
        var requested = false
        var process: GuardProcess?
        var heartbeat: Task<Void, Never>?
        var spawnCount = 0
    }

    let state = Mutex(State())
    let signalGate = Mutex(SignalGate())
    let cpuHistory = Mutex(CPUHistory())
    let guardState = Mutex(GuardState())

    /// Binding signature.
    /// - Parameters:
    ///   - signaller: dry-run-gated signaller (the coordinator passes `SideEffects.signaller`).
    ///   - guardExecutable: `Kakureneko.app/Contents/Helpers/kakureneko-guard`; nil (or dry-run) → no guard.
    ///   - ledger: records `pause.guard` when dry-run keeps the guard from being spawned. When nil, the ledger of a
    ///     gated `DryRunProcessSignaller` is used (the coordinator passes it explicitly).
    public convenience init(
        paths: Paths,
        signaller: any ProcessSignalling,
        processes: any ProcessLookup,
        dryRun: DryRunGate,
        guardExecutable: URL?,
        clock: any KakurenekoClock = SystemClock(),
        logger: KakurenekoLogger = KakurenekoLogger(.pause),
        ledger: DryRunLedger? = nil
    ) {
        self.init(paths: paths, signaller: signaller, processes: processes, dryRun: dryRun,
                  guardExecutable: guardExecutable, clock: clock, logger: logger,
                  probe: LiveSystemProbe(), candidates: WorkspaceCandidateProvider(),
                  groupingResolver: LiveGroupingResolver(), crashBuffer: ProcessCrashThawBuffer(), ledger: ledger)
    }

    /// Designated initializer with every collaborator injectable (tests use a synthetic world).
    init(
        paths: Paths,
        signaller: any ProcessSignalling,
        processes: any ProcessLookup,
        dryRun: DryRunGate,
        guardExecutable: URL?,
        clock: any KakurenekoClock,
        logger: KakurenekoLogger,
        probe: any SystemProbing,
        candidates: any CandidateProviding,
        groupingResolver: any GroupingResolving,
        crashBuffer: any CrashThawPublishing,
        selfPID: pid_t = getpid(),
        guardEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        guardExtraArguments: [String] = [],
        ledger: DryRunLedger? = nil
    ) {
        self.paths = paths
        self.signaller = signaller
        self.processes = processes
        self.dryRun = dryRun
        self.guardExecutable = guardExecutable
        self.clock = clock
        self.logger = logger
        self.probe = probe
        self.candidates = candidates
        self.groupingResolver = groupingResolver
        self.crashBuffer = crashBuffer
        self.selfPID = selfPID
        self.guardEnvironment = guardEnvironment
        self.guardExtraArguments = guardExtraArguments
        self.ledger = ledger ?? (signaller as? DryRunProcessSignaller)?.ledger
        self.journal = JournalStore(url: paths.pauseJournalFile)
        self.recovery = PauseRecovery(signaller: signaller, processes: processes, probe: probe)
    }

    deinit {
        // Without `stopGuard()` the guard sees EOF and recovers whatever is still journaled — the safe default.
        let (process, task) = guardState.withLock { ($0.process, $0.heartbeat) }
        task?.cancel()
        if let process { close(process.writeFD) }
    }

    // MARK: - Recovery and safety nets

    @concurrent
    public func recoverFromJournal() async -> Int {
        await operations.withLock { self.recoverLocked() }
    }

    func recoverLocked() -> Int {
        defer {
            state.withLock { s in
                s.metadata = [:]
                s.mains = [:]
                s.session = Session()
            }
            publishCrashBuffer()
        }
        guard let disk = journal.readDisk() else {
            if FileManager.default.fileExists(atPath: paths.pauseJournalFile.path(percentEncoded: false)) {
                logger.error("launch recovery: pause journal unreadable; removed (nothing verifiable to thaw)")
            }
            try? journal.replace(with: nil)
            return 0
        }
        var keep: [PauseJournalApp] = []
        var thawed = 0
        if dryRun.isOn {
            // Real records cannot be undone through the gated signaller: keep them (never silently simulated).
            for app in disk.apps where !app.simulated {
                var real = app
                real.members = app.members.filter { $0.action != .terminate }
                guard !real.members.isEmpty else { continue }
                logger.error("launch recovery in dry-run: \(app.name ?? "pid \(app.appPid)") is REALLY paused; kept in the journal for a non-dry-run launch or kakureneko-guard --recover")
                keep.append(real)
            }
        } else {
            let summary = recovery.thawAll(disk, keepUnsignalled: false) { [logger] in logger.info("launch recovery: \($0)") }
            thawed = summary.thawed
            keep = summary.remaining
        }
        var next = disk
        next.apps = keep
        do {
            try journal.replace(with: next)
        } catch {
            logger.error("launch recovery: could not rewrite the pause journal: \(error)")
        }
        logger.notice("launch recovery: thawed \(thawed) process(es), kept \(keep.reduce(0) { $0 + $1.members.count })")
        return thawed
    }

    public func installCrashHandlers() {
        let first = state.withLock { s -> Bool in
            defer { s.crashHandlersInstalled = true }
            return !s.crashHandlersInstalled
        }
        guard first else { return }
        crashBuffer.installHandlers()
        publishCrashBuffer()
        logger.info("crash handler installed for SEGV/BUS/ILL/ABRT/TRAP/FPE")
    }

    /// Mirrors the frozen pids into the crash-handler buffer (empty in dry-run). Runs under the state lock so
    /// concurrent publishers never interleave their writes.
    func publishCrashBuffer() {
        state.withLock { s in
            guard s.crashHandlersInstalled else { return }
            crashBuffer.publish(dryRun.isOn ? [] : CrashThawBuffer.pids(for: journal.current))
        }
    }

    public func thawAllSynchronously(reason: ThawReason) -> Int {
        signalGate.withLock { g in
            g.terminating = true
            g.generation &+= 1
        }
        let result = thawJournal(allowRelaunch: false)
        finishThaw(reason: reason)
        logger.notice("thawed \(result.thawed) process(es) synchronously (\(reason.rawValue))")
        return result.thawed
    }

    @concurrent
    @discardableResult
    public func thawAll(reason: ThawReason) async -> Int {
        signalGate.withLock { $0.generation &+= 1 }
        return await operations.withLock {
            let result = self.thawJournal(allowRelaunch: Self.relaunchReasons.contains(reason))
            await self.relaunch(result.relaunch)
            self.finishThaw(reason: reason)
            if result.thawed > 0 || !result.relaunch.isEmpty {
                self.logger.notice("thawed \(result.thawed) process(es), relaunching \(result.relaunch.count) app(s) (\(reason.rawValue))")
            }
            return result.thawed
        }
    }

    public func pausedApps() async -> [PausedApp] { currentPausedApps() }

    // MARK: - Grouping self-test and P-I history

    @concurrent
    public func selfTest() async -> GroupingSelfTest {
        let selection = groupingResolver.resolve(selfPID: selfPID)
        state.withLock { $0.selection = selection }
        logger.notice("grouping self-test: \(selection.selfTest.method.rawValue), freeze \(selection.selfTest.freezeAllowed ? "allowed" : "not allowed")")
        return selection.selfTest
    }

    func currentSelection() -> GroupingSelection {
        if let cached = state.withLock({ $0.selection }) { return cached }
        let selection = groupingResolver.resolve(selfPID: selfPID)
        state.withLock { $0.selection = selection }
        return selection
    }

    @concurrent
    public func observe(now: Date) async {
        probe.startMemoryPressureMonitoring()
        guard let grouping = currentSelection().grouping, let table = probe.processTable() else { return }
        let uid = probe.userID
        let mains = candidates.runningApplications()
            .filter { $0.isRegular && $0.pid != selfPID && table[$0.pid]?.isOwned(by: uid) == true }
            .map(\.pid)
        let groups = grouping.groups(for: mains, in: table, uid: uid)
        var samples: [ProcessIdentity: [ProcessIdentity: UInt64]] = [:]
        for main in mains {
            guard let entry = table[main] else { continue }
            var cpu: [ProcessIdentity: UInt64] = [:]
            for pid in groups[main] ?? [] {
                guard let member = table[pid], let nanoseconds = probe.cpuNanoseconds(of: pid) else { continue }
                cpu[member.identity] = nanoseconds
            }
            samples[entry.identity] = cpu
        }
        cpuHistory.withLock { $0.record(samples, at: now) }
    }

    // MARK: - Guard

    public func startGuard() throws {
        guardState.withLock { $0.requested = true }
        if dryRun.isOn, let guardExecutable {
            ledger?.record(.pause, action: "pause.guard",
                           detail: "would start \(guardExecutable.lastPathComponent) watching pid \(selfPID)")
        }
        try ensureGuardRunning()
    }

    /// Spawns the guard when it was requested, is not running, a helper exists and dry-run is off. Also called before
    /// every real pause (dry-run may have been switched off since `startGuard()`).
    func ensureGuardRunning() throws {
        guard !dryRun.isOn else {
            logger.debug("dry-run: kakureneko-guard not spawned")
            return
        }
        guard let executable = guardExecutable else { return }
        try guardState.withLock { g in
            guard g.requested, g.process == nil else { return }
            g.process = try spawnGuard(executable)
            g.spawnCount += 1
            if g.heartbeat == nil { g.heartbeat = makeHeartbeatTask() }
        }
    }

    private func spawnGuard(_ executable: URL) throws -> GuardProcess {
        let process = try GuardLauncher.spawn(
            executable: executable, watchPID: selfPID, journal: paths.pauseJournalFile, log: paths.guardLogFile,
            environment: guardEnvironment, extraArguments: guardExtraArguments)
        logger.notice("kakureneko-guard started (pid \(process.pid))")
        return process
    }

    private func makeHeartbeatTask() -> Task<Void, Never> {
        Task.detached(priority: .utility) { [weak self, clock] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: GuardLauncher.heartbeatInterval)
                } catch {
                    return
                }
                guard let self else { return }
                self.heartbeat()
            }
        }
    }

    /// One heartbeat: reap + respawn a guard that exited unexpectedly, else write `hb`.
    func heartbeat() {
        guardState.withLock { g in
            guard let process = g.process else { return }
            if GuardLauncher.hasExited(process.pid) {
                close(process.writeFD)
                g.process = nil
                logger.warning("kakureneko-guard (pid \(process.pid)) exited unexpectedly; respawning")
                guard !dryRun.isOn, let executable = guardExecutable else { return }
                do {
                    g.process = try spawnGuard(executable)
                    g.spawnCount += 1
                } catch {
                    logger.error("could not respawn kakureneko-guard: \(error)")
                }
                return
            }
            GuardLauncher.write(GuardLauncher.heartbeatLine, to: process.writeFD)
        }
    }

    public func stopGuard() {
        let (process, task) = guardState.withLock { g in
            defer {
                g.process = nil
                g.heartbeat = nil
                g.requested = false
            }
            return (g.process, g.heartbeat)
        }
        task?.cancel()
        guard let process else { return }
        GuardLauncher.write(GuardLauncher.byeLine, to: process.writeFD)
        close(process.writeFD)
        logger.notice("kakureneko-guard stopped (pid \(process.pid))")
        if !GuardLauncher.hasExited(process.pid) {
            // Reap off-thread; never block the caller. A guard that ignores `bye` is reaped by launchd later.
            Task.detached(priority: .utility) {
                for _ in 0..<100 {
                    if GuardLauncher.hasExited(process.pid) { return }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
        }
    }

    /// The running guard (tests/diagnostics).
    var guardProcess: GuardProcess? { guardState.withLock { $0.process } }
    var guardSpawnCount: Int { guardState.withLock { $0.spawnCount } }

    // MARK: - Thaw

    /// Relaunch is allowed only when the user is (likely) back — never before sleep, power-off or quit.
    static let relaunchReasons: Set<ThawReason> = [.lidOpened, .userRequest, .externalDisplay, .userInput]
    /// Thaws that do NOT end the pausing session (decisions such as session protections survive them).
    static let sessionKeepingReasons: Set<ThawReason> = [.hardCap, .watchdog, .protectionMatched]

    struct RelaunchItem: Sendable, Hashable {
        var appPid: Int32
        var bundleID: String?
        var record: PauseJournalRecord
        var simulated: Bool
    }

    struct ThawResult: Sendable {
        var thawed = 0
        var relaunch: [RelaunchItem] = []
    }

    /// Per-app undo plan: what was thawed, which records leave the journal, which apps to relaunch.
    struct AppThaw: Sendable {
        var thawed = 0
        var remove: [PauseJournalRecord] = []
        var relaunch: [RelaunchItem] = []
    }

    /// Undoes one journaled app, LIFO. Real records are verified first (`PauseRecovery`); simulated apps go through
    /// the (gated) signaller only while the gate is still on, so they only produce "would …" ledger lines; a real app
    /// while the gate is on is kept journaled (a mismatch is logged, never silently simulated).
    func thawApp(_ app: PauseJournalApp, dry: Bool, bootMatches: Bool, allowRelaunch: Bool) -> AppThaw {
        var result = AppThaw()
        let name = app.name ?? app.bundleID ?? "pid \(app.appPid)"
        if !app.simulated && dry {
            logger.error("dry-run is on while \(name) is REALLY paused: not undone through the dry-run signaller; kept journaled")
            return result
        }
        if app.simulated && !dry {
            logger.error("dry-run was turned off while \(name) was only simulated: dropped without signalling")
            result.remove = app.members
            return result
        }
        for record in app.members.reversed() {
            if record.action == .terminate {
                if allowRelaunch {
                    result.relaunch.append(RelaunchItem(appPid: app.appPid, bundleID: app.bundleID, record: record, simulated: app.simulated))
                }
                continue // kept until relaunched (never relaunched before sleep/power-off/quit)
            }
            if app.simulated {
                switch record.action {
                case .sigstop: try? signaller.send(.cont, to: record.identity)
                case .darwinBackground: try? signaller.setDarwinBackground(false, for: record.identity)
                case .terminate: break
                }
                result.thawed += 1
                result.remove.append(record)
                continue
            }
            switch recovery.thaw(record, bootMatches: bootMatches) {
            case .thawed:
                result.thawed += 1
                result.remove.append(record)
            case .dropped(let why):
                logger.info("dropped journal record pid \(record.pid): \(why)")
                result.remove.append(record)
            case .failed(let why):
                logger.error("could not thaw pid \(record.pid) (\(name)): \(why); kept journaled")
            case .skipped:
                break
            }
        }
        return result
    }

    /// Thaws every journaled app (apps in reverse order, members LIFO), synchronously. Records that were undone or
    /// can never be undone leave the journal; failed undos and not-yet-relaunched `.terminate` records stay.
    func thawJournal(allowRelaunch: Bool) -> ThawResult {
        journal.reconcileWithDisk()
        adoptInheritedThrottles() // children forked by throttled members inherited the throttle
        guard let snapshot = journal.current else {
            syncMetadataWithJournal()
            return ThawResult()
        }
        let dry = dryRun.isOn
        let currentBoot = probe.bootSessionUUID()
        let bootMatches = currentBoot != nil && currentBoot == snapshot.bootSessionUUID
        var result = ThawResult()
        var removals: [Int32: [PauseJournalRecord]] = [:]
        for app in snapshot.apps.reversed() {
            let thaw = thawApp(app, dry: dry, bootMatches: bootMatches, allowRelaunch: allowRelaunch)
            result.thawed += thaw.thawed
            result.relaunch.append(contentsOf: thaw.relaunch)
            removals[app.appPid, default: []].append(contentsOf: thaw.remove)
        }
        removeFromJournal(removals)
        return result
    }

    /// Relaunches apps closed by Quit mode (not activated). A record whose process is still alive never quit; one
    /// whose bundle already runs again was reopened by the user. Records leave the journal either way.
    func relaunch(_ items: [RelaunchItem]) async {
        guard !items.isEmpty else { return }
        let running = Set(candidates.runningApplications().compactMap(\.bundleID))
        for item in items {
            defer { removeFromJournal([item.appPid: [item.record]]) }
            if item.simulated && !dryRun.isOn { continue }
            if !item.simulated {
                if processes.isAlive(item.record.identity) { continue }
                if let bundleID = item.bundleID, running.contains(bundleID) { continue }
            }
            guard let path = item.record.path, path.hasSuffix(".app") else {
                logger.warning("cannot relaunch pid \(item.record.pid): no bundle path journaled")
                continue
            }
            do {
                try await signaller.relaunchApplication(at: URL(filePath: path, directoryHint: .isDirectory))
                logger.notice("relaunched \((path as NSString).lastPathComponent) (not activated)")
            } catch {
                logger.error("relaunch of \((path as NSString).lastPathComponent) failed: \(error)")
            }
        }
    }

    func removeFromJournal(_ removals: [Int32: [PauseJournalRecord]]) {
        let nonEmpty = removals.filter { !$0.value.isEmpty }
        if !nonEmpty.isEmpty {
            do {
                try journal.update(header: { PauseJournal(bootSessionUUID: "", kakurenekoPid: selfPID, startedAt: clock.now()) }) { j in
                    for index in j.apps.indices {
                        guard let gone = nonEmpty[j.apps[index].appPid] else { continue }
                        let set = Set(gone)
                        j.apps[index].members.removeAll { set.contains($0) }
                    }
                }
            } catch {
                logger.error("could not rewrite the pause journal after thawing: \(error)")
            }
        }
        syncMetadataWithJournal()
        publishCrashBuffer()
    }

    /// Ends or keeps the session depending on `reason`.
    func finishThaw(reason: ThawReason) {
        state.withLock { s in
            if Self.sessionKeepingReasons.contains(reason) {
                switch reason {
                case .hardCap: s.session.latch = "hard cap reached; pausing resumes after the lid opens"
                case .watchdog: s.session.latch = "watchdog thawed everything; pausing resumes after the lid opens"
                default: break
                }
            } else {
                s.session = Session()
            }
        }
        syncMetadataWithJournal()
    }

    func syncMetadataWithJournal() {
        let pausedPIDs = Set(journal.current?.apps.map(\.appPid) ?? [])
        state.withLock { s in
            s.metadata = s.metadata.filter { pausedPIDs.contains($0.key) }
            s.mains = s.mains.filter { pausedPIDs.contains($0.key) }
        }
    }

    func currentPausedApps() -> [PausedApp] {
        guard let snapshot = journal.current else { return [] }
        let metadata = state.withLock { $0.metadata }
        return snapshot.apps.map { app in
            var paused = metadata[app.appPid] ?? PausedApp(
                appPID: app.appPid, bundleID: app.bundleID, name: app.name ?? app.bundleID ?? "pid \(app.appPid)",
                mode: app.mode, memberCount: app.members.count, pausedAt: snapshot.startedAt)
            paused.mode = app.mode
            paused.memberCount = app.members.count
            return paused
        }
    }

    // MARK: - Signalling helpers

    enum SignalResult {
        case done
        case aborted
        case failed(any Error)
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        signalGate.withLock { !$0.terminating && $0.generation == generation }
    }

    /// Runs `body` (one signal or priority change) unless a thaw or termination started since `generation`.
    func perform(_ generation: UInt64, _ body: () throws -> Void) -> SignalResult {
        signalGate.withLock { g in
            guard !g.terminating, g.generation == generation else { return .aborted }
            do {
                try body()
                return .done
            } catch {
                return .failed(error)
            }
        }
    }
}
