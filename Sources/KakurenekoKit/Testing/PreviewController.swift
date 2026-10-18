import KakurenekoCloud
import Foundation
import Synchronization

/// A scriptable `KakurenekoControlling` for SwiftUI previews and app tests. Keeps an `AppSnapshot` in
/// memory, applies simple, plausible state changes for each action and records every call.
/// It never touches the system.
public actor PreviewKakurenekoController: KakurenekoControlling {
    public private(set) var calls: [String] = []
    private nonisolated let synchronousTerminations = Mutex(0)
    private var snapshot: AppSnapshot
    private nonisolated let broadcaster = AsyncBroadcaster<AppSnapshot>(replayLatest: true)

    public init(snapshot: AppSnapshot = PreviewKakurenekoController.sampleSnapshot()) {
        self.snapshot = snapshot
        broadcaster.yield(snapshot)
    }

    /// Replaces the snapshot and publishes it (tests/previews).
    public func publish(_ snapshot: AppSnapshot) {
        self.snapshot = snapshot
        broadcaster.yield(snapshot)
    }

    private func mutate(_ call: String, _ change: (inout AppSnapshot) -> Void = { _ in }) {
        calls.append(call)
        change(&snapshot)
        snapshot.generatedAt = Date()
        broadcaster.yield(snapshot)
    }

    public func start() async { mutate("start") { $0.mode = $0.privileged.isOperational ? .full : .notificationsOnly } }
    public func prepareForTermination() async { mutate("prepareForTermination") { $0.pausedApps = [] } }
    public nonisolated func terminateSynchronously() { synchronousTerminations.withLock { $0 += 1 } }
    /// How often `terminateSynchronously()` was called (nonisolated: it is synchronous).
    public nonisolated var terminateSynchronouslyCount: Int { synchronousTerminations.withLock { $0 } }

    public nonisolated func snapshots() -> AsyncStream<AppSnapshot> { broadcaster.stream() }
    public func currentSnapshot() async -> AppSnapshot { snapshot }

    public func setEnabled(_ enabled: Bool) async {
        mutate("setEnabled(\(enabled))") {
            $0.settings.general.enabled = enabled
            $0.mode = enabled ? ($0.privileged.isOperational ? .full : .notificationsOnly) : .disabled
        }
    }
    public func keepAwake(for seconds: TimeInterval) async {
        mutate("keepAwake(\(Int(seconds)))") { $0.keepAwakeUntil = Date().addingTimeInterval(seconds) }
    }
    public func cancelKeepAwake() async { mutate("cancelKeepAwake") { $0.keepAwakeUntil = nil } }
    public func sleepNow() async { mutate("sleepNow") }
    public func cancelWindDown() async { mutate("cancelWindDown") }
    public func dismissSession(_ key: SessionKey) async {
        mutate("dismissSession(\(key))") { $0.sessions.removeAll { $0.key == key } }
    }
    public func resumeAllApps() async { mutate("resumeAllApps") { $0.pausedApps = [] } }
    public func setNeverPause(bundleID: String, _ neverPause: Bool) async {
        mutate("setNeverPause(\(bundleID),\(neverPause))") { s in
            var list = Set(s.settings.pausing.neverPauseBundleIDs)
            if neverPause { list.insert(bundleID) } else { list.remove(bundleID) }
            s.settings.pausing.neverPauseBundleIDs = list.sorted()
        }
    }
    public func updateSettings(_ settings: KakurenekoSettings) async { mutate("updateSettings") { $0.settings = settings.normalized() } }
    public func completeOnboarding() async { mutate("completeOnboarding") { $0.settings.general.onboardingCompleted = true } }
    public func installPrivilegedHelper() async throws {
        mutate("installPrivilegedHelper") {
            $0.privileged = PrivilegedStatus(sudoRuleInstalled: true, failsafeLoaded: true, checkedAt: Date(), detail: "preview")
            $0.mode = .full
        }
    }
    public func uninstallPrivilegedHelper() async throws {
        mutate("uninstallPrivilegedHelper") {
            $0.privileged = PrivilegedStatus(sudoRuleInstalled: false, failsafeLoaded: false, checkedAt: Date(), detail: "preview")
            $0.mode = .notificationsOnly
        }
    }
    public func refreshPrivilegedStatus() async { mutate("refreshPrivilegedStatus") }
    public func requestNotificationPermission() async -> MacAlertAuthorization {
        mutate("requestNotificationPermission") { $0.notifications.macAuthorization = .authorized }
        return .authorized
    }
    public func sendTestNotification() async throws { mutate("sendTestNotification") }
    public func handleCloudPush() async { mutate("handleCloudPush") }
    public func forgetPhone(deviceID: String) async {
        mutate("forgetPhone(\(deviceID))") { $0.notifications.phones.removeAll { $0.deviceID == deviceID } }
    }
    public func lookForPhones() async { mutate("lookForPhones") }
    public func refreshIntegrations() async { mutate("refreshIntegrations") }
    public func previewIntegration(_ agent: AgentID, operation: InstallPlan.Operation) async throws -> InstallPlan {
        mutate("previewIntegration(\(agent.rawValue),\(operation.rawValue))")
        return InstallPlan(agent: agent, operation: operation, changes: [
            FileChange(path: "~/.example/hooks.json", kind: .modify, before: "{}\n", after: "{\"hooks\":{}}\n",
                       unifiedDiff: "--- a\n+++ b\n-{}\n+{\"hooks\":{}}\n"),
        ])
    }
    public func installIntegration(_ agent: AgentID) async throws -> InstallResult {
        let plan = InstallPlan(agent: agent, operation: .install)
        var status = snapshot.integrations.first { $0.agent == agent } ?? IntegrationStatus(agent: agent, supported: true, configDirExists: true)
        status.installed = true
        let final = status
        mutate("installIntegration(\(agent.rawValue))") { s in
            s.integrations.removeAll { $0.agent == agent }
            s.integrations.append(final)
        }
        return InstallResult(plan: plan, status: final)
    }
    public func uninstallIntegration(_ agent: AgentID) async throws -> InstallResult {
        var status = snapshot.integrations.first { $0.agent == agent } ?? IntegrationStatus(agent: agent, supported: true, configDirExists: true)
        status.installed = false
        let final = status
        mutate("uninstallIntegration(\(agent.rawValue))") { s in
            s.integrations.removeAll { $0.agent == agent }
            s.integrations.append(final)
        }
        return InstallResult(plan: InstallPlan(agent: agent, operation: .uninstall), status: final)
    }
    public func repairIntegration(_ agent: AgentID) async throws -> InstallResult {
        var status = snapshot.integrations.first { $0.agent == agent } ?? IntegrationStatus(agent: agent, supported: true, configDirExists: true)
        status.needsRepair = false
        let final = status
        mutate("repairIntegration(\(agent.rawValue))")
        return InstallResult(plan: InstallPlan(agent: agent, operation: .repair), status: final)
    }
    public func clearResumeOffer() async { mutate("clearResumeOffer") { $0.resumeOffer = [] } }

    /// A realistic snapshot: two sessions (one working, one waiting), armed, one throttled app.
    public static func sampleSnapshot(now: Date = Date()) -> AppSnapshot {
        let working = AgentSession(
            key: SessionKey(agent: .claude, id: "3514aa88-efa8-4a60-97d7-2878eed849d4"),
            agentProcess: ProcessIdentity(pid: 96888, startSec: 1_791_810_323, startUsec: 1234),
            host: HostApp(bundleID: "com.apple.Terminal", name: "Terminal"),
            cwd: "/Users/me/Developer/api", title: "Refactor auth middleware",
            state: .working(since: now.addingTimeInterval(-42 * 60)),
            turnStartedAt: now.addingTimeInterval(-42 * 60), lastHookAt: now.addingTimeInterval(-20),
            lastProgressAt: now.addingTimeInterval(-5), tiers: [.hook, .stateFile, .heuristic])
        let waiting = AgentSession(
            key: SessionKey(agent: .codex, id: "thread-7"),
            host: HostApp(bundleID: "com.microsoft.VSCode", name: "VS Code"),
            cwd: "/Users/me/Developer/web",
            state: .waiting(kind: .permission, since: now.addingTimeInterval(-3 * 60)),
            tiers: [.hook], waitingFor: "Waiting for permission")
        let sessions = [working, waiting]
        return AppSnapshot(
            generatedAt: now,
            mode: .full,
            sessions: sessions,
            aggregate: SessionAggregate.compute(from: sessions, stateVersion: 7, lastFinishedAt: nil),
            powerPhase: .armed(since: now.addingTimeInterval(-40 * 60)),
            power: PowerSnapshot(takenAt: now, lid: .open, sleepDisabled: true, batteryPercent: 64, onAC: false,
                                 timeToEmptyMinutes: 213, secondsSinceUserInput: 4, screenLocked: false),
            privileged: PrivilegedStatus(sudoRuleInstalled: true, failsafeLoaded: true, checkedAt: now, detail: nil),
            pausedApps: [PausedApp(appPID: 92564, bundleID: "company.thebrowser.Browser", name: "Arc", mode: .throttle,
                                   memberCount: 14, pausedAt: now.addingTimeInterval(-60))],
            notifications: NotificationStatus(
                macAuthorization: .authorized, macTimeSensitive: true, iCloud: .available,
                phones: [PhoneDevice(deviceID: "preview", name: "iPhone", model: "iPhone18,3", systemVersion: "26.6.1",
                                     appVersion: "0.1.0", alertsAuthorized: true, timeSensitiveAllowed: true,
                                     lastSeenAt: now.addingTimeInterval(-90))],
                lastDeliveredAt: now.addingTimeInterval(-300)),
            integrations: [
                IntegrationStatus(agent: .claude, supported: true, configDirExists: true, installed: true, lastEventSeen: now.addingTimeInterval(-20)),
                IntegrationStatus(agent: .codex, supported: true, configDirExists: true, installed: true, needsTrustStep: true),
                IntegrationStatus(agent: .gemini, supported: true, configDirExists: false),
            ]
        )
    }
}
