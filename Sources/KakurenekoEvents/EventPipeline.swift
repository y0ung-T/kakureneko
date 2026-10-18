import KakurenekoKit
import Foundation

/// Turns one parsed inbox file into at most one `AgentEvent`: normalize (per delivering integration) → attribute
/// → session key → opencode roll-up → Droid open-turn rule → caps/sanitizing → dedupe.
///
/// Deterministic and synchronous; owned by `EventInbox` inside its `Mutex` and driven only from the serialized
/// drain, so its state needs no further locking. Tests drive it directly.
struct EventPipeline {
    enum DropReason: Equatable {
        /// argv label unknown and attribution found no agent either.
        case unknownAgent(String)
        /// The normalizer does not know this event (or it carries no state change, e.g. a Gemini Notification of
        /// an unknown type).
        case unknownEvent(String)
        /// opencode roll-up: a child-session change that does not change the process state.
        case noStateChange
        /// Consecutive duplicate / Codex notify+Stop of the same turn.
        case duplicate
    }

    enum Outcome: Equatable {
        case accepted(AgentEvent)
        case dropped(DropReason)

        var event: AgentEvent? {
            if case .accepted(let event) = self { return event }
            return nil
        }
    }

    /// Info.plist lookup for host attribution (`bundlePath` → `CFBundleIdentifier`).
    typealias BundleIdentifierLookup = @Sendable (String) -> String?

    /// Event timestamps later than this past `receivedAt` are clamped (a file cannot come from the future).
    static let maxClockSkew: TimeInterval = 5 * 60
    static let maxOpenTurns = 4_096
    static let maxBundleCacheEntries = 256

    let matcher: any AgentSignatureMatching
    private let lookupBundleIdentifier: BundleIdentifierLookup
    private(set) var dedupe = DedupeState()
    private(set) var openCode = OpenCodeRollup()
    /// A started, unfinished turn (for Droid's `idle_prompt`-instead-of-`Stop`).
    struct OpenTurn: Equatable {
        var startedAt: Date
        /// The agent asked for input during the turn (an `idle_prompt` then means "still waiting", not "cancelled").
        var waiting = false
    }

    /// Sessions with a started, unfinished turn.
    private(set) var openTurns: [SessionKey: OpenTurn] = [:]
    /// Proof of life per delivering integration (`AgentID(label: argv agent)`), every parsed file counts.
    var lastSeen: [AgentID: Date] = [:]
    private var bundleCache: [String: String] = [:]
    private var bundleMisses: Set<String> = []

    init(matcher: any AgentSignatureMatching, bundleIdentifierLookup: @escaping BundleIdentifierLookup = EventPipeline.liveBundleIdentifier) {
        self.matcher = matcher
        self.lookupBundleIdentifier = bundleIdentifierLookup
    }

    /// `Bundle(url:)?.bundleIdentifier` of an `.app` path.
    static let liveBundleIdentifier: BundleIdentifierLookup = { path in
        Bundle(url: URL(filePath: path, directoryHint: .isDirectory))?.bundleIdentifier
    }

    // MARK: - Processing

    mutating func process(id: String, header: InboxHeader, payload data: Data, receivedAt: Date) -> Outcome {
        let argvAgent = AgentID(label: header.agent)
        if argvAgent != .unknown { lastSeen[argvAgent] = max(lastSeen[argvAgent] ?? .distantPast, receivedAt) }

        let payload = RawPayload(data: data)
        var attribution = AttributionResolver.resolve(
            header: header, payload: payload, matcher: matcher, bundleLookup: { bundleIdentifier($0) })
        let family = argvAgent != .unknown ? argvAgent : attribution.agent
        guard family != .unknown, let normalizer = Normalizers.normalizer(for: family) else {
            return .dropped(.unknownAgent(String(header.agent.prefix(64))))
        }

        var input = NormalizationInput(eventName: header.event, payload: payload, environment: header.env)
        var normalized = normalizer.normalize(input)
        if normalized == nil, let alternative = payload.string(EventName.payloadKeys),
           EventName.key(alternative) != input.key {
            input.eventName = alternative
            normalized = normalizer.normalize(input)
        }
        guard var fields = normalized else { return .dropped(.unknownEvent(String(header.event.prefix(64)))) }

        let sessionKey: SessionKey
        if let signal = fields.openCode {
            // The plugin runs INSIDE opencode: the payload pid names the process that owns every session.
            let agent = family
            let anchor = OpenCodeNormalizer.processID(payload).flatMap { pid in header.ancestry.first { $0.pid == pid } }
            let identity = anchor?.identity
                ?? header.ancestry.first { matcher.match($0.descriptor)?.agent == agent }?.identity
            if attribution.agent != agent { attribution.relabelledFrom = nil }
            attribution.agent = agent
            attribution.agentProcess = identity
            sessionKey = identity.map { SessionKey.fallback(agent: agent, identity: $0) }
                ?? Self.openCodeSessionFallback(signal, agent: agent)
                ?? SessionKey(agent: agent, id: "ppid:\(header.ppid)")
            let rolled = openCode.apply(signal, key: sessionKey)
            guard let event = rolled.event else { return .dropped(.noStateChange) }
            fields.event = event
            if let root = rolled.rootSession { fields.metadata[MetadataKey.opencodeSessionID] = root }
            if let child = rolled.childSession { fields.metadata[MetadataKey.opencodeChildSession] = child }
        } else {
            sessionKey = Self.sessionKey(fields: fields, payload: payload, header: header, attribution: attribution)
        }

        if fields.idlePromptMayEndOpenTurn, case .idleReminder = fields.event,
           let open = openTurns[sessionKey], !open.waiting {
            // Droid sends `Notification idle_prompt` INSTEAD of `Stop` when the user cancels (brief §3.4).
            fields.event = .turnFinished(.interrupted)
        }

        let event = makeEvent(id: id, header: header, fields: fields, attribution: attribution,
                              sessionKey: sessionKey, receivedAt: receivedAt)
        guard dedupe.accept(event) else { return .dropped(.duplicate) }
        trackTurn(event)
        return .accepted(event)
    }

    // MARK: - Session key (ARCHITECTURE §8)

    /// Payload id → agent env id (never inherited from another agent) → process fallback → hook parent.
    static func sessionKey(fields: NormalizedFields, payload: RawPayload, header: InboxHeader,
                           attribution: Attribution) -> SessionKey {
        let agent = attribution.agent
        var sessionID = FieldLimits.capped(fields.sessionID)
        if agent == .cursor, let conversation = FieldLimits.capped(payload.string("conversation_id", "conversationId")) {
            // Claude-format hooks run by Cursor carry Cursor's conversation id; one key per conversation.
            sessionID = conversation
        }
        if let sessionID { return SessionKey(agent: agent, id: sessionID) }
        if let envID = environmentSessionID(agent: agent, env: header.env, attribution: attribution) {
            return SessionKey(agent: agent, id: envID)
        }
        if let identity = attribution.agentProcess ?? attribution.fallbackIdentity {
            return SessionKey.fallback(agent: agent, identity: identity)
        }
        return SessionKey(agent: agent, id: "ppid:\(header.ppid)")
    }

    /// Session ids some agents export to their hooks. `CLAUDE_CODE_SESSION_ID` is inherited by everything Claude
    /// spawns, so it is used only when `CLAUDE_PID` is the bound agent process.
    static func environmentSessionID(agent: AgentID, env: [String: String], attribution: Attribution) -> String? {
        let name: String
        switch agent {
        case .claude:
            guard let pid = env["CLAUDE_PID"].flatMap({ Int32($0) }), attribution.agentProcess?.pid == pid else { return nil }
            name = "CLAUDE_CODE_SESSION_ID"
        case .gemini: name = "GEMINI_SESSION_ID"
        case .auggie: name = "AUGMENT_CONVERSATION_ID"
        case .grok: name = "GROK_SESSION_ID"
        case .openhands: name = "OPENHANDS_SESSION_ID"
        case .crush: name = "CRUSH_SESSION_ID"
        default: return nil
        }
        return FieldLimits.capped(env[name])
    }

    static func openCodeSessionFallback(_ signal: OpenCodeSignal, agent: AgentID) -> SessionKey? {
        let session: String? = switch signal {
        case .busy(let s), .idle(let s), .deleted(let s), .created(let s, _): s
        case .error(let s), .needsInput(_, let s), .replied(let s): s
        }
        return FieldLimits.capped(session).map { SessionKey(agent: agent, id: $0) }
    }

    // MARK: - Event assembly

    private func makeEvent(id: String, header: InboxHeader, fields: NormalizedFields, attribution: Attribution,
                           sessionKey: SessionKey, receivedAt: Date) -> AgentEvent {
        var metadata = fields.metadata
        if let relabelled = attribution.relabelledFrom { metadata[MetadataKey.relabelledFrom] = relabelled }
        if attribution.agent == .claude, let entrypoint = header.env["CLAUDE_CODE_ENTRYPOINT"] {
            metadata[MetadataKey.claudeEntrypoint] = entrypoint
        }
        var occurredAt = header.date
        if occurredAt.timeIntervalSince(receivedAt) > Self.maxClockSkew { occurredAt = receivedAt }
        return AgentEvent(
            id: id,
            agent: attribution.agent,
            argvAgentLabel: FieldLimits.capped(header.agent, maxBytes: 64) ?? "unknown",
            event: fields.event,
            rawEventName: FieldLimits.capped(header.event, maxBytes: 128) ?? "",
            sessionKey: sessionKey,
            agentProcess: attribution.agentProcess,
            host: attribution.host.map(Self.cappedHost),
            cwd: FieldLimits.capped(fields.cwd) ?? FieldLimits.capped(header.cwd),
            title: FieldLimits.sanitized(fields.title),
            messagePreview: FieldLimits.sanitized(fields.messagePreview),
            waitingFor: FieldLimits.sanitized(fields.waitingFor),
            turnID: FieldLimits.capped(fields.turnID, maxBytes: 256),
            backgroundTasksRunning: fields.backgroundTasksRunning,
            errorDetail: FieldLimits.sanitized(fields.errorDetail),
            transcriptPath: FieldLimits.capped(fields.transcriptPath),
            tier: .hook,
            occurredAt: occurredAt,
            receivedAt: receivedAt,
            metadata: FieldLimits.metadata(metadata)
        )
    }

    static func cappedHost(_ host: HostApp) -> HostApp {
        HostApp(bundleID: FieldLimits.capped(host.bundleID, maxBytes: 256),
                name: FieldLimits.capped(host.name, maxBytes: 128) ?? "App",
                pid: host.pid)
    }

    private mutating func trackTurn(_ event: AgentEvent) {
        switch event.event {
        case .turnStarted:
            openTurns[event.sessionKey] = OpenTurn(startedAt: event.occurredAt)
            if openTurns.count > Self.maxOpenTurns {
                let newest = openTurns.sorted { $0.value.startedAt > $1.value.startedAt }.prefix(Self.maxOpenTurns / 2)
                openTurns = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
            }
        case .needsInput:
            openTurns[event.sessionKey]?.waiting = true
        case .activity:
            openTurns[event.sessionKey]?.waiting = false
        case .turnFinished, .sessionEnded:
            openTurns.removeValue(forKey: event.sessionKey)
        case .sessionStarted, .idleReminder:
            break
        }
    }

    // MARK: - Host bundle lookups (cached; untrusted paths only ever read, never executed)

    private mutating func bundleIdentifier(_ bundlePath: String) -> String? {
        if let cached = bundleCache[bundlePath] { return cached }
        if bundleMisses.contains(bundlePath) { return nil }
        let found = lookupBundleIdentifier(bundlePath)
        if bundleCache.count + bundleMisses.count >= Self.maxBundleCacheEntries {
            bundleCache.removeAll()
            bundleMisses.removeAll()
        }
        if let found { bundleCache[bundlePath] = found } else { bundleMisses.insert(bundlePath) }
        return found
    }
}
