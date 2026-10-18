import Darwin
import KakurenekoKit
import Foundation
import Synchronization

/// The in-memory mirror of `paused.json` plus its crash-safe persistence (brief §6.5 item 1, R06 §4.1).
///
/// Every mutation is written to disk (`AtomicFile`, 0600, `F_FULLFSYNC`) INSIDE the lock and BEFORE the caller
/// signals anything; when the write fails the in-memory journal is left unchanged and the caller must not act.
/// Apps without members are dropped; an empty journal removes the file (the guard treats "missing" as "empty").
final class JournalStore: Sendable {
    let url: URL
    private let state = Mutex<PauseJournal?>(nil)

    init(url: URL) { self.url = url }

    /// The current journal (nil = nothing journaled).
    var current: PauseJournal? { state.withLock { $0 } }

    /// Applies `body` to the journal (created from `header()` when absent) and persists the result. Under the
    /// journal file lock, and after dropping the records `kakureneko-guard` thawed meanwhile (missing on disk), so a
    /// guard rewrite and this append can never overwrite each other.
    @discardableResult
    func update(header: () -> PauseJournal, _ body: (inout PauseJournal) -> Void) throws -> PauseJournal? {
        try state.withLock { stored in
            try JournalFileLock.withLock(journal: url) {
                var journal = Self.reconciled(memory: stored, disk: PauseJournal.read(from: url)).journal ?? header()
                body(&journal)
                let normalized = Self.normalized(journal)
                try persist(normalized)
                stored = normalized
                return normalized
            }
        }
    }

    /// Replaces the journal (nil or empty removes the file).
    func replace(with journal: PauseJournal?) throws {
        try state.withLock { stored in
            try JournalFileLock.withLock(journal: url) {
                let normalized = journal.flatMap(Self.normalized)
                try persist(normalized)
                stored = normalized
            }
        }
    }

    /// `memory` without the members missing from a usable `disk` journal (thawed by the guard); `memory` as is when
    /// the file is missing or unusable.
    static func reconciled(memory: PauseJournal?, disk: PauseJournal?) -> (journal: PauseJournal?, dropped: Int) {
        guard let memory, let disk else { return (memory, 0) }
        var dropped = 0
        var apps: [PauseJournalApp] = []
        for app in memory.apps {
            let onDisk = Set(disk.apps.filter { $0.appPid == app.appPid }.flatMap(\.members))
            var kept = app
            kept.members = app.members.filter { onDisk.contains($0) }
            dropped += app.members.count - kept.members.count
            if !kept.members.isEmpty { apps.append(kept) }
        }
        guard dropped > 0 else { return (memory, 0) }
        var next = memory
        next.apps = apps
        return (normalized(next), dropped)
    }

    /// Reads the file (lossy). nil when missing or unusable.
    func readDisk() -> PauseJournal? { PauseJournal.read(from: url) }

    /// Re-reads the file because `kakureneko-guard` may have thawed records during a hang (and rewritten the journal
    /// without them; after thawing everything it writes an EMPTY journal rather than removing the file). Members
    /// missing on disk are treated as already thawed and dropped from memory. When the file is missing or unusable
    /// while memory still has records, the file is rewritten from memory (journal first: never lose track of a
    /// paused process). Returns the number of members dropped.
    @discardableResult
    func reconcileWithDisk() -> Int {
        state.withLock { stored in
            guard let memory = stored else { return 0 }
            return JournalFileLock.withLock(journal: url) {
                guard let disk = PauseJournal.read(from: url) else {
                    try? persist(memory)
                    return 0
                }
                let result = Self.reconciled(memory: memory, disk: disk)
                guard result.dropped > 0 else { return 0 }
                try? persist(result.journal)
                stored = result.journal
                return result.dropped
            }
        }
    }

    /// Drops empty apps; nil when nothing is left.
    static func normalized(_ journal: PauseJournal) -> PauseJournal? {
        var copy = journal
        copy.apps = journal.apps.filter { !$0.members.isEmpty }
        return copy.apps.isEmpty ? nil : copy
    }

    private func persist(_ journal: PauseJournal?) throws {
        if let journal {
            try journal.write(to: url)
        } else if unlink(url.path(percentEncoded: false)) != 0, errno != ENOENT {
            throw AtomicFile.Failure.write(path: url.path(percentEncoded: false), errno: errno)
        }
    }
}

/// FIFO mutual exclusion for async operations (`pause`, `recheck`, `thawAll`, recovery). They suspend (Quit-mode
/// terminate, relaunch) and must never interleave; a `Mutex` cannot be held across `await`.
final class AsyncSerialLock: Sendable {
    private struct State {
        var locked = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    init() {}

    func lock() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let acquired = state.withLock { s -> Bool in
                if !s.locked {
                    s.locked = true
                    return true
                }
                s.waiters.append(continuation)
                return false
            }
            if acquired { continuation.resume() }
        }
    }

    func unlock() {
        let next = state.withLock { s -> CheckedContinuation<Void, Never>? in
            guard !s.waiters.isEmpty else {
                s.locked = false
                return nil
            }
            return s.waiters.removeFirst()
        }
        next?.resume()
    }

    func withLock<T>(_ body: () async -> T) async -> T {
        await lock()
        defer { unlock() }
        return await body()
    }
}

/// Advisory `flock` on `<journal>.lock`, shared by the app (`JournalStore`) and `kakureneko-guard`'s recovery: the
/// guard's read → thaw → write and the app's read-modify-write of `paused.json` never interleave. Without it a guard
/// write computed from a journal read BEFORE the app appended a record (hang recovery while the app resumes) drops
/// that record, and nothing ever restores the process it describes. Bounded: after `timeout` the caller proceeds
/// without the lock — a stopped holder must never block the safety net (or the app) forever.
enum JournalFileLock {
    static let defaultTimeout: TimeInterval = 2
    static let pollInterval: useconds_t = 10_000

    static func lockURL(for journal: URL) -> URL { journal.appendingPathExtension("lock") }

    /// Runs `body` holding the lock (or, after `timeout`, without it).
    static func withLock<T>(journal: URL, timeout: TimeInterval = defaultTimeout, _ body: () throws -> T) rethrows -> T {
        let fd = acquire(journal: journal, timeout: timeout)
        defer { release(fd) }
        return try body()
    }

    /// The locked descriptor, or -1 when the lock file cannot be opened or the lock was not free within `timeout`.
    static func acquire(journal: URL, timeout: TimeInterval) -> Int32 {
        let fd = open(lockURL(for: journal).path(percentEncoded: false), O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return -1 }
        let deadline = Kernel.uptimeNanoseconds() &+ UInt64(max(0, timeout) * 1_000_000_000)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Kernel.uptimeNanoseconds() < deadline else {
                close(fd)
                return -1
            }
            usleep(pollInterval)
        }
        return fd
    }

    static func release(_ fd: Int32) {
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        close(fd)
    }
}
