import Darwin
import KakurenekoKit
@testable import KakurenekoPause
import Foundation
import Synchronization
import Testing

/// Launch recovery, the shared thaw routine, the journal store and the async lock.
@Suite("Recovery and journal", .timeLimit(.minutes(1)))
struct RecoveryAndJournalTests {
    static let now = PauseHarness.now

    static func record(_ world: FakeWorld, _ pid: pid_t, _ action: PauseAction,
                       tweak: (inout PauseJournalRecord) -> Void = { _ in }) throws -> PauseJournalRecord {
        let identity = try #require(world.enriched(pid))
        var record = try #require(PauseJournalRecord(identity: identity, path: "/x/\(pid)", action: action))
        tweak(&record)
        return record
    }

    // MARK: recoverFromJournal

    @Test func recoveryThawsOnlyVerifiedRecords() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        let w = h.world
        for pid: pid_t in [1000, 1001, 1002, 2000, 2001, 2002, 3000, 4000] { w.add(pid: pid) }
        w.setStopped(1000, true)
        w.update(2002) { $0.darwinBackground = true }
        let frozenApp = PauseJournalApp(bundleID: "a", name: "A", appPid: 1000, mode: .freeze, members: [
            try Self.record(w, 1000, .sigstop), try Self.record(w, 1001, .sigstop), try Self.record(w, 1002, .sigstop),
        ])
        let throttledApp = PauseJournalApp(bundleID: "b", name: "B", appPid: 2000, mode: .throttle, members: [
            try Self.record(w, 2000, .darwinBackground) { $0.uniqueID &+= 1 },   // uniqueID changed
            try Self.record(w, 2001, .darwinBackground) { $0.pidVersion &+= 1 }, // audit token pidversion changed
            try Self.record(w, 2002, .darwinBackground),
        ])
        let simulatedApp = PauseJournalApp(bundleID: "c", name: "C", appPid: 3000, mode: .freeze,
                                           members: [try Self.record(w, 3000, .sigstop)], simulated: true)
        let quitApp = PauseJournalApp(bundleID: "d", name: "D", appPid: 4000, mode: .quit,
                                      members: [try Self.record(w, 4000, .terminate)])
        try PauseJournal(bootSessionUUID: "BOOT-A", kakurenekoPid: 1, startedAt: Self.now,
                         apps: [frozenApp, throttledApp, simulatedApp, quitApp]).write(to: h.home.journalURL)
        w.reuse(1001)  // pid reused since
        w.remove(1002) // gone

        #expect(await h.manager.recoverFromJournal() == 2)
        #expect(h.recorder.calls == [.background(2002, false), .cont(1000)], "LIFO; simulated / terminate / unverifiable never signalled")
        #expect(!h.journalExists, "journal cleared")
        #expect(!w.isStopped(1000))
        #expect(await h.manager.pausedApps().isEmpty)
    }

    @Test func recoveryDropsAnotherBootsJournal() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.world.add(pid: 1000)
        h.world.setStopped(1000, true)
        try PauseJournal(bootSessionUUID: "BOOT-OLD", kakurenekoPid: 1, startedAt: Self.now, apps: [
            PauseJournalApp(bundleID: nil, name: nil, appPid: 1000, mode: .freeze, members: [try Self.record(h.world, 1000, .sigstop)]),
        ]).write(to: h.home.journalURL)

        #expect(await h.manager.recoverFromJournal() == 0)
        #expect(h.recorder.calls.isEmpty, "never a blanket SIGCONT")
        #expect(h.world.isStopped(1000))
        #expect(!h.journalExists)
    }

    @Test func lossyJournalWithACorruptRecordStillThawsTheOthers() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.world.add(pid: 1000)
        h.world.add(pid: 1001)
        h.world.setStopped(1000, true)
        h.world.setStopped(1001, true)
        let journal = PauseJournal(bootSessionUUID: "BOOT-A", kakurenekoPid: 1, startedAt: Self.now, apps: [
            PauseJournalApp(bundleID: "a", name: "A", appPid: 1000, mode: .freeze,
                            members: [try Self.record(h.world, 1000, .sigstop), try Self.record(h.world, 1001, .sigstop)]),
        ])
        var object = try #require(try JSONSerialization.jsonObject(with: journal.encoded()) as? [String: Any])
        var apps = try #require(object["apps"] as? [[String: Any]])
        var members = try #require(apps[0]["members"] as? [[String: Any]])
        members[0].removeValue(forKey: "pidVersion")                       // record 1000 is now corrupt
        members.append(["pid": "not a number"])                            // garbage record
        apps[0]["members"] = members
        apps.append(["bundleID": "broken", "members": 7])                 // app without appPid
        apps.append(["appPid": 5, "mode": "nonsense", "members": [], "futureField": true])
        object["apps"] = apps
        object["futureHeaderField"] = ["x": 1]
        try FileManager.default.createDirectory(at: h.home.journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: h.home.journalURL)

        #expect(await h.manager.recoverFromJournal() == 1)
        #expect(h.recorder.calls == [.cont(1001)])
        #expect(h.world.isStopped(1000), "an unverifiable record is never thawed on a guess")
        #expect(!h.journalExists)
    }

    @Test func unreadableJournalIsRemovedWithoutSignalling() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        try FileManager.default.createDirectory(at: h.home.journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: h.home.journalURL)
        #expect(await h.manager.recoverFromJournal() == 0)
        #expect(!h.journalExists)
        #expect(h.recorder.calls.isEmpty)
        #expect(await h.manager.recoverFromJournal() == 0, "missing journal: nothing to do")
    }

    @Test func failedUndoStaysJournaledForRetry() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.world.add(pid: 1000)
        h.world.setStopped(1000, true)
        try PauseJournal(bootSessionUUID: "BOOT-A", kakurenekoPid: 1, startedAt: Self.now, apps: [
            PauseJournalApp(bundleID: "a", name: "A", appPid: 1000, mode: .freeze, members: [try Self.record(h.world, 1000, .sigstop)]),
        ]).write(to: h.home.journalURL)
        h.recorder.fail(.cont(1000), with: .notPermitted("EPERM"))

        #expect(await h.manager.recoverFromJournal() == 0)
        #expect(h.journal?.allMembers.map(\.pid) == [1000])
    }

    @Test func dryRunRecoveryKeepsRealRecordsAndDropsSimulatedOnes() async throws {
        let h = try PauseHarness(dryRun: true)
        defer { h.cleanup() }
        h.world.add(pid: 1000)
        h.world.add(pid: 2000)
        h.world.setStopped(1000, true)
        try PauseJournal(bootSessionUUID: "BOOT-A", kakurenekoPid: 1, startedAt: Self.now, apps: [
            PauseJournalApp(bundleID: "a", name: "A", appPid: 1000, mode: .freeze, members: [try Self.record(h.world, 1000, .sigstop)]),
            PauseJournalApp(bundleID: "b", name: "B", appPid: 2000, mode: .freeze, members: [try Self.record(h.world, 2000, .sigstop)], simulated: true),
        ]).write(to: h.home.journalURL)

        #expect(await h.manager.recoverFromJournal() == 0)
        #expect(h.ledger.entries.isEmpty && h.recorder.calls.isEmpty)
        #expect(h.journal?.apps.map(\.appPid) == [1000], "a REALLY paused app is never 'undone' through the dry-run signaller")
    }

    @Test func thawUnderTheOtherGateValueNeverSimulatesOrSignalsBlindly() async throws {
        // Paused for real, then the gate turned on without the coordinator thawing first: kept, logged.
        let real = try PauseHarness()
        defer { real.cleanup() }
        real.addApp(pid: 1000)
        _ = await real.pause()
        real.gate.setRequested(true)
        real.recorder.clear()
        #expect(await real.manager.thawAll(reason: .lidOpened) == 0)
        #expect(real.recorder.calls.isEmpty)
        #expect(real.journal?.allMembers.map(\.pid) == [1000])
        real.gate.setRequested(false)
        #expect(await real.manager.thawAll(reason: .lidOpened) == 1)
        #expect(real.recorder.calls == [.background(1000, false)])
    }

    // MARK: PauseRecovery (shared with kakureneko-guard)

    @Test func recoveryRoutineOrdersAndKeepsAsAsked() throws {
        let world = FakeWorld()
        let home = try TempHome()
        defer { home.remove() }
        let signaller = RecordingSignaller(world: world, journalURL: home.journalURL)
        for pid: pid_t in [1, 2, 3, 4, 5] { world.add(pid: pid + 100) }
        let recovery = PauseRecovery(signaller: signaller, processes: world, probe: world)
        let journal = PauseJournal(bootSessionUUID: "BOOT-A", kakurenekoPid: 1, startedAt: Self.now, apps: [
            PauseJournalApp(bundleID: nil, name: nil, appPid: 101, mode: .freeze,
                            members: [try Self.record(world, 101, .sigstop), try Self.record(world, 102, .sigstop)]),
            PauseJournalApp(bundleID: nil, name: nil, appPid: 103, mode: .throttle,
                            members: [try Self.record(world, 103, .darwinBackground)]),
            PauseJournalApp(bundleID: nil, name: nil, appPid: 104, mode: .quit, members: [try Self.record(world, 104, .terminate)]),
            PauseJournalApp(bundleID: nil, name: nil, appPid: 105, mode: .freeze, members: [try Self.record(world, 105, .sigstop)], simulated: true),
        ])
        #expect(PauseRecovery.hasThawableRecords(journal))
        #expect(!PauseRecovery.hasThawableRecords(nil))
        #expect(!PauseRecovery.hasThawableRecords(PauseJournal(bootSessionUUID: "x", kakurenekoPid: 1, startedAt: Self.now, apps: [
            PauseJournalApp(bundleID: nil, name: nil, appPid: 105, mode: .freeze, members: [try Self.record(world, 105, .sigstop)], simulated: true),
            PauseJournalApp(bundleID: nil, name: nil, appPid: 104, mode: .quit, members: [try Self.record(world, 104, .terminate)]),
        ])))

        signaller.fail(.background(103, false), with: .notPermitted("EPERM"))
        var lines: [String] = []
        let hang = recovery.thawAll(journal, keepUnsignalled: true) { lines.append($0) }
        #expect(signaller.calls == [.cont(102), .cont(101)], "apps in reverse order, members LIFO")
        #expect(hang.thawed == 2 && hang.failed == 1)
        #expect(hang.remaining.map(\.appPid) == [103, 104, 105], "failed, terminate and simulated kept for the app")
        #expect(!lines.isEmpty)

        signaller.clear()
        let gone = recovery.thawAll(journal, keepUnsignalled: false) { _ in }
        #expect(gone.remaining.map(\.appPid) == [103], "only the failed undo stays")
        #expect(gone.dropped == 2)

        world.setBoot("BOOT-B")
        signaller.clear()
        let otherBoot = recovery.thawAll(journal, keepUnsignalled: false) { _ in }
        #expect(signaller.calls.isEmpty && otherBoot.thawed == 0 && otherBoot.remaining.isEmpty)
    }

    @Test func verifyNamesEveryMismatch() throws {
        let world = FakeWorld()
        let home = try TempHome()
        defer { home.remove() }
        world.add(pid: 300)
        let recovery = PauseRecovery(signaller: RecordingSignaller(world: world, journalURL: home.journalURL), processes: world, probe: world)
        let good = try Self.record(world, 300, .sigstop)
        #expect(recovery.verify(good, bootMatches: true) == nil)
        #expect(recovery.verify(good, bootMatches: false) != nil)
        var badStart = good
        badStart.startUsec += 1
        #expect(recovery.verify(badStart, bootMatches: true) != nil)
        var badUnique = good
        badUnique.uniqueID &+= 1
        #expect(recovery.verify(badUnique, bootMatches: true) != nil)
        var badVersion = good
        badVersion.pidVersion &+= 1
        #expect(recovery.verify(badVersion, bootMatches: true) != nil)
        #expect(recovery.thaw(try Self.record(world, 300, .terminate), bootMatches: true) == .skipped)
        world.remove(300)
        #expect(recovery.verify(good, bootMatches: true) != nil)
    }

    // MARK: JournalStore

    static func sampleJournal(_ pids: [Int32], boot: String = "BOOT-A") -> PauseJournal {
        PauseJournal(bootSessionUUID: boot, kakurenekoPid: 9, startedAt: now, apps: pids.map { pid in
            PauseJournalApp(bundleID: "b\(pid)", name: "n\(pid)", appPid: pid, mode: .throttle, members: [
                PauseJournalRecord(pid: pid, pidVersion: 1, uniqueID: UInt64(pid), startSec: 1, startUsec: 0, path: nil, action: .darwinBackground),
                PauseJournalRecord(pid: pid + 1, pidVersion: 1, uniqueID: UInt64(pid + 1), startSec: 1, startUsec: 0, path: nil, action: .darwinBackground),
            ])
        })
    }

    @Test func storePersistsEveryMutationAndRemovesAnEmptyJournal() throws {
        let home = try TempHome()
        defer { home.remove() }
        let store = JournalStore(url: home.journalURL)
        #expect(store.current == nil)
        try store.update(header: { Self.sampleJournal([]) }) { $0.apps = Self.sampleJournal([10]).apps }
        #expect(PauseJournal.read(from: home.journalURL) == store.current)
        #expect(store.current?.apps.count == 1)
        try store.update(header: { Self.sampleJournal([]) }) { $0.apps.append(PauseJournalApp(bundleID: nil, name: nil, appPid: 20, mode: .freeze, members: [])) }
        #expect(store.current?.apps.map(\.appPid) == [10], "apps without members are dropped")
        try store.update(header: { Self.sampleJournal([]) }) { $0.apps[0].members.removeAll() }
        #expect(store.current == nil)
        #expect(!FileManager.default.fileExists(atPath: home.journalPath))
        try store.replace(with: Self.sampleJournal([30]))
        #expect(PauseJournal.read(from: home.journalURL)?.apps.map(\.appPid) == [30])
        try store.replace(with: nil)
        #expect(!FileManager.default.fileExists(atPath: home.journalPath))
    }

    @Test func failedWriteLeavesMemoryUnchanged() throws {
        let home = try TempHome()
        defer { home.remove() }
        // The journal's directory is a regular file: every write fails.
        let blocker = home.paths.home.appending(path: "blocked", directoryHint: .notDirectory)
        try Data("x".utf8).write(to: blocker)
        let store = JournalStore(url: blocker.appending(path: "paused.json", directoryHint: .notDirectory))
        #expect(throws: (any Error).self) {
            try store.update(header: { Self.sampleJournal([]) }) { $0.apps = Self.sampleJournal([10]).apps }
        }
        #expect(store.current == nil, "the caller must not signal: nothing was journaled")
    }

    @Test func reconcileTreatsMissingRecordsAsThawed() throws {
        let home = try TempHome()
        defer { home.remove() }
        let store = JournalStore(url: home.journalURL)
        try store.replace(with: Self.sampleJournal([10, 20]))

        // The guard thawed pid 11 during a hang and rewrote the journal without it.
        var guardView = Self.sampleJournal([10, 20])
        guardView.apps[0].members.removeLast()
        try guardView.write(to: home.journalURL)
        #expect(store.reconcileWithDisk() == 1)
        #expect(store.current?.allMembers.map(\.pid) == [10, 20, 21])
        #expect(store.reconcileWithDisk() == 0)

        // …then everything: an EMPTY journal (not a missing file).
        try PauseJournal(bootSessionUUID: "BOOT-A", kakurenekoPid: 9, startedAt: Self.now, apps: []).write(to: home.journalURL)
        #expect(store.reconcileWithDisk() == 3)
        #expect(store.current == nil)
        #expect(!FileManager.default.fileExists(atPath: home.journalPath))
    }

    @Test func reconcileRewritesAMissingOrCorruptFileFromMemory() throws {
        let home = try TempHome()
        defer { home.remove() }
        let store = JournalStore(url: home.journalURL)
        try store.replace(with: Self.sampleJournal([10]))
        try FileManager.default.removeItem(at: home.journalURL)
        #expect(store.reconcileWithDisk() == 0)
        #expect(PauseJournal.read(from: home.journalURL) == store.current, "journal first: never lose a paused process")
        try Data("garbage".utf8).write(to: home.journalURL)
        #expect(store.reconcileWithDisk() == 0)
        #expect(PauseJournal.read(from: home.journalURL) == store.current)
    }

    final class EventLog: Sendable {
        private let entries = Mutex<[String]>([])
        func append(_ entry: String) { entries.withLock { $0.append(entry) } }
        var all: [String] { entries.withLock { $0 } }
    }

    @Test func asyncLockSerializesOperations() async {
        let lock = AsyncSerialLock()
        let log = EventLog()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask {
                    await lock.withLock {
                        log.append("in\(i)")
                        await Task.yield()
                        try? await Task.sleep(for: .milliseconds(2))
                        log.append("out\(i)")
                    }
                }
            }
        }
        let entries = log.all
        #expect(entries.count == 16)
        for pair in stride(from: 0, to: entries.count, by: 2) {
            #expect(entries[pair].dropFirst(2) == entries[pair + 1].dropFirst(3), "no interleaving")
        }
    }
}

/// `recheck` while paused (P-C/D/E/F + new agents → thaw & protect for the session; helper re-scan; hard cap).
@Suite("PauseManager — recheck", .timeLimit(.minutes(1)))
struct PauseManagerRecheckTests {
    static let now = PauseHarness.now

    static func pausedPair() async throws -> PauseHarness {
        let h = try PauseHarness()
        h.addApp(pid: 1000, helpers: [1001], name: "Arc")
        h.addApp(pid: 2000, helpers: [2001], name: "Slack")
        let report = await h.pause()
        #expect(report.paused.count == 2)
        h.recorder.clear()
        return h
    }

    @Test func protectionMatchThawsAndProtectsForTheSession() async throws {
        let h = try await Self.pausedPair()
        defer { h.cleanup() }
        let peer = AgentTopology(builtAt: Self.now, ipcPeers: [IPCPeerHint(peerPID: 2001, kind: .loopbackTCP, agentSidePID: 7)])
        let report = await h.recheck(topology: peer, at: Self.now.addingTimeInterval(15))
        #expect(report.thawed.map(\.appPID) == [2000])
        #expect(report.protected.first?.reasons == [.ipcPeer])
        #expect(report.paused.map(\.appPID) == [1000])
        #expect(h.recorder.calls == [.background(2001, false), .background(2000, false)])
        #expect(h.journal?.apps.map(\.appPid) == [1000])

        // Same session: Slack stays protected even though the connection is gone.
        let again = await h.pause(at: Self.now.addingTimeInterval(20))
        #expect(again.protected.first { $0.appPID == 2000 }?.reasons == [.ipcPeer])
        #expect(h.recorder.calls.count == 2)

        // A session-ending thaw resets the protections.
        _ = await h.manager.thawAll(reason: .lidOpened)
        let next = await h.pause(at: Self.now.addingTimeInterval(100))
        #expect(Set(next.paused.map(\.appPID)) == [1000, 2000])
    }

    struct Trigger: Sendable, CustomTestStringConvertible {
        var label: String
        var reason: ProtectionReason
        var topology: @Sendable (Date) -> AgentTopology = { AgentTopology(builtAt: $0) }
        var adjust: @Sendable (FakeWorld) -> Void = { _ in }
        var testDescription: String { label }
    }

    static let triggers: [Trigger] = [
        Trigger(label: "new agent inside the app", reason: .agentHost, topology: {
            AgentTopology(builtAt: $0, agentIdentities: [ProcessIdentity(pid: 1001, startSec: 0, startUsec: 0)])
        }),
        Trigger(label: "session host", reason: .agentHost, topology: { AgentTopology(builtAt: $0, sessionHostPIDs: [1000]) }),
        Trigger(label: "listener in use", reason: .listenerInUse, topology: {
            AgentTopology(builtAt: $0, ipcPeers: [IPCPeerHint(peerPID: 1000, kind: .listener, agentSidePID: 7)])
        }),
        Trigger(label: "automation helper", reason: .automationTarget, topology: {
            AgentTopology(builtAt: $0, automationHelpers: [AutomationHelperHint(helper: ProcessIdentity(pid: 7, startSec: 1, startUsec: 0), tool: "osascript")])
        }),
        Trigger(label: "audio", reason: .audio, adjust: { $0.update(1001) { $0.audio = true } }),
    ]

    @Test(arguments: triggers)
    func recheckTriggers(_ trigger: Trigger) async throws {
        let h = try await Self.pausedPair()
        defer { h.cleanup() }
        trigger.adjust(h.world)
        let report = await h.recheck(topology: trigger.topology(Self.now), at: Self.now.addingTimeInterval(15))
        #expect(report.thawed.map(\.appPID).contains(1000))
        #expect(report.protected.first { $0.appPID == 1000 }?.reasons.contains(trigger.reason) == true)
        #expect(Array(h.recorder.calls.prefix(2)) == [.background(1001, false), .background(1000, false)], "LIFO")
        #expect(h.journal?.app(1000) == nil)
    }

    @Test func hardCapThawsEverythingAndLatchesUntilTheLidOpens() async throws {
        let h = try await Self.pausedPair()
        defer { h.cleanup() }
        let capped = Self.now.addingTimeInterval(12 * 3600)
        let report = await h.recheck(at: capped)
        #expect(Set(report.thawed.map(\.appPID)) == [1000, 2000])
        #expect(report.skippedReason?.contains("hard cap") == true)
        #expect(report.paused.isEmpty && !h.journalExists)

        let blocked = await h.pause(at: capped.addingTimeInterval(60))
        #expect(blocked.paused.isEmpty && blocked.skippedReason?.contains("hard cap") == true)

        _ = await h.manager.thawAll(reason: .lidOpened)
        let resumed = await h.pause(at: capped.addingTimeInterval(120))
        #expect(resumed.paused.count == 2)
    }

    @Test func disablingPausingThawsOnRecheck() async throws {
        let h = try await Self.pausedPair()
        defer { h.cleanup() }
        let report = await h.recheck(.with { $0.enabled = false }, at: Self.now.addingTimeInterval(15))
        #expect(report.skippedReason == "pausing disabled")
        #expect(report.thawed.count == 2 && !h.journalExists)
    }

    @Test func rescanThrottlesNewHelpersEveryThrottleRescanInterval() async throws {
        let h = try await Self.pausedPair()
        defer { h.cleanup() }
        h.world.add(pid: 1005, ppid: 1000, start: Self.now.addingTimeInterval(3)) // a new XPC service / renderer
        _ = await h.recheck(at: Self.now.addingTimeInterval(10))
        #expect(h.recorder.calls.isEmpty, "not due yet (30 s)")
        let report = await h.recheck(at: Self.now.addingTimeInterval(31))
        #expect(h.recorder.calls == [.background(1005, true)])
        #expect(PauseManagerPauseTests.journaledBeforeSignalling(h.recorder))
        #expect(report.paused.first { $0.appPID == 1000 }?.memberCount == 3)
        _ = await h.recheck(at: Self.now.addingTimeInterval(45))
        #expect(h.recorder.calls.count == 1, "not due again until 61 s")
    }

    @Test func rescanNewcomerWithATTYProtectsTheApp() async throws {
        let h = try await Self.pausedPair()
        defer { h.cleanup() }
        h.world.add(pid: 1005, ppid: 1001, tty: 0x1000009)
        let report = await h.recheck(at: Self.now.addingTimeInterval(31))
        // rule I is also part of the protection re-check, so the app is thawed before the re-scan even runs
        #expect(report.thawed.map(\.appPID).contains(1000))
        #expect(report.protected.first { $0.appPID == 1000 }?.reasons.contains(.notCandidate) == true)
        #expect(!h.recorder.calls.contains(.background(1005, true)))
        #expect(h.journal?.app(1000) == nil)
    }

    @Test func recheckRereadsTheJournalTheGuardRewrote() async throws {
        let h = try await Self.pausedPair()
        defer { h.cleanup() }
        var guardView = try #require(h.journal)
        guardView.apps[0].members.removeAll { $0.pid == 1001 } // thawed by kakureneko-guard during a hang
        try guardView.write(to: h.home.journalURL)

        let report = await h.recheck(at: Self.now.addingTimeInterval(15))
        #expect(report.paused.first { $0.appPID == 1000 }?.memberCount == 1)
        #expect(h.recorder.calls.isEmpty)
        _ = await h.manager.thawAll(reason: .lidOpened)
        #expect(h.recorder.calls == [.background(2001, false), .background(2000, false), .background(1000, false)])
    }

    @Test func emptyJournalFromTheGuardMeansEverythingWasThawed() async throws {
        let h = try await Self.pausedPair()
        defer { h.cleanup() }
        try PauseJournal(bootSessionUUID: "BOOT-A", kakurenekoPid: 1, startedAt: Self.now, apps: []).write(to: h.home.journalURL)
        let report = await h.recheck(at: Self.now.addingTimeInterval(15))
        #expect(report.paused.isEmpty)
        #expect(await h.manager.thawAll(reason: .lidOpened) == 0)
        #expect(h.recorder.calls.isEmpty)
    }

    @Test func appThatQuitWhilePausedReleasesItsHelpers() async throws {
        let h = try await Self.pausedPair()
        defer { h.cleanup() }
        h.world.remove(1000)
        let report = await h.recheck(at: Self.now.addingTimeInterval(15))
        #expect(report.thawed.map(\.appPID) == [1000])
        #expect(h.recorder.calls == [.background(1001, false)])
        #expect(h.journal?.apps.map(\.appPid) == [2000])
    }

    @Test func recheckWithNothingPausedIsANoOp() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        let report = await h.recheck(at: Self.now)
        #expect(report.paused.isEmpty && report.thawed.isEmpty && report.skippedReason == nil)
    }
}
