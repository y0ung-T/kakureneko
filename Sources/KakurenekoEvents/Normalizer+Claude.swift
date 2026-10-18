import KakurenekoKit
import Foundation

/// Claude Code plugin hooks (brief §3.3 row 1, R02 §1.2–1.4) with the binding corrections of ARCHITECTURE §9.1:
///
/// | Raw | Normalized |
/// |---|---|
/// | `SessionStart` | sessionStarted (+ `claude.sessionStartSource` = `source`: startup/resume/clear/compact) |
/// | `UserPromptSubmit` | turnStarted |
/// | `Stop` | turnFinished(completed) (+ preview; a running subagent/workflow/monitor/teammate → background) |
/// | `StopFailure` | `rate_limit` → turnFinished(rateLimited), else turnFinished(error); `error` → errorDetail |
/// | `Notification` | `permission_prompt`/`worker_permission_prompt` → needsInput(permission), `elicitation_dialog`/`elicitation_url_dialog` → needsInput(question), `agent_needs_input` → needsInput(unknown), `idle_prompt` → idleReminder, `agent_completed` → activity, `quota_auto_resume_fired` → turnStarted, `quota_auto_resume_stale`/`_disabled` → needsInput(unknown); other types dropped |
/// | `PermissionRequest` | needsInput(permission) (never installed for Claude; family agents use it) |
/// | `SessionEnd` | sessionEnded |
/// | tool / subagent / compaction / task events | activity |
struct ClaudeNormalizer: EventNormalizer {
    func normalize(_ input: NormalizationInput) -> NormalizedFields? {
        guard var fields = ClaudeStyle.normalize(input) else { return nil }
        if case .turnFinished(.completed) = fields.event, input.payload.has("cursor_version"),
           let status = input.payload.string("status") {
            // Cursor runs Claude-format hooks with its own payload: `stop.status` completed/aborted/error.
            fields.event = .turnFinished(CursorNormalizer.outcome(status))
        }
        fields.turnID = input.payload.string("prompt_id") ?? input.payload.string("generation_id")
        if let mode = input.payload.string("permission_mode") { fields.metadata[MetadataKey.claudePermissionMode] = mode }
        if let agentType = input.payload.string("agent_type") { fields.metadata[MetadataKey.claudeAgentType] = agentType }
        return fields
    }
}

/// The Claude hook vocabulary, shared by Claude Code, the Claude-compatible family and the generic fallback.
enum ClaudeStyle {
    static func normalize(_ input: NormalizationInput) -> NormalizedFields? {
        let payload = input.payload
        var fields: NormalizedFields
        switch input.key {
        case "sessionstart":
            fields = NormalizedFields(.sessionStarted)
            if let source = payload.string("source") { fields.metadata[MetadataKey.claudeSessionStartSource] = source }
            fields.title = payload.string("session_title")
        case "userpromptsubmit":
            fields = NormalizedFields(.turnStarted)
            fields.title = payload.string("session_title")
        case "stop":
            fields = NormalizedFields(.turnFinished(.completed))
            fields.messagePreview = payload.commonLastMessage
            fields.backgroundTasksRunning = runningBackgroundWork(payload)
        case "stopfailure":
            let error = payload.string("error")
            fields = NormalizedFields(.turnFinished(isRateLimit(error) ? .rateLimited : .error))
            fields.errorDetail = error
        case "notification":
            guard let mapped = notification(payload) else { return nil }
            fields = mapped
        case "permissionrequest":
            fields = NormalizedFields(.needsInput(.permission))
            fields.waitingFor = toolDescription(payload)
        case "sessionend":
            fields = NormalizedFields(.sessionEnded)
            if let reason = payload.string("reason") { fields.metadata[MetadataKey.sessionEndReason] = reason }
        case "pretooluse", "posttooluse", "posttoolusefailure", "posttoolbatch", "subagentstart", "subagentstop",
             "precompact", "postcompact", "taskcreated", "taskcompleted", "teammateidle", "cwdchanged",
             "userpromptexpansion":
            fields = NormalizedFields(.activity)
        default:
            return nil
        }
        fields.fillCommon(from: payload)
        return fields
    }

    /// `Notification.notification_type` (R02 §1.4 + ARCHITECTURE §9.1 corrections).
    static func notification(_ payload: RawPayload) -> NormalizedFields? {
        let message = payload.string("message")
        let type = payload.string("notification_type", "notificationType")?.lowercased()
        var fields: NormalizedFields
        switch type {
        case "permission_prompt", "worker_permission_prompt":
            fields = NormalizedFields(.needsInput(.permission))
        case "elicitation_dialog", "elicitation_url_dialog":
            fields = NormalizedFields(.needsInput(.question))
        case "agent_needs_input":
            fields = NormalizedFields(.needsInput(.unknown))
        case "idle_prompt":
            fields = NormalizedFields(.idleReminder)
        case "agent_completed":
            // A background agent finished: progress, not the end of the foreground turn.
            fields = NormalizedFields(.activity)
        case "quota_auto_resume_fired":
            // Claude resumed WORK after a usage-limit wait.
            fields = NormalizedFields(.turnStarted)
        case "quota_auto_resume_stale", "quota_auto_resume_disabled":
            // The limit reset but Claude waits for Enter.
            fields = NormalizedFields(.needsInput(.unknown))
        case nil:
            // Builds without `notification_type`: infer from the fixed message texts.
            let text = message?.lowercased() ?? ""
            if text.contains("permission") {
                fields = NormalizedFields(.needsInput(.permission))
            } else if text.contains("waiting for your input") {
                fields = NormalizedFields(.idleReminder)
            } else {
                return nil
            }
        default:
            return nil
        }
        if case .needsInput = fields.event { fields.waitingFor = message ?? payload.string("title") }
        return fields
    }

    /// Claude `Stop.background_tasks`: a running subagent / workflow / teammate keeps the session working. Ignored:
    /// shell tasks (the Monitor tool is one), monitors (passive watchers, e.g. the comment watch Claude Code keeps on a
    /// published artifact, which never ends on its own; if one fires, the agent starts a new turn), cloud sessions and
    /// MCP tasks. A task without a status counts as running.
    static func runningBackgroundWork(_ payload: RawPayload) -> Bool {
        let relevant: Set<String> = ["subagent", "workflow", "teammate"]
        let running: Set<String> = ["running", "pending", "queued", "in_progress", "active", "started", "waiting"]
        return payload.objects("background_tasks").contains { task in
            guard let type = task.string("type")?.lowercased(), relevant.contains(type) else { return false }
            guard let status = task.string("status")?.lowercased() else { return true }
            return running.contains(status)
        }
    }

    /// `StopFailure.error == rate_limit` (R02 §1.2).
    static func isRateLimit(_ error: String?) -> Bool {
        guard let error = error?.lowercased() else { return false }
        return error == "rate_limit" || error == "rate_limited"
    }

    /// `tool_input.description` (Codex) or the tool name, for the needs-input text.
    static func toolDescription(_ payload: RawPayload) -> String? {
        if let description = payload.object("tool_input")?.string("description") { return description }
        return payload.string("tool_name", "toolName").map { "Permission for \($0)" }
    }
}
