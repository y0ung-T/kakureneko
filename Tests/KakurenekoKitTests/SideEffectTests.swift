import KakurenekoCloud
import KakurenekoKit
import Foundation
import Synchronization
import Testing

/// Records calls; stands in for a "real" implementation behind the dry-run switches.
private final class CountingSleeper: SystemSleeping {
    let count = Mutex(0)
    func sleepNow() async throws { count.withLock { $0 += 1 } }
    let scheduled = Mutex<[Duration]>([])
    func scheduleDetachedSleep(after delay: Duration) throws { scheduled.withLock { $0.append(delay) } }
}

private final class CountingPrivileged: PrivilegedCommandRunning {
    let commands = Mutex<[PrivilegedCommand]>([])
    func run(_ command: PrivilegedCommand) async throws -> SubprocessResult {
        commands.withLock { $0.append(command) }
        return SubprocessResult(exitCode: 0)
    }
}

@Suite("Side effects and dry-run", .timeLimit(.minutes(1)))
struct SideEffectTests {
    @Test func dryRunPolicyFromEnvironment() {
        #expect(DryRunPolicy.fromEnvironment(["KAKURENEKO_DRY_RUN": "1"]).isEnabled)
        #expect(DryRunPolicy.fromEnvironment(["KAKURENEKO_DRY_RUN": "TRUE"]).isEnabled)
        #expect(!DryRunPolicy.fromEnvironment(["KAKURENEKO_DRY_RUN": "0"]).isEnabled)
        #expect(!DryRunPolicy.fromEnvironment([:]).isEnabled)
    }

    @Test func gateForcedByEnvironmentCannotBeTurnedOff() {
        let forced = DryRunGate(policy: .on)
        forced.setRequested(false)
        #expect(forced.isOn && forced.isForcedByEnvironment)
        let soft = DryRunGate(policy: .off)
        #expect(!soft.isOn)
        soft.setRequested(true)
        #expect(soft.isOn && !soft.isForcedByEnvironment)
        soft.setRequested(false)
        #expect(!soft.isOn)
    }

    @Test func switchingForwardsOnlyWhenGateIsOff() async throws {
        let ledger = DryRunLedger(clock: TestClock())
        let gate = DryRunGate(policy: .off)
        let real = CountingSleeper()
        let sleeper = DryRunSystemSleeper(passthrough: real, gate: gate, ledger: ledger)
        try await sleeper.sleepNow()
        #expect(real.count.withLock { $0 } == 1)
        #expect(ledger.entries.isEmpty)
        gate.setRequested(true)
        try await sleeper.sleepNow()
        #expect(real.count.withLock { $0 } == 1)
        #expect(ledger.entries(action: "power.sleep").count == 1)
    }

    @Test func privilegedHealthCheckPassesThroughInDryRun() async throws {
        let ledger = DryRunLedger()
        let real = CountingPrivileged()
        let runner = DryRunPrivilegedCommandRunner(passthrough: real, gate: .alwaysOn(), ledger: ledger)
        _ = try await runner.run(.checkSudoRule)
        _ = try await runner.run(.setSleepDisabled(true))
        #expect(real.commands.withLock { $0 } == [.checkSudoRule])
        let arm = ledger.entries(action: "power.arm")
        #expect(arm.count == 1)
        #expect(arm[0].detail == "would run /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 1")
        #expect(PrivilegedCommand.setSleepDisabled(false).argv == ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "0"])
    }

    @Test func cloudDryRunBlocksWritesButAllowsReads() async throws {
        let ledger = DryRunLedger()
        let cloud = InMemoryCloudStore(zoneExists: true)
        let alert = CloudAlert(macID: "m", macName: "Mac", kind: "test", title: "t", body: "b", threadID: "t",
                               createdAt: Date(), expiresAt: Date())
        try await cloud.save([.alert(alert)])
        let gated = DryRunCloudStore(passthrough: cloud, gate: .alwaysOn(), ledger: ledger)
        try await gated.prepare()
        try await gated.save([.alert(alert), .alert(alert)])
        try await gated.delete([CloudItem.alert(alert).id])
        try await gated.saveSubscription(.macInbox)
        #expect(await cloud.allItems.count == 1, "nothing written or deleted for real")
        #expect(await cloud.subscriptions.isEmpty)
        #expect(ledger.entries.map(\.action) == ["cloud.prepare", "cloud.save", "cloud.delete", "cloud.subscribe"])
        #expect(ledger.entries(action: "cloud.save").first?.detail == "would save 2 iCloud record(s) (Alert, Alert)")
        #expect(try await gated.fetchChanges(since: nil).items.count == 1, "reads pass through")
        #expect(await gated.accountStatus() == .available)
        // Off: everything passes through.
        let open = DryRunCloudStore(passthrough: cloud, gate: .off(), ledger: ledger)
        try await open.delete([CloudItem.alert(alert).id])
        #expect(await cloud.allItems.isEmpty)
        // Without a real store (no iCloud entitlement) reads report the build.
        #expect(await DryRunCloudStore(gate: .alwaysOn(), ledger: ledger).accountStatus() == .unavailableInThisBuild)
    }

    @Test func localNotificationDryRunLogsPostsAndPrompts() async throws {
        let ledger = DryRunLedger()
        let real = RecordingLocalNotifications(authorization: .notDetermined)
        let gated = DryRunLocalNotificationPoster(passthrough: real, gate: .alwaysOn(), ledger: ledger)
        let alert = CloudAlert(macID: "m", macName: "Mac", kind: "test", title: "Hello", body: "secret body", threadID: "t",
                               createdAt: Date(), expiresAt: Date())
        try await gated.post(alert)
        #expect(await gated.requestAuthorization() == .notDetermined)
        await gated.registerCategories(keepAwakeSeconds: 600)
        #expect(real.posted.isEmpty && real.authorizationRequests == 0)
        #expect(real.categoryRegistrations == [600], "registering categories is harmless and passes through")
        #expect(ledger.entries.map(\.action) == ["notify.post", "notify.authorize"])
        #expect(ledger.entries.first?.detail == "would show the notification \"Hello\"")
        #expect(!(ledger.entries.first?.detail.contains("secret") ?? true), "bodies are never logged")
        #expect(await DryRunLocalNotificationPoster(gate: .alwaysOn(), ledger: ledger).authorization().0 == .unavailable)
        #expect(await UnavailableLocalNotifications().requestAuthorization() == .unavailable)
    }

    @Test func subprocessDryRunBlocksOnlyMutating() async throws {
        let ledger = DryRunLedger()
        let fake = FakeSubprocessRunner { request in
            SubprocessResult(exitCode: 0, stdout: Data(request.arguments.joined(separator: " ").utf8))
        }
        let runner = DryRunSubprocessRunner(passthrough: fake, gate: .alwaysOn(), ledger: ledger)
        let list = try await runner.run(SubprocessRequest(executable: "/x/claude", arguments: ["plugin", "list", "--json"], effect: .readOnly))
        #expect(list.stdoutString == "plugin list --json")
        let install = try await runner.run(SubprocessRequest(executable: "/x/claude", arguments: ["plugin", "install", "kakureneko@kakureneko-local"], effect: .mutating))
        #expect(install.succeeded && install.stdout.isEmpty)
        #expect(fake.requests.count == 1)
        #expect(ledger.entries(action: "subprocess.run").first?.detail == "would run /x/claude plugin install kakureneko@kakureneko-local")
    }

    @Test func pureDryRunSideEffectsNeverAct() async throws {
        let ledger = DryRunLedger()
        let effects = SideEffects.inert(ledger: ledger)
        try await effects.systemSleep.sleepNow()
        try await effects.shutdown.requestShutdown()
        try await effects.displaySleep.displaySleepNow()
        let bare = ProcessIdentity(pid: 123, startSec: 1, startUsec: 2)
        #expect(throws: SideEffectError.identityMismatch) { try effects.signaller.send(.stop, to: bare) }
        #expect(throws: SideEffectError.identityMismatch) { try effects.signaller.setDarwinBackground(true, for: bare) }
        let target = ProcessIdentity(pid: 123, startSec: 1, startUsec: 2, uniqueID: 9, pidVersion: 4) // enriched
        try effects.signaller.send(.stop, to: target)
        try effects.signaller.setDarwinBackground(true, for: target)
        try await effects.signaller.terminateApplication(target)
        _ = try await effects.administrator.runAsAdministrator(script: "exit 0", name: "install-privileged.sh", arguments: ["u"])
        let actions = ledger.entries.map(\.action)
        #expect(actions == ["power.sleep", "power.shutdown", "power.displaySleep", "signal.stop", "priority.background", "app.terminate", "admin.script"])
        #expect(ledger.entries(action: "priority.background").first?.detail == "would throttle pid 123")
    }

    @Test func ledgerIsBounded() {
        let ledger = DryRunLedger(capacity: 3)
        for i in 0..<5 { ledger.record(.app, action: "a", detail: "\(i)") }
        #expect(ledger.entries.map(\.detail) == ["2", "3", "4"])
    }

    @Test func recordingLocalNotificationsRecordAndTap() async throws {
        let local = RecordingLocalNotifications(authorization: .notDetermined)
        #expect(await local.requestAuthorization() == .authorized)
        #expect(local.authorizationRequests == 1)
        var iterator = local.buttonTaps().makeAsyncIterator()
        local.tap(AlertPresentation.ButtonTap(request: .sleepNow, alertID: "a", macID: "m", stateVersion: 1, expiresAt: nil))
        #expect(await iterator.next()?.request == .sleepNow)
        local.setPostError(CocoaError(.featureUnsupported))
        let alert = CloudAlert(macID: "m", macName: "Mac", kind: "test", title: "t", body: "b", threadID: "t",
                               createdAt: Date(), expiresAt: Date())
        await #expect(throws: CocoaError.self) { try await local.post(alert) }
        #expect(local.posted.isEmpty)
    }
}

@Suite("FoundationSubprocessRunner (spawns only its own children)", .timeLimit(.minutes(1)))
struct SubprocessRunnerTests {
    @Test func capturesStdoutAndExitCode() async throws {
        let runner = FoundationSubprocessRunner()
        let ok = try await runner.run(SubprocessRequest(executable: "/bin/echo", arguments: ["hello", "world"], effect: .readOnly))
        #expect(ok.succeeded)
        #expect(ok.stdoutString == "hello world\n")
        let fail = try await runner.run(SubprocessRequest(executable: "/usr/bin/false", effect: .readOnly))
        #expect(fail.exitCode == 1 && !fail.succeeded)
    }

    @Test func passesStdinAndEnvironment() async throws {
        let runner = FoundationSubprocessRunner()
        let cat = try await runner.run(SubprocessRequest(executable: "/bin/cat", stdin: Data("piped".utf8), effect: .readOnly))
        #expect(cat.stdoutString == "piped")
        let env = try await runner.run(SubprocessRequest(executable: "/bin/sh", arguments: ["-c", "printf %s \"$KAKURENEKO_TEST_VAR\""],
                                                         environment: [:], extraEnvironment: ["KAKURENEKO_TEST_VAR": "42"], effect: .readOnly))
        #expect(env.stdoutString == "42")
        // stdin defaults to /dev/null: cat terminates immediately.
        let empty = try await runner.run(SubprocessRequest(executable: "/bin/cat", timeout: .seconds(5), effect: .readOnly))
        #expect(empty.succeeded && empty.stdout.isEmpty)
    }

    @Test func enforcesTimeout() async throws {
        let runner = FoundationSubprocessRunner()
        let started = ContinuousClock.now
        let slow = try await runner.run(SubprocessRequest(executable: "/bin/sleep", arguments: ["30"], timeout: .milliseconds(300), effect: .readOnly))
        #expect(slow.timedOut)
        #expect(!slow.succeeded)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func missingExecutableThrows() async {
        let runner = FoundationSubprocessRunner()
        await #expect(throws: SideEffectError.self) {
            _ = try await runner.run(SubprocessRequest(executable: "/nonexistent/binary", effect: .readOnly))
        }
    }
}

@Suite("FoundationSubprocessRunner stdin robustness", .timeLimit(.minutes(1)))
struct SubprocessStdinTests {
    /// A child that never reads stdin must not SIGPIPE the test process (regression).
    @Test func childIgnoringStdinDoesNotKillParent() async throws {
        let runner = FoundationSubprocessRunner()
        let big = Data(repeating: 0x41, count: 1 << 20)
        for _ in 0..<5 {
            let r = try await runner.run(SubprocessRequest(executable: "/usr/bin/true", stdin: big, timeout: .seconds(5), effect: .readOnly))
            #expect(r.exitCode == 0)
        }
    }
}
