import CloudKit
import Foundation

/// CloudItem ⇄ CKRecord. Creating `CKRecord`s needs no entitlement, so this is unit-tested on both platforms.
///
/// Every record writes EVERY field of its type, an absent optional as its sentinel (`CloudSchema.Absent`): a CloudKit
/// save only modifies the keys it carries, so an omitted key would keep its previous server value (a cancelled
/// countdown would still show on the phone), and a field that is never written would be missing from the
/// development schema that is deployed to production.
public enum CloudRecordCoding {
    /// The public database's default zone (where every Kakureneko record lives).
    public static func zoneID() -> CKRecordZone.ID {
        CKRecordZone.ID.default
    }

    public static func recordID(_ id: CloudItemID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.recordName, zoneID: zoneID())
    }

    // MARK: Encoding

    /// `recordID`: where the record is saved (CloudKitStore scopes Mac and iPhone records to the account).
    public static func record(for item: CloudItem, recordID: CKRecord.ID? = nil) -> CKRecord {
        let record = CKRecord(recordType: item.id.recordType, recordID: recordID ?? Self.recordID(item.id))
        let fields = FieldWriter(record: record)
        fields.int(CloudSchema.Field.schema, CloudSchema.version)
        switch item {
        case .alert(let a):
            fields.string(CloudSchema.Field.macID, a.macID)
            fields.string(CloudSchema.Field.macName, a.macName)
            fields.string(CloudSchema.Field.kind, a.kind)
            fields.string(CloudSchema.Field.title, a.title)
            fields.string(CloudSchema.Field.body, a.body)
            fields.string(CloudSchema.Field.threadID, a.threadID)
            fields.string(CloudSchema.Field.replaceKey, a.replaceKey)
            fields.string(CloudSchema.Field.interruption, a.interruption.rawValue)
            fields.strings(CloudSchema.Field.actions, a.actions.map(\.wireValue))
            fields.int(CloudSchema.Field.stateVersion, a.stateVersion)
            fields.date(CloudSchema.Field.createdAt, a.createdAt)
            fields.date(CloudSchema.Field.expiresAt, a.expiresAt)
        case .command(let c):
            fields.string(CloudSchema.Field.macID, c.macID)
            fields.string(CloudSchema.Field.request, c.request.wireValue)
            fields.int(CloudSchema.Field.stateVersion, c.stateVersion)
            fields.string(CloudSchema.Field.alertID, c.alertID)
            fields.date(CloudSchema.Field.createdAt, c.issuedAt)
            fields.date(CloudSchema.Field.expiresAt, c.expiresAt)
            fields.string(CloudSchema.Field.deviceID, c.deviceID)
            fields.string(CloudSchema.Field.deviceName, c.deviceName)
        case .status(let s):
            fields.string(CloudSchema.Field.macID, s.macID)
            fields.string(CloudSchema.Field.macName, s.macName)
            fields.string(CloudSchema.Field.model, s.model)
            fields.string(CloudSchema.Field.phase, s.phase.rawValue)
            fields.string(CloudSchema.Field.headline, s.headline)
            fields.string(CloudSchema.Field.detail, s.detail)
            fields.date(CloudSchema.Field.countdownEndsAt, s.countdownEndsAt)
            fields.date(CloudSchema.Field.keepAwakeUntil, s.keepAwakeUntil)
            fields.string(CloudSchema.Field.agentsJSON, encodeAgents(s.agents))
            fields.int(CloudSchema.Field.batteryPercent, s.batteryPercent)
            fields.bool(CloudSchema.Field.onBattery, s.onBattery)
            fields.bool(CloudSchema.Field.lidClosed, s.lidClosed)
            fields.int(CloudSchema.Field.stateVersion, s.stateVersion)
            fields.int(CloudSchema.Field.keepAwakeSeconds, s.keepAwakeSeconds)
            fields.bool(CloudSchema.Field.shutdownEnabled, s.shutdownEnabled)
            fields.bool(CloudSchema.Field.canSleep, s.canSleep)
            fields.date(CloudSchema.Field.updatedAt, s.updatedAt)
            fields.string(CloudSchema.Field.appVersion, s.appVersion)
        case .device(let d):
            fields.string(CloudSchema.Field.deviceID, d.deviceID)
            fields.string(CloudSchema.Field.name, d.name)
            fields.string(CloudSchema.Field.model, d.model)
            fields.string(CloudSchema.Field.systemVersion, d.systemVersion)
            fields.string(CloudSchema.Field.appVersion, d.appVersion)
            fields.bool(CloudSchema.Field.alertsAuthorized, d.alertsAuthorized)
            fields.bool(CloudSchema.Field.timeSensitiveAllowed, d.timeSensitiveAllowed)
            fields.date(CloudSchema.Field.lastSeenAt, d.lastSeenAt)
        }
        return record
    }

    // MARK: Decoding

    /// nil for a record of an unknown type, a newer schema, a malformed record, or one outside the default zone.
    public static func item(from record: CKRecord) -> CloudItem? {
        guard record.recordID.zoneID.zoneName == CloudSchema.zoneName else { return nil }
        let fields = FieldReader(values: { record[$0] })
        return item(recordType: record.recordType, recordName: record.recordID.recordName, fields: fields)
    }

    /// An alert rebuilt from a CloudKit push (`CKQueryNotification.recordFields` of the `alerts-v1` subscription).
    /// nil when the payload lacks required fields (CloudKit drops `desiredKeys` that do not fit; then fetch it).
    public static func alert(pushFields: [String: Any], recordName: String) -> CloudAlert? {
        let fields = FieldReader(values: { pushFields[$0] })
        guard case .alert(let alert)? = item(recordType: CloudSchema.RecordType.alert, recordName: recordName, fields: fields) else {
            return nil
        }
        return alert
    }

    static func item(recordType: String, recordName: String, fields f: FieldReader) -> CloudItem? {
        if let schema = f.int(CloudSchema.Field.schema), schema > CloudSchema.version { return nil }
        switch recordType {
        case CloudSchema.RecordType.alert:
            guard let id = strip(recordName, CloudSchema.RecordNamePrefix.alert),
                  let macID = f.string(CloudSchema.Field.macID), let title = f.string(CloudSchema.Field.title),
                  let createdAt = f.date(CloudSchema.Field.createdAt), let expiresAt = f.date(CloudSchema.Field.expiresAt) else { return nil }
            return .alert(CloudAlert(
                id: id, macID: macID, macName: f.string(CloudSchema.Field.macName) ?? "Mac",
                kind: f.string(CloudSchema.Field.kind) ?? "", title: title, body: f.string(CloudSchema.Field.body) ?? "",
                threadID: f.string(CloudSchema.Field.threadID) ?? macID, replaceKey: f.optionalString(CloudSchema.Field.replaceKey),
                interruption: f.string(CloudSchema.Field.interruption).flatMap(AlertInterruption.init(rawValue:)) ?? .active,
                actions: (f.strings(CloudSchema.Field.actions) ?? []).compactMap(CloudAction.init(wireValue:)),
                stateVersion: f.int(CloudSchema.Field.stateVersion) ?? 0, createdAt: createdAt, expiresAt: expiresAt))
        case CloudSchema.RecordType.command:
            guard let id = strip(recordName, CloudSchema.RecordNamePrefix.command),
                  let macID = f.string(CloudSchema.Field.macID),
                  let request = f.string(CloudSchema.Field.request).flatMap(CloudRequest.init(wireValue:)),
                  let issuedAt = f.date(CloudSchema.Field.createdAt), let expiresAt = f.date(CloudSchema.Field.expiresAt) else { return nil }
            return .command(CloudCommand(
                id: id, macID: macID, request: request, stateVersion: f.int(CloudSchema.Field.stateVersion),
                alertID: f.optionalString(CloudSchema.Field.alertID), issuedAt: issuedAt, expiresAt: expiresAt,
                deviceID: f.string(CloudSchema.Field.deviceID) ?? "", deviceName: f.string(CloudSchema.Field.deviceName) ?? "iPhone"))
        case CloudSchema.RecordType.macStatus:
            guard strip(recordName, CloudSchema.RecordNamePrefix.macStatus) != nil,
                  let macID = f.string(CloudSchema.Field.macID),
                  let phase = f.string(CloudSchema.Field.phase).flatMap(MacPhase.init(rawValue:)),
                  let updatedAt = f.date(CloudSchema.Field.updatedAt) else { return nil }
            return .status(MacStatus(
                macID: macID, macName: f.string(CloudSchema.Field.macName) ?? "Mac", model: f.optionalString(CloudSchema.Field.model),
                phase: phase, headline: f.string(CloudSchema.Field.headline) ?? "", detail: f.optionalString(CloudSchema.Field.detail),
                countdownEndsAt: f.date(CloudSchema.Field.countdownEndsAt), keepAwakeUntil: f.date(CloudSchema.Field.keepAwakeUntil),
                agents: decodeAgents(f.string(CloudSchema.Field.agentsJSON)), batteryPercent: f.int(CloudSchema.Field.batteryPercent),
                onBattery: f.bool(CloudSchema.Field.onBattery) ?? false, lidClosed: f.bool(CloudSchema.Field.lidClosed) ?? false,
                stateVersion: f.int(CloudSchema.Field.stateVersion) ?? 0,
                keepAwakeSeconds: f.int(CloudSchema.Field.keepAwakeSeconds) ?? 3600,
                shutdownEnabled: f.bool(CloudSchema.Field.shutdownEnabled) ?? false, canSleep: f.bool(CloudSchema.Field.canSleep) ?? true,
                updatedAt: updatedAt, appVersion: f.string(CloudSchema.Field.appVersion) ?? ""))
        case CloudSchema.RecordType.phoneDevice:
            guard strip(recordName, CloudSchema.RecordNamePrefix.phoneDevice) != nil,
                  let deviceID = f.string(CloudSchema.Field.deviceID), let lastSeenAt = f.date(CloudSchema.Field.lastSeenAt) else { return nil }
            return .device(PhoneDevice(
                deviceID: deviceID, name: f.string(CloudSchema.Field.name) ?? "iPhone", model: f.string(CloudSchema.Field.model) ?? "",
                systemVersion: f.string(CloudSchema.Field.systemVersion) ?? "", appVersion: f.string(CloudSchema.Field.appVersion) ?? "",
                alertsAuthorized: f.bool(CloudSchema.Field.alertsAuthorized) ?? false,
                timeSensitiveAllowed: f.bool(CloudSchema.Field.timeSensitiveAllowed), lastSeenAt: lastSeenAt))
        default:
            return nil
        }
    }

    /// The `CloudItemID` of a CloudKit record id (nil outside the default zone).
    public static func itemID(_ recordID: CKRecord.ID, recordType: String) -> CloudItemID? {
        guard recordID.zoneID.zoneName == CloudSchema.zoneName else { return nil }
        return CloudItemID(recordType: recordType, recordName: recordID.recordName)
    }

    // MARK: Helpers

    static func strip(_ name: String, _ prefix: String) -> String? {
        guard name.hasPrefix(prefix), name.count > prefix.count else { return nil }
        return String(name.dropFirst(prefix.count))
    }

    static func encodeAgents(_ agents: [AgentSummary]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(agents) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeAgents(_ json: String?) -> [AgentSummary] {
        guard let json else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([AgentSummary].self, from: Data(json.utf8))) ?? []
    }
}

/// Writes typed values. A nil value is written as its sentinel (never omitted, see `CloudRecordCoding`).
struct FieldWriter {
    let record: CKRecord

    func string(_ key: String, _ value: String?) {
        record[key] = (value ?? CloudSchema.Absent.string) as NSString
    }

    /// An empty list is written as `[""]` (readers drop entries they cannot parse): CloudKit cannot infer a field
    /// type from an empty list.
    func strings(_ key: String, _ value: [String]) {
        let list = value.isEmpty ? [CloudSchema.Absent.string] : value
        record[key] = list.map { $0 as NSString } as NSArray
    }

    func int(_ key: String, _ value: Int?) {
        record[key] = NSNumber(value: value.map(Int64.init) ?? CloudSchema.Absent.number)
    }

    func bool(_ key: String, _ value: Bool?) {
        record[key] = NSNumber(value: value.map { Int64($0 ? 1 : 0) } ?? CloudSchema.Absent.number)
    }

    func date(_ key: String, _ value: Date?) {
        record[key] = NSNumber(value: value.map { Int64($0.timeIntervalSince1970.rounded(.down)) } ?? CloudSchema.Absent.number)
    }
}

/// Reads typed values from a record or a push payload (tolerant: numbers may arrive as any NSNumber, dates as
/// seconds or as `Date`, string lists as `[String]` or `NSArray`). Number sentinels read as nil everywhere; the empty
/// string reads as nil only through `optionalString` (a required text such as a body may legitimately be empty).
struct FieldReader {
    let values: (String) -> Any?

    func string(_ key: String) -> String? {
        switch values(key) {
        case let s as String: s
        case let s as NSString: s as String
        default: nil
        }
    }

    func optionalString(_ key: String) -> String? {
        string(key).flatMap { $0 == CloudSchema.Absent.string ? nil : $0 }
    }

    func strings(_ key: String) -> [String]? {
        let list: [String]? = switch values(key) {
        case let list as [String]: list
        case let list as NSArray: list.compactMap { $0 as? String }
        case let single as String: [single]
        default: nil
        }
        return list?.filter { $0 != CloudSchema.Absent.string }
    }

    func int(_ key: String) -> Int? {
        let raw: Int64? = switch values(key) {
        case let n as NSNumber: n.int64Value
        case let n as Int: Int64(n)
        case let n as Int64: n
        case let s as String: Int64(s)
        default: nil
        }
        guard let raw, raw != CloudSchema.Absent.number else { return nil }
        return Int(raw)
    }

    func bool(_ key: String) -> Bool? { int(key).map { $0 != 0 } }

    func date(_ key: String) -> Date? {
        switch values(key) {
        case let d as Date: d
        default: int(key).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        }
    }
}
