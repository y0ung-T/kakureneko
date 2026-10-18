import Foundation

/// Every action the UI can take, and the snapshot stream it observes. Implemented by
/// `KakurenekoCoordinator.KakurenekoCoordinator` (an actor); `PreviewKakurenekoController` (Kit/Testing) is a
/// scriptable stand-in for SwiftUI previews and app tests.
///
/// The app target talks ONLY to this protocol + `AppSnapshot` (never to services directly).
///
/// Isolation: the implementation is an actor; `snapshots()` is `nonisolated` (backed by an
/// `AsyncBroadcaster` with `replayLatest`). UI code calls the async methods from `Task { await … }`.
/// Errors thrown are user-presentable (`LocalizedError` or `SideEffectError`/installer errors).
public protocol KakurenekoControlling: Sendable {
    // MARK: Lifecycle (called by the app delegate — never from a MenuBarExtra `.task`)

    /// Loads settings, reconciles (journal recovery, disarm a stale flag, drain the inbox, deploy the hook
    /// helper, privileged health check), starts every service and the main loop. Idempotent.
    func start() async
    /// `applicationWillTerminate`: thaw everything, disarm, flush the outbox briefly, stop services.
    func prepareForTermination() async
    /// (fix) The SYNCHRONOUS last resort of every quit path that may skip `prepareForTermination` (the app's quit
    /// watchdog when prepare hangs, `applicationWillTerminate`): thaw every journaled pause, then clear a flag this
    /// process really set (bounded wait), exactly like the coordinator's SIGTERM handler. Cheap and idempotent after
    /// a completed `prepareForTermination`. Implementations are `nonisolated`; it may block for ≤ ~2 s.
    func terminateSynchronously()

    // MARK: Observation

    /// Fan-out: emits the current snapshot immediately, then on every change (leading-edge coalesced, ≤ 4 Hz).
    ///
    /// Snapshots with `mode == .starting` are published before `start()` has reconciled: their `isDryRun` reflects
    /// ONLY `KAKURENEKO_DRY_RUN` (the settings toggle `general.dryRun` is applied in start step 6, after journal
    /// recovery and the kernel-flag reconcile), and the privileged status is not checked yet. UI code with side
    /// effects (login item registration, Automation consent) must wait for the first snapshot whose mode is not
    /// `.starting`, and treats `isDryRun || settings.general.dryRun` as dry-run.
    func snapshots() -> AsyncStream<AppSnapshot>
    func currentSnapshot() async -> AppSnapshot

    // MARK: Master switch & power

    /// "Kakureneko is on/off" (`general.enabled`). Off → thaw, disarm, stop pushing (keeps watching).
    func setEnabled(_ enabled: Bool) async
    /// Keep the Mac awake for `seconds` regardless of agents (menu "Keep awake for…").
    func keepAwake(for seconds: TimeInterval) async
    func cancelKeepAwake() async
    /// User-initiated wind-down → sleep now (thaw, flush, disarm, sleep).
    func sleepNow() async
    /// Cancels a pending shutdown grace (`PowerPhase.shutdownPending`) or a wind-down that has not yet reached
    /// `sleepNow`/`requestShutdown`; returns to the phase the lid state implies.
    func cancelWindDown() async

    // MARK: Sessions

    /// Dismiss a (stuck) session from the list.
    func dismissSession(_ key: SessionKey) async

    // MARK: Pausing

    /// "Resume all" — thaw every paused app now (reason `.userRequest`).
    func resumeAllApps() async
    /// Adds/removes a bundle id on the never-pause list (persists settings).
    func setNeverPause(bundleID: String, _ neverPause: Bool) async

    // MARK: Settings

    /// Replaces settings (normalized + persisted + applied to every service).
    func updateSettings(_ settings: KakurenekoSettings) async
    /// Marks onboarding as completed.
    func completeOnboarding() async

    // MARK: Privileged install (D3)

    /// One admin prompt; then re-runs the health check.
    func installPrivilegedHelper() async throws
    func uninstallPrivilegedHelper() async throws
    func refreshPrivilegedStatus() async

    // MARK: Notifications (docs/NATIVE-NOTIFICATIONS.md)

    /// Shows the macOS notification permission prompt (onboarding); the result lands in the next snapshot too.
    func requestNotificationPermission() async -> MacAlertAuthorization
    /// A test notification on this Mac and every iPhone running the Kakureneko app.
    func sendTestNotification() async throws
    /// The app delegate received a remote notification (a CloudKit push): fetch iCloud changes now.
    func handleCloudPush() async
    /// Removes an iPhone from the list and from iCloud (an old install, a phone that is gone).
    func forgetPhone(deviceID: String) async
    /// "Waiting for your iPhone…" is on screen: look for it in iCloud every few seconds (for 10 minutes).
    func lookForPhones() async

    // MARK: Agent integrations

    func refreshIntegrations() async
    /// Diff preview for install, uninstall or repair (shown before anything is written).
    func previewIntegration(_ agent: AgentID, operation: InstallPlan.Operation) async throws -> InstallPlan
    func installIntegration(_ agent: AgentID) async throws -> InstallResult
    func uninstallIntegration(_ agent: AgentID) async throws -> InstallResult
    func repairIntegration(_ agent: AgentID) async throws -> InstallResult

    // MARK: Resume after shutdown

    /// Forget the "Reopen sessions" offer (the app performs the reopening itself from `ResumeEntry.resumeCommand`).
    func clearResumeOffer() async
}
