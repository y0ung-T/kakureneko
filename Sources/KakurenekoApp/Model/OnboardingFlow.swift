// First-launch onboarding (brief §8.6, spec card §9.9), shown while `general.onboardingCompleted == false`:
//   1. closed-lid mode: what it does + "Install" (ONE admin prompt via `installPrivilegedHelper`) or
//      "Skip — notifications only";
//   2. notifications: allow macOS notifications (`requestNotificationPermission`); then the iPhone (`PhoneSetup`):
//      already connected (the iPhone app came first), or "Get alerts on your iPhone too?" → "Set up my iPhone" (QR
//      code, three steps, "iPhone connected" by itself once its `PhoneDevice` record arrives, a checklist if it
//      doesn't) or "Just this Mac" (iPhone alerts off: nothing about this Mac goes to iCloud); a test on both;
//   3. agent integrations (only agents whose config dir exists) with a diff preview before every change;
//   4. when agents are done: Sleep (default) or opt-in Shut down — choosing Shut down asks for Automation consent
//      (skipped in dry-run); "Open Kakureneko at login" and "Check for updates automatically" (both preset on the first
//      run, applied on Done).

import KakurenekoCloud
import KakurenekoKit
import Foundation

@Observable
final class OnboardingFlow {
    enum Step: Int, CaseIterable, Identifiable, Sendable {
        case closedLid
        case notifications
        case integrations
        case finish

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .closedLid: "Closed lid"
            case .notifications: "Alerts"
            case .integrations: "Agents"
            case .finish: "When done"
            }
        }

        var symbolName: String {
            switch self {
            case .closedLid: "lock.laptopcomputer"
            case .notifications: "bell.badge.fill"
            case .integrations: "puzzlepiece.extension.fill"
            case .finish: "moon.zzz.fill"
            }
        }
    }

    /// What the user chose on step 1.
    enum PrivilegedChoice: Sendable, Hashable {
        case installed
        case skipped
    }

    /// Step 2's question: alerts on an iPhone too, or only on this Mac.
    enum PhoneChoice: Sendable, Hashable {
        case iPhone
        case macOnly
    }

    /// What step 2 shows for the iPhone.
    enum PhoneSetup: Sendable, Hashable {
        /// "Get alerts on your iPhone too?": Set up my iPhone / Just this Mac.
        case ask
        /// The QR code and three steps, waiting for the iPhone's record.
        case waitingForIPhone
        /// An iPhone with the app shares this Apple Account (it may have come first) and iPhone alerts are on.
        case connected
        /// "Just this Mac".
        case macOnly
        /// This Mac can't use iCloud (not signed in, restricted): the explanation, alerts stay on the Mac.
        case iCloudUnavailable
    }

    private(set) var step: Step = .closedLid
    private(set) var privilegedChoice: PrivilegedChoice?
    private(set) var phoneChoice: PhoneChoice?
    /// Set once onboarding was completed from this flow.
    private(set) var isFinished = false

    @ObservationIgnored let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    // MARK: Navigation

    var isFirstStep: Bool { step == Step.allCases.first }
    var isLastStep: Bool { step == Step.allCases.last }

    /// "Continue" is always possible (every step can be skipped); the label says what happens.
    var continueTitle: String {
        switch step {
        case .closedLid: privilegedChoice == nil && !model.snapshot.privileged.isOperational ? "Skip · notifications only" : "Continue"
        case .notifications: macAllowed || phoneConnected || phoneChoice != nil ? "Continue" : "Skip for now"
        case .integrations: "Continue"
        case .finish: "Done"
        }
    }

    func next() async {
        if step == .closedLid, privilegedChoice == nil, !model.snapshot.privileged.isOperational {
            privilegedChoice = .skipped
        }
        guard let following = Step(rawValue: step.rawValue + 1) else {
            await finish()
            return
        }
        await enter(following)
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// Jumps to `target` and runs its entry work (privileged status, integration refresh).
    func enter(_ target: Step) async {
        step = target
        switch target {
        case .closedLid:
            await model.refreshPrivilegedStatus()
        case .notifications:
            break
        case .integrations:
            await model.refreshIntegrations()
        case .finish:
            break
        }
    }

    // MARK: Step 1 — closed-lid mode

    var privilegedSummary: PrivilegedSummary { PrivilegedSummary.make(model.snapshot.privileged) }

    /// One admin prompt; advances on success.
    func installPrivileged() async {
        if await model.installPrivilegedHelper() {
            privilegedChoice = .installed
            await next()
        }
    }

    /// "Skip — notifications only".
    func skipPrivileged() async {
        privilegedChoice = .skipped
        await enter(.notifications)
    }

    // MARK: Step 2 — notifications

    var macAllowed: Bool { model.snapshot.notifications.macAuthorization.canPost }
    var phoneConnected: Bool { model.snapshot.notifications.phoneConnected }

    var phoneSetup: PhoneSetup {
        let notifications = model.snapshot.notifications
        if phoneChoice == .macOnly { return .macOnly }
        if !notifications.iCloud.isAvailable && notifications.iCloud != .couldNotDetermine { return .iCloudUnavailable }
        if !notifications.phones.isEmpty && model.snapshot.settings.notifications.phoneAlerts { return .connected }
        return phoneChoice == .iPhone ? .waitingForIPhone : .ask
    }

    /// How long step 2 waits for the iPhone before it lists what to check.
    static let phoneHelpDelay: Duration = .seconds(45)

    /// "Set up my iPhone": iPhone alerts on, so this Mac shares its status and the iPhone app finds it.
    func chooseIPhone() async {
        phoneChoice = .iPhone
        if !model.snapshot.settings.notifications.phoneAlerts {
            await model.updateSettingsNow { $0.notifications.phoneAlerts = true }
        }
    }

    /// "Just this Mac": iPhone alerts off, so nothing about this Mac goes to iCloud (Settings → Notifications
    /// turns them on later).
    func chooseMacOnly() async {
        phoneChoice = .macOnly
        if model.snapshot.settings.notifications.phoneAlerts {
            await model.updateSettingsNow { $0.notifications.phoneAlerts = false }
        }
    }

    // MARK: Step 3 — integrations

    /// Agents whose config dir exists and that the user has not dismissed.
    var integrations: [IntegrationStatus] {
        IntegrationRowModel.offered(model.snapshot.integrations, dismissed: model.snapshot.settings.integrations.dismissedAgents)
    }

    // MARK: Step 4 — end action

    var endAction: EndAction { model.snapshot.settings.power.endAction }

    /// Persists the end action at once; enabling shutdown asks for Automation consent (not in dry-run).
    func setEndAction(_ action: EndAction) async {
        await model.updateSettingsNow { $0.power.endAction = action }
    }

    /// "Open Kakureneko at login": on by default the first time (a menu bar app that isn't running after a restart
    /// keeps nothing awake); a re-run shows the current setting.
    var openAtLogin: Bool {
        get { openAtLoginChoice ?? (model.snapshot.settings.general.onboardingCompleted ? model.snapshot.settings.general.launchAtLogin : true) }
        set { openAtLoginChoice = newValue }
    }

    /// "Check for updates automatically" (only offered when this build can update itself).
    var checkForUpdates: Bool {
        get { checkForUpdatesChoice ?? model.snapshot.settings.general.automaticUpdateChecks }
        set { checkForUpdatesChoice = newValue }
    }

    var offersUpdates: Bool { model.environment.updater.isAvailable }

    private var openAtLoginChoice: Bool?
    private var checkForUpdatesChoice: Bool?

    /// Applies the last step's choices, marks onboarding complete and closes the window.
    func finish() async {
        if openAtLogin != model.snapshot.settings.general.launchAtLogin || openAtLogin {
            await model.setLaunchAtLogin(openAtLogin)
        }
        if offersUpdates, checkForUpdates != model.snapshot.settings.general.automaticUpdateChecks {
            await model.setAutomaticUpdateChecks(checkForUpdates)
        }
        await model.completeOnboarding()
        isFinished = true
        model.closeOnboarding()
    }
}
