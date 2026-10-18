import Darwin
import KakurenekoKit
import Foundation

/// File access used by the installers and `IntegrationManager`. Injectable so tests can simulate a write that
/// lands corrupted (the re-parse check must then roll back) without touching anything outside a temp home.
protocol InstallFileSystem: Sendable {
    /// File contents, following symlinks; `nil` when the file does not exist.
    func read(_ url: URL) throws -> Data?
    /// Atomic replace (temp file + fsync + rename), following symlinks to their target (also a dangling link's)
    /// and keeping the existing mode (`permissions == nil`). Missing parent directories are created with mode 0700.
    func write(_ data: Data, to url: URL, permissions: mode_t?) throws
    /// Atomic replace of `url` ITSELF (a symlink at `url` is replaced, not followed). Used for the hook helper.
    func replaceItem(_ data: Data, at url: URL, permissions: mode_t) throws
    /// Deletes a file; when `url` is a symlink, its final target is deleted and the link is kept. No error when it
    /// is missing.
    func remove(_ url: URL) throws
    /// Deletes a directory tree; no error when it is missing. A symlink is unlinked, never followed.
    func removeTree(_ url: URL) throws
    /// True for an existing file or directory (symlinks followed).
    func exists(_ url: URL) -> Bool
    /// True for an existing directory (symlinks followed).
    func directoryExists(_ url: URL) -> Bool
    /// True for an existing regular file (symlinks followed) with an execute bit for this user.
    func isExecutableFile(_ url: URL) -> Bool
    /// True when `url` itself is a symbolic link.
    func isSymbolicLink(_ url: URL) -> Bool
    /// Direct children of a directory (empty when it does not exist).
    func contentsOfDirectory(_ url: URL) -> [URL]
}

/// The real file system (Kit `AtomicFile` + POSIX/`FileManager`).
struct LiveInstallFileSystem: InstallFileSystem {
    init() {}

    func read(_ url: URL) throws -> Data? {
        try AtomicFile.readIfExists(url)
    }

    func write(_ data: Data, to url: URL, permissions: mode_t?) throws {
        // Kit's `AtomicFile` follows the whole link chain (also a dangling link's: the target is created and the
        // user's link kept), brief §3.7.2.
        try AtomicFile.write(data, to: url, permissions: permissions, followSymlinks: true, createDirectories: true)
    }

    func replaceItem(_ data: Data, at url: URL, permissions: mode_t) throws {
        try AtomicFile.write(data, to: url, permissions: permissions, followSymlinks: false, createDirectories: true)
    }

    func remove(_ url: URL) throws {
        // A file reached through a link is deleted at its target; the user's link stays (as before the install).
        let path = Self.finalTarget(url).linkSafePath
        if unlink(path) != 0, errno != ENOENT {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path, NSUnderlyingErrorKey: POSIXError(code)])
        }
    }

    /// The file a write or delete of `url` acts on: the end of its symlink chain (also the target of a dangling
    /// link), or `url` itself when it is not a link — `AtomicFile.finalTarget(of:)`, the same resolution writes use.
    /// A loop (more than `AtomicFile.maxSymlinkHops` links) resolves to `url` itself (unlinking it removes the link).
    static func finalTarget(_ url: URL) -> URL {
        (try? AtomicFile.finalTarget(of: url)) ?? url
    }

    func removeTree(_ url: URL) throws {
        if isSymbolicLink(url) {
            // Never follow a link out of Kakureneko's own folder: drop the link itself.
            let path = url.linkSafePath
            if unlink(path) != 0, errno != ENOENT {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path, NSUnderlyingErrorKey: POSIXError(code)])
            }
            return
        }
        let path = url.linkSafePath
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.removeItem(atPath: path)
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func isExecutableFile(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    func isSymbolicLink(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.linkSafePath, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    func contentsOfDirectory(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])) ?? []
    }
}

extension InstallFileSystem {
    /// UTF-8 text of a file, `nil` when missing. Throws when the bytes are not UTF-8 (never rewrite such a file).
    func readText(_ url: URL) throws -> String? {
        guard let data = try read(url) else { return nil }
        return try InstallText.decode(data, path: url.path(percentEncoded: false))
    }
}

/// Byte-exact text conversion for agent config files.
enum InstallText {
    /// Decodes UTF-8 without dropping a byte-order mark (Foundation's `String(data:encoding:)` may strip it,
    /// which would make "uninstall restores byte for byte" impossible).
    static func decode(_ data: Data, path: String) throws -> String {
        guard let text = String(validating: data, as: UTF8.self) else { throw InstallError.notUTF8(path: path) }
        return text
    }

    static func encode(_ text: String) -> Data { Data(text.utf8) }
}

extension URL {
    /// The file-system path without a trailing slash. A directory URL's path ends in `/`, and POSIX resolves a
    /// symlink named with a trailing slash to its target (`lstat("link/")` describes the target, `removeItem`
    /// would empty the target), so every link-sensitive call uses this form.
    var linkSafePath: String {
        let path = self.path(percentEncoded: false)
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}
