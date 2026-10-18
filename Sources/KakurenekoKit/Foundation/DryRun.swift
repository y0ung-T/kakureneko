import Foundation
import Synchronization

/// The dry-run policy (DECISIONS "Development safety rules"): with `KAKURENEKO_DRY_RUN=1` (or the
/// settings developer toggle) every system-mutating side effect is logged ("would arm", "would
/// sleep", "would throttle pid 123", "would publish …") instead of performed.
public struct DryRunPolicy: Sendable, Equatable, Codable {
    public var isEnabled: Bool

    public init(isEnabled: Bool) { self.isEnabled = isEnabled }

    public static let off = DryRunPolicy(isEnabled: false)
    public static let on = DryRunPolicy(isEnabled: true)

    /// Reads `KAKURENEKO_DRY_RUN` (truthy: 1/true/yes/on).
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> DryRunPolicy {
        DryRunPolicy(isEnabled: KakurenekoEnvironment.isTruthy(environment[KakurenekoEnvironment.dryRun]))
    }
}

/// Runtime switch consulted by every side-effect wrapper on every call.
///
/// * Forced on by the environment (`KAKURENEKO_DRY_RUN=1`): cannot be switched off at runtime.
/// * Otherwise follows `KakurenekoSettings.general.dryRun` (the coordinator calls `setRequested`).
public final class DryRunGate: Sendable {
    private struct State { var forced: Bool; var requested: Bool }
    private let state: Mutex<State>

    public init(policy: DryRunPolicy, requested: Bool = false) {
        state = Mutex(State(forced: policy.isEnabled, requested: requested))
    }

    /// Convenience: always on (tests, previews).
    public static func alwaysOn() -> DryRunGate { DryRunGate(policy: .on) }
    /// Convenience: off unless requested later.
    public static func off() -> DryRunGate { DryRunGate(policy: .off) }

    /// True when side effects must only be logged.
    public var isOn: Bool { state.withLock { $0.forced || $0.requested } }
    /// True when the environment forced dry-run (UI shows it as locked).
    public var isForcedByEnvironment: Bool { state.withLock { $0.forced } }

    /// Mirrors the settings toggle. Has no effect while forced by the environment.
    ///
    /// COORDINATOR ONLY, and only after `pausing.thawAll(reason: .pausingDisabled)` and `power.disarm()` have run
    /// under the OLD gate value (otherwise a real arm/throttle would be "undone" by a simulated call and stay in
    /// effect, or a simulated one would be undone for real). `LiveComposition` creates the gate with the environment
    /// policy only; the coordinator applies `settings.general.dryRun` in `start()` step 6, after journal recovery and
    /// the kernel-flag reconcile (so a crashed real run's effects are undone for real).
    public func setRequested(_ requested: Bool) { state.withLock { $0.requested = requested } }
}

/// One "would …" line.
public struct DryRunEntry: Sendable, Hashable, Codable, Identifiable {
    public var id: UInt64
    public var at: Date
    public var category: LogCategory
    /// Machine-readable action, e.g. `power.arm`, `power.sleep`, `signal.stop`, `priority.background`, `http.publish`.
    public var action: String
    /// Human-readable detail, e.g. `would throttle pid 123 (Arc)`. Never contains secrets.
    public var detail: String

    public init(id: UInt64, at: Date, category: LogCategory, action: String, detail: String) {
        self.id = id
        self.at = at
        self.category = category
        self.action = action
        self.detail = detail
    }
}

/// Ring buffer of recent dry-run decisions (shown in the UI's debug section and asserted in tests).
/// Each record is also logged to os.Logger category `dryrun` (+ file sink when configured).
public final class DryRunLedger: Sendable {
    private struct State { var nextID: UInt64 = 0; var entries: [DryRunEntry] = [] }
    private let state = Mutex(State())
    private let capacity: Int
    private let logger: KakurenekoLogger
    private let clock: any KakurenekoClock

    public init(capacity: Int = 200, logger: KakurenekoLogger = KakurenekoLogger(.dryRun), clock: any KakurenekoClock = SystemClock()) {
        self.capacity = max(1, capacity)
        self.logger = logger.with(category: .dryRun)
        self.clock = clock
    }

    /// Records a decision. `detail` should read like "would sleep the Mac now".
    public func record(_ category: LogCategory, action: String, detail: String) {
        let now = clock.now()
        state.withLock { s in
            s.nextID += 1
            s.entries.append(DryRunEntry(id: s.nextID, at: now, category: category, action: action, detail: detail))
            if s.entries.count > capacity { s.entries.removeFirst(s.entries.count - capacity) }
        }
        logger.notice("[\(category.rawValue)] \(action): \(detail)")
    }

    /// Oldest first.
    public var entries: [DryRunEntry] { state.withLock { $0.entries } }

    /// Entries whose `action` equals `action`.
    public func entries(action: String) -> [DryRunEntry] { entries.filter { $0.action == action } }

    public func removeAll() { state.withLock { $0.entries.removeAll() } }
}
