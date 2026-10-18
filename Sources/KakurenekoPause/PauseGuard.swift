import Darwin
import KakurenekoKit
import Foundation

/// The `kakureneko-guard` program (contract: `Sources/KakurenekoGuard/main.swift` header; brief §6.5 item 3).
///
/// Lives in KakurenekoPause so it shares the exact thaw logic (`PauseRecovery`) and the crash handler with the app;
/// the executable's `main.swift` only calls `PauseGuard.run(arguments:)`. Always returns 0 (the hidden crash
/// self-test dies by its signal on purpose). Logs only to the `--log` file.
public enum PauseGuard {
    /// No `hb` line for this long (CLOCK_UPTIME_RAW, so system sleep does not count) = the app hangs.
    public static let defaultHangTimeout: Duration = .seconds(90)

    /// Runs the guard with `arguments` (`CommandLine.arguments`, program name first). Returns the exit status.
    public static func run(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        _ = signal(SIGPIPE, SIG_IGN)
        let parsed = Options.parse(Array(arguments.dropFirst()))
        let logURL: URL
        switch parsed {
        case .success(let options) where options.log != nil: logURL = options.log!
        case .failure(let failure) where failure.log != nil: logURL = failure.log!
        default: logURL = Paths.live(environment: environment).guardLogFile
        }
        let log = GuardLog(url: logURL)
        switch parsed {
        case .failure(let failure):
            log(.error, "bad arguments: \(failure.message)")
            return 0
        case .success(let options):
            switch options.command {
            case .watch(let pid):
                watch(pid: pid, options: options, log: log)
            case .recover:
                log(.notice, "one-shot recovery of \(options.journal.path(percentEncoded: false))\(options.dryRun ? " (dry-run)" : "")")
                _ = recover(options: options, mode: .appGone, log: log)
            case .crashSelfTest(let pids, let signalName):
                crashSelfTest(pids: pids, signalName: signalName, log: log)
            }
            return 0
        }
    }

    // MARK: - Options

    enum Command: Equatable {
        case watch(pid_t)
        case recover
        case crashSelfTest(pids: [pid_t], signal: String)
    }

    struct Options: Equatable {
        var command: Command
        var journal: URL
        var log: URL?
        var pipeFD: Int32?
        var dryRun = false
        var hangTimeout: Duration = PauseGuard.defaultHangTimeout

        struct Failure: Error, Equatable {
            var message: String
            var log: URL?
        }

        static func parse(_ arguments: [String]) -> Result<Options, Failure> {
            var watch: pid_t?
            var recover = false
            var crash = false
            var crashPIDs: [pid_t] = []
            var crashSignal = "abrt"
            var journal: URL?
            var log: URL?
            var pipeFD: Int32?
            var dryRun = false
            var hangTimeout = PauseGuard.defaultHangTimeout
            var index = 0
            func value() -> String? {
                index += 1
                return index < arguments.count ? arguments[index] : nil
            }
            func failure(_ message: String) -> Result<Options, Failure> { .failure(Failure(message: message, log: log)) }
            while index < arguments.count {
                let argument = arguments[index]
                switch argument {
                case "--watch":
                    guard let text = value(), let pid = pid_t(text), pid > 1 else { return failure("--watch needs a pid > 1") }
                    watch = pid
                case "--journal":
                    guard let path = value(), path.hasPrefix("/") else { return failure("--journal needs an absolute path") }
                    journal = URL(filePath: path, directoryHint: .notDirectory)
                case "--log":
                    guard let path = value(), path.hasPrefix("/") else { return failure("--log needs an absolute path") }
                    log = URL(filePath: path, directoryHint: .notDirectory)
                case "--pipe-fd":
                    guard let text = value(), let fd = Int32(text), fd >= 0 else { return failure("--pipe-fd needs a descriptor") }
                    pipeFD = fd
                case "--dry-run":
                    dryRun = true
                case "--recover":
                    recover = true
                case "--hang-timeout-ms": // hidden: tests shorten the 90 s hang timeout
                    guard let text = value(), let ms = Int64(text), ms > 0 else { return failure("--hang-timeout-ms needs a positive number") }
                    hangTimeout = .milliseconds(ms)
                case "--crash-selftest": // hidden: exercises the crash handler in this separate process
                    crash = true
                case "--pid":
                    guard let text = value(), let pid = pid_t(text), pid > 1 else { return failure("--pid needs a pid > 1") }
                    crashPIDs.append(pid)
                case "--signal":
                    guard let name = value() else { return failure("--signal needs a name") }
                    crashSignal = name.lowercased()
                default:
                    return failure("unknown argument \(argument)")
                }
                index += 1
            }
            if crash {
                return .success(Options(command: .crashSelfTest(pids: crashPIDs, signal: crashSignal),
                                        journal: journal ?? URL(filePath: "/dev/null"), log: log))
            }
            guard let journal else { return failure("--journal is required") }
            let command: Command
            if recover {
                command = .recover
            } else if let watch {
                command = .watch(watch)
            } else {
                return failure("either --watch <pid> or --recover is required")
            }
            return .success(Options(command: command, journal: journal, log: log, pipeFD: pipeFD, dryRun: dryRun,
                                    hangTimeout: hangTimeout))
        }
    }

    // MARK: - Watching

    enum PipeStatus: Equatable {
        case quiet
        case heartbeat
        case bye
        case closed
    }

    /// Accumulates pipe bytes into lines (`hb`, `bye`).
    struct LineBuffer {
        private var pending: [UInt8] = []

        /// Feeds `bytes`; returns the strongest status seen (`bye` beats `heartbeat`).
        mutating func feed(_ bytes: some Sequence<UInt8>) -> PipeStatus {
            pending.append(contentsOf: bytes)
            var status = PipeStatus.quiet
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: pending[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                pending.removeSubrange(...newline)
                if line == "bye" { return .bye }
                if line == "hb" { status = .heartbeat }
            }
            if pending.count > 4096 { pending.removeAll() } // garbage without newlines
            return status
        }
    }

    /// Reads everything available (non-blocking). `closed` = EOF without `bye`.
    static func drain(_ fd: Int32, into buffer: inout LineBuffer) -> PipeStatus {
        var result = PipeStatus.quiet
        var chunk = [UInt8](repeating: 0, count: 512)
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                switch buffer.feed(chunk.prefix(n)) {
                case .bye: return .bye
                case .heartbeat: result = .heartbeat
                default: break
                }
                continue
            }
            if n == 0 { return .closed }
            if errno == EINTR { continue }
            return result // EAGAIN: nothing more for now
        }
    }

    static func watch(pid: pid_t, options: Options, log: GuardLog) {
        let timeoutNanoseconds = UInt64(max(1, options.hangTimeout.timeInterval * 1e9))
        let hangText = describe(options.hangTimeout)
        log(.notice, "watching pid \(pid) (journal \(options.journal.path(percentEncoded: false)), hang timeout \(hangText)\(options.pipeFD == nil ? ", no heartbeat pipe" : "")\(options.dryRun ? ", dry-run" : ""))")
        let queue = kqueue()
        guard queue >= 0 else {
            log(.error, "kqueue failed (\(String(cString: strerror(errno)))); recovering now")
            _ = recover(options: options, mode: .appGone, log: log)
            return
        }
        defer { close(queue) }

        var processEvent = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
                                  fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        if kevent(queue, &processEvent, 1, nil, 0, nil) != 0 || KernelProcessLookup().identity(of: pid) == nil {
            log(.warning, "pid \(pid) is already gone; recovering")
            _ = recover(options: options, mode: .appGone, log: log)
            return
        }
        var buffer = LineBuffer()
        if let fd = options.pipeFD {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var readEvent = kevent(ident: UInt(fd), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD | EV_ENABLE),
                                   fflags: 0, data: 0, udata: nil)
            if kevent(queue, &readEvent, 1, nil, 0, nil) != 0 {
                log(.error, "cannot watch the heartbeat pipe (\(String(cString: strerror(errno)))); exit detection only")
            }
        }

        var lastBeat = Kernel.uptimeNanoseconds()
        var sawHeartbeat = false
        var events: [Darwin.kevent] = Array(repeating: Darwin.kevent(), count: 4)
        while true {
            var timeout = timespec(tv_sec: 1, tv_nsec: 0)
            if options.pipeFD != nil {
                let elapsed = Kernel.uptimeNanoseconds() &- lastBeat
                let remaining = elapsed >= timeoutNanoseconds ? 0 : timeoutNanoseconds - elapsed
                let wait = min(remaining, 1_000_000_000)
                timeout = timespec(tv_sec: Int(wait / 1_000_000_000), tv_nsec: Int(wait % 1_000_000_000))
            }
            let count = kevent(queue, nil, 0, &events, Int32(events.count), &timeout)
            if count < 0 {
                if errno == EINTR { continue }
                log(.error, "kevent failed (\(String(cString: strerror(errno)))); recovering now")
                _ = recover(options: options, mode: .appGone, log: log)
                return
            }
            var appGone = false
            for event in events.prefix(Int(count)) {
                if event.filter == Int16(EVFILT_READ), let fd = options.pipeFD {
                    switch drain(fd, into: &buffer) {
                    case .bye:
                        log(.notice, "bye received: exiting without recovery")
                        return
                    case .closed:
                        appGone = true
                    case .heartbeat:
                        lastBeat = Kernel.uptimeNanoseconds()
                        if !sawHeartbeat {
                            sawHeartbeat = true
                            log(.info, "first heartbeat received")
                        }
                    case .quiet:
                        break
                    }
                } else if event.filter == Int16(EVFILT_PROC) {
                    appGone = true
                }
            }
            if appGone {
                // `bye` may still sit in the pipe next to the exit notification.
                if let fd = options.pipeFD, drain(fd, into: &buffer) == .bye {
                    log(.notice, "bye received: exiting without recovery")
                    return
                }
                log(.warning, "pid \(pid) is gone without bye; recovering")
                _ = recover(options: options, mode: .appGone, log: log)
                return
            }
            if options.pipeFD != nil, Kernel.uptimeNanoseconds() &- lastBeat >= timeoutNanoseconds {
                if PauseRecovery.hasThawableRecords(PauseJournal.read(from: options.journal)) {
                    log(.warning, "no heartbeat for \(hangText): pid \(pid) hangs; thawing verified records and watching on")
                    _ = recover(options: options, mode: .hang, log: log)
                }
                lastBeat = Kernel.uptimeNanoseconds() // ignored while the journal is empty; re-armed after a hang thaw
            }
        }
    }

    /// `90 s`, or `300 ms` for the shortened test timeouts.
    static func describe(_ duration: Duration) -> String {
        let seconds = duration.timeInterval
        return seconds >= 1 ? "\(Int(seconds)) s" : "\(Int((seconds * 1000).rounded())) ms"
    }

    // MARK: - Recovery

    enum RecoveryMode {
        /// The app is gone (or one-shot `--recover`): thaw, then clear the journal (only failed undos stay).
        case appGone
        /// The app hangs: thaw, rewrite the journal WITHOUT the thawed records (simulated/terminate records stay).
        case hang
    }

    /// Holds the journal file lock from the read to the rewrite, so a record the resumed app appends meanwhile is
    /// never overwritten by a result computed from the older read (the app reconciles under the same lock).
    @discardableResult
    static func recover(options: Options, mode: RecoveryMode, log: GuardLog) -> Int {
        JournalFileLock.withLock(journal: options.journal) { recoverLocked(options: options, mode: mode, log: log) }
    }

    private static func recoverLocked(options: Options, mode: RecoveryMode, log: GuardLog) -> Int {
        guard let journal = PauseJournal.read(from: options.journal) else {
            log(.info, "no usable journal: nothing to thaw")
            return 0
        }
        let signaller: any ProcessSignalling = options.dryRun ? LoggingSignaller(log: log) : AuditTokenSignaller()
        let recovery = PauseRecovery(signaller: signaller, processes: KernelProcessLookup(), probe: LiveSystemProbe())
        let summary = recovery.thawAll(journal, keepUnsignalled: mode == .hang) { log(.info, $0) }
        log(.notice, "recovery: thawed \(summary.thawed), dropped \(summary.dropped), failed \(summary.failed)")
        guard !options.dryRun else {
            log(.notice, "dry-run: journal left unchanged")
            return summary.thawed
        }
        var next = journal
        next.apps = summary.remaining.filter { !$0.members.isEmpty }
        do {
            if next.apps.isEmpty && mode == .appGone {
                if unlink(options.journal.path(percentEncoded: false)) != 0, errno != ENOENT {
                    log(.error, "could not remove the journal: \(String(cString: strerror(errno)))")
                }
            } else {
                // After a hang the (still running) app re-reads the journal and treats missing records as thawed. An
                // EMPTY journal says "all thawed"; a missing file would make it rewrite its in-memory copy instead.
                try next.write(to: options.journal)
            }
        } catch {
            log(.error, "could not rewrite the journal: \(error)")
        }
        return summary.thawed
    }

    /// `--dry-run`: logs what would be undone, signals nothing.
    struct LoggingSignaller: ProcessSignalling {
        let log: GuardLog
        func send(_ signal: ProcessSignalKind, to target: ProcessIdentity) throws {
            log(.notice, "dry-run: would \(signal == .cont ? "SIGCONT" : "SIGSTOP") pid \(target.pid)")
        }
        func setDarwinBackground(_ enabled: Bool, for target: ProcessIdentity) throws {
            log(.notice, "dry-run: would \(enabled ? "throttle" : "unthrottle") pid \(target.pid)")
        }
        func isDarwinBackground(_ target: ProcessIdentity) -> Bool? { nil }
        func terminateApplication(_ target: ProcessIdentity) async throws {
            log(.notice, "dry-run: would quit pid \(target.pid)")
        }
        func relaunchApplication(at bundleURL: URL) async throws {
            log(.notice, "dry-run: would relaunch \(bundleURL.lastPathComponent)")
        }
    }

    // MARK: - Crash self-test

    /// Installs the real crash handler in THIS process, publishes `pids`, then dies by `signalName` (`abrt`, `segv`,
    /// `bus`, `ill`, `trap`, `fpe`, `fault` = a real invalid memory write, or `overflow` = unbounded recursion on the
    /// main thread until the stack guard page faults). The handler must SIGCONT the pids and re-raise, so the process
    /// terminates by that signal. Crash reporting is disabled for this process only.
    static func crashSelfTest(pids: [pid_t], signalName: String, log: GuardLog) {
        log(.notice, "crash self-test: \(pids.count) pid(s), dying by \(signalName)")
        let mask = exception_mask_t(EXC_MASK_CRASH) | exception_mask_t(EXC_MASK_CORPSE_NOTIFY)
        _ = task_set_exception_ports(mach_task_self_, mask, mach_port_t(MACH_PORT_NULL),
                                     exception_behavior_t(EXCEPTION_DEFAULT), thread_state_flavor_t(THREAD_STATE_NONE))
        CrashHandlers.install()
        CrashThawBuffer.publish(pids)
        let signals: [String: Int32] = ["abrt": SIGABRT, "segv": SIGSEGV, "bus": SIGBUS, "ill": SIGILL, "trap": SIGTRAP, "fpe": SIGFPE]
        if signalName == "fault" {
            let address = UnsafeMutablePointer<Int32>(bitPattern: 0x10)
            address?.pointee = 1
        } else if signalName == "overflow" {
            log(.notice, "crash self-test: recursed to depth \(overflowStack(1))")
        } else {
            _ = raise(signals[signalName] ?? SIGABRT)
        }
        log(.error, "crash self-test: still alive after \(signalName)")
    }

    /// Recurses until the stack is exhausted (each frame keeps a 512-byte buffer alive across the call, so the
    /// optimizer cannot turn it into a loop).
    @inline(never)
    static func overflowStack(_ depth: Int) -> Int {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 512) { buffer in
            buffer[0] = UInt8(truncatingIfNeeded: depth)
            buffer[511] = buffer[0] &+ 1
            return overflowStack(depth &+ 1) &+ Int(buffer[511])
        }
    }
}

/// The guard's only log destination: the `--log` file (no os_log, no `Paths.live()` when `--log` is given).
struct GuardLog: Sendable {
    let sink: FileLogSink

    init(url: URL) { sink = FileLogSink(url: url, minimumLevel: .debug) }

    func callAsFunction(_ level: LogLevel, _ message: String) {
        sink.write(level: level, category: .guardian, message: "[pid \(getpid())] \(message)")
    }
}
