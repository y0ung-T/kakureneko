import Foundation
import UserNotifications

/// How a `CloudAlert` looks as a notification — identical on the Mac (local notification) and the iPhone (the
/// notification extension's content) — and how a button tap turns back into a request.
///
/// Building `UNNotificationContent` / `UNNotificationCategory` objects needs no app bundle (unit-tested);
/// only `UNUserNotificationCenter.current()` does, and that stays in the apps.
public enum AlertPresentation {
    // MARK: Categories

    /// Category for a set of buttons: `com.kakureneko.alert` (none) or `com.kakureneko.alert.keepawake+sleep`.
    public static func categoryID(for actions: [CloudAction]) -> String {
        categoryID(for: actions.map(\.kind))
    }

    public static func categoryID(for kinds: [CloudActionKind]) -> String {
        let sorted = Array(Set(kinds)).sorted()
        guard !sorted.isEmpty else { return NotificationIDs.plainCategory }
        return NotificationIDs.plainCategory + "." + sorted.map(\.rawValue).joined(separator: "+")
    }

    /// Every combination of buttons (7) plus the plain category, so any alert's buttons have a registered category.
    /// Keep awake buttons are titled with `keepAwakeSeconds` (the Mac's setting; the phone uses its last status).
    /// `keepAwakeSeconds` nil: the Keep awake button says just "Keep awake" (Macs with different durations share
    /// the categories; the tap still sends the alert's own duration).
    public static func categories(keepAwakeSeconds: Int?) -> Set<UNNotificationCategory> {
        var result: Set<UNNotificationCategory> = [
            UNNotificationCategory(identifier: NotificationIDs.plainCategory, actions: [], intentIdentifiers: [], options: []),
        ]
        let kinds = CloudActionKind.allCases
        for mask in 1..<(1 << kinds.count) {
            let subset = kinds.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            result.insert(UNNotificationCategory(
                identifier: categoryID(for: subset),
                actions: subset.map { notificationAction($0, keepAwakeSeconds: keepAwakeSeconds) },
                intentIdentifiers: [], options: []))
        }
        return result
    }

    static func notificationAction(_ kind: CloudActionKind, keepAwakeSeconds: Int?) -> UNNotificationAction {
        let title: String
        let symbol: String
        var options: UNNotificationActionOptions = []
        switch kind {
        case .keepAwake:
            title = keepAwakeSeconds.map { CloudAction.keepAwake(seconds: $0).title } ?? "Keep awake"
            symbol = "cup.and.heat.waves"
        case .sleepNow:
            title = CloudAction.sleepNow.title
            symbol = "moon.zzz"
            options = [.destructive, .authenticationRequired]
        case .shutDown:
            title = CloudAction.shutDown.title
            symbol = "power"
            options = [.destructive, .authenticationRequired]
        }
        return UNNotificationAction(identifier: kind.notificationActionID, title: title, options: options,
                                    icon: UNNotificationActionIcon(systemImageName: symbol))
    }

    // MARK: Content

    /// The notification for `alert`. `now` decides whether the buttons are still valid (a late delivery shows the
    /// text only). `showMacName` adds the Mac's name as the subtitle (the iPhone; the Mac itself does not need it).
    public static func content(for alert: CloudAlert, now: Date, showMacName: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        if showMacName { content.subtitle = alert.macName }
        content.threadIdentifier = NotificationIDs.threadPrefix + alert.threadID
        content.categoryIdentifier = alert.isExpired(at: now) ? NotificationIDs.plainCategory : categoryID(for: alert.actions)
        content.interruptionLevel = interruptionLevel(alert.interruption)
        content.relevanceScore = relevance(alert.interruption)
        content.sound = alert.interruption == .passive ? nil : .default
        content.targetContentIdentifier = alert.macID
        content.userInfo = userInfo(for: alert)
        return content
    }

    /// Request identifier on the Mac: alerts sharing a `replaceKey` replace each other on screen.
    public static func requestIdentifier(for alert: CloudAlert) -> String {
        alert.replaceKey.map { "com.kakureneko.replace." + $0 } ?? (CloudSchema.RecordNamePrefix.alert + alert.id)
    }

    public static func userInfo(for alert: CloudAlert) -> [String: Any] {
        var info: [String: Any] = [
            NotificationIDs.UserInfo.alertID: alert.id,
            NotificationIDs.UserInfo.macID: alert.macID,
            NotificationIDs.UserInfo.macName: alert.macName,
            NotificationIDs.UserInfo.kind: alert.kind,
            NotificationIDs.UserInfo.stateVersion: alert.stateVersion,
            NotificationIDs.UserInfo.expiresAt: Int(alert.expiresAt.timeIntervalSince1970.rounded(.down)),
        ]
        if let replaceKey = alert.replaceKey { info[NotificationIDs.UserInfo.replaceKey] = replaceKey }
        if let seconds = alert.keepAwakeSeconds { info[NotificationIDs.UserInfo.keepAwakeSeconds] = seconds }
        return info
    }

    public static func interruptionLevel(_ interruption: AlertInterruption) -> UNNotificationInterruptionLevel {
        switch interruption {
        case .passive: .passive
        case .active: .active
        case .timeSensitive: .timeSensitive
        }
    }

    static func relevance(_ interruption: AlertInterruption) -> Double {
        switch interruption {
        case .passive: 0.1
        case .active: 0.5
        case .timeSensitive: 1.0
        }
    }

    // MARK: Responses

    /// A button tap, decoded from the notification's `userInfo`.
    public struct ButtonTap: Sendable, Hashable {
        public var request: CloudRequest
        public var alertID: String?
        public var macID: String
        public var stateVersion: Int?
        public var expiresAt: Date?

        public init(request: CloudRequest, alertID: String?, macID: String, stateVersion: Int?, expiresAt: Date?) {
            self.request = request
            self.alertID = alertID
            self.macID = macID
            self.stateVersion = stateVersion
            self.expiresAt = expiresAt
        }
    }

    /// nil for the default tap (open the app), a dismissal, or a notification that is not Kakureneko's.
    public static func buttonTap(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> ButtonTap? {
        guard let kind = CloudActionKind(notificationActionID: actionIdentifier),
              let macID = userInfo[NotificationIDs.UserInfo.macID] as? String else { return nil }
        let request: CloudRequest
        switch kind {
        case .keepAwake:
            let seconds = (userInfo[NotificationIDs.UserInfo.keepAwakeSeconds] as? NSNumber)?.intValue ?? 3600
            request = .keepAwake(seconds: seconds.clamped(to: CloudAction.keepAwakeSecondsRange))
        case .sleepNow:
            request = .sleepNow
        case .shutDown:
            request = .shutDown
        }
        let expires = (userInfo[NotificationIDs.UserInfo.expiresAt] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return ButtonTap(request: request, alertID: userInfo[NotificationIDs.UserInfo.alertID] as? String, macID: macID,
                         stateVersion: (userInfo[NotificationIDs.UserInfo.stateVersion] as? NSNumber)?.intValue, expiresAt: expires)
    }
}
