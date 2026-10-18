import Foundation
import Synchronization

/// Lid state from `IOPMrootDomain["AppleClamshellState"]` (never `AppleClamshellCausesSleep`).
public enum LidState: String, Sendable, Hashable, Codable {
    case open
    case closed
    /// Desktop Mac / property absent.
    case noLid
    case unknown

    public var isClosed: Bool { self == .closed }
}

/// Kernel truth read from IOPMrootDomain (cheap, synchronous IORegistry read).
///
/// Dry-run keeps a SIMULATED `SleepDisabled` flag (`sleepDisabled`), but `kernelSleepDisabled` is ALWAYS the real
/// IOPMrootDomain value: launch reconcile and the "stale flag" warning must look at the kernel, never at the
/// simulation (a real armed run killed with `kill -9`, then relaunched in dry-run, would otherwise leave the
/// kernel's low-battery/thermal emergency sleeps disabled).
public struct KernelPowerFlags: Sendable, Hashable, Codable {
    /// EFFECTIVE `SleepDisabled`: the simulated flag in dry-run, else the kernel value. nil = unreadable.
    public var sleepDisabled: Bool?
    /// The real IOPMrootDomain `SleepDisabled`, always (also in dry-run). nil = unreadable.
    public var kernelSleepDisabled: Bool?
    /// True when `sleepDisabled` is the dry-run simulation.
    public var isSimulated: Bool
    /// `AppleClamshellState`. nil = no lid.
    public var clamshellClosed: Bool?

    /// `kernelSleepDisabled` defaults to `sleepDisabled` when not simulated.
    public init(sleepDisabled: Bool?, clamshellClosed: Bool?, kernelSleepDisabled: Bool? = nil, isSimulated: Bool = false) {
        self.sleepDisabled = sleepDisabled
        self.clamshellClosed = clamshellClosed
        self.isSimulated = isSimulated
        self.kernelSleepDisabled = isSimulated ? kernelSleepDisabled : (kernelSleepDisabled ?? sleepDisabled)
    }

    public var lid: LidState {
        switch clamshellClosed {
        case .some(true): .closed
        case .some(false): .open
        case .none: .noLid
        }
    }

    private enum CodingKeys: String, CodingKey { case sleepDisabled, kernelSleepDisabled, isSimulated, clamshellClosed }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sleepDisabled = c.tolerantDecodeIfPresent(Bool.self, forKey: .sleepDisabled)
        clamshellClosed = c.tolerantDecodeIfPresent(Bool.self, forKey: .clamshellClosed)
        isSimulated = c.tolerantDecode(Bool.self, forKey: .isSimulated, default: false)
        kernelSleepDisabled = c.tolerantDecodeIfPresent(Bool.self, forKey: .kernelSleepDisabled) ?? (isSimulated ? nil : sleepDisabled)
    }
}

/// `ProcessInfo.ThermalState` mirror.
public enum ThermalLevel: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case nominal, fair, serious, critical

    private var rank: Int {
        switch self {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        }
    }
    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rank < rhs.rank }
}

/// `notify_get_state("com.apple.system.thermalpressurelevel")`: 0 nominal, 1 moderate, 2 heavy, 3 trapping, 4 sleeping.
public enum ThermalPressure: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case nominal, moderate, heavy, trapping, sleeping, unknown

    public init(notifyState value: UInt64) {
        switch value {
        case 0: self = .nominal
        case 1: self = .moderate
        case 2: self = .heavy
        case 3: self = .trapping
        case 4: self = .sleeping
        default: self = .unknown
        }
    }

    private var rank: Int {
        switch self {
        case .unknown: -1
        case .nominal: 0
        case .moderate: 1
        case .heavy: 2
        case .trapping: 3
        case .sleeping: 4
        }
    }
    public static func < (lhs: ThermalPressure, rhs: ThermalPressure) -> Bool { lhs.rank < rhs.rank }
}

/// `IOPSGetBatteryWarningLevel()`: 1 none, 2 early, 3 final.
public enum BatteryWarningLevel: Int, Sendable, Hashable, Codable, Comparable {
    case none = 1
    case early = 2
    case final = 3

    public static func < (lhs: BatteryWarningLevel, rhs: BatteryWarningLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Everything the power state machine, the safety policy and the iPhone's timing read (brief §7.2/§7.4/§8.5).
public struct PowerSnapshot: Sendable, Hashable, Codable {
    public var takenAt: Date
    public var lid: LidState
    /// Effective `SleepDisabled` (simulated in dry-run).
    public var sleepDisabled: Bool?
    /// Real IOPMrootDomain `SleepDisabled`, also in dry-run (see `KernelPowerFlags`).
    public var kernelSleepDisabled: Bool?
    /// 0–100; nil = no battery.
    public var batteryPercent: Int?
    public var onAC: Bool
    public var isCharging: Bool?
    /// `kIOPSTimeToEmptyKey` in minutes; nil = unknown / calculating / on AC.
    public var timeToEmptyMinutes: Int?
    public var batteryWarningLevel: BatteryWarningLevel
    /// On AC but `AppleSmartBattery.InstantAmperage < 0`.
    public var drainingOnAC: Bool
    public var thermalState: ThermalLevel
    public var thermalPressure: ThermalPressure
    public var lowPowerMode: Bool
    /// `NWPathMonitor` status == satisfied.
    public var networkSatisfied: Bool
    /// `NWPath.isExpensive` (e.g. iPhone hotspot) — warn at lid close.
    public var networkExpensive: Bool
    /// Any non-builtin display online (`CGGetOnlineDisplayList` + `CGDisplayIsBuiltin`).
    public var externalDisplayConnected: Bool
    /// `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)`.
    public var secondsSinceUserInput: TimeInterval?
    /// `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`.
    public var screenLocked: Bool?

    public init(
        takenAt: Date,
        lid: LidState = .unknown,
        sleepDisabled: Bool? = nil,
        batteryPercent: Int? = nil,
        onAC: Bool = true,
        isCharging: Bool? = nil,
        timeToEmptyMinutes: Int? = nil,
        batteryWarningLevel: BatteryWarningLevel = .none,
        drainingOnAC: Bool = false,
        thermalState: ThermalLevel = .nominal,
        thermalPressure: ThermalPressure = .nominal,
        lowPowerMode: Bool = false,
        networkSatisfied: Bool = true,
        networkExpensive: Bool = false,
        externalDisplayConnected: Bool = false,
        secondsSinceUserInput: TimeInterval? = nil,
        screenLocked: Bool? = nil,
        kernelSleepDisabled: Bool? = nil
    ) {
        self.takenAt = takenAt
        self.lid = lid
        self.sleepDisabled = sleepDisabled
        self.kernelSleepDisabled = kernelSleepDisabled
        self.batteryPercent = batteryPercent
        self.onAC = onAC
        self.isCharging = isCharging
        self.timeToEmptyMinutes = timeToEmptyMinutes
        self.batteryWarningLevel = batteryWarningLevel
        self.drainingOnAC = drainingOnAC
        self.thermalState = thermalState
        self.thermalPressure = thermalPressure
        self.lowPowerMode = lowPowerMode
        self.networkSatisfied = networkSatisfied
        self.networkExpensive = networkExpensive
        self.externalDisplayConnected = externalDisplayConnected
        self.secondsSinceUserInput = secondsSinceUserInput
        self.screenLocked = screenLocked
    }

    public var onBattery: Bool { !onAC }

    /// Clamshell desktop mode (lid closed + external display): the user may be working. The coordinator treats
    /// it as lid OPEN (no countdown, no pausing, no display sleep).
    public var isClamshellDesktop: Bool { lid.isClosed && externalDisplayConnected }

    /// Presence for notification gating.
    public var presence: Presence {
        Presence(lidClosed: lid.isClosed, screenLocked: screenLocked ?? false, secondsSinceUserInput: secondsSinceUserInput,
                 hasLid: lid != .noLid)
    }
}

/// Presence (brief §8.5): away = lid closed, screen locked, or no user input ≥ threshold (default 5 min).
///
/// **Unknown input time (binding, one rule everywhere — ARCHITECTURE §8 "Presence"):** when
/// `secondsSinceUserInput` is nil (no HID idle reading yet), the user counts as AWAY while the lid is
/// (effectively) closed and as PRESENT while it is open. So a missing reading can never block a countdown or a
/// push forever with the lid closed, and never pushes to the phone while someone may be sitting at an open Mac.
/// `Presence.hasRecentInput` is that rule; `isAway` (notification gating) and the coordinator's `userPresent`
/// (countdown gating) both use it. They still answer different questions with a KNOWN reading: with the lid
/// closed, notifications always count the user as away, while recent input (e.g. Screen Sharing) keeps the
/// coordinator from starting a countdown.
public struct Presence: Sendable, Hashable, Codable {
    /// Lid EFFECTIVELY closed (a closed lid with an external display — clamshell desktop — counts as open).
    public var lidClosed: Bool
    public var screenLocked: Bool
    public var secondsSinceUserInput: TimeInterval?
    /// False on a Mac without a lid (Mac mini, Studio, iMac): "only when the lid is closed" then means "away".
    public var hasLid: Bool

    public init(lidClosed: Bool, screenLocked: Bool, secondsSinceUserInput: TimeInterval?, hasLid: Bool = true) {
        self.lidClosed = lidClosed
        self.screenLocked = screenLocked
        self.secondsSinceUserInput = secondsSinceUserInput
        self.hasLid = hasLid
    }

    private enum CodingKeys: String, CodingKey { case lidClosed, screenLocked, secondsSinceUserInput, hasLid }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lidClosed = try c.decode(Bool.self, forKey: .lidClosed)
        screenLocked = try c.decode(Bool.self, forKey: .screenLocked)
        secondsSinceUserInput = try c.decodeIfPresent(TimeInterval.self, forKey: .secondsSinceUserInput)
        hasLid = try c.decodeIfPresent(Bool.self, forKey: .hasLid) ?? true
    }

    /// Lid closed, screen locked, or no recent input (`hasRecentInput` — unknown counts as present only with the
    /// lid open, which this check never reaches with the lid closed).
    public func isAway(idleThreshold: TimeInterval = 300) -> Bool {
        lidClosed || screenLocked
            || !Self.hasRecentInput(secondsSinceUserInput: secondsSinceUserInput, idleThreshold: idleThreshold,
                                    lidClosed: lidClosed)
    }

    /// The shared "recent user input" rule: a known reading counts when `< idleThreshold`; an UNKNOWN reading
    /// (nil) counts as recent only while the lid is open (see the type documentation).
    public static func hasRecentInput(secondsSinceUserInput: TimeInterval?, idleThreshold: TimeInterval,
                                      lidClosed: Bool) -> Bool {
        guard let seconds = secondsSinceUserInput else { return !lidClosed }
        return seconds < idleThreshold
    }

    public static let present = Presence(lidClosed: false, screenLocked: false, secondsSinceUserInput: 0)
    public static let away = Presence(lidClosed: true, screenLocked: false, secondsSinceUserInput: nil)
}

/// Result of the side-effect-free privileged health check (brief §7.1).
public struct PrivilegedStatus: Sendable, Hashable, Codable {
    /// `sudo -n -l /usr/bin/pmset -a disablesleep 1` exits 0.
    public var sudoRuleInstalled: Bool
    /// `launchctl print system/com.kakureneko.failsafe` succeeds.
    public var failsafeLoaded: Bool
    public var checkedAt: Date?
    /// Diagnostic text for the UI (never secrets).
    public var detail: String?
    /// Dry-run on a Mac without the privileged install: the coordinator substitutes an operational status so the
    /// developer sees every "would arm / would sleep" decision. The UI labels it "simulated".
    public var simulated: Bool
    /// Heartbeat path baked into the installed root fail-safe script (parsed read-only from
    /// `/Library/Application Support/Kakureneko/kakureneko-failsafe.sh`). A mismatch with `Paths.heartbeatFile`
    /// means the fail-safe would clear the flag 150 s into every closed-lid session → not operational.
    public var failsafeHeartbeatPath: String?
    /// Set by `healthCheck()` when `failsafeHeartbeatPath` is known and differs from `Paths.heartbeatFile`.
    public var heartbeatPathMismatch: Bool
    /// (fix) Set by `healthCheck()` when the daemon is loaded but the installed fail-safe script is missing, has no
    /// parseable heartbeat line or differs from what this version generates, or its LaunchDaemon plist is missing or
    /// differs: there is no trustworthy root backstop → not operational. A file the user cannot read is not set here.
    public var failsafeScriptMismatch: Bool

    public init(sudoRuleInstalled: Bool, failsafeLoaded: Bool, checkedAt: Date? = nil, detail: String? = nil,
                simulated: Bool = false, failsafeHeartbeatPath: String? = nil, heartbeatPathMismatch: Bool = false,
                failsafeScriptMismatch: Bool = false) {
        self.sudoRuleInstalled = sudoRuleInstalled
        self.failsafeLoaded = failsafeLoaded
        self.checkedAt = checkedAt
        self.detail = detail
        self.simulated = simulated
        self.failsafeHeartbeatPath = failsafeHeartbeatPath
        self.heartbeatPathMismatch = heartbeatPathMismatch
        self.failsafeScriptMismatch = failsafeScriptMismatch
    }

    /// Both parts present (and the fail-safe is intact and watches our heartbeat) → closed-lid mode available.
    /// Otherwise "notifications only".
    public var isOperational: Bool {
        sudoRuleInstalled && failsafeLoaded && !heartbeatPathMismatch && !failsafeScriptMismatch
    }

    /// The installed root part needs reinstalling (wrong heartbeat, or a damaged/foreign fail-safe).
    public var needsReinstall: Bool { heartbeatPathMismatch || failsafeScriptMismatch }

    public static let unknown = PrivilegedStatus(sudoRuleInstalled: false, failsafeLoaded: false, checkedAt: nil, detail: "Not checked yet")

    /// What the coordinator uses in dry-run when the real health check is not operational.
    public static func simulatedForDryRun(at date: Date) -> PrivilegedStatus {
        PrivilegedStatus(sudoRuleInstalled: true, failsafeLoaded: true, checkedAt: date, detail: "simulated (dry-run)", simulated: true)
    }

    private enum CodingKeys: String, CodingKey {
        case sudoRuleInstalled, failsafeLoaded, checkedAt, detail, simulated, failsafeHeartbeatPath, heartbeatPathMismatch
        case failsafeScriptMismatch
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sudoRuleInstalled = c.tolerantDecode(Bool.self, forKey: .sudoRuleInstalled, default: false)
        failsafeLoaded = c.tolerantDecode(Bool.self, forKey: .failsafeLoaded, default: false)
        checkedAt = c.tolerantDecodeIfPresent(Date.self, forKey: .checkedAt)
        detail = c.tolerantDecodeIfPresent(String.self, forKey: .detail)
        simulated = c.tolerantDecode(Bool.self, forKey: .simulated, default: false)
        failsafeHeartbeatPath = c.tolerantDecodeIfPresent(String.self, forKey: .failsafeHeartbeatPath)
        heartbeatPathMismatch = c.tolerantDecode(Bool.self, forKey: .heartbeatPathMismatch, default: false)
        failsafeScriptMismatch = c.tolerantDecode(Bool.self, forKey: .failsafeScriptMismatch, default: false)
    }
}

/// Why a countdown is running (picks the timer: finished 5 min, needs-input 10 min).
/// `.needsInput` when any session is waiting; `.wentQuiet` when every finished session since the lid closed is
/// heuristic-only; else `.finished`.
public enum CountdownReason: String, Sendable, Hashable, Codable {
    case finished
    case needsInput
    case wentQuiet
}

/// Safety guards (brief §7.4). Each carries what the push text needs.
public enum SafetyTrip: Sendable, Hashable, Codable {
    case batteryFloor(percent: Int)
    case batteryWarning(level: BatteryWarningLevel, percent: Int?)
    case lowTimeToEmpty(minutes: Int)
    case drainingOnAC(percent: Int)
    /// Battery not allowed with the lid closed (setting) and the Mac is on battery.
    case onBatteryNotAllowed(percent: Int?)
    case thermalCritical
    case thermalSerious(seconds: Int)
    case thermalPressure(ThermalPressure)
    case networkOffline(minutes: Int)
    case maxDuration(hours: Double)

    /// Short reason for the push body: "battery 19 %", "too hot", "offline 15 min" (brief §8.4).
    public var userReason: String {
        switch self {
        case .batteryFloor(let p): "battery \(p) %"
        case .batteryWarning(_, let p): p.map { "battery low (\($0) %)" } ?? "battery low"
        case .lowTimeToEmpty(let m): "battery has \(m) min left"
        case .drainingOnAC(let p): "battery draining on power adapter (\(p) %)"
        case .onBatteryNotAllowed(let p): p.map { "on battery (\($0) %)" } ?? "on battery"
        case .thermalCritical, .thermalSerious, .thermalPressure: "too hot"
        case .networkOffline(let m): "offline \(m) min"
        case .maxDuration(let h): "lid closed for \(h.formatted(.number.precision(.fractionLength(0...1)))) h"
        }
    }
}

/// Why the Mac is winding down.
public enum WindDownReason: Sendable, Hashable, Codable {
    case countdownElapsed
    case userSleepNow
    case remoteSleep
    case remoteShutdown
    case safetyTrip(SafetyTrip)
}

/// End action (D2: sleep by default; shutdown opt-in with sleep fallback).
public enum EndAction: String, Sendable, Hashable, Codable, CaseIterable {
    case sleep
    case shutdown
}

/// The power state machine's phase (brief §7.3). Owned by KakurenekoCoordinator.
public enum PowerPhase: Sendable, Hashable, Codable {
    case disarmed
    case armed(since: Date)
    case closedAwake(since: Date)
    case countdown(endsAt: Date, reason: CountdownReason, closedSince: Date)
    /// The 60 s "Shutting down" grace (phone `shutdown` command or opt-in end action) before wind-down.
    /// Cancellable from the menu (`KakurenekoControlling.cancelWindDown`), by lid open or a keep-awake command.
    case shutdownPending(at: Date, requestedFromPhone: Bool)
    case windingDown(reason: WindDownReason, since: Date)

    public var label: String {
        switch self {
        case .disarmed: "disarmed"
        case .armed: "armed"
        case .closedAwake: "closedAwake"
        case .countdown: "countdown"
        case .shutdownPending: "shutdownPending"
        case .windingDown: "windingDown"
        }
    }

    /// Flag expected set (armed, closed awake, countdown, shutdown pending).
    public var isArmed: Bool {
        switch self {
        case .armed, .closedAwake, .countdown, .shutdownPending: true
        case .disarmed, .windingDown: false
        }
    }
}

/// A sleep Kakureneko initiated (for the "Mac slept 01:12–07:40" push after wake).
public struct SleepRecord: Sendable, Hashable, Codable {
    public var startedAt: Date
    public var endedAt: Date?
    public var reason: WindDownReason
    public var batteryPercentAtStart: Int?
    public var endAction: EndAction

    public init(startedAt: Date, endedAt: Date? = nil, reason: WindDownReason, batteryPercentAtStart: Int? = nil, endAction: EndAction = .sleep) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.reason = reason
        self.batteryPercentAtStart = batteryPercentAtStart
        self.endAction = endAction
    }
}

/// Resume manifest entry (`resume.json`, brief §7.5) written before an opt-in shutdown.
public struct ResumeEntry: Sendable, Hashable, Codable {
    public var agent: AgentID
    public var sessionId: String?
    public var cwd: String?
    public var title: String?
    /// `interactive` | `bg`
    public var kind: String?
    public var jobId: String?
    public var host: HostApp?

    public init(agent: AgentID, sessionId: String?, cwd: String?, title: String?, kind: String? = nil, jobId: String? = nil, host: HostApp? = nil) {
        self.agent = agent
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
        self.kind = kind
        self.jobId = jobId
        self.host = host
    }

    /// Shell command to reopen it, e.g. `cd '/x/y' && claude --resume <id>` or `claude attach <job>`.
    ///
    /// Injection-safe for arbitrary values: the cwd is always single-quoted (`'` → `'\''`), and an id is emitted
    /// bare only when it consists solely of `[A-Za-z0-9._:@%+=,/-]`, else single-quoted too. Without a (non-empty)
    /// cwd the command runs `cd "$HOME"` (a quoted `'~'` would never expand). nil for non-Claude entries and for
    /// entries without an id.
    public var resumeCommand: String? {
        guard agent == .claude else { return nil }
        if let jobId, !jobId.isEmpty, kind == "bg" { return "claude attach \(Self.shellWord(jobId))" }
        guard let sessionId, !sessionId.isEmpty else { return nil }
        let directory = cwd.flatMap { $0.isEmpty ? nil : Self.shellQuoted($0) } ?? #""$HOME""#
        return "cd \(directory) && claude --resume \(Self.shellWord(sessionId))"
    }

    /// `value` as one single-quoted POSIX shell word.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// `value` as one POSIX shell word: bare when every character is in a set the shell never interprets, else
    /// `shellQuoted`.
    static func shellWord(_ value: String) -> String {
        let safe = !value.isEmpty && value.unicodeScalars.allSatisfy { s in
            s.isASCII && (s.properties.isAlphabetic || ("0"..."9").contains(s) || "._:@%+=,/-".unicodeScalars.contains(s))
        }
        return safe ? value : shellQuoted(value)
    }
}

/// Events from `PowerEventSource` (brief §7.2 lid edges, sleep/wake, thaw triggers §6.5).
public enum PowerEvent: Sendable, Hashable {
    /// Edge only (deduplicated against the last state; the interest notification also fires on AC changes).
    case lidChanged(LidState)
    /// `kIOMessageSystemWillSleep`. Call `acknowledger.allow()` when ready; KakurenekoPower auto-allows after its deadline (≤ 8 s).
    case willSleep(PowerChangeAcknowledger)
    case didWake
    /// `NSWorkspace.willPowerOffNotification` (logout/restart/shutdown).
    case willPowerOff
    /// `NSWorkspace.sessionDidResignActiveNotification` (fast user switching) — thaw trigger.
    case sessionResignedActive
    case sessionBecameActive
    case externalDisplayChanged(connected: Bool)
    /// User input while the lid is closed (e.g. Screen Sharing), detected by the 1 Hz poll when
    /// `secondsSinceUserInput` drops below 2 s; rate-limited to once per 10 s. Thaw trigger (`.userInput`).
    case userActivity(secondsSinceInput: TimeInterval)
    /// Periodic (15 s) and on-change power/thermal/network/display/input snapshot. The only case a new
    /// subscriber gets replayed (`AsyncBroadcaster(replayFilter:)`): edges are never replayed.
    case snapshot(PowerSnapshot)

    /// True for `.snapshot` (the replay filter `PowerEventSource` implementations use).
    public var isSnapshot: Bool { if case .snapshot = self { true } else { false } }
}

/// One-shot acknowledgement for `kIOMessageSystemWillSleep` (`IOAllowPowerChange`). Thread-safe, idempotent.
public final class PowerChangeAcknowledger: Sendable, Hashable {
    private let allowed = Mutex(false)
    private let onAllow: @Sendable () -> Void

    public init(onAllow: @escaping @Sendable () -> Void) {
        self.onAllow = onAllow
    }

    /// Allows the power change (first call only).
    public func allow() {
        let first = allowed.withLock { done -> Bool in
            if done { return false }
            done = true
            return true
        }
        if first { onAllow() }
    }

    public var isAllowed: Bool { allowed.withLock { $0 } }

    public static func == (lhs: PowerChangeAcknowledger, rhs: PowerChangeAcknowledger) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
