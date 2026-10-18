@testable import KakurenekoProcesses
import Darwin
import KakurenekoKit
import Foundation
import Synchronization

/// A scriptable, synthetic process table for exercising the scan/topology pipeline without touching the system.
final class FakeProbe: ProcessProbing {
    struct Process: Sendable {
        var row: ProcessRow
        /// Identity for other users' rows (resolved through `identity(of:)`, like `KERN_PROC_PID`).
        var foreignIdentity: ProcessIdentity?
        var path: String?
        var arguments: ProcArguments?
        var cpuSeconds: Double?
        var cwd: String?
        var unique: (uniqueID: UInt64, pidVersion: UInt32)?
        var fds: FDReadResult = .entries([])
    }

    private struct State {
        var processes: [Int32: Process] = [:]
        var tableAvailable = true
        var assertions: [Int32: [PowerAssertionInfo]]? = [:]
        var terminals: [Int32: (name: String, modified: Date?)] = [:]
        var wallNow = Date(timeIntervalSince1970: 1_800_000_000)
        var argumentReads: [Int32] = []
        var pathReads: [Int32] = []
        var fdReads: [Int32] = []
    }

    static let me: UInt32 = 501
    static let root: UInt32 = 0
    /// Default start times are far in the past relative to `wallNow` (so processes are not "young").
    static let baseStart: Int64 = 1_700_000_000

    private let state = Mutex(State())

    // MARK: Building

    /// Adds (or replaces) a process. Same-uid rows carry an identity; other users' rows get a foreign identity.
    @discardableResult
    func add(
        pid: Int32,
        ppid: Int32,
        uid: UInt32 = FakeProbe.me,
        comm: String? = nil,
        path: String? = nil,
        argv: [String]? = nil,
        environment: [String: String] = [:],
        execPath: String? = nil,
        tdev: Int32? = nil,
        cpu: Double? = 0,
        cwd: String? = nil,
        startSec: Int64? = nil,
        status: UInt32 = 2
    ) -> ProcessIdentity {
        let identity = ProcessIdentity(pid: pid, startSec: startSec ?? (Self.baseStart + Int64(pid)), startUsec: 0)
        let argv = argv ?? path.map { [$0] } ?? []
        let comm = comm ?? String((path ?? argv.first ?? "?").split(separator: "/").last ?? "?").prefix(16).description
        var row = ProcessRow(pid: pid, ppid: ppid, uid: uid, comm: comm, status: status)
        if uid == Self.me {
            row.identity = identity
            row.tdev = tdev
        }
        let process = Process(
            row: row,
            foreignIdentity: uid == Self.me ? nil : identity,
            path: path,
            arguments: ProcArguments(executablePath: execPath ?? path, argv: argv, environment: environment),
            cpuSeconds: cpu,
            cwd: cwd,
            unique: (UInt64(pid) * 1000, UInt32(pid) + 7)
        )
        state.withLock { $0.processes[pid] = process }
        return identity
    }

    func remove(_ pid: Int32) { state.withLock { _ = $0.processes.removeValue(forKey: pid) } }

    func update(_ pid: Int32, _ body: (inout Process) -> Void) {
        state.withLock { s in
            guard var process = s.processes[pid] else { return }
            body(&process)
            s.processes[pid] = process
        }
    }

    func setCPU(_ pid: Int32, _ seconds: Double) { update(pid) { $0.cpuSeconds = seconds } }
    func setFDs(_ pid: Int32, _ entries: [FDEntry]) { update(pid) { $0.fds = .entries(entries) } }
    func setFDResult(_ pid: Int32, _ result: FDReadResult) { update(pid) { $0.fds = result } }
    func setTableAvailable(_ available: Bool) { state.withLock { $0.tableAvailable = available } }
    func setAssertions(_ assertions: [Int32: [PowerAssertionInfo]]?) { state.withLock { $0.assertions = assertions } }
    func setTerminal(_ device: Int32, name: String, modified: Date?) {
        state.withLock { $0.terminals[device] = (name, modified) }
    }
    func setWallNow(_ date: Date) { state.withLock { $0.wallNow = date } }

    var argumentReads: [Int32] { state.withLock { $0.argumentReads } }
    var pathReads: [Int32] { state.withLock { $0.pathReads } }
    var fdReads: [Int32] { state.withLock { $0.fdReads } }
    func resetCounters() {
        state.withLock {
            $0.argumentReads = []
            $0.pathReads = []
            $0.fdReads = []
        }
    }

    // MARK: ProcessProbing

    func readTable() -> ProcessTable? {
        state.withLock { s in
            guard s.tableAvailable else { return nil }
            return ProcessTable(currentUID: Self.me, rows: s.processes.values.map(\.row))
        }
    }

    func identity(of pid: Int32) -> ProcessIdentity? {
        state.withLock { s in
            guard let process = s.processes[pid] else { return nil }
            return process.row.identity ?? process.foreignIdentity
        }
    }

    func executablePath(of pid: Int32) -> String? {
        state.withLock { s in
            s.pathReads.append(pid)
            return s.processes[pid]?.path
        }
    }

    func arguments(of pid: Int32, reader: inout ProcArgsReader) -> ProcArguments? {
        state.withLock { s in
            s.argumentReads.append(pid)
            return s.processes[pid]?.arguments
        }
    }

    func cpuSeconds(of pid: Int32) -> Double? { state.withLock { $0.processes[pid]?.cpuSeconds } }
    func workingDirectory(of pid: Int32) -> String? { state.withLock { $0.processes[pid]?.cwd } }
    func uniqueIdentifier(of pid: Int32) -> (uniqueID: UInt64, pidVersion: UInt32)? {
        state.withLock { $0.processes[pid]?.unique }
    }

    func fileDescriptors(of pid: Int32, kinds: FDKinds) -> FDReadResult {
        state.withLock { s in
            s.fdReads.append(pid)
            guard let process = s.processes[pid] else { return .gone }
            guard case .entries(let entries) = process.fds else { return process.fds }
            return .entries(entries.filter { entry in
                switch entry {
                case .ptyMaster: kinds.contains(.ptyMasters)
                case .tcp, .unixSocket: kinds.contains(.sockets)
                case .pipe: kinds.contains(.pipes)
                }
            })
        }
    }

    func powerAssertions() -> [Int32: [PowerAssertionInfo]]? { state.withLock { $0.assertions } }
    func terminal(device: Int32) -> (name: String, modified: Date?)? { state.withLock { $0.terminals[device] } }
    func wallClockNow() -> Date { state.withLock { $0.wallNow } }
}

/// A matcher that classifies by a predicate (live tests: match only processes this test spawned).
struct PredicateMatcher: AgentSignatureMatching {
    let predicate: @Sendable (ProcessDescriptor) -> AgentMatch?
    func match(_ process: ProcessDescriptor) -> AgentMatch? { predicate(process) }
}

/// Fixture helpers.
enum Fixtures {
    static let home = "/Users/tester"
    static let rules = AgentSignatureRules(home: home)

    static func scanContext(
        matcher: any AgentSignatureMatching = AgentSignatureRules.matcherForTests,
        endpoints: ModelEndpointSet = ModelEndpointSet(),
        storeWrites: SessionStoreWriteLog = SessionStoreWriteLog(),
        bundleIDs: [String: String] = [:]
    ) -> ScanContext {
        ScanContext(
            matcher: matcher,
            endpoints: endpoints,
            storeWrites: storeWrites,
            bundles: BundleIdentifierCache(reader: { bundleIDs[$0] })
        )
    }

    static func tcp(
        local: String, _ localPort: UInt16, remote: String, _ remotePort: UInt16, state: Int32 = TSI_S_ESTABLISHED
    ) -> FDEntry {
        .tcp(TCPSocketInfo(local: IPAddress(local), localPort: localPort, remote: IPAddress(remote), remotePort: remotePort, state: state))
    }

    static func listener(_ address: String, _ port: UInt16) -> FDEntry {
        .tcp(TCPSocketInfo(local: IPAddress(address), localPort: port, remote: IPAddress("0.0.0.0"), remotePort: 0, state: TSI_S_LISTEN))
    }

    static func unix(_ socket: UInt64, peer: UInt64 = 0, path: String? = nil, peerPath: String? = nil, listening: Bool = false) -> FDEntry {
        .unixSocket(UnixSocketInfo(socket: socket, peerSocket: peer, path: path, peerPath: peerPath, isListening: listening))
    }
}

extension AgentSignatureRules {
    /// The production rules for the fixture home, as an `AgentSignatureMatching`.
    static let matcherForTests: any AgentSignatureMatching = RulesMatcher(rules: AgentSignatureRules(home: Fixtures.home))
}

struct RulesMatcher: AgentSignatureMatching {
    let rules: AgentSignatureRules
    func match(_ process: ProcessDescriptor) -> AgentMatch? { rules.match(process) }
}

/// Temp `Paths` with automatic cleanup.
struct TempHome: ~Copyable {
    let paths: Paths
    init() throws { paths = try Paths.temporary() }
    deinit { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
}
