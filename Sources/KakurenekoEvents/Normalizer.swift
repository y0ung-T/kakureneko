import KakurenekoKit
import Foundation

/// What a per-agent normalizer extracts from one raw hook event (brief §3.3/§3.4). Strings are RAW here; the
/// pipeline caps and sanitizes them before they leave the module.
struct NormalizedFields: Sendable {
    var event: NormalizedEvent
    /// Session id from the PAYLOAD (`session_id`, `thread-id`, `conversation_id`, `taskId`, `trajectory_id`, …).
    var sessionID: String?
    var turnID: String?
    var cwd: String?
    var title: String?
    /// Last assistant message (sanitized to a ≤ 140-char preview by the pipeline).
    var messagePreview: String?
    /// Needs-input text (`Notification.message`, …).
    var waitingFor: String?
    var errorDetail: String?
    var transcriptPath: String?
    var backgroundTasksRunning = false
    var metadata: [String: String] = [:]
    /// Droid: `Notification idle_prompt` replaces `Stop` on cancel → the pipeline turns this `idleReminder` into
    /// `turnFinished(.interrupted)` when the session's turn is still open.
    var idlePromptMayEndOpenTurn = false
    /// opencode/Kilo plugin events are rolled up per agent process (`OpenCodeRollup`) instead of mapped 1:1.
    var openCode: OpenCodeSignal?

    init(_ event: NormalizedEvent) {
        self.event = event
    }
}

/// Inputs every normalizer sees.
struct NormalizationInput: Sendable {
    /// Raw event name: argv `<event>` first; the pipeline retries with the payload's own event name when the
    /// argv name is unknown (`hook_event_name`, `hookEventName`, `event`, `type`, …).
    var eventName: String
    var payload: RawPayload
    /// Allow-listed hook environment.
    var environment: [String: String]

    /// Canonical form of `eventName` (lowercased, separators removed): `UserPromptSubmit`, `userPromptSubmit`,
    /// `user_prompt_submit` and `session.status` → `userpromptsubmit` / `sessionstatus`.
    var key: String { EventName.key(eventName) }
}

/// One agent family's raw → `NormalizedEvent` table. Returning nil drops the event (unknown event name, or a
/// raw event that carries no state change).
protocol EventNormalizer: Sendable {
    func normalize(_ input: NormalizationInput) -> NormalizedFields?
}

enum EventName {
    /// Lowercased with every non-alphanumeric character removed.
    static func key(_ name: String) -> String {
        String(String.UnicodeScalarView(name.lowercased().unicodeScalars.filter {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0))
        }))
    }

    /// Event-name fields agents put in their payloads (C15: argv is primary, these are the fallback).
    static let payloadKeys = ["hook_event_name", "hookEventName", "event", "event_type", "hookName", "type",
                              "agent_action_name"]
}

/// Normalizer registry keyed by the DELIVERING integration (the argv label): the event names in argv were
/// written by that integration's installer, even when attribution later relabels the agent (a Copilot-file
/// event run by VS Code, a Claude-format hook run by Cursor).
enum Normalizers {
    static func normalizer(for agent: AgentID) -> (any EventNormalizer)? {
        switch agent {
        case .claude: ClaudeNormalizer()
        case .codex: CodexNormalizer()
        case .gemini: GeminiNormalizer()
        case .agy: AgyNormalizer()
        case .copilot, .vscode: CopilotNormalizer()
        case .cursor: CursorNormalizer()
        case .opencode, .kilo: OpenCodeNormalizer()
        case .aider: AiderNormalizer()
        case .cline: ClineNormalizer()
        case .windsurf: WindsurfNormalizer()
        case .droid, .qwen, .auggie, .qoder, .codebuddy, .iflow, .devin: ClaudeFamilyNormalizer(agent: agent)
        case .unknown: nil
        default: GenericNormalizer(agent: agent)
        }
    }
}

// MARK: - Shared extraction helpers

extension RawPayload {
    /// Common session-id spellings across agents.
    var commonSessionID: String? {
        string("session_id", "sessionId", "sessionID", "conversation_id", "conversationId", "thread-id",
               "thread_id", "threadId", "taskId", "task_id", "trajectory_id", "trajectoryId")
    }

    /// Common working-directory spellings (`cwd`, `working_dir`, first workspace root).
    var commonCwd: String? {
        if let cwd = string("cwd", "working_dir", "workingDirectory", "workspaceRoot", "directory") { return cwd }
        for key in ["workspace_roots", "workspaceRoots", "workspacePaths"] {
            if let first = strings(key).first { return first }
        }
        return object("workspaceInfo")?.string("rootPath")
    }

    var commonTranscriptPath: String? { string("transcript_path", "transcriptPath", "agent_transcript_path") }

    var commonLastMessage: String? {
        string("last_assistant_message", "last-assistant-message", "lastAssistantMessage", "prompt_response",
               "assistant_response")
    }
}

extension NormalizedFields {
    /// Fills the fields every Claude-style payload carries (session, cwd, transcript).
    mutating func fillCommon(from payload: RawPayload) {
        if sessionID == nil { sessionID = payload.commonSessionID }
        if cwd == nil { cwd = payload.commonCwd }
        if transcriptPath == nil { transcriptPath = payload.commonTranscriptPath }
    }
}
