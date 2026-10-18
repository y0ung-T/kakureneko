import Foundation

/// How much of Kakureneko is operational.
public enum OperatingMode: String, Sendable, Hashable, Codable {
    /// Launching / reconciling.
    case starting
    /// Privileged parts installed: closed-lid mode, pausing and sleep work.
    case full
    /// Privileged install missing/broken: detection + phone pushes only, never relies on staying awake.
    case notificationsOnly
    /// The user turned Kakureneko off (`general.enabled == false`).
    case disabled
}

/// A user-visible warning in the menu.
public struct AppWarning: Sendable, Hashable, Codable, Identifiable {
    public enum Severity: String, Sendable, Hashable, Codable { case info, warning, critical }
    /// Stable id (`privileged-missing`, `app-tamer`, `freeze-unavailable`, `hotspot`, `low-power-mode`,
    /// `mac-notifications-off`, `icloud-unavailable`, `phone-alerts-error`, `dry-run`, `dry-run-privileged-simulated`,
    /// `kernel-sleep-disabled`
    /// (critical: the REAL kernel flag is set while dry-run is on), `disarm-failed`, `arming-blocked`,
    /// `heartbeat-path-mismatch`, `failsafe-damaged`, `integration-repair:<agent>`).
    public var id: String
    public var severity: Severity
    public var title: String
    public var message: String

    public init(id: String, severity: Severity, title: String, message: String) {
        self.id = id
        self.severity = severity
        self.title = title
        self.message = message
    }
}

/// Everything the UI shows, published by the coordinator through `KakurenekoControlling.snapshots()`.
/// Value type, Equatable so SwiftUI can diff cheaply. The UI never reaches into services directly.
public struct AppSnapshot: Sendable, Hashable {
    public var generatedAt: Date
    public var mode: OperatingMode
    /// Effective dry-run (env or settings).
    public var isDryRun: Bool
    /// True when `KAKURENEKO_DRY_RUN` forced it (UI shows the toggle locked).
    public var isDryRunForced: Bool
    /// Recent "would …" lines (newest last), ≤ 50.
    public var dryRunLog: [DryRunEntry]

    /// Live sessions (ended excluded), sorted by `SessionState.displayRank`, then most recent activity.
    public var sessions: [AgentSession]
    public var aggregate: SessionAggregate

    public var powerPhase: PowerPhase
    public var power: PowerSnapshot?
    public var privileged: PrivilegedStatus
    /// Keep-awake override from the menu or phone.
    public var keepAwakeUntil: Date?
    /// Most recent Kakureneko-initiated sleep.
    public var lastSleep: SleepRecord?

    public var pausedApps: [PausedApp]
    public var lastPauseReport: PauseReport?
    /// Freeze is only selectable when the grouping self-test passed.
    public var groupingSelfTest: GroupingSelfTest?

    public var notifications: NotificationStatus
    public var integrations: [IntegrationStatus]
    /// Sessions offered for reopening after an opt-in shutdown (`resume.json`).
    public var resumeOffer: [ResumeEntry]

    public var settings: KakurenekoSettings
    public var warnings: [AppWarning]

    public init(
        generatedAt: Date,
        mode: OperatingMode = .starting,
        isDryRun: Bool = false,
        isDryRunForced: Bool = false,
        dryRunLog: [DryRunEntry] = [],
        sessions: [AgentSession] = [],
        aggregate: SessionAggregate = .empty,
        powerPhase: PowerPhase = .disarmed,
        power: PowerSnapshot? = nil,
        privileged: PrivilegedStatus = .unknown,
        keepAwakeUntil: Date? = nil,
        lastSleep: SleepRecord? = nil,
        pausedApps: [PausedApp] = [],
        lastPauseReport: PauseReport? = nil,
        groupingSelfTest: GroupingSelfTest? = nil,
        notifications: NotificationStatus = .initial,
        integrations: [IntegrationStatus] = [],
        resumeOffer: [ResumeEntry] = [],
        settings: KakurenekoSettings = .default,
        warnings: [AppWarning] = []
    ) {
        self.generatedAt = generatedAt
        self.mode = mode
        self.isDryRun = isDryRun
        self.isDryRunForced = isDryRunForced
        self.dryRunLog = dryRunLog
        self.sessions = sessions
        self.aggregate = aggregate
        self.powerPhase = powerPhase
        self.power = power
        self.privileged = privileged
        self.keepAwakeUntil = keepAwakeUntil
        self.lastSleep = lastSleep
        self.pausedApps = pausedApps
        self.lastPauseReport = lastPauseReport
        self.groupingSelfTest = groupingSelfTest
        self.notifications = notifications
        self.integrations = integrations
        self.resumeOffer = resumeOffer
        self.settings = settings
        self.warnings = warnings
    }

    /// Empty snapshot shown before the coordinator publishes.
    public static func placeholder(at date: Date = Date()) -> AppSnapshot { AppSnapshot(generatedAt: date) }

    /// Countdown end, if counting down.
    public var countdownEndsAt: Date? {
        if case .countdown(let endsAt, _, _) = powerPhase { return endsAt }
        return nil
    }

    /// One-line status for the menu header: "2 working · 1 waiting", "Idle", "Off".
    public var statusLine: String {
        if mode == .disabled { return "Off" }
        var parts: [String] = []
        if aggregate.workingCount > 0 { parts.append("\(aggregate.workingCount) working") }
        if aggregate.waitingCount > 0 { parts.append("\(aggregate.waitingCount) waiting") }
        if aggregate.stalledCount > 0 { parts.append("\(aggregate.stalledCount) stuck") }
        return parts.isEmpty ? "Idle" : parts.joined(separator: " · ")
    }
}
