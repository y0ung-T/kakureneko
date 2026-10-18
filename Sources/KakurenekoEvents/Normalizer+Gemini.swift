import KakurenekoKit
import Foundation

/// Gemini CLI (brief §3.3 row 3, R03 §3):
///
/// | Raw | Normalized |
/// |---|---|
/// | `SessionStart` | sessionStarted |
/// | `BeforeAgent` | turnStarted |
/// | `AfterAgent` | turnFinished(completed) (preview = `prompt_response`) |
/// | `Notification` `notification_type: "ToolPermission"` | needsInput(permission) |
/// | `SessionEnd` | sessionEnded |
/// | `BeforeTool`/`AfterTool`/`BeforeModel`/`AfterModel`/`BeforeToolSelection`/`PreCompress` | activity |
///
/// Session key `session_id` (env `GEMINI_SESSION_ID` as a fallback, applied by the pipeline).
struct GeminiNormalizer: EventNormalizer {
    func normalize(_ input: NormalizationInput) -> NormalizedFields? {
        let payload = input.payload
        var fields: NormalizedFields
        switch input.key {
        case "sessionstart":
            fields = NormalizedFields(.sessionStarted)
            if let source = payload.string("source") { fields.metadata[MetadataKey.geminiSessionStartSource] = source }
        case "beforeagent":
            fields = NormalizedFields(.turnStarted)
        case "afteragent":
            fields = NormalizedFields(.turnFinished(.completed))
            fields.messagePreview = payload.string("prompt_response")
        case "notification":
            // Only "ToolPermission" exists today; an unknown type is never guessed into a needs-input push.
            guard payload.string("notification_type")?.lowercased() == "toolpermission" else { return nil }
            fields = NormalizedFields(.needsInput(.permission))
            fields.waitingFor = payload.string("message")
        case "sessionend":
            fields = NormalizedFields(.sessionEnded)
        case "beforetool", "aftertool", "beforemodel", "aftermodel", "beforetoolselection", "precompress":
            fields = NormalizedFields(.activity)
        default:
            return nil
        }
        fields.fillCommon(from: payload)
        if fields.cwd == nil { fields.cwd = input.environment["GEMINI_CWD"] }
        return fields
    }
}
