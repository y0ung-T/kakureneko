import Foundation

// MARK: - Buttons and requests

/// The kind of a notification button (stable order: keep awake, sleep, shut down).
public enum CloudActionKind: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case keepAwake = "keepawake"
    case sleepNow = "sleep"
    case shutDown = "shutdown"

    public var notificationActionID: String {
        switch self {
        case .keepAwake: NotificationIDs.Action.keepAwake
        case .sleepNow: NotificationIDs.Action.sleepNow
        case .shutDown: NotificationIDs.Action.shutDown
        }
    }

    public init?(notificationActionID: String) {
        guard let kind = Self.allCases.first(where: { $0.notificationActionID == notificationActionID }) else { return nil }
        self = kind
    }

    /// Sleep and shut down end the agents' work: red, and the phone must be unlocked.
    public var isDestructive: Bool { self != .keepAwake }

    private var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
}

/// A button on a notification (Keep awake carries its duration).
public enum CloudAction: Sendable, Hashable, Codable {
    case keepAwake(seconds: Int)
    case sleepNow
    case shutDown

    public static let keepAwakeSecondsRange: ClosedRange<Int> = 60...(24 * 3600)

    public var kind: CloudActionKind {
        switch self {
        case .keepAwake: .keepAwake
        case .sleepNow: .sleepNow
        case .shutDown: .shutDown
        }
    }

    /// Wire value stored in `Alert.actions`: `keepawake:3600`, `sleep`, `shutdown`.
    public var wireValue: String {
        switch self {
        case .keepAwake(let seconds): "keepawake:\(seconds)"
        case .sleepNow: "sleep"
        case .shutDown: "shutdown"
        }
    }

    public init?(wireValue: String) {
        switch wireValue {
        case "sleep": self = .sleepNow
        case "shutdown": self = .shutDown
        default:
            let parts = wireValue.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "keepawake", let seconds = Int(parts[1]),
                  Self.keepAwakeSecondsRange.contains(seconds) else { return nil }
            self = .keepAwake(seconds: seconds)
        }
    }

    /// Button title: "Keep awake 1h", "Keep awake 30m", "Sleep now", "Shut down".
    public var title: String {
        switch self {
        case .keepAwake(let seconds): "Keep awake \(Self.durationText(seconds))"
        case .sleepNow: "Sleep now"
        case .shutDown: "Shut down"
        }
    }

    /// "1h", "90m", "2h" — hours when whole, else minutes.
    public static func durationText(_ seconds: Int) -> String {
        seconds >= 3600 && seconds % 3600 == 0 ? "\(seconds / 3600)h" : "\(max(1, seconds / 60))m"
    }

    /// The request a tap on this button sends.
    public var request: CloudRequest {
        switch self {
        case .keepAwake(let seconds): .keepAwake(seconds: seconds)
        case .sleepNow: .sleepNow
        case .shutDown: .shutDown
        }
    }
}

/// What a phone asks the Mac to do (`Command.request`).
public enum CloudRequest: Sendable, Hashable, Codable {
    case keepAwake(seconds: Int)
    case sleepNow
    case shutDown
    /// "Send a test alert": the Mac answers with a test notification on every device.
    case sendTest
    /// Republish `MacStatus` now (the app was opened).
    case refreshStatus

    public var wireValue: String {
        switch self {
        case .keepAwake(let seconds): "keepawake:\(seconds)"
        case .sleepNow: "sleep"
        case .shutDown: "shutdown"
        case .sendTest: "test"
        case .refreshStatus: "refresh"
        }
    }

    public init?(wireValue: String) {
        switch wireValue {
        case "test": self = .sendTest
        case "refresh": self = .refreshStatus
        default:
            guard let action = CloudAction(wireValue: wireValue) else { return nil }
            self = action.request
        }
    }

    /// Sleep and shut down are only honoured for the state the user saw (`sv` must match the Mac's current one).
    public var requiresStateVersion: Bool {
        switch self {
        case .sleepNow, .shutDown: true
        case .keepAwake, .sendTest, .refreshStatus: false
        }
    }
}

// MARK: - Alert (Mac → phones)

/// How strongly a notification interrupts (maps to `UNNotificationInterruptionLevel`).
public enum AlertInterruption: String, Sendable, Hashable, Codable, CaseIterable {
    /// Silent, straight to the list (after-the-fact news: "Mac slept 01:12–07:40").
    case passive
    /// Normal banner and sound.
    case active
    /// Breaks through Focus (an agent needs you, the Mac is about to sleep, a safety stop).
    case timeSensitive
}

/// One notification, written once by the Mac. The iPhone shows it via the `alerts-v1` subscription; the Mac
/// shows the same content locally.
public struct CloudAlert: Sendable, Hashable, Codable, Identifiable {
    /// UUID string (record name `alert-<id>`).
    public var id: String
    public var macID: String
    public var macName: String
    /// `NotificationKind` raw value on the Mac (`finished`, `needsInput`, `countdown`, …).
    public var kind: String
    public var title: String
    public var body: String
    /// Notifications with the same thread are grouped on the device.
    public var threadID: String
    /// A newer alert with the same key replaces the older one on screen (the countdown, one wait per session).
    public var replaceKey: String?
    public var interruption: AlertInterruption
    /// ≤ 3 buttons, in display order.
    public var actions: [CloudAction]
    /// The Mac's state version when this was decided (`sv` of sleep/shut down taps).
    public var stateVersion: Int
    public var createdAt: Date
    /// Buttons stop working after this; a late delivery shows the text without buttons.
    public var expiresAt: Date

    public init(id: String = UUID().uuidString, macID: String, macName: String, kind: String, title: String, body: String,
                threadID: String, replaceKey: String? = nil, interruption: AlertInterruption = .active,
                actions: [CloudAction] = [], stateVersion: Int = 0, createdAt: Date, expiresAt: Date) {
        self.id = id
        self.macID = macID
        self.macName = String(macName.prefix(CloudSchema.Limits.nameCharacters))
        self.kind = kind
        self.title = String(title.prefix(CloudSchema.Limits.titleCharacters))
        self.body = String(body.prefix(CloudSchema.Limits.bodyCharacters))
        self.threadID = threadID
        self.replaceKey = replaceKey
        self.interruption = interruption
        self.actions = Array(Self.normalizedActions(actions).prefix(3))
        self.stateVersion = stateVersion
        self.createdAt = createdAt
        self.expiresAt = max(expiresAt, createdAt)
    }

    /// One button per kind, in the canonical order (keep awake, sleep, shut down): the category id depends on it.
    public static func normalizedActions(_ actions: [CloudAction]) -> [CloudAction] {
        var seen = Set<CloudActionKind>()
        return actions.filter { seen.insert($0.kind).inserted }.sorted { $0.kind < $1.kind }
    }

    public var recordName: String { CloudSchema.RecordNamePrefix.alert + id }

    public func isExpired(at now: Date) -> Bool { now >= expiresAt }

    /// The Keep awake duration offered on this alert, if any.
    public var keepAwakeSeconds: Int? {
        for action in actions { if case .keepAwake(let seconds) = action { return seconds } }
        return nil
    }
}

// MARK: - Command (phone → Mac)

/// A tap on a notification button or an in-app request, written by a phone, read and deleted by its Mac.
public struct CloudCommand: Sendable, Hashable, Codable, Identifiable {
    /// UUID string (record name `command-<id>`); also the replay key on the Mac.
    public var id: String
    /// The Mac this is for (each Mac ignores the others' commands).
    public var macID: String
    public var request: CloudRequest
    /// Required for sleep / shut down: the `sv` of the alert or status the user acted on.
    public var stateVersion: Int?
    /// The alert whose button was tapped (nil for in-app requests).
    public var alertID: String?
    public var issuedAt: Date
    public var expiresAt: Date
    public var deviceID: String
    public var deviceName: String

    public init(id: String = UUID().uuidString, macID: String, request: CloudRequest, stateVersion: Int?, alertID: String? = nil,
                issuedAt: Date, expiresAt: Date, deviceID: String, deviceName: String) {
        self.id = id
        self.macID = macID
        self.request = request
        self.stateVersion = stateVersion
        self.alertID = alertID
        self.issuedAt = issuedAt
        self.expiresAt = min(expiresAt, issuedAt.addingTimeInterval(CloudSchema.Limits.commandMaximumAge))
        self.deviceID = deviceID
        self.deviceName = String(deviceName.prefix(CloudSchema.Limits.nameCharacters))
    }

    public var recordName: String { CloudSchema.RecordNamePrefix.command + id }

    /// Why a command must not run (nil = it may; the Mac still checks `sv` against its CURRENT state for
    /// sleep / shut down, and its replay cache).
    public enum Rejection: String, Sendable, Hashable, Codable {
        case otherMac, expired, issuedInFuture, tooOld, missingStateVersion
    }

    public func rejection(forMac macID: String, now: Date) -> Rejection? {
        guard self.macID == macID else { return .otherMac }
        if issuedAt > now.addingTimeInterval(CloudSchema.Limits.commandClockSkew) { return .issuedInFuture }
        if now.timeIntervalSince(issuedAt) > CloudSchema.Limits.commandMaximumAge { return .tooOld }
        if now >= expiresAt { return .expired }
        if request.requiresStateVersion && stateVersion == nil { return .missingStateVersion }
        return nil
    }
}

// MARK: - MacStatus (Mac → phones)

/// What the Mac is doing, as the iPhone app shows it.
public enum MacPhase: String, Sendable, Hashable, Codable, CaseIterable {
    /// Kakureneko is switched off on the Mac.
    case off
    /// Nothing to protect: no agent working.
    case idle
    /// Agents working, lid open (closed-lid mode armed).
    case working
    /// Lid closed: holding the Mac awake for the agents.
    case lidClosedAwake
    /// About to sleep (`countdownEndsAt`).
    case countdown
    /// Shutting down after a grace period.
    case shutdownPending
    /// Wind-down in progress (thaw, flush, then sleep / shut down).
    case windingDown
    /// The Mac went to sleep (the last status before it did).
    case asleep
    /// The Mac shut down.
    case shutDown
}

/// One agent session as the phone lists it.
public struct AgentSummary: Sendable, Hashable, Codable {
    public enum Activity: String, Sendable, Hashable, Codable, CaseIterable {
        case working, waiting, finished, stalled, idle
    }

    /// "Claude Code", "Codex", …
    public var agent: String
    public var project: String?
    /// "Terminal", "VS Code", …
    public var host: String?
    public var activity: Activity
    /// When the current activity started.
    public var since: Date?
    /// "Needs permission", "Asked a question" (waiting only).
    public var note: String?

    public init(agent: String, project: String? = nil, host: String? = nil, activity: Activity, since: Date? = nil, note: String? = nil) {
        self.agent = agent
        self.project = project
        self.host = host
        self.activity = activity
        self.since = since
        self.note = note
    }
}

public struct MacStatus: Sendable, Hashable, Codable, Identifiable {
    public var id: String { macID }
    public var macID: String
    public var macName: String
    /// "MacBook Pro".
    public var model: String?
    public var phase: MacPhase
    /// "2 agents working · lid closed".
    public var headline: String
    /// "Keeping your Mac awake. 4 apps slowed down."
    public var detail: String?
    public var countdownEndsAt: Date?
    public var keepAwakeUntil: Date?
    /// ≤ `CloudSchema.Limits.agentsInStatus`.
    public var agents: [AgentSummary]
    public var batteryPercent: Int?
    public var onBattery: Bool
    public var lidClosed: Bool
    /// Current `sv` (sleep / shut down from the app carry it).
    public var stateVersion: Int
    /// Duration of the app's Keep awake button.
    public var keepAwakeSeconds: Int
    /// The user enabled shutdown on the Mac (the app offers "Shut down").
    public var shutdownEnabled: Bool
    /// The Mac would accept "Sleep now" right now.
    public var canSleep: Bool
    public var updatedAt: Date
    public var appVersion: String

    public init(macID: String, macName: String, model: String? = nil, phase: MacPhase, headline: String, detail: String? = nil,
                countdownEndsAt: Date? = nil, keepAwakeUntil: Date? = nil, agents: [AgentSummary] = [], batteryPercent: Int? = nil,
                onBattery: Bool = false, lidClosed: Bool = false, stateVersion: Int = 0, keepAwakeSeconds: Int = 3600,
                shutdownEnabled: Bool = false, canSleep: Bool = true, updatedAt: Date, appVersion: String) {
        self.macID = macID
        self.macName = String(macName.prefix(CloudSchema.Limits.nameCharacters))
        self.model = model
        self.phase = phase
        self.headline = String(headline.prefix(CloudSchema.Limits.headlineCharacters))
        self.detail = detail.map { String($0.prefix(CloudSchema.Limits.detailCharacters)) }
        self.countdownEndsAt = countdownEndsAt
        self.keepAwakeUntil = keepAwakeUntil
        self.agents = Array(agents.prefix(CloudSchema.Limits.agentsInStatus))
        self.batteryPercent = batteryPercent
        self.onBattery = onBattery
        self.lidClosed = lidClosed
        self.stateVersion = stateVersion
        self.keepAwakeSeconds = keepAwakeSeconds.clamped(to: CloudAction.keepAwakeSecondsRange)
        self.shutdownEnabled = shutdownEnabled
        self.canSleep = canSleep
        self.updatedAt = updatedAt
        self.appVersion = appVersion
    }

    public var recordName: String { CloudSchema.RecordNamePrefix.macStatus + macID }

    /// While running, the Mac republishes at least every `heartbeatInterval`; older (and not asleep / off / shut
    /// down) means the Mac stopped responding (crashed, offline, lost power).
    public static let heartbeatInterval: TimeInterval = 5 * 60
    public static let staleAfter: TimeInterval = 12 * 60

    public func isStale(at now: Date) -> Bool {
        switch phase {
        case .asleep, .shutDown, .off: false
        default: now.timeIntervalSince(updatedAt) > Self.staleAfter
        }
    }
}

// MARK: - PhoneDevice (phone → Macs)

public struct PhoneDevice: Sendable, Hashable, Codable, Identifiable {
    public var id: String { deviceID }
    /// Random per install (`identifierForVendor` is not used: it changes when all vendor apps are removed).
    public var deviceID: String
    /// "iPhone" (iOS no longer exposes the user-assigned name without an entitlement).
    public var name: String
    /// "iPhone18,3".
    public var model: String
    public var systemVersion: String
    public var appVersion: String
    /// Notifications allowed for the Kakureneko app on this phone.
    public var alertsAuthorized: Bool
    /// Time Sensitive allowed (nil = unknown).
    public var timeSensitiveAllowed: Bool?
    public var lastSeenAt: Date

    public init(deviceID: String, name: String, model: String, systemVersion: String, appVersion: String,
                alertsAuthorized: Bool, timeSensitiveAllowed: Bool? = nil, lastSeenAt: Date) {
        self.deviceID = deviceID
        self.name = String(name.prefix(CloudSchema.Limits.nameCharacters))
        self.model = model
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.alertsAuthorized = alertsAuthorized
        self.timeSensitiveAllowed = timeSensitiveAllowed
        self.lastSeenAt = lastSeenAt
    }

    public var recordName: String { CloudSchema.RecordNamePrefix.phoneDevice + deviceID }
}

// MARK: - Items

/// Every record Kakureneko keeps in the zone.
public enum CloudItem: Sendable, Hashable {
    case alert(CloudAlert)
    case command(CloudCommand)
    case status(MacStatus)
    case device(PhoneDevice)

    public var id: CloudItemID {
        switch self {
        case .alert(let a): CloudItemID(recordType: CloudSchema.RecordType.alert, recordName: a.recordName)
        case .command(let c): CloudItemID(recordType: CloudSchema.RecordType.command, recordName: c.recordName)
        case .status(let s): CloudItemID(recordType: CloudSchema.RecordType.macStatus, recordName: s.recordName)
        case .device(let d): CloudItemID(recordType: CloudSchema.RecordType.phoneDevice, recordName: d.recordName)
        }
    }
}

/// A record's identity within the Kakureneko zone.
public struct CloudItemID: Sendable, Hashable, Codable, CustomStringConvertible {
    public var recordType: String
    public var recordName: String

    public init(recordType: String, recordName: String) {
        self.recordType = recordType
        self.recordName = recordName
    }

    public static func alert(_ id: String) -> CloudItemID {
        CloudItemID(recordType: CloudSchema.RecordType.alert, recordName: CloudSchema.RecordNamePrefix.alert + id)
    }

    public static func command(_ id: String) -> CloudItemID {
        CloudItemID(recordType: CloudSchema.RecordType.command, recordName: CloudSchema.RecordNamePrefix.command + id)
    }

    public var description: String { "\(recordType)/\(recordName)" }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
