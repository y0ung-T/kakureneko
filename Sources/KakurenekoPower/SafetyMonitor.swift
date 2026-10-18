// KakurenekoPower — SafetyMonitor: the closed-lid safety policy (the kernel's own low-battery and thermal emergency sleeps
// are disabled while `SleepDisabled` is set, so these guards are the hard rules).
// OWNER: agent "power". Spec card: docs/ARCHITECTURE.md §9.4. Brief §7.4; R01 §8, §11.2; DECISIONS D1.
//
// Deterministic and synchronous: `evaluate` remembers only two durations (thermal serious/heavy since, network
// unsatisfied since) between calls; `armingBlocker` is stateless and never touches them.

import KakurenekoKit
import Foundation
import Synchronization

/// Safety policy (brief §7.4).
public final class SafetyMonitor: SafetyEvaluating {
    private struct Durations {
        /// First snapshot at which thermal state ≥ serious or pressure == heavy was seen (continuous since).
        var thermalSince: Date?
        /// First snapshot at which the network path was unsatisfied (continuous since).
        var offlineSince: Date?
    }

    private let logger: KakurenekoLogger
    private let durations = Mutex(Durations())

    /// Binding signature.
    public init(logger: KakurenekoLogger = KakurenekoLogger(.power)) {
        self.logger = logger
    }

    /// Returns the first guard that trips, or nil. Durations are updated on EVERY call (before any guard returns), so
    /// a battery trip never freezes the thermal/network clocks.
    public func evaluate(_ snapshot: PowerSnapshot, closedSince: Date, settings: SafetySettings, now: Date) -> SafetyTrip? {
        let sustainedHot = Self.isSustainedThermalCondition(snapshot)
        let offline = !snapshot.networkSatisfied
        let (thermalSince, offlineSince) = durations.withLock { d -> (Date?, Date?) in
            d.thermalSince = sustainedHot ? Self.continuing(d.thermalSince, now: now) : nil
            d.offlineSince = offline ? Self.continuing(d.offlineSince, now: now) : nil
            return (d.thermalSince, d.offlineSince)
        }

        if let trip = Self.batteryTrip(snapshot, settings: settings) {
            return tripped(trip)
        }
        if let trip = Self.immediateThermalTrip(snapshot) {
            return tripped(trip)
        }
        if sustainedHot, let since = thermalSince {
            let elapsed = now.timeIntervalSince(since)
            if elapsed >= TimeInterval(max(0, settings.thermalSeriousSeconds)) {
                let trip: SafetyTrip = snapshot.thermalState >= .serious
                    ? .thermalSerious(seconds: Int(elapsed))
                    : .thermalPressure(snapshot.thermalPressure)
                return tripped(trip)
            }
        }
        if offline, let since = offlineSince {
            let elapsed = now.timeIntervalSince(since)
            if elapsed >= TimeInterval(max(0, settings.networkOfflineMinutes)) * 60 {
                return tripped(.networkOffline(minutes: Int(elapsed / 60)))
            }
        }
        let closedFor = now.timeIntervalSince(closedSince)
        if closedFor >= TimeInterval(max(0, settings.maxClosedLidHours)) * 3600 {
            return tripped(.maxDuration(hours: closedFor / 3600))
        }
        return nil
    }

    /// STATELESS: may the Mac be (or stay) armed with the lid OPEN? nil = allowed (R01 §11.2).
    public func armingBlocker(_ snapshot: PowerSnapshot, settings: SafetySettings) -> SafetyTrip? {
        if let trip = Self.batteryTrip(snapshot, settings: settings) { return trip }
        switch snapshot.thermalState {
        case .critical: return .thermalCritical
        case .serious: return .thermalSerious(seconds: 0)
        case .nominal, .fair: break
        }
        if snapshot.thermalPressure >= .heavy { return .thermalPressure(snapshot.thermalPressure) }
        return nil
    }

    /// Forget accumulated durations (lid opened, disarmed).
    public func reset() {
        durations.withLock { $0 = Durations() }
    }

    // MARK: - Guards (pure)

    /// Battery guards shared by `evaluate` and `armingBlocker`, in priority order.
    static func batteryTrip(_ snapshot: PowerSnapshot, settings: SafetySettings) -> SafetyTrip? {
        let floor = settings.batteryFloorPercent
        if snapshot.onBattery && !settings.allowOnBattery {
            return .onBatteryNotAllowed(percent: snapshot.batteryPercent)
        }
        if snapshot.onBattery, let percent = snapshot.batteryPercent, percent <= floor {
            return .batteryFloor(percent: percent)
        }
        if snapshot.batteryWarningLevel >= .early {
            return .batteryWarning(level: snapshot.batteryWarningLevel, percent: snapshot.batteryPercent)
        }
        // `kIOPSTimeToEmptyKey` only means something while discharging (on AC it is absent or -1).
        if snapshot.onBattery, let minutes = snapshot.timeToEmptyMinutes, minutes >= 0,
           minutes < settings.minimumTimeToEmptyMinutes {
            return .lowTimeToEmpty(minutes: minutes)
        }
        if snapshot.onAC, snapshot.drainingOnAC, let percent = snapshot.batteryPercent, percent <= floor {
            return .drainingOnAC(percent: percent)
        }
        return nil
    }

    /// Thermal `.critical` or pressure ≥ trapping → trip at once.
    static func immediateThermalTrip(_ snapshot: PowerSnapshot) -> SafetyTrip? {
        if snapshot.thermalState == .critical { return .thermalCritical }
        if snapshot.thermalPressure >= .trapping { return .thermalPressure(snapshot.thermalPressure) }
        return nil
    }

    /// `.serious` thermal state or `heavy` pressure (the immediate cases trip on their own).
    static func isSustainedThermalCondition(_ snapshot: PowerSnapshot) -> Bool {
        snapshot.thermalState >= .serious || snapshot.thermalPressure >= .heavy
    }

    /// Keeps a running "since" unless it lies in the future (clock moved backwards), which restarts it at `now`.
    private static func continuing(_ since: Date?, now: Date) -> Date {
        guard let since, since <= now else { return now }
        return since
    }

    private func tripped(_ trip: SafetyTrip) -> SafetyTrip {
        logger.notice("safety guard tripped: \(trip.userReason)")
        return trip
    }
}
