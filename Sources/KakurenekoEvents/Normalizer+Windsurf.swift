import KakurenekoKit
import Foundation

/// Windsurf / Devin Desktop Cascade hooks (brief §3.4, R05 §3.8). No needs-input event exists.
///
/// | Raw | Normalized |
/// |---|---|
/// | `pre_user_prompt` | turnStarted |
/// | `post_cascade_response` / `post_cascade_response_with_transcript` | turnFinished(completed) |
/// | `post_run_command` and the other pre/post tool hooks | activity |
///
/// Session key = `trajectory_id`; turn id = `execution_id`.
struct WindsurfNormalizer: EventNormalizer {
    func normalize(_ input: NormalizationInput) -> NormalizedFields? {
        let payload = input.payload
        let toolInfo = payload.object("tool_info")
        var fields: NormalizedFields
        switch input.key {
        case "preuserprompt":
            fields = NormalizedFields(.turnStarted)
        case "postcascaderesponse", "postcascaderesponsewithtranscript":
            fields = NormalizedFields(.turnFinished(.completed))
            fields.messagePreview = toolInfo?.string("response")
            fields.transcriptPath = toolInfo?.string("transcript_path")
        case "postruncommand", "preruncommand", "prereadcode", "postreadcode", "prewritecode", "postwritecode",
             "premcptooluse", "postmcptooluse", "postsetupworktree":
            fields = NormalizedFields(.activity)
        default:
            return nil
        }
        fields.sessionID = payload.string("trajectory_id", "trajectoryId")
        fields.turnID = payload.string("execution_id", "executionId")
        fields.cwd = toolInfo?.string("cwd") ?? payload.string("cwd")
        return fields
    }
}
