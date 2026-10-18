import Darwin
import Foundation

/// Crash-safe file replacement: write `<dir>/.<name>.tmp-<pid>-<rand>`, `fsync` (or `F_FULLFSYNC`),
/// then `rename(2)` over the destination. Used for settings, outbox, secrets, the pause journal
/// (with `fullSync: true`), the install manifest and installer config edits.
public enum AtomicFile {
    public enum Failure: Error, Sendable, Equatable {
        case open(path: String, errno: Int32)
        case write(path: String, errno: Int32)
        case sync(path: String, errno: Int32)
        case rename(from: String, to: String, errno: Int32)
    }

    /// Symlink hops `write(followSymlinks: true)` follows before giving up with `ELOOP`.
    public static let maxSymlinkHops = 32

    /// Atomically replaces `url` with `data`.
    /// - Parameters:
    ///   - permissions: file mode; `nil` keeps the existing file's mode (or 0644 for a new file).
    ///   - fullSync: use `fcntl(F_FULLFSYNC)` (pause journal); otherwise `fsync`.
    ///   - followSymlinks: when `url` is a symlink, replace the FINAL target of its link chain (installer rule
    ///     brief §3.7.2) and keep every link; a dangling chain's missing target is created (with
    ///     `createDirectories`, its parent too). Relative link targets resolve against the link's own directory.
    ///     A chain longer than `maxSymlinkHops` (a loop) throws `Failure.open(…, ELOOP)`. When false, a link at
    ///     `url` is replaced by a regular file.
    ///   - createDirectories: create missing parent directories with mode 0700.
    public static func write(
        _ data: Data,
        to url: URL,
        permissions: mode_t? = nil,
        fullSync: Bool = false,
        followSymlinks: Bool = true,
        createDirectories: Bool = true
    ) throws {
        var destination = url
        if followSymlinks {
            destination = try finalTarget(of: url)
        }
        let directory = destination.deletingLastPathComponent()
        if createDirectories {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let destPath = destination.path(percentEncoded: false)
        var mode: mode_t = permissions ?? 0o644
        if permissions == nil {
            var st = stat()
            if stat(destPath, &st) == 0 { mode = st.st_mode & 0o7777 }
        }
        let tmpName = ".\(destination.lastPathComponent).tmp-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let tmpPath = directory.appending(path: tmpName, directoryHint: .notDirectory).path(percentEncoded: false)
        let fd = open(tmpPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard fd >= 0 else { throw Failure.open(path: tmpPath, errno: errno) }
        var ok = false
        defer {
            if !ok { unlink(tmpPath) }
        }
        _ = fchmod(fd, mode) // umask may have masked bits off
        let writeError: Int32? = data.withUnsafeBytes { raw -> Int32? in
            guard var base = raw.baseAddress else { return nil }
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.write(fd, base, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                remaining -= n
                base = base.advanced(by: n)
            }
            return nil
        }
        if let writeError {
            close(fd)
            throw Failure.write(path: tmpPath, errno: writeError)
        }
        let syncResult = fullSync ? fcntl(fd, F_FULLFSYNC) : fsync(fd)
        if syncResult != 0 {
            let e = errno
            // F_FULLFSYNC is unsupported on some file systems (e.g. tmpfs); fall back to fsync.
            if !(fullSync && fsync(fd) == 0) {
                close(fd)
                throw Failure.sync(path: tmpPath, errno: e)
            }
        }
        close(fd)
        guard rename(tmpPath, destPath) == 0 else {
            throw Failure.rename(from: tmpPath, to: destPath, errno: errno)
        }
        ok = true
    }

    /// The end of `url`'s symlink chain: `url` itself when it is not a symlink (or does not exist), else the target
    /// of the last link — also when that target does not exist (a dangling link). Only the LAST path component is
    /// followed hop by hop (`readlink(2)`); directory symlinks earlier in the path are left to the kernel.
    /// Throws `Failure.open(path:errno: ELOOP)` after `maxSymlinkHops` links.
    public static func finalTarget(of url: URL) throws -> URL {
        var current = URL(filePath: linkSafePath(url), directoryHint: .notDirectory)
        for _ in 0..<maxSymlinkHops {
            let path = current.path(percentEncoded: false)
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK else { return current }
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = readlink(path, &buffer, buffer.count - 1)
            guard length > 0 else { throw Failure.open(path: path, errno: length == 0 ? ENOENT : errno) }
            let target = String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let next = target.hasPrefix("/")
                ? URL(filePath: target, directoryHint: .notDirectory)
                : current.deletingLastPathComponent().appending(path: target, directoryHint: .notDirectory)
            // No lexical `..` folding: the kernel resolves `..` after directory symlinks, and so must we.
            current = URL(filePath: linkSafePath(next), directoryHint: .notDirectory)
        }
        throw Failure.open(path: url.path(percentEncoded: false), errno: ELOOP)
    }

    /// The path without a trailing slash (`lstat("link/")` would describe the link's target, not the link).
    private static func linkSafePath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    /// Reads a file, returning `nil` if it does not exist.
    public static func readIfExists(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return nil
        }
    }
}
