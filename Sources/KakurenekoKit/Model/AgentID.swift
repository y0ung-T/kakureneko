import Foundation

/// Every agent Kakureneko knows about (brief §3.1, plus `plandex` from §3.5).
///
/// The raw value is the label used in hook argv (`kakureneko-hook <agent> <event>`), recordings,
/// backups (`~/.kakureneko/backups/<agent>`) and persisted files. Decoding is tolerant: an unknown
/// string decodes as `.unknown`; `init(label:)` also accepts common aliases.
public enum AgentID: String, Sendable, Hashable, CaseIterable, Comparable {
    case claude, codex, gemini, agy, copilot, vscode, cursor, opencode, kilo, aider
    case droid, qwen, auggie, openhands, devin, qoder, codebuddy, iflow, grok, kimi, vibe, kiro, goose
    case cline, windsurf, amp, pi, junie, rovo, hermes, crush
    case continueCLI = "continue"
    case warp, zed, xcode, jetbrains, plandex
    case unknown

    /// Display name used in notifications and the UI (brief §8.4 `{Agent}`).
    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .agy: "Antigravity"
        case .copilot: "Copilot"
        case .vscode: "VS Code agent"
        case .cursor: "Cursor"
        case .opencode: "opencode"
        case .kilo: "Kilo Code"
        case .aider: "Aider"
        case .droid: "Factory Droid"
        case .qwen: "Qwen Code"
        case .auggie: "Auggie"
        case .openhands: "OpenHands"
        case .devin: "Devin"
        case .qoder: "Qoder"
        case .codebuddy: "CodeBuddy"
        case .iflow: "iFlow"
        case .grok: "Grok Build"
        case .kimi: "Kimi Code"
        case .vibe: "Mistral Vibe"
        case .kiro: "Kiro"
        case .goose: "Goose"
        case .cline: "Cline"
        case .windsurf: "Windsurf"
        case .amp: "Amp"
        case .pi: "Pi"
        case .junie: "Junie"
        case .rovo: "Rovo Dev"
        case .hermes: "Hermes"
        case .crush: "Crush"
        case .continueCLI: "Continue"
        case .warp: "Warp agent"
        case .zed: "Zed agent"
        case .xcode: "Xcode agent"
        case .jetbrains: "JetBrains AI"
        case .plandex: "Plandex"
        case .unknown: "An agent"
        }
    }

    /// Accepts the raw value or a known alias (case-insensitive). Returns `.unknown` otherwise.
    public init(label: String) {
        let key = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = AgentID(rawValue: key) {
            self = exact
            return
        }
        switch key {
        case "claude-code", "claudecode", "claude_code": self = .claude
        case "cursor-agent", "cursor_agent": self = .cursor
        case "antigravity": self = .agy
        case "github-copilot", "copilot-cli": self = .copilot
        case "kilocode", "kilo-code": self = .kilo
        case "cn", "continuecli", "continue-cli": self = .continueCLI
        case "rovodev", "rovo-dev", "acli": self = .rovo
        case "kiro-cli", "kiro-cli-chat": self = .kiro
        case "qodercli": self = .qoder
        case "cbc": self = .codebuddy
        case "omp", "pi-rpc": self = .pi
        case "goosed": self = .goose
        case "factory", "factory-droid": self = .droid
        case "kimi-code": self = .kimi
        case "mistral-vibe": self = .vibe
        case "augment", "augment-code": self = .auggie
        case "devin-desktop", "codeium": self = .windsurf
        case "pdx": self = .plandex
        default: self = .unknown
        }
    }

    /// Agents that get an installer in this build (DECISIONS "Scope for v1").
    public static let installableInV1: [AgentID] = [
        .claude, .codex, .gemini, .agy, .copilot, .cursor, .opencode, .aider,
        .droid, .qwen, .auggie, .qoder, .codebuddy, .iflow, .devin,
        .windsurf,
    ]

    /// The Claude-compatible family installed through one generic routine (DECISIONS).
    public static let claudeCompatibleFamily: Set<AgentID> = [.droid, .qwen, .auggie, .qoder, .codebuddy, .iflow, .devin]

    /// Agents covered by the T3 heuristic only (no hook in v1; push says "went quiet").
    public var isHeuristicOnlyInV1: Bool { !AgentID.installableInV1.contains(self) && self != .vscode }

    public static func < (lhs: AgentID, rhs: AgentID) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension AgentID: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = AgentID(label: raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Lets `[AgentID: T]` encode as a JSON object keyed by raw value.
extension AgentID: CodingKeyRepresentable {
    public var codingKey: any CodingKey { AgentCodingKey(stringValue: rawValue) }
    public init?<T: CodingKey>(codingKey: T) {
        self = AgentID(label: codingKey.stringValue)
    }
}

private struct AgentCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
