import KakurenekoKit
import Foundation

/// Cursor IDE agent + CLI `agent`/`cursor-agent` (brief §3.3 row 6, R03 §6, R05 §3.2). Session key =
/// `conversation_id`; `generation_id` changes per user message (turn id).
///
/// | Raw | Normalized |
/// |---|---|
/// | `sessionStart` | sessionStarted |
/// | `beforeSubmitPrompt` | turnStarted (the hook itself answers `{"continue":true}`) |
/// | `postToolUse` and the other after-hooks | activity |
/// | `stop` `status`: `completed` → completed, `aborted` → interrupted, `error` → error |
/// | `sessionEnd` | sessionEnded |
struct CursorNormalizer: EventNormalizer {
    func normalize(_ input: NormalizationInput) -> NormalizedFields? {
        let payload = input.payload
        var fields: NormalizedFields
        switch input.key {
        case "sessionstart":
            fields = NormalizedFields(.sessionStarted)
            if let mode = payload.string("composer_mode") { fields.metadata[MetadataKey.cursorComposerMode] = mode }
        case "beforesubmitprompt":
            fields = NormalizedFields(.turnStarted)
        case "posttooluse", "posttoolusefailure", "aftershellexecution", "aftermcpexecution", "afterfileedit",
             "afteragentresponse", "afteragentthought", "subagentstop", "precompact":
            fields = NormalizedFields(.activity)
        case "stop":
            fields = NormalizedFields(.turnFinished(Self.outcome(payload.string("status"))))
        case "sessionend":
            fields = NormalizedFields(.sessionEnded)
            if let reason = payload.string("reason") { fields.metadata[MetadataKey.sessionEndReason] = reason }
        default:
            return nil
        }
        fields.sessionID = payload.string("conversation_id", "conversationId", "session_id")
        fields.turnID = payload.string("generation_id")
        fields.cwd = payload.strings("workspace_roots").first ?? input.environment["CURSOR_PROJECT_DIR"]
        fields.transcriptPath = payload.commonTranscriptPath
        return fields
    }

    static func outcome(_ status: String?) -> TurnOutcome {
        switch status?.lowercased() {
        case "aborted", "cancelled", "canceled": .interrupted
        case "error", "failed": .error
        default: .completed
        }
    }
}
