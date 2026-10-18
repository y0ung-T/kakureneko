@testable import KakurenekoEvents
import KakurenekoKit
import Foundation
import Testing

/// opencode / Kilo plugin events (brief §3.3 row 7, snippet G; ARCHITECTURE §8, §9.1 "opencode roll-up", §11.14):
/// sessions are keyed by the opencode PROCESS, which is busy while ANY of its sessions (root or subagent child) is.
@Suite("opencode roll-up", .timeLimit(.minutes(1)))
struct OpenCodeTests {
    static let process = Ancestor.opencode(500)
    static var processKey: SessionKey { SessionKey.fallback(agent: .opencode, identity: process.identity) }

    /// Snippet G: `{type, properties, directory, pid}`; the plugin spawns the hook directly from opencode.
    static func payload(_ type: String, _ properties: String, pid: Int32 = 500, envelope: String = "properties") -> String {
        #"{"type":"\#(type)","\#(envelope)":\#(properties),"directory":"/Users/x/oc-project","pid":\#(pid)}"#
    }

    static func status(_ session: String, _ status: String) -> String {
        payload("session.status", #"{"sessionID":"\#(session)","status":{"type":"\#(status)"}}"#)
    }

    /// Acceptance 10: two sessions of one process busy → idle(child) → idle(root) → exactly one turnStarted and one
    /// turnFinished on the process key.
    @Test func twoBusySessionsOfOneProcessRollUpToOneTurn() throws {
        var harness = PipelineHarness()
        let ancestry = [Self.process, Ancestor.zsh(400)]
        var accepted: [AgentEvent] = []
        func send(_ event: String, _ payload: String, at offset: TimeInterval) {
            if let event = harness.send("opencode", event, payload, ancestry: ancestry, at: offset).event { accepted.append(event) }
        }
        send("session.created", Self.payload("session.created", #"{"info":{"id":"root","title":"Fix tests"}}"#), at: 0)
        send("session.status", Self.status("root", "busy"), at: 1)
        send("session.created", Self.payload("session.created", #"{"info":{"id":"child","parentID":"root"}}"#), at: 2)
        send("session.status", Self.status("child", "busy"), at: 3)
        send("session.status", Self.status("child", "idle"), at: 10)
        send("session.idle", Self.payload("session.idle", #"{"sessionID":"child"}"#), at: 10.5)
        send("session.status", Self.status("root", "idle"), at: 20)

        #expect(accepted.map(\.event) == [.sessionStarted, .turnStarted, .turnFinished(.completed)])
        for event in accepted {
            #expect(event.agent == .opencode)
            #expect(event.sessionKey == Self.processKey)
            #expect(event.agentProcess == Self.process.identity)
            #expect(event.metadata[MetadataKey.opencodeSessionID] == "root")
            #expect(event.cwd == "/Users/x/oc-project", "payload directory beats the hook's cwd")
        }
        #expect(accepted.allSatisfy { $0.metadata[MetadataKey.opencodeChildSession] == nil })
    }

    @Test func childNeedsInputIsReportedOnTheProcessKey() throws {
        var harness = PipelineHarness()
        let ancestry = [Self.process]
        _ = harness.send("opencode", "session.created", Self.payload("session.created", #"{"info":{"id":"child","parentID":"root"}}"#), ancestry: ancestry)
        _ = try harness.accept("opencode", "session.status", Self.status("root", "busy"), ancestry: ancestry, at: 1)
        let asked = try harness.accept("opencode", "permission.asked",
                                       Self.payload("permission.asked", #"{"id":"p1","sessionID":"child","permission":"bash","title":"Run npm test","patterns":[]}"#),
                                       ancestry: ancestry, at: 2)
        #expect(asked.event == .needsInput(.permission))
        #expect(asked.sessionKey == Self.processKey)
        #expect(asked.waitingFor == "Run npm test")
        #expect(asked.metadata[MetadataKey.opencodeChildSession] == "child")
        #expect(asked.metadata[MetadataKey.opencodeSessionID] == "root")

        let replied = try harness.accept("opencode", "permission.replied",
                                         Self.payload("permission.replied", #"{"sessionID":"child","reply":"once"}"#), ancestry: ancestry, at: 3)
        #expect(replied.event == .activity, "an answered prompt means the agent resumes (waiting exit)")

        let question = try harness.accept("opencode", "question.asked",
                                          Self.payload("question.asked", #"{"id":"q","sessionID":"root","questions":[{"question":"Which DB?"}]}"#),
                                          ancestry: ancestry, at: 4)
        #expect(question.event == .needsInput(.question))
        #expect(question.waitingFor == "Which DB?")

        // v2 envelope (`data`) and the form events (> 2 s later: the same needsInput kind would be a duplicate).
        let form = try harness.accept("opencode", "form.created",
                                      Self.payload("form.created", #"{"form":{"sessionID":"root","title":"Pick a branch"}}"#, envelope: "data"),
                                      ancestry: ancestry, at: 8)
        #expect(form.event == .needsInput(.question))
        #expect(form.waitingFor == "Pick a branch")
    }

    @Test func sessionErrorEndsTheTurnWithError() throws {
        var harness = PipelineHarness()
        let ancestry = [Self.process]
        _ = try harness.accept("opencode", "session.status", Self.status("root", "retry"), ancestry: ancestry, at: 0)
        _ = harness.send("opencode", "session.status", Self.status("child", "busy"), ancestry: ancestry, at: 1)
        #expect(harness.send("opencode", "session.error", Self.payload("session.error", #"{"sessionID":"child","error":{"name":"APIError"}}"#),
                             ancestry: ancestry, at: 2) == .dropped(.noStateChange), "root is still busy")
        let failed = try harness.accept("opencode", "session.error", Self.payload("session.error", #"{"sessionID":"root"}"#),
                                        ancestry: ancestry, at: 3)
        #expect(failed.event == .turnFinished(.error))
        // An error without a session id stops every busy session.
        _ = try harness.accept("opencode", "session.status", Self.status("a", "busy"), ancestry: ancestry, at: 10)
        _ = harness.send("opencode", "session.status", Self.status("b", "busy"), ancestry: ancestry, at: 11)
        let global = try harness.accept("opencode", "session.error", Self.payload("session.error", #"{}"#), ancestry: ancestry, at: 12)
        #expect(global.event == .turnFinished(.error))
    }

    @Test func deletingTheLastBusySessionFinishesTheTurn() throws {
        var harness = PipelineHarness()
        let ancestry = [Self.process]
        _ = try harness.accept("opencode", "session.status", Self.status("root", "busy"), ancestry: ancestry, at: 0)
        let deleted = try harness.accept("opencode", "session.deleted", Self.payload("session.deleted", #"{"info":{"id":"root"}}"#),
                                         ancestry: ancestry, at: 1)
        #expect(deleted.event == .turnFinished(.completed))
        #expect(harness.send("opencode", "session.status", Self.status("other", "idle"), ancestry: ancestry, at: 2) == .dropped(.noStateChange),
                "idle while nothing is busy carries no state change")
    }

    @Test func eachProcessIsItsOwnSession() throws {
        var harness = PipelineHarness()
        let other = Ancestor.opencode(600)
        let a = try harness.accept("opencode", "session.status", Self.status("s", "busy"), ancestry: [Self.process], at: 0)
        let b = try harness.accept("opencode", "session.status", Self.payload("session.status", #"{"sessionID":"s","status":{"type":"busy"}}"#, pid: 600),
                                   ancestry: [other], at: 0.1)
        #expect(a.sessionKey != b.sessionKey)
        #expect(b.sessionKey == SessionKey.fallback(agent: .opencode, identity: other.identity))
        let finishedA = try harness.accept("opencode", "session.status", Self.status("s", "idle"), ancestry: [Self.process], at: 1)
        #expect(finishedA.event == .turnFinished(.completed))
        #expect(finishedA.sessionKey == a.sessionKey)
    }

    @Test func payloadPidAnchorsTheProcessEvenBehindAWrapper() throws {
        var harness = PipelineHarness()
        // npm install: a node wrapper above the native opencode binary; the plugin runs in the binary (pid 500).
        let nodeWrapper = Ancestor.make(450, argv0: "node", path: "/opt/homebrew/bin/node", argv1: "/opt/homebrew/bin/opencode", exe: "node")
        let event = try harness.accept("opencode", "session.status", Self.status("s", "busy"),
                                       ancestry: [Ancestor.make(500, argv0: "/opt/homebrew/lib/node_modules/opencode-ai/bin/.opencode", exe: ".opencode"), nodeWrapper])
        #expect(event.sessionKey.id == Ancestor.make(500, argv0: "x").identity.fallbackSessionID)
    }

    @Test func withoutAProcessTheSessionIDIsTheKey() throws {
        var harness = PipelineHarness()
        let event = try harness.accept("opencode", "session.status", Self.payload("session.status", #"{"sessionID":"ses_1","status":{"type":"busy"}}"#, pid: 9_999))
        #expect(event.sessionKey == SessionKey(agent: .opencode, id: "ses_1"))
        #expect(event.agentProcess == nil)
    }

    @Test func kiloUsesTheSameRollUp() throws {
        var harness = PipelineHarness()
        let kilo = Ancestor.make(700, argv0: "kilo", path: "/Users/x/.kilo/bin/kilo", exe: "kilo")
        let started = try harness.accept("kilo", "session.status", Self.payload("session.status", #"{"sessionID":"k","status":{"type":"busy"}}"#, pid: 700),
                                         ancestry: [kilo])
        #expect(started.agent == .kilo)
        #expect(started.event == .turnStarted)
        #expect(started.sessionKey == SessionKey.fallback(agent: .kilo, identity: kilo.identity))
    }

    @Test func unknownOrIncompleteEventsAreDropped() {
        var harness = PipelineHarness()
        #expect(harness.send("opencode", "message.updated", Self.payload("message.updated", #"{}"#), ancestry: [Self.process]).event == nil)
        #expect(harness.send("opencode", "session.status", Self.payload("session.status", #"{"status":{"type":"busy"}}"#), ancestry: [Self.process]).event == nil,
                "no session id")
        #expect(harness.send("opencode", "session.status", Self.status("s", "compacting"), ancestry: [Self.process]).event == nil)
    }

    // MARK: Roll-up state machine

    @Test func rollupTransitions() {
        var rollup = OpenCodeRollup()
        let key = SessionKey(agent: .opencode, id: "pid:1:2.3")
        #expect(rollup.apply(.created(session: "r", parent: nil), key: key).event == .sessionStarted)
        #expect(rollup.apply(.created(session: "c", parent: "r"), key: key).event == nil)
        #expect(rollup.apply(.busy(session: "r"), key: key).event == .turnStarted)
        #expect(rollup.isBusy(key))
        let childBusy = rollup.apply(.busy(session: "c"), key: key)
        #expect(childBusy.event == nil)
        #expect(childBusy.rootSession == "r")
        #expect(childBusy.childSession == "c")
        #expect(rollup.apply(.busy(session: "r"), key: key).event == nil, "already busy")
        #expect(rollup.apply(.idle(session: "r"), key: key).event == nil, "the child is still busy")
        #expect(rollup.apply(.idle(session: "c"), key: key).event == .turnFinished(.completed))
        #expect(!rollup.isBusy(key))
        #expect(rollup.apply(.idle(session: "c"), key: key).event == nil, "idle twice: no second finish")
    }

    @Test func rollupTrackingIsBounded() {
        var rollup = OpenCodeRollup()
        for index in 0..<(OpenCodeRollup.maxProcesses + 50) {
            _ = rollup.apply(.idle(session: "s"), key: SessionKey(agent: .opencode, id: "pid:\(index):0.0"))
        }
        #expect(rollup.processes.count <= OpenCodeRollup.maxProcesses)
        let busyKey = SessionKey(agent: .opencode, id: "pid:busy:0.0")
        for index in 0..<(OpenCodeRollup.maxSessionsPerProcess + 10) {
            _ = rollup.apply(.busy(session: "s\(index)"), key: busyKey)
        }
        #expect((rollup.processes[busyKey]?.busy.count ?? 0) <= OpenCodeRollup.maxSessionsPerProcess)
    }
}
