import Darwin
import Dispatch
import KakurenekoKit
import Synchronization

/// The preallocated pid array walked by the crash handler — the ONE global mutable state allowed in the codebase
/// (ARCHITECTURE §5): a signal handler cannot allocate, lock or capture context.
///
/// Writers (`PauseManager`, under its own lock) store the pids of really SIGSTOPped members; the handler reads
/// `count` (acquire) and walks `pids[0..<count]`. During an update the handler may see a mix of the old and new
/// lists — every entry is a process that is or was just frozen, and SIGCONT to a running process is harmless.
enum CrashThawBuffer {
    static let capacity = 4096
    nonisolated(unsafe) static let pids: UnsafeMutablePointer<pid_t> = {
        let buffer = UnsafeMutablePointer<pid_t>.allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
        return buffer
    }()
    static let count = Atomic<Int>(0)

    /// Publishes `list` into the process-wide buffer.
    static func publish(_ list: [pid_t]) {
        store(list, into: pids, capacity: capacity, count: count)
    }

    /// Writes `list` (only pids > 1, at most `capacity`) into `buffer` and publishes the new count. Shrinks the
    /// count first so the handler never walks stale entries past the new end.
    static func store(_ list: [pid_t], into buffer: UnsafeMutablePointer<pid_t>, capacity: Int, count: borrowing Atomic<Int>) {
        let valid = Array(list.lazy.filter { $0 > 1 }.prefix(capacity))
        if valid.count < count.load(ordering: .acquiring) { count.store(valid.count, ordering: .releasing) }
        for (index, pid) in valid.enumerated() { buffer[index] = pid }
        count.store(valid.count, ordering: .releasing)
    }

    /// The published pids (diagnostics/tests).
    static func snapshot(of buffer: UnsafeMutablePointer<pid_t>, count: borrowing Atomic<Int>) -> [pid_t] {
        let n = count.load(ordering: .acquiring)
        return (0..<n).map { buffer[$0] }
    }

    /// The pids the handler must SIGCONT for `journal`: members of REAL (non-simulated) apps journaled as `.sigstop`,
    /// in journal order, without duplicates. Throttled and quit apps are left to the guard.
    static func pids(for journal: PauseJournal?) -> [pid_t] {
        guard let journal else { return [] }
        var seen: Set<pid_t> = []
        var result: [pid_t] = []
        for app in journal.realApps {
            for member in app.members where member.action == .sigstop && member.pid > 1 {
                if seen.insert(member.pid).inserted { result.append(member.pid) }
            }
        }
        return result
    }
}

/// The async-signal-safe crash handler for SEGV/BUS/ILL/ABRT/TRAP/FPE (brief §6.5 item 2). SIGTERM/INT/HUP/QUIT
/// belong to the coordinator. NEVER installed in a test process (tests use `kakureneko-guard --crash-selftest`).
enum CrashHandlers {
    static let signals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE]

    /// Alternate signal stack per thread that gets one (128 KiB+; the handler itself needs a few hundred bytes).
    static let alternateStackSize = max(Int(SIGSTKSZ), 256 << 10)

    /// Installs the `sigaction` handler for `signals` with `SA_ONSTACK`, and a preallocated alternate signal stack
    /// for the calling thread and the main thread: a stack overflow (deep recursion, a SwiftUI update loop) faults
    /// on the guard page, where the kernel cannot push a handler frame on the exhausted stack — without an alternate
    /// stack the SIGCONT loop never runs. Threads without one (GCD workers) use their own stack as before. Touches
    /// the lazily initialised globals first: their one-time initialisation is not async-signal-safe.
    static func install() {
        _ = CrashThawBuffer.capacity
        _ = CrashThawBuffer.pids
        _ = CrashThawBuffer.count.load(ordering: .relaxed)
        installAlternateStackForCurrentThread()
        if pthread_main_np() == 0 {
            DispatchQueue.main.async { CrashHandlers.installAlternateStackForCurrentThread() }
        }
        for sig in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { signal in CrashHandlers.handle(signal) }
            sigemptyset(&action.sa_mask)
            action.sa_flags = SA_ONSTACK
            _ = sigaction(sig, &action, nil)
        }
    }

    /// `sigaltstack` for the calling thread unless it already has one. The memory (mmap, never freed) is allocated
    /// here, never in the handler.
    static func installAlternateStackForCurrentThread() {
        var current = stack_t()
        guard sigaltstack(nil, &current) == 0, current.ss_flags & SS_DISABLE != 0 else { return }
        guard let memory = mmap(nil, alternateStackSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
              memory != MAP_FAILED else { return }
        var stack = stack_t(ss_sp: memory, ss_size: alternateStackSize, ss_flags: 0)
        if sigaltstack(&stack, nil) != 0 { munmap(memory, alternateStackSize) }
    }

    /// The handler body: SIGCONT every published pid (`kill` is the only raw kill allowed), restore the default
    /// disposition and re-raise so the process still crashes (and is reported) normally. No allocation, no locks.
    static func handle(_ signal: Int32) {
        let n = min(CrashThawBuffer.count.load(ordering: .acquiring), CrashThawBuffer.capacity)
        let pids = CrashThawBuffer.pids
        var index = 0
        while index < n {
            let pid = pids[index]
            if pid > 1 { _ = kill(pid, SIGCONT) }
            index += 1
        }
        _ = Darwin.signal(signal, SIG_DFL)
        _ = raise(signal)
    }
}

/// Where `PauseManager` keeps the crash-handler pid list. The live implementation is the process-wide
/// `CrashThawBuffer`; tests inject a recording fake so they never touch process-wide signal state.
protocol CrashThawPublishing: Sendable {
    func installHandlers()
    func publish(_ pids: [pid_t])
}

struct ProcessCrashThawBuffer: CrashThawPublishing {
    init() {}
    func installHandlers() { CrashHandlers.install() }
    func publish(_ pids: [pid_t]) { CrashThawBuffer.publish(pids) }
}
