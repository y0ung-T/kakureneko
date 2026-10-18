// "Uninstall Kakureneko…" (Settings → General): everything the app added to the Mac, in an order that never leaves
// an agent pointing at a missing hook. The admin pieces first (one prompt; cancelling stops here, nothing else is
// touched), then every agent integration, then the login item; only then the local files go, after the app has quit
// (the coordinator writes its state while it terminates), and the app moves to the Trash.
//
// iCloud: the first step turns "Send alerts to your iPhone" off, which deletes this Mac's status and the alerts it
// saved (NotificationDispatcher.removeCloudData). Records the iPhone created (its device record) go when the Mac
// removes them (Settings → Notifications → Remove) or after 30 days without an update (the prune).

import AppKit
import KakurenekoKit
import Foundation

/// What an uninstall removes on this Mac, from the latest snapshot (shown in the confirmation, then performed).
nonisolated struct UninstallPlan: Sendable, Equatable {
    /// The sudoers rule and the fail-safe daemon (an admin prompt).
    var removesClosedLidMode: Bool
    /// Agents whose hook is installed (or half-installed).
    var integrations: [AgentID]
    var removesLoginItem: Bool

    static func make(snapshot: AppSnapshot, loginItem: LoginItemStatus) -> UninstallPlan {
        UninstallPlan(
            removesClosedLidMode: snapshot.privileged.sudoRuleInstalled || snapshot.privileged.failsafeLoaded,
            integrations: snapshot.integrations.filter { $0.installed || $0.needsRepair }.map(\.agent),
            removesLoginItem: loginItem == .enabled || loginItem == .requiresApproval || snapshot.settings.general.launchAtLogin)
    }

    /// The confirmation's list, one line per step.
    var lines: [String] {
        var lines: [String] = []
        if removesClosedLidMode { lines.append("Closed-lid mode: the sleep rule and the fail-safe (asks for your password)") }
        if !integrations.isEmpty {
            lines.append("Hooks in \(integrations.map(\.displayName).joined(separator: ", "))")
        }
        if removesLoginItem { lines.append("Opening at login") }
        lines.append("This Mac's status and alerts in iCloud")
        lines.append("Settings, logs and config backups (~/.kakureneko and Application Support)")
        lines.append("The app itself (moved to the Trash)")
        return lines
    }
}

/// The last step, after everything reversible went: schedule the file removal for after exit, trash the app, quit.
protocol UninstallFinishing: AnyObject {
    /// `emergencyStop`: the synchronous thaw + disarm, run before exiting when the normal quit never happens.
    func finish(emergencyStop: @escaping () -> Void)
}

/// The real last step. Only removes Kakureneko's own folders under the user's home.
final class LiveUninstallFinisher: UninstallFinishing {
    private let paths: Paths
    private let bundle: URL
    private let logger: KakurenekoLogger

    init(paths: Paths = .live(), bundle: URL = Bundle.main.bundleURL, logger: KakurenekoLogger) {
        self.paths = paths
        self.bundle = bundle
        self.logger = logger
    }

    /// Kakureneko's own folders: ~/.kakureneko, Application Support, and what macOS keeps for the bundle id.
    nonisolated static func folders(in paths: Paths) -> [URL] {
        let library = paths.home.appending(path: "Library", directoryHint: .isDirectory)
        let id = KakurenekoID.bundleIdentifier
        return [
            paths.kakurenekoDirectory,
            paths.appSupport,
            library.appending(path: "Caches/\(id)", directoryHint: .isDirectory),
            library.appending(path: "HTTPStorages/\(id)", directoryHint: .isDirectory),
            library.appending(path: "Saved Application State/\(id).savedState", directoryHint: .isDirectory),
        ].filter { $0.path.hasPrefix(paths.home.path + "/") }
    }

    func finish(emergencyStop: @escaping () -> Void) {
        let folders = Self.folders(in: paths).map(\.path)
        let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.3; done
            shift
            rm -rf -- "$@"
            /usr/bin/defaults delete \(KakurenekoID.bundleIdentifier) >/dev/null 2>&1 || true
            """
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier)] + folders
        do {
            try process.run()
        } catch {
            logger.warning("uninstall: could not schedule the file removal: \(error.localizedDescription)")
        }
        if bundle.pathExtension == "app" {
            do {
                try FileManager.default.trashItem(at: bundle, resultingItemURL: nil)
            } catch {
                logger.warning("uninstall: could not move the app to the Trash: \(error.localizedDescription)")
            }
        }
        logger.notice("uninstalled; quitting")
        // On the next turn of the run loop, after the confirmation sheet has closed: AppKit drops a terminate that
        // arrives while it is still closing, and the app would sit in the Trash with its files waiting.
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        // Belt and braces: still running after 10 s (the normal quit takes about 2), quit anyway, after the same
        // synchronous thaw + disarm a SIGTERM runs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [logger] in
            logger.warning("uninstall: the normal quit did not happen; exiting")
            emergencyStop()
            exit(0)
        }
    }
}

/// Counts the last step instead of performing it (tests, previews).
final class RecordingUninstallFinisher: UninstallFinishing {
    private(set) var finished = 0
    func finish(emergencyStop: @escaping () -> Void) { finished += 1 }
}
