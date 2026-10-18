@testable import KakurenekoSessions
import KakurenekoKit
import Foundation
import Synchronization
import Testing

/// Record, `agents --json` and transcript fixtures with the real shapes observed in R02 §3.2, §3.5, §5.2 (extra keys
/// such as `peerFeatures` or `messagingSocketPath` included, so tolerant decoding is exercised).
enum R02 {
    static let procStart = "Mon Oct 12 13:05:23 2026"
    static let procStartPadded = "Sun Oct  4 09:12:01 2026"
    static let interactiveSession = "3514aa88-efa8-4a60-97d7-2878eed849d4"
    static let backgroundSession = "e5b3e311-326c-4b68-847f-51f7e4ee6a7b"

    static func startSec(_ procStart: String) -> Int64 { ClaudeSessionRecord.parseProcStart(procStart) ?? 0 }

    /// Live identity matching a record's `procStart`.
    static func identity(_ pid: Int32, procStart: String = R02.procStart, offset: Int64 = 0) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startSec: startSec(procStart) + offset, startUsec: 250_000)
    }

    static func interactive(status: String = "busy", statusUpdatedAt: Int64 = 1_791_810_678_765, extra: String = "") -> String {
        """
        {"pid":96888,"sessionId":"\(interactiveSession)","cwd":"/Users/tomasnguyen/Developer",\
        "startedAt":1791810326817,"procStart":"\(procStart)","version":"2.1.296","peerProtocol":1,\
        "peerFeatures":["notify_idle","reply_across_default_dirs","artifact_yield"],"kind":"interactive",\
        "entrypoint":"cli","pidDomain":"darwin","messagingSocketPath":"/tmp/cc-socks/96888.sock","name":"developer-40",\
        "nameSource":"derived","nameSince":1791810326817,"status":"\(status)","updatedAt":\(statusUpdatedAt),\
        "statusUpdatedAt":\(statusUpdatedAt)\(extra)}
        """
    }

    static let background = """
        {"pid":24617,"sessionId":"\(backgroundSession)","cwd":"/Users/tomasnguyen/Desktop/bakalarka",\
        "procStart":"\(procStartPadded)","kind":"bg","entrypoint":"cli","name":"Titulná strana bakalárskej práce (2)",\
        "nameSource":"peer","jobId":"e5b3e311","status":"idle","statusUpdatedAt":1791323191564,"updatedAt":1791323191564}
        """
    static let parked = """
        {"pid":44386,"sessionId":"99b32bd6-0000-4000-8000-000000000001","procStart":"\(procStart)","kind":"interactive",\
        "status":"idle","statusUpdatedAt":1790979977529,"updatedAt":1791212724873,"parkedJobId":"e5b3e311"}
        """
    static let spare = #"{"pid":50001,"procStart":"Mon Oct 12 13:05:23 2026","kind":"bg","spare":true}"#
    static let daemon = #"{"pid":35816,"procStart":"Mon Oct 12 13:05:23 2026","kind":"daemon"}"#
    static let deadDaemonWorker = #"{"pid":35900,"procStart":"Mon Oct 12 13:05:23 2026","kind":"daemon-worker"}"#
    /// The 13 h case's process is gone (or never existed on this test machine).
    static let deadBusy = """
        {"pid":76720,"sessionId":"fc061117-c7f7-4b91-9732-b6d60a05cd65","cwd":"/Users/tomasnguyen",\
        "procStart":"\(procStart)","kind":"interactive","status":"busy","statusUpdatedAt":1791761114630}
        """
    /// pid reused by an unrelated process (start time differs by an hour).
    static let reusedPID = """
        {"pid":9220,"sessionId":"0d4f9a1e-aaaa-4bbb-8ccc-dddddddddddd","procStart":"\(procStart)","kind":"interactive",\
        "status":"idle","statusUpdatedAt":1791000000000}
        """

    static let agentsJSON = """
        [{"pid":24617,"id":"e5b3e311","cwd":"/Users/tomasnguyen/Desktop/bakalarka","kind":"background",\
        "startedAt":1791212730037,"sessionId":"\(backgroundSession)","name":"Titulná strana bakalárskej práce (2)",\
        "status":"idle","state":"done"},
         {"pid":76720,"cwd":"/Users/tomasnguyen","kind":"interactive","startedAt":1791719069628,\
        "sessionId":"fc061117-c7f7-4b91-9732-b6d60a05cd65","name":"tomasnguyen-3f","status":"busy"},
         {"id":"0a5f4ad1","cwd":"/Users/tomasnguyen/Developer/kakureneko","kind":"background","startedAt":1791000000000,\
        "sessionId":"7d1c5a90-1111-4222-8333-444455556666","name":"Release notes","state":"stopped"}]
        """

    static let turnCompletedAt = "2026-10-12T22:01:00.200Z"

    /// A transcript tail: prompt, titles, a tool-use step, a sidechain message, the final answer, `turn_duration`.
    static func transcript(sessionId: String = interactiveSession, withTurnDuration: Bool = true) -> String {
        var lines = [
            #"{"type":"user","message":{"role":"user","content":"Fix the cursor reveal"},"cwd":"/Users/tomasnguyen/Developer","timestamp":"2026-10-12T22:00:00.000Z","sessionId":"\#(sessionId)"}"#,
            #"{"type":"custom-title","customTitle":"Cursor reveal","sessionId":"\#(sessionId)"}"#,
            #"{"type":"ai-title","aiTitle":"Portfolio cursor reveal with blowout","sessionId":"\#(sessionId)"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Working on it."},{"type":"tool_use","id":"t1","name":"Bash","input":{}}],"stop_reason":"tool_use"},"isSidechain":false,"cwd":"/Users/tomasnguyen/Developer/projects portfolio","timestamp":"2026-10-12T22:00:10.000Z"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Subagent chatter"}]},"isSidechain":true,"cwd":"/Users/tomasnguyen/Developer/projects portfolio"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done.\n\n  The cursor now reveals \u001b[1mthe blowout\u001b[0m. Tests pass."}],"stop_reason":"end_turn"},"isSidechain":false,"cwd":"/Users/tomasnguyen/Developer/projects portfolio","timestamp":"2026-10-12T22:00:59.000Z"}"#,
        ]
        if withTurnDuration {
            lines.append(#"{"type":"system","subtype":"turn_duration","durationMs":59800,"messageCount":12,"pendingWorkflowCount":0,"pendingBackgroundAgentCount":1,"timestamp":"\#(turnCompletedAt)"}"#)
        }
        lines.append(#"{"type":"last-prompt","lastPrompt":"Fix the cursor reveal","leafUuid":"x"}"#)
        return lines.joined(separator: "\n") + "\n"
    }
}

/// `ClaudeFileAccess` over the real (temp) file system that records every path it is asked about.
/// `hideFromWatcher` makes the sessions directory invisible to the FSEvents arming check only (listing still works),
/// so a test can drive refreshes deterministically without real FSEvents callbacks.
final class RecordingFileAccess: ClaudeFileAccess {
    struct Call: Sendable, Hashable {
        var method: String
        var path: String
    }

    private let base = PosixClaudeFileAccess()
    private let log = Mutex<[Call]>([])
    private let hidden: String?

    init(hideFromWatcher directory: URL? = nil) {
        hidden = directory?.path(percentEncoded: false)
    }

    var calls: [Call] { log.withLock { $0 } }
    /// Paths whose CONTENT was read.
    var opened: [String] { calls.filter { $0.method == "readFile" || $0.method == "readTail" }.map(\.path) }

    private func record(_ method: String, _ url: URL) {
        let path = url.path(percentEncoded: false)
        log.withLock { $0.append(Call(method: method, path: path)) }
    }

    func listDirectory(_ url: URL) -> [String]? {
        record("list", url)
        return base.listDirectory(url)
    }

    func stamp(_ url: URL) -> FileStamp? {
        record("stamp", url)
        if let hidden, url.path(percentEncoded: false) == hidden { return nil }
        return base.stamp(url)
    }

    func readFile(_ url: URL, maxBytes: Int) -> Data? {
        record("readFile", url)
        return base.readFile(url, maxBytes: maxBytes)
    }

    func readTail(_ url: URL, maxBytes: Int) -> (data: Data, offset: UInt64)? {
        record("readTail", url)
        return base.readTail(url, maxBytes: maxBytes)
    }

    func isExecutableFile(_ url: URL) -> Bool {
        record("isExecutable", url)
        return base.isExecutableFile(url)
    }
}

/// A temp home with a fake `~/.claude`, a `StaticProcessLookup`, a `FakeSubprocessRunner` and a `TestClock`.
/// Never touches the real `~/.claude`; the "claude" CLI is never executed (only the fake runner sees requests).
final class WatcherFixture: Sendable {
    let paths: Paths
    let clock = TestClock()
    let runner = FakeSubprocessRunner()
    let lookup = StaticProcessLookup()
    let files: RecordingFileAccess

    init(createSessionsDirectory: Bool = true, fsevents: Bool = true) throws {
        paths = try Paths.temporary(prefix: "kakureneko-sessions-test")
        #expect(paths.isHomeOverridden)
        files = RecordingFileAccess(hideFromWatcher: fsevents ? nil : paths.claudeSessionsDirectory)
        if createSessionsDirectory {
            try FileManager.default.createDirectory(at: paths.claudeSessionsDirectory, withIntermediateDirectories: true)
        }
    }

    deinit { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }

    var root: URL { paths.home.deletingLastPathComponent() }
    var sessions: URL { paths.claudeSessionsDirectory }

    func makeWatcher() -> ClaudeStateWatcher {
        ClaudeStateWatcher(paths: paths, subprocess: runner, processes: lookup, clock: clock,
                           logger: KakurenekoLogger(.sessions), files: files)
    }

    func makeCore() -> ClaudeStateCore {
        ClaudeStateCore(paths: paths, subprocess: runner, processes: lookup, files: files, clock: clock,
                        logger: KakurenekoLogger(.sessions))
    }

    func createSessionsDirectory() throws {
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }

    /// Writes a new file in `sessions/`.
    func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: sessions.appending(path: name), options: .atomic)
    }

    /// Rewrites a file IN PLACE the way Claude does (truncate + write, same inode, no rename). Returns the inode
    /// before and after.
    @discardableResult
    func rewriteInPlace(_ name: String, _ text: String) throws -> (before: Int, after: Int) {
        let url = sessions.appending(path: name)
        let before = try inode(url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
        return (before, try inode(url))
    }

    private func inode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes[.systemFileNumber] as? NSNumber)?.intValue ?? -1
    }

    /// Writes `projects/<directory>/<sessionId>.jsonl`; returns its path.
    @discardableResult
    func writeTranscript(directory: String, sessionId: String, _ text: String) throws -> String {
        let dir = paths.claudeProjectsDirectory.appending(path: directory, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: sessionId + ".jsonl")
        try Data(text.utf8).write(to: url)
        return url.path(percentEncoded: false)
    }

    func appendTranscript(_ path: String, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: URL(filePath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    /// An executable placeholder at `path` (never run: the fake runner answers every request).
    @discardableResult
    func installExecutable(at url: URL) throws -> String {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        return url.path(percentEncoded: false)
    }

    /// `~/.local/bin/claude` inside the temp home.
    @discardableResult
    func installCLICandidate() throws -> String { try installExecutable(at: paths.claudeCLICandidate) }

    /// Answers `claude agents --json --all` with `json` (any executable), everything else with exit 1.
    func answerAgents(_ json: String) {
        runner.setHandler { request in
            request.arguments == ClaudeCLI.agentsArguments
                ? SubprocessResult(exitCode: 0, stdout: Data(json.utf8)) : SubprocessResult(exitCode: 1)
        }
    }

    var agentsRequests: [SubprocessRequest] { runner.requests.filter { $0.arguments == ClaudeCLI.agentsArguments } }
}

/// Collects every snapshot of one subscription on a background task.
final class SnapshotCollector: Sendable {
    private struct State {
        var snapshots: [ClaudeStateSnapshot] = []
        var finished = false
    }

    private final class Box: Sendable {
        let state = Mutex(State())
    }

    private let box = Box()
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<ClaudeStateSnapshot>) {
        let box = box
        task = Task {
            for await snapshot in stream { box.state.withLock { $0.snapshots.append(snapshot) } }
            box.state.withLock { $0.finished = true }
        }
    }

    deinit { task.cancel() }

    var snapshots: [ClaudeStateSnapshot] { box.state.withLock { $0.snapshots } }
    var count: Int { box.state.withLock { $0.snapshots.count } }
    var isFinished: Bool { box.state.withLock { $0.finished } }

    /// The first collected snapshot (from index `from`) matching `predicate`, waiting up to `timeout` of real time.
    func first(from: Int = 0, timeout: Duration = .seconds(10),
               where predicate: (ClaudeStateSnapshot) -> Bool) async -> ClaudeStateSnapshot? {
        var found: ClaudeStateSnapshot?
        _ = await waitUntil(timeout: timeout) {
            found = self.snapshots.dropFirst(from).first(where: predicate)
            return found != nil
        }
        return found
    }
}

/// Polls `condition` every 5 ms of real time (the watcher's tasks run meanwhile) until it holds or `timeout` passes.
/// Positive waits only: the generous default returns as soon as the condition holds and absorbs a busy machine.
@discardableResult
func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
