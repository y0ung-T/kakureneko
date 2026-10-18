@testable import KakurenekoPower
import KakurenekoKit
import Foundation
import Testing

/// Regression tests for the power-safety review (each failed before its fix). Fakes only: no sudo, no pmset, no
/// sleep, no spawn.
@Suite("Power safety fixes", .timeLimit(.minutes(1)))
struct PowerSafetyFixTests {
    private func waitForSleeper(_ clock: TestClock) async -> Bool {
        await clock.waitForSleepers(1)
    }

    // MARK: Termination while an arm is in flight

    /// SIGTERM while `arm()` is parked in its read-back poll: the flag our command just set used to be treated as
    /// foreign and left for the fail-safe (≤ ~210 s).
    @Test func terminationDuringAnInFlightArmClearsTheFlag() async throws {
        let rig = try ControllerRig(gateOn: false, kernel: false, lag: 1)
        let controller = rig.controller
        let outcome = Locked<Result<Void, any Error>?>(nil)
        let armTask = Task {
            do {
                try await controller.arm()
                outcome.set(.success(()))
            } catch {
                outcome.set(.failure(error))
            }
        }
        #expect(await waitForSleeper(rig.clock)) // parked in the read-back poll, `disablesleep 1` already sent
        #expect(rig.runner.argvs == [armArgv])
        let cleared = await rig.disarmSynchronouslyOffTheCooperativePool(timeout: .seconds(2))
        #expect(cleared)
        #expect(rig.kernel.current == false)
        #expect(rig.runner.argvs.prefix(2) == [armArgv, disarmArgv])
        // Let the interrupted arm finish (drive its poll); it must never claim the flag afterwards.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while outcome.value == nil, ContinuousClock.now < deadline {
            if rig.clock.sleeperCount > 0 { rig.clock.advance(by: .milliseconds(100)) } else {
                try? await Task.sleep(for: .microseconds(200))
            }
        }
        armTask.cancel()
        let result = try #require(outcome.value)
        if case .success = result { Issue.record("the interrupted arm reported success") }
        #expect(!rig.controller.isArmedForReal)
        #expect(rig.kernel.current == false)
    }

    /// After the termination path ran, nothing re-arms behind it.
    @Test func anArmAfterTheTerminationPathIsRefused() async throws {
        let rig = try ControllerRig(gateOn: false, kernel: false)
        #expect(await rig.disarmSynchronouslyOffTheCooperativePool(timeout: .seconds(1)))
        await #expect(throws: SideEffectError.failed(PowerController.terminatingMessage)) { try await rig.arm() }
        #expect(rig.runner.argvs.isEmpty)
        #expect(rig.kernel.current == false)
    }

    /// `sudo` timed out (15 s) after `pmset` had applied the flag: the arm used to throw without reverting.
    @Test func anArmWhoseCommandThrowsAfterApplyingIsReverted() async throws {
        let kernel = FakeRootDomain(sleepDisabled: false, clamshellClosed: false)
        let runner = ScriptedPrivilegedRunner(kernel: kernel) { command in
            if command == .setSleepDisabled(true) {
                kernel.apply(true, afterReads: 0)
                throw SideEffectError.timedOut
            }
            return SubprocessResult(exitCode: 0)
        }
        let rig = try ControllerRig(gateOn: false, privileged: runner, rootDomain: kernel)
        await #expect(throws: SideEffectError.timedOut) { try await rig.arm() }
        #expect(runner.argvs == [armArgv, disarmArgv])
        #expect(kernel.current == false)
        #expect(!rig.controller.isArmedForReal)
    }

    /// A flag that was already set (crash leftover, someone else) is not "reverted" by a failing arm.
    @Test func aFailingArmNeverClearsAFlagThatWasAlreadySet() async throws {
        let kernel = FakeRootDomain(sleepDisabled: true, clamshellClosed: false)
        let runner = ScriptedPrivilegedRunner(kernel: kernel) { command in
            if command == .setSleepDisabled(true) { throw SideEffectError.timedOut }
            return SubprocessResult(exitCode: 0)
        }
        let rig = try ControllerRig(gateOn: false, privileged: runner, rootDomain: kernel)
        await #expect(throws: SideEffectError.timedOut) { try await rig.arm() }
        #expect(runner.argvs == [armArgv])
    }

    // MARK: The shutdown's sleep fallback outlives the app

    @Test func theDetachedSleeperIsAShellInItsOwnSessionThatSleepsOnlyWithTheLidClosed() async throws {
        let argv = IOPMSystemSleeper.detachedSleepArgv(after: .seconds(150))
        #expect(argv.first == "/bin/sh")
        #expect(argv[1] == "-c")
        #expect(argv.suffix(2) == ["kakureneko-sleep-fallback", "150"])
        #expect(IOPMSystemSleeper.detachedSleepArgv(after: .milliseconds(10)).last == "1")
        let script = IOPMSystemSleeper.detachedSleepScript
        #expect(script.hasPrefix(#"/bin/sleep "$1"; "#))
        #expect(script.contains(#""AppleClamshellState" = Yes"#))
        #expect(script.contains("&& exec /usr/bin/pmset sleepnow"))
        // Syntax only (`sh -n` never executes it).
        let result = try await runTool("/bin/sh", ["-n", "-c", script])
        #expect(result.exitCode == 0, "\(result.stderrString)")

        let spawned = Locked<[[String]]>([])
        let sleeper = IOPMSystemSleeper(subprocess: FakeSubprocessRunner(), sleepCall: { 0 }, retryDelay: .zero,
                                        spawnDetached: { argv in spawned.update { $0.append(argv) } })
        try sleeper.scheduleDetachedSleep(after: .seconds(90))
        #expect(spawned.value == [IOPMSystemSleeper.detachedSleepArgv(after: .seconds(90))])
    }

    @Test func theControllerHandsTheDetachedSleepToTheGatedSleeper() throws {
        let off = try ControllerRig(gateOn: false)
        try off.controller.scheduleDetachedSleep(after: .seconds(120))
        #expect(off.sleeper.scheduledDelays == [.seconds(120)])

        let on = try ControllerRig(gateOn: true)
        try on.controller.scheduleDetachedSleep(after: .seconds(120))
        #expect(on.sleeper.scheduledDelays.isEmpty)
        #expect(on.ledgerCount("power.scheduleSleep") == 1)
    }
}
