// The UI model: the latest `AppSnapshot` plus every user action, sent to `any KakurenekoControlling` (the
// coordinator in the app, `PreviewKakurenekoController` in tests and previews). The UI never reaches services.
//
// Isolation: MainActor (the target's default). Actions are `async` so tests can await them; views call them from
// `Task { await model.… }`. Failures become an inline `ErrorBanner`, never a crash or a silent drop.

import AppKit
import KakurenekoKit
import Foundation

/// Settings window panes.
nonisolated enum SettingsPane: String, Sendable, Hashable, CaseIterable, Identifiable {
    case general, closedLid, sessions, pausing, notifications, integrations, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .closedLid: "Closed Lid & Safety"
        case .sessions: "Sessions"
        case .pausing: "Pausing Apps"
        case .notifications: "Notifications"
        case .integrations: "Agents"
        case .advanced: "Advanced"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .closedLid: "lock.shield.fill"
        case .sessions: "hourglass"
        case .pausing: "pause.circle.fill"
        case .notifications: "bell.badge.fill"
        case .integrations: "puzzlepiece.extension.fill"
        case .advanced: "wrench.and.screwdriver.fill"
        }
    }
}

/// Opens and closes the app's windows (AppKit-hosted in the app, a recorder in tests).
protocol WindowPresenting: AnyObject {
    func showSettings(pane: SettingsPane?)
    func showOnboarding()
    func closeOnboarding()
}

/// Actions that show progress and must not run twice at once.
nonisolated enum AppAction: Hashable, Sendable {
    case privileged
    case notificationPermission
    case sendTest
    case integration(AgentID)
    case settings
    case automation
    case resume
    case uninstall
}

@Observable
final class AppModel {
    /// The latest snapshot (placeholder until the controller publishes).
    private(set) var snapshot: AppSnapshot = .placeholder()
    /// True once the controller published at least one snapshot.
    private(set) var hasReceivedSnapshot = false
    /// Inline error shown until dismissed.
    var banner: ErrorBanner?
    /// Actions currently running.
    private(set) var inFlight: Set<AppAction> = []
    /// The app's own dry-run decisions ("would register login item"), newest last, ≤ 20.
    private(set) var localDryRunLog: [DryRunEntry] = []
    /// `MenuBarExtra(isInserted:)`: the user may drag the item out; reopening the app brings it back.
    var isMenuBarItemInserted = true
    /// Last read `SMAppService.mainApp` status.
    private(set) var loginItemStatus: LoginItemStatus = .unknown
    /// Outcome of the last Automation consent request (opt-in shutdown).
    private(set) var automationConsent: AutomationConsentResult?
    /// Settings pane the settings window shows.
    var settingsPane: SettingsPane = .general
    /// What "Uninstall Kakureneko…" is doing right now (shown beside its spinner).
    private(set) var uninstallStep: String?
    /// The settings window's local draft (rebased on every snapshot).
    let settingsDraft = SettingsDraft()

    @ObservationIgnored private(set) var controller: (any KakurenekoControlling)?
    @ObservationIgnored let environment: AppEnvironment
    @ObservationIgnored weak var presenter: (any WindowPresenting)?
    /// Called once with the first snapshot published after `start()` reconciled (`mode != .starting`): settings are
    /// loaded and the dry-run gate is applied, so launch tasks (login item, onboarding) see the real state.
    @ObservationIgnored var onStarted: ((AppSnapshot) -> Void)?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var localDryRunID: UInt64 = 0

    init(environment: AppEnvironment = .inert()) {
        self.environment = environment
    }

    // MARK: Connection

    /// Subscribes to `controller.snapshots()` FIRST, then (by default) starts the controller. The app delegate calls
    /// this from `applicationDidFinishLaunching` (never from a MenuBarExtra `.task`).
    func connect(to controller: any KakurenekoControlling, start: Bool = true) {
        self.controller = controller
        observation?.cancel()
        let stream = controller.snapshots()
        observation = Task { [weak self] in
            for await next in stream {
                guard let self else { return }
                self.apply(next)
            }
        }
        if start {
            Task { await controller.start() }
        }
    }

    /// Stops following snapshots (tests).
    func disconnect() {
        observation?.cancel()
        observation = nil
    }

    /// Takes a snapshot from the stream (internal so tests can drive the model directly).
    func apply(_ next: AppSnapshot) {
        if snapshot != next { snapshot = next }
        hasReceivedSnapshot = true
        settingsDraft.rebase(onto: next.settings)
        if next.mode != .starting, let handler = onStarted {
            onStarted = nil
            handler(next)
        }
    }

    // MARK: Derived state

    /// Effective dry-run for the app's own side effects (login item, Automation consent, reopening sessions): the
    /// coordinator's gate, the persisted request (`general.dryRun`, applied by the coordinator during `start()`), or
    /// `KAKURENEKO_DRY_RUN` on this process. Any of them is enough to only log.
    var isDryRun: Bool {
        snapshot.isDryRun || snapshot.settings.general.dryRun || environment.dryRunForcedByEnvironment
    }

    func isRunning(_ action: AppAction) -> Bool { inFlight.contains(action) }

    // MARK: Power

    func setEnabled(_ enabled: Bool) async {
        await controller?.setEnabled(enabled)
    }

    func keepAwake(for seconds: TimeInterval) async {
        await controller?.keepAwake(for: seconds)
    }

    func cancelKeepAwake() async {
        await controller?.cancelKeepAwake()
    }

    func sleepNow() async {
        await controller?.sleepNow()
    }

    func cancelWindDown() async {
        await controller?.cancelWindDown()
    }

    // MARK: Sessions and pausing

    func dismissSession(_ key: SessionKey) async {
        await controller?.dismissSession(key)
    }

    func resumeAllApps() async {
        await controller?.resumeAllApps()
    }

    func setNeverPause(bundleID: String, _ neverPause: Bool) async {
        await controller?.setNeverPause(bundleID: bundleID, neverPause)
    }

    // MARK: Settings

    /// Sends the draft (merged onto the latest settings) with `updateSettings`.
    func commitSettings() async {
        guard let controller, settingsDraft.isDirty else { return }
        guard inFlight.insert(.settings).inserted else { return }
        defer { inFlight.remove(.settings) }
        let latest = await controller.currentSnapshot().settings
        let payload = settingsDraft.commitPayload(latest: latest)
        settingsDraft.markCommitted(payload)
        await controller.updateSettings(payload)
        await afterSettingsChange(from: latest, to: payload)
    }

    func revertSettings() { settingsDraft.revert() }

    /// Applies one change immediately (toggles that act at once: launch at login, end action in onboarding,
    /// dismissed agents, custom server). Reads the controller's current settings so nothing else is reverted.
    func updateSettingsNow(_ change: (inout KakurenekoSettings) -> Void) async {
        guard let controller else { return }
        let latest = await controller.currentSnapshot().settings
        var next = latest
        change(&next)
        next = next.normalized()
        guard next != latest else { return }
        await controller.updateSettings(next)
        await afterSettingsChange(from: latest, to: next)
    }

    func completeOnboarding() async {
        await controller?.completeOnboarding()
    }

    /// Side effects of a settings change that belong to the app: Automation consent when shutdown gets enabled.
    /// A commit that turns dry-run on together with shutdown counts as dry-run already.
    private func afterSettingsChange(from old: KakurenekoSettings, to new: KakurenekoSettings) async {
        if new.power.shutdownEnabled && !old.power.shutdownEnabled {
            await requestAutomationConsent(dryRun: isDryRun || new.general.dryRun)
        }
    }

    // MARK: Launch at login (SMAppService.mainApp)

    /// Launch: read the status every launch and re-register when the user opted in (never in dry-run).
    func reconcileLoginItem(optedIn: Bool) {
        loginItemStatus = environment.loginItem.status
        perform(LoginItemPolicy.atLaunch(optedIn: optedIn, status: loginItemStatus, isDryRun: isDryRun,
                                         isBundled: environment.isBundled))
    }

    /// The toggle: register/unregister (or log in dry-run), then persist with `updateSettings`.
    func setLaunchAtLogin(_ enabled: Bool) async {
        loginItemStatus = environment.loginItem.status
        let ok = perform(LoginItemPolicy.toggled(on: enabled, status: loginItemStatus, isDryRun: isDryRun,
                                                 isBundled: environment.isBundled))
        guard ok else { return }
        await updateSettingsNow { $0.general.launchAtLogin = enabled }
    }

    func openLoginItemsSettings() {
        environment.loginItem.openSystemSettings()
    }

    @discardableResult
    private func perform(_ decision: LoginItemDecision) -> Bool {
        defer { loginItemStatus = environment.loginItem.status }
        switch decision {
        case .none:
            return true
        case .log(let line):
            recordLocalDryRun(action: "app.loginItem", detail: line)
            return true
        case .register:
            do {
                try environment.loginItem.register()
                environment.logger.notice("login item registered")
                return true
            } catch {
                report(error, while: "Turning on launch at login")
                return false
            }
        case .unregister:
            do {
                try environment.loginItem.unregister()
                environment.logger.notice("login item unregistered")
                return true
            } catch {
                report(error, while: "Turning off launch at login")
                return false
            }
        }
    }

    // MARK: Updates (Sparkle; Developer ID builds only)

    /// The toggle: Sparkle's daily check on or off, persisted with `updateSettings`.
    func setAutomaticUpdateChecks(_ on: Bool) async {
        environment.updater.setAutomaticChecks(on)
        await updateSettingsNow { $0.general.automaticUpdateChecks = on }
    }

    /// "Check for Updates…" (also the menu's "Install…" for an update found in the background).
    func checkForUpdates() {
        environment.updater.checkNow()
    }

    // MARK: Uninstall

    /// What "Uninstall Kakureneko…" would remove right now.
    var uninstallPlan: UninstallPlan { UninstallPlan.make(snapshot: snapshot, loginItem: environment.loginItem.status) }

    /// Removes everything Kakureneko added, then quits from the Trash (`UninstallPlan`). Stops at the first failure
    /// before any file is deleted, so a cancelled admin prompt or a failed hook removal leaves a working install.
    /// Dry-run only logs.
    func uninstall() async {
        let plan = uninstallPlan
        if isDryRun {
            for line in plan.lines { recordLocalDryRun(action: "app.uninstall", detail: "would remove \(line)") }
            return
        }
        guard controller != nil, inFlight.insert(.uninstall).inserted else { return }
        defer { inFlight.remove(.uninstall) }
        environment.logger.notice("uninstall: \(plan.lines.joined(separator: "; "))")
        // iPhone alerts off first: this Mac's status and saved alerts leave iCloud, and nothing new is saved there.
        defer { uninstallStep = nil }
        if snapshot.settings.notifications.phoneAlerts {
            uninstallStep = "Removing this Mac's records from iCloud…"
            await updateSettingsNow { $0.notifications.phoneAlerts = false }
        }
        if plan.removesClosedLidMode {
            uninstallStep = "Removing closed-lid mode (enter your password)…"
            guard await run(.privileged, "Removing closed-lid mode", { try await $0.uninstallPrivilegedHelper() }) != nil else { return }
        }
        for agent in plan.integrations {
            uninstallStep = "Removing the \(agent.displayName) hook…"
            guard await run(.integration(agent), "Removing the \(agent.displayName) hook", {
                try await $0.uninstallIntegration(agent)
            }) != nil else { return }
        }
        if plan.removesLoginItem {
            perform(.unregister)
        }
        uninstallStep = "Quitting…"
        let controller = self.controller
        environment.uninstallFinisher.finish(emergencyStop: { controller?.terminateSynchronously() })
    }

    // MARK: Automation consent (opt-in shutdown only)

    /// Asks macOS for permission to send the shutdown Apple Event. Never in dry-run (`dryRun` defaults to `isDryRun`).
    func requestAutomationConsent(dryRun: Bool? = nil) async {
        if dryRun ?? isDryRun {
            recordLocalDryRun(action: "app.automationConsent", detail: "would ask for permission to shut down the Mac")
            automationConsent = .skippedInDryRun
            return
        }
        guard inFlight.insert(.automation).inserted else { return }
        defer { inFlight.remove(.automation) }
        automationConsent = await environment.automation.requestShutdownConsent()
        environment.logger.notice("automation consent: \(String(describing: automationConsent))")
    }

    // MARK: Privileged install (D3)

    /// One admin prompt (via the coordinator), then a health check. Returns true on success.
    @discardableResult
    func installPrivilegedHelper() async -> Bool {
        await run(.privileged, "Installing closed-lid mode") { try await $0.installPrivilegedHelper() } != nil
    }

    @discardableResult
    func uninstallPrivilegedHelper() async -> Bool {
        await run(.privileged, "Removing closed-lid mode") { try await $0.uninstallPrivilegedHelper() } != nil
    }

    func refreshPrivilegedStatus() async {
        await controller?.refreshPrivilegedStatus()
    }

    // MARK: Notifications (docs/NATIVE-NOTIFICATIONS.md)

    /// The macOS permission prompt (onboarding, settings). In dry-run the coordinator only logs it.
    @discardableResult
    func requestNotificationPermission() async -> MacAlertAuthorization? {
        guard let controller, inFlight.insert(.notificationPermission).inserted else { return nil }
        defer { inFlight.remove(.notificationPermission) }
        return await controller.requestNotificationPermission()
    }

    /// A test notification on this Mac and every iPhone with the Kakureneko app.
    @discardableResult
    func sendTestNotification() async -> Bool {
        await run(.sendTest, "Sending a test notification") { try await $0.sendTestNotification() } != nil
    }

    /// System Settings → Notifications → Kakureneko (where the user allows alerts and Time Sensitive).
    func openNotificationSettings() {
        open(AppLinks.notificationSettings)
    }

    /// Settings → Notifications → an iPhone → Remove.
    /// Keeps looking for an iPhone in iCloud while `isWaiting` (the "Waiting for your iPhone…" spinners): every few
    /// seconds, renewed before the 10-minute window runs out. Call from a view's `.task`, which cancels it.
    func lookForPhonesWhileWaiting() async {
        while !Task.isCancelled {
            await controller?.lookForPhones()
            try? await Task.sleep(for: .seconds(9 * 60))
        }
    }

    func forgetPhone(_ deviceID: String) async {
        await controller?.forgetPhone(deviceID: deviceID)
    }

    /// A CloudKit push reached the app (`application(_:didReceiveRemoteNotification:)`).
    func handleCloudPush() async {
        await controller?.handleCloudPush()
    }

    // MARK: Integrations

    func refreshIntegrations() async {
        await controller?.refreshIntegrations()
    }

    /// Diff preview (nothing is written).
    func previewIntegration(_ agent: AgentID, operation: InstallPlan.Operation) async -> InstallPlan? {
        await run(.integration(agent), "Preparing the \(agent.displayName) preview") {
            try await $0.previewIntegration(agent, operation: operation)
        }
    }

    /// Applies a previewed plan (install, uninstall or repair), then refreshes the statuses.
    func applyIntegration(_ plan: InstallPlan) async -> InstallResult? {
        let agent = plan.agent
        let result = await run(.integration(agent), "Updating \(agent.displayName)") { controller -> InstallResult in
            switch plan.operation {
            case .install: try await controller.installIntegration(agent)
            case .uninstall: try await controller.uninstallIntegration(agent)
            case .repair: try await controller.repairIntegration(agent)
            }
        }
        await controller?.refreshIntegrations()
        return result
    }

    /// Onboarding "Not now": stop offering this agent.
    func dismissIntegration(_ agent: AgentID) async {
        await updateSettingsNow { $0.integrations.dismissedAgents.insert(agent) }
    }

    func restoreIntegration(_ agent: AgentID) async {
        await updateSettingsNow { $0.integrations.dismissedAgents.remove(agent) }
    }

    // MARK: Resume after shutdown (brief §7.5)

    /// Reopens every offered session in its host terminal, then clears the offer. Dry-run only logs.
    func reopenResumeOffer() async {
        let entries = snapshot.resumeOffer
        guard !entries.isEmpty, inFlight.insert(.resume).inserted else { return }
        defer { inFlight.remove(.resume) }
        if isDryRun {
            let names = entries.map(ResumeScript.label(for:)).joined(separator: ", ")
            recordLocalDryRun(action: "app.reopenSessions", detail: "would reopen \(names)")
        } else {
            let report = await environment.reopener.reopen(entries)
            if !report.skipped.isEmpty {
                banner = ErrorBanner(title: "Some sessions could not be reopened",
                                     message: report.skipped.joined(separator: ", "))
            }
        }
        await controller?.clearResumeOffer()
    }

    func dismissResumeOffer() async {
        await controller?.clearResumeOffer()
    }

    // MARK: Windows, pasteboard, URLs, quit

    func openSettings(_ pane: SettingsPane? = nil) {
        if let pane { settingsPane = pane }
        presenter?.showSettings(pane: pane)
    }

    func openOnboarding() {
        presenter?.showOnboarding()
    }

    func closeOnboarding() {
        presenter?.closeOnboarding()
    }

    func copy(_ text: String) {
        environment.pasteboard.copy(text)
    }

    func open(_ url: URL) {
        environment.urlOpener.open(url)
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func dismissBanner() { banner = nil }

    // MARK: Helpers

    /// Runs a throwing controller call with in-flight tracking; errors become the banner. nil = failed/skipped.
    private func run<T>(_ action: AppAction, _ what: String,
                        _ body: (any KakurenekoControlling) async throws -> T) async -> T? {
        guard let controller else {
            banner = ErrorBanner(title: what, message: "Kakureneko is still starting. Try again in a moment.")
            return nil
        }
        guard inFlight.insert(action).inserted else { return nil }
        defer { inFlight.remove(action) }
        do {
            return try await body(controller)
        } catch {
            report(error, while: what)
            return nil
        }
    }

    private func report(_ error: any Error, while what: String) {
        let message = ErrorText.describe(error)
        environment.logger.warning("\(what) failed: \(message)")
        banner = ErrorBanner(title: what, message: message)
    }

    /// A "would …" line of the app itself (shown in the dry-run banner next to the coordinator's ledger).
    func recordLocalDryRun(action: String, detail: String) {
        localDryRunID += 1
        localDryRunLog.append(DryRunEntry(id: localDryRunID, at: environment.now(), category: .app, action: action, detail: detail))
        if localDryRunLog.count > 20 { localDryRunLog.removeFirst(localDryRunLog.count - 20) }
        environment.logger.notice("[dry-run] \(action): \(detail)")
    }
}
