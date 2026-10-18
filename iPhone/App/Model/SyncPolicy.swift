// Small decision rules of the sync loop, kept as pure values so tests can pin them down: how reachable iCloud is
// (`ConnectionState`), how long to wait after a failure (`RetryBackoff`), what a sync achieved (`SyncOutcome`) and
// when this iPhone's `PhoneDevice` record must be saved again (`DeviceRecordPolicy`).

import KakurenekoCloud
import Foundation

/// How the last sync went (the screens show "offline" banners from it).
enum ConnectionState: Equatable, Sendable {
    /// No sync finished yet in this process.
    case unknown
    case online
    /// iCloud unreachable (network, rate limit); the next automatic attempt waits until `retryAt`.
    case offline(retryAt: Date)
    /// iCloud refused (storage full, unexpected error); retried after `retryAt`.
    case failed(message: String, retryAt: Date)

    /// Automatic syncs before this are skipped (pull-to-refresh and pushes still try).
    var retryAt: Date? {
        switch self {
        case .offline(let date), .failed(_, let date): date
        case .unknown, .online: nil
        }
    }
}

/// What one `PhoneStore.sync` did (a silent push reports it to iOS).
enum SyncOutcome: Equatable, Sendable {
    /// Statuses or alerts changed.
    case changed
    case unchanged
    /// Waiting for the backoff to pass.
    case skipped
    /// No usable iCloud account.
    case unavailable
    case failed
}

/// Exponential backoff after failed syncs: 5 s, 10 s, 20 s … capped at 5 min, or CloudKit's own hint if longer.
struct RetryBackoff: Equatable, Sendable {
    static let base: TimeInterval = 5
    static let maximum: TimeInterval = 5 * 60

    private(set) var failures = 0

    /// Records one more failure and returns how long to wait before the next automatic attempt.
    mutating func nextDelay(hint: TimeInterval?) -> TimeInterval {
        failures += 1
        let exponential = min(Self.maximum, Self.base * pow(2, Double(min(failures - 1, 16))))
        return max(hint ?? 0, exponential)
    }

    mutating func reset() { failures = 0 }
}

/// When the `PhoneDevice` record is saved: at the first foreground launch of the process, whenever notification
/// permission or the device / app version changed, and otherwise at most every `interval`.
enum DeviceRecordPolicy {
    static let interval: TimeInterval = 6 * 3600

    static func isDue(last: DeviceRecordStamp?, authorization: NotificationAuthorization, device: DeviceInfo,
                      launchPending: Bool, now: Date) -> Bool {
        guard let last else { return true }
        if launchPending || last.authorization != authorization || last.device != device { return true }
        let age = now.timeIntervalSince(last.savedAt)
        return age >= interval || age < 0
    }
}

extension CloudError {
    /// Worth keeping a command queued for: the next attempt may well succeed (back online, signed in again, zone
    /// recreated). Anything else is dropped with an error message.
    var isWorthRetryingLater: Bool {
        switch self {
        case .network, .rateLimited, .notSignedIn, .zoneMissing: true
        case .changeTokenExpired, .quotaExceeded, .unknownRecordType, .permanent: false
        }
    }
}
