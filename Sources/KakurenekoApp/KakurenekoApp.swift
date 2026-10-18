// KakurenekoApp — SwiftUI MenuBarExtra(.window) UI, onboarding (privileged install, phone pairing, agent
// integrations), settings window. OWNER: agent "app" (also owns scripts/ and Resources/).
// Spec card: docs/ARCHITECTURE.md §9.9. Brief §8.6 (onboarding), §9.2, §9.4; R08 §9 (Swift 6 patterns).
//
// This target is compiled with `.defaultIsolation(MainActor.self)`: everything here is @MainActor unless
// marked `nonisolated`. The UI talks ONLY to `KakurenekoControlling` + `AppSnapshot` (never to services).
// Closures handed to GCD/IOKit/notify from this target must be `{ @Sendable in … }` (R08 pitfall 1).
// The coordinator is created and started in `applicationDidFinishLaunching`, never in a MenuBarExtra `.task`.
//
// Layout of this target:
//   KakurenekoApp.swift            @main app, AppDelegate (lifecycle, launch tasks, termination)
//   Model/                       AppModel (snapshot + actions), SettingsDraft, OnboardingFlow, TerminationFlow,
//                                AppEnvironment (login item, Automation consent, reopening sessions, pasteboard)
//   Formatting/                  pure view-model formatting (tested): menu rows, phase text, settings catalog
//   Support/                     QR codes (CoreImage), resume scripts, app links (Info.plist), Sparkle updates,
//                                the Applications-folder move, uninstall (docs/RELEASE.md)
//   Views/, Windows/             SwiftUI views and their AppKit windows

import AppKit
import KakurenekoCoordinator
import KakurenekoKit
import SwiftUI

@main
struct KakurenekoMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        let model = delegate.model
        // `isInserted:` keeps the app running if the user drags the item out of the menu bar (opening the app
        // again brings it back); without it macOS terminates a menu-bar-only app.
        MenuBarExtra(isInserted: Binding(get: { model.isMenuBarItemInserted },
                                         set: { model.isMenuBarItemInserted = $0 })) {
            MenuContentView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the model; creates and starts the coordinator once the app has launched; runs the launch tasks on the
/// first snapshot; answers `applicationShouldTerminate` after `prepareForTermination()`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private let makeController: () -> any KakurenekoControlling
    private let makePresenter: (AppModel) -> any WindowPresenting
    private(set) var presenter: (any WindowPresenting)?
    let termination: TerminationFlow

    /// Production wiring (`@NSApplicationDelegateAdaptor` needs `init()`). Creating it has no side effects.
    override convenience init() {
        self.init(environment: .live(),
                  makeController: { KakurenekoCoordinator.live() },
                  makePresenter: { WindowCoordinator(model: $0) })
    }

    /// Injectable wiring (tests pass `PreviewKakurenekoController`, an inert environment and a recording presenter).
    init(environment: AppEnvironment,
         makeController: @escaping () -> any KakurenekoControlling,
         makePresenter: @escaping (AppModel) -> any WindowPresenting,
         termination: TerminationFlow = TerminationFlow()) {
        model = AppModel(environment: environment)
        self.makeController = makeController
        self.makePresenter = makePresenter
        self.termination = termination
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Another copy running: one of the two quits before anything starts (SingleInstance.swift).
        if model.environment.settleOtherCopies() { return }
        // Opened from the disk image or Downloads: move to Applications first (relaunches; nothing started yet).
        if model.environment.offerMoveToApplications() { return }
        let presenter = makePresenter(model)
        self.presenter = presenter
        model.presenter = presenter
        model.onStarted = { [weak self] snapshot in self?.runLaunchTasks(snapshot) }
        model.connect(to: makeController())
        model.environment.registerForPushes()
    }

    /// A CloudKit push (`zone-v1`: an iPhone saved a command or its device record): fetch iCloud now.
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { await model.handleCloudPush() }
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        model.environment.logger.notice("registered for iCloud pushes")
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        model.environment.logger.notice("push registration failed (iCloud is polled instead): \(type(of: error))")
    }

    /// Launch tasks, on the first snapshot after `start()` reconciled (settings loaded, dry-run gate applied):
    /// re-check the login item, start the updater, then show onboarding until it is completed.
    func runLaunchTasks(_ snapshot: AppSnapshot) {
        model.reconcileLoginItem(optedIn: snapshot.settings.general.launchAtLogin)
        model.environment.updater.start(automaticChecks: snapshot.settings.general.automaticUpdateChecks)
        if !snapshot.settings.general.onboardingCompleted {
            presenter?.showOnboarding()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shouldTerminate { sender.reply(toApplicationShouldTerminate: $0) }
    }

    /// `.terminateLater` while `prepareForTermination()` runs (thaw, disarm, flush), then `reply(true)`; `.terminateNow`
    /// when the coordinator was never created. Split from the delegate method so tests never touch `NSApplication`.
    func shouldTerminate(reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply {
        guard let controller = model.controller else { return .terminateNow }
        return termination.begin(prepare: { await controller.prepareForTermination() },
                                 emergency: { controller.terminateSynchronously() }, reply: reply)
    }

    /// Every NSApp exit passes here (also after the quit watchdog): the synchronous thaw + disarm, a no-op when
    /// `prepareForTermination()` already did it.
    func applicationWillTerminate(_ notification: Notification) {
        model.controller?.terminateSynchronously()
    }

    /// Opening the app again (Finder, Spotlight) restores a removed menu bar item and shows the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.isMenuBarItemInserted = true
        if !flag { presenter?.showSettings(pane: nil) }
        return false
    }
}
