import Foundation
import Synchronization

// Scriptable fakes for every service protocol. Used by KakurenekoCoordinatorTests (which must not depend on
// other modules' real behaviour), by the app's previews and by any module that needs a collaborator.
// All are `final class … : Sendable` with Mutex-protected state; every call is recorded.
//
// Cross-service ORDER: every fake appends its mutating calls to a shared `FakeCallLog` (pass the same log to
// every fake — `FakeServiceSet` does), e.g. `["notify.drain", "pause.thawAll(beforePowerAction)", "power.disarm",
// "power.sleep"]`. Time-stamped values (`PowerSnapshot.takenAt`) come from the injected
// clock (the `TestClock` in `FakeServiceSet`).

/// Shared, ordered log of calls across fakes (assert cross-service ordering in coordinator tests).
public final class FakeCallLog: Sendable {
    private let state = Mutex<[String]>([])

    public init() {}

    public func append(_ entry: String) { state.withLock { $0.append(entry) } }
    /// Oldest first.
    public var entries: [String] { state.withLock { $0 } }
    /// Entries starting with `prefix` (e.g. `"power."`).
    public func entries(withPrefix prefix: String) -> [String] { entries.filter { $0.hasPrefix(prefix) } }
    /// Entries that are in `names` (keeps order), handy for `#expect(log.subsequence([...]) == [...])`.
    public func filtered(_ names: Set<String>) -> [String] { entries.filter { names.contains($0) } }
    public func removeAll() { state.withLock { $0.removeAll() } }
}

/// Fake `AgentEventSource`: `emit(_:)` pushes events to subscribers; `queueForDrain(_:)` stages events
/// yielded (and returned) by the next `drainNow()` — and by `start()`, like the real launch drain.
public final class FakeEventSource: AgentEventSource {
    private struct State {
        var started = 0
        var stopped = 0
        var pendingDrain: [AgentEvent] = []
        var lastSeen: [AgentID: Date] = [:]
    }
    private let state = Mutex(State())
    private let broadcaster = AsyncBroadcaster<AgentEvent>(bufferLimit: InboxFile.maxQueuedFiles)
    private let log: FakeCallLog

    public init(log: FakeCallLog = FakeCallLog()) { self.log = log }

    public var startCount: Int { state.withLock { $0.started } }
    public var stopCount: Int { state.withLock { $0.stopped } }

    /// Like the real inbox: the launch drain is yielded to the subscribers that exist NOW.
    public func start() async throws {
        state.withLock { $0.started += 1 }
        log.append("events.start")
        _ = takeAndYield()
    }

    public func stop() async {
        state.withLock { $0.stopped += 1 }
        log.append("events.stop")
    }

    public func events() -> AsyncStream<AgentEvent> { broadcaster.stream() }

    @discardableResult
    public func drainNow() async -> [AgentEvent] {
        log.append("events.drain")
        return takeAndYield()
    }

    private func takeAndYield() -> [AgentEvent] {
        let events = state.withLock { s -> [AgentEvent] in
            defer { s.pendingDrain.removeAll() }
            for e in s.pendingDrain { s.lastSeen[AgentID(label: e.argvAgentLabel)] = e.receivedAt }
            return s.pendingDrain
        }
        for e in events { broadcaster.yield(e) }
        return events
    }

    public func lastEventSeen() async -> [AgentID: Date] { state.withLock { $0.lastSeen } }

    /// Delivers an event to every subscriber and updates `lastEventSeen` (keyed by the delivering integration).
    public func emit(_ event: AgentEvent) {
        state.withLock { $0.lastSeen[AgentID(label: event.argvAgentLabel)] = event.receivedAt }
        broadcaster.yield(event)
    }

    public func queueForDrain(_ events: [AgentEvent]) { state.withLock { $0.pendingDrain.append(contentsOf: events) } }
    public var subscriberCount: Int { broadcaster.subscriberCount }
}

/// Fake `ProcessSampling` returning scripted snapshots/topologies.
public final class FakeProcessSampler: ProcessSampling {
    private struct State {
        var snapshot: ProcessSnapshot?
        var topology: AgentTopology?
        var sampleCount = 0
        var topologyCount = 0
        var hints: [SessionStoreHint] = []
        var started = 0
    }
    private let state = Mutex(State())
    private let log: FakeCallLog

    public init(log: FakeCallLog = FakeCallLog()) { self.log = log }

    public func setSnapshot(_ snapshot: ProcessSnapshot) { state.withLock { $0.snapshot = snapshot } }
    public func setTopology(_ topology: AgentTopology) { state.withLock { $0.topology = topology } }
    public var sampleCount: Int { state.withLock { $0.sampleCount } }
    public var topologyCount: Int { state.withLock { $0.topologyCount } }
    public var lastHints: [SessionStoreHint] { state.withLock { $0.hints } }

    public func start() async {
        state.withLock { $0.started += 1 }
        log.append("processes.start")
    }
    public func stop() async { log.append("processes.stop") }

    public func sample(now: Date) async -> ProcessSnapshot {
        state.withLock { s in
            s.sampleCount += 1
            var snap = s.snapshot ?? .empty(at: now)
            snap.takenAt = now
            return snap
        }
    }

    public func topology(for snapshot: ProcessSnapshot, now: Date) async -> AgentTopology {
        log.append("processes.topology")
        return state.withLock { s in
            s.topologyCount += 1
            return s.topology ?? .empty(at: now)
        }
    }

    public func updateSessionStoreHints(_ hints: [SessionStoreHint]) async { state.withLock { $0.hints = hints } }
}

/// Fake `ClaudeStateSource`: `emit(_:)` pushes snapshots.
public final class FakeClaudeStateSource: ClaudeStateSource {
    private struct State { var current: ClaudeStateSnapshot?; var cadence: SamplingCadence?; var started = 0 }
    private let state = Mutex(State())
    private let broadcaster = AsyncBroadcaster<ClaudeStateSnapshot>(replayLatest: true)
    private let log: FakeCallLog
    private let clock: any KakurenekoClock

    public init(log: FakeCallLog = FakeCallLog(), clock: any KakurenekoClock = SystemClock()) {
        self.log = log
        self.clock = clock
    }

    public var cadence: SamplingCadence? { state.withLock { $0.cadence } }
    public var startCount: Int { state.withLock { $0.started } }

    public func start() async {
        state.withLock { $0.started += 1 }
        log.append("claude.start")
    }
    public func stop() async { log.append("claude.stop") }
    public func snapshots() -> AsyncStream<ClaudeStateSnapshot> { broadcaster.stream() }
    public func current() async -> ClaudeStateSnapshot { state.withLock { $0.current } ?? .empty(at: clock.now()) }
    public func setCadence(_ cadence: SamplingCadence) async {
        state.withLock { $0.cadence = cadence }
        log.append("claude.cadence(\(cadence.rawValue))")
    }

    public func emit(_ snapshot: ClaudeStateSnapshot) {
        state.withLock { $0.current = snapshot }
        broadcaster.yield(snapshot)
    }
}

/// Fake `SessionTracking`: returns scripted sessions/aggregate; `queueEffects` are returned by the next
/// ingest/tick call. Records every input.
public final class FakeSessionTracker: SessionTracking {
    private struct State {
        var sessions: [AgentSession] = []
        var aggregate: SessionAggregate = .empty
        var queuedEffects: [SessionEffect] = []
        var events: [AgentEvent] = []
        var claudeStates: [ClaudeStateSnapshot] = []
        var processSnapshots: [ProcessSnapshot] = []
        var ticks: [Date] = []
        var timers: SessionTimers = SessionTimers()
        var dismissed: [SessionKey] = []
    }
    private let state = Mutex(State())
    private let log: FakeCallLog

    public init(log: FakeCallLog = FakeCallLog()) { self.log = log }

    /// Sets sessions and recomputes the aggregate (keeping `stateVersion` unless given).
    public func setSessions(_ sessions: [AgentSession], stateVersion: Int? = nil) {
        state.withLock { s in
            s.sessions = sessions
            s.aggregate = SessionAggregate.compute(from: sessions, stateVersion: stateVersion ?? s.aggregate.stateVersion,
                                                   lastFinishedAt: s.aggregate.lastFinishedAt)
        }
    }
    public func setAggregate(_ aggregate: SessionAggregate) { state.withLock { $0.aggregate = aggregate } }
    public func queueEffects(_ effects: [SessionEffect]) { state.withLock { $0.queuedEffects.append(contentsOf: effects) } }

    public var ingestedEvents: [AgentEvent] { state.withLock { $0.events } }
    public var ingestedClaudeStates: [ClaudeStateSnapshot] { state.withLock { $0.claudeStates } }
    public var ingestedProcessSnapshots: [ProcessSnapshot] { state.withLock { $0.processSnapshots } }
    public var ticks: [Date] { state.withLock { $0.ticks } }
    public var timers: SessionTimers { state.withLock { $0.timers } }
    public var dismissedKeys: [SessionKey] { state.withLock { $0.dismissed } }

    private func takeEffects(_ s: inout State) -> [SessionEffect] {
        defer { s.queuedEffects.removeAll() }
        return s.queuedEffects
    }

    public func ingest(_ event: AgentEvent, now: Date) -> [SessionEffect] {
        state.withLock { s in
            s.events.append(event)
            return takeEffects(&s)
        }
    }

    public func ingest(claudeState: ClaudeStateSnapshot, now: Date) -> [SessionEffect] {
        state.withLock { s in
            s.claudeStates.append(claudeState)
            return takeEffects(&s)
        }
    }

    public func ingest(processes: ProcessSnapshot, now: Date) -> [SessionEffect] {
        state.withLock { s in
            s.processSnapshots.append(processes)
            return takeEffects(&s)
        }
    }

    public func tick(now: Date) -> [SessionEffect] {
        state.withLock { s in
            s.ticks.append(now)
            return takeEffects(&s)
        }
    }

    public func updateTimers(_ timers: SessionTimers) { state.withLock { $0.timers = timers } }

    public func dismiss(_ key: SessionKey, now: Date) -> [SessionEffect] {
        log.append("sessions.dismiss(\(key))")
        return state.withLock { s in
            s.dismissed.append(key)
            s.sessions.removeAll { $0.key == key }
            return []
        }
    }

    public var sessions: [AgentSession] { state.withLock { $0.sessions } }
    public var aggregate: SessionAggregate { state.withLock { $0.aggregate } }
    public func session(for key: SessionKey) -> AgentSession? { state.withLock { $0.sessions.first { $0.key == key } } }
}

/// Fake `PowerControlling`: simulated kernel flag; counts every action; optional scripted errors.
/// `setKernelSleepDisabled` scripts the REAL kernel value independently (dry-run reconcile tests).
public final class FakePowerController: PowerControlling {
    public enum Call: String, Sendable, Hashable {
        case start, arm, disarm, disarmSync, heartbeat, sleep, shutdown, displaySleep, chime, scheduleSleep
    }
    private struct State {
        var flags = KernelPowerFlags(sleepDisabled: false, clamshellClosed: false)
        var calls: [Call] = []
        var armError: SideEffectError?
        var disarmError: SideEffectError?
        var sleepError: SideEffectError?
        var snapshot: PowerSnapshot?
        var scheduledSleepDelays: [Duration] = []
    }
    private let state = Mutex(State())
    private let log: FakeCallLog
    private let clock: any KakurenekoClock

    public init(log: FakeCallLog = FakeCallLog(), clock: any KakurenekoClock = SystemClock()) {
        self.log = log
        self.clock = clock
    }

    public var calls: [Call] { state.withLock { $0.calls } }
    public func count(_ call: Call) -> Int { calls.filter { $0 == call }.count }
    public func setLidClosed(_ closed: Bool?) { state.withLock { $0.flags.clamshellClosed = closed } }
    /// Sets the effective AND kernel flag (non-simulated).
    public func setSleepDisabled(_ on: Bool?) {
        state.withLock {
            $0.flags.sleepDisabled = on
            $0.flags.kernelSleepDisabled = on
            $0.flags.isSimulated = false
        }
    }
    /// Scripts dry-run: effective (simulated) flag `simulated`, real kernel flag `kernel`.
    public func setSimulatedFlags(simulated: Bool?, kernel: Bool?) {
        state.withLock {
            $0.flags.sleepDisabled = simulated
            $0.flags.kernelSleepDisabled = kernel
            $0.flags.isSimulated = true
        }
    }
    public func setArmError(_ error: SideEffectError?) { state.withLock { $0.armError = error } }
    public func setDisarmError(_ error: SideEffectError?) { state.withLock { $0.disarmError = error } }
    public func setSleepError(_ error: SideEffectError?) { state.withLock { $0.sleepError = error } }
    public func setSnapshot(_ snapshot: PowerSnapshot) { state.withLock { $0.snapshot = snapshot } }

    private func record(_ call: Call) {
        state.withLock { $0.calls.append(call) }
        log.append("power.\(call.rawValue)")
    }

    public func start() async { record(.start) }
    public func kernelFlags() -> KernelPowerFlags { state.withLock { $0.flags } }

    public func arm() async throws {
        record(.arm)
        let error = state.withLock { s -> SideEffectError? in
            if s.armError == nil {
                s.flags.sleepDisabled = true
                if !s.flags.isSimulated { s.flags.kernelSleepDisabled = true }
            }
            return s.armError
        }
        if let error { throw error }
    }

    public func disarm() async throws {
        record(.disarm)
        let error = state.withLock { s -> SideEffectError? in
            if s.disarmError == nil {
                s.flags.sleepDisabled = false
                if !s.flags.isSimulated { s.flags.kernelSleepDisabled = false }
            }
            return s.disarmError
        }
        if let error { throw error }
    }

    public func disarmSynchronously(timeout: Duration) -> Bool {
        record(.disarmSync)
        return state.withLock { s in
            guard s.disarmError == nil else { return false }
            s.flags.sleepDisabled = false
            if !s.flags.isSimulated { s.flags.kernelSleepDisabled = false }
            return true
        }
    }

    public func touchHeartbeat() throws { record(.heartbeat) }

    public func sleepNow() async throws {
        record(.sleep)
        if let error = state.withLock({ $0.sleepError }) { throw error }
    }

    public func requestShutdown() async throws { record(.shutdown) }
    public func scheduleDetachedSleep(after delay: Duration) throws {
        state.withLock { $0.scheduledSleepDelays.append(delay) }
        record(.scheduleSleep)
    }
    /// Delays passed to `scheduleDetachedSleep`, in call order.
    public var scheduledSleepDelays: [Duration] { state.withLock { $0.scheduledSleepDelays } }
    public func displaySleepNow() async throws { record(.displaySleep) }
    public func playLidCloseChime() { record(.chime) }

    public func snapshot() async -> PowerSnapshot {
        let now = clock.now()
        return state.withLock { s in
            var snap = s.snapshot ?? PowerSnapshot(takenAt: now)
            snap.takenAt = now
            snap.lid = s.flags.lid
            snap.sleepDisabled = s.flags.sleepDisabled
            snap.kernelSleepDisabled = s.flags.kernelSleepDisabled
            return snap
        }
    }
}

/// Fake `PowerEventSource`: `emit(_:)` pushes events (only `.snapshot` is replayed to late subscribers).
public final class FakePowerEventSource: PowerEventSource {
    private let broadcaster = AsyncBroadcaster<PowerEvent>(replayLatest: true, replayFilter: { $0.isSnapshot })
    private let started = Mutex(0)
    private let log: FakeCallLog

    public init(log: FakeCallLog = FakeCallLog()) { self.log = log }

    public var startCount: Int { started.withLock { $0 } }
    public func start() async {
        started.withLock { $0 += 1 }
        log.append("powerEvents.start")
    }
    public func stop() async { log.append("powerEvents.stop") }
    public func events() -> AsyncStream<PowerEvent> { broadcaster.stream() }
    public func emit(_ event: PowerEvent) { broadcaster.yield(event) }
    public var subscriberCount: Int { broadcaster.subscriberCount }
}

/// Fake `SafetyEvaluating`: `evaluate` returns the scripted trip, `armingBlocker` the scripted blocker
/// (both sticky until changed).
public final class FakeSafetyEvaluator: SafetyEvaluating {
    private struct State { var trip: SafetyTrip?; var blocker: SafetyTrip?; var evaluations = 0; var blockerChecks = 0; var resets = 0 }
    private let state = Mutex(State())

    public init() {}

    public func setTrip(_ trip: SafetyTrip?) { state.withLock { $0.trip = trip } }
    public func setArmingBlocker(_ blocker: SafetyTrip?) { state.withLock { $0.blocker = blocker } }
    public var evaluationCount: Int { state.withLock { $0.evaluations } }
    public var armingBlockerCheckCount: Int { state.withLock { $0.blockerChecks } }
    public var resetCount: Int { state.withLock { $0.resets } }

    public func evaluate(_ snapshot: PowerSnapshot, closedSince: Date, settings: SafetySettings, now: Date) -> SafetyTrip? {
        state.withLock { s in
            s.evaluations += 1
            return s.trip
        }
    }

    public func armingBlocker(_ snapshot: PowerSnapshot, settings: SafetySettings) -> SafetyTrip? {
        state.withLock { s in
            s.blockerChecks += 1
            return s.blocker
        }
    }

    public func reset() { state.withLock { $0.resets += 1 } }
}

/// Fake `PrivilegedInstalling`.
public final class FakePrivilegedInstaller: PrivilegedInstalling {
    private struct State { var status: PrivilegedStatus; var installs = 0; var uninstalls = 0; var installError: SideEffectError? }
    private let state: Mutex<State>
    private let log: FakeCallLog

    public init(status: PrivilegedStatus = PrivilegedStatus(sudoRuleInstalled: true, failsafeLoaded: true, checkedAt: nil, detail: "fake"),
                log: FakeCallLog = FakeCallLog()) {
        state = Mutex(State(status: status))
        self.log = log
    }

    public func setStatus(_ status: PrivilegedStatus) { state.withLock { $0.status = status } }
    public func setInstallError(_ error: SideEffectError?) { state.withLock { $0.installError = error } }
    public var installCount: Int { state.withLock { $0.installs } }
    public var uninstallCount: Int { state.withLock { $0.uninstalls } }

    public func healthCheck() async -> PrivilegedStatus { state.withLock { $0.status } }

    public func install() async throws {
        log.append("privileged.install")
        let error = state.withLock { s -> SideEffectError? in
            s.installs += 1
            if s.installError == nil { s.status = PrivilegedStatus(sudoRuleInstalled: true, failsafeLoaded: true, checkedAt: nil, detail: "fake") }
            return s.installError
        }
        if let error { throw error }
    }

    public func uninstall() async throws {
        log.append("privileged.uninstall")
        state.withLock { s in
            s.uninstalls += 1
            s.status = PrivilegedStatus(sudoRuleInstalled: false, failsafeLoaded: false, checkedAt: nil, detail: "fake")
        }
    }

    public func scripts() -> PrivilegedScripts {
        PrivilegedScripts(installScript: "#!/bin/bash\nexit 0\n", failsafeScriptTemplate: "#!/bin/bash\nexit 0\n",
                          launchDaemonPlist: "<plist/>", uninstallScript: "#!/bin/bash\nexit 0\n",
                          sudoersLine: "tester ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0")
    }
}

/// Fake `AppPausing`: records calls; `pause` returns `nextReport` (default: nothing paused).
public final class FakeAppPausing: AppPausing {
    public enum Call: Sendable, Hashable {
        case recover, installCrashHandlers, startGuard, stopGuard, selfTest, observe, pause, recheck
        case thawAll(ThawReason)
        case thawAllSynchronously(ThawReason)
    }
    private struct State {
        var calls: [Call] = []
        var paused: [PausedApp] = []
        var nextReport: PauseReport?
        var selfTest = GroupingSelfTest(method: .responsibility, freezeAllowed: true, detail: "fake")
        var recoverCount = 0
        var topologies: [AgentTopology] = []
    }
    private let state = Mutex(State())
    private let log: FakeCallLog

    public init(log: FakeCallLog = FakeCallLog()) { self.log = log }

    public var calls: [Call] { state.withLock { $0.calls } }
    /// Topologies passed to `pause`/`recheck` (assert `sessionHostPIDs` etc.).
    public var receivedTopologies: [AgentTopology] { state.withLock { $0.topologies } }
    public func setNextReport(_ report: PauseReport) { state.withLock { $0.nextReport = report } }
    public func setPaused(_ apps: [PausedApp]) { state.withLock { $0.paused = apps } }
    public func setRecoverCount(_ n: Int) { state.withLock { $0.recoverCount = n } }
    public func setSelfTest(_ result: GroupingSelfTest) { state.withLock { $0.selfTest = result } }

    private func record(_ call: Call, _ name: String) {
        state.withLock { $0.calls.append(call) }
        log.append("pause.\(name)")
    }

    public func recoverFromJournal() async -> Int {
        record(.recover, "recover")
        return state.withLock { $0.recoverCount }
    }
    public func installCrashHandlers() { record(.installCrashHandlers, "installCrashHandlers") }
    public func startGuard() throws { record(.startGuard, "startGuard") }
    public func stopGuard() { record(.stopGuard, "stopGuard") }
    public func selfTest() async -> GroupingSelfTest {
        record(.selfTest, "selfTest")
        return state.withLock { $0.selfTest }
    }
    public func observe(now: Date) async { state.withLock { $0.calls.append(.observe) } }

    public func pause(topology: AgentTopology, settings: PauseSettings, now: Date) async -> PauseReport {
        record(.pause, "pause")
        return state.withLock { s in
            s.topologies.append(topology)
            let report = s.nextReport ?? PauseReport(at: now, paused: s.paused)
            s.paused = report.paused
            return report
        }
    }

    public func recheck(topology: AgentTopology, settings: PauseSettings, now: Date) async -> PauseReport {
        record(.recheck, "recheck")
        return state.withLock { s in
            s.topologies.append(topology)
            return PauseReport(at: now, paused: s.paused)
        }
    }

    public func thawAll(reason: ThawReason) async -> Int {
        record(.thawAll(reason), "thawAll(\(reason.rawValue))")
        return state.withLock { s in
            defer { s.paused.removeAll() }
            return s.paused.reduce(0) { $0 + $1.memberCount }
        }
    }

    public func thawAllSynchronously(reason: ThawReason) -> Int {
        record(.thawAllSynchronously(reason), "thawAllSynchronously(\(reason.rawValue))")
        return state.withLock { s in
            defer { s.paused.removeAll() }
            return s.paused.reduce(0) { $0 + $1.memberCount }
        }
    }

    public func pausedApps() async -> [PausedApp] { state.withLock { $0.paused } }
}

/// Fake `NotificationDispatching`: records intents/enqueues/drains/status reports; `emitCommand(_:)` pushes
/// remote commands.
public final class FakeNotificationDispatcher: NotificationDispatching {
    private struct State {
        var submitted: [(NotificationIntent, NotificationContext)] = []
        var enqueued: [OutgoingNotification] = []
        var drains: [Date] = []
        var settings: NotificationSettings?
        var status = NotificationStatus()
        var disposition: NotificationDisposition = .queued(UUID())
        var tests = 0
        var testError: (any Error & Sendable)?
        var started = 0
        var reports: [MacStatusReport] = []
        var authorizationRequests = 0
        var authorizationResult: MacAlertAuthorization = .authorized
        var cloudPushes = 0
    }
    private let state = Mutex(State())
    private let commands = AsyncBroadcaster<RemoteCommand>()
    private let log: FakeCallLog
    private let clock: any KakurenekoClock

    public init(log: FakeCallLog = FakeCallLog(), clock: any KakurenekoClock = SystemClock()) {
        self.log = log
        self.clock = clock
    }

    public var submittedIntents: [NotificationIntent] { state.withLock { $0.submitted.map(\.0) } }
    public var submittedContexts: [NotificationContext] { state.withLock { $0.submitted.map(\.1) } }
    public var enqueued: [OutgoingNotification] { state.withLock { $0.enqueued } }
    public var drainDeadlines: [Date] { state.withLock { $0.drains } }
    public var appliedSettings: NotificationSettings? { state.withLock { $0.settings } }
    public var testCount: Int { state.withLock { $0.tests } }
    /// Every `updateMacStatus` report, oldest first.
    public var statusReports: [MacStatusReport] { state.withLock { $0.reports } }
    public var authorizationRequestCount: Int { state.withLock { $0.authorizationRequests } }
    public var cloudPushCount: Int { state.withLock { $0.cloudPushes } }
    public func setDisposition(_ d: NotificationDisposition) { state.withLock { $0.disposition = d } }
    public func setStatus(_ s: NotificationStatus) { state.withLock { $0.status = s } }
    public func setTestError(_ error: (any Error & Sendable)?) { state.withLock { $0.testError = error } }
    public func setAuthorizationResult(_ value: MacAlertAuthorization) { state.withLock { $0.authorizationResult = value } }
    public func emitCommand(_ command: RemoteCommand) { commands.yield(command) }

    public func start() async {
        state.withLock { $0.started += 1 }
        log.append("notify.start")
    }
    public func stop() async { log.append("notify.stop") }
    public func applySettings(_ settings: NotificationSettings) async { state.withLock { $0.settings = settings } }

    public func submit(_ intent: NotificationIntent, context: NotificationContext) async -> NotificationDisposition {
        log.append("notify.submit(\(intent.kind.rawValue))")
        return state.withLock { s in
            s.submitted.append((intent, context))
            return s.disposition
        }
    }

    public func enqueue(_ notification: OutgoingNotification) async {
        log.append("notify.enqueue(\(notification.kind.rawValue))")
        state.withLock { $0.enqueued.append(notification) }
    }

    public func drain(deadline: Date) async -> DrainResult {
        log.append("notify.drain")
        return state.withLock { s in
            s.drains.append(deadline)
            return DrainResult(delivered: 0, remaining: 0)
        }
    }

    public func remoteCommands() -> AsyncStream<RemoteCommand> { commands.stream() }
    public func status() async -> NotificationStatus { state.withLock { $0.status } }

    public func updateMacStatus(_ report: MacStatusReport) async { state.withLock { $0.reports.append(report) } }

    public func requestMacAuthorization() async -> MacAlertAuthorization {
        log.append("notify.requestMacAuthorization")
        return state.withLock { s in
            s.authorizationRequests += 1
            s.status.macAuthorization = s.authorizationResult
            return s.authorizationResult
        }
    }

    public func forgetPhone(deviceID: String) async {
        log.append("notify.forgetPhone")
    }

    public func lookForPhones() async {
        log.append("notify.lookForPhones")
    }

    public func sendTest() async throws {
        log.append("notify.sendTest")
        let error = state.withLock { s -> (any Error & Sendable)? in
            s.tests += 1
            return s.testError
        }
        if let error { throw error }
    }

    public func cloudDidNotify() async {
        log.append("notify.cloudDidNotify")
        state.withLock { $0.cloudPushes += 1 }
    }
}

/// Fake `AgentIntegrating`.
public final class FakeIntegrations: AgentIntegrating {
    public enum Call: Sendable, Hashable {
        case statuses
        case preview(AgentID, InstallPlan.Operation)
        case install(AgentID), uninstall(AgentID), repair(AgentID), deploy
    }
    private struct State {
        var statuses: [IntegrationStatus] = []
        var calls: [Call] = []
    }
    private let state = Mutex(State())
    private let log: FakeCallLog

    public init(statuses: [IntegrationStatus] = [], log: FakeCallLog = FakeCallLog()) {
        self.log = log
        state.withLock { $0.statuses = statuses }
    }

    public var calls: [Call] { state.withLock { $0.calls } }
    public func setStatuses(_ statuses: [IntegrationStatus]) { state.withLock { $0.statuses = statuses } }

    public func statuses() async -> [IntegrationStatus] {
        state.withLock { s in
            s.calls.append(.statuses)
            return s.statuses
        }
    }

    private func status(_ agent: AgentID, _ s: State) -> IntegrationStatus {
        s.statuses.first { $0.agent == agent } ?? IntegrationStatus(agent: agent, supported: true, configDirExists: true)
    }

    public func preview(_ agent: AgentID, operation: InstallPlan.Operation) async throws -> InstallPlan {
        state.withLock { s in
            s.calls.append(.preview(agent, operation))
            return InstallPlan(agent: agent, operation: operation)
        }
    }

    public func install(_ agent: AgentID) async throws -> InstallResult {
        log.append("install.install(\(agent.rawValue))")
        return state.withLock { s in
            s.calls.append(.install(agent))
            var st = status(agent, s)
            st.installed = true
            return InstallResult(plan: InstallPlan(agent: agent, operation: .install), status: st)
        }
    }

    public func uninstall(_ agent: AgentID) async throws -> InstallResult {
        log.append("install.uninstall(\(agent.rawValue))")
        return state.withLock { s in
            s.calls.append(.uninstall(agent))
            var st = status(agent, s)
            st.installed = false
            return InstallResult(plan: InstallPlan(agent: agent, operation: .uninstall), status: st)
        }
    }

    public func repair(_ agent: AgentID) async throws -> InstallResult {
        log.append("install.repair(\(agent.rawValue))")
        return state.withLock { s in
            s.calls.append(.repair(agent))
            var st = status(agent, s)
            st.needsRepair = false
            return InstallResult(plan: InstallPlan(agent: agent, operation: .repair), status: st)
        }
    }

    public func deployHelper(from bundledHelper: URL) async throws -> HelperDeployment {
        log.append("install.deployHelper")
        state.withLock { $0.calls.append(.deploy) }
        return HelperDeployment(path: bundledHelper.path(percentEncoded: false), sha256: String(repeating: "0", count: 64), copied: false)
    }
}

/// Every fake, plus a `KakurenekoServices` composed from them. All fakes share `log` (cross-service order) and
/// `clock` (deterministic timestamps).
public struct FakeServiceSet: Sendable {
    public let log: FakeCallLog
    public let events: FakeEventSource
    public let processes: FakeProcessSampler
    public let processLookup = StaticProcessLookup()
    public let claudeState: FakeClaudeStateSource
    public let sessions: FakeSessionTracker
    public let power: FakePowerController
    public let powerEvents: FakePowerEventSource
    public let safety = FakeSafetyEvaluator()
    public let privileged: FakePrivilegedInstaller
    public let pausing: FakeAppPausing
    public let notifications: FakeNotificationDispatcher
    public let integrations: FakeIntegrations
    public let subprocess = FakeSubprocessRunner()
    public let ledger: DryRunLedger
    public let clock: TestClock
    public let paths: Paths
    public let dryRun: DryRunGate
    public let services: KakurenekoServices

    /// - Parameters:
    ///   - paths: a temp home (`try Paths.temporary()`).
    ///   - clock: virtual time.
    ///   - log: shared call log.
    ///   - dryRun: the gate the composed services report (default off; the fakes never touch the system anyway).
    public init(paths: Paths, clock: TestClock = TestClock(), log: FakeCallLog = FakeCallLog(), dryRun: DryRunGate = .off()) {
        self.paths = paths
        self.clock = clock
        self.log = log
        self.dryRun = dryRun
        events = FakeEventSource(log: log)
        processes = FakeProcessSampler(log: log)
        claudeState = FakeClaudeStateSource(log: log, clock: clock)
        sessions = FakeSessionTracker(log: log)
        power = FakePowerController(log: log, clock: clock)
        powerEvents = FakePowerEventSource(log: log)
        privileged = FakePrivilegedInstaller(log: log)
        pausing = FakeAppPausing(log: log)
        notifications = FakeNotificationDispatcher(log: log, clock: clock)
        integrations = FakeIntegrations(log: log)
        let ledger = DryRunLedger(clock: clock)
        self.ledger = ledger
        let sideEffects = SideEffects.inert(ledger: ledger, subprocess: subprocess)
        services = KakurenekoServices(
            paths: paths,
            clock: clock,
            dryRun: dryRun,
            ledger: ledger,
            events: events,
            processes: processes,
            processLookup: processLookup,
            claudeState: claudeState,
            sessions: sessions,
            power: power,
            powerEvents: powerEvents,
            safety: safety,
            privileged: privileged,
            pausing: pausing,
            notifications: notifications,
            integrations: integrations,
            sideEffects: sideEffects
        )
    }
}
