import KakurenekoKit
import Foundation

/// One row of the cheap pass (`proc_listallpids` + `PROC_PIDT_SHORTBSDINFO` for every pid, plus
/// `PROC_PIDTBSDINFO` for same-uid pids).
struct ProcessRow: Sendable, Hashable {
    var pid: Int32
    var ppid: Int32
    var uid: UInt32
    /// `p_comm` (≤ 16 chars; Claude Code's is its version string — never match on it alone).
    var comm: String
    /// `p_stat` (`SZOMB` = 5).
    var status: UInt32
    /// `pbi_flags` / `pbsi_flags` (`PROC_FLAG_*`).
    var flags: UInt32
    /// Start-time identity: filled for same-uid rows by the cheap pass; other users' rows (root `login`, `sshd`)
    /// resolve it on demand through `ProcessProbing.identity(of:)` (`sysctl KERN_PROC_PID`).
    var identity: ProcessIdentity?
    /// Controlling tty (`e_tdev`), nil = none (or unknown for other users' rows).
    var tdev: Int32?

    init(pid: Int32, ppid: Int32, uid: UInt32, comm: String = "", status: UInt32 = 2, flags: UInt32 = 0,
         identity: ProcessIdentity? = nil, tdev: Int32? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.comm = comm
        self.status = status
        self.flags = flags
        self.identity = identity
        self.tdev = tdev
    }

    var isZombie: Bool { status == LibProc.zombieStatus }
}

/// A point-in-time process table with parent/child links (pure; built by the live probe or by tests).
struct ProcessTable: Sendable {
    let currentUID: UInt32
    let rows: [Int32: ProcessRow]
    /// ppid → children pids (sorted), zombies excluded.
    let children: [Int32: [Int32]]

    /// Ancestor walks stop after this many levels (guards against corrupt ppid loops).
    static let maxAncestorDepth = 64

    init(currentUID: UInt32, rows: [ProcessRow]) {
        self.currentUID = currentUID
        var byPID: [Int32: ProcessRow] = [:]
        byPID.reserveCapacity(rows.count)
        for row in rows where row.pid > 0 { byPID[row.pid] = row }
        self.rows = byPID
        var children: [Int32: [Int32]] = [:]
        for row in byPID.values where !row.isZombie && row.ppid != row.pid {
            children[row.ppid, default: []].append(row.pid)
        }
        for key in children.keys { children[key]?.sort() }
        self.children = children
    }

    static let empty = ProcessTable(currentUID: getuid(), rows: [])

    subscript(pid: Int32) -> ProcessRow? { rows[pid] }

    /// Same-uid, non-zombie rows that carry an identity.
    var sameUIDRows: [ProcessRow] {
        rows.values.filter { $0.uid == currentUID && !$0.isZombie && $0.identity != nil }
    }

    /// True when `identity` is a live row of this table.
    func contains(_ identity: ProcessIdentity) -> Bool {
        rows[identity.pid]?.identity == identity
    }

    /// Every descendant pid of `pid` (any uid, zombies excluded), breadth first, sorted by pid.
    func descendants(of pid: Int32) -> [Int32] {
        var result: [Int32] = []
        var visited: Set<Int32> = [pid]
        var queue = children[pid] ?? []
        var head = 0
        while head < queue.count {
            let next = queue[head]
            head += 1
            guard visited.insert(next).inserted else { continue }
            result.append(next)
            queue.append(contentsOf: children[next] ?? [])
        }
        return result.sorted()
    }

    /// Ancestor pids of `pid`, nearest first, stopping before launchd (1) and the kernel (0).
    func ancestors(of pid: Int32) -> [Int32] {
        var result: [Int32] = []
        var visited: Set<Int32> = [pid]
        var current = rows[pid]?.ppid ?? 0
        while current > 1, result.count < Self.maxAncestorDepth, visited.insert(current).inserted,
              let row = rows[current] {
            result.append(current)
            current = row.ppid
        }
        return result
    }
}
