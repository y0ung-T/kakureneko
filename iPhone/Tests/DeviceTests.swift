// This iPhone: the PhoneDevice record (launch, permission changes, 6-hour throttle), the device id (kept across
// reinstalls),
// notification permission, notification categories and foreground-only polling.

import KakurenekoCloud
import Foundation
import Testing
import UserNotifications

/// A Keychain stand-in: it outlives the `UserDefaults` it's paired with, like the real one outlives the app.
final class MemoryDeviceID: DeviceIDStoring, @unchecked Sendable {
    var value: String?
    var locked = false
    init(_ value: String? = nil) { self.value = value }
    func load() -> DeviceIDLookup { locked ? .unavailable : value.map { .found($0) } ?? .missing }
    func save(_ id: String) { if !locked { value = id } }
}

@MainActor
@Suite("This iPhone")
struct DeviceTests {
    private func freshDefaults() -> UserDefaults {
        let name = "kakureneko.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aReinstallKeepsTheDeviceID() {
        let keychain = MemoryDeviceID()
        let first = PhonePreferences(defaults: freshDefaults(), persistentID: keychain).deviceID()
        #expect(keychain.value == first, "kept in the Keychain")
        // Deleting the app wipes its defaults, not the Keychain: the same iPhone, the same record.
        let afterReinstall = PhonePreferences(defaults: freshDefaults(), persistentID: keychain).deviceID()
        #expect(afterReinstall == first)
    }

    @Test func aNewIPhoneRestoredFromABackupGetsItsOwnID() {
        // The backup carries UserDefaults, not this-device-only Keychain items.
        let defaults = freshDefaults()
        let oldPhone = PhonePreferences(defaults: defaults).deviceID()
        let newPhone = PhonePreferences(defaults: defaults, persistentID: MemoryDeviceID())
        let id = newPhone.deviceID()
        #expect(id != oldPhone, "two phones never share one record")
        #expect(newPhone.supersededDeviceID == oldPhone, "the old id's record is removed from iCloud")
        // The Keychain wins when the two disagree.
        #expect(PhonePreferences(defaults: defaults, persistentID: MemoryDeviceID("K")).deviceID() == "K")
    }

    @Test func aLockedKeychainNeverMakesANewID() {
        let defaults = freshDefaults()
        let keychain = MemoryDeviceID()
        let id = PhonePreferences(defaults: defaults, persistentID: keychain).deviceID()
        keychain.locked = true
        let preferences = PhonePreferences(defaults: defaults, persistentID: keychain)
        #expect(preferences.deviceID() == id, "a background launch before the first unlock keeps the id")
        #expect(preferences.supersededDeviceID == nil)
    }

    @Test func theDeviceRecordIsSavedOnLaunch() async throws {
        let h = Harness()
        let store = h.makeStore()
        await store.sceneDidBecomeActive()
        store.sceneDidEnterBackground()

        let record = try #require(await h.deviceRecord())
        #expect(record.deviceID == store.deviceID)
        #expect(record.name == "iPhone")
        #expect(record.model == "iPhone18,3")
        #expect(record.systemVersion == "26.0")
        #expect(record.appVersion == "0.1.0 (1)")
        #expect(record.alertsAuthorized)
        #expect(record.timeSensitiveAllowed == true)
        #expect(record.lastSeenAt == h.clock.now)
    }

    @Test func theDeviceRecordIsThrottledUnlessPermissionChanges() async throws {
        let h = Harness()
        let store = h.makeStore()
        await store.sceneDidBecomeActive()
        let launch = h.clock.now

        h.clock.advance(3600)
        await store.sceneDidBecomeActive()
        #expect(await h.deviceRecord()?.lastSeenAt == launch, "within 6 h: not saved again")

        h.notifications.current = NotificationAuthorization(status: .denied, timeSensitive: nil)
        await store.sceneDidBecomeActive()
        var record = try #require(await h.deviceRecord())
        #expect(record.lastSeenAt == h.clock.now, "a permission change is saved at once")
        #expect(!record.alertsAuthorized)
        #expect(record.timeSensitiveAllowed == nil)

        let changed = h.clock.now
        h.clock.advance(DeviceRecordPolicy.interval - 1)
        await store.saveDeviceRecordIfNeeded()
        #expect(await h.deviceRecord()?.lastSeenAt == changed)
        h.clock.advance(1)
        await store.saveDeviceRecordIfNeeded()
        record = try #require(await h.deviceRecord())
        #expect(record.lastSeenAt == h.clock.now, "every 6 h at most")
        store.sceneDidEnterBackground()

        let relaunched = h.makeStore()
        h.clock.advance(60)
        await relaunched.sceneDidBecomeActive()
        relaunched.sceneDidEnterBackground()
        #expect(await h.deviceRecord()?.lastSeenAt == h.clock.now, "every launch saves it")
    }

    @Test func theDeviceIDIsStablePerInstall() {
        let h = Harness()
        let first = h.makeStore().deviceID
        #expect(h.makeStore().deviceID == first)
        #expect(Harness().makeStore().deviceID != first)
        #expect(UUID(uuidString: first) != nil)
    }

    @Test func notificationPermissionIsOnlyRequestedWhenAsked() async throws {
        let h = Harness(authorization: NotificationAuthorization(status: .notDetermined, timeSensitive: nil))
        let store = h.makeStore()
        await store.sceneDidBecomeActive()
        store.sceneDidEnterBackground()
        #expect(h.notifications.requestCount == 0, "never before onboarding explains it")
        #expect(store.notificationAuthorization?.status == .notDetermined)
        #expect(await h.deviceRecord()?.alertsAuthorized == false)

        await store.requestNotificationAuthorization()
        #expect(h.notifications.requestCount == 1)
        #expect(store.notificationAuthorization?.alertsAllowed == true)
        #expect(await h.deviceRecord()?.alertsAuthorized == true, "the Mac learns about it right away")
    }

    @Test func categoriesFollowTheKeepAwakeDuration() async throws {
        let h = Harness()
        let store = h.makeStore()
        await store.start()
        #expect(h.notifications.registeredCategories.count == 1)
        #expect(keepAwakeTitle(h.notifications.registeredCategories.last) == "Keep awake 1h")
        #expect(h.notifications.registeredCategories.last?.count == 8, "every button combination")

        try await h.macSaves(.status(Fixture.status(updatedAt: h.clock.now, keepAwakeSeconds: 1800)))
        await store.sync()
        #expect(h.notifications.registeredCategories.count == 2)
        #expect(keepAwakeTitle(h.notifications.registeredCategories.last) == "Keep awake 30m")

        try await h.macSaves(.status(Fixture.status(sv: 2, updatedAt: h.clock.now.addingTimeInterval(5), keepAwakeSeconds: 1800)))
        await store.sync()
        #expect(h.notifications.registeredCategories.count == 2, "same duration: not registered again")
    }

    func keepAwakeTitle(_ categories: Set<UNNotificationCategory>?) -> String? {
        categories?.first { $0.identifier == AlertPresentation.categoryID(for: [CloudActionKind.keepAwake]) }?.actions.first?.title
    }

    @Test func pollingRunsOnlyInTheForeground() async {
        let h = Harness()
        let store = h.makeStore()
        #expect(!store.isPolling)
        await store.sceneDidBecomeActive()
        #expect(store.isPolling)
        store.sceneDidEnterBackground()
        #expect(!store.isPolling)
    }

    @Test func onboardingIsRemembered() {
        let h = Harness()
        let store = h.makeStore()
        #expect(!store.hasCompletedOnboarding)
        store.completeOnboarding()
        #expect(h.makeStore().hasCompletedOnboarding)
    }
}
