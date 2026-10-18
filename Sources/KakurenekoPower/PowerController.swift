// KakurenekoPower — PowerController: arm/disarm the kernel `SleepDisabled` flag, heartbeat, sleep/shutdown/display,
// chime, snapshots.
// OWNER: agent "power". Spec card: docs/ARCHITECTURE.md §9.4. Brief §7.2–7.3; R01 §2, §5.5, §9.1, §10; ARCHITECTURE §6.
//
// Every mutation goes through an injected side effect: `privileged` (sudo -n pmset, byte-exact argv), `systemSleep`,
// `shutdown`, `displaySleep`. The kernel flag is only ever READ here (IORegistry). In dry-run the controller keeps a
// SIMULATED flag (`kernelFlags().sleepDisabled`), never polls the kernel, never creates the assertion and never
// touches the heartbeat file — while `kernelFlags().kernelSleepDisabled` always reports the real kernel value.

import KakurenekoKit
import Darwin
import Foundation
import IOKit.pwr_mgt
import Synchronization

/// Power mechanisms (arm/disarm/heartbeat/sleep/shutdown/display/chime/snapshot).
public final class PowerController: PowerControlling {
    /// Mutable state. `armGate` remembers the dry-run gate value of the last successful `arm()` (nil = not armed by
    /// this process): `false` = really armed (`armedForReal`), `true` = simulated.
    private struct State {
        var armGate: Bool?
        /// A REAL arm's `disablesleep 1` went out and the arm has not finished (read-back poll, assertion, heartbeat):
        /// the flag may already be set by THIS process. The termination path treats it like `armGate == false`.
        var armInFlight = false
        /// `disarmSynchronously` ran (termination): every later `arm()` is refused.
        var terminating = false
        var simulatedSleepDisabled = false
        var assertionID: IOPMAssertionID?
        var activity: ActivityToken?
        var started = false
    }

    private let paths: Paths
    private let privileged: any PrivilegedCommandRunning
    private let systemSleep: any SystemSleeping
    private let shutdown: any ShutdownRequesting
    private let displaySleep: any DisplaySleeping
    private let dryRun: DryRunGate
    private let clock: any KakurenekoClock
    private let logger: KakurenekoLogger
    private let ledger: DryRunLedger?
    private let rootDomain: any RootDomainReading
    private let assertions: any PowerAssertionMaking
    private let snapshotReader: any PowerSnapshotReading
    private let chime: any ChimePlaying
    private let pollInterval: Duration
    private let pollAttempts: Int
    private let state = Mutex(State())
    /// Serializes `arm()` / `disarm()` (the coordinator actor is reentrant: a disarm must never interleave with an arm's
    /// command and read-back poll). `disarmSynchronously` does not take it (termination path).
    private let transitions = AsyncSerialLock()

    /// The message thrown when the dry-run gate differs from the one used at arm time (ARCHITECTURE §6).
    static let gateToggledMessage = "dry-run toggled while really armed"
    /// The message thrown by `arm()` once the termination path ran.
    static let terminatingMessage = "terminating"

    /// Binding signature. All side-effect parameters are already dry-run gated by the coordinator; `dryRun`
    /// tells the controller to simulate the kernel flag instead of polling IOPMrootDomain after arm/disarm.
    /// - Parameter ledger: where dry-run-only decisions (`power.heartbeat`, `power.simulatedFlag`) are recorded. When
    ///   nil, the ledger of the gated `privileged` runner (`DryRunPrivilegedCommandRunner`) is used.
    /// - Parameter lidSimulation: developer tool, dry-run only (`LidSimulation.fromEnvironment`): the lid and snapshot
    ///   readings follow its control file.
    public convenience init(
        paths: Paths,
        privileged: any PrivilegedCommandRunning,
        systemSleep: any SystemSleeping,
        shutdown: any ShutdownRequesting,
        displaySleep: any DisplaySleeping,
        dryRun: DryRunGate,
        clock: any KakurenekoClock = SystemClock(),
        logger: KakurenekoLogger = KakurenekoLogger(.power),
        ledger: DryRunLedger? = nil,
        lidSimulation: LidSimulation? = nil
    ) {
        let rootDomain: any RootDomainReading = lidSimulation.map { SimulatedRootDomain(base: LiveRootDomain(), simulation: $0) }
            ?? LiveRootDomain()
        let snapshotReader = lidSimulation.map {
            LivePowerSnapshotReader(displays: SimulatedDisplayReader(base: LiveDisplayReader(), simulation: $0),
                                    input: SimulatedInputReader(base: LiveUserInputIdleReader(), simulation: $0))
        } ?? LivePowerSnapshotReader()
        self.init(
            paths: paths, privileged: privileged, systemSleep: systemSleep, shutdown: shutdown,
            displaySleep: displaySleep, dryRun: dryRun, clock: clock, logger: logger, ledger: ledger,
            rootDomain: rootDomain, assertions: LivePowerAssertionMaker(),
            snapshotReader: snapshotReader, chime: SystemChimePlayer()
        )
    }

    /// Designated (internal) initializer: also takes the IORegistry reader, the assertion maker, the snapshot reader
    /// and the chime player so tests never create a real assertion or poll the real kernel.
    init(
        paths: Paths,
        privileged: any PrivilegedCommandRunning,
        systemSleep: any SystemSleeping,
        shutdown: any ShutdownRequesting,
        displaySleep: any DisplaySleeping,
        dryRun: DryRunGate,
        clock: any KakurenekoClock,
        logger: KakurenekoLogger,
        ledger: DryRunLedger?,
        rootDomain: any RootDomainReading,
        assertions: any PowerAssertionMaking,
        snapshotReader: any PowerSnapshotReading,
        chime: any ChimePlaying,
        pollInterval: Duration = .milliseconds(100),
        pollAttempts: Int = 50
    ) {
        self.paths = paths
        self.privileged = privileged
        self.systemSleep = systemSleep
        self.shutdown = shutdown
        self.displaySleep = displaySleep
        self.dryRun = dryRun
        self.clock = clock
        self.logger = logger
        self.ledger = ledger ?? (privileged as? DryRunPrivilegedCommandRunner)?.ledger
        self.rootDomain = rootDomain
        self.assertions = assertions
        self.snapshotReader = snapshotReader
        self.chime = chime
        self.pollInterval = pollInterval
        self.pollAttempts = max(1, pollAttempts)
    }

    deinit {
        // Never leave an assertion/activity behind if the owner drops the controller (the kernel flag is NOT touched:
        // a deinit cannot run the privileged command; the fail-safe covers a really-armed flag).
        let (assertion, activity) = state.withLock { s in (s.assertionID, s.activity) }
        if let assertion { assertions.releaseAssertion(assertion) }
        if let activity { assertions.endActivity(activity) }
    }

    // MARK: - Introspection (tests, diagnostics)

    /// True when this process armed the REAL flag (gate off at arm time) and has not disarmed since.
    var isArmedForReal: Bool { state.withLock { $0.armGate == false } }
    /// True while the dry-run simulation holds the flag.
    var isSimulatedArmed: Bool { state.withLock { $0.simulatedSleepDisabled } }
    /// True while the visibility assertion is held.
    var holdsAssertion: Bool { state.withLock { $0.assertionID != nil } }

    // MARK: - PowerControlling

    /// Reconciles internal state at launch: starts the long-lived snapshot observers and logs the kernel truth. Makes
    /// no system change (the coordinator decides whether to disarm a stale flag).
    public func start() async {
        let first = state.withLock { s -> Bool in
            defer { s.started = true }
            return !s.started
        }
        guard first else { return }
        snapshotReader.start()
        let flags = kernelFlags()
        let kernel = flags.kernelSleepDisabled.map { $0 ? "set" : "clear" } ?? "unreadable"
        logger.notice("power controller started: kernel SleepDisabled \(kernel), lid \(flags.lid.rawValue), dry-run \(dryRun.isOn)")
    }

    public func kernelFlags() -> KernelPowerFlags {
        let kernel = rootDomain.sleepDisabled()
        let closed = rootDomain.clamshellClosed()
        if dryRun.isOn {
            let simulated = state.withLock { $0.simulatedSleepDisabled }
            return KernelPowerFlags(sleepDisabled: simulated, clamshellClosed: closed, kernelSleepDisabled: kernel, isSimulated: true)
        }
        return KernelPowerFlags(sleepDisabled: kernel, clamshellClosed: closed, kernelSleepDisabled: kernel, isSimulated: false)
    }

    /// Arm: `sudo -n /usr/bin/pmset -a disablesleep 1` (through the injected runner), read the kernel flag back every
    /// 100 ms for ≤ 5 s, create the `PreventUserIdleSystemSleep` assertion, begin the activity, touch the heartbeat.
    /// Dry-run: the (gated) runner logs `power.arm`; the flag is simulated; no polling, assertion or heartbeat.
    @concurrent
    public func arm() async throws {
        try await transitions.run { try await self.armSerialized() }
    }

    private func armSerialized() async throws {
        let gateOn = dryRun.isOn
        if state.withLock({ $0.terminating }) {
            logger.notice("arm refused: terminating")
            throw SideEffectError.failed(Self.terminatingMessage)
        }
        let previous = state.withLock { $0.armGate }
        if previous == false && gateOn {
            logger.error("arm refused: really armed, but dry-run is now on (\(Self.gateToggledMessage))")
            throw SideEffectError.failed(Self.gateToggledMessage)
        }
        if previous == true && !gateOn {
            logger.warning("arm: discarding a stale dry-run simulation, arming for real")
            clearSimulation(recordLedger: false)
        }

        if gateOn {
            let result = try await runPrivileged(.setSleepDisabled(true), gateOn: gateOn)
            guard result.succeeded else { throw Self.commandError(result) }
        } else {
            // From here until `armGate = false` the flag may be ours although the arm has not completed: the
            // termination path must clear it too (it would otherwise see "not armed" and leave it to the fail-safe).
            let kernelBefore = rootDomain.sleepDisabled()
            state.withLock { $0.armInFlight = true }
            let result: SubprocessResult
            do {
                result = try await runPrivileged(.setSleepDisabled(true), gateOn: gateOn)
            } catch {
                // e.g. the 15 s sudo timeout: pmset may have applied the flag anyway.
                logger.error("arm: \(error); reverting")
                if kernelBefore != true { await revertBestEffort() }
                state.withLock { $0.armInFlight = false }
                throw error
            }
            guard result.succeeded else {
                if kernelBefore != true, rootDomain.sleepDisabled() == true { await revertBestEffort() }
                state.withLock { $0.armInFlight = false }
                throw Self.commandError(result)
            }
        }

        if gateOn {
            state.withLock { s in
                s.simulatedSleepDisabled = true
                s.armGate = true
            }
            ledger?.record(.power, action: "power.simulatedFlag", detail: "simulated SleepDisabled = 1 (kernel untouched)")
            logger.notice("armed (dry-run simulation)")
            return
        }

        do {
            try await waitForKernelFlag(true)
        } catch {
            logger.error("arm: kernel SleepDisabled never read back true (\(error)); reverting")
            await revertBestEffort()
            state.withLock { $0.armInFlight = false }
            throw error
        }
        // Terminating meanwhile: the handler cleared (or is clearing) the flag; never leave it set behind it.
        let terminating = state.withLock { s -> Bool in
            s.armInFlight = false
            if !s.terminating { s.armGate = false }
            return s.terminating
        }
        if terminating {
            await revertBestEffort()
            throw SideEffectError.failed(Self.terminatingMessage)
        }
        acquireAssertionAndActivity()
        do {
            try writeHeartbeat()
        } catch {
            // Without a heartbeat the root fail-safe clears the flag within 150 s: refuse to pretend we are armed.
            logger.error("arm: cannot write the heartbeat (\(error)); disarming")
            try? await performRealDisarm()
            throw SideEffectError.failed("cannot write heartbeat: \(error.localizedDescription)")
        }
        logger.notice("armed: kernel SleepDisabled = 1")
    }

    /// Disarm. Never short-circuits on internal state: with the gate off it runs `disablesleep 0` whenever the kernel
    /// reads true (launch reconcile clears a flag left by a crashed process) and polls for false; a no-op only when the
    /// kernel reads false. Releases the assertion + activity. A gate that differs from the arm-time gate throws.
    @concurrent
    public func disarm() async throws {
        try await transitions.run { try await self.disarmSerialized() }
    }

    private func disarmSerialized() async throws {
        let gateOn = dryRun.isOn
        let previous = state.withLock { $0.armGate }
        if let previous, previous != gateOn {
            logger.error("disarm refused: armed with dry-run \(previous ? "on" : "off"), now \(gateOn ? "on" : "off") (\(Self.gateToggledMessage))")
            if previous {
                // A stale simulation has no real effect: drop it so the next call acts on the kernel normally.
                clearSimulation(recordLedger: true)
            }
            throw SideEffectError.failed(Self.gateToggledMessage)
        }

        if gateOn {
            let simulated = state.withLock { $0.simulatedSleepDisabled }
            guard simulated else {
                releaseAssertionAndActivity()
                logger.debug("disarm: simulated flag already clear")
                return
            }
            let result = try await runPrivileged(.setSleepDisabled(false), gateOn: true)
            guard result.succeeded else { throw Self.commandError(result) }
            clearSimulation(recordLedger: true)
            releaseAssertionAndActivity()
            logger.notice("disarmed (dry-run simulation)")
            return
        }

        try await performRealDisarm()
    }

    /// Termination path only (a non-async signal-source handler). Runs the injected runner's
    /// `.setSleepDisabled(false)` in a detached task and waits ≤ `timeout`. Acts only when this process really armed —
    /// or has a real arm in flight (its command may already have set the flag). Latches "terminating": every later
    /// `arm()` is refused, so nothing re-arms behind the handler.
    public func disarmSynchronously(timeout: Duration) -> Bool {
        let gateOn = dryRun.isOn
        let (recorded, inFlight) = state.withLock { s -> (Bool?, Bool) in
            s.terminating = true
            return (s.armGate, s.armInFlight)
        }
        let armGate: Bool? = recorded ?? (inFlight ? false : nil)
        switch armGate {
        case .none:
            // Nothing of ours to clear.
            return gateOn ? true : rootDomain.sleepDisabled() != true
        case .some(true):
            clearSimulation(recordLedger: true)
            return true
        case .some(false):
            break
        }
        guard !gateOn else {
            logger.error("disarmSynchronously: really armed but dry-run is now on; the gated runner cannot clear the flag")
            return false
        }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        let outcome = SynchronousOutcome()
        let semaphore = DispatchSemaphore(value: 0)
        let runner = privileged
        Task.detached {
            do {
                let result = try await runner.run(.setSleepDisabled(false))
                outcome.set(result.succeeded)
            } catch {
                outcome.set(false)
            }
            semaphore.signal()
        }
        let remaining = max(0, (deadline - ContinuousClock.now).timeInterval)
        guard semaphore.wait(timeout: .now() + remaining) == .success, outcome.value == true else {
            logger.error("disarmSynchronously: disablesleep 0 did not complete within \(timeout)")
            return false
        }
        // Read back (real time: this is a blocking termination path, not a test-clock-driven loop).
        while rootDomain.sleepDisabled() == true {
            if ContinuousClock.now >= deadline {
                logger.error("disarmSynchronously: kernel SleepDisabled still set at the deadline")
                return false
            }
            usleep(20_000)
        }
        releaseAssertionAndActivity()
        state.withLock { $0.armGate = nil }
        logger.notice("disarmed synchronously (termination)")
        return true
    }

    /// Touches `paths.heartbeatFile` (0600, directory 0700, mtime = now) ONLY when really armed and the gate is off.
    /// Otherwise records `power.heartbeat` in the ledger: a dry-run app must never keep the root fail-safe from
    /// clearing a REAL stale flag.
    public func touchHeartbeat() throws {
        let really = state.withLock { $0.armGate == false }
        let gateOn = dryRun.isOn
        guard really, !gateOn else {
            if really {
                // Really armed but dry-run switched on without a disarm first: stop proving liveness so the root
                // fail-safe clears the real flag (≤ 210 s) instead of a simulated run keeping it set.
                logger.error("heartbeat withheld: really armed but dry-run is now on (\(Self.gateToggledMessage))")
            }
            ledger?.record(.power, action: "power.heartbeat", detail: "would touch heartbeat (not really armed)")
            return
        }
        try writeHeartbeat()
    }

    /// `IOPMSleepSystem` through the injected `SystemSleeping` (dry-run gated by the coordinator).
    public func sleepNow() async throws {
        if dryRun.isOn && !DryRunSafety.isInert(systemSleep) {
            withheld(action: "power.sleep", detail: "would put the Mac to sleep now (IOPMSleepSystem)")
            return
        }
        logger.notice("sleep now")
        try await systemSleep.sleepNow()
    }

    /// Polite shutdown through the injected `ShutdownRequesting` (dry-run gated by the coordinator).
    public func requestShutdown() async throws {
        if dryRun.isOn && !DryRunSafety.isInert(shutdown) {
            withheld(action: "power.shutdown", detail: "would ask loginwindow to shut down")
            return
        }
        logger.notice("polite shutdown requested")
        try await shutdown.requestShutdown()
    }

    /// The shutdown's sleep fallback in a detached helper (`SystemSleeping.scheduleDetachedSleep`, gated).
    public func scheduleDetachedSleep(after delay: Duration) throws {
        if dryRun.isOn && !DryRunSafety.isInert(systemSleep) {
            withheld(action: "power.scheduleSleep",
                     detail: "would leave a helper that sleeps the Mac in \(delay.components.seconds) s if the lid is closed")
            return
        }
        logger.notice("sleep fallback handed to a detached helper (\(delay.components.seconds) s)")
        try systemSleep.scheduleDetachedSleep(after: delay)
    }

    /// `pmset displaysleepnow` through the injected `DisplaySleeping` (dry-run gated by the coordinator).
    public func displaySleepNow() async throws {
        if dryRun.isOn && !DryRunSafety.isInert(displaySleep) {
            withheld(action: "power.displaySleep", detail: "would turn the built-in display off (pmset displaysleepnow)")
            return
        }
        logger.info("display sleep now")
        try await displaySleep.displaySleepNow()
    }

    public func playLidCloseChime() {
        chime.play(soundNamed: KakurenekoID.lidCloseChimeSoundName)
    }

    /// Fresh snapshot: battery, thermal, network, displays, user input, lock state + lid and both flags.
    @concurrent
    public func snapshot() async -> PowerSnapshot {
        snapshotReader.start()
        var snapshot = snapshotReader.read(at: clock.now())
        let flags = kernelFlags()
        snapshot.lid = flags.lid
        snapshot.sleepDisabled = flags.sleepDisabled
        snapshot.kernelSleepDisabled = flags.kernelSleepDisabled
        return snapshot
    }

    // MARK: - Internals

    /// Runs `.setSleepDisabled`. With the gate on, the command only goes to a runner that will merely LOG it (a Kit
    /// `DryRunPrivilegedCommandRunner` whose gate is on or that has no passthrough). Any other runner would change the
    /// real kernel flag while this controller reports a simulation — a wiring error — so the controller records the
    /// ledger entry itself and answers with a synthetic success instead.
    private func runPrivileged(_ command: PrivilegedCommand, gateOn: Bool) async throws -> SubprocessResult {
        if gateOn && !DryRunSafety.isInert(privileged) {
            let action = command == .setSleepDisabled(true) ? "power.arm" : "power.disarm"
            withheld(action: action, detail: "would run \(command.argv.joined(separator: " "))")
            return SubprocessResult(exitCode: 0)
        }
        return try await privileged.run(command)
    }

    /// Dry-run with a side effect that is not dry-run gated: never call it; record what would have happened.
    private func withheld(action: String, detail: String) {
        logger.warning("dry-run: \(action) withheld from an ungated side effect")
        ledger?.record(.power, action: action, detail: detail)
    }

    /// The real disarm (gate off): command when the kernel reads true (or is unreadable), read back false, release.
    /// On failure the armed state is kept, so `disarmSynchronously` and a later `disarm()` still try.
    private func performRealDisarm() async throws {
        let kernel = rootDomain.sleepDisabled()
        if kernel == false {
            releaseAssertionAndActivity()
            state.withLock { $0.armGate = nil }
            logger.debug("disarm: kernel SleepDisabled already clear")
            return
        }
        let result = try await privileged.run(.setSleepDisabled(false))
        guard result.succeeded else { throw Self.commandError(result) }
        if kernel == nil {
            logger.warning("disarm: kernel SleepDisabled unreadable; cannot verify the read-back")
        } else {
            try await waitForKernelFlag(false)
        }
        releaseAssertionAndActivity()
        state.withLock { $0.armGate = nil }
        logger.notice("disarmed: kernel SleepDisabled = 0")
    }

    /// Polls IOPMrootDomain `SleepDisabled` every `pollInterval` (injected clock) up to `pollAttempts` sleeps.
    /// An unreadable flag while waiting for `false` ends the wait (nothing more can be verified).
    private func waitForKernelFlag(_ expected: Bool) async throws {
        var attempt = 0
        while true {
            let value = rootDomain.sleepDisabled()
            if value == expected { return }
            if value == nil && !expected { return }
            guard attempt < pollAttempts else {
                throw SideEffectError.timedOut
            }
            attempt += 1
            try await clock.sleep(for: pollInterval)
        }
    }

    /// After a failed real arm: `disablesleep 0` without waiting (a late powerd apply of `1` is undone in order).
    private func revertBestEffort() async {
        do {
            let result = try await privileged.run(.setSleepDisabled(false))
            if !result.succeeded { logger.error("arm revert failed: exit \(result.exitCode)") }
        } catch {
            logger.error("arm revert failed: \(error)")
        }
    }

    private func acquireAssertionAndActivity() {
        let needs = state.withLock { s in (s.assertionID == nil, s.activity == nil) }
        var newAssertion: IOPMAssertionID?
        if needs.0 {
            newAssertion = assertions.createAssertion(reason: KakurenekoID.powerAssertionReason)
            if newAssertion == nil { logger.warning("could not create the PreventUserIdleSystemSleep assertion") }
        }
        let newActivity = needs.1 ? assertions.beginActivity(reason: KakurenekoID.activityReason) : nil
        let leftovers = state.withLock { s -> (IOPMAssertionID?, ActivityToken?) in
            var extraAssertion: IOPMAssertionID?
            var extraActivity: ActivityToken?
            if let newAssertion {
                if s.assertionID == nil { s.assertionID = newAssertion } else { extraAssertion = newAssertion }
            }
            if let newActivity {
                if s.activity == nil { s.activity = newActivity } else { extraActivity = newActivity }
            }
            return (extraAssertion, extraActivity)
        }
        if let extra = leftovers.0 { assertions.releaseAssertion(extra) }
        if let extra = leftovers.1 { assertions.endActivity(extra) }
    }

    private func releaseAssertionAndActivity() {
        let (assertion, activity) = state.withLock { s -> (IOPMAssertionID?, ActivityToken?) in
            defer {
                s.assertionID = nil
                s.activity = nil
            }
            return (s.assertionID, s.activity)
        }
        if let assertion { assertions.releaseAssertion(assertion) }
        if let activity { assertions.endActivity(activity) }
    }

    private func clearSimulation(recordLedger: Bool) {
        let was = state.withLock { s -> Bool in
            defer {
                s.simulatedSleepDisabled = false
                if s.armGate == true { s.armGate = nil }
            }
            return s.simulatedSleepDisabled
        }
        if was && recordLedger {
            ledger?.record(.power, action: "power.simulatedFlag", detail: "simulated SleepDisabled = 0 (kernel untouched)")
        }
    }

    /// Creates/updates the heartbeat file: directory 0700, file 0600, mtime = `clock.now()`.
    private func writeHeartbeat() throws {
        try Heartbeat.touch(paths.heartbeatFile, at: clock.now())
    }

    /// Non-zero exit (sudo: a password is required, …) → `.notPermitted(stderr)`.
    static func commandError(_ result: SubprocessResult) -> SideEffectError {
        if result.timedOut { return .timedOut }
        let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        return .notPermitted(stderr.isEmpty ? "exit \(result.exitCode)" : String(stderr.prefix(1024)))
    }
}

/// A FIFO async mutual-exclusion lock (no thread is blocked while waiting).
final class AsyncSerialLock: Sendable {
    private struct State {
        var locked = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    /// Runs `body` once every earlier caller has finished.
    func run<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let acquired = state.withLock { s -> Bool in
                if s.locked {
                    s.waiters.append(continuation)
                    return false
                }
                s.locked = true
                return true
            }
            if acquired { continuation.resume() }
        }
    }

    /// Hands the lock to the next waiter (it stays locked) or unlocks.
    private func release() {
        let next = state.withLock { s -> CheckedContinuation<Void, Never>? in
            if s.waiters.isEmpty {
                s.locked = false
                return nil
            }
            return s.waiters.removeFirst()
        }
        next?.resume()
    }
}

/// One-shot result slot shared between `disarmSynchronously` and its detached task.
private final class SynchronousOutcome: Sendable {
    private let state = Mutex<Bool?>(nil)
    func set(_ value: Bool) { state.withLock { $0 = value } }
    var value: Bool? { state.withLock { $0 } }
}

/// Recognises the Kit dry-run switches that will only LOG a call (gate on, or no passthrough at all).
enum DryRunSafety {
    static func isInert(_ runner: any PrivilegedCommandRunning) -> Bool {
        guard let wrapper = runner as? DryRunPrivilegedCommandRunner else { return false }
        return wrapper.passthrough == nil || wrapper.gate.isOn
    }

    static func isInert(_ sleeper: any SystemSleeping) -> Bool {
        guard let wrapper = sleeper as? DryRunSystemSleeper else { return false }
        return wrapper.passthrough == nil || wrapper.gate.isOn
    }

    static func isInert(_ requester: any ShutdownRequesting) -> Bool {
        guard let wrapper = requester as? DryRunShutdownRequester else { return false }
        return wrapper.passthrough == nil || wrapper.gate.isOn
    }

    static func isInert(_ sleeper: any DisplaySleeping) -> Bool {
        guard let wrapper = sleeper as? DryRunDisplaySleeper else { return false }
        return wrapper.passthrough == nil || wrapper.gate.isOn
    }
}

/// The heartbeat file the root fail-safe watches (`stat -f %m`, 150 s max age; R01 §5.4).
enum Heartbeat {
    /// Creates/updates the file (0600, never through a symlink) in a 0700 directory and sets its mtime to `date`.
    static func touch(_ url: URL, at date: Date) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        _ = chmod(directory.path(percentEncoded: false), 0o700)
        let path = url.path(percentEncoded: false)
        let fd = open(path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError.posix(errno, path: path) }
        defer { close(fd) }
        _ = fchmod(fd, 0o600)
        let seconds = date.timeIntervalSince1970
        let whole = floor(seconds)
        let time = timeval(tv_sec: Int(whole), tv_usec: Int32(((seconds - whole) * 1_000_000).rounded(.down)))
        var times = [time, time]
        guard futimes(fd, &times) == 0 else { throw CocoaError.posix(errno, path: path) }
    }
}

extension CocoaError {
    /// A POSIX failure as a Cocoa file error (keeps the path for the log).
    static func posix(_ code: Int32, path: String) -> any Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }
}
