// The Notification Service Extension of Kakureneko for iPhone (docs/NATIVE-NOTIFICATIONS.md §4.1): every `alerts-v1`
// push (mutable-content) passes through here. It rebuilds the alert from the push's record fields — or, when
// CloudKit left fields out, fetches the record — and replaces the generic push text with the same content the Mac
// shows (`AlertPresentation.content`): title, Mac name, buttons, thread, interruption level. An older notification
// with the same replace key from the same Mac (the countdown, a session's wait) is removed first. If time runs out,
// the best content built so far is delivered. Waits and sleep alerts carry Soot as a thumbnail ("design language/
// DESIGN.md" §7: a sticker pose on paper, Artwork/alert-<pose>.png rendered by scripts/make-icon.sh).

import CloudKit
import KakurenekoCloud
import Foundation
import os
import UserNotifications

private let log = Logger(subsystem: "com.kakureneko.Kakureneko.alerts", category: "NotificationService")

final class NotificationService: UNNotificationServiceExtension {
    private var delivery: NotificationDelivery?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let delivery = NotificationDelivery(handler: contentHandler, fallback: request.content)
        self.delivery = delivery
        switch AlertPush(userInfo: request.content.userInfo) {
        case .alert(let alert):
            delivery.improve(AlertContent.content(for: alert))
            Task { await AlertContent.finish(alert, delivery: delivery) }
        case .incomplete(let alertID):
            Task { await AlertContent.fetchAndFinish(alertID: alertID, delivery: delivery) }
        case .notAnAlert:
            delivery.deliver()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        delivery?.deliver()
    }
}

/// Building and finishing an alert's notification.
private enum AlertContent {
    /// The notification for `alert`; a schema-bootstrap placeholder (a fresh container's setup record) gets empty,
    /// silent content so nothing meaningful is shown for it.
    static func content(for alert: CloudAlert) -> UNNotificationContent {
        guard !CloudSchemaBootstrap.isPlaceholder(.alert(alert)) else {
            let silent = UNMutableNotificationContent()
            silent.interruptionLevel = .passive
            return silent
        }
        let content = AlertPresentation.content(for: alert, now: Date(), showMacName: true)
        if let attachment = poseAttachment(for: alert.kind) { content.attachments = [attachment] }
        return content
    }

    /// The pose thumbnail for an alert kind (`NotificationKind` raw values): waving for a wait, asleep for the
    /// countdown and the Mac going to sleep; nil for the rest or if the file can't be attached.
    static func poseAttachment(for kind: String) -> UNNotificationAttachment? {
        let pose: String
        switch kind {
        case "needsInput": pose = "wave"
        case "countdown", "asleep": pose = "sleep"
        default: return nil
        }
        guard let source = Bundle.main.url(forResource: "alert-\(pose)", withExtension: "png") else { return nil }
        // iOS moves an attachment's file into its own store: hand it a copy, never the bundle's file.
        let copy = FileManager.default.temporaryDirectory.appending(path: "alert-\(pose)-\(UUID().uuidString).png")
        do {
            try FileManager.default.copyItem(at: source, to: copy)
            return try UNNotificationAttachment(identifier: "pose", url: copy, options: nil)
        } catch {
            log.notice("no pose thumbnail: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The alert record for a push that arrived without its fields; the push's fallback text if it can't be had.
    static func fetchAndFinish(alertID: String, delivery: NotificationDelivery) async {
        guard let alert = await fetchAlert(alertID) else {
            delivery.deliver()
            return
        }
        delivery.improve(content(for: alert))
        await finish(alert, delivery: delivery)
    }

    /// Removes the notifications this alert replaces, then delivers it.
    static func finish(_ alert: CloudAlert, delivery: NotificationDelivery) async {
        if let replaceKey = alert.replaceKey {
            let center = UNUserNotificationCenter.current()
            let replaced = await center.deliveredNotifications()
                .filter {
                    let info = $0.request.content.userInfo
                    return info[NotificationIDs.UserInfo.replaceKey] as? String == replaceKey
                        && info[NotificationIDs.UserInfo.macID] as? String == alert.macID
                }
                .map(\.request.identifier)
            if !replaced.isEmpty { center.removeDeliveredNotifications(withIdentifiers: replaced) }
        }
        delivery.deliver()
    }

    /// The alert record, when the push arrived without its fields (nil: gone, unreadable, or iCloud unreachable —
    /// then the push's own fallback text is shown).
    private static func fetchAlert(_ alertID: String) async -> CloudAlert? {
        guard let store = CloudKitStore.makeIfEntitled() else { return nil }
        do throws(CloudError) {
            guard case .alert(let alert)? = try await store.fetch(.alert(alertID)) else { return nil }
            return alert
        } catch {
            log.notice("could not fetch alert: \(error.description, privacy: .public)")
            return nil
        }
    }
}

/// What a push carries, read synchronously from its payload (the payload itself is not Sendable).
private enum AlertPush {
    /// Every field was in the payload.
    case alert(CloudAlert)
    /// An `alerts-v1` push whose fields CloudKit trimmed: fetch the record.
    case incomplete(alertID: String)
    /// Some other push.
    case notAnAlert

    init(userInfo: [AnyHashable: Any]) {
        guard let query = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              query.subscriptionID == CloudSchema.SubscriptionID.alerts,
              let recordName = query.recordID?.recordName,
              recordName.hasPrefix(CloudSchema.RecordNamePrefix.alert) else {
            self = .notAnAlert
            return
        }
        if let alert = CloudRecordCoding.alert(pushFields: query.recordFields ?? [:], recordName: recordName) {
            self = .alert(alert)
        } else {
            self = .incomplete(alertID: String(recordName.dropFirst(CloudSchema.RecordNamePrefix.alert.count)))
        }
    }
}
