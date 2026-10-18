@testable import KakurenekoApp
import AppKit
import KakurenekoCloud
import KakurenekoKit
import Foundation
import Testing

/// What a downloaded build needs (docs/RELEASE.md): links from Info.plist, the Applications folder check, Sparkle's
/// configuration, uninstall, and the onboarding's login and update choices. Recording fakes only.
@MainActor
@Suite("Release", .timeLimit(.minutes(1)))
struct ReleaseTests {
    // MARK: Links

    @Test func linksComeFromTheWebsiteInInfoPlist() {
        let links = ReleaseLinks(info: ["KakurenekoWebsiteURL": "https://kakureneko.example"])
        #expect(links.website?.absoluteString == "https://kakureneko.example/")
        #expect(links.privacyPolicy?.absoluteString == "https://kakureneko.example/privacy/")
        #expect(links.support?.absoluteString == "https://kakureneko.example/support/")
        #expect(links.iPhoneApp?.absoluteString == "https://kakureneko.example/iphone/", "the website's page until the App Store link exists")

        let listed = ReleaseLinks(info: ["KakurenekoWebsiteURL": "https://kakureneko.example/",
                                         "KakurenekoIPhoneAppURL": "https://apps.apple.com/app/id123"])
        #expect(listed.iPhoneApp?.absoluteString == "https://apps.apple.com/app/id123")
        #expect(listed.privacyPolicy?.absoluteString == "https://kakureneko.example/privacy/")
    }

    @Test func aBuildWithoutLinksShowsNone() {
        for info: [String: Any] in [[:], ["KakurenekoWebsiteURL": ""], ["KakurenekoWebsiteURL": "http://plain.example"],
                                    ["KakurenekoWebsiteURL": "not a url"], ["KakurenekoWebsiteURL": 42]] {
            let links = ReleaseLinks(info: info)
            #expect(links.website == nil && links.privacyPolicy == nil && links.iPhoneApp == nil, "\(info)")
        }
    }

    // MARK: Applications folder

    @Test func onlyDiskImagesDownloadsAndTranslocationAskToMove() {
        let home = "/Users/someone"
        #expect(InstallLocationProblem.of(bundlePath: "/Volumes/Kakureneko/Kakureneko.app", home: home) == .diskImage)
        #expect(InstallLocationProblem.of(
            bundlePath: "/private/var/folders/xy/T/AppTranslocation/0A1B/d/Kakureneko.app", home: home) == .translocated)
        #expect(InstallLocationProblem.of(bundlePath: "/Users/someone/Downloads/Kakureneko.app", home: home) == .downloads)
        #expect(InstallLocationProblem.of(bundlePath: "/Users/someone/Downloads/Kakureneko 2/Kakureneko.app", home: home) == .downloads)
        for fine in ["/Applications/Kakureneko.app", "/Users/someone/Applications/Kakureneko.app",
                     "/Users/someone/Developer/kakureneko/build/Kakureneko.app", "/Users/someone/DownloadsOld/Kakureneko.app"] {
            #expect(InstallLocationProblem.of(bundlePath: fine, home: home) == nil, "\(fine)")
        }
    }

    @Test func launchingAskedToMoveStopsBeforeAnythingStarts() {
        let presenter = RecordingPresenter()
        let delegate = AppDelegate(environment: .inert(offerMoveToApplications: { true }),
                                   makeController: { PreviewKakurenekoController() },
                                   makePresenter: { _ in presenter })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(delegate.model.controller == nil, "relaunching from Applications: no coordinator here")
        #expect(delegate.presenter == nil)
    }

    // MARK: One copy at a time

    @Test func theInstalledCopyWinsOverAStrayOne() {
        let home = "/Users/someone"
        let installed = "/Users/someone/Applications/Kakureneko.app"
        let stray = RunningCopy(pid: 11, bundlePath: "/Users/someone/Developer/kakureneko/build/Kakureneko.app")
        #expect(SingleInstanceDecision.decide(selfPath: installed, others: [], home: home) == .carryOn)
        // The installed copy launches while a build copy runs: the stray quits, the installed one carries on.
        #expect(SingleInstanceDecision.decide(selfPath: installed, others: [stray], home: home) == .replace([11]))
        #expect(SingleInstanceDecision.decide(selfPath: "/Applications/Kakureneko.app", others: [stray], home: home) == .replace([11]))
        // A stray copy launches while the installed one runs: it shows that one and quits.
        let running = RunningCopy(pid: 22, bundlePath: installed)
        #expect(SingleInstanceDecision.decide(selfPath: stray.bundlePath, others: [running], home: home) == .quitAndActivate(22))
        // Two installed copies (Applications and ~/Applications): the newcomer yields.
        #expect(SingleInstanceDecision.decide(selfPath: "/Applications/Kakureneko.app", others: [running], home: home) == .quitAndActivate(22))
        // Strays only: the newcomer yields to whichever already runs.
        #expect(SingleInstanceDecision.decide(selfPath: "/Volumes/Kakureneko/Kakureneko.app", others: [stray], home: home) == .quitAndActivate(11))
    }

    @Test func launchingAsASecondCopyStopsBeforeAnythingStarts() {
        let delegate = AppDelegate(environment: .inert(settleOtherCopies: { true }),
                                   makeController: { PreviewKakurenekoController() },
                                   makePresenter: { _ in RecordingPresenter() })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(delegate.model.controller == nil)
    }

    // MARK: Sparkle

    @Test func updatesNeedAnHTTPSFeedAKeyAndARealBundle() {
        let info: [String: Any] = ["SUFeedURL": "https://kakureneko.example/updates/appcast.xml", "SUPublicEDKey": "abc="]
        #expect(SparkleUpdater.isConfigured(info))
        #expect(SparkleUpdater(info: info, enabled: true).isAvailable)
        #expect(!SparkleUpdater(info: info, enabled: false).isAvailable, "dry run / swift run")
        #expect(!SparkleUpdater.isConfigured(["SUFeedURL": "https://kakureneko.example/updates/appcast.xml"]))
        #expect(!SparkleUpdater.isConfigured(["SUFeedURL": "http://kakureneko.example/appcast.xml", "SUPublicEDKey": "abc="]))
        #expect(!SparkleUpdater.isConfigured([:]), "development builds")
    }

    @Test func theUpdaterStartsAtLaunchWithTheSetting() async throws {
        let updater = RecordingUpdater(isAvailable: true)
        var snapshot = PreviewKakurenekoController.sampleSnapshot()
        snapshot.settings.general.automaticUpdateChecks = false
        let delegate = AppDelegate(environment: .inert(updater: updater),
                                   makeController: { PreviewKakurenekoController(snapshot: snapshot) },
                                   makePresenter: { _ in RecordingPresenter() })
        delegate.runLaunchTasks(snapshot)
        #expect(updater.startedWith == false)
    }

    @Test func theToggleReachesSparkleAndTheSettings() async throws {
        let updater = RecordingUpdater(isAvailable: true)
        let (model, controller) = try await connectedModel(environment: .inert(updater: updater))
        await model.setAutomaticUpdateChecks(false)
        #expect(updater.automaticChecks == [false])
        #expect(await controller.currentSnapshot().settings.general.automaticUpdateChecks == false)
        model.checkForUpdates()
        #expect(updater.checks == 1)
    }

    // MARK: Uninstall

    private func installedSnapshot() -> AppSnapshot {
        var snapshot = PreviewKakurenekoController.sampleSnapshot()
        snapshot.isDryRun = false
        snapshot.settings.general.dryRun = false
        snapshot.privileged = PrivilegedStatus(sudoRuleInstalled: true, failsafeLoaded: true, checkedAt: fixedNow, detail: nil)
        snapshot.integrations = [
            IntegrationStatus(agent: .claude, supported: true, configDirExists: true, installed: true),
            IntegrationStatus(agent: .codex, supported: true, configDirExists: true, installed: false, needsRepair: true),
            IntegrationStatus(agent: .gemini, supported: true, configDirExists: true, installed: false),
        ]
        snapshot.settings.general.launchAtLogin = true
        return snapshot
    }

    @Test func thePlanListsWhatThisMacHas() {
        let plan = UninstallPlan.make(snapshot: installedSnapshot(), loginItem: .enabled)
        #expect(plan.removesClosedLidMode)
        #expect(plan.integrations == [.claude, .codex], "installed or half-installed only")
        #expect(plan.removesLoginItem)
        #expect(plan.lines.first?.hasPrefix("Closed-lid mode") == true)
        #expect(plan.lines.contains("Hooks in Claude Code, Codex"))
        #expect(plan.lines.last == "The app itself (moved to the Trash)")

        var bare = PreviewKakurenekoController.sampleSnapshot()
        bare.privileged = PrivilegedStatus(sudoRuleInstalled: false, failsafeLoaded: false, checkedAt: fixedNow, detail: nil)
        bare.integrations = []
        bare.settings.general.launchAtLogin = false
        let nothing = UninstallPlan.make(snapshot: bare, loginItem: .notFound)
        #expect(!nothing.removesClosedLidMode && nothing.integrations.isEmpty && !nothing.removesLoginItem)
        #expect(nothing.lines.count == 3, "iCloud records, files and the app are always removed")
    }

    @Test func uninstallRemovesEverythingInOrderThenFinishes() async throws {
        let loginItem = RecordingLoginItem(status: .enabled)
        let finisher = RecordingUninstallFinisher()
        let (model, controller) = try await connectedModel(
            snapshot: installedSnapshot(), environment: .inert(loginItem: loginItem, uninstallFinisher: finisher))
        await model.uninstall()
        // iPhone alerts off first (removes this Mac's iCloud records), then the admin pieces, then the hooks.
        #expect(await controller.calls == ["updateSettings", "uninstallPrivilegedHelper",
                                           "uninstallIntegration(claude)", "uninstallIntegration(codex)"])
        #expect(await controller.currentSnapshot().settings.notifications.phoneAlerts == false)
        #expect(loginItem.calls == ["unregister"])
        #expect(finisher.finished == 1)
        #expect(model.banner == nil)
    }

    @Test func aCancelledAdminPromptStopsTheUninstallBeforeAnythingElse() async throws {
        let loginItem = RecordingLoginItem(status: .enabled)
        let finisher = RecordingUninstallFinisher()
        let controller = ScriptedController(snapshot: installedSnapshot())
        await controller.fail("uninstallPrivilegedHelper", with: SideEffectError.notPermitted("User canceled."))
        let model = AppModel(environment: .inert(loginItem: loginItem, uninstallFinisher: finisher))
        model.connect(to: controller, start: false)
        #expect(await waitUntil { model.hasReceivedSnapshot })
        await model.uninstall()
        #expect(await controller.calls == ["updateSettings"], "no hook removed")
        #expect(loginItem.calls.isEmpty)
        #expect(finisher.finished == 0, "no file deleted, the app stays")
        #expect(model.banner?.title == "Removing closed-lid mode")
    }

    @Test func aDryRunUninstallOnlyLogs() async throws {
        var snapshot = installedSnapshot()
        snapshot.isDryRun = true
        let finisher = RecordingUninstallFinisher()
        let (model, controller) = try await connectedModel(snapshot: snapshot, environment: .inert(uninstallFinisher: finisher))
        await model.uninstall()
        #expect(await controller.calls.isEmpty)
        #expect(finisher.finished == 0)
        #expect(model.localDryRunLog.count == model.uninstallPlan.lines.count)
        #expect(model.localDryRunLog.allSatisfy { $0.action == "app.uninstall" && $0.detail.hasPrefix("would remove ") })
    }

    @Test func onlyKakurenekosOwnFoldersAreRemoved() throws {
        let paths = try Paths.temporary()
        let folders = LiveUninstallFinisher.folders(in: paths).map(\.path)
        #expect(folders.contains(paths.kakurenekoDirectory.path))
        #expect(folders.contains(paths.appSupport.path))
        #expect(folders.allSatisfy { $0.hasPrefix(paths.home.path + "/") })
        #expect(folders.allSatisfy { $0.contains("kakureneko") || $0.contains("Kakureneko") }, "\(folders)")
        #expect(!folders.contains(paths.home.path))
    }

    // MARK: Onboarding's last step

    private func firstRun() -> AppSnapshot {
        var snapshot = PreviewKakurenekoController.sampleSnapshot()
        snapshot.settings.general.onboardingCompleted = false
        snapshot.settings.general.launchAtLogin = false
        snapshot.isDryRun = false
        return snapshot
    }

    @Test func theFirstRunOpensAtLoginUnlessTheUserSaysNo() async throws {
        let loginItem = RecordingLoginItem()
        let (model, controller) = try await connectedModel(snapshot: firstRun(), environment: .inert(loginItem: loginItem))
        let presenter = RecordingPresenter()
        model.presenter = presenter
        let flow = OnboardingFlow(model: model)
        #expect(flow.openAtLogin, "preset on the first run")
        #expect(!flow.offersUpdates, "no updater in this build")
        await flow.finish()
        #expect(loginItem.calls == ["register"])
        let settings = await controller.currentSnapshot().settings
        #expect(settings.general.launchAtLogin && settings.general.onboardingCompleted)
    }

    @Test func turningTheChoicesOffIsRespected() async throws {
        let loginItem = RecordingLoginItem()
        let updater = RecordingUpdater(isAvailable: true)
        let (model, controller) = try await connectedModel(snapshot: firstRun(),
                                                           environment: .inert(loginItem: loginItem, updater: updater))
        let presenter = RecordingPresenter()
        model.presenter = presenter
        let flow = OnboardingFlow(model: model)
        #expect(flow.offersUpdates && flow.checkForUpdates)
        flow.openAtLogin = false
        flow.checkForUpdates = false
        await flow.finish()
        #expect(loginItem.calls.isEmpty, "never registered")
        #expect(updater.automaticChecks == [false])
        let settings = await controller.currentSnapshot().settings
        #expect(!settings.general.launchAtLogin && !settings.general.automaticUpdateChecks)
    }

    @Test func aRerunShowsTheCurrentLoginSetting() async throws {
        var snapshot = firstRun()
        snapshot.settings.general.onboardingCompleted = true
        snapshot.settings.general.launchAtLogin = false
        let (model, _) = try await connectedModel(snapshot: snapshot)
        #expect(!OnboardingFlow(model: model).openAtLogin, "the user turned it off before")
    }

    // MARK: Settings

    @Test func automaticUpdateChecksDefaultOnAndDecodeTolerantly() throws {
        #expect(KakurenekoSettings.default.general.automaticUpdateChecks)
        let old = try KakurenekoJSON.decode(KakurenekoSettings.self, from: Data(#"{"version": 2, "general": {"enabled": true}}"#.utf8))
        #expect(old.general.automaticUpdateChecks, "files from before the setting")
        var off = KakurenekoSettings.default
        off.general.automaticUpdateChecks = false
        #expect(try KakurenekoJSON.decode(KakurenekoSettings.self, from: KakurenekoJSON.encode(off)).general.automaticUpdateChecks == false)
    }
}
