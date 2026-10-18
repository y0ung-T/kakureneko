import CryptoKit
import Darwin
import Foundation
import IOKit

/// This Mac's id for iCloud (`MacStatus.macID`, what commands target), derived from the hardware and the user:
/// a hash of the machine's IOPlatformUUID and the user id, shaped as a UUID. Deleting Application Support or
/// reinstalling keeps it, so the iPhone keeps seeing one Mac instead of a new one each time; a copy of the user's
/// files on another Mac (Migration Assistant, a restore) gets a different one, so one "Sleep now" can never reach
/// two Macs. Not reversible: the hardware UUID never leaves the Mac.
enum MachineIdentity {
    static func macID() -> String? {
        guard let platform = platformUUID() else { return nil }
        return derive(platformUUID: platform, userID: getuid())
    }

    static func derive(platformUUID: String, userID: uid_t) -> String {
        let digest = SHA256.hash(data: Data("kakureneko-mac:\(platformUUID):\(userID)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5-style (name-based)
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString
    }

    private static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? String
    }
}
