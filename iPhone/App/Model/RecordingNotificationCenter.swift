// A notification center that only records what it is asked, standing in for `UNUserNotificationCenter` in unit
// tests, SwiftUI previews and the in-app demo (Model/Demo.swift: release builds too, so the demo's categories and
// notices never reach the system). The app itself uses `SystemNotificationCenter`.

import Foundation
import UserNotifications

@MainActor
final class RecordingNotificationCenter: NotificationCenterClient {
    /// What `authorization()` reports.
    var current: NotificationAuthorization
    /// What the user answers to the permission prompt.
    var grantsRequest: Bool
    private(set) var requestCount = 0
    /// Every category set registered, in order.
    private(set) var registeredCategories: [Set<UNNotificationCategory>] = []
    private(set) var posted: [LocalNotice] = []

    init(current: NotificationAuthorization = NotificationAuthorization(status: .authorized, timeSensitive: true),
         grantsRequest: Bool = true) {
        self.current = current
        self.grantsRequest = grantsRequest
    }

    func authorization() async -> NotificationAuthorization { current }

    func requestAuthorization() async -> NotificationAuthorization {
        requestCount += 1
        if current.status == .notDetermined {
            current = grantsRequest ? NotificationAuthorization(status: .authorized, timeSensitive: true)
                                    : NotificationAuthorization(status: .denied, timeSensitive: nil)
        }
        return current
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) { registeredCategories.append(categories) }

    func post(_ notice: LocalNotice) { posted.append(notice) }

    /// What `deliveredAlerts()` reports (tests put alerts here; removals take them out).
    var delivered: [DeliveredAlert] = []

    func deliveredAlerts() async -> [DeliveredAlert] { delivered }

    func removeDelivered(identifiers: [String]) {
        delivered.removeAll { identifiers.contains($0.identifier) }
    }
}
