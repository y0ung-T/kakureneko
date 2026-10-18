// "Move Kakureneko to Applications?" at launch (docs/RELEASE.md). Opened straight from the downloaded disk image or
// from Downloads, macOS runs the app from a read-only, randomised copy (App Translocation) or from a volume that goes
// away: the login item and the integrations would point at a path that disappears. Kakureneko offers to move itself
// once, before anything else starts, and relaunches from the Applications folder.

import AppKit
import KakurenekoKit
import Foundation

/// Where a bundle runs from, when that is a problem.
nonisolated enum InstallLocationProblem: Sendable, Hashable {
    /// A mounted disk image (`/Volumes/…`).
    case diskImage
    /// App Translocation (quarantined app opened where it was downloaded).
    case translocated
    /// `~/Downloads`.
    case downloads

    /// The problem with running from `bundlePath`, or nil (Applications folders, a development build).
    static func of(bundlePath: String, home: String) -> InstallLocationProblem? {
        let path = (bundlePath as NSString).standardizingPath
        if path.contains("/AppTranslocation/") { return .translocated }
        if path.hasPrefix("/Volumes/") { return .diskImage }
        let downloads = ((home as NSString).appendingPathComponent("Downloads") as NSString).standardizingPath + "/"
        if path.hasPrefix(downloads) { return .downloads }
        return nil
    }
}

/// Offers the move and performs it (AppKit alert, file operations, relaunch). Main actor; used once at launch.
enum ApplicationsFolderMover {
    /// Shows the offer when the app runs from a problem location. Returns true when the app is relaunching from the
    /// new location (the caller stops launching and quits).
    static func offerIfNeeded(bundle: URL = Bundle.main.bundleURL, logger: KakurenekoLogger) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard bundle.pathExtension == "app",
              InstallLocationProblem.of(bundlePath: bundle.path, home: home) != nil else { return false }
        NSApplication.shared.activate()
        let alert = NSAlert()
        alert.messageText = "Move Kakureneko to the Applications folder?"
        alert.informativeText = "Kakureneko keeps running in the menu bar and opens at login, so it needs to live in "
            + "Applications. It moves itself there and opens again."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            let destination = try move(bundle, logger: logger)
            relaunch(destination)
            return true
        } catch {
            logger.warning("moving to Applications failed: \(error.localizedDescription)")
            let failure = NSAlert()
            failure.messageText = "Kakureneko couldn't move itself"
            failure.informativeText = "Drag Kakureneko into the Applications folder in Finder, then open it from there."
                + " (\(error.localizedDescription))"
            failure.runModal()
            return false
        }
    }

    /// Copies (from a disk image) or moves (from Downloads) the bundle into /Applications, or ~/Applications when
    /// /Applications isn't writable. An older copy there goes to the Trash first.
    private static func move(_ bundle: URL, logger: KakurenekoLogger) throws -> URL {
        let fm = FileManager.default
        let source = originalLocation(of: bundle) ?? bundle
        let folder: URL
        if fm.isWritableFile(atPath: "/Applications") {
            folder = URL(filePath: "/Applications", directoryHint: .isDirectory)
        } else {
            folder = fm.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let destination = folder.appending(path: source.lastPathComponent, directoryHint: .isDirectory)
        if fm.fileExists(atPath: destination.path) {
            try fm.trashItem(at: destination, resultingItemURL: nil)
        }
        if source.path.hasPrefix("/Volumes/") {
            try fm.copyItem(at: source, to: destination)
        } else {
            try fm.moveItem(at: source, to: destination)
        }
        // The user already opened this download once: don't ask Gatekeeper's "downloaded from the internet" again.
        let xattr = Process()
        xattr.executableURL = URL(filePath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", destination.path]
        try? xattr.run()
        xattr.waitUntilExit()
        logger.notice("moved to \(destination.path)")
        return destination
    }

    /// The real location of a translocated bundle (Security's `SecTranslocateCreateOriginalPathForURL`), else nil.
    private static func originalLocation(of bundle: URL) -> URL? {
        guard bundle.path.contains("/AppTranslocation/"),
              let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let function = unsafeBitCast(symbol, to: OriginalPath.self)
        return function(bundle as CFURL, nil)?.takeRetainedValue() as URL?
    }

    /// Opens the moved app once this process has exited, then quits (nothing was started yet).
    private static func relaunch(_ destination: URL) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
                             "sh", String(ProcessInfo.processInfo.processIdentifier), destination.path]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }
}
