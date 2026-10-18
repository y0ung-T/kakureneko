// App updates through Sparkle (docs/RELEASE.md): the Developer ID build reads its signed appcast from the website
// (`SUFeedURL`, `SUPublicEDKey` in Info.plist, written by scripts/build-app.sh for DISTRIBUTION=1 builds). Development
// builds have neither key, so the updater stays off and nothing is ever checked.
//
// A menu bar app has no Dock icon to bounce, so scheduled checks use Sparkle's "gentle reminders": an update found
// in the background shows as a row in the menu ("Kakureneko 1.1 is available"), and Sparkle's window only opens when
// the user asks for it. `GeneralSettings.automaticUpdateChecks` is the source of truth; it is applied at launch.

import AppKit
import Foundation
import Sparkle

/// What the app needs from the updater (Sparkle in the app, a recorder in tests).
protocol UpdateChecking: AnyObject {
    /// This build can update itself (bundled, feed and key present, not a dry run).
    var isAvailable: Bool { get }
    /// A check can start now (none running).
    var canCheckNow: Bool { get }
    /// The version Sparkle found in a background check and has not shown yet.
    var pendingUpdateVersion: String? { get }
    /// Starts the updater (once, after launch). No-op when unavailable.
    func start(automaticChecks: Bool)
    /// Daily background checks on or off.
    func setAutomaticChecks(_ on: Bool)
    /// "Check for Updates…": Sparkle's window with the result.
    func checkNow()
}

/// Sparkle's standard updater with gentle reminders. Creating it has no side effect; `start` does the work.
@Observable
final class SparkleUpdater: NSObject, UpdateChecking, SPUStandardUserDriverDelegate {
    let isAvailable: Bool
    private(set) var canCheckNow = false
    private(set) var pendingUpdateVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    /// `info`: the app's Info.plist. Off unless the build carries a feed and a key and `enabled` (bundled, not a dry run).
    init(info: [String: Any], enabled: Bool) {
        isAvailable = enabled && Self.isConfigured(info)
        super.init()
    }

    nonisolated static func isConfigured(_ info: [String: Any]) -> Bool {
        let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:))
        let key = (info["SUPublicEDKey"] as? String) ?? ""
        return feed?.scheme == "https" && !key.isEmpty
    }

    func start(automaticChecks: Bool) {
        guard isAvailable, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        controller.updater.automaticallyChecksForUpdates = automaticChecks
        // KVO fires on the main thread (Sparkle changes it there).
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let canCheck = change.newValue ?? false
            MainActor.assumeIsolated { self?.canCheckNow = canCheck }
        }
        controller.startUpdater()
    }

    func setAutomaticChecks(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
    }

    func checkNow() {
        guard let controller else { return }
        NSApplication.shared.activate()
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate (gentle reminders for a background app)

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows a scheduled update itself only when the app is in front; otherwise the menu row does.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate && !state.userInitiated {
            pendingUpdateVersion = update.displayVersionString
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingUpdateVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingUpdateVersion = nil
    }
}

/// Records what the app asked of the updater (tests, previews).
@Observable
final class RecordingUpdater: UpdateChecking {
    var isAvailable: Bool
    var canCheckNow = true
    var pendingUpdateVersion: String?
    private(set) var startedWith: Bool?
    private(set) var automaticChecks: [Bool] = []
    private(set) var checks = 0

    init(isAvailable: Bool = false) { self.isAvailable = isAvailable }

    func start(automaticChecks: Bool) {
        guard isAvailable else { return }
        startedWith = automaticChecks
    }

    func setAutomaticChecks(_ on: Bool) { automaticChecks.append(on) }
    func checkNow() { checks += 1 }
}
