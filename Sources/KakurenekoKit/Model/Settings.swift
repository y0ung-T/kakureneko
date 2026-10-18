import Foundation

/// All user settings with the defaults from DECISIONS (D1–D6) and the brief (§5.6, §6, §7.4, §8).
///
/// Persisted at `Paths.settingsFile` by the coordinator (`load(from:)` / `save(to:)`).
/// Versioned and tolerant: a missing key, a wrong type or an unknown key never fails a load — the
/// default is used instead, then `normalized()` clamps every range.
public struct KakurenekoSettings: Sendable, Hashable, Codable {
    /// 2: native notifications (ntfy removed). Files of either version without `phoneTiming` derive it from the
    /// keys it replaced (`NotificationSettings.init(from:)`).
    public static let currentVersion = 2

    public var version: Int
    public var general: GeneralSettings
    public var power: PowerSettings
    public var safety: SafetySettings
    public var timers: SessionTimers
    public var pausing: PauseSettings
    public var notifications: NotificationSettings
    public var integrations: IntegrationSettings

    public init(
        version: Int = KakurenekoSettings.currentVersion,
        general: GeneralSettings = GeneralSettings(),
        power: PowerSettings = PowerSettings(),
        safety: SafetySettings = SafetySettings(),
        timers: SessionTimers = SessionTimers(),
        pausing: PauseSettings = PauseSettings(),
        notifications: NotificationSettings = NotificationSettings(),
        integrations: IntegrationSettings = IntegrationSettings()
    ) {
        self.version = version
        self.general = general
        self.power = power
        self.safety = safety
        self.timers = timers
        self.pausing = pausing
        self.notifications = notifications
        self.integrations = integrations
    }

    public static let `default` = KakurenekoSettings()

    private enum CodingKeys: String, CodingKey { case version, general, power, safety, timers, pausing, notifications, integrations }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.tolerantDecode(Int.self, forKey: .version, default: KakurenekoSettings.currentVersion)
        general = c.tolerantDecode(GeneralSettings.self, forKey: .general, default: GeneralSettings())
        power = c.tolerantDecode(PowerSettings.self, forKey: .power, default: PowerSettings())
        safety = c.tolerantDecode(SafetySettings.self, forKey: .safety, default: SafetySettings())
        timers = c.tolerantDecode(SessionTimers.self, forKey: .timers, default: SessionTimers())
        pausing = c.tolerantDecode(PauseSettings.self, forKey: .pausing, default: PauseSettings())
        notifications = c.tolerantDecode(NotificationSettings.self, forKey: .notifications, default: NotificationSettings())
        integrations = c.tolerantDecode(IntegrationSettings.self, forKey: .integrations, default: IntegrationSettings())
    }

    /// Clamps every value into its documented range (the public `…Range` constants the UI also uses) and
    /// migrates older versions.
    public func normalized() -> KakurenekoSettings {
        var s = self
        // v1 → v2: v1's "away only" default is not carried over: the iPhone gets the current default.
        if s.version < 2 { s.notifications.phoneTiming = NotificationSettings().phoneTiming }
        s.version = KakurenekoSettings.currentVersion
        s.power.keepAwakeButtonSeconds = s.power.keepAwakeButtonSeconds.clamped(to: PowerSettings.keepAwakeButtonSecondsRange)
        s.safety.batteryFloorPercent = s.safety.batteryFloorPercent.clamped(to: SafetySettings.batteryFloorPercentRange)
        s.safety.hardFloorPercent = SafetySettings.hardFloorPercentFixed
        s.safety.minimumTimeToEmptyMinutes = s.safety.minimumTimeToEmptyMinutes.clamped(to: SafetySettings.minimumTimeToEmptyMinutesRange)
        s.safety.thermalSeriousSeconds = s.safety.thermalSeriousSeconds.clamped(to: SafetySettings.thermalSeriousSecondsRange)
        s.safety.networkOfflineMinutes = s.safety.networkOfflineMinutes.clamped(to: SafetySettings.networkOfflineMinutesRange)
        s.safety.maxClosedLidHours = s.safety.maxClosedLidHours.clamped(to: SafetySettings.maxClosedLidHoursRange)
        let fixed = SessionTimers()
        s.timers.settleSeconds = fixed.settleSeconds
        s.timers.notifyBatchSeconds = fixed.notifyBatchSeconds
        s.timers.finishCountdownMinutes = s.timers.finishCountdownMinutes.clamped(to: SessionTimers.finishCountdownMinutesRange)
        s.timers.needsInputCountdownMinutes = s.timers.needsInputCountdownMinutes.clamped(to: SessionTimers.needsInputCountdownMinutesRange)
        s.timers.stallMinutes = s.timers.stallMinutes.clamped(to: SessionTimers.stallMinutesRange)
        s.timers.heuristicExitMinutes = s.timers.heuristicExitMinutes.clamped(to: SessionTimers.heuristicExitMinutesRange)
        s.timers.heuristicSustainSeconds = fixed.heuristicSustainSeconds
        s.timers.disarmLidOpenMinutes = fixed.disarmLidOpenMinutes
        s.timers.endedRetentionMinutes = fixed.endedRetentionMinutes
        if s.pausing.mode == .quit { s.pausing.mode = .throttle } // Quit is gated by quitWhenMemoryLow only
        s.pausing.lidCloseSettleSeconds = s.pausing.lidCloseSettleSeconds.clamped(to: PauseSettings.lidCloseSettleSecondsRange)
        s.pausing.userInputGraceSeconds = s.pausing.userInputGraceSeconds.clamped(to: PauseSettings.userInputGraceSecondsRange)
        s.pausing.recheckSeconds = s.pausing.recheckSeconds.clamped(to: PauseSettings.recheckSecondsRange)
        s.pausing.throttleRescanSeconds = s.pausing.throttleRescanSeconds.clamped(to: PauseSettings.throttleRescanSecondsRange)
        s.pausing.maxPausedHours = s.pausing.maxPausedHours.clamped(to: PauseSettings.maxPausedHoursRange)
        s.pausing.watchdogMinutes = s.pausing.watchdogMinutes.clamped(to: PauseSettings.watchdogMinutesRange)
        s.pausing.neverPauseBundleIDs = Array(Set(s.pausing.neverPauseBundleIDs.filter { !$0.isEmpty })).sorted()
        s.notifications.awayIdleSeconds = s.notifications.awayIdleSeconds.clamped(to: NotificationSettings.awayIdleSecondsRange)
        s.notifications.rateLimitPerTenMinutes = s.notifications.rateLimitPerTenMinutes.clamped(to: NotificationSettings.rateLimitPerTenMinutesRange)
        s.notifications.needsInputReminderMinutes = s.notifications.needsInputReminderMinutes.clamped(to: NotificationSettings.needsInputReminderMinutesRange)
        s.notifications.minimumWorkSeconds = s.notifications.minimumWorkSeconds.clamped(to: NotificationSettings.minimumWorkSecondsRange)
        s.notifications.quietHours.startMinute = s.notifications.quietHours.startMinute.clamped(to: QuietHours.minuteRange)
        s.notifications.quietHours.endMinute = s.notifications.quietHours.endMinute.clamped(to: QuietHours.minuteRange)
        return s
    }

    /// Loads settings; a missing or corrupt file yields `.default`. Always normalized.
    public static func load(from url: URL) -> KakurenekoSettings {
        guard let data = try? AtomicFile.readIfExists(url),
              let decoded = try? KakurenekoJSON.decode(KakurenekoSettings.self, from: data) else {
            return KakurenekoSettings.default.normalized()
        }
        return decoded.normalized()
    }

    /// The `version` stored in the file at `url` (nil: no file, unreadable, or no version key).
    public static func storedVersion(at url: URL) -> Int? {
        struct Header: Decodable { var version: Int? }
        guard let data = try? AtomicFile.readIfExists(url) else { return nil }
        return (try? JSONDecoder().decode(Header.self, from: data))?.version
    }

    /// Atomic write (0600).
    public func save(to url: URL) throws {
        try AtomicFile.write(KakurenekoJSON.encode(normalized()), to: url, permissions: 0o600, followSymlinks: false)
    }
}

/// General.
public struct GeneralSettings: Sendable, Hashable, Codable {
    /// Master switch ("Kakureneko is on"). Off → disarm, thaw, no pushes, only watching.
    public var enabled: Bool = true
    /// `SMAppService.mainApp` toggle (performed by the app target; persisted here).
    public var launchAtLogin: Bool = false
    /// Developer dry-run toggle. Effective dry-run = `KAKURENEKO_DRY_RUN` OR this.
    public var dryRun: Bool = false
    public var onboardingCompleted: Bool = false
    /// Mirror logs into `~/.kakureneko/log/kakureneko.log`.
    public var fileLogEnabled: Bool = true
    /// Sparkle's daily update check (Developer ID builds only; the app applies it at launch and on change).
    public var automaticUpdateChecks: Bool = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, launchAtLogin, dryRun, onboardingCompleted, fileLogEnabled, automaticUpdateChecks
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GeneralSettings()
        enabled = c.tolerantDecode(Bool.self, forKey: .enabled, default: d.enabled)
        launchAtLogin = c.tolerantDecode(Bool.self, forKey: .launchAtLogin, default: d.launchAtLogin)
        dryRun = c.tolerantDecode(Bool.self, forKey: .dryRun, default: d.dryRun)
        onboardingCompleted = c.tolerantDecode(Bool.self, forKey: .onboardingCompleted, default: d.onboardingCompleted)
        fileLogEnabled = c.tolerantDecode(Bool.self, forKey: .fileLogEnabled, default: d.fileLogEnabled)
        automaticUpdateChecks = c.tolerantDecode(Bool.self, forKey: .automaticUpdateChecks, default: d.automaticUpdateChecks)
    }
}

/// Power behaviour (goal 1 and goal 4).
public struct PowerSettings: Sendable, Hashable, Codable {
    /// Keep the Mac awake with the lid closed while agents work (needs the privileged install, D3).
    public var keepAwakeWithLidClosed: Bool = true
    /// D2: `.sleep` (default). `.shutdown` is opt-in, falls back to sleep, and enables the phone "Shut down" button.
    public var endAction: EndAction = .sleep
    /// `pmset displaysleepnow` at lid close when no external display is online.
    public var displaySleepOnLidClose: Bool = true
    /// When the "Submarine" chime plays at lid close (bag hint): on battery by default.
    public var lidCloseSound: LidCloseSound = .onBattery
    /// Seconds for the phone/menu "Keep awake" button (default 1 h).
    public var keepAwakeButtonSeconds: Int = 3600

    public init() {}

    /// UI/`normalized()` range for `keepAwakeButtonSeconds` (5 min – 12 h).
    public static let keepAwakeButtonSecondsRange: ClosedRange<Int> = 300...(12 * 3600)

    public var shutdownEnabled: Bool { endAction == .shutdown }

    /// `lidCloseChimeOnBattery` (replaced by `lidCloseSound`) is read only to derive it.
    private enum CodingKeys: String, CodingKey {
        case keepAwakeWithLidClosed, endAction, displaySleepOnLidClose, lidCloseSound, lidCloseChimeOnBattery, keepAwakeButtonSeconds
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PowerSettings()
        keepAwakeWithLidClosed = c.tolerantDecode(Bool.self, forKey: .keepAwakeWithLidClosed, default: d.keepAwakeWithLidClosed)
        endAction = c.tolerantDecode(EndAction.self, forKey: .endAction, default: d.endAction)
        displaySleepOnLidClose = c.tolerantDecode(Bool.self, forKey: .displaySleepOnLidClose, default: d.displaySleepOnLidClose)
        lidCloseSound = c.tolerantDecodeIfPresent(LidCloseSound.self, forKey: .lidCloseSound)
            ?? (c.tolerantDecodeIfPresent(Bool.self, forKey: .lidCloseChimeOnBattery) == false ? .off : d.lidCloseSound)
        keepAwakeButtonSeconds = c.tolerantDecode(Int.self, forKey: .keepAwakeButtonSeconds, default: d.keepAwakeButtonSeconds)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(keepAwakeWithLidClosed, forKey: .keepAwakeWithLidClosed)
        try c.encode(endAction, forKey: .endAction)
        try c.encode(displaySleepOnLidClose, forKey: .displaySleepOnLidClose)
        try c.encode(lidCloseSound, forKey: .lidCloseSound)
        try c.encode(keepAwakeButtonSeconds, forKey: .keepAwakeButtonSeconds)
    }
}

/// When the lid-close chime plays (a reminder not to put a running Mac in a bag). Only while an agent keeps the
/// Mac awake: a lid close that lets the Mac sleep stays silent.
public enum LidCloseSound: String, Sendable, Hashable, Codable, CaseIterable {
    case off
    /// Default: on battery, where a closed Mac in a bag runs flat and heats up.
    case onBattery
    /// Also on AC power.
    case always

    public func plays(onBattery: Bool) -> Bool {
        switch self {
        case .off: false
        case .onBattery: onBattery
        case .always: true
        }
    }
}

/// Safety policy (brief §7.4, D1).
public struct SafetySettings: Sendable, Hashable, Codable {
    /// D1: lid closed on battery allowed.
    public var allowOnBattery: Bool = true
    /// Battery floor, 10–50 %.
    public var batteryFloorPercent: Int = 20
    /// Root fail-safe floor (fixed 7 %, informational).
    public var hardFloorPercent: Int = 7
    /// Trip when `timeToEmpty` < this many minutes.
    public var minimumTimeToEmptyMinutes: Int = 25
    /// `.serious` thermal state or `heavy` pressure for this long → trip.
    public var thermalSeriousSeconds: Int = 60
    /// Network unsatisfied for this long → trip.
    public var networkOfflineMinutes: Int = 15
    /// Max closed-lid duration, 1–24 h.
    public var maxClosedLidHours: Int = 12
    /// Warn (only) about Low Power Mode on battery.
    public var warnLowPowerMode: Bool = true

    public init() {}

    // Ranges shared by `normalized()` and the settings UI.
    public static let batteryFloorPercentRange: ClosedRange<Int> = 10...50
    public static let hardFloorPercentFixed = 7
    public static let minimumTimeToEmptyMinutesRange: ClosedRange<Int> = 5...120
    public static let thermalSeriousSecondsRange: ClosedRange<Int> = 10...600
    public static let networkOfflineMinutesRange: ClosedRange<Int> = 1...120
    public static let maxClosedLidHoursRange: ClosedRange<Int> = 1...24

    private enum CodingKeys: String, CodingKey {
        case allowOnBattery, batteryFloorPercent, hardFloorPercent, minimumTimeToEmptyMinutes
        case thermalSeriousSeconds, networkOfflineMinutes, maxClosedLidHours, warnLowPowerMode
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SafetySettings()
        allowOnBattery = c.tolerantDecode(Bool.self, forKey: .allowOnBattery, default: d.allowOnBattery)
        batteryFloorPercent = c.tolerantDecode(Int.self, forKey: .batteryFloorPercent, default: d.batteryFloorPercent)
        hardFloorPercent = c.tolerantDecode(Int.self, forKey: .hardFloorPercent, default: d.hardFloorPercent)
        minimumTimeToEmptyMinutes = c.tolerantDecode(Int.self, forKey: .minimumTimeToEmptyMinutes, default: d.minimumTimeToEmptyMinutes)
        thermalSeriousSeconds = c.tolerantDecode(Int.self, forKey: .thermalSeriousSeconds, default: d.thermalSeriousSeconds)
        networkOfflineMinutes = c.tolerantDecode(Int.self, forKey: .networkOfflineMinutes, default: d.networkOfflineMinutes)
        maxClosedLidHours = c.tolerantDecode(Int.self, forKey: .maxClosedLidHours, default: d.maxClosedLidHours)
        warnLowPowerMode = c.tolerantDecode(Bool.self, forKey: .warnLowPowerMode, default: d.warnLowPowerMode)
    }
}

/// Session timers (brief §5.6). "fixed" values are clamped back by `normalized()`.
public struct SessionTimers: Sendable, Hashable, Codable {
    /// Fixed 5 s.
    public var settleSeconds: Int = 5
    /// Fixed 15 s.
    public var notifyBatchSeconds: Int = 15
    /// 1–60 min.
    public var finishCountdownMinutes: Int = 5
    /// 2–120 min.
    public var needsInputCountdownMinutes: Int = 10
    /// 10–120 min.
    public var stallMinutes: Int = 20
    /// T3 exit window, 2–30 min.
    public var heuristicExitMinutes: Int = 5
    /// T3 sustain, fixed 20 s.
    public var heuristicSustainSeconds: Int = 20
    /// Disarm after nothing works with the lid open, fixed 2 min.
    public var disarmLidOpenMinutes: Int = 2
    /// Ended sessions are dropped after this, fixed 10 min.
    public var endedRetentionMinutes: Int = 10

    public init() {}

    // Ranges shared by `normalized()` and the settings UI (the other timers are fixed).
    public static let finishCountdownMinutesRange: ClosedRange<Int> = 1...60
    public static let needsInputCountdownMinutesRange: ClosedRange<Int> = 2...120
    public static let stallMinutesRange: ClosedRange<Int> = 10...120
    public static let heuristicExitMinutesRange: ClosedRange<Int> = 2...30

    public var settle: TimeInterval { TimeInterval(settleSeconds) }
    public var notifyBatch: TimeInterval { TimeInterval(notifyBatchSeconds) }
    public var finishCountdown: TimeInterval { TimeInterval(finishCountdownMinutes * 60) }
    public var needsInputCountdown: TimeInterval { TimeInterval(needsInputCountdownMinutes * 60) }
    public var stall: TimeInterval { TimeInterval(stallMinutes * 60) }
    public var heuristicExit: TimeInterval { TimeInterval(heuristicExitMinutes * 60) }
    public var heuristicSustain: TimeInterval { TimeInterval(heuristicSustainSeconds) }
    public var disarmLidOpen: TimeInterval { TimeInterval(disarmLidOpenMinutes * 60) }
    public var endedRetention: TimeInterval { TimeInterval(endedRetentionMinutes * 60) }

    private enum CodingKeys: String, CodingKey {
        case settleSeconds, notifyBatchSeconds, finishCountdownMinutes, needsInputCountdownMinutes, stallMinutes
        case heuristicExitMinutes, heuristicSustainSeconds, disarmLidOpenMinutes, endedRetentionMinutes
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SessionTimers()
        settleSeconds = c.tolerantDecode(Int.self, forKey: .settleSeconds, default: d.settleSeconds)
        notifyBatchSeconds = c.tolerantDecode(Int.self, forKey: .notifyBatchSeconds, default: d.notifyBatchSeconds)
        finishCountdownMinutes = c.tolerantDecode(Int.self, forKey: .finishCountdownMinutes, default: d.finishCountdownMinutes)
        needsInputCountdownMinutes = c.tolerantDecode(Int.self, forKey: .needsInputCountdownMinutes, default: d.needsInputCountdownMinutes)
        stallMinutes = c.tolerantDecode(Int.self, forKey: .stallMinutes, default: d.stallMinutes)
        heuristicExitMinutes = c.tolerantDecode(Int.self, forKey: .heuristicExitMinutes, default: d.heuristicExitMinutes)
        heuristicSustainSeconds = c.tolerantDecode(Int.self, forKey: .heuristicSustainSeconds, default: d.heuristicSustainSeconds)
        disarmLidOpenMinutes = c.tolerantDecode(Int.self, forKey: .disarmLidOpenMinutes, default: d.disarmLidOpenMinutes)
        endedRetentionMinutes = c.tolerantDecode(Int.self, forKey: .endedRetentionMinutes, default: d.endedRetentionMinutes)
    }
}

/// App pausing (brief §6, D6).
public struct PauseSettings: Sendable, Hashable, Codable {
    /// Global "pause nothing" switch is `enabled == false` (rule P-K).
    public var enabled: Bool = true
    /// `.throttle` (default) or `.freeze` (experimental, only effective when the grouping self-test passes).
    /// Never `.quit` (`normalized()` maps it to `.throttle`; Quit is `quitWhenMemoryLow`).
    public var mode: PauseMode = .throttle
    /// D6: "Quit idle apps when memory is low" — off by default.
    public var quitWhenMemoryLow: Bool = false
    /// Per-app never-pause list (bundle ids, rule P-K).
    public var neverPauseBundleIDs: [String] = []
    /// Settle after lid close before pausing (brief §6.1: 90 s).
    public var lidCloseSettleSeconds: Int = 90
    /// No user input for this long before pausing (brief §6.1: 60 s).
    public var userInputGraceSeconds: Int = 60
    /// Re-check protection rules while paused (10–15 s).
    public var recheckSeconds: Int = 15
    /// Re-scan for new helpers to throttle (30 s).
    public var throttleRescanSeconds: Int = 30
    /// Hard cap; thaw everything after this.
    public var maxPausedHours: Int = 12
    /// "Agent CPU not advancing for N min while apps are frozen → thaw all" watchdog.
    public var watchdogMinutes: Int = 5
    /// Optional App Tamer-style breathing for Freeze (off).
    public var breathing: Bool = false

    public init() {}

    // Ranges shared by `normalized()` and the settings UI.
    public static let lidCloseSettleSecondsRange: ClosedRange<Int> = 30...600
    public static let userInputGraceSecondsRange: ClosedRange<Int> = 10...600
    public static let recheckSecondsRange: ClosedRange<Int> = 10...60
    public static let throttleRescanSecondsRange: ClosedRange<Int> = 10...120
    public static let maxPausedHoursRange: ClosedRange<Int> = 1...24
    public static let watchdogMinutesRange: ClosedRange<Int> = 1...30

    private enum CodingKeys: String, CodingKey {
        case enabled, mode, quitWhenMemoryLow, neverPauseBundleIDs, lidCloseSettleSeconds, userInputGraceSeconds
        case recheckSeconds, throttleRescanSeconds, maxPausedHours, watchdogMinutes, breathing
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PauseSettings()
        enabled = c.tolerantDecode(Bool.self, forKey: .enabled, default: d.enabled)
        mode = c.tolerantDecode(PauseMode.self, forKey: .mode, default: d.mode)
        quitWhenMemoryLow = c.tolerantDecode(Bool.self, forKey: .quitWhenMemoryLow, default: d.quitWhenMemoryLow)
        neverPauseBundleIDs = c.tolerantDecode([String].self, forKey: .neverPauseBundleIDs, default: d.neverPauseBundleIDs)
        lidCloseSettleSeconds = c.tolerantDecode(Int.self, forKey: .lidCloseSettleSeconds, default: d.lidCloseSettleSeconds)
        userInputGraceSeconds = c.tolerantDecode(Int.self, forKey: .userInputGraceSeconds, default: d.userInputGraceSeconds)
        recheckSeconds = c.tolerantDecode(Int.self, forKey: .recheckSeconds, default: d.recheckSeconds)
        throttleRescanSeconds = c.tolerantDecode(Int.self, forKey: .throttleRescanSeconds, default: d.throttleRescanSeconds)
        maxPausedHours = c.tolerantDecode(Int.self, forKey: .maxPausedHours, default: d.maxPausedHours)
        watchdogMinutes = c.tolerantDecode(Int.self, forKey: .watchdogMinutes, default: d.watchdogMinutes)
        breathing = c.tolerantDecode(Bool.self, forKey: .breathing, default: d.breathing)
    }
}

/// When alerts go to the iPhone (the Mac shows every alert while its notifications are on).
public enum PhoneAlertTiming: String, Sendable, Hashable, Codable, CaseIterable {
    /// Only while the lid is (effectively) closed. Default: at an open Mac its own notifications are enough.
    case lidClosed
    /// While the user is away from the Mac: lid closed, screen locked or no input for `awayIdleSeconds`.
    case away
    /// Always, also while the user is at the Mac.
    case always
}

/// Quiet hours (default off): downgrade to priority ≤ 2, never drop.
public struct QuietHours: Sendable, Hashable, Codable {
    public var enabled: Bool = false
    /// Minutes after local midnight (default 23:00).
    public var startMinute: Int = 23 * 60
    /// Minutes after local midnight (default 07:00).
    public var endMinute: Int = 7 * 60

    /// Minutes after local midnight.
    public static let minuteRange: ClosedRange<Int> = 0...1439

    public init(enabled: Bool = false, startMinute: Int = 23 * 60, endMinute: Int = 7 * 60) {
        self.enabled = enabled
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    /// True when `date` falls inside the window (handles windows crossing midnight).
    public func contains(_ date: Date, timeZone: TimeZone = .current) -> Bool {
        guard enabled, startMinute != endMinute else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if startMinute < endMinute { return minute >= startMinute && minute < endMinute }
        return minute >= startMinute || minute < endMinute
    }

    private enum CodingKeys: String, CodingKey { case enabled, startMinute, endMinute }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = QuietHours()
        enabled = c.tolerantDecode(Bool.self, forKey: .enabled, default: d.enabled)
        startMinute = c.tolerantDecode(Int.self, forKey: .startMinute, default: d.startMinute)
        endMinute = c.tolerantDecode(Int.self, forKey: .endMinute, default: d.endMinute)
    }
}

/// Phone notifications (brief §8, D4).
public struct NotificationSettings: Sendable, Hashable, Codable {
    public var enabled: Bool = true
    /// Show alerts as macOS notifications on this Mac.
    public var macAlerts: Bool = true
    /// Send alerts to the Kakureneko iPhone app through iCloud.
    public var phoneAlerts: Bool = true
    /// When they go to the iPhone. The test, answers to iPhone taps, the shutdown and safety stops always go
    /// (`NotificationPolicy.phoneTimingBypass`).
    public var phoneTiming: PhoneAlertTiming = .lidClosed
    /// D4: Basic by default.
    public var detailLevel: DetailLevel = .basic
    /// "Away" after this much user inactivity (default 5 min).
    public var awayIdleSeconds: Int = 300
    public var quietHours: QuietHours = QuietHours()
    /// Kinds the user muted (new kinds are on by default).
    public var mutedKinds: Set<NotificationKind> = []
    /// "Don't push for Claude sessions with Remote Control connected" (default off).
    public var skipClaudeRemoteControlSessions: Bool = false
    /// Global bucket: at most this many pushes per 10 min; overflow → digest.
    public var rateLimitPerTenMinutes: Int = 6
    /// One reminder after this many minutes of waiting.
    public var needsInputReminderMinutes: Int = 10
    /// "Agent finished" (and "went quiet") alerts only for turns that worked at least this long; 0 = every turn.
    /// Unknown durations still alert; waiting agents always do.
    public var minimumWorkSeconds: Int = 0

    public init() {}

    // Ranges shared by `normalized()` and the settings UI.
    public static let awayIdleSecondsRange: ClosedRange<Int> = 60...3600
    public static let rateLimitPerTenMinutesRange: ClosedRange<Int> = 1...60
    public static let needsInputReminderMinutesRange: ClosedRange<Int> = 2...120
    public static let minimumWorkSecondsRange: ClosedRange<Int> = 0...7200

    public func isMuted(_ kind: NotificationKind) -> Bool { mutedKinds.contains(kind) }

    /// `phoneTiming` of a file written before it existed: "only when the lid is closed" (default on) wins, else
    /// presence gating "only when I'm away" (it gated the Mac too; now only the iPhone), else always.
    static func legacyPhoneTiming(lidClosedOnly: Bool?, awayOnly: Bool) -> PhoneAlertTiming {
        if lidClosedOnly == true { return .lidClosed }
        if awayOnly { return .away }
        return lidClosedOnly == false ? .always : NotificationSettings().phoneTiming
    }

    /// Keys of settings files written before v2 (`provider`, `ntfyServer`) are ignored when decoding;
    /// `presenceGating` and `phoneOnlyWhenLidClosed` (replaced by `phoneTiming`) are read only to derive it.
    private enum CodingKeys: String, CodingKey {
        case enabled, macAlerts, phoneAlerts, phoneTiming, detailLevel, awayIdleSeconds, quietHours, mutedKinds
        case presenceGating, phoneOnlyWhenLidClosed
        case skipClaudeRemoteControlSessions, rateLimitPerTenMinutes, needsInputReminderMinutes, minimumWorkSeconds
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotificationSettings()
        enabled = c.tolerantDecode(Bool.self, forKey: .enabled, default: d.enabled)
        macAlerts = c.tolerantDecode(Bool.self, forKey: .macAlerts, default: d.macAlerts)
        phoneAlerts = c.tolerantDecode(Bool.self, forKey: .phoneAlerts, default: d.phoneAlerts)
        phoneTiming = c.tolerantDecodeIfPresent(PhoneAlertTiming.self, forKey: .phoneTiming)
            ?? Self.legacyPhoneTiming(
                lidClosedOnly: c.tolerantDecodeIfPresent(Bool.self, forKey: .phoneOnlyWhenLidClosed),
                awayOnly: c.tolerantDecodeIfPresent(String.self, forKey: .presenceGating) == "awayOnly")
        detailLevel = c.tolerantDecode(DetailLevel.self, forKey: .detailLevel, default: d.detailLevel)
        awayIdleSeconds = c.tolerantDecode(Int.self, forKey: .awayIdleSeconds, default: d.awayIdleSeconds)
        quietHours = c.tolerantDecode(QuietHours.self, forKey: .quietHours, default: d.quietHours)
        let mutedRaw = c.tolerantDecode([String].self, forKey: .mutedKinds, default: [])
        mutedKinds = Set(mutedRaw.compactMap(NotificationKind.init(rawValue:)))
        skipClaudeRemoteControlSessions = c.tolerantDecode(Bool.self, forKey: .skipClaudeRemoteControlSessions, default: d.skipClaudeRemoteControlSessions)
        rateLimitPerTenMinutes = c.tolerantDecode(Int.self, forKey: .rateLimitPerTenMinutes, default: d.rateLimitPerTenMinutes)
        needsInputReminderMinutes = c.tolerantDecode(Int.self, forKey: .needsInputReminderMinutes, default: d.needsInputReminderMinutes)
        minimumWorkSeconds = c.tolerantDecode(Int.self, forKey: .minimumWorkSeconds, default: d.minimumWorkSeconds)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(macAlerts, forKey: .macAlerts)
        try c.encode(phoneAlerts, forKey: .phoneAlerts)
        try c.encode(phoneTiming, forKey: .phoneTiming)
        try c.encode(detailLevel, forKey: .detailLevel)
        try c.encode(awayIdleSeconds, forKey: .awayIdleSeconds)
        try c.encode(quietHours, forKey: .quietHours)
        try c.encode(mutedKinds.map(\.rawValue).sorted(), forKey: .mutedKinds)
        try c.encode(skipClaudeRemoteControlSessions, forKey: .skipClaudeRemoteControlSessions)
        try c.encode(rateLimitPerTenMinutes, forKey: .rateLimitPerTenMinutes)
        try c.encode(needsInputReminderMinutes, forKey: .needsInputReminderMinutes)
        try c.encode(minimumWorkSeconds, forKey: .minimumWorkSeconds)
    }
}

/// Agent integrations.
public struct IntegrationSettings: Sendable, Hashable, Codable {
    /// Agents the user chose not to integrate (onboarding stops offering them).
    public var dismissedAgents: Set<AgentID> = []
    /// Re-apply our entries automatically when an agent rewrote its config (default off: show "Repair").
    public var autoRepair: Bool = false

    public init() {}

    private enum CodingKeys: String, CodingKey { case dismissedAgents, autoRepair }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dismissedAgents = Set(c.tolerantDecode([AgentID].self, forKey: .dismissedAgents, default: []).filter { $0 != .unknown })
        autoRepair = c.tolerantDecode(Bool.self, forKey: .autoRepair, default: false)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dismissedAgents.sorted(), forKey: .dismissedAgents)
        try c.encode(autoRepair, forKey: .autoRepair)
    }
}

extension Comparable {
    /// Clamps into a closed range.
    public func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
