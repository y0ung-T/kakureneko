import CloudKit
import Foundation

/// In-memory `CloudStore` for tests on both platforms: change tokens, paging, zone existence, account status and
/// injected failures behave like the CloudKit database Kakureneko uses. Records are kept as `CKRecord`s and a save
/// MERGES the saved keys into the stored record (keys the save does not carry keep their old value, like a CloudKit
/// save); fetches return each record in its CURRENT version, once per fetch. Like the public database, change fetches
/// do NOT report deletions (`reportsDeletions` turns that on for tests of a store that would).
public actor InMemoryCloudStore: CloudStore {
    public enum Operation: String, Sendable, Hashable, CaseIterable {
        case accountStatus, prepare, save, delete, fetchChanges, fetchAll, deleteOwned, fetch, saveSubscription
    }

    private var records: [CloudItemID: (record: CKRecord, sequence: Int)] = [:]
    /// Server-side modification time of each record (`deleteOwned` prunes by it).
    private var modifiedAt: [CloudItemID: Date] = [:]
    private let now: @Sendable () -> Date
    private var deletions: [CloudItemID: Int] = [:]
    private var sequence = 0
    private var failures: [Operation: [CloudError]] = [:]
    private var persistentFailures: [Operation: CloudError] = [:]

    public private(set) var zoneExists: Bool
    public private(set) var subscriptions: Set<CloudSubscription> = []
    public private(set) var operations: [Operation] = []
    public var account: CloudAccountStatus
    /// Like a fresh development container: subscriptions fail with `.unknownRecordType` until an `Alert` was saved.
    public var requiresSchemaBootstrap = false
    public private(set) var schemaBootstrapped = false
    /// Records per fetch page (exercises `moreComing`).
    public var pageSize: Int
    /// Change fetches list deleted ids (off: the public database never does).
    public var reportsDeletions = false
    /// The signed-in account's tag (`accountTag`); tests change it to simulate another Apple Account.
    public var accountTagValue = "account-a"

    /// `now`: the "server" clock behind modification times (tests pass their test clock).
    public init(account: CloudAccountStatus = .available, zoneExists: Bool = false, pageSize: Int = 200,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.account = account
        self.zoneExists = zoneExists
        self.pageSize = max(1, pageSize)
        self.now = now
    }

    // MARK: Test controls

    /// The next `operation` call(s) throw these errors, in order.
    public func failNext(_ operation: Operation, with errors: CloudError...) { failures[operation, default: []] += errors }
    /// Every `operation` call throws `error` until it is set to nil (after any queued `failNext` errors).
    public func setPersistentFailure(_ operation: Operation, _ error: CloudError?) { persistentFailures[operation] = error }
    /// How many times `operation` was called.
    public func count(_ operation: Operation) -> Int { operations.filter { $0 == operation }.count }
    public func setAccount(_ status: CloudAccountStatus) { account = status }
    public func setPageSize(_ size: Int) { pageSize = max(1, size) }
    public func setRequiresSchemaBootstrap(_ required: Bool) { requiresSchemaBootstrap = required }
    public func setReportsDeletions(_ reports: Bool) { reportsDeletions = reports }
    public func setAccountTag(_ tag: String) { accountTagValue = tag }
    /// Makes a record look last modified at `date` (prune tests).
    public func setModified(_ id: CloudItemID, at date: Date) { modifiedAt[id] = date }
    /// The user deleted the app's iCloud data: zone, records and change history are gone.
    public func deleteZone() {
        zoneExists = false
        records = [:]
        deletions = [:]
        modifiedAt = [:]
    }
    /// What a fetch from scratch would return (decodable records only).
    public var allItems: [CloudItem] {
        records.values.sorted { $0.sequence < $1.sequence }.compactMap { CloudRecordCoding.item(from: $0.record) }
    }
    public func items(ofType recordType: String) -> [CloudItem] { allItems.filter { $0.id.recordType == recordType } }
    /// The stored value of one field (tests check what a merge left behind).
    public func rawValue(_ key: String, of id: CloudItemID) -> String? {
        records[id].flatMap { $0.record[key] }.map { String(describing: $0) }
    }
    public func contains(_ id: CloudItemID) -> Bool { records[id] != nil }
    public func clearOperations() { operations = [] }

    // MARK: CloudStore

    public func accountStatus() async -> CloudAccountStatus {
        operations.append(.accountStatus)
        return account
    }

    public func prepare() async throws(CloudError) {
        try begin(.prepare, needsZone: false)
        zoneExists = true
    }

    public func save(_ items: [CloudItem]) async throws(CloudError) {
        try begin(.save)
        for item in items {
            if case .alert = item { schemaBootstrapped = true }
            sequence += 1
            let incoming = CloudRecordCoding.record(for: item)
            if let existing = records[item.id]?.record {
                for key in incoming.allKeys() { existing[key] = incoming[key] }
                records[item.id] = (existing, sequence)
            } else {
                records[item.id] = (incoming, sequence)
            }
            deletions[item.id] = nil
            modifiedAt[item.id] = now()
        }
    }

    public func delete(_ ids: [CloudItemID]) async throws(CloudError) {
        try begin(.delete)
        for id in ids { remove(id) }
    }

    private func remove(_ id: CloudItemID) {
        guard records.removeValue(forKey: id) != nil else { return }
        modifiedAt[id] = nil
        sequence += 1
        deletions[id] = sequence
    }

    public func fetchAll(_ recordType: String) async throws(CloudError) -> [CloudItem] {
        try begin(.fetchAll)
        return items(ofType: recordType)
    }

    public func deleteOwned(_ recordType: String, modifiedBefore cutoff: Date) async throws(CloudError) -> Int {
        try begin(.deleteOwned)
        let old = records.keys.filter { $0.recordType == recordType && (modifiedAt[$0] ?? .distantPast) < cutoff }
        for id in old { remove(id) }
        return old.count
    }

    public func resetIdentity() async {}

    public func accountTag() async throws(CloudError) -> String {
        guard account.isAvailable else { throw .notSignedIn }
        return accountTagValue
    }

    public func fetchChanges(since token: CloudChangeToken?, types: [String]) async throws(CloudError) -> CloudChangeBatch {
        try begin(.fetchChanges)
        let after = token.flatMap(Self.sequence(of:)) ?? 0
        if after > sequence { throw .changeTokenExpired }
        typealias Change = (sequence: Int, item: CloudItem?, deleted: CloudItemID?)
        var changes: [Change] = records.filter { types.contains($0.key.recordType) && $0.value.sequence > after }
            .map { ($0.value.sequence, CloudRecordCoding.item(from: $0.value.record), nil) }
        if reportsDeletions {
            changes += deletions.filter { types.contains($0.key.recordType) && $0.value > after }.map { ($0.value, nil, $0.key) }
        }
        changes.sort { $0.sequence < $1.sequence }
        let page = changes.prefix(pageSize)
        let last = page.last?.sequence ?? max(after, token == nil ? sequence : after)
        return CloudChangeBatch(
            items: page.compactMap { $0.item }, deleted: page.compactMap(\.deleted),
            token: Self.token(last), moreComing: changes.count > page.count)
    }

    public func fetch(_ id: CloudItemID) async throws(CloudError) -> CloudItem? {
        try begin(.fetch)
        return records[id].flatMap { CloudRecordCoding.item(from: $0.record) }
    }

    public func saveSubscription(_ subscription: CloudSubscription) async throws(CloudError) {
        try begin(.saveSubscription)
        if requiresSchemaBootstrap && !schemaBootstrapped { throw .unknownRecordType }
        subscriptions.insert(subscription)
    }

    // MARK: Helpers

    private func begin(_ operation: Operation, needsZone: Bool = true) throws(CloudError) {
        operations.append(operation)
        if var queued = failures[operation], !queued.isEmpty {
            let error = queued.removeFirst()
            failures[operation] = queued
            throw error
        }
        if let error = persistentFailures[operation] { throw error }
        guard account.isAvailable else { throw .notSignedIn }
        if needsZone && !zoneExists { throw .zoneMissing }
    }

    static func token(_ sequence: Int) -> CloudChangeToken {
        CloudChangeToken(data: Data("seq:\(sequence)".utf8))
    }

    static func sequence(of token: CloudChangeToken) -> Int? {
        let text = String(decoding: token.data, as: UTF8.self)
        guard text.hasPrefix("seq:") else { return nil }
        return Int(text.dropFirst(4))
    }
}
