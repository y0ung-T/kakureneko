import Foundation

/// Pause modes (brief §6.2). Throttle is the default; Freeze is experimental; Quit is opt-in (D6).
/// `PauseSettings.mode` is `.throttle` or `.freeze` only (`normalized()` maps `.quit` → `.throttle`); Quit is
/// gated solely by `PauseSettings.quitWhenMemoryLow` and appears here for journal/`PausedApp` records.
public enum PauseMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)`.
    case throttle
    /// `proc_signal_with_audittoken(SIGSTOP)`.
    case freeze
    /// `NSRunningApplication.terminate()` — only clean apps under memory pressure.
    case quit
}

/// What was done to one journal member (R06 §4.1 `action` values).
public enum PauseAction: String, Sendable, Hashable, Codable {
    case darwinBackground = "darwinbg"
    case sigstop
    case terminate
}

/// Identity tuple of one paused process — exactly what `paused.json` stores per member.
/// Thaw only if boot UUID, start time and uniqueID match AND a fresh audit token has `val[7] == pidVersion`.
/// Identity fields and `action` decode STRICTLY (a record missing any of them is dropped by the lossy
/// `PauseJournalApp` decoder rather than thawed on a guess).
public struct PauseJournalRecord: Sendable, Hashable, Codable {
    public var pid: Int32
    public var pidVersion: UInt32
    public var uniqueID: UInt64
    public var startSec: Int64
    public var startUsec: Int32
    public var path: String?
    public var action: PauseAction

    public init(pid: Int32, pidVersion: UInt32, uniqueID: UInt64, startSec: Int64, startUsec: Int32, path: String?, action: PauseAction) {
        self.pid = pid
        self.pidVersion = pidVersion
        self.uniqueID = uniqueID
        self.startSec = startSec
        self.startUsec = startUsec
        self.path = path
        self.action = action
    }

    /// nil unless `identity` was ENRICHED (`pidVersion` = fresh audit token `val[7]`, `uniqueID` = flavor 17
    /// `p_uniqueid`). Never journal (or signal) a member that was not enriched: recovery could not verify it.
    public init?(identity: ProcessIdentity, path: String?, action: PauseAction) {
        guard let pidVersion = identity.pidVersion, let uniqueID = identity.uniqueID else { return nil }
        self.init(pid: identity.pid, pidVersion: pidVersion, uniqueID: uniqueID,
                  startSec: identity.startSec, startUsec: identity.startUsec, path: path, action: action)
    }

    public var identity: ProcessIdentity {
        ProcessIdentity(pid: pid, startSec: startSec, startUsec: startUsec, uniqueID: uniqueID, pidVersion: pidVersion)
    }
}

/// One paused app group in the journal.
public struct PauseJournalApp: Sendable, Hashable, Codable {
    public var bundleID: String?
    public var name: String?
    public var appPid: Int32
    public var mode: PauseMode
    /// Main process first, then helpers in pause order. Thaw in reverse (LIFO).
    public var members: [PauseJournalRecord]
    /// Written in dry-run: nothing was really stopped/throttled. Recovery (in-process and `kakureneko-guard`) and
    /// thaw NEVER signal simulated apps — they just drop them.
    public var simulated: Bool

    public init(bundleID: String?, name: String?, appPid: Int32, mode: PauseMode, members: [PauseJournalRecord], simulated: Bool = false) {
        self.bundleID = bundleID
        self.name = name
        self.appPid = appPid
        self.mode = mode
        self.members = members
        self.simulated = simulated
    }

    private enum CodingKeys: String, CodingKey { case bundleID, name, appPid, mode, members, simulated }

    /// Lossy: members that fail to decode are skipped (`droppedMemberCount`); non-identity fields are tolerant.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = c.tolerantDecodeIfPresent(String.self, forKey: .bundleID)
        name = c.tolerantDecodeIfPresent(String.self, forKey: .name)
        appPid = try c.decode(Int32.self, forKey: .appPid)
        mode = c.tolerantDecode(PauseMode.self, forKey: .mode, default: .throttle)
        let lossy = c.tolerantDecode(LossyArray<PauseJournalRecord>.self, forKey: .members, default: LossyArray())
        members = lossy.elements
        droppedMemberCount = lossy.dropped
        simulated = c.tolerantDecode(Bool.self, forKey: .simulated, default: false)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(bundleID, forKey: .bundleID)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(appPid, forKey: .appPid)
        try c.encode(mode, forKey: .mode)
        try c.encode(members, forKey: .members)
        try c.encode(simulated, forKey: .simulated)
    }

    /// Members skipped while decoding (diagnostics; not encoded, not part of equality).
    public private(set) var droppedMemberCount: Int = 0

    public static func == (lhs: PauseJournalApp, rhs: PauseJournalApp) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.name == rhs.name && lhs.appPid == rhs.appPid && lhs.mode == rhs.mode
            && lhs.members == rhs.members && lhs.simulated == rhs.simulated
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bundleID)
        hasher.combine(name)
        hasher.combine(appPid)
        hasher.combine(mode)
        hasher.combine(members)
        hasher.combine(simulated)
    }
}

/// `~/Library/Application Support/Kakureneko/paused.json` — the write-ahead journal (brief §6.5, R06 §4.1).
/// Written BEFORE every signal/setpriority with `AtomicFile.write(…, permissions: 0o600, fullSync: true)`.
/// Read by KakurenekoPause at launch and by `kakureneko-guard` when the app dies.
///
/// Decoding is LOSSY for `apps`/`members` (one malformed record, or a field added later and read by an older
/// guard, must never stop recovery from thawing everything else); identity fields stay strict per record.
public struct PauseJournal: Sendable, Hashable, Codable {
    public static let currentSchema = 1

    public var schema: Int
    /// `kern.bootsessionuuid` at write time. Records from another boot are dropped, never thawed.
    public var bootSessionUUID: String
    /// pid of the Kakureneko app that wrote it.
    public var kakurenekoPid: Int32
    public var startedAt: Date
    public var apps: [PauseJournalApp]

    public init(schema: Int = PauseJournal.currentSchema, bootSessionUUID: String, kakurenekoPid: Int32, startedAt: Date, apps: [PauseJournalApp] = []) {
        self.schema = schema
        self.bootSessionUUID = bootSessionUUID
        self.kakurenekoPid = kakurenekoPid
        self.startedAt = startedAt
        self.apps = apps
    }

    private enum CodingKeys: String, CodingKey { case schema, bootSessionUUID, kakurenekoPid, startedAt, apps }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = c.tolerantDecode(Int.self, forKey: .schema, default: PauseJournal.currentSchema)
        bootSessionUUID = try c.decode(String.self, forKey: .bootSessionUUID)
        kakurenekoPid = c.tolerantDecode(Int32.self, forKey: .kakurenekoPid, default: 0)
        startedAt = c.tolerantDecode(Date.self, forKey: .startedAt, default: Date(timeIntervalSince1970: 0))
        apps = c.tolerantDecode(LossyArray<PauseJournalApp>.self, forKey: .apps, default: LossyArray()).elements
    }

    public var isEmpty: Bool { apps.allSatisfy(\.members.isEmpty) }

    /// Apps whose members must really be thawed (simulated dry-run entries excluded).
    public var realApps: [PauseJournalApp] { apps.filter { !$0.simulated } }

    /// Encodes with `KakurenekoJSON` (ISO 8601 dates, sorted keys).
    public func encoded() throws -> Data { try KakurenekoJSON.encode(self) }

    /// Decodes a journal; `nil` if the data is unusable (not JSON, or no boot UUID).
    public static func decode(_ data: Data) -> PauseJournal? { try? KakurenekoJSON.decode(PauseJournal.self, from: data) }

    /// Atomic, fully-synced write (0600).
    public func write(to url: URL) throws {
        try AtomicFile.write(encoded(), to: url, permissions: 0o600, fullSync: true, followSymlinks: false)
    }

    /// Reads the journal at `url` (`nil` if missing or unreadable).
    public static func read(from url: URL) -> PauseJournal? {
        guard let data = try? AtomicFile.readIfExists(url) else { return nil }
        return decode(data)
    }
}

/// Decodes an array element by element, skipping elements that fail (journal resilience).
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element] = []
    var dropped = 0

    init() {}

    init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        while !c.isAtEnd {
            if let e = try? c.decode(Element.self) {
                elements.append(e)
            } else {
                // A failed decode does not advance the container; skip the element explicitly.
                dropped += 1
                guard (try? c.decode(SkippedElement.self)) != nil else { break }
            }
        }
    }

    private struct SkippedElement: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}

/// Protection rules (brief §6.3). Raw values are the rule ids.
public enum ProtectionReason: String, Sendable, Hashable, Codable, CaseIterable {
    case agentHost = "P-A"
    case launchedByAgent = "P-B"
    case ipcPeer = "P-C"
    case listenerInUse = "P-D"
    case automationTarget = "P-E"
    case audio = "P-F"
    /// Download in progress → Throttle, never Freeze.
    case download = "P-G"
    case traced = "P-H"
    /// > 20 % of one core over the last 2 min → Throttle instead of Freeze.
    case busyAtLidClose = "P-I"
    case staticNeverList = "P-J"
    case userNeverList = "P-K"
    /// Not `.regular` activation policy, not finished launching, has a controlling tty, root/other user.
    case notCandidate = "candidate"
    case launchedAfterPause = "late"
    case kakurenekoItself = "self"
    /// Grouping self-test failed / topology incomplete → protect conservatively.
    case uncertain = "uncertain"
    /// R06 §5.4 category default: browsers (agents drive them) and chat, mail and meeting apps (sessions, calls) are
    /// throttled, never frozen.
    case categoryDefault = "category"

    /// P-G, P-I and the category default only downgrade Freeze to Throttle; every other reason protects the group.
    public var downgradesOnly: Bool { self == .download || self == .busyAtLidClose || self == .categoryDefault }

    public var explanation: String {
        switch self {
        case .agentHost: "hosts an agent"
        case .launchedByAgent: "launched by an agent"
        case .ipcPeer: "talks to an agent"
        case .listenerInUse: "an agent is connected to it"
        case .automationTarget: "an agent is automating it"
        case .audio: "playing or recording audio"
        case .download: "downloading"
        case .traced: "being debugged"
        case .busyAtLidClose: "busy when the lid closed"
        case .staticNeverList: "never paused"
        case .userNeverList: "on your never-pause list"
        case .notCandidate: "not a regular app"
        case .launchedAfterPause: "launched after pausing began"
        case .kakurenekoItself: "Kakureneko itself"
        case .uncertain: "protected to be safe"
        case .categoryDefault: "browser or chat app: slowed, never frozen"
        }
    }
}

/// An app currently paused.
public struct PausedApp: Sendable, Hashable, Codable, Identifiable {
    public var appPID: Int32
    public var id: Int32 { appPID }
    public var bundleID: String?
    public var name: String
    public var mode: PauseMode
    public var memberCount: Int
    public var pausedAt: Date
    /// Set when Freeze was downgraded to Throttle (P-G / P-I).
    public var downgradedBecause: ProtectionReason?

    public init(appPID: Int32, bundleID: String?, name: String, mode: PauseMode, memberCount: Int, pausedAt: Date, downgradedBecause: ProtectionReason? = nil) {
        self.appPID = appPID
        self.bundleID = bundleID
        self.name = name
        self.mode = mode
        self.memberCount = memberCount
        self.pausedAt = pausedAt
        self.downgradedBecause = downgradedBecause
    }
}

/// An app that was considered and protected.
public struct ProtectedApp: Sendable, Hashable, Codable, Identifiable {
    public var appPID: Int32
    public var id: Int32 { appPID }
    public var bundleID: String?
    public var name: String
    public var reasons: [ProtectionReason]

    public init(appPID: Int32, bundleID: String?, name: String, reasons: [ProtectionReason]) {
        self.appPID = appPID
        self.bundleID = bundleID
        self.name = name
        self.reasons = reasons
    }
}

/// A pause attempt that failed (partial freeze → thawed).
public struct PauseFailure: Sendable, Hashable, Codable {
    public var appPID: Int32
    public var name: String
    public var message: String

    public init(appPID: Int32, name: String, message: String) {
        self.appPID = appPID
        self.name = name
        self.message = message
    }
}

/// Result of `pause`/`recheck`.
public struct PauseReport: Sendable, Hashable, Codable {
    public var at: Date
    /// Everything paused after this call.
    public var paused: [PausedApp]
    /// Apps thawed by this call (recheck matches, watchdog …).
    public var thawed: [PausedApp]
    public var protected: [ProtectedApp]
    public var failures: [PauseFailure]
    /// Why nothing was paused at all, if so ("pausing disabled", "grouping self-test failed", "no agent working").
    public var skippedReason: String?

    public init(at: Date, paused: [PausedApp] = [], thawed: [PausedApp] = [], protected: [ProtectedApp] = [], failures: [PauseFailure] = [], skippedReason: String? = nil) {
        self.at = at
        self.paused = paused
        self.thawed = thawed
        self.protected = protected
        self.failures = failures
        self.skippedReason = skippedReason
    }

    /// Phone/menu summary, e.g. "Paused 3 apps (Word, Spotify, Steam); throttled Arc, Slack; protected Terminal".
    public var summary: String {
        let frozen = paused.filter { $0.mode == .freeze }.map(\.name)
        let throttled = paused.filter { $0.mode == .throttle }.map(\.name)
        var parts: [String] = []
        if !frozen.isEmpty { parts.append("paused \(frozen.joined(separator: ", "))") }
        if !throttled.isEmpty { parts.append("throttled \(throttled.joined(separator: ", "))") }
        let hosts = protected.filter { $0.reasons.contains(.agentHost) }.map(\.name)
        if !hosts.isEmpty { parts.append("protected \(hosts.joined(separator: ", "))") }
        if parts.isEmpty { return skippedReason ?? "Nothing paused" }
        let text = parts.joined(separator: "; ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// Why apps are being thawed (brief §6.5 item 5).
public enum ThawReason: String, Sendable, Hashable, Codable, CaseIterable {
    case lidOpened
    case externalDisplay
    case userInput
    case willSleep
    case willPowerOff
    case sessionResignedActive
    case beforePowerAction
    case appQuitting
    case pausingDisabled
    case hardCap
    case protectionMatched
    case watchdog
    case noAgentWorking
    case userRequest
    case launchRecovery
    case guardRecovery
}

/// Result of the responsibility/coalition/ppid grouping self-test (brief §6.3). Freeze requires `freezeAllowed`.
public struct GroupingSelfTest: Sendable, Hashable, Codable {
    public enum Method: String, Sendable, Hashable, Codable { case responsibility, coalition, parentTree, unavailable }
    public var method: Method
    public var freezeAllowed: Bool
    public var detail: String?

    public init(method: Method, freezeAllowed: Bool, detail: String? = nil) {
        self.method = method
        self.freezeAllowed = freezeAllowed
        self.detail = detail
    }
}
