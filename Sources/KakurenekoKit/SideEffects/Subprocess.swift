import Darwin
import Foundation
import Synchronization

/// A subprocess invocation. Absolute executable path; stdin `/dev/null` unless `stdin` is given.
public struct SubprocessRequest: Sendable, Hashable {
    /// Absolute path (GUI apps do not inherit the shell PATH).
    public var executable: String
    public var arguments: [String]
    /// nil → inherit the current environment.
    public var environment: [String: String]?
    /// Merged on top of `environment` (e.g. `DISABLE_AUTOUPDATER=1`).
    public var extraEnvironment: [String: String]
    /// nil → `/dev/null`.
    public var stdin: Data?
    public var workingDirectory: String?
    /// SIGTERM at the timeout, SIGKILL 2 s later (only ever our own child).
    public var timeout: Duration
    /// Per-stream capture cap; extra output is discarded.
    public var maxOutputBytes: Int
    /// `.mutating` requests are blocked (and logged) in dry-run.
    public var effect: SideEffectKind

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        extraEnvironment: [String: String] = [:],
        stdin: Data? = nil,
        workingDirectory: String? = nil,
        timeout: Duration = .seconds(30),
        maxOutputBytes: Int = 4 << 20,
        effect: SideEffectKind
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.extraEnvironment = extraEnvironment
        self.stdin = stdin
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.effect = effect
    }

    /// `executable arg1 arg2` (for logs; may contain paths but never secrets — don't pass secrets in argv).
    public var displayString: String { ([executable] + arguments).joined(separator: " ") }
}

/// Outcome of a subprocess.
public struct SubprocessResult: Sendable, Hashable {
    /// Exit status, or `128 + signal` when killed by a signal.
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool
    public var durationSeconds: Double

    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data(), timedOut: Bool = false, durationSeconds: Double = 0) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.durationSeconds = durationSeconds
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut }
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs subprocesses. Real: `FoundationSubprocessRunner`. Tests: `FakeSubprocessRunner` (Kit/Testing).
/// Throws `SideEffectError.unavailable` if the executable cannot be launched; a non-zero exit is NOT an error.
public protocol SubprocessRunning: Sendable {
    func run(_ request: SubprocessRequest) async throws -> SubprocessResult
}

/// `Foundation.Process`-backed runner. Runs off the caller's actor (`@concurrent`), drains stdout and
/// stderr concurrently (no pipe deadlock), enforces the timeout, and never waits more than 1 s for
/// pipe EOF after exit (grandchildren that inherit the pipe cannot hang it).
public final class FoundationSubprocessRunner: SubprocessRunning {
    public init() {}

    @concurrent
    public func run(_ request: SubprocessRequest) async throws -> SubprocessResult {
        let started = ContinuousClock.now
        let process = Process()
        process.executableURL = URL(filePath: request.executable)
        process.arguments = request.arguments
        var environment = request.environment ?? ProcessInfo.processInfo.environment
        for (k, v) in request.extraEnvironment { environment[k] = v }
        process.environment = environment
        if let wd = request.workingDirectory {
            process.currentDirectoryURL = URL(filePath: wd, directoryHint: .isDirectory)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        var stdinPipe: Pipe?
        if request.stdin != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let out = OutputCollector(limit: request.maxOutputBytes)
        let err = OutputCollector(limit: request.maxOutputBytes)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in out.consume(handle) }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in err.consume(handle) }

        let exit = ExitWaiter()
        process.terminationHandler = { p in
            let code: Int32 = p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus
            exit.signal(code)
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw SideEffectError.unavailable("cannot launch \(request.executable): \(error.localizedDescription)")
        }

        if let data = request.stdin, let writer = stdinPipe?.fileHandleForWriting {
            // A child that exits without reading stdin must yield EPIPE, never SIGPIPE in this process.
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .utility).async {
                try? writer.write(contentsOf: data)
                try? writer.close()
            }
        }

        let pid = process.processIdentifier
        let owned = OwnedProcess(process)
        let timeout = request.timeout
        let timedOut: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await exit.waitForExit()
                return false
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return true
                } catch {
                    return false
                }
            }
            let first = await group.next() ?? false
            if first, exit.code == nil {
                owned.terminate() // SIGTERM to our own child
                var waited = 0
                while exit.code == nil && waited < 200 {
                    try? await Task.sleep(for: .milliseconds(10))
                    waited += 1
                }
                if exit.code == nil { _ = kill(pid, SIGKILL) } // still our own, not yet reaped child
            }
            group.cancelAll()
            return first
        }

        // Wait (≤ 1 s) for both pipes to hit EOF, then stop reading.
        var spins = 0
        while !(out.isFinished && err.isFinished) && spins < 100 {
            try? await Task.sleep(for: .milliseconds(10))
            spins += 1
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()

        let elapsed = (ContinuousClock.now - started).timeInterval
        return SubprocessResult(
            exitCode: exit.code ?? -1,
            stdout: out.data,
            stderr: err.data,
            timedOut: timedOut,
            durationSeconds: elapsed
        )
    }
}

/// Wraps a `Process` we spawned so it can be terminated from a `@Sendable` context.
private final class OwnedProcess: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() { if process.isRunning { process.terminate() } }
}

private final class OutputCollector: Sendable {
    private struct State { var data = Data(); var finished = false }
    private let state = Mutex(State())
    private let limit: Int

    init(limit: Int) { self.limit = max(0, limit) }

    func consume(_ handle: FileHandle) {
        let chunk = handle.availableData
        state.withLock { s in
            if chunk.isEmpty {
                s.finished = true
                return
            }
            let room = limit - s.data.count
            if room > 0 { s.data.append(chunk.prefix(room)) }
        }
        if chunk.isEmpty { handle.readabilityHandler = nil }
    }

    var data: Data { state.withLock { $0.data } }
    var isFinished: Bool { state.withLock { $0.finished } }
}

private final class ExitWaiter: Sendable {
    private struct State {
        var code: Int32?
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func signal(_ code: Int32) {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { s in
            s.code = code
            defer { s.waiters.removeAll() }
            return s.waiters
        }
        for w in waiters { w.resume() }
    }

    func waitForExit() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done = state.withLock { s -> Bool in
                if s.code != nil { return true }
                s.waiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    var code: Int32? { state.withLock { $0.code } }
}
