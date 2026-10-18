import KakurenekoCloud
import KakurenekoKit
import Foundation
import IOKit
import Synchronization
import SystemConfiguration
import UserNotifications

/// The live `LocalNotificationPosting`: Kakureneko's own macOS notifications through `UNUserNotificationCenter`,
/// and their delegate (presentation while Kakureneko is frontmost, button taps → `buttonTaps()`).
///
/// Only exists inside the app bundle (`makeIfAvailable`): `UNUserNotificationCenter.current()` traps in a
/// process without a bundle identifier (`swift test`, the bare SwiftPM executable).
///
/// Isolation: immutable after init; the center is fetched per call (`UNUserNotificationCenter.current()` is
/// thread-safe); the delegate callbacks run on UserNotifications' queue and only yield into a broadcaster.
public final class UserNotificationCenterPoster: NSObject, LocalNotificationPosting, UNUserNotificationCenterDelegate, Sendable {
    private let taps = AsyncBroadcaster<AlertPresentation.ButtonTap>(bufferLimit: 16)
    /// Taps that arrived before anyone subscribed (the tap that launched the app); handed to the first subscriber.
    private let early = Mutex(EarlyTaps())
    private let logger: KakurenekoLogger

    private struct EarlyTaps {
        var subscribed = false
        var pending: [AlertPresentation.ButtonTap] = []
    }

    private init(logger: KakurenekoLogger) {
        self.logger = logger
        super.init()
        // The delegate is weak: whoever holds this poster (the composition's side effects) keeps it alive.
        UNUserNotificationCenter.current().delegate = self
    }

    /// nil outside an app bundle (see the type documentation).
    public static func makeIfAvailable(bundle: Bundle = .main, logger: KakurenekoLogger = KakurenekoLogger(.notify)) -> UserNotificationCenterPoster? {
        guard bundle.bundleIdentifier != nil, bundle.bundleURL.pathExtension == "app" else { return nil }
        return UserNotificationCenterPoster(logger: logger)
    }

    // MARK: LocalNotificationPosting

    public func authorization() async -> (MacAlertAuthorization, timeSensitive: Bool?) {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let status: MacAlertAuthorization = switch settings.authorizationStatus {
        case .authorized: .authorized
        case .provisional, .ephemeral: .provisional
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
        let timeSensitive: Bool? = switch settings.timeSensitiveSetting {
        case .enabled: true
        case .disabled: false
        case .notSupported: nil
        @unknown default: nil
        }
        return (status, timeSensitive)
    }

    public func requestAuthorization() async -> MacAlertAuthorization {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            logger.notice("notification permission request failed: \(type(of: error))")
        }
        return await authorization().0
    }

    public func registerCategories(keepAwakeSeconds: Int) async {
        UNUserNotificationCenter.current().setNotificationCategories(AlertPresentation.categories(keepAwakeSeconds: keepAwakeSeconds))
    }

    public func post(_ alert: CloudAlert) async throws {
        let content = AlertPresentation.content(for: alert, now: Date(), showMacName: false)
        let request = UNNotificationRequest(identifier: AlertPresentation.requestIdentifier(for: alert), content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }

    public func buttonTaps() -> AsyncStream<AlertPresentation.ButtonTap> {
        let stream = taps.stream()
        let pending = early.withLock { e -> [AlertPresentation.ButtonTap] in
            e.subscribed = true
            defer { e.pending = [] }
            return e.pending
        }
        for tap in pending { taps.yield(tap) }
        return stream
    }

    public func removeRemoteAlerts() async {
        let center = UNUserNotificationCenter.current()
        let remote = await center.deliveredNotifications()
            .filter { $0.request.trigger is UNPushNotificationTrigger }
            .map(\.request.identifier)
        if !remote.isEmpty { center.removeDeliveredNotifications(withIdentifiers: remote) }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Kakureneko's own notifications show as banners even while it is frontmost. A CloudKit alert push (another Mac
    /// of the same Apple Account) is not shown: this Mac shows its own alerts locally, and the iPhone is where
    /// the alerts of every Mac come together.
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.trigger is UNPushNotificationTrigger {
            completionHandler([])
        } else {
            completionHandler([.banner, .list, .sound])
        }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        let request = response.notification.request
        guard !(request.trigger is UNPushNotificationTrigger),
              let tap = AlertPresentation.buttonTap(actionIdentifier: response.actionIdentifier, userInfo: request.content.userInfo)
        else { return }
        logger.notice("Mac notification button: \(tap.request.wireValue)")
        let deliverNow = early.withLock { e -> Bool in
            if !e.subscribed { e.pending.append(tap) }
            return e.subscribed
        }
        if deliverNow { taps.yield(tap) }
    }
}

/// This Mac as the iPhone app shows it.
public struct MacIdentity: Sendable, Hashable {
    /// The computer name (System Settings → General → Sharing).
    public var name: String
    /// "MacBook Pro (16-inch, 2021)" (device tree), else the `hw.model` identifier.
    public var model: String?
    /// "0.1.0 (12)".
    public var appVersion: String

    public init(name: String, model: String?, appVersion: String) {
        self.name = name
        self.model = model
        self.appVersion = appVersion
    }

    public static func current(bundle: Bundle = .main) -> MacIdentity {
        let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?).flatMap { $0.isEmpty ? nil : $0 } ?? "Mac"
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return MacIdentity(name: name, model: productName() ?? hardwareModel(), appVersion: build.map { "\(short) (\($0))" } ?? short)
    }

    /// `IODeviceTree:/product` `product-name` (Apple silicon).
    static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let value = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        let text = String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{0}")))
        return text.isEmpty ? nil : text
    }

    /// `hw.model`, e.g. "MacBookPro18,1".
    static func hardwareModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }
}
