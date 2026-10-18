@testable import KakurenekoApp
import KakurenekoKit
import Foundation
import Testing

@MainActor
@Suite("KakurenekoApp model", .timeLimit(.minutes(1)))
struct AppModelTests {
    /// The UI model follows the controller's snapshot stream (PreviewKakurenekoController: no system access).
    @Test func modelFollowsSnapshots() async throws {
        let controller = PreviewKakurenekoController()
        let model = AppModel()
        model.connect(to: controller)
        for _ in 0..<200 where model.snapshot.sessions.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.snapshot.sessions.count == 2)
        #expect(model.snapshot.statusLine == "1 working · 1 waiting")
    }

    @Test func connectSubscribesThenStarts() async throws {
        let controller = PreviewKakurenekoController()
        let model = AppModel()
        #expect(model.snapshot.mode == .starting)
        #expect(!model.hasReceivedSnapshot)
        model.connect(to: controller)
        #expect(await waitUntil { model.snapshot.mode == .full })
        #expect(await controller.calls == ["start"])
    }

    @Test func connectWithoutStartDoesNotStart() async throws {
        let (model, controller) = try await connectedModel()
        #expect(model.snapshot.sessions.count == 2)
        #expect(await controller.calls.isEmpty)
    }

    @Test func republishedSnapshotsReplaceTheModelState() async throws {
        let (model, controller) = try await connectedModel()
        var next = PreviewKakurenekoController.sampleSnapshot()
        next.sessions = []
        next.aggregate = .empty
        next.mode = .disabled
        await controller.publish(next)
        #expect(await waitUntil { model.snapshot.mode == .disabled })
        #expect(model.snapshot.sessions.isEmpty)
        #expect(model.snapshot.statusLine == "Off")
    }

    @Test func startedHandlerRunsExactlyOnce() async throws {
        let controller = PreviewKakurenekoController()
        let model = AppModel()
        var seen: [OperatingMode] = []
        model.onStarted = { seen.append($0.mode) }
        model.connect(to: controller, start: false)
        #expect(await waitUntil { model.hasReceivedSnapshot })
        await controller.keepAwake(for: 60)
        #expect(await waitUntil { model.snapshot.keepAwakeUntil != nil })
        #expect(seen == [.full])
    }

    /// The coordinator's initial `.starting` snapshot precedes `start()` (dry-run gate not applied yet): launch tasks
    /// wait for the first snapshot after it.
    @Test func startedHandlerWaitsForTheEndOfStarting() async throws {
        var initial = PreviewKakurenekoController.sampleSnapshot()
        initial.mode = .starting
        initial.privileged = .unknown
        let controller = PreviewKakurenekoController(snapshot: initial)
        let model = AppModel()
        var seen: [OperatingMode] = []
        model.onStarted = { seen.append($0.mode) }
        model.connect(to: controller, start: false)
        #expect(await waitUntil { model.hasReceivedSnapshot })
        #expect(seen.isEmpty)
        await controller.start()
        #expect(await waitUntil { !seen.isEmpty })
        #expect(seen == [.notificationsOnly])
    }

    @Test func persistedDryRunRequestCountsAsDryRun() async throws {
        var snapshot = PreviewKakurenekoController.sampleSnapshot()
        snapshot.isDryRun = false
        snapshot.settings.general.dryRun = true
        let (model, _) = try await connectedModel(snapshot: snapshot)
        #expect(model.isDryRun)
    }

    @Test func powerActionsCallTheController() async throws {
        let (model, controller) = try await connectedModel()
        await model.keepAwake(for: 15 * 60)
        await model.cancelKeepAwake()
        await model.sleepNow()
        await model.cancelWindDown()
        await model.setEnabled(false)
        #expect(await controller.calls == ["keepAwake(900)", "cancelKeepAwake", "sleepNow", "cancelWindDown", "setEnabled(false)"])
        #expect(await waitUntil { model.snapshot.mode == .disabled })
    }

    @Test func sessionAndPausingActionsCallTheController() async throws {
        let (model, controller) = try await connectedModel()
        let key = SessionKey(agent: .codex, id: "thread-7")
        await model.dismissSession(key)
        await model.resumeAllApps()
        await model.setNeverPause(bundleID: "com.spotify.client", true)
        #expect(await controller.calls == ["dismissSession(codex/thread-7)", "resumeAllApps", "setNeverPause(com.spotify.client,true)"])
        #expect(await waitUntil { model.snapshot.settings.pausing.neverPauseBundleIDs == ["com.spotify.client"] })
        #expect(model.snapshot.sessions.count == 1)
        #expect(model.snapshot.pausedApps.isEmpty)
    }

    @Test func notificationActionsCallTheController() async throws {
        let opener = RecordingURLOpener()
        let (model, controller) = try await connectedModel(environment: .inert(urlOpener: opener))
        #expect(await model.requestNotificationPermission() == .authorized)
        #expect(!model.isRunning(.notificationPermission))
        #expect(await model.sendTestNotification())
        await model.handleCloudPush()
        #expect(await controller.calls == ["requestNotificationPermission", "sendTestNotification", "handleCloudPush"])
        #expect(await waitUntil { model.snapshot.notifications.macAuthorization == .authorized })
        model.openNotificationSettings()
        #expect(opener.opened == [AppLinks.notificationSettings])
    }

    @Test func integrationPreviewAndApplyCallTheController() async throws {
        let (model, controller) = try await connectedModel()
        let plan = try #require(await model.previewIntegration(.codex, operation: .uninstall))
        #expect(plan.agent == .codex && plan.operation == .uninstall)
        #expect(!plan.changes.isEmpty)
        let result = await model.applyIntegration(plan)
        #expect(result?.status.installed == false)
        #expect(await controller.calls == ["previewIntegration(codex,uninstall)", "uninstallIntegration(codex)", "refreshIntegrations"])

        let install = InstallPlan(agent: .gemini, operation: .install)
        _ = await model.applyIntegration(install)
        let repair = InstallPlan(agent: .claude, operation: .repair)
        _ = await model.applyIntegration(repair)
        let calls = await controller.calls
        #expect(calls.contains("installIntegration(gemini)"))
        #expect(calls.contains("repairIntegration(claude)"))
        #expect(!model.isRunning(.integration(.codex)))
    }

    @Test func dismissAndRestoreIntegrationPersistViaSettings() async throws {
        let (model, controller) = try await connectedModel()
        await model.dismissIntegration(.codex)
        #expect(await controller.currentSnapshot().settings.integrations.dismissedAgents == [.codex])
        await model.restoreIntegration(.codex)
        #expect(await controller.currentSnapshot().settings.integrations.dismissedAgents.isEmpty)
        #expect(await controller.calls == ["updateSettings", "updateSettings"])
    }

    @Test func privilegedInstallAndUninstall() async throws {
        let (model, controller) = try await connectedModel()
        #expect(await model.installPrivilegedHelper())
        #expect(await model.uninstallPrivilegedHelper())
        await model.refreshPrivilegedStatus()
        #expect(await controller.calls == ["installPrivilegedHelper", "uninstallPrivilegedHelper", "refreshPrivilegedStatus"])
        #expect(await waitUntil { model.snapshot.mode == .notificationsOnly })
    }

    @Test func failuresBecomeABannerNotACrash() async throws {
        let controller = ScriptedController()
        await controller.fail("installPrivilegedHelper", with: SideEffectError.notPermitted("the admin prompt was cancelled"))
        await controller.fail("sendTestNotification", with: DeliveryError.retryable(after: 30))
        await controller.fail("previewIntegration", with: SideEffectError.unavailable("hook helper not deployed"))
        let model = AppModel()
        model.connect(to: controller, start: false)
        #expect(await waitUntil { model.hasReceivedSnapshot })

        #expect(await model.installPrivilegedHelper() == false)
        #expect(model.banner?.title == "Installing closed-lid mode")
        #expect(model.banner?.message == "Not permitted: the admin prompt was cancelled")
        #expect(!model.isRunning(.privileged))

        #expect(await model.sendTestNotification() == false)
        #expect(model.banner?.message == "iCloud could not be reached. Kakureneko retries in 30s.")

        #expect(await model.previewIntegration(.claude, operation: .install) == nil)
        #expect(model.banner?.message == "Unavailable: hook helper not deployed")
        model.dismissBanner()
        #expect(model.banner == nil)
    }

    @Test func actionsBeforeConnectingExplainInsteadOfFailingSilently() async {
        let model = AppModel()
        #expect(await model.sendTestNotification() == false)
        #expect(model.banner?.message.contains("still starting") == true)
        await model.sleepNow() // no controller: a no-op, never a crash
    }

    @Test func resumeOfferReopensThenClears() async throws {
        let reopener = RecordingSessionReopener()
        var snapshot = PreviewKakurenekoController.sampleSnapshot()
        snapshot.resumeOffer = [
            ResumeEntry(agent: .claude, sessionId: "3514aa88-efa8", cwd: "/Users/me/api", title: "api"),
            ResumeEntry(agent: .claude, sessionId: "abc; rm -rf ~", cwd: "/Users/me/web", title: "web"),
        ]
        let (model, controller) = try await connectedModel(snapshot: snapshot, environment: .inert(reopener: reopener))
        await model.reopenResumeOffer()
        #expect(reopener.reopened == [snapshot.resumeOffer])
        #expect(await controller.calls == ["clearResumeOffer"])
        #expect(model.banner?.title == "Some sessions could not be reopened")
        #expect(model.banner?.message == "Claude Code · web")
        #expect(await waitUntil { model.snapshot.resumeOffer.isEmpty })
    }

    @Test func resumeOfferInDryRunIsOnlyLogged() async throws {
        let reopener = RecordingSessionReopener()
        var snapshot = PreviewKakurenekoController.sampleSnapshot()
        snapshot.isDryRun = true
        snapshot.resumeOffer = [ResumeEntry(agent: .claude, sessionId: "s1", cwd: "/x/api", title: "api")]
        let (model, controller) = try await connectedModel(snapshot: snapshot, environment: .inert(reopener: reopener))
        await model.reopenResumeOffer()
        #expect(reopener.reopened.isEmpty)
        #expect(model.localDryRunLog.map(\.detail) == ["would reopen Claude Code · api"])
        #expect(await controller.calls == ["clearResumeOffer"])
    }

    @Test func dismissResumeOffer() async throws {
        var snapshot = PreviewKakurenekoController.sampleSnapshot()
        snapshot.resumeOffer = [ResumeEntry(agent: .claude, sessionId: "s1", cwd: "/x", title: nil)]
        let reopener = RecordingSessionReopener()
        let (model, controller) = try await connectedModel(snapshot: snapshot, environment: .inert(reopener: reopener))
        await model.dismissResumeOffer()
        #expect(await controller.calls == ["clearResumeOffer"])
        #expect(reopener.reopened.isEmpty)
    }

    @Test func windowsPasteboardAndURLsGoThroughTheEnvironment() async throws {
        let pasteboard = RecordingPasteboard()
        let opener = RecordingURLOpener()
        let presenter = RecordingPresenter()
        let (model, _) = try await connectedModel(environment: .inert(pasteboard: pasteboard, urlOpener: opener))
        model.presenter = presenter
        model.copy("some text")
        model.open(URL(string: "https://example.com/kakureneko")!)
        model.openSettings(.notifications)
        model.openSettings()
        model.openOnboarding()
        model.closeOnboarding()
        #expect(pasteboard.copied == ["some text"])
        #expect(opener.opened == [URL(string: "https://example.com/kakureneko")!])
        #expect(presenter.settingsRequests == [.notifications, nil])
        #expect(model.settingsPane == .notifications)
        #expect(presenter.onboardingShown == 1 && presenter.onboardingClosed == 1)
    }

    @Test func defaultModelUsesInertServices() {
        let model = AppModel()
        #expect(model.environment.loginItem is RecordingLoginItem)
        #expect(model.environment.automation is RecordingAutomationConsent)
        #expect(model.environment.reopener is RecordingSessionReopener)
    }

    @Test func dryRunIsTheGateOrTheEnvironment() async throws {
        let (model, controller) = try await connectedModel()
        #expect(!model.isDryRun)
        var next = await controller.currentSnapshot()
        next.isDryRun = true
        await controller.publish(next)
        #expect(await waitUntil { model.isDryRun })

        let forced = AppModel(environment: .inert(dryRunForcedByEnvironment: true))
        #expect(forced.isDryRun)
    }

    @Test func localDryRunLogIsCapped() {
        let model = AppModel(environment: .inert(now: { fixedNow }))
        for i in 0..<30 { model.recordLocalDryRun(action: "app.test", detail: "would \(i)") }
        #expect(model.localDryRunLog.count == 20)
        #expect(model.localDryRunLog.first?.detail == "would 10")
        #expect(model.localDryRunLog.last?.detail == "would 29")
        #expect(model.localDryRunLog.allSatisfy { $0.category == .app && $0.at == fixedNow })
    }
}
