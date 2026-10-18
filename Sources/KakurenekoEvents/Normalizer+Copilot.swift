import KakurenekoKit
import Foundation

/// GitHub Copilot CLI + the VS Code Local harness reading the same `~/.copilot/hooks/kakureneko.json` (brief §3.3
/// row 5, C7, R03 §5, R05 §3.3). argv carries the Copilot (lowerCamelCase) name; VS Code sends a snake_case
/// payload with a PascalCase `hook_event_name`, so both spellings are accepted.
///
/// | Raw | Normalized |
/// |---|---|
/// | `sessionStart` / `SessionStart` | sessionStarted |
/// | `userPromptSubmitted` / `UserPromptSubmit` | turnStarted |
/// | `agentStop` / `Stop` | turnFinished(completed) (`stopReason` other than `end_turn` → interrupted/error) |
/// | `errorOccurred` | turnFinished(error) |
/// | `notification` `permission_prompt` → needsInput(permission), `elicitation_dialog` → needsInput(question), `agent_idle` → idleReminder, `agent_completed` → activity |
/// | `sessionEnd` / `SessionEnd` | sessionEnded |
/// | tool / subagent / compaction hooks | activity |
struct CopilotNormalizer: EventNormalizer {
    func normalize(_ input: NormalizationInput) -> NormalizedFields? {
        let payload = input.payload
        var fields: NormalizedFields
        switch input.key {
        case "sessionstart":
            fields = NormalizedFields(.sessionStarted)
            if let source = payload.string("source") { fields.metadata[MetadataKey.copilotSessionStartSource] = source }
        case "userpromptsubmitted", "userpromptsubmit", "userprompttransformed":
            fields = NormalizedFields(.turnStarted)
        case "agentstop", "stop":
            fields = NormalizedFields(.turnFinished(Self.stopOutcome(payload.string("stopReason", "stop_reason"))))
            fields.messagePreview = payload.commonLastMessage
        case "erroroccurred":
            fields = NormalizedFields(.turnFinished(.error))
            fields.errorDetail = payload.object("error")?.string("message", "name") ?? payload.string("error", "message")
        case "notification":
            let message = payload.string("message")
            switch payload.string("notification_type", "notificationType")?.lowercased() {
            case "permission_prompt":
                fields = NormalizedFields(.needsInput(.permission))
                fields.waitingFor = message ?? payload.string("title")
            case "elicitation_dialog":
                fields = NormalizedFields(.needsInput(.question))
                fields.waitingFor = message ?? payload.string("title")
            case "agent_idle":
                fields = NormalizedFields(.idleReminder)
            case "agent_completed":
                fields = NormalizedFields(.activity)
            default:
                return nil
            }
        case "sessionend":
            fields = NormalizedFields(.sessionEnded)
            if let reason = payload.string("reason") { fields.metadata[MetadataKey.sessionEndReason] = reason }
        case "pretooluse", "premcptoolcall", "posttooluse", "posttoolusefailure", "subagentstart", "subagentstop",
             "precompact":
            fields = NormalizedFields(.activity)
        default:
            return nil
        }
        fields.fillCommon(from: payload)
        return fields
    }

    static func stopOutcome(_ reason: String?) -> TurnOutcome {
        switch reason?.lowercased() {
        case nil, "end_turn", "endturn", "complete", "completed", "stop": .completed
        case "error", "failed", "failure": .error
        case "abort", "aborted", "cancelled", "canceled", "interrupted", "user_exit": .interrupted
        default: .completed
        }
    }

    /// VS Code Local payload shape: a PascalCase `hook_event_name` with snake_case fields. Copilot CLI's camelCase
    /// events carry camelCase fields (`sessionId`) — its `notification` payload ALSO has `hook_event_name:
    /// "Notification"`, so the camelCase session key rules the CLI back in. Used by attribution for the
    /// copilot → vscode relabel.
    static func isVSCodeLocalPayload(_ payload: RawPayload) -> Bool {
        guard let name = payload.string("hook_event_name"), let first = name.unicodeScalars.first,
              CharacterSet.uppercaseLetters.contains(first)
        else { return false }
        return !payload.has("sessionId")
    }
}
