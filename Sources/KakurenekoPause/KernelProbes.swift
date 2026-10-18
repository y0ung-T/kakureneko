import Darwin
import KakurenekoKit
import Foundation

// Read-only kernel probes used by grouping, protection rules, enrichment, the signaller and the guard.
// Every function here is synchronous, allocation-light and safe to call for any pid (failures → nil).
// Nothing in this file mutates another process.

/// One row of the kernel process table (`sysctl {CTL_KERN, KERN_PROC, KERN_PROC_ALL}` → `kinfo_proc`).
/// `kinfo_proc` works for every pid (also root-owned `login`), unlike `PROC_PIDTBSDINFO` (R08 §7).
struct ProcessEntry: Sendable, Hashable {
    var pid: pid_t
    var ppid: pid_t
    /// Effective uid (`kp_eproc.e_ucred.cr_uid`).
    var uid: uid_t
    /// Real uid (`kp_eproc.e_pcred.p_ruid`).
    var realUID: uid_t
    var startSec: Int64
    var startUsec: Int32
    /// Controlling tty (`kp_eproc.e_tdev`); nil when `NODEV` (no controlling terminal).
    var ttyDevice: Int32?
    /// `kp_proc.p_stat` (`SSTOP` = 4, `SZOMB` = 5).
    var stat: Int8
    /// `kp_proc.p_flag` (`P_TRACED` = 0x800).
    var flags: Int32

    init(pid: pid_t, ppid: pid_t, uid: uid_t, realUID: uid_t? = nil, startSec: Int64, startUsec: Int32,
         ttyDevice: Int32? = nil, stat: Int8 = 2, flags: Int32 = 0) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.realUID = realUID ?? uid
        self.startSec = startSec
        self.startUsec = startUsec
        self.ttyDevice = ttyDevice
        self.stat = stat
        self.flags = flags
    }

    /// (pid, start) identity — the §8 tuple (un-enriched).
    var identity: ProcessIdentity { ProcessIdentity(pid: pid, startSec: startSec, startUsec: startUsec) }
    var isStopped: Bool { Int32(stat) == SSTOP }
    var isZombie: Bool { Int32(stat) == SZOMB }
    var isTraced: Bool { flags & P_TRACED != 0 }
    var hasControllingTTY: Bool { ttyDevice != nil }
    /// Same user in both effective and real uid (the group formula's `uid == me`).
    func isOwned(by uid: uid_t) -> Bool { self.uid == uid && realUID == uid }
}

/// An immutable snapshot of the process table with a parent → children index.
struct ProcessTable: Sendable {
    let entries: [pid_t: ProcessEntry]
    private let childrenByParent: [pid_t: [pid_t]]

    init(_ list: [ProcessEntry]) {
        var entries: [pid_t: ProcessEntry] = [:]
        var children: [pid_t: [pid_t]] = [:]
        entries.reserveCapacity(list.count)
        for entry in list {
            entries[entry.pid] = entry
            if entry.ppid != entry.pid { children[entry.ppid, default: []].append(entry.pid) }
        }
        for key in children.keys { children[key]?.sort() }
        self.entries = entries
        self.childrenByParent = children
    }

    static let empty = ProcessTable([])

    subscript(pid: pid_t) -> ProcessEntry? { entries[pid] }

    var pids: [pid_t] { entries.keys.sorted() }

    /// Every descendant of `root` by ppid (breadth-first, without `root`). Cycle-safe.
    func descendants(of root: pid_t) -> [pid_t] {
        var out: [pid_t] = []
        var seen: Set<pid_t> = [root]
        var queue = childrenByParent[root] ?? []
        var index = 0
        while index < queue.count {
            let pid = queue[index]
            index += 1
            guard seen.insert(pid).inserted else { continue }
            out.append(pid)
            queue.append(contentsOf: childrenByParent[pid] ?? [])
        }
        return out
    }

    /// The ancestor chain of `pid` (nearest first, up to but excluding pid 0). Cycle-safe.
    func ancestors(of pid: pid_t) -> [pid_t] {
        var out: [pid_t] = []
        var seen: Set<pid_t> = [pid]
        var current = entries[pid]?.ppid ?? 0
        while current > 0, seen.insert(current).inserted {
            out.append(current)
            current = entries[current]?.ppid ?? 0
        }
        return out
    }
}

/// `proc_uniqidentifierinfo` (private flavor `PROC_PIDUNIQIDENTIFIERINFO` = 17, xnu `proc_info_private.h`).
/// Layout verified by R06 `identity.swift` (56 bytes; `p_idversion` == audit token `val[7]`).
private struct UniqueIdentifierInfo {
    var uuid: (UInt64, UInt64) = (0, 0)
    var uniqueID: UInt64 = 0
    var parentUniqueID: UInt64 = 0
    var idVersion: Int32 = 0
    var originalParentIDVersion: Int32 = 0
    var reserved2: UInt64 = 0
    var reserved3: UInt64 = 0
}

/// Kernel probes. All read-only.
enum Kernel {
    /// Private `PROC_PIDUNIQIDENTIFIERINFO`.
    static let flavorUniqueIdentifierInfo: Int32 = 17
    /// Private `PROC_PIDCOALITIONINFO` (`struct proc_pidcoalitioninfo { uint64_t coalition_id[2]; uint64_t reserved[3]; }`).
    static let flavorCoalitionInfo: Int32 = 20
    /// Private `PROC_FLAG_DARWINBG` (internal darwinbg request, the process asked for it itself).
    static let procFlagDarwinBG: UInt32 = 0x8000
    /// Private `PROC_FLAG_EXT_DARWINBG` (EXTERNAL darwinbg — what `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)`
    /// from another process sets). Verified on macOS 26.6: set → bit appears, `setpriority(…, 0)` → bit clears, while
    /// `getpriority(PRIO_DARWIN_PROCESS, otherPid)` keeps returning 0 (it reports the target's INTERNAL request only).
    static let procFlagExternalDarwinBG: UInt32 = 0x10000

    // MARK: Process table

    /// The whole process table (`KERN_PROC_ALL`), nil if the sysctl keeps failing.
    static func processTable() -> ProcessTable? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<4 {
            var size = 0
            guard mib.withUnsafeMutableBufferPointer({ sysctl($0.baseAddress, 3, nil, &size, nil, 0) }) == 0 else { return nil }
            size += 64 * stride
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
            let rc = buffer.withUnsafeMutableBytes { raw in
                mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, 3, raw.baseAddress, &size, nil, 0) }
            }
            if rc != 0 {
                if errno == ENOMEM { continue }
                return nil
            }
            let count = size / stride
            return ProcessTable(buffer.prefix(count).compactMap { entry(from: $0) })
        }
        return nil
    }

    /// `kinfo_proc` of one pid (works for every uid).
    static func kinfo(of pid: pid_t) -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, 4, &info, &size, nil, 0) }
        guard rc == 0, size >= MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else { return nil }
        return info
    }

    /// Table row of one pid.
    static func entry(of pid: pid_t) -> ProcessEntry? { kinfo(of: pid).flatMap(entry(from:)) }

    static func entry(from info: kinfo_proc) -> ProcessEntry? {
        let pid = info.kp_proc.p_pid
        guard pid > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let tdev = info.kp_eproc.e_tdev
        return ProcessEntry(
            pid: pid,
            ppid: info.kp_eproc.e_ppid,
            uid: info.kp_eproc.e_ucred.cr_uid,
            realUID: info.kp_eproc.e_pcred.p_ruid,
            startSec: Int64(start.tv_sec),
            startUsec: Int32(start.tv_usec),
            ttyDevice: tdev == -1 ? nil : tdev,
            stat: info.kp_proc.p_stat,
            flags: info.kp_proc.p_flag
        )
    }

    /// `p_stat == SSTOP`.
    static func isStopped(_ pid: pid_t) -> Bool { entry(of: pid)?.isStopped ?? false }

    // MARK: Identity enrichment

    /// `(p_uniqueid, p_idversion)` from flavor 17 (same-user check exempt in xnu).
    static func uniqueIdentifier(of pid: pid_t) -> (uniqueID: UInt64, idVersion: UInt32)? {
        guard pid > 0 else { return nil }
        var info = UniqueIdentifierInfo()
        let size = Int32(MemoryLayout<UniqueIdentifierInfo>.size)
        guard proc_pidinfo(pid, flavorUniqueIdentifierInfo, 0, &info, size) == size else { return nil }
        return (info.uniqueID, UInt32(bitPattern: info.idVersion))
    }

    /// Fresh audit token via `task_name_for_pid` + `task_info(TASK_AUDIT_TOKEN)` (R06 §2.4). nil when not permitted
    /// (e.g. another user's process, or a hardened-runtime restriction) or gone.
    static func auditToken(of pid: pid_t) -> audit_token_t? {
        guard pid > 0 else { return nil }
        var name: mach_port_name_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &name) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, name) }
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(name, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS, Int32(bitPattern: token.val.5) == pid else { return nil }
        return token
    }

    /// A token carrying only pid (`val[5]`) and pidversion (`val[7]`). `proc_signal_with_audittoken` resolves the
    /// target from exactly these two fields and rejects a stale pidversion with `ESRCH` (verified on macOS 26.6), so
    /// it is as race-free as a fetched token. Used only when `task_name_for_pid` is refused.
    static func synthesizedToken(pid: pid_t, pidVersion: UInt32) -> audit_token_t {
        var token = audit_token_t()
        token.val.5 = UInt32(bitPattern: pid)
        token.val.7 = pidVersion
        return token
    }

    /// Adds `uniqueID` (flavor 17) and `pidVersion` (fresh audit token `val[7]`, or flavor 17's `p_idversion` when
    /// the token is refused) to `identity`, after checking the live start time. nil when the process is gone, its
    /// start time differs (pid reused) or the two pidversion sources disagree.
    static func enrich(_ identity: ProcessIdentity) -> ProcessIdentity? {
        guard let live = entry(of: identity.pid), live.identity == identity, !live.isZombie,
              let unique = uniqueIdentifier(of: identity.pid) else { return nil }
        var pidVersion = unique.idVersion
        if let token = auditToken(of: identity.pid) {
            guard token.val.7 == unique.idVersion else { return nil }
            pidVersion = token.val.7
        }
        if let known = identity.uniqueID, known != unique.uniqueID { return nil }
        if let known = identity.pidVersion, known != pidVersion { return nil }
        // Re-check the start time AFTER reading the ids: a reuse between the two reads would show here.
        guard entry(of: identity.pid)?.identity == identity else { return nil }
        var enriched = identity
        enriched.uniqueID = unique.uniqueID
        enriched.pidVersion = pidVersion
        return enriched
    }

    // MARK: BSD info

    /// `proc_bsdinfo.pbi_flags` (same-user processes only).
    static func bsdFlags(of pid: pid_t) -> UInt32? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_flags
    }

    /// `PROC_FLAG_TRACED` in `pbi_flags`, falling back to `P_TRACED` in `kinfo_proc`.
    static func isTraced(_ pid: pid_t) -> Bool {
        if let flags = bsdFlags(of: pid) { return flags & UInt32(PROC_FLAG_TRACED) != 0 }
        return entry(of: pid)?.isTraced ?? false
    }

    /// External darwinbg state (`PROC_FLAG_EXT_DARWINBG`), nil when unreadable.
    static func isExternallyDarwinBackground(_ pid: pid_t) -> Bool? {
        bsdFlags(of: pid).map { $0 & procFlagExternalDarwinBG != 0 }
    }

    /// Whether `pid` runs in darwinbg for any reason: external (`setpriority` from another process: App Tamer,
    /// `taskpolicy -b -p`, Kakureneko), internal (the process asked itself), or `getpriority(PRIO_DARWIN_PROCESS) == 1`.
    /// `getpriority` alone is NOT enough: for another pid it reports only the internal request (verified on macOS
    /// 26.6 — it stays 0 after an external `PRIO_DARWIN_BG`), so the `pbi_flags` bits are authoritative.
    /// nil when the flags are unreadable (gone, or another user's process).
    static func isDarwinBackground(_ pid: pid_t) -> Bool? {
        guard let flags = bsdFlags(of: pid) else { return nil }
        if flags & (procFlagExternalDarwinBG | procFlagDarwinBG) != 0 { return true }
        errno = 0
        let priority = getpriority(PRIO_DARWIN_PROCESS, id_t(pid))
        return errno == 0 && priority == 1
    }

    /// `proc_pidpath`.
    static func executablePath(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Resource coalition id (private flavor 20), nil/0 when unavailable.
    static func coalitionID(of pid: pid_t) -> UInt64? {
        guard pid > 0 else { return nil }
        var buffer = [UInt64](repeating: 0, count: 5)
        let size = Int32(buffer.count * MemoryLayout<UInt64>.size)
        let rc = buffer.withUnsafeMutableBytes { proc_pidinfo(pid, flavorCoalitionInfo, 0, $0.baseAddress, size) }
        guard rc == size, buffer[0] != 0 else { return nil }
        return buffer[0]
    }

    /// `PROC_DIRTY_TRACKED` (`<sys/proc_info.h>`): the process uses sudden-termination dirty tracking.
    static let dirtyTracked: UInt32 = 0x1
    /// `PROC_DIRTY_IS_DIRTY`: the process currently has unsaved state.
    static let dirtyIsDirty: UInt32 = 0x4

    /// Quit-mode safety (R06 §1.4): TRACKED && !IS_DIRTY = "clean, quitting is safe".
    static func isCleanForQuit(dirtyFlags flags: UInt32?) -> Bool {
        guard let flags else { return false }
        return flags & dirtyTracked != 0 && flags & dirtyIsDirty == 0
    }

    /// `proc_get_dirty` flags (`PROC_DIRTY_TRACKED` 0x1, `PROC_DIRTY_IS_DIRTY` 0x4), nil on error.
    static func dirtyFlags(of pid: pid_t) -> UInt32? {
        guard pid > 0 else { return nil }
        var flags: UInt32 = 0
        return proc_get_dirty(pid, &flags) == 0 ? flags : nil
    }

    // MARK: CPU

    /// Mach timebase (ticks → ns). `ri_user_time`/`ri_system_time` are mach ticks on Apple Silicon (R08 §7).
    static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return (1, 1) }
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    /// Cumulative user + system CPU time in nanoseconds (`proc_pid_rusage` V4), nil on error.
    static func cpuNanoseconds(of pid: pid_t) -> UInt64? {
        guard pid > 0 else { return nil }
        var usage = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return nil }
        let ticks = usage.ri_user_time &+ usage.ri_system_time
        let (numer, denom) = timebase
        return ticks.multipliedFullWidth(by: numer).high == 0 ? ticks * numer / denom : ticks / denom * numer
    }

    // MARK: File descriptors

    /// Paths of the vnode file descriptors of `pid` (same-user only). Empty on error.
    static func openVnodePaths(of pid: pid_t, limit: Int = 4096) -> [String] {
        guard pid > 0 else { return [] }
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: min(Int(needed) / stride + 16, limit))
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        var paths: [String] = []
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw -> String in
                let bytes = raw.bindMemory(to: UInt8.self)
                let end = bytes.firstIndex(of: 0) ?? bytes.count
                return String(decoding: bytes[..<end], as: UTF8.self)
            }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }

    // MARK: System

    /// `kern.bootsessionuuid`.
    static func bootSessionUUID() -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        var length = buffer.count
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &length, nil, 0) == 0 else { return nil }
        let value = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    /// `kern.memorystatus_vm_pressure_level` (1 normal, 2 warning, 4 critical), nil on error.
    static func memoryPressureLevel() -> Int32? {
        var level: Int32 = 0
        var length = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &length, nil, 0) == 0 else { return nil }
        return level
    }

    /// Uptime that excludes system sleep (`CLOCK_UPTIME_RAW`), in nanoseconds.
    static func uptimeNanoseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}

extension ProcessIdentity {
    /// Both enrichment fields are present (the only identities that may be journaled or paused).
    var isEnriched: Bool { pidVersion != nil && uniqueID != nil }
}
