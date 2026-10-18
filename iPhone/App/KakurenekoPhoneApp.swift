// Kakureneko for iPhone (docs/IPHONE-APP.md): alerts from the user's Macs through Apple's iCloud (the app's public
// CloudKit database, each record readable only by the Apple Account that created it), each Mac's live status, and
// Keep awake / Sleep now / Shut down buttons. The app delegate owns the model; this scene shows it (or the demo over
// it) and tells it when the app enters and leaves the foreground (polling runs only while visible).

import SwiftUI

@main
struct KakurenekoPhoneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AppRootView(live: appDelegate.store, demo: appDelegate.demo)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            let store = appDelegate.store
            switch phase {
            case .active: Task { await store.sceneDidBecomeActive() }
            case .background: store.sceneDidEnterBackground()
            case .inactive: break
            @unknown default: break
            }
        }
    }
}
