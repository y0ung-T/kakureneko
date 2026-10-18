// One Kakureneko at a time. Two copies of the app (the installed one and one opened from a build folder or the disk
// image, which share the bundle id) would both arm and disarm sleep, pause apps and write iCloud: when one quits, it
// turns sleep back on under the other. At launch, before anything starts, the copies settle it: the one in an
// Applications folder wins; a stray copy is asked to quit (SIGTERM, which the app handles: thaw, disarm, flush).

import AppKit
import Darwin
import KakurenekoKit
import Foundation

/// Another running copy: its pid and bundle path.
nonisolated struct RunningCopy: Sendable, Hashable {
    var pid: pid_t
    var bundlePath: String
}

/// What a launching copy does about the others.
nonisolated enum SingleInstanceDecision: Sendable, Hashable {
    /// Nobody else runs: carry on.
    case carryOn
    /// This is the installed copy and only strays run: they quit, then this one starts.
    case replace([pid_t])
    /// A copy is already running and this one is no better: show that one and quit.
    case quitAndActivate(pid_t)

    static func decide(selfPath: String, others: [RunningCopy], home: String) -> SingleInstanceDecision {
        guard !others.isEmpty else { return .carryOn }
        if isInstalled(selfPath, home: home), others.allSatisfy({ !isInstalled($0.bundlePath, home: home) }) {
            return .replace(others.map(\.pid))
        }
        // Prefer showing an installed copy over a stray one.
        let target = others.first { isInstalled($0.bundlePath, home: home) } ?? others[0]
        return .quitAndActivate(target.pid)
    }

    /// In /Applications or ~/Applications.
    static func isInstalled(_ bundlePath: String, home: String) -> Bool {
        let path = (bundlePath as NSString).standardizingPath
        return path.hasPrefix("/Applications/") || path.hasPrefix((home as NSString).appendingPathComponent("Applications") + "/")
    }
}

/// Applies the decision at launch (main thread, before the coordinator exists). True = this copy is quitting.
enum SingleInstance {
    static func settle(bundle: URL, logger: KakurenekoLogger) -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).compactMap { app -> RunningCopy? in
            guard app.processIdentifier != me, let url = app.bundleURL, url.pathExtension == "app" else { return nil }
            return RunningCopy(pid: app.processIdentifier, bundlePath: url.path)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch SingleInstanceDecision.decide(selfPath: bundle.path, others: others, home: home) {
        case .carryOn:
            return false
        case .replace(let pids):
            logger.notice("another copy is running outside Applications (\(pids)); asking it to quit")
            for pid in pids { kill(pid, SIGTERM) }
            // Wait for them to thaw and disarm before this copy arms (up to 15 s, like scripts/install.sh).
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            return false
        case .quitAndActivate(let pid):
            logger.notice("Kakureneko is already running (pid \(pid)); showing it and quitting this copy")
            NSRunningApplication(processIdentifier: pid)?.activate()
            NSApplication.shared.terminate(nil)
            return true
        }
    }
}
