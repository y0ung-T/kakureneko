@testable import KakurenekoSessions
import KakurenekoKit
import Foundation
import Testing

/// T3: liveness from process snapshots, binding T1 sessions by cwd (+ fallback merge), and the rules for creating
/// heuristic sessions (outermost, unbound, non-IDE-host, non-ignored, non-infrastructure).
@Suite("SessionEngine T3 processes", .timeLimit(.minutes(1)))
struct EngineProcessTests {
    static let busy: Set<EvidenceKind> = [.treeCPU, .childChurn, .modelAPISocket]

    // MARK: Liveness

    @Test func processAbsentFromTwoConsecutiveSnapshotsEndsTheSession() throws {
        let d = EngineDriver()
        let codex = F.identity(100)
        let key = F.key("t1", .codex)
        d.send(.turnStarted, at: 0, agent: .codex, session: "t1", process: codex)
        d.processes(at: 5, [F.process(codex, .codex, at: 5)])
        d.processes(at: 10, [])
        d.processes(at: 15, [F.process(codex, .codex, at: 15)]) // a scan glitch: the count resets
        d.processes(at: 20, [])
        #expect(d.state(key)?.isWorking == true)
        let effects = d.processes(at: 25, [])
        #expect(effects.map(\.kind) == [.ended])
        #expect(d.state(key) == .ended(at: F.at(25)))
        #expect(try #require(effects.first).session.tiers.contains(.guardrail))
        #expect(d.aggregate.liveCount == 0)
    }

    @Test func sessionNeverSeenByT3IsNotEndedByT3() {
        let d = EngineDriver()
        let unmatched = F.identity(101) // e.g. a wrapper the scanner does not classify
        d.send(.turnStarted, at: 0, agent: .cursor, session: "c1", process: unmatched)
        for t in stride(from: 5.0, through: 60, by: 5) { d.processes(at: t, []) }
        #expect(d.state(F.key("c1", .cursor))?.isWorking == true)
        #expect(d.effects.isEmpty)
    }

    // MARK: Binding by cwd

    @Test(arguments: ["/Users/me/proj", "/Users/me/proj/"])
    func t1SessionWithoutProcessBindsToTheUniqueSameCwdProcess(eventCwd: String) {
        let d = EngineDriver()
        let codex = F.identity(102)
        let other = F.identity(103)
        let daemon = F.identity(104)
        d.processes(at: 0, [
            F.process(codex, .codex, at: 0, cwd: "/Users/me/proj"),
            F.process(other, .gemini, at: 0, cwd: "/Users/me/proj"), // other agent
            F.process(daemon, .codex, at: 0, cwd: "/Users/me/proj", infrastructure: true),
        ])
        d.send(.turnStarted, at: 1, agent: .codex, session: "t1", cwd: eventCwd)
        #expect(d.session(F.key("t1", .codex))?.agentProcess == codex)
    }

    @Test func ambiguousCwdLeavesTheSessionUnboundUntilItIsUnique() {
        let d = EngineDriver()
        let a = F.identity(105)
        let b = F.identity(106)
        let key = F.key("t1", .codex)
        d.processes(at: 0, [F.process(a, .codex, at: 0), F.process(b, .codex, at: 0)])
        d.send(.turnStarted, at: 1, agent: .codex, session: "t1", cwd: "/Users/me/proj")
        #expect(d.session(key)?.agentProcess == nil)
        // One of them exits: the next snapshot binds the session to the survivor.
        d.processes(at: 5, [F.process(b, .codex, at: 5)])
        #expect(d.session(key)?.agentProcess == b)
    }

    @Test func processClaimedByAnotherRealSessionIsNotACwdCandidate() {
        let d = EngineDriver()
        let codex = F.identity(107)
        d.send(.turnStarted, at: 0, agent: .codex, session: "t1", process: codex)
        d.processes(at: 1, [F.process(codex, .codex, at: 1)])
        d.send(.turnStarted, at: 2, agent: .codex, session: "t2", cwd: "/Users/me/proj")
        #expect(d.session(F.key("t2", .codex))?.agentProcess == nil)
    }

    @Test func bindingByCwdMergesTheHeuristicSessionOfThatProcess() throws {
        let d = EngineDriver()
        let aider = F.identity(108)
        for t in stride(from: 0.0, through: 20, by: 5) { d.processes(at: t, [F.process(aider, .aider, kinds: Self.busy, at: t)]) }
        #expect(d.session(.fallback(agent: .aider, identity: aider))?.state.isWorking == true)
        d.send(.needsInput(.question), at: 25, agent: .aider, session: "chat-1", cwd: "/Users/me/proj")
        #expect(d.engine.sessions.map(\.key) == [F.key("chat-1", .aider)])
        let s = try #require(d.session(F.key("chat-1", .aider)))
        #expect(s.agentProcess == aider)
        #expect(s.state.isWaiting)
        #expect(s.turnStartedAt == F.at(0))
        #expect(d.kinds == [.needsInput])
    }

    // MARK: Heuristic sessions

    struct CandidateCase: Sendable, CustomTestStringConvertible {
        var name: String
        var processes: @Sendable (TimeInterval) -> [AgentProcess]
        var bindFirst: (agent: AgentID, process: ProcessIdentity)?
        var ignored: [ProcessIdentity] = []
        var expected: [SessionKey]
        var testDescription: String { name }
    }

    @Test(arguments: [
        CandidateCase(name: "plain hook-less agent", processes: C.one(.goose),
                      expected: [.fallback(agent: .goose, identity: C.outer)]),
        CandidateCase(name: "infrastructure", processes: C.one(.claude, infrastructure: true), expected: []),
        CandidateCase(name: "IDE host without E4", processes: C.one(.vscode, kinds: [.treeCPU, .childChurn, .ttyActivity], ideHost: true),
                      expected: []),
        CandidateCase(name: "IDE host with E4", processes: C.one(.vscode, ideHost: true),
                      expected: [.fallback(agent: .vscode, identity: C.outer)]),
        CandidateCase(name: "ignored (parked) record", processes: C.one(.claude), ignored: [C.outer], expected: []),
        CandidateCase(name: "Codex npm wrapper + native child: the outermost owns the tree", processes: C.pair(.codex),
                      expected: [.fallback(agent: .codex, identity: C.outer)]),
        CandidateCase(name: "nested claude -p under a bound claude", processes: C.pair(.claude), bindFirst: (.claude, C.outer),
                      expected: [F.key("bound", .claude)]),
        CandidateCase(name: "hook bound the inner process; the wrapper is not a second session", processes: C.pair(.codex),
                      bindFirst: (.codex, C.inner), expected: [F.key("bound", .codex)]),
        CandidateCase(name: "a different agent under a bound claude gets its own session", processes: C.pair(.claude, inner: .goose),
                      bindFirst: (.claude, C.outer), expected: [F.key("bound", .claude), .fallback(agent: .goose, identity: C.inner)]),
        CandidateCase(name: "below two kinds", processes: C.one(.goose, kinds: [.treeCPU]), expected: []),
    ])
    func heuristicSessionCandidates(_ c: CandidateCase) {
        let d = EngineDriver()
        if !c.ignored.isEmpty { d.claude(at: 0, [], ignored: c.ignored) }
        if let bind = c.bindFirst { d.send(.sessionStarted, at: 0, agent: bind.agent, session: "bound", process: bind.process) }
        for t in stride(from: 0.0, through: 30, by: 5) { d.processes(at: t, c.processes(t)) }
        #expect(d.engine.sessions.map(\.key).sorted() == c.expected.sorted())
    }

    @Test func candidateSustainRestartsWhenEvidenceDrops() {
        let d = EngineDriver()
        let p = F.identity(113)
        let key = SessionKey.fallback(agent: .kimi, identity: p)
        for t in stride(from: 0.0, through: 15, by: 5) { d.processes(at: t, [F.process(p, .kimi, kinds: Self.busy, at: t)]) }
        d.processes(at: 18, [F.process(p, .kimi, kinds: [.treeCPU], at: 18)])
        for t in stride(from: 20.0, through: 35, by: 5) { d.processes(at: t, [F.process(p, .kimi, kinds: Self.busy, at: t)]) }
        #expect(d.session(key) == nil)
        d.processes(at: 40, [F.process(p, .kimi, kinds: Self.busy, at: 40)])
        #expect(d.session(key)?.state == .working(since: F.at(20)))
        #expect(d.engine.withState { $0.heuristicCandidates.isEmpty })
    }

    @Test func heuristicSessionTakesCwdAndHostFromItsProcessAndEndsWithIt() throws {
        let d = EngineDriver()
        let p = F.identity(114)
        let host = HostApp(bundleID: "com.mitchellh.ghostty", name: "Ghostty")
        let key = SessionKey.fallback(agent: .goose, identity: p)
        for t in stride(from: 0.0, through: 20, by: 5) {
            d.processes(at: t, [F.process(p, .goose, kinds: Self.busy, at: t, cwd: "/Users/me/site", host: host)])
        }
        let s = try #require(d.session(key))
        #expect(s.cwd == "/Users/me/site")
        #expect(s.host == host)
        #expect(s.isHeuristicOnly)
        #expect(s.projectName == "site")
        d.processes(at: 25, [])
        #expect(d.processes(at: 30, []).map(\.kind) == [.ended])
        d.tick(at: 629)
        #expect(d.session(key) != nil)
        d.tick(at: 630)
        #expect(d.session(key) == nil)
    }

    @Test func stalledHeuristicSessionRecoversOnProgress() {
        let d = EngineDriver()
        let p = F.identity(115)
        let key = SessionKey.fallback(agent: .goose, identity: p)
        for t in stride(from: 0.0, through: 20, by: 5) { d.processes(at: t, [F.process(p, .goose, kinds: Self.busy, at: t)]) }
        // From here on only E6 (an assertion is not progress): stalled after the (shortened) stall threshold, well
        // before the (lengthened) heuristic exit window.
        var timers = SessionTimers()
        timers.stallMinutes = 10
        timers.heuristicExitMinutes = 30
        d.engine.updateTimers(timers)
        for t in stride(from: 25.0, through: 615, by: 5) { d.processes(at: t, [F.process(p, .goose, kinds: [.powerAssertion], at: t)]) }
        d.tick(at: 620)
        #expect(d.state(key)?.isStalled == true)
        d.processes(at: 625, [F.process(p, .goose, kinds: [.treeCPU], at: 625)])
        #expect(d.state(key)?.isWorking == true)
        #expect(d.kinds == [.stalled])
    }
}

/// Process trees for the candidate table (`@Test(arguments:)` is evaluated outside any suite instance).
private enum C {
    static let outer = F.identity(110)
    static let inner = F.identity(111)

    /// One busy process.
    static func one(_ agent: AgentID, kinds: Set<EvidenceKind> = EngineProcessTests.busy, infrastructure: Bool = false,
                    ideHost: Bool = false) -> @Sendable (TimeInterval) -> [AgentProcess] {
        { t in [F.process(outer, agent, kinds: kinds, at: t, infrastructure: infrastructure, ideHost: ideHost)] }
    }

    /// A busy outer process of `agent` with a busy child of `innerAgent` (default: the same agent).
    static func pair(_ agent: AgentID, inner innerAgent: AgentID? = nil) -> @Sendable (TimeInterval) -> [AgentProcess] {
        { t in
            [F.process(outer, agent, kinds: EngineProcessTests.busy, at: t, descendants: [inner]),
             F.process(inner, innerAgent ?? agent, kinds: EngineProcessTests.busy, at: t, ancestors: [outer])]
        }
    }
}
