// Onboarding's last step, "Your Mac" (Views/OnboardingView.swift): which screen to show. Pure, so every path is
// tested (Tests/MacSetupTests.swift).
//
// The iPhone can't see whether the Mac app is installed until that Mac shares its status through iCloud, so it asks:
//   no Mac yet, no answer   → "Is Kakureneko on your Mac?"
//   "Yes, it's on my Mac"   → what to do on the Mac, then waiting (a checklist appears after `helpDelay`)
//   "Not yet"               → how to get the Mac app (send or copy the link), still waiting underneath
//   a Mac appears           → "Connected to <Mac>", from any of them, and right away when one is already known.

import KakurenekoCloud
import Foundation

/// What the user said about the Mac app.
enum MacSetupAnswer: Hashable, Sendable {
    case onMac
    case notYet
}

/// The screen of the "Your Mac" step.
enum MacSetupScreen: Hashable, Sendable {
    case question
    case getMacApp
    case waiting
    case connected(macName: String, macID: String)

    static func of(answer: MacSetupAnswer?, macs: [MacStatus]) -> MacSetupScreen {
        if let mac = macs.first { return .connected(macName: mac.macName, macID: mac.macID) }
        switch answer {
        case nil: return .question
        case .notYet: return .getMacApp
        case .onMac: return .waiting
        }
    }

    /// How long the waiting screens wait before they show what to check.
    static let helpDelay: Duration = .seconds(45)
}

/// The words the iPhone uses for what happens on the Mac. They quote the Mac app's own labels, so the two match
/// (Sources/KakurenekoApp: onboarding "Set up my iPhone", Settings → Notifications "Send alerts to your iPhone").
enum MacSetupText {
    static let macButton = "Set up my iPhone"
    static let macSetting = "Settings → Notifications → Send alerts to your iPhone"

    /// "github.com/y0ung-T/kakureneko" for the Mac download link (host and path, no scheme or trailing slash).
    static func display(_ url: URL) -> String {
        var text = (url.host() ?? url.absoluteString) + url.path()
        while text.hasSuffix("/") { text.removeLast() }
        return text.hasPrefix("www.") ? String(text.dropFirst(4)) : text
    }
}
