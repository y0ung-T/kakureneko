// Test doubles for KakurenekoPower's internal seams. Nothing here touches the system: no sudo, no pmset, no IOKit
// mutation, no assertion, no admin prompt, no sound.

@testable import KakurenekoPower
import KakurenekoKit
import Foundation
import IOKit.pwr_mgt
import Synchronization
import Testing

// MARK: - Kernel (IOPMrootDomain) fake

/// Scriptable IOPMrootDomain: `SleepDisabled` / `AppleClamshellState`, with an optional pending change that becomes
/// visible after N more reads (powerd applies `pmset` asynchronously).
final class FakeRootDomain: RootDomainReading {
    private struct State {
        var sleepDisabled: Bool?
        var clamshellClosed: Bool?
        var pending: (value: Bool, readsLeft: Int)?
        var sleepDisabledReads = 0
    }
    private let state: Mutex<State>

    init(sleepDisabled: Bool? = false, clamshellClosed: Bool? = false) {
        state = Mutex(State(sleepDisabled: sleepDisabled, clamshellClosed: clamshellClosed))
    }

    func sleepDisabled() -> Bool? {
        state.withLock { s in
            s.sleepDisabledReads += 1
            if let pending = s.pending {
                if pending.readsLeft <= 0 {
                    s.sleepDisabled = pending.value
                    s.pending = nil
                } else {
                    s.pending = (pending.value, pending.readsLeft - 1)
                }
            }
            return s.sleepDisabled
        }
    }

    func clamshellClosed() -> Bool? { state.withLock { $0.clamshellClosed } }

    /// The kernel reports `value` after `reads` more reads that still return the old value.
    func apply(_ value: Bool, afterReads reads: Int) {
        state.withLock { $0.pending = (value, reads) }
    }

    func set(sleepDisabled: Bool?) { state.withLock { $0.sleepDisabled = sleepDisabled; $0.pending = nil } }
    func set(clamshellClosed: Bool?) { state.withLock { $0.clamshellClosed = clamshellClosed } }
    var reads: Int { state.withLock { $0.sleepDisabledReads } }
    /// The value without counting a read.
    var current: Bool? { state.withLock { $0.sleepDisabled } }
}

/// Records every privileged command (argv byte-exact through `PrivilegedCommand.argv`); answers with `result`; when
/// `kernel` is set and the command succeeded, the fake kernel applies the new flag after `lag` reads (unless
/// `kernelFollows == false`, which models a flag that never reads back).
final class ScriptedPrivilegedRunner: PrivilegedCommandRunning {
    typealias Responder = @Sendable (PrivilegedCommand) throws -> SubprocessResult
    private struct State {
        var commands: [PrivilegedCommand] = []
        var responder: Responder
        var kernelFollows: Bool
        var lag: Int
    }
    private let state: Mutex<State>
    private let kernel: FakeRootDomain?

    init(kernel: FakeRootDomain? = nil, lag: Int = 0, kernelFollows: Bool = true, responder: Responder? = nil) {
        self.kernel = kernel
        state = Mutex(State(responder: responder ?? { _ in SubprocessResult(exitCode: 0) }, kernelFollows: kernelFollows, lag: lag))
    }

    var commands: [PrivilegedCommand] { state.withLock { $0.commands } }
    var argvs: [[String]] { commands.map(\.argv) }
    func setKernelFollows(_ follows: Bool) { state.withLock { $0.kernelFollows = follows } }
    func setResponder(_ responder: @escaping Responder) { state.withLock { $0.responder = responder } }

    func run(_ command: PrivilegedCommand) async throws -> SubprocessResult {
        let (responder, follows, lag) = state.withLock { s in
            s.commands.append(command)
            return (s.responder, s.kernelFollows, s.lag)
        }
        let result = try responder(command)
        if result.succeeded, follows, case .setSleepDisabled(let on) = command {
            kernel?.apply(on, afterReads: lag)
        }
        return result
    }
}

/// Arms instantly (the fake kernel follows) and hangs on `disablesleep 0` until `release()` (a hung `sudo`).
final class HangOnDisarmRunner: PrivilegedCommandRunning {
    private let hold = TestClock()
    private let calls = Locked(0)
    private let kernel: FakeRootDomain

    init(kernel: FakeRootDomain) { self.kernel = kernel }

    var disarmCalls: Int { calls.value }

    func run(_ command: PrivilegedCommand) async throws -> SubprocessResult {
        if command == .setSleepDisabled(true) {
            kernel.apply(true, afterReads: 0)
            return SubprocessResult(exitCode: 0)
        }
        calls.update { $0 += 1 }
        try await hold.sleep(for: .seconds(3600))
        return SubprocessResult(exitCode: 0)
    }

    func release() { hold.advance(by: .seconds(3601)) }
}

// MARK: - Assertion / activity / chime / snapshot fakes

final class RecordingAssertionMaker: PowerAssertionMaking {
    private struct State {
        var nextID: IOPMAssertionID = 100
        var created: [(IOPMAssertionID, String)] = []
        var released: [IOPMAssertionID] = []
        var activities: [String] = []
        var endedActivities = 0
    }
    private let state = Mutex(State())

    func createAssertion(reason: String) -> IOPMAssertionID? {
        state.withLock { s in
            s.nextID += 1
            s.created.append((s.nextID, reason))
            return s.nextID
        }
    }

    func releaseAssertion(_ id: IOPMAssertionID) { state.withLock { $0.released.append(id) } }

    func beginActivity(reason: String) -> ActivityToken {
        state.withLock { $0.activities.append(reason) }
        return ActivityToken(NSObject())
    }

    func endActivity(_ token: ActivityToken) { state.withLock { $0.endedActivities += 1 } }

    var createdReasons: [String] { state.withLock { $0.created.map(\.1) } }
    var createdIDs: [IOPMAssertionID] { state.withLock { $0.created.map(\.0) } }
    var releasedIDs: [IOPMAssertionID] { state.withLock { $0.released } }
    var activityReasons: [String] { state.withLock { $0.activities } }
    var endedActivities: Int { state.withLock { $0.endedActivities } }
    /// Assertions created and not released.
    var held: Int { state.withLock { s in s.created.count - s.released.count } }
}

final class RecordingChime: ChimePlaying {
    private let names = Mutex<[String]>([])
    func play(soundNamed name: String) { names.withLock { $0.append(name) } }
    var played: [String] { names.withLock { $0 } }
}

/// Returns `base` (with `takenAt = now`); counts starts.
final class StaticSnapshotReader: PowerSnapshotReading {
    private let state: Mutex<(base: PowerSnapshot, starts: Int)>
    init(_ base: PowerSnapshot = PowerSnapshot(takenAt: .distantPast, batteryPercent: 80, onAC: false)) {
        state = Mutex((base, 0))
    }
    func start() { state.withLock { $0.starts += 1 } }
    func read(at now: Date) -> PowerSnapshot {
        var snapshot = state.withLock { $0.base }
        snapshot.takenAt = now
        return snapshot
    }
    var starts: Int { state.withLock { $0.starts } }
}

// MARK: - Side-effect recorders (never the real ones)

final class RecordingSleeper: SystemSleeping {
    private let count = Mutex(0)
    private let scheduled = Mutex<[Duration]>([])
    func sleepNow() async throws { count.withLock { $0 += 1 } }
    func scheduleDetachedSleep(after delay: Duration) throws { scheduled.withLock { $0.append(delay) } }
    var calls: Int { count.withLock { $0 } }
    var scheduledDelays: [Duration] { scheduled.withLock { $0 } }
}

final class RecordingShutdown: ShutdownRequesting {
    private let count = Mutex(0)
    func requestShutdown() async throws { count.withLock { $0 += 1 } }
    var calls: Int { count.withLock { $0 } }
}

final class RecordingDisplaySleeper: DisplaySleeping {
    private let count = Mutex(0)
    func displaySleepNow() async throws { count.withLock { $0 += 1 } }
    var calls: Int { count.withLock { $0 } }
}

final class RecordingAdministrator: AdministratorScriptRunning {
    struct Call: Sendable, Hashable { var script: String; var name: String; var arguments: [String] }
    private let calls = Mutex<[Call]>([])
    func runAsAdministrator(script: String, name: String, arguments: [String]) async throws -> String {
        calls.withLock { $0.append(Call(script: script, name: name, arguments: arguments)) }
        return "kakureneko privileged install OK\n"
    }
    var recorded: [Call] { calls.withLock { $0 } }
}

// MARK: - Monitor fakes

/// A `PowerObserving` the test drives by hand (`deliver`).
final class ManualObserver: PowerObserving {
    let name: String
    private struct State { var sink: PowerObservationSink?; var starts = 0; var stops = 0 }
    private let state = Mutex(State())
    private let accepts: Bool

    init(name: String = "manual", accepts: Bool = true) {
        self.name = name
        self.accepts = accepts
    }

    func start(_ sink: PowerObservationSink) -> Bool {
        state.withLock { s in
            s.starts += 1
            if accepts { s.sink = sink }
        }
        return accepts
    }

    func stop() {
        state.withLock { s in
            s.stops += 1
            s.sink = nil
        }
    }

    /// Delivers like a system callback would (no-op when not started).
    func deliver(_ observation: PowerObservation) {
        state.withLock { $0.sink }?.deliver(observation)
    }

    var starts: Int { state.withLock { $0.starts } }
    var stops: Int { state.withLock { $0.stops } }
    var isRegistered: Bool { state.withLock { $0.sink != nil } }
}

final class FakeDisplays: ExternalDisplayReading {
    private let value: Mutex<Bool>
    init(_ connected: Bool = false) { value = Mutex(connected) }
    func externalDisplayConnected() -> Bool { value.withLock { $0 } }
    func set(_ connected: Bool) { value.withLock { $0 = connected } }
}

final class FakeInput: UserInputIdleReading {
    private let value: Mutex<TimeInterval?>
    init(_ seconds: TimeInterval? = 600) { value = Mutex(seconds) }
    func secondsSinceUserInput() -> TimeInterval? { value.withLock { $0 } }
    func set(_ seconds: TimeInterval?) { value.withLock { $0 = seconds } }
}

/// A `Mutex` in a class, so escaping `@Sendable` closures can share it (`Mutex` itself is non-copyable).
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    var value: Value { mutex.withLock { $0 } }
    func set(_ value: Value) { mutex.withLock { $0 = value } }
    func update(_ body: (inout Value) -> Void) { mutex.withLock { body(&$0) } }
}

/// Collects a `PowerEvent` stream in the background.
final class EventRecorder: Sendable {
    private let events = Locked<[PowerEvent]>([])
    private let finished = Locked(false)
    private let task = Locked<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<PowerEvent>) {
        let events = self.events
        let finished = self.finished
        let consumer = Task.detached {
            for await event in stream { events.update { $0.append(event) } }
            finished.set(true)
        }
        task.set(consumer)
    }

    var all: [PowerEvent] { events.value }
    var isFinished: Bool { finished.value }
    var snapshots: [PowerSnapshot] {
        all.compactMap { if case .snapshot(let s) = $0 { s } else { nil } }
    }
    var lidEdges: [LidState] {
        all.compactMap { if case .lidChanged(let l) = $0 { l } else { nil } }
    }
    var displayEdges: [Bool] {
        all.compactMap { if case .externalDisplayChanged(let c) = $0 { c } else { nil } }
    }
    var userActivities: [TimeInterval] {
        all.compactMap { if case .userActivity(let s) = $0 { s } else { nil } }
    }
    var acknowledgers: [PowerChangeAcknowledger] {
        all.compactMap { if case .willSleep(let a) = $0 { a } else { nil } }
    }
    /// Events other than `.snapshot`.
    var edges: [PowerEvent] { all.filter { !$0.isSnapshot } }

    /// Waits (real time, short polls) until `predicate` holds; false on timeout.
    @discardableResult
    func wait(timeout: Duration = .seconds(10), _ predicate: @Sendable (EventRecorder) -> Bool) async -> Bool {
        await waitUntil(timeout: timeout) { predicate(self) }
    }

    func cancel() { task.value?.cancel() }
}

// MARK: - Helpers

/// Polls `condition` every millisecond (real time) until it holds or `timeout` passes (positive waits only: the
/// generous default returns as soon as the condition holds).
@discardableResult
func waitUntil(timeout: Duration = .seconds(10), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

/// Runs `operation` while advancing `clock` by `step` whenever something sleeps on it (the kernel read-back poll).
/// Returns the result and how many steps were needed.
///
/// Keeps driving until the operation FINISHES: stopping earlier (e.g. at a short wall-clock deadline on a busy
/// machine) would leave it parked on the TestClock forever and `task.value` would hang the whole run. A generous
/// wall-clock cap (60 s) cancels the operation and records an issue instead.
func driving<T: Sendable>(
    _ clock: TestClock,
    step: Duration = .milliseconds(100),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> (value: T, steps: Int) {
    let done = Locked(false)
    let task = Task {
        defer { done.set(true) }
        return try await operation()
    }
    var steps = 0
    let deadline = ContinuousClock.now.advanced(by: .seconds(60))
    while !done.value {
        if ContinuousClock.now >= deadline {
            Issue.record("the driven operation did not finish within 60 s of real time", sourceLocation: sourceLocation)
            task.cancel()
            break
        }
        if clock.sleeperCount > 0 {
            clock.advance(by: step)
            steps += 1
        } else {
            try? await Task.sleep(for: .microseconds(200))
        }
    }
    return (try await task.value, steps)
}

/// A fresh temp home, removed by the caller with `cleanup(paths)`.
func temporaryPaths() throws -> Paths { try Paths.temporary(prefix: "kakureneko-power-test") }

func cleanup(_ paths: Paths) {
    try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent())
}

/// `stat` of a path: (mode bits, mtime as Date). nil when missing.
func fileStatus(_ url: URL) -> (mode: mode_t, modified: Date)? {
    var st = stat()
    guard lstat(url.path(percentEncoded: false), &st) == 0 else { return nil }
    let seconds = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
    return (st.st_mode & 0o7777, Date(timeIntervalSince1970: seconds))
}

/// Runs a read-only validation tool (`bash -n`, `plutil -lint`, `visudo -cf`, `bash -c <snippet>`) with a 10 s bound.
func runTool(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) async throws -> SubprocessResult {
    try await FoundationSubprocessRunner().run(SubprocessRequest(
        executable: executable,
        arguments: arguments,
        environment: environment ?? ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
        timeout: .seconds(10),
        effect: .readOnly
    ))
}

/// Writes `text` to a new temp file (inside `directory`) and returns its path.
func writeTemp(_ text: String, named name: String, in directory: URL) throws -> String {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: name, directoryHint: .notDirectory)
    try Data(text.utf8).write(to: url)
    return url.path(percentEncoded: false)
}
