import KakurenekoKit
import Foundation

/// Cline CLI / extension file hooks (brief §3.4, C14, R04 §3.8, R05 §3.5). argv = the hook file name; the SDK
/// payload's `hookName` uses the snake_case names, accepted as well. The hook itself answers `{"cancel":false}`.
///
/// | Raw | Normalized |
/// |---|---|
/// | `TaskStart` / `agent_start`, `TaskResume` / `agent_resume`, `UserPromptSubmit` / `prompt_submit` | turnStarted |
/// | `TaskComplete` / `agent_end` | turnFinished(completed) |
/// | `TaskCancel` / `agent_abort` | turnFinished(interrupted) |
/// | `TaskError` / `agent_error` | turnFinished(error) |
/// | `PreToolUse`/`PostToolUse` (`tool_call`/`tool_result`), `PreCompact` | activity |
/// | `SessionShutdown` / `session_shutdown` | sessionEnded |
///
/// Session key = `taskId` (falls back to `sessionContext.rootSessionId`).
struct ClineNormalizer: EventNormalizer {
    func normalize(_ input: NormalizationInput) -> NormalizedFields? {
        let payload = input.payload
        var fields: NormalizedFields
        switch input.key {
        case "taskstart", "agentstart", "taskresume", "agentresume", "userpromptsubmit", "promptsubmit":
            fields = NormalizedFields(.turnStarted)
        case "taskcomplete", "agentend":
            fields = NormalizedFields(.turnFinished(.completed))
        case "taskcancel", "agentabort":
            fields = NormalizedFields(.turnFinished(.interrupted))
        case "taskerror", "agenterror":
            fields = NormalizedFields(.turnFinished(.error))
            fields.errorDetail = payload.object("error")?.string("message", "name") ?? payload.string("error")
        case "pretooluse", "posttooluse", "toolcall", "toolresult", "precompact":
            fields = NormalizedFields(.activity)
        case "sessionshutdown":
            fields = NormalizedFields(.sessionEnded)
        default:
            return nil
        }
        fields.sessionID = payload.string("taskId", "task_id") ?? payload.object("sessionContext")?.string("rootSessionId")
        fields.cwd = payload.strings("workspaceRoots").first ?? payload.object("workspaceInfo")?.string("rootPath")
        return fields
    }
}
