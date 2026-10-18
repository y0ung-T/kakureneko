// KakurenekoCloud — the Mac ⇄ iPhone wire schema over the PUBLIC CloudKit database of Kakureneko's container, with
// creator-only permissions (docs/NATIVE-NOTIFICATIONS.md): storage comes from the app's CloudKit allowance, not the
// user's iCloud storage, and only the Apple Account that created a record can read it. Shared verbatim by the Mac app (KakurenekoNotify) and the iPhone app
// (Xcode/project.yml), so both sides always agree on record types, field keys, ids and notification buttons.
//
// Builds for macOS and iOS. No dependency on KakurenekoKit (macOS-only).
//
// Layout of this module:
//   Schema.swift              container / zone / record types / field keys / subscription + notification ids
//   Models.swift              pure value types: CloudAlert, CloudCommand, MacStatus, PhoneDevice, CloudItem
//   RecordCoding.swift        CloudItem ⇄ CKRecord, CloudAlert from a CloudKit push payload
//   CloudStore.swift          the database protocol both apps use (+ errors, change tokens, subscriptions)
//   CloudKitStore.swift       live CloudKit implementation (needs the iCloud entitlement)
//   InMemoryCloudStore.swift  in-memory fake for tests on both platforms
//   AlertPresentation.swift   UserNotifications content, categories, buttons and button responses

import Foundation

/// Identifiers that must never change once shipped: a renamed record type, field or subscription id orphans data
/// already in users' iCloud (and the production schema cannot drop deployed types or fields).
public enum CloudSchema {
    /// Wire schema version written into every record (`schema` field). Readers ignore records from a NEWER major
    /// version they do not understand instead of misreading them.
    public static let version = 1

    /// The iCloud container shared by the Mac app and the iPhone app (registered for team 7NRW73MYQZ).
    public static let containerIdentifier = "iCloud.com.kakureneko.Kakureneko"

    /// Every record lives in the public database's default zone (the public database has no custom zones).
    public static let zoneName = "_defaultZone"

    public enum RecordType {
        /// Mac → phones: one notification (created once, never updated).
        public static let alert = "Alert"
        /// Phone → Mac: one button tap or app request (the Mac deletes it after handling).
        public static let command = "Command"
        /// Mac → phones: the Mac's live status (one record per Mac, updated in place).
        public static let macStatus = "MacStatus"
        /// Phone → Macs: an installed iPhone app (one record per device, updated in place).
        public static let phoneDevice = "PhoneDevice"

        public static let all = [alert, command, macStatus, phoneDevice]
    }

    /// Record name prefixes (`<prefix><id>`): readable in the CloudKit console and collision-free across types.
    public enum RecordNamePrefix {
        public static let alert = "alert-"
        public static let command = "command-"
        public static let macStatus = "mac-"
        public static let phoneDevice = "phone-"
    }

    /// How an absent optional is written (every record writes every field of its type; see `CloudRecordCoding`).
    public enum Absent {
        /// Optional text (and the only element of an empty list).
        public static let string = ""
        /// Optional number, timestamp or boolean.
        public static let number = Int64.min
    }

    /// Field keys. Timestamps are Int64 Unix seconds (they survive the push payload unchanged), booleans are
    /// Int64 0/1, absent optionals are `Absent` sentinels.
    public enum Field {
        public static let schema = "schema"
        /// The creating user's record name (`CKContainer.userRecordID()`): what queries and subscriptions filter on.
        /// The server-set creator is checked too before anything is trusted (see `CloudKitStore`).
        public static let owner = "owner"
        // Shared
        public static let macID = "macID"
        public static let macName = "macName"
        public static let createdAt = "createdAt"
        public static let expiresAt = "expiresAt"
        public static let stateVersion = "sv"
        // Alert
        public static let kind = "kind"
        public static let title = "title"
        public static let body = "body"
        public static let threadID = "threadID"
        public static let replaceKey = "replaceKey"
        public static let interruption = "interruption"
        public static let actions = "actions"
        // Command
        public static let request = "request"
        public static let alertID = "alertID"
        public static let deviceID = "deviceID"
        public static let deviceName = "deviceName"
        // MacStatus
        public static let model = "model"
        public static let phase = "phase"
        public static let headline = "headline"
        public static let detail = "detail"
        public static let countdownEndsAt = "countdownEndsAt"
        public static let keepAwakeUntil = "keepAwakeUntil"
        public static let agentsJSON = "agentsJSON"
        public static let batteryPercent = "batteryPercent"
        public static let onBattery = "onBattery"
        public static let lidClosed = "lidClosed"
        public static let keepAwakeSeconds = "keepAwakeSeconds"
        public static let shutdownEnabled = "shutdownEnabled"
        public static let canSleep = "canSleep"
        public static let updatedAt = "updatedAt"
        public static let appVersion = "appVersion"
        // PhoneDevice
        public static let name = "name"
        public static let systemVersion = "systemVersion"
        public static let alertsAuthorized = "alertsAuthorized"
        public static let timeSensitiveAllowed = "timeSensitiveAllowed"
        public static let lastSeenAt = "lastSeenAt"

        /// Alert fields copied into the push payload (`desiredKeys`): none. CloudKit's public-database subscriptions
        /// accept only a handful ("notification additional fields limit exceeded": measured 5 accepted, 7 refused),
        /// too few for the notification (title, buttons, `sv`, expiry, Mac, thread, replace key). The iPhone's
        /// notification extension fetches the alert by the push's record id instead (strongly consistent); the push
        /// still carries the title and body as localization arguments, shown without buttons if that fetch fails.
        public static let alertPushKeys: [String] = []

        /// The most `desiredKeys` CloudKit accepted on a public-database subscription.
        public static let maximumPushKeys = 5
    }

    /// Query subscriptions (the public database has no zone or database subscriptions), each limited to the user's
    /// own records (`owner == <user record name>`). CloudKit never pushes to the device that made the change.
    public enum SubscriptionID {
        /// `Alert` created → a VISIBLE push (mutable-content). Created by the iPhone app.
        public static let alerts = "alerts-v1"
        /// `Command` created → a SILENT push. Created by the Mac (it hears button taps within seconds).
        public static let macCommands = "mac-commands-v1"
        /// `PhoneDevice` created or updated → a SILENT push. Created by the Mac ("iPhone connected").
        public static let macDevices = "mac-devices-v1"
        /// `MacStatus` created or updated → a SILENT push. Created by the iPhone app (live status).
        public static let phoneStatuses = "phone-statuses-v1"

        /// The silent ones (a remote notification with one of these ids means "fetch changes now").
        public static let silent: Set<String> = [macCommands, macDevices, phoneStatuses]
    }

    /// Limits shared by both sides (checked when encoding, so a record always fits a push payload).
    public enum Limits {
        public static let titleCharacters = 120
        public static let bodyCharacters = 600
        public static let headlineCharacters = 120
        public static let detailCharacters = 300
        public static let agentsInStatus = 12
        public static let nameCharacters = 80
        /// A command is honoured at most this long after it was issued, whatever its `expiresAt` says.
        public static let commandMaximumAge: TimeInterval = 30 * 60
        /// Clock skew tolerated between phone and Mac for `issuedAt` in the future.
        public static let commandClockSkew: TimeInterval = 5 * 60
    }
}

/// Identifiers of the notification categories and buttons (same on Mac and iPhone).
public enum NotificationIDs {
    /// `userInfo` keys on every Kakureneko notification (local on the Mac, the extension's content on the iPhone).
    public enum UserInfo {
        public static let alertID = "kakureneko.alertID"
        public static let macID = "kakureneko.macID"
        public static let macName = "kakureneko.macName"
        public static let kind = "kakureneko.kind"
        public static let stateVersion = "kakureneko.sv"
        public static let expiresAt = "kakureneko.expiresAt"
        public static let replaceKey = "kakureneko.replaceKey"
        /// Duration of the Keep awake button on this notification.
        public static let keepAwakeSeconds = "kakureneko.keepAwakeSeconds"
    }

    /// Button identifiers (`UNNotificationAction.identifier`).
    public enum Action {
        public static let keepAwake = "com.kakureneko.action.keepawake"
        public static let sleepNow = "com.kakureneko.action.sleep"
        public static let shutDown = "com.kakureneko.action.shutdown"
    }

    /// Category for a notification without buttons.
    public static let plainCategory = "com.kakureneko.alert"
    /// `UNNotificationContent.targetContentIdentifier` / thread prefix.
    public static let threadPrefix = "com.kakureneko."
}
