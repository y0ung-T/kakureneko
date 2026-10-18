@testable import KakurenekoApp
import KakurenekoCloud
import KakurenekoKit
import Foundation
import Testing

/// Onboarding (brief §8.6, spec card §9.9) driven against `PreviewKakurenekoController`: every step calls the
/// controller, never the system.
@MainActor
@Suite("Onboarding flow", .timeLimit(.minutes(1)))
struct OnboardingFlowTests {
    /// A first-launch snapshot: privileged part missing, Mac notifications never asked, no iPhone yet, onboarding not
    /// completed.
    private func firstLaunch(isDryRun: Bool = false) -> AppSnapshot {
        var snapshot = PreviewKakurenekoController.sampleSnapshot()
        snapshot.mode = .notificationsOnly
        snapshot.privileged = PrivilegedStatus(sudoRuleInstalled: false, failsafeLoaded: false, checkedAt: fixedNow, detail: nil)
        snapshot.notifications = NotificationStatus(macAuthorization: .notDetermined, iCloud: .available)
        snapshot.settings.general.onboardingCompleted = false
        snapshot.isDryRun = isDryRun
        return snapshot
    }

    private func makeFlow(snapshot: AppSnapshot? = nil,
                          environment: AppEnvironment = .inert()) async throws -> (OnboardingFlow, AppModel, PreviewKakurenekoController, RecordingPresenter) {
        let (model, controller) = try await connectedModel(snapshot: snapshot ?? firstLaunch(), environment: environment)
        let presenter = RecordingPresenter()
        model.presenter = presenter
        return (OnboardingFlow(model: model), model, controller, presenter)
    }

    // MARK: Step 1 — closed-lid mode

    @Test func startsAtClosedLidAndOffersTheSkip() async throws {
        let (flow, _, _, _) = try await makeFlow()
        #expect(flow.step == .closedLid)
        #expect(flow.isFirstStep && !flow.isLastStep)
        #expect(flow.continueTitle == "Skip · notifications only")
        #expect(flow.privilegedSummary.offersInstall)
    }

    @Test func installUsesOneControllerCallThenAdvancesToNotifications() async throws {
        let (flow, _, controller, _) = try await makeFlow()
        await flow.installPrivileged()
        #expect(flow.privilegedChoice == .installed)
        #expect(flow.step == .notifications)
        // Entering the notifications step asks for nothing by itself (the user taps Allow).
        #expect(await controller.calls == ["installPrivilegedHelper"])
    }

    @Test func failedInstallStaysOnTheStepWithABanner() async throws {
        let controller = ScriptedController(snapshot: firstLaunch())
        await controller.fail("installPrivilegedHelper", with: SideEffectError.notPermitted("User canceled."))
        let model = AppModel()
        model.connect(to: controller, start: false)
        #expect(await waitUntil { model.hasReceivedSnapshot })
        let flow = OnboardingFlow(model: model)
        await flow.installPrivileged()
        #expect(flow.step == .closedLid)
        #expect(flow.privilegedChoice == nil)
        #expect(model.banner?.title == "Installing closed-lid mode")
        #expect(await controller.calls.isEmpty)
    }

    @Test func skipMeansNotificationsOnly() async throws {
        let (flow, _, controller, _) = try await makeFlow()
        await flow.skipPrivileged()
        #expect(flow.privilegedChoice == .skipped)
        #expect(flow.step == .notifications)
        #expect(await controller.calls.isEmpty)
    }

    @Test func continueOnStepOneWithoutChoosingSkips() async throws {
        let (flow, _, _, _) = try await makeFlow()
        await flow.next()
        #expect(flow.privilegedChoice == .skipped)
        #expect(flow.step == .notifications)
    }

    @Test func alreadyInstalledSaysContinue() async throws {
        let (flow, _, _, _) = try await makeFlow(snapshot: PreviewKakurenekoController.sampleSnapshot())
        #expect(flow.continueTitle == "Continue")
        await flow.next()
        #expect(flow.privilegedChoice == nil)
        #expect(flow.step == .notifications)
    }

    // MARK: Step 2 — notifications

    @Test func allowingMacNotificationsSaysContinue() async throws {
        let (flow, model, controller, _) = try await makeFlow()
        await flow.enter(.notifications)
        #expect(!flow.macAllowed && !flow.phoneConnected)
        #expect(flow.continueTitle == "Skip for now")
        #expect(await model.requestNotificationPermission() == .authorized)
        #expect(await controller.calls == ["requestNotificationPermission"])
        #expect(await waitUntil { flow.macAllowed })
        #expect(flow.continueTitle == "Continue")
    }

    @Test func anIPhoneConnectsByItself() async throws {
        let (flow, _, controller, _) = try await makeFlow()
        await flow.enter(.notifications)
        // The iPhone app saved its device record: the coordinator republishes, no pairing step involved.
        var connected = await controller.currentSnapshot()
        connected.notifications.phones = [PhoneDevice(deviceID: "p", name: "iPhone", model: "iPhone18,3", systemVersion: "26.6.1",
                                                      appVersion: "0.1.0", alertsAuthorized: true, lastSeenAt: fixedNow)]
        await controller.publish(connected)
        #expect(await waitUntil { flow.phoneConnected })
        #expect(flow.continueTitle == "Continue", "an iPhone alone is enough")
        #expect(await controller.calls.isEmpty)
    }

    @Test func noICloudMeansNoPhoneConnection() async throws {
        var snapshot = firstLaunch()
        snapshot.notifications.iCloud = .noAccount
        snapshot.notifications.phones = [PhoneDevice(deviceID: "p", name: "iPhone", model: "iPhone18,3", systemVersion: "26",
                                                     appVersion: "1", alertsAuthorized: true, lastSeenAt: fixedNow)]
        let (flow, _, _, _) = try await makeFlow(snapshot: snapshot)
        #expect(!flow.phoneConnected)
    }

    // MARK: Step 3 — integrations

    @Test func integrationsStepRefreshesAndOffersOnlyDetectedAgents() async throws {
        let (flow, model, controller, _) = try await makeFlow()
        await flow.enter(.integrations)
        #expect(await controller.calls == ["refreshIntegrations"])
        // Gemini's config dir does not exist in the sample: never offered (phantom-install rule).
        #expect(flow.integrations.map(\.agent) == [.claude, .codex])
        await model.dismissIntegration(.codex)
        #expect(await waitUntil { flow.integrations.map(\.agent) == [.claude] })
    }

    @Test func codexUninstallPreviewIsShownBeforeAnythingIsWritten() async throws {
        let (_, model, controller, _) = try await makeFlow()
        let plan = try #require(await model.previewIntegration(.codex, operation: .uninstall))
        #expect(await controller.calls == ["previewIntegration(codex,uninstall)"])
        #expect(plan.changes.first?.unifiedDiff.isEmpty == false)
    }

    // MARK: Step 4 — end action

    @Test func choosingShutdownPersistsAndAsksForAutomationConsent() async throws {
        let consent = RecordingAutomationConsent(result: .denied)
        let (flow, model, controller, _) = try await makeFlow(environment: .inert(automation: consent))
        await flow.enter(.finish)
        #expect(flow.endAction == .sleep)
        await flow.setEndAction(.shutdown)
        #expect(await controller.currentSnapshot().settings.power.endAction == .shutdown)
        #expect(consent.requestCount == 1)
        #expect(model.automationConsent == .denied)
        #expect(await waitUntil { flow.endAction == .shutdown })
        // Back to sleep: no new prompt.
        await flow.setEndAction(.sleep)
        #expect(consent.requestCount == 1)
    }

    @Test func dryRunNeverAsksForAutomationConsent() async throws {
        let consent = RecordingAutomationConsent()
        let (flow, model, _, _) = try await makeFlow(snapshot: firstLaunch(isDryRun: true),
                                                     environment: .inert(automation: consent))
        await flow.setEndAction(.shutdown)
        #expect(consent.requestCount == 0)
        #expect(model.automationConsent == .skippedInDryRun)
        // The explicit "Ask" button is also only logged.
        await model.requestAutomationConsent()
        #expect(consent.requestCount == 0)
        #expect(model.localDryRunLog.count == 2)
    }

    @Test func sleepIsTheDefaultAndNeverAsks() async throws {
        let consent = RecordingAutomationConsent()
        let (flow, _, controller, _) = try await makeFlow(environment: .inert(automation: consent))
        await flow.setEndAction(.sleep)
        #expect(consent.requestCount == 0)
        #expect(await controller.calls.isEmpty) // unchanged settings → no update
    }

    // MARK: Navigation and finishing

    @Test func walksEveryStepAndCompletesOnboarding() async throws {
        let (flow, _, controller, presenter) = try await makeFlow()
        #expect(flow.step == .closedLid)
        await flow.next()
        #expect(flow.step == .notifications)
        await flow.next()
        #expect(flow.step == .integrations)
        await flow.next()
        #expect(flow.step == .finish)
        #expect(flow.isLastStep)
        #expect(flow.continueTitle == "Done")
        await flow.next()
        #expect(flow.isFinished)
        #expect(presenter.onboardingClosed == 1)
        #expect(await controller.currentSnapshot().settings.general.onboardingCompleted)
        // Done applies "Open Kakureneko at login" (preset on the first run), then completes.
        #expect(await controller.calls == ["refreshIntegrations", "updateSettings", "completeOnboarding"])
    }

    // MARK: Step 2 — the iPhone

    private func phone(authorized: Bool = true) -> PhoneDevice {
        PhoneDevice(deviceID: "p1", name: "iPhone", model: "iPhone18,3", systemVersion: "26.6.1", appVersion: "1.0.0",
                    alertsAuthorized: authorized, timeSensitiveAllowed: true, lastSeenAt: fixedNow)
    }

    @Test func withoutAnIPhoneStepTwoAsks() async throws {
        let (flow, _, _, _) = try await makeFlow()
        await flow.enter(.notifications)
        #expect(flow.phoneSetup == .ask)
        #expect(flow.continueTitle == "Skip for now", "nothing allowed or chosen yet")
    }

    @Test func setUpMyIPhoneWaitsForItAndKeepsIPhoneAlertsOn() async throws {
        var snapshot = firstLaunch()
        snapshot.settings.notifications.phoneAlerts = false // a rerun after "Just this Mac"
        let (flow, model, controller, _) = try await makeFlow(snapshot: snapshot)
        await flow.enter(.notifications)
        await flow.chooseIPhone()
        #expect(flow.phoneSetup == .waitingForIPhone)
        #expect(flow.continueTitle == "Continue")
        #expect(await controller.currentSnapshot().settings.notifications.phoneAlerts, "the iPhone finds this Mac through its status")
        // The iPhone's record arrives: connected, by itself.
        var connected = await controller.currentSnapshot()
        connected.notifications.phones = [phone()]
        await controller.publish(connected)
        #expect(await waitUntil { flow.phoneSetup == .connected })
        _ = model
    }

    @Test func justThisMacTurnsIPhoneAlertsOffAndCanBeUndone() async throws {
        let (flow, _, controller, _) = try await makeFlow()
        await flow.enter(.notifications)
        await flow.chooseMacOnly()
        #expect(flow.phoneSetup == .macOnly)
        #expect(flow.continueTitle == "Continue")
        #expect(await controller.currentSnapshot().settings.notifications.phoneAlerts == false, "nothing about this Mac goes to iCloud")
        await flow.chooseIPhone()
        #expect(flow.phoneSetup == .waitingForIPhone)
        #expect(await controller.currentSnapshot().settings.notifications.phoneAlerts)
    }

    @Test func anIPhoneThatCameFirstIsAlreadyConnected() async throws {
        var snapshot = firstLaunch()
        snapshot.notifications.phones = [phone()]
        let (flow, _, _, _) = try await makeFlow(snapshot: snapshot)
        await flow.enter(.notifications)
        #expect(flow.phoneSetup == .connected)
        #expect(flow.continueTitle == "Continue")
        // With iPhone alerts off it asks again (a connected iPhone would get nothing).
        snapshot.settings.notifications.phoneAlerts = false
        let (off, _, _, _) = try await makeFlow(snapshot: snapshot)
        #expect(off.phoneSetup == .ask)
    }

    @Test func withoutICloudTheIPhonePartExplains() async throws {
        var snapshot = firstLaunch()
        snapshot.notifications = NotificationStatus(macAuthorization: .notDetermined, iCloud: .noAccount)
        let (flow, _, _, _) = try await makeFlow(snapshot: snapshot)
        #expect(flow.phoneSetup == .iCloudUnavailable)
    }

    @Test func backGoesToThePreviousStepAndStopsAtTheFirst() async throws {
        let (flow, _, _, _) = try await makeFlow()
        await flow.enter(.integrations)
        flow.back()
        #expect(flow.step == .notifications)
        flow.back()
        #expect(flow.step == .closedLid)
        flow.back()
        #expect(flow.step == .closedLid)
    }

    @Test func reenteringStepOneRechecksThePrivilegedStatus() async throws {
        let (flow, _, controller, _) = try await makeFlow()
        await flow.enter(.closedLid)
        #expect(await controller.calls == ["refreshPrivilegedStatus"])
    }
}
