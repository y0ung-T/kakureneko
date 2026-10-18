// The Kakureneko zone as this iPhone knows it — the latest `MacStatus` of every Mac and the alerts of the last three
// days — and how one round of fetched zone changes updates it. Pure value logic (no I/O), used by `PhoneStore` and
// unit-tested directly.

import KakurenekoCloud
import Foundation

struct ZoneSnapshot: Equatable, Sendable {
    /// Alerts older than this are dropped (the Mac deletes its own after the same time).
    static let alertRetention: TimeInterval = 3 * 24 * 3600
    /// Upper bound of kept alerts, whatever their age (bounds the cache file).
    static let maximumAlerts = 500
    /// Keep awake duration before any Mac reported its own (`MacStatus`'s default).
    static let defaultKeepAwakeSeconds = 3600

    /// By `macID`.
    private(set) var statuses: [String: MacStatus] = [:]
    /// Newest first.
    private(set) var alerts: [CloudAlert] = []

    init(statuses: [MacStatus] = [], alerts: [CloudAlert] = [], now: Date) {
        for status in statuses { self.statuses[status.macID] = status }
        self.alerts = alerts
        normalizeAlerts(now: now)
    }

    /// The most recently updated status (its `keepAwakeSeconds` titles the notification buttons).
    var latestStatus: MacStatus? { statuses.values.max { $0.updatedAt < $1.updatedAt } }

    /// Applies one fetch. `fromScratch`: the fetch started without a change token, so it returned the whole zone and
    /// anything it did not return no longer exists. Placeholders of the schema bootstrap are ignored.
    /// - Returns: ids of `Command` records that were deleted — the Mac deletes a command once it handled it.
    @discardableResult
    mutating func apply(_ items: [CloudItem], deleted: [CloudItemID], fromScratch: Bool, now: Date) -> Set<String> {
        if fromScratch {
            statuses = [:]
            alerts = []
        }
        var alertsByID = Dictionary(alerts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in items where !CloudSchemaBootstrap.isPlaceholder(item) {
            switch item {
            case .status(let status): statuses[status.macID] = status
            case .alert(let alert): alertsByID[alert.id] = alert
            case .command, .device: continue // written by phones; nothing to show
            }
        }
        // Deletions last, so they win over a modification in the same fetch: a record created and deleted since the
        // token must not reappear.
        var handledCommands = Set<String>()
        for id in deleted {
            switch id.recordType {
            case CloudSchema.RecordType.macStatus:
                if let macID = Self.strip(id.recordName, CloudSchema.RecordNamePrefix.macStatus) { statuses[macID] = nil }
            case CloudSchema.RecordType.alert:
                if let alertID = Self.strip(id.recordName, CloudSchema.RecordNamePrefix.alert) { alertsByID[alertID] = nil }
            case CloudSchema.RecordType.command:
                if let commandID = Self.strip(id.recordName, CloudSchema.RecordNamePrefix.command) { handledCommands.insert(commandID) }
            default:
                continue
            }
        }
        alerts = Array(alertsByID.values)
        normalizeAlerts(now: now)
        return handledCommands
    }

    /// Removes one Mac (Remove on "Not seen recently").
    mutating func removeStatus(_ macID: String) {
        statuses[macID] = nil
    }

    /// The Macs' statuses from a whole read (`CloudStore.fetchAll`): a Mac whose status left iCloud leaves too.
    mutating func replaceStatuses(_ items: [CloudItem]) {
        var next: [String: MacStatus] = [:]
        for case .status(let status) in items where !CloudSchemaBootstrap.isPlaceholder(.status(status)) {
            next[status.macID] = status
        }
        statuses = next
    }

    /// Drops expired-by-age alerts and keeps the rest newest first.
    mutating func normalizeAlerts(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.alertRetention)
        alerts = Array(alerts.filter { $0.createdAt >= cutoff }
            .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
            .prefix(Self.maximumAlerts))
    }

    private static func strip(_ name: String, _ prefix: String) -> String? {
        guard name.hasPrefix(prefix), name.count > prefix.count else { return nil }
        return String(name.dropFirst(prefix.count))
    }
}
