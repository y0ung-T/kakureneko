import Foundation

/// `~/.claude/sessions/<pid>.json` (R02 §3.3, §8.3). Undocumented schema → every field is optional
/// and decoded tolerantly (wrong types become nil; unknown keys ignored). `pid` is required.
///
/// Never read `*.key` files, never write anything under `~/.claude/sessions`.
public struct ClaudeSessionRecord: Sendable, Hashable, Codable {
    public var pid: Int32
    public var sessionId: String?
    /// LAUNCH cwd (transcript entries carry the current cwd).
    public var cwd: String?
    /// Epoch ms.
    public var startedAt: Double?
    /// `TZ=UTC LC_ALL=C ps -o lstart=` format, e.g. `Mon Oct 12 13:05:23 2026`. pid + procStart defeat pid reuse.
    public var procStart: String?
    public var version: String?
    /// `interactive` | `bg` | `daemon` | `daemon-worker`
    public var kind: String?
    /// `cli`, `claude-desktop`, `claude-vscode`, `sdk-ts`, `sdk-py`, `remote`, …
    public var entrypoint: String?
    /// `busy` | `shell` | `idle` | `waiting`
    public var status: String?
    /// With `waiting`: `permission prompt`, `input needed`, `dialog open`, `sandbox request`, `worker request`, `goal proposal`.
    public var waitingFor: String?
    /// Epoch ms; changes only when status/waitingFor is rewritten.
    public var statusUpdatedAt: Double?
    /// Epoch ms.
    public var updatedAt: Double?
    public var name: String?
    /// `user`, `peer`, `derived`, `collision`, `auto`, `hook`
    public var nameSource: String?
    /// Background job short id (`kind == bg`).
    public var jobId: String?
    /// Parked interactive record → ignore (Claude's own reader skips it).
    public var parkedJobId: String?
    /// Pre-warmed unclaimed process → ignore.
    public var spare: Bool?
    /// Remote Control connected.
    public var bridgeSessionId: String?

    public enum Status: String, Sendable, Hashable, Codable { case busy, shell, idle, waiting }

    public init(
        pid: Int32, sessionId: String? = nil, cwd: String? = nil, startedAt: Double? = nil, procStart: String? = nil,
        version: String? = nil, kind: String? = nil, entrypoint: String? = nil, status: String? = nil,
        waitingFor: String? = nil, statusUpdatedAt: Double? = nil, updatedAt: Double? = nil, name: String? = nil,
        nameSource: String? = nil, jobId: String? = nil, parkedJobId: String? = nil, spare: Bool? = nil,
        bridgeSessionId: String? = nil
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.startedAt = startedAt
        self.procStart = procStart
        self.version = version
        self.kind = kind
        self.entrypoint = entrypoint
        self.status = status
        self.waitingFor = waitingFor
        self.statusUpdatedAt = statusUpdatedAt
        self.updatedAt = updatedAt
        self.name = name
        self.nameSource = nameSource
        self.jobId = jobId
        self.parkedJobId = parkedJobId
        self.spare = spare
        self.bridgeSessionId = bridgeSessionId
    }

    private enum CodingKeys: String, CodingKey {
        case pid, sessionId, cwd, startedAt, procStart, version, kind, entrypoint, status, waitingFor
        case statusUpdatedAt, updatedAt, name, nameSource, jobId, parkedJobId, spare, bridgeSessionId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let p = try? c.decode(Int32.self, forKey: .pid) {
            pid = p
        } else if let d = c.tolerantDouble(forKey: .pid), let p = Int32(exactly: d.rounded()) {
            pid = p
        } else {
            throw DecodingError.keyNotFound(CodingKeys.pid, .init(codingPath: c.codingPath, debugDescription: "pid missing"))
        }
        sessionId = c.tolerantDecodeIfPresent(String.self, forKey: .sessionId)
        cwd = c.tolerantDecodeIfPresent(String.self, forKey: .cwd)
        startedAt = c.tolerantDouble(forKey: .startedAt)
        procStart = c.tolerantDecodeIfPresent(String.self, forKey: .procStart)
        version = c.tolerantDecodeIfPresent(String.self, forKey: .version)
        kind = c.tolerantDecodeIfPresent(String.self, forKey: .kind)
        entrypoint = c.tolerantDecodeIfPresent(String.self, forKey: .entrypoint)
        status = c.tolerantDecodeIfPresent(String.self, forKey: .status)
        waitingFor = c.tolerantDecodeIfPresent(String.self, forKey: .waitingFor)
        statusUpdatedAt = c.tolerantDouble(forKey: .statusUpdatedAt)
        updatedAt = c.tolerantDouble(forKey: .updatedAt)
        name = c.tolerantDecodeIfPresent(String.self, forKey: .name)
        nameSource = c.tolerantDecodeIfPresent(String.self, forKey: .nameSource)
        jobId = c.tolerantDecodeIfPresent(String.self, forKey: .jobId)
        parkedJobId = c.tolerantDecodeIfPresent(String.self, forKey: .parkedJobId)
        spare = c.tolerantDecodeIfPresent(Bool.self, forKey: .spare)
        bridgeSessionId = c.tolerantDecodeIfPresent(String.self, forKey: .bridgeSessionId)
    }

    /// Tolerant decode of a record file's bytes; `nil` if unusable.
    public static func decode(_ data: Data) -> ClaudeSessionRecord? {
        try? JSONDecoder().decode(ClaudeSessionRecord.self, from: data)
    }

    /// `^\d+\.json$` — the only files in `sessions/` to read (ignore `*.key`, `.fleetview-heartbeat`).
    public static func isRecordFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        let stem = name.dropLast(5)
        return !stem.isEmpty && stem.allSatisfy(\.isASCII) && stem.allSatisfy(\.isNumber)
    }

    public var statusKind: Status? { status.flatMap(Status.init(rawValue:)) }

    /// Records Claude's own reader skips: spare, parked, daemon, daemon-worker.
    public var isIgnorable: Bool {
        spare == true || parkedJobId != nil || kind == "daemon" || kind == "daemon-worker"
    }

    /// Title rule (brief §8.4): record `name` only if `nameSource ∈ {user, peer, auto}`.
    public var humanName: String? {
        guard let name, !name.isEmpty, let nameSource, ["user", "peer", "auto"].contains(nameSource) else { return nil }
        return name
    }

    /// `procStart` parsed as UTC epoch seconds (`Mon Oct 12 13:05:23 2026`, day may be space-padded).
    public var procStartEpochSeconds: Int64? {
        guard let procStart else { return nil }
        return Self.parseProcStart(procStart)
    }

    public static func parseProcStart(_ text: String) -> Int64? {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 5 else { return nil }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard let monthIndex = months.firstIndex(of: String(parts[1])),
              let day = Int(parts[2]), let year = Int(parts[4]) else { return nil }
        let hms = parts[3].split(separator: ":")
        guard hms.count == 3, let h = Int(hms[0]), let m = Int(hms[1]), let s = Int(hms[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = year
        comps.month = monthIndex + 1
        comps.day = day
        comps.hour = h
        comps.minute = m
        comps.second = s
        guard let date = calendar.date(from: comps) else { return nil }
        return Int64(date.timeIntervalSince1970)
    }
}

/// One entry of `claude agents --json --all` (R02 §3.5), tolerant.
public struct ClaudeAgentsEntry: Sendable, Hashable, Codable {
    public var pid: Int32?
    /// Background short id.
    public var id: String?
    public var cwd: String?
    /// `interactive` | `background`
    public var kind: String?
    public var startedAt: Double?
    public var sessionId: String?
    public var name: String?
    /// `busy` | `waiting` | `idle` (alive processes)
    public var status: String?
    /// Background: `working`, `blocked`, `done`, `failed`, `stopped`
    public var state: String?
    public var waitingFor: String?

    public init(pid: Int32? = nil, id: String? = nil, cwd: String? = nil, kind: String? = nil, startedAt: Double? = nil,
                sessionId: String? = nil, name: String? = nil, status: String? = nil, state: String? = nil, waitingFor: String? = nil) {
        self.pid = pid
        self.id = id
        self.cwd = cwd
        self.kind = kind
        self.startedAt = startedAt
        self.sessionId = sessionId
        self.name = name
        self.status = status
        self.state = state
        self.waitingFor = waitingFor
    }

    private enum CodingKeys: String, CodingKey { case pid, id, cwd, kind, startedAt, sessionId, name, status, state, waitingFor }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = c.tolerantDouble(forKey: .pid).flatMap { Int32(exactly: $0.rounded()) }
        id = c.tolerantDecodeIfPresent(String.self, forKey: .id)
        cwd = c.tolerantDecodeIfPresent(String.self, forKey: .cwd)
        kind = c.tolerantDecodeIfPresent(String.self, forKey: .kind)
        startedAt = c.tolerantDouble(forKey: .startedAt)
        sessionId = c.tolerantDecodeIfPresent(String.self, forKey: .sessionId)
        name = c.tolerantDecodeIfPresent(String.self, forKey: .name)
        status = c.tolerantDecodeIfPresent(String.self, forKey: .status)
        state = c.tolerantDecodeIfPresent(String.self, forKey: .state)
        waitingFor = c.tolerantDecodeIfPresent(String.self, forKey: .waitingFor)
    }

    /// Decodes the whole `--json` output (a JSON array); tolerant of individual bad entries.
    public static func decodeList(_ data: Data) -> [ClaudeAgentsEntry]? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        return raw.compactMap { item in
            guard JSONSerialization.isValidJSONObject(item),
                  let d = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            return try? JSONDecoder().decode(ClaudeAgentsEntry.self, from: d)
        }
    }
}

/// One validated session record.
public struct ClaudeSessionObservation: Sendable, Hashable, Codable {
    public var record: ClaudeSessionRecord
    /// Live identity of `record.pid` if the process exists AND its start time matches `procStart`
    /// (±1 s); `nil` → the session is dead (→ `ended`).
    public var identity: ProcessIdentity?
    /// mtime of the record file.
    public var fileModifiedAt: Date?
    /// Resolved `projects/*/<sessionId>.jsonl`, if found.
    public var transcriptPath: String?
    /// Title per brief §8.4 (custom-title → agent-name → ai-title → record name rule), if resolved.
    public var title: String?
    /// cwd of the last transcript entry (current cwd), if resolved.
    public var currentCwd: String?
    /// Sanitized preview of the last assistant message, if resolved.
    public var lastAssistantPreview: String?
    /// Timestamp of the last transcript entry with `type == "system"` and `subtype == "turn_duration"` in the
    /// tail read (R02 §5.2/§8.2: "a turn just ended"). Lets T2-only sessions (no hook loaded yet) produce a
    /// `finished` push. The watcher re-reads the tail 1–2 s after a busy → idle change (it is written just after
    /// the turn).
    public var lastTurnCompletedAt: Date?
    /// `durationMs` of that `turn_duration` entry.
    public var lastTurnDurationMs: Double?
    /// `pendingWorkflowCount + pendingBackgroundAgentCount` of that entry (nil when absent = 0).
    public var lastTurnPendingBackground: Int?

    public init(record: ClaudeSessionRecord, identity: ProcessIdentity?, fileModifiedAt: Date? = nil, transcriptPath: String? = nil,
                title: String? = nil, currentCwd: String? = nil, lastAssistantPreview: String? = nil,
                lastTurnCompletedAt: Date? = nil, lastTurnDurationMs: Double? = nil, lastTurnPendingBackground: Int? = nil) {
        self.record = record
        self.identity = identity
        self.fileModifiedAt = fileModifiedAt
        self.transcriptPath = transcriptPath
        self.title = title
        self.currentCwd = currentCwd
        self.lastAssistantPreview = lastAssistantPreview
        self.lastTurnCompletedAt = lastTurnCompletedAt
        self.lastTurnDurationMs = lastTurnDurationMs
        self.lastTurnPendingBackground = lastTurnPendingBackground
    }

    private enum CodingKeys: String, CodingKey {
        case record, identity, fileModifiedAt, transcriptPath, title, currentCwd, lastAssistantPreview
        case lastTurnCompletedAt, lastTurnDurationMs, lastTurnPendingBackground
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        record = try c.decode(ClaudeSessionRecord.self, forKey: .record)
        identity = c.tolerantDecodeIfPresent(ProcessIdentity.self, forKey: .identity)
        fileModifiedAt = c.tolerantDecodeIfPresent(Date.self, forKey: .fileModifiedAt)
        transcriptPath = c.tolerantDecodeIfPresent(String.self, forKey: .transcriptPath)
        title = c.tolerantDecodeIfPresent(String.self, forKey: .title)
        currentCwd = c.tolerantDecodeIfPresent(String.self, forKey: .currentCwd)
        lastAssistantPreview = c.tolerantDecodeIfPresent(String.self, forKey: .lastAssistantPreview)
        lastTurnCompletedAt = c.tolerantDecodeIfPresent(Date.self, forKey: .lastTurnCompletedAt)
        lastTurnDurationMs = c.tolerantDouble(forKey: .lastTurnDurationMs)
        lastTurnPendingBackground = c.tolerantDecodeIfPresent(Int.self, forKey: .lastTurnPendingBackground)
    }
}

/// Full T2 state for Claude Code at one moment (what `ClaudeStateSource` emits).
public struct ClaudeStateSnapshot: Sendable, Hashable, Codable {
    public var takenAt: Date
    /// Every non-ignorable record currently in `sessions/` (dead ones included with `identity == nil`).
    public var sessions: [ClaudeSessionObservation]
    /// Last `claude agents --json --all` result (`nil` when never polled / CLI unavailable / failed).
    public var agents: [ClaudeAgentsEntry]?
    public var agentsPolledAt: Date?
    /// False when `sessions/` is missing or unreadable (Claude not installed → no T2). Never ends sessions.
    public var sessionsDirectoryReadable: Bool
    /// LIVE identities of ignorable records (parked `claude -c`, spare, daemon, daemon-worker). The engine never
    /// creates T3 heuristic sessions for these processes (a parked session is not working).
    public var ignoredIdentities: [ProcessIdentity]

    public init(takenAt: Date, sessions: [ClaudeSessionObservation] = [], agents: [ClaudeAgentsEntry]? = nil,
                agentsPolledAt: Date? = nil, sessionsDirectoryReadable: Bool = false, ignoredIdentities: [ProcessIdentity] = []) {
        self.takenAt = takenAt
        self.sessions = sessions
        self.agents = agents
        self.agentsPolledAt = agentsPolledAt
        self.sessionsDirectoryReadable = sessionsDirectoryReadable
        self.ignoredIdentities = ignoredIdentities
    }

    public static func empty(at date: Date) -> ClaudeStateSnapshot { ClaudeStateSnapshot(takenAt: date) }

    private enum CodingKeys: String, CodingKey {
        case takenAt, sessions, agents, agentsPolledAt, sessionsDirectoryReadable, ignoredIdentities
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        takenAt = try c.decode(Date.self, forKey: .takenAt)
        sessions = c.tolerantDecode([ClaudeSessionObservation].self, forKey: .sessions, default: [])
        agents = c.tolerantDecodeIfPresent([ClaudeAgentsEntry].self, forKey: .agents)
        agentsPolledAt = c.tolerantDecodeIfPresent(Date.self, forKey: .agentsPolledAt)
        sessionsDirectoryReadable = c.tolerantDecode(Bool.self, forKey: .sessionsDirectoryReadable, default: false)
        ignoredIdentities = c.tolerantDecode([ProcessIdentity].self, forKey: .ignoredIdentities, default: [])
    }
}
