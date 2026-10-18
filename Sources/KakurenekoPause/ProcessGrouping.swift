import Darwin
import KakurenekoKit
import Foundation

/// Finds every process that belongs to an app (brief §6.3, R06 §2):
/// `group = {main} ∪ {p : uid(p) == me ∧ responsible(p) == main}`.
///
/// Implementations: responsibility API (primary), resource coalition (fallback), ppid descendants (last resort).
/// Only processes owned by `uid` (effective AND real) are ever members: other users' processes are never signalled.
protocol ProcessGrouping: Sendable {
    var method: GroupingSelfTest.Method { get }
    /// Members per main pid: the main first (when owned by `uid`), then the others in ascending pid order.
    /// A main missing from `table` maps to `[]`.
    func groups(for mains: [pid_t], in table: ProcessTable, uid: uid_t) -> [pid_t: [pid_t]]
}

extension ProcessGrouping {
    /// Assembles `main + others` in the documented order.
    static func ordered(main: pid_t, others: [pid_t], table: ProcessTable, uid: uid_t) -> [pid_t] {
        guard let entry = table[main] else { return [] }
        let rest = others.filter { $0 != main }.sorted()
        return entry.isOwned(by: uid) ? [main] + rest : rest
    }
}

/// `responsibility_get_pid_responsible_for_pid` (private, exported by libquarantine; resolved with `dlsym`).
/// Returns -1 for processes not owned by the caller, the pid itself for self-responsible (LaunchServices) apps, and
/// survives reparenting (R06 §2.2).
struct ResponsibilityAPI: Sendable {
    private typealias Function = @convention(c) (pid_t) -> pid_t
    static let symbolName = "responsibility_get_pid_responsible_for_pid"

    /// The function pointer's bit pattern (C function pointers are not `Sendable`; the address is).
    private let address: Int

    /// Resolves the symbol via `dlsym(RTLD_DEFAULT, …)`; nil when it is missing.
    static func resolve() -> ResponsibilityAPI? {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT on Darwin
        guard let symbol = dlsym(rtldDefault, symbolName) else { return nil }
        return ResponsibilityAPI(address: Int(bitPattern: symbol))
    }

    private init(address: Int) { self.address = address }

    /// The pid responsible for `pid`, nil when the API refuses (other uid, gone).
    func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let raw = UnsafeRawPointer(bitPattern: address) else { return nil }
        let function = unsafeBitCast(raw, to: Function.self)
        let result = function(pid)
        return result > 0 ? result : nil
    }
}

/// Primary grouping: everything the app is responsible for (XPC services with ppid 1 included).
struct ResponsibilityGrouping: ProcessGrouping {
    let api: ResponsibilityAPI
    var method: GroupingSelfTest.Method { .responsibility }

    func groups(for mains: [pid_t], in table: ProcessTable, uid: uid_t) -> [pid_t: [pid_t]] {
        let wanted = Set(mains)
        var others: [pid_t: [pid_t]] = [:]
        for pid in table.pids {
            guard let entry = table[pid], entry.isOwned(by: uid), !entry.isZombie,
                  let responsible = api.responsiblePID(for: pid), responsible != pid, wanted.contains(responsible) else { continue }
            others[responsible, default: []].append(pid)
        }
        var result: [pid_t: [pid_t]] = [:]
        for main in mains { result[main] = Self.ordered(main: main, others: others[main] ?? [], table: table, uid: uid) }
        return result
    }
}

/// Fallback: same resource coalition (private `proc_pidinfo` flavor 20). Broader than responsibility (an app that
/// spawned another app directly shares its coalition), which the overlap check turns into `.uncertain`.
struct CoalitionGrouping: ProcessGrouping {
    /// Coalition id lookup (injectable for tests).
    let coalitionID: @Sendable (pid_t) -> UInt64?
    var method: GroupingSelfTest.Method { .coalition }

    init(coalitionID: @escaping @Sendable (pid_t) -> UInt64? = { Kernel.coalitionID(of: $0) }) {
        self.coalitionID = coalitionID
    }

    func groups(for mains: [pid_t], in table: ProcessTable, uid: uid_t) -> [pid_t: [pid_t]] {
        var mainsByCoalition: [UInt64: [pid_t]] = [:]
        for main in mains {
            if let id = coalitionID(main) { mainsByCoalition[id, default: []].append(main) }
        }
        var others: [pid_t: [pid_t]] = [:]
        if !mainsByCoalition.isEmpty {
            for pid in table.pids {
                guard let entry = table[pid], entry.isOwned(by: uid), !entry.isZombie,
                      let id = coalitionID(pid), let owners = mainsByCoalition[id] else { continue }
                for main in owners where main != pid { others[main, default: []].append(pid) }
            }
        }
        var result: [pid_t: [pid_t]] = [:]
        for main in mains { result[main] = Self.ordered(main: main, others: others[main] ?? [], table: table, uid: uid) }
        return result
    }
}

/// Last resort: ppid descendants from `KERN_PROC_ALL` (traverses root-owned `login`, keeps only owned members).
/// Misses launchd-spawned XPC services, so Freeze is never allowed with it.
struct ParentTreeGrouping: ProcessGrouping {
    var method: GroupingSelfTest.Method { .parentTree }

    func groups(for mains: [pid_t], in table: ProcessTable, uid: uid_t) -> [pid_t: [pid_t]] {
        var result: [pid_t: [pid_t]] = [:]
        for main in mains {
            let descendants = table.descendants(of: main).filter { pid in
                guard let entry = table[pid] else { return false }
                return entry.isOwned(by: uid) && !entry.isZombie
            }
            result[main] = Self.ordered(main: main, others: descendants, table: table, uid: uid)
        }
        return result
    }
}

/// The grouping chosen by the self-test, with the self-test result.
struct GroupingSelection: Sendable {
    let grouping: (any ProcessGrouping)?
    let selfTest: GroupingSelfTest
}

/// Picks the grouping method (responsibility → coalition → ppid) and reports it as `GroupingSelfTest`.
protocol GroupingResolving: Sendable {
    func resolve(selfPID: pid_t) -> GroupingSelection
}

/// Live self-test against the kernel (read-only).
struct LiveGroupingResolver: GroupingResolving {
    init() {}

    func resolve(selfPID: pid_t) -> GroupingSelection {
        if let api = ResponsibilityAPI.resolve() {
            // Our own pid must resolve to a live process (ourselves when launched by LaunchServices, the hosting app
            // — Terminal, Xcode — otherwise).
            if let responsible = api.responsiblePID(for: selfPID), Kernel.entry(of: responsible) != nil {
                return GroupingSelection(
                    grouping: ResponsibilityGrouping(api: api),
                    selfTest: GroupingSelfTest(method: .responsibility, freezeAllowed: true,
                                               detail: "\(ResponsibilityAPI.symbolName) resolved; pid \(selfPID) → \(responsible)"))
            }
        }
        if let coalition = Kernel.coalitionID(of: selfPID) {
            return GroupingSelection(
                grouping: CoalitionGrouping(),
                selfTest: GroupingSelfTest(method: .coalition, freezeAllowed: true,
                                           detail: "responsibility API unavailable; resource coalition \(coalition)"))
        }
        if Kernel.processTable() != nil {
            return GroupingSelection(
                grouping: ParentTreeGrouping(),
                selfTest: GroupingSelfTest(method: .parentTree, freezeAllowed: false,
                                           detail: "responsibility and coalition unavailable; Throttle only (XPC helpers missed)"))
        }
        return GroupingSelection(
            grouping: nil,
            selfTest: GroupingSelfTest(method: .unavailable, freezeAllowed: false, detail: "process table unreadable"))
    }
}

/// Groups that share a member (e.g. an app spawned by another app without disclaiming responsibility, or a shared
/// coalition) cannot be paused independently: both are protected as `.uncertain`.
enum GroupOverlap {
    static func conflictingMains(_ groups: [pid_t: [pid_t]]) -> Set<pid_t> {
        var owners: [pid_t: [pid_t]] = [:]
        for (main, members) in groups {
            for pid in Set(members).union([main]) { owners[pid, default: []].append(main) }
        }
        var conflicting: Set<pid_t> = []
        for (_, mains) in owners where mains.count > 1 { conflicting.formUnion(mains) }
        return conflicting
    }
}
