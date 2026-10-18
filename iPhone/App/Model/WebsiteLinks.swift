// The website pages the app links to (privacy policy, support, the Mac app's download), derived from one address:
// the Info.plist's `KakurenekoWebsiteURL`, which the `KAKURENEKO_WEBSITE_URL` build setting fills (Xcode/project.yml;
// scripts/build-phone.sh passes `WEBSITE_URL` from scripts/release.env). A missing or malformed value falls back to
// https://kakureneko.com/, so a link never points nowhere. `AppLinks` (Views/Components.swift) reads it from the bundle.

import Foundation

struct WebsiteLinks: Sendable, Hashable {
    static let infoKey = "KakurenekoWebsiteURL"
    /// The product's website (also the default of `KAKURENEKO_WEBSITE_URL`).
    static let fallback = URL(string: "https://kakureneko.com/")!

    /// The home page, always with a trailing slash. The Mac app is downloaded from here.
    let home: URL

    /// `infoValue`: the Info.plist value (a string like "https://example.com" or "https://example.com/kakureneko/").
    init(infoValue: Any?) {
        home = Self.homePage(from: infoValue as? String) ?? Self.fallback
    }

    /// <home>privacy/
    var privacyPolicy: URL { home.appending(path: "privacy/") }
    /// <home>support/
    var support: URL { home.appending(path: "support/") }

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
