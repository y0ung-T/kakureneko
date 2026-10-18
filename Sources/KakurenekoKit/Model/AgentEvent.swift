import Foundation

/// A normalized, attributed event (brief §3.1 + §4.4) — the unit KakurenekoEvents emits and
/// KakurenekoSessions ingests.
///
/// Producers: `EventInbox` (T1 hooks/plugins). KakurenekoSessions may also synthesize AgentEvents
/// internally, but cross-module T2/T3 inputs travel as `ClaudeStateSnapshot` / `ProcessSnapshot`.
///
/// Every string field is untrusted input already capped by the producer (≤ 1 KiB per field,
/// `messagePreview` ≤ 140 chars sanitized with `TextSanitizer`).
public struct AgentEvent: Sendable, Hashable, Codable, Identifiable {
    /// Unique id of this event: the inbox file name (`<ns>-<pid>.event`) for T1 events.
    public var id: String
    /// Attributed agent (env markers → ancestry signature → argv label, brief §4.4).
    public var agent: AgentID
    /// The agent label as given in argv (before attribution), e.g. `copilot` relabelled to `vscode`.
    public var argvAgentLabel: String
    public var event: NormalizedEvent
    /// Raw event name from argv (`Stop`, `notify`, `session.status`, …).
    public var rawEventName: String
    /// Session the event belongs to: `session_id` | `thread-id` | `conversation_id` | … ; fallback
    /// `SessionKey.fallback(agent:identity:)` from the bound agent process.
    public var sessionKey: SessionKey
    /// The agent process bound from the ancestry (`CLAUDE_PID` / first ancestor matching a signature).
    public var agentProcess: ProcessIdentity?
    /// Host app from `__CFBundleIdentifier` / `TERM_PROGRAM` / ancestry.
    public var host: HostApp?
    /// Best-known working directory of the session (payload `cwd` beats the hook's cwd).
    public var cwd: String?
    /// Human title if the payload carries one.
    public var title: String?
    /// Sanitized preview of the last assistant message (≤ 140 chars). Shown only at `DetailLevel.detailed`.
    public var messagePreview: String?
    /// Needs-input text (`Notification.message`, `waitingFor`), sanitized, ≤ 140 chars.
    public var waitingFor: String?
    /// Turn id for dedupe (Codex `turn-id` collapses `notify` + `Stop`).
    public var turnID: String?
    /// True when the finishing turn still has running background work (Claude `Stop.background_tasks`
    /// containing a running subagent/workflow/monitor/teammate; Qwen `background_tasks`/`crons` non-empty).
    /// The engine keeps the session `working`.
    public var backgroundTasksRunning: Bool
    /// Error detail for `turnFinished(.error/.rateLimited)` (e.g. `rate_limit`), sanitized.
    public var errorDetail: String?
    /// Transcript path from the payload (Claude `transcript_path`), for title/duration helpers.
    public var transcriptPath: String?
    /// Tier that produced the event (T1 for inbox events).
    public var tier: Tier
    /// When the agent emitted it (inbox header `ts`).
    public var occurredAt: Date
    /// When Kakureneko accepted it.
    public var receivedAt: Date
    /// Small agent-specific extras, ≤ 16 entries, keys namespaced (`claude.entrypoint`, `codex.client`,
    /// `claude.permissionMode`, `opencode.childSession`). Escape hatch so normalizers never need a contract change.
    public var metadata: [String: String]

    public init(
        id: String,
        agent: AgentID,
        argvAgentLabel: String? = nil,
        event: NormalizedEvent,
        rawEventName: String,
        sessionKey: SessionKey,
        agentProcess: ProcessIdentity? = nil,
        host: HostApp? = nil,
        cwd: String? = nil,
        title: String? = nil,
        messagePreview: String? = nil,
        waitingFor: String? = nil,
        turnID: String? = nil,
        backgroundTasksRunning: Bool = false,
        errorDetail: String? = nil,
        transcriptPath: String? = nil,
        tier: Tier = .hook,
        occurredAt: Date,
        receivedAt: Date,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.agent = agent
        self.argvAgentLabel = argvAgentLabel ?? agent.rawValue
        self.event = event
        self.rawEventName = rawEventName
        self.sessionKey = sessionKey
        self.agentProcess = agentProcess
        self.host = host
        self.cwd = cwd
        self.title = title
        self.messagePreview = messagePreview
        self.waitingFor = waitingFor
        self.turnID = turnID
        self.backgroundTasksRunning = backgroundTasksRunning
        self.errorDetail = errorDetail
        self.transcriptPath = transcriptPath
        self.tier = tier
        self.occurredAt = occurredAt
        self.receivedAt = receivedAt
        self.metadata = metadata
    }

    /// Dedupe identity without the time component (brief §4.4: `(agent, sessionKey, normalizedEvent, ±2 s)`).
    public var dedupeIdentity: String {
        var parts = [agent.rawValue, sessionKey.id, event.typeName]
        switch event {
        case .turnFinished(let o): parts.append(o.rawValue)
        case .needsInput(let k): parts.append(k.rawValue)
        default: break
        }
        return parts.joined(separator: "|")
    }

    /// Dedupe window (brief §4.4).
    public static let dedupeWindow: TimeInterval = 2
}
