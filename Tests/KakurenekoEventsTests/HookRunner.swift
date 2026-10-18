import Darwin
import Dispatch
import Foundation

/// Spawns `kakureneko-hook` (or a wrapper) with `posix_spawn`: exact control over stdin (data, `/dev/null`, a pipe the
/// parent keeps open, a pty slave), captured stdout/stderr, wall time, and a hard timeout (SIGKILL — only ever this
/// test's own child). `Foundation.Process` adds ~65 ms per launch (R08 §10), which would swamp the timing checks.
enum HookRunner {
    enum Stdin: Sendable {
        case devNull
        /// A pipe that receives `data` and is then closed (EOF).
        case data(Data)
        /// A pipe that receives `prefix` and stays OPEN until the child exits (an agent that never closes stdin).
        case heldOpen(prefix: Data)
        /// A pty slave (Aider runs the hook with the user's terminal as stdin).
        case pty
    }

    struct Result: Sendable {
        var pid: Int32
        /// `waitpid` status decoded: exit code, or 128 + signal.
        var exitCode: Int32
        var stdout: Data
        var stderr: Data
        var milliseconds: Double
        var timedOut: Bool
    }

    /// - Parameter argv0: argv[0] of the child (default: `executable`), e.g. `python3` for a `/bin/sh` stand-in.
    static func run(
        executable: String = Products.hookPath,
        argv0: String? = nil,
        _ arguments: [String],
        environment: [String: String],
        stdin: Stdin = .devNull,
        workingDirectory: String? = nil,
        timeout: Double = 5
    ) async -> Result {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(executable: executable, argv0: argv0 ?? executable,
                                                          arguments: arguments, environment: environment, stdin: stdin,
                                                          workingDirectory: workingDirectory, timeout: timeout))
            }
        }
    }

    private static func makePipe() -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        precondition(pipe(&fds) == 0, "pipe failed")
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return (fds[0], fds[1])
    }

    private static func runBlocking(
        executable: String, argv0: String, arguments: [String], environment: [String: String], stdin: Stdin,
        workingDirectory: String?, timeout: Double
    ) -> Result {
        let out = makePipe()
        let err = makePipe()
        var stdinFD: Int32 = -1
        var stdinWriter: Int32 = -1
        var ptyMaster: Int32 = -1
        var pendingStdin = Data()
        switch stdin {
        case .devNull:
            stdinFD = open("/dev/null", O_RDONLY | O_CLOEXEC)
        case .data(let data):
            let p = makePipe()
            stdinFD = p.read
            stdinWriter = p.write
            pendingStdin = data
        case .heldOpen(let prefix):
            let p = makePipe()
            stdinFD = p.read
            stdinWriter = p.write
            pendingStdin = prefix
        case .pty:
            ptyMaster = posix_openpt(O_RDWR | O_NOCTTY)
            precondition(ptyMaster >= 0 && grantpt(ptyMaster) == 0 && unlockpt(ptyMaster) == 0, "pty setup failed")
            _ = fcntl(ptyMaster, F_SETFD, FD_CLOEXEC)
            let slaveName = String(cString: ptsname(ptyMaster))
            stdinFD = open(slaveName, O_RDWR | O_NOCTTY | O_CLOEXEC)
            precondition(stdinFD >= 0, "pty slave open failed")
        }
        if stdinWriter >= 0 { _ = fcntl(stdinWriter, F_SETNOSIGPIPE, 1) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdinFD, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, out.write, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, err.write, STDERR_FILENO)
        if let workingDirectory { posix_spawn_file_actions_addchdir(&actions, workingDirectory) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = [argv0] + arguments
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in cArgv { free(pointer) }
            for pointer in cEnv { free(pointer) }
        }

        let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attributes, &cArgv, &cEnv)
        close(out.write)
        close(err.write)
        close(stdinFD)
        precondition(rc == 0, "posix_spawn \(executable) failed: \(rc)")

        // Feed stdin (small payloads fit the pipe buffer; larger ones are written by a helper thread).
        var writerDone: DispatchSemaphore?
        if stdinWriter >= 0 {
            let keepOpen: Bool = { if case .heldOpen = stdin { return true } else { return false } }()
            let writer = stdinWriter
            let data = pendingStdin
            let done = DispatchSemaphore(value: 0)
            writerDone = done
            DispatchQueue.global().async {
                data.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let n = write(writer, raw.baseAddress! + offset, raw.count - offset)
                        if n < 0 && errno == EINTR { continue }
                        if n <= 0 { break }
                        offset += n
                    }
                }
                if !keepOpen { close(writer) }
                done.signal()
            }
        }

        // Collect output concurrently (a chatty child could fill a pipe).
        let stdoutBox = Collector()
        let stderrBox = Collector()
        let readers = DispatchGroup()
        for (fd, box) in [(out.read, stdoutBox), (err.read, stderrBox)] {
            DispatchQueue.global().async(group: readers) {
                var chunk = [UInt8](repeating: 0, count: 4_096)
                while true {
                    let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    box.append(chunk[0..<n])
                }
                close(fd)
            }
        }

        var status: Int32 = 0
        var timedOut = false
        let deadline = started + UInt64(timeout * 1e9)
        while true {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { break }
            if r < 0 && errno != EINTR { break }
            if clock_gettime_nsec_np(CLOCK_UPTIME_RAW) > deadline {
                timedOut = true
                kill(pid, SIGKILL) // our own child only
                _ = waitpid(pid, &status, 0)
                break
            }
            usleep(500)
        }
        let finished = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

        writerDone?.wait()
        if case .heldOpen = stdin { close(stdinWriter) }
        if ptyMaster >= 0 { close(ptyMaster) }
        _ = readers.wait(timeout: .now() + 2)

        let exitCode: Int32 = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
        return Result(pid: pid, exitCode: exitCode, stdout: stdoutBox.data, stderr: stderrBox.data,
                      milliseconds: Double(finished - started) / 1e6, timedOut: timedOut)
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        func append(_ bytes: ArraySlice<UInt8>) { lock.withLock { storage.append(contentsOf: bytes) } }
        var data: Data { lock.withLock { storage } }
    }
}
