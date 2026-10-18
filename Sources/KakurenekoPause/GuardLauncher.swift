import Darwin
import KakurenekoKit
import Foundation

/// A running `kakureneko-guard` and the write end of its heartbeat pipe.
struct GuardProcess: Sendable, Hashable {
    var pid: pid_t
    /// O_CLOEXEC | O_NONBLOCK | F_SETNOSIGPIPE: never inherited by other children, never blocks, never SIGPIPEs.
    var writeFD: Int32
}

/// Spawns and talks to `kakureneko-guard` (brief §6.5 item 3; ARCHITECTURE §9.5).
enum GuardLauncher {
    /// Heartbeat cadence; the guard declares a hang after `PauseGuard.defaultHangTimeout` without one.
    static let heartbeatInterval: Duration = .seconds(10)
    static let heartbeatLine = "hb\n"
    static let byeLine = "bye\n"

    /// `guardExecutable --watch <watchPID> --journal <journal> --log <log> --pipe-fd <fd>` via `posix_spawn` with
    /// `POSIX_SPAWN_SETSID` (own session: no terminal signals) and `POSIX_SPAWN_CLOEXEC_DEFAULT` (it inherits only
    /// /dev/null stdio and the pipe's read end). Signal dispositions and mask are reset: the app ignores SIGTERM & co.
    /// for its signal sources, and ignored dispositions would otherwise survive `exec`.
    static func spawn(executable: URL, watchPID: pid_t, journal: URL, log: URL,
                      environment: [String: String], extraArguments: [String] = []) throws -> GuardProcess {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw SideEffectError.failed("pipe: \(String(cString: strerror(errno)))") }
        let readFD = fds[0], writeFD = fds[1]
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
        _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK)

        let arguments = [executable.path(percentEncoded: false),
                         "--watch", String(watchPID),
                         "--journal", journal.path(percentEncoded: false),
                         "--log", log.path(percentEncoded: false),
                         "--pipe-fd", String(readFD)] + extraArguments
        let pid: pid_t
        do {
            pid = try spawnProcess(path: executable.path(percentEncoded: false), arguments: arguments,
                                   environment: environment, inheritedFDs: [readFD])
        } catch {
            close(readFD)
            close(writeFD)
            throw error
        }
        close(readFD)
        return GuardProcess(pid: pid, writeFD: writeFD)
    }

    /// Writes one line; false when the pipe is gone or full (the guard is dead or hung — never blocks).
    @discardableResult
    static func write(_ line: String, to fd: Int32) -> Bool {
        let bytes = Array(line.utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        return written == bytes.count
    }

    /// `waitpid(pid, WNOHANG)`: true when the guard has exited (and is now reaped).
    static func hasExited(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        return result == pid || (result == -1 && errno == ECHILD)
    }

    /// posix_spawn with /dev/null stdio, a new session, close-on-exec by default except `inheritedFDs`, and
    /// default signal dispositions and an empty mask.
    static func spawnProcess(path: String, arguments: [String], environment: [String: String],
                             inheritedFDs: [Int32] = []) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        for fd in inheritedFDs { posix_spawn_file_actions_addinherit_np(&actions, fd) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGPIPE, SIGCHLD, SIGALRM, SIGUSR1, SIGUSR2] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        posix_spawnattr_setflags(&attributes, Int16(flags))

        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attributes, &argv, &envp)
        guard rc == 0 else { throw SideEffectError.failed("posix_spawn \(path): \(String(cString: strerror(rc)))") }
        return pid
    }
}
