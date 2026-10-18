import KakurenekoKit
import Foundation

/// Antigravity CLI `agy` (brief §3.3 row 4, R03 §4). Only `Stop` is installed; busy and needs-input come from T3.
///
/// | Raw | Normalized |
/// |---|---|
/// | `Stop` `{conversationId, workspacePaths, transcriptPath, terminationReason, error?, fullyIdle}` | turnFinished: `error` / failing reason → error, cancel/interrupt/abort → interrupted, quota/rate → rateLimited, else completed; `fullyIdle == false` → background work still running |
/// | `PreToolUse`/`PostToolUse`/`PreInvocation`/`PostInvocation` | activity |
/// | status-line updates (`agent_state`, `tool_confirmation_pending`, v1.1) | pending confirmation → needsInput(permission); `thinking`/`working`/`tool_use` → activity |
struct AgyNormalizer: EventNormalizer {
    func normalize(_ input: NormalizationInput) -> NormalizedFields? {
        let payload = input.payload
        var fields: NormalizedFields
        switch input.key {
        case "stop":
            fields = NormalizedFields(.turnFinished(Self.outcome(payload)))
            if payload.bool("fullyIdle") == false { fields.backgroundTasksRunning = true }
            fields.errorDetail = payload.string("error")
            if let reason = payload.string("terminationReason") { fields.metadata[MetadataKey.agyTerminationReason] = reason }
        case "pretooluse", "posttooluse", "preinvocation", "postinvocation":
            fields = NormalizedFields(.activity)
        case "statusline", "status", "title":
            if payload.bool("tool_confirmation_pending") == true {
                fields = NormalizedFields(.needsInput(.permission))
            } else if let state = payload.string("agent_state")?.lowercased(),
                      ["thinking", "working", "tool_use"].contains(state) {
                fields = NormalizedFields(.activity)
            } else {
                return nil
            }
        default:
            return nil
        }
        fields.sessionID = payload.string("conversationId", "conversation_id", "session_id")
        fields.cwd = payload.strings("workspacePaths").first ?? payload.object("workspace")?.string("current_dir")
            ?? payload.string("cwd")
        fields.transcriptPath = payload.string("transcriptPath", "transcript_path")
        return fields
    }

    static func outcome(_ payload: RawPayload) -> TurnOutcome {
        if payload.string("error") != nil { return .error }
        let reason = payload.string("terminationReason")?.lowercased() ?? ""
        if reason.contains("quota") || reason.contains("rate") { return .rateLimited }
        if reason.contains("cancel") || reason.contains("interrupt") || reason.contains("abort") {
            return .interrupted
        }
        if reason.contains("error") || reason.contains("fail") { return .error }
        return .completed
    }
}
