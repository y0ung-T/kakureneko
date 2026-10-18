@testable import KakurenekoSessions
import KakurenekoKit
import Foundation
import Testing

/// T2: merging `sessions/<pid>.json` records with `claude agents --json`, record lifecycle (dead, deleted,
/// unreadable), duplicate records, the busy → idle finish rules and the fields other modules read.
@Suite("SessionEngine Claude T2", .timeLimit(.minutes(1)))
struct EngineClaudeStateTests {
    // MARK: Merge rules (pure)

    struct MergeCase: Sendable, CustomTestStringConvertible {
        var name: String
        var record: String?? = .none // .none = no record; .some(nil) = record without status
        var recordAt: TimeInterval = 10
        var entryStatus: String?
        var entryState: String?
        var entryWaitingFor: String?
        var hasEntry: Bool { entryStatus != nil || entryState != nil }
        var polledAt: TimeInterval? = 20
        var expected: ClaudeT2Status?
        var testDescription: String { name }
    }

    @Test(arguments: [
        MergeCase(name: "record fresher than the poll", record: "busy", recordAt: 30, entryStatus: "idle", expected: .busy),
        MergeCase(name: "poll fresher than the record", record: "busy", entryStatus: "idle", expected: .idle),
        MergeCase(name: "record as fresh as the poll", record: "idle", recordAt: 20, entryStatus: "busy", expected: .idle),
        MergeCase(name: "record without status", record: .some(nil), entryStatus: "busy", expected: .busy),
        MergeCase(name: "record only", record: "shell", polledAt: nil, expected: .shell),
        MergeCase(name: "record only, a poll without this session", record: "waiting", expected: .waiting(nil)),
        MergeCase(name: "entry only", entryStatus: "waiting", entryWaitingFor: "permission prompt",
                  expected: .waiting("permission prompt")),
        MergeCase(name: "bg working beats a stale idle record", record: "idle", entryState: "working", expected: .busy),
        MergeCase(name: "bg blocked", record: "idle", entryState: "blocked", entryWaitingFor: "permission prompt",
                  expected: .waiting("permission prompt")),
        MergeCase(name: "bg done beats a stale busy record", record: "busy", entryState: "done", expected: .idle),
        MergeCase(name: "bg done, a fresher busy record proves a start", record: "busy", recordAt: 30, entryState: "done",
                  expected: .busy),
        MergeCase(name: "bg failed", entryState: "failed", expected: .idle),
        MergeCase(name: "bg stopped, a fresher shell record", record: "shell", recordAt: 30, entryState: "stopped",
                  expected: .shell),
        MergeCase(name: "bg unknown state falls back to status", entryStatus: "busy", entryState: "resuming", expected: .busy),
        MergeCase(name: "nothing known", record: .some(nil), polledAt: nil, expected: nil),
        MergeCase(name: "unknown entry status", entryStatus: "thinking", expected: nil),
    ])
    func mergedStatus(_ c: MergeCase) {
        let record: ClaudeSessionRecord? = switch c.record {
        case .none: nil
        case .some(let status): F.record(pid: 1, status: status, statusAt: c.recordAt)
        }
        let entry = c.hasEntry ? ClaudeAgentsEntry(pid: 1, sessionId: "s1", status: c.entryStatus, state: c.entryState,
                                                   waitingFor: c.entryWaitingFor) : nil
        #expect(EngineState.mergedStatus(record: record, entry: entry, agentsPolledAt: c.polledAt.map(F.at)) == c.expected)
    }

    // MARK: Views and duplicates

    @Test(arguments: [false, true])
    func crashLeftoverAndResumedRecordAreOneSession(reversed: Bool) {
        let d = EngineDriver()
        let resumed = F.identity(21)
        var observations = [F.observation(F.record(pid: 20, status: "busy", statusAt: -3600), nil), F.live(resumed, statusAt: 0)]
        if reversed { observations.reverse() }
        d.claude(at: 0, observations)
        #expect(d.engine.sessions.map(\.key) == [F.key("s1")])
        #expect(d.session()?.agentProcess == resumed)
        #expect(d.state()?.isWorking == true)
        #expect(d.effects.isEmpty)
    }

    @Test func twoLiveRecordsForOneConversationTakeTheMostRecentlyUpdated() throws {
        let snapshot = ClaudeStateSnapshot(takenAt: F.at(30), sessions: [
            F.live(F.identity(31), status: "busy", statusAt: 20),
            F.live(F.identity(30), status: "idle", statusAt: 10),
        ], sessionsDirectoryReadable: true)
        let views = EngineState.claudeViews(from: snapshot, processes: nil)
        let view = try #require(views[F.key("s1")])
        #expect(views.count == 1)
        #expect(view.identity == F.identity(31))
        #expect(view.status == .busy)
    }

    @Test func recordsWithoutASessionIDAreKeyedByTheirLiveProcess() {
        let live = F.identity(32)
        let snapshot = ClaudeStateSnapshot(takenAt: F.at(0), sessions: [
            F.observation(F.record(pid: 32, session: nil), live),
            F.observation(F.record(pid: 33, session: nil), nil),
        ], sessionsDirectoryReadable: true)
        let views = EngineState.claudeViews(from: snapshot, processes: nil)
        #expect(Array(views.keys) == [SessionKey.fallback(agent: .claude, identity: live)])
    }

    @Test func agentsOnlyEntriesBecomeSessionsAndHistoryIsIgnored() throws {
        let d = EngineDriver()
        let bgProcess = F.identity(40)
        let interactive = F.identity(41)
        d.processes(at: 0, [F.process(bgProcess, .claude, at: 0), F.process(interactive, .claude, at: 0)])
        let agents = [
            ClaudeAgentsEntry(pid: 41, cwd: "/Users/me/proj", kind: "interactive", sessionId: "s1", name: "proj-3f", status: "busy"),
            ClaudeAgentsEntry(pid: 40, id: "a1b2c3d4", cwd: "/Users/me/other", kind: "background", sessionId: "bg-x",
                              name: "Nightly refactor", status: "busy", state: "working"),
            ClaudeAgentsEntry(id: "deadbeef", cwd: "/Users/me/old", kind: "background", sessionId: "bg-old",
                              name: "Old job", state: "stopped"),
        ]
        d.claude(at: 1, [F.live(interactive, statusAt: 1)], agents: agents, polledAt: 1)
        #expect(d.engine.sessions.map(\.key).sorted() == [F.key("bg-x"), F.key("s1")])
        let bg = try #require(d.session(F.key("bg-x")))
        #expect(bg.agentProcess == bgProcess)
        #expect(bg.title == "Nightly refactor")
        #expect(bg.cwd == "/Users/me/other")
        #expect(bg.metadata[MetadataKey.claudeKind] == "bg")
        #expect(bg.metadata[MetadataKey.claudeJobID] == "a1b2c3d4")
        #expect(bg.state.isWorking)
        // An interactive entry's derived name is not a title.
        #expect(d.session()?.title == nil)
    }

    @Test func oneConversationSeenByT3ThenT2ThenHooksIsOneSession() throws {
        let d = EngineDriver()
        let claude = F.identity(42)
        let busy: Set<EvidenceKind> = [.treeCPU, .modelAPISocket]
        for t in stride(from: 0.0, through: 20, by: 5) { d.processes(at: t, [F.process(claude, .claude, kinds: busy, at: t)]) }
        #expect(d.session(.fallback(agent: .claude, identity: claude))?.state.isWorking == true)
        d.claude(at: 25, [F.live(claude, statusAt: 25)])
        d.send(.turnStarted, at: 26, process: claude)
        d.processes(at: 30, [F.process(claude, .claude, kinds: busy, at: 30)])
        let s = try #require(d.session())
        #expect(d.engine.sessions.map(\.key) == [F.key("s1")])
        #expect(s.tiers.isSuperset(of: [.heuristic, .stateFile, .hook]))
        #expect(s.turnStartedAt == F.at(0))
        #expect(d.stateVersion == 1)
        #expect(d.effects.isEmpty)
    }

    // MARK: Record lifecycle

    @Test func deadRecordEndsTheSessionAndNeverCreatesOne() {
        let d = EngineDriver()
        let claude = F.identity(50)
        d.claude(at: 0, [F.observation(F.record(pid: 49, session: "leftover"), nil)])
        #expect(d.engine.sessions.isEmpty)
        d.claude(at: 1, [F.live(claude, statusAt: 1)])
        let effects = d.claude(at: 10, [F.observation(F.record(pid: 50, statusAt: 1), nil)])
        #expect(effects.map(\.kind) == [.ended])
        #expect(d.state() == .ended(at: F.at(10)))
        #expect(d.session()?.tiers.contains(.guardrail) == true)
    }

    @Test func deletedRecordEndsTheSessionOnlyWhileTheDirectoryIsReadable() {
        let d = EngineDriver()
        let claude = F.identity(51)
        d.claude(at: 0, [F.live(claude, statusAt: 0)])
        #expect(d.claude(at: 10, [], readable: false).isEmpty)
        #expect(d.state()?.isWorking == true)
        #expect(d.claude(at: 20, []).map(\.kind) == [.ended])
        #expect(d.state() == .ended(at: F.at(20)))
    }

    @Test func backgroundEntryVanishingEndsTheSessionOnlyAfterASuccessfulPoll() {
        let d = EngineDriver()
        let entry = ClaudeAgentsEntry(pid: 52, id: "bg1", kind: "background", sessionId: "bg-1", state: "working")
        d.claude(at: 0, [], agents: [entry], polledAt: 0)
        #expect(d.state(F.key("bg-1"))?.isWorking == true)
        #expect(d.claude(at: 15, [], agents: nil).isEmpty) // poll failed
        #expect(d.claude(at: 30, [], agents: [], polledAt: 30).map(\.kind) == [.ended])
    }

    @Test func aStalePollCannotKeepADeletedRecordAlive() {
        let d = EngineDriver()
        let claude = F.identity(53)
        let entry = ClaudeAgentsEntry(pid: 53, kind: "interactive", sessionId: "s1", status: "busy")
        d.claude(at: 0, [F.live(claude, statusAt: 0)], agents: [entry], polledAt: 0)
        // The record is gone (session exited); the last poll still lists it.
        #expect(d.claude(at: 10, [], agents: [entry], polledAt: 0).map(\.kind) == [.ended])
    }

    @Test func crashLeftoverDoesNotEndASessionHooksBoundToAResumedProcess() {
        let d = EngineDriver()
        let resumed = F.identity(55)
        d.send(.turnStarted, at: 0, process: resumed)
        #expect(d.claude(at: 1, [F.observation(F.record(pid: 54, statusAt: -60), nil)]).isEmpty)
        #expect(d.state()?.isWorking == true)
    }

    @Test func recordWithoutStatusCreatesAnIdleSessionUntilTheFirstWrite() {
        let d = EngineDriver()
        let claude = F.identity(56)
        d.claude(at: 0, [F.live(claude, status: nil, statusAt: nil)])
        #expect(d.state() == .idle(since: F.at(0), outcome: nil))
        #expect(d.session()?.tiers == [.stateFile])
        d.claude(at: 5, [F.live(claude, statusAt: 5)])
        #expect(d.state() == .working(since: F.at(5)))
        #expect(d.effects.isEmpty)
    }

    @Test func idleOrShellRecordNeverCountsAsWorking() {
        let d = EngineDriver()
        d.claude(at: 0, [F.live(F.identity(57), session: "a", status: "idle", statusAt: 0),
                         F.live(F.identity(58), session: "b", status: "shell", statusAt: 0)])
        #expect(d.aggregate.anyWorking == false)
        #expect(d.aggregate.idleCount == 2)
        #expect(d.effects.isEmpty)
    }

    // MARK: Busy → idle finish rules

    @Test func busyToShellAfterAStopFinishes() throws {
        let d = EngineDriver()
        let claude = F.identity(59)
        d.claude(at: 0, [F.live(claude, statusAt: 0)])
        d.send(.turnFinished(.completed), at: 30, process: claude)
        d.tick(at: 35) // held: the record is still busy
        let effects = d.claude(at: 50, [F.live(claude, status: "shell", statusAt: 50)])
        #expect(effects.map(\.kind) == [.finished])
        #expect(try #require(effects.first).workedFor == 50)
        #expect(d.aggregate.anyWorking == false)
    }

    @Test func stopArrivingJustAfterTheRecordWentIdleStillFinishesTheTurn() throws {
        let d = EngineDriver()
        let claude = F.identity(60)
        d.send(.turnStarted, at: 0, process: claude)
        d.claude(at: 1, [F.live(claude, statusAt: 1)])
        // The record's idle races ahead of the Stop hook: interrupted for now, no push.
        #expect(d.claude(at: 30, [F.live(claude, status: "idle", statusAt: 30)]).isEmpty)
        #expect(d.state()?.isIdle(outcome: .interrupted) == true)
        d.send(.turnFinished(.completed), at: 31, process: claude)
        let finished = try #require(d.tick(at: 36).first)
        #expect(finished.kind == .finished)
        #expect(finished.workedFor == 36) // the turn that started at 0
        #expect(d.kinds == [.finished])
    }

    @Test func aLateTurnDurationNeverUpgradesAHookLiveInterrupt() {
        let d = EngineDriver()
        let claude = F.identity(61)
        d.send(.sessionStarted, at: 0, process: claude)
        d.claude(at: 1, [F.live(claude, statusAt: 1)])
        d.claude(at: 30, [F.live(claude, status: "idle", statusAt: 30)])
        d.claude(at: 32, [F.live(claude, status: "idle", statusAt: 30, turnCompletedAt: 30.1, durationMs: 29_000)])
        #expect(d.state()?.isIdle(outcome: .interrupted) == true)
        #expect(d.effects.isEmpty)
    }

    @Test func t2OnlyWaitingThenIdleIsNoFinish() {
        let d = EngineDriver()
        let claude = F.identity(62)
        d.claude(at: 0, [F.live(claude, statusAt: 0)])
        d.claude(at: 10, [F.live(claude, status: "waiting", statusAt: 10, waitingFor: "permission prompt")])
        d.claude(at: 20, [F.live(claude, status: "idle", statusAt: 20, turnCompletedAt: 19, durationMs: 19_000)])
        #expect(d.state()?.isIdle(outcome: nil) == true)
        #expect(d.kinds == [.needsInput])
    }

    @Test func t2OnlyTurnsFinishOncePerTurnAcrossSeveralTurns() throws {
        let d = EngineDriver()
        let claude = F.identity(63)
        d.claude(at: 0, [F.live(claude, statusAt: 0)])
        d.claude(at: 30, [F.live(claude, status: "idle", statusAt: 30, turnCompletedAt: 29.5, durationMs: 29_500)])
        d.claude(at: 100, [F.live(claude, statusAt: 100, turnCompletedAt: 29.5, durationMs: 29_500)])
        #expect(d.stateVersion == 2)
        // Turn 2 ends; the tail still shows turn 1's turn_duration until the re-read.
        d.claude(at: 160, [F.live(claude, status: "idle", statusAt: 160, turnCompletedAt: 29.5, durationMs: 29_500)])
        #expect(d.effects(.finished).count == 1)
        d.claude(at: 161.5, [F.live(claude, status: "idle", statusAt: 160, turnCompletedAt: 160.2, durationMs: 60_000)])
        #expect(d.effects(.finished).map(\.workedFor) == [29.5, 60])
    }

    // MARK: Fields

    @Test func titleFollowsTheLatestChangedSource() {
        let d = EngineDriver()
        let claude = F.identity(64)
        func observe(_ t: TimeInterval, title: String?, name: String? = nil, nameSource: String? = nil) {
            let record = F.record(pid: claude.pid, statusAt: 0, name: name, nameSource: nameSource)
            d.claude(at: t, [F.observation(record, claude, title: title)])
        }
        observe(0, title: nil, name: "developer-40", nameSource: "derived")
        #expect(d.session()?.title == nil) // derived names are not titles
        observe(1, title: nil, name: "Paper outline", nameSource: "user")
        #expect(d.session()?.title == "Paper outline")
        observe(2, title: "Fix the cursor", name: "Paper outline", nameSource: "user")
        #expect(d.session()?.title == "Fix the cursor")
        d.send(.activity, at: 3, process: claude, title: "Renamed by hook")
        observe(4, title: "Fix the cursor") // unchanged tail: the fresher hook value stays
        #expect(d.session()?.title == "Renamed by hook")
        observe(5, title: "Portfolio cursor reveal")
        #expect(d.session()?.title == "Portfolio cursor reveal")
    }

    @Test func remoteControlAndRecordMetadataFollowTheRecord() {
        let d = EngineDriver()
        let claude = F.identity(65)
        d.claude(at: 0, [F.observation(F.record(pid: claude.pid, statusAt: 0, entrypoint: "claude-desktop", bridge: "rc-1"), claude)])
        #expect(d.session()?.remoteControlConnected == true)
        #expect(d.session()?.metadata[MetadataKey.claudeEntrypoint] == "claude-desktop")
        #expect(d.session()?.metadata[MetadataKey.claudeKind] == "interactive")
        d.claude(at: 5, [F.observation(F.record(pid: claude.pid, statusAt: 0, entrypoint: "claude-desktop"), claude)])
        #expect(d.session()?.remoteControlConnected == false)
    }

    @Test func transcriptPathFromEventAndObservationLatestWins() {
        let d = EngineDriver()
        let claude = F.identity(66)
        d.send(.sessionStarted, at: 0, process: claude, transcriptPath: "/h/.claude/projects/-a/s1.jsonl")
        d.claude(at: 1, [F.observation(F.record(pid: claude.pid, statusAt: 1), claude, transcript: "/h/.claude/projects/-b/s1.jsonl")])
        #expect(d.session()?.metadata[MetadataKey.transcriptPath] == "/h/.claude/projects/-b/s1.jsonl")
        #expect(d.session()?.metadata[MetadataKey.sessionStoreDirectory] == "/h/.claude/projects/-b/s1")
        d.send(.activity, at: 2, process: claude, transcriptPath: "/h/.claude/projects/-c/s1.jsonl")
        d.claude(at: 3, [F.observation(F.record(pid: claude.pid, statusAt: 1), claude, transcript: "/h/.claude/projects/-b/s1.jsonl")])
        #expect(d.session()?.metadata[MetadataKey.transcriptPath] == "/h/.claude/projects/-c/s1.jsonl")
        #expect(d.session()?.metadata[MetadataKey.sessionStoreDirectory] == "/h/.claude/projects/-c/s1")
    }

    @Test func ignoredIdentitiesComeFromTheLatestSnapshotOnly() {
        let d = EngineDriver()
        let parked = F.identity(67)
        let busy: Set<EvidenceKind> = [.treeCPU, .childChurn]
        d.claude(at: 0, [], ignored: [parked])
        for t in stride(from: 0.0, through: 30, by: 5) { d.processes(at: t, [F.process(parked, .claude, kinds: busy, at: t)]) }
        #expect(d.engine.sessions.isEmpty)
        // Un-parked (the conversation came back to this process): evidence counts again.
        d.claude(at: 31, [])
        for t in stride(from: 35.0, through: 55, by: 5) { d.processes(at: t, [F.process(parked, .claude, kinds: busy, at: t)]) }
        #expect(d.engine.sessions.map(\.key) == [.fallback(agent: .claude, identity: parked)])
    }
}
