import Darwin
import Foundation

/// T3 process registry + evidence sampling (brief §5.3–5.4) and the pausing topology (§6.3).
/// Implemented by `KakurenekoProcesses.ProcessScanner`.
///
/// Isolation: `final class … : Sendable` with Mutex-protected caches (identity → argv/path cache,
/// CPU history, descendant history). `sample` and `topology` are `@concurrent` (syscall-heavy;
/// must never run on the main actor). The coordinator drives the cadence (5 s lid closed / 15 s open).
public protocol ProcessSampling: Sendable {
    /// Starts background helpers (FSEvents for E3, periodic model-API IP resolution for E4). Idempotent.
    func start() async
    func stop() async
    /// One scan: cheap pass over all same-uid pids (`proc_listallpids` + `PROC_PIDT_SHORTBSDINFO`),
    /// argv/path only for new identities (cache by `(pid, startSec, startUsec)`), signature match,
    /// descendants, ancestry, host app, and evidence E1–E6 for matched agents. From `KERN_PROCARGS2` it reads
    /// argv plus ONLY the env allow-list `VSCODE_ESM_ENTRYPOINT`, `__CFBundleIdentifier`, `TERM_PROGRAM`,
    /// `CLAUDE_CODE_ENTRYPOINT` (into `ProcessDescriptor.environment`; never stored or logged otherwise).
    func sample(now: Date) async -> ProcessSnapshot
    /// Expensive (~60 ms): pty-master holders (P-A2), ancestors (P-A3), agent-launched apps (P-B), IPC
    /// peers and listeners (P-C/P-D), automation helpers (P-E). Called only when pausing / re-checking.
    func topology(for snapshot: ProcessSnapshot, now: Date) async -> AgentTopology
    /// Paths whose writes count as E3 progress per agent process (refreshed by the coordinator from sessions).
    func updateSessionStoreHints(_ hints: [SessionStoreHint]) async
}

/// Point lookups of live process identity (liveness checks for Claude records, guard, journal).
/// Implemented by `KakurenekoProcesses.LiveProcessLookup` (which may wrap `KernelProcessLookup`). Synchronous, cheap.
public protocol ProcessLookup: Sendable {
    /// Identity of the live process `pid` (nil if no such process). `uniqueID`/`pidVersion` may be nil.
    func identity(of pid: Int32) -> ProcessIdentity?
}

/// The reference identity lookup (§8 invariant: hook, scanner, lookup and journal all produce the SAME
/// `(pid, startSec, startUsec)` tuple): `sysctl({CTL_KERN, KERN_PROC, KERN_PROC_PID, pid})` →
/// `kinfo_proc.kp_proc.p_starttime`. Works for every pid (also root-owned). `uniqueID`/`pidVersion` are left nil
/// (KakurenekoPause enriches them with flavor 17 / the audit token before journaling or signalling).
/// Used by `kakureneko-guard`, KakurenekoPause and tests; `KakurenekoProcesses.LiveProcessLookup` may wrap it.
public struct KernelProcessLookup: ProcessLookup {
    public init() {}

    public func identity(of pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, 4, &info, &size, nil, 0) }
        guard rc == 0, size >= MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return ProcessIdentity(pid: pid, startSec: Int64(start.tv_sec), startUsec: Int32(start.tv_usec))
    }

    /// Parent pid (`kp_eproc.e_ppid`), nil when gone.
    public func parentPID(of pid: Int32) -> Int32? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, 4, &info, &size, nil, 0) }
        guard rc == 0, size >= MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else { return nil }
        return info.kp_eproc.e_ppid
    }
}

extension ProcessLookup {
    /// True if `identity` is still the same live process (pid + start time match).
    public func isAlive(_ identity: ProcessIdentity) -> Bool { self.identity(of: identity.pid) == identity }
}
