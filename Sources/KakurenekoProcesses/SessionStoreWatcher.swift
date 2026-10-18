import CoreServices
import Darwin
import KakurenekoKit
import Foundation
import Synchronization

/// E3 bookkeeping: which paths belong to which agent process, and when each was last written. Fed by the FSEvents
/// stream (or by tests directly); read by the scanner every sample.
final class SessionStoreWriteLog: Sendable {
    private struct State {
        /// identity → normalised hint paths (as given and with symlinks resolved, e.g. `/var` → `/private/var`).
        var hints: [ProcessIdentity: [String]] = [:]
        var lastWrite: [ProcessIdentity: Date] = [:]
    }

    private let state = Mutex(State())

    /// Replaces the hint set; forgets write times of identities that are no longer hinted.
    func setHints(_ hints: [SessionStoreHint]) {
        var normalised: [ProcessIdentity: [String]] = [:]
        for hint in hints {
            var forms: [String] = normalised[hint.identity] ?? []
            for path in hint.paths {
                for form in Self.forms(of: path) where !forms.contains(form) { forms.append(form) }
            }
            normalised[hint.identity] = forms
        }
        state.withLock { s in
            s.hints = normalised
            s.lastWrite = s.lastWrite.filter { normalised[$0.key] != nil }
        }
    }

    var hintedPaths: [String] { state.withLock { Array(Set($0.hints.values.joined())).sorted() } }

    /// Records writes to `paths` at `date`. `recursive` = the event says "rescan this subtree" (coalesced events):
    /// every hint below such a path counts as written.
    func record(paths: [(path: String, recursive: Bool)], at date: Date) {
        guard !paths.isEmpty else { return }
        state.withLock { s in
            for (identity, hintPaths) in s.hints {
                let written = paths.contains { event in
                    hintPaths.contains { hint in Self.matches(eventPath: event.path, hint: hint, recursive: event.recursive) }
                }
                if written { s.lastWrite[identity] = max(date, s.lastWrite[identity] ?? date) }
            }
        }
    }

    func lastWrite(for identity: ProcessIdentity) -> Date? {
        state.withLock { $0.lastWrite[identity] }
    }

    // MARK: Pure helpers

    static func matches(eventPath: String, hint: String, recursive: Bool) -> Bool {
        let event = trimmed(eventPath)
        if event == hint || event.hasPrefix(hint + "/") { return true }
        return recursive && hint.hasPrefix(event + "/")
    }

    /// The path as given and with its existing prefix resolved (`realpath`), both without a trailing slash.
    static func forms(of path: String) -> [String] {
        let given = trimmed(path)
        guard given.hasPrefix("/") else { return [] }
        var result = [given]
        if let resolved = resolvingExistingPrefix(given), resolved != given { result.append(resolved) }
        return result
    }

    static func trimmed(_ path: String) -> String {
        var value = path
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// `realpath` of the longest existing prefix + the non-existing remainder.
    static func resolvingExistingPrefix(_ path: String) -> String? {
        var existing = path
        var remainder: [String] = []
        while existing != "/" && !existing.isEmpty {
            if let resolved = realPath(existing) {
                return ([resolved] + remainder.reversed()).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
            }
            let url = URL(filePath: existing)
            remainder.append(url.lastPathComponent)
            existing = url.deletingLastPathComponent().path(percentEncoded: false)
            existing = trimmed(existing)
        }
        return nil
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Directories to watch for a set of hint paths: each hint's nearest existing directory (the hint itself when it is
    /// a directory, else its parent, else further up — but never `/` or the bare home), with nested roots collapsed.
    static func watchRoots(for hintPaths: [String], home: String) -> [String] {
        let homeTrimmed = trimmed(home)
        let homeResolved = realPath(homeTrimmed) ?? homeTrimmed
        var roots: Set<String> = []
        for hint in hintPaths {
            var candidate = trimmed(hint)
            var isDirectory: ObjCBool = false
            if !(FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory) && isDirectory.boolValue) {
                candidate = trimmed(URL(filePath: candidate).deletingLastPathComponent().path(percentEncoded: false))
            }
            while candidate != "/", candidate != homeTrimmed, !candidate.isEmpty,
                  !FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory) || !isDirectory.boolValue {
                candidate = trimmed(URL(filePath: candidate).deletingLastPathComponent().path(percentEncoded: false))
            }
            guard candidate != "/", candidate != homeTrimmed, !candidate.isEmpty else { continue }
            // One root per directory: hints arrive both as given and symlink-resolved (`/var` → `/private/var`), and
            // FSEvents reports resolved paths anyway.
            let resolved = realPath(candidate) ?? candidate
            guard resolved != "/", resolved != homeResolved else { continue }
            roots.insert(resolved)
        }
        let sorted = roots.sorted()
        return sorted.filter { root in !sorted.contains { $0 != root && root.hasPrefix($0 + "/") } }
    }
}

/// FSEvents stream over the hinted session stores (E3). Started by `ProcessScanner.start()`; the stream is rebuilt
/// only when the set of watched roots changes. The C callback reaches the write log through an `Unmanaged` box
/// (R08 §8); create/stop happen on the stream's own serial queue, so no callback runs while it is torn down.
final class SessionStoreWatcher: Sendable {
    /// What the C callback needs. Retained by the stream handle for the stream's lifetime.
    private final class CallbackContext: Sendable {
        let log: SessionStoreWriteLog
        let clock: any KakurenekoClock
        init(log: SessionStoreWriteLog, clock: any KakurenekoClock) {
            self.log = log
            self.clock = clock
        }
    }

    /// The live stream (only touched on `queue`).
    private final class StreamHandle: @unchecked Sendable {
        let stream: FSEventStreamRef
        let context: Unmanaged<CallbackContext>
        init(stream: FSEventStreamRef, context: Unmanaged<CallbackContext>) {
            self.stream = stream
            self.context = context
        }
    }

    private struct State {
        var running = false
        var roots: [String] = []
        var handle: StreamHandle?
    }

    let log: SessionStoreWriteLog
    private let clock: any KakurenekoClock
    private let home: String
    private let logger: KakurenekoLogger
    private let latency: CFTimeInterval
    private let queue = DispatchQueue(label: "com.kakureneko.processes.store-events")
    private let state = Mutex(State())

    static let relevantFlags: FSEventStreamEventFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed
            | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagMustScanSubDirs
    )

    init(log: SessionStoreWriteLog, clock: any KakurenekoClock, home: String, logger: KakurenekoLogger, latency: CFTimeInterval = 0.2) {
        self.log = log
        self.clock = clock
        self.home = home
        self.logger = logger
        self.latency = latency
    }

    deinit {
        let handle = state.withLock { s -> StreamHandle? in
            defer { s.handle = nil }
            return s.handle
        }
        if let handle { queue.sync { Self.teardown(handle) } }
    }

    var isRunning: Bool { state.withLock { $0.running } }
    var watchedRoots: [String] { state.withLock { $0.roots } }

    func start() {
        let alreadyRunning = state.withLock { s -> Bool in
            defer { s.running = true }
            return s.running
        }
        if !alreadyRunning { refreshStream() }
    }

    func stop() {
        let handle = state.withLock { s -> StreamHandle? in
            s.running = false
            s.roots = []
            defer { s.handle = nil }
            return s.handle
        }
        if let handle { queue.sync { Self.teardown(handle) } }
    }

    func setHints(_ hints: [SessionStoreHint]) {
        log.setHints(hints)
        if isRunning { refreshStream() }
    }

    /// Re-creates the stream when the watched roots changed.
    private func refreshStream() {
        let roots = SessionStoreWriteLog.watchRoots(for: log.hintedPaths, home: home)
        let previous = state.withLock { s -> StreamHandle?? in
            guard s.running, roots != s.roots || (s.handle == nil && !roots.isEmpty) else { return .none }
            s.roots = roots
            defer { s.handle = nil }
            return .some(s.handle)
        }
        guard case .some(let old) = previous else { return }
        let created: StreamHandle? = queue.sync {
            if let old { Self.teardown(old) }
            return roots.isEmpty ? nil : makeStream(roots: roots)
        }
        let stale = state.withLock { s -> StreamHandle? in
            // stop() or another refresh may have run meanwhile.
            guard s.running, s.roots == roots else { return created }
            let replaced = s.handle
            s.handle = created
            return replaced
        }
        if let stale { queue.sync { Self.teardown(stale) } }
        logger.debug("store watcher: \(roots.count) root(s)")
    }

    /// Must run on `queue`.
    private func makeStream(roots: [String]) -> StreamHandle? {
        let box = Unmanaged.passRetained(CallbackContext(log: log, clock: clock))
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let context = Unmanaged<CallbackContext>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            var written: [(path: String, recursive: Bool)] = []
            for index in 0..<min(count, paths.count) {
                let flags = eventFlags[index]
                guard flags & SessionStoreWatcher.relevantFlags != 0 else { continue }
                let recursive = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
                written.append((paths[index], recursive))
            }
            context.log.record(paths: written, at: context.clock.now())
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else {
            box.release()
            logger.warning("store watcher: FSEventStreamCreate failed for \(roots.count) root(s)")
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            box.release()
            logger.warning("store watcher: FSEventStreamStart failed")
            return nil
        }
        return StreamHandle(stream: stream, context: box)
    }

    /// Must run on `queue` (no callback can be executing concurrently).
    private static func teardown(_ handle: StreamHandle) {
        FSEventStreamStop(handle.stream)
        FSEventStreamInvalidate(handle.stream)
        FSEventStreamRelease(handle.stream)
        handle.context.release()
    }
}
