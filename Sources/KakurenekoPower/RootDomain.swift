// KakurenekoPower — IOPMrootDomain reads (kernel truth) and the power assertion / activity seam.
// OWNER: agent "power". Spec card: docs/ARCHITECTURE.md §9.4 ("Testability (binding shape)"). Brief §7.2; R01 §2.3,
// §6.1; R08 §8.
//
// Both protocols are INTERNAL test seams: `PowerController`'s public init forwards to its internal designated init with
// the live implementations; tests inject fakes (never a real assertion, never seconds of real polling).

import KakurenekoKit
import Foundation
import IOKit
import IOKit.pwr_mgt
import Synchronization

// MARK: - Root domain

/// Reads IOPMrootDomain properties. Cheap, synchronous, read-only (no privilege needed).
protocol RootDomainReading: Sendable {
    /// Kernel `SleepDisabled` (`pmset -a disablesleep`). nil = unreadable.
    func sleepDisabled() -> Bool?
    /// `AppleClamshellState` (true = lid closed). nil = no lid (property absent) or unreadable.
    func clamshellClosed() -> Bool?
}

/// The live IORegistry reader (`IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))`
/// + `IORegistryEntryCreateCFProperty`). Never reads `AppleClamshellCausesSleep` (stale, ignores `SleepDisabled`).
struct LiveRootDomain: RootDomainReading {
    init() {}

    func sleepDisabled() -> Bool? {
        IORegistryReader.bool(RootDomainKey.sleepDisabled, inServiceClass: RootDomainKey.serviceClass)
    }

    func clamshellClosed() -> Bool? {
        IORegistryReader.bool(RootDomainKey.clamshellState, inServiceClass: RootDomainKey.serviceClass)
    }
}

/// Minimal read-only IORegistry helpers.
enum IORegistryReader {
    /// Copies one property of the first service matching `serviceClass`. nil when the service or property is absent.
    static func property(_ key: String, inServiceClass serviceClass: String) -> Any? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(serviceClass))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// A boolean property (`CFBoolean`, or a number where non-zero is true).
    static func bool(_ key: String, inServiceClass serviceClass: String) -> Bool? {
        switch property(key, inServiceClass: serviceClass) {
        case let value as Bool: value
        case let value as NSNumber: value.intValue != 0
        default: nil
        }
    }

    /// A signed integer property (`CFNumber`; two's-complement values such as a negative amperage stay negative).
    static func int64(_ key: String, inServiceClass serviceClass: String) -> Int64? {
        (property(key, inServiceClass: serviceClass) as? NSNumber)?.int64Value
    }
}

// MARK: - Power assertion + activity

/// `ProcessInfo.beginActivity` returns a non-Sendable `NSObjectProtocol`; it is boxed so it can live in a `Mutex`
/// (ARCHITECTURE §5 "Non-Sendable tokens in a Mutex"). Only ever handed back to `endActivity`.
final class ActivityToken: @unchecked Sendable {
    let raw: any NSObjectProtocol
    init(_ raw: any NSObjectProtocol) { self.raw = raw }
}

/// Creates/releases the `PreventUserIdleSystemSleep` assertion and the `ProcessInfo` activity held while armed.
protocol PowerAssertionMaking: Sendable {
    /// `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep, on, reason)`. nil on failure.
    func createAssertion(reason: String) -> IOPMAssertionID?
    /// `IOPMAssertionRelease`.
    func releaseAssertion(_ id: IOPMAssertionID)
    /// `ProcessInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason:)` (keeps Kakureneko un-napped
    /// without itself blocking idle sleep — the sleep policy stays with the flag).
    func beginActivity(reason: String) -> ActivityToken
    /// `ProcessInfo.endActivity`.
    func endActivity(_ token: ActivityToken)
}

/// The live assertion maker. Never used by tests.
struct LivePowerAssertionMaker: PowerAssertionMaking {
    init() {}

    func createAssertion(reason: String) -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        return result == kIOReturnSuccess ? id : nil
    }

    func releaseAssertion(_ id: IOPMAssertionID) {
        _ = IOPMAssertionRelease(id)
    }

    func beginActivity(reason: String) -> ActivityToken {
        ActivityToken(ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: reason))
    }

    func endActivity(_ token: ActivityToken) {
        ProcessInfo.processInfo.endActivity(token.raw)
    }
}

// MARK: - Chime

/// Plays a named system sound (the lid-close "bag hint"). Internal seam so tests stay silent.
protocol ChimePlaying: Sendable {
    func play(soundNamed name: String)
}

/// `NSSound(named:)?.play()` on the main thread.
struct SystemChimePlayer: ChimePlaying {
    init() {}

    func play(soundNamed name: String) {
        Task { @MainActor in
            _ = SystemSound.play(name)
        }
    }
}
