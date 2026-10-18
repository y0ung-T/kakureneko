// KakurenekoPower — read-only power/thermal/network/display/input readings for `PowerSnapshot`.
// OWNER: agent "power". Spec card: docs/ARCHITECTURE.md §9.4 (`snapshot()`). Brief §7.2, §7.4; R01 §6.1, §8; R07 §14.
//
// Everything here is a READ: IOPowerSources, the AppleSmartBattery registry entry, ProcessInfo, the thermal-pressure
// Darwin notification state, a long-lived NWPathMonitor, CoreGraphics display/input/session queries. Nothing mutates
// the system, so tests may call it; assertions must never depend on the values (battery present, lid, displays …).

import CoreGraphics
import KakurenekoKit
import Foundation
import IOKit
import IOKit.ps
import Network
import notify
import Synchronization

/// Produces the machine part of a `PowerSnapshot` (the controller adds lid + `SleepDisabled`).
protocol PowerSnapshotReading: Sendable {
    /// Starts long-lived observers (the `NWPathMonitor`). Idempotent.
    func start()
    /// Battery, thermal, network, displays, user input, screen lock at `now`. `lid`/`sleepDisabled` are left default.
    func read(at now: Date) -> PowerSnapshot
}

/// External-display presence (`CGGetOnlineDisplayList` + `CGDisplayIsBuiltin`). Shared by the snapshot reader and the
/// monitor's display-change detection.
protocol ExternalDisplayReading: Sendable {
    func externalDisplayConnected() -> Bool
}

/// Seconds since the last user input event (HID, any type) in the console session.
protocol UserInputIdleReading: Sendable {
    func secondsSinceUserInput() -> TimeInterval?
}

// MARK: - Live readers

struct LiveDisplayReader: ExternalDisplayReading {
    init() {}

    func externalDisplayConnected() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }
}

struct LiveUserInputIdleReader: UserInputIdleReading {
    init() {}

    func secondsSinceUserInput() -> TimeInterval? {
        // kCGAnyInputEventType = (CGEventType)~0 is a macro Swift does not import.
        guard let anyInput = CGEventType(rawValue: ~0) else { return nil }
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }
}

/// Battery readings from IOPowerSources + AppleSmartBattery.
struct BatteryReading: Sendable, Hashable {
    var percent: Int?
    var onAC: Bool
    var isCharging: Bool?
    var timeToEmptyMinutes: Int?
    var warningLevel: BatteryWarningLevel
    var drainingOnAC: Bool

    static let noBattery = BatteryReading(percent: nil, onAC: true, isCharging: nil, timeToEmptyMinutes: nil,
                                          warningLevel: .none, drainingOnAC: false)
}

enum PowerSourceReader {
    /// `IOPSCopyPowerSourcesInfo` → providing source type + the internal battery's description.
    static func read() -> BatteryReading {
        let warning = BatteryWarningLevel(rawValue: Int(IOPSGetBatteryWarningLevel().rawValue)) ?? .none
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            var reading = BatteryReading.noBattery
            reading.warningLevel = warning
            return reading
        }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        var onAC = providing != kIOPSBatteryPowerValue
        var percent: Int?
        var charging: Bool?
        var timeToEmpty: Int?
        let sources = (IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            if let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue {
                let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 100
                if maximum > 0 {
                    percent = min(100, max(0, Int((current / maximum * 100).rounded())))
                }
            }
            charging = (description[kIOPSIsChargingKey] as? NSNumber)?.boolValue
            if let state = description[kIOPSPowerSourceStateKey] as? String, providing == nil {
                onAC = state != kIOPSBatteryPowerValue
            }
            if let minutes = (description[kIOPSTimeToEmptyKey] as? NSNumber)?.intValue, minutes > 0 {
                timeToEmpty = minutes
            }
            break
        }
        if onAC { timeToEmpty = nil }
        var draining = false
        if onAC, percent != nil {
            let amperage = IORegistryReader.int64(RootDomainKey.instantAmperage, inServiceClass: RootDomainKey.smartBatteryClass)
                ?? IORegistryReader.int64(RootDomainKey.amperage, inServiceClass: RootDomainKey.smartBatteryClass)
            draining = (amperage ?? 0) < 0
        }
        return BatteryReading(percent: percent, onAC: onAC, isCharging: charging, timeToEmptyMinutes: timeToEmpty,
                              warningLevel: warning, drainingOnAC: draining)
    }
}

/// `notify_get_state("com.apple.system.thermalpressurelevel")` through one long-lived `notify_register_check` token.
final class ThermalPressureReader: Sendable {
    private let token = Mutex<Int32?>(nil)

    init() {}

    deinit {
        token.withLock { t in
            if let value = t { notify_cancel(value) }
            t = nil
        }
    }

    func read() -> ThermalPressure {
        token.withLock { t -> ThermalPressure in
            if t == nil {
                var newToken: Int32 = 0
                guard notify_register_check(PowerNotifyName.thermalPressureLevel, &newToken) == NOTIFY_STATUS_OK else {
                    return .unknown
                }
                t = newToken
            }
            guard let value = t else { return .unknown }
            var state: UInt64 = 0
            guard notify_get_state(value, &state) == NOTIFY_STATUS_OK else { return .unknown }
            return ThermalPressure(notifyState: state)
        }
    }
}

/// A long-lived `NWPathMonitor` (brief §7.4 network guard; R07 §14). Until the first path update arrives the network
/// counts as satisfied (an unknown network must never start the offline countdown).
final class NetworkPathObserver: Sendable {
    /// Shared with the monitor's update handler (no capture of `self`, so `deinit` can cancel the monitor).
    private final class PathState: Sendable {
        struct Value { var satisfied: Bool? = nil; var expensive = false }
        let value = Mutex(Value())
    }
    private final class MonitorBox: @unchecked Sendable {
        let monitor: NWPathMonitor
        init(_ monitor: NWPathMonitor) { self.monitor = monitor }
    }

    private let path = PathState()
    private let monitor = Mutex<MonitorBox?>(nil)
    private let queue = DispatchQueue(label: "com.kakureneko.power.network", qos: .utility)

    init() {}

    deinit { cancel() }

    /// Idempotent.
    func start() {
        let shared = path
        monitor.withLock { box in
            guard box == nil else { return }
            let m = NWPathMonitor()
            m.pathUpdateHandler = { @Sendable update in
                let satisfied = update.status == .satisfied
                let expensive = update.isExpensive
                shared.value.withLock {
                    $0.satisfied = satisfied
                    $0.expensive = expensive
                }
            }
            m.start(queue: queue)
            box = MonitorBox(m)
        }
    }

    func cancel() {
        let box = monitor.withLock { b -> MonitorBox? in
            defer { b = nil }
            return b
        }
        box?.monitor.cancel()
    }

    /// (satisfied, expensive). Satisfied defaults to true before the first update.
    var current: (satisfied: Bool, expensive: Bool) {
        path.value.withLock { ($0.satisfied ?? true, $0.expensive) }
    }
}

/// The production `PowerSnapshotReading`.
final class LivePowerSnapshotReader: PowerSnapshotReading {
    private let network = NetworkPathObserver()
    private let thermalPressure = ThermalPressureReader()
    private let displays: any ExternalDisplayReading
    private let input: any UserInputIdleReading

    init(displays: any ExternalDisplayReading = LiveDisplayReader(),
         input: any UserInputIdleReading = LiveUserInputIdleReader()) {
        self.displays = displays
        self.input = input
    }

    func start() { network.start() }

    func read(at now: Date) -> PowerSnapshot {
        let battery = PowerSourceReader.read()
        let net = network.current
        return PowerSnapshot(
            takenAt: now,
            batteryPercent: battery.percent,
            onAC: battery.onAC,
            isCharging: battery.isCharging,
            timeToEmptyMinutes: battery.timeToEmptyMinutes,
            batteryWarningLevel: battery.warningLevel,
            drainingOnAC: battery.drainingOnAC,
            thermalState: ThermalLevel(ProcessInfo.processInfo.thermalState),
            thermalPressure: thermalPressure.read(),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            networkSatisfied: net.satisfied,
            networkExpensive: net.expensive,
            externalDisplayConnected: displays.externalDisplayConnected(),
            secondsSinceUserInput: input.secondsSinceUserInput(),
            screenLocked: ScreenLockReader.isLocked()
        )
    }
}

enum ScreenLockReader {
    /// `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`; nil without a console session.
    static func isLocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        switch session["CGSSessionScreenIsLocked"] {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        default: return false
        }
    }
}

extension ThermalLevel {
    /// `ProcessInfo.ThermalState` → Kit mirror.
    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
}
