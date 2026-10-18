@testable import KakurenekoSessions
import KakurenekoKit
import Foundation
import Testing

/// ARCHITECTURE §9.3 acceptance tests for `SessionEngine`, one per bullet.
@Suite("SessionEngine acceptance (§9.3)", .timeLimit(.minutes(1)))
struct EngineAcceptanceTests {
    // MARK: 13 h replay

    @Test func thirteenHourBusyRecordStallsExactlyAtTwentyMinutes() {
        let d = EngineDriver()
        let claude = F.identity(76720)
        let key = F.key("fc061117")
        // Busy since 13 h ago; Claude keeps respawning caffeinate → only E6 (never progress).
        let record = F.live(claude, session: "fc061117", statusAt: -13 * 3600)
        d.claude(at: 0, [record])
        #expect(d.state(key)?.isWorking == true)

        for t in stride(from: 1.0, through: 1199, by: 1) {
            if t.truncatingRemainder(dividingBy: 5) == 0 {
                d.processes(at: t, [F.process(claude, .claude, kinds: [.powerAssertion], at: t)])
            }
            if t.truncatingRemainder(dividingBy: 15) == 0 { d.claude(at: t, [record]) }
            d.tick(at: t)
        }
        #expect(d.state(key)?.isWorking == true)
        #expect(d.effects.isEmpty)

        let stalled = d.tick(at: 1200)
        #expect(stalled.map(\.kind) == [.stalled])
        #expect(d.state(key)?.isStalled == true)
        #expect(d.aggregate.anyWorking == false)
        #expect(d.aggregate.stalledCount == 1)

        for t in stride(from: 1201.0, through: 13 * 3600 / 20, by: 5) {
            d.processes(at: t, [F.process(claude, .claude, kinds: [.powerAssertion], at: t)])
            d.claude(at: t, [record])
            d.tick(at: t)
        }
        #expect(d.effects(.stalled).count == 1)
        #expect(d.effects.count == 1)
        #expect(d.state(key)?.isStalled == true)
    }

    // MARK: Hook turn lifecycle

    @Test func turnFinishedSettlesForExactlyFiveSecondsThenFinishes() throws {
        let d = EngineDriver()
        d.send(.turnStarted, at: 0)
        d.send(.turnFinished(.completed), at: 60)
        #expect(d.state()?.isSettling == true)
        #expect(d.aggregate.anyWorking == true)
        #expect(d.tick(at: 64.999).isEmpty)

        let effects = d.tick(at: 65)
        #expect(effects.map(\.kind) == [.finished])
        let finished = try #require(effects.first)
        #expect(finished.outcome == .completed)
        #expect(finished.workedFor == 65)
        #expect(finished.at == F.at(65))
        #expect(finished.session.state.isIdle(outcome: .completed))
        #expect(d.session()?.lastTurnDuration == 65)
        #expect(d.aggregate.lastFinishedAt == F.at(65))
        #expect(d.tick(at: 70).isEmpty)
    }

    @Test(arguments: [NormalizedEvent.activity, .turnStarted])
    func continuationInsideSettleCancelsTheFinish(continuation: NormalizedEvent) throws {
        let d = EngineDriver()
        d.send(.turnStarted, at: 0)
        d.send(.turnFinished(.completed), at: 10)
        d.send(continuation, at: 12)
        #expect(d.state()?.isWorking == true)
        #expect(d.tick(from: 13, through: 30).isEmpty)
        // A new prompt bumps the state version; a vetoed Stop (activity) continues the same turn.
        #expect(d.stateVersion == (continuation == .turnStarted ? 2 : 1))

        d.send(.turnFinished(.completed), at: 40)
        let finished = try #require(d.tick(at: 45).first)
        #expect(finished.kind == .finished)
        #expect(finished.workedFor == 45) // the turn start is kept across the continuation
        #expect(d.effects(.finished).count == 1)
    }

    @Test func claudeStopWhileRecordBusyHoldsWorkingUntilTheRecordGoesIdle() throws {
        let d = EngineDriver()
        let claude = F.identity(100)
        d.claude(at: 0, [F.live(claude, statusAt: 0)])
        #expect(d.state()?.isWorking == true)
        #expect(d.stateVersion == 1)

        d.send(.turnFinished(.completed), at: 30, process: claude)
        #expect(d.state()?.isSettling == true)
        #expect(d.tick(at: 35).isEmpty)
        #expect(d.state()?.isWorking == true)
        #expect(d.stateVersion == 1) // settle-expiry re-entry never bumps
        #expect(d.claude(at: 36, [F.live(claude, statusAt: 0)]).isEmpty)
        #expect(d.tick(from: 37, through: 39).isEmpty)

        let effects = d.claude(at: 40, [F.live(claude, status: "idle", statusAt: 40)])
        #expect(effects.map(\.kind) == [.finished])
        let finished = try #require(effects.first)
        #expect(finished.outcome == .completed)
        #expect(finished.workedFor == 40)
        #expect(d.state()?.isIdle(outcome: .completed) == true)
        #expect(d.stateVersion == 1)
    }

    @Test func stopWithRecordBusyForTwentyFiveMinutesStallsAtTwentyMinutes() {
        let d = EngineDriver()
        let claude = F.identity(101)
        let busy = F.live(claude, statusAt: 0)
        d.claude(at: 0, [busy])
        d.send(.turnFinished(.completed), at: 60, process: claude)
        d.tick(at: 65)
        #expect(d.state()?.isWorking == true)

        for t in stride(from: 70.0, through: 1259, by: 1) {
            if t.truncatingRemainder(dividingBy: 5) == 0 {
                d.processes(at: t, [F.process(claude, .claude, at: t)])
                d.claude(at: t, [busy])
            }
            d.tick(at: t)
        }
        #expect(d.state()?.isWorking == true)
        #expect(d.tick(at: 1260).map(\.kind) == [.stalled]) // 20 min after the Stop (last progress)
        #expect(d.aggregate.anyWorking == false)
        for t in stride(from: 1261.0, through: 60 + 25 * 60, by: 5) {
            d.processes(at: t, [F.process(claude, .claude, at: t)])
            d.claude(at: t, [busy])
            d.tick(at: t)
        }
        #expect(d.kinds == [.stalled])
        #expect(d.aggregate.anyWorking == false)
    }

    @Test func busyToIdleWithoutStopWithHooksLiveIsInterruptedWithoutEffect() {
        let d = EngineDriver()
        let claude = F.identity(102)
        d.send(.turnStarted, at: 0, process: claude)
        d.claude(at: 1, [F.live(claude, statusAt: 0.5)])
        let effects = d.claude(at: 30, [F.live(claude, status: "idle", statusAt: 30, turnCompletedAt: 29.9, durationMs: 29_000)])
        #expect(effects.isEmpty)
        #expect(d.state()?.isIdle(outcome: .interrupted) == true)
        #expect(d.tick(from: 31, through: 120, step: 5).isEmpty)
        #expect(d.session()?.lastTurnDuration == 30)
    }

    // MARK: T2-only finish via turn_duration

    @Test func t2OnlyBusyToIdleWithALaterTurnDurationFinishesExactlyOnce() throws {
        let d = EngineDriver()
        let claude = F.identity(103)
        d.claude(at: 0, [F.live(claude, statusAt: 0)])
        // Record idle; the tail still shows the PREVIOUS turn's turn_duration.
        let first = d.claude(at: 60, [F.live(claude, status: "idle", statusAt: 60, turnCompletedAt: -100, durationMs: 5000)])
        #expect(first.isEmpty)
        #expect(d.state()?.isIdle(outcome: .interrupted) == true)

        // 1.5 s later the re-read tail has this turn's turn_duration.
        let late = d.claude(at: 61.5, [F.live(claude, status: "idle", statusAt: 60, turnCompletedAt: 60.2, durationMs: 59_800)])
        #expect(late.map(\.kind) == [.finished])
        let finished = try #require(late.first)
        #expect(finished.outcome == .completed)
        #expect(finished.workedFor == 59.8)
        #expect(d.state()?.isIdle(outcome: .completed) == true)
        #expect(d.session()?.lastTurnDuration == 59.8)

        for t in stride(from: 65.0, through: 200, by: 5) {
            d.claude(at: t, [F.live(claude, status: "idle", statusAt: 60, turnCompletedAt: 60.2, durationMs: 59_800)])
            d.tick(at: t)
        }
        #expect(d.effects(.finished).count == 1)
        #expect(d.effects.count == 1)
    }

    @Test func t2OnlyTurnDurationAlreadyPresentFinishesAtTheIdleEdge() throws {
        let d = EngineDriver()
        let claude = F.identity(104)
        d.claude(at: 0, [F.live(claude, statusAt: 0)])
        let effects = d.claude(at: 42, [F.live(claude, status: "shell", statusAt: 41, turnCompletedAt: 40.9, durationMs: 40_900)])
        #expect(effects.map(\.kind) == [.finished])
        #expect(try #require(effects.first).workedFor == 40.9)
        #expect(d.state()?.isIdle(outcome: .completed) == true)
    }

    @Test func t2OnlyTurnWithPendingBackgroundWorkOrNoTurnDurationIsInterrupted() {
        let d = EngineDriver()
        let claude = F.identity(105)
        d.claude(at: 0, [F.live(claude, statusAt: 0)])
        // The workflow was killed: the turn ended with pending background work, then the record went idle.
        d.claude(at: 30, [F.live(claude, status: "idle", statusAt: 30, turnCompletedAt: 5, durationMs: 5000, pending: 1)])
        #expect(d.state()?.isIdle(outcome: .interrupted) == true)
        // A matching turn_duration that only shows up after the 60 s window does not resurrect a finish.
        d.claude(at: 95, [F.live(claude, status: "idle", statusAt: 30, turnCompletedAt: 29, durationMs: 29_000)])
        #expect(d.effects.isEmpty)
    }

    // MARK: Needs input

    @Test func oneNeedsInputEffectPerWait() throws {
        let d = EngineDriver()
        d.send(.turnStarted, at: 0)
        let first = d.send(.needsInput(.permission), at: 10, waitingFor: "Claude needs your permission to use Bash")
        #expect(first.map(\.kind) == [.needsInput])
        #expect(try #require(first.first).needsInputKind == .permission)
        #expect(d.session()?.waitingFor == "Claude needs your permission to use Bash")
        #expect(d.send(.needsInput(.permission), at: 20).isEmpty)
        #expect(d.send(.idleReminder, at: 70).isEmpty)
        #expect(d.state()?.isWaiting == true)
        #expect(d.aggregate.anyWaiting == true)
        #expect(d.aggregate.anyWorking == false)

        // The approval resumes the turn (stateVersion bumps); a new wait pushes again.
        d.send(.activity, at: 80)
        #expect(d.state()?.isWorking == true)
        #expect(d.stateVersion == 2)
        #expect(d.session()?.waitingFor == nil)
        #expect(d.send(.needsInput(.question), at: 90).map(\.kind) == [.needsInput])
        #expect(d.effects(.needsInput).count == 2)
    }

    @Test func codexPermissionRequestThenWorkEvidenceForTwentySecondsResumesWorking() {
        let d = EngineDriver()
        let codex = F.identity(200)
        let key = F.key("thread-1", .codex)
        d.send(.turnStarted, at: 0, agent: .codex, session: "thread-1", process: codex)
        d.send(.needsInput(.permission), at: 10, agent: .codex, session: "thread-1", process: codex)
        #expect(d.stateVersion == 1)

        // Evidence sampled within one window (60 s) of the prompt may still be the work that led to it: no exit,
        // however long it lasts. From +60 s on, 20 s of E1+E4 resume the turn.
        for t in stride(from: 15.0, through: 85, by: 5) {
            d.processes(at: t, [F.process(codex, .codex, kinds: [.treeCPU, .modelAPISocket], at: t)])
            #expect(d.state(key)?.isWaiting == true)
        }
        d.processes(at: 90, [F.process(codex, .codex, kinds: [.treeCPU, .modelAPISocket], at: 90)])
        #expect(d.state(key)?.isWorking == true)
        #expect(d.stateVersion == 2)
        for t in stride(from: 95.0, through: 135, by: 5) {
            d.processes(at: t, [F.process(codex, .codex, kinds: [.treeCPU, .modelAPISocket], at: t)])
            d.tick(at: t)
        }
        #expect(d.effects(.needsInput).count == 1)
        #expect(d.state(key)?.isWorking == true)
    }

    @Test func idleReminderNeverTransitionsOrPushes() {
        let d = EngineDriver()
        d.send(.turnStarted, at: 0)
        d.send(.turnFinished(.completed), at: 10)
        d.tick(at: 15)
        let before = d.effects.count
        #expect(d.send(.idleReminder, at: 75).isEmpty)
        #expect(d.state()?.isIdle(outcome: .completed) == true)
        #expect(d.effects.count == before)
    }

    @Test func sessionStartedCompactWhileWorkingStaysWorking() {
        let d = EngineDriver()
        d.send(.turnStarted, at: 0)
        d.send(.sessionStarted, at: 30, metadata: [MetadataKey.claudeSessionStartSource: "compact"])
        #expect(d.state() == .working(since: F.at(0)))
        #expect(d.stateVersion == 1)
        #expect(d.session()?.metadata[MetadataKey.claudeSessionStartSource] == "compact")
    }

    @Test func rateLimitedNeverCountsAsWorking() throws {
        let d = EngineDriver()
        d.send(.turnStarted, at: 0)
        let effects = d.send(.turnFinished(.rateLimited), at: 30)
        #expect(effects.map(\.kind) == [.finished])
        #expect(try #require(effects.first).outcome == .rateLimited)
        #expect(d.state()?.isIdle(outcome: .rateLimited) == true)
        #expect(d.aggregate.anyWorking == false)
        #expect(d.tick(at: 35).isEmpty)
    }

    @Test func backgroundTasksKeepTheSessionWorking() throws {
        let d = EngineDriver()
        d.send(.turnStarted, at: 0)
        d.send(.turnFinished(.completed), at: 30, background: true)
        #expect(d.tick(at: 35).isEmpty)
        #expect(d.state()?.isWorking == true)
        #expect(d.aggregate.anyWorking == true)
        #expect(d.stateVersion == 1)
        // The background work wakes the model; its final Stop has no background tasks.
        d.send(.turnFinished(.completed), at: 300)
        let finished = try #require(d.tick(at: 305).first)
        #expect(finished.kind == .finished)
        #expect(finished.workedFor == 305)
    }

    // MARK: T3 heuristics

    @Test func heuristicSustainAndExitWindow() throws {
        let d = EngineDriver()
        let p = F.identity(300)
        let key = SessionKey.fallback(agent: .plandex, identity: p)
        func sample(_ t: TimeInterval, _ kinds: Set<EvidenceKind>) {
            d.processes(at: t, [F.process(p, .plandex, kinds: kinds, at: t)])
        }
        sample(0, [.treeCPU, .childChurn])
        sample(10, [.treeCPU, .childChurn])
        sample(19, [.treeCPU, .childChurn])
        #expect(d.session(key) == nil)
        #expect(d.aggregate.anyWorking == false)
        sample(20, [.treeCPU, .childChurn])
        let session = try #require(d.session(key))
        #expect(session.state == .working(since: F.at(0)))
        #expect(session.turnStartedAt == F.at(0))
        #expect(session.isHeuristicOnly)
        #expect(d.stateVersion == 1)

        sample(30, [.treeCPU])
        for t in stride(from: 35.0, through: 325, by: 5) { sample(t, [.treeCPU]) }
        sample(329, [.treeCPU])
        #expect(d.state(key)?.isWorking == true)
        sample(330, [.treeCPU])
        #expect(d.state(key)?.isIdle(outcome: nil) == true)
        let quiet = try #require(d.effects(.wentQuiet).first)
        #expect(quiet.session.isHeuristicOnly)
        #expect(quiet.workedFor == 30)
        #expect(d.effects.map(\.kind) == [.wentQuiet])
    }

    @Test func codexNotifyTwiceWithEvidenceBetweenFinishesTwice() throws {
        let d = EngineDriver()
        let codex = F.identity(400)
        let real = F.key("thread-1", .codex)
        let work: Set<EvidenceKind> = [.treeCPU, .modelAPISocket]
        // Turn 1: T3 sees the work before Codex says anything (notify-only: no start edge).
        for t in stride(from: 0.0, through: 20, by: 5) { d.processes(at: t, [F.process(codex, .codex, kinds: work, at: t)]) }
        #expect(d.aggregate.anyWorking == true)
        #expect(d.stateVersion == 1)
        d.send(.turnFinished(.completed), at: 40, agent: .codex, session: "thread-1", process: codex)
        let first = try #require(d.tick(at: 45).first)
        #expect(first.kind == .finished)
        #expect(first.session.key == real)
        #expect(first.workedFor == 45)
        #expect(d.engine.sessions.map(\.key) == [real]) // the fallback session was re-keyed, not duplicated

        // The sampler's 60 s window still shows turn 1 after its finish: that never starts a phantom turn.
        for t in stride(from: 50.0, through: 100, by: 5) { d.processes(at: t, [F.process(codex, .codex, kinds: work, at: t)]) }
        #expect(d.state(real)?.isIdle(outcome: .completed) == true)
        #expect(d.stateVersion == 1)

        // Turn 2: evidence beyond the window, sustained 20 s, then the second notify.
        for t in stride(from: 105.0, through: 125, by: 5) { d.processes(at: t, [F.process(codex, .codex, kinds: work, at: t)]) }
        #expect(d.state(real) == .working(since: F.at(105)))
        #expect(d.stateVersion == 2)
        d.send(.turnFinished(.completed), at: 140, agent: .codex, session: "thread-1", process: codex)
        let second = try #require(d.tick(at: 145).first)
        #expect(second.kind == .finished)
        #expect(second.workedFor == 40)
        // Quiet afterwards: the finish stands, no `wentQuiet`.
        for t in stride(from: 150.0, through: 600, by: 5) {
            d.processes(at: t, [F.process(codex, .codex, at: t)])
            d.tick(at: t)
        }
        #expect(d.kinds == [.finished, .finished])
    }

    @Test func geminiParentAndChildNodeAreOneSession() {
        let d = EngineDriver()
        let parent = F.identity(500)
        let child = F.identity(501)
        for t in stride(from: 0.0, through: 30, by: 5) {
            d.processes(at: t, [
                F.process(parent, .gemini, kinds: [.treeCPU, .modelAPISocket], at: t, descendants: [child]),
                F.process(child, .gemini, kinds: [.treeCPU, .modelAPISocket], at: t, ancestors: [parent]),
            ])
        }
        #expect(d.engine.sessions.map(\.key) == [SessionKey.fallback(agent: .gemini, identity: parent)])
    }

    @Test func ideHostWithoutModelSocketGetsNoSessionButWithOneDoes() {
        let d = EngineDriver()
        let host = F.identity(600)
        for t in stride(from: 0.0, through: 30, by: 5) {
            d.processes(at: t, [F.process(host, .codex, kinds: [.treeCPU, .childChurn], at: t, ideHost: true)])
        }
        #expect(d.engine.sessions.isEmpty)
        for t in stride(from: 35.0, through: 60, by: 5) {
            d.processes(at: t, [F.process(host, .codex, kinds: [.treeCPU, .modelAPISocket], at: t, ideHost: true)])
        }
        #expect(d.engine.sessions.map(\.key) == [SessionKey.fallback(agent: .codex, identity: host)])
    }

    @Test func ignoredIdentityInfrastructureAndBoundDescendantsGetNoSession() {
        let d = EngineDriver()
        let parked = F.identity(700)
        let daemon = F.identity(701)
        let lead = F.identity(702)
        let teammate = F.identity(703)
        d.claude(at: 0, [], ignored: [parked])
        d.send(.turnStarted, at: 0, process: lead) // lead Claude session bound by its hook (CLAUDE_PID)
        let busy: Set<EvidenceKind> = [.treeCPU, .childChurn, .modelAPISocket]
        for t in stride(from: 0.0, through: 40, by: 5) {
            d.processes(at: t, [
                F.process(parked, .claude, kinds: busy, at: t),
                F.process(daemon, .claude, kinds: busy, at: t, infrastructure: true),
                // The lead is not in this snapshot: ownership must still come from its binding.
                F.process(teammate, .claude, kinds: busy, at: t, ancestors: [lead]),
            ])
        }
        #expect(d.engine.sessions.map(\.key) == [F.key("s1")])
    }

    // MARK: Bookkeeping

    @Test func duplicateEventIDIsIgnored() {
        let d = EngineDriver()
        d.send(.turnStarted, at: 0, id: "1791842400000000000-42.event")
        #expect(d.send(.turnFinished(.completed), at: 5, id: "1791842400000000000-42.event").isEmpty)
        #expect(d.state()?.isWorking == true)
        #expect(d.tick(at: 20).isEmpty)
    }

    @Test func endedSessionsAreDroppedAfterTenMinutes() throws {
        let d = EngineDriver()
        d.send(.turnStarted, at: 0)
        let ended = d.send(.sessionEnded, at: 100)
        #expect(ended.map(\.kind) == [.ended])
        #expect(d.state() == .ended(at: F.at(100)))
        #expect(d.aggregate.liveCount == 0)
        d.tick(at: 699)
        #expect(d.session() != nil)
        d.tick(at: 700)
        #expect(d.session() == nil)
        #expect(d.engine.sessions.isEmpty)
    }

    @Test func stateVersionIsSeededAndBumpsOnlyOnNewEntriesIntoWorking() {
        let d = EngineDriver(initialStateVersion: 1_791_842_400_000)
        let base = 1_791_842_400_000
        let claude = F.identity(800)
        #expect(d.stateVersion == base)
        d.send(.turnStarted, at: 0, process: claude)
        #expect(d.stateVersion == base + 1)
        d.send(.activity, at: 1)
        d.send(.turnStarted, at: 2) // already working: no new entry
        #expect(d.stateVersion == base + 1)
        d.send(.turnFinished(.completed), at: 10)
        d.tick(at: 15)
        #expect(d.stateVersion == base + 1)
        d.claude(at: 20, [F.live(claude, statusAt: 20)])
        #expect(d.stateVersion == base + 2) // record busy: a new turn
        d.send(.turnFinished(.completed), at: 30)
        d.tick(at: 35) // held by the busy record: no bump
        #expect(d.state()?.isWorking == true)
        #expect(d.stateVersion == base + 2)
        d.send(.needsInput(.permission), at: 40)
        d.send(.activity, at: 50) // waiting exit
        #expect(d.stateVersion == base + 3)
    }

    @Test func fallbackSessionIsRekeyedWhenARealIDAppearsForTheSameProcess() throws {
        let d = EngineDriver()
        let codex = F.identity(900)
        for t in stride(from: 0.0, through: 20, by: 5) {
            d.processes(at: t, [F.process(codex, .codex, kinds: [.treeCPU, .childChurn], at: t)])
        }
        let fallback = SessionKey.fallback(agent: .codex, identity: codex)
        #expect(d.session(fallback)?.state.isWorking == true)

        let real = F.key("019a-thread", .codex)
        d.send(.turnStarted, at: 30, agent: .codex, session: "019a-thread", process: codex)
        #expect(d.session(fallback) == nil)
        let session = try #require(d.session(real))
        #expect(session.state.isWorking)
        #expect(session.turnStartedAt == F.at(0)) // earliest start kept
        #expect(session.tiers.isSuperset(of: [.hook, .heuristic]))
        #expect(session.agentProcess == codex)
        #expect(d.stateVersion == 1) // no second entry into working
        #expect(d.engine.sessions.count == 1)
        #expect(d.effects.isEmpty)
    }

    @Test func fieldsOtherModulesReadArePopulated() throws {
        let d = EngineDriver()
        let claude = F.identity(1000)
        let host = HostApp(bundleID: "com.apple.Terminal", name: "Terminal")
        d.send(.turnStarted, at: 0, process: claude, cwd: "/Users/me/proj", transcriptPath: "/h/.claude/projects/-Users-me-proj/s1.jsonl",
               host: host, metadata: [MetadataKey.claudeEntrypoint: "cli"])
        var s = try #require(d.session())
        #expect(s.metadata[MetadataKey.transcriptPath] == "/h/.claude/projects/-Users-me-proj/s1.jsonl")
        #expect(s.metadata[MetadataKey.sessionStoreDirectory] == "/h/.claude/projects/-Users-me-proj/s1")
        #expect(s.host == host)
        #expect(s.cwd == "/Users/me/proj")

        var record = F.record(pid: claude.pid, status: "busy", statusAt: 0, kind: "bg", cwd: "/Users/me", jobId: "e5b3e311",
                              entrypoint: "claude-vscode", bridge: "bridge-1")
        record.name = "derived-40"
        record.nameSource = "derived"
        d.claude(at: 1, [F.observation(record, claude, transcript: "/h/.claude/projects/-Users-me/s1.jsonl", title: "Fix the cursor",
                                       currentCwd: "/Users/me/proj/sub", preview: "Done. All tests pass.")])
        s = try #require(d.session())
        #expect(s.title == "Fix the cursor")
        #expect(s.cwd == "/Users/me/proj/sub") // current cwd beats the record's launch cwd
        #expect(s.lastMessagePreview == "Done. All tests pass.")
        #expect(s.metadata[MetadataKey.transcriptPath] == "/h/.claude/projects/-Users-me/s1.jsonl")
        #expect(s.metadata[MetadataKey.sessionStoreDirectory] == "/h/.claude/projects/-Users-me/s1")
        #expect(s.metadata[MetadataKey.claudeKind] == "bg")
        #expect(s.metadata[MetadataKey.claudeJobID] == "e5b3e311")
        #expect(s.metadata[MetadataKey.claudeEntrypoint] == "claude-vscode")
        #expect(s.remoteControlConnected)
        #expect(s.tiers == [.hook, .stateFile])

        d.send(.needsInput(.question), at: 5, waitingFor: "Which database?")
        #expect(d.session()?.waitingFor == "Which database?")
        d.send(.turnFinished(.completed), at: 10, preview: "Migrated to Postgres.")
        // The record going idle inside the settle window does not cut it short (brief §5.2: the finish comes at expiry).
        #expect(d.claude(at: 11, [F.observation(F.record(pid: claude.pid, status: "idle", statusAt: 11), claude)]).isEmpty)
        #expect(d.state()?.isSettling == true)
        let finished = try #require(d.tick(at: 15).first)
        #expect(finished.kind == .finished)
        #expect(finished.workedFor == 15)
        s = try #require(d.session())
        #expect(s.lastMessagePreview == "Migrated to Postgres.")
        #expect(s.lastTurnDuration == 15)
        #expect(s.waitingFor == nil)
        // A record-only observation (no transcript) never regresses the current cwd to the launch cwd.
        #expect(s.cwd == "/Users/me/proj/sub")
    }
}
