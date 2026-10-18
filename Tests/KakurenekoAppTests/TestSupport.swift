@testable import KakurenekoApp
import KakurenekoKit
import Foundation
import Testing

/// Polls a main-actor condition (stream deliveries are asynchronous). Bounded: ≤ `timeout`, 5 ms steps.
@MainActor
/// Positive waits only (returns as soon as `condition` holds); the generous default absorbs a busy main actor.
func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        if clock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// A fixed instant for formatting tests (2026-10-12T22:00:00Z, same as `TestClock.defaultStart`).
let fixedNow = TestClock.defaultStart
let utc = TimeZone(identifier: "UTC")!

/// Records window requests instead of opening AppKit windows.
@MainActor
final class RecordingPresenter: WindowPresenting {
    private(set) var settingsRequests: [SettingsPane?] = []
    private(set) var onboardingShown = 0
    private(set) var onboardingClosed = 0

    func showSettings(pane: SettingsPane?) { settingsRequests.append(pane) }
    func showOnboarding() { onboardingShown += 1 }
    func closeOnboarding() { onboardingClosed += 1 }
}

/// A `KakurenekoControlling` that forwards to `PreviewKakurenekoController` (so `calls` and snapshots behave the same)
/// but can make chosen calls throw.
actor ScriptedController: KakurenekoControlling {
    let inner: PreviewKakurenekoController
    private var failures: [String: any Error] = [:]

    init(snapshot: AppSnapshot = PreviewKakurenekoController.sampleSnapshot()) {
        inner = PreviewKakurenekoController(snapshot: snapshot)
    }

    func fail(_ call: String, with error: any Error) { failures[call] = error }

    private func check(_ call: String) throws {
        if let error = failures[call] { throw error }
    }

    var calls: [String] { get async { await inner.calls } }

    func start() async { await inner.start() }
    func prepareForTermination() async { await inner.prepareForTermination() }
    nonisolated func terminateSynchronously() { inner.terminateSynchronously() }
    nonisolated func snapshots() -> AsyncStream<AppSnapshot> { inner.snapshots() }
    func currentSnapshot() async -> AppSnapshot { await inner.currentSnapshot() }
    func setEnabled(_ enabled: Bool) async { await inner.setEnabled(enabled) }
    func keepAwake(for seconds: TimeInterval) async { await inner.keepAwake(for: seconds) }
    func cancelKeepAwake() async { await inner.cancelKeepAwake() }
    func sleepNow() async { await inner.sleepNow() }
    func cancelWindDown() async { await inner.cancelWindDown() }
    func dismissSession(_ key: SessionKey) async { await inner.dismissSession(key) }
    func resumeAllApps() async { await inner.resumeAllApps() }
    func setNeverPause(bundleID: String, _ neverPause: Bool) async { await inner.setNeverPause(bundleID: bundleID, neverPause) }
    func updateSettings(_ settings: KakurenekoSettings) async { await inner.updateSettings(settings) }
    func completeOnboarding() async { await inner.completeOnboarding() }
    func installPrivilegedHelper() async throws {
        try check("installPrivilegedHelper")
        try await inner.installPrivilegedHelper()
    }
    func uninstallPrivilegedHelper() async throws {
        try check("uninstallPrivilegedHelper")
        try await inner.uninstallPrivilegedHelper()
    }
    func refreshPrivilegedStatus() async { await inner.refreshPrivilegedStatus() }
    func requestNotificationPermission() async -> MacAlertAuthorization { await inner.requestNotificationPermission() }
    func sendTestNotification() async throws {
        try check("sendTestNotification")
        try await inner.sendTestNotification()
    }
    func handleCloudPush() async { await inner.handleCloudPush() }
    func forgetPhone(deviceID: String) async { await inner.forgetPhone(deviceID: deviceID) }
    func lookForPhones() async { await inner.lookForPhones() }
    func refreshIntegrations() async { await inner.refreshIntegrations() }
    func previewIntegration(_ agent: AgentID, operation: InstallPlan.Operation) async throws -> InstallPlan {
        try check("previewIntegration")
        return try await inner.previewIntegration(agent, operation: operation)
    }
    func installIntegration(_ agent: AgentID) async throws -> InstallResult {
        try check("installIntegration")
        return try await inner.installIntegration(agent)
    }
    func uninstallIntegration(_ agent: AgentID) async throws -> InstallResult {
        try check("uninstallIntegration")
        return try await inner.uninstallIntegration(agent)
    }
    func repairIntegration(_ agent: AgentID) async throws -> InstallResult {
        try check("repairIntegration")
        return try await inner.repairIntegration(agent)
    }
    func clearResumeOffer() async { await inner.clearResumeOffer() }
}

/// Builds a model connected to a fresh `PreviewKakurenekoController` and waits for its first snapshot.
@MainActor
func connectedModel(snapshot: AppSnapshot = PreviewKakurenekoController.sampleSnapshot(),
                    environment: AppEnvironment = .inert(),
                    start: Bool = false) async throws -> (AppModel, PreviewKakurenekoController) {
    let controller = PreviewKakurenekoController(snapshot: snapshot)
    let model = AppModel(environment: environment)
    model.connect(to: controller, start: start)
    try #require(await waitUntil { model.hasReceivedSnapshot })
    return (model, controller)
}

/// The repository root (for script and resource checks).
func repositoryRoot(filePath: String = #filePath) -> URL {
    URL(filePath: filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
