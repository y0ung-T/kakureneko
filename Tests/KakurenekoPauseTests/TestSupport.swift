import Darwin
import KakurenekoKit
@testable import KakurenekoPause
import Foundation
import Synchronization
import Testing

// Test support for KakurenekoPauseTests.
//
// Two kinds of fixtures:
//   * a SYNTHETIC world (`FakeWorld` + `RecordingSignaller` + `FakeCandidates`) for PauseManager decision logic —
//     no real process is ever inspected or touched;
//   * SPAWNED children (`SpawnedChild`, e.g. `/bin/sleep 30` in its own session) — the ONLY real processes any test
//     signals, throttles or kills.

/// Built products next to the test bundle (`kakureneko-guard`).
enum Products {
    final class Marker {}
    static var directory: URL { Bundle(for: Marker.self).bundleURL.deletingLastPathComponent() }
    static func executable(_ name: String) -> URL { directory.appending(path: name, directoryHint: .notDirectory) }
    static var guardExecutable: URL { executable(KakurenekoID.guardExecutableName) }
}

/// A temp home that removes itself.
struct TempHome {
    let paths: Paths

    init() throws { paths = try Paths.temporary(prefix: "kakureneko-pause-test") }

    func remove() { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }

    var journalURL: URL { paths.pauseJournalFile }
    var journalPath: String { paths.pauseJournalFile.path(percentEncoded: false) }
    var logPath: String { paths.guardLogFile.path(percentEncoded: false) }
    var log: String { (try? String(contentsOf: paths.guardLogFile, encoding: .utf8)) ?? "" }
}

/// Polls `condition` every 10 ms until it holds or `timeout` (seconds) passes. Generous by default: it returns as
/// soon as the condition holds, and the whole suite shares a machine that may be busy with other work.
func eventually(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

// MARK: - Spawned children (the only real processes tests may signal)

/// A child process spawned by the test itself (own session: no controlling tty, no terminal signals).
///
/// Tracks whether it was reaped: once `waitpid` returned its pid, the pid may be reused by an unrelated process, so
/// every later signal is skipped (tests must never signal a process they did not spawn).
final class SpawnedChild: Sendable {
    let pid: pid_t
    private let reaped = Mutex(false)

    init(pid: pid_t) { self.pid = pid }

    /// `/bin/sleep <seconds>`.
    static func sleep(_ seconds: Int = 30) throws -> SpawnedChild {
        try spawn("/bin/sleep", [String(seconds)])
    }

    static func spawn(_ path: String, _ arguments: [String], environment: [String: String] = [:]) throws -> SpawnedChild {
        let pid = try GuardLauncher.spawnProcess(path: path, arguments: [path] + arguments, environment: environment)
        return SpawnedChild(pid: pid)
    }

    /// Kernel identity (pid + start time), un-enriched.
    var identity: ProcessIdentity {
        get throws { try #require(KernelProcessLookup().identity(of: pid)) }
    }

    /// Identity with `uniqueID` and `pidVersion`.
    var enriched: ProcessIdentity {
        get throws { try #require(Kernel.enrich(identity)) }
    }

    var isReaped: Bool { reaped.withLock { $0 } }
    var isStopped: Bool { !isReaped && Kernel.isStopped(pid) }
    var isAlive: Bool { !isReaped && (Kernel.entry(of: pid).map { !$0.isZombie } ?? false) }

    /// Raw signal to this child — allowed ONLY because the test spawned it; never after it was reaped.
    func signal(_ sig: Int32) {
        reaped.withLock { done in
            if !done { _ = Darwin.kill(pid, sig) }
        }
    }

    func stop() async {
        signal(SIGSTOP)
        _ = await eventually { isStopped }
    }

    /// SIGCONT + SIGKILL + reap (idempotent). Always call in `defer`.
    func terminate() {
        reaped.withLock { done in
            guard !done else { return }
            _ = Darwin.kill(pid, SIGCONT)
            _ = Darwin.kill(pid, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
            done = true
        }
    }

    /// One `waitpid(WNOHANG)`: the raw status when the child has exited (it is then reaped), nil while it runs.
    private func poll() -> Int32? {
        reaped.withLock { done -> Int32? in
            guard !done else { return nil }
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result == -1 && errno == ECHILD) {
                done = true
                return result == pid ? status : nil
            }
            return nil
        }
    }

    /// Waits (polling) for the child to exit; returns the raw wait status, nil on timeout.
    func waitForExit(timeout: TimeInterval = 10) async -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let status = poll() { return status }
            if isReaped { return nil }
            try? await Task.sleep(for: .milliseconds(10))
        } while Date() < deadline
        return nil
    }

    /// Still running (not exited).
    var hasNotExited: Bool { poll() == nil && !isReaped }
}

/// Writes `hb\n` to a heartbeat pipe from a dedicated OS thread. A task on the cooperative pool can be starved for
/// hundreds of milliseconds while the whole suite runs in parallel; a thread keeps a steady cadence.
final class HeartbeatWriter: Sendable {
    private let running = Atomic<Bool>(true)
    private let finished = Atomic<Bool>(false)

    init(fd: Int32, intervalMilliseconds: UInt32) {
        Thread.detachNewThread { [self] in
            while running.load(ordering: .acquiring) {
                GuardLauncher.write(GuardLauncher.heartbeatLine, to: fd)
                usleep(intervalMilliseconds * 1000)
            }
            finished.store(true, ordering: .releasing)
        }
    }

    /// Stops the thread and waits until it no longer touches `fd` (only then may the caller close it).
    func stop() async -> Bool {
        running.store(false, ordering: .releasing)
        return await eventually { finished.load(ordering: .acquiring) }
    }
}

/// Wait-status decoding (the C macros are not imported).
enum WaitStatus {
    static func signal(_ status: Int32) -> Int32? {
        let low = status & 0x7f
        return (low != 0 && low != 0x7f) ? low : nil
    }

    static func exitCode(_ status: Int32) -> Int32? {
        (status & 0x7f) == 0 ? (status >> 8) & 0xff : nil
    }
}

// MARK: - Synthetic world

/// A synthetic process table + every probe the pause engine reads. Never touches the real system.
final class FakeWorld: SystemProbing, ProcessLookup {
    struct Process: Sendable {
        var entry: ProcessEntry
        var uniqueID: UInt64
        var pidVersion: UInt32
        var path: String?
        var cpu: UInt64 = 0
        var darwinBackground = false
        var traced = false
        var downloading = false
        var audio = false
        var enrichable = true
    }

    private struct State {
        var processes: [pid_t: Process] = [:]
        var boot: String? = "BOOT-A"
        var pressure: MemoryPressure = .normal
        var dirty: [pid_t: UInt32] = [:]
        var monitoringStarts = 0
        var tableAvailable = true
        var nextUnique: UInt64 = 70_000
    }

    private let state = Mutex(State())
    let userID: uid_t = 501
    /// Default process start: one hour before `TestClock.defaultStart`.
    static let defaultStart = TestClock.defaultStart.addingTimeInterval(-3600)

    init() {}

    // MARK: Building

    @discardableResult
    func add(pid: pid_t, ppid: pid_t = 1, uid: uid_t? = nil, start: Date = FakeWorld.defaultStart, tty: Int32? = nil,
             path: String? = nil) -> ProcessIdentity {
        let sec = Int64(start.timeIntervalSince1970.rounded(.down))
        let usec = Int32(((start.timeIntervalSince1970 - Double(sec)) * 1_000_000).rounded())
        let entry = ProcessEntry(pid: pid, ppid: ppid, uid: uid ?? userID, startSec: sec, startUsec: usec, ttyDevice: tty)
        state.withLock { s in
            s.nextUnique += 1
            s.processes[pid] = Process(entry: entry, uniqueID: s.nextUnique, pidVersion: UInt32(pid) &* 7 &+ 3,
                                       path: path ?? "/Applications/App\(pid).app/Contents/MacOS/App")
        }
        return entry.identity
    }

    /// Adds a regular app (main + helpers with ppid = main) and returns its candidate.
    @discardableResult
    func addApp(pid: pid_t, helpers: [pid_t] = [], bundleID: String? = nil, name: String? = nil,
                start: Date = FakeWorld.defaultStart, regular: Bool = true, finished: Bool = true) -> AppCandidate {
        add(pid: pid, start: start)
        for helper in helpers { add(pid: helper, ppid: pid, start: start.addingTimeInterval(1)) }
        return AppCandidate(pid: pid, bundleID: bundleID ?? "test.app\(pid)", localizedName: name ?? "App\(pid)",
                            bundlePath: "/Applications/App\(pid).app", isRegular: regular, isFinishedLaunching: finished)
    }

    func update(_ pid: pid_t, _ body: (inout Process) -> Void) {
        state.withLock { s in
            if var p = s.processes[pid] {
                body(&p)
                s.processes[pid] = p
            }
        }
    }

    func remove(_ pid: pid_t) { state.withLock { _ = $0.processes.removeValue(forKey: pid) } }

    /// Replaces `pid` with a different process (pid reuse: new start time, uniqueID and pidversion).
    func reuse(_ pid: pid_t) {
        state.withLock { s in
            guard var p = s.processes[pid] else { return }
            p.entry.startSec += 77
            s.nextUnique += 1
            p.uniqueID = s.nextUnique
            p.pidVersion &+= 1
            p.entry.stat = 2
            p.darwinBackground = false
            s.processes[pid] = p
        }
    }

    func process(_ pid: pid_t) -> Process? { state.withLock { $0.processes[pid] } }
    func setBoot(_ uuid: String?) { state.withLock { $0.boot = uuid } }
    func setPressure(_ level: MemoryPressure) { state.withLock { $0.pressure = level } }
    func setDirty(_ pid: pid_t, _ flags: UInt32) { state.withLock { $0.dirty[pid] = flags } }
    func clearDirty(_ pid: pid_t) { state.withLock { _ = $0.dirty.removeValue(forKey: pid) } }
    func setTableAvailable(_ available: Bool) { state.withLock { $0.tableAvailable = available } }
    var monitoringStarts: Int { state.withLock { $0.monitoringStarts } }

    func setStopped(_ pid: pid_t, _ stopped: Bool) { update(pid) { $0.entry.stat = stopped ? Int8(SSTOP) : 2 } }
    func addCPU(_ pid: pid_t, nanoseconds: UInt64) { update(pid) { $0.cpu += nanoseconds } }

    /// Full identity (enriched) of a synthetic process.
    func enriched(_ pid: pid_t) -> ProcessIdentity? {
        process(pid).map {
            var identity = $0.entry.identity
            identity.uniqueID = $0.uniqueID
            identity.pidVersion = $0.pidVersion
            return identity
        }
    }

    // MARK: ProcessLookup

    func identity(of pid: Int32) -> ProcessIdentity? { process(pid)?.entry.identity }

    // MARK: SystemProbing

    func processTable() -> ProcessTable? {
        state.withLock { s in s.tableAvailable ? ProcessTable(s.processes.values.map(\.entry)) : nil }
    }

    func executablePath(of pid: pid_t) -> String? { process(pid)?.path }

    func enrich(_ identity: ProcessIdentity) -> ProcessIdentity? {
        guard let p = process(identity.pid), p.enrichable, p.entry.identity == identity else { return nil }
        if let known = identity.uniqueID, known != p.uniqueID { return nil }
        if let known = identity.pidVersion, known != p.pidVersion { return nil }
        var enriched = identity
        enriched.uniqueID = p.uniqueID
        enriched.pidVersion = p.pidVersion
        return enriched
    }

    func cpuNanoseconds(of pid: pid_t) -> UInt64? { process(pid)?.cpu }
    func hasDownloadInProgress(_ pid: pid_t) -> Bool { process(pid)?.downloading ?? false }
    func isTraced(_ pid: pid_t) -> Bool { process(pid)?.traced ?? false }

    func audioActivePIDs(among pids: Set<pid_t>) -> Set<pid_t> {
        state.withLock { s in Set(s.processes.values.filter { $0.audio }.map(\.entry.pid)).intersection(pids) }
    }

    func dirtyFlags(of pid: pid_t) -> UInt32? { state.withLock { $0.dirty[pid] } }
    func bootSessionUUID() -> String? { state.withLock { $0.boot } }
    func memoryPressure() -> MemoryPressure { state.withLock { $0.pressure } }
    func startMemoryPressureMonitoring() { state.withLock { $0.monitoringStarts += 1 } }
    func isStopped(_ pid: pid_t) -> Bool { process(pid)?.entry.isStopped ?? false }
}

/// `ProcessSignalling` over the synthetic world. Enforces the Kit contract (pausing calls refuse un-enriched
/// identities; every call re-verifies identity), records every successful call together with the journal file AS IT
/// WAS ON DISK at call time (proves "journal first"), and can be scripted to fail or to silently not take effect.
final class RecordingSignaller: ProcessSignalling {
    enum Call: Sendable, Hashable {
        case stop(pid_t)
        case cont(pid_t)
        case background(pid_t, Bool)
        case terminate(pid_t)
        case relaunch(String)
    }

    struct Record: Sendable {
        var call: Call
        var journal: PauseJournal?
    }

    private struct State {
        var records: [Record] = []
        var failures: [Call: SideEffectError] = [:]
        var ineffective: Set<Call> = []
        var afterStop: [pid_t: @Sendable () -> Void] = [:]
        var terminateRemovesProcess = true
    }

    private let state = Mutex(State())
    let world: FakeWorld
    let journalURL: URL

    init(world: FakeWorld, journalURL: URL) {
        self.world = world
        self.journalURL = journalURL
    }

    var records: [Record] { state.withLock { $0.records } }
    var calls: [Call] { records.map(\.call) }

    func fail(_ call: Call, with error: SideEffectError) { state.withLock { $0.failures[call] = error } }
    /// The call "succeeds" but has no effect (verification must catch it).
    func makeIneffective(_ call: Call) { state.withLock { _ = $0.ineffective.insert(call) } }
    func afterStopping(_ pid: pid_t, _ action: @escaping @Sendable () -> Void) { state.withLock { $0.afterStop[pid] = action } }
    func clear() { state.withLock { $0.records.removeAll() } }
    /// false: `terminateApplication` succeeds but the app keeps running (it refused to quit).
    func setTerminateRemovesProcess(_ removes: Bool) { state.withLock { $0.terminateRemovesProcess = removes } }

    private func verify(_ target: ProcessIdentity, pausing: Bool) throws {
        if pausing, target.pidVersion == nil || target.uniqueID == nil { throw SideEffectError.identityMismatch }
        guard let p = world.process(target.pid) else { throw SideEffectError.processGone }
        guard p.entry.identity == target else { throw SideEffectError.identityMismatch }
        if let v = target.pidVersion, v != p.pidVersion { throw SideEffectError.identityMismatch }
        if let u = target.uniqueID, u != p.uniqueID { throw SideEffectError.identityMismatch }
    }

    /// Records `call` (with the on-disk journal) unless it is scripted to fail; returns whether it takes effect.
    private func perform(_ call: Call) throws -> Bool {
        let journal = PauseJournal.read(from: journalURL)
        return try state.withLock { s in
            if let error = s.failures[call] { throw error }
            s.records.append(Record(call: call, journal: journal))
            return !s.ineffective.contains(call)
        }
    }

    func send(_ signal: ProcessSignalKind, to target: ProcessIdentity) throws {
        try verify(target, pausing: signal == .stop)
        let call: Call = signal == .stop ? .stop(target.pid) : .cont(target.pid)
        if try perform(call) { world.setStopped(target.pid, signal == .stop) }
        if signal == .stop, let hook = state.withLock({ $0.afterStop.removeValue(forKey: target.pid) }) { hook() }
    }

    func setDarwinBackground(_ enabled: Bool, for target: ProcessIdentity) throws {
        try verify(target, pausing: enabled)
        if try perform(.background(target.pid, enabled)) { world.update(target.pid) { $0.darwinBackground = enabled } }
    }

    func isDarwinBackground(_ target: ProcessIdentity) -> Bool? {
        guard let p = world.process(target.pid), p.entry.identity == target else { return nil }
        return p.darwinBackground
    }

    func terminateApplication(_ target: ProcessIdentity) async throws {
        try verify(target, pausing: true)
        if try perform(.terminate(target.pid)), state.withLock({ $0.terminateRemovesProcess }) { world.remove(target.pid) }
    }

    func relaunchApplication(at bundleURL: URL) async throws {
        var path = bundleURL.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() } // directory URLs carry a trailing slash
        _ = try perform(.relaunch(path))
    }
}

/// Scriptable list of running applications.
final class FakeCandidates: CandidateProviding {
    private let apps: Mutex<[AppCandidate]>
    private let browsers = Mutex<Set<String>>([])

    init(_ apps: [AppCandidate] = []) { self.apps = Mutex(apps) }

    func set(_ list: [AppCandidate]) { apps.withLock { $0 = list } }
    func append(_ app: AppCandidate) { apps.withLock { $0.append(app) } }
    func runningApplications() -> [AppCandidate] { apps.withLock { $0 } }
    /// Apps registered for `https` (the browser heuristic).
    func setBrowsers(_ bundleIDs: Set<String>) { browsers.withLock { $0 = bundleIDs } }
    func webBrowserBundleIdentifiers() -> Set<String> { browsers.withLock { $0 } }
}

/// A fixed grouping + self-test result.
struct FakeGroupingResolver: GroupingResolving {
    var grouping: (any ProcessGrouping)?
    var selfTest: GroupingSelfTest

    func resolve(selfPID: pid_t) -> GroupingSelection { GroupingSelection(grouping: grouping, selfTest: selfTest) }
}

/// Records crash-buffer bookkeeping instead of touching process-wide signal state.
final class RecordingCrashBuffer: CrashThawPublishing {
    private struct State {
        var installs = 0
        var published: [[pid_t]] = []
    }
    private let state = Mutex(State())

    init() {}

    var installs: Int { state.withLock { $0.installs } }
    var published: [[pid_t]] { state.withLock { $0.published } }
    var latest: [pid_t]? { published.last }

    func installHandlers() { state.withLock { $0.installs += 1 } }
    func publish(_ pids: [pid_t]) { state.withLock { $0.published.append(pids) } }
}

// MARK: - PauseManager harness

/// A PauseManager wired to the synthetic world.
struct PauseHarness {
    let home: TempHome
    let world: FakeWorld
    let recorder: RecordingSignaller
    let candidates: FakeCandidates
    let crash: RecordingCrashBuffer
    let gate: DryRunGate
    let ledger: DryRunLedger
    let clock: TestClock
    let manager: PauseManager
    let selfPID: pid_t

    static let now = TestClock.defaultStart
    static let freezeAllowed = GroupingSelfTest(method: .responsibility, freezeAllowed: true, detail: "fake")

    init(dryRun: Bool = false,
         selfTest: GroupingSelfTest = PauseHarness.freezeAllowed,
         grouping: (any ProcessGrouping)? = ParentTreeGrouping(),
         guardExecutable: URL? = nil,
         selfPID: pid_t = 4242,
         guardExtraArguments: [String] = []) throws {
        home = try TempHome()
        world = FakeWorld()
        recorder = RecordingSignaller(world: world, journalURL: home.journalURL)
        candidates = FakeCandidates()
        crash = RecordingCrashBuffer()
        gate = dryRun ? DryRunGate.alwaysOn() : DryRunGate.off()
        ledger = DryRunLedger()
        clock = TestClock()
        self.selfPID = selfPID
        let signaller: any ProcessSignalling = dryRun
            ? DryRunProcessSignaller(passthrough: recorder, gate: gate, ledger: ledger)
            : recorder
        manager = PauseManager(
            paths: home.paths, signaller: signaller, processes: world, dryRun: gate,
            guardExecutable: guardExecutable, clock: clock, logger: KakurenekoLogger(.pause),
            probe: world, candidates: candidates,
            groupingResolver: FakeGroupingResolver(grouping: grouping, selfTest: selfTest),
            crashBuffer: crash, selfPID: selfPID, guardEnvironment: home.paths.helperEnvironment,
            guardExtraArguments: guardExtraArguments, ledger: ledger)
    }

    func cleanup() {
        manager.stopGuard()
        home.remove()
    }

    var journal: PauseJournal? { PauseJournal.read(from: home.journalURL) }
    var journalExists: Bool { FileManager.default.fileExists(atPath: home.journalPath) }

    /// Adds a regular app to the world AND the candidate list.
    @discardableResult
    func addApp(pid: pid_t, helpers: [pid_t] = [], bundleID: String? = nil, name: String? = nil,
                start: Date = FakeWorld.defaultStart, regular: Bool = true, finished: Bool = true) -> AppCandidate {
        let app = world.addApp(pid: pid, helpers: helpers, bundleID: bundleID, name: name, start: start,
                               regular: regular, finished: finished)
        candidates.append(app)
        return app
    }

    /// Two observations 60 s apart with no CPU use: P-I history says "idle" (Freeze allowed).
    func observeIdle(at now: Date = PauseHarness.now) async {
        await manager.observe(now: now.addingTimeInterval(-60))
        await manager.observe(now: now)
    }

    func pause(_ settings: PauseSettings = PauseSettings(), topology: AgentTopology? = nil,
               at now: Date = PauseHarness.now) async -> PauseReport {
        await manager.pause(topology: topology ?? AgentTopology(builtAt: now), settings: settings, now: now)
    }

    func recheck(_ settings: PauseSettings = PauseSettings(), topology: AgentTopology? = nil,
                 at now: Date) async -> PauseReport {
        await manager.recheck(topology: topology ?? AgentTopology(builtAt: now), settings: settings, now: now)
    }
}

extension PauseSettings {
    static func with(_ body: (inout PauseSettings) -> Void) -> PauseSettings {
        var settings = PauseSettings()
        body(&settings)
        return settings
    }

    static var freeze: PauseSettings { .with { $0.mode = .freeze } }
}

extension PauseJournal {
    /// Every member of every app, flattened.
    var allMembers: [PauseJournalRecord] { apps.flatMap(\.members) }
    func app(_ pid: Int32) -> PauseJournalApp? { apps.first { $0.appPid == pid } }
}
