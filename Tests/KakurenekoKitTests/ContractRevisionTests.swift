import Darwin
import KakurenekoCloud
import KakurenekoKit
import Foundation
import Testing

/// Contracts added in the architect's second pass (reviewer findings).
@Suite("Contract revision 2", .timeLimit(.minutes(1)))
struct ContractRevisionTests {
    // MARK: Paths

    @Test func liveResolvesKakurenekoHomeThenHomeThenFileManager() {
        let real = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let viaHome = Paths.live(environment: ["HOME": "/tmp/fake-home-env", "CLAUDE_CONFIG_DIR": "/real/claude"])
        #expect(viaHome.home.path(percentEncoded: false) == "/tmp/fake-home-env/")
        #expect(viaHome.isHomeOverridden)
        // Agent dir variables are ignored for a fake home: they derive from it.
        #expect(viaHome.claudeConfigDirectory.path(percentEncoded: false) == "/tmp/fake-home-env/.claude/")
        let viaKakureneko = Paths.live(environment: ["HOME": "/tmp/other", "KAKURENEKO_HOME": "/tmp/dh"])
        #expect(viaKakureneko.home.path(percentEncoded: false) == "/tmp/dh/")
        let realPaths = Paths.live(environment: ["HOME": real.path(percentEncoded: false), "CODEX_HOME": "/tmp/cx"])
        #expect(!realPaths.isHomeOverridden)
        #expect(realPaths.codexHome.path(percentEncoded: false) == "/tmp/cx/") // honoured for the real home
        #expect(!Paths.live(environment: [:]).isHomeOverridden)
    }

    @Test func agentSubprocessEnvironmentPinsFakeHome() throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        #expect(paths.isHomeOverridden)
        let env = paths.agentSubprocessEnvironment
        let home = paths.home.path(percentEncoded: false)
        #expect(env["HOME"] == String(home.dropLast()))
        #expect(env["CLAUDE_CONFIG_DIR"] == home + ".claude")
        #expect(env["CODEX_HOME"] == home + ".codex")
        #expect(env["COPILOT_HOME"] == home + ".copilot")
        #expect(env["XDG_CONFIG_HOME"] == home + ".config")
        #expect(paths.helperEnvironment["KAKURENEKO_HOME"] == String(home.dropLast()))
        // A real-home Paths never sets CLAUDE_CONFIG_DIR (it would move Claude's global .claude.json).
        let real = Paths(home: URL(filePath: "/Users/someone", directoryHint: .isDirectory))
        #expect(real.agentSubprocessEnvironment == ["HOME": "/Users/someone"])
        #expect(real.lastEventsFile.path(percentEncoded: false) == "/Users/someone/.kakureneko/run/last-events.json")
    }

    // MARK: KernelProcessLookup

    @Test func kernelProcessLookupMatchesOwnProcessAndRejectsDeadPid() throws {
        let lookup = KernelProcessLookup()
        let me = try #require(lookup.identity(of: getpid()))
        #expect(me.pid == getpid())
        #expect(me.startSec > 1_600_000_000)
        #expect(lookup.identity(of: getpid()) == me) // stable
        #expect(lookup.parentPID(of: getpid()) == getppid())
        #expect(lookup.identity(of: 0) == nil)
        #expect(lookup.identity(of: -1) == nil)
        // A child WE spawned: alive → identity; killed + reaped → gone (or a different, reused process).
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
        defer { argv.forEach { free($0) } }
        #expect(posix_spawn(&pid, "/bin/sleep", nil, nil, argv, nil) == 0)
        let child = try #require(lookup.identity(of: pid))
        #expect(lookup.parentPID(of: pid) == getpid())
        kill(pid, SIGKILL) // our own child only
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        #expect(!lookup.isAlive(child))
    }

    // MARK: AsyncBroadcaster

    @Test func replayFilterOnlyReplaysMatchingElements() async {
        let b = AsyncBroadcaster<PowerEvent>(replayLatest: true, replayFilter: { $0.isSnapshot })
        let snap = PowerSnapshot(takenAt: Date(timeIntervalSince1970: 1))
        b.yield(.snapshot(snap))
        b.yield(.lidChanged(.closed)) // an edge: never replayed
        var it = b.stream().makeAsyncIterator()
        #expect(await it.next() == .snapshot(snap))
        b.yield(.didWake)
        #expect(await it.next() == .didWake)
    }

    // MARK: Inbox ancestry

    @Test func inboxAncestorArgv1AndPath() throws {
        let line = #"{"pid":5,"startSec":1,"startUsec":2,"exe":"node","argv0":"node","argv1":"/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js","path":"/opt/homebrew/bin/node"}"#
        let a = try JSONDecoder().decode(InboxAncestor.self, from: Data(line.utf8))
        #expect(a.descriptor.argv == ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"])
        #expect(a.descriptor.executablePath == "/opt/homebrew/bin/node")
        #expect(BasicAgentSignatureMatcher().match(a.descriptor)?.agent == .codex)
        // Old headers (no argv1/path) still decode.
        let old = try JSONDecoder().decode(InboxAncestor.self, from: Data(#"{"pid":5,"startSec":1,"startUsec":2,"argv0":"claude"}"#.utf8))
        #expect(old.argv1 == nil && old.path == nil && old.descriptor.argv == ["claude"])
        #expect(InboxAncestor.isRecordableArgv1("/usr/local/bin/aider"))
        #expect(!InboxAncestor.isRecordableArgv1("fix the build please"))
        #expect(!InboxAncestor.isRecordableArgv1("no-slash"))
        #expect(!InboxAncestor.isRecordableArgv1("/" + String(repeating: "a", count: 600)))
    }

    // MARK: Claude T2

    @Test func claudeSnapshotDecodesOlderShapeAndNewFields() throws {
        let old = #"{"takenAt":"2026-10-12T23:30:04.000Z","sessions":[],"sessionsDirectoryReadable":true}"#
        let snap = try KakurenekoJSON.decode(ClaudeStateSnapshot.self, from: Data(old.utf8))
        #expect(snap.ignoredIdentities.isEmpty && snap.sessionsDirectoryReadable)
        let obs = ClaudeSessionObservation(record: ClaudeSessionRecord(pid: 7, status: "idle"), identity: nil,
                                           lastTurnCompletedAt: Date(timeIntervalSince1970: 10), lastTurnDurationMs: 4200,
                                           lastTurnPendingBackground: 0)
        let full = ClaudeStateSnapshot(takenAt: Date(timeIntervalSince1970: 11), sessions: [obs],
                                       ignoredIdentities: [ProcessIdentity(pid: 44386, startSec: 1, startUsec: 0)])
        #expect(try KakurenekoJSON.decode(ClaudeStateSnapshot.self, from: KakurenekoJSON.encode(full)) == full)
    }

    // MARK: Power

    @Test func kernelFlagsSeparateSimulationFromKernelTruth() throws {
        let real = KernelPowerFlags(sleepDisabled: true, clamshellClosed: false)
        #expect(real.kernelSleepDisabled == true && !real.isSimulated)
        let dry = KernelPowerFlags(sleepDisabled: false, clamshellClosed: true, kernelSleepDisabled: true, isSimulated: true)
        #expect(dry.sleepDisabled == false && dry.kernelSleepDisabled == true)
        #expect(try KakurenekoJSON.decode(KernelPowerFlags.self, from: KakurenekoJSON.encode(dry)) == dry)
        let legacy = try JSONDecoder().decode(KernelPowerFlags.self, from: Data(#"{"sleepDisabled":true}"#.utf8))
        #expect(legacy.kernelSleepDisabled == true && legacy.lid == .noLid)

        var status = PrivilegedStatus(sudoRuleInstalled: true, failsafeLoaded: true)
        #expect(status.isOperational)
        status.heartbeatPathMismatch = true
        #expect(!status.isOperational)
        let sim = PrivilegedStatus.simulatedForDryRun(at: Date(timeIntervalSince1970: 5))
        #expect(sim.isOperational && sim.simulated)

        let pending = PowerPhase.shutdownPending(at: Date(timeIntervalSince1970: 60), requestedFromPhone: true)
        #expect(pending.isArmed && pending.label == "shutdownPending")
        #expect(try KakurenekoJSON.decode(PowerPhase.self, from: KakurenekoJSON.encode(pending)) == pending)
        let desk = PowerSnapshot(takenAt: Date(), lid: .closed, externalDisplayConnected: true)
        #expect(desk.isClamshellDesktop)
    }

    // MARK: Pause journal

    @Test func journalRecordRequiresEnrichedIdentity() {
        let bare = ProcessIdentity(pid: 1, startSec: 2, startUsec: 3)
        #expect(PauseJournalRecord(identity: bare, path: nil, action: .sigstop) == nil)
        let enriched = ProcessIdentity(pid: 1, startSec: 2, startUsec: 3, uniqueID: 9, pidVersion: 4)
        #expect(PauseJournalRecord(identity: enriched, path: nil, action: .sigstop)?.uniqueID == 9)
    }

    @Test func journalDecodingIsLossyPerRecord() throws {
        let json = #"""
        {"schema":1,"bootSessionUUID":"B","kakurenekoPid":4242,"startedAt":"2026-10-12T23:30:04.000Z","futureField":1,
         "apps":[
          {"appPid":10,"mode":"freeze","simulated":false,"members":[
             {"pid":10,"pidVersion":1,"uniqueID":2,"startSec":3,"startUsec":4,"action":"sigstop"},
             {"pid":11,"startSec":3,"startUsec":4,"action":"sigstop"},
             {"pid":12,"pidVersion":1,"uniqueID":2,"startSec":3,"startUsec":4,"action":"explode"},
             {"pid":13,"pidVersion":1,"uniqueID":2,"startSec":3,"startUsec":4,"action":"darwinbg","extra":true}]},
          {"name":"no appPid"},
          {"appPid":20,"mode":"throttle","simulated":true,"members":[
             {"pid":20,"pidVersion":1,"uniqueID":2,"startSec":3,"startUsec":4,"action":"darwinbg"}]},
          {"appPid":30,"members":[]}]}
        """#
        let journal = try #require(PauseJournal.decode(Data(json.utf8)))
        #expect(journal.apps.map(\.appPid) == [10, 20, 30])
        #expect(journal.apps[0].members.map(\.pid) == [10, 13])
        #expect(journal.apps[0].droppedMemberCount == 2)
        #expect(journal.apps[1].simulated)
        #expect(journal.realApps.map(\.appPid) == [10, 30])
        #expect(!journal.apps[2].simulated) // missing → false
        // Encoding round-trips (dropped count is not part of equality).
        #expect(PauseJournal.decode(try journal.encoded()) == journal)
        #expect(PauseJournal.decode(Data(#"{"apps":[]}"#.utf8)) == nil) // no boot UUID → unusable
    }

    // MARK: Topology

    @Test func sessionHostsAreDirectlyProtected() {
        let t = AgentTopology(builtAt: Date(), sessionHostPIDs: [501])
        #expect(t.directlyProtectedPIDs.contains(501))
        #expect(!t.isEmpty)
        #expect(AgentTopology.empty(at: Date()).isEmpty)
    }

    // MARK: Settings

    @Test func normalizationMapsQuitModeAndUsesPublicRanges() {
        var s = KakurenekoSettings.default
        s.pausing.mode = .quit
        s.timers.finishCountdownMinutes = 999
        s.safety.batteryFloorPercent = 1
        let n = s.normalized()
        #expect(n.pausing.mode == .throttle)
        #expect(n.timers.finishCountdownMinutes == SessionTimers.finishCountdownMinutesRange.upperBound)
        #expect(n.safety.batteryFloorPercent == SafetySettings.batteryFloorPercentRange.lowerBound)
        #expect(SessionTimers.needsInputCountdownMinutesRange == 2...120)
        #expect(SafetySettings.maxClosedLidHoursRange == 1...24)
    }

    // MARK: Notify

    @Test func notificationIntentShapes() {
        let key = SessionKey(agent: .codex, id: "t")
        #expect(NotificationIntent.resolved(key).kind == .needsInput)
        let countdown = NotificationIntent.countdown(endsAt: Date(), reason: .needsInput, finished: [], waiting: [], offerShutdown: false)
        #expect(countdown.kind == .countdown)
        #expect(NotificationContext(now: Date(), presence: .away, stateVersion: 1).keepAwakeSeconds == 3600)
    }

    // MARK: Side effects

    @Test func dryRunSignallerLogsRelaunch() async throws {
        let ledger = DryRunLedger()
        let signaller = DryRunProcessSignaller(gate: .alwaysOn(), ledger: ledger)
        try await signaller.relaunchApplication(at: URL(filePath: "/Applications/Spotify.app"))
        #expect(ledger.entries(action: "app.relaunch").count == 1)
    }

    // MARK: Fakes

    @Test func fakeServiceSetLogsCrossServiceOrderWithTestClock() async throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let fakes = FakeServiceSet(paths: paths)
        let s = fakes.services
        await s.notifications.drain(deadline: fakes.clock.now().addingTimeInterval(10))
        _ = await s.pausing.thawAll(reason: .beforePowerAction)
        try await s.power.disarm()
        try await s.power.sleepNow()
        #expect(fakes.log.entries == ["notify.drain", "pause.thawAll(beforePowerAction)", "power.disarm", "power.sleep"])
        #expect(await s.power.snapshot().takenAt == fakes.clock.now())
        try await s.notifications.sendTest()
        #expect(fakes.notifications.testCount == 1)
        #expect(await s.notifications.requestMacAuthorization() == .authorized)
        #expect(await s.notifications.status().macAuthorization == .authorized)
        await s.notifications.updateMacStatus(MacStatusReport(phase: .idle, headline: "Idle"))
        #expect(fakes.notifications.statusReports.map(\.phase) == [.idle])
        await s.notifications.cloudDidNotify()
        #expect(fakes.notifications.cloudPushCount == 1)
        #expect(fakes.safety.armingBlocker(PowerSnapshot(takenAt: Date()), settings: SafetySettings()) == nil)
        fakes.power.setSimulatedFlags(simulated: false, kernel: true)
        #expect(s.power.kernelFlags().kernelSleepDisabled == true)
        #expect(s.pausing.thawAllSynchronously(reason: .appQuitting) == 0)
    }

    @Test func fakeEventSourceLaunchDrainGoesToExistingSubscribers() async throws {
        let source = FakeEventSource()
        let event = AgentEvent(id: "1", agent: .vscode, argvAgentLabel: "copilot", event: .turnStarted, rawEventName: "UserPromptSubmit",
                               sessionKey: SessionKey(agent: .vscode, id: "s"), occurredAt: Date(), receivedAt: Date())
        source.queueForDrain([event])
        let stream = source.events() // subscribe first
        try await source.start()
        var it = stream.makeAsyncIterator()
        #expect(await it.next() == event)
        #expect(await source.lastEventSeen()[.copilot] != nil) // keyed by the delivering integration
    }
}
