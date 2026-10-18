// Debug-only ways onto the demo (Model/Demo.swift): SwiftUI previews (`PreviewHost`), and launch arguments that run
// the whole app on a scenario in the Simulator (screenshots, design reviews):
//   -KakurenekoDemo oneMac|working|waiting|countdown|…   the scenario (DemoFixtures.Scenario)
//   -KakurenekoDemoTab activity|settings                 the tab to open
//   -KakurenekoDemoStep waitingForMac                    the onboarding step (with `firstRun` / `firstRunWithMac`)
//   -KakurenekoDemoMacAnswer onMac|notYet                "Your Mac": the answer already given (Model/MacSetup.swift)
//   -KakurenekoDemoCover YES                             also open the in-app demo over it (banner and all)
//   -KakurenekoDemoClock 9:41                            write the app's clock times as if it were 9:41 at launch
//                                                      (screenshots beside a 9:41 status bar; see `showClock`)
// No iCloud, no pushes. Release builds reach the demo only through the app's own "See a demo" buttons (DemoMode).

#if DEBUG
import KakurenekoCloud
import Foundation
import SwiftUI

extension DemoEnvironment {
    /// The demo environment named by the `KakurenekoDemo` launch argument, if any.
    static func fromLaunchArguments(_ defaults: UserDefaults = .standard) -> DemoEnvironment? {
        guard let name = defaults.string(forKey: "KakurenekoDemo"), let scenario = DemoFixtures.Scenario(rawValue: name) else { return nil }
        // Before the fixtures: some of their texts carry clock times ("Studio slept 6:46 AM–1:46 PM").
        if let clock = defaults.string(forKey: "KakurenekoDemoClock") { showClock(clock) }
        let environment = DemoEnvironment(scenario)
        switch defaults.string(forKey: "KakurenekoDemoTab") {
        case "activity": environment.store.selectedTab = .activity
        case "settings": environment.store.selectedTab = .settings
        default: break
        }
        return environment
    }

    /// `-KakurenekoDemoClock 9:41`: makes the app's time zone the offset from UTC at which this moment reads `hh:mm`,
    /// so every time the app writes (agents' "since", alert times, Today / Yesterday) sits plausibly beside the
    /// Simulator's 9:41 status bar override. The data stays relative to the real clock: only how times are written
    /// changes. Debug launches only, never the demo of Release builds. `TZ` too, because `NSTimeZone.default` alone
    /// moves `Calendar.current` but not `TimeZone.current`, which the date formats use.
    static func showClock(_ text: String, at now: Date = Date()) {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let real = utc.dateComponents([.hour, .minute], from: now)
        var offset = (parts[0] - (real.hour ?? 0)) * 3600 + (parts[1] - (real.minute ?? 0)) * 60
        if offset > 12 * 3600 { offset -= 86400 } else if offset < -12 * 3600 { offset += 86400 }
        guard let zone = TimeZone(secondsFromGMT: offset) else { return }
        setenv("TZ", zone.identifier, 1)
        NSTimeZone.resetSystemTimeZone()
        NSTimeZone.default = zone
    }
}

/// Wraps a preview in a `DemoEnvironment` for `scenario`.
struct PreviewHost<Content: View>: View {
    @State private var environment: DemoEnvironment
    private let content: Content

    init(_ scenario: DemoFixtures.Scenario, @ViewBuilder content: () -> Content) {
        _environment = State(initialValue: DemoEnvironment(scenario))
        self.content = content()
    }

    var body: some View {
        content
            .environment(environment.store)
            .task { await environment.run() }
    }
}
#endif
