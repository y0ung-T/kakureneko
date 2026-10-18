@testable import KakurenekoSessions
import KakurenekoKit
import Foundation
import Testing

/// Regression tests for the detection review (each failed before its fix).
@Suite(.timeLimit(.minutes(1))) struct DetectionFixTests {
    static let work: Set<EvidenceKind> = [.treeCPU, .modelAPISocket]

    // MARK: Stall guard: only evidence that proves work counts (E1/E2/E3)

    /// R02 §4.1 with what an idle Claude TUI really produces: a tty write (E5) every ~16 min. One E5 blip used to count
    /// as progress, so the stale-busy session never stalled and kept the Mac awake in the bag.
    @Test func staleBusyRecordWithPeriodicTtyWritesStillStalls() {
        let d = EngineDriver()
        let claude = F.identity(980)
        d.claude(at: 0, [F.live(claude, status: "busy", statusAt: -60)])
        var t = 5.0
        while t <= 3 * 3600 {
            let redraw = Int(t) % 960 < 10
            d.processes(at: t, [F.process(claude, .claude, kinds: redraw ? [.powerAssertion, .ttyActivity] : [.powerAssertion], at: t)])
            d.tick(at: t)
            t += 5
        }
        #expect(d.state()?.isStalled == true)
        #expect(!d.aggregate.anyWorking)
        #expect(d.effects(.stalled).count == 1)
        #expect(d.effects(.stalled).first.map { Int($0.at.timeIntervalSince(F.t0).rounded()) } == 20 * 60)
    }

    /// The verifier's variant: a tty write AND a fresh model-API connection (E4) every 25 min. Each blip used to revive
    /// the stalled session for another 20 min (seven "looks stuck" pushes in 3 h).
    @Test func ttyAndSocketBlipsNeverReviveAStalledSession() {
        for period in [960, 1500] {
            let d = EngineDriver()
            let claude = F.identity(981)
            d.claude(at: 0, [F.live(claude, status: "busy", statusAt: -60)])
            var t = 5.0
            var workingSamples = 0
            while t <= 3 * 3600 {
                let blip = Int(t) % period < 10
                let kinds: Set<EvidenceKind> = blip ? [.powerAssertion, .ttyActivity, .modelAPISocket] : [.powerAssertion]
                d.processes(at: t, [F.process(claude, .claude, kinds: kinds, at: t)])
                d.tick(at: t)
                if t > 20 * 60, d.aggregate.anyWorking { workingSamples += 1 }
                t += 5
            }
            #expect(d.effects(.stalled).count == 1, "period \(period)")
            #expect(workingSamples == 0, "period \(period)")
            #expect(d.state()?.isStalled == true, "period \(period)")
        }
    }

    /// Real work still refreshes the guard: a build's tree CPU (E1) or new children (E2) or session-store writes (E3).
    @Test func treeCPUChildChurnAndStoreWritesStillCountAsProgress() {
        for kind in [EvidenceKind.treeCPU, .childChurn, .sessionStoreWrite] {
            let d = EngineDriver()
            let claude = F.identity(982)
            d.claude(at: 0, [F.live(claude, status: "busy", statusAt: -60)])
            var t = 5.0
            while t <= 2 * 3600 {
                let active = Int(t) % 900 < 10 // once every 15 min
                d.processes(at: t, [F.process(claude, .claude, kinds: active ? [.powerAssertion, kind] : [.powerAssertion], at: t)])
                d.tick(at: t)
                t += 5
            }
            #expect(d.state()?.isWorking == true, "\(kind)")
            #expect(d.effects(.stalled).isEmpty, "\(kind)")
        }
    }

    /// And progress evidence of real work revives a stalled session (brief §5.2 "progress returns while stalled").
    @Test func treeCPURevivesAStalledSession() {
        let d = EngineDriver()
        let claude = F.identity(983)
        d.claude(at: 0, [F.live(claude, status: "busy", statusAt: -60)])
        d.processes(at: 5, [F.process(claude, .claude, kinds: [.powerAssertion], at: 5)])
        d.tick(from: 5, through: 20 * 60, step: 5)
        #expect(d.state()?.isStalled == true)
        d.processes(at: 1300, [F.process(claude, .claude, kinds: [.powerAssertion, .ttyActivity, .modelAPISocket], at: 1300)])
        #expect(d.state()?.isStalled == true)
        d.processes(at: 1305, [F.process(claude, .claude, kinds: [.powerAssertion, .treeCPU], at: 1305)])
        #expect(d.state()?.isWorking == true)
    }

    // MARK: IDE hosts: the extension host's tree is not the agent's evidence

    /// VS Code Local (bound to `Code Helper (Plugin)`): a turn whose Stop never comes (a permission prompt; VS Code has
    /// no needs-input event). One minute of extension-host CPU every 15 min used to keep it working forever.
    @Test func ideHostNoiseDoesNotFeedTheStallGuardOfAHookedSession() {
        let d = EngineDriver()
        let host = F.identity(960)
        let key = F.key("vs1", .vscode)
        d.send(.turnStarted, at: 0, agent: .vscode, session: "vs1", process: host)
        var t = 5.0
        while t <= 3 * 3600 {
            let busy = Int(t) % 900 < 60
            d.processes(at: t, [F.process(host, .vscode, kinds: busy ? [.treeCPU, .childChurn, .modelAPISocket] : [], at: t, ideHost: true)])
            d.tick(at: t)
            t += 5
        }
        #expect(d.state(key)?.isStalled == true)
        #expect(!d.aggregate.anyWorking)
        #expect(d.effects(.stalled).count == 1)
    }

    /// The hooks themselves still refresh progress for an IDE-hosted session (tool hooks → activity).
    @Test func hookActivityStillRefreshesAnIDEHostedSession() {
        let d = EngineDriver()
        let host = F.identity(961)
        let key = F.key("vs2", .vscode)
        d.send(.turnStarted, at: 0, agent: .vscode, session: "vs2", process: host)
        for minute in stride(from: 10.0, through: 120, by: 10) {
            d.send(.activity, at: minute * 60, agent: .vscode, session: "vs2", process: host)
            d.processes(at: minute * 60, [F.process(host, .vscode, at: minute * 60, ideHost: true)])
            d.tick(at: minute * 60)
        }
        #expect(d.state(key)?.isWorking == true)
        #expect(d.effects(.stalled).isEmpty)
    }

    /// A waiting session bound to an IDE host is not resumed by extension-host CPU and child churn (no model socket).
    @Test func ideHostNoiseDoesNotEndAWait() {
        let d = EngineDriver()
        let host = F.identity(962)
        let key = F.key("t1", .codex)
        d.send(.turnStarted, at: 0, agent: .codex, session: "t1", process: host)
        d.send(.needsInput(.permission), at: 30, agent: .codex, session: "t1", process: host)
        var t = 35.0
        while t <= 3600 {
            let busy = Int(t) % 600 < 120
            d.processes(at: t, [F.process(host, .codex, kinds: busy ? [.treeCPU, .childChurn] : [], at: t, ideHost: true)])
            d.tick(at: t)
            t += 5
        }
        #expect(d.state(key)?.isWaiting == true)
        #expect(d.effects(.needsInput).count == 1)
    }

    /// Codex `app-server` (an IDE host) driven by heuristic turns (notify-only): its own model traffic still counts,
    /// so a long turn neither stalls nor goes quiet.
    @Test func ideHostHeuristicTurnWithModelTrafficKeepsWorking() {
        let d = EngineDriver()
        let server = F.identity(963)
        let key = F.key("t2", .codex)
        // A notify from an earlier turn binds the thread to the app-server (no start edge: notify-only).
        d.processes(at: 0, [F.process(server, .codex, at: 0, ideHost: true)])
        d.send(.turnFinished(.completed), at: 1, agent: .codex, session: "t2", process: server)
        d.tick(from: 2, through: 70, step: 1)
        var t = 100.0
        while t <= 100 + 45 * 60 {
            d.processes(at: t, [F.process(server, .codex, kinds: Self.work, at: t, ideHost: true)])
            d.tick(at: t)
            t += 5
        }
        #expect(d.state(key)?.isWorking == true)
        #expect(d.effects(.stalled).isEmpty)
    }

    // MARK: npm Codex: wrapper (T3 outermost) + native child (hook binding) are one session

    @Test func codexNpmWrapperHeuristicSessionMergesIntoTheNotifySession() {
        let d = EngineDriver()
        let wrapper = F.identity(800)
        let native = F.identity(801)
        func tree(_ t: TimeInterval, _ kinds: Set<EvidenceKind>) -> [AgentProcess] {
            [F.process(wrapper, .codex, kinds: kinds, at: t, descendants: [native]),
             F.process(native, .codex, kinds: kinds, at: t, ancestors: [wrapper])]
        }
        for t in stride(from: 0.0, through: 30, by: 5) { d.processes(at: t, tree(t, Self.work)) }
        #expect(d.aggregate.anyWorking)
        d.send(.turnFinished(.completed), at: 40, agent: .codex, session: "thread-1", process: native)
        d.tick(at: 45)
        for t in stride(from: 50.0, through: 700, by: 5) {
            d.processes(at: t, tree(t, []))
            d.tick(at: t)
        }
        #expect(d.engine.sessions.map(\.key) == [F.key("thread-1", .codex)])
        #expect(d.kinds == [.finished])
        // The finish measured the whole turn the wrapper's heuristic session saw (it started at the first sample).
        #expect(d.effects(.finished).first?.workedFor.map { Int($0.rounded()) } == 45)
    }

    /// Three notify-only turns: one finish per turn, no duplicate "went quiet", no extra working minutes.
    @Test func codexNpmWrapperThreeTurnsFinishOncePerTurn() {
        let d = EngineDriver()
        let wrapper = F.identity(810)
        let native = F.identity(811)
        func tree(_ t: TimeInterval, _ kinds: Set<EvidenceKind>) -> [AgentProcess] {
            [F.process(wrapper, .codex, kinds: kinds, at: t, descendants: [native]),
             F.process(native, .codex, kinds: kinds, at: t, ancestors: [wrapper])]
        }
        for turn in 0..<3 {
            let start = Double(turn) * 1000
            var t = start
            while t <= start + 60 { d.processes(at: t, tree(t, Self.work)); d.tick(at: t); t += 5 }
            d.send(.turnFinished(.completed), at: start + 62, agent: .codex, session: "thread-1", process: native)
            t = start + 65
            while t < start + 1000 {
                d.processes(at: t, tree(t, []))
                d.tick(at: t)
                if t > start + 70 { #expect(!d.aggregate.anyWorking, "turn \(turn) at \(t)") }
                t += 5
            }
        }
        #expect(d.kinds == [.finished, .finished, .finished])
        #expect(d.engine.sessions.count == 1)
    }

    // MARK: Launch-drain replay of old inbox files

    @Test func eventsFromDaysAgoAreHistoryNotCurrentState() {
        let engine = SessionEngine()
        let now = F.at(10 * 24 * 3600)
        let old = now.addingTimeInterval(-3 * 24 * 3600)
        func event(_ id: String, _ e: NormalizedEvent, at: Date, session: String = "old") -> AgentEvent {
            AgentEvent(id: id, agent: .gemini, event: e, rawEventName: e.typeName, sessionKey: F.key(session, .gemini),
                       agentProcess: F.identity(990), occurredAt: at, receivedAt: now)
        }
        var effects = engine.ingest(event("a", .turnStarted, at: old), now: now)
        effects += engine.ingest(event("b", .turnFinished(.completed), at: old.addingTimeInterval(120)), now: now)
        // A dead agent's last word was a turnStarted: it must not count as working.
        effects += engine.ingest(event("c", .turnStarted, at: old, session: "dead"), now: now)
        effects += engine.tick(now: now.addingTimeInterval(6))
        #expect(effects.isEmpty)
        #expect(engine.sessions.isEmpty)
        #expect(!engine.aggregate.anyWorking)
    }

    /// A replayed file may refresh the descriptive fields of a session that exists, never its state.
    @Test func aReplayedEventOnlyRefreshesFieldsOfAnExistingSession() {
        let engine = SessionEngine()
        let now = F.at(1000)
        let live = AgentEvent(id: "live", agent: .gemini, event: .turnStarted, rawEventName: "BeforeAgent",
                              sessionKey: F.key("g", .gemini), agentProcess: F.identity(991), occurredAt: now, receivedAt: now)
        _ = engine.ingest(live, now: now)
        let replay = AgentEvent(id: "old", agent: .gemini, event: .turnFinished(.completed), rawEventName: "AfterAgent",
                                sessionKey: F.key("g", .gemini), agentProcess: F.identity(991), title: "Old title",
                                occurredAt: now.addingTimeInterval(-3600), receivedAt: now)
        let effects = engine.ingest(replay, now: now) + engine.tick(now: now.addingTimeInterval(10))
        #expect(effects.isEmpty)
        #expect(engine.session(for: F.key("g", .gemini))?.state.isWorking == true)
        #expect(engine.session(for: F.key("g", .gemini))?.title == "Old title")
    }

    /// Files that waited a few minutes (Kakureneko restarted) are still current.
    @Test func recentlyQueuedEventsStillApply() {
        let engine = SessionEngine()
        let now = F.at(1000)
        let event = AgentEvent(id: "q", agent: .gemini, event: .turnStarted, rawEventName: "BeforeAgent",
                               sessionKey: F.key("g", .gemini), agentProcess: F.identity(992),
                               occurredAt: now.addingTimeInterval(-5 * 60), receivedAt: now)
        _ = engine.ingest(event, now: now)
        #expect(engine.aggregate.anyWorking)
    }

    // MARK: Liveness of a bound process no snapshot ever contained

    @Test func aSessionOfAProcessThatNoSnapshotContainsEndsWhenTheProcessIsDead() {
        let lookup = StaticProcessLookup()
        let d = EngineDriver(engine: SessionEngine(processes: lookup))
        let dead = F.identity(950)
        let other = F.identity(951)
        d.send(.turnStarted, at: 0, agent: .gemini, session: "g1", process: dead)
        #expect(d.aggregate.anyWorking)
        d.processes(at: 5, [F.process(other, .claude, at: 5)])
        #expect(d.state(F.key("g1", .gemini))?.isWorking == true) // one miss is not enough
        d.processes(at: 10, [F.process(other, .claude, at: 10)])
        #expect(d.state(F.key("g1", .gemini))?.isEnded == true)
        #expect(d.kinds == [.ended])
        #expect(!d.aggregate.anyWorking)
        // Dropped after the retention like any ended session.
        d.tick(from: 15, through: 15 + SessionTimers().endedRetention + 5, step: 5)
        #expect(d.session(F.key("g1", .gemini)) == nil)
    }

    /// Alive but never classified by the scanner: kept (the lookup proves it lives).
    @Test func anUnclassifiedLiveProcessKeepsItsSession() {
        let alive = F.identity(952)
        let d = EngineDriver(engine: SessionEngine(processes: StaticProcessLookup([alive])))
        d.send(.turnStarted, at: 0, agent: .gemini, session: "g2", process: alive)
        for t in stride(from: 5.0, through: 120, by: 5) { d.processes(at: t, []) }
        #expect(d.state(F.key("g2", .gemini))?.isWorking == true)
        // A different process now owns the pid (start time differs): dead.
        let lookup = StaticProcessLookup([F.identity(952, start: 1_791_900_000)])
        let d2 = EngineDriver(engine: SessionEngine(processes: lookup))
        d2.send(.turnStarted, at: 0, agent: .gemini, session: "g2", process: alive)
        d2.processes(at: 5, [])
        d2.processes(at: 10, [])
        #expect(d2.state(F.key("g2", .gemini))?.isEnded == true)
    }

    /// A short-lived agent (`claude -p`, `codex exec`) that exits right after its finish still gets its finish: the
    /// settle window (5 s) expires before the second miss.
    @Test func aQuickAgentThatExitsAfterItsFinishStillFinishes() {
        let d = EngineDriver(engine: SessionEngine(processes: StaticProcessLookup()))
        let gone = F.identity(953)
        d.send(.turnStarted, at: 0, agent: .gemini, session: "g3", process: gone)
        d.send(.turnFinished(.completed), at: 2, agent: .gemini, session: "g3", process: gone)
        d.processes(at: 3, [])
        d.tick(from: 3, through: 8, step: 1)
        d.processes(at: 8, [])
        #expect(d.kinds == [.finished, .ended])
    }

    // MARK: T2: a poll that raced a record write

    /// The CLI read the records, the record went busy (new turn), then the CLI returned: the stale `idle` entry wins the
    /// merge. It used to count as a busy → idle edge and finish the working turn as interrupted.
    @Test func aPollThatRacedARecordWriteDoesNotEndAWorkingTurn() {
        let d = EngineDriver()
        let claude = F.identity(900)
        d.claude(at: -10, [F.live(claude, status: "idle", statusAt: -100)], agents: nil)
        d.send(.turnStarted, at: 0, process: claude)
        let entry = ClaudeAgentsEntry(pid: claude.pid, cwd: "/Users/me/proj", kind: "interactive", sessionId: "s1", status: "idle")
        d.claude(at: 0.2, [F.live(claude, status: "busy", statusAt: 0)], agents: [entry], polledAt: 0.2)
        #expect(d.state()?.isWorking == true)
        #expect(d.aggregate.anyWorking)
        let sv = d.stateVersion
        // The next poll agrees with the record: still the same turn.
        let busy = ClaudeAgentsEntry(pid: claude.pid, cwd: "/Users/me/proj", kind: "interactive", sessionId: "s1", status: "busy")
        d.claude(at: 15, [F.live(claude, status: "busy", statusAt: 0)], agents: [busy], polledAt: 15)
        #expect(d.state()?.isWorking == true)
        #expect(d.stateVersion == sv)
        #expect(d.kinds.isEmpty)
    }

    /// The mirror: Stop arrives, then a snapshot whose record says idle (written while the CLI ran) but whose stale
    /// entry says busy. It used to count as a busy edge while settling (continuation), wiping the Stop: the finish was
    /// then lost as interrupted.
    @Test func aPollThatRacedTheFinishDoesNotLoseIt() {
        let d = EngineDriver()
        let claude = F.identity(901)
        let busyEntry = ClaudeAgentsEntry(pid: claude.pid, cwd: "/Users/me/proj", kind: "interactive", sessionId: "s1", status: "busy")
        let idleEntry = ClaudeAgentsEntry(pid: claude.pid, cwd: "/Users/me/proj", kind: "interactive", sessionId: "s1", status: "idle")
        d.claude(at: -10, [F.live(claude, status: "idle", statusAt: -100)], agents: nil)
        d.send(.turnStarted, at: 0, process: claude)
        d.claude(at: 0.5, [F.live(claude, status: "busy", statusAt: 0.1)], agents: [busyEntry], polledAt: 0.3)
        d.send(.turnFinished(.completed), at: 30, process: claude)
        d.claude(at: 30.3, [F.live(claude, status: "idle", statusAt: 30.0)], agents: [busyEntry], polledAt: 30.2)
        d.tick(from: 31, through: 44, step: 1)
        d.claude(at: 45.2, [F.live(claude, status: "idle", statusAt: 30.0)], agents: [idleEntry], polledAt: 45.2)
        d.tick(from: 46, through: 80, step: 1)
        #expect(d.state()?.isIdle(outcome: .completed) == true)
        #expect(d.kinds == [.finished])
    }

    /// The poll is stamped when the CLI STARTS: a record rewritten while it ran is fresher than the poll.
    @Test func agentsPolledAtIsStampedBeforeTheCLIRuns() async throws {
        let f = try WatcherFixture()
        _ = try f.installCLICandidate()
        let clock = f.clock
        f.runner.setHandler { request in
            clock.advance(by: .seconds(2)) // the CLI takes two seconds
            return request.arguments == ClaudeCLI.agentsArguments
                ? SubprocessResult(exitCode: 0, stdout: Data(R02.agentsJSON.utf8)) : SubprocessResult(exitCode: 1)
        }
        let core = f.makeCore()
        let start = clock.now()
        _ = await core.pollAndRefresh()
        let snapshot = await core.snapshot()
        #expect(snapshot.agents?.isEmpty == false)
        #expect(snapshot.agentsPolledAt == start)
        #expect(clock.now() == start.addingTimeInterval(2))
    }
}
