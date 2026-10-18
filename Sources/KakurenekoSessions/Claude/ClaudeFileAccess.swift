import Darwin
import Foundation

/// Size, mtime and type of one file (cache key for records and transcript tails).
struct FileStamp: Sendable, Hashable {
    var size: UInt64
    var modified: Date
    var isDirectory: Bool
    var isRegularFile: Bool
}

/// Read-only file access used by the Claude watcher. Injectable so tests can prove which files were opened
/// (never `*.key`) — production uses `PosixClaudeFileAccess`.
protocol ClaudeFileAccess: Sendable {
    /// Entry names of a directory; `nil` when it is missing or unreadable.
    func listDirectory(_ url: URL) -> [String]?
    /// `stat(2)` (follows symlinks); `nil` when missing.
    func stamp(_ url: URL) -> FileStamp?
    /// The whole file if it is a regular file of at most `maxBytes`; `nil` otherwise.
    func readFile(_ url: URL, maxBytes: Int) -> Data?
    /// The last ≤ `maxBytes` of a regular file and the offset they start at.
    func readTail(_ url: URL, maxBytes: Int) -> (data: Data, offset: UInt64)?
    func isExecutableFile(_ url: URL) -> Bool
}

/// POSIX implementation: `open(O_RDONLY | O_NONBLOCK | O_CLOEXEC)` + `fstat` (regular files only, so a FIFO or a
/// device can never block the reader) + `pread`. Never writes.
struct PosixClaudeFileAccess: ClaudeFileAccess {
    func listDirectory(_ url: URL) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))
    }

    func stamp(_ url: URL) -> FileStamp? {
        var st = stat()
        guard stat(url.path(percentEncoded: false), &st) == 0 else { return nil }
        return Self.stamp(from: st)
    }

    func readFile(_ url: URL, maxBytes: Int) -> Data? {
        withRegularFile(url) { fd, st in
            guard st.st_size >= 0, Int(st.st_size) <= maxBytes else { return nil }
            return Self.read(fd, offset: 0, count: Int(st.st_size))
        }
    }

    func readTail(_ url: URL, maxBytes: Int) -> (data: Data, offset: UInt64)? {
        withRegularFile(url) { fd, st in
            let size = UInt64(max(0, st.st_size))
            let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
            guard let data = Self.read(fd, offset: offset, count: Int(size - offset)) else { return nil }
            return (data, offset)
        }
    }

    func isExecutableFile(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        guard let stamp = stamp(url), stamp.isRegularFile else { return false }
        return access(path, X_OK) == 0
    }

    // MARK: - Helpers

    private func withRegularFile<T>(_ url: URL, _ body: (Int32, stat) -> T?) -> T? {
        let fd = open(url.path(percentEncoded: false), O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return body(fd, st)
    }

    private static func read(_ fd: Int32, offset: UInt64, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let n = buffer.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress! + filled, count - filled, off_t(offset) + off_t(filled))
            }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            filled += n
        }
        return Data(buffer.prefix(filled))
    }

    static func stamp(from st: stat) -> FileStamp {
        let type = st.st_mode & S_IFMT
        let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
            + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000)
        return FileStamp(size: UInt64(max(0, st.st_size)), modified: modified, isDirectory: type == S_IFDIR,
                         isRegularFile: type == S_IFREG)
    }
}
