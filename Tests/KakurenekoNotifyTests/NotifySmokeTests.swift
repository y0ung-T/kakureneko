import KakurenekoCloud
import KakurenekoKit
import KakurenekoNotify
import Foundation
import Testing

@Suite("KakurenekoNotify smoke", .timeLimit(.minutes(1)))
struct NotifySmokeTests {
    /// In-memory iCloud and recording Mac notifications only: tests never touch CloudKit or UserNotifications.
    @Test func dispatcherConformsToContract() async throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let dispatcher: any NotificationDispatching = NotificationDispatcher(
            paths: paths, settings: NotificationSettings(), localNotifications: RecordingLocalNotifications(),
            cloud: InMemoryCloudStore(), clock: TestClock())
        _ = await dispatcher.status()
        _ = dispatcher.remoteCommands()
        await dispatcher.stop()
    }

    /// The live poster refuses to exist outside an app bundle (`UNUserNotificationCenter` would trap).
    @Test func livePosterNeedsAnAppBundle() {
        #expect(UserNotificationCenterPoster.makeIfAvailable() == nil)
    }

    @Test func identityIsReadFromThisMac() {
        let identity = MacIdentity.current()
        #expect(!identity.name.isEmpty)
        #expect(identity.model?.isEmpty == false)
    }
}
