import Darwin
import KakurenekoKit
@testable import KakurenekoPause
import Foundation
import Testing

/// `kakureneko-guard` argument parsing and pipe protocol (pure).
@Suite("kakureneko-guard protocol", .timeLimit(.minutes(1)))
struct GuardProtocolTests {
    typealias Options = PauseGuard.Options

    @Test func parsesTheWatchContract() throws {
        let options = try Options.parse(["--watch", "123", "--journal", "/j/paused.json", "--log", "/l/guard.log",
                                         "--pipe-fd", "5", "--dry-run", "--hang-timeout-ms", "250"]).get()
        #expect(options.command == .watch(123))
        #expect(options.journal.path(percentEncoded: false) == "/j/paused.json")
        #expect(options.log?.path(percentEncoded: false) == "/l/guard.log")
        #expect(options.pipeFD == 5)
        #expect(options.dryRun)
        #expect(options.hangTimeout == .milliseconds(250))

        let defaults = try Options.parse(["--watch", "9", "--journal", "/j"]).get()
        #expect(defaults.hangTimeout == .seconds(90) && defaults.pipeFD == nil && !defaults.dryRun && defaults.log == nil)
    }

    @Test func parsesRecoverAndCrashSelfTest() throws {
        let recover = try Options.parse(["--recover", "--journal", "/j", "--log", "/l"]).get()
        #expect(recover.command == .recover)
        let crash = try Options.parse(["--crash-selftest", "--pid", "77", "--pid", "78", "--signal", "SEGV"]).get()
        #expect(crash.command == .crashSelfTest(pids: [77, 78], signal: "segv"))
        let defaultSignal = try Options.parse(["--crash-selftest"]).get()
        #expect(defaultSignal.command == .crashSelfTest(pids: [], signal: "abrt"))
    }

    @Test func rejectsBadArgumentsButKeepsTheLogPath() {
        let bad: [[String]] = [
            ["--watch", "5"],                         // no journal
            ["--journal", "/j"],                      // neither watch nor recover
            ["--watch", "1", "--journal", "/j"],      // launchd is never watched
            ["--watch", "abc", "--journal", "/j"],
            ["--watch", "5", "--journal", "relative"],
            ["--watch", "5", "--journal", "/j", "--pipe-fd", "-1"],
            ["--watch", "5", "--journal", "/j", "--hang-timeout-ms", "0"],
            ["--crash-selftest", "--pid", "1"],
            ["--watch"],
        ]
        for arguments in bad {
            guard case .failure = Options.parse(arguments) else {
                Issue.record("accepted \(arguments)")
                continue
            }
        }
        guard case .failure(let failure) = Options.parse(["--log", "/l/guard.log", "--bogus"]) else {
            Issue.record("accepted --bogus")
            return
        }
        #expect(failure.log?.path(percentEncoded: false) == "/l/guard.log", "errors are still logged to --log")
    }

    @Test func lineBufferRecognisesHeartbeatAndBye() {
        var buffer = PauseGuard.LineBuffer()
        #expect(buffer.feed(Array("h".utf8)) == .quiet)
        #expect(buffer.feed(Array("b\n".utf8)) == .heartbeat)
        #expect(buffer.feed(Array(" hb \nhb\n".utf8)) == .heartbeat)
        #expect(buffer.feed(Array("hb\nbye\nhb\n".utf8)) == .bye)
        var garbage = PauseGuard.LineBuffer()
        #expect(garbage.feed([UInt8](repeating: 0x41, count: 5000)) == .quiet)
        #expect(garbage.feed(Array("hb\n".utf8)) == .heartbeat, "garbage without newlines is discarded")
        #expect(garbage.feed(Array("noise\n".utf8)) == .quiet)
    }

    @Test func drainReadsANonBlockingPipe() async throws {
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        defer { close(fds[0]) }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)
        var buffer = PauseGuard.LineBuffer()
        #expect(PauseGuard.drain(fds[0], into: &buffer) == .quiet)
        #expect(GuardLauncher.write(GuardLauncher.heartbeatLine, to: fds[1]))
        #expect(PauseGuard.drain(fds[0], into: &buffer) == .heartbeat)
        #expect(GuardLauncher.write(GuardLauncher.byeLine, to: fds[1]))
        #expect(PauseGuard.drain(fds[0], into: &buffer) == .bye)
        close(fds[1])
        // EOF once no other process holds the write end: a posix_spawn running concurrently on another thread (a
        // parallel test) gives its child a copy of the fd table that keeps the write end open until its exec has
        // closed the close-on-exec descriptors.
        #expect(await eventually(timeout: 10) { PauseGuard.drain(fds[0], into: &buffer) == .closed })
    }
}

/// The real `kakureneko-guard` binary, spawned with `paths.helperEnvironment` + `--log <temp>`. Every process it may
/// signal is a `/bin/sleep` child of this test.
@Suite("kakureneko-guard (spawned)", .timeLimit(.minutes(1)))
struct GuardIntegrationTests {
    /// A watched "app" (alive until the test kills it), a really SIGSTOPped "paused app", and a temp home.
    struct Fixture {
        let home: TempHome
        let watched: SpawnedChild
        let frozen: SpawnedChild

        init() async throws {
            home = try TempHome()
            watched = try SpawnedChild.sleep()
            frozen = try SpawnedChild.sleep()
            await frozen.stop()
        }

        func cleanup() {
            watched.terminate()
            frozen.terminate()
            home.remove()
        }

        var journalExists: Bool { FileManager.default.fileExists(atPath: home.journalPath) }
        var journal: PauseJournal? { PauseJournal.read(from: home.journalURL) }

        static func app(_ child: SpawnedChild, simulated: Bool = false, tweak: (inout PauseJournalRecord) -> Void = { _ in }) throws -> PauseJournalApp {
            var record = try #require(PauseJournalRecord(identity: try child.enriched, path: "/bin/sleep", action: .sigstop))
            tweak(&record)
            return PauseJournalApp(bundleID: "test.sleep", name: "Sleep \(child.pid)", appPid: child.pid, mode: .freeze,
                                   members: [record], simulated: simulated)
        }

        /// Journals `frozen` (plus `extra`) as SIGSTOPped by the watched app, under the CURRENT boot unless told otherwise.
        func writeJournal(boot: String? = nil, extra: [PauseJournalApp] = [],
                          tweak: (inout PauseJournalRecord) -> Void = { _ in }) throws {
            let bootUUID = try boot ?? #require(Kernel.bootSessionUUID())
            try PauseJournal(bootSessionUUID: bootUUID, kakurenekoPid: watched.pid, startedAt: Date(),
                             apps: [try Self.app(frozen, tweak: tweak)] + extra).write(to: home.journalURL)
        }

        func guardArguments(_ extra: [String]) -> [String] {
            ["--journal", home.journalPath, "--log", home.logPath] + extra
        }

        /// `kakureneko-guard <arguments>` without a pipe (posix_spawn, own session, /dev/null stdio).
        func spawnGuard(_ arguments: [String]) throws -> SpawnedChild {
            let path = Products.guardExecutable.path(percentEncoded: false)
            let pid = try GuardLauncher.spawnProcess(path: path, arguments: [path] + arguments, environment: home.paths.helperEnvironment)
            return SpawnedChild(pid: pid)
        }

        /// `kakureneko-guard --watch <watched> … --pipe-fd <fd>` exactly as `PauseManager.startGuard()` spawns it.
        func spawnPipedGuard(extra: [String] = []) throws -> GuardProcess {
            try GuardLauncher.spawn(executable: Products.guardExecutable, watchPID: watched.pid, journal: home.journalURL,
                                    log: home.paths.guardLogFile, environment: home.paths.helperEnvironment,
                                    extraArguments: extra)
        }

        func runOnce(_ arguments: [String]) async throws -> Int32 {
            let result = try await FoundationSubprocessRunner().run(SubprocessRequest(
                executable: Products.guardExecutable.path(percentEncoded: false), arguments: arguments,
                environment: home.paths.helperEnvironment, timeout: .seconds(5), effect: .readOnly))
            return result.exitCode
        }

        func waitUntilWatching() async -> Bool { await eventually { home.log.contains("watching pid") } }
    }

    @Test func watchedAppExitThawsTheJournalAndExits() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        try f.writeJournal()
        let guardian = try f.spawnGuard(f.guardArguments(["--watch", String(f.watched.pid)]))
        defer { guardian.terminate() }
        #expect(await f.waitUntilWatching())
        #expect(f.frozen.isStopped)

        f.watched.terminate() // the app dies (SIGKILL): kqueue NOTE_EXIT
        let status = try #require(await guardian.waitForExit(timeout: 10))
        #expect(WaitStatus.exitCode(status) == 0)
        #expect(!f.frozen.isStopped, "SIGCONT via audit token")
        #expect(!f.journalExists, "journal cleared")
        #expect(f.home.log.contains("recovering"))
    }

    @Test func pipeEOFWithoutByeMeansTheAppIsGone() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        try f.writeJournal()
        let guardian = try f.spawnPipedGuard()
        let child = SpawnedChild(pid: guardian.pid)
        defer { child.terminate() }
        #expect(await f.waitUntilWatching())
        close(guardian.writeFD) // e.g. the app was SIGKILLed (its fds close before NOTE_EXIT), or it closed by mistake
        let status = try #require(await child.waitForExit(timeout: 10))
        #expect(WaitStatus.exitCode(status) == 0)
        #expect(!f.frozen.isStopped)
        #expect(!f.journalExists)
    }

    @Test func byeExitsWithoutRecovery() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        try f.writeJournal()
        let guardian = try f.spawnPipedGuard()
        let child = SpawnedChild(pid: guardian.pid)
        defer { child.terminate() }
        #expect(await f.waitUntilWatching())
        #expect(GuardLauncher.write(GuardLauncher.heartbeatLine, to: guardian.writeFD))
        #expect(GuardLauncher.write(GuardLauncher.byeLine, to: guardian.writeFD))
        close(guardian.writeFD)
        let status = try #require(await child.waitForExit(timeout: 10))
        #expect(WaitStatus.exitCode(status) == 0)
        #expect(f.frozen.isStopped, "bye = intentional stop: nothing thawed")
        #expect(f.journalExists)
        #expect(f.home.log.contains("bye received"))
    }

    @Test func hangThawsVerifiedRecordsAndKeepsWatching() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let simulated = try SpawnedChild.sleep()
        defer { simulated.terminate() }
        await simulated.stop()
        try f.writeJournal(extra: [try Fixture.app(simulated, simulated: true)])
        let guardian = try f.spawnPipedGuard(extra: ["--hang-timeout-ms", "300"])
        let child = SpawnedChild(pid: guardian.pid)
        defer { child.terminate() }

        #expect(await eventually(timeout: 10) { !f.frozen.isStopped }, "no hb for 300 ms → hang → thaw")
        #expect(child.hasNotExited, "keeps watching after a hang")
        #expect(simulated.isStopped, "simulated (dry-run) apps are never signalled")
        #expect(await eventually { f.journal?.apps.map(\.appPid) == [simulated.pid] }, "journal rewritten without the thawed record")
        #expect(f.home.log.contains("hangs"))

        #expect(GuardLauncher.write(GuardLauncher.byeLine, to: guardian.writeFD))
        close(guardian.writeFD)
        let status = try #require(await child.waitForExit(timeout: 10))
        #expect(WaitStatus.exitCode(status) == 0)
    }

    @Test func hangThatThawsEverythingLeavesAnEmptyJournal() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        try f.writeJournal()
        let guardian = try f.spawnPipedGuard(extra: ["--hang-timeout-ms", "200"])
        let child = SpawnedChild(pid: guardian.pid)
        defer { child.terminate() }
        #expect(await eventually(timeout: 10) { !f.frozen.isStopped })
        // The app (still alive, merely slow) re-reads the journal: an EMPTY journal tells it everything was thawed.
        #expect(await eventually { f.journal.map { $0.apps.isEmpty } == true })
        #expect(child.hasNotExited)
        close(guardian.writeFD) // EOF without bye now: recovery of an empty journal, then exit
        #expect(await child.waitForExit(timeout: 10) != nil)
    }

    @Test func heartbeatsPreventAHangVerdict() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        try f.writeJournal()
        // A generous timeout: a loaded machine (the whole suite runs in parallel) must not starve a 50 ms beat that long.
        let guardian = try f.spawnPipedGuard(extra: ["--hang-timeout-ms", "1500"])
        let child = SpawnedChild(pid: guardian.pid)
        defer { child.terminate() }
        let writer = HeartbeatWriter(fd: guardian.writeFD, intervalMilliseconds: 50)
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(300)) } // twice the 1.5 s timeout
        #expect(await writer.stop())
        #expect(f.frozen.isStopped, "regular heartbeats: no hang")
        #expect(f.home.log.contains("first heartbeat received"))
        #expect(!f.home.log.contains("hangs"))
        #expect(GuardLauncher.write(GuardLauncher.byeLine, to: guardian.writeFD))
        close(guardian.writeFD)
        #expect(await child.waitForExit(timeout: 10) != nil)
        #expect(f.frozen.isStopped)
    }

    @Test func hangIsIgnoredWhileTheJournalIsEmpty() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let guardian = try f.spawnPipedGuard(extra: ["--hang-timeout-ms", "150"])
        let child = SpawnedChild(pid: guardian.pid)
        defer { child.terminate() }
        #expect(await f.waitUntilWatching())
        try await Task.sleep(for: .milliseconds(450))
        #expect(child.hasNotExited)
        #expect(!f.home.log.contains("hangs"))
        // A journal written now (the app paused after a long quiet period) is thawed on the next missed beat.
        try f.writeJournal()
        #expect(await eventually(timeout: 10) { !f.frozen.isStopped })
        #expect(GuardLauncher.write(GuardLauncher.byeLine, to: guardian.writeFD))
        close(guardian.writeFD)
        #expect(await child.waitForExit(timeout: 10) != nil)
    }

    @Test func oneShotRecover() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        try f.writeJournal()
        #expect(try await f.runOnce(f.guardArguments(["--recover"])) == 0)
        #expect(!f.frozen.isStopped)
        #expect(!f.journalExists)
        #expect(try await f.runOnce(f.guardArguments(["--recover"])) == 0, "missing journal: nothing to do")
    }

    @Test func recoverDropsUnverifiableRecordsWithoutSignalling() async throws {
        let wrongBoot = try await Fixture()
        defer { wrongBoot.cleanup() }
        try wrongBoot.writeJournal(boot: "00000000-0000-0000-0000-000000000000")
        #expect(try await wrongBoot.runOnce(wrongBoot.guardArguments(["--recover"])) == 0)
        #expect(wrongBoot.frozen.isStopped, "another boot's record is dropped, never thawed")
        #expect(!wrongBoot.journalExists)

        let wrongVersion = try await Fixture()
        defer { wrongVersion.cleanup() }
        try wrongVersion.writeJournal { $0.pidVersion &+= 1 }
        #expect(try await wrongVersion.runOnce(wrongVersion.guardArguments(["--recover"])) == 0)
        #expect(wrongVersion.frozen.isStopped, "audit-token pidversion mismatch: dropped")

        let wrongStart = try await Fixture()
        defer { wrongStart.cleanup() }
        try wrongStart.writeJournal { $0.startSec -= 1 }
        #expect(try await wrongStart.runOnce(wrongStart.guardArguments(["--recover"])) == 0)
        #expect(wrongStart.frozen.isStopped, "start time mismatch (pid reuse): dropped")
    }

    @Test func dryRunSignalsNothing() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        try f.writeJournal()
        let before = try Data(contentsOf: f.home.journalURL)
        #expect(try await f.runOnce(f.guardArguments(["--recover", "--dry-run"])) == 0)
        #expect(f.frozen.isStopped)
        #expect(try Data(contentsOf: f.home.journalURL) == before, "journal left unchanged")
        #expect(f.home.log.contains("dry-run: would SIGCONT pid \(f.frozen.pid)"))

        let guardian = try f.spawnGuard(f.guardArguments(["--watch", String(f.watched.pid), "--dry-run"]))
        defer { guardian.terminate() }
        #expect(await f.waitUntilWatching())
        f.watched.terminate()
        #expect(await guardian.waitForExit(timeout: 10) != nil)
        #expect(f.frozen.isStopped)
        #expect(try Data(contentsOf: f.home.journalURL) == before)
    }

    @Test func alreadyGoneAppIsRecoveredImmediately() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        try f.writeJournal()
        let gone = try SpawnedChild.sleep()
        gone.terminate()
        #expect(try await f.runOnce(f.guardArguments(["--watch", String(gone.pid)])) == 0)
        #expect(!f.frozen.isStopped)
    }

    // MARK: Crash handler (exercised ONLY in this separate process)

    @Test(arguments: [("abrt", SIGABRT), ("fault", SIGSEGV)])
    func crashHandlerContinuesPublishedPidsAndReRaises(_ name: String, _ expected: Int32) async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let crasher = try f.spawnGuard(["--crash-selftest", "--pid", String(f.frozen.pid), "--signal", name, "--log", f.home.logPath])
        defer { crasher.terminate() }
        let status = try #require(await crasher.waitForExit(timeout: 10))
        let signal = try #require(WaitStatus.signal(status), "died by a signal, not exit")
        #expect(signal == expected || (name == "fault" && signal == SIGBUS))
        #expect(!f.frozen.isStopped, "the handler SIGCONTed the pid before re-raising")
        #expect(!f.home.log.contains("still alive"))
    }

    /// A stack overflow faults on the guard page, where no handler frame fits on the exhausted stack: the handler
    /// runs only on its preallocated alternate signal stack (`SA_ONSTACK`).
    @Test func crashHandlerRunsOnAStackOverflow() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let crasher = try f.spawnGuard(["--crash-selftest", "--pid", String(f.frozen.pid), "--signal", "overflow", "--log", f.home.logPath])
        defer { crasher.terminate() }
        let status = try #require(await crasher.waitForExit(timeout: 20))
        let signal = try #require(WaitStatus.signal(status), "died by a signal, not exit")
        #expect(signal == SIGSEGV || signal == SIGBUS)
        #expect(!f.frozen.isStopped, "the handler SIGCONTed the pid on the alternate stack")
        #expect(!f.home.log.contains("still alive"))
        #expect(!f.home.log.contains("recursed to depth"))
    }
}

/// `PauseManager.startGuard()/stopGuard()` with the real binary: spawn, heartbeat on the injected clock, respawn,
/// `bye`. The guard watches a `/bin/sleep` child (never the test process).
@Suite("PauseManager guard lifecycle", .timeLimit(.minutes(1)))
struct GuardLifecycleTests {
    @Test func startHeartbeatRespawnStop() async throws {
        let watched = try SpawnedChild.sleep()
        defer { watched.terminate() }
        let frozen = try SpawnedChild.sleep()
        defer { frozen.terminate() }
        await frozen.stop()
        let h = try PauseHarness(guardExecutable: Products.guardExecutable, selfPID: watched.pid,
                                 guardExtraArguments: ["--hang-timeout-ms", "5000"])
        defer { h.cleanup() }
        try PauseJournal(bootSessionUUID: try #require(Kernel.bootSessionUUID()), kakurenekoPid: watched.pid, startedAt: Date(),
                         apps: [try GuardIntegrationTests.Fixture.app(frozen)]).write(to: h.home.journalURL)

        try h.manager.startGuard()
        try h.manager.startGuard()
        let first = try #require(h.manager.guardProcess)
        #expect(h.manager.guardSpawnCount == 1, "idempotent")
        #expect(fcntl(first.writeFD, F_GETFD) & FD_CLOEXEC != 0, "the write end is never inherited by other children")
        #expect(fcntl(first.writeFD, F_GETFL) & O_NONBLOCK != 0, "a hung guard never blocks the app")
        #expect(getsid(first.pid) == first.pid, "POSIX_SPAWN_SETSID: own session, no terminal signals")
        #expect(await eventually { h.home.log.contains("watching pid \(watched.pid)") })
        #expect(!h.home.log.contains("first heartbeat received"), "the first hb is due 10 (virtual) s after start")

        // The heartbeat task runs on the injected clock: one virtual 10 s step → one `hb` through the pipe.
        #expect(await h.clock.waitForSleepers(1))
        h.clock.advance(by: GuardLauncher.heartbeatInterval)
        #expect(await eventually { h.home.log.contains("first heartbeat received") })

        // The guard dies unexpectedly → the next heartbeat reaps and respawns it.
        // Our own child (spawned by the code under test) and not reaped yet, so its pid cannot have been reused.
        let row = try #require(Kernel.entry(of: first.pid))
        try #require(row.ppid == getpid() && !row.isZombie)
        _ = Darwin.kill(first.pid, SIGKILL)
        #expect(await eventually { Kernel.entry(of: first.pid)?.isZombie ?? true })
        h.manager.heartbeat()
        let second = try #require(h.manager.guardProcess)
        #expect(second.pid != first.pid)
        #expect(h.manager.guardSpawnCount == 2)

        h.manager.stopGuard()
        #expect(h.manager.guardProcess == nil)
        #expect(await eventually(timeout: 10) { Kernel.entry(of: second.pid).map(\.isZombie) ?? true })
        #expect(await eventually { h.home.log.contains("bye received") })
        #expect(frozen.isStopped, "bye: no recovery")
    }

    /// No `stopGuard()` (the app crashed or leaked the manager): the pipe closes without `bye` → the guard recovers.
    @Test func releasingTheManagerClosesThePipeAndTheGuardRecovers() async throws {
        let watched = try SpawnedChild.sleep()
        defer { watched.terminate() }
        let frozen = try SpawnedChild.sleep()
        defer { frozen.terminate() }
        await frozen.stop()
        let home = try TempHome()
        defer { home.remove() }
        try PauseJournal(bootSessionUUID: try #require(Kernel.bootSessionUUID()), kakurenekoPid: watched.pid, startedAt: Date(),
                         apps: [try GuardIntegrationTests.Fixture.app(frozen)]).write(to: home.journalURL)

        let guardPID = try Self.startGuardAndDropTheManager(home: home, watched: watched)
        let guardian = SpawnedChild(pid: guardPID)
        defer { guardian.terminate() }
        #expect(await eventually(timeout: 10) { !frozen.isStopped }, "EOF without bye = app gone → recovery")
        #expect(await guardian.waitForExit(timeout: 10) != nil)
        #expect(!FileManager.default.fileExists(atPath: home.journalPath))
    }

    static func startGuardAndDropTheManager(home: TempHome, watched: SpawnedChild) throws -> pid_t {
        let manager = PauseManager(
            paths: home.paths, signaller: DryRunProcessSignaller(gate: .alwaysOn(), ledger: DryRunLedger()),
            processes: KernelProcessLookup(), dryRun: .off(), guardExecutable: Products.guardExecutable,
            clock: TestClock(), logger: KakurenekoLogger(.pause), probe: FakeWorld(), candidates: FakeCandidates(),
            groupingResolver: FakeGroupingResolver(grouping: nil, selfTest: PauseHarness.freezeAllowed),
            crashBuffer: RecordingCrashBuffer(), selfPID: watched.pid, guardEnvironment: home.paths.helperEnvironment)
        try manager.startGuard()
        return try #require(manager.guardProcess?.pid)
    }

    @Test func noGuardWithoutAnExecutable() throws {
        let h = try PauseHarness(guardExecutable: nil)
        defer { h.cleanup() }
        try h.manager.startGuard()
        #expect(h.manager.guardProcess == nil)
        h.manager.heartbeat()
        h.manager.stopGuard()
    }
}
