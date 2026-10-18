import KakurenekoKit
import Foundation

/// Every other known agent label (Grok, Kimi, Goose, Kiro, OpenHands, Vibe, Amp, Pi, Hermes, Junie, Crush, Rovo,
/// Continue, …): no v1 installer, but users (or v1.1 installers) can wire them to the same hook. The normalization
/// map of R04 §7.3 first, then the Claude vocabulary (most of the long tail copies Claude's event names).
///
/// | Raw (canonical key) | Normalized |
/// |---|---|
/// | `agentSpawn`, `session.start`, `session_start`, `on_session_start` | sessionStarted |
/// | `TurnStarted`, `agent.start`, `before_agent_start`, `pre_llm_call`, `on_user_prompt`, `PromptSubmit`, `TaskStart`/`TaskResume` | turnStarted |
/// | `pre_tool`/`post_tool`, `tool.call`/`tool.result`, `SessionHeartbeat`, `TaskStarted`, `on_tool_start`/`on_tool_end`, Kiro file/task hooks, `session_compact` | activity |
/// | `agent.end` (`status` done/error/cancelled), `post_agent`, `post_llm_call`, `on_complete`, `task.complete` | turnFinished |
/// | `agent_error`, `on_error`, `session.error` | turnFinished(error) |
/// | `Interrupt`, `TaskCancel`, `agent_abort` | turnFinished(interrupted) |
/// | `permission.asked`, `on_tool_permission`, `pre_approval_request`, `permission.request` | needsInput(permission) |
/// | `question.asked`, `input.required` | needsInput(question) |
/// | `session_shutdown`, `session.deleted`, `on_session_finalize`, `session.end`; `on_session_end` except Hermes | sessionEnded |
/// | Kimi `Notification{task.completed}` | activity |
///
/// Hermes fires `on_session_end` after EVERY turn (its real end is `on_session_finalize`), so it is dropped there.
struct GenericNormalizer: EventNormalizer {
    let agent: AgentID

    func normalize(_ input: NormalizationInput) -> NormalizedFields? {
        let payload = input.payload
        var fields: NormalizedFields
        switch input.key {
        case "onsessionend":
            guard agent != .hermes else { return nil }
            fields = NormalizedFields(.sessionEnded)
        case "agentspawn", "onsessionstart":
            fields = NormalizedFields(.sessionStarted)
        case "turnstarted", "agentstart", "beforeagentstart", "prellmcall", "onuserprompt", "promptsubmit",
             "taskresume", "taskstart":
            fields = NormalizedFields(.turnStarted)
        case "pretool", "posttool", "sessionheartbeat", "toolcall", "toolresult", "taskstarted", "ontoolstart",
             "ontoolend", "postfilecreate", "postfilesave", "postfiledelete", "pretaskexec", "posttaskexec",
             "sessioncompact":
            fields = NormalizedFields(.activity)
        case "agentend":
            // Amp `agent.end.status` ∈ done | error | cancelled; Pi `agent_end`.
            switch payload.string("status")?.lowercased() {
            case "error", "failed": fields = NormalizedFields(.turnFinished(.error))
            case "cancelled", "canceled", "aborted": fields = NormalizedFields(.turnFinished(.interrupted))
            default: fields = NormalizedFields(.turnFinished(.completed))
            }
            fields.messagePreview = payload.commonLastMessage
        case "postagent", "postllmcall", "oncomplete", "taskcomplete":
            fields = NormalizedFields(.turnFinished(.completed))
            fields.messagePreview = payload.commonLastMessage
        case "agenterror", "taskerror", "sessionerror", "onerror":
            fields = NormalizedFields(.turnFinished(.error))
            fields.errorDetail = payload.object("error")?.string("message", "name") ?? payload.string("error")
        case "interrupt", "taskcancel", "agentabort":
            fields = NormalizedFields(.turnFinished(.interrupted))
        case "permissionasked", "ontoolpermission", "preapprovalrequest":
            fields = NormalizedFields(.needsInput(.permission))
            fields.waitingFor = payload.string("message", "title")
        case "questionasked", "inputrequired":
            fields = NormalizedFields(.needsInput(.question))
            fields.waitingFor = payload.string("message", "title")
        case "sessionshutdown", "sessiondeleted", "onsessionfinalize":
            fields = NormalizedFields(.sessionEnded)
        case "notification" where Self.isTaskCompleted(payload):
            // Kimi `Notification{task.completed}`: background work finished — progress, not a turn end.
            fields = NormalizedFields(.activity)
        default:
            guard let claudeStyle = ClaudeStyle.normalize(input) else { return nil }
            fields = claudeStyle
        }
        fields.fillCommon(from: payload)
        if fields.turnID == nil { fields.turnID = payload.string("turn_id", "turnId") }
        return fields
    }

    static func isTaskCompleted(_ payload: RawPayload) -> Bool {
        let type = payload.string("notification_type", "type")?.lowercased()
        return type == "task.completed" || type == "task_completed"
    }
}
