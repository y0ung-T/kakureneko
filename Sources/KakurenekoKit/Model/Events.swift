import Foundation

/// How a turn ended (brief §3.1). `ambiguous` = Aider's bell (done *or* confirm), treated as idle.
public enum TurnOutcome: String, Sendable, Hashable, Codable, CaseIterable {
    case completed, interrupted, error, rateLimited, ambiguous
}

/// Why an agent is waiting for the human (brief §3.1).
public enum NeedsInputKind: String, Sendable, Hashable, Codable, CaseIterable {
    case permission, question, dialog, unknown
}

/// The normalized event every tier maps into (brief §3.1, binding).
///
/// JSON form: `{"type":"turnFinished","outcome":"completed"}`, `{"type":"needsInput","kind":"permission"}`,
/// `{"type":"sessionStarted"}` …
public enum NormalizedEvent: Sendable, Hashable {
    case sessionStarted
    /// → busy
    case turnStarted
    /// Heartbeat: tool pre/post, Kimi SessionHeartbeat, Cursor postToolUse. Refreshes progress.
    case activity
    case turnFinished(TurnOutcome)
    case needsInput(NeedsInputKind)
    /// Claude/Droid/Qwen `idle_prompt`: "still waiting" — never a second push.
    case idleReminder
    case sessionEnded

    /// Stable discriminator (`turnFinished`, `needsInput`, …) used in dedupe keys and JSON.
    public var typeName: String {
        switch self {
        case .sessionStarted: "sessionStarted"
        case .turnStarted: "turnStarted"
        case .activity: "activity"
        case .turnFinished: "turnFinished"
        case .needsInput: "needsInput"
        case .idleReminder: "idleReminder"
        case .sessionEnded: "sessionEnded"
        }
    }
}

extension NormalizedEvent: Codable {
    private enum CodingKeys: String, CodingKey { case type, outcome, kind }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "sessionStarted": self = .sessionStarted
        case "turnStarted": self = .turnStarted
        case "activity": self = .activity
        case "turnFinished":
            self = .turnFinished(c.tolerantDecode(TurnOutcome.self, forKey: .outcome, default: .ambiguous))
        case "needsInput":
            self = .needsInput(c.tolerantDecode(NeedsInputKind.self, forKey: .kind, default: .unknown))
        case "idleReminder": self = .idleReminder
        case "sessionEnded": self = .sessionEnded
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown NormalizedEvent type \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(typeName, forKey: .type)
        switch self {
        case .turnFinished(let outcome): try c.encode(outcome, forKey: .outcome)
        case .needsInput(let kind): try c.encode(kind, forKey: .kind)
        default: break
        }
    }
}

/// Detection tiers (brief §3.2). Raw values are the brief's labels.
public enum Tier: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    /// Native hook / plugin → precise edges.
    case hook = "T1"
    /// Agent state file (Claude sessions/*.json, `claude agents --json`, …).
    case stateFile = "T2"
    /// Process heuristic (evidence sampling).
    case heuristic = "T3"
    /// Liveness / stall guards.
    case guardrail = "T4"

    public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
}
