@testable import KakurenekoPower
import KakurenekoKit
import Foundation
import IOKit
import Synchronization
import Testing

/// The REAL side-effect types, exercised only through `FakeSubprocessRunner` and injected seams: nothing here calls
/// sudo, pmset, `IOPMSleepSystem`, an Apple Event or an admin prompt.
@Suite("Real side effects (fakes only)", .timeLimit(.minutes(1)))
struct RealSideEffectsTests {
    @Test func sudoRunnerBuildsTheByteExactArgv() async throws {
        let fake = FakeSubprocessRunner()
        let runner = SudoPrivilegedCommandRunner(subprocess: fake)
        _ = try await runner.run(.setSleepDisabled(true))
        _ = try await runner.run(.setSleepDisabled(false))
        _ = try await runner.run(.checkSudoRule)
        let requests = fake.requests
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.executable == "/usr/bin/sudo" })
        #expect(requests[0].arguments == ["-n", "/usr/bin/pmset", "-a", "disablesleep", "1"])
        #expect(requests[1].arguments == ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"])
        #expect(requests[2].arguments == ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"])
        #expect(requests[0].effect == .mutating)
        #expect(requests[1].effect == .mutating)
        #expect(requests[2].effect == .readOnly)
        #expect(requests.allSatisfy { $0.stdin == nil }, "sudo -n never gets a password on stdin")
        // The argv is exactly what the sudoers rule allows.
        let rule = PrivilegedScriptGenerator.sudoersRule(user: "tester")
        for request in requests.prefix(2) {
            #expect(rule.contains(request.arguments.dropFirst().joined(separator: " ")))
        }
    }

    @Test func sudoRunnerPassesFailuresThrough() async throws {
        let fake = FakeSubprocessRunner { _ in SubprocessResult(exitCode: 1, stderr: Data("sudo: a password is required".utf8)) }
        let result = try await SudoPrivilegedCommandRunner(subprocess: fake).run(.checkSudoRule)
        #expect(result.exitCode == 1)
        #expect(result.stderrString == "sudo: a password is required")
    }

    @Test func systemSleeperSucceedsWithoutFallback() async throws {
        let calls = Locked(0)
        let fake = FakeSubprocessRunner()
        let sleeper = IOPMSystemSleeper(subprocess: fake, sleepCall: { calls.update { $0 += 1 }; return IOKitReturn.success },
                                        retryDelay: .zero)
        try await sleeper.sleepNow()
        #expect(calls.value == 1)
        #expect(fake.requests.isEmpty)
    }

    @Test func systemSleeperRetriesOnceOnNotPermitted() async throws {
        let results = Locked<[IOReturn]>([IOKitReturn.notPermitted, IOKitReturn.success])
        let fake = FakeSubprocessRunner()
        let sleeper = IOPMSystemSleeper(subprocess: fake, sleepCall: {
            var next = IOKitReturn.success
            results.update { next = $0.removeFirst() }
            return next
        }, retryDelay: .zero)
        try await sleeper.sleepNow()
        #expect(results.value.isEmpty)
        #expect(fake.requests.isEmpty)
    }

    @Test func systemSleeperFallsBackToPmsetSleepnow() async throws {
        let calls = Locked(0)
        let fake = FakeSubprocessRunner()
        let sleeper = IOPMSystemSleeper(subprocess: fake, sleepCall: { calls.update { $0 += 1 }; return IOKitReturn.notPermitted },
                                        retryDelay: .zero)
        try await sleeper.sleepNow()
        #expect(calls.value == 2, "one retry, then the fallback")
        let request = try #require(fake.requests.first)
        #expect(fake.requests.count == 1)
        #expect(request.executable == "/usr/bin/pmset")
        #expect(request.arguments == ["sleepnow"])
        #expect(request.effect == .mutating)
    }

    @Test func systemSleeperReportsAFailedFallback() async throws {
        let fake = FakeSubprocessRunner { _ in SubprocessResult(exitCode: 1, stderr: Data("Sleep blocked".utf8)) }
        let sleeper = IOPMSystemSleeper(subprocess: fake, sleepCall: { IOKitReturn.notPrivileged }, retryDelay: .zero)
        do {
            try await sleeper.sleepNow()
            Issue.record("expected a failure")
        } catch let error as SideEffectError {
            guard case .commandFailed(let code, let stderr) = error else { Issue.record("unexpected \(error)"); return }
            #expect(code == 1)
            #expect(stderr.contains("0xE00002C1"))
            #expect(stderr.contains("Sleep blocked"))
        }
        // kIOReturnNotPrivileged is not retried.
        #expect(fake.requests.count == 1)
    }

    @Test func displaySleeperRunsPmsetDisplaysleepnow() async throws {
        let fake = FakeSubprocessRunner()
        try await PmsetDisplaySleeper(subprocess: fake).displaySleepNow()
        let request = try #require(fake.requests.first)
        #expect(request.executable == "/usr/bin/pmset")
        #expect(request.arguments == ["displaysleepnow"])
        #expect(request.effect == .mutating)

        let failing = FakeSubprocessRunner { _ in SubprocessResult(exitCode: 2, stderr: Data("nope\n".utf8)) }
        await #expect(throws: SideEffectError.commandFailed(exitCode: 2, stderr: "nope")) {
            try await PmsetDisplaySleeper(subprocess: failing).displaySleepNow()
        }
    }

    /// The script travels INLINE (`bash -c <text>`): root never executes a file a same-user process could rewrite.
    @Test func administratorAppleScriptRunsTheScriptInlineAndQuotesEveryArgument() {
        let source = AppleScriptAdministratorRunner.appleScriptSource(
            script: "echo hi\nexit 0\n", name: "install-privileged.sh",
            arguments: ["tester", "/Users/tester/.kakureneko/run/heartbeat"])
        #expect(source == "do shell script \"/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash --noprofile --norc -c \" & quoted form of \"echo hi\nexit 0\n\" & \" \" & quoted form of \"install-privileged.sh\" & \" \" & quoted form of \"tester\" & \" \" & quoted form of \"/Users/tester/.kakureneko/run/heartbeat\" with administrator privileges")
        #expect(!source.contains("Application Support"))
        let tricky = AppleScriptAdministratorRunner.appleScriptSource(script: #"echo "b" \c"#, name: "x", arguments: [])
        #expect(tricky == #"do shell script "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash --noprofile --norc -c " & quoted form of "echo \"b\" \\c" & " " & quoted form of "x" with administrator privileges"#)
    }

    @Test func administratorErrorsAreMapped() {
        let cancelled = AppleScriptAdministratorRunner.map([NSAppleScript.errorNumber: NSNumber(value: -128),
                                                            NSAppleScript.errorMessage: "User canceled."] as NSDictionary)
        #expect(cancelled == .notPermitted("administrator prompt cancelled"))
        let failed = AppleScriptAdministratorRunner.map([NSAppleScript.errorNumber: NSNumber(value: 3),
                                                         NSAppleScript.errorMessage: "bad heartbeat path"] as NSDictionary)
        #expect(failed == .failed("administrator script failed (3): bad heartbeat path"))
    }

    @Test func shutdownErrorsAreMapped() {
        let denied = LoginWindowShutdownRequester.map(NSError(domain: NSOSStatusErrorDomain, code: -1743))
        #expect(denied == .notPermitted("Automation permission for loginwindow is missing (-1743)"))
        let consent = LoginWindowShutdownRequester.map(NSError(domain: NSOSStatusErrorDomain, code: -1744))
        guard case .notPermitted = consent else { Issue.record("expected notPermitted"); return }
        let other = LoginWindowShutdownRequester.map(NSError(domain: NSOSStatusErrorDomain, code: -600))
        guard case .failed(let message) = other else { Issue.record("expected failed"); return }
        #expect(message.contains("-600"))
    }

    @Test func handDefinedIOKitConstants() {
        #expect(IOKitMessage.clamshellStateChange == 0xE003_4100)
        #expect(IOKitMessage.canSystemSleep == 0xE000_0270)
        #expect(IOKitMessage.systemWillSleep == 0xE000_0280)
        #expect(IOKitMessage.systemWillNotSleep == 0xE000_0290)
        #expect(IOKitMessage.systemHasPoweredOn == 0xE000_0300)
        #expect(IOKitMessage.systemWillPowerOn == 0xE000_0320)
        #expect(IOKitMessage.clamshellStateBit == 1)
        #expect(UInt32(bitPattern: IOKitReturn.notPermitted) == 0xE000_02E2)
        #expect(IOKitReturn.describe(IOKitReturn.notPermitted) == "0xE00002E2")
        // iokit_family_msg(sub_iokit_powermanagement, 0x100) = (0x38 << 26) | (13 << 14) | 0x100
        #expect(IOKitMessage.clamshellStateChange == (0x38 << 26) | (13 << 14) | 0x100)
        #expect(AppleEventCode.coreEventClass == 0x6165_7674) // 'aevt'
        #expect(AppleEventCode.shutDown == 0x7368_7574)       // 'shut'
    }

    @Test func realTypesExistWithTheBindingInitializers() {
        let fake = FakeSubprocessRunner()
        let _: any PrivilegedCommandRunning = SudoPrivilegedCommandRunner(subprocess: fake)
        let _: any SystemSleeping = IOPMSystemSleeper(subprocess: fake)
        let _: any ShutdownRequesting = LoginWindowShutdownRequester()
        let _: any DisplaySleeping = PmsetDisplaySleeper(subprocess: fake)
        let _: any AdministratorScriptRunning = AppleScriptAdministratorRunner()
        #expect(fake.requests.isEmpty, "constructing never runs anything")
    }
}
