import KakurenekoKit
import Foundation

/// Window lengths and thresholds of brief §5.4 / ARCHITECTURE §9.2. The sustain/exit windows (20 s / 5 min) are the
/// SessionEngine's job; everything here only says whether a kind holds at one sample.
enum EvidencePolicy {
    /// E1/E2/E3/E4 trailing window.
    static let window: TimeInterval = EvidenceSample.window
    /// E1: average tree CPU over the window, in % of one core.
    static let treeCPUThresholdPercent = 3.0
    /// E2: a descendant whose argv matches one that exited within this long is a keep-alive respawn.
    static let respawnMemory: TimeInterval = 600
    /// E5: controlling-tty mtime recency.
    static let ttyWindow: TimeInterval = 30
    /// E6: assertion names that never count on their own (Claude Desktop holds one forever, R05 §5.1).
    static let ignoredAssertionNames: Set<String> = ["electron"]
    /// History kept for E1 beyond the window (interpolation needs one point before the window start).
    static let cpuHistoryRetention: TimeInterval = 300
}

// MARK: - E1 tree CPU

/// Cumulative CPU of an agent process tree (agent + descendants) and its trailing-window average.
///
/// `totalSeconds` is monotonic while the tree lives: each sample adds the positive per-member deltas, plus the full
/// CPU of members that are new since the previous sample (they were born inside the window). Members that exit stop
/// contributing; nothing is ever subtracted (the pause watchdog compares successive values).
struct TreeCPUAccumulator: Sendable {
    private(set) var memberSeconds: [ProcessIdentity: Double] = [:]
    private(set) var totalSeconds: Double = 0
    private(set) var history: [(at: Date, total: Double)] = []

    mutating func record(members: [(identity: ProcessIdentity, cpuSeconds: Double)], now: Date) {
        var next: [ProcessIdentity: Double] = [:]
        next.reserveCapacity(members.count)
        if history.isEmpty && memberSeconds.isEmpty {
            // First sight of the tree: everything it used so far.
            totalSeconds = members.reduce(0) { $0 + max(0, $1.cpuSeconds) }
        } else {
            for member in members {
                let previous = memberSeconds[member.identity]
                totalSeconds += max(0, member.cpuSeconds - (previous ?? 0))
            }
        }
        for member in members { next[member.identity] = max(member.cpuSeconds, memberSeconds[member.identity] ?? 0) }
        memberSeconds = next
        if let last = history.last, now <= last.at {
            // Time did not advance (or went backwards): refresh the newest point instead of adding one.
            history[history.count - 1].total = totalSeconds
        } else {
            history.append((now, totalSeconds))
        }
        prune(now: now)
    }

    /// Average CPU over `[now − window, now]` in % of one core. Uses linear interpolation at the window start when the
    /// history reaches back that far, else the observed span (≥ 1 s). nil without two points.
    func averagePercent(now: Date, window: TimeInterval = EvidencePolicy.window) -> Double? {
        guard history.count >= 2, let last = history.last else { return nil }
        let target = now.addingTimeInterval(-window)
        let baseline: Double
        let span: TimeInterval
        if let first = history.first, first.at <= target {
            var before = history[0]
            var after = history[history.count - 1]
            for index in 0..<(history.count - 1) where history[index].at <= target && history[index + 1].at > target {
                before = history[index]
                after = history[index + 1]
                break
            }
            if after.at <= target {
                baseline = after.total
            } else {
                let fraction = target.timeIntervalSince(before.at) / after.at.timeIntervalSince(before.at)
                baseline = before.total + (after.total - before.total) * fraction
            }
            span = last.at.timeIntervalSince(target)
        } else {
            baseline = history[0].total
            span = last.at.timeIntervalSince(history[0].at)
        }
        guard span >= 1 else { return nil }
        return max(0, last.total - baseline) / span * 100
    }

    private mutating func prune(now: Date) {
        let horizon = now.addingTimeInterval(-EvidencePolicy.cpuHistoryRetention)
        // Keep one point at or before the horizon so the window start can still be interpolated.
        while history.count > 2, history[1].at <= horizon { history.removeFirst() }
    }
}

// MARK: - E2 child churn

/// One descendant as E2 sees it.
struct DescendantInfo: Sendable, Hashable {
    var identity: ProcessIdentity
    /// Exact argv (memory only) — the keep-alive respawn key.
    var argvKey: String
    /// `caffeinate` by executable basename or argv[0] (Claude respawns `caffeinate -i -t 300` every ~4 min).
    var isCaffeinate: Bool
    /// Matched as agent infrastructure (`claude bg-spare`, `goosed`, …).
    var isInfrastructure: Bool

    init(identity: ProcessIdentity, argvKey: String, isCaffeinate: Bool = false, isInfrastructure: Bool = false) {
        self.identity = identity
        self.argvKey = argvKey
        self.isCaffeinate = isCaffeinate
        self.isInfrastructure = isInfrastructure
    }

    static func argvKey(executablePath: String?, argv: [String], comm: String) -> String {
        guard !argv.isEmpty else { return "exe:" + (executablePath ?? comm) }
        return argv.joined(separator: "\u{0}")
    }
}

/// E2: new descendants within the window, excluding (a) `caffeinate`, (b) agent infrastructure and (c) respawns
/// with the same argv as a descendant of the same tree that exited within the last 10 min.
struct DescendantChurnTracker: Sendable {
    private(set) var known: [ProcessIdentity: DescendantInfo] = [:]
    private(set) var recentlyExitedArgv: [String: Date] = [:]
    private(set) var countedArrivals: [Date] = []
    private var initialized = false

    mutating func update(current: [DescendantInfo], now: Date) {
        var currentByIdentity: [ProcessIdentity: DescendantInfo] = [:]
        for info in current { currentByIdentity[info.identity] = info }
        defer {
            known = currentByIdentity
            initialized = true
            countedArrivals.removeAll { now.timeIntervalSince($0) > EvidencePolicy.window }
        }
        // Descendants present when the tree is first seen are the baseline, not churn.
        guard initialized else { return }

        // Exits first, so a respawn observed in the same sample as its predecessor's exit is recognised.
        for (identity, info) in known where currentByIdentity[identity] == nil {
            recentlyExitedArgv[info.argvKey] = now
        }
        recentlyExitedArgv = recentlyExitedArgv.filter { now.timeIntervalSince($0.value) <= EvidencePolicy.respawnMemory }

        for info in current where known[info.identity] == nil {
            if info.isCaffeinate || info.isInfrastructure { continue }
            if recentlyExitedArgv[info.argvKey] != nil { continue }
            countedArrivals.append(now)
        }
    }

    func newDescendantCount(now: Date) -> Int {
        countedArrivals.filter { now.timeIntervalSince($0) <= EvidencePolicy.window }.count
    }

    func isActive(now: Date) -> Bool { newDescendantCount(now: now) > 0 }
}

// MARK: - E4 model-API sockets

/// E4: a new ESTABLISHED TCP connection to the model-API set, or a change of their count, within the window. The first
/// observation of a tree is the baseline (existence alone is weak: keep-alive lingering was never measured).
struct ModelSocketTracker: Sendable {
    private(set) var previous: Set<String>?
    private(set) var lastChangeAt: Date?

    mutating func update(connections: Set<String>, now: Date) {
        defer { previous = connections }
        guard let previous else { return }
        if connections.count != previous.count || !connections.isSubset(of: previous) {
            lastChangeAt = now
        }
    }

    func isActive(now: Date) -> Bool {
        guard let lastChangeAt else { return false }
        return now.timeIntervalSince(lastChangeAt) <= EvidencePolicy.window
    }

    var count: Int? { previous?.count }
}

// MARK: - E3, E5

enum RecencyEvidence {
    /// E3: a session-store write within the window (writes stamped slightly after `now` count too).
    static func storeWriteActive(lastWrite: Date?, now: Date) -> Bool {
        guard let lastWrite else { return false }
        return now.timeIntervalSince(lastWrite) <= EvidencePolicy.window
    }

    /// E5: the controlling tty was written within 30 s.
    static func ttyActive(modified: Date?, now: Date) -> Bool {
        guard let modified else { return false }
        return now.timeIntervalSince(modified) <= EvidencePolicy.ttyWindow
    }
}

// MARK: - E6 power assertions

/// One entry of `IOPMCopyAssertionsByProcess`.
struct PowerAssertionInfo: Sendable, Hashable {
    var type: String
    var name: String
}

/// E6 attribution: assertions owned by the agent itself, or by a `caffeinate` whose parent is the agent (Claude,
/// Qwen, Kilo). A lone `"Electron"` assertion never counts.
enum AssertionAttribution {
    static func names(
        forAgent agentPID: Int32,
        assertionsByPID: [Int32: [PowerAssertionInfo]],
        caffeinateParents: [Int32: Int32]
    ) -> [String] {
        var owners: [Int32] = [agentPID]
        for (caffeinate, parent) in caffeinateParents where parent == agentPID { owners.append(caffeinate) }
        var names: Set<String> = []
        for owner in owners {
            for assertion in assertionsByPID[owner] ?? [] {
                let trimmed = assertion.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !EvidencePolicy.ignoredAssertionNames.contains(trimmed.lowercased()) else { continue }
                names.insert(String(trimmed.prefix(140)))
            }
        }
        return names.sorted()
    }
}

// MARK: - Assembly

/// Raw per-tree observations of one sample, turned into an `EvidenceSample`.
struct EvidenceInputs: Sendable {
    var cpu: TreeCPUAccumulator
    var churn: DescendantChurnTracker
    var sockets: ModelSocketTracker
    var lastStoreWrite: Date?
    var ttyModified: Date?
    var assertionNames: [String]

    func sample(at now: Date) -> EvidenceSample {
        var active: Set<EvidenceKind> = []
        let percent = cpu.averagePercent(now: now)
        if let percent, percent >= EvidencePolicy.treeCPUThresholdPercent { active.insert(.treeCPU) }
        if churn.isActive(now: now) { active.insert(.childChurn) }
        if RecencyEvidence.storeWriteActive(lastWrite: lastStoreWrite, now: now) { active.insert(.sessionStoreWrite) }
        if sockets.isActive(now: now) { active.insert(.modelAPISocket) }
        if RecencyEvidence.ttyActive(modified: ttyModified, now: now) { active.insert(.ttyActivity) }
        if !assertionNames.isEmpty { active.insert(.powerAssertion) }
        return EvidenceSample(
            sampledAt: now,
            active: active,
            treeCPUPercent: percent,
            treeCPUSeconds: cpu.history.isEmpty ? nil : cpu.totalSeconds,
            newDescendantCount: churn.newDescendantCount(now: now),
            lastStoreWriteAt: lastStoreWrite,
            modelSocketCount: sockets.count,
            ttyLastActivityAt: ttyModified,
            assertionNames: assertionNames
        )
    }
}
