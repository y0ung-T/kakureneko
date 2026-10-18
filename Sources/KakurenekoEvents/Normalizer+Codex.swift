import KakurenekoKit
import Foundation

/// OpenAI Codex (brief §3.3 row 2, C8, R03 §2):
///
/// | Raw | Normalized |
/// |---|---|
/// | `notify` `{"type":"agent-turn-complete","thread-id","turn-id","cwd","client","last-assistant-message"}` | turnFinished(completed) |
/// | `SessionStart` | sessionStarted |
/// | `UserPromptSubmit` | turnStarted |
/// | `Stop` | turnFinished(completed) — collapses with `notify` of the same `turn_id` (dedupe) |
/// | `Interrupt` | turnFinished(interrupted) |
/// | `PermissionRequest` | needsInput(permission) |
/// | `SessionEnd` | sessionEnded |
/// | tool / subagent / compaction hooks | activity |
///
/// Session key: `thread-id` (notify) == `session_id` (hooks), the same conversation id.
struct CodexNormalizer: EventNormalizer {
    func normalize(_ input: NormalizationInput) -> NormalizedFields? {
        let payload = input.payload
        var fields: NormalizedFields
        switch input.key {
        case "notify", "codexnotify", "agentturncomplete":
            let type = payload.string("type")?.lowercased()
            guard type == nil || type == "agent-turn-complete" else { return nil }
            fields = NormalizedFields(.turnFinished(.completed))
            fields.sessionID = payload.string("thread-id", "thread_id", "threadId")
            fields.turnID = payload.string("turn-id", "turn_id", "turnId")
            fields.messagePreview = payload.commonLastMessage
            if let client = payload.string("client") { fields.metadata[MetadataKey.codexClient] = client }
        case "sessionstart":
            fields = NormalizedFields(.sessionStarted)
            if let source = payload.string("source") { fields.metadata[MetadataKey.codexSessionStartSource] = source }
        case "userpromptsubmit":
            fields = NormalizedFields(.turnStarted)
        case "stop":
            fields = NormalizedFields(.turnFinished(.completed))
            fields.messagePreview = payload.commonLastMessage
        case "interrupt":
            fields = NormalizedFields(.turnFinished(.interrupted))
        case "permissionrequest":
            fields = NormalizedFields(.needsInput(.permission))
            fields.waitingFor = ClaudeStyle.toolDescription(payload)
        case "sessionend":
            fields = NormalizedFields(.sessionEnded)
        case "pretooluse", "posttooluse", "subagentstart", "subagentstop", "precompact", "postcompact":
            fields = NormalizedFields(.activity)
        default:
            return nil
        }
        if fields.turnID == nil { fields.turnID = payload.string("turn_id", "turn-id", "turnId") }
        fields.fillCommon(from: payload)
        return fields
    }
}
