// The menu's warnings (ARCHITECTURE §9.8 "Snapshot") as a pure function, and snapshot comparison for the
// leading-edge publisher.

import KakurenekoCloud
import KakurenekoKit
import Foundation

/// Everything the warning list depends on.
struct WarningInputs: Sendable, Hashable {
    var mode: OperatingMode
    /// Status as shown (possibly `simulatedForDryRun`).
    var privileged: PrivilegedStatus
    /// The real health-check result.
    var rawPrivileged: PrivilegedStatus
    var privilegedChecked: Bool
    var settings: KakurenekoSettings
    var power: PowerSnapshot?
    var effectiveLidClosed: Bool
    var isDryRun: Bool
    var appTamerRunning: Bool
    var groupingSelfTest: GroupingSelfTest?
    var notifications: NotificationStatus
    /// The REAL kernel `SleepDisabled` is set while dry-run is on (the fail-safe will clear it).
    var kernelSleepDisabledInDryRun: Bool
    var disarmFailed: Bool
    var armingBlocked: SafetyTrip?
    /// The network was "expensive" (iPhone hotspot) when the lid closed.
    var hotspotAtLidClose: Bool
    var integrations: [IntegrationStatus]
}

enum WarningsBuilder {
    /// Stable ids (`AppWarning.id`), most severe first, then in a fixed order.
    static func warnings(_ i: WarningInputs) -> [AppWarning] {
        var list: [AppWarning] = []

        if i.kernelSleepDisabledInDryRun {
            list.append(AppWarning(
                id: "kernel-sleep-disabled", severity: .critical, title: "Sleep is disabled for real",
                message: "The kernel's SleepDisabled flag is set although Kakureneko runs in dry-run. The root fail-safe clears it within a few minutes; run `sudo pmset -a disablesleep 0` to clear it now."))
        }
        if i.disarmFailed {
            list.append(AppWarning(
                id: "disarm-failed", severity: .critical, title: "Could not re-enable sleep",
                message: "Clearing the SleepDisabled flag failed. Kakureneko stopped its heartbeat, so the root fail-safe clears the flag within about 4 minutes."))
        }
        if i.privilegedChecked, i.rawPrivileged.heartbeatPathMismatch {
            let watched = i.rawPrivileged.failsafeHeartbeatPath ?? "another path"
            list.append(AppWarning(
                id: "heartbeat-path-mismatch", severity: .critical, title: "Fail-safe watches the wrong heartbeat",
                message: "The installed root fail-safe watches \(watched), not this account's heartbeat, so it would clear the flag during closed-lid sessions. Reinstall closed-lid mode."))
        }
        if i.privilegedChecked, i.rawPrivileged.failsafeScriptMismatch, !i.rawPrivileged.heartbeatPathMismatch {
            list.append(AppWarning(
                id: "failsafe-damaged", severity: .critical, title: "Fail-safe needs reinstalling",
                message: "The installed root fail-safe is missing, damaged or from another version of Kakureneko, so nothing would re-enable sleep if Kakureneko stopped. Closed-lid mode is off until you reinstall it."))
        }
        if i.privilegedChecked, i.settings.general.enabled, !i.privileged.simulated, !i.rawPrivileged.isOperational,
           !i.rawPrivileged.needsReinstall {
            list.append(AppWarning(
                id: "privileged-missing", severity: .warning, title: "Closed-lid mode not installed",
                message: "Kakureneko only sends notifications: it cannot keep the Mac awake with the lid closed or pause apps. Install closed-lid mode in Settings (one admin prompt)."))
        }
        if let trip = i.armingBlocked {
            list.append(AppWarning(
                id: "arming-blocked", severity: .warning, title: "Not keeping the Mac awake",
                message: "Closed-lid mode is blocked right now: \(trip.userReason)."))
        }
        if i.appTamerRunning {
            list.append(AppWarning(
                id: "app-tamer", severity: .warning, title: "App Tamer is running",
                message: "App Tamer resumes processes that other apps paused. Quit it while you are away, or turn off Kakureneko's pausing."))
        }
        if i.hotspotAtLidClose, i.effectiveLidClosed {
            list.append(AppWarning(
                id: "hotspot", severity: .warning, title: "On a phone hotspot",
                message: "The Mac is on an expensive network (probably your iPhone's hotspot). If you take the phone away, the agents and Kakureneko lose the network."))
        }
        let notify = i.settings.notifications
        if notify.enabled, notify.macAlerts, i.notifications.macAuthorization == .denied {
            list.append(AppWarning(
                id: "mac-notifications-off", severity: .info, title: "Mac notifications are off",
                message: "Allow notifications for Kakureneko in System Settings → Notifications to see alerts on this Mac."))
        }
        if notify.enabled, notify.phoneAlerts {
            switch i.notifications.iCloud {
            case .noAccount, .restricted, .unavailableInThisBuild:
                list.append(AppWarning(
                    id: "icloud-unavailable", severity: .info, title: "iPhone alerts unavailable",
                    message: i.notifications.iCloud.explanation))
            case .available, .temporarilyUnavailable, .couldNotDetermine:
                if let error = i.notifications.lastError {
                    list.append(AppWarning(
                        id: "phone-alerts-error", severity: .warning, title: "iPhone alerts are failing", message: error))
                }
            }
        }
        for status in i.integrations where status.needsRepair {
            list.append(AppWarning(
                id: "integration-repair:\(status.agent.rawValue)", severity: .warning,
                title: "\(status.agent.displayName) integration needs repair",
                message: "Kakureneko's hook in \(status.agent.displayName)'s settings is missing or out of date, so its sessions may not show up."))
        }
        if i.settings.pausing.mode == .freeze, i.groupingSelfTest?.freezeAllowed != true {
            let method = i.groupingSelfTest?.method.rawValue ?? "not run"
            list.append(AppWarning(
                id: "freeze-unavailable", severity: .info, title: "Freeze unavailable",
                message: "The process-grouping self-test did not allow Freeze (\(method)); Kakureneko throttles apps instead."))
        }
        if i.settings.safety.warnLowPowerMode, let power = i.power, power.lowPowerMode, power.onBattery {
            list.append(AppWarning(
                id: "low-power-mode", severity: .info, title: "Low Power Mode: agents run slower",
                message: "Agents keep working on battery, but slower."))
        }
        if i.isDryRun {
            list.append(AppWarning(
                id: "dry-run", severity: .info, title: "Dry run",
                message: "Kakureneko only logs what it would do (arm, sleep, pause, publish); nothing is changed on this Mac."))
        }
        if i.privileged.simulated {
            list.append(AppWarning(
                id: "dry-run-privileged-simulated", severity: .info, title: "Closed-lid mode simulated",
                message: "Closed-lid mode is not installed; dry-run simulates it so every decision is visible."))
        }

        let rank: [AppWarning.Severity: Int] = [.critical: 0, .warning: 1, .info: 2]
        return list.enumerated()
            .sorted { (rank[$0.element.severity] ?? 3, $0.offset) < (rank[$1.element.severity] ?? 3, $1.offset) }
            .map(\.element)
    }
}

extension AppSnapshot {
    /// Equal apart from `generatedAt` (the publisher only republishes real changes).
    func isEquivalent(to other: AppSnapshot) -> Bool {
        var copy = self
        copy.generatedAt = other.generatedAt
        return copy == other
    }
}
