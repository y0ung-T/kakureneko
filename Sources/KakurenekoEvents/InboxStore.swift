import Darwin
import KakurenekoKit
import Foundation

/// File-level operations on the two inbox directories (brief §4.3–4.4). Everything here is synchronous and runs on
/// `EventInbox`'s serial drain queue; nothing ever follows a symlink, blocks on a FIFO or reads an unbounded file
/// (any same-user process can drop entries into the inbox).
struct InboxStore: Sendable {
    /// An entry of one inbox directory.
    struct Entry: Equatable, Sendable {
        var name: String
        /// Index into `inboxes` (0 = primary). Breaks ties between equal names (primary first).
        var inboxIndex: Int
        var directory: URL

        var path: String { directory.appending(path: name, directoryHint: .notDirectory).path(percentEncoded: false) }
    }

    struct Listing: Equatable, Sendable {
        /// `*.event` files of BOTH inboxes, merged and sorted globally by file name (= chronological).
        var candidates: [Entry]
        /// Other non-hidden, non-directory entries (junk, symlinks, FIFOs): moved to `bad/`.
        var junk: [Entry]
    }

    enum ReadResult: Equatable {
        case data(Data)
        /// Gone between listing and opening (nothing to do).
        case vanished
        /// Not a regular file, too large, unreadable → quarantine.
        case unusable(String)
    }

    /// Primary first, then the per-user temp-dir fallback.
    let inboxes: [URL]
    /// Upper bound for one inbox file: header line + 4 MiB payload + slack.
    static let maxFileBytes = InboxFile.maxHeaderBytes + InboxFile.maxPayloadBytes + 4_096

    init(inboxes: [URL]) {
        self.inboxes = inboxes
    }

    init(paths: Paths) {
        self.init(inboxes: paths.allInboxDirectories)
    }

    // MARK: - Listing

    func list() -> Listing {
        var candidates: [Entry] = []
        var junk: [Entry] = []
        for (index, inbox) in inboxes.enumerated() {
            Self.forEachEntry(in: inbox) { name, type in
                guard !name.hasPrefix(".") else { return } // ".tmp", ".DS_Store", "." and ".."
                let entry = Entry(name: name, inboxIndex: index, directory: inbox)
                switch type {
                case UInt8(DT_DIR):
                    return // "bad" (and anything else a user put there) is never touched
                case UInt8(DT_REG), UInt8(DT_UNKNOWN):
                    if name.hasSuffix(".\(InboxFile.fileExtension)") { candidates.append(entry) } else { junk.append(entry) }
                default:
                    junk.append(entry) // symlinks, FIFOs, sockets, devices
                }
            }
        }
        candidates.sort { ($0.name, $0.inboxIndex) < ($1.name, $1.inboxIndex) }
        junk.sort { ($0.name, $0.inboxIndex) < ($1.name, $1.inboxIndex) }
        return Listing(candidates: candidates, junk: junk)
    }

    /// `readdir` with `d_type` (no per-entry `stat`). Missing directories yield nothing.
    static func forEachEntry(in directory: URL, _ body: (String, UInt8) -> Void) {
        guard let dir = opendir(directory.path(percentEncoded: false)) else { return }
        defer { closedir(dir) }
        while let entry = readdir(dir) {
            let length = Int(entry.pointee.d_namlen)
            let type = entry.pointee.d_type
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(min(length, raw.count)), as: UTF8.self)
            }
            body(name, type)
        }
    }

    // MARK: - Reading

    /// Reads one inbox file without following symlinks or blocking on special files; bounded by `maxBytes`.
    static func read(_ path: String, maxBytes: Int = maxFileBytes) -> ReadResult {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            return code == ENOENT ? .vanished : .unusable("open errno \(code)")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .unusable("fstat errno \(errno)") }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .unusable("not a regular file") }
        let size = Int(info.st_size)
        guard size <= maxBytes else { return .unusable("too large (\(size) bytes)") }
        var data = Data(count: size)
        var offset = 0
        let failure: String? = data.withUnsafeMutableBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            while offset < size {
                let n = Darwin.read(fd, base + offset, size - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return "read errno \(errno)"
                }
                if n == 0 { break } // truncated underneath us: parse what is there
                offset += n
            }
            return nil
        }
        if let failure { return .unusable(failure) }
        if offset < size { data.removeSubrange(offset..<size) }
        return .data(data)
    }

    // MARK: - Removal

    /// Deletes a processed file. True when it is gone.
    @discardableResult
    static func remove(_ entry: Entry) -> Bool {
        unlink(entry.path) == 0 || errno == ENOENT
    }

    /// Moves an unusable entry to `<inbox>/bad/` (renaming the entry itself, never a symlink target). Falls back to
    /// deleting it so a poisoned file can never be re-processed forever. True when it left the inbox.
    @discardableResult
    static func quarantine(_ entry: Entry) -> Bool {
        let bad = InboxDirectories.bad(of: entry.directory)
        try? FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = bad.appending(path: entry.name, directoryHint: .notDirectory).path(percentEncoded: false)
        if rename(entry.path, destination) == 0 || errno == ENOENT { return true }
        return remove(entry)
    }

    // MARK: - Garbage collection

    /// Deletes `bad/` and `.tmp/` entries (not directories) whose mtime is older than `maxAge` before `now`.
    /// `now` is the WALL clock: file times are kernel wall-clock times. Returns the number of entries removed.
    @discardableResult
    func collectGarbage(now: Date, maxAge: TimeInterval = InboxFile.garbageCollectionAge) -> Int {
        let cutoff = now.timeIntervalSince1970 - maxAge
        var removed = 0
        for inbox in inboxes {
            for directory in [InboxDirectories.temporary(of: inbox), InboxDirectories.bad(of: inbox)] {
                var names: [String] = []
                Self.forEachEntry(in: directory) { name, _ in
                    if name != "." && name != ".." { names.append(name) }
                }
                for name in names {
                    let path = directory.appending(path: name, directoryHint: .notDirectory).path(percentEncoded: false)
                    var info = stat()
                    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) != S_IFDIR else { continue }
                    let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
                    if modified < cutoff, unlink(path) == 0 { removed += 1 }
                }
            }
        }
        return removed
    }
}
