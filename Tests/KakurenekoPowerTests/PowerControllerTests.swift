@testable import KakurenekoPower
import KakurenekoKit
import Foundation
import Synchronization
import Testing

/// A `PowerController` wired like production (each side effect behind its Kit dry-run switch, one shared gate and
/// ledger), but every "real" implementation is a recording fake and the kernel / assertions are fakes.
final class ControllerRig: Sendable {
    let paths: Paths
    let clock = TestClock()
    let gate: DryRunGate
    let ledger: DryRunLedger
    let kernel: FakeRootDomain
    let runner: ScriptedPrivilegedRunner
    let assertions = RecordingAssertionMaker()
    let reader = StaticSnapshotReader()
    let chime = RecordingChime()
    let sleeper = RecordingSleeper()
    let shutdown = RecordingShutdown()
    let display = RecordingDisplaySleeper()
    let controller: PowerController

    /// - Parameters:
    ///   - gated: wrap the fakes in the Kit dry-run switches (production wiring). false = hand the raw fakes over.
    ///   - privileged: replaces the scripted runner (still gated when `gated`).
    ///   - rootDomain: replaces the fake kernel built from `kernelValue` / `lid`.
    init(gateOn: Bool, kernel kernelValue: Bool? = false, lid: Bool? = false, lag: Int = 0, kernelFollows: Bool = true,
         gated: Bool = true, privileged: (any PrivilegedCommandRunning)? = nil, rootDomain: FakeRootDomain? = nil) throws {
        paths = try temporaryPaths()
        gate = DryRunGate(policy: .off, requested: gateOn)
        ledger = DryRunLedger(clock: clock)
        kernel = rootDomain ?? FakeRootDomain(sleepDisabled: kernelValue, clamshellClosed: lid)
        runner = ScriptedPrivilegedRunner(kernel: kernel, lag: lag, kernelFollows: kernelFollows)
        let realPrivileged: any PrivilegedCommandRunning = privileged ?? runner
        controller = PowerController(
            paths: paths,
            privileged: gated ? DryRunPrivilegedCommandRunner(passthrough: realPrivileged, gate: gate, ledger: ledger) : realPrivileged,
            systemSleep: gated ? DryRunSystemSleeper(passthrough: sleeper, gate: gate, ledger: ledger) : sleeper,
            shutdown: gated ? DryRunShutdownRequester(passthrough: shutdown, gate: gate, ledger: ledger) : shutdown,
            displaySleep: gated ? DryRunDisplaySleeper(passthrough: display, gate: gate, ledger: ledger) : display,
            dryRun: gate,
            clock: clock,
            logger: KakurenekoLogger(.power),
            ledger: gated ? nil : ledger,
            rootDomain: kernel,
            assertions: assertions,
            snapshotReader: reader,
            chime: chime
        )
    }

    deinit { cleanup(paths) }

    var heartbeat: URL { paths.heartbeatFile }
    var heartbeatExists: Bool { FileManager.default.fileExists(atPath: heartbeat.path(percentEncoded: false)) }

    func ledgerCount(_ action: String) -> Int { ledger.entries(action: action).count }

    /// arm() while advancing the test clock through the read-back poll.
    @discardableResult
    func arm() async throws -> Int {
        let controller = self.controller
        return try await driving(clock) { try await controller.arm() }.steps
    }

    @discardableResult
    func disarm() async throws -> Int {
        let controller = self.controller
        return try await driving(clock) { try await controller.disarm() }.steps
    }

    /// `disarmSynchronously` on a GCD thread, the way the coordinator's signal-source handler calls it.
    func disarmSynchronouslyOffTheCooperativePool(timeout: Duration) async -> Bool {
        let controller = self.controller
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: controller.disarmSynchronously(timeout: timeout))
            }
        }
    }
}

let armArgv = ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "1"]
let disarmArgv = ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "0"]

@Suite("PowerController — dry-run", .timeLimit(.minutes(1)))
struct PowerControllerDryRunTests {
    @Test func armSimulatesTheFlagWithoutTouchingTheKernel() async throws {
        let rig = try ControllerRig(gateOn: true, kernel: false)
        let steps = try await rig.arm()
        #expect(steps == 0)
        #expect(rig.kernel.reads == 0, "dry-run never polls the kernel")
        let flags = rig.controller.kernelFlags()
        #expect(flags.sleepDisabled == true)
        #expect(flags.kernelSleepDisabled == false)
        #expect(flags.isSimulated)
        #expect(rig.runner.commands.isEmpty, "the real runner is never reached in dry-run")
        let arm = rig.ledger.entries(action: "power.arm")
        #expect(arm.count == 1)
        #expect(arm.first?.detail == "would run " + armArgv.joined(separator: " "))
        #expect(rig.ledgerCount("power.simulatedFlag") == 1)
        #expect(rig.assertions.createdReasons.isEmpty)
        #expect(rig.assertions.activityReasons.isEmpty)
        #expect(!rig.controller.isArmedForReal)
        #expect(rig.controller.isSimulatedArmed)
        #expect(!rig.heartbeatExists, "arm never writes the heartbeat in dry-run")
    }

    @Test func heartbeatIsOnlyLedgeredInDryRun() async throws {
        let rig = try ControllerRig(gateOn: true)
        try await rig.arm()
        try rig.controller.touchHeartbeat()
        try rig.controller.touchHeartbeat()
        #expect(!rig.heartbeatExists)
        #expect(!FileManager.default.fileExists(atPath: rig.paths.runDirectory.path(percentEncoded: false)))
        #expect(rig.ledgerCount("power.heartbeat") == 2)
    }

    @Test func disarmReversesTheSimulation() async throws {
        let rig = try ControllerRig(gateOn: true, kernel: false)
        try await rig.arm()
        try await rig.disarm()
        let flags = rig.controller.kernelFlags()
        #expect(flags.sleepDisabled == false)
        #expect(flags.isSimulated)
        #expect(rig.ledgerCount("power.disarm") == 1)
        #expect(rig.ledgerCount("power.simulatedFlag") == 2)
        #expect(rig.runner.commands.isEmpty)
        #expect(!rig.controller.isSimulatedArmed)
        // A second disarm has nothing to undo.
        try await rig.disarm()
        #expect(rig.ledgerCount("power.disarm") == 1)
    }

    @Test func realKernelFlagIsAlwaysReported() async throws {
        // A real flag left set by a crashed, really armed run; this run is dry-run.
        let rig = try ControllerRig(gateOn: true, kernel: true)
        var flags = rig.controller.kernelFlags()
        #expect(flags.sleepDisabled == false)
        #expect(flags.kernelSleepDisabled == true)
        try await rig.arm()
        try await rig.disarm()
        flags = rig.controller.kernelFlags()
        #expect(flags.sleepDisabled == false)
        #expect(flags.kernelSleepDisabled == true, "dry-run never clears the real flag")
        #expect(rig.runner.commands.isEmpty)
        let snapshot = await rig.controller.snapshot()
        #expect(snapshot.sleepDisabled == false)
        #expect(snapshot.kernelSleepDisabled == true)
    }

    @Test func ungatedSideEffectsAreNeverCalledInDryRun() async throws {
        // Wiring error: raw implementations handed over while dry-run is on. The controller must not act.
        let rig = try ControllerRig(gateOn: true, gated: false)
        try await rig.arm()
        try await rig.disarm()
        try await rig.controller.sleepNow()
        try await rig.controller.requestShutdown()
        try await rig.controller.displaySleepNow()
        #expect(rig.runner.commands.isEmpty)
        #expect(rig.sleeper.calls == 0)
        #expect(rig.shutdown.calls == 0)
        #expect(rig.display.calls == 0)
        #expect(rig.ledgerCount("power.arm") == 1)
        #expect(rig.ledgerCount("power.disarm") == 1)
        #expect(rig.ledgerCount("power.sleep") == 1)
        #expect(rig.ledgerCount("power.shutdown") == 1)
        #expect(rig.ledgerCount("power.displaySleep") == 1)
    }

    @Test func gatedEndActionsAreOnlyLedgered() async throws {
        let rig = try ControllerRig(gateOn: true)
        try await rig.controller.sleepNow()
        try await rig.controller.requestShutdown()
        try await rig.controller.displaySleepNow()
        #expect(rig.sleeper.calls == 0 && rig.shutdown.calls == 0 && rig.display.calls == 0)
        #expect(rig.ledgerCount("power.sleep") == 1)
        #expect(rig.ledgerCount("power.shutdown") == 1)
        #expect(rig.ledgerCount("power.displaySleep") == 1)
    }

    @Test func publicInitDerivesTheLedgerFromTheGatedRunner() async throws {
        let paths = try temporaryPaths()
        defer { cleanup(paths) }
        let ledger = DryRunLedger()
        let effects = SideEffects.inert(ledger: ledger)
        let controller = PowerController(
            paths: paths, privileged: effects.privileged, systemSleep: effects.systemSleep, shutdown: effects.shutdown,
            displaySleep: effects.displaySleep, dryRun: .alwaysOn(), clock: TestClock())
        try await controller.arm()
        #expect(controller.kernelFlags().sleepDisabled == true)
        try controller.touchHeartbeat()
        try await controller.disarm()
        #expect(controller.kernelFlags().sleepDisabled == false)
        #expect(ledger.entries.map(\.action) == ["power.arm", "power.simulatedFlag", "power.heartbeat", "power.disarm", "power.simulatedFlag"])
        #expect(!FileManager.default.fileExists(atPath: paths.heartbeatFile.path(percentEncoded: false)))
    }
}

@Suite("PowerController — gate off (fake runner + fake kernel)", .timeLimit(.minutes(1)))
struct PowerControllerRealPathTests {
    @Test func armRunsTheExactCommandAndReadsTheKernelBack() async throws {
        let rig = try ControllerRig(gateOn: false, kernel: false, lag: 3)
        let start = rig.clock.now()
        let steps = try await rig.arm()
        #expect(steps == 3, "three 100 ms polls before the kernel reports the flag")
        #expect(abs(rig.clock.now().timeIntervalSince(start) - 0.3) < 1e-3)
        #expect(rig.runner.argvs == [armArgv])
        #expect(rig.assertions.createdReasons == [KakurenekoID.powerAssertionReason])
        #expect(rig.assertions.createdReasons == ["Kakureneko: agent active"])
        #expect(rig.assertions.activityReasons == ["Kakureneko monitoring"])
        #expect(rig.controller.isArmedForReal)
        #expect(rig.controller.holdsAssertion)
        let flags = rig.controller.kernelFlags()
        #expect(flags.sleepDisabled == true && flags.kernelSleepDisabled == true && !flags.isSimulated)
        // The heartbeat: 0600 file in a 0700 directory, mtime = now.
        let file = try #require(fileStatus(rig.heartbeat))
        #expect(file.mode == 0o600)
        #expect(fileStatus(rig.paths.runDirectory)?.mode == 0o700)
        #expect(abs(file.modified.timeIntervalSince(rig.clock.now())) < 0.001)
        #expect(rig.ledger.entries.isEmpty, "nothing is simulated with the gate off")
    }

    @Test func armTimesOutAndRevertsWhenTheKernelNeverReportsTheFlag() async throws {
        let rig = try ControllerRig(gateOn: false, kernel: false, kernelFollows: false)
        let start = rig.clock.now()
        await #expect(throws: SideEffectError.timedOut) { try await rig.arm() }
        #expect(rig.kernel.reads == 52, "the pre-arm read (was the flag already set?) + one read + 50 polls")
        #expect(abs(rig.clock.now().timeIntervalSince(start) - 5) < 1e-3, "≤ 5 s of (virtual) polling")
        #expect(rig.runner.argvs == [armArgv, disarmArgv], "a failed arm is reverted")
        #expect(rig.assertions.createdReasons.isEmpty)
        #expect(!rig.controller.isArmedForReal)
        #expect(!rig.heartbeatExists)
    }

    @Test func armWithoutTheSudoRuleThrowsNotPermitted() async throws {
        let rig = try ControllerRig(gateOn: false)
        rig.runner.setResponder { _ in SubprocessResult(exitCode: 1, stderr: Data("sudo: a password is required\n".utf8)) }
        await #expect(throws: SideEffectError.notPermitted("sudo: a password is required")) { try await rig.arm() }
        // No read-back poll after a failed command: only the pre-arm read and the "did it apply anyway?" check.
        #expect(rig.kernel.reads == 2)
        #expect(rig.runner.argvs == [armArgv], "nothing applied: no revert")
        #expect(rig.assertions.createdReasons.isEmpty)
        #expect(!rig.controller.isArmedForReal)
        #expect(!rig.heartbeatExists)
    }

    @Test func armWithSilentFailureStillThrowsNotPermitted() async throws {
        let rig = try ControllerRig(gateOn: false)
        rig.runner.setResponder { _ in SubprocessResult(exitCode: 1) }
        await #expect(throws: SideEffectError.notPermitted("exit 1")) { try await rig.arm() }
    }

    @Test func armPropagatesRunnerErrors() async throws {
        let rig = try ControllerRig(gateOn: false)
        rig.runner.setResponder { _ in throw SideEffectError.unavailable("cannot launch /usr/bin/sudo") }
        await #expect(throws: SideEffectError.unavailable("cannot launch /usr/bin/sudo")) { try await rig.arm() }
        #expect(!rig.controller.isArmedForReal)
    }

    @Test func armFailsAndDisarmsWhenTheHeartbeatCannotBeWritten() async throws {
        let rig = try ControllerRig(gateOn: false)
        // A regular file where the run directory should be.
        try FileManager.default.createDirectory(at: rig.paths.kakurenekoDirectory, withIntermediateDirectories: true)
        try Data().write(to: rig.paths.runDirectory)
        do {
            try await rig.arm()
            Issue.record("arm must fail without a heartbeat")
        } catch let error as SideEffectError {
            guard case .failed(let message) = error else { Issue.record("unexpected \(error)"); return }
            #expect(message.contains("heartbeat"))
        }
        #expect(rig.runner.argvs == [armArgv, disarmArgv])
        #expect(!rig.controller.isArmedForReal)
        #expect(rig.assertions.held == 0)
        #expect(rig.kernel.current == false)
    }

    @Test func disarmClearsAFlagLeftByACrashedProcess() async throws {
        let rig = try ControllerRig(gateOn: false, kernel: true, lag: 2)
        let steps = try await rig.disarm()
        #expect(steps == 2)
        #expect(rig.runner.argvs == [disarmArgv])
        #expect(rig.kernel.current == false)
    }

    @Test func disarmIsANoOpOnlyWhenTheKernelReadsFalse() async throws {
        let rig = try ControllerRig(gateOn: false, kernel: false)
        try await rig.disarm()
        #expect(rig.runner.commands.isEmpty)
    }

    @Test func disarmWithAnUnreadableKernelStillRunsTheCommand() async throws {
        let rig = try ControllerRig(gateOn: false, kernel: nil, kernelFollows: false)
        let steps = try await rig.disarm()
        #expect(steps == 0)
        #expect(rig.runner.argvs == [disarmArgv])
    }

    @Test func disarmTimesOutWhenTheFlagStaysSet() async throws {
        let rig = try ControllerRig(gateOn: false, kernel: true, kernelFollows: false)
        await #expect(throws: SideEffectError.timedOut) { try await rig.disarm() }
        #expect(rig.runner.argvs == [disarmArgv])
    }

    @Test func disarmFailureKeepsTheArmedStateForALaterAttempt() async throws {
        let rig = try ControllerRig(gateOn: false)
        try await rig.arm()
        rig.runner.setResponder { command in
            command == .setSleepDisabled(false)
                ? SubprocessResult(exitCode: 1, stderr: Data("sudo: a password is required".utf8))
                : SubprocessResult(exitCode: 0)
        }
        await #expect(throws: SideEffectError.notPermitted("sudo: a password is required")) { try await rig.disarm() }
        #expect(rig.controller.isArmedForReal)
        rig.runner.setResponder { _ in SubprocessResult(exitCode: 0) }
        try await rig.disarm()
        #expect(!rig.controller.isArmedForReal)
    }

    @Test func disarmAfterArmReleasesAssertionAndActivity() async throws {
        let rig = try ControllerRig(gateOn: false, lag: 1)
        try await rig.arm()
        let armedAt = try #require(fileStatus(rig.heartbeat)).modified
        try await rig.disarm()
        #expect(rig.runner.argvs == [armArgv, disarmArgv])
        #expect(rig.assertions.releasedIDs == rig.assertions.createdIDs)
        #expect(rig.assertions.endedActivities == 1)
        #expect(!rig.controller.isArmedForReal)
        #expect(!rig.controller.holdsAssertion)
        // No heartbeat once disarmed.
        rig.clock.advance(by: .seconds(30))
        try rig.controller.touchHeartbeat()
        #expect(try #require(fileStatus(rig.heartbeat)).modified == armedAt)
        #expect(rig.ledgerCount("power.heartbeat") == 1)
    }

    @Test func rearmingDoesNotLeakAssertions() async throws {
        let rig = try ControllerRig(gateOn: false)
        try await rig.arm()
        try await rig.arm()
        #expect(rig.runner.argvs == [armArgv, armArgv])
        #expect(rig.assertions.held == 1)
        #expect(rig.assertions.activityReasons.count == 1)
    }

    @Test func gateTurnedOnBetweenArmAndDisarmThrows() async throws {
        let rig = try ControllerRig(gateOn: false)
        try await rig.arm()
        rig.gate.setRequested(true)
        await #expect(throws: SideEffectError.failed("dry-run toggled while really armed")) { try await rig.disarm() }
        await #expect(throws: SideEffectError.failed("dry-run toggled while really armed")) { try await rig.arm() }
        #expect(rig.runner.argvs == [armArgv], "no simulated undo of a real arm")
        #expect(rig.controller.isArmedForReal)
        // The heartbeat stops (the root fail-safe will clear the real flag).
        let before = try #require(fileStatus(rig.heartbeat)).modified
        rig.clock.advance(by: .seconds(15))
        try rig.controller.touchHeartbeat()
        #expect(try #require(fileStatus(rig.heartbeat)).modified == before)
        #expect(rig.ledgerCount("power.heartbeat") == 1)
        // Back under the arm-time gate, the undo works.
        rig.gate.setRequested(false)
        try await rig.disarm()
        #expect(rig.runner.argvs == [armArgv, disarmArgv])
        #expect(!rig.controller.isArmedForReal)
    }

    @Test func gateTurnedOffBetweenSimulatedArmAndDisarmThrows() async throws {
        let rig = try ControllerRig(gateOn: true, kernel: false)
        try await rig.arm()
        rig.gate.setRequested(false)
        await #expect(throws: SideEffectError.failed("dry-run toggled while really armed")) { try await rig.disarm() }
        #expect(rig.runner.commands.isEmpty, "a simulated arm is never undone for real")
        let flags = rig.controller.kernelFlags()
        #expect(flags.sleepDisabled == false && !flags.isSimulated)
        // The stale simulation is gone: the next disarm acts on the (clear) kernel normally.
        try await rig.disarm()
        #expect(rig.runner.commands.isEmpty)
    }

    @Test func overlappingDisarmWaitsForTheArmInFlight() async throws {
        let rig = try ControllerRig(gateOn: false, kernel: false, lag: 3)
        let controller = rig.controller
        let arm = Task { try await controller.arm() }
        #expect(await waitUntil { rig.clock.sleeperCount == 1 }, "arm is polling the kernel")
        let disarm = Task { try await controller.disarm() }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(rig.runner.argvs == [armArgv], "disarm must not interleave with the arm's read-back")
        // Let both finish: arm needs 3 polls, then disarm (kernel true) runs and needs 3 polls too.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while (rig.runner.argvs.count < 2 || rig.kernel.current != false) && ContinuousClock.now < deadline {
            if rig.clock.sleeperCount > 0 { rig.clock.advance(by: .milliseconds(100)) } else { await Task.yield() }
        }
        try await arm.value
        try await disarm.value
        #expect(rig.runner.argvs == [armArgv, disarmArgv])
        #expect(rig.kernel.current == false)
        #expect(!rig.controller.isArmedForReal)
        #expect(rig.assertions.held == 0)
    }

    @Test func serialLockIsFIFO() async throws {
        let lock = AsyncSerialLock()
        let order = Locked<[Int]>([])
        let gate = TestClock()
        let first = Task {
            try await lock.run {
                order.update { $0.append(1) }
                try await gate.sleep(for: .seconds(1))
                order.update { $0.append(-1) }
            }
        }
        #expect(await waitUntil { gate.sleeperCount == 1 })
        let second = Task { try await lock.run { order.update { $0.append(2) } } }
        try? await Task.sleep(for: .milliseconds(10))
        let third = Task { try await lock.run { order.update { $0.append(3) } } }
        try? await Task.sleep(for: .milliseconds(10))
        #expect(order.value == [1])
        gate.advance(by: .seconds(1))
        try await first.value
        try await second.value
        try await third.value
        #expect(order.value == [1, -1, 2, 3])
    }

    @Test func touchHeartbeatUpdatesTheMtimeWhileReallyArmed() async throws {
        let rig = try ControllerRig(gateOn: false)
        try await rig.arm()
        for _ in 0..<3 {
            rig.clock.advance(by: .seconds(15))
            try rig.controller.touchHeartbeat()
            let status = try #require(fileStatus(rig.heartbeat))
            #expect(abs(status.modified.timeIntervalSince(rig.clock.now())) < 0.001)
            #expect(status.mode == 0o600)
        }
        #expect(rig.ledgerCount("power.heartbeat") == 0)
    }

    @Test func touchHeartbeatWithoutArmingWritesNothing() async throws {
        let rig = try ControllerRig(gateOn: false)
        try rig.controller.touchHeartbeat()
        #expect(!rig.heartbeatExists)
        #expect(rig.ledgerCount("power.heartbeat") == 1)
    }

    @Test func heartbeatRefusesASymlink() async throws {
        let rig = try ControllerRig(gateOn: false)
        try await rig.arm()
        let target = rig.paths.home.appending(path: "elsewhere")
        try Data().write(to: target)
        try FileManager.default.removeItem(at: rig.heartbeat)
        try FileManager.default.createSymbolicLink(at: rig.heartbeat, withDestinationURL: target)
        #expect(throws: (any Error).self) { try rig.controller.touchHeartbeat() }
    }

    @Test func endActionsDelegateToTheInjectedSideEffects() async throws {
        let rig = try ControllerRig(gateOn: false)
        try await rig.controller.sleepNow()
        try await rig.controller.requestShutdown()
        try await rig.controller.displaySleepNow()
        #expect(rig.sleeper.calls == 1)
        #expect(rig.shutdown.calls == 1)
        #expect(rig.display.calls == 1)
        #expect(rig.ledger.entries.isEmpty)
    }

    @Test func chimePlaysSubmarine() throws {
        let rig = try ControllerRig(gateOn: true)
        rig.controller.playLidCloseChime()
        #expect(rig.chime.played == ["Submarine"])
    }

    @Test func snapshotMergesLidAndBothFlags() async throws {
        let rig = try ControllerRig(gateOn: false, kernel: false, lid: true)
        rig.clock.advance(by: .seconds(42))
        let snapshot = await rig.controller.snapshot()
        #expect(snapshot.takenAt == rig.clock.now())
        #expect(snapshot.lid == .closed)
        #expect(snapshot.sleepDisabled == false)
        #expect(snapshot.kernelSleepDisabled == false)
        #expect(snapshot.batteryPercent == 80)
        #expect(snapshot.onBattery)
        #expect(rig.reader.starts >= 1)
    }

    @Test func kernelFlagsMapTheLid() throws {
        let rig = try ControllerRig(gateOn: false, kernel: true, lid: nil)
        var flags = rig.controller.kernelFlags()
        #expect(flags.lid == .noLid)
        #expect(flags.sleepDisabled == true && flags.kernelSleepDisabled == true && !flags.isSimulated)
        rig.kernel.set(clamshellClosed: false)
        flags = rig.controller.kernelFlags()
        #expect(flags.lid == .open)
        rig.kernel.set(clamshellClosed: true)
        #expect(rig.controller.kernelFlags().lid == .closed)
    }

    @Test func startIsIdempotentAndChangesNothing() async throws {
        let rig = try ControllerRig(gateOn: false, kernel: true)
        await rig.controller.start()
        await rig.controller.start()
        #expect(rig.reader.starts == 1)
        #expect(rig.runner.commands.isEmpty, "reconcile is the coordinator's decision")
        #expect(rig.controller.kernelFlags().kernelSleepDisabled == true)
    }
}

@Suite("PowerController — disarmSynchronously", .timeLimit(.minutes(1)))
struct PowerControllerSynchronousTests {
    @Test func usesTheInjectedRunnerWhenReallyArmed() async throws {
        let rig = try ControllerRig(gateOn: false, lag: 1)
        try await rig.arm()
        // Generous: the injected runner runs in a detached task that may wait for a thread on a busy machine; the
        // call returns as soon as the flag reads clear.
        let cleared = await rig.disarmSynchronouslyOffTheCooperativePool(timeout: .seconds(10))
        #expect(cleared)
        #expect(rig.runner.argvs == [armArgv, disarmArgv])
        #expect(rig.kernel.current == false)
        #expect(!rig.controller.isArmedForReal)
        #expect(rig.assertions.held == 0)
    }

    @Test func actsOnlyWhenThisProcessReallyArmed() async throws {
        let clear = try ControllerRig(gateOn: false, kernel: false)
        #expect(await clear.disarmSynchronouslyOffTheCooperativePool(timeout: .seconds(1)))
        #expect(clear.runner.commands.isEmpty)

        // Someone else's flag: reported (not clear) but never touched from the termination path.
        let foreign = try ControllerRig(gateOn: false, kernel: true)
        #expect(await foreign.disarmSynchronouslyOffTheCooperativePool(timeout: .seconds(1)) == false)
        #expect(foreign.runner.commands.isEmpty)

        let simulated = try ControllerRig(gateOn: true)
        try await simulated.arm()
        #expect(await simulated.disarmSynchronouslyOffTheCooperativePool(timeout: .seconds(1)))
        #expect(simulated.runner.commands.isEmpty)
        #expect(simulated.controller.kernelFlags().sleepDisabled == false)
    }

    @Test func refusesWhenTheGateFlippedAfterARealArm() async throws {
        let rig = try ControllerRig(gateOn: false)
        try await rig.arm()
        rig.gate.setRequested(true)
        #expect(await rig.disarmSynchronouslyOffTheCooperativePool(timeout: .seconds(1)) == false)
        #expect(rig.runner.argvs == [armArgv])
    }

    @Test func givesUpAtTheTimeout() async throws {
        let kernel = FakeRootDomain(sleepDisabled: false)
        let hanging = HangOnDisarmRunner(kernel: kernel)
        let rig = try ControllerRig(gateOn: false, privileged: hanging, rootDomain: kernel)
        try await rig.arm()
        let started = ContinuousClock.now
        let cleared = await rig.disarmSynchronouslyOffTheCooperativePool(timeout: .milliseconds(150))
        let elapsed = ContinuousClock.now - started
        #expect(!cleared)
        // The runner never returns until released: returning at all (well before the release) proves the timeout
        // was honoured. The bound leaves room for dispatching onto a busy machine.
        #expect(elapsed < .seconds(5))
        #expect(hanging.disarmCalls == 1)
        #expect(rig.controller.isArmedForReal, "still armed: the fail-safe (or a later disarm) clears it")
        hanging.release()
    }
}

@Suite("PowerController — live reads (read-only)", .timeLimit(.minutes(1)))
struct PowerControllerLiveReadTests {
    @Test func snapshotReturnsSaneRanges() async throws {
        let paths = try temporaryPaths()
        defer { cleanup(paths) }
        let clock = TestClock()
        let effects = SideEffects.inert()
        // Dry-run + inert side effects: only IOKit/IOPS/CoreGraphics READS happen.
        let controller = PowerController(
            paths: paths, privileged: effects.privileged, systemSleep: effects.systemSleep, shutdown: effects.shutdown,
            displaySleep: effects.displaySleep, dryRun: .alwaysOn(), clock: clock)
        let snapshot = await controller.snapshot()
        #expect(snapshot.takenAt == clock.now())
        if let percent = snapshot.batteryPercent { #expect((0...100).contains(percent)) }
        if let minutes = snapshot.timeToEmptyMinutes {
            #expect(minutes > 0)
            #expect(snapshot.onBattery)
        }
        if snapshot.drainingOnAC { #expect(snapshot.onAC) }
        if let seconds = snapshot.secondsSinceUserInput { #expect(seconds >= 0) }
        #expect([LidState.open, .closed, .noLid].contains(snapshot.lid))
        #expect(snapshot.sleepDisabled == false, "simulated flag, never armed")
        let flags = controller.kernelFlags()
        #expect(flags.isSimulated)
    }
}
