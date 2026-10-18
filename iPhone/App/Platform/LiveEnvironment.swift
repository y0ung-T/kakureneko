// The app's live wiring: this device's description (UIDevice, `utsname`, the bundle's version), the store built on
// the real CloudKit container, and a background-task helper for work that must finish after the user leaves the
// app (a notification button). App-only: tests and previews build `PhoneStore` with fakes instead.

import KakurenekoCloud
import Foundation
import Security
import UIKit

extension DeviceInfo {
    /// This iPhone, read from the system.
    @MainActor
    static func current(bundle: Bundle = .main) -> DeviceInfo {
        DeviceInfo(name: UIDevice.current.name, model: hardwareModel(), systemVersion: UIDevice.current.systemVersion,
                   appVersion: appVersion(bundle: bundle))
    }

    /// "0.1.0 (1)".
    static func appVersion(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }

    /// "iPhone18,3" (the simulator reports the model it simulates).
    private static func hardwareModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

extension PhoneStore {
    /// The app's store: the app's public CloudKit database (each record readable and writable only by the Apple
    /// Account that created it), the cache in Application Support, standard defaults.
    static func live() -> PhoneStore {
        // iOS builds always carry the iCloud entitlement, so the fallback only guards against a mis-signed build:
        // an empty store that reports "unavailable in this build" instead of crashing on CKContainer.
        let cloud: any CloudStore = CloudKitStore.makeIfEntitled() ?? InMemoryCloudStore(account: .unavailableInThisBuild)
        return PhoneStore(cloud: cloud, cacheFile: .live, defaults: .standard, persistentID: KeychainDeviceID(),
                          device: .current(), notifications: SystemNotificationCenter())
    }
}

/// This iPhone's id in the Keychain: a generic password that outlives deleting the app, readable after the first
/// unlock (background pushes), this device only and never synced (each iPhone keeps its own).
struct KeychainDeviceID: DeviceIDStoring {
    private let service = "com.kakureneko.deviceID"
    private let account = "device"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    func load() -> DeviceIDLookup {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch SecItemCopyMatching(request as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data, let id = String(data: data, encoding: .utf8) else { return .missing }
            return .found(id)
        case errSecItemNotFound:
            return .missing
        default:
            return .unavailable // errSecInteractionNotAllowed before the first unlock, and the like
        }
    }

    func save(_ id: String) {
        let data = Data(id.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard update == errSecItemNotFound else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// Keeps the app running in the background until `end()` (or until iOS reclaims the time, after calling
/// `onExpiration`).
@MainActor
final class BackgroundTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String, onExpiration: @escaping @MainActor @Sendable () -> Void) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            onExpiration()
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
