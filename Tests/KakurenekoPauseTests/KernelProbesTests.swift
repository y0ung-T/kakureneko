import Darwin
import KakurenekoKit
@testable import KakurenekoPause
import Foundation
import Testing

/// Read-only kernel probes and the three grouping strategies. Assertions never depend on machine state (which apps
/// run, battery, lid): they use the test process itself and children it spawned.
@Suite("Kernel probes and grouping", .timeLimit(.minutes(1)))
struct KernelProbesTests {
    @Test func entryMatchesTheKitReferenceIdentity() throws {
        let me = getpid()
        let entry = try #require(Kernel.entry(of: me))
        #expect(entry.identity == KernelProcessLookup().identity(of: me))
        #expect(entry.uid == getuid())
        #expect(entry.isOwned(by: getuid()))
        #expect(!entry.isZombie && !entry.isStopped)
        #expect(Kernel.entry(of: 0) == nil)
        #expect(Kernel.entry(of: -5) == nil)
    }

    @Test func enrichmentAddsUniqueIDAndPidVersion() throws {
        let child = try SpawnedChild.sleep()
        defer { child.terminate() }
        let plain = try child.identity
        let enriched = try #require(Kernel.enrich(plain))
        let unique = try #require(Kernel.uniqueIdentifier(of: child.pid))
        #expect(enriched == plain)
        #expect(enriched.uniqueID == unique.uniqueID)
        #expect(enriched.pidVersion == unique.idVersion)
        if let token = Kernel.auditToken(of: child.pid) {
            #expect(token.val.7 == enriched.pidVersion, "audit token val[7] == p_idversion")
        }
        #expect(Kernel.enrich(enriched) == enriched, "re-enrichment is stable")

        var wrongStart = plain
        wrongStart.startSec += 1
        #expect(Kernel.enrich(wrongStart) == nil)
        var wrongUnique = enriched
        wrongUnique.uniqueID = enriched.uniqueID.map { $0 &+ 1 }
        #expect(Kernel.enrich(wrongUnique) == nil)
        var wrongVersion = enriched
        wrongVersion.pidVersion = enriched.pidVersion.map { $0 &+ 1 }
        #expect(Kernel.enrich(wrongVersion) == nil)
    }

    @Test func enrichmentFailsForGoneProcesses() throws {
        let child = try SpawnedChild.sleep()
        let plain = try child.identity
        child.terminate()
        #expect(Kernel.enrich(plain) == nil)
        #expect(Kernel.uniqueIdentifier(of: child.pid) == nil || KernelProcessLookup().identity(of: child.pid) != plain)
    }

    @Test func processTableSeesChildrenAndAncestry() throws {
        let child = try SpawnedChild.sleep()
        defer { child.terminate() }
        let table = try #require(Kernel.processTable())
        let me = getpid()
        #expect(table[me] != nil)
        let row = try #require(table[child.pid])
        #expect(row.ppid == me)
        #expect(row.ttyDevice == nil, "spawned with POSIX_SPAWN_SETSID: no controlling tty")
        #expect(table.descendants(of: me).contains(child.pid))
        #expect(table.ancestors(of: child.pid).first == me)
        #expect(Kernel.executablePath(of: child.pid) == "/bin/sleep")
        #expect(!Kernel.isTraced(child.pid))
        _ = Kernel.dirtyFlags(of: child.pid) // readable or not: must not crash
    }

    @Test func stoppedStateIsVisible() async throws {
        let child = try SpawnedChild.sleep()
        defer { child.terminate() }
        #expect(!Kernel.isStopped(child.pid))
        await child.stop()
        #expect(Kernel.isStopped(child.pid))
        #expect(Kernel.entry(of: child.pid)?.isStopped == true)
    }

    @Test func systemReadsAreStable() throws {
        let boot = try #require(Kernel.bootSessionUUID())
        #expect(!boot.isEmpty)
        #expect(Kernel.bootSessionUUID() == boot)
        let first = try #require(Kernel.cpuNanoseconds(of: getpid()))
        var spin: UInt64 = 0
        for i in 0..<200_000 { spin &+= UInt64(i) }
        #expect(spin > 0)
        let second = try #require(Kernel.cpuNanoseconds(of: getpid()))
        #expect(second >= first)
        let a = Kernel.uptimeNanoseconds()
        #expect(Kernel.uptimeNanoseconds() >= a)
        if let level = Kernel.memoryPressureLevel() { #expect(level >= 0) }
    }

    @Test func quitSafetyFromDirtyFlags() {
        #expect(Kernel.isCleanForQuit(dirtyFlags: 0x1), "tracked + clean")
        #expect(Kernel.isCleanForQuit(dirtyFlags: 0x3), "tracked + allows idle exit + clean")
        #expect(!Kernel.isCleanForQuit(dirtyFlags: 0x5), "tracked + dirty")
        #expect(!Kernel.isCleanForQuit(dirtyFlags: 0x0), "not tracked")
        #expect(!Kernel.isCleanForQuit(dirtyFlags: nil), "unreadable")
    }

    @Test func downloadFilePatterns() {
        #expect(DownloadFiles.isInProgress("/Users/u/Downloads/movie.mp4.crdownload"))
        #expect(DownloadFiles.isInProgress("/Users/u/Downloads/file.zip.part"))
        #expect(DownloadFiles.isInProgress("/Users/u/Downloads/archive.zip.download"))
        #expect(DownloadFiles.isInProgress("/Users/u/Downloads/archive.zip.download/archive.zip"))
        #expect(DownloadFiles.isInProgress("/X/Y.CRDOWNLOAD"))
        #expect(!DownloadFiles.isInProgress("/Users/u/Documents/report.pdf"))
        #expect(!DownloadFiles.isInProgress("/Users/u/Downloads"))
        #expect(!DownloadFiles.isInProgress("/Users/u/partition.txt"))
    }

    @Test func memoryPressureLevels() {
        #expect(MemoryPressure(sysctlLevel: 0) == .normal)
        #expect(MemoryPressure(sysctlLevel: 1) == .normal)
        #expect(MemoryPressure(sysctlLevel: 2) == .warning)
        #expect(MemoryPressure(sysctlLevel: 4) == .critical)
        #expect(MemoryPressure.warning >= .warning && MemoryPressure.critical > .warning && MemoryPressure.normal < .warning)
    }

    @Test func liveProbeReadsOwnChild() throws {
        let child = try SpawnedChild.sleep()
        defer { child.terminate() }
        let probe = LiveSystemProbe()
        #expect(probe.userID == getuid())
        #expect(probe.processTable()?[child.pid] != nil)
        #expect(probe.enrich(try child.identity) != nil)
        #expect(probe.executablePath(of: child.pid) == "/bin/sleep")
        #expect(!probe.hasDownloadInProgress(child.pid))
        #expect(!probe.isTraced(child.pid))
        #expect(!probe.isStopped(child.pid))
        #expect(probe.audioActivePIDs(among: [child.pid]).isEmpty, "sleep plays no audio")
        #expect(probe.bootSessionUUID() == Kernel.bootSessionUUID())
        probe.startMemoryPressureMonitoring()
        probe.startMemoryPressureMonitoring() // idempotent
        _ = probe.memoryPressure()
    }

    // MARK: Grouping

    /// table: 100 (main, owned) → 101, 102 (owned), 103 (other uid), 104 (zombie) ; 102 → 105 (owned grandchild)
    static func syntheticTable() -> ProcessTable {
        ProcessTable([
            ProcessEntry(pid: 100, ppid: 1, uid: 501, startSec: 10, startUsec: 0),
            ProcessEntry(pid: 101, ppid: 100, uid: 501, startSec: 11, startUsec: 0),
            ProcessEntry(pid: 102, ppid: 100, uid: 501, startSec: 12, startUsec: 0),
            ProcessEntry(pid: 103, ppid: 100, uid: 0, startSec: 13, startUsec: 0),
            ProcessEntry(pid: 104, ppid: 100, uid: 501, startSec: 14, startUsec: 0, stat: Int8(SZOMB)),
            ProcessEntry(pid: 105, ppid: 102, uid: 501, startSec: 15, startUsec: 0),
            ProcessEntry(pid: 200, ppid: 1, uid: 0, startSec: 20, startUsec: 0),
            ProcessEntry(pid: 201, ppid: 200, uid: 501, startSec: 21, startUsec: 0),
            ProcessEntry(pid: 300, ppid: 1, uid: 501, startSec: 30, startUsec: 0),
        ])
    }

    @Test func parentTreeGroupingKeepsOwnedLiveDescendantsMainFirst() {
        let table = Self.syntheticTable()
        let groups = ParentTreeGrouping().groups(for: [100, 200, 999], in: table, uid: 501)
        #expect(groups[100] == [100, 101, 102, 105])
        #expect(groups[200] == [201], "a root-owned main is never a member itself")
        #expect(groups[999] == [], "unknown main → empty group")
        #expect(ParentTreeGrouping().method == .parentTree)
    }

    @Test func coalitionGroupingUsesInjectedCoalitions() {
        let table = Self.syntheticTable()
        let coalitions: [pid_t: UInt64] = [100: 7, 101: 7, 102: 7, 103: 7, 105: 8, 300: 7, 201: 9]
        let grouping = CoalitionGrouping(coalitionID: { coalitions[$0] })
        let groups = grouping.groups(for: [100, 201], in: table, uid: 501)
        // 103 is another user's; 105 is in another coalition; 300 shares coalition 7 (a directly spawned app).
        #expect(groups[100] == [100, 101, 102, 300])
        #expect(groups[201] == [201])
        #expect(grouping.method == .coalition)
    }

    @Test func overlappingGroupsAreConflicts() {
        #expect(GroupOverlap.conflictingMains([1: [1, 2, 3], 4: [4, 5]]).isEmpty)
        #expect(GroupOverlap.conflictingMains([1: [1, 2, 3], 4: [4, 3]]) == [1, 4])
        #expect(GroupOverlap.conflictingMains([1: [1, 4], 4: [4]]) == [1, 4], "an app inside another app's group")
    }

    @Test func liveGroupingResolverFindsAMethod() throws {
        let selection = LiveGroupingResolver().resolve(selfPID: getpid())
        #expect(selection.grouping != nil)
        #expect(selection.selfTest.method != .unavailable)
        #expect(selection.selfTest.freezeAllowed == (selection.selfTest.method == .responsibility || selection.selfTest.method == .coalition))
    }

    @Test func responsibilityAPIAgreesForAChild() throws {
        guard let api = ResponsibilityAPI.resolve() else { return } // OS without the private symbol: nothing to check
        let child = try SpawnedChild.sleep()
        defer { child.terminate() }
        let mine = api.responsiblePID(for: getpid())
        let childs = api.responsiblePID(for: child.pid)
        if let mine, let childs { #expect(mine == childs, "a spawned child inherits its parent's responsible process") }
    }
}
