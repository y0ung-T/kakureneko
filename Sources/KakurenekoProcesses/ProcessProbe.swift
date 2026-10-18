import Darwin
import KakurenekoKit
import Foundation
import IOKit.pwr_mgt

/// Every system read the scanner performs, behind one seam so the scan pipeline can be tested over synthetic
/// process tables. The live implementation is strictly read-only (libproc, sysctl, IOPM assertion listing, stat).
protocol ProcessProbing: Sendable {
    /// The cheap pass: every pid with ppid/uid/comm/status, start time and tty for same-uid pids. nil = failed.
    func readTable() -> ProcessTable?
    /// `sysctl(KERN_PROC_PID)` identity of any pid (other users' too). nil when gone.
    func identity(of pid: Int32) -> ProcessIdentity?
    /// `proc_pidpath`.
    func executablePath(of pid: Int32) -> String?
    /// `KERN_PROCARGS2` (argv + allow-listed env), using the caller's per-scan reader.
    func arguments(of pid: Int32, reader: inout ProcArgsReader) -> ProcArguments?
    /// Cumulative user+system CPU seconds (`proc_pid_rusage` V4 ticks × timebase).
    func cpuSeconds(of pid: Int32) -> Double?
    /// Current working directory.
    func workingDirectory(of pid: Int32) -> String?
    /// `p_uniqueid` / `p_idversion` (flavor 17).
    func uniqueIdentifier(of pid: Int32) -> (uniqueID: UInt64, pidVersion: UInt32)?
    /// Decoded descriptors of the requested kinds.
    func fileDescriptors(of pid: Int32, kinds: FDKinds) -> FDReadResult
    /// `IOPMCopyAssertionsByProcess` (owner pid → assertions). nil = failed.
    func powerAssertions() -> [Int32: [PowerAssertionInfo]]?
    /// `devname(tdev)` and the `st_mtime` of `/dev/<name>`.
    func terminal(device: Int32) -> (name: String, modified: Date?)?
    /// Real wall-clock time (process start times are real; `sample(now:)` may be synthetic in tests).
    func wallClockNow() -> Date
}

/// The production probe (R08 §7 verified calls). No state; safe to share.
struct LiveProcessProbe: ProcessProbing {
    func readTable() -> ProcessTable? {
        let me = getuid()
        let pids = LibProc.listAllPIDs()
        guard !pids.isEmpty else { return nil }
        var rows: [ProcessRow] = []
        rows.reserveCapacity(pids.count)
        for pid in pids {
            guard let short = LibProc.shortInfo(pid) else { continue }
            var row = ProcessRow(
                pid: pid,
                ppid: Int32(bitPattern: short.pbsi_ppid),
                uid: short.pbsi_uid,
                comm: LibProc.string(fromTuple: short.pbsi_comm),
                status: short.pbsi_status,
                flags: short.pbsi_flags
            )
            if short.pbsi_uid == me {
                // Same uid: start time + tty (TBSDINFO fails only if the process exited meanwhile).
                guard let info = LibProc.bsdInfo(pid) else { continue }
                row.ppid = Int32(bitPattern: info.pbi_ppid)
                row.status = info.pbi_status
                row.flags = info.pbi_flags
                row.identity = ProcessIdentity(
                    pid: pid, startSec: Int64(bitPattern: info.pbi_start_tvsec), startUsec: Int32(truncatingIfNeeded: info.pbi_start_tvusec))
                row.tdev = info.e_tdev == LibProc.noDevice ? nil : Int32(bitPattern: info.e_tdev)
            }
            rows.append(row)
        }
        return ProcessTable(currentUID: me, rows: rows)
    }

    func identity(of pid: Int32) -> ProcessIdentity? {
        KernelProcessLookup().identity(of: pid)
    }

    func executablePath(of pid: Int32) -> String? {
        LibProc.executablePath(pid)
    }

    func arguments(of pid: Int32, reader: inout ProcArgsReader) -> ProcArguments? {
        reader.read(pid: pid)
    }

    func cpuSeconds(of pid: Int32) -> Double? {
        LibProc.cpuTicks(pid).map { MachTimebase.current.seconds(fromTicks: $0) }
    }

    func workingDirectory(of pid: Int32) -> String? {
        LibProc.workingDirectory(pid)
    }

    func uniqueIdentifier(of pid: Int32) -> (uniqueID: UInt64, pidVersion: UInt32)? {
        LibProc.uniqueIdentifier(pid)
    }

    func fileDescriptors(of pid: Int32, kinds: FDKinds) -> FDReadResult {
        let descriptors: [proc_fdinfo]
        switch LibProc.fileDescriptors(pid) {
        case .gone: return .gone
        case .failed(let error): return .failed(error)
        case .descriptors(let list): descriptors = list
        }
        var entries: [FDEntry] = []
        for fd in descriptors {
            switch Int32(fd.proc_fdtype) {
            case PROX_FDTYPE_VNODE where kinds.contains(.ptyMasters):
                if let vnode = LibProc.vnodePath(pid: pid, fd: fd.proc_fd), vnode.path == "/dev/ptmx" {
                    entries.append(.ptyMaster(minor: deviceMinor(vnode.rdev)))
                }
            case PROX_FDTYPE_SOCKET where kinds.contains(.sockets):
                if let info = LibProc.socketInfo(pid: pid, fd: fd.proc_fd), let entry = Self.decodeSocket(info) {
                    entries.append(entry)
                }
            case PROX_FDTYPE_PIPE where kinds.contains(.pipes):
                if let info = LibProc.pipeInfo(pid: pid, fd: fd.proc_fd) {
                    entries.append(.pipe(handle: info.pipeinfo.pipe_handle, peer: info.pipeinfo.pipe_peerhandle))
                }
            default:
                continue
            }
        }
        return .entries(entries)
    }

    func powerAssertions() -> [Int32: [PowerAssertionInfo]]? {
        var reference: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&reference) == kIOReturnSuccess, let dictionary = reference?.takeRetainedValue()
        else { return nil }
        guard let byPID = dictionary as? [NSNumber: [[String: Any]]] else { return [:] }
        var result: [Int32: [PowerAssertionInfo]] = [:]
        for (pid, list) in byPID {
            result[pid.int32Value] = list.map {
                PowerAssertionInfo(type: $0["AssertType"] as? String ?? "", name: $0["AssertName"] as? String ?? "")
            }
        }
        return result
    }

    func terminal(device: Int32) -> (name: String, modified: Date?)? {
        guard let name = LibProc.deviceName(device) else { return nil }
        return (name, LibProc.modificationDate(path: "/dev/" + name))
    }

    func wallClockNow() -> Date { Date() }

    /// `socket_fdinfo` → `FDEntry` (TCP and Unix only).
    static func decodeSocket(_ info: socket_fdinfo) -> FDEntry? {
        let socket = info.psi
        switch socket.soi_kind {
        case Int32(SOCKINFO_TCP):
            let tcp = socket.soi_proto.pri_tcp
            let ini = tcp.tcpsi_ini
            let isV4 = ini.insi_vflag & UInt8(INI_IPV4) != 0
            let local = isV4 ? IPAddress(ini.insi_laddr.ina_46.i46a_addr4) : IPAddress(ini.insi_laddr.ina_6)
            let remote = isV4 ? IPAddress(ini.insi_faddr.ina_46.i46a_addr4) : IPAddress(ini.insi_faddr.ina_6)
            return .tcp(TCPSocketInfo(
                local: local,
                localPort: UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)),
                remote: remote,
                remotePort: UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport)),
                state: tcp.tcpsi_state
            ))
        case Int32(SOCKINFO_UN):
            let unix = socket.soi_proto.pri_un
            let path = withUnsafeBytes(of: unix.unsi_addr.ua_sun.sun_path) { LibProc.string(fromBytes: $0) }
            let peerPath = withUnsafeBytes(of: unix.unsi_caddr.ua_sun.sun_path) { LibProc.string(fromBytes: $0) }
            return .unixSocket(UnixSocketInfo(
                socket: socket.soi_so,
                peerSocket: unix.unsi_conn_so,
                path: path.isEmpty ? nil : path,
                peerPath: peerPath.isEmpty ? nil : peerPath,
                isListening: Int32(socket.soi_options) & SO_ACCEPTCONN != 0
            ))
        default:
            return nil
        }
    }
}
