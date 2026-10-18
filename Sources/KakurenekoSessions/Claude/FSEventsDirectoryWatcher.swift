import CoreServices
import KakurenekoKit
import Dispatch
import Foundation
import Synchronization

/// FSEvents stream with FILE-level events on one directory (ARCHITECTURE §9.3): Claude rewrites `<pid>.json` in
/// place, which a directory vnode source does not report. Latency 0.2 s, `NoDefer` (first event of a burst is
/// delivered at once). Only changes to `^\d+\.json$` entries (or "rescan" flags) call `onChange`; `*.key` and
/// `.fleetview-heartbeat` churn is filtered out.
///
/// The C callback is capture-free and reaches Swift through an `Unmanaged` box (ARCHITECTURE §5). The box is
/// retained for the stream's lifetime and released on the stream's queue after invalidation, so a callback that is
/// already queued can never touch a freed box.
final class FSEventsDirectoryWatcher: Sendable {
    private final class Box: Sendable {
        let onChange: @Sendable () -> Void
        init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    }

    /// The stream and the retained box pointer (C handles; only touched under `stream`'s lock).
    private final class Handle: @unchecked Sendable {
        let stream: FSEventStreamRef
        let info: UnsafeMutableRawPointer
        init(stream: FSEventStreamRef, info: UnsafeMutableRawPointer) {
            self.stream = stream
            self.info = info
        }
    }

    let path: String
    let latency: TimeInterval
    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void
    private let handle = Mutex<Handle?>(nil)

    init(path: String, latency: TimeInterval = 0.2, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.latency = latency
        self.onChange = onChange
        queue = DispatchQueue(label: "com.kakureneko.sessions.fsevents", qos: .utility)
    }

    deinit { stop() }

    var isRunning: Bool { handle.withLock { $0 != nil } }

    /// Starts the stream (idempotent). False when FSEvents refused the path.
    @discardableResult
    func start() -> Bool {
        handle.withLock { current -> Bool in
            if current != nil { return true }
            let info = Unmanaged.passRetained(Box(onChange: onChange)).toOpaque()
            var context = FSEventStreamContext(version: 0, info: info, retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
                guard let info else { return }
                let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
                let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                var relevant = false
                for i in 0..<count where !relevant {
                    relevant = FSEventsDirectoryWatcher.isRelevant(path: String(cString: paths[i]), flags: eventFlags[i])
                }
                if relevant { box.onChange() }
            }
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
            guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [path] as CFArray,
                                                   FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
                Unmanaged<Box>.fromOpaque(info).release()
                return false
            }
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                Unmanaged<Box>.fromOpaque(info).release()
                return false
            }
            current = Handle(stream: stream, info: info)
            return true
        }
    }

    /// Stops the stream (idempotent). Safe from any thread, including the stream's own queue.
    func stop() {
        guard let h = handle.withLock({ current -> Handle? in
            defer { current = nil }
            return current
        }) else { return }
        FSEventStreamStop(h.stream)
        FSEventStreamInvalidate(h.stream)
        FSEventStreamRelease(h.stream)
        // Callbacks already queued run before this block (serial queue), so the box outlives them.
        queue.async { Unmanaged<Box>.fromOpaque(h.info).release() }
    }

    /// A record file changed, or FSEvents asks for a rescan.
    static func isRelevant(path: String, flags: FSEventStreamEventFlags) -> Bool {
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        if flags & rescan != 0 { return true }
        let name = (path as NSString).lastPathComponent
        return ClaudeSessionRecord.isRecordFileName(name)
    }
}
