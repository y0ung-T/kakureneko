@testable import KakurenekoEvents
import KakurenekoKit
import Foundation
import Testing

/// ARCHITECTURE §9.1 "Dedupe" / §11.15: only CONSECUTIVE duplicates per session key within 2 s of `occurredAt`;
/// Codex `notify` + `Stop` of the same turn collapse regardless of time (acceptance 9).
@Suite("Dedupe", .timeLimit(.minutes(1)))
struct DedupeTests {
    static let permission = #"{"session_id":"s1","message":"Claude needs your permission","notification_type":"permission_prompt"}"#

    @Test func consecutiveDuplicateWithinTwoSecondsIsDroppedOnce() throws {
        var harness = PipelineHarness()
        _ = try harness.accept("claude", "Notification", Self.permission, at: 0)
        #expect(harness.send("claude", "Notification", Self.permission, at: 1.5) == .dropped(.duplicate))
        // Exactly at the window edge is still a duplicate (|Δ| ≤ 2 s).
        #expect(harness.send("claude", "Notification", Self.permission, at: 2) == .dropped(.duplicate))
    }

    @Test func alternatingEventsWithinTwoSecondsAreAllKept() throws {
        var harness = PipelineHarness()
        let started = try harness.accept("claude", "UserPromptSubmit", #"{"session_id":"s1"}"#, at: 0)
        let finished = try harness.accept("claude", "Stop", #"{"session_id":"s1"}"#, at: 0.5)
        let again = try harness.accept("claude", "UserPromptSubmit", #"{"session_id":"s1"}"#, at: 1.0)
        #expect([started.event, finished.event, again.event] == [.turnStarted, .turnFinished(.completed), .turnStarted],
                "a second turnStarted after a sub-2-s turn is legitimate")
    }

    @Test func sameEventThreeSecondsApartIsKeptTwice() throws {
        var harness = PipelineHarness()
        _ = try harness.accept("claude", "Notification", Self.permission, at: 0)
        _ = try harness.accept("claude", "Notification", Self.permission, at: 3)
    }

    @Test func windowIsMeasuredOnOccurredAtNotArrival() throws {
        var harness = PipelineHarness()
        let arrival = Fixture.t0.addingTimeInterval(60)
        // Both files are drained in the same pass (same receivedAt) but were written 5 s apart.
        #expect(harness.send("claude", "Notification", Self.permission, at: 0, receivedAt: arrival).event != nil)
        #expect(harness.send("claude", "Notification", Self.permission, at: 5, receivedAt: arrival).event != nil)
        // Written 1 s apart, delivered a minute apart: still a duplicate.
        #expect(harness.send("claude", "Notification", Self.permission, at: 6, receivedAt: arrival.addingTimeInterval(60))
                == .dropped(.duplicate))
    }

    @Test func differentSessionsKindsAndOutcomesAreNotDuplicates() throws {
        var harness = PipelineHarness()
        _ = try harness.accept("claude", "Notification", Self.permission, at: 0)
        _ = try harness.accept("claude", "Notification", #"{"session_id":"s2","notification_type":"permission_prompt"}"#, at: 0.1)
        _ = try harness.accept("claude", "Notification", #"{"session_id":"s1","notification_type":"elicitation_dialog"}"#, at: 0.2)
        _ = try harness.accept("claude", "StopFailure", #"{"session_id":"s1","error":"rate_limit"}"#, at: 0.3)
        _ = try harness.accept("claude", "StopFailure", #"{"session_id":"s1","error":"overloaded"}"#, at: 0.4)
    }

    @Test func onlyTheMostRecentAcceptedEventCounts() throws {
        var harness = PipelineHarness()
        _ = try harness.accept("claude", "PreToolUse", #"{"session_id":"s1"}"#, at: 0)
        #expect(harness.send("claude", "PostToolUse", #"{"session_id":"s1"}"#, at: 0.5) == .dropped(.duplicate),
                "tool pre/post are both `activity`: consecutive duplicates")
        _ = try harness.accept("claude", "Stop", #"{"session_id":"s1"}"#, at: 1)
        _ = try harness.accept("claude", "PreToolUse", #"{"session_id":"s1"}"#, at: 1.5)
    }

    // MARK: Codex notify + Stop

    static let notify = #"{"type":"agent-turn-complete","thread-id":"th-1","turn-id":"42","cwd":"/p","last-assistant-message":"done"}"#

    @Test func codexNotifyAndStopOfTheSameTurnCollapseRegardlessOfTime() throws {
        var harness = PipelineHarness()
        let first = try harness.accept("codex", "notify", Self.notify, at: 0)
        #expect(first.sessionKey == SessionKey(agent: .codex, id: "th-1"))
        #expect(first.turnID == "42")
        #expect(harness.send("codex", "Stop", #"{"session_id":"th-1","turn_id":"42","last_assistant_message":"done"}"#, at: 0.2)
                == .dropped(.duplicate))
        #expect(harness.send("codex", "Stop", #"{"session_id":"th-1","turn_id":"42"}"#, at: 45) == .dropped(.duplicate),
                "same turn id 45 s later is still the same turn")
        // The next turn finishes normally, in either order.
        _ = try harness.accept("codex", "UserPromptSubmit", #"{"session_id":"th-1","turn_id":"43"}"#, at: 50)
        _ = try harness.accept("codex", "Stop", #"{"session_id":"th-1","turn_id":"43"}"#, at: 60)
        #expect(harness.send("codex", "notify", #"{"type":"agent-turn-complete","thread-id":"th-1","turn-id":"43"}"#, at: 60.1)
                == .dropped(.duplicate))
    }

    @Test func codexTurnsOfDifferentThreadsDoNotCollapse() throws {
        var harness = PipelineHarness()
        _ = try harness.accept("codex", "notify", #"{"type":"agent-turn-complete","thread-id":"a","turn-id":"1"}"#, at: 0)
        _ = try harness.accept("codex", "notify", #"{"type":"agent-turn-complete","thread-id":"b","turn-id":"1"}"#, at: 0)
    }

    @Test func turnIDsOnlyCollapseCodex() throws {
        var harness = PipelineHarness()
        // Claude's prompt_id is a turn id too, but only Codex has two delivery paths for one finish.
        _ = try harness.accept("claude", "Stop", #"{"session_id":"s","prompt_id":"p1"}"#, at: 0)
        _ = try harness.accept("claude", "UserPromptSubmit", #"{"session_id":"s","prompt_id":"p1"}"#, at: 5)
        _ = try harness.accept("claude", "Stop", #"{"session_id":"s","prompt_id":"p1"}"#, at: 10)
    }

    // MARK: Bounded state

    @Test func tablesStayBounded() {
        var state = DedupeState()
        for index in 0..<(DedupeState.maxSessions + 100) {
            let event = AgentEvent(id: "\(index)", agent: .codex, event: .turnFinished(.completed), rawEventName: "notify",
                                   sessionKey: SessionKey(agent: .codex, id: "t\(index)"), turnID: "1",
                                   occurredAt: Fixture.t0.addingTimeInterval(Double(index)), receivedAt: Fixture.t0)
            let accepted = state.accept(event)
            #expect(accepted)
        }
        #expect(state.lastAccepted.count <= DedupeState.maxSessions)
        #expect(state.codexFinishedTurns.count <= DedupeState.maxCodexTurns)
        // The newest entries survive pruning.
        let newest = AgentEvent(id: "x", agent: .codex, event: .turnFinished(.completed), rawEventName: "Stop",
                                sessionKey: SessionKey(agent: .codex, id: "t\(DedupeState.maxSessions + 99)"), turnID: "1",
                                occurredAt: Fixture.t0.addingTimeInterval(100_000), receivedAt: Fixture.t0)
        let acceptedAgain = state.accept(newest)
        #expect(!acceptedAgain)
    }
}
