// What the iPhone app remembers between launches. Two places, both inside the app's own sandbox:
//   * `PhoneCacheFile` — a JSON file in Application Support: the zone change token, the last known status of every
//     Mac, recent alerts, commands waiting to be sent and setup bookkeeping. Losing it is harmless (the next sync
//     fetches everything again), so an unreadable file simply starts fresh.
//   * `PhonePreferences` — UserDefaults (the privacy manifest's CA92.1 reason): this install's random device id and
//     whether onboarding is done. Kept apart from the cache so a reset cache never changes the device id.
// Tests inject a temporary directory and a throwaway defaults suite.

import KakurenekoCloud
import Foundation

/// The persisted part of `PhoneStore`'s state.
struct PhoneCache: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = PhoneCache.currentVersion
    /// Zone change token of the last applied fetch (nil = fetch everything).
    var changeToken: CloudChangeToken?
    var statuses: [MacStatus] = []
    /// Newest first.
    var alerts: [CloudAlert] = []
    /// Commands not yet saved to iCloud, oldest first.
    var pendingCommands: [CloudCommand] = []
    var deviceRecord: DeviceRecordStamp?
    /// When the zone and both subscriptions were last ensured.
    var setupCompletedAt: Date?
    /// `CloudStore.accountTag()` of the Apple Account all of the above belongs to (nil: not known yet).
    var accountTag: String?
}

/// When, and with which values, this iPhone's `PhoneDevice` record was last saved.
struct DeviceRecordStamp: Codable, Equatable, Sendable {
    var savedAt: Date
    var authorization: NotificationAuthorization
    var device: DeviceInfo
}

/// `PhoneCache` on disk, written atomically. Readable after the first unlock, so a push that launches the app in
/// the background while the phone is locked still finds it.
struct PhoneCacheFile: Sendable {
    let url: URL

    init(directory: URL) {
        url = directory.appending(path: "phone-cache.json", directoryHint: .notDirectory)
    }

    /// The app's own Application Support directory.
    static var live: PhoneCacheFile {
        PhoneCacheFile(directory: URL.applicationSupportDirectory)
    }

    /// The saved cache, or an empty one when there is none, it is unreadable, or it was written by a newer version.
    func load() -> PhoneCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(PhoneCache.self, from: data),
              cache.version <= PhoneCache.currentVersion else { return PhoneCache() }
        return cache
    }

    func save(_ cache: PhoneCache) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(cache)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // Not in backups: a restored iPhone rebuilds it from iCloud instead of showing Macs that may be gone.
        var file = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? file.setResourceValues(values)
    }
}

/// What the Keychain says about this iPhone's id.
enum DeviceIDLookup: Equatable, Sendable {
    case found(String)
    /// Never stored on this device (a first install, or a new iPhone restored from a backup).
    case missing
    /// Can't be read right now (a background launch before the first unlock): never a reason for a new id.
    case unavailable
}

/// Where this iPhone's id survives a reinstall (the Keychain in the app; nothing in tests and the demo).
protocol DeviceIDStoring: Sendable {
    func load() -> DeviceIDLookup
    func save(_ id: String)
}

/// Small settings kept in `UserDefaults`.
struct PhonePreferences {
    private enum Key {
        static let deviceID = "com.kakureneko.deviceID"
        static let onboardingComplete = "com.kakureneko.onboardingComplete"
        static let lastPrunedAt = "com.kakureneko.lastPrunedAt"
        static let supersededDeviceID = "com.kakureneko.supersededDeviceID"
    }

    let defaults: UserDefaults
    /// The Keychain copy of the id: deleting and reinstalling the app keeps it, so the Mac keeps seeing one iPhone
    /// instead of one more per install. nil: `UserDefaults` only.
    var persistentID: (any DeviceIDStoring)?

    /// Random, created once per iPhone (`identifierForVendor` is not used: it changes when every app of the vendor
    /// is removed, and it is not ours to publish to iCloud). Kept in the Keychain (this device only) and mirrored in
    /// `UserDefaults`:
    /// * in the Keychain → that one (a reinstall keeps it);
    /// * not in the Keychain, but in `UserDefaults` → this is a new iPhone restored from another one's backup: a new
    ///   id, and the old id's record is removed from iCloud (`supersededDeviceID`), so the two phones don't share one;
    /// * the Keychain locked (before the first unlock) → the `UserDefaults` copy, nothing new created.
    func deviceID() -> String {
        let local = defaults.string(forKey: Key.deviceID).flatMap { $0.isEmpty ? nil : $0 }
        guard let persistentID else { return local ?? created() }
        switch persistentID.load() {
        case .found(let id) where !id.isEmpty:
            if local != id { defaults.set(id, forKey: Key.deviceID) }
            return id
        case .found, .missing:
            let id = UUID().uuidString
            persistentID.save(id)
            defaults.set(id, forKey: Key.deviceID)
            if let local, local != id { supersededDeviceID = local }
            return id
        case .unavailable:
            return local ?? created()
        }
    }

    private func created() -> String {
        let id = UUID().uuidString
        defaults.set(id, forKey: Key.deviceID)
        return id
    }

    /// A previous id of this iPhone (or of the one whose backup it came from) whose iCloud record is still to remove.
    var supersededDeviceID: String? {
        get { defaults.string(forKey: Key.supersededDeviceID) }
        nonmutating set { defaults.set(newValue, forKey: Key.supersededDeviceID) }
    }

    /// When old records were last pruned from iCloud.
    var lastPrunedAt: Date? {
        get { defaults.object(forKey: Key.lastPrunedAt) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Key.lastPrunedAt) }
    }

    var onboardingComplete: Bool {
        get { defaults.bool(forKey: Key.onboardingComplete) }
        nonmutating set { defaults.set(newValue, forKey: Key.onboardingComplete) }
    }
}
