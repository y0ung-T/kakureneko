// What the iPhone model layer needs from the device and the system, as plain values and one protocol, so that
// `PhoneStore` runs unchanged in the app (live implementations in iPhone/App/Platform), in unit tests and in
// SwiftUI previews (`RecordingNotificationCenter`). Also the injectable clock: every timeout, backoff and expiry
// decision reads `PhoneClock`, which tests advance by hand.

import Foundation
import UserNotifications

/// Where `PhoneStore` reads the current time. Live: the system clock; tests: a hand-advanced clock.
struct PhoneClock: Sendable {
    let now: @Sendable () -> Date

    static let system = PhoneClock(now: { Date() })
}

/// This iPhone, as its `PhoneDevice` record describes it.
struct DeviceInfo: Sendable, Hashable, Codable {
    /// "iPhone" (iOS hides the user-assigned name from apps without a special entitlement).
    var name: String
    /// Hardware identifier ("iPhone18,3").
    var model: String
    /// iOS version ("26.0.1").
    var systemVersion: String
    /// "0.1.0 (1)".
    var appVersion: String
}

/// Notification permission of this app, as the screens and the Mac (via `PhoneDevice`) see it.
struct NotificationAuthorization: Sendable, Hashable, Codable {
    enum Status: String, Sendable, Hashable, Codable {
        case notDetermined, denied, authorized, provisional
    }

    var status: Status
    /// Time Sensitive alerts allowed (nil = unknown, e.g. before the user decided).
    var timeSensitive: Bool?

    /// Banners and sounds can reach the user.
    var alertsAllowed: Bool { status == .authorized || status == .provisional }
}

/// A notification the app posts itself (a button tap it could not deliver to the Mac).
struct LocalNotice: Sendable, Hashable {
    /// Request identifier: a newer notice for the same Mac replaces the older one.
    var identifier: String
    var title: String
    var body: String
    /// Tapping the notice opens the app on this Mac.
    var macID: String

    static func couldNotReach(macID: String, macName: String) -> LocalNotice {
        LocalNotice(identifier: "com.kakureneko.unsent.\(macID)", title: "Couldn't reach \(macName)",
                    body: "Open Kakureneko to retry.", macID: macID)
    }

    static func expiredAlert(macID: String, macName: String) -> LocalNotice {
        LocalNotice(identifier: "com.kakureneko.expired.\(macID)", title: "That alert has expired",
                    body: "Open Kakureneko to see what \(macName) is doing now.", macID: macID)
    }
}

/// The parts of `UNUserNotificationCenter` the model uses. Live: `SystemNotificationCenter`; tests and previews:
/// `RecordingNotificationCenter`.
@MainActor
protocol NotificationCenterClient: AnyObject {
    func authorization() async -> NotificationAuthorization
    /// Asks for alerts, sounds and badges (shows the system prompt once) and returns the resulting permission.
    func requestAuthorization() async -> NotificationAuthorization
    func setCategories(_ categories: Set<UNNotificationCategory>)
    /// Fire-and-forget: also called from a background task's expiration handler, which cannot wait.
    func post(_ notice: LocalNotice)
    /// The Mac alerts in Notification Center (only notifications that carry an alert id and a Mac).
    func deliveredAlerts() async -> [DeliveredAlert]
    func removeDelivered(identifiers: [String])
}

/// A Mac alert still shown in Notification Center.
struct DeliveredAlert: Equatable, Sendable {
    /// `UNNotificationRequest.identifier`.
    var identifier: String
    var alertID: String
    var macID: String
    var kind: String
}
