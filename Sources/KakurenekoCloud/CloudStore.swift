import Foundation

/// iCloud availability for Kakureneko on this device.
public enum CloudAccountStatus: String, Sendable, Hashable, Codable {
    case available
    /// Not signed in to iCloud (or iCloud Drive/CloudKit turned off for Kakureneko).
    case noAccount
    /// Parental controls / MDM.
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine
    /// This build has no iCloud entitlement (ad-hoc / unprovisioned Mac build): phone alerts are unavailable.
    case unavailableInThisBuild

    public var isAvailable: Bool { self == .available }

    /// One sentence for the UI.
    public var explanation: String {
        switch self {
        case .available: "iCloud is available."
        case .noAccount: "Sign in to iCloud (System Settings → Apple Account) to get alerts on your iPhone."
        case .restricted: "iCloud is restricted on this device (Screen Time or device management)."
        case .temporarilyUnavailable: "iCloud is temporarily unavailable. Kakureneko will retry."
        case .couldNotDetermine: "Couldn't reach iCloud. Kakureneko will retry."
        case .unavailableInThisBuild: "This build of Kakureneko isn't signed for iCloud, so iPhone alerts are off."
        }
    }
}

/// A CloudKit failure, reduced to what callers act on.
public enum CloudError: Error, Sendable, Hashable, CustomStringConvertible {
    /// No iCloud account / CloudKit disabled for the app.
    case notSignedIn
    /// Offline or a server hiccup. Retry after the hint (seconds) or a backoff.
    case network(retryAfter: TimeInterval?)
    /// CloudKit asked us to slow down.
    case rateLimited(retryAfter: TimeInterval?)
    /// The store is not prepared (or lost its preparation): `prepare()` again and restart change fetching from
    /// scratch. (CloudKit's public database never reports it; kept for stores that have zones.)
    case zoneMissing
    /// The change token is no longer valid: fetch from scratch.
    case changeTokenExpired
    /// The user's iCloud storage is full.
    case quotaExceeded
    /// A subscription references a record type the (development) schema does not have yet.
    case unknownRecordType
    /// Anything else (bad request, permission, server rejected the record). Not retried.
    case permanent(String)

    public var isRetryable: Bool {
        switch self {
        case .network, .rateLimited: true
        default: false
        }
    }

    public var retryAfter: TimeInterval? {
        switch self {
        case .network(let after), .rateLimited(let after): after
        default: nil
        }
    }

    public var description: String {
        switch self {
        case .notSignedIn: "not signed in to iCloud"
        case .network(let after): "network unavailable" + (after.map { " (retry in \(Int($0)) s)" } ?? "")
        case .rateLimited(let after): "rate limited" + (after.map { " (retry in \(Int($0)) s)" } ?? "")
        case .zoneMissing: "zone missing"
        case .changeTokenExpired: "change token expired"
        case .quotaExceeded: "iCloud storage full"
        case .unknownRecordType: "record type missing from the schema"
        case .permanent(let message): message
        }
    }

    /// A user-facing sentence (settings / onboarding).
    public var userMessage: String {
        switch self {
        case .notSignedIn: CloudAccountStatus.noAccount.explanation
        case .network, .rateLimited: "Couldn't reach iCloud. Kakureneko will retry."
        case .quotaExceeded: "Kakureneko's iCloud space is full right now, so alerts can't reach your iPhone. Kakureneko keeps retrying."
        case .zoneMissing, .changeTokenExpired, .unknownRecordType: "iCloud is being set up. Kakureneko will retry."
        case .permanent(let message): "iCloud rejected the request: \(message)"
        }
    }
}

/// Opaque change token (an archived `CKServerChangeToken`), persisted by the caller.
public struct CloudChangeToken: Sendable, Hashable, Codable {
    public var data: Data
    public init(data: Data) { self.data = data }
}

/// One page of zone changes.
public struct CloudChangeBatch: Sendable, Hashable {
    /// Records created or changed since the token (decodable ones only; unknown or newer-schema records are skipped).
    public var items: [CloudItem]
    public var deleted: [CloudItemID]
    /// Store it and pass it to the next fetch (nil only if CloudKit returned none).
    public var token: CloudChangeToken?
    /// Fetch again immediately with `token`.
    public var moreComing: Bool

    public init(items: [CloudItem] = [], deleted: [CloudItemID] = [], token: CloudChangeToken?, moreComing: Bool = false) {
        self.items = items
        self.deleted = deleted
        self.token = token
        self.moreComing = moreComing
    }
}

/// The subscriptions Kakureneko creates (ids in `CloudSchema.SubscriptionID`), each limited to the user's own records.
public enum CloudSubscription: String, Sendable, Hashable, Codable, CaseIterable {
    /// Visible push for every new `Alert` (created by the iPhone app; the Mac that saved an alert never gets it).
    case alerts
    /// Silent pushes for new `Command`s and changed `PhoneDevice`s (created by the Mac).
    case macInbox
    /// Silent push for every changed `MacStatus` (created by the iPhone app).
    case phoneInbox

    /// The CloudKit subscription ids this creates.
    public var subscriptionIDs: [String] {
        switch self {
        case .alerts: [CloudSchema.SubscriptionID.alerts]
        case .macInbox: [CloudSchema.SubscriptionID.macCommands, CloudSchema.SubscriptionID.macDevices]
        case .phoneInbox: [CloudSchema.SubscriptionID.phoneStatuses]
        }
    }
}

/// The user's Kakureneko records, as both apps use them. Live: `CloudKitStore` (public database, creator-only);
/// tests: `InMemoryCloudStore`.
///
/// Every call is independent and safe to retry. Saves write every field of the record (last writer wins): each
/// record has exactly one writer (alerts and status: their Mac; commands and devices: their phone).
public protocol CloudStore: Sendable {
    func accountStatus() async -> CloudAccountStatus
    /// Gets ready for the other calls (resolves the user's identity; idempotent).
    func prepare() async throws(CloudError)
    /// Upserts. Throws the first failure; records that did save stay saved.
    func save(_ items: [CloudItem]) async throws(CloudError)
    /// Deletes; ids that do not exist are ignored.
    func delete(_ ids: [CloudItemID]) async throws(CloudError)
    /// The user's records of `types` changed since `token` (nil = everything). A store may return a record more than
    /// once across fetches (callers are idempotent) and does not report deletions (`CloudChangeBatch.deleted` empty
    /// in production): the few records that must disappear when deleted (Mac statuses, iPhones) are read whole with
    /// `fetchAll` instead.
    func fetchChanges(since token: CloudChangeToken?, types: [String]) async throws(CloudError) -> CloudChangeBatch
    /// Every one of the user's records of `recordType`. Callers REPLACE their copy with it, so a record deleted on
    /// the server (another device's Remove, a prune) disappears. Meant for the small types (MacStatus, PhoneDevice).
    func fetchAll(_ recordType: String) async throws(CloudError) -> [CloudItem]
    /// Deletes the user's records of `recordType` that the server last modified before `cutoff` (server time, so
    /// clocks don't matter) and returns how many went. Pruning by query, not by a local list, also removes records
    /// whose writer is gone (a reinstalled Mac, a deleted app).
    func deleteOwned(_ recordType: String, modifiedBefore cutoff: Date) async throws(CloudError) -> Int
    /// The Apple Account may have changed (`CKAccountChanged`): forget the cached identity; the next call resolves it.
    func resetIdentity() async
    /// A short tag of the signed-in Apple Account (a hash, never the account itself): callers keep it next to their
    /// account-bound state and start over when it changes.
    func accountTag() async throws(CloudError) -> String
    /// One record by id (nil when it does not exist or cannot be decoded). The iPhone's notification extension
    /// uses it when a push arrives without its fields.
    func fetch(_ id: CloudItemID) async throws(CloudError) -> CloudItem?
    /// Creates or replaces a subscription (idempotent: fixed ids).
    func saveSubscription(_ subscription: CloudSubscription) async throws(CloudError)
}

extension CloudStore {
    /// Changes of every record type.
    public func fetchChanges(since token: CloudChangeToken?) async throws(CloudError) -> CloudChangeBatch {
        try await fetchChanges(since: token, types: CloudSchema.RecordType.all)
    }

    /// Every change of `types` since `token`, following `moreComing` (bounded to `maxPages` pages).
    public func fetchAllChanges(since token: CloudChangeToken?, types: [String] = CloudSchema.RecordType.all,
                                maxPages: Int = 20) async throws(CloudError) -> CloudChangeBatch {
        var merged = CloudChangeBatch(token: token)
        var cursor = token
        for _ in 0..<max(1, maxPages) {
            let page = try await fetchChanges(since: cursor, types: types)
            merged.items += page.items
            merged.deleted += page.deleted
            merged.token = page.token ?? merged.token
            merged.moreComing = page.moreComing
            cursor = merged.token
            if !page.moreComing { break }
        }
        return merged
    }
}

extension CloudStore {
    /// Creates `subscription`; when the (development) schema lacks the record types it refers to, first creates
    /// them by saving and deleting one placeholder of every type with every field set, then retries once.
    /// Production containers get their schema from the CloudKit console ("Deploy Schema Changes"), so there the
    /// first attempt succeeds.
    public func ensureSubscription(_ subscription: CloudSubscription, now: Date = Date()) async throws(CloudError) {
        do {
            try await saveSubscription(subscription)
        } catch .unknownRecordType {
            try await bootstrapSchema(now: now)
            try await saveSubscription(subscription)
        }
    }

    /// Saves and deletes `CloudSchemaBootstrap.placeholders` (development schema only creates types and fields
    /// on first save).
    public func bootstrapSchema(now: Date = Date()) async throws(CloudError) {
        let placeholders = CloudSchemaBootstrap.placeholders(now: now)
        try await save(placeholders)
        try await delete(placeholders.map(\.id))
    }
}

/// One record of every type with every optional field present, so a save creates the complete development
/// schema (field types included). Their ids start with `bootstrap-` and their `macID` is `bootstrap`, so a reader
/// that sees one before it is deleted ignores it.
public enum CloudSchemaBootstrap {
    public static let macID = "bootstrap"

    public static func placeholders(now: Date) -> [CloudItem] {
        let suffix = "bootstrap-" + UUID().uuidString
        return [
            .alert(CloudAlert(id: suffix, macID: macID, macName: "Bootstrap", kind: "test", title: "Bootstrap", body: "Schema",
                              threadID: "bootstrap", replaceKey: "bootstrap", interruption: .passive,
                              actions: [.keepAwake(seconds: 3600), .sleepNow, .shutDown], stateVersion: 0, createdAt: now,
                              expiresAt: now)),
            .command(CloudCommand(id: suffix, macID: macID, request: .refreshStatus, stateVersion: 0, alertID: suffix, issuedAt: now,
                                  expiresAt: now, deviceID: macID, deviceName: "Bootstrap")),
            .status(MacStatus(macID: suffix, macName: "Bootstrap", model: "Mac", phase: .idle, headline: "Bootstrap", detail: "Schema",
                              countdownEndsAt: now, keepAwakeUntil: now,
                              agents: [AgentSummary(agent: "Agent", project: "p", host: "h", activity: .idle, since: now, note: "n")],
                              batteryPercent: 100, onBattery: false, lidClosed: false, stateVersion: 0, keepAwakeSeconds: 3600,
                              shutdownEnabled: false, canSleep: true, updatedAt: now, appVersion: "0")),
            .device(PhoneDevice(deviceID: suffix, name: "Bootstrap", model: "iPhone", systemVersion: "0", appVersion: "0",
                                alertsAuthorized: false, timeSensitiveAllowed: false, lastSeenAt: now)),
        ]
    }

    /// True for a placeholder (skip it if a fetch catches one between its save and delete).
    public static func isPlaceholder(_ item: CloudItem) -> Bool {
        switch item {
        case .alert(let a): a.macID == macID
        case .command(let c): c.macID == macID
        case .status(let s): s.macID.hasPrefix("bootstrap-")
        case .device(let d): d.deviceID.hasPrefix("bootstrap-")
        }
    }
}
