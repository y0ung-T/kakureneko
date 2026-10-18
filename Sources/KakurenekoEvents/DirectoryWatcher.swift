import Darwin
import Dispatch
import Foundation
import Synchronization

/// One inbox directory watched with a vnode `DispatchSource` on an `O_EVTONLY` descriptor (R08 §6.6: fires
/// 0–1 ms after the hook's `rename(2)`, no coalescing latency).
///
/// * Mask `[.write, .rename, .delete]`: `.write` = an entry was added or removed; `.rename`/`.delete` = the
///   directory ITSELF was moved or removed — the watcher then re-creates it (0700, with `.tmp/` and `bad/`) and
///   re-arms on a fresh descriptor, so a user who deletes `~/.kakureneko/inbox` does not silently stop delivery.
/// * Every handler runs on the owner's serial queue; the change callback only schedules a drain.
/// * The descriptor is closed by the source's cancel handler (never while the source can still fire).
final class DirectoryWatcher: Sendable {
    let directory: URL
    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void
    private let source = Mutex<(any DispatchSourceFileSystemObject)?>(nil)

    init(directory: URL, queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
        self.directory = directory
        self.queue = queue
        self.onChange = onChange
    }

    deinit {
        source.withLock { current in
            current?.cancel()
            current = nil
        }
    }

    var isArmed: Bool { source.withLock { $0 != nil } }

    /// (Re)arms the watcher, creating the directory first when it is missing. Returns true when armed.
    @discardableResult
    func arm() -> Bool {
        disarm()
        guard InboxDirectories.ensure(directory) else { return false }
        let fd = open(directory.path(percentEncoded: false), O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        newSource.setEventHandler { [weak self] in self?.handleEvent() }
        newSource.setCancelHandler { close(fd) }
        source.withLock { $0 = newSource }
        newSource.activate()
        return true
    }

    /// Cancels the source (its cancel handler closes the descriptor).
    func disarm() {
        source.withLock { current in
            current?.cancel()
            current = nil
        }
    }

    private func handleEvent() {
        let mask: DispatchSource.FileSystemEvent = source.withLock { $0?.data } ?? []
        if mask.contains(.delete) || mask.contains(.rename) {
            // The watched directory itself went away: watch the (re-created) path instead.
            arm()
        }
        onChange()
    }
}

/// Kakureneko's own inbox directories (never an agent's directory).
enum InboxDirectories {
    /// Creates `directory` plus its `.tmp/` and `bad/` children with mode 0700. True when `directory` exists.
    @discardableResult
    static func ensure(_ directory: URL) -> Bool {
        let fm = FileManager.default
        for url in [directory, temporary(of: directory), bad(of: directory)] {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        return stat(directory.path(percentEncoded: false), &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func temporary(of inbox: URL) -> URL { inbox.appending(path: ".tmp", directoryHint: .isDirectory) }
    static func bad(of inbox: URL) -> URL { inbox.appending(path: "bad", directoryHint: .isDirectory) }
}
