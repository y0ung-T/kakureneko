// The pages the app links to (privacy policy, support, the Mac app's download), derived from one address, the
// project's GitHub repository: the Info.plist's `KakurenekoWebsiteURL`, which the `KAKURENEKO_WEBSITE_URL` build setting
// fills (Xcode/project.yml; scripts/build-phone.sh passes `WEBSITE_URL` from scripts/release.env). A missing or
// malformed value falls back to https://github.com/y0ung-T/kakureneko/, so a link never points nowhere. `AppLinks` (Views/Components.swift) reads it from the bundle.

import Foundation

struct WebsiteLinks: Sendable, Hashable {
    static let infoKey = "KakurenekoWebsiteURL"
    /// The project's GitHub repository (also the default of `KAKURENEKO_WEBSITE_URL`).
    static let fallback = URL(string: "https://github.com/y0ung-T/kakureneko/")!

    /// The repository's page, always with a trailing slash. Its README links the Mac app's download.
    let home: URL

    /// `infoValue`: the Info.plist value (a string like "https://example.com" or "https://example.com/kakureneko/").
    init(infoValue: Any?) {
        home = Self.homePage(from: infoValue as? String) ?? Self.fallback
    }

    /// <home>blob/main/PRIVACY.md
    var privacyPolicy: URL { home.appending(path: "blob/main/PRIVACY.md") }
    /// <home>issues
    var support: URL { home.appending(path: "issues") }

    /// An http(s) address with a host and no query or fragment, given a trailing slash; nil otherwise (including an
    /// unexpanded "$(KAKURENEKO_WEBSITE_URL)").
    private static func homePage(from value: String?) -> URL? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if !text.hasSuffix("/") { text += "/" }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(), !host.isEmpty, url.query() == nil, url.fragment() == nil else { return nil }
        return url
    }
}
