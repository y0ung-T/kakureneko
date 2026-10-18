@testable import KakurenekoApp
import AppKit
import KakurenekoKit
import Foundation
import Synchronization
import Testing

/// App lifecycle: the delegate creates and starts the controller at launch, runs the launch tasks once start()
/// reconciled, and quits only after `prepareForTermination()`. Everything is injected: `PreviewKakurenekoController`,
/// `AppEnvironment.inert` (recording login item) and a recording presenter — no window, no SMAppService, no app launch.
@MainActor
@Suite("App lifecycle", .timeLimit(.minutes(1)))
struct LifecycleTests {
    private func makeDelegate(snapshot: AppSnapshot,
                              loginItem: RecordingLoginItem = RecordingLoginItem(),
                              timeout: Duration = .seconds(6)) -> (AppDelegate, PreviewKakurenekoController, RecordingPresenter) {
        let controller = PreviewKakurenekoController(snapshot: snapshot)
        let presenter = RecordingPresenter()
        let delegate = AppDelegate(environment: .inert(loginItem: loginItem),
                                   makeController: { controller },
                                   makePresenter: { _ in presenter },
                                   termination: TerminationFlow(timeout: timeout))
        return (delegate, controller, presenter)
    }

    private func launch(_ delegate: AppDelegate) {
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    }

    private func startingSnapshot(onboardingCompleted: Bool, launchAtLogin: Bool = false) -> AppSnapshot {
        var snapshot = PreviewKakurenekoController.sampleSnapshot()
        snapshot.mode = .starting
        snapshot.settings.general.onboardingCompleted = onboardingCompleted
        snapshot.settings.general.launchAtLogin = launchAtLogin
        return snapshot
    }

    // MARK: Launch

    @Test func launchStartsTheControllerAndShowsOnboardingOnFirstRun() async throws {
        let (delegate, controller, presenter) = makeDelegate(snapshot: startingSnapshot(onboardingCompleted: false))
        #expect(await controller.calls.isEmpty) // creating the delegate has no side effect
        launch(delegate)
        #expect(delegate.model.controller != nil)
        #expect(delegate.presenter === presenter)
        #expect(await waitUntil { presenter.onboardingShown == 1 })
        #expect(await controller.calls == ["start"])
        #expect(delegate.model.snapshot.mode == .full)
    }

    @Test func completedOnboardingIsNotShownAgain() async throws {
        let (delegate, controller, presenter) = makeDelegate(snapshot: startingSnapshot(onboardingCompleted: true))
        launch(delegate)
        #expect(await waitUntil { delegate.model.snapshot.mode == .full })
        // Further republishes never re-run the launch tasks.
        await controller.keepAwake(for: 60)
        #expect(await waitUntil { delegate.model.snapshot.keepAwakeUntil != nil })
        #expect(presenter.onboardingShown == 0)
    }

    @Test func launchReRegistersTheLoginItemWhenOptedIn() async throws {
        let loginItem = RecordingLoginItem(status: .notFound)
        let (delegate, _, _) = makeDelegate(snapshot: startingSnapshot(onboardingCompleted: true, launchAtLogin: true),
                                            loginItem: loginItem)
        launch(delegate)
        #expect(await waitUntil { loginItem.calls == ["register"] })
        #expect(delegate.model.loginItemStatus == .enabled)
    }

    @Test func launchInDryRunOnlyLogsTheLoginItem() async throws {
        let loginItem = RecordingLoginItem(status: .notFound)
        var snapshot = startingSnapshot(onboardingCompleted: true, launchAtLogin: true)
        snapshot.isDryRun = true
        let (delegate, _, _) = makeDelegate(snapshot: snapshot, loginItem: loginItem)
        launch(delegate)
        #expect(await waitUntil { !delegate.model.localDryRunLog.isEmpty })
        #expect(loginItem.calls.isEmpty)
        #expect(delegate.model.localDryRunLog.map(\.detail) == ["would register login item"])
    }

    // MARK: Termination

    @Test func terminationWaitsForPrepareForTermination() async throws {
        let (delegate, controller, _) = makeDelegate(snapshot: startingSnapshot(onboardingCompleted: true))
        launch(delegate)
        #expect(await waitUntil { delegate.model.snapshot.mode == .full })
        var replies: [Bool] = []
        let answer = delegate.shouldTerminate { replies.append($0) }
        #expect(answer == .terminateLater)
        #expect(await waitUntil { replies == [true] })
        #expect(await controller.calls.last == "prepareForTermination")
        // A second request while quitting neither prepares again nor replies twice.
        #expect(delegate.shouldTerminate { replies.append($0) } == .terminateLater)
        try await Task.sleep(for: .milliseconds(20))
        #expect(replies == [true])
        #expect(await controller.calls.filter { $0 == "prepareForTermination" }.count == 1)
    }

    @Test func terminationBeforeLaunchQuitsAtOnce() {
        let (delegate, _, _) = makeDelegate(snapshot: startingSnapshot(onboardingCompleted: true))
        var replies: [Bool] = []
        #expect(delegate.shouldTerminate { replies.append($0) } == .terminateNow)
        #expect(replies.isEmpty)
    }

    @Test func terminationFlowRepliesOnceAfterPrepare() async {
        let flow = TerminationFlow(timeout: .seconds(5))
        var replies: [Bool] = []
        let prepared = Mutex(false)
        let answer = flow.begin(prepare: { prepared.withLock { $0 = true } }, reply: { replies.append($0) })
        #expect(answer == .terminateLater)
        #expect(flow.isTerminating)
        #expect(await waitUntil { flow.hasReplied })
        #expect(replies == [true])
        #expect(prepared.withLock { $0 })
    }

    /// A wedged `prepareForTermination` can never keep the app from quitting: the watchdog replies after exactly
    /// `timeout` (virtual time on a `TestClock`, so a busy main actor can delay the reply but never make it early
    /// or missing), the hanging prepare is cancelled, and nothing replies twice.
    @Test func terminationWatchdogRepliesWhenPrepareHangs() async {
        let clock = TestClock()
        let flow = TerminationFlow(timeout: .seconds(6), clock: clock)
        var replies: [Bool] = []
        let prepareCancelled = Mutex(false)
        _ = flow.begin(prepare: {
            try? await Task.sleep(for: .seconds(30)) // wedged (until the flow cancels it)
            prepareCancelled.withLock { $0 = Task.isCancelled }
        }, reply: { replies.append($0) })
        #expect(await clock.waitForSleepers(1), "the watchdog is armed on the clock")
        clock.advance(by: .seconds(5))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!flow.hasReplied, "no reply before the timeout")
        #expect(replies.isEmpty)
        clock.advance(by: .seconds(1))
        #expect(await waitUntil(timeout: .seconds(10)) { flow.hasReplied })
        #expect(replies == [true])
        #expect(await waitUntil(timeout: .seconds(10)) { prepareCancelled.withLock { $0 } }, "the wedged prepare is cancelled")
        #expect(replies == [true], "replied exactly once")
    }

    /// Review finding: when the watchdog fired, the app exited without the synchronous thaw + disarm (a normal NSApp
    /// exit runs no signal handler). It now runs them before replying; a prepare that finished never needs them.
    @Test func theWatchdogRunsTheSynchronousThawAndDisarmBeforeReplying() async {
        let clock = TestClock()
        let flow = TerminationFlow(timeout: .seconds(6), clock: clock)
        var events: [String] = []
        _ = flow.begin(prepare: { try? await Task.sleep(for: .seconds(30)) },
                       emergency: { events.append("emergency") }, reply: { _ in events.append("reply") })
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(6))
        #expect(await waitUntil(timeout: .seconds(10)) { flow.hasReplied })
        #expect(events == ["emergency", "reply"])

        let quick = TerminationFlow(timeout: .seconds(5))
        var quickEvents: [String] = []
        _ = quick.begin(prepare: {}, emergency: { quickEvents.append("emergency") }, reply: { _ in quickEvents.append("reply") })
        #expect(await waitUntil { quick.hasReplied })
        #expect(quickEvents == ["reply"])
    }

    @Test func theDelegateWiresTheSynchronousTerminationPaths() async throws {
        let (delegate, controller, _) = makeDelegate(snapshot: startingSnapshot(onboardingCompleted: true), timeout: .milliseconds(50))
        launch(delegate)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(controller.terminateSynchronouslyCount == 1)
    }

    // MARK: Launch at login

    @Test func loginItemPolicyAtLaunch() {
        typealias P = LoginItemPolicy
        #expect(P.atLaunch(optedIn: false, status: .notFound, isDryRun: false, isBundled: true) == .none)
        #expect(P.atLaunch(optedIn: true, status: .enabled, isDryRun: false, isBundled: true) == .none)
        #expect(P.atLaunch(optedIn: true, status: .requiresApproval, isDryRun: false, isBundled: true) == .none)
        #expect(P.atLaunch(optedIn: true, status: .notFound, isDryRun: false, isBundled: true) == .register)
        #expect(P.atLaunch(optedIn: true, status: .notRegistered, isDryRun: false, isBundled: true) == .register)
        #expect(P.atLaunch(optedIn: true, status: .notFound, isDryRun: true, isBundled: true) == .log("would register login item"))
        if case .log = P.atLaunch(optedIn: true, status: .notFound, isDryRun: false, isBundled: false) {} else {
            Issue.record("a bare executable must never be registered")
        }
    }

    @Test func loginItemPolicyWhenToggled() {
        typealias P = LoginItemPolicy
        #expect(P.toggled(on: true, status: .notFound, isDryRun: false, isBundled: true) == .register)
        #expect(P.toggled(on: true, status: .enabled, isDryRun: false, isBundled: true) == .none)
        #expect(P.toggled(on: true, status: .notFound, isDryRun: true, isBundled: true) == .log("would register login item"))
        #expect(P.toggled(on: false, status: .enabled, isDryRun: false, isBundled: true) == .unregister)
        #expect(P.toggled(on: false, status: .requiresApproval, isDryRun: false, isBundled: true) == .unregister)
        #expect(P.toggled(on: false, status: .notFound, isDryRun: false, isBundled: true) == .none)
        #expect(P.toggled(on: false, status: .enabled, isDryRun: true, isBundled: true) == .log("would unregister login item"))
        #expect(P.toggled(on: false, status: .enabled, isDryRun: false, isBundled: false) == .none)
    }

    @Test func launchAtLoginToggleRegistersThenPersists() async throws {
        let loginItem = RecordingLoginItem(status: .notFound)
        let (model, controller) = try await connectedModel(environment: .inert(loginItem: loginItem))
        await model.setLaunchAtLogin(true)
        #expect(loginItem.calls == ["register"])
        #expect(model.loginItemStatus == .enabled)
        #expect(await controller.currentSnapshot().settings.general.launchAtLogin)
        await model.setLaunchAtLogin(false)
        #expect(loginItem.calls == ["register", "unregister"])
        #expect(await controller.currentSnapshot().settings.general.launchAtLogin == false)
        #expect(await controller.calls == ["updateSettings", "updateSettings"])
    }

    @Test func launchAtLoginFailureIsReportedAndNotPersisted() async throws {
        let loginItem = RecordingLoginItem(status: .notFound)
        loginItem.failure = SideEffectError.notPermitted("Operation not permitted")
        let (model, controller) = try await connectedModel(environment: .inert(loginItem: loginItem))
        await model.setLaunchAtLogin(true)
        #expect(loginItem.calls == ["register"])
        #expect(model.banner?.title == "Turning on launch at login")
        #expect(await controller.calls.isEmpty)
        #expect(await controller.currentSnapshot().settings.general.launchAtLogin == false)
    }

    /// Spec: in dry-run the toggle never calls SMAppService; it logs and still remembers the preference.
    @Test func launchAtLoginInDryRunOnlyLogs() async throws {
        let loginItem = RecordingLoginItem(status: .notFound)
        var snapshot = PreviewKakurenekoController.sampleSnapshot()
        snapshot.isDryRun = true
        let (model, controller) = try await connectedModel(snapshot: snapshot, environment: .inert(loginItem: loginItem))
        await model.setLaunchAtLogin(true)
        #expect(loginItem.calls.isEmpty)
        #expect(model.localDryRunLog.map(\.detail) == ["would register login item"])
        #expect(await controller.currentSnapshot().settings.general.launchAtLogin)
    }

    @Test func dryRunForcedByTheEnvironmentAlsoOnlyLogs() async throws {
        let loginItem = RecordingLoginItem(status: .notFound)
        let (model, _) = try await connectedModel(environment: .inert(loginItem: loginItem, dryRunForcedByEnvironment: true))
        model.reconcileLoginItem(optedIn: true)
        #expect(loginItem.calls.isEmpty)
        #expect(model.localDryRunLog.count == 1)
    }

    @Test func openLoginItemsSettingsGoesThroughTheEnvironment() async throws {
        let loginItem = RecordingLoginItem(status: .requiresApproval)
        let (model, _) = try await connectedModel(environment: .inert(loginItem: loginItem))
        model.openLoginItemsSettings()
        #expect(loginItem.calls == ["openSystemSettings"])
    }

    @Test func loginItemStatusTexts() {
        #expect(LoginItemStatus.notFound.text == "Not registered")
        #expect(LoginItemStatus.enabled.text == "Enabled")
        #expect(LoginItemStatus.requiresApproval.text.contains("Login Items"))
    }

    /// The live environment is only built by `AppDelegate()`; building it has no side effects and classifies the bundle.
    @Test func liveEnvironmentDetectsBundleAndDryRun() {
        let bundled = AppEnvironment.live(processEnvironment: [KakurenekoEnvironment.dryRun: "1"],
                                          bundleURL: URL(filePath: "/Applications/Kakureneko.app", directoryHint: .isDirectory))
        #expect(bundled.isBundled)
        #expect(bundled.dryRunForcedByEnvironment)
        let bare = AppEnvironment.live(processEnvironment: [:], bundleURL: URL(filePath: "/tmp/.build/debug", directoryHint: .isDirectory))
        #expect(!bare.isBundled)
        #expect(!bare.dryRunForcedByEnvironment)
    }
}
