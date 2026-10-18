@testable import KakurenekoCoordinator
import KakurenekoKit
import Foundation
import Synchronization
import Testing

// Test support: a coordinator on `FakeServiceSet` + `TestClock`, with the main loop off (tests call `tick()`),
// a scripted "real world" power model that keeps the fake power controller consistent with the events the test
// emits, and bounded waits for stream consumers. No real side effects anywhere.

// MARK: - Fixtures

enum Fixture {
    static let project = "/Users/tester/code/api"

    static func identity(_ pid: Int32) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startSec: 1_791_000_000, startUsec: pid)
    }

    static func session(
        _ id: String,
        agent: AgentID = .claude,
        state: SessionState,
        cwd: String? = Fixture.project,
        agentPID: Int32? = nil,
        hostPID: Int32? = nil,
        turnStartedAt: Date? = nil,
        tiers: Set<Tier> = [.hook],
        metadata: [String: String] = [:]
    ) -> AgentSession {
        AgentSession(
            key: SessionKey(agent: agent, id: id),
            agentProcess: agentPID.map(identity),
            host: hostPID.map { HostApp(bundleID: "com.microsoft.VSCode", name: "VS Code", pid: $0) },
            cwd: cwd,
            state: state,
            turnStartedAt: turnStartedAt,
            tiers: tiers,
            metadata: metadata
        )
    }

    static func effect(_ kind: SessionEffect.Kind, _ session: AgentSession, at: Date, outcome: TurnOutcome? = nil) -> SessionEffect {
        SessionEffect(kind: kind, session: session, at: at, outcome: outcome,
                      needsInputKind: kind == .needsInput ? .permission : nil)
    }

    static func command(_ kind: RemoteCommandKind, sv: Int, at: Date) -> RemoteCommand {
        RemoteCommand(kind: kind, commandID: UUID().uuidString, stateVersion: sv, expiresAt: at.addingTimeInterval(1800),
                      receivedAt: at, source: .phone(name: "iPhone"))
    }

    static func agentEvent(_ id: String, session: String, at: Date) -> AgentEvent {
        AgentEvent(id: id, agent: .claude, event: .turnStarted, rawEventName: "UserPromptSubmit",
                   sessionKey: SessionKey(agent: .claude, id: session), occurredAt: at, receivedAt: at)
    }

    static func agentProcess(_ pid: Int32, cpuSeconds: Double?, at: Date) -> AgentProcess {
        AgentProcess(identity: identity(pid), agent: .claude, argv0: "claude",
                     evidence: EvidenceSample(sampledAt: at, treeCPUSeconds: cpuSeconds), firstSeen: at)
    }

    static func pausedApp(_ name: String, pid: Int32, mode: PauseMode = .throttle, at: Date) -> PausedApp {
        PausedApp(appPID: pid, bundleID: "com.example.\(name.lowercased())", name: name, mode: mode, memberCount: 3, pausedAt: at)
    }
}

/// The physical world the fake power controller and power monitor report.
struct PowerModel {
    var lid: LidState = .open
    var externalDisplay = false
    /// nil = never (idle forever).
    var lastInputAt: Date?
    var onAC = true
    var batteryPercent: Int? = 80
    var networkExpensive = false
    var lowPowerMode = false

    func snapshot(at now: Date) -> PowerSnapshot {
        PowerSnapshot(
            takenAt: now, lid: lid, batteryPercent: batteryPercent, onAC: onAC, lowPowerMode: lowPowerMode,
            networkExpensive: networkExpensive, externalDisplayConnected: externalDisplay,
            secondsSinceUserInput: lastInputAt.map { max(0, now.timeIntervalSince($0)) })
    }
}

// MARK: - Harness

/// One coordinator under test. Not Sendable: used from the test's own task only.
final class Harness {
    let paths: Paths
    let fakes: FakeServiceSet
    let services: KakurenekoServices
    let coordinator: KakurenekoCoordinator
    var power = PowerModel()

    init(
        settings: KakurenekoSettings = .default,
        dryRun: DryRunGate = .off(),
        privileged: PrivilegedStatus? = nil,
        paths: Paths? = nil,
        appRunning: @escaping @Sendable (String) -> Bool = { _ in false },
        bootTime: @escaping @Sendable () -> Date? = { nil },
        configure: (inout KakurenekoServices, FakeServiceSet) -> Void = { _, _ in }
    ) throws {
        let paths = try paths ?? Paths.temporary()
        self.paths = paths
        let fakes = FakeServiceSet(paths: paths, dryRun: dryRun)
        self.fakes = fakes
        if let privileged { fakes.privileged.setStatus(privileged) }
        var services = fakes.services
        configure(&services, fakes)
        self.services = services
        coordinator = KakurenekoCoordinator(
            services: services, settings: settings,
            options: CoordinatorOptions(runsMainLoop: false, isApplicationRunning: appRunning, bootTime: bootTime))
        scriptPower()
    }

    var clock: TestClock { fakes.clock }
    var now: Date { fakes.clock.now() }
    var log: FakeCallLog { fakes.log }
    var intents: [NotificationIntent] { fakes.notifications.submittedIntents }
    var intentKinds: [NotificationKind] { intents.map(\.kind) }

    func phase() async -> PowerPhase { await coordinator.machine.phase }
    func snapshot() async -> AppSnapshot { await coordinator.currentSnapshot() }
    func thawReasons() -> [ThawReason] {
        fakes.pausing.calls.compactMap { if case .thawAll(let r) = $0 { r } else { nil } }
    }
    func pauseCount() -> Int { fakes.pausing.calls.filter { $0 == .pause }.count }

    /// Keeps the fake controller's `snapshot()` / `kernelFlags()` lid in line with the modelled world.
    func scriptPower() {
        fakes.power.setLidClosed(power.lid == .closed)
        fakes.power.setSnapshot(power.snapshot(at: now))
    }

    // MARK: Driving

    func start() async {
        await coordinator.start()
    }

    func tick() async {
        scriptPower()
        await coordinator.tick()
    }

    func advance(_ seconds: TimeInterval) {
        clock.advance(by: .interval(seconds))
        scriptPower()
    }

    func advanceAndTick(_ seconds: TimeInterval) async {
        advance(seconds)
        await tick()
    }

    /// Emits through the fake power monitor's stream and waits until the coordinator handled it.
    func emitPower(_ event: PowerEvent) async {
        let before = await coordinator.handled.powerEvents
        fakes.powerEvents.emit(event)
        let done = await waitUntil { await self.coordinator.handled.powerEvents > before }
        #expect(done, "power event \(event) was not handled")
    }

    /// Emits a fresh `.snapshot` of the modelled world.
    func emitSnapshot() async {
        scriptPower()
        await emitPower(.snapshot(power.snapshot(at: now)))
    }

    func closeLid(lastInputAgo: TimeInterval? = 600, external: Bool = false) async {
        power.lid = .closed
        power.externalDisplay = external
        power.lastInputAt = lastInputAgo.map { now.addingTimeInterval(-$0) }
        await emitSnapshot()
        await emitPower(.lidChanged(.closed))
    }

    func openLid() async {
        power.lid = .open
        power.lastInputAt = now
        scriptPower()
        await emitPower(.lidChanged(.open))
        await emitSnapshot()
    }

    /// Closed-lid user input (Screen Sharing): the monitor's `.userActivity`, with the modelled world updated so
    /// later snapshots agree.
    func userActivity() async {
        power.lastInputAt = now
        scriptPower()
        await emitPower(.userActivity(secondsSinceInput: 0))
    }

    /// Advances in `step`-second ticks (process scans, session ticks, pausing all run as in production).
    func run(for seconds: TimeInterval, step: TimeInterval = 1) async {
        var elapsed: TimeInterval = 0
        while elapsed < seconds {
            let next = min(step, seconds - elapsed)
            await advanceAndTick(next)
            elapsed += next
        }
    }

    /// A working Claude session `s1` (agent pid 100, VS Code host pid 4242), armed via one tick.
    func startWorking(sv: Int = 7, hostPID: Int32? = 4242) async -> AgentSession {
        let session = Fixture.session("s1", state: .working(since: now), agentPID: 100, hostPID: hostPID, turnStartedAt: now)
        setSessions([session], sv: sv)
        await tick()
        return session
    }

    func command(_ kind: RemoteCommandKind, sv: Int) async {
        let before = await coordinator.handled.remoteCommands
        fakes.notifications.emitCommand(Fixture.command(kind, sv: sv, at: now))
        let done = await waitUntil { await self.coordinator.handled.remoteCommands > before }
        #expect(done, "remote command \(kind) was not handled")
    }

    func setSessions(_ sessions: [AgentSession], sv: Int = 7) {
        fakes.sessions.setSessions(sessions, stateVersion: sv)
    }

    /// Waits (≤ 10 s of wall time, returning as soon as it holds) until `count` tasks sleep on the TestClock.
    func waitForSleepers(_ count: Int = 1) async -> Bool {
        await waitUntil { self.clock.sleeperCount >= count }
    }

    /// Lets the running wind-down pass its 3 s thaw settle (it must be sleeping on the clock first).
    func passThawSettle() async {
        let sleeping = await waitForSleepers()
        #expect(sleeping, "the wind-down never reached its 3 s wait")
        advance(3)
    }

    /// Prepares for termination and removes the temp home.
    func finish() async {
        await coordinator.prepareForTermination()
        try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent())
    }
}

/// Runs `body` with a fresh harness and always cleans up.
func withHarness(
    settings: KakurenekoSettings = .default,
    dryRun: DryRunGate = .off(),
    privileged: PrivilegedStatus? = nil,
    appRunning: @escaping @Sendable (String) -> Bool = { _ in false },
    bootTime: @escaping @Sendable () -> Date? = { nil },
    configure: (inout KakurenekoServices, FakeServiceSet) -> Void = { _, _ in },
    _ body: (Harness) async throws -> Void
) async throws {
    let harness = try Harness(settings: settings, dryRun: dryRun, privileged: privileged, appRunning: appRunning,
                              bootTime: bootTime, configure: configure)
    do {
        try await body(harness)
    } catch {
        await harness.finish()
        throw error
    }
    await harness.finish()
}

/// Polls `condition` (yielding, 1 ms steps) for at most `timeout` of wall time. Only waits on stream consumers,
/// never on virtual time. Positive waits only: the generous default returns as soon as the condition holds.
@discardableResult
func waitUntil(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

/// Lets chained hand-off tasks (status reports) run before asserting that nothing more happened.
func settleTasks() async {
    for _ in 0..<50 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(30))
    for _ in 0..<50 { await Task.yield() }
}

/// Not operational: notifications-only mode.
let notInstalled = PrivilegedStatus(sudoRuleInstalled: false, failsafeLoaded: false, detail: "missing")

/// Hands a wrapper built inside `configure` to the test body.
final class Ref<Value: Sendable>: Sendable {
    private let storage = Mutex<Value?>(nil)
    init() {}
    var value: Value? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

/// Collects every snapshot a `snapshots()` subscription yields (cancelled by `stop()`).
final class SnapshotCollector: Sendable {
    private let received = Mutex<[AppSnapshot]>([])
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<AppSnapshot>) {
        let consumer = Task { [self] in
            for await snapshot in stream { self.received.withLock { $0.append(snapshot) } }
        }
        task.withLock { $0 = consumer }
    }

    var snapshots: [AppSnapshot] { received.withLock { $0 } }
    var count: Int { snapshots.count }

    func stop() { task.withLock { $0?.cancel() } }
}

/// A pauser whose `pause` suspends on the TestClock for `pauseDuration` (a slow `pause` racing a thaw trigger).
final class SlowPausing: AppPausing {
    let base: FakeAppPausing
    let clock: TestClock
    let pauseDuration: Duration

    init(base: FakeAppPausing, clock: TestClock, pauseDuration: Duration = .seconds(2)) {
        self.base = base
        self.clock = clock
        self.pauseDuration = pauseDuration
    }

    func recoverFromJournal() async -> Int { await base.recoverFromJournal() }
    func installCrashHandlers() { base.installCrashHandlers() }
    func thawAllSynchronously(reason: ThawReason) -> Int { base.thawAllSynchronously(reason: reason) }
    func startGuard() throws { try base.startGuard() }
    func stopGuard() { base.stopGuard() }
    func selfTest() async -> GroupingSelfTest { await base.selfTest() }
    func observe(now: Date) async { await base.observe(now: now) }
    func pause(topology: AgentTopology, settings: PauseSettings, now: Date) async -> PauseReport {
        try? await clock.sleep(for: pauseDuration)
        return await base.pause(topology: topology, settings: settings, now: now)
    }
    func recheck(topology: AgentTopology, settings: PauseSettings, now: Date) async -> PauseReport {
        await base.recheck(topology: topology, settings: settings, now: now)
    }
    func thawAll(reason: ThawReason) async -> Int { await base.thawAll(reason: reason) }
    func pausedApps() async -> [PausedApp] { await base.pausedApps() }
}

// MARK: - Recording wrappers (observe the dry-run gate at call time)

/// Forwards to a fake power controller and records the gate value whenever the flag is touched.
final class GateObservingPower: PowerControlling {
    let base: FakePowerController
    let gate: DryRunGate
    private let records = Mutex<[String]>([])

    init(base: FakePowerController, gate: DryRunGate) {
        self.base = base
        self.gate = gate
    }

    var observed: [String] { records.withLock { $0 } }
    private func note(_ name: String) { records.withLock { $0.append("\(name) gate=\(gate.isOn)") } }

    func start() async { await base.start() }
    func kernelFlags() -> KernelPowerFlags { base.kernelFlags() }
    func arm() async throws {
        note("arm")
        try await base.arm()
    }
    func disarm() async throws {
        note("disarm")
        try await base.disarm()
    }
    func disarmSynchronously(timeout: Duration) -> Bool { base.disarmSynchronously(timeout: timeout) }
    func touchHeartbeat() throws { try base.touchHeartbeat() }
    func sleepNow() async throws { try await base.sleepNow() }
    func requestShutdown() async throws { try await base.requestShutdown() }
    func scheduleDetachedSleep(after delay: Duration) throws { try base.scheduleDetachedSleep(after: delay) }
    func displaySleepNow() async throws { try await base.displaySleepNow() }
    func playLidCloseChime() { base.playLidCloseChime() }
    func snapshot() async -> PowerSnapshot { await base.snapshot() }
}

/// Forwards to a fake pauser and records the gate value at every `recoverFromJournal` and `thawAll`.
final class GateObservingPausing: AppPausing {
    let base: FakeAppPausing
    let gate: DryRunGate
    private let records = Mutex<[String]>([])

    init(base: FakeAppPausing, gate: DryRunGate) {
        self.base = base
        self.gate = gate
    }

    var observed: [String] { records.withLock { $0 } }

    func recoverFromJournal() async -> Int {
        records.withLock { $0.append("recoverFromJournal gate=\(gate.isOn)") }
        return await base.recoverFromJournal()
    }
    func installCrashHandlers() { base.installCrashHandlers() }
    func thawAllSynchronously(reason: ThawReason) -> Int { base.thawAllSynchronously(reason: reason) }
    func startGuard() throws { try base.startGuard() }
    func stopGuard() { base.stopGuard() }
    func selfTest() async -> GroupingSelfTest { await base.selfTest() }
    func observe(now: Date) async { await base.observe(now: now) }
    func pause(topology: AgentTopology, settings: PauseSettings, now: Date) async -> PauseReport {
        await base.pause(topology: topology, settings: settings, now: now)
    }
    func recheck(topology: AgentTopology, settings: PauseSettings, now: Date) async -> PauseReport {
        await base.recheck(topology: topology, settings: settings, now: now)
    }
    func thawAll(reason: ThawReason) async -> Int {
        records.withLock { $0.append("thawAll(\(reason.rawValue)) gate=\(gate.isOn)") }
        return await base.thawAll(reason: reason)
    }
    func pausedApps() async -> [PausedApp] { await base.pausedApps() }
}
