import KakurenekoKit
import Foundation

/// One opencode (or Kilo, an opencode fork) plugin event, before the per-process roll-up.
enum OpenCodeSignal: Equatable {
    /// `session.status {busy|retry}`
    case busy(session: String)
    /// `session.status {idle}` / `session.idle`
    case idle(session: String)
    /// `session.deleted`
    case deleted(session: String)
    /// `session.error` (`session` nil = an error not tied to one session: every busy session stops)
    case error(session: String?)
    /// `session.created` (`parent` = `parentID` for subagent child sessions)
    case created(session: String, parent: String?)
    /// `permission.asked` / `question.asked` / `form.created`
    case needsInput(NeedsInputKind, session: String?)
    /// `permission.replied` / `question.replied` / `form.replied` / `form.cancelled`: the agent resumes.
    case replied(session: String?)
}

/// opencode / Kilo plugin events (brief §3.3 row 7, snippet G, R03 §7(d)). The plugin sends
/// `{type, properties|data, directory, pid}`; v1 and v2 envelopes are both accepted. The mapping to
/// `NormalizedEvent` happens in `OpenCodeRollup` (sessions are keyed by the opencode PROCESS, ARCHITECTURE §8).
struct OpenCodeNormalizer: EventNormalizer {
    func normalize(_ input: NormalizationInput) -> NormalizedFields? {
        let payload = input.payload
        let properties = payload.object("properties") ?? payload.object("data") ?? payload
        let sessionID = properties.string("sessionID", "sessionId", "session_id")
        let signal: OpenCodeSignal
        var waitingFor: String?
        switch input.key {
        case "sessionstatus":
            guard let sessionID else { return nil }
            let status = properties.object("status")?.string("type") ?? properties.string("status")
            switch status?.lowercased() {
            case "busy", "retry": signal = .busy(session: sessionID)
            case "idle": signal = .idle(session: sessionID)
            default: return nil
            }
        case "sessionidle":
            guard let sessionID else { return nil }
            signal = .idle(session: sessionID)
        case "sessioncreated":
            let info = properties.object("info") ?? properties.object("session") ?? properties
            guard let id = info.string("id") ?? sessionID else { return nil }
            signal = .created(session: id, parent: info.string("parentID", "parentId", "parent_id"))
        case "sessiondeleted":
            let info = properties.object("info") ?? properties.object("session") ?? properties
            guard let id = info.string("id") ?? sessionID else { return nil }
            signal = .deleted(session: id)
        case "sessionerror":
            signal = .error(session: sessionID)
        case "permissionasked":
            signal = .needsInput(.permission, session: sessionID)
            waitingFor = properties.string("title", "permission")
        case "questionasked":
            signal = .needsInput(.question, session: sessionID)
            waitingFor = properties.objects("questions").first?.string("question", "text", "header")
        case "formcreated":
            let form = properties.object("form") ?? properties
            signal = .needsInput(.question, session: form.string("sessionID", "sessionId") ?? sessionID)
            waitingFor = form.string("title", "message")
        case "permissionreplied", "questionreplied", "formreplied", "formcancelled":
            signal = .replied(session: sessionID)
        default:
            return nil
        }
        // `event` is a placeholder: the roll-up decides what (if anything) this signal emits.
        var fields = NormalizedFields(.activity)
        fields.openCode = signal
        fields.waitingFor = waitingFor
        fields.cwd = payload.string("directory") ?? properties.string("directory", "cwd")
        return fields
    }

    /// `pid` of the opencode process (the plugin adds `process.pid`).
    static func processID(_ payload: RawPayload) -> Int32? {
        payload.string("pid").flatMap { Int32($0) }
    }
}

/// Per-process roll-up of opencode sessions (ARCHITECTURE §9.1): the process is busy while ANY of its sessions
/// (root or subagent child) is busy. `.turnStarted` only on empty → non-empty, `.turnFinished` (`.error` for
/// `session.error`) only on non-empty → empty; needs-input on the process key; other child events → nothing.
struct OpenCodeRollup {
    struct ProcessState: Equatable {
        /// Busy session ids (`opencodeBusy` in the spec card).
        var busy: Set<String> = []
        /// child session → parent session (from `session.created`).
        var parents: [String: String] = [:]
    }

    struct Output: Equatable {
        var event: NormalizedEvent?
        /// Root session id (`MetadataKey.opencodeSessionID`).
        var rootSession: String?
        /// Child session id (`MetadataKey.opencodeChildSession`) when the signal came from a subagent session.
        var childSession: String?
    }

    /// Bound on tracked processes (opencode restarts get a new identity; old keys are pruned).
    static let maxProcesses = 256
    static let maxSessionsPerProcess = 512

    private(set) var processes: [SessionKey: ProcessState] = [:]

    mutating func apply(_ signal: OpenCodeSignal, key: SessionKey) -> Output {
        var state = processes[key] ?? ProcessState()
        let wasBusy = !state.busy.isEmpty
        var event: NormalizedEvent?
        var session: String?
        switch signal {
        case .busy(let id):
            session = id
            if state.busy.count < Self.maxSessionsPerProcess { state.busy.insert(id) }
            if !wasBusy { event = .turnStarted }
        case .idle(let id), .deleted(let id):
            session = id
            state.busy.remove(id)
            if wasBusy && state.busy.isEmpty { event = .turnFinished(.completed) }
            if case .deleted = signal { state.parents.removeValue(forKey: id) }
        case .error(let id):
            session = id
            if let id { state.busy.remove(id) } else { state.busy.removeAll() }
            if wasBusy && state.busy.isEmpty { event = .turnFinished(.error) }
        case .created(let id, let parent):
            session = id
            if let parent, parent != id {
                if state.parents.count < Self.maxSessionsPerProcess { state.parents[id] = parent }
            } else {
                event = .sessionStarted
            }
        case .needsInput(let kind, let id):
            session = id
            event = .needsInput(kind)
        case .replied(let id):
            session = id
            event = .activity
        }
        processes[key] = state
        prune(keeping: key)

        var output = Output(event: event)
        if let session {
            if let parent = state.parents[session] {
                output.rootSession = root(of: parent, in: state)
                output.childSession = session
            } else {
                output.rootSession = session
            }
        }
        return output
    }

    func isBusy(_ key: SessionKey) -> Bool { !(processes[key]?.busy.isEmpty ?? true) }

    /// Follows parent links (bounded) to the top-level session.
    private func root(of session: String, in state: ProcessState) -> String {
        var current = session
        var hops = 0
        while let parent = state.parents[current], hops < 16 {
            current = parent
            hops += 1
        }
        return current
    }

    private mutating func prune(keeping key: SessionKey) {
        guard processes.count > Self.maxProcesses else { return }
        for (candidate, state) in processes where candidate != key && state.busy.isEmpty {
            processes.removeValue(forKey: candidate)
            if processes.count <= Self.maxProcesses { return }
        }
        while processes.count > Self.maxProcesses, let victim = processes.keys.first(where: { $0 != key }) {
            processes.removeValue(forKey: victim)
        }
    }
}
