import Darwin
import KakurenekoKit
@testable import KakurenekoPause
import Foundation
import Testing

/// `PauseManager` with the REAL `AuditTokenSignaller`, `LiveSystemProbe` and `KernelProcessLookup`. The only
/// "app" it may touch is a `/bin/sleep` child of this test, injected as the sole candidate (the real NSWorkspace list
/// is never consulted).
@Suite("End to end with spawned children", .timeLimit(.minutes(1)))
struct EndToEndTests {
    struct Rig {
        let home: TempHome
        let child: SpawnedChild
        let crash = RecordingCrashBuffer()
        let manager: PauseManager
        /// After the child started, so it counts as "launched before the pause began".
        let now = Date().addingTimeInterval(5)

        init() throws {
            home = try TempHome()
            child = try SpawnedChild.sleep()
            manager = Self.makeManager(home: home, child: child, crash: crash)
        }

        static func makeManager(home: TempHome, child: SpawnedChild, crash: RecordingCrashBuffer) -> PauseManager {
            let candidates = FakeCandidates([AppCandidate(pid: child.pid, bundleID: "com.kakureneko.test.sleeper",
                                                          localizedName: "Sleeper", bundlePath: nil)])
            return PauseManager(
                paths: home.paths, signaller: AuditTokenSignaller(), processes: KernelProcessLookup(), dryRun: .off(),
                guardExecutable: nil, clock: SystemClock(), logger: KakurenekoLogger(.pause),
                probe: LiveSystemProbe(), candidates: candidates,
                groupingResolver: FakeGroupingResolver(grouping: ParentTreeGrouping(), selfTest: PauseHarness.freezeAllowed),
                crashBuffer: crash)
        }

        func cleanup() {
            child.terminate()
            home.remove()
        }

        var journal: PauseJournal? { PauseJournal.read(from: home.journalURL) }
    }

    @Test func throttleAndThawARealChild() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let report = await rig.manager.pause(topology: AgentTopology(builtAt: rig.now), settings: PauseSettings(), now: rig.now)
        #expect(report.failures.isEmpty, "\(report.failures)")
        #expect(report.paused.map(\.appPID) == [rig.child.pid])
        #expect(Kernel.isExternallyDarwinBackground(rig.child.pid) == true, "verified through pbi_flags")

        let record = try #require(rig.journal?.allMembers.first)
        let enriched = try rig.child.enriched
        #expect(record.identity == enriched && record.uniqueID == enriched.uniqueID && record.pidVersion == enriched.pidVersion)
        #expect(record.path == "/bin/sleep" && record.action == .darwinBackground)
        #expect(rig.journal?.bootSessionUUID == Kernel.bootSessionUUID())

        #expect(await rig.manager.thawAll(reason: .lidOpened) == 1)
        #expect(Kernel.isExternallyDarwinBackground(rig.child.pid) == false)
        #expect(rig.journal == nil)
    }

    @Test func freezeThenRecoverAfterARelaunch() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        await rig.manager.observe(now: rig.now.addingTimeInterval(-60))
        await rig.manager.observe(now: rig.now) // sleep(1) uses no CPU: P-I says idle
        rig.manager.installCrashHandlers()      // recording fake: never process-wide handlers in a test process

        let report = await rig.manager.pause(topology: AgentTopology(builtAt: rig.now), settings: .freeze, now: rig.now)
        #expect(report.failures.isEmpty, "\(report.failures)")
        #expect(report.paused.first?.mode == .freeze)
        #expect(rig.child.isStopped, "p_stat == SSTOP verified")
        #expect(rig.crash.latest == [rig.child.pid])

        // Kakureneko "crashed": a fresh manager (as at the next launch) recovers from the journal.
        let relaunched = Rig.makeManager(home: rig.home, child: rig.child, crash: RecordingCrashBuffer())
        #expect(await relaunched.recoverFromJournal() == 1)
        #expect(await eventually { !rig.child.isStopped })
        #expect(rig.journal == nil)
    }

    @Test func childWithAControllingTTYIsNeverSignalled() async throws {
        // `script` gives its command a pty as controlling terminal (rule I: a tty job is never a candidate member).
        let home = try TempHome()
        defer { home.remove() }
        let script = try SpawnedChild.spawn("/usr/bin/script", ["-q", "/dev/null", "/bin/sleep", "30"])
        defer { script.terminate() } // the pty closes: its sleep gets SIGHUP
        var sleeper: pid_t?
        _ = await eventually {
            sleeper = Kernel.processTable()?.descendants(of: script.pid).first
            return sleeper != nil
        }
        let ttyChild = try #require(sleeper)
        #expect(Kernel.entry(of: ttyChild)?.hasControllingTTY == true)

        let crash = RecordingCrashBuffer()
        let candidates = FakeCandidates([AppCandidate(pid: script.pid, bundleID: "com.kakureneko.test.script", localizedName: "Script")])
        let manager = PauseManager(
            paths: home.paths, signaller: AuditTokenSignaller(), processes: KernelProcessLookup(), dryRun: .off(),
            guardExecutable: nil, clock: SystemClock(), logger: KakurenekoLogger(.pause), probe: LiveSystemProbe(),
            candidates: candidates,
            groupingResolver: FakeGroupingResolver(grouping: ParentTreeGrouping(), selfTest: PauseHarness.freezeAllowed),
            crashBuffer: crash)
        let now = Date().addingTimeInterval(5)
        let report = await manager.pause(topology: AgentTopology(builtAt: now), settings: PauseSettings(), now: now)
        #expect(report.paused.isEmpty)
        #expect(report.protected.first?.reasons.contains(.notCandidate) == true)
        #expect(Kernel.isExternallyDarwinBackground(ttyChild) == false)
        #expect(Kernel.isExternallyDarwinBackground(script.pid) == false)
        #expect(!FileManager.default.fileExists(atPath: home.journalPath))
    }
}

/// Spike (R06 §3.1, brief §12): an agent writing to a pty whose MASTER holder is frozen blocks once the pty's output
/// queue fills — the reason rule P-A2 never freezes a pty-master holder. Uses only spawned processes: `script`
/// (holds the master, copies the output to /dev/null) running `yes` (the "agent", writing continuously).
/// `yes` is exec'd by perl after `alarm 120`: the timer survives exec, so if this test process dies before its
/// `defer` runs (a crash elsewhere in the suite), the orphaned writer still exits within two minutes.
@Suite("Spike: frozen pty-master holder", .timeLimit(.minutes(1)))
struct PtyMasterSpikeTests {
    /// Cumulative CPU of `pid`, sampled `interval` apart; true when it did not advance (blocked).
    static func isBlocked(_ pid: pid_t, interval: Duration = .milliseconds(120)) async -> Bool {
        guard let before = Kernel.cpuNanoseconds(of: pid) else { return false }
        try? await Task.sleep(for: interval)
        guard let after = Kernel.cpuNanoseconds(of: pid) else { return false }
        return after == before
    }

    @Test func writerBlocksWhenTheMasterHolderIsStopped() async throws {
        let script = try SpawnedChild.spawn("/usr/bin/script", ["-q", "/dev/null", "/usr/bin/perl", "-e",
                                                               #"alarm 120; exec "/usr/bin/yes", "kakureneko""#])
        var writerIdentity: ProcessIdentity?
        defer {
            script.terminate() // the master closes: `yes` gets SIGHUP / EIO and exits (reaped by launchd)
            // Belt and braces: the writer is this test's grandchild; kill it only if it is still THAT process.
            if let writerIdentity, KernelProcessLookup().identity(of: writerIdentity.pid) == writerIdentity {
                _ = Darwin.kill(writerIdentity.pid, SIGKILL)
            }
        }
        var found: pid_t?
        _ = await eventually {
            found = Kernel.processTable()?.descendants(of: script.pid).first
            return found != nil
        }
        let writer = try #require(found)
        writerIdentity = KernelProcessLookup().identity(of: writer)
        let writerEntry = try #require(Kernel.entry(of: writer))
        #expect(writerEntry.ppid == script.pid && writerEntry.hasControllingTTY, "the writer's controlling tty is the pty slave")
        #expect(Kernel.openVnodePaths(of: script.pid).contains("/dev/ptmx"), "script holds the pty master (P-A2 signal)")
        #expect(await eventually { Kernel.cpuNanoseconds(of: writer) ?? 0 > 0 })

        script.signal(SIGSTOP) // freeze the master holder (our own child)
        defer { script.signal(SIGCONT) }
        #expect(await eventually(timeout: 10) { script.isStopped })
        var blocked = false
        for _ in 0..<8 where !blocked {
            blocked = await Self.isBlocked(writer)
        }
        #expect(blocked, "the writer stalls in ttywri once the pty output queue is full")

        script.signal(SIGCONT)
        var resumed = false
        // Up to ~3 s: on a busy machine the released writer may wait a while for a CPU before it advances.
        for _ in 0..<50 where !resumed {
            resumed = !(await Self.isBlocked(writer, interval: .milliseconds(60)))
        }
        #expect(resumed, "thawing the master holder releases the writer")
    }
}
