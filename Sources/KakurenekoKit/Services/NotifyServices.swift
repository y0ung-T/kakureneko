import KakurenekoCloud
import Foundation

/// macOS notifications as a side effect (docs/NATIVE-NOTIFICATIONS.md §4.1–4.2). Live:
/// `KakurenekoNotify.UserNotificationCenterPoster` (only inside the app bundle, where `UNUserNotificationCenter`
/// works); dry-run: `DryRunLocalNotificationPoster` (logs); tests: `RecordingLocalNotifications`.
///
/// Isolation: `final class … : Sendable` or actor.
public protocol LocalNotificationPosting: Sendable {
    /// Current permission (+ Time Sensitive, nil = unknown). Never prompts.
    func authorization() async -> (MacAlertAuthorization, timeSensitive: Bool?)
    /// Shows the system prompt the first time; afterwards returns the current permission.
    func requestAuthorization() async -> MacAlertAuthorization
    /// (Re)registers every button category (`AlertPresentation.categories`), Keep awake titled with `keepAwakeSeconds`.
    func registerCategories(keepAwakeSeconds: Int) async
    /// Shows `alert` now (`AlertPresentation.content`; the request id from `replaceKey` replaces an older one).
    func post(_ alert: CloudAlert) async throws
    /// Taps on the buttons of Kakureneko's own Mac notifications (fan-out; never finishes while the app runs). Taps
    /// that arrive before the first subscriber (a tap that launched the app) are delivered to it.
    func buttonTaps() -> AsyncStream<AlertPresentation.ButtonTap>
    /// Removes delivered notifications that came as CloudKit pushes (another Mac's alerts): this Mac shows its own
    /// alerts locally; the iPhone is where every Mac's alerts come together.
    func removeRemoteAlerts() async
}

/// The notification subsystem as the coordinator sees it (brief §8, docs/NATIVE-NOTIFICATIONS.md). Implemented by
/// `KakurenekoNotify.NotificationDispatcher` (Templates + NotificationPolicy + Mac notifications + iCloud relay).
///
/// Isolation: actor (recommended) with `nonisolated` `remoteCommands()`; persists `outbox.json` and
/// `notify-state.json` atomically. Time comes from the injected clock only.
public protocol NotificationDispatching: Sendable {
    /// Loads the outbox and state, registers the Mac's button categories, checks iCloud, prepares the zone and the
    /// Mac inbox subscriptions, starts the drain / poll / status timers. Callers subscribe to `remoteCommands()` first.
    func start() async
    func stop() async
    /// Applies new settings (Mac / iPhone channels, the iPhone's timing, detail level, quiet hours, mutes, rate limit).
    func applySettings(_ settings: NotificationSettings) async
    /// Policy-gated: renders via Templates, applies the iPhone's timing, 15 s batching (finished items fold into
    /// a countdown submitted in the same batch), per-session needs-input dedupe on `(sessionKey, waiting since)`
    /// + one reminder only while still waiting (cancelled by `.resolved`), the global 6/10 min bucket
    /// (overflow → digest), quiet hours (priority ≤ 2), Remote-Control skip; then shows it on the Mac and queues it
    /// for the iPhone.
    @discardableResult
    func submit(_ intent: NotificationIntent, context: NotificationContext) async -> NotificationDisposition
    /// Bypasses policy (already rendered): Mac notification + outbox enqueue + immediate drain attempt.
    func enqueue(_ notification: OutgoingNotification) async
    /// Saves as much as possible to iCloud before `deadline` (called with now + 10 s before every Kakureneko-initiated
    /// sleep), including the latest Mac status.
    @discardableResult
    func drain(deadline: Date) async -> DrainResult
    /// Fan-out stream of VALIDATED commands from both the Mac's own notification buttons and the iPhone (right Mac,
    /// not expired, `sv` present for sleep/shutdown, unseen id). The coordinator still checks `sv == current`.
    func remoteCommands() -> AsyncStream<RemoteCommand>
    /// Current status (Mac permission, iCloud, phones, outbox, last delivery / command / error).
    func status() async -> NotificationStatus

    /// The Mac's state for the iPhone app. Saved when it changed (debounced), at least every 5 minutes while
    /// running, and at once for a phone's `refresh` request or when `phase` changed.
    func updateMacStatus(_ report: MacStatusReport) async
    /// Shows the macOS permission prompt (onboarding) and returns the result.
    func requestMacAuthorization() async -> MacAlertAuthorization
    /// A test notification on the Mac and every iPhone (whatever the iPhone's timing). Throws a user-presentable
    /// error when no channel can show it.
    func sendTest() async throws
    /// A CloudKit push arrived (the app delegate's remote notification): fetch iCloud changes now.
    func cloudDidNotify() async
    /// Settings → an iPhone → Remove: its record leaves iCloud and the list (it returns if that iPhone opens the app).
    func forgetPhone(deviceID: String) async
    /// A screen says "Waiting for your iPhone…": fetch iCloud now and every few seconds for a while (not every 5
    /// minutes), so the iPhone shows up moments after its setup even when the push doesn't come.
    func lookForPhones() async
}
