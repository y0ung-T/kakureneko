@testable import KakurenekoEvents
import KakurenekoKit
import Foundation
import Testing

/// One raw hook event → expected normalized result (brief §3.3/§3.4 + ARCHITECTURE §9.1 corrections). Payload shapes
/// are the verified ones from R02 §1, R03 §2–§8, R04 §3, R05 §3.
struct NormalizerCase: Sendable, CustomTestStringConvertible {
    var agent: String
    var event: String
    var payload: String
    /// nil = the event must be dropped.
    var expected: NormalizedEvent?
    var session: String? = nil
    var turnID: String? = nil
    var background = false
    var preview: String? = nil
    var waitingFor: String? = nil
    var errorDetail: String? = nil
    var metadata: [String: String] = [:]
    var env: [String: String] = [:]
    var expectedAgent: AgentID? = nil

    var testDescription: String { "\(agent) \(event) → \(expected.map { "\($0)" } ?? "dropped")" }
}

@Suite("Normalizers", .timeLimit(.minutes(1)))
struct NormalizerTests {
    static let sid = "e5b3e311-1111-2222-3333-444455556666"

    // MARK: Claude Code (brief §3.3 row 1, R02 §1.2–1.4, ARCHITECTURE §9.1 corrections)

    static let claude: [NormalizerCase] = [
        NormalizerCase(agent: "claude", event: "SessionStart",
                       payload: #"{"session_id":"\#(sid)","source":"startup","cwd":"/Users/x/proj","transcript_path":"/Users/x/.claude/projects/p/\#(sid).jsonl","hook_event_name":"SessionStart"}"#,
                       expected: .sessionStarted, session: sid, metadata: [MetadataKey.claudeSessionStartSource: "startup"]),
        NormalizerCase(agent: "claude", event: "SessionStart", payload: #"{"session_id":"\#(sid)","source":"compact"}"#,
                       expected: .sessionStarted, session: sid, metadata: [MetadataKey.claudeSessionStartSource: "compact"]),
        NormalizerCase(agent: "claude", event: "SessionStart", payload: #"{"session_id":"\#(sid)","source":"resume"}"#,
                       expected: .sessionStarted, session: sid, metadata: [MetadataKey.claudeSessionStartSource: "resume"]),
        NormalizerCase(agent: "claude", event: "SessionStart", payload: #"{"session_id":"\#(sid)","source":"clear"}"#,
                       expected: .sessionStarted, session: sid, metadata: [MetadataKey.claudeSessionStartSource: "clear"]),
        NormalizerCase(agent: "claude", event: "UserPromptSubmit",
                       payload: #"{"session_id":"\#(sid)","prompt_id":"p-1","prompt":"refactor the auth module","permission_mode":"default"}"#,
                       expected: .turnStarted, session: sid, turnID: "p-1", metadata: ["claude.permissionMode": "default"]),
        NormalizerCase(agent: "claude", event: "Stop",
                       payload: #"{"session_id":"\#(sid)","stop_hook_active":false,"last_assistant_message":"Refactor done.\n\nSee /Users/me/proj/src/auth.swift","background_tasks":[{"id":"task-001","type":"shell","status":"running","command":"tail -f /var/log/syslog"}],"session_crons":[{"id":"cron-1"}]}"#,
                       expected: .turnFinished(.completed), session: sid, background: false, preview: "Refactor done. See auth.swift"),
        NormalizerCase(agent: "claude", event: "Stop",
                       payload: #"{"session_id":"\#(sid)","background_tasks":[{"type":"subagent","status":"running"}]}"#,
                       expected: .turnFinished(.completed), session: sid, background: true),
        NormalizerCase(agent: "claude", event: "Stop",
                       payload: #"{"session_id":"\#(sid)","background_tasks":[{"type":"workflow","status":"running"}]}"#,
                       expected: .turnFinished(.completed), session: sid, background: true),
        NormalizerCase(agent: "claude", event: "Stop",
                       payload: #"{"session_id":"\#(sid)","background_tasks":[{"type":"subagent"}]}"#,
                       expected: .turnFinished(.completed), session: sid, background: true),
        // Claude Code's comment watch on a published artifact (`monitor_ws`) stays armed after the turn.
        NormalizerCase(agent: "claude", event: "Stop",
                       payload: #"{"session_id":"\#(sid)","background_tasks":[{"id":"w1","type":"monitor","status":"running","description":"Kakureneko Design"},{"type":"monitor","status":"running","server":"ci","tool":"watch"}]}"#,
                       expected: .turnFinished(.completed), session: sid, background: false),
        NormalizerCase(agent: "claude", event: "Stop",
                       payload: #"{"session_id":"\#(sid)","background_tasks":[{"type":"teammate","status":"running"}]}"#,
                       expected: .turnFinished(.completed), session: sid, background: true),
        NormalizerCase(agent: "claude", event: "Stop",
                       payload: #"{"session_id":"\#(sid)","background_tasks":[{"type":"subagent","status":"completed"},{"type":"cloud session","status":"running"},{"type":"MCP task","status":"running"}]}"#,
                       expected: .turnFinished(.completed), session: sid, background: false),
        NormalizerCase(agent: "claude", event: "StopFailure",
                       payload: #"{"session_id":"\#(sid)","error":"rate_limit","last_assistant_message":"API Error: Rate limited"}"#,
                       expected: .turnFinished(.rateLimited), session: sid, errorDetail: "rate_limit"),
        NormalizerCase(agent: "claude", event: "StopFailure", payload: #"{"session_id":"\#(sid)","error":"overloaded"}"#,
                       expected: .turnFinished(.error), session: sid, errorDetail: "overloaded"),
        NormalizerCase(agent: "claude", event: "StopFailure", payload: #"{"session_id":"\#(sid)","error":"authentication_failed"}"#,
                       expected: .turnFinished(.error), session: sid, errorDetail: "authentication_failed"),
        NormalizerCase(agent: "claude", event: "Notification",
                       payload: #"{"session_id":"\#(sid)","hook_event_name":"Notification","message":"Claude needs your permission to use Bash","title":"Permission needed","notification_type":"permission_prompt"}"#,
                       expected: .needsInput(.permission), session: sid, waitingFor: "Claude needs your permission to use Bash"),
        NormalizerCase(agent: "claude", event: "Notification",
                       payload: #"{"session_id":"\#(sid)","message":"A worker needs permission","notification_type":"worker_permission_prompt"}"#,
                       expected: .needsInput(.permission), session: sid, waitingFor: "A worker needs permission"),
        NormalizerCase(agent: "claude", event: "Notification",
                       payload: #"{"session_id":"\#(sid)","message":"Claude has a question","notification_type":"elicitation_dialog"}"#,
                       expected: .needsInput(.question), session: sid, waitingFor: "Claude has a question"),
        NormalizerCase(agent: "claude", event: "Notification",
                       payload: #"{"session_id":"\#(sid)","message":"Open the link","notification_type":"elicitation_url_dialog"}"#,
                       expected: .needsInput(.question), session: sid),
        NormalizerCase(agent: "claude", event: "Notification",
                       payload: #"{"session_id":"\#(sid)","message":"Agent needs input","notification_type":"agent_needs_input"}"#,
                       expected: .needsInput(.unknown), session: sid),
        NormalizerCase(agent: "claude", event: "Notification",
                       payload: #"{"session_id":"\#(sid)","message":"Claude is waiting for your input","notification_type":"idle_prompt"}"#,
                       expected: .idleReminder, session: sid),
        // Corrections (binding): agent_completed → activity; quota_auto_resume_fired → turnStarted;
        // quota_auto_resume_stale/_disabled → needsInput(unknown).
        NormalizerCase(agent: "claude", event: "Notification",
                       payload: #"{"session_id":"\#(sid)","message":"Background agent finished","notification_type":"agent_completed"}"#,
                       expected: .activity, session: sid),
        NormalizerCase(agent: "claude", event: "Notification",
                       payload: #"{"session_id":"\#(sid)","notification_type":"quota_auto_resume_fired"}"#,
                       expected: .turnStarted, session: sid),
        NormalizerCase(agent: "claude", event: "Notification",
                       payload: #"{"session_id":"\#(sid)","message":"Usage limit reset. Press Enter to continue","notification_type":"quota_auto_resume_stale"}"#,
                       expected: .needsInput(.unknown), session: sid, waitingFor: "Usage limit reset. Press Enter to continue"),
        NormalizerCase(agent: "claude", event: "Notification",
                       payload: #"{"session_id":"\#(sid)","notification_type":"quota_auto_resume_disabled"}"#,
                       expected: .needsInput(.unknown), session: sid),
        NormalizerCase(agent: "claude", event: "Notification",
                       payload: #"{"session_id":"\#(sid)","notification_type":"auth_success","message":"Logged in"}"#,
                       expected: nil),
        NormalizerCase(agent: "claude", event: "Notification",
                       payload: #"{"session_id":"\#(sid)","notification_type":"push_notification"}"#, expected: nil),
        NormalizerCase(agent: "claude", event: "PermissionRequest",
                       payload: #"{"session_id":"\#(sid)","tool_name":"Bash","tool_input":{"command":"rm -rf build","description":"Remove the build folder"}}"#,
                       expected: .needsInput(.permission), session: sid, waitingFor: "Remove the build folder"),
        NormalizerCase(agent: "claude", event: "SessionEnd", payload: #"{"session_id":"\#(sid)","reason":"prompt_input_exit"}"#,
                       expected: .sessionEnded, session: sid, metadata: ["sessionEndReason": "prompt_input_exit"]),
        NormalizerCase(agent: "claude", event: "PreToolUse", payload: #"{"session_id":"\#(sid)","tool_name":"Bash"}"#,
                       expected: .activity, session: sid),
        NormalizerCase(agent: "claude", event: "PostToolUse", payload: #"{"session_id":"\#(sid)"}"#, expected: .activity, session: sid),
        NormalizerCase(agent: "claude", event: "SubagentStop",
                       payload: #"{"session_id":"\#(sid)","agent_id":"a1","agent_type":"Explore"}"#,
                       expected: .activity, session: sid, metadata: ["claude.agentType": "Explore"]),
        NormalizerCase(agent: "claude", event: "PreCompact", payload: #"{"session_id":"\#(sid)"}"#, expected: .activity, session: sid),
        NormalizerCase(agent: "claude", event: "ConfigChange", payload: #"{"session_id":"\#(sid)"}"#, expected: nil),
    ]

    // MARK: Codex (brief §3.3 row 2, R03 §2(d))

    static let codex: [NormalizerCase] = [
        NormalizerCase(agent: "codex", event: "notify",
                       payload: #"{"type":"agent-turn-complete","thread-id":"b5f6c1c2-aaaa","turn-id":"12345","cwd":"/Users/example/project","client":"codex-tui","input-messages":["Rename `foo`"],"last-assistant-message":"Rename complete"}"#,
                       expected: .turnFinished(.completed), session: "b5f6c1c2-aaaa", turnID: "12345", preview: "Rename complete",
                       metadata: [MetadataKey.codexClient: "codex-tui"]),
        NormalizerCase(agent: "codex", event: "notify",
                       payload: #"{"type":"agent-turn-complete","thread-id":"t2","turn-id":"9","last-assistant-message":null}"#,
                       expected: .turnFinished(.completed), session: "t2", turnID: "9"),
        NormalizerCase(agent: "codex", event: "notify", payload: #"{"type":"approval-requested","thread-id":"t2"}"#, expected: nil),
        NormalizerCase(agent: "codex", event: "SessionStart",
                       payload: #"{"session_id":"t1","transcript_path":null,"cwd":"/p","hook_event_name":"SessionStart","model":"gpt-6","source":"startup"}"#,
                       expected: .sessionStarted, session: "t1", metadata: ["codex.sessionStartSource": "startup"]),
        NormalizerCase(agent: "codex", event: "UserPromptSubmit", payload: #"{"session_id":"t1","turn_id":"12346","prompt":"x"}"#,
                       expected: .turnStarted, session: "t1", turnID: "12346"),
        NormalizerCase(agent: "codex", event: "Stop",
                       payload: #"{"session_id":"t1","turn_id":"12346","stop_hook_active":false,"last_assistant_message":"All tests pass"}"#,
                       expected: .turnFinished(.completed), session: "t1", turnID: "12346", preview: "All tests pass"),
        NormalizerCase(agent: "codex", event: "Interrupt", payload: #"{"session_id":"t1","turn_id":"12347"}"#,
                       expected: .turnFinished(.interrupted), session: "t1", turnID: "12347"),
        NormalizerCase(agent: "codex", event: "PermissionRequest",
                       payload: #"{"session_id":"t1","turn_id":"12348","tool_name":"shell","tool_input":{"description":"Run npm test"}}"#,
                       expected: .needsInput(.permission), session: "t1", turnID: "12348", waitingFor: "Run npm test"),
        NormalizerCase(agent: "codex", event: "SessionEnd", payload: #"{"session_id":"t1","reason":"other"}"#,
                       expected: .sessionEnded, session: "t1"),
        NormalizerCase(agent: "codex", event: "PreToolUse", payload: #"{"session_id":"t1"}"#, expected: .activity, session: "t1"),
        NormalizerCase(agent: "codex", event: "PostCompact", payload: #"{"session_id":"t1"}"#, expected: .activity, session: "t1"),
    ]

    // MARK: Gemini CLI (brief §3.3 row 3, R03 §3(d))

    static let gemini: [NormalizerCase] = [
        NormalizerCase(agent: "gemini", event: "SessionStart", payload: #"{"session_id":"g1","cwd":"/p","source":"startup"}"#,
                       expected: .sessionStarted, session: "g1", metadata: ["gemini.sessionStartSource": "startup"]),
        NormalizerCase(agent: "gemini", event: "BeforeAgent", payload: #"{"session_id":"g1","prompt":"build it"}"#,
                       expected: .turnStarted, session: "g1"),
        NormalizerCase(agent: "gemini", event: "AfterAgent",
                       payload: #"{"session_id":"g1","prompt":"build it","prompt_response":"Built successfully.","stop_hook_active":false}"#,
                       expected: .turnFinished(.completed), session: "g1", preview: "Built successfully."),
        NormalizerCase(agent: "gemini", event: "Notification",
                       payload: #"{"session_id":"g1","notification_type":"ToolPermission","message":"Allow run_shell_command?","details":{}}"#,
                       expected: .needsInput(.permission), session: "g1", waitingFor: "Allow run_shell_command?"),
        NormalizerCase(agent: "gemini", event: "Notification", payload: #"{"session_id":"g1","notification_type":"Other"}"#, expected: nil),
        NormalizerCase(agent: "gemini", event: "SessionEnd", payload: #"{"session_id":"g1","reason":"exit"}"#, expected: .sessionEnded, session: "g1"),
        NormalizerCase(agent: "gemini", event: "BeforeTool", payload: #"{"session_id":"g1"}"#, expected: .activity, session: "g1"),
        NormalizerCase(agent: "gemini", event: "AfterModel", payload: #"{"session_id":"g1"}"#, expected: .activity, session: "g1"),
        // Session id from GEMINI_SESSION_ID when the payload has none.
        NormalizerCase(agent: "gemini", event: "AfterAgent", payload: #"{}"#, expected: .turnFinished(.completed), session: "g-env",
                       env: ["GEMINI_SESSION_ID": "g-env"]),
        // The payload id always wins over the environment.
        NormalizerCase(agent: "gemini", event: "BeforeAgent", payload: #"{"session_id":"g-payload"}"#, expected: .turnStarted,
                       session: "g-payload", env: ["GEMINI_SESSION_ID": "g-env"]),
    ]

    // MARK: Antigravity agy (brief §3.3 row 4, R03 §4(d))

    static let agy: [NormalizerCase] = [
        NormalizerCase(agent: "agy", event: "Stop",
                       payload: #"{"conversationId":"a1","workspacePaths":["/Users/x/w"],"transcriptPath":"/t","artifactDirectoryPath":"/a","modelName":"g","executionNum":3,"terminationReason":"completed","fullyIdle":true}"#,
                       expected: .turnFinished(.completed), session: "a1", metadata: ["agy.terminationReason": "completed"]),
        NormalizerCase(agent: "agy", event: "Stop",
                       payload: #"{"conversationId":"a1","terminationReason":"error","error":"model unavailable","fullyIdle":true}"#,
                       expected: .turnFinished(.error), session: "a1", errorDetail: "model unavailable"),
        NormalizerCase(agent: "agy", event: "Stop", payload: #"{"conversationId":"a1","terminationReason":"user_cancelled"}"#,
                       expected: .turnFinished(.interrupted), session: "a1"),
        NormalizerCase(agent: "agy", event: "Stop", payload: #"{"conversationId":"a1","terminationReason":"quota_exceeded"}"#,
                       expected: .turnFinished(.rateLimited), session: "a1"),
        NormalizerCase(agent: "agy", event: "Stop", payload: #"{"conversationId":"a1","terminationReason":"completed","fullyIdle":false}"#,
                       expected: .turnFinished(.completed), session: "a1", background: true),
        NormalizerCase(agent: "agy", event: "PostToolUse", payload: #"{"conversationId":"a1"}"#, expected: .activity, session: "a1"),
        NormalizerCase(agent: "agy", event: "statusLine", payload: #"{"conversation_id":"a1","agent_state":"idle","tool_confirmation_pending":true}"#,
                       expected: .needsInput(.permission), session: "a1"),
        NormalizerCase(agent: "agy", event: "statusLine", payload: #"{"conversation_id":"a1","agent_state":"idle","tool_confirmation_pending":false}"#,
                       expected: nil),
    ]

    // MARK: Copilot CLI (brief §3.3 row 5, R03 §5(d))

    static let copilot: [NormalizerCase] = [
        NormalizerCase(agent: "copilot", event: "sessionStart", payload: #"{"sessionId":"cp1","timestamp":1791811783024,"cwd":"/p","source":"new"}"#,
                       expected: .sessionStarted, session: "cp1", metadata: ["copilot.sessionStartSource": "new"]),
        NormalizerCase(agent: "copilot", event: "userPromptSubmitted", payload: #"{"sessionId":"cp1","prompt":"x"}"#,
                       expected: .turnStarted, session: "cp1"),
        NormalizerCase(agent: "copilot", event: "agentStop",
                       payload: #"{"sessionId":"cp1","timestamp":1791811783024,"cwd":"/p","transcriptPath":"/t.jsonl","stopReason":"end_turn","stop_hook_active":false}"#,
                       expected: .turnFinished(.completed), session: "cp1"),
        NormalizerCase(agent: "copilot", event: "agentStop", payload: #"{"sessionId":"cp1","stopReason":"abort"}"#,
                       expected: .turnFinished(.interrupted), session: "cp1"),
        NormalizerCase(agent: "copilot", event: "errorOccurred", payload: #"{"sessionId":"cp1","error":{"name":"APIError","message":"boom"}}"#,
                       expected: .turnFinished(.error), session: "cp1", errorDetail: "boom"),
        NormalizerCase(agent: "copilot", event: "notification",
                       payload: #"{"sessionId":"cp1","hook_event_name":"Notification","message":"Allow edit?","notification_type":"permission_prompt"}"#,
                       expected: .needsInput(.permission), session: "cp1", waitingFor: "Allow edit?", expectedAgent: .copilot),
        NormalizerCase(agent: "copilot", event: "notification", payload: #"{"sessionId":"cp1","message":"Pick one","notification_type":"elicitation_dialog"}"#,
                       expected: .needsInput(.question), session: "cp1", waitingFor: "Pick one", expectedAgent: .copilot),
        NormalizerCase(agent: "copilot", event: "notification", payload: #"{"sessionId":"cp1","notification_type":"agent_idle"}"#,
                       expected: .idleReminder, session: "cp1", expectedAgent: .copilot),
        NormalizerCase(agent: "copilot", event: "notification", payload: #"{"sessionId":"cp1","notification_type":"agent_completed"}"#,
                       expected: .activity, session: "cp1", expectedAgent: .copilot),
        NormalizerCase(agent: "copilot", event: "notification", payload: #"{"sessionId":"cp1","notification_type":"shell_completed"}"#,
                       expected: nil),
        NormalizerCase(agent: "copilot", event: "sessionEnd", payload: #"{"sessionId":"cp1","reason":"user_exit"}"#,
                       expected: .sessionEnded, session: "cp1", metadata: ["sessionEndReason": "user_exit"]),
        NormalizerCase(agent: "copilot", event: "postToolUse", payload: #"{"sessionId":"cp1"}"#, expected: .activity, session: "cp1"),
    ]

    // MARK: Cursor (brief §3.3 row 6, R03 §6(d), R05 §3.2)

    static let cursor: [NormalizerCase] = [
        NormalizerCase(agent: "cursor", event: "sessionStart",
                       payload: #"{"conversation_id":"cu1","generation_id":"g0","session_id":"s-x","is_background_agent":false,"composer_mode":"agent","workspace_roots":["/Users/x/repo"]}"#,
                       expected: .sessionStarted, session: "cu1", turnID: "g0", metadata: ["cursor.composerMode": "agent"]),
        NormalizerCase(agent: "cursor", event: "beforeSubmitPrompt", payload: #"{"conversation_id":"cu1","generation_id":"g1","prompt":"x"}"#,
                       expected: .turnStarted, session: "cu1", turnID: "g1"),
        NormalizerCase(agent: "cursor", event: "postToolUse", payload: #"{"conversation_id":"cu1","generation_id":"g1"}"#,
                       expected: .activity, session: "cu1", turnID: "g1"),
        NormalizerCase(agent: "cursor", event: "afterAgentResponse", payload: #"{"conversation_id":"cu1","text":"hi"}"#,
                       expected: .activity, session: "cu1"),
        NormalizerCase(agent: "cursor", event: "stop", payload: #"{"conversation_id":"cu1","generation_id":"g1","status":"completed","loop_count":0}"#,
                       expected: .turnFinished(.completed), session: "cu1", turnID: "g1"),
        NormalizerCase(agent: "cursor", event: "stop", payload: #"{"conversation_id":"cu1","status":"aborted"}"#,
                       expected: .turnFinished(.interrupted), session: "cu1"),
        NormalizerCase(agent: "cursor", event: "stop", payload: #"{"conversation_id":"cu1","status":"error"}"#,
                       expected: .turnFinished(.error), session: "cu1"),
        NormalizerCase(agent: "cursor", event: "sessionEnd", payload: #"{"conversation_id":"cu1","session_id":"s","reason":"window_close"}"#,
                       expected: .sessionEnded, session: "cu1", metadata: ["sessionEndReason": "window_close"]),
        NormalizerCase(agent: "cursor", event: "preToolUse", payload: #"{"conversation_id":"cu1"}"#, expected: nil),
    ]

    // MARK: Aider (brief §3.3 row 8)

    static let aider: [NormalizerCase] = [
        NormalizerCase(agent: "aider", event: "waiting", payload: "", expected: .turnFinished(.ambiguous)),
    ]

    // MARK: Claude-compatible family (brief §3.4, R04 §3)

    static let family: [NormalizerCase] = [
        // Factory Droid
        NormalizerCase(agent: "droid", event: "SessionStart", payload: #"{"session_id":"d1","source":"startup"}"#, expected: .sessionStarted, session: "d1"),
        NormalizerCase(agent: "droid", event: "UserPromptSubmit", payload: #"{"session_id":"d1"}"#, expected: .turnStarted, session: "d1"),
        NormalizerCase(agent: "droid", event: "Stop", payload: #"{"session_id":"d1","stop_hook_active":false,"tool_execution_count":3,"elapsed_time":12}"#,
                       expected: .turnFinished(.completed), session: "d1"),
        NormalizerCase(agent: "droid", event: "Notification", payload: #"{"session_id":"d1","message":"Approve edit?","notification_type":"permission_prompt"}"#,
                       expected: .needsInput(.permission), session: "d1", waitingFor: "Approve edit?"),
        NormalizerCase(agent: "droid", event: "Notification", payload: #"{"session_id":"d1","notification_type":"idle_prompt"}"#,
                       expected: .idleReminder, session: "d1"),
        NormalizerCase(agent: "droid", event: "SessionEnd", payload: #"{"session_id":"d1","reason":"clear"}"#, expected: .sessionEnded, session: "d1"),
        // Qwen Code
        NormalizerCase(agent: "qwen", event: "Stop", payload: #"{"session_id":"q1","background_tasks":[{"id":"b"}],"crons":[]}"#,
                       expected: .turnFinished(.completed), session: "q1", background: true),
        NormalizerCase(agent: "qwen", event: "Stop", payload: #"{"session_id":"q1","background_tasks":[],"crons":[{"id":"c"}]}"#,
                       expected: .turnFinished(.completed), session: "q1", background: true),
        NormalizerCase(agent: "qwen", event: "Stop", payload: #"{"session_id":"q1","last_assistant_message":"ok","background_tasks":[],"crons":[]}"#,
                       expected: .turnFinished(.completed), session: "q1", background: false, preview: "ok"),
        NormalizerCase(agent: "qwen", event: "StopFailure", payload: #"{"session_id":"q1","error":"rate_limit"}"#,
                       expected: .turnFinished(.rateLimited), session: "q1"),
        NormalizerCase(agent: "qwen", event: "PermissionRequest", payload: #"{"session_id":"q1","tool_name":"run_shell"}"#,
                       expected: .needsInput(.permission), session: "q1", waitingFor: "Permission for run_shell"),
        NormalizerCase(agent: "qwen", event: "Notification", payload: #"{"session_id":"q1","notification_type":"idle_prompt"}"#,
                       expected: .idleReminder, session: "q1"),
        // Augment Auggie (conversation_id, agent_stop_cause, PromptSubmit; ms timeouts are an installer concern)
        NormalizerCase(agent: "auggie", event: "PromptSubmit", payload: #"{"hook_event_name":"PromptSubmit","conversation_id":"au1","user_prompt":"x"}"#,
                       expected: .turnStarted, session: "au1"),
        NormalizerCase(agent: "auggie", event: "Stop", payload: #"{"conversation_id":"au1","agent_stop_cause":"end_turn","workspace_roots":["/w"]}"#,
                       expected: .turnFinished(.completed), session: "au1", metadata: ["auggie.stopCause": "end_turn"]),
        NormalizerCase(agent: "auggie", event: "Stop", payload: #"{"conversation_id":"au1","agent_stop_cause":"max_iterations"}"#,
                       expected: .turnFinished(.completed), session: "au1"),
        NormalizerCase(agent: "auggie", event: "Stop", payload: #"{"conversation_id":"au1","agent_stop_cause":"interrupted"}"#,
                       expected: .turnFinished(.interrupted), session: "au1"),
        NormalizerCase(agent: "auggie", event: "Stop", payload: #"{"conversation_id":"au1","agent_stop_cause":"error"}"#,
                       expected: .turnFinished(.error), session: "au1"),
        NormalizerCase(agent: "auggie", event: "Notification", payload: #"{"conversation_id":"au1","notification_type":"info","notification_message":"x"}"#,
                       expected: nil),
        NormalizerCase(agent: "auggie", event: "SessionStart", payload: #"{"conversation_id":"au1"}"#, expected: .sessionStarted, session: "au1"),
        NormalizerCase(agent: "auggie", event: "Stop", payload: #"{"agent_stop_cause":"end_turn"}"#, expected: .turnFinished(.completed),
                       session: "au-env", env: ["AUGMENT_CONVERSATION_ID": "au-env"]),
        // Qoder, CodeBuddy, iFlow, Devin: Claude event names.
        NormalizerCase(agent: "qoder", event: "UserPromptSubmit", payload: #"{"session_id":"qd"}"#, expected: .turnStarted, session: "qd"),
        NormalizerCase(agent: "qoder", event: "Stop", payload: #"{"session_id":"qd"}"#, expected: .turnFinished(.completed), session: "qd"),
        NormalizerCase(agent: "codebuddy", event: "Stop", payload: #"{"session_id":"cb"}"#, expected: .turnFinished(.completed), session: "cb"),
        NormalizerCase(agent: "codebuddy", event: "Notification", payload: #"{"session_id":"cb","notification_type":"permission_prompt"}"#,
                       expected: .needsInput(.permission), session: "cb"),
        NormalizerCase(agent: "iflow", event: "SessionEnd", payload: #"{"session_id":"if"}"#, expected: .sessionEnded, session: "if"),
        NormalizerCase(agent: "iflow", event: "UserPromptSubmit", payload: #"{"session_id":"if"}"#, expected: .turnStarted, session: "if"),
        NormalizerCase(agent: "devin", event: "Stop", payload: #"{"session_id":"dv"}"#, expected: .turnFinished(.completed), session: "dv"),
        NormalizerCase(agent: "devin", event: "StopFailure", payload: #"{"session_id":"dv","error":"server_error"}"#,
                       expected: .turnFinished(.error), session: "dv"),
    ]

    // MARK: Cline, Windsurf (brief §3.4, R04 §3.8, R05 §3.8)

    static let clineAndWindsurf: [NormalizerCase] = [
        NormalizerCase(agent: "cline", event: "TaskStart", payload: #"{"taskId":"k1","hookName":"agent_start","workspaceRoots":["/w"]}"#,
                       expected: .turnStarted, session: "k1"),
        NormalizerCase(agent: "cline", event: "TaskResume", payload: #"{"taskId":"k1"}"#, expected: .turnStarted, session: "k1"),
        NormalizerCase(agent: "cline", event: "UserPromptSubmit", payload: #"{"taskId":"k1"}"#, expected: .turnStarted, session: "k1"),
        NormalizerCase(agent: "cline", event: "TaskComplete", payload: #"{"taskId":"k1","hookName":"agent_end"}"#,
                       expected: .turnFinished(.completed), session: "k1"),
        NormalizerCase(agent: "cline", event: "TaskCancel", payload: #"{"taskId":"k1","reason":"user"}"#,
                       expected: .turnFinished(.interrupted), session: "k1"),
        NormalizerCase(agent: "cline", event: "TaskError", payload: #"{"taskId":"k1","error":{"name":"E","message":"tool failed"}}"#,
                       expected: .turnFinished(.error), session: "k1", errorDetail: "tool failed"),
        NormalizerCase(agent: "cline", event: "SessionShutdown", payload: #"{"sessionContext":{"rootSessionId":"root-1"}}"#,
                       expected: .sessionEnded, session: "root-1"),
        NormalizerCase(agent: "cline", event: "PreToolUse", payload: #"{"taskId":"k1"}"#, expected: .activity, session: "k1"),
        // SDK snake_case hook names (payload `hookName`) under an unknown argv event.
        NormalizerCase(agent: "cline", event: "hook", payload: #"{"taskId":"k1","hookName":"agent_end"}"#,
                       expected: .turnFinished(.completed), session: "k1"),
        NormalizerCase(agent: "windsurf", event: "pre_user_prompt",
                       payload: #"{"agent_action_name":"pre_user_prompt","trajectory_id":"w1","execution_id":"e1","tool_info":{"user_prompt":"x"}}"#,
                       expected: .turnStarted, session: "w1", turnID: "e1"),
        NormalizerCase(agent: "windsurf", event: "post_cascade_response",
                       payload: ###"{"trajectory_id":"w1","execution_id":"e1","tool_info":{"response":"## Done\nAll **green**"}}"###,
                       expected: .turnFinished(.completed), session: "w1", turnID: "e1", preview: "## Done All **green**"),
        NormalizerCase(agent: "windsurf", event: "post_cascade_response_with_transcript",
                       payload: #"{"trajectory_id":"w1","tool_info":{"transcript_path":"/Users/x/.windsurf/transcripts/w1.jsonl"}}"#,
                       expected: .turnFinished(.completed), session: "w1"),
        NormalizerCase(agent: "windsurf", event: "post_run_command", payload: #"{"trajectory_id":"w1","tool_info":{"command_line":"ls","cwd":"/w"}}"#,
                       expected: .activity, session: "w1"),
        NormalizerCase(agent: "windsurf", event: "pre_run_command", payload: #"{"trajectory_id":"w1"}"#, expected: .activity, session: "w1"),
    ]

    // MARK: Long tail (generic normalizer, R04 §7.3)

    static let generic: [NormalizerCase] = [
        NormalizerCase(agent: "kimi", event: "TurnStarted", payload: #"{"session_id":"km"}"#, expected: .turnStarted, session: "km"),
        NormalizerCase(agent: "kimi", event: "Stop", payload: #"{"session_id":"km"}"#, expected: .turnFinished(.completed), session: "km"),
        NormalizerCase(agent: "kimi", event: "Interrupt", payload: #"{"session_id":"km"}"#, expected: .turnFinished(.interrupted), session: "km"),
        NormalizerCase(agent: "kimi", event: "SessionHeartbeat", payload: #"{"session_id":"km"}"#, expected: .activity, session: "km"),
        NormalizerCase(agent: "kimi", event: "Notification", payload: #"{"session_id":"km","type":"task.completed"}"#, expected: .activity, session: "km"),
        NormalizerCase(agent: "amp", event: "agent.end", payload: #"{"thread_id":"am","status":"error"}"#, expected: .turnFinished(.error), session: "am"),
        NormalizerCase(agent: "amp", event: "agent.end", payload: #"{"thread_id":"am","status":"cancelled"}"#, expected: .turnFinished(.interrupted), session: "am"),
        NormalizerCase(agent: "hermes", event: "on_session_end", payload: #"{"session_id":"h"}"#, expected: nil),
        NormalizerCase(agent: "hermes", event: "on_session_finalize", payload: #"{"session_id":"h"}"#, expected: .sessionEnded, session: "h"),
        NormalizerCase(agent: "goose", event: "Stop", payload: #"{"session_id":"go","event":"Stop"}"#, expected: .turnFinished(.completed), session: "go"),
        NormalizerCase(agent: "vibe", event: "post_agent", payload: #"{"session_id":"vb"}"#, expected: .turnFinished(.completed), session: "vb"),
        NormalizerCase(agent: "kiro", event: "Stop", payload: #"{"hook_event_name":"stop","session_id":"kr","assistant_response":"Done"}"#,
                       expected: .turnFinished(.completed), session: "kr"),
        NormalizerCase(agent: "crush", event: "PreToolUse", payload: #"{"event":"PreToolUse","tool_name":"bash"}"#, expected: .activity,
                       session: "cr-env", env: ["CRUSH_SESSION_ID": "cr-env"]),
    ]

    // MARK: Driver

    @Test(arguments: claude + codex + gemini + agy + copilot + cursor + aider)
    func v1Agents(_ fixture: NormalizerCase) throws { try check(fixture) }

    @Test(arguments: family + clineAndWindsurf + generic)
    func familyClineWindsurfAndLongTail(_ fixture: NormalizerCase) throws { try check(fixture) }

    private func check(_ fixture: NormalizerCase, sourceLocation: SourceLocation = #_sourceLocation) throws {
        var harness = PipelineHarness()
        let outcome = harness.send(fixture.agent, fixture.event, fixture.payload, env: fixture.env)
        guard let expected = fixture.expected else {
            #expect(outcome.event == nil, "expected a drop, got \(outcome)", sourceLocation: sourceLocation)
            return
        }
        let event = try #require(outcome.event, "dropped: \(outcome)", sourceLocation: sourceLocation)
        #expect(event.event == expected, sourceLocation: sourceLocation)
        #expect(event.agent == (fixture.expectedAgent ?? AgentID(label: fixture.agent)), sourceLocation: sourceLocation)
        #expect(event.argvAgentLabel == fixture.agent, sourceLocation: sourceLocation)
        #expect(event.rawEventName == fixture.event, sourceLocation: sourceLocation)
        #expect(event.tier == .hook, sourceLocation: sourceLocation)
        if let session = fixture.session {
            #expect(event.sessionKey == SessionKey(agent: event.agent, id: session), sourceLocation: sourceLocation)
        }
        #expect(event.turnID == fixture.turnID, sourceLocation: sourceLocation)
        #expect(event.backgroundTasksRunning == fixture.background, sourceLocation: sourceLocation)
        if let preview = fixture.preview { #expect(event.messagePreview == preview, sourceLocation: sourceLocation) }
        if let waiting = fixture.waitingFor { #expect(event.waitingFor == waiting, sourceLocation: sourceLocation) }
        if let detail = fixture.errorDetail { #expect(event.errorDetail == detail, sourceLocation: sourceLocation) }
        for (key, value) in fixture.metadata {
            #expect(event.metadata[key] == value, "metadata[\(key)]", sourceLocation: sourceLocation)
        }
        if let preview = event.messagePreview { #expect(preview.count <= TextSanitizer.defaultLimit, sourceLocation: sourceLocation) }
    }

    // MARK: Targeted checks

    @Test func claudeStopCarriesCwdAndTranscript() throws {
        var harness = PipelineHarness()
        let event = try harness.accept("claude", "Stop",
                                       #"{"session_id":"s","cwd":"/Users/x/payload-dir","transcript_path":"/Users/x/.claude/projects/p/s.jsonl"}"#)
        #expect(event.cwd == "/Users/x/payload-dir", "payload cwd beats the hook's cwd")
        #expect(event.transcriptPath == "/Users/x/.claude/projects/p/s.jsonl")
        let noCwd = try harness.accept("claude", "UserPromptSubmit", #"{"session_id":"s"}"#, at: 10)
        #expect(noCwd.cwd == "/Users/x/proj", "the hook's cwd is the fallback")
    }

    @Test func messagePreviewIsSanitized() throws {
        var harness = PipelineHarness()
        let long = String(repeating: "word ", count: 100)
        let message = "\u{1B}[31mDone\u{1B}[0m with key sk-ant-api03-abcdefghijklmnopqrstuvwxyz in /Users/me/secret/project/file.txt \(long)"
        let payload = try JSONSerialization.data(withJSONObject: ["session_id": "s", "last_assistant_message": message])
        let event = try harness.accept("claude", "Stop", String(decoding: payload, as: UTF8.self))
        let preview = try #require(event.messagePreview)
        #expect(preview.count <= 140)
        #expect(preview.hasPrefix("Done with key [redacted] in file.txt"))
        #expect(!preview.contains("sk-ant"))
        #expect(!preview.contains("/Users/me"))
        #expect(!preview.contains("\u{1B}"))
        #expect(preview.hasSuffix("…"))
    }

    @Test func payloadEventNameIsTheFallbackForUnknownArgvEvents() throws {
        var harness = PipelineHarness()
        let event = try harness.accept("claude", "hook", #"{"session_id":"s","hook_event_name":"UserPromptSubmit"}"#)
        #expect(event.event == .turnStarted)
        #expect(event.rawEventName == "hook")
        // A known argv name with a deliberately ignored payload type is never re-routed.
        let dropped = harness.send("claude", "Notification", #"{"session_id":"s","hook_event_name":"Notification","notification_type":"auth_success"}"#)
        #expect(dropped == .dropped(.unknownEvent("Notification")))
    }

    @Test func eventNameKeysAreCaseAndSeparatorInsensitive() {
        #expect(EventName.key("UserPromptSubmit") == "userpromptsubmit")
        #expect(EventName.key("user_prompt_submit") == "userpromptsubmit")
        #expect(EventName.key("session.status") == "sessionstatus")
        #expect(EventName.key("post_cascade_response") == "postcascaderesponse")
        #expect(EventName.key("Ünïcode-Name") == "ncodename")
    }

    @Test func unknownAgentAndUnknownEventAreDropped() {
        var harness = PipelineHarness()
        #expect(harness.send("no-such-agent", "Stop", #"{"session_id":"s"}"#) == .dropped(.unknownAgent("no-such-agent")))
        #expect(harness.send("claude", "Bogus", #"{"session_id":"s"}"#) == .dropped(.unknownEvent("Bogus")))
        #expect(harness.send("claude", "Stop", "not json at all").event?.event == .turnFinished(.completed),
                "a malformed payload is an empty payload, never a crash")
        // 5 s later (an identical event at the same instant would be a consecutive duplicate).
        #expect(harness.send("claude", "Stop", "[1,2,3]", at: 5).event?.event == .turnFinished(.completed))
        #expect(harness.send("claude", "Stop", #"{"session_id":7}"#, at: 10).event?.sessionKey == SessionKey(agent: .claude, id: "7"),
                "numeric ids are rendered, never dropped")
        #expect(harness.send("claude", "Stop", #"{"session_id":true}"#, at: 15).event?.sessionKey.id.hasPrefix("ppid:") == true,
                "a boolean is never an identifier")
    }

    @Test func unknownArgvLabelFallsBackToEnvMarkers() throws {
        var harness = PipelineHarness()
        let cursor = try harness.accept("some-wrapper", "stop", #"{"conversation_id":"c9","status":"completed"}"#, env: ["CURSOR_VERSION": "2.6.11"])
        #expect(cursor.agent == .cursor)
        #expect(cursor.sessionKey == SessionKey(agent: .cursor, id: "c9"))
        let claude = try harness.accept("x", "Stop", #"{"session_id":"s9"}"#, env: ["AI_AGENT": "claude-code_2-1-288_harness"], at: 5)
        #expect(claude.agent == .claude)
        let droid = try harness.accept("y", "Stop", #"{"session_id":"d9"}"#, env: ["FACTORY_PROJECT_DIR": "/p"], at: 10)
        #expect(droid.agent == .droid)
    }

    @Test func claudeFormatHookRunByCursorUsesCursorPayload() throws {
        var harness = PipelineHarness()
        let event = try harness.accept("claude", "Stop",
                                       #"{"conversation_id":"cur-1","generation_id":"g5","cursor_version":"2.6","status":"aborted","hook_event_name":"stop"}"#,
                                       env: ["CURSOR_VERSION": "2.6.11"])
        #expect(event.agent == .cursor)
        #expect(event.argvAgentLabel == "claude")
        #expect(event.metadata[MetadataKey.relabelledFrom] == "claude")
        #expect(event.event == .turnFinished(.interrupted))
        #expect(event.sessionKey == SessionKey(agent: .cursor, id: "cur-1"))
        #expect(event.turnID == "g5")
    }
}
