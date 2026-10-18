import KakurenekoCloud
import Foundation

/// Notification kinds (brief §8.4 + R07 §16.1). Shown on the Mac and on the iPhone (docs/NATIVE-NOTIFICATIONS.md).
public enum NotificationKind: String, Sendable, Hashable, Codable, CaseIterable {
    case finished
    case needsInput
    case countdown
    /// T3-only: "went quiet (finished or waiting)".
    case wentQuiet
    case stalled
    case safetyTrip
    /// Delivered after wake: "Mac slept 01:12–07:40".
    case asleep
    case shuttingDown
    /// "Ignored: Codex in web is busy again".
    case commandIgnored
    /// Generic warning (closed-lid mode unavailable, hotspot at lid close, …).
    case warning
    case test

    /// Default priority (brief §8.4 / R07 §16.2); `interruption` maps it to the notification's interruption level.
    public var defaultPriority: NotificationPriority {
        switch self {
        case .needsInput, .safetyTrip, .warning: .high
        case .asleep, .shuttingDown, .commandIgnored: .low
        case .finished, .countdown, .wentQuiet, .stalled, .test: .default
        }
    }

    /// Outbox TTL (brief §8.5). Countdown messages use the countdown end instead.
    public var defaultTTL: TimeInterval {
        switch self {
        case .finished: 6 * 3600
        case .needsInput: 2 * 3600
        case .countdown: 30 * 60
        case .wentQuiet, .stalled: 2 * 3600
        case .asleep: 12 * 3600
        case .safetyTrip, .warning, .shuttingDown, .commandIgnored: 30 * 60
        case .test: 10 * 60
        }
    }

    /// Validity of action buttons (brief §8.3: countdown 30 min, needs-input 2 h). A countdown message uses
    /// `max(actionTTL, endsAt − now)` and `expiresAt = endsAt`, so its buttons outlive long countdowns.
    public var actionTTL: TimeInterval {
        switch self {
        case .needsInput, .wentQuiet, .stalled: 2 * 3600
        default: 30 * 60
        }
    }
}

/// Priorities 1…5 (quiet hours lower everything to ≤ `.low`). The notification's interruption level follows it.
public enum NotificationPriority: Int, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case min = 1
    case low = 2
    case `default` = 3
    case high = 4
    case urgent = 5

    public static func < (lhs: NotificationPriority, rhs: NotificationPriority) -> Bool { lhs.rawValue < rhs.rawValue }

    /// high / urgent break through Focus (Time Sensitive); low / min arrive silently.
    public var interruption: AlertInterruption {
        switch self {
        case .min, .low: .passive
        case .default: .active
        case .high, .urgent: .timeSensitive
        }
    }
}

/// A button on a notification (Mac and iPhone show the same buttons).
public enum NotificationAction: Sendable, Hashable, Codable {
    case keepAwake(seconds: Int)
    case sleepNow
    /// Only offered when shutdown is enabled (D2).
    case shutDown

    public var label: String { cloudAction.title }

    /// The command this button sends.
    public var commandKind: RemoteCommandKind {
        switch self {
        case .keepAwake(let s): .keepAwake(seconds: s)
        case .sleepNow: .sleep
        case .shutDown: .shutdown
        }
    }

    /// The same button in the shared wire schema.
    public var cloudAction: CloudAction {
        switch self {
        case .keepAwake(let s): .keepAwake(seconds: s.clamped(to: CloudAction.keepAwakeSecondsRange))
        case .sleepNow: .sleepNow
        case .shutDown: .shutDown
        }
    }
}

/// A rendered message, ready to show on the Mac and to save for the iPhone (R07 §17.3, renamed).
public struct OutgoingNotification: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var kind: NotificationKind
    public var title: String
    public var body: String
    public var priority: NotificationPriority
    /// Coalescing key: a newer queued item with the same key replaces the older (`countdown`, `input:<session>`).
    public var groupKey: String
    /// A newer notification with the same key replaces the older one on screen (Mac and iPhone).
    public var replaceKey: String?
    /// ≤ 3.
    public var actions: [NotificationAction]
    public var createdAt: Date
    /// Drop instead of delivering stale news.
    public var expiresAt: Date
    /// `sv` carried by sleep/shutdown buttons.
    public var stateVersion: Int
    /// Button validity (`buttons expire = createdAt + actionTTL`, capped by `expiresAt` for countdowns).
    public var actionTTL: TimeInterval

    public init(
        id: UUID = UUID(),
        kind: NotificationKind,
        title: String,
        body: String,
        priority: NotificationPriority? = nil,
        groupKey: String,
        replaceKey: String? = nil,
        actions: [NotificationAction] = [],
        createdAt: Date,
        expiresAt: Date? = nil,
        stateVersion: Int = 0,
        actionTTL: TimeInterval? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.priority = priority ?? kind.defaultPriority
        self.groupKey = groupKey
        self.replaceKey = replaceKey
        self.actions = Array(actions.prefix(3))
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(kind.defaultTTL)
        self.stateVersion = stateVersion
        self.actionTTL = actionTTL ?? kind.actionTTL
    }
}

/// What a verified remote command asks for.
public enum RemoteCommandKind: Sendable, Hashable, Codable {
    case keepAwake(seconds: Int)
    case sleep
    case shutdown

    /// Log label.
    public var label: String {
        switch self {
        case .keepAwake(let s): "keepawake \(s)s"
        case .sleep: "sleep"
        case .shutdown: "shutdown"
        }
    }

    /// sleep/shutdown require `sv == currentStateVersion` (brief §8.3).
    public var requiresStateVersionMatch: Bool {
        switch self {
        case .sleep, .shutdown: true
        case .keepAwake: false
        }
    }
}

/// Where a command came from.
public enum CommandSource: Sendable, Hashable, Codable {
    /// A button on one of this Mac's own notifications.
    case macNotification
    /// The Kakureneko iPhone app (a notification button or the app), by device name.
    case phone(name: String)

    public var isPhone: Bool { if case .phone = self { true } else { false } }

    public var label: String {
        switch self {
        case .macNotification: "Mac notification"
        case .phone(let name): name
        }
    }
}

/// A command that passed Notify's checks (right Mac, not expired, `sv` present for sleep/shutdown, unseen id).
/// The `sv == current` check for sleep/shutdown is the coordinator's job (it owns the current state version).
public struct RemoteCommand: Sendable, Hashable, Codable {
    public var kind: RemoteCommandKind
    /// Unique per command (CloudKit record id or the Mac notification's alert id + button); replay key.
    public var commandID: String
    /// `sv` of the alert or status the user acted on (nil only for keep-awake from the app).
    public var stateVersion: Int?
    public var expiresAt: Date
    public var receivedAt: Date
    public var source: CommandSource

    public init(kind: RemoteCommandKind, commandID: String, stateVersion: Int?, expiresAt: Date, receivedAt: Date, source: CommandSource) {
        self.kind = kind
        self.commandID = commandID
        self.stateVersion = stateVersion
        self.expiresAt = expiresAt
        self.receivedAt = receivedAt
        self.source = source
    }
}

/// Delivery failure of one channel (iCloud save).
public enum DeliveryError: Error, Sendable, Hashable, Codable {
    /// Offline, server busy, rate limited. Retry after the hint or a backoff.
    case retryable(after: TimeInterval?)
    /// Rejected (not signed in, storage full, invalid record). Not retried; surfaced in the UI.
    case permanent(String)
}

/// How much agent content goes into a notification (brief §8.4). Default `.basic`.
public enum DetailLevel: String, Sendable, Hashable, Codable, CaseIterable {
    /// "An agent finished".
    case `private`
    /// Agent + project + duration.
    case basic
    /// + ≤ 140 sanitized chars of the last assistant message.
    case detailed
}

/// macOS notification permission for Kakureneko.
public enum MacAlertAuthorization: String, Sendable, Hashable, Codable {
    /// Never asked (onboarding asks).
    case notDetermined
    case denied
    case authorized
    /// Delivered quietly to Notification Center only.
    case provisional
    /// Not available in this process (not an app bundle, e.g. unit tests).
    case unavailable

    public var canPost: Bool { self == .authorized || self == .provisional }
}

/// Snapshot of the notification subsystem for the UI.
public struct NotificationStatus: Sendable, Hashable, Codable {
    /// macOS notification permission.
    public var macAuthorization: MacAlertAuthorization
    /// Time Sensitive allowed in System Settings (nil = unknown).
    public var macTimeSensitive: Bool?
    /// iCloud availability for iPhone alerts.
    public var iCloud: CloudAccountStatus
    /// iPhones running the Kakureneko app with this Apple Account (most recently seen first).
    public var phones: [PhoneDevice]
    /// Alerts waiting to be saved to iCloud.
    public var outboxCount: Int
    /// Last successful iCloud save of an alert.
    public var lastDeliveredAt: Date?
    /// Last command received from a phone.
    public var lastCommandAt: Date?
    /// Last iCloud problem (user-presentable), cleared on success.
    public var lastError: String?

    public init(macAuthorization: MacAlertAuthorization = .notDetermined, macTimeSensitive: Bool? = nil,
                iCloud: CloudAccountStatus = .couldNotDetermine, phones: [PhoneDevice] = [], outboxCount: Int = 0,
                lastDeliveredAt: Date? = nil, lastCommandAt: Date? = nil, lastError: String? = nil) {
        self.macAuthorization = macAuthorization
        self.macTimeSensitive = macTimeSensitive
        self.iCloud = iCloud
        self.phones = phones
        self.outboxCount = outboxCount
        self.lastDeliveredAt = lastDeliveredAt
        self.lastCommandAt = lastCommandAt
        self.lastError = lastError
    }

    public static let initial = NotificationStatus()

    /// iCloud works and at least one iPhone runs the Kakureneko app.
    public var phoneConnected: Bool { iCloud.isAvailable && !phones.isEmpty }
}

/// What the coordinator reports about the Mac for the iPhone app (`MacStatus` minus identity, version and time,
/// which Notify adds). Rebuilt on every snapshot; Notify saves it debounced (docs/NATIVE-NOTIFICATIONS.md §4.3).
public struct MacStatusReport: Sendable, Hashable {
    public var phase: MacPhase
    public var headline: String
    public var detail: String?
    public var countdownEndsAt: Date?
    public var keepAwakeUntil: Date?
    public var agents: [AgentSummary]
    public var batteryPercent: Int?
    public var onBattery: Bool
    public var lidClosed: Bool
    public var stateVersion: Int
    public var keepAwakeSeconds: Int
    public var shutdownEnabled: Bool
    public var canSleep: Bool

    public init(phase: MacPhase, headline: String, detail: String? = nil, countdownEndsAt: Date? = nil, keepAwakeUntil: Date? = nil,
                agents: [AgentSummary] = [], batteryPercent: Int? = nil, onBattery: Bool = false, lidClosed: Bool = false,
                stateVersion: Int = 0, keepAwakeSeconds: Int = 3600, shutdownEnabled: Bool = false, canSleep: Bool = false) {
        self.phase = phase
        self.headline = headline
        self.detail = detail
        self.countdownEndsAt = countdownEndsAt
        self.keepAwakeUntil = keepAwakeUntil
        self.agents = agents
        self.batteryPercent = batteryPercent
        self.onBattery = onBattery
        self.lidClosed = lidClosed
        self.stateVersion = stateVersion
        self.keepAwakeSeconds = keepAwakeSeconds
        self.shutdownEnabled = shutdownEnabled
        self.canSleep = canSleep
    }

}

/// What the coordinator wants to tell the phone. KakurenekoNotify renders it with its Templates
/// (brief §8.4) and applies NotificationPolicy (the iPhone's timing, 15 s batching, rate limit,
/// quiet hours, Remote-Control skip) before it reaches the outbox.
public enum NotificationIntent: Sendable, Hashable {
    case finished(SessionEffect, stillRunning: Int)
    /// One per wait. Deduped by Notify on `(sessionKey, waiting since)` (from `effect.session.state`), so the
    /// coordinator may RE-SUBMIT it for every still-waiting session on each present → away transition and lid close
    /// (what the iPhone's timing held back then reaches the iPhone). Schedules the single reminder
    /// after `needsInputReminderMinutes`, sent only while the wait is unresolved.
    case needsInput(SessionEffect, awakeUntil: Date?)
    /// The session left `.waiting` (answered, working again, ended): drop queued `input:<key>` items and cancel
    /// the pending reminder. Never produces a message.
    case resolved(SessionKey)
    case wentQuiet(SessionEffect, sleepsAt: Date?)
    case stalled(SessionEffect)
    /// Countdown entry (sent once; iOS cannot update it). `reason` picks the template ("All agents done…" vs
    /// "<Agent> is waiting for you…"); `finished` = finished effects since the lid closed (policy folds pending
    /// `finished` items of the same batch into it); `waiting` = sessions still waiting.
    case countdown(endsAt: Date, reason: CountdownReason, finished: [SessionEffect], waiting: [AgentSession], offerShutdown: Bool)
    case safetyTrip(SafetyTrip, runningAgents: Int)
    case asleep(SleepRecord, batteryPercent: Int?)
    case shuttingDown(at: Date, requestedFromPhone: Bool)
    case commandIgnored(reason: String)
    case warning(title: String, body: String)
    case test

    public var kind: NotificationKind {
        switch self {
        case .finished: .finished
        case .needsInput, .resolved: .needsInput
        case .wentQuiet: .wentQuiet
        case .stalled: .stalled
        case .countdown: .countdown
        case .safetyTrip: .safetyTrip
        case .asleep: .asleep
        case .shuttingDown: .shuttingDown
        case .commandIgnored: .commandIgnored
        case .warning: .warning
        case .test: .test
        }
    }
}

/// Context the policy needs at submit time.
public struct NotificationContext: Sendable, Hashable {
    public var now: Date
    public var presence: Presence
    /// Current `SessionAggregate.stateVersion`, embedded as `sv`.
    public var stateVersion: Int
    /// Duration of the "Keep awake" button (`settings.power.keepAwakeButtonSeconds`, default 1 h).
    public var keepAwakeSeconds: Int

    public init(now: Date, presence: Presence, stateVersion: Int, keepAwakeSeconds: Int = 3600) {
        self.now = now
        self.presence = presence
        self.stateVersion = stateVersion
        self.keepAwakeSeconds = keepAwakeSeconds
    }
}

/// What `submit` did with an intent.
public enum NotificationDisposition: Sendable, Hashable {
    /// Rendered and queued (or delivered) immediately.
    case queued(UUID)
    /// Held in the 15 s batch.
    case batched
    /// Folded into another message (e.g. finished → countdown, or into a digest).
    case folded
    /// Not sent: reason (`disabled`, `noChannel`, `lidOpen` / `present` — only the iPhone could show it and its timing
    /// holds it back —, `muted`, `remoteControl`, `shortTurn`, `duplicate`, `stopped`, `resolved`).
    case suppressed(String)
}

/// Result of `drain(deadline:)`.
public struct DrainResult: Sendable, Hashable {
    public var delivered: Int
    public var remaining: Int
    public var permanentFailures: Int
    public var hitDeadline: Bool

    public init(delivered: Int = 0, remaining: Int = 0, permanentFailures: Int = 0, hitDeadline: Bool = false) {
        self.delivered = delivered
        self.remaining = remaining
        self.permanentFailures = permanentFailures
        self.hitDeadline = hitDeadline
    }
}
