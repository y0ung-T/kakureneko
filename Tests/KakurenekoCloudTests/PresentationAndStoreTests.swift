import CloudKit
import Foundation
import Synchronization
import Testing
import UserNotifications
@testable import KakurenekoCloud

@Suite("Alert presentation")
struct AlertPresentationTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func alert(actions: [CloudAction], interruption: AlertInterruption = .active, replaceKey: String? = nil) -> CloudAlert {
        CloudAlert(id: "A1", macID: "mac-1", macName: "Studio", kind: "countdown", title: "Title", body: "Body", threadID: "countdown",
                   replaceKey: replaceKey, interruption: interruption, actions: actions, stateVersion: 9, createdAt: t0,
                   expiresAt: t0.addingTimeInterval(300))
    }

    @Test func categoryIDsAreOrderIndependent() {
        #expect(AlertPresentation.categoryID(for: [CloudAction]()) == "com.kakureneko.alert")
        #expect(AlertPresentation.categoryID(for: [.sleepNow, .keepAwake(seconds: 60)]) == "com.kakureneko.alert.keepawake+sleep")
        #expect(AlertPresentation.categoryID(for: [.shutDown, .sleepNow, .keepAwake(seconds: 1)]) == "com.kakureneko.alert.keepawake+sleep+shutdown")
    }

    @Test func everyButtonCombinationHasACategory() {
        let categories = AlertPresentation.categories(keepAwakeSeconds: 1800)
        #expect(categories.count == 8)
        let ids = Set(categories.map(\.identifier))
        let kinds = CloudActionKind.allCases
        for mask in 0..<(1 << kinds.count) {
            let subset = kinds.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            #expect(ids.contains(AlertPresentation.categoryID(for: subset)))
        }
        let full = categories.first { $0.identifier == "com.kakureneko.alert.keepawake+sleep+shutdown" }
        #expect(full?.actions.map(\.identifier) == [NotificationIDs.Action.keepAwake, NotificationIDs.Action.sleepNow, NotificationIDs.Action.shutDown])
        #expect(full?.actions.first?.title == "Keep awake 30m")
        #expect(full?.actions[1].options.contains(.destructive) == true)
        #expect(full?.actions[1].options.contains(.authenticationRequired) == true)
        #expect(full?.actions[0].options.isEmpty == true, "keep awake runs in the background without unlocking")
    }

    @Test func contentCarriesEverything() {
        let content = AlertPresentation.content(for: alert(actions: [.keepAwake(seconds: 3600), .sleepNow], interruption: .timeSensitive,
                                                           replaceKey: "countdown"), now: t0, showMacName: true)
        #expect(content.title == "Title" && content.body == "Body" && content.subtitle == "Studio")
        #expect(content.categoryIdentifier == "com.kakureneko.alert.keepawake+sleep")
        #expect(content.threadIdentifier == "com.kakureneko.countdown")
        #expect(content.interruptionLevel == .timeSensitive)
        #expect(content.sound != nil)
        #expect(content.userInfo[NotificationIDs.UserInfo.stateVersion] as? Int == 9)
        #expect(content.userInfo[NotificationIDs.UserInfo.keepAwakeSeconds] as? Int == 3600)
        #expect(content.userInfo[NotificationIDs.UserInfo.replaceKey] as? String == "countdown")
        #expect(content.userInfo[NotificationIDs.UserInfo.expiresAt] as? Int == 1_800_000_300)
    }

    @Test func expiredOrPassiveAlerts() {
        let late = AlertPresentation.content(for: alert(actions: [.sleepNow]), now: t0.addingTimeInterval(301), showMacName: false)
        #expect(late.categoryIdentifier == NotificationIDs.plainCategory, "no buttons once expired")
        #expect(late.subtitle.isEmpty)
        let passive = AlertPresentation.content(for: alert(actions: [], interruption: .passive), now: t0, showMacName: false)
        #expect(passive.interruptionLevel == .passive && passive.sound == nil)
    }

    @Test func requestIdentifiers() {
        #expect(AlertPresentation.requestIdentifier(for: alert(actions: [], replaceKey: "countdown")) == "com.kakureneko.replace.countdown")
        #expect(AlertPresentation.requestIdentifier(for: alert(actions: [])) == "alert-A1")
    }

    @Test func buttonTapsDecode() {
        let info = AlertPresentation.userInfo(for: alert(actions: [.keepAwake(seconds: 5400), .sleepNow, .shutDown])) as [AnyHashable: Any]
        let keep = AlertPresentation.buttonTap(actionIdentifier: NotificationIDs.Action.keepAwake, userInfo: info)
        #expect(keep?.request == .keepAwake(seconds: 5400))
        #expect(keep?.macID == "mac-1" && keep?.alertID == "A1" && keep?.stateVersion == 9)
        #expect(keep?.expiresAt == t0.addingTimeInterval(300))
        #expect(AlertPresentation.buttonTap(actionIdentifier: NotificationIDs.Action.sleepNow, userInfo: info)?.request == .sleepNow)
        #expect(AlertPresentation.buttonTap(actionIdentifier: NotificationIDs.Action.shutDown, userInfo: info)?.request == .shutDown)
        #expect(AlertPresentation.buttonTap(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: info) == nil)
        #expect(AlertPresentation.buttonTap(actionIdentifier: NotificationIDs.Action.sleepNow, userInfo: [:]) == nil, "not ours")
        var noDuration = info
        noDuration[NotificationIDs.UserInfo.keepAwakeSeconds] = nil
        #expect(AlertPresentation.buttonTap(actionIdentifier: NotificationIDs.Action.keepAwake, userInfo: noDuration)?.request
                == .keepAwake(seconds: 3600))
    }
}

@Suite("In-memory store")
struct InMemoryCloudStoreTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func alert(_ id: String) -> CloudItem {
        .alert(CloudAlert(id: id, macID: "m", macName: "Mac", kind: "finished", title: id, body: "", threadID: "t",
                          createdAt: t0, expiresAt: t0.addingTimeInterval(60)))
    }

    @Test func zoneMustExist() async throws {
        let store = InMemoryCloudStore()
        await #expect(throws: CloudError.zoneMissing) { try await store.save([alert("a")]) }
        try await store.prepare()
        try await store.save([alert("a")])
        #expect(await store.allItems == [alert("a")])
    }

    @Test func changesSinceTokenAndDeletions() async throws {
        let store = InMemoryCloudStore(zoneExists: true)
        await store.setReportsDeletions(true) // the opt-in; the public database never reports them
        try await store.save([alert("a"), alert("b")])
        let first = try await store.fetchChanges(since: nil)
        #expect(Set(first.items.map(\.id)) == [alert("a").id, alert("b").id])
        try await store.save([alert("c")])
        try await store.delete([alert("a").id, CloudItemID.alert("never-existed")])
        let second = try await store.fetchChanges(since: first.token)
        #expect(second.items == [alert("c")])
        #expect(second.deleted == [alert("a").id])
        let third = try await store.fetchChanges(since: second.token)
        #expect(third.items.isEmpty && third.deleted.isEmpty && !third.moreComing)
        #expect(third.token == second.token)
    }

    @Test func pagingAndFetchAll() async throws {
        let store = InMemoryCloudStore(zoneExists: true, pageSize: 2)
        try await store.save((0..<5).map { alert("\($0)") })
        let page = try await store.fetchChanges(since: nil)
        #expect(page.items.count == 2 && page.moreComing)
        let all = try await store.fetchAllChanges(since: nil)
        #expect(all.items.count == 5 && !all.moreComing)
    }

    @Test func injectedFailuresAndAccount() async throws {
        let store = InMemoryCloudStore(zoneExists: true)
        await store.failNext(.save, with: .network(retryAfter: 3), .quotaExceeded)
        await #expect(throws: CloudError.network(retryAfter: 3)) { try await store.save([alert("a")]) }
        await #expect(throws: CloudError.quotaExceeded) { try await store.save([alert("a")]) }
        try await store.save([alert("a")])
        await store.setAccount(.noAccount)
        #expect(await store.accountStatus() == .noAccount)
        await #expect(throws: CloudError.notSignedIn) { try await store.fetchChanges(since: nil) }
    }

    @Test func zoneDeletionInvalidatesTokens() async throws {
        let store = InMemoryCloudStore(zoneExists: true)
        try await store.save([alert("a"), alert("b")])
        let token = try await store.fetchChanges(since: nil).token
        await store.deleteZone()
        await #expect(throws: CloudError.zoneMissing) { try await store.fetchChanges(since: token) }
        try await store.prepare()
        try await store.save([alert("c")])
        let after = try await store.fetchChanges(since: nil)
        #expect(after.items == [alert("c")])
    }

    @Test func savesMergeLikeCloudKitAndSentinelsClearStaleFields() async throws {
        let store = InMemoryCloudStore(zoneExists: true)
        var status = MacStatus(macID: "m", macName: "Mac", phase: .countdown, headline: "Going to sleep soon",
                               countdownEndsAt: t0.addingTimeInterval(300), keepAwakeUntil: t0.addingTimeInterval(60),
                               updatedAt: t0, appVersion: "1")
        try await store.save([.status(status)])
        // The countdown was cancelled: the next save has no countdown and no keep-awake.
        status.phase = .working
        status.countdownEndsAt = nil
        status.keepAwakeUntil = nil
        try await store.save([.status(status)])
        guard case .status(let stored)? = await store.allItems.first else { Issue.record("no status"); return }
        #expect(stored.countdownEndsAt == nil && stored.keepAwakeUntil == nil, "the sentinel overwrote the old value")
        #expect(await store.rawValue(CloudSchema.Field.countdownEndsAt, of: CloudItem.status(status).id) == String(Int64.min))
    }

    @Test func fetchByID() async throws {
        let store = InMemoryCloudStore(zoneExists: true)
        try await store.save([alert("a")])
        #expect(try await store.fetch(alert("a").id) == alert("a"))
        #expect(try await store.fetch(CloudItemID.alert("zzz")) == nil)
    }

    @Test func ensureSubscriptionBootstrapsAFreshSchema() async throws {
        let store = InMemoryCloudStore(zoneExists: true)
        await store.setRequiresSchemaBootstrap(true)
        try await store.ensureSubscription(.alerts, now: t0)
        #expect(await store.subscriptions == [.alerts])
        #expect(await store.allItems.isEmpty, "placeholders are deleted again")
        let changes = try await store.fetchChanges(since: nil)
        #expect(changes.items.isEmpty && changes.deleted.isEmpty, "like the public database: deletions are not reported")
    }

    /// The public database's behaviour, which the apps are built for: change fetches never report deletions, so the
    /// small types are read whole (`fetchAll`) and old records pruned by server age (`deleteOwned`).
    @Test func deletionsShowOnlyInWholeReadsAndPruneByAge() async throws {
        let clock = Mutex(t0)
        let store = InMemoryCloudStore(zoneExists: true, now: { clock.withLock { $0 } })
        let old = CloudItem.device(PhoneDevice(deviceID: "old", name: "iPhone", model: "iPhone18,3", systemVersion: "26", appVersion: "1",
                                               alertsAuthorized: true, timeSensitiveAllowed: nil, lastSeenAt: t0))
        try await store.save([old, alert("a")])
        let first = try await store.fetchChanges(since: nil, types: [CloudSchema.RecordType.phoneDevice])
        #expect(first.items == [old], "only the asked types")
        try await store.delete([old.id])
        #expect(try await store.fetchChanges(since: first.token, types: [CloudSchema.RecordType.phoneDevice]).deleted.isEmpty)
        #expect(try await store.fetchAll(CloudSchema.RecordType.phoneDevice).isEmpty, "a whole read shows it is gone")
        clock.withLock { $0 = $0.addingTimeInterval(3600) }
        try await store.save([alert("b")])
        let pruned = try await store.deleteOwned(CloudSchema.RecordType.alert, modifiedBefore: clock.withLock { $0 }.addingTimeInterval(-60))
        let left = await store.allItems
        #expect(pruned == 1 && left == [alert("b")])
    }

    @Test func placeholdersSetEveryOptionalField() throws {
        for item in CloudSchemaBootstrap.placeholders(now: t0) {
            #expect(CloudSchemaBootstrap.isPlaceholder(item))
            let record = CloudRecordCoding.record(for: item)
            let expected: Int = switch item {
            case .alert: 13
            case .command: 9
            case .status: 19
            case .device: 9
            }
            #expect(record.allKeys().count == expected, "\(item.id.recordType): \(record.allKeys().sorted())")
        }
        #expect(!CloudSchemaBootstrap.isPlaceholder(alert("real")))
    }

    @Test func subscriptionsAreRecorded() async throws {
        let store = InMemoryCloudStore(zoneExists: true)
        try await store.saveSubscription(.alerts)
        try await store.saveSubscription(.macInbox)
        try await store.saveSubscription(.alerts)
        #expect(await store.subscriptions == [.alerts, .macInbox])
    }
}
