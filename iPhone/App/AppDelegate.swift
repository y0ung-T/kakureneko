// The app delegate: owns the `PhoneStore` (created before any scene, because iOS also launches the app in the
// background for silent pushes and notification buttons) and the `DemoMode` switch, registers for remote
// notifications, turns `phone-statuses-v1` silent pushes into syncs, follows iCloud account changes, and is the
// `UNUserNotificationCenter` delegate: banners while the app is open, buttons → `Command` records (inside a
// background task), taps → that Mac (ending a demo first). Pushes, buttons and taps always go to the real store,
// never to a demo.

import CloudKit
import KakurenekoCloud
import os
import UIKit
import UserNotifications

private let log = Logger(subsystem: "com.kakureneko.Kakureneko", category: "AppDelegate")

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let store: PhoneStore
    /// The in-app demo ("See a demo"): its own store on fakes, shown over the real app while it runs.
    let demo: DemoMode
    private var accountObserver: (any NSObjectProtocol)?
    #if DEBUG
    /// Debug builds only: `-KakurenekoDemo oneMac|working|waiting|countdown|…` runs the whole app on a demo scenario
    /// instead of iCloud (Simulator screenshots, design reviews): no live store, no pushes, no demo banner.
    private let launchDemo = DemoEnvironment.fromLaunchArguments()
    #endif

    override init() {
        #if DEBUG
        store = launchDemo?.store ?? PhoneStore.live()
        #else
        store = PhoneStore.live()
        #endif
        demo = DemoMode(device: .current())
        super.init()
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if DEBUG
        if let launchDemo {
            Task { await launchDemo.run() }
            // `-KakurenekoDemoCover YES`: also open the in-app demo (banner and all) over it.
            if UserDefaults.standard.bool(forKey: "KakurenekoDemoCover") {
                demo.start()
                demo.session?.store.selectedTab = launchDemo.store.selectedTab
            }
            return true
        }
        #endif
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let store = self?.store else { return }
                Task { await store.accountDidChange() }
            }
        }
        store.registerCategoriesIfNeeded() // before any notification response is handled
        Task { await store.start() }
        return true
    }

    // MARK: Remote notifications

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        log.info("registered for remote notifications") // CloudKit manages the token itself
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        log.error("remote notification registration failed: \(error.localizedDescription, privacy: .public)")
    }

    /// A silent push (`phone-statuses-v1`: a Mac's status changed; `alerts-v1` pushes are visible and go to the
    /// notification service extension).
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              CloudSchema.SubscriptionID.silent.contains(notification.subscriptionID ?? "") else { return .noData }
        switch await store.handleZonePush() {
        case .changed: return .newData
        case .unchanged, .skipped: return .noData
        case .unavailable, .failed: return .failed
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    // Completion-handler forms on purpose: with the `async` forms Swift calls iOS's completion handler from a
    // cooperative-pool thread, and UIKit aborts the app ("_performBlockAfterCATransactionCommitSynchronizes" main-thread
    // assertion) — every notification tap crashed the app instead of opening it.

    /// While the app is open: show the banner too, and refresh so the Activity list has the alert at once.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
        Task { @MainActor in self.refreshForPresentedAlert() }
    }

    /// A tap on a notification or one of its buttons. Decoded here into a Sendable value; the completion handler
    /// (iOS: "done") is called on the main thread once handled, so a button's command is saved first.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = NotificationResponseAction(actionIdentifier: response.actionIdentifier,
                                                userInfo: response.notification.request.content.userInfo)
        let done = MainThreadCompletion(completionHandler)
        Task { @MainActor in
            await self.handle(action)
            done.call()
        }
    }

    private func refreshForPresentedAlert() {
        Task { await store.sync(force: true) }
    }

    private func handle(_ action: NotificationResponseAction) async {
        switch action {
        case .open(let macID):
            // A real notification wins over a demo: show the real Mac.
            if demo.isActive { demo.end() }
            store.open(macID: macID)
        case .button(let tap, let macName):
            // A button runs in the background (the app is not opened): hold a background task until the command
            // is saved. If iOS ends it first, the command stays queued and the user is told.
            let store = self.store
            let task = BackgroundTask(name: "Send command to Mac") { store.backgroundTimeWillExpire() }
            await store.handleButtonTap(tap, macName: macName)
            task.end()
        case .ignore:
            break
        }
    }
}

/// iOS's notification-response completion handler, carried to the main actor and called only there (UIKit requires
/// the main thread); it is not marked Sendable in the SDK, hence the unchecked wrapper.
private struct MainThreadCompletion: @unchecked Sendable {
    private let body: () -> Void

    init(_ body: @escaping () -> Void) { self.body = body }

    @MainActor func call() { body() }
}
