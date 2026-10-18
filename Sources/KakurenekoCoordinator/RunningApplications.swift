// Read-only probe for conflicting apps (App Tamer resumes processes others stopped, brief §6.5 item 6).

import AppKit
import Foundation

enum RunningApplications {
    /// True when an app with `bundleIdentifier` is running for this user. Read-only; never touches the app.
    static func isRunning(_ bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}
