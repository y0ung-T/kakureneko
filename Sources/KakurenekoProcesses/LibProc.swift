import Darwin
import Foundation

/// Thin, strictly read-only wrappers over libproc and `sysctl` (R08 §7, R06 §2–3).
///
/// Every function returns `nil` (or an empty result) when the process is gone or the call is not permitted.
/// Nothing here signals, renices or otherwise mutates any process.
enum LibProc {
    /// `NODEV` as stored in `proc_bsdinfo.e_tdev` (no controlling tty).
    static let noDevice: UInt32 = 0xFFFF_FFFF
    /// `p_stat` value of a zombie (`SZOMB`).
    static let zombieStatus: UInt32 = 5
    /// Private `PROC_PIDUNIQIDENTIFIERINFO` flavor (xnu `proc_info_private.h`); exempt from the same-user check.
    static let uniqueIdentifierFlavor: Int32 = 17
    /// `sizeof(struct proc_uniqidentifierinfo)`: uuid[16], p_uniqueid, p_puniqueid, p_idversion, p_orig_ppidversion,
    /// two reserved u64 (verified on macOS 26: 56 bytes, `p_idversion` == audit token `val[7]`).
    static let uniqueIdentifierSize = 56

    // MARK: Process list and BSD info

    /// Every pid on the system (`proc_listallpids`), excluding 0.
    static func listAllPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 128)
        let count = pids.withUnsafeMutableBytes { raw in
            proc_listallpids(raw.baseAddress, Int32(raw.count))
        }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    /// `PROC_PIDT_SHORTBSDINFO` — works for every pid (other users' too): ppid, uid, comm, status, flags.
    static func shortInfo(_ pid: Int32) -> proc_bsdshortinfo? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    /// `PROC_PIDTBSDINFO` — same-uid processes only (EPERM otherwise): adds start time and `e_tdev`.
    static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    /// `proc_pidpath` (nil for a binary replaced by an auto-update, or when the call fails).
    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = string(fromCChars: buffer.prefix(Int(length)))
        return path.isEmpty ? nil : path
    }

    /// `proc_pid_rusage(RUSAGE_INFO_V4)` user + system time in Mach absolute-time ticks (NOT nanoseconds on Apple
    /// Silicon; multiply by `MachTimebase`). Same-uid only.
    static func cpuTicks(_ pid: Int32) -> UInt64? {
        var usage = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return nil }
        return usage.ri_user_time &+ usage.ri_system_time
    }

    /// Current working directory (`PROC_PIDVNODEPATHINFO` → `pvi_cdir.vip_path`).
    static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { string(fromBytes: $0) }
        return path.isEmpty ? nil : path
    }

    /// `p_uniqueid` and `p_idversion` (flavor 17). Works for every pid.
    static func uniqueIdentifier(_ pid: Int32) -> (uniqueID: UInt64, pidVersion: UInt32)? {
        var buffer = [UInt8](repeating: 0, count: uniqueIdentifierSize)
        let size = Int32(uniqueIdentifierSize)
        let rc = buffer.withUnsafeMutableBytes { proc_pidinfo(pid, uniqueIdentifierFlavor, 0, $0.baseAddress, size) }
        guard rc == size else { return nil }
        return buffer.withUnsafeBytes { raw in
            let unique = raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
            let version = raw.loadUnaligned(fromByteOffset: 32, as: UInt32.self)
            return unique == 0 ? nil : (unique, version)
        }
    }

    // MARK: File descriptors

    /// Outcome of listing a process's file descriptors.
    enum FDListResult {
        case descriptors([proc_fdinfo])
        /// The process exited (ESRCH) — not a probe failure.
        case gone
        /// Any other error (EPERM, …) — the caller marks its result incomplete.
        case failed(Int32)
    }

    /// `PROC_PIDLISTFDS`.
    static func fileDescriptors(_ pid: Int32) -> FDListResult {
        errno = 0
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        if needed <= 0 {
            let error = errno
            if error == 0 { return .descriptors([]) }
            return error == ESRCH ? .gone : .failed(error)
        }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 32)
        errno = 0
        let got = fds.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        if got <= 0 {
            let error = errno
            if error == 0 { return .descriptors([]) }
            return error == ESRCH ? .gone : .failed(error)
        }
        return .descriptors(Array(fds.prefix(Int(got) / stride)))
    }

    /// `PROC_PIDFDVNODEPATHINFO`: vnode path and `vst_rdev`.
    static func vnodePath(pid: Int32, fd: Int32) -> (path: String, rdev: UInt32)? {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvip.vip_path) { string(fromBytes: $0) }
        return (path, info.pvip.vip_vi.vi_stat.vst_rdev)
    }

    /// `PROC_PIDFDSOCKETINFO`.
    static func socketInfo(pid: Int32, fd: Int32) -> socket_fdinfo? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { return nil }
        return info
    }

    /// `PROC_PIDFDPIPEINFO`.
    static func pipeInfo(pid: Int32, fd: Int32) -> pipe_fdinfo? {
        var info = pipe_fdinfo()
        let size = Int32(MemoryLayout<pipe_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDPIPEINFO, &info, size) == size else { return nil }
        return info
    }

    // MARK: TTY

    /// `devname_r(dev, S_IFCHR)` → `ttys004` (thread-safe variant of `devname`).
    static func deviceName(_ device: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            devname_r(dev_t(device), mode_t(S_IFCHR), pointer.baseAddress, Int32(pointer.count))
        }
        guard result != nil else { return nil }
        let name = string(fromCChars: buffer[...])
        // devname_r answers "??" when the device has no node in /dev.
        guard !name.isEmpty, name != "??" else { return nil }
        return name
    }

    /// `st_mtime` of a file (`stat`, follows symlinks).
    static func modificationDate(path: String) -> Date? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let spec = info.st_mtimespec
        return Date(timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1_000_000_000)
    }

    // MARK: Strings

    /// NUL-terminated bytes → String (invalid UTF-8 replaced).
    static func string(fromBytes raw: UnsafeRawBufferPointer) -> String {
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// NUL-terminated `CChar`s → String.
    static func string<C: Collection<CChar>>(fromCChars chars: C) -> String {
        String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// A fixed-size C `char[N]` tuple (e.g. `pbi_comm`) → String.
    static func string<T>(fromTuple tuple: T) -> String {
        withUnsafeBytes(of: tuple) { string(fromBytes: $0) }
    }
}

/// `mach_timebase_info` (125/3 on Apple Silicon: rusage times are ticks of 41.67 ns, R08 §7).
struct MachTimebase: Sendable, Hashable {
    let numer: UInt32
    let denom: UInt32

    static let current: MachTimebase = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return MachTimebase(numer: 1, denom: 1) }
        return MachTimebase(numer: info.numer, denom: info.denom)
    }()

    /// Ticks → seconds.
    func seconds(fromTicks ticks: UInt64) -> Double {
        Double(ticks) * Double(numer) / Double(denom) / 1_000_000_000
    }
}
