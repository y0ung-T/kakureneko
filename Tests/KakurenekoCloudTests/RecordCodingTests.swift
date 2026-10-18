import CloudKit
import Foundation
import Testing
@testable import KakurenekoCloud

@Suite("Record coding")
struct RecordCodingTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    var alert: CloudAlert {
        CloudAlert(id: "A1", macID: "mac-1", macName: "Studio", kind: "countdown", title: "Mac sleeps in 5 min",
                   body: "All agents done.", threadID: "countdown", replaceKey: "countdown", interruption: .timeSensitive,
                   actions: [.keepAwake(seconds: 3600), .sleepNow], stateVersion: 42, createdAt: t0, expiresAt: t0.addingTimeInterval(300))
    }

    @Test func everyItemRoundTrips() throws {
        let command = CloudCommand(id: "C1", macID: "mac-1", request: .sleepNow, stateVersion: 42, alertID: "A1", issuedAt: t0,
                                   expiresAt: t0.addingTimeInterval(600), deviceID: "D1", deviceName: "iPhone")
        let status = MacStatus(
            macID: "mac-1", macName: "Studio", model: "MacBook Pro", phase: .countdown, headline: "Sleeping soon",
            detail: "All agents done", countdownEndsAt: t0.addingTimeInterval(300), keepAwakeUntil: t0.addingTimeInterval(60),
            agents: [AgentSummary(agent: "Claude Code", project: "kakureneko", host: "Terminal", activity: .finished, since: t0, note: nil),
                     AgentSummary(agent: "Codex", activity: .waiting, since: t0, note: "Needs permission")],
            batteryPercent: 81, onBattery: true, lidClosed: true, stateVersion: 42, keepAwakeSeconds: 1800, shutdownEnabled: true,
            canSleep: false, updatedAt: t0, appVersion: "0.2.0 (7)")
        let device = PhoneDevice(deviceID: "D1", name: "iPhone", model: "iPhone18,3", systemVersion: "26.6.1", appVersion: "0.2.0",
                                 alertsAuthorized: true, timeSensitiveAllowed: false, lastSeenAt: t0)
        for item in [CloudItem.alert(alert), .command(command), .status(status), .device(device)] {
            let record = CloudRecordCoding.record(for: item)
            #expect(record.recordType == item.id.recordType)
            #expect(record.recordID.recordName == item.id.recordName)
            #expect(record.recordID.zoneID == CKRecordZone.ID.default, "the public database's default zone")
            #expect(record[CloudSchema.Field.schema] as? NSNumber == 1)
            #expect(CloudRecordCoding.item(from: record) == item)
        }
    }

    @Test func absentOptionalsAreWrittenAsSentinels() throws {
        // Every record writes every field: a CloudKit save keeps the server value of a key it does not carry.
        var bare = alert
        bare.replaceKey = nil
        bare.actions = []
        let record = CloudRecordCoding.record(for: .alert(bare))
        #expect(record[CloudSchema.Field.replaceKey] as? String == "")
        #expect(record[CloudSchema.Field.actions] as? [String] == [""], "an empty list still has a type")
        #expect(record.allKeys().count == 13)
        #expect(CloudRecordCoding.item(from: record) == .alert(bare))

        let status = MacStatus(macID: "m", macName: "Mac", phase: .idle, headline: "Idle", updatedAt: t0, appVersion: "1")
        let statusRecord = CloudRecordCoding.record(for: .status(status))
        #expect(statusRecord.allKeys().count == 19)
        for key in [CloudSchema.Field.countdownEndsAt, CloudSchema.Field.keepAwakeUntil, CloudSchema.Field.batteryPercent] {
            #expect(statusRecord[key] as? NSNumber == NSNumber(value: Int64.min), "\(key)")
        }
        #expect(statusRecord[CloudSchema.Field.detail] as? String == "" && statusRecord[CloudSchema.Field.model] as? String == "")
        #expect(CloudRecordCoding.item(from: statusRecord) == .status(status))

        let command = CloudCommand(id: "C", macID: "m", request: .keepAwake(seconds: 60), stateVersion: nil, issuedAt: t0,
                                   expiresAt: t0.addingTimeInterval(60), deviceID: "d", deviceName: "iPhone")
        let commandRecord = CloudRecordCoding.record(for: .command(command))
        #expect(commandRecord.allKeys().count == 9)
        #expect(CloudRecordCoding.item(from: commandRecord) == .command(command))
        let device = PhoneDevice(deviceID: "D", name: "iPhone", model: "m", systemVersion: "26", appVersion: "1",
                                 alertsAuthorized: false, lastSeenAt: t0)
        #expect(CloudRecordCoding.record(for: .device(device)).allKeys().count == 9)
        #expect(CloudRecordCoding.item(from: CloudRecordCoding.record(for: .device(device))) == .device(device))
    }

    @Test func sentinelsInAPushPayloadReadAsAbsent() {
        let fields: [String: Any] = [
            "macID": "m", "title": "t", "createdAt": NSNumber(value: 1_800_000_000), "expiresAt": NSNumber(value: 1_800_000_060),
            "replaceKey": "", "actions": [""] as NSArray, "sv": NSNumber(value: 3),
        ]
        let decoded = CloudRecordCoding.alert(pushFields: fields, recordName: "alert-X")
        #expect(decoded?.replaceKey == nil && decoded?.actions.isEmpty == true)
        var missingDate = fields
        missingDate["expiresAt"] = NSNumber(value: Int64.min)
        #expect(CloudRecordCoding.alert(pushFields: missingDate, recordName: "alert-X") == nil, "a required field may not be absent")
    }

    @Test func timestampsAreWholeSeconds() {
        var a = alert
        a.createdAt = t0.addingTimeInterval(0.9)
        let record = CloudRecordCoding.record(for: .alert(a))
        #expect(record[CloudSchema.Field.createdAt] as? NSNumber == NSNumber(value: Int64(1_800_000_000)))
    }

    @Test func rejectsNewerSchemaOtherZonesAndMalformedRecords() {
        let newer = CloudRecordCoding.record(for: .alert(alert))
        newer[CloudSchema.Field.schema] = NSNumber(value: 2)
        #expect(CloudRecordCoding.item(from: newer) == nil)

        let otherZone = CKRecord(recordType: "Alert", recordID: CKRecord.ID(recordName: "alert-A1", zoneID: CKRecordZone.ID(zoneName: "Other")))
        #expect(CloudRecordCoding.item(from: otherZone) == nil)

        let missingTitle = CloudRecordCoding.record(for: .alert(alert))
        missingTitle[CloudSchema.Field.title] = nil
        #expect(CloudRecordCoding.item(from: missingTitle) == nil)

        let badName = CKRecord(recordType: "Alert", recordID: CloudRecordCoding.recordID(CloudItemID(recordType: "Alert", recordName: "nope")))
        #expect(CloudRecordCoding.item(from: badName) == nil)

        let unknownType = CKRecord(recordType: "Secret", recordID: CloudRecordCoding.recordID(CloudItemID(recordType: "Secret", recordName: "x")))
        #expect(CloudRecordCoding.item(from: unknownType) == nil)

        let badRequest = CloudRecordCoding.record(for: .command(CloudCommand(
            id: "C", macID: "m", request: .sendTest, stateVersion: nil, issuedAt: t0, expiresAt: t0.addingTimeInterval(60),
            deviceID: "d", deviceName: "iPhone")))
        badRequest[CloudSchema.Field.request] = "format-disk" as NSString
        #expect(CloudRecordCoding.item(from: badRequest) == nil)
    }

    @Test func unknownActionsAreDropped() {
        let record = CloudRecordCoding.record(for: .alert(alert))
        record[CloudSchema.Field.actions] = ["sleep", "reboot", "keepawake:1800"] as NSArray
        guard case .alert(let decoded)? = CloudRecordCoding.item(from: record) else { Issue.record("not an alert"); return }
        #expect(decoded.actions == [.keepAwake(seconds: 1800), .sleepNow])
    }

    @Test func alertFromPushPayload() {
        // CKQueryNotification.recordFields: NSString / NSNumber / NSArray (or Swift bridged values).
        let fields: [String: Any] = [
            "schema": NSNumber(value: 1), "macID": "mac-1" as NSString, "macName": "Studio", "kind": "needsInput",
            "title": "Claude Code needs you", "body": "Permission to run tests", "threadID": "input:claude/1",
            "replaceKey": "input:claude/1", "interruption": "timeSensitive", "actions": ["keepawake:3600", "sleep"] as NSArray,
            "sv": NSNumber(value: 7), "createdAt": NSNumber(value: 1_800_000_000), "expiresAt": Date(timeIntervalSince1970: 1_800_007_200),
        ]
        let decoded = CloudRecordCoding.alert(pushFields: fields, recordName: "alert-XYZ")
        #expect(decoded?.id == "XYZ")
        #expect(decoded?.interruption == .timeSensitive)
        #expect(decoded?.actions == [.keepAwake(seconds: 3600), .sleepNow])
        #expect(decoded?.stateVersion == 7)
        #expect(decoded?.expiresAt == Date(timeIntervalSince1970: 1_800_007_200))
        #expect(CloudRecordCoding.alert(pushFields: fields.filter { $0.key != "title" }, recordName: "alert-XYZ") == nil)
        #expect(CloudRecordCoding.alert(pushFields: fields, recordName: "command-XYZ") == nil)
    }

    @Test func agentsJSONTolerance() {
        #expect(CloudRecordCoding.decodeAgents(nil).isEmpty)
        #expect(CloudRecordCoding.decodeAgents("not json").isEmpty)
        let agents = [AgentSummary(agent: "Aider", activity: .stalled, since: t0)]
        #expect(CloudRecordCoding.decodeAgents(CloudRecordCoding.encodeAgents(agents)) == agents)
    }

    @Test func errorMapping() {
        func ck(_ code: CKError.Code, retry: Double? = nil) -> CKError {
            CKError(code, userInfo: retry.map { [CKErrorRetryAfterKey: NSNumber(value: $0)] } ?? [:])
        }
        #expect(CloudKitStore.map(ck(.notAuthenticated)) == .notSignedIn)
        #expect(CloudKitStore.map(ck(.networkUnavailable)) == .network(retryAfter: nil))
        #expect(CloudKitStore.map(ck(.serviceUnavailable, retry: 30)) == .network(retryAfter: 30))
        #expect(CloudKitStore.map(ck(.requestRateLimited, retry: 12)) == .rateLimited(retryAfter: 12))
        #expect(CloudKitStore.map(ck(.zoneNotFound)) == .zoneMissing)
        #expect(CloudKitStore.map(ck(.userDeletedZone)) == .zoneMissing)
        #expect(CloudKitStore.map(ck(.changeTokenExpired)) == .changeTokenExpired)
        #expect(CloudKitStore.map(ck(.quotaExceeded)) == .quotaExceeded)
        #expect(CloudKitStore.map(ck(.quotaExceeded, retry: 332)) == .quotaExceeded, "storage full, whatever the retry hint")
        #expect(CloudKitStore.map(ck(.unknownItem), savingSubscription: true) == .unknownRecordType)
        #expect(CloudKitStore.map(ck(.unknownItem)) != .unknownRecordType)
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: ["x": ck(.quotaExceeded)]])
        #expect(CloudKitStore.map(partial) == .quotaExceeded)
        #expect(CloudKitStore.map(CocoaError(.fileNoSuchFile)).isRetryable == false)
        #expect(CloudKitStore.map(CancellationError()) == .network(retryAfter: nil), "cancelled work is still to be done")
        #expect(CloudKitStore.map(ck(.operationCancelled)) == .network(retryAfter: nil))
        #expect(CloudError.network(retryAfter: 5).isRetryable && CloudError.rateLimited(retryAfter: nil).isRetryable)
        #expect(!CloudError.zoneMissing.isRetryable)
    }

    @Test func testProcessHasNoContainerEntitlement() {
        // The unit-test runner is unsigned for iCloud: the live store must refuse to exist (CKContainer would crash).
        #expect(!CloudKitStore.hasContainerEntitlement())
        #expect(CloudKitStore.makeIfEntitled() == nil)
    }
}

@Suite("Public database store (pure parts)")
struct PublicStoreTests {
    let owner = "_5d5a50ac768a601d3905c307d54135da"

    @Test func queriesFilterOnTheOwnerAndTheWatermark() {
        #expect(CloudKitStore.predicate(owner: owner, modifiedAfter: nil).predicateFormat == "owner == \"\(owner)\"")
        let after = Date(timeIntervalSince1970: 1_800_000_000)
        let format = CloudKitStore.predicate(owner: owner, modifiedAfter: after).predicateFormat
        #expect(format.hasPrefix("owner == \"\(owner)\" AND modificationDate > CAST("))
    }

    @Test func watermarksRoundTripAndRejectGarbage() {
        let date = Date(timeIntervalSince1970: 1_800_000_123.5)
        #expect(CloudKitStore.watermark(of: CloudKitStore.token(for: date)) == date)
        #expect(CloudKitStore.watermark(of: CloudChangeToken(data: Data("seq:4".utf8))) == nil, "an old private-database token")
        #expect(CloudKitStore.watermarkOverlap >= 60, "covers the public database's indexing delay")
    }

    @Test func subscriptionsAreLimitedToTheOwnersRecords() throws {
        let alerts = CloudKitStore.subscriptions(for: .alerts, owner: owner)
        let alert = try #require(alerts.first as? CKQuerySubscription)
        #expect(alerts.count == 1 && alert.subscriptionID == "alerts-v1" && alert.recordType == "Alert")
        #expect(alert.predicate.predicateFormat == "owner == \"\(owner)\"")
        #expect(alert.querySubscriptionOptions == [.firesOnRecordCreation])
        #expect(alert.notificationInfo?.shouldSendMutableContent == true)
        #expect(alert.notificationInfo?.desiredKeys == nil, "the extension fetches the alert by id")

        let mac = CloudKitStore.subscriptions(for: .macInbox, owner: owner).compactMap { $0 as? CKQuerySubscription }
        #expect(mac.map(\.subscriptionID) == ["mac-commands-v1", "mac-devices-v1"])
        #expect(mac.map(\.recordType) == ["Command", "PhoneDevice"])
        #expect(mac.allSatisfy { $0.notificationInfo?.shouldSendContentAvailable == true && $0.predicate.predicateFormat.contains(owner) })
        // Deletions push too: a removed iPhone leaves the Mac's list right away.
        #expect(mac[1].querySubscriptionOptions == [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion])

        let phone = CloudKitStore.subscriptions(for: .phoneInbox, owner: owner).compactMap { $0 as? CKQuerySubscription }
        #expect(phone.map(\.recordType) == ["MacStatus"] && phone.first?.notificationInfo?.shouldSendContentAvailable == true)
        #expect(phone.first?.querySubscriptionOptions == [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion])
    }

    /// Mac and iPhone records carry the account's tag in their names (another account's old record can never block
    /// a save); alerts and commands (random ids) don't.
    @Test func longLivedRecordNamesAreScopedToTheAccount() {
        let mac = CloudItemID(recordType: CloudSchema.RecordType.macStatus, recordName: "mac-M1")
        let a = CloudKitStore.recordID(mac, owner: "_ownerA").recordName
        let b = CloudKitStore.recordID(mac, owner: "_ownerB").recordName
        #expect(a.hasPrefix("mac-M1-") && b.hasPrefix("mac-M1-") && a != b)
        #expect(CloudKitStore.recordID(mac, owner: "_ownerA").recordName == a, "stable")
        #expect(CloudKitStore.recordID(.alert("x"), owner: "_ownerA").recordName == CloudItemID.alert("x").recordName)
        #expect(CloudKitStore.tag(of: "_ownerA").count == 12)
        #expect(CloudKitStore.chunks(Array(0..<450)).map(\.count) == [200, 200, 50])
    }

    @Test func recordsOfOthersAreNeverTrusted() {
        let record = CKRecord(recordType: "Command", recordID: CKRecord.ID(recordName: "command-x"))
        #expect(!CloudKitStore.isTrusted(record, owner: owner), "no owner, no server-set creator")
        record[CloudSchema.Field.owner] = owner as NSString
        #expect(!CloudKitStore.isTrusted(record, owner: owner), "a matching owner field alone is not enough")
        record[CloudSchema.Field.owner] = "_someoneElse" as NSString
        #expect(!CloudKitStore.isTrusted(record, owner: owner))
    }
}
