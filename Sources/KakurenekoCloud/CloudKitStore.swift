import CloudKit
import CryptoKit
import Foundation
import Synchronization
#if os(macOS)
import Security
#endif

/// The live `CloudStore`: the PUBLIC database of `CloudSchema.containerIdentifier`, default zone.
///
/// Why public: private-database records count against the user's iCloud storage, so a full iCloud (common on the
/// free 5 GB plan) would silently break Kakureneko. Public-database storage comes from the app's CloudKit allowance.
/// Privacy comes from the schema's security roles (`Xcode/CloudKit/schema.ckdb`): every Kakureneko record type is
/// readable and writable by its CREATOR only (no world read), so only the Apple Account that saved a record — the
/// same account on the user's Mac and iPhone — can read it.
///
/// Trust: every record carries `owner` = the user's record name; queries and subscriptions filter on it, and a
/// fetched record is used only when the server-set `creatorUserRecordID` is the current user too (an `owner`
/// field alone could be forged by another account).
///
/// Changes: the public database has no change tokens, so `fetchChanges` queries each record type for the user's
/// records modified after a watermark (the newest modification date seen, minus an overlap that absorbs the
/// public database's indexing delay). Deletions are not reported: `fetchAll` reads the small types whole, and
/// `deleteOwned` prunes by age on the server.
///
/// Account scope: record names live in one namespace for every account of the public database, so the names of
/// the long-lived records (one MacStatus per Mac, one PhoneDevice per iPhone, whose ids outlive a switch of Apple
/// Account) carry a tag of the account: another account's old record can never block a save. Callers never see it
/// (they use `CloudItemID`s; those records are decoded from their fields).
///
/// Requests: at most `chunkSize` records per modify request (CloudKit refuses more than 400).
///
/// Create it ONLY through `makeIfEntitled()`: instantiating `CKContainer` in a process without the iCloud
/// entitlement (unit tests, an ad-hoc Mac build) crashes the process.
///
/// Isolation: `CKContainer` / `CKDatabase` are thread-safe; the resolved user identity sits behind a Mutex.
public final class CloudKitStore: CloudStore, @unchecked Sendable {
    /// Records modified up to this long before the watermark are fetched again (the public database's query index
    /// lags behind saves by up to a few seconds; consumers are idempotent).
    static let watermarkOverlap: TimeInterval = 120
    /// Records per query page, and at most this many pages per record type and fetch.
    static let pageSize = 200
    static let maxPages = 10
    /// Records per modify request.
    static let chunkSize = 200

    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID = CloudRecordCoding.zoneID()
    private let owner = Mutex<String?>(nil)

    private init(containerIdentifier: String) {
        container = CKContainer(identifier: containerIdentifier)
        database = container.publicCloudDatabase
    }

    /// nil when this process may not use the Kakureneko container (see the type documentation).
    public static func makeIfEntitled(containerIdentifier: String = CloudSchema.containerIdentifier) -> CloudKitStore? {
        guard hasContainerEntitlement(containerIdentifier) else { return nil }
        return CloudKitStore(containerIdentifier: containerIdentifier)
    }

    /// True when the running binary is signed with `com.apple.developer.icloud-container-identifiers` containing
    /// `containerIdentifier`. iOS apps are always built with it (the iPhone targets declare it).
    public static func hasContainerEntitlement(_ containerIdentifier: String = CloudSchema.containerIdentifier) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains(containerIdentifier) ?? false
        #else
        return true
        #endif
    }

    // MARK: CloudStore

    public func accountStatus() async -> CloudAccountStatus {
        do {
            switch try await container.accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .temporarilyUnavailable: return .temporarilyUnavailable
            case .couldNotDetermine: return .couldNotDetermine
            @unknown default: return .couldNotDetermine
            }
        } catch {
            return Self.map(error) == .notSignedIn ? .noAccount : .couldNotDetermine
        }
    }

    public func prepare() async throws(CloudError) {
        _ = try await ownerName()
    }

    public func save(_ items: [CloudItem]) async throws(CloudError) {
        guard !items.isEmpty else { return }
        let owner = try await ownerName()
        let records = items.map { item -> CKRecord in
            let record = CloudRecordCoding.record(for: item, recordID: Self.recordID(item.id, owner: owner))
            record[CloudSchema.Field.owner] = owner as NSString
            return record
        }
        for chunk in Self.chunks(records) {
            do {
                let result = try await database.modifyRecords(saving: chunk, deleting: [], savePolicy: .allKeys, atomically: false)
                for (_, outcome) in result.saveResults {
                    if case .failure(let error) = outcome { throw Self.map(error) }
                }
            } catch let error as CloudError {
                throw error
            } catch {
                throw Self.map(error)
            }
        }
    }

    public func delete(_ ids: [CloudItemID]) async throws(CloudError) {
        guard !ids.isEmpty else { return }
        let owner = try await ownerName()
        try await deleteRecords(ids.map { Self.recordID($0, owner: owner) })
    }

    /// Deletes in chunks, every chunk tried. Already gone and not ours to delete (another account's record) are
    /// skipped, so one such id never blocks the rest; any other failure is thrown after the last chunk.
    private func deleteRecords(_ recordIDs: [CKRecord.ID]) async throws(CloudError) {
        var firstFailure: CloudError?
        for chunk in Self.chunks(recordIDs) {
            do {
                let result = try await database.modifyRecords(saving: [], deleting: chunk, savePolicy: .allKeys, atomically: false)
                for (_, outcome) in result.deleteResults {
                    guard case .failure(let error) = outcome else { continue }
                    let code = (error as? CKError)?.code
                    if code == .unknownItem || code == .permissionFailure { continue }
                    firstFailure = firstFailure ?? Self.map(error)
                }
            } catch {
                firstFailure = firstFailure ?? Self.map(error)
                if firstFailure?.isRetryable == true { break } // offline: the rest would fail the same way
            }
        }
        if let firstFailure { throw firstFailure }
    }

    public func fetchAll(_ recordType: String) async throws(CloudError) -> [CloudItem] {
        let owner = try await ownerName()
        return try await query(recordType, owner: owner, modifiedAfter: nil).compactMap { record in
            Self.isTrusted(record, owner: owner) ? CloudRecordCoding.item(from: record) : nil
        }
    }

    public func deleteOwned(_ recordType: String, modifiedBefore cutoff: Date) async throws(CloudError) -> Int {
        let owner = try await ownerName()
        let predicate = NSPredicate(format: "%K == %@ AND modificationDate < %@", CloudSchema.Field.owner, owner, cutoff as NSDate)
        let ids = try await query(recordType, predicate: predicate, desiredKeys: []).map(\.recordID)
        try await deleteRecords(ids)
        return ids.count
    }

    public func resetIdentity() async {
        owner.withLock { $0 = nil }
    }

    public func accountTag() async throws(CloudError) -> String {
        Self.tag(of: try await ownerName())
    }

    public func fetchChanges(since token: CloudChangeToken?, types: [String]) async throws(CloudError) -> CloudChangeBatch {
        let owner = try await ownerName()
        let watermark = token.flatMap(Self.watermark(of:))
        let after = watermark.map { $0.addingTimeInterval(-Self.watermarkOverlap) }
        var items: [CloudItem] = []
        var newest = watermark
        for recordType in types {
            let records = try await query(recordType, owner: owner, modifiedAfter: after)
            for record in records {
                if let modified = record.modificationDate, modified > (newest ?? .distantPast) { newest = modified }
                guard Self.isTrusted(record, owner: owner), let item = CloudRecordCoding.item(from: record) else { continue }
                items.append(item)
            }
        }
        return CloudChangeBatch(items: items, deleted: [], token: newest.map(Self.token(for:)) ?? token, moreComing: false)
    }

    public func fetch(_ id: CloudItemID) async throws(CloudError) -> CloudItem? {
        let owner = try await ownerName()
        do {
            let record = try await database.record(for: Self.recordID(id, owner: owner))
            guard Self.isTrusted(record, owner: owner) else { return nil }
            return CloudRecordCoding.item(from: record)
        } catch {
            if (error as? CKError)?.code == .unknownItem { return nil }
            throw Self.map(error)
        }
    }

    public func saveSubscription(_ subscription: CloudSubscription) async throws(CloudError) {
        let owner = try await ownerName()
        let subscriptions = Self.subscriptions(for: subscription, owner: owner)
        do {
            let result = try await database.modifySubscriptions(saving: subscriptions, deleting: [])
            for (_, outcome) in result.saveResults {
                if case .failure(let error) = outcome { throw Self.map(error, savingSubscription: true) }
            }
        } catch let error as CloudError {
            throw error
        } catch {
            throw Self.map(error, savingSubscription: true)
        }
    }

    // MARK: Identity, queries, subscriptions

    /// The user's record name in this container (the same on every device of the Apple Account), cached.
    func ownerName() async throws(CloudError) -> String {
        if let cached = owner.withLock({ $0 }) { return cached }
        do {
            let name = try await container.userRecordID().recordName
            owner.withLock { $0 = name }
            return name
        } catch {
            throw Self.map(error)
        }
    }

    /// The user's records of `recordType` modified after `modifiedAfter` (all when nil), oldest first.
    private func query(_ recordType: String, owner: String, modifiedAfter: Date?) async throws(CloudError) -> [CKRecord] {
        try await query(recordType, predicate: Self.predicate(owner: owner, modifiedAfter: modifiedAfter), desiredKeys: nil)
    }

    /// Up to `maxPages` pages of `recordType` matching `predicate`, oldest first (`desiredKeys` [] = ids only).
    private func query(_ recordType: String, predicate: NSPredicate, desiredKeys: [CKRecord.FieldKey]?) async throws(CloudError) -> [CKRecord] {
        let query = CKQuery(recordType: recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "modificationDate", ascending: true)]
        var records: [CKRecord] = []
        do {
            var (results, cursor) = try await database.records(matching: query, inZoneWith: zoneID, desiredKeys: desiredKeys,
                                                               resultsLimit: Self.pageSize)
            var pages = 1
            while true {
                for (_, outcome) in results {
                    if case .success(let record) = outcome { records.append(record) }
                }
                guard let next = cursor, pages < Self.maxPages else { break }
                (results, cursor) = try await database.records(continuingMatchFrom: next, desiredKeys: desiredKeys,
                                                               resultsLimit: Self.pageSize)
                pages += 1
            }
        } catch {
            throw Self.map(error)
        }
        return records
    }

    // MARK: Account scope, chunks

    /// A short, stable tag of an account's record name (not reversible).
    static func tag(of owner: String) -> String {
        SHA256.hash(data: Data(owner.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// Where `id` lives: Mac statuses and iPhone devices carry the account's tag (see the type documentation).
    static func recordID(_ id: CloudItemID, owner: String) -> CKRecord.ID {
        switch id.recordType {
        case CloudSchema.RecordType.macStatus, CloudSchema.RecordType.phoneDevice:
            CKRecord.ID(recordName: id.recordName + "-" + tag(of: owner), zoneID: CloudRecordCoding.zoneID())
        default:
            CloudRecordCoding.recordID(id)
        }
    }

    static func chunks<T>(_ items: [T]) -> [[T]] {
        stride(from: 0, to: items.count, by: chunkSize).map { Array(items[$0..<min($0 + chunkSize, items.count)]) }
    }

    static func predicate(owner: String, modifiedAfter: Date?) -> NSPredicate {
        guard let modifiedAfter else { return NSPredicate(format: "%K == %@", CloudSchema.Field.owner, owner) }
        return NSPredicate(format: "%K == %@ AND modificationDate > %@", CloudSchema.Field.owner, owner, modifiedAfter as NSDate)
    }

    /// The CloudKit subscriptions for `subscription`, limited to `owner`'s records.
    static func subscriptions(for subscription: CloudSubscription, owner: String) -> [CKSubscription] {
        let mine = NSPredicate(format: "%K == %@", CloudSchema.Field.owner, owner)
        switch subscription {
        case .alerts:
            let query = CKQuerySubscription(recordType: CloudSchema.RecordType.alert, predicate: mine,
                                            subscriptionID: CloudSchema.SubscriptionID.alerts, options: [.firesOnRecordCreation])
            let info = CKSubscription.NotificationInfo()
            // Fallback text if the notification extension cannot run: "%1$@" is not in any strings file, so iOS
            // uses the key itself as the format and shows the record's title / body.
            info.titleLocalizationKey = "%1$@"
            info.titleLocalizationArgs = [CloudSchema.Field.title]
            info.alertLocalizationKey = "%1$@"
            info.alertLocalizationArgs = [CloudSchema.Field.body]
            info.soundName = "default"
            info.category = NotificationIDs.plainCategory
            info.shouldSendMutableContent = true
            info.desiredKeys = CloudSchema.Field.alertPushKeys.isEmpty ? nil : CloudSchema.Field.alertPushKeys
            query.notificationInfo = info
            return [query]
        case .macInbox:
            return [
                silent(CloudSchema.RecordType.command, id: CloudSchema.SubscriptionID.macCommands, predicate: mine, options: [.firesOnRecordCreation]),
                silent(CloudSchema.RecordType.phoneDevice, id: CloudSchema.SubscriptionID.macDevices, predicate: mine,
                       options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]),
            ]
        case .phoneInbox:
            return [silent(CloudSchema.RecordType.macStatus, id: CloudSchema.SubscriptionID.phoneStatuses, predicate: mine,
                           options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion])]
        }
    }

    private static func silent(_ recordType: String, id: String, predicate: NSPredicate,
                               options: CKQuerySubscription.Options) -> CKQuerySubscription {
        let subscription = CKQuerySubscription(recordType: recordType, predicate: predicate, subscriptionID: id, options: options)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        return subscription
    }

    /// A record of the current user: the `owner` field matches AND the server says the current user created it
    /// (CloudKit reports the current user's own records as `CKCurrentUserDefaultName`).
    static func isTrusted(_ record: CKRecord, owner: String) -> Bool {
        guard (record[CloudSchema.Field.owner] as? String) == owner, let creator = record.creatorUserRecordID?.recordName else { return false }
        return creator == CKCurrentUserDefaultName || creator == owner
    }

    // MARK: Tokens and errors

    private struct Watermark: Codable { var modifiedAfter: Double }

    static func token(for date: Date) -> CloudChangeToken {
        CloudChangeToken(data: (try? JSONEncoder().encode(Watermark(modifiedAfter: date.timeIntervalSince1970))) ?? Data())
    }

    static func watermark(of token: CloudChangeToken) -> Date? {
        (try? JSONDecoder().decode(Watermark.self, from: token.data)).map { Date(timeIntervalSince1970: $0.modifiedAfter) }
    }

    /// CKError → CloudError (partial failures: the first item error decides). A cancelled request (the app stopping,
    /// a timeout) is retryable: the work it carried is still to be done.
    static func map(_ error: any Error, savingSubscription: Bool = false) -> CloudError {
        if error is CancellationError { return .network(retryAfter: nil) }
        guard let ck = error as? CKError else { return .permanent(String(describing: type(of: error))) }
        let retryAfter = ck.retryAfterSeconds
        switch ck.code {
        case .notAuthenticated, .managedAccountRestricted, .permissionFailure:
            return ck.code == .notAuthenticated ? .notSignedIn : .permanent("permission denied (\(ck.code.rawValue))")
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .zoneBusy, .accountTemporarilyUnavailable, .operationCancelled:
            return .network(retryAfter: retryAfter)
        case .requestRateLimited:
            return .rateLimited(retryAfter: retryAfter)
        case .zoneNotFound, .userDeletedZone:
            return .zoneMissing
        case .changeTokenExpired:
            return .changeTokenExpired
        case .quotaExceeded:
            // The storage quota (in the public database: the app's container) is used up; CloudKit adds a retry time.
            return .quotaExceeded
        case .unknownItem where savingSubscription, .invalidArguments where savingSubscription:
            return .unknownRecordType
        case .partialFailure:
            if let first = ck.partialErrorsByItemID?.values.first { return map(first, savingSubscription: savingSubscription) }
            return .permanent("partial failure")
        default:
            let server = (ck.userInfo["ServerErrorDescription"] as? String).map { ": " + $0.prefix(160) } ?? ""
            return .permanent("CloudKit error \(ck.code.rawValue)\(server)")
        }
    }
}
