// KakurenekoPower — IOKit/power-management constants.
// OWNER: agent "power". Spec card: docs/ARCHITECTURE.md §9.4. Brief §7.2; R01 §1, §6; R08 §8.
//
// The IOKit message values are C macros (`iokit_common_msg`, `iokit_family_msg`) that Swift does not import, so they
// are hand-defined here (R08 §8: "cannot find 'kIOMessageCanSystemSleep' in scope"). Values derived from the SDK
// headers `IOKit/IOMessage.h`, `IOKit/IOReturn.h`, `mach/error.h` and `IOKit/pwr_mgt/IOPM.h`.

import Foundation
import IOKit

/// IOKit message types delivered to interest / system-power callbacks.
enum IOKitMessage {
    /// `kIOPMMessageClamshellStateChange` = `iokit_family_msg(sub_iokit_powermanagement, 0x100)`.
    /// Argument bits: `kClamshellStateBit` (1 << 0) = lid closed, `kClamshellSleepBit` (1 << 1) — never used: it
    /// ignores `SleepDisabled` (R01 §1). Also fires on AC plug/unplug and desktop-mode changes, so callers compare
    /// against the last known state.
    static let clamshellStateChange: UInt32 = 0xE003_4100
    /// `kIOMessageCanSystemSleep` = `iokit_common_msg(0x270)` — idle sleep only; must be answered.
    static let canSystemSleep: UInt32 = 0xE000_0270
    /// `kIOMessageSystemWillSleep` = `iokit_common_msg(0x280)` — must be answered (`IOAllowPowerChange`).
    static let systemWillSleep: UInt32 = 0xE000_0280
    /// `kIOMessageSystemWillNotSleep` = `iokit_common_msg(0x290)`.
    static let systemWillNotSleep: UInt32 = 0xE000_0290
    /// `kIOMessageSystemHasPoweredOn` = `iokit_common_msg(0x300)`.
    static let systemHasPoweredOn: UInt32 = 0xE000_0300
    /// `kIOMessageSystemWillPowerOn` = `iokit_common_msg(0x320)`.
    static let systemWillPowerOn: UInt32 = 0xE000_0320

    /// `kClamshellStateBit`.
    static let clamshellStateBit: UInt = 1 << 0
}

/// `IOReturn` codes (`iokit_common_err(x)` = `0xE0000000 | x`, as a signed `kern_return_t`).
enum IOKitReturn {
    static let success: IOReturn = 0
    /// `kIOReturnNotPermitted` (0xE00002E2): `IOPMSleepSystem` while `SleepDisabled` is set.
    static let notPermitted = IOReturn(bitPattern: 0xE000_02E2)
    /// `kIOReturnNotPrivileged` (0xE00002C1): not root / not the console user.
    static let notPrivileged = IOReturn(bitPattern: 0xE000_02C1)

    /// `0xE00002E2` style hex for logs.
    static func describe(_ code: IOReturn) -> String {
        "0x" + String(UInt32(bitPattern: code), radix: 16, uppercase: true)
    }
}

/// IORegistry names (exact registry keys; R01 §6.1, R08 §8).
enum RootDomainKey {
    /// The IOService class matched with `IOServiceMatching` (the `IOService:/IOResources/IOPMrootDomain` path does
    /// not resolve on 26.x, R01 §6.1).
    static let serviceClass = "IOPMrootDomain"
    /// Kernel `userDisabledAllSleep` mirror (`pmset -a disablesleep`).
    static let sleepDisabled = "SleepDisabled"
    /// Lid state (true = closed). Absent on Macs without a lid. NEVER `AppleClamshellCausesSleep` (stale).
    static let clamshellState = "AppleClamshellState"
    /// `AppleSmartBattery` service class and its signed current (mA; negative = discharging).
    static let smartBatteryClass = "AppleSmartBattery"
    static let instantAmperage = "InstantAmperage"
    static let amperage = "Amperage"
}

/// Darwin notification names used by the monitor and the snapshot reader.
enum PowerNotifyName {
    /// `kOSThermalNotificationPressureLevelName` (`libkern/OSThermalNotification.h`).
    static let thermalPressureLevel = "com.apple.system.thermalpressurelevel"
    /// `kIOPSNotifyPowerSource` (AC ↔ battery).
    static let powerSource = "com.apple.system.powersources.source"
    /// `kIOPSNotifyLowBattery` (warning level changes).
    static let lowBattery = "com.apple.system.powersources.lowbattery"
    /// `kIOPSNotifyPercentChange` (battery percentage changed).
    static let percentChange = "com.apple.system.powersources.percent"
}

/// Apple Event codes for the polite shutdown (`kCoreEventClass` / `kAEShutDown`, `AE/AERegistry.h`).
enum AppleEventCode {
    /// `'aevt'`
    static let coreEventClass = fourCharCode("aevt")
    /// `'shut'`
    static let shutDown = fourCharCode("shut")
    /// `kAutoGenerateReturnID`
    static let autoGenerateReturnID: AEReturnID = -1
    /// `kAnyTransactionID`
    static let anyTransactionID: AETransactionID = 0
    /// `errAEEventNotPermitted` (Automation consent denied).
    static let eventNotPermitted = -1743
    /// `errAEEventWouldRequireUserConsent`.
    static let eventWouldRequireUserConsent = -1744
    /// `userCanceledErr` (admin prompt cancelled).
    static let userCanceled = -128

    static func fourCharCode(_ text: String) -> FourCharCode {
        text.utf8.prefix(4).reduce(FourCharCode(0)) { ($0 << 8) | FourCharCode($1) }
    }
}
