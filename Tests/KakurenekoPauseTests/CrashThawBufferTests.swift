import Darwin
import KakurenekoKit
@testable import KakurenekoPause
import Foundation
import Synchronization
import Testing

/// The crash-handler pid buffer bookkeeping as pure functions over a LOCAL buffer (the process-wide
/// `CrashThawBuffer` and the real handler are exercised only in `kakureneko-guard --crash-selftest`).
@Suite("Crash thaw buffer bookkeeping", .timeLimit(.minutes(1)))
struct CrashThawBufferTests {
    final class LocalBuffer: Sendable {
        let capacity: Int
        nonisolated(unsafe) let pids: UnsafeMutablePointer<pid_t>
        let count = Atomic<Int>(0)

        init(capacity: Int) {
            self.capacity = capacity
            pids = .allocate(capacity: capacity)
            pids.initialize(repeating: 0, count: capacity)
        }

        deinit { pids.deallocate() }

        func store(_ list: [pid_t]) { CrashThawBuffer.store(list, into: pids, capacity: capacity, count: count) }
        var snapshot: [pid_t] { CrashThawBuffer.snapshot(of: pids, count: count) }
    }

    @Test func storeFiltersCapsAndShrinks() {
        let buffer = LocalBuffer(capacity: 4)
        buffer.store([10, 0, 1, -3, 11, 12])
        #expect(buffer.snapshot == [10, 11, 12], "launchd, 0 and negative pids are never published")
        buffer.store([20, 21, 22, 23, 24, 25])
        #expect(buffer.snapshot == [20, 21, 22, 23], "capped at capacity")
        buffer.store([30])
        #expect(buffer.snapshot == [30], "shrinks: no stale entries past the end")
        buffer.store([])
        #expect(buffer.snapshot.isEmpty)
    }

    @Test func pidsForAJournalAreRealFrozenMembersOnly() {
        func record(_ pid: Int32, _ action: PauseAction) -> PauseJournalRecord {
            PauseJournalRecord(pid: pid, pidVersion: 1, uniqueID: UInt64(pid), startSec: 1, startUsec: 0, path: nil, action: action)
        }
        let journal = PauseJournal(bootSessionUUID: "B", kakurenekoPid: 1, startedAt: TestClock.defaultStart, apps: [
            PauseJournalApp(bundleID: nil, name: nil, appPid: 100, mode: .freeze, members: [record(100, .sigstop), record(101, .sigstop)]),
            PauseJournalApp(bundleID: nil, name: nil, appPid: 200, mode: .throttle, members: [record(200, .darwinBackground)]),
            PauseJournalApp(bundleID: nil, name: nil, appPid: 300, mode: .freeze, members: [record(300, .sigstop)], simulated: true),
            PauseJournalApp(bundleID: nil, name: nil, appPid: 400, mode: .quit, members: [record(400, .terminate)]),
            PauseJournalApp(bundleID: nil, name: nil, appPid: 500, mode: .freeze, members: [record(101, .sigstop), record(1, .sigstop)]),
        ])
        #expect(CrashThawBuffer.pids(for: journal) == [100, 101], "SIGSTOPped, real, deduplicated, never pid 1")
        #expect(CrashThawBuffer.pids(for: nil).isEmpty)
    }

    @Test func handledSignalsAreTheCrashSignalsOnly() {
        #expect(Set(CrashHandlers.signals) == [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE])
        #expect(!CrashHandlers.signals.contains(SIGTERM) && !CrashHandlers.signals.contains(SIGINT), "owned by the coordinator")
        #expect(CrashThawBuffer.capacity == 4096)
    }

    @Test func managerPublishesOnlyAfterInstallAndOnlyRealFrozenPids() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001])
        h.addApp(pid: 2000)
        await h.observeIdle()
        _ = await h.pause(.freeze)
        #expect(h.crash.published.isEmpty, "nothing is published before installCrashHandlers()")
        h.manager.installCrashHandlers()
        #expect(h.crash.latest == [1000, 1001, 2000])
        h.recorder.clear()
        let peer = AgentTopology(builtAt: PauseHarness.now, ipcPeers: [IPCPeerHint(peerPID: 2000, kind: .pipe, agentSidePID: 7)])
        _ = await h.recheck(topology: peer, at: PauseHarness.now.addingTimeInterval(15))
        #expect(h.crash.latest == [1000, 1001], "thawed pids leave the buffer")
        _ = h.manager.thawAllSynchronously(reason: .appQuitting)
        #expect(h.crash.latest == [])
    }

    @Test func synchronousThawNeverRelaunches() async throws {
        let h = try await PauseManagerPauseTests.quitHarness(dryRun: true)
        defer { h.cleanup() }
        _ = await h.pause(PauseManagerPauseTests.quitSettings)
        _ = h.manager.thawAllSynchronously(reason: .lidOpened)
        #expect(h.ledger.entries(action: "app.relaunch").isEmpty)
    }
}
