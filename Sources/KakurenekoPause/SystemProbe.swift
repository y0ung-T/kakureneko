import Darwin
import Dispatch
import KakurenekoKit
import Foundation
import Synchronization

/// Memory pressure as reported by the kernel (`DispatchSource.makeMemoryPressureSource` /
/// `kern.memorystatus_vm_pressure_level`). Quit mode needs ≥ `.warning`.
enum MemoryPressure: Int, Sendable, Comparable {
    case normal = 1
    case warning = 2
    case critical = 4

    init(sysctlLevel: Int32) {
        switch sysctlLevel {
        case 4...: self = .critical
        case 2, 3: self = .warning
        default: self = .normal
        }
    }

    static func < (lhs: MemoryPressure, rhs: MemoryPressure) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Everything the pause engine reads from the system (read-only). The live implementation calls the kernel; tests
/// inject a synthetic world so no real app is ever inspected or touched.
protocol SystemProbing: Sendable {
    /// The uid whose processes may be paused (`getuid()`): the group formula's `uid == me`.
    var userID: uid_t { get }
    /// The process table (nil when the sysctl fails).
    func processTable() -> ProcessTable?
    /// `proc_pidpath` (journal `path` of throttled/frozen members).
    func executablePath(of pid: pid_t) -> String?
    /// Adds `uniqueID` + `pidVersion` after re-verifying the live start time; nil when that is impossible.
    func enrich(_ identity: ProcessIdentity) -> ProcessIdentity?
    /// Cumulative CPU nanoseconds of `pid` (rule P-I history).
    func cpuNanoseconds(of pid: pid_t) -> UInt64?
    /// A member holds an fd ending in `.crdownload`/`.part`/`.download` (rule P-G).
    func hasDownloadInProgress(_ pid: pid_t) -> Bool
    /// `PROC_FLAG_TRACED` (rule P-H).
    func isTraced(_ pid: pid_t) -> Bool
    /// Pids whose CoreAudio process object is running output or input (rule P-F).
    func audioActivePIDs(among pids: Set<pid_t>) -> Set<pid_t>
    /// `proc_get_dirty` flags (Quit mode: `TRACKED && !IS_DIRTY`).
    func dirtyFlags(of pid: pid_t) -> UInt32?
    /// `kern.bootsessionuuid`.
    func bootSessionUUID() -> String?
    /// Current memory pressure.
    func memoryPressure() -> MemoryPressure
    /// Lazily starts the memory-pressure source (called from `observe`). Idempotent.
    func startMemoryPressureMonitoring()
    /// `p_stat == SSTOP` (Freeze verification).
    func isStopped(_ pid: pid_t) -> Bool
}

/// The real probe: libproc, sysctl, CoreAudio, a lazily created memory-pressure dispatch source.
final class LiveSystemProbe: SystemProbing {
    private let audio = AudioActivityProbe()
    private let pressure = MemoryPressureMonitor()

    init() {}

    var userID: uid_t { getuid() }
    func processTable() -> ProcessTable? { Kernel.processTable() }
    func executablePath(of pid: pid_t) -> String? { Kernel.executablePath(of: pid) }
    func enrich(_ identity: ProcessIdentity) -> ProcessIdentity? { Kernel.enrich(identity) }
    func cpuNanoseconds(of pid: pid_t) -> UInt64? { Kernel.cpuNanoseconds(of: pid) }
    func hasDownloadInProgress(_ pid: pid_t) -> Bool {
        Kernel.openVnodePaths(of: pid).contains(where: DownloadFiles.isInProgress)
    }
    func isTraced(_ pid: pid_t) -> Bool { Kernel.isTraced(pid) }
    func audioActivePIDs(among pids: Set<pid_t>) -> Set<pid_t> { audio.activePIDs().intersection(pids) }
    func dirtyFlags(of pid: pid_t) -> UInt32? { Kernel.dirtyFlags(of: pid) }
    func bootSessionUUID() -> String? { Kernel.bootSessionUUID() }
    func memoryPressure() -> MemoryPressure { pressure.current() }
    func startMemoryPressureMonitoring() { pressure.start() }
    func isStopped(_ pid: pid_t) -> Bool { Kernel.isStopped(pid) }
}

/// Rule P-G file-name patterns (R06 §3.3 G): Chromium `.crdownload`, Firefox `.part`, Safari `*.download` bundles.
enum DownloadFiles {
    static func isInProgress(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.hasSuffix(".crdownload") || lower.hasSuffix(".part") || lower.hasSuffix(".download") { return true }
        return lower.contains(".download/")
    }
}

/// Lazily-owned `DispatchSource.makeMemoryPressureSource` (Quit mode). Until the source reports an event, the
/// level comes from `kern.memorystatus_vm_pressure_level` (the source only fires on changes).
final class MemoryPressureMonitor: Sendable {
    /// Boxes the non-Sendable dispatch source (§5 "Non-Sendable tokens in a Mutex").
    private final class SourceBox: @unchecked Sendable {
        let source: any DispatchSourceMemoryPressure
        init(_ source: any DispatchSourceMemoryPressure) { self.source = source }
    }
    private struct State {
        var box: SourceBox?
        var reported: MemoryPressure?
    }
    private let state = Mutex(State())

    init() {}

    deinit {
        state.withLock { $0.box?.source.cancel() }
    }

    func start() {
        state.withLock { s in
            guard s.box == nil else { return }
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.normal, .warning, .critical], queue: DispatchQueue.global(qos: .utility))
            let box = SourceBox(source)
            // Closure created here, inside the nonisolated library (R08 pitfall 1).
            source.setEventHandler { [weak self, box] in
                let event = box.source.data
                let level: MemoryPressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
                self?.state.withLock { $0.reported = level }
            }
            source.activate()
            s.box = box
        }
    }

    func current() -> MemoryPressure {
        if let reported = state.withLock({ $0.reported }) { return reported }
        return Kernel.memoryPressureLevel().map(MemoryPressure.init(sysctlLevel:)) ?? .normal
    }
}
