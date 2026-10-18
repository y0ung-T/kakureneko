import AppKit
import Darwin
import Foundation

/// One running application as seen by `NSWorkspace` (a Sendable snapshot; `NSRunningApplication` is not).
struct AppCandidate: Sendable, Hashable {
    var pid: pid_t
    var bundleID: String?
    var localizedName: String?
    /// `NSRunningApplication.bundleURL` path (journaled for Quit-mode relaunch).
    var bundlePath: String?
    /// `activationPolicy == .regular` — the only kind of app that is ever a candidate (R06 rule J).
    var isRegular: Bool
    var isFinishedLaunching: Bool

    init(pid: pid_t, bundleID: String? = nil, localizedName: String? = nil, bundlePath: String? = nil,
         isRegular: Bool = true, isFinishedLaunching: Bool = true) {
        self.pid = pid
        self.bundleID = bundleID
        self.localizedName = localizedName
        self.bundlePath = bundlePath
        self.isRegular = isRegular
        self.isFinishedLaunching = isFinishedLaunching
    }

    /// Menu/phone name: localized name, else the last bundle-id component, else the bundle file name.
    var displayName: String {
        if let localizedName, !localizedName.isEmpty { return localizedName }
        if let bundleID, let last = bundleID.split(separator: ".").last { return String(last) }
        if let bundlePath { return ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension }
        return "pid \(pid)"
    }
}

/// Source of running applications. Tests inject a synthetic list so no real app is ever inspected or touched.
protocol CandidateProviding: Sendable {
    func runningApplications() -> [AppCandidate]
    /// Bundle ids of the apps that can open `https` URLs (the browser-engine heuristic of the R06 §5.4 category
    /// table). Read only for Freeze.
    func webBrowserBundleIdentifiers() -> Set<String>
}

extension CandidateProviding {
    func webBrowserBundleIdentifiers() -> Set<String> { [] }
}

/// `NSWorkspace.shared.runningApplications` (thread-safe; properties are read atomically).
struct WorkspaceCandidateProvider: CandidateProviding {
    init() {}

    func webBrowserBundleIdentifiers() -> Set<String> {
        guard let probe = URL(string: "https://example.com") else { return [] }
        return Set(NSWorkspace.shared.urlsForApplications(toOpen: probe).compactMap { Bundle(url: $0)?.bundleIdentifier })
    }

    func runningApplications() -> [AppCandidate] {
        NSWorkspace.shared.runningApplications.map { app in
            AppCandidate(
                pid: app.processIdentifier,
                bundleID: app.bundleIdentifier,
                localizedName: app.localizedName,
                bundlePath: app.bundleURL?.path(percentEncoded: false),
                isRegular: app.activationPolicy == .regular,
                isFinishedLaunching: app.isFinishedLaunching
            )
        }
    }
}
