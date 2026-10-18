import Darwin
import KakurenekoKit
import Foundation

/// Everything the rules need to know about one app group (all read-only facts gathered by the engine).
struct GroupFacts: Sendable {
    var app: AppCandidate
    /// Main process (kernel table row).
    var main: ProcessEntry
    /// Owned members, main first (see `ProcessGrouping`).
    var members: [ProcessEntry]
    /// The main process's ancestor chain (nearest first) from the kernel table — P-B defense in depth.
    var mainAncestors: [pid_t]
    /// Some member plays or records audio (P-F).
    var audioActive: Bool
    /// Some member is traced by a debugger (P-H).
    var traced: Bool

    var memberPIDs: Set<pid_t> { Set(members.map(\.pid)).union([main.pid]) }
}

/// The environment the rules are evaluated in.
struct ProtectionContext: Sendable {
    var topology: AgentTopology
    var settings: PauseSettings
    /// Kakureneko's own processes (the app, the guard): any group containing one is never touched.
    var selfPIDs: Set<pid_t>
}

/// Protection rules P-A…P-K (brief §6.3, R06 §3.3) as pure functions.
///
/// Every reason except P-G/P-I protects the WHOLE group. P-G (download) and P-I (busy at lid close) only downgrade
/// Freeze to Throttle. `KakurenekoPause` never infers "no agent" from `topology.isEmpty`.
enum ProtectionRules {
    /// P-I threshold: more than 20 % of one core over the trailing window.
    static let busyThreshold = 0.20

    /// Whole-group protections, in rule order; empty = the group may be paused.
    static func protections(for group: GroupFacts, in context: ProtectionContext) -> [ProtectionReason] {
        var reasons: [ProtectionReason] = []
        let pids = group.memberPIDs
        let topology = context.topology
        let bundleID = group.app.bundleID

        if bundleID == KakurenekoID.bundleIdentifier || !pids.isDisjoint(with: context.selfPIDs) {
            reasons.append(.kakurenekoItself)
        }
        // P-A: (1) an agent or agent descendant belongs to the group (responsibility grouping over the agent trees),
        // (2) a member holds an agent's pty master, (3) a member is in an agent's ancestor chain, and in-app agents:
        // any group containing a live session's host app.
        if !pids.isDisjoint(with: topology.allAgentTreePIDs)
            || !pids.isDisjoint(with: topology.ptyMasterHolderPIDs)
            || !pids.isDisjoint(with: topology.ancestorPIDs)
            || !pids.isDisjoint(with: topology.sessionHostPIDs) {
            reasons.append(.agentHost)
        }
        // P-B: the app was launched by an agent (Playwright/CDP browsers share the user's bundle id: per pid only).
        if !pids.isDisjoint(with: topology.agentLaunchedAppPIDs)
            || !Set(group.mainAncestors).isDisjoint(with: topology.allAgentTreePIDs) {
            reasons.append(.launchedByAgent)
        }
        // P-C / P-D: connected to an agent tree / owns a listener an agent tree connects to.
        if topology.ipcPeers.contains(where: { $0.kind != .listener && pids.contains($0.peerPID) }) {
            reasons.append(.ipcPeer)
        }
        if topology.ipcPeers.contains(where: { $0.kind == .listener && pids.contains($0.peerPID) }) {
            reasons.append(.listenerInUse)
        }
        // P-E: an agent tree runs an automation helper whose target is this app, or whose target is unknown.
        if topology.automationHelpers.contains(where: { helper in
            helper.likelyTargetBundleIDs.isEmpty || (bundleID.map(helper.likelyTargetBundleIDs.contains) ?? false)
        }) {
            reasons.append(.automationTarget)
        }
        if group.audioActive { reasons.append(.audio) }
        if group.traced { reasons.append(.traced) }
        if NeverPauseList.contains(bundleID) { reasons.append(.staticNeverList) }
        if let bundleID, context.settings.neverPauseBundleIDs.contains(bundleID) { reasons.append(.userNeverList) }
        // Rule I: any member with a controlling tty is a CLI job (job control; agents the signature table missed).
        if group.main.hasControllingTTY || group.members.contains(where: \.hasControllingTTY) {
            reasons.append(.notCandidate)
        }
        return reasons
    }

    /// R06 §5.4 "Default modes by category": browsers (agents drive them — Claude in Chrome, CDP — and they show
    /// hang warnings when stopped) and chat, mail and meeting apps (sessions, incoming calls) are throttled, never
    /// frozen. Matched by bundle id, plus any app registered to open `https` URLs (`browserBundleIDs`).
    static let throttleOnlyBundleIDs: Set<String> = [
        // Browsers
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.beta",
        "com.google.Chrome.dev", "com.google.Chrome.canary", "org.chromium.Chromium", "company.thebrowser.Browser",
        "company.thebrowser.dia", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly", "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi", "app.zen-browser.zen", "com.kagi.kagimacOS", "ai.perplexity.comet",
        // Chat, mail, meetings
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.microsoft.teams2", "com.microsoft.teams",
        "com.microsoft.Outlook", "com.apple.mail", "com.apple.MobileSMS", "com.apple.FaceTime", "net.whatsapp.WhatsApp",
        "desktop.WhatsApp", "us.zoom.xos", "ru.keepcoder.Telegram", "org.telegram.desktop",
        "org.whispersystems.signal-desktop", "com.readdle.smartemail-Mac", "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark",
        "com.skype.skype", "com.superhuman.electron",
    ]

    /// `.categoryDefault` when `bundleID` is a browser or a chat/mail/meeting app (Freeze only; never protects).
    static func categoryDowngrade(bundleID: String?, browserBundleIDs: Set<String>) -> ProtectionReason? {
        guard let bundleID else { return nil }
        return throttleOnlyBundleIDs.contains(bundleID) || browserBundleIDs.contains(bundleID) ? .categoryDefault : nil
    }

    /// Downgrade-only reasons. No CPU history means "assume busy" (Throttle only).
    static func downgrades(downloadInProgress: Bool, busyFraction: Double?) -> [ProtectionReason] {
        var reasons: [ProtectionReason] = []
        if downloadInProgress { reasons.append(.download) }
        if busyFraction.map({ $0 > busyThreshold }) ?? true { reasons.append(.busyAtLidClose) }
        return reasons
    }

    /// The mode for an unprotected group.
    /// - Parameters:
    ///   - requested: `settings.mode` (`.quit` is treated as `.throttle`; Quit is gated by `quitEligible`).
    ///   - freezePermitted: grouping self-test allows Freeze AND the topology is complete.
    ///   - downgrades: P-G / P-I reasons (they also block Quit).
    ///   - quitEligible: Quit opt-in, memory pressure ≥ warning, `proc_get_dirty` tracked and clean.
    static func mode(requested: PauseMode, freezePermitted: Bool, downgrades: [ProtectionReason],
                     quitEligible: Bool) -> (mode: PauseMode, downgradedBecause: ProtectionReason?) {
        if quitEligible && downgrades.isEmpty { return (.quit, nil) }
        guard requested == .freeze else { return (.throttle, nil) }
        if let first = downgrades.first { return (.throttle, first) }
        guard freezePermitted else { return (.throttle, .uncertain) }
        return (.freeze, nil)
    }
}

/// Rule P-I history: per candidate group (keyed by the main's identity), per-member cumulative CPU samples over the
/// last 2 minutes, recorded by `observe(now:)` on every process-scan tick while the lid is closed.
struct CPUHistory: Sendable {
    /// Trailing window kept and evaluated.
    static let window: TimeInterval = 120
    /// Less history than this counts as "no history".
    static let minimumSpan: TimeInterval = 30
    /// At most this many groups are tracked (defensive bound).
    static let maximumGroups = 256

    struct Sample: Sendable, Hashable {
        var at: Date
        /// Cumulative CPU nanoseconds per member identity.
        var cpu: [ProcessIdentity: UInt64]
    }

    private(set) var series: [ProcessIdentity: [Sample]] = [:]

    /// Appends one sample per group, prunes samples older than the window and forgets groups not seen now.
    mutating func record(_ groups: [ProcessIdentity: [ProcessIdentity: UInt64]], at now: Date) {
        var next: [ProcessIdentity: [Sample]] = [:]
        for (app, cpu) in groups.prefix(Self.maximumGroups) {
            var samples = (series[app] ?? []).filter { now.timeIntervalSince($0.at) <= Self.window && $0.at <= now }
            samples.append(Sample(at: now, cpu: cpu))
            next[app] = samples
        }
        series = next
    }

    /// Fraction of one core used by the group over the trailing window; nil when there is not enough history.
    func busyFraction(for app: ProcessIdentity, now: Date) -> Double? {
        let samples = (series[app] ?? []).filter { now.timeIntervalSince($0.at) <= Self.window && $0.at <= now }
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= Self.minimumSpan else { return nil }
        var nanoseconds: Double = 0
        for (member, value) in last.cpu {
            // Baseline: the member's earliest sample in the window; a member that started inside the window counts
            // from zero (all of its CPU was spent inside the window).
            let baseline: UInt64
            if member.startDate >= first.at {
                baseline = 0
            } else if let earliest = samples.first(where: { $0.cpu[member] != nil }), earliest.at < last.at {
                baseline = earliest.cpu[member] ?? 0
            } else {
                continue // seen only in the newest sample but older than the window: no usable baseline
            }
            if value > baseline { nanoseconds += Double(value - baseline) }
        }
        return nanoseconds / 1e9 / span
    }
}
