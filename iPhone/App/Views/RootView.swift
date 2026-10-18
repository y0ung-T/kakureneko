// The top of the view tree: the real app, with the demo over it while one runs; inside each, onboarding on first
// run, then three tabs — the Mac(s), recent Activity, Settings.

import SwiftUI

/// The real app (the live store), covered by the demo while `DemoMode` runs one. The real app's views stay where
/// they were underneath (onboarding step, navigation), so ending the demo returns to exactly that.
struct AppRootView: View {
    let live: PhoneStore
    let demo: DemoMode

    var body: some View {
        RootView()
            .environment(live)
            .environment(demo)
            .fullScreenCover(item: Binding(get: { demo.session }, set: { if $0 == nil { demo.end() } })) { session in
                DemoRootView(session: session)
                    .environment(demo)
            }
    }
}

/// The app on the demo's store, under the Demo banner.
private struct DemoRootView: View {
    let session: DemoEnvironment
    @Environment(DemoMode.self) private var demo

    var body: some View {
        RootView()
            .environment(session.store)
            .safeAreaInset(edge: .top, spacing: 0) {
                DemoBanner { demo.end() }
            }
    }
}

struct RootView: View {
    @Environment(PhoneStore.self) private var store

    var body: some View {
        Group {
            if store.hasCompletedOnboarding {
                MainTabView()
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(.default, value: store.hasCompletedOnboarding)
    }
}

struct MainTabView: View {
    @Environment(PhoneStore.self) private var store

    var body: some View {
        @Bindable var store = store
        TabView(selection: $store.selectedTab) {
            Tab(store.macs.count > 1 ? "Macs" : "Mac", systemImage: "laptopcomputer", value: MainTab.macs) {
                MacsTab()
            }
            Tab("Activity", systemImage: "bell", value: MainTab.activity) {
                ActivityView()
            }
            Tab("Settings", systemImage: "gear", value: MainTab.settings) {
                SettingsView()
            }
        }
    }
}

#if DEBUG
#Preview("One Mac") {
    PreviewHost(.oneMac) { RootView() }
}

#Preview("First run") {
    PreviewHost(.firstRun) { RootView() }
}
#endif
