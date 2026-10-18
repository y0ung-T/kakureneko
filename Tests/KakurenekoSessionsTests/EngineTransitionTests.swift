@testable import KakurenekoSessions
import KakurenekoKit
import Foundation
import Testing

/// T1 transitions and the §11 item 17 refinements that do not need Claude T2 state: waiting entry/exit, settle,
/// stall guard (incl. settling), heuristic turns for agents without a start edge, sub-threads, dismissal.
@Suite("SessionEngine transitions", .timeLimit(.minutes(1)))
struct EngineTransitionTests {
    // MARK: Needs input

    @Test(arguments: [
        ("permission prompt", NeedsInputKind.permission),
        ("input needed", .question),
        ("dialog open", .dialog),
        ("  Permission Prompt\n", .permission),
        ("sandbox request", .unknown),
        ("worker request", .unknown),
        ("goal proposal", .unknown),
    ])
    func recordWaitingForTextMapsToNeedsInputKind(text: String, kind: NeedsInputKind) throws {
        #expect(EngineAgentTraits.needsInputKind(forWaitingFor: text) == kind)
        let d = EngineDriver()
        let claude = F.identity(1)
        d.claude(at: 0, [F.live(claude, statusAt: 0)])
        let effects = d.claude(at: 10, [F.live(claude, status: "waiting", statusAt: 10, waitingFor: text)])
        let effect = try #require(effects.first)
        #expect(effects.map(\.kind) == [.needsInput])
        #expect(effect.needsInputKind == kind)
        #expect(d.state() == .waiting(kind: kind, since: F.at(10)))
        #expect(d.session()?.waitingFor == text)
    }

    @Test func missingWaitingForTextIsUnknown() {
        #expect(EngineAgentTraits.needsInputKind(forWaitingFor: nil) == .unknown)
        let d = EngineDriver()
        d.claude(at: 0, [F.live(F.identity(1), status: "waiting", statusAt: 0)])
        #expect(d.effects.map(\.needsInputKind) == [.unknown])
    }

    @Test func recordWaitingRewritesNeverPushTwiceAndIdleResolvesTheWaitQuietly() {
        let d = EngineDriver()
        let claude = F.identity(2)
        d.claude(at: 0, [F.live(claude, statusAt: 0)])
        #expect(d.claude(at: 10, [F.live(claude, status: "waiting", statusAt: 10, waitingFor: "permission prompt")]).map(\.kind) == [.needsInput])
        // Same record again, then a rewrite with new text and a new statusUpdatedAt: still the same wait.
        #expect(d.claude(at: 15, [F.live(claude, status: "waiting", statusAt: 10, waitingFor: "permission prompt")]).isEmpty)
        #expect(d.claude(at: 20, [F.live(claude, status: "waiting", statusAt: 20, waitingFor: "input needed")]).isEmpty)
        #expect(d.session()?.waitingFor == "input needed")
        // The user answered elsewhere and the turn ended: idle(nil), no push.
        #expect(d.claude(at: 30, [F.live(claude, status: "idle", statusAt: 30)]).isEmpty)
        #expect(d.state()?.isIdle(outcome: nil) == true)
        #expect(d.session()?.waitingFor == nil)
        #expect(d.kinds == [.needsInput])
    }

    @Test(arguments: ["turnStarted", "activity", "recordBusy"])
    func waitingExitsOnAResumeEdge(signal: String) {
        let d = EngineDriver()
        let claude = F.identity(3)
        d.claude(at: 0, [F.live(claude, statusAt: 0)])
        d.send(.needsInput(.permission), at: 10, process: claude)
        #expect(d.state()?.isWaiting == true)
        #expect(d.stateVersion == 1)
        switch signal {
        case "turnStarted": d.send(.turnStarted, at: 20, process: claude)
        case "activity": d.send(.activity, at: 20, process: claude)
        default: d.claude(at: 20, [F.live(claude, statusAt: 20)])
        }
        #expect(d.state() == .working(since: F.at(20)))
        // An approval continues the same turn; a new prompt starts a new one.
        #expect(d.session()?.turnStartedAt == F.at(signal == "turnStarted" ? 20 : 0))
        #expect(d.stateVersion == 2)
        #expect(d.kinds == [.needsInput])
    }

    @Test func staleBusyRecordDoesNotEndAHookReportedWait() {
        let d = EngineDriver()
        let claude = F.identity(4)
        d.claude(at: 0, [F.live(claude, statusAt: 0)])
        d.send(.needsInput(.permission), at: 10, process: claude)
        // The record has not caught up yet (same busy write): no edge, still waiting.
        #expect(d.claude(at: 12, [F.live(claude, statusAt: 0)]).isEmpty)
        #expect(d.state()?.isWaiting == true)
        // Claude now writes waiting: same wait, no second push.
        #expect(d.claude(at: 13, [F.live(claude, status: "waiting", statusAt: 13, waitingFor: "permission prompt")]).isEmpty)
        #expect(d.kinds == [.needsInput])
    }

    @Test func turnFinishedWhileWaitingSettlesThenFinishes() throws {
        let d = EngineDriver()
        d.send(.turnStarted, at: 0)
        d.send(.needsInput(.question), at: 10)
        d.send(.turnFinished(.completed), at: 20)
        #expect(d.state() == .settling(until: F.at(25), outcome: .completed))
        let finished = try #require(d.tick(at: 25).first)
        #expect(finished.kind == .finished)
        #expect(finished.workedFor == 25)
        #expect(d.kinds == [.needsInput, .finished])
    }

    @Test func backgroundAgentBlockedThenWorkingResumes() {
        let d = EngineDriver()
        let key = F.key("bg-1")
        func poll(_ t: TimeInterval, state: String, waitingFor: String? = nil) {
            let entry = ClaudeAgentsEntry(pid: 60, id: "bg1", cwd: "/Users/me/proj", kind: "background", sessionId: "bg-1",
                                          name: "Nightly refactor", state: state, waitingFor: waitingFor)
            d.claude(at: t, [], agents: [entry], polledAt: t)
        }
        poll(0, state: "working")
        #expect(d.state(key)?.isWorking == true)
        #expect(d.session(key)?.title == "Nightly refactor")
        poll(15, state: "blocked", waitingFor: "permission prompt")
        #expect(d.state(key) == .waiting(kind: .permission, since: F.at(15)))
        poll(30, state: "blocked", waitingFor: "permission prompt")
        poll(45, state: "working")
        #expect(d.state(key)?.isWorking == true)
        #expect(d.stateVersion == 2)
        #expect(d.kinds == [.needsInput])
    }

    // MARK: Waiting exit on T3 progress (agents without a resume edge)

    struct WaitingExitCase: Sendable, CustomTestStringConvertible {
        var name: String
        var kinds: Set<EvidenceKind>
        var withRecord = false
        var staleSamples = false
        var resumes: Bool
        var testDescription: String { name }
    }

    @Test(arguments: [
        WaitingExitCase(name: "E1+E4", kinds: [.treeCPU, .modelAPISocket], resumes: true),
        WaitingExitCase(name: "E2+E5", kinds: [.childChurn, .ttyActivity], resumes: true),
        WaitingExitCase(name: "E3+E5 (no work kind)", kinds: [.sessionStoreWrite, .ttyActivity], resumes: false),
        WaitingExitCase(name: "E1 alone", kinds: [.treeCPU], resumes: false),
        WaitingExitCase(name: "E1+E6", kinds: [.treeCPU, .powerAssertion], resumes: true),
        WaitingExitCase(name: "with a T2 record", kinds: [.treeCPU, .modelAPISocket], withRecord: true, resumes: false),
        WaitingExitCase(name: "samples taken before the wait", kinds: [.treeCPU, .modelAPISocket], staleSamples: true, resumes: false),
    ])
    func waitingExitOnProcessEvidence(_ c: WaitingExitCase) {
        let d = EngineDriver()
        let p = F.identity(5)
        let agent: AgentID = c.withRecord ? .claude : .gemini
        let key = F.key("g1", agent)
        if c.withRecord {
            d.claude(at: 0, [F.live(p, session: "g1", statusAt: 0)])
        } else {
            d.send(.turnStarted, at: 0, agent: agent, session: "g1", process: p)
        }
        d.send(.needsInput(.permission), at: 10, agent: agent, session: "g1", process: p)
        for t in stride(from: 15.0, through: 115, by: 5) {
            // Stale: a sample taken before the wait began but ingested after it.
            d.processes(at: t, [F.process(p, agent, kinds: c.kinds, at: c.staleSamples ? 9 : t)])
            // Samples from the first evidence window (10…70 s) never count; then 20 s sustain → working at 90 s.
            if t < 90 { #expect(d.state(key)?.isWaiting == true) }
        }
        #expect(d.state(key)?.isWorking == c.resumes)
        #expect(d.state(key)?.isWaiting == !c.resumes)
        #expect(d.effects(.needsInput).count == 1)
        #expect(d.stateVersion == (c.resumes ? 2 : 1))
    }

    // MARK: Activity, sessionStarted, outcomes

    @Test(arguments: [(AgentID.crush, true), (.auggie, true), (.vibe, true), (.claude, false), (.gemini, false)])
    func activityFromIdleStartsATurnOnlyWithoutAStartEvent(agent: AgentID, starts: Bool) {
        let d = EngineDriver()
        let key = F.key("a1", agent)
        if !starts {
            // Agents with a start edge: a finished turn, then a stray activity hook.
            d.send(.turnStarted, at: 0, agent: agent, session: "a1")
            d.send(.turnFinished(.completed), at: 10, agent: agent, session: "a1")
            d.tick(at: 15)
        }
        d.send(.activity, at: 100, agent: agent, session: "a1")
        #expect(d.state(key)?.isWorking == starts)
    }

    @Test func sessionStartedCreatesAnIdleSession() throws {
        let d = EngineDriver()
        let host = HostApp(bundleID: "com.googlecode.iterm2", name: "iTerm2")
        #expect(d.send(.sessionStarted, at: 0, cwd: "/Users/me/proj", host: host).isEmpty)
        let s = try #require(d.session())
        #expect(s.state == .idle(since: F.at(0), outcome: nil))
        #expect(s.cwd == "/Users/me/proj")
        #expect(s.host == host)
        #expect(s.tiers == [.hook])
        #expect(d.stateVersion == 0)
    }

    @Test(arguments: ["settling", "waiting", "idle"])
    func sessionStartedNeverChangesAnExistingState(state: String) {
        let d = EngineDriver()
        d.send(.turnStarted, at: 0)
        switch state {
        case "settling": d.send(.turnFinished(.completed), at: 10)
        case "waiting": d.send(.needsInput(.permission), at: 10)
        default:
            d.send(.turnFinished(.completed), at: 5)
            d.tick(at: 10)
        }
        let before = d.state()
        d.send(.sessionStarted, at: 11, metadata: [MetadataKey.claudeSessionStartSource: "compact"])
        #expect(d.state() == before)
    }

    @Test(arguments: [TurnOutcome.completed, .error, .ambiguous])
    func pushableOutcomesFinishAfterSettle(outcome: TurnOutcome) throws {
        let d = EngineDriver()
        d.send(.turnStarted, at: 0)
        d.send(.turnFinished(outcome), at: 20)
        let effect = try #require(d.tick(at: 25).first)
        #expect(effect.kind == .finished)
        #expect(effect.outcome == outcome)
        #expect(d.state()?.isIdle(outcome: outcome) == true)
    }

    @Test func interruptedOutcomeNeverPushes() {
        let d = EngineDriver()
        d.send(.turnStarted, at: 0)
        d.send(.turnFinished(.interrupted), at: 20)
        #expect(d.tick(at: 25).isEmpty)
        #expect(d.state()?.isIdle(outcome: .interrupted) == true)
        #expect(d.session()?.lastTurnDuration == 25)
        #expect(d.aggregate.lastFinishedAt == nil)
    }

    @Test(arguments: ["working", "waiting", "idle"])
    func rateLimitedFinishesAtOnceFromAnyState(from: String) throws {
        let d = EngineDriver()
        switch from {
        case "working": d.send(.turnStarted, at: 0)
        case "waiting":
            d.send(.turnStarted, at: 0)
            d.send(.needsInput(.unknown), at: 5)
        default: d.send(.sessionStarted, at: 0)
        }
        let effects = d.send(.turnFinished(.rateLimited), at: 10)
        #expect(effects.map(\.kind) == [.finished])
        #expect(try #require(effects.first).outcome == .rateLimited)
        #expect(d.state()?.isIdle(outcome: .rateLimited) == true)
        #expect(d.aggregate.anyWorking == false)
        #expect(d.tick(from: 11, through: 30).isEmpty)
    }

    @Test func finishForAnUnseenTurnStillPushesWithoutDuration() throws {
        let d = EngineDriver()
        d.send(.turnFinished(.completed), at: 0, agent: .agy, session: "t1")
        let effect = try #require(d.tick(at: 5).first)
        #expect(effect.kind == .finished)
        #expect(effect.workedFor == nil)
    }

    // MARK: Settle

    @Test func newPromptInsideSettleIsOneTurnWithANewStateVersion() throws {
        let d = EngineDriver()
        d.send(.turnStarted, at: 0)
        d.send(.turnFinished(.completed), at: 30)
        d.send(.turnStarted, at: 32) // queued prompt
        #expect(d.state() == .working(since: F.at(0)))
        #expect(d.stateVersion == 2)
        d.send(.turnFinished(.completed), at: 50)
        #expect(try #require(d.tick(at: 55).first).workedFor == 55)
        #expect(d.kinds == [.finished])
    }

    @Test func settleUsesUpdatedTimers() {
        let d = EngineDriver()
        var timers = SessionTimers()
        timers.settleSeconds = 8
        d.engine.updateTimers(timers)
        d.send(.turnStarted, at: 0)
        d.send(.turnFinished(.completed), at: 10)
        #expect(d.tick(at: 17).isEmpty)
        #expect(d.tick(at: 18).map(\.kind) == [.finished])
    }

    // MARK: Stall guard

    @Test func stallGuardCoversSettling() {
        var timers = SessionTimers()
        timers.settleSeconds = 30 * 60 // a settle that outlives the stall threshold
        let d = EngineDriver(timers: timers)
        d.send(.turnStarted, at: 0)
        d.send(.turnFinished(.completed), at: 60)
        #expect(d.tick(from: 61, through: 1259, step: 7).isEmpty)
        #expect(d.state()?.isSettling == true)
        #expect(d.tick(at: 1260).map(\.kind) == [.stalled])
        #expect(d.state() == .stalled(since: F.at(1260)))
        #expect(d.aggregate.anyWorking == false)
        #expect(d.tick(from: 1261, through: 2000, step: 10).isEmpty)
    }

    @Test(arguments: ["evidence", "activity", "recordBusy", "turnStarted"])
    func stalledSessionRecoversOnProgress(signal: String) {
        let d = EngineDriver()
        let claude = F.identity(6)
        d.claude(at: 0, [F.live(claude, statusAt: 0)])
        d.send(.turnStarted, at: 0, process: claude)
        d.tick(at: 1200)
        #expect(d.state()?.isStalled == true)
        #expect(d.session()?.tiers.contains(.guardrail) == true)
        let sv = d.stateVersion
        switch signal {
        case "evidence": d.processes(at: 1300, [F.process(claude, .claude, kinds: [.childChurn], at: 1300)])
        case "activity": d.send(.activity, at: 1300, process: claude)
        case "recordBusy": d.claude(at: 1300, [F.live(claude, statusAt: 1300)])
        default: d.send(.turnStarted, at: 1300, process: claude)
        }
        #expect(d.state() == .working(since: F.at(1300)))
        #expect(d.session()?.lastProgressAt == F.at(1300))
        #expect(d.stateVersion == sv + 1)
        // A second stall pushes again (one effect per stall).
        d.tick(at: 2500)
        #expect(d.effects(.stalled).count == 2)
    }

    @Test func powerAssertionAloneIsNotProgress() {
        let d = EngineDriver()
        let claude = F.identity(7)
        d.send(.turnStarted, at: 0, process: claude)
        for t in stride(from: 5.0, through: 1195, by: 5) {
            d.processes(at: t, [F.process(claude, .claude, kinds: [.powerAssertion], at: t)])
        }
        #expect(d.tick(at: 1200).map(\.kind) == [.stalled])
    }

    @Test func progressEvidenceKeepsAWorkingSessionFromStalling() {
        let d = EngineDriver()
        let claude = F.identity(8)
        d.send(.turnStarted, at: 0, process: claude)
        for t in stride(from: 60.0, through: 3600, by: 60) {
            d.processes(at: t, [F.process(claude, .claude, kinds: [.treeCPU], at: t)])
            d.tick(at: t)
        }
        #expect(d.state()?.isWorking == true)
        #expect(d.effects.isEmpty)
    }

    @Test func stallThresholdFollowsUpdatedTimers() {
        let d = EngineDriver()
        var timers = SessionTimers()
        timers.stallMinutes = 10
        d.engine.updateTimers(timers)
        d.send(.turnStarted, at: 0)
        #expect(d.tick(at: 599).isEmpty)
        #expect(d.tick(at: 600).map(\.kind) == [.stalled])
    }

    // MARK: Bound sessions without a start edge (Codex notify-only, agy, Aider, Auggie, Cursor -p)

    @Test func boundSessionWithoutStartEdgeGoesQuietWithoutAFinish() throws {
        let d = EngineDriver()
        let agy = F.identity(9)
        let key = F.key("t1", .agy)
        let work: Set<EvidenceKind> = [.treeCPU, .modelAPISocket]
        // A finished turn creates and binds the session (agy reports Stop only).
        d.send(.turnFinished(.completed), at: 0, agent: .agy, session: "t1", process: agy)
        d.tick(at: 5)
        // Next turn: evidence beyond the window after that finish, sustained 20 s.
        for t in stride(from: 70.0, through: 90, by: 5) { d.processes(at: t, [F.process(agy, .agy, kinds: work, at: t)]) }
        #expect(d.state(key) == .working(since: F.at(70)))
        #expect(d.session(key)?.tiers.contains(.heuristic) == true)
        // No Stop this time (crash, kill): fewer than two kinds for the exit window → idle(nil) + wentQuiet.
        for t in stride(from: 95.0, through: 394, by: 5) { d.processes(at: t, [F.process(agy, .agy, kinds: [.treeCPU], at: t)]) }
        #expect(d.state(key)?.isWorking == true)
        d.processes(at: 395, [F.process(agy, .agy, kinds: [.treeCPU], at: 395)])
        #expect(d.state(key)?.isIdle(outcome: nil) == true)
        let quiet = try #require(d.effects(.wentQuiet).first)
        #expect(quiet.workedFor == 25) // 70 → the first quiet sample at 95
        #expect(d.kinds == [.finished, .wentQuiet])
    }

    @Test func tickAppliesTheHeuristicExitBetweenSamples() {
        let d = EngineDriver()
        let p = F.identity(10)
        let key = SessionKey.fallback(agent: .aider, identity: p)
        for t in stride(from: 0.0, through: 20, by: 5) { d.processes(at: t, [F.process(p, .aider, kinds: [.treeCPU, .childChurn], at: t)]) }
        d.processes(at: 25, [F.process(p, .aider, at: 25)])
        #expect(d.tick(at: 324).isEmpty)
        #expect(d.tick(at: 325).map(\.kind) == [.wentQuiet])
        #expect(d.state(key)?.isIdle(outcome: nil) == true)
    }

    @Test func startEdgeSessionsUseEvidenceOnlyForProgress() {
        let d = EngineDriver()
        let gemini = F.identity(11)
        let key = F.key("g1", .gemini)
        d.send(.turnStarted, at: 0, agent: .gemini, session: "g1", process: gemini)
        d.send(.turnFinished(.completed), at: 10, agent: .gemini, session: "g1", process: gemini)
        d.tick(at: 15)
        // Plenty of evidence later (MCP servers, a dev server): never a heuristic turn for a start-edge agent.
        for t in stride(from: 100.0, through: 200, by: 5) {
            d.processes(at: t, [F.process(gemini, .gemini, kinds: [.treeCPU, .childChurn, .modelAPISocket], at: t)])
        }
        #expect(d.state(key)?.isIdle(outcome: .completed) == true)
        #expect(d.stateVersion == 1)
        #expect(d.engine.sessions.count == 1)
    }

    @Test func oneProcessDrivesOnlyOneHeuristicTurn() {
        let d = EngineDriver()
        let codex = F.identity(12)
        let work: Set<EvidenceKind> = [.treeCPU, .modelAPISocket]
        for t in stride(from: 0.0, through: 20, by: 5) { d.processes(at: t, [F.process(codex, .codex, kinds: work, at: t)]) }
        d.send(.turnFinished(.completed), at: 40, agent: .codex, session: "thread-A", process: codex)
        d.tick(at: 45)
        // A sub-thread of the finished turn reports late: its own (idle-born) session on the same process.
        d.send(.turnFinished(.completed), at: 50, agent: .codex, session: "thread-B", process: codex)
        d.tick(at: 55)
        #expect(d.engine.sessions.count == 2)
        let sv = d.stateVersion
        for t in stride(from: 120.0, through: 140, by: 5) { d.processes(at: t, [F.process(codex, .codex, kinds: work, at: t)]) }
        let working = d.engine.sessions.filter(\.state.isWorking).map(\.key)
        #expect(working == [F.key("thread-B", .codex)]) // the most recently active session of that process
        #expect(d.stateVersion == sv + 1)
    }

    @Test func aSustainRunDoesNotSurviveLosingTheDriverRole() {
        let d = EngineDriver()
        let codex = F.identity(19)
        let a = F.key("thread-A", .codex)
        let work: Set<EvidenceKind> = [.treeCPU, .modelAPISocket]
        func sample(_ t: TimeInterval) { d.processes(at: t, [F.process(codex, .codex, kinds: work, at: t)]) }
        for t in stride(from: 0.0, through: 20, by: 5) { sample(t) }
        d.send(.turnFinished(.completed), at: 40, agent: .codex, session: "thread-A", process: codex)
        d.tick(at: 45)
        d.send(.turnFinished(.completed), at: 50, agent: .codex, session: "thread-B", process: codex)
        d.tick(at: 55)
        d.send(.idleReminder, at: 120, agent: .codex, session: "thread-A", process: codex) // A drives
        sample(125)
        sample(130)
        d.send(.idleReminder, at: 131, agent: .codex, session: "thread-B", process: codex) // B drives
        sample(131)
        d.send(.sessionEnded, at: 132, agent: .codex, session: "thread-B", process: codex) // A drives again
        for t in stride(from: 135.0, through: 150, by: 5) { sample(t) }
        #expect(d.state(a)?.isIdle == true) // the 125 run was dropped when A lost the role
        sample(155)
        #expect(d.state(a) == .working(since: F.at(135)))
        #expect(d.kinds == [.finished, .finished, .ended])
    }

    // MARK: Codex sub-threads

    @Test func subThreadFinishIsActivityOfTheWorkingThread() throws {
        let d = EngineDriver()
        let codex = F.identity(13)
        d.send(.turnStarted, at: 0, agent: .codex, session: "main", process: codex)
        #expect(d.send(.turnFinished(.completed), at: 30, agent: .codex, session: "worker", process: codex).isEmpty)
        #expect(d.engine.sessions.map(\.key) == [F.key("main", .codex)])
        #expect(d.state(F.key("main", .codex))?.isWorking == true)
        #expect(d.session(F.key("main", .codex))?.lastProgressAt == F.at(30))
        #expect(d.tick(from: 31, through: 40).isEmpty)
        // The main thread's own finish still finishes the turn.
        d.send(.turnFinished(.completed), at: 60, agent: .codex, session: "main", process: codex)
        #expect(try #require(d.tick(at: 65).first).workedFor == 65)
    }

    // MARK: Routing and identity

    @Test func fallbackKeyedEventRoutesToTheRealSessionOfItsProcess() {
        let d = EngineDriver()
        let claude = F.identity(14)
        d.send(.turnStarted, at: 0, process: claude)
        d.send(.turnFinished(.completed), at: 10, key: .fallback(agent: .claude, identity: claude), process: claude)
        #expect(d.engine.sessions.map(\.key) == [F.key("s1")])
        #expect(d.state()?.isSettling == true)
    }

    @Test func endedSessionIsRevivedByNewActivityButNotByTheDeadProcess() {
        let d = EngineDriver()
        let old = F.identity(15)
        let resumed = F.identity(16)
        d.send(.turnStarted, at: 0, process: old)
        d.processes(at: 5, [F.process(old, .claude, at: 5)])
        d.processes(at: 10, [])
        d.processes(at: 15, [])
        #expect(d.state() == .ended(at: F.at(15)))
        // A late hook of the dead process is ignored.
        d.send(.activity, at: 16, process: old)
        #expect(d.state()?.isEnded == true)
        // `claude --resume` of the same conversation in a new process revives it.
        d.send(.turnStarted, at: 20, process: resumed)
        #expect(d.state() == .working(since: F.at(20)))
        #expect(d.session()?.agentProcess == resumed)
        #expect(d.kinds == [.ended])
    }

    @Test func sessionEndedForAnUnknownSessionIsIgnoredAndIdleReminderNeverRevives() {
        let d = EngineDriver()
        #expect(d.send(.sessionEnded, at: 0, session: "ghost").isEmpty)
        #expect(d.engine.sessions.isEmpty)
        d.send(.turnStarted, at: 1)
        d.send(.sessionEnded, at: 2)
        d.send(.idleReminder, at: 3)
        #expect(d.state() == .ended(at: F.at(2)))
        #expect(d.kinds == [.ended])
    }

    // MARK: Dismissal

    @Test func dismissEndsTheSessionAndHeuristicsNeverResurrectIt() {
        let d = EngineDriver()
        let p = F.identity(17)
        let key = SessionKey.fallback(agent: .plandex, identity: p)
        let busy: Set<EvidenceKind> = [.treeCPU, .childChurn]
        for t in stride(from: 0.0, through: 20, by: 5) { d.processes(at: t, [F.process(p, .plandex, kinds: busy, at: t)]) }
        #expect(d.state(key)?.isWorking == true)
        let dismissed = d.dismiss(key, at: 30)
        let again = d.dismiss(key, at: 31)
        #expect(dismissed.map(\.kind) == [.ended])
        #expect(again.isEmpty)
        for t in stride(from: 35.0, through: 1000, by: 5) {
            d.processes(at: t, [F.process(p, .plandex, kinds: busy, at: t)])
            d.tick(at: t)
        }
        #expect(d.session(key) == nil) // dropped after retention, never recreated
        #expect(d.kinds == [.ended])
        #expect(d.aggregate.anyWorking == false)
    }

    @Test func dismissedClaudeSessionReturnsOnlyWithNewRecordActivity() {
        let d = EngineDriver()
        let claude = F.identity(18)
        d.claude(at: 0, [F.live(claude, statusAt: 0)])
        d.dismiss(F.key("s1"), at: 10)
        for t in stride(from: 15.0, through: 700, by: 15) {
            d.claude(at: t, [F.live(claude, statusAt: 0)])
            d.tick(at: t)
        }
        #expect(d.session() == nil)
        d.claude(at: 710, [F.live(claude, statusAt: 705)])
        #expect(d.state() == .working(since: F.at(710)))
    }

    // MARK: Bookkeeping

    @Test func eventIDMemoryIsBoundedFIFO() {
        var ids = RecentIDs(capacity: 3)
        let inserted = ["a", "b", "c", "a", "d"].map { ids.insert($0) }
        #expect(inserted == [true, true, true, false, true]) // "d" evicts "a"
        #expect(ids.count == 3)
        #expect(!ids.contains("a"))
        let again = ids.insert("a") // evicts "b"
        #expect(again)
        #expect(!ids.contains("b"))
        #expect(ids.contains("c") && ids.contains("d"))
        #expect(EngineState.eventIDMemory == 4096)
    }

    @Test func sustainWindowSemantics() {
        var w = SustainWindow()
        w.record(meets: true, at: F.at(0))
        w.record(meets: true, at: F.at(10))
        #expect(w.aboveSince == F.at(0))
        #expect(!w.sustained(for: 20, at: F.at(19)))
        #expect(w.sustained(for: 20, at: F.at(20)))
        w.record(meets: false, at: F.at(25))
        #expect(w.aboveSince == nil)
        #expect(w.quiet(for: 300, at: F.at(325)))
        #expect(!w.quiet(for: 300, at: F.at(324)))
        w.reset()
        #expect(w == SustainWindow())
    }

    @Test func sessionsAreSortedByDisplayRankThenRecentActivity() {
        let d = EngineDriver()
        d.send(.sessionStarted, at: 0, session: "idle-old")
        d.send(.sessionStarted, at: 5, session: "idle-new")
        d.send(.turnStarted, at: 1, session: "working")
        d.send(.turnStarted, at: 2, session: "waiting")
        d.send(.needsInput(.permission), at: 3, session: "waiting")
        d.send(.turnStarted, at: 4, session: "settling")
        d.send(.turnFinished(.completed), at: 6, session: "settling")
        d.send(.turnStarted, at: 0, session: "ended")
        d.send(.sessionEnded, at: 7, session: "ended")
        #expect(d.engine.sessions.map(\.key.id) == ["working", "settling", "waiting", "idle-new", "idle-old", "ended"])
    }

    @Test func aggregateCountsSessionsAndKeepsTheLastFinish() {
        let d = EngineDriver(initialStateVersion: 7)
        d.send(.turnStarted, at: 0, session: "a")
        d.send(.turnStarted, at: 0, session: "b")
        d.send(.needsInput(.permission), at: 3, session: "b")
        d.send(.turnStarted, at: 0, session: "c")
        d.send(.needsInput(.question), at: 2, session: "c")
        d.send(.turnStarted, at: 0, session: "d")
        d.send(.turnFinished(.completed), at: 4, session: "d")
        d.tick(at: 9)
        let a = d.aggregate
        #expect(a.anyWorking && a.anyWaiting)
        #expect(a.workingCount == 1)
        #expect(a.waitingCount == 2)
        #expect(a.idleCount == 1)
        #expect(a.liveCount == 4)
        #expect(a.oldestWaitingSince == F.at(2))
        #expect(a.lastFinishedAt == F.at(9))
        #expect(a.stateVersion == 11)
    }

    @Test func untrustedStringsAreCapped() throws {
        let d = EngineDriver()
        let long = String(repeating: "x", count: 5000)
        var metadata: [String: String] = [:]
        for i in 0..<40 { metadata["extra.\(i)"] = long }
        d.send(.turnStarted, at: 0, cwd: "/" + long, title: long, preview: "Done " + long, metadata: metadata)
        let s = try #require(d.session())
        #expect(s.title?.count == EngineState.maxFieldLength)
        #expect(s.cwd?.count == EngineState.maxFieldLength)
        #expect((s.lastMessagePreview?.count ?? 0) <= TextSanitizer.defaultLimit)
        #expect(s.metadata.count <= EngineState.maxMetadataEntries)
        #expect(s.metadata.values.allSatisfy { $0.count <= EngineState.maxFieldLength })
    }
}
