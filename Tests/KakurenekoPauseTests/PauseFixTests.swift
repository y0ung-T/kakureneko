import Darwin
import KakurenekoKit
@testable import KakurenekoPause
import Foundation
import Testing

/// Regression tests for the pause-safety review (each failed before its fix). Synthetic world only.
@Suite("Pause safety fixes", .timeLimit(.minutes(1)))
struct PauseFixTests {
    static let now = PauseHarness.now

    // MARK: Inherited darwinbg (XNU copies the EXTERNAL throttle to children forked afterwards)

    /// A renderer the throttled app forks while paused inherits darwinbg; the re-scan used to skip it as "already in
    /// the background", so no thaw ever restored it.
    @Test func aHelperForkedByAThrottledAppIsRestoredByTheThaw() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001], name: "Chrome")
        #expect(await h.pause().paused.map(\.appPID) == [1000])

        h.world.add(pid: 1003, ppid: 1000, start: Self.now.addingTimeInterval(5))
        h.world.update(1003) { $0.darwinBackground = true } // inherited
        _ = await h.recheck(at: Self.now.addingTimeInterval(31))
        #expect(h.journal?.allMembers.contains { $0.pid == 1003 && $0.action == .darwinBackground } == true)

        await h.manager.thawAll(reason: .lidOpened)
        for pid: pid_t in [1000, 1001, 1003] { #expect(h.world.process(pid)?.darwinBackground == false, "pid \(pid)") }
    }

    /// Grandchildren too (a renderer forked by a zygote the app forked while paused), and even when the lid opens
    /// before any re-scan ran.
    @Test func aChainForkedWhilePausedIsRestoredByAThawBeforeAnyRescan() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1100, helpers: [1101], name: "Chrome")
        _ = await h.pause()
        h.world.add(pid: 1102, ppid: 1100, start: Self.now.addingTimeInterval(5))
        h.world.add(pid: 1103, ppid: 1102, start: Self.now.addingTimeInterval(6))
        h.world.update(1102) { $0.darwinBackground = true }
        h.world.update(1103) { $0.darwinBackground = true }
        await h.manager.thawAll(reason: .lidOpened)
        #expect(h.world.process(1102)?.darwinBackground == false)
        #expect(h.world.process(1103)?.darwinBackground == false)
        #expect(!h.journalExists)
    }

    /// The agent flavour: an idle editor throttled at lid close spawns an agent CLI, which inherits the throttle. The
    /// recheck protects the editor (P-A) — and must restore the agent too.
    @Test func anAgentForkedByAThrottledAppIsRestoredWhenTheAppIsProtected() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 3000, helpers: [3001], bundleID: "org.gnu.Emacs", name: "Emacs")
        _ = await h.pause()
        let agent = h.world.add(pid: 3005, ppid: 3000, start: Self.now.addingTimeInterval(20))
        h.world.update(3005) { $0.darwinBackground = true }
        let topology = AgentTopology(builtAt: Self.now.addingTimeInterval(30), agentIdentities: [agent])
        let report = await h.recheck(topology: topology, at: Self.now.addingTimeInterval(30))
        #expect(report.protected.first?.reasons.contains(.agentHost) == true)
        #expect(h.world.process(3000)?.darwinBackground == false)
        #expect(h.world.process(3005)?.darwinBackground == false)
    }

    /// Never adopted: a member somebody else throttled before the pause (App Tamer) and what it forks afterwards, nor a
    /// child that was darwinbg before the pause began.
    @Test func someoneElsesThrottleIsNeverRestored() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 4000, helpers: [4001, 4002], name: "Mail")
        h.world.update(4001) { $0.darwinBackground = true } // App Tamer
        h.world.update(4002) { $0.darwinBackground = true }
        _ = await h.pause()
        #expect(h.journal?.allMembers.map(\.pid).sorted() == [4000])
        h.world.add(pid: 4003, ppid: 4001, start: Self.now.addingTimeInterval(5)) // forked by App Tamer's member
        h.world.update(4003) { $0.darwinBackground = true }
        _ = await h.recheck(at: Self.now.addingTimeInterval(31))
        await h.manager.thawAll(reason: .lidOpened)
        #expect(h.world.process(4000)?.darwinBackground == false)
        for pid: pid_t in [4001, 4002, 4003] { #expect(h.world.process(pid)?.darwinBackground == true, "pid \(pid)") }
    }

    // MARK: Freeze never resumes what someone else stopped

    @Test func freezeLeavesAMemberSomeoneElseStoppedAlone() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 2000, helpers: [2001], name: "Spotify")
        h.world.setStopped(2001, true)
        await h.observeIdle()
        let report = await h.pause(.freeze)
        #expect(report.paused.first?.mode == .freeze)
        #expect(h.journal?.allMembers.map(\.pid) == [2000])
        await h.manager.thawAll(reason: .lidOpened)
        #expect(!h.recorder.calls.contains(.cont(2001)))
        #expect(!h.recorder.calls.contains(.stop(2001)))
        #expect(h.world.isStopped(2001))
        #expect(!h.world.isStopped(2000))
    }

    @Test func freezeOfAnAppWhoseMainIsAlreadyStoppedDoesNothing() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 2100, helpers: [2101], name: "Notes")
        h.world.setStopped(2100, true)
        await h.observeIdle()
        let report = await h.pause(.freeze)
        #expect(report.paused.isEmpty)
        #expect(!h.journalExists)
        #expect(h.recorder.calls.isEmpty)
    }

    // MARK: Freeze category defaults (R06 §5.4)

    @Test func freezeThrottlesBrowsersAndChatApps() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 5000, bundleID: "com.google.Chrome", name: "Chrome")
        h.addApp(pid: 5010, bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        h.addApp(pid: 5020, bundleID: "org.example.NewBrowser", name: "NewBrowser")
        h.addApp(pid: 5030, bundleID: "com.apple.Notes", name: "Notes")
        h.candidates.setBrowsers(["org.example.NewBrowser"])
        await h.observeIdle()
        let report = await h.pause(.freeze)
        let modes = Dictionary(uniqueKeysWithValues: report.paused.map { ($0.appPID, $0.mode) })
        #expect(modes == [5000: .throttle, 5010: .throttle, 5020: .throttle, 5030: .freeze])
        #expect(report.paused.filter { $0.mode == .throttle }.allSatisfy { $0.downgradedBecause == .categoryDefault })
        #expect(!h.world.isStopped(5000))
        #expect(h.world.isStopped(5030))
    }

    @Test func theCategoryRuleOnlyDowngrades() {
        #expect(ProtectionReason.categoryDefault.downgradesOnly)
        #expect(ProtectionRules.categoryDowngrade(bundleID: "com.apple.Safari", browserBundleIDs: []) == .categoryDefault)
        #expect(ProtectionRules.categoryDowngrade(bundleID: "com.apple.Notes", browserBundleIDs: []) == nil)
        #expect(ProtectionRules.categoryDowngrade(bundleID: nil, browserBundleIDs: ["x"]) == nil)
        #expect(ProtectionRules.mode(requested: .freeze, freezePermitted: true, downgrades: [.categoryDefault],
                                     quitEligible: false) == (.throttle, .categoryDefault))
    }

    // MARK: A recheck that cannot see never keeps apps frozen

    @Test func aRecheckWithoutAProcessTableThawsFrozenApps() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 2200, helpers: [2201], name: "Notes")
        await h.observeIdle()
        #expect(await h.pause(.freeze).paused.first?.mode == .freeze)
        h.world.setTableAvailable(false)
        let report = await h.recheck(.freeze, at: Self.now.addingTimeInterval(15))
        #expect(report.skippedReason != nil)
        #expect(report.thawed.map(\.appPID) == [2200])
        #expect(!h.world.isStopped(2200))
        #expect(!h.world.isStopped(2201))
    }

    /// An incomplete topology (the newest processes' fds were not read): frozen apps are thawed, throttled ones stay.
    @Test func aRecheckOnAnIncompleteTopologyThawsFrozenAppsOnly() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 2300, helpers: [2301], name: "Notes")
        h.addApp(pid: 2310, bundleID: "com.google.Chrome", name: "Chrome")
        await h.observeIdle()
        let report = await h.pause(.freeze)
        #expect(Set(report.paused.map(\.mode)) == [.freeze, .throttle])
        let blind = AgentTopology(builtAt: Self.now.addingTimeInterval(15), isComplete: false)
        let re = await h.recheck(.freeze, topology: blind, at: Self.now.addingTimeInterval(15))
        #expect(re.thawed.map(\.appPID) == [2300])
        #expect(!h.world.isStopped(2300))
        #expect(re.paused.map(\.appPID) == [2310])
        #expect(h.world.process(2310)?.darwinBackground == true)
    }

    // MARK: Journal writers never overwrite each other (app ↔ kakureneko-guard)

    /// The guard holds the journal lock from its read to its rewrite; the app's append waits for it and then applies
    /// on top of the guard's result: the guard's thaw is respected AND the appended record survives.
    @Test func anAppendDuringTheGuardsRewriteIsNotLost() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let url = home.journalURL
        let identity = { (pid: Int32) in
            ProcessIdentity(pid: pid, startSec: 1_791_000_000, startUsec: 0, uniqueID: UInt64(pid), pidVersion: UInt32(pid))
        }
        func record(_ pid: Int32) throws -> PauseJournalRecord {
            try #require(PauseJournalRecord(identity: identity(pid), path: "/x", action: .darwinBackground))
        }
        let store = JournalStore(url: url)
        let header = PauseJournal(bootSessionUUID: "B", kakurenekoPid: 1, startedAt: Self.now)
        let initial = [try record(1000), try record(1001)]
        try store.update(header: { header }) { j in
            j.apps = [PauseJournalApp(bundleID: "a", name: "A", appPid: 1000, mode: .throttle, members: initial, simulated: false)]
        }

        // The guard: lock, read, (thaw), …
        let held = JournalFileLock.acquire(journal: url, timeout: 1)
        #expect(held >= 0)
        let stale = try #require(PauseJournal.read(from: url))
        // … the resumed app appends a new helper meanwhile (it must wait for the lock) …
        let newcomer = try record(1003)
        let append = Task.detached {
            // As `journalAppend`: append to the app's entry, or create it when the guard's thaw emptied it.
            try store.update(header: { header }) { j in
                if let index = j.apps.firstIndex(where: { $0.appPid == 1000 }) {
                    j.apps[index].members.append(newcomer)
                } else {
                    j.apps.append(PauseJournalApp(bundleID: "a", name: "A", appPid: 1000, mode: .throttle, members: [newcomer]))
                }
            }
        }
        try await Task.sleep(for: .milliseconds(150))
        // … the guard writes the journal computed from its read (all thawed) and releases.
        var next = stale
        next.apps = []
        try next.write(to: url)
        JournalFileLock.release(held)
        _ = try await append.value

        let disk = try #require(PauseJournal.read(from: url))
        #expect(disk.allMembers.map(\.pid) == [1003])
        #expect(store.current?.allMembers.map(\.pid) == [1003])
    }

    @Test func theLockIsBoundedWhenItsHolderNeverReleases() throws {
        let home = try TempHome()
        defer { home.remove() }
        try FileManager.default.createDirectory(at: home.journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let held = JournalFileLock.acquire(journal: home.journalURL, timeout: 1)
        #expect(held >= 0)
        defer { JournalFileLock.release(held) }
        let start = Kernel.uptimeNanoseconds()
        let second = JournalFileLock.acquire(journal: home.journalURL, timeout: 0.1)
        #expect(second == -1)
        #expect(Kernel.uptimeNanoseconds() - start < 2_000_000_000)
        let ran = JournalFileLock.withLock(journal: home.journalURL, timeout: 0.05) { true }
        #expect(ran) // proceeds without the lock
    }
}
