// The live `NotificationCenterClient`: `UNUserNotificationCenter.current()` for permission, categories and the
// app's own "couldn't reach your Mac" notices. App-only (the unit tests use `RecordingNotificationCenter`, because
// the notification center needs an app bundle).

import KakurenekoCloud
import Foundation
import os
import UserNotifications

private let log = Logger(subsystem: "com.kakureneko.Kakureneko", category: "Notifications")

@MainActor
final class SystemNotificationCenter: NotificationCenterClient {
    func authorization() async -> NotificationAuthorization {
        await Self.readAuthorization()
    }

    func requestAuthorization() async -> NotificationAuthorization {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            log.error("notification permission request failed: \(error.localizedDescription, privacy: .public)")
        }
        return await Self.readAuthorization()
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) {
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }

    func post(_ notice: LocalNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        content.threadIdentifier = NotificationIDs.threadPrefix + "notices"
        // The Mac key of an alert, so tapping a notice opens that Mac like tapping one of its alerts.
        content.userInfo = [NotificationIDs.UserInfo.macID: notice.macID]
        let request = UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil)
        // @Sendable: UserNotifications calls this on its own queue, not the main actor.
        UNUserNotificationCenter.current().add(request) { @Sendable error in
            if let error { log.error("could not post a notice: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func deliveredAlerts() async -> [DeliveredAlert] {
        await Self.readDeliveredAlerts()
    }

    func removeDelivered(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Off the main actor, like the settings (`UNNotification` is not Sendable, so only the summary leaves).
    @concurrent
    nonisolated private static func readDeliveredAlerts() async -> [DeliveredAlert] {
        await UNUserNotificationCenter.current().deliveredNotifications().compactMap { notification in
            let info = notification.request.content.userInfo
            guard let alertID = info[NotificationIDs.UserInfo.alertID] as? String,
                  let macID = info[NotificationIDs.UserInfo.macID] as? String,
                  let kind = info[NotificationIDs.UserInfo.kind] as? String else { return nil }
            return DeliveredAlert(identifier: notification.request.identifier, alertID: alertID, macID: macID, kind: kind)
        }
    }

    /// Reads the settings off the main actor (`UNNotificationSettings` is not Sendable, so only the summary leaves).
    @concurrent
    nonisolated private static func readAuthorization() async -> NotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let status: NotificationAuthorization.Status = switch settings.authorizationStatus {
        case .authorized, .ephemeral: .authorized
        case .provisional: .provisional
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
        let timeSensitive: Bool? = switch settings.timeSensitiveSetting {
        case .enabled: true
        case .disabled: false
        case .notSupported: nil
        @unknown default: nil
        }
        return NotificationAuthorization(status: status, timeSensitive: status == .notDetermined ? nil : timeSensitive)
    }
}
