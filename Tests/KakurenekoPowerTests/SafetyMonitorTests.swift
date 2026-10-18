@testable import KakurenekoPower
import KakurenekoKit
import Foundation
import Testing

/// Brief §7.4 / ARCHITECTURE §9.4: every guard, its duration, `reset()`, and the stateless `armingBlocker`.
@Suite("SafetyMonitor", .timeLimit(.minutes(1)))
struct SafetyMonitorTests {
    static let t0 = TestClock.defaultStart
    static let settings = SafetySettings()

    /// A healthy closed-lid snapshot on battery (above every limit).
    static func healthy(at date: Date = t0) -> PowerSnapshot {
        PowerSnapshot(takenAt: date, lid: .closed, batteryPercent: 80, onAC: false, isCharging: false,
                      timeToEmptyMinutes: 240, batteryWarningLevel: .none, thermalState: .nominal,
                      thermalPressure: .nominal, networkSatisfied: true)
    }

    static func modified(_ change: (inout PowerSnapshot) -> Void) -> PowerSnapshot {
        var snapshot = healthy()
        change(&snapshot)
        return snapshot
    }

    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var snapshot: PowerSnapshot
        var settings: SafetySettings = SafetyMonitorTests.settings
        var expected: SafetyTrip?
        var testDescription: String { name }
    }

    static let immediateCases: [Case] = [
        Case(name: "healthy on battery", snapshot: healthy(), expected: nil),
        Case(name: "healthy on AC", snapshot: modified { $0.onAC = true; $0.timeToEmptyMinutes = nil }, expected: nil),
        Case(name: "on battery not allowed", snapshot: healthy(),
             settings: { var s = SafetySettings(); s.allowOnBattery = false; return s }(),
             expected: .onBatteryNotAllowed(percent: 80)),
        Case(name: "on AC with battery not allowed", snapshot: modified { $0.onAC = true; $0.timeToEmptyMinutes = nil },
             settings: { var s = SafetySettings(); s.allowOnBattery = false; return s }(), expected: nil),
        Case(name: "battery at the floor", snapshot: modified { $0.batteryPercent = 20 }, expected: .batteryFloor(percent: 20)),
        Case(name: "battery below the floor", snapshot: modified { $0.batteryPercent = 19 }, expected: .batteryFloor(percent: 19)),
        Case(name: "battery just above the floor", snapshot: modified { $0.batteryPercent = 21 }, expected: nil),
        Case(name: "custom floor 35 %", snapshot: modified { $0.batteryPercent = 30 },
             settings: { var s = SafetySettings(); s.batteryFloorPercent = 35; return s }(), expected: .batteryFloor(percent: 30)),
        Case(name: "low battery on AC charging", snapshot: modified { $0.onAC = true; $0.batteryPercent = 10; $0.timeToEmptyMinutes = nil },
             expected: nil),
        Case(name: "warning level early", snapshot: modified { $0.batteryWarningLevel = .early },
             expected: .batteryWarning(level: .early, percent: 80)),
        Case(name: "warning level final", snapshot: modified { $0.batteryWarningLevel = .final },
             expected: .batteryWarning(level: .final, percent: 80)),
        Case(name: "time to empty below the limit", snapshot: modified { $0.timeToEmptyMinutes = 24 },
             expected: .lowTimeToEmpty(minutes: 24)),
        Case(name: "time to empty at the limit", snapshot: modified { $0.timeToEmptyMinutes = 25 }, expected: nil),
        Case(name: "time to empty ignored on AC", snapshot: modified { $0.onAC = true; $0.timeToEmptyMinutes = 5 }, expected: nil),
        Case(name: "draining on AC below the floor",
             snapshot: modified { $0.onAC = true; $0.drainingOnAC = true; $0.batteryPercent = 18; $0.timeToEmptyMinutes = nil },
             expected: .drainingOnAC(percent: 18)),
        Case(name: "draining on AC above the floor",
             snapshot: modified { $0.onAC = true; $0.drainingOnAC = true; $0.batteryPercent = 60; $0.timeToEmptyMinutes = nil },
             expected: nil),
        Case(name: "thermal critical", snapshot: modified { $0.thermalState = .critical }, expected: .thermalCritical),
        Case(name: "pressure trapping", snapshot: modified { $0.thermalPressure = .trapping }, expected: .thermalPressure(.trapping)),
        Case(name: "pressure sleeping", snapshot: modified { $0.thermalPressure = .sleeping }, expected: .thermalPressure(.sleeping)),
        Case(name: "thermal fair", snapshot: modified { $0.thermalState = .fair }, expected: nil),
        Case(name: "pressure moderate", snapshot: modified { $0.thermalPressure = .moderate }, expected: nil),
        Case(name: "pressure unknown", snapshot: modified { $0.thermalPressure = .unknown }, expected: nil),
        Case(name: "low power mode never trips", snapshot: modified { $0.lowPowerMode = true }, expected: nil),
        Case(name: "no battery (desktop)", snapshot: modified { $0.onAC = true; $0.batteryPercent = nil; $0.timeToEmptyMinutes = nil },
             expected: nil),
    ]

    @Test(arguments: immediateCases)
    func immediateGuards(_ testCase: Case) {
        let monitor = SafetyMonitor()
        let trip = monitor.evaluate(testCase.snapshot, closedSince: Self.t0, settings: testCase.settings, now: Self.t0)
        #expect(trip == testCase.expected)
    }

    @Test func batteryGuardsBeatThermalAndOrderIsStable() {
        let monitor = SafetyMonitor()
        let snapshot = Self.modified { $0.batteryPercent = 15; $0.thermalState = .critical; $0.batteryWarningLevel = .final }
        #expect(monitor.evaluate(snapshot, closedSince: Self.t0, settings: Self.settings, now: Self.t0) == .batteryFloor(percent: 15))
        var notAllowed = SafetySettings()
        notAllowed.allowOnBattery = false
        #expect(monitor.evaluate(snapshot, closedSince: Self.t0, settings: notAllowed, now: Self.t0) == .onBatteryNotAllowed(percent: 15))
    }

    @Test func thermalSeriousTripsAfterSixtySecondsContinuously() {
        let monitor = SafetyMonitor()
        let hot = Self.modified { $0.thermalState = .serious }
        for seconds in [0, 15, 30, 45, 59] {
            #expect(monitor.evaluate(hot, closedSince: Self.t0, settings: Self.settings, now: Self.t0 + TimeInterval(seconds)) == nil)
        }
        #expect(monitor.evaluate(hot, closedSince: Self.t0, settings: Self.settings, now: Self.t0 + 60) == .thermalSerious(seconds: 60))
    }

    @Test func heavyPressureTripsAfterTheSameDuration() {
        let monitor = SafetyMonitor()
        let heavy = Self.modified { $0.thermalPressure = .heavy }
        #expect(monitor.evaluate(heavy, closedSince: Self.t0, settings: Self.settings, now: Self.t0) == nil)
        #expect(monitor.evaluate(heavy, closedSince: Self.t0, settings: Self.settings, now: Self.t0 + 59) == nil)
        #expect(monitor.evaluate(heavy, closedSince: Self.t0, settings: Self.settings, now: Self.t0 + 61) == .thermalPressure(.heavy))
    }

    @Test func thermalDurationRestartsWhenItCoolsDown() {
        let monitor = SafetyMonitor()
        let hot = Self.modified { $0.thermalState = .serious }
        let cool = Self.healthy()
        #expect(monitor.evaluate(hot, closedSince: Self.t0, settings: Self.settings, now: Self.t0) == nil)
        #expect(monitor.evaluate(hot, closedSince: Self.t0, settings: Self.settings, now: Self.t0 + 45) == nil)
        #expect(monitor.evaluate(cool, closedSince: Self.t0, settings: Self.settings, now: Self.t0 + 50) == nil)
        #expect(monitor.evaluate(hot, closedSince: Self.t0, settings: Self.settings, now: Self.t0 + 60) == nil)
        #expect(monitor.evaluate(hot, closedSince: Self.t0, settings: Self.settings, now: Self.t0 + 119) == nil)
        #expect(monitor.evaluate(hot, closedSince: Self.t0, settings: Self.settings, now: Self.t0 + 120) == .thermalSerious(seconds: 60))
    }

    @Test func customThermalDuration() {
        let monitor = SafetyMonitor()
        var settings = SafetySettings()
        settings.thermalSeriousSeconds = 10
        let hot = Self.modified { $0.thermalState = .serious }
        #expect(monitor.evaluate(hot, closedSince: Self.t0, settings: settings, now: Self.t0) == nil)
        #expect(monitor.evaluate(hot, closedSince: Self.t0, settings: settings, now: Self.t0 + 10) == .thermalSerious(seconds: 10))
    }

    @Test func networkOfflineTripsAfterFifteenMinutes() {
        let monitor = SafetyMonitor()
        let offline = Self.modified { $0.networkSatisfied = false }
        #expect(monitor.evaluate(offline, closedSince: Self.t0, settings: Self.settings, now: Self.t0) == nil)
        #expect(monitor.evaluate(offline, closedSince: Self.t0, settings: Self.settings, now: Self.t0 + 14 * 60 + 59) == nil)
        #expect(monitor.evaluate(offline, closedSince: Self.t0, settings: Self.settings, now: Self.t0 + 15 * 60) == .networkOffline(minutes: 15))
    }

    @Test func networkBackOnlineRestartsTheClock() {
        let monitor = SafetyMonitor()
        let offline = Self.modified { $0.networkSatisfied = false }
        _ = monitor.evaluate(offline, closedSince: Self.t0, settings: Self.settings, now: Self.t0)
        _ = monitor.evaluate(Self.healthy(), closedSince: Self.t0, settings: Self.settings, now: Self.t0 + 10 * 60)
        #expect(monitor.evaluate(offline, closedSince: Self.t0, settings: Self.settings, now: Self.t0 + 15 * 60) == nil)
        #expect(monitor.evaluate(offline, closedSince: Self.t0, settings: Self.settings, now: Self.t0 + 30 * 60) == .networkOffline(minutes: 15))
    }

    @Test func maxClosedLidDuration() {
        let monitor = SafetyMonitor()
        let healthy = Self.healthy()
        #expect(monitor.evaluate(healthy, closedSince: Self.t0, settings: Self.settings, now: Self.t0 + 12 * 3600 - 1) == nil)
        #expect(monitor.evaluate(healthy, closedSince: Self.t0, settings: Self.settings, now: Self.t0 + 12 * 3600) == .maxDuration(hours: 12))
        var short = SafetySettings()
        short.maxClosedLidHours = 1
        #expect(monitor.evaluate(healthy, closedSince: Self.t0, settings: short, now: Self.t0 + 5400) == .maxDuration(hours: 1.5))
        // A future closedSince (clock skew) never trips.
        #expect(monitor.evaluate(healthy, closedSince: Self.t0 + 60, settings: Self.settings, now: Self.t0) == nil)
    }

    @Test func resetClearsDurations() {
        let monitor = SafetyMonitor()
        let hot = Self.modified { $0.thermalState = .serious; $0.networkSatisfied = false }
        _ = monitor.evaluate(hot, closedSince: Self.t0, settings: Self.settings, now: Self.t0)
        monitor.reset()
        #expect(monitor.evaluate(hot, closedSince: Self.t0, settings: Self.settings, now: Self.t0 + 61) == nil)
        #expect(monitor.evaluate(hot, closedSince: Self.t0, settings: Self.settings, now: Self.t0 + 121) == .thermalSerious(seconds: 60))
        monitor.reset()
        let offline = Self.modified { $0.networkSatisfied = false }
        _ = monitor.evaluate(offline, closedSince: Self.t0, settings: Self.settings, now: Self.t0 + 200)
        #expect(monitor.evaluate(offline, closedSince: Self.t0, settings: Self.settings, now: Self.t0 + 200 + 14 * 60) == nil)
    }

    @Test func durationsKeepRunningWhileAnotherGuardTrips() {
        let monitor = SafetyMonitor()
        let hotAndLow = Self.modified { $0.thermalState = .serious; $0.batteryPercent = 10 }
        #expect(monitor.evaluate(hotAndLow, closedSince: Self.t0, settings: Self.settings, now: Self.t0) == .batteryFloor(percent: 10))
        let hot = Self.modified { $0.thermalState = .serious }
        #expect(monitor.evaluate(hot, closedSince: Self.t0, settings: Self.settings, now: Self.t0 + 60) == .thermalSerious(seconds: 60))
    }

    // MARK: armingBlocker (stateless)

    static let blockerCases: [Case] = [
        Case(name: "healthy", snapshot: healthy(), expected: nil),
        Case(name: "battery not allowed", snapshot: healthy(),
             settings: { var s = SafetySettings(); s.allowOnBattery = false; return s }(), expected: .onBatteryNotAllowed(percent: 80)),
        Case(name: "floor", snapshot: modified { $0.batteryPercent = 20 }, expected: .batteryFloor(percent: 20)),
        Case(name: "warning", snapshot: modified { $0.batteryWarningLevel = .early }, expected: .batteryWarning(level: .early, percent: 80)),
        Case(name: "time to empty", snapshot: modified { $0.timeToEmptyMinutes = 10 }, expected: .lowTimeToEmpty(minutes: 10)),
        Case(name: "draining on AC", snapshot: modified { $0.onAC = true; $0.drainingOnAC = true; $0.batteryPercent = 12; $0.timeToEmptyMinutes = nil },
             expected: .drainingOnAC(percent: 12)),
        Case(name: "thermal serious", snapshot: modified { $0.thermalState = .serious }, expected: .thermalSerious(seconds: 0)),
        Case(name: "thermal critical", snapshot: modified { $0.thermalState = .critical }, expected: .thermalCritical),
        Case(name: "thermal fair allowed", snapshot: modified { $0.thermalState = .fair }, expected: nil),
        Case(name: "pressure heavy", snapshot: modified { $0.thermalPressure = .heavy }, expected: .thermalPressure(.heavy)),
        Case(name: "pressure trapping", snapshot: modified { $0.thermalPressure = .trapping }, expected: .thermalPressure(.trapping)),
        Case(name: "pressure moderate allowed", snapshot: modified { $0.thermalPressure = .moderate }, expected: nil),
        Case(name: "network offline allowed", snapshot: modified { $0.networkSatisfied = false }, expected: nil),
        Case(name: "low power mode allowed", snapshot: modified { $0.lowPowerMode = true }, expected: nil),
    ]

    @Test(arguments: blockerCases)
    func armingBlockers(_ testCase: Case) {
        #expect(SafetyMonitor().armingBlocker(testCase.snapshot, settings: testCase.settings) == testCase.expected)
    }

    @Test func armingBlockerLeavesEvaluateDurationsUntouched() {
        let monitor = SafetyMonitor()
        let hot = Self.modified { $0.thermalState = .serious }
        // Start the thermal clock through evaluate …
        #expect(monitor.evaluate(hot, closedSince: Self.t0, settings: Self.settings, now: Self.t0) == nil)
        // … the stateless blocker sees cool and hot snapshots in between …
        #expect(monitor.armingBlocker(Self.healthy(), settings: Self.settings) == nil)
        #expect(monitor.armingBlocker(hot, settings: Self.settings) == .thermalSerious(seconds: 0))
        // … and evaluate's clock still started at t0 (a cool armingBlocker call did not reset it).
        #expect(monitor.evaluate(hot, closedSince: Self.t0, settings: Self.settings, now: Self.t0 + 60) == .thermalSerious(seconds: 60))

        // Conversely the blocker never starts a duration: evaluate's first hot reading starts at its own `now`.
        let fresh = SafetyMonitor()
        for _ in 0..<5 { _ = fresh.armingBlocker(hot, settings: Self.settings) }
        #expect(fresh.evaluate(hot, closedSince: Self.t0, settings: Self.settings, now: Self.t0 + 1000) == nil)
        #expect(fresh.evaluate(hot, closedSince: Self.t0, settings: Self.settings, now: Self.t0 + 1059) == nil)
    }

    @Test func userReasonsReadNaturally() {
        #expect(SafetyTrip.batteryFloor(percent: 19).userReason == "battery 19 %")
        #expect(SafetyTrip.networkOffline(minutes: 15).userReason == "offline 15 min")
        #expect(SafetyTrip.thermalSerious(seconds: 60).userReason == "too hot")
    }
}
