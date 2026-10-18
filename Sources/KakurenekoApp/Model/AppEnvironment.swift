// The few system services the APP itself touches (everything else goes through `KakurenekoControlling`):
// launch at login (`SMAppService.mainApp`), Automation consent for the opt-in shutdown, reopening sessions in a
// terminal, the pasteboard and opening URLs. Each sits behind a small protocol so `AppModel` is testable with
// recording fakes: tests and previews use `AppEnvironment.inert()`, only `AppDelegate` builds `.live()`.
//
// Dry-run (spec card §9.9): the model never calls `register`/`unregister` or requests consent while
// `snapshot.isDryRun` (or `KAKURENEKO_DRY_RUN`) is on; it records "would …" lines instead.

import AppKit
import CoreServices
import KakurenekoKit
import Foundation
import ServiceManagement

// MARK: - Launch at login

nonisolated enum LoginItemStatus: String, Sendable, Hashable {
    /// Not read yet.
    case unknown
    case notRegistered
    case enabled
    /// The user must approve it in System Settings > General > Login Items.
    case requiresApproval
    /// Never registered (normal before the first registration, R08 §5).
    case notFound

    var text: String {
        switch self {
        case .unknown: "Not checked yet"
        case .notRegistered, .notFound: "Not registered"
        case .enabled: "Enabled"
        case .requiresApproval: "Needs approval in System Settings › Login Items"
        }
    }
}

protocol LoginItemControlling: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// `SMAppService.mainApp` (brief §9.2). Only `AppEnvironment.live()` creates it.
final class MainAppLoginItem: LoginItemControlling {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Test/preview stand-in: records calls, never touches ServiceManagement.
final class RecordingLoginItem: LoginItemControlling {
    var status: LoginItemStatus
    var failure: (any Error)?
    private(set) var calls: [String] = []

    init(status: LoginItemStatus = .notFound) { self.status = status }

    func register() throws {
        calls.append("register")
        if let failure { throw failure }
        status = .enabled
    }

    func unregister() throws {
        calls.append("unregister")
        if let failure { throw failure }
        status = .notRegistered
    }

    func openSystemSettings() { calls.append("openSystemSettings") }
}

/// What to do with the login item.
nonisolated enum LoginItemDecision: Sendable, Hashable {
    case none
    case register
    case unregister
    /// Dry-run or not running from the bundle: log this instead of acting.
    case log(String)
}

nonisolated enum LoginItemPolicy {
    /// At every launch: re-register when the user opted in and macOS does not report it enabled
    /// (`.notFound` before the first registration is normal; ad-hoc rebuilds can drop the registration).
    static func atLaunch(optedIn: Bool, status: LoginItemStatus, isDryRun: Bool, isBundled: Bool) -> LoginItemDecision {
        guard optedIn else { return .none }
        switch status {
        case .enabled, .requiresApproval:
            return .none
        case .notRegistered, .notFound, .unknown:
            if isDryRun { return .log("would register login item") }
            if !isBundled { return .log("launch at login needs Kakureneko.app (not registering a bare executable)") }
            return .register
        }
    }

    /// The user flipped the toggle.
    static func toggled(on: Bool, status: LoginItemStatus, isDryRun: Bool, isBundled: Bool) -> LoginItemDecision {
        if on {
            if status == .enabled { return .none }
            if isDryRun { return .log("would register login item") }
            if !isBundled { return .log("launch at login needs Kakureneko.app (not registering a bare executable)") }
            return .register
        }
        guard status == .enabled || status == .requiresApproval else { return .none }
        if isDryRun { return .log("would unregister login item") }
        if !isBundled { return .none }
        return .unregister
    }
}

// MARK: - Automation consent (opt-in shutdown)

nonisolated enum AutomationConsentResult: Sendable, Hashable {
    case granted
    case denied
    case notDetermined
    case targetNotRunning
    case skippedInDryRun
    case failed(Int32)

    /// `AEDeterminePermissionToAutomateTarget` status → result.
    static func from(status: OSStatus) -> AutomationConsentResult {
        switch status {
        case OSStatus(noErr): .granted
        case OSStatus(errAEEventNotPermitted): .denied
        case OSStatus(errAEEventWouldRequireUserConsent): .notDetermined
        case OSStatus(procNotFound): .targetNotRunning
        default: .failed(status)
        }
    }

    var text: String {
        switch self {
        case .granted: "Kakureneko may ask macOS to shut down."
        case .denied: "Shutdown permission was denied. Kakureneko will sleep instead. Allow it in System Settings › Privacy & Security › Automation."
        case .notDetermined: "macOS has not asked yet."
        case .targetNotRunning: "Could not reach the login window to ask for permission."
        case .skippedInDryRun: "Dry run: permission was not requested."
        case .failed(let status): "Could not check the shutdown permission (error \(status))."
        }
    }

    var isGranted: Bool { self == .granted }
}

protocol AutomationConsentRequesting: AnyObject {
    /// Asks for permission to send `aevt/shut` to loginwindow (may show the system prompt).
    func requestShutdownConsent() async -> AutomationConsentResult
}

/// `AEDeterminePermissionToAutomateTarget(loginwindow, kCoreEventClass, kAEShutDown, askUserIfNeeded: true)`.
/// The call blocks while the prompt is up, so it runs on a global queue (the closure is `@Sendable`, R08 pitfall 1).
final class AppleEventAutomationConsent: AutomationConsentRequesting {
    nonisolated static let loginWindowBundleID = "com.apple.loginwindow"

    func requestShutdownConsent() async -> AutomationConsentResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<AutomationConsentResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { @Sendable in
                continuation.resume(returning: Self.determine(askUserIfNeeded: true))
            }
        }
    }

    nonisolated static func determine(askUserIfNeeded: Bool) -> AutomationConsentResult {
        let target = NSAppleEventDescriptor(bundleIdentifier: loginWindowBundleID)
        let status = AEDeterminePermissionToAutomateTarget(
            target.aeDesc, AEEventClass(kCoreEventClass), AEEventID(kAEShutDown), askUserIfNeeded)
        return AutomationConsentResult.from(status: status)
    }
}

/// Test/preview stand-in.
final class RecordingAutomationConsent: AutomationConsentRequesting {
    var result: AutomationConsentResult
    private(set) var requestCount = 0

    init(result: AutomationConsentResult = .granted) { self.result = result }

    func requestShutdownConsent() async -> AutomationConsentResult {
        requestCount += 1
        return result
    }
}

// MARK: - Reopening sessions

nonisolated struct ReopenReport: Sendable, Hashable {
    var opened: [String] = []
    var skipped: [String] = []
}

protocol SessionReopening: AnyObject {
    func reopen(_ entries: [ResumeEntry]) async -> ReopenReport
}

/// Writes one `.command` file per session (0700, in a private temp folder) and opens it with the host terminal.
final class CommandFileSessionReopener: SessionReopening {
    private let logger: KakurenekoLogger
    private let directory: URL

    init(logger: KakurenekoLogger, directory: URL = FileManager.default.temporaryDirectory.appending(path: "Kakureneko-resume", directoryHint: .isDirectory)) {
        self.logger = logger
        self.directory = directory
    }

    func reopen(_ entries: [ResumeEntry]) async -> ReopenReport {
        var report = ReopenReport()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            logger.error("resume: cannot create \(directory.lastPathComponent): \(error)")
            report.skipped = entries.map(ResumeScript.label(for:))
            return report
        }
        for entry in entries {
            let label = ResumeScript.label(for: entry)
            guard let command = ResumeScript.command(for: entry) else {
                report.skipped.append(label)
                continue
            }
            let file = directory.appending(path: "\(UUID().uuidString).command", directoryHint: .notDirectory)
            do {
                try Data(ResumeScript.fileContents(command: command).utf8).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path(percentEncoded: false))
            } catch {
                logger.error("resume: cannot write the command file: \(error)")
                report.skipped.append(label)
                continue
            }
            let bundleID = ResumeScript.terminalBundleID(for: entry)
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: ResumeScript.defaultTerminalBundleID) else {
                report.skipped.append(label)
                continue
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let log = logger
            NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: configuration) { @Sendable _, error in
                if let error { log.error("resume: opening the terminal failed: \(error.localizedDescription)") }
            }
            logger.info("resume: reopening \(entry.agent.rawValue) session in \(bundleID)")
            report.opened.append(label)
        }
        return report
    }
}

/// Test/preview stand-in.
final class RecordingSessionReopener: SessionReopening {
    private(set) var reopened: [[ResumeEntry]] = []

    func reopen(_ entries: [ResumeEntry]) async -> ReopenReport {
        reopened.append(entries)
        var report = ReopenReport()
        for entry in entries {
            if ResumeScript.command(for: entry) != nil {
                report.opened.append(ResumeScript.label(for: entry))
            } else {
                report.skipped.append(ResumeScript.label(for: entry))
            }
        }
        return report
    }
}

// MARK: - Pasteboard and URLs

protocol PasteboardWriting: AnyObject {
    func copy(_ string: String)
}

final class GeneralPasteboard: PasteboardWriting {
    func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

final class RecordingPasteboard: PasteboardWriting {
    private(set) var copied: [String] = []
    func copy(_ string: String) { copied.append(string) }
}

protocol URLOpening: AnyObject {
    func open(_ url: URL)
}

final class WorkspaceURLOpener: URLOpening {
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

final class RecordingURLOpener: URLOpening {
    private(set) var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
}

// MARK: - The environment

/// System services used by `AppModel`.
struct AppEnvironment {
    var loginItem: any LoginItemControlling
    var automation: any AutomationConsentRequesting
    var reopener: any SessionReopening
    var pasteboard: any PasteboardWriting
    var urlOpener: any URLOpening
    var logger: KakurenekoLogger
    /// Running from `Kakureneko.app` (not `swift run`): SMAppService only makes sense for a bundle (R08 §5).
    var isBundled: Bool
    /// `KAKURENEKO_DRY_RUN` is set for this process (belt and braces next to `AppSnapshot.isDryRun`).
    var dryRunForcedByEnvironment: Bool
    var now: () -> Date
    /// Registers with APNs so CloudKit pushes (an iPhone tapped a button) reach the app; a no-op in tests. Without
    /// the push entitlement (an unprovisioned build) registration fails and the app relies on polling.
    var registerForPushes: () -> Void
    /// Sparkle (off in builds without a feed, in dry-run and outside a bundle).
    var updater: any UpdateChecking
    /// At launch, first: one copy at a time (SingleInstance.swift). True = this copy is quitting (stop launching).
    var settleOtherCopies: () -> Bool
    /// At launch: offers to move a bundle opened from a disk image or Downloads into Applications. True = the app is
    /// relaunching from there (stop launching). Never asks in tests.
    var offerMoveToApplications: () -> Bool
    /// The last step of "Uninstall Kakureneko…" (remove the local files after exit, trash the app, quit).
    var uninstallFinisher: any UninstallFinishing

    /// The real services. Creating them has no side effect; they act only when the model calls them.
    static func live(processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                     bundleURL: URL = Bundle.main.bundleURL) -> AppEnvironment {
        let logger = KakurenekoLogger(.app)
        let isBundled = bundleURL.pathExtension == "app"
        let dryRun = KakurenekoEnvironment.isTruthy(processEnvironment[KakurenekoEnvironment.dryRun])
        let homeOverridden = processEnvironment[KakurenekoEnvironment.home] != nil
        return AppEnvironment(
            loginItem: MainAppLoginItem(),
            automation: AppleEventAutomationConsent(),
            reopener: CommandFileSessionReopener(logger: logger),
            pasteboard: GeneralPasteboard(),
            urlOpener: WorkspaceURLOpener(),
            logger: logger,
            isBundled: isBundled,
            dryRunForcedByEnvironment: dryRun,
            now: { Date() },
            registerForPushes: { NSApplication.shared.registerForRemoteNotifications() },
            updater: SparkleUpdater(info: Bundle(url: bundleURL)?.infoDictionary ?? [:],
                                    enabled: isBundled && !dryRun && !homeOverridden),
            settleOtherCopies: {
                // A dry run with its own home may run next to the real app (development).
                guard isBundled, !dryRun, !homeOverridden else { return false }
                return SingleInstance.settle(bundle: bundleURL, logger: logger)
            },
            offerMoveToApplications: {
                guard isBundled, !dryRun, !homeOverridden else { return false }
                return ApplicationsFolderMover.offerIfNeeded(bundle: bundleURL, logger: logger)
            },
            uninstallFinisher: LiveUninstallFinisher(bundle: bundleURL, logger: logger)
        )
    }

    /// Recording fakes only (tests, previews, the default `AppModel()`): never touches the system.
    static func inert(
        loginItem: any LoginItemControlling = RecordingLoginItem(),
        automation: any AutomationConsentRequesting = RecordingAutomationConsent(),
        reopener: any SessionReopening = RecordingSessionReopener(),
        pasteboard: any PasteboardWriting = RecordingPasteboard(),
        urlOpener: any URLOpening = RecordingURLOpener(),
        isBundled: Bool = true,
        dryRunForcedByEnvironment: Bool = false,
        now: @escaping () -> Date = { Date() },
        registerForPushes: @escaping () -> Void = {},
        updater: any UpdateChecking = RecordingUpdater(),
        settleOtherCopies: @escaping () -> Bool = { false },
        offerMoveToApplications: @escaping () -> Bool = { false },
        uninstallFinisher: any UninstallFinishing = RecordingUninstallFinisher()
    ) -> AppEnvironment {
        AppEnvironment(loginItem: loginItem, automation: automation, reopener: reopener, pasteboard: pasteboard,
                       urlOpener: urlOpener, logger: KakurenekoLogger(.app), isBundled: isBundled,
                       dryRunForcedByEnvironment: dryRunForcedByEnvironment, now: now, registerForPushes: registerForPushes,
                       updater: updater, settleOtherCopies: settleOtherCopies, offerMoveToApplications: offerMoveToApplications,
                       uninstallFinisher: uninstallFinisher)
    }
}
