import Foundation

/// T1 event source: the hook inbox (brief §4.3–4.4). Implemented by `KakurenekoEvents.EventInbox`.
///
/// Isolation: implementations are `final class … : Sendable` (Mutex-protected state, a private serial
/// DispatchQueue for the vnode/FSEvents source / timer) or actors with `nonisolated` stream accessors.
/// All parsing/IO runs off the caller's actor (`@concurrent` or the private queue).
///
/// Contract:
/// * **Subscribe before start.** Callers obtain `events()` synchronously BEFORE `start()`. `start()` performs the
///   launch drain (files written while the app was down) and yields to the subscribers that exist at that point;
///   events are never buffered for future subscribers. Consumers ingest ONLY from the stream.
/// * `start()` creates the inbox directories (0700), loads `Paths.lastEventsFile`, drains anything queued, then
///   watches BOTH `Paths.inboxDirectory` and `Paths.fallbackInboxDirectory` (vnode `DispatchSource` on an
///   `O_EVTONLY` fd + 30 s safety re-drain + GC of `bad/` and `.tmp/` > 24 h). Idempotent.
/// * Every drain (launch, vnode, timer, notify hint, `drainNow`) is SERIALIZED (one private serial queue or a
///   `draining` flag): list both inboxes, merge, sort globally by file name (= chronological), ≤ 500 files per
///   pass, then process in that order.
/// * Each inbox file is parsed with `InboxFile.parse`, normalized (per-agent normalizers, brief §3.3/§3.4),
///   attributed (nearest matched ancestor → argv label → env markers, ARCHITECTURE §9.1) and deduped
///   (CONSECUTIVE duplicates per `sessionKey` within `AgentEvent.dedupeWindow` of `occurredAt`; Codex `notify` +
///   `Stop` with the same turn id collapse into one), then DELETED. Unparseable files move to `bad/`.
/// * The stream's broadcaster holds `InboxFile.maxQueuedFiles` events per subscriber (a 500-file drain pass is
///   never truncated).
/// * Payloads are untrusted: cap every field, ignore unknown keys, never execute anything.
/// * Never act destructively on a single event — the event source only reports.
public protocol AgentEventSource: Sendable {
    /// Error semantics (binding): `start()` must NOT throw for transient or recoverable filesystem problems (an
    /// inbox that cannot be created, opened or watched right now — permissions, a missing volume, a deleted
    /// directory). It logs the problem and keeps retrying from its safety tick, so the coordinator's start sequence
    /// is never aborted by the inbox. It may throw only for a programming/configuration error that no retry can fix;
    /// the coordinator logs any error and continues starting the other services either way.
    /// `KakurenekoEvents.EventInbox.start()` never throws.
    func start() async throws
    /// Stops watching and finishes every stream returned by `events()`.
    func stop() async
    /// Fan-out: each call returns an independent stream of accepted events in arrival order. Call it BEFORE
    /// `start()` (see above).
    func events() -> AsyncStream<AgentEvent>
    /// Drains both inboxes now (serialized with every other drain). Accepted events are yielded to the streams;
    /// the returned array is INFORMATIONAL (logging/tests) — never ingest it as well.
    @discardableResult
    func drainNow() async -> [AgentEvent]
    /// Proof of life per INTEGRATION: keyed by `AgentID(label: event.argvAgentLabel)` (the integration that
    /// delivered the event — a Copilot-file event relabelled `.vscode` still counts for `.copilot`), value = last
    /// `receivedAt`. Persisted to `Paths.lastEventsFile` (atomic, at most once per minute) and loaded at start.
    func lastEventSeen() async -> [AgentID: Date]
}

/// Process signature matching (brief §5.3 + R04 §7.5). The authoritative implementation is
/// `KakurenekoProcesses.AgentMatcher`; KakurenekoEvents receives it by injection for ancestry attribution.
/// Pure and synchronous.
public protocol AgentSignatureMatching: Sendable {
    /// Classifies one process. Match on exe path + argv[0]/argv[1] basenames, never on `p_comm` alone.
    func match(_ process: ProcessDescriptor) -> AgentMatch?
}

/// Minimal matcher (exact argv[0]/exe basename table for the main CLIs). Used as a default in tests
/// and previews; production injects `KakurenekoProcesses.AgentMatcher`.
public struct BasicAgentSignatureMatcher: AgentSignatureMatching {
    public init() {}

    private static let table: [String: AgentID] = [
        "claude": .claude, "codex": .codex, "gemini": .gemini, "agy": .agy, "copilot": .copilot,
        "cursor-agent": .cursor, "opencode": .opencode, "kilo": .kilo, "kilocode": .kilo, "aider": .aider,
        "droid": .droid, "qwen": .qwen, "auggie": .auggie, "openhands": .openhands, "devin": .devin,
        "qodercli": .qoder, "codebuddy": .codebuddy, "cbc": .codebuddy, "iflow": .iflow, "grok": .grok,
        "kimi": .kimi, "vibe": .vibe, "kiro-cli": .kiro, "kiro-cli-chat": .kiro, "goose": .goose, "cline": .cline,
        "amp": .amp, "pi": .pi, "junie": .junie, "hermes": .hermes, "crush": .crush, "cn": .continueCLI,
        "plandex": .plandex,
    ]
    private static let claudeInfrastructureArgs: Set<String> = ["daemon", "bg-pty-host", "bg-spare", "--bg-pty-host"]

    public func match(_ process: ProcessDescriptor) -> AgentMatch? {
        let candidates = [process.argv0Basename, process.executableBasename].compactMap { $0 }
        for name in candidates {
            // Claude's argv[0] may be rewritten to "claude bg-spare" etc.
            let first = name.split(separator: " ").first.map(String.init) ?? name
            if first == "ugrep" || first == "rg" { return nil }
            if let agent = Self.table[first] {
                let words = Set(process.argv.flatMap { $0.split(separator: " ").map(String.init) })
                let infra = agent == .claude && !words.isDisjoint(with: Self.claudeInfrastructureArgs)
                return AgentMatch(agent: agent, isInfrastructure: infra)
            }
        }
        if process.argv0Basename == "node" || process.executableBasename == "node", let script = process.argv1Basename {
            let stem = script.hasSuffix(".js") ? String(script.dropLast(3)) : script
            if let agent = Self.table[stem] { return AgentMatch(agent: agent) }
        }
        return nil
    }
}
