import Darwin
import KakurenekoKit
@testable import KakurenekoPause
import Foundation
import Synchronization
import Testing

/// `PauseManager.pause` over a synthetic world (injected candidates, process table and signaller — never real apps).
@Suite("PauseManager — pause", .timeLimit(.minutes(1)))
struct PauseManagerPauseTests {
    static let now = PauseHarness.now

    /// Every pausing call (stop / throttle) found its own record in the journal file AS IT WAS ON DISK at call time.
    static func journaledBeforeSignalling(_ recorder: RecordingSignaller) -> Bool {
        recorder.records.allSatisfy { record in
            switch record.call {
            case .stop(let pid):
                return record.journal?.allMembers.contains { $0.pid == pid && $0.action == .sigstop } == true
            case .background(let pid, true):
                return record.journal?.allMembers.contains { $0.pid == pid && $0.action == .darwinBackground } == true
            case .terminate(let pid):
                return record.journal?.allMembers.contains { $0.pid == pid && $0.action == .terminate } == true
            default:
                return true
            }
        }
    }

    // MARK: Throttle

    @Test func throttleIsTheDefaultAndTheJournalComesFirst() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001, 1002], name: "Arc")

        let report = await h.pause()
        #expect(report.skippedReason == nil && report.failures.isEmpty)
        #expect(report.paused.map(\.appPID) == [1000])
        #expect(report.paused.first?.mode == .throttle)
        #expect(report.paused.first?.memberCount == 3)
        #expect(report.paused.first?.name == "Arc")
        #expect(report.summary == "Throttled Arc")
        #expect(h.recorder.calls == [.background(1000, true), .background(1001, true), .background(1002, true)])
        #expect(Self.journaledBeforeSignalling(h.recorder))

        let journal = try #require(h.journal)
        #expect(journal.bootSessionUUID == "BOOT-A")
        #expect(journal.kakurenekoPid == h.selfPID)
        #expect(journal.startedAt == Self.now)
        let app = try #require(journal.app(1000))
        #expect(app.mode == .throttle && !app.simulated && app.bundleID == "test.app1000" && app.name == "Arc")
        #expect(app.members.map(\.pid) == [1000, 1001, 1002], "main first")
        for member in app.members {
            let process = try #require(h.world.process(member.pid))
            #expect(member.uniqueID == process.uniqueID && member.pidVersion == process.pidVersion)
            #expect(member.startSec == process.entry.startSec && member.startUsec == process.entry.startUsec)
            #expect(member.action == .darwinBackground)
            #expect(member.path == process.path)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: h.home.journalPath)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(await h.manager.pausedApps().map(\.appPID) == [1000])
        #expect(h.world.process(1002)?.darwinBackground == true)
    }

    @Test func unenrichedMembersAreNeitherJournaledNorSignalled() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001, 1002])
        h.world.update(1002) { $0.enrichable = false }

        let report = await h.pause()
        #expect(report.paused.first?.memberCount == 2)
        #expect(!h.recorder.calls.contains(.background(1002, true)))
        #expect(h.journal?.allMembers.map(\.pid) == [1000, 1001])
        #expect(h.journal?.allMembers.allSatisfy { $0.identity.uniqueID != nil && $0.identity.pidVersion != nil } == true)
    }

    @Test func unenrichableMainIsProtectedAsUncertain() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001])
        h.world.update(1000) { $0.enrichable = false }

        let report = await h.pause()
        #expect(report.paused.isEmpty)
        #expect(report.protected.first?.reasons == [.uncertain])
        #expect(h.recorder.calls.isEmpty)
        #expect(!h.journalExists)
    }

    @Test func alreadyBackgroundMembersAreSkippedAndLeftAlone() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001, 1002])
        h.world.update(1001) { $0.darwinBackground = true } // App Tamer / taskpolicy -b / the user

        _ = await h.pause()
        #expect(h.recorder.calls == [.background(1000, true), .background(1002, true)])
        #expect(h.journal?.allMembers.map(\.pid) == [1000, 1002])

        h.recorder.clear()
        #expect(await h.manager.thawAll(reason: .lidOpened) == 2)
        #expect(h.recorder.calls == [.background(1002, false), .background(1000, false)])
        #expect(h.world.process(1001)?.darwinBackground == true, "restoring to 0 would have undone someone else's choice")
    }

    @Test func groupAlreadyFullyInBackgroundIsNotPaused() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001])
        h.world.update(1000) { $0.darwinBackground = true }
        h.world.update(1001) { $0.darwinBackground = true }

        let report = await h.pause()
        #expect(report.paused.isEmpty && report.failures.isEmpty)
        #expect(h.recorder.calls.isEmpty)
        #expect(!h.journalExists)
    }

    @Test func thawIsLIFOPerGroupAndClearsTheJournal() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001])
        h.addApp(pid: 2000, helpers: [2001, 2002])
        _ = await h.pause()
        #expect(h.journal?.apps.map(\.appPid) == [1000, 2000])

        h.recorder.clear()
        #expect(await h.manager.thawAll(reason: .lidOpened) == 5)
        #expect(h.recorder.calls == [
            .background(2002, false), .background(2001, false), .background(2000, false),
            .background(1001, false), .background(1000, false),
        ])
        #expect(!h.journalExists)
        #expect(await h.manager.pausedApps().isEmpty)
        #expect(await h.manager.thawAll(reason: .lidOpened) == 0, "idempotent")
    }

    @Test func throttleVerificationFailureOfTheMainUndoesTheGroup() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001, 1002])
        h.recorder.makeIneffective(.background(1000, true))

        let report = await h.pause()
        #expect(report.paused.isEmpty)
        #expect(report.failures.map(\.appPID) == [1000])
        #expect(h.world.process(1001)?.darwinBackground == false && h.world.process(1002)?.darwinBackground == false)
        #expect(!h.journalExists)
    }

    @Test func helperThatDoesNotThrottleIsDropped() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001, 1002])
        h.recorder.makeIneffective(.background(1002, true))
        h.recorder.fail(.background(1001, true), with: .notPermitted("EPERM"))

        let report = await h.pause()
        #expect(report.paused.first?.memberCount == 1)
        #expect(h.journal?.allMembers.map(\.pid) == [1000])
    }

    // MARK: Freeze

    @Test func freezeStopsMainFirstAndThawsLIFO() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001, 1002], name: "Word")
        await h.observeIdle()
        h.manager.installCrashHandlers()
        h.manager.installCrashHandlers()
        #expect(h.crash.installs == 1, "installed once")

        let report = await h.pause(.freeze)
        let paused = try #require(report.paused.first)
        #expect(paused.mode == .freeze && paused.memberCount == 3 && paused.downgradedBecause == nil)
        #expect(report.summary == "Paused Word")
        #expect(h.recorder.calls == [.stop(1000), .stop(1001), .stop(1002)])
        #expect(Self.journaledBeforeSignalling(h.recorder))
        #expect(h.journal?.allMembers.allSatisfy { $0.action == .sigstop } == true)
        #expect(h.journal?.app(1000)?.mode == .freeze)
        #expect(h.crash.latest == [1000, 1001, 1002], "the crash handler can SIGCONT every frozen pid")

        h.recorder.clear()
        #expect(await h.manager.thawAll(reason: .userInput) == 3)
        #expect(h.recorder.calls == [.cont(1002), .cont(1001), .cont(1000)])
        #expect(h.crash.latest == [])
        #expect([1000, 1001, 1002].allSatisfy { !h.world.isStopped($0) })
        #expect(!h.journalExists)
    }

    @Test func freezeIsRefusedWhenTheSelfTestDisallowsIt() async throws {
        let h = try PauseHarness(selfTest: GroupingSelfTest(method: .parentTree, freezeAllowed: false))
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001])
        await h.observeIdle()
        let report = await h.pause(.freeze)
        #expect(report.paused.first?.mode == .throttle)
        #expect(report.paused.first?.downgradedBecause == .uncertain)
        #expect(!h.recorder.calls.contains { if case .stop = $0 { true } else { false } })
    }

    @Test func freezeIsRefusedOnAnIncompleteTopology() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001])
        await h.observeIdle()
        let report = await h.pause(.freeze, topology: AgentTopology(builtAt: Self.now, isComplete: false))
        #expect(report.paused.first?.mode == .throttle)
        #expect(report.paused.first?.downgradedBecause == .uncertain)
        #expect(h.recorder.calls == [.background(1000, true), .background(1001, true)])
    }

    @Test func noCPUHistoryMeansNoFreeze() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000)
        let report = await h.pause(.freeze)
        #expect(report.paused.first?.mode == .throttle)
        #expect(report.paused.first?.downgradedBecause == .busyAtLidClose)
        #expect(await h.manager.pausedApps().first?.downgradedBecause == .busyAtLidClose)
    }

    @Test func busyAtLidCloseDowngradesToThrottle() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001])
        await h.manager.observe(now: Self.now.addingTimeInterval(-90))
        h.world.addCPU(1001, nanoseconds: 45_000_000_000) // 45 s of CPU in 90 s = 50 % of a core
        await h.manager.observe(now: Self.now)
        let report = await h.pause(.freeze)
        #expect(report.paused.first?.mode == .throttle)
        #expect(report.paused.first?.downgradedBecause == .busyAtLidClose)
        #expect(h.world.monitoringStarts >= 1, "observe lazily owns the memory-pressure source")
    }

    @Test func downloadDowngradesToThrottle() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001])
        h.world.update(1001) { $0.downloading = true }
        await h.observeIdle()
        let report = await h.pause(.freeze)
        #expect(report.paused.first?.mode == .throttle)
        #expect(report.paused.first?.downgradedBecause == .download)
    }

    @Test func freezeStopsNewcomersSpawnedDuringTheFreeze() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001])
        await h.observeIdle()
        let world = h.world
        h.recorder.afterStopping(1000) { world.add(pid: 1003, ppid: 1000, start: FakeWorld.defaultStart.addingTimeInterval(5)) }

        let report = await h.pause(.freeze)
        #expect(report.paused.first?.memberCount == 3)
        #expect(h.recorder.calls == [.stop(1000), .stop(1001), .stop(1003)])
        #expect(Self.journaledBeforeSignalling(h.recorder))
        #expect(h.journal?.allMembers.map(\.pid) == [1000, 1001, 1003])
    }

    @Test func newcomerWithATTYThawsAndProtectsTheGroup() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001])
        await h.observeIdle()
        let world = h.world
        h.recorder.afterStopping(1001) { world.add(pid: 1003, ppid: 1001, tty: 0x1000007) }

        let report = await h.pause(.freeze)
        #expect(report.paused.isEmpty)
        #expect(report.protected.first?.reasons == [.notCandidate])
        #expect(![1000, 1001].contains { world.isStopped($0) })
        #expect(!h.journalExists)
    }

    @Test func partialFreezeFailureThawsTheGroup() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001, 1002])
        await h.observeIdle()
        h.recorder.fail(.stop(1001), with: .notPermitted("EPERM"))

        let report = await h.pause(.freeze)
        #expect(report.paused.isEmpty)
        #expect(report.failures.map(\.appPID) == [1000])
        #expect(![1000, 1001, 1002].contains { h.world.isStopped($0) }, "never left half-frozen")
        #expect(h.recorder.calls.last == .cont(1000), "main thawed last")
        #expect(!h.journalExists)
    }

    @Test func helperThatVanishedDuringTheFreezeIsDropped() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001, 1002])
        await h.observeIdle()
        h.recorder.fail(.stop(1002), with: .processGone)

        let report = await h.pause(.freeze)
        #expect(report.paused.first?.memberCount == 2)
        #expect(h.journal?.allMembers.map(\.pid) == [1000, 1001])
    }

    @Test func freezeVerificationFailureThawsTheGroup() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001, 1002])
        await h.observeIdle()
        h.recorder.makeIneffective(.stop(1002)) // "succeeds" but p_stat never becomes SSTOP

        let report = await h.pause(.freeze)
        #expect(report.paused.isEmpty)
        #expect(report.failures.first?.message.contains("did not stop") == true)
        #expect(![1000, 1001, 1002].contains { h.world.isStopped($0) })
        #expect(!h.journalExists)
    }

    // MARK: Protections and candidates

    struct ProtectionCase: Sendable, CustomTestStringConvertible {
        var label: String
        var expected: ProtectionReason
        var bundleID: String?
        var settings = PauseSettings()
        var topology: @Sendable (Date) -> AgentTopology = { AgentTopology(builtAt: $0) }
        var adjust: @Sendable (FakeWorld) -> Void = { _ in }
        var testDescription: String { label }
    }

    static let protectionCases: [ProtectionCase] = [
        ProtectionCase(label: "P-A agent descendant in the group", expected: .agentHost, topology: {
            AgentTopology(builtAt: $0, descendantIdentities: [ProcessIdentity(pid: 1002, startSec: Int64(FakeWorld.defaultStart.timeIntervalSince1970) + 1, startUsec: 0)])
        }),
        ProtectionCase(label: "P-A pty master holder", expected: .agentHost, topology: { AgentTopology(builtAt: $0, ptyMasterHolderPIDs: [1001]) }),
        ProtectionCase(label: "P-A session host app", expected: .agentHost, topology: { AgentTopology(builtAt: $0, sessionHostPIDs: [1000]) }),
        ProtectionCase(label: "P-B launched by an agent", expected: .launchedByAgent, topology: { AgentTopology(builtAt: $0, agentLaunchedAppPIDs: [1000]) }),
        ProtectionCase(label: "P-C IPC peer", expected: .ipcPeer, topology: {
            AgentTopology(builtAt: $0, ipcPeers: [IPCPeerHint(peerPID: 1002, kind: .unixSocket, agentSidePID: 7)])
        }),
        ProtectionCase(label: "P-D listener", expected: .listenerInUse, topology: {
            AgentTopology(builtAt: $0, ipcPeers: [IPCPeerHint(peerPID: 1001, kind: .listener, agentSidePID: 7)])
        }),
        ProtectionCase(label: "P-E automation, unknown target", expected: .automationTarget, topology: {
            AgentTopology(builtAt: $0, automationHelpers: [AutomationHelperHint(helper: ProcessIdentity(pid: 7, startSec: 1, startUsec: 0), tool: "open")])
        }),
        ProtectionCase(label: "P-F audio", expected: .audio, adjust: { $0.update(1002) { $0.audio = true } }),
        ProtectionCase(label: "P-H traced", expected: .traced, adjust: { $0.update(1001) { $0.traced = true } }),
        ProtectionCase(label: "P-J static never-list", expected: .staticNeverList, bundleID: "com.apple.Terminal"),
        ProtectionCase(label: "P-K user never-list", expected: .userNeverList, bundleID: "com.example.mine",
                       settings: .with { $0.neverPauseBundleIDs = ["com.example.mine"] }),
        ProtectionCase(label: "rule I: a helper has a tty", expected: .notCandidate,
                       adjust: { $0.update(1002) { $0.entry.ttyDevice = 0x1000003 } }),
    ]

    @Test(arguments: protectionCases)
    func protectedGroupsAreReportedAndNeverTouched(_ c: ProtectionCase) async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001, 1002], bundleID: c.bundleID)
        c.adjust(h.world)
        await h.observeIdle()

        for mode in [PauseMode.throttle, .freeze] {
            var settings = c.settings
            settings.mode = mode
            let report = await h.pause(settings, topology: c.topology(Self.now))
            #expect(report.paused.isEmpty)
            #expect(report.protected.map(\.appPID) == [1000])
            #expect(report.protected.first?.reasons.contains(c.expected) == true)
        }
        #expect(h.recorder.calls.isEmpty)
        #expect(!h.journalExists)
    }

    @Test func candidateFilters() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, regular: false)                                   // .accessory: never a candidate
        h.addApp(pid: 2000, finished: false)                                  // still launching
        h.world.add(pid: 3000, uid: 0)                                        // another user's app
        h.candidates.append(AppCandidate(pid: 3000, bundleID: "root.app", localizedName: "Root"))
        h.addApp(pid: 4000, start: Self.now.addingTimeInterval(5))            // launched after the pause began
        h.world.add(pid: h.selfPID)                                           // Kakureneko itself
        h.candidates.append(AppCandidate(pid: h.selfPID, bundleID: KakurenekoID.bundleIdentifier, localizedName: "Kakureneko"))
        h.addApp(pid: 5000, bundleID: KakurenekoID.bundleIdentifier)            // another Kakureneko instance
        h.candidates.append(AppCandidate(pid: 6000, bundleID: "gone.app"))  // not in the process table

        let report = await h.pause()
        let reasons = Dictionary(uniqueKeysWithValues: report.protected.map { ($0.appPID, $0.reasons) })
        #expect(reasons[1000] == nil, "non-regular apps are not even reported")
        #expect(reasons[2000] == [.notCandidate])
        #expect(reasons[3000] == [.notCandidate])
        #expect(reasons[4000] == [.launchedAfterPause])
        #expect(reasons[h.selfPID] == [.kakurenekoItself])
        #expect(reasons[5000] == [.kakurenekoItself])
        #expect(reasons[6000] == nil)
        #expect(report.paused.isEmpty)
        #expect(h.recorder.calls.isEmpty)
    }

    @Test func appsLaunchedAfterTheSessionBeganAreLeftAlone() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000)
        _ = await h.pause()
        h.addApp(pid: 2000, start: Self.now.addingTimeInterval(30)) // the agent (or a remote user) opened it
        let later = await h.pause(at: Self.now.addingTimeInterval(60))
        #expect(later.protected.first { $0.appPID == 2000 }?.reasons == [.launchedAfterPause])
        #expect(later.paused.map(\.appPID) == [1000], "already paused app stays paused, not re-signalled")
        #expect(h.recorder.calls == [.background(1000, true)])
    }

    @Test func overlappingGroupsAreUncertain() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001])
        // An app spawned directly by another app: it lies inside the first app's group.
        h.world.add(pid: 2000, ppid: 1000)
        h.candidates.append(AppCandidate(pid: 2000, bundleID: "child.app", localizedName: "Child"))

        let report = await h.pause()
        #expect(Set(report.protected.map(\.appPID)) == [1000, 2000])
        #expect(report.protected.allSatisfy { $0.reasons == [.uncertain] })
        #expect(h.recorder.calls.isEmpty)
    }

    @Test func skippedWhenDisabledOrPreconditionsFail() async throws {
        let disabled = try PauseHarness()
        defer { disabled.cleanup() }
        disabled.addApp(pid: 1000)
        #expect(await disabled.pause(.with { $0.enabled = false }).skippedReason == "pausing disabled")

        let noGrouping = try PauseHarness(selfTest: GroupingSelfTest(method: .unavailable, freezeAllowed: false), grouping: nil)
        defer { noGrouping.cleanup() }
        noGrouping.addApp(pid: 1000)
        #expect(await noGrouping.pause().skippedReason == "grouping self-test failed")

        let noTable = try PauseHarness()
        defer { noTable.cleanup() }
        noTable.addApp(pid: 1000)
        noTable.world.setTableAvailable(false)
        #expect(await noTable.pause().skippedReason == "process table unavailable")

        let noBoot = try PauseHarness()
        defer { noBoot.cleanup() }
        noBoot.addApp(pid: 1000)
        noBoot.world.setBoot(nil)
        #expect(await noBoot.pause().skippedReason == "boot session unavailable")

        for h in [disabled, noGrouping, noTable, noBoot] {
            #expect(h.recorder.calls.isEmpty)
            #expect(!h.journalExists)
        }
    }

    @Test func staleGenerationAbortsBeforeAnySignal() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000)
        let stale = h.manager.signalGate.withLock { $0.generation }
        h.manager.signalGate.withLock { $0.generation &+= 1 } // a thaw started meanwhile
        let report = await h.manager.pauseLocked(topology: AgentTopology(builtAt: Self.now), settings: PauseSettings(),
                                                 now: Self.now, generation: stale)
        #expect(report.skippedReason == "interrupted by a thaw")
        if case .aborted = h.manager.perform(stale, {}) {} else { Issue.record("perform must refuse a stale generation") }
        if case .done = h.manager.perform(h.manager.signalGate.withLock { $0.generation }, {}) {} else { Issue.record("current generation runs") }
        #expect(h.recorder.calls.isEmpty)
    }

    @Test func selfTestReportsTheResolverResult() async throws {
        let h = try PauseHarness(selfTest: GroupingSelfTest(method: .coalition, freezeAllowed: true, detail: "x"))
        defer { h.cleanup() }
        let result = await h.manager.selfTest()
        #expect(result.method == .coalition && result.freezeAllowed)
    }

    // MARK: Dry-run

    @Test func dryRunThrottleWritesSimulatedJournalAndSkipsVerification() async throws {
        let h = try PauseHarness(dryRun: true)
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001, 1002])
        h.manager.installCrashHandlers()

        let report = await h.pause()
        #expect(report.paused.first?.memberCount == 3, "counted as succeeded without verification")
        #expect(report.failures.isEmpty)
        #expect(h.recorder.calls.isEmpty, "nothing reached the real signaller")
        #expect(h.ledger.entries(action: "priority.background").count == 3)
        #expect(h.journal?.apps.first?.simulated == true)
        #expect(h.world.process(1000)?.darwinBackground == false)

        #expect(await h.manager.thawAll(reason: .lidOpened) == 3)
        #expect(h.ledger.entries(action: "priority.normal").count == 3)
        #expect(!h.journalExists)
        #expect(h.crash.published.allSatisfy { $0.isEmpty }, "the crash-handler array stays empty in dry-run")
    }

    @Test func dryRunFreezeKeepsTheCrashBufferEmpty() async throws {
        let h = try PauseHarness(dryRun: true)
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001])
        await h.observeIdle()
        h.manager.installCrashHandlers()

        let report = await h.pause(.freeze)
        #expect(report.paused.first?.mode == .freeze)
        #expect(h.ledger.entries(action: "signal.stop").count == 2)
        #expect(h.recorder.calls.isEmpty)
        #expect(h.journal?.apps.first?.simulated == true)
        #expect(!h.crash.published.isEmpty && h.crash.published.allSatisfy { $0.isEmpty })
        #expect(await h.manager.thawAll(reason: .willSleep) == 2)
        #expect(h.ledger.entries(action: "signal.cont").count == 2)
    }

    @Test func dryRunNeverSpawnsTheGuard() throws {
        let h = try PauseHarness(dryRun: true, guardExecutable: Products.guardExecutable)
        defer { h.cleanup() }
        try h.manager.startGuard()
        #expect(h.manager.guardProcess == nil)
        #expect(h.manager.guardSpawnCount == 0)
        // The decision stays visible (ARCHITECTURE §6 ledger action `pause.guard`).
        #expect(h.ledger.entries(action: "pause.guard").count == 1)
    }

    // MARK: Quit (opt-in, memory pressure, clean apps only)

    static func quitHarness(dryRun: Bool = false) async throws -> PauseHarness {
        let h = try PauseHarness(dryRun: dryRun)
        h.addApp(pid: 1000, helpers: [1001], name: "Pages")
        h.world.setPressure(.warning)
        h.world.setDirty(1000, 0x1) // tracked, clean
        await h.observeIdle()
        return h
    }

    static let quitSettings = PauseSettings.with { $0.quitWhenMemoryLow = true }

    @Test func quitTerminatesCleanAppsAndRelaunchesOnLidOpen() async throws {
        let h = try await Self.quitHarness()
        defer { h.cleanup() }
        let report = await h.pause(Self.quitSettings)
        #expect(report.paused.first?.mode == .quit)
        #expect(report.paused.first?.memberCount == 1)
        #expect(h.recorder.calls == [.terminate(1000)])
        #expect(Self.journaledBeforeSignalling(h.recorder))
        let record = try #require(h.journal?.allMembers.first)
        #expect(record.action == .terminate && record.path == "/Applications/App1000.app", "journaled with the BUNDLE path")
        h.candidates.set([]) // it quit: NSWorkspace no longer lists it

        h.recorder.clear()
        _ = await h.manager.thawAll(reason: .willSleep)
        #expect(h.recorder.calls.isEmpty, "never relaunched before sleep")
        #expect(h.journal?.allMembers.first?.action == .terminate, "kept for a later lid-open")
        #expect(await h.manager.pausedApps().first?.mode == .quit)

        _ = await h.manager.thawAll(reason: .lidOpened)
        #expect(h.recorder.calls == [.relaunch("/Applications/App1000.app")])
        #expect(!h.journalExists)
    }

    @Test func quitIsNotRelaunchedWhenTheAppNeverQuitOrRunsAgain() async throws {
        let h = try await Self.quitHarness()
        defer { h.cleanup() }
        h.recorder.setTerminateRemovesProcess(false) // refused to quit (e.g. a save dialog)
        _ = await h.pause(Self.quitSettings)
        h.recorder.clear()
        _ = await h.manager.thawAll(reason: .lidOpened)
        #expect(h.recorder.calls.isEmpty)
        #expect(!h.journalExists)

        let reopened = try await Self.quitHarness()
        defer { reopened.cleanup() }
        _ = await reopened.pause(Self.quitSettings)
        reopened.candidates.set([AppCandidate(pid: 1999, bundleID: "test.app1000")]) // the user reopened it
        reopened.recorder.clear()
        _ = await reopened.manager.thawAll(reason: .userRequest)
        #expect(reopened.recorder.calls.isEmpty)
        #expect(!reopened.journalExists)
    }

    struct QuitGate: Sendable, CustomTestStringConvertible {
        var label: String
        var adjust: @Sendable (PauseHarness) -> Void
        var settings = PauseManagerPauseTests.quitSettings
        var topologyComplete = true
        var testDescription: String { label }
    }

    static let quitGates: [QuitGate] = [
        QuitGate(label: "opt-in off", adjust: { _ in }, settings: PauseSettings()),
        QuitGate(label: "memory pressure normal", adjust: { $0.world.setPressure(.normal) }),
        QuitGate(label: "dirty", adjust: { $0.world.setDirty(1000, 0x5) }),
        QuitGate(label: "not tracked", adjust: { $0.world.setDirty(1000, 0x0) }),
        QuitGate(label: "dirty flags unreadable", adjust: { $0.world.clearDirty(1000) }),
        QuitGate(label: "downloading", adjust: { $0.world.update(1001) { $0.downloading = true } }),
        QuitGate(label: "incomplete topology", adjust: { _ in }, topologyComplete: false),
    ]

    @Test(arguments: quitGates)
    func quitRequiresEveryGate(_ gate: QuitGate) async throws {
        let h = try await Self.quitHarness()
        defer { h.cleanup() }
        gate.adjust(h)
        let report = await h.pause(gate.settings, topology: AgentTopology(builtAt: Self.now, isComplete: gate.topologyComplete))
        #expect(report.paused.first?.mode == .throttle)
        #expect(!h.recorder.calls.contains(.terminate(1000)))
    }

    @Test(arguments: ThawReason.allCases)
    func relaunchOnlyForTheAllowedReasons(_ reason: ThawReason) async throws {
        let h = try await Self.quitHarness(dryRun: true)
        defer { h.cleanup() }
        _ = await h.pause(Self.quitSettings)
        #expect(h.ledger.entries(action: "app.terminate").count == 1)
        _ = await h.manager.thawAll(reason: reason)
        let allowed: Set<ThawReason> = [.lidOpened, .userRequest, .externalDisplay, .userInput]
        #expect(h.ledger.entries(action: "app.relaunch").count == (allowed.contains(reason) ? 1 : 0))
        #expect(h.recorder.calls.isEmpty)
    }

    @Test func thawAllSynchronouslyIsLIFONoRelaunchAndBlocksLaterPauses() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001])
        h.addApp(pid: 2000)
        _ = await h.pause()
        h.recorder.clear()

        #expect(h.manager.thawAllSynchronously(reason: .appQuitting) == 3)
        #expect(h.recorder.calls == [.background(2000, false), .background(1001, false), .background(1000, false)])
        #expect(!h.journalExists)

        h.addApp(pid: 3000)
        let late = await h.pause(at: Self.now.addingTimeInterval(1))
        #expect(late.skippedReason == "interrupted by a thaw", "the app is terminating")
        #expect(h.recorder.calls.count == 3)
    }

    @Test func pausedAppsCarryDisplayMetadata() async throws {
        let h = try PauseHarness()
        defer { h.cleanup() }
        h.addApp(pid: 1000, helpers: [1001], bundleID: "com.spotify.client", name: "Spotify")
        _ = await h.pause()
        let paused = try #require(await h.manager.pausedApps().first)
        #expect(paused.name == "Spotify" && paused.bundleID == "com.spotify.client")
        #expect(paused.pausedAt == Self.now && paused.memberCount == 2 && paused.mode == .throttle)
    }
}
