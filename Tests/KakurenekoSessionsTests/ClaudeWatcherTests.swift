@testable import KakurenekoSessions
import KakurenekoKit
import Foundation
import Testing

/// `ClaudeStateWatcher` on a temp `~/.claude` (ARCHITECTURE §9.3 acceptance): R02 records, liveness, ignored
/// records, `.key` never opened, transcript tails, in-place rewrites via FSEvents, the mtime sweep, the
/// `agents --json` poller (only ever through `FakeSubprocessRunner`) and its cadence.
@Suite("ClaudeStateWatcher", .timeLimit(.minutes(1)))
struct ClaudeWatcherTests {
    /// Writes the R02 sample directory: live, parked, spare, daemon, dead and pid-reused records, plus files that
    /// must never be read.
    static func writeR02Directory(_ f: WatcherFixture) throws {
        try f.write("96888.json", R02.interactive())
        try f.write("24617.json", R02.background)
        try f.write("44386.json", R02.parked)
        try f.write("50001.json", R02.spare)
        try f.write("35816.json", R02.daemon)
        try f.write("35900.json", R02.deadDaemonWorker)
        try f.write("76720.json", R02.deadBusy)
        try f.write("9220.json", R02.reusedPID)
        try f.write("123.json", #"{"pid":123,"sessionId":"tor"#) // caught mid-rewrite, never seen whole
        try f.write("96888.4c1f0e9a2b.key", "peer-token-SECRET")
        try f.write(".fleetview-heartbeat", "")
        try f.write("notes.txt", "hello")
        for pid: Int32 in [96888, 44386, 50001, 35816] { f.lookup.set(R02.identity(pid)) }
        f.lookup.set(R02.identity(24617, procStart: R02.procStartPadded))
        f.lookup.set(R02.identity(9220, offset: 3600)) // same pid, an unrelated younger process
    }

    // MARK: Reading

    @Test func currentReadsRecordsWithLivenessAndIgnoresParkedSpareAndDaemonRecords() async throws {
        let f = try WatcherFixture()
        try Self.writeR02Directory(f)
        let watcher = f.makeWatcher()
        let snapshot = await watcher.current()

        #expect(snapshot.sessionsDirectoryReadable)
        #expect(snapshot.sessions.map(\.record.pid) == [9220, 24617, 76720, 96888])
        let byPID = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.record.pid, $0) })
        #expect(byPID[96888]?.identity == R02.identity(96888))
        #expect(byPID[24617]?.identity == R02.identity(24617, procStart: R02.procStartPadded))
        #expect(byPID[76720]?.identity == nil) // dead
        #expect(byPID[9220]?.identity == nil) // pid reused
        #expect(byPID[96888]?.fileModifiedAt != nil)
        #expect(byPID[96888]?.title == nil) // `developer-40` is a derived name
        #expect(byPID[24617]?.title == "Titulná strana bakalárskej práce (2)")
        // Live ignorable records only; the dead daemon-worker is simply gone.
        #expect(snapshot.ignoredIdentities == [R02.identity(35816), R02.identity(44386), R02.identity(50001)])
        // `current()` never polls the CLI.
        #expect(snapshot.agents == nil)
        #expect(f.runner.requests.isEmpty)

        // Never opened: `.key`, the heartbeat, non-record files. Never touched: anything outside the temp root.
        let touched = f.files.calls.map(\.path)
        #expect(!touched.contains { $0.hasSuffix(".key") || $0.hasSuffix(".fleetview-heartbeat") || $0.hasSuffix("notes.txt") })
        let root = f.root.path(percentEncoded: false)
        #expect(touched.allSatisfy { $0.hasPrefix(root) })
        #expect(f.files.opened.allSatisfy { ClaudeSessionRecord.isRecordFileName(($0 as NSString).lastPathComponent) })
    }

    @Test func missingSessionsDirectoryIsAnUnreadableSnapshot() async throws {
        let f = try WatcherFixture(createSessionsDirectory: false)
        let snapshot = await f.makeWatcher().current()
        #expect(!snapshot.sessionsDirectoryReadable)
        #expect(snapshot.sessions.isEmpty)
        #expect(snapshot.ignoredIdentities.isEmpty)
    }

    @Test func transcriptGivesTitleCwdPreviewAndTurnDuration() async throws {
        let f = try WatcherFixture()
        try f.write("96888.json", R02.interactive())
        f.lookup.set(R02.identity(96888))
        let path = try f.writeTranscript(directory: "-Users-tomasnguyen-Developer", sessionId: R02.interactiveSession,
                                         R02.transcript())
        let observation = try #require(await f.makeWatcher().current().sessions.first)
        #expect(observation.transcriptPath == path)
        #expect(observation.title == "Cursor reveal")
        #expect(observation.currentCwd == "/Users/tomasnguyen/Developer/projects portfolio")
        #expect(observation.lastAssistantPreview?.hasSuffix("Tests pass.") == true)
        #expect(observation.lastTurnCompletedAt == KakurenekoJSON.date(fromISO8601: R02.turnCompletedAt))
        #expect(observation.lastTurnDurationMs == 59_800)
        #expect(observation.lastTurnPendingBackground == 1)
        // Only the tail was read, never the whole file through `readFile`.
        #expect(f.files.calls.contains { $0.method == "readTail" && $0.path == path })
        #expect(!f.files.calls.contains { $0.method == "readFile" && $0.path == path })
    }

    @Test func transcriptIsFoundByScanningProjectsWhenTheSlugDoesNotMatch() async throws {
        let f = try WatcherFixture()
        try f.write("96888.json", R02.interactive())
        f.lookup.set(R02.identity(96888))
        try f.writeTranscript(directory: "-Users-tomasnguyen-Developer-elsewhere", sessionId: "unrelated", "{}\n")
        let path = try f.writeTranscript(directory: "-Users-tomasnguyen-Developer-very-long-trunc-1a2b3c",
                                         sessionId: R02.interactiveSession, R02.transcript())
        let observation = try #require(await f.makeWatcher().current().sessions.first)
        #expect(observation.transcriptPath == path)
        #expect(observation.title == "Cursor reveal")
    }

    @Test func deadSessionsGetNoTranscriptLookup() async throws {
        let f = try WatcherFixture()
        try f.write("76720.json", R02.deadBusy)
        try f.writeTranscript(directory: "-Users-tomasnguyen", sessionId: "fc061117-c7f7-4b91-9732-b6d60a05cd65", R02.transcript())
        let observation = try #require(await f.makeWatcher().current().sessions.first)
        #expect(observation.identity == nil)
        #expect(observation.transcriptPath == nil)
        #expect(!f.files.calls.contains { $0.path.contains("/projects") })
    }

    // MARK: Core: torn reads, change detection

    @Test func tornRecordKeepsTheLastGoodContentAndAsksForOneRetry() async throws {
        let f = try WatcherFixture()
        let core = f.makeCore()
        try f.write("96888.json", R02.interactive())
        f.lookup.set(R02.identity(96888))
        let first = await core.refresh(reason: "test", force: false)
        #expect(first.emitted && !first.retryWanted)

        try f.rewriteInPlace("96888.json", #"{"pid":96888,"sessionId":"3514"#)
        let torn = await core.refresh(reason: "test", force: false)
        #expect(torn.retryWanted)
        #expect(!torn.emitted)
        #expect(await core.snapshot().sessions.first?.record.status == "busy")
        #expect(!(await core.refresh(reason: "test", force: false).retryWanted)) // once per file state, never a loop

        try f.rewriteInPlace("96888.json", R02.interactive(status: "idle", statusUpdatedAt: 1_791_810_700_000, extra: #","waitingFor":null"#))
        let whole = await core.refresh(reason: "test", force: false)
        #expect(whole.emitted)
        #expect(whole.tailRereadWanted) // busy → idle
        #expect(core.broadcaster.latest?.sessions.first?.record.status == "idle")
    }

    @Test func currentDoesNotConsumeAChangeTheSweepMustStillEmit() async throws {
        let f = try WatcherFixture()
        let core = f.makeCore()
        try f.write("96888.json", R02.interactive())
        f.lookup.set(R02.identity(96888))
        _ = await core.refresh(reason: "test", force: false)
        #expect(!(await core.recordFilesChanged()))

        try f.rewriteInPlace("96888.json", R02.interactive(status: "idle", statusUpdatedAt: 1_791_810_700_000, extra: #","waitingFor":null"#))
        #expect(await core.snapshot().sessions.first?.record.status == "idle")
        #expect(await core.recordFilesChanged())
        let outcome = await core.refresh(reason: "sweep", force: false)
        #expect(outcome.emitted)
        #expect(outcome.tailRereadWanted)
        #expect(!(await core.recordFilesChanged()))
    }

    // MARK: Watching

    @Test func recordRewrittenInPlaceIsReportedWithinOneSecond() async throws {
        let f = try WatcherFixture()
        try f.write("96888.json", R02.interactive())
        f.lookup.set(R02.identity(96888))
        let watcher = f.makeWatcher()
        let collector = SnapshotCollector(watcher.snapshots())
        await watcher.start()
        defer { Task { await watcher.stop() } }
        #expect(await collector.first { $0.sessions.first?.record.status == "busy" } != nil)
        #expect(await waitUntil { f.clock.sleeperCount >= 2 }) // poll + sweep loops parked
        #expect(watcher.isWatchingDirectory)

        let inodes = try f.rewriteInPlace("96888.json", R02.interactive(status: "idle", statusUpdatedAt: 1_791_810_700_000))
        #expect(inodes.before == inodes.after) // truncate + write, no rename
        let start = f.clock.now()
        var found: ClaudeStateSnapshot?
        _ = await waitUntil {
            found = collector.snapshots.first { $0.sessions.first?.record.status == "idle" }
            if found == nil, f.clock.sleeperCount >= 3, f.clock.now().timeIntervalSince(start) < 1 {
                f.clock.advance(by: ClaudeWatchRuntime.debounce) // the FSEvents callback scheduled the debounce
            }
            return found != nil
        }
        #expect(found != nil)
        #expect(f.clock.now().timeIntervalSince(start) <= 1)
    }

    @Test func missingDirectoryIsSweptAndWatchedOnceItAppears() async throws {
        let f = try WatcherFixture(createSessionsDirectory: false)
        f.lookup.set(R02.identity(96888))
        let watcher = f.makeWatcher()
        let collector = SnapshotCollector(watcher.snapshots())
        await watcher.start()
        defer { Task { await watcher.stop() } }
        #expect(await collector.first { !$0.sessionsDirectoryReadable } != nil)
        #expect(!watcher.isWatchingDirectory)
        #expect(await waitUntil { f.clock.sleeperCount >= 3 }) // poll + sweep + directory re-check

        try f.createSessionsDirectory()
        try f.write("96888.json", R02.interactive())
        f.clock.advance(by: SamplingCadence.lidOpen.processScanInterval)
        let swept = await collector.first { $0.sessionsDirectoryReadable && $0.sessions.count == 1 }
        #expect(swept?.sessions.first?.identity == R02.identity(96888))
        #expect(!watcher.isWatchingDirectory)

        #expect(await waitUntil { f.clock.sleeperCount >= 3 })
        f.clock.advance(by: ClaudeWatchRuntime.directoryRecheck - SamplingCadence.lidOpen.processScanInterval)
        #expect(await waitUntil { watcher.isWatchingDirectory })
    }

    @Test func deletedRecordLeavesTheNextSweptSnapshot() async throws {
        let f = try WatcherFixture(fsevents: false)
        try f.write("96888.json", R02.interactive())
        f.lookup.set(R02.identity(96888))
        let watcher = f.makeWatcher()
        let collector = SnapshotCollector(watcher.snapshots())
        await watcher.start()
        defer { Task { await watcher.stop() } }
        #expect(await collector.first { $0.sessions.count == 1 } != nil)
        #expect(await waitUntil { f.clock.sleeperCount >= 3 })
        try FileManager.default.removeItem(at: f.sessions.appending(path: "96888.json"))
        f.clock.advance(by: .seconds(15))
        let gone = await collector.first { $0.sessions.isEmpty }
        #expect(gone?.sessionsDirectoryReadable == true)
    }

    @Test func busyToIdleRereadsTheTranscriptTailForTurnDuration() async throws {
        let f = try WatcherFixture(fsevents: false)
        try f.write("96888.json", R02.interactive())
        f.lookup.set(R02.identity(96888))
        let transcript = try f.writeTranscript(directory: "-Users-tomasnguyen-Developer", sessionId: R02.interactiveSession,
                                               R02.transcript(withTurnDuration: false))
        let core = f.makeCore()
        let runtime = ClaudeWatchRuntime(core: core, directory: f.sessions, files: f.files, clock: f.clock,
                                         logger: KakurenekoLogger(.sessions))
        let collector = SnapshotCollector(core.broadcaster.stream())
        await runtime.start()
        defer { runtime.shutdown(finishStreams: true) }
        #expect(await waitUntil { f.clock.sleeperCount >= 3 }) // poll, sweep, directory re-check

        // The record goes idle; the turn_duration entry is written just after.
        try f.rewriteInPlace("96888.json", R02.interactive(status: "idle", statusUpdatedAt: 1_791_810_700_000, extra: #","waitingFor":null"#))
        let start = f.clock.now()
        runtime.scheduleRefresh()
        #expect(await waitUntil { f.clock.sleeperCount >= 4 })
        f.clock.advance(by: ClaudeWatchRuntime.debounce)
        let idle = await collector.first { $0.sessions.first?.record.status == "idle" }
        #expect(idle?.sessions.first?.lastTurnDurationMs == nil)

        try f.appendTranscript(transcript, #"{"type":"system","subtype":"turn_duration","durationMs":59800,"timestamp":"\#(R02.turnCompletedAt)"}"# + "\n")
        #expect(await waitUntil { f.clock.sleeperCount >= 4 }) // the re-read is scheduled
        f.clock.advance(by: ClaudeWatchRuntime.tailRereadDelays[0]) // scheduled when the idle snapshot went out
        let reread = await collector.first { $0.sessions.first?.lastTurnDurationMs != nil }
        #expect(reread?.sessions.first?.lastTurnDurationMs == 59_800)
        #expect(reread?.sessions.first?.lastTurnCompletedAt == KakurenekoJSON.date(fromISO8601: R02.turnCompletedAt))
        let elapsed = f.clock.now().timeIntervalSince(start)
        #expect(elapsed >= 1 && elapsed <= 2)
    }

    // MARK: `claude agents --json --all`

    @Test func pollRunsTheCandidateCLIReadOnlyWithTheAgentEnvironment() async throws {
        let f = try WatcherFixture()
        let cli = try f.installCLICandidate()
        f.answerAgents(R02.agentsJSON)
        let watcher = f.makeWatcher()
        let collector = SnapshotCollector(watcher.snapshots())
        await watcher.start()
        defer { Task { await watcher.stop() } }
        let polled = try #require(await collector.first { $0.agents != nil })
        #expect(polled.agents?.count == 3)
        #expect(polled.agentsPolledAt == f.clock.now())
        #expect(collector.snapshots.first?.agents == nil) // the start snapshot came first

        let request = try #require(f.runner.requests.first)
        #expect(f.runner.requests.count == 1) // no login-shell lookup: the candidate exists
        #expect(request.executable == cli)
        #expect(request.arguments == ["agents", "--json", "--all"])
        #expect(request.stdin == nil)
        #expect(request.environment == nil)
        #expect(request.effect == .readOnly)
        #expect(request.timeout == .seconds(10))
        for (key, value) in f.paths.agentSubprocessEnvironment { #expect(request.extraEnvironment[key] == value) }
        // The temp home is an override: the CLI is pinned to the fake config dir, never the real ~/.claude.
        #expect(request.extraEnvironment["CLAUDE_CONFIG_DIR"]?.hasPrefix(f.root.path(percentEncoded: false)) == true)
        #expect(request.extraEnvironment["DISABLE_AUTOUPDATER"] == "1")
        #expect(request.extraEnvironment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1")
    }

    @Test func loginShellLookupResolvesTheCLIOnce() async throws {
        let f = try WatcherFixture()
        let cli = try f.installExecutable(at: f.root.appending(path: "opt/bin/claude"))
        f.runner.setHandler { request in
            if request.executable == ClaudeCLI.shell { return SubprocessResult(exitCode: 0, stdout: Data("Welcome back!\n\(cli)\n".utf8)) }
            if request.executable == cli, request.arguments == ClaudeCLI.agentsArguments {
                return SubprocessResult(exitCode: 0, stdout: Data("[]".utf8))
            }
            return SubprocessResult(exitCode: 127)
        }
        let watcher = f.makeWatcher()
        let collector = SnapshotCollector(watcher.snapshots())
        await watcher.start()
        defer { Task { await watcher.stop() } }
        #expect(await collector.first { $0.agents == [] } != nil)
        let lookup = try #require(f.runner.requests.first)
        #expect(lookup.executable == "/bin/zsh")
        #expect(lookup.arguments == ["-lc", "command -v claude"])
        #expect(lookup.effect == .readOnly)
        #expect(lookup.extraEnvironment["HOME"] == f.paths.agentSubprocessEnvironment["HOME"])

        #expect(await waitUntil { f.clock.sleeperCount >= 2 })
        f.clock.advance(by: SamplingCadence.lidOpen.claudeAgentsPollInterval)
        #expect(await waitUntil { f.runner.requests.count == 3 })
        #expect(f.runner.requests.map(\.executable) == ["/bin/zsh", cli, cli])
    }

    @Test func missingCLIPausesPollingAndRetriesTheLookupRarely() async throws {
        let f = try WatcherFixture()
        let watcher = f.makeWatcher() // default handler: `command -v claude` prints nothing
        let collector = SnapshotCollector(watcher.snapshots())
        await watcher.start()
        defer { Task { await watcher.stop() } }
        #expect(await waitUntil { collector.count >= 2 && f.clock.sleeperCount >= 2 })
        #expect(f.runner.requests.map(\.executable) == ["/bin/zsh"])
        #expect(collector.snapshots.allSatisfy { $0.agents == nil })

        f.clock.advance(by: .seconds(60))
        #expect(await waitUntil { collector.count >= 3 && f.clock.sleeperCount >= 2 }) // polled (and emitted) without a lookup
        #expect(f.runner.requests.count == 1)

        f.clock.advance(by: .interval(ClaudeCLI.lookupRetryInterval))
        #expect(await waitUntil { f.runner.requests.count == 2 })
        #expect(f.runner.requests.map(\.executable) == ["/bin/zsh", "/bin/zsh"])
    }

    @Test func failedOrThrowingPollsClearTheAgentsUntilTheNextGoodPoll() async throws {
        struct LaunchFailure: Error {}
        let f = try WatcherFixture()
        try f.installCLICandidate()
        f.answerAgents(R02.agentsJSON)
        let watcher = f.makeWatcher()
        let collector = SnapshotCollector(watcher.snapshots())
        await watcher.start()
        defer { Task { await watcher.stop() } }
        #expect(await collector.first { $0.agents?.count == 3 } != nil)

        func poll(_ handler: @escaping FakeSubprocessRunner.Handler) async -> ClaudeStateSnapshot? {
            f.runner.setHandler(handler)
            _ = await waitUntil { f.clock.sleeperCount >= 2 }
            let mark = collector.count
            let polls = f.runner.requests.count
            f.clock.advance(by: SamplingCadence.lidOpen.claudeAgentsPollInterval)
            _ = await waitUntil { f.runner.requests.count > polls }
            return await collector.first(from: mark) { _ in true }
        }
        let failed = await poll { _ in SubprocessResult(exitCode: 1, stderr: Data("not logged in".utf8)) }
        #expect(failed?.agents == nil)
        #expect(failed?.agentsPolledAt == nil)
        let thrown = await poll { _ in throw LaunchFailure() }
        #expect(thrown?.agents == nil)
        let good = await poll { _ in SubprocessResult(exitCode: 0, stdout: Data(R02.agentsJSON.utf8)) }
        #expect(good?.agents?.count == 3)
    }

    @Test func setCadenceSwitchesThePollInterval() async throws {
        let f = try WatcherFixture()
        try f.installCLICandidate()
        f.answerAgents("[]")
        let watcher = f.makeWatcher()
        await watcher.start()
        defer { Task { await watcher.stop() } }
        #expect(watcher.cadence == .lidOpen)
        #expect(await waitUntil { f.agentsRequests.count == 1 && f.clock.sleeperCount >= 2 })

        /// Advances virtual time, then waits until the loops are parked again and returns the poll count.
        func advance(_ duration: Duration) async -> Int {
            f.clock.advance(by: duration)
            try? await Task.sleep(for: .milliseconds(20))
            _ = await waitUntil { f.clock.sleeperCount >= 2 }
            return f.agentsRequests.count
        }

        await watcher.setCadence(.lidClosed)
        #expect(watcher.cadence == .lidClosed)
        #expect(await waitUntil { f.clock.sleeperCount >= 2 })
        #expect(await advance(.seconds(14)) == 1)
        #expect(await advance(.seconds(1)) == 2) // 15 s after the last poll
        #expect(await advance(.seconds(15)) == 3)

        await watcher.setCadence(.lidOpen)
        #expect(await waitUntil { f.clock.sleeperCount >= 2 })
        #expect(await advance(.seconds(59)) == 3)
        #expect(await advance(.seconds(1)) == 4) // 60 s after the last poll
    }

    // MARK: Lifecycle

    @Test func stopFinishesEveryStreamAndIsFinal() async throws {
        let f = try WatcherFixture()
        let watcher = f.makeWatcher()
        let collector = SnapshotCollector(watcher.snapshots())
        await watcher.start()
        await watcher.start() // idempotent
        #expect(await collector.first { _ in true } != nil)
        await watcher.stop()
        #expect(await waitUntil { collector.isFinished })
        #expect(!watcher.isWatchingDirectory)
        #expect(await waitUntil { f.clock.sleeperCount == 0 })
        await watcher.start() // final: no restart
        #expect(f.clock.sleeperCount == 0)
        let late = SnapshotCollector(watcher.snapshots())
        #expect(await waitUntil { late.isFinished })
        #expect(late.count == 0)
    }
}
