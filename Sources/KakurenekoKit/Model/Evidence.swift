import Foundation

/// Evidence kinds sampled per agent process tree (brief §5.4).
public enum EvidenceKind: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    /// E1 — tree CPU ≥ 3 % of one core averaged over 60 s (rusage ticks × timebase 125/3 on Apple Silicon).
    case treeCPU = "E1"
    /// E2 — any new descendant within 60 s that is NOT (a) `caffeinate` (exe basename or argv0 — Claude respawns
    /// `caffeinate -i -t 300` every ~4 min while busy, R02 §4.1; that is E6), (b) matched agent infrastructure,
    /// (c) a respawn with the same argv as a descendant of the same tree that exited within the last 10 min
    /// (keep-alive loops). Without these exclusions the stall guard never fires on the 13 h stale-busy case.
    case childChurn = "E2"
    /// E3 — any write to the session store within 60 s (never the main transcript mtime alone).
    case sessionStoreWrite = "E3"
    /// E4 — a new ESTABLISHED TCP connection to a model API, or a socket-count change.
    case modelAPISocket = "E4"
    /// E5 — controlling tty mtime within 30 s.
    case ttyActivity = "E5"
    /// E6 — agent-owned power assertion (never a lone "Electron" assertion).
    case powerAssertion = "E6"

    /// The kinds that prove the agent's tree is doing work and refresh `lastProgressAt` (stall guard, brief §5.5:
    /// "a 40-minute build counts as progress through E1/E2"): E1, E2, E3. (fix, ARCHITECTURE §11.C) E4 and E5 alone
    /// do NOT: an idle Claude TUI writes its tty and opens a fresh model-API connection every few minutes (measured on
    /// macOS 26, several idle sessions at the same second), so counting them kept a stale-busy session (R02 §4.1)
    /// out of `.stalled` forever. E6 never counts. E4/E5 still count toward the T3 two-kind threshold.
    public var countsAsProgress: Bool { self == .treeCPU || self == .childChurn || self == .sessionStoreWrite }

    public static func < (lhs: EvidenceKind, rhs: EvidenceKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Evidence for one agent process tree at one sample time.
///
/// `active` already applies the per-kind thresholds over the sampler's trailing 60 s window.
/// The sustain/exit logic ("≥ 2 kinds for 20 s → working; < 2 for 5 min → idle") is the
/// SessionEngine's job, not the sampler's.
public struct EvidenceSample: Sendable, Hashable, Codable {
    public var sampledAt: Date
    /// Kinds that currently hold.
    public var active: Set<EvidenceKind>
    /// Average tree CPU over the window, in % of one core.
    public var treeCPUPercent: Double?
    /// Cumulative tree CPU seconds (monotonic per tree while it lives) — used by the pause watchdog
    /// ("agent claims working but tree CPU not advancing for 5 min while apps are frozen").
    public var treeCPUSeconds: Double?
    /// New non-infrastructure descendants within the window.
    public var newDescendantCount: Int
    /// Last session-store write seen.
    public var lastStoreWriteAt: Date?
    /// ESTABLISHED model-API sockets now.
    public var modelSocketCount: Int?
    /// Last tty activity (mtime of `/dev/ttysNNN`).
    public var ttyLastActivityAt: Date?
    /// Names of attributed power assertions (e.g. `caffeinate command-line tool`).
    public var assertionNames: [String]

    public init(
        sampledAt: Date,
        active: Set<EvidenceKind> = [],
        treeCPUPercent: Double? = nil,
        treeCPUSeconds: Double? = nil,
        newDescendantCount: Int = 0,
        lastStoreWriteAt: Date? = nil,
        modelSocketCount: Int? = nil,
        ttyLastActivityAt: Date? = nil,
        assertionNames: [String] = []
    ) {
        self.sampledAt = sampledAt
        self.active = active
        self.treeCPUPercent = treeCPUPercent
        self.treeCPUSeconds = treeCPUSeconds
        self.newDescendantCount = newDescendantCount
        self.lastStoreWriteAt = lastStoreWriteAt
        self.modelSocketCount = modelSocketCount
        self.ttyLastActivityAt = ttyLastActivityAt
        self.assertionNames = assertionNames
    }

    public static func none(at date: Date) -> EvidenceSample { EvidenceSample(sampledAt: date) }

    /// The sampler's trailing window for E1–E4 (brief §5.4): evidence in a sample can be up to this old. Shared by
    /// KakurenekoProcesses (window length) and KakurenekoSessions (evidence sampled less than one window after a finish
    /// or after a wait began may still describe the turn before it).
    public static let window: TimeInterval = 60

    /// Any of E1–E3 holds → refresh `lastProgressAt` (`EvidenceKind.countsAsProgress`).
    public var showsProgress: Bool { active.contains { $0.countsAsProgress } }
    /// Raw per-tick T3 condition: at least two kinds hold (sustain logic lives in the engine).
    public var meetsHeuristicThreshold: Bool { active.count >= 2 }
}
