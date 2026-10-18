import Foundation
import Testing
@testable import KakurenekoCloud

@Suite("Models")
struct ModelTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func actionWireValuesRoundTrip() {
        for action in [CloudAction.keepAwake(seconds: 3600), .keepAwake(seconds: 60), .keepAwake(seconds: 86_400), .sleepNow, .shutDown] {
            #expect(CloudAction(wireValue: action.wireValue) == action)
        }
        for bad in ["", "keepawake", "keepawake:", "keepawake:abc", "keepawake:59", "keepawake:86401", "keepawake:60:1", "Sleep", "reboot"] {
            #expect(CloudAction(wireValue: bad) == nil, "\(bad)")
        }
    }

    @Test func actionTitles() {
        #expect(CloudAction.keepAwake(seconds: 3600).title == "Keep awake 1h")
        #expect(CloudAction.keepAwake(seconds: 7200).title == "Keep awake 2h")
        #expect(CloudAction.keepAwake(seconds: 5400).title == "Keep awake 90m")
        #expect(CloudAction.keepAwake(seconds: 60).title == "Keep awake 1m")
        #expect(CloudAction.sleepNow.title == "Sleep now")
        #expect(CloudAction.shutDown.title == "Shut down")
    }

    @Test func requestWireValuesRoundTrip() {
        for request in [CloudRequest.keepAwake(seconds: 1800), .sleepNow, .shutDown, .sendTest, .refreshStatus] {
            #expect(CloudRequest(wireValue: request.wireValue) == request)
        }
        #expect(CloudRequest(wireValue: "pair") == nil)
        #expect(CloudRequest.sleepNow.requiresStateVersion && CloudRequest.shutDown.requiresStateVersion)
        #expect(!CloudRequest.keepAwake(seconds: 60).requiresStateVersion && !CloudRequest.sendTest.requiresStateVersion)
        #expect(CloudAction.keepAwake(seconds: 600).request == .keepAwake(seconds: 600))
    }

    @Test func alertNormalizesActionsAndLengths() {
        let alert = CloudAlert(
            macID: "m", macName: String(repeating: "n", count: 200), kind: "countdown",
            title: String(repeating: "t", count: 500), body: String(repeating: "b", count: 2000), threadID: "countdown",
            actions: [.shutDown, .sleepNow, .keepAwake(seconds: 3600), .sleepNow, .keepAwake(seconds: 60)],
            createdAt: t0, expiresAt: t0.addingTimeInterval(-10))
        #expect(alert.actions == [.keepAwake(seconds: 3600), .sleepNow, .shutDown])
        #expect(alert.title.count == CloudSchema.Limits.titleCharacters)
        #expect(alert.body.count == CloudSchema.Limits.bodyCharacters)
        #expect(alert.macName.count == CloudSchema.Limits.nameCharacters)
        #expect(alert.expiresAt == t0, "never expires before it was created")
        #expect(alert.keepAwakeSeconds == 3600)
        #expect(alert.recordName == "alert-" + alert.id)
        #expect(alert.isExpired(at: t0))
    }

    @Test func commandLifetimeIsCapped() {
        let c = CloudCommand(macID: "m", request: .sleepNow, stateVersion: 3, issuedAt: t0, expiresAt: t0.addingTimeInterval(86_400),
                             deviceID: "d", deviceName: "iPhone")
        #expect(c.expiresAt == t0.addingTimeInterval(CloudSchema.Limits.commandMaximumAge))
    }

    @Test func commandRejections() {
        func command(_ request: CloudRequest, sv: Int? = 1, issued: Date? = nil, expires: TimeInterval = 600, mac: String = "m") -> CloudCommand {
            let issuedAt = issued ?? t0
            return CloudCommand(macID: mac, request: request, stateVersion: sv, issuedAt: issuedAt,
                                expiresAt: issuedAt.addingTimeInterval(expires), deviceID: "d", deviceName: "iPhone")
        }
        #expect(command(.sleepNow).rejection(forMac: "m", now: t0) == nil)
        #expect(command(.sleepNow, mac: "other").rejection(forMac: "m", now: t0) == .otherMac)
        #expect(command(.sleepNow, sv: nil).rejection(forMac: "m", now: t0) == .missingStateVersion)
        #expect(command(.shutDown, sv: nil).rejection(forMac: "m", now: t0) == .missingStateVersion)
        #expect(command(.keepAwake(seconds: 60), sv: nil).rejection(forMac: "m", now: t0) == nil)
        #expect(command(.sleepNow, expires: 60).rejection(forMac: "m", now: t0.addingTimeInterval(61)) == .expired)
        #expect(command(.sleepNow, issued: t0.addingTimeInterval(301)).rejection(forMac: "m", now: t0) == .issuedInFuture)
        #expect(command(.sleepNow, issued: t0.addingTimeInterval(299)).rejection(forMac: "m", now: t0) == nil, "small skew is fine")
        #expect(command(.sendTest, expires: 3600).rejection(forMac: "m", now: t0.addingTimeInterval(1801)) == .tooOld)
    }

    @Test func statusStaleness() {
        var status = MacStatus(macID: "m", macName: "Mac", phase: .working, headline: "1 agent working", updatedAt: t0, appVersion: "1")
        #expect(!status.isStale(at: t0.addingTimeInterval(MacStatus.staleAfter)))
        #expect(status.isStale(at: t0.addingTimeInterval(MacStatus.staleAfter + 1)))
        for phase in [MacPhase.asleep, .shutDown, .off] {
            status.phase = phase
            #expect(!status.isStale(at: t0.addingTimeInterval(86_400)), "\(phase)")
        }
    }

    @Test func statusClampsAndCaps() {
        let agents = (0..<20).map { AgentSummary(agent: "Claude Code", project: "p\($0)", activity: .working) }
        let status = MacStatus(macID: "m", macName: "Mac", phase: .working, headline: String(repeating: "h", count: 300),
                               detail: String(repeating: "d", count: 999), agents: agents, keepAwakeSeconds: 5,
                               updatedAt: t0, appVersion: "1")
        #expect(status.agents.count == CloudSchema.Limits.agentsInStatus)
        #expect(status.headline.count == CloudSchema.Limits.headlineCharacters)
        #expect(status.detail?.count == CloudSchema.Limits.detailCharacters)
        #expect(status.keepAwakeSeconds == 60)
        #expect(status.recordName == "mac-m")
    }

    @Test func itemIDs() {
        let device = PhoneDevice(deviceID: "abc", name: "iPhone", model: "iPhone18,3", systemVersion: "26.6", appVersion: "1",
                                 alertsAuthorized: true, lastSeenAt: t0)
        #expect(CloudItem.device(device).id == CloudItemID(recordType: "PhoneDevice", recordName: "phone-abc"))
        #expect(CloudItemID.alert("x") == CloudItemID(recordType: "Alert", recordName: "alert-x"))
        #expect(CloudItemID.command("y").description == "Command/command-y")
    }

    @Test func containerAndIDsAreStable() {
        // Shipped identifiers: changing any of these orphans users' data or breaks deployed schema.
        #expect(CloudSchema.containerIdentifier == "iCloud.com.kakureneko.Kakureneko")
        #expect(CloudSchema.zoneName == "_defaultZone")
        #expect(CloudSchema.RecordType.all == ["Alert", "Command", "MacStatus", "PhoneDevice"])
        #expect(CloudSchema.Field.owner == "owner")
        #expect(CloudSchema.Field.alertPushKeys.count <= CloudSchema.Field.maximumPushKeys, "CloudKit rejects the subscription otherwise")
        #expect(Set(CloudSchema.Field.alertPushKeys).count == CloudSchema.Field.alertPushKeys.count)
        #expect(CloudSchema.SubscriptionID.alerts == "alerts-v1")
        #expect(CloudSchema.SubscriptionID.silent == ["mac-commands-v1", "mac-devices-v1", "phone-statuses-v1"])
        #expect(CloudSubscription.macInbox.subscriptionIDs == ["mac-commands-v1", "mac-devices-v1"])
        #expect(CloudSubscription.phoneInbox.subscriptionIDs == ["phone-statuses-v1"])
        #expect(NotificationIDs.Action.sleepNow == "com.kakureneko.action.sleep")
    }
}
