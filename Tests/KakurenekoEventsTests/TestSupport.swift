import Darwin
@testable import KakurenekoEvents
import KakurenekoKit
import Foundation
import Synchronization
import Testing

/// Locates executables built into the SwiftPM products directory (next to the .xctest bundle).
enum Products {
    final class Marker {}
    static var directory: URL { Bundle(for: Marker.self).bundleURL.deletingLastPathComponent() }
    static func executable(_ name: String) -> URL { directory.appending(path: name, directoryHint: .notDirectory) }
    static var hookPath: String { executable(KakurenekoID.hookExecutableName).path(percentEncoded: false) }
}

/// A fresh temp home (`Paths.temporary()`), removed when the test ends.
final class TempHome: Sendable {
    let paths: Paths

    init() throws {
        paths = try Paths.temporary(prefix: "kakureneko-events")
    }

    deinit {
        // Read-only test directories (fallback tests) must become writable again before removal.
        let root = paths.home.deletingLastPathComponent()
        if let enumerator = FileManager.default.enumerator(atPath: root.path(percentEncoded: false)) {
            for case let relative as String in enumerator {
                _ = chmod(root.appending(path: relative).path(percentEncoded: false), 0o700)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// A scratch directory inside the temp root (never inside the fake home's agent dirs).
    func scratch(_ name: String) throws -> URL {
        let url = paths.home.deletingLastPathComponent().appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Environment for a spawned hook: `HOME` + `KAKURENEKO_HOME` (helperEnvironment) + BOTH inbox overrides.
    func hookEnvironment(inbox: URL? = nil, fallback: URL? = nil, extra: [String: String] = [:]) -> [String: String] {
        var env = paths.helperEnvironment
        env[KakurenekoEnvironment.inbox] = (inbox ?? paths.inboxDirectory).path(percentEncoded: false)
        env[KakurenekoEnvironment.fallbackInbox] = (fallback ?? paths.fallbackInboxDirectory).path(percentEncoded: false)
        for (key, value) in extra { env[key] = value }
        return env
    }
}

extension URL {
    /// Filesystem path with symlinks resolved (`/var/folders` → `/private/var/folders`), as `getcwd` reports it.
    var realPath: String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let path = self.path(percentEncoded: false)
        guard realpath(path, &buffer) != nil else { return path }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

// MARK: - Inbox files

enum InboxFiles {
    /// `*.event` files of a directory, sorted by name.
    static func eventFiles(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return names.filter { $0.hasSuffix(".event") }.sorted().map { directory.appending(path: $0, directoryHint: .notDirectory) }
    }

    static func entries(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []).sorted()
    }

    /// Writes an inbox file the way the hook does (`.tmp/` then `rename(2)`). Returns the final URL.
    @discardableResult
    static func write(
        _ header: InboxHeader,
        payload: String,
        to inbox: URL,
        nanoseconds: UInt64? = nil
    ) throws -> URL {
        let ns = nanoseconds ?? UInt64(header.ts) * 1_000_000
        let name = InboxFile.fileName(epochNanoseconds: ns, pid: header.pid)
        let data = try InboxFile.serialize(header: header, payload: Data(payload.utf8))
        try FileManager.default.createDirectory(at: inbox.appending(path: ".tmp"), withIntermediateDirectories: true)
        let temporary = inbox.appending(path: ".tmp/\(name).tmp", directoryHint: .notDirectory)
        try data.write(to: temporary)
        let final = inbox.appending(path: name, directoryHint: .notDirectory)
        guard rename(temporary.path(percentEncoded: false), final.path(percentEncoded: false)) == 0 else {
            throw POSIXError(.EIO)
        }
        return final
    }

    /// Sets a file's modification time (GC tests).
    static func setModified(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path(percentEncoded: false))
    }
}

// MARK: - Fixtures

enum Fixture {
    /// Fixed fixture time (= `TestClock.defaultStart`).
    static let t0 = TestClock.defaultStart

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    static func header(
        _ agent: String,
        _ event: String,
        at date: Date = t0,
        env: [String: String] = [:],
        ancestry: [InboxAncestor] = [],
        cwd: String? = "/Users/x/proj",
        pid: Int32 = 4_242,
        ppid: Int32 = 4_241,
        payloadSource: String? = "stdin"
    ) -> InboxHeader {
        InboxHeader(agent: agent, event: event, ts: ms(date), pid: pid, ppid: ppid, cwd: cwd,
                    payloadSource: payloadSource, env: env, ancestry: ancestry)
    }
}

/// Ancestry builders (nearest first in headers). Paths and argv shapes follow R02/R03/R04/R05.
enum Ancestor {
    static func make(_ pid: Int32, argv0: String?, path: String? = nil, argv1: String? = nil, exe: String? = nil,
                     ppid: Int32? = nil, startSec: Int64 = 1_791_800_000, tdev: Int32? = nil) -> InboxAncestor {
        InboxAncestor(pid: pid, ppid: ppid, startSec: startSec + Int64(pid), startUsec: Int32(pid % 1_000_000), exe: exe,
                      argv0: argv0, tdev: tdev, argv1: argv1, path: path)
    }

    static func claude(_ pid: Int32) -> InboxAncestor {
        make(pid, argv0: "claude", path: "/Users/x/.local/share/claude/versions/2.1.296", exe: "2.1.296")
    }
    static func claudeDaemon(_ pid: Int32) -> InboxAncestor {
        make(pid, argv0: "/Users/x/.local/bin/claude", path: "/Users/x/.local/share/claude/versions/2.1.296",
             argv1: nil, exe: "2.1.296")
    }
    static func codex(_ pid: Int32) -> InboxAncestor {
        make(pid, argv0: "codex", path: "/opt/homebrew/bin/codex", exe: "codex")
    }
    static func codexNode(_ pid: Int32) -> InboxAncestor {
        make(pid, argv0: "node", path: "/opt/homebrew/Cellar/node/26.0.0/bin/node",
             argv1: "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js", exe: "node")
    }
    static func geminiNode(_ pid: Int32) -> InboxAncestor {
        make(pid, argv0: "/opt/homebrew/bin/node", path: "/opt/homebrew/bin/node", argv1: "/opt/homebrew/bin/gemini", exe: "node")
    }
    static func copilot(_ pid: Int32) -> InboxAncestor {
        make(pid, argv0: "copilot", path: "/opt/homebrew/bin/copilot", exe: "copilot")
    }
    static func droid(_ pid: Int32) -> InboxAncestor {
        make(pid, argv0: "droid", path: "/Users/x/.local/bin/droid", exe: "droid")
    }
    static func opencode(_ pid: Int32) -> InboxAncestor {
        make(pid, argv0: "opencode", path: "/Users/x/.opencode/bin/opencode", exe: "opencode")
    }
    static func python(_ pid: Int32, script: String = "/Users/x/.local/share/uv/tools/aider-chat/bin/aider") -> InboxAncestor {
        make(pid, argv0: "/Users/x/.local/share/uv/tools/aider-chat/bin/python3.12",
             path: "/opt/homebrew/Cellar/python@3.12/3.12.9/Frameworks/Python.framework/Versions/3.12/bin/python3.12",
             argv1: script, exe: "python3.12")
    }
    /// Cursor CLI: `exec -a "$0" node … index.js` (the basic matcher does not know it).
    static func cursorCLI(_ pid: Int32) -> InboxAncestor {
        make(pid, argv0: "/Users/x/.local/bin/agent", path: "/Users/x/.local/share/cursor-agent/versions/2026.10.01/node",
             argv1: nil, exe: "node")
    }
    static func sh(_ pid: Int32) -> InboxAncestor { make(pid, argv0: "/bin/sh", path: "/bin/bash", exe: "bash") }
    static func bash(_ pid: Int32) -> InboxAncestor { make(pid, argv0: "bash", path: "/bin/bash", exe: "bash") }
    static func zsh(_ pid: Int32) -> InboxAncestor { make(pid, argv0: "-zsh", path: "/bin/zsh", exe: "zsh", tdev: 268_435_460) }
    static func login(_ pid: Int32) -> InboxAncestor { make(pid, argv0: nil, path: nil, exe: "login") }
    static func terminal(_ pid: Int32) -> InboxAncestor {
        make(pid, argv0: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
             path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", exe: "Terminal")
    }
    static func vscodePluginHost(_ pid: Int32) -> InboxAncestor {
        let path = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        return make(pid, argv0: path, path: path, exe: "Code Helper (Plu")
    }
    static func vscodeMain(_ pid: Int32) -> InboxAncestor {
        let path = "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"
        return make(pid, argv0: path, path: path, exe: "Electron")
    }
    /// An unrelated, unmatched program (e.g. `make`, a test runner).
    static func other(_ pid: Int32, _ name: String = "make") -> InboxAncestor {
        make(pid, argv0: name, path: "/usr/bin/\(name)", exe: name)
    }
}

/// Drives `EventPipeline` directly with synthetic inbox headers.
struct PipelineHarness {
    var pipeline: EventPipeline
    var now: Date = Fixture.t0
    private var sequence: UInt64 = 0

    init(matcher: any AgentSignatureMatching = BasicAgentSignatureMatcher(),
         bundles: [String: String] = [:]) {
        pipeline = EventPipeline(matcher: matcher, bundleIdentifierLookup: { bundles[$0] })
    }

    /// Processes one event `offset` seconds after `t0` (header ts and receivedAt both at that time unless given).
    mutating func send(
        _ agent: String,
        _ event: String,
        _ payload: String = "{}",
        env: [String: String] = [:],
        ancestry: [InboxAncestor] = [],
        at offset: TimeInterval = 0,
        receivedAt: Date? = nil,
        cwd: String? = "/Users/x/proj",
        ppid: Int32 = 4_241
    ) -> EventPipeline.Outcome {
        sequence += 1
        let date = Fixture.t0.addingTimeInterval(offset)
        let header = Fixture.header(agent, event, at: date, env: env, ancestry: ancestry, cwd: cwd, ppid: ppid)
        let id = InboxFile.fileName(epochNanoseconds: UInt64(Fixture.ms(date)) * 1_000_000 + sequence, pid: header.pid)
        return pipeline.process(id: id, header: header, payload: Data(payload.utf8), receivedAt: receivedAt ?? date)
    }

    /// `send` that must be accepted.
    mutating func accept(
        _ agent: String, _ event: String, _ payload: String = "{}", env: [String: String] = [:],
        ancestry: [InboxAncestor] = [], at offset: TimeInterval = 0, sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> AgentEvent {
        let outcome = send(agent, event, payload, env: env, ancestry: ancestry, at: offset)
        return try #require(outcome.event, "expected \(agent) \(event) to be accepted, got \(outcome)", sourceLocation: sourceLocation)
    }
}

// MARK: - Stream recording

/// Consumes an `AsyncStream<AgentEvent>` in the background; tests poll it with a deadline.
final class EventRecorder: Sendable {
    private final class Storage: Sendable {
        let events = Mutex<[AgentEvent]>([])
        let finished = Mutex(false)
    }
    private let storage = Storage()
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<AgentEvent>) {
        let storage = self.storage
        task = Task.detached {
            for await event in stream { storage.events.withLock { $0.append(event) } }
            storage.finished.withLock { $0 = true }
        }
    }

    deinit { task.cancel() }

    var events: [AgentEvent] { storage.events.withLock { $0 } }
    var isFinished: Bool { storage.finished.withLock { $0 } }

    /// Waits (polling every 5 ms) until at least `count` events arrived or `timeout` passed.
    @discardableResult
    func wait(for count: Int, timeout: Duration = .seconds(10)) async -> [AgentEvent] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let current = events
            if current.count >= count { return current }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return events
    }

    /// Waits until the stream finished.
    @discardableResult
    func waitForFinish(timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if isFinished { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return isFinished
    }
}

/// Polls `condition` every 5 ms until it holds or `timeout` passes.
/// Positive waits only (returns as soon as `condition` holds); the generous default absorbs a busy machine.
func eventually(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
