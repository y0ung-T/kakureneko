// Test support for KakurenekoPhoneTests: a hand-advanced clock, a harness that builds `PhoneStore`s on an
// `InMemoryCloudStore` with a throwaway cache directory and defaults suite (so "relaunching" is just building a
// second store on the same harness), and record fixtures. Never touches CloudKit.

import KakurenekoCloud
import Foundation
import Synchronization

/// A clock tests move by hand.
final class ManualClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date = Fixture.t0) {
        current = Mutex(start)
    }

    var now: Date { current.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    var phoneClock: PhoneClock {
        PhoneClock(now: { [self] in now })
    }
}

/// One simulated install of the app: cloud, clock, cache directory, defaults and notification center.
@MainActor
final class Harness {
    let cloud: InMemoryCloudStore
    let clock = ManualClock()
    let notifications: RecordingNotificationCenter
    let device = DeviceInfo(name: "iPhone", model: "iPhone18,3", systemVersion: "26.0", appVersion: "0.1.0 (1)")
    let defaults: UserDefaults
    private let directory: URL
    private let suiteName: String

    /// `cloud` nil: an empty store on this harness's clock (its modification times drive the prune).
    init(cloud: InMemoryCloudStore? = nil,
         authorization: NotificationAuthorization = NotificationAuthorization(status: .authorized, timeSensitive: true)) {
        let clock = self.clock
        self.cloud = cloud ?? InMemoryCloudStore(zoneExists: true, now: { clock.now })
        notifications = RecordingNotificationCenter(current: authorization)
        suiteName = "KakurenekoPhoneTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        directory = FileManager.default.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    /// A store as a fresh process would create it (reads the same cache and defaults as earlier stores).
    func makeStore() -> PhoneStore {
        PhoneStore(cloud: cloud, clock: clock.phoneClock, cacheFile: PhoneCacheFile(directory: directory), defaults: defaults,
                   device: device, notifications: notifications)
    }

    /// The Mac side: saves records into the zone.
    func macSaves(_ items: CloudItem...) async throws {
        try await cloud.save(items)
    }

    /// Every `Command` in the zone.
    func commands() async -> [CloudCommand] {
        await cloud.items(ofType: CloudSchema.RecordType.command).compactMap {
            if case .command(let command) = $0 { command } else { nil }
        }
    }

    /// This phone's `PhoneDevice` record, if saved.
    func deviceRecord() async -> PhoneDevice? {
        await cloud.items(ofType: CloudSchema.RecordType.phoneDevice).compactMap {
            if case .device(let device) = $0 { device } else { nil }
        }.first
    }
}

enum Fixture {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func status(_ macID: String = "mac-1", name: String = "Studio", phase: MacPhase = .working, sv: Int = 1,
                       updatedAt: Date, keepAwakeSeconds: Int = 3600, canSleep: Bool = true, shutdownEnabled: Bool = false,
                       keepAwakeUntil: Date? = nil, countdownEndsAt: Date? = nil, batteryPercent: Int? = 80,
                       onBattery: Bool = true) -> MacStatus {
        MacStatus(macID: macID, macName: name, model: "MacBook Pro", phase: phase, headline: "2 agents working",
                  countdownEndsAt: countdownEndsAt, keepAwakeUntil: keepAwakeUntil,
                  agents: [AgentSummary(agent: "Claude Code", project: "kakureneko", host: "Terminal", activity: .working, since: updatedAt)],
                  batteryPercent: batteryPercent, onBattery: onBattery, lidClosed: true, stateVersion: sv,
                  keepAwakeSeconds: keepAwakeSeconds, shutdownEnabled: shutdownEnabled, canSleep: canSleep, updatedAt: updatedAt,
                  appVersion: "0.2.0 (7)")
    }

    static func alert(_ id: String, macID: String = "mac-1", macName: String = "Studio", kind: String = "finished",
                      title: String = "Claude Code finished", body: String = "kakureneko · 12 min", createdAt: Date,
                      expiresIn: TimeInterval = 600, actions: [CloudAction] = [], sv: Int = 1) -> CloudAlert {
        CloudAlert(id: id, macID: macID, macName: macName, kind: kind, title: title, body: body, threadID: kind,
                   actions: actions, stateVersion: sv, createdAt: createdAt, expiresAt: createdAt.addingTimeInterval(expiresIn))
    }
}
