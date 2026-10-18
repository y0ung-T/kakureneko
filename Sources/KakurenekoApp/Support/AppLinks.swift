// The links the app opens or shows. The website and the iPhone app's App Store page come from Info.plist
// (`KakurenekoWebsiteURL`, `KakurenekoIPhoneAppURL`), which scripts/build-app.sh fills from scripts/release.env, so a
// domain or an App Store id changes in one place. Development builds without them show no links.

import KakurenekoKit
import Foundation

/// Links derived from an Info.plist dictionary (testable without a bundle).
nonisolated struct ReleaseLinks: Sendable, Equatable {
    /// The website root (download, privacy, support), or nil when this build has none.
    var website: URL?
    /// The Kakureneko iPhone app's App Store (or public TestFlight) page; nil until it is published.
    var iPhoneAppStore: URL?

    init(info: [String: Any]) {
        website = Self.httpsURL(info["KakurenekoWebsiteURL"], directory: true)
        iPhoneAppStore = Self.httpsURL(info["KakurenekoIPhoneAppURL"], directory: false)
    }

    /// The page the onboarding's QR code and "Get the iPhone app" open: the App Store page, else the website's.
    var iPhoneApp: URL? { iPhoneAppStore ?? page("iphone/") }
    var privacyPolicy: URL? { page("privacy/") }
    var support: URL? { page("support/") }

    private func page(_ path: String) -> URL? {
        website.flatMap { URL(string: path, relativeTo: $0)?.absoluteURL }
    }

    /// An https URL with a host; `directory` adds the trailing slash relative pages resolve against.
    private static func httpsURL(_ value: Any?, directory: Bool) -> URL? {
        guard var text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if directory && !text.hasSuffix("/") { text += "/" }
        guard let url = URL(string: text), url.scheme == "https", url.host() != nil else { return nil }
        return url
    }
}

/// Links the app shows or opens.
nonisolated enum AppLinks {
    static let release = ReleaseLinks(info: Bundle.main.infoDictionary ?? [:])

    /// The Kakureneko iPhone app's page. nil in a build without links: onboarding then explains that the iPhone app is
    /// coming instead of showing a QR code.
    static var iPhoneApp: URL? { release.iPhoneApp }

    /// System Settings → Notifications → Kakureneko.
    static let notificationSettings = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(KakurenekoID.bundleIdentifier)")!

    /// "1.0.0 (202610181200)" from Info.plist.
    static var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
