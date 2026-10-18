import KakurenekoKit
import Foundation

/// The Claude-compatible family installed through one generic routine (brief §3.4, R04 §3): Factory Droid,
/// Qwen Code, Augment Auggie, Qoder, CodeBuddy, iFlow, Devin. Claude event names, with these quirks:
///
/// * **Droid** — on cancel it sends `Notification idle_prompt` *instead of* `Stop`: an `idle_prompt` while the
///   session's turn is still open becomes turnFinished(interrupted) (done by the pipeline, which knows the turn).
/// * **Qwen** — `Stop.background_tasks` / `Stop.crons` non-empty → background work keeps the session working.
/// * **Auggie** — session id `conversation_id`; `Stop.agent_stop_cause` ∈ `end_turn`/`max_iterations` →
///   completed, `interrupted` → interrupted, `error` → error; `PromptSubmit` → turnStarted; its `Notification`
///   (`notification_type: "info"`) is not a needs-input signal → dropped.
struct ClaudeFamilyNormalizer: EventNormalizer {
    let agent: AgentID

    func normalize(_ input: NormalizationInput) -> NormalizedFields? {
        let payload = input.payload
        if agent == .auggie {
            switch input.key {
            case "promptsubmit":
                var fields = NormalizedFields(.turnStarted)
                fields.fillCommon(from: payload)
                return fields
            case "stop":
                var fields = NormalizedFields(.turnFinished(Self.auggieOutcome(payload.string("agent_stop_cause"))))
                fields.messagePreview = payload.commonLastMessage
                fields.fillCommon(from: payload)
                if let cause = payload.string("agent_stop_cause") { fields.metadata[MetadataKey.auggieStopCause] = cause }
                return fields
            case "notification":
                let type = payload.string("notification_type")?.lowercased()
                guard type == "permission_prompt" || type == "elicitation_dialog" else { return nil }
            default:
                break
            }
        }
        guard var fields = ClaudeStyle.normalize(input) else { return nil }
        switch (agent, fields.event) {
        case (.droid, .idleReminder):
            fields.idlePromptMayEndOpenTurn = true
        case (.qwen, .turnFinished):
            let tasks = payload.array("background_tasks") ?? []
            let crons = payload.array("crons") ?? []
            fields.backgroundTasksRunning = fields.backgroundTasksRunning || !tasks.isEmpty || !crons.isEmpty
        default:
            break
        }
        return fields
    }

    static func auggieOutcome(_ cause: String?) -> TurnOutcome {
        switch cause?.lowercased() {
        case "interrupted", "cancelled", "canceled", "aborted": .interrupted
        case "error": .error
        default: .completed
        }
    }
}
