import Foundation

/// Creates Kakureneko's own directories (never any agent's directory).
public enum DirectoryLayout {
    /// `~/.kakureneko/{bin,inbox,inbox/.tmp,inbox/bad,run,log,backups,recordings}`, the fallback inbox
    /// (`.tmp`, `bad`), app support and `app support/install` — all mode 0700. Idempotent.
    /// Called by the coordinator at launch (KakurenekoInstall.deployHelper also calls it).
    public static func ensureUserDirectories(_ paths: Paths) throws {
        let directories: [URL] = [
            paths.kakurenekoDirectory,
            paths.binDirectory,
            paths.inboxDirectory,
            paths.inboxTempDirectory,
            paths.inboxBadDirectory,
            paths.fallbackInboxDirectory,
            paths.fallbackInboxTempDirectory,
            paths.fallbackInboxBadDirectory,
            paths.runDirectory,
            paths.logDirectory,
            paths.backupsDirectory,
            paths.recordingsDirectory,
            paths.appSupport,
            paths.installScriptsDirectory,
        ]
        let fm = FileManager.default
        for directory in directories {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path(percentEncoded: false))
        }
    }
}
