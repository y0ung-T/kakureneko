// The settings form, as data: every numeric setting with its range taken from the public Kit `…Range`
// constants (never copies, so the UI and `KakurenekoSettings.normalized()` always agree), plus the small pure
// conversions and validators the settings and onboarding screens use.

import KakurenekoKit
import Foundation

/// How a numeric value is shown.
nonisolated enum SettingUnit: Sendable, Hashable {
    case seconds
    case minutes
    case hours
    case percent
    case perTenMinutes

    func format(_ value: Int) -> String {
        switch self {
        case .seconds: DurationText.settingSeconds(value)
        case .minutes: DurationText.settingMinutes(value)
        case .hours: value == 1 ? "1 hour" : "\(value) hours"
        case .percent: "\(value) %"
        case .perTenMinutes: value == 1 ? "1 per 10 min" : "\(value) per 10 min"
        }
    }
}

/// One numeric setting row (a stepper).
struct IntSettingSpec: Identifiable {
    var id: String
    var title: String
    var help: String?
    var keyPath: WritableKeyPath<KakurenekoSettings, Int>
    var range: ClosedRange<Int>
    var step: Int
    var unit: SettingUnit

    func format(_ value: Int) -> String { unit.format(value) }

    /// `1 min – 1 h` for the help line.
    var rangeText: String { "\(unit.format(range.lowerBound)) – \(unit.format(range.upperBound))" }

    /// The value after a stepper/typed edit: clamped exactly like `normalized()`.
    func clamp(_ value: Int) -> Int { value.clamped(to: range) }
}

/// Every numeric setting, grouped by settings pane.
enum SettingsCatalog {
    static let keepAwakeButton = IntSettingSpec(
        id: "power.keepAwakeButtonSeconds", title: "\"Keep awake\" button on alerts",
        help: "How long the Keep awake button (Mac and iPhone) keeps the Mac up.",
        keyPath: \.power.keepAwakeButtonSeconds, range: PowerSettings.keepAwakeButtonSecondsRange, step: 300, unit: .seconds)

    static let safety: [IntSettingSpec] = [
        IntSettingSpec(id: "safety.batteryFloorPercent", title: "Sleep when the battery drops to",
                       help: "Also trips on the system's low-battery warning.",
                       keyPath: \.safety.batteryFloorPercent, range: SafetySettings.batteryFloorPercentRange, step: 1, unit: .percent),
        IntSettingSpec(id: "safety.minimumTimeToEmptyMinutes", title: "Sleep when less battery time is left than",
                       help: nil, keyPath: \.safety.minimumTimeToEmptyMinutes,
                       range: SafetySettings.minimumTimeToEmptyMinutesRange, step: 5, unit: .minutes),
        IntSettingSpec(id: "safety.thermalSeriousSeconds", title: "Sleep when it stays hot for",
                       help: "Critical temperatures always put the Mac to sleep at once.",
                       keyPath: \.safety.thermalSeriousSeconds, range: SafetySettings.thermalSeriousSecondsRange, step: 10, unit: .seconds),
        IntSettingSpec(id: "safety.networkOfflineMinutes", title: "Sleep when offline for",
                       help: "Agents cannot reach their API without a network.",
                       keyPath: \.safety.networkOfflineMinutes, range: SafetySettings.networkOfflineMinutesRange, step: 1, unit: .minutes),
        IntSettingSpec(id: "safety.maxClosedLidHours", title: "Never stay awake with the lid closed longer than",
                       help: nil, keyPath: \.safety.maxClosedLidHours, range: SafetySettings.maxClosedLidHoursRange, step: 1, unit: .hours),
    ]

    static let timers: [IntSettingSpec] = [
        IntSettingSpec(id: "timers.finishCountdownMinutes", title: "Sleep after all agents finish",
                       help: "Countdown with the lid closed once nothing is working.",
                       keyPath: \.timers.finishCountdownMinutes, range: SessionTimers.finishCountdownMinutesRange, step: 1, unit: .minutes),
        IntSettingSpec(id: "timers.needsInputCountdownMinutes", title: "Sleep after an agent starts waiting",
                       help: "Also how long a waiting agent keeps the Mac armed with the lid open.",
                       keyPath: \.timers.needsInputCountdownMinutes, range: SessionTimers.needsInputCountdownMinutesRange, step: 1, unit: .minutes),
        IntSettingSpec(id: "timers.stallMinutes", title: "Treat a silent agent as stuck after",
                       help: "A stuck agent no longer keeps the Mac awake.",
                       keyPath: \.timers.stallMinutes, range: SessionTimers.stallMinutesRange, step: 5, unit: .minutes),
        IntSettingSpec(id: "timers.heuristicExitMinutes", title: "Agents without hooks count as done after",
                       help: "Quiet time before an activity-detected agent is considered finished.",
                       keyPath: \.timers.heuristicExitMinutes, range: SessionTimers.heuristicExitMinutesRange, step: 1, unit: .minutes),
    ]

    static let pausing: [IntSettingSpec] = [
        IntSettingSpec(id: "pausing.lidCloseSettleSeconds", title: "Wait after closing the lid", help: nil,
                       keyPath: \.pausing.lidCloseSettleSeconds, range: PauseSettings.lidCloseSettleSecondsRange, step: 10, unit: .seconds),
        IntSettingSpec(id: "pausing.userInputGraceSeconds", title: "Only after no input for", help: nil,
                       keyPath: \.pausing.userInputGraceSeconds, range: PauseSettings.userInputGraceSecondsRange, step: 10, unit: .seconds),
        IntSettingSpec(id: "pausing.recheckSeconds", title: "Re-check paused apps every", help: nil,
                       keyPath: \.pausing.recheckSeconds, range: PauseSettings.recheckSecondsRange, step: 5, unit: .seconds),
        IntSettingSpec(id: "pausing.throttleRescanSeconds", title: "Look for new helper processes every", help: nil,
                       keyPath: \.pausing.throttleRescanSeconds, range: PauseSettings.throttleRescanSecondsRange, step: 10, unit: .seconds),
        IntSettingSpec(id: "pausing.maxPausedHours", title: "Resume everything after", help: nil,
                       keyPath: \.pausing.maxPausedHours, range: PauseSettings.maxPausedHoursRange, step: 1, unit: .hours),
        IntSettingSpec(id: "pausing.watchdogMinutes", title: "Resume all if an agent makes no progress for",
                       help: "Safety net in case a paused app was blocking an agent.",
                       keyPath: \.pausing.watchdogMinutes, range: PauseSettings.watchdogMinutesRange, step: 1, unit: .minutes),
    ]

    /// Shown under the iPhone's "When I'm away from the Mac" (it also tells the closed-lid countdown that someone
    /// is still using the Mac).
    static let awayIdle = IntSettingSpec(
        id: "notifications.awayIdleSeconds", title: "Count me as away after no input for",
        help: "With the lid open; a closed lid or a locked screen always counts as away.",
        keyPath: \.notifications.awayIdleSeconds, range: NotificationSettings.awayIdleSecondsRange, step: 60, unit: .seconds)

    static let notifications: [IntSettingSpec] = [
        IntSettingSpec(id: "notifications.needsInputReminderMinutes", title: "Remind me once about a waiting agent after",
                       help: nil, keyPath: \.notifications.needsInputReminderMinutes,
                       range: NotificationSettings.needsInputReminderMinutesRange, step: 1, unit: .minutes),
        IntSettingSpec(id: "notifications.rateLimitPerTenMinutes", title: "At most",
                       help: "Anything beyond this is folded into one digest.",
                       keyPath: \.notifications.rateLimitPerTenMinutes, range: NotificationSettings.rateLimitPerTenMinutesRange,
                       step: 1, unit: .perTenMinutes),
    ]

    /// "Only after working at least": the picker's choices (seconds, label); a value set elsewhere that is
    /// not one of them is listed too, so the picker always shows the current value.
    static func minimumWorkChoices(current: Int) -> [(seconds: Int, label: String)] {
        var values = [0, 30, 60, 120, 300, 600, 900, 1800, 3600]
        if !values.contains(current) { values = (values + [current]).sorted() }
        return values.map { ($0, $0 == 0 ? "Every turn" : DurationText.settingSeconds($0)) }
    }

    /// Every numeric setting the UI edits (tests check each against `normalized()`).
    static var all: [IntSettingSpec] { [keepAwakeButton, awayIdle] + safety + timers + pausing + notifications }

    /// The plain-language pausing sentence (brief §6.2, spec card §9.9).
    static let pausingMemorySentence =
        "Pausing saves CPU and battery; it does not free memory unless you allow 'Quit when memory is low'."

    /// Fixed timers shown read-only.
    static func fixedTimers(_ timers: SessionTimers) -> [(title: String, value: String)] {
        [
            ("Settle after a turn ends", DurationText.settingSeconds(timers.settleSeconds)),
            ("Batch alerts for", DurationText.settingSeconds(timers.notifyBatchSeconds)),
            ("Activity needed to count as working", DurationText.settingSeconds(timers.heuristicSustainSeconds)),
            ("Disarm with the lid open after", DurationText.settingMinutes(timers.disarmLidOpenMinutes)),
            ("Forget ended sessions after", DurationText.settingMinutes(timers.endedRetentionMinutes)),
        ]
    }
}

// MARK: - Notification kinds

nonisolated enum NotificationKindText {
    /// Kinds the user can mute (the test message is never muted).
    static let mutable: [NotificationKind] = [
        .finished, .needsInput, .countdown, .wentQuiet, .stalled, .safetyTrip, .asleep, .shuttingDown, .commandIgnored, .warning,
    ]

    static func name(_ kind: NotificationKind) -> String {
        switch kind {
        case .finished: "An agent finished"
        case .needsInput: "An agent needs input"
        case .countdown: "Sleep countdown started"
        case .wentQuiet: "An agent without hooks went quiet"
        case .stalled: "An agent looks stuck"
        case .safetyTrip: "Safety sleep (battery, heat, network)"
        case .asleep: "The Mac slept (sent after waking)"
        case .shuttingDown: "Shutting down"
        case .commandIgnored: "A button tap was ignored"
        case .warning: "Warnings"
        case .test: "Test message"
        }
    }

    static func detailLevel(_ level: DetailLevel) -> String {
        switch level {
        case .private: "Private · \"An agent finished\""
        case .basic: "Basic · agent, project and duration"
        case .detailed: "Detailed · adds a short preview of the reply"
        }
    }
}

// MARK: - Quiet hours

nonisolated enum QuietHoursText {
    /// A date on `reference`'s day at `minute` after midnight (for the time pickers).
    static func date(fromMinute minute: Int, reference: Date, calendar: Calendar = .current) -> Date {
        let clamped = minute.clamped(to: QuietHours.minuteRange)
        let start = calendar.startOfDay(for: reference)
        return calendar.date(bySettingHour: clamped / 60, minute: clamped % 60, second: 0, of: start) ?? start
    }

    /// Minutes after local midnight for a picked time.
    static func minute(from date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return ((c.hour ?? 0) * 60 + (c.minute ?? 0)).clamped(to: QuietHours.minuteRange)
    }

    /// `23:00 – 07:00`.
    static func range(_ quiet: QuietHours) -> String {
        "\(clock(quiet.startMinute)) – \(clock(quiet.endMinute))"
    }

    static func clock(_ minute: Int) -> String {
        let m = minute.clamped(to: QuietHours.minuteRange)
        let h = m / 60
        let rest = m % 60
        return (h < 10 ? "0" : "") + "\(h):" + (rest < 10 ? "0" : "") + "\(rest)"
    }
}

// MARK: - Input validation

nonisolated enum BundleIDInput {
    /// `com.example.App`: letters, digits, `-` and `.`, at least one dot, no leading/trailing dot.
    static func normalize(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3, t.count <= 255, t.contains("."), !t.hasPrefix("."), !t.hasSuffix("."), !t.contains("..") else {
            return nil
        }
        let allowed = t.unicodeScalars.allSatisfy { scalar in
            (scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar))) || scalar == "-" || scalar == "."
        }
        return allowed ? t : nil
    }
}

/// Where a setting applies (the Notifications pane's section headers).
nonisolated enum SettingScope: Sendable, Hashable {
    case mac, phone, both

    var title: String {
        switch self {
        case .mac: "This Mac"
        case .phone: "iPhone"
        case .both: "Mac & iPhone"
        }
    }
}

/// The iPhone's "Send them" choices.
nonisolated enum PhoneTimingText {
    static func title(_ timing: PhoneAlertTiming) -> String {
        switch timing {
        case .lidClosed: "Only when the lid is closed"
        case .away: "When I'm away from the Mac"
        case .always: "Always"
        }
    }

    static func explanation(_ timing: PhoneAlertTiming) -> String {
        switch timing {
        case .lidClosed: "While you use the Mac with the lid open, alerts stay on the Mac. A Mac without a lid sends them once you're away."
        case .away: "Also with the lid open, once the screen locks or you stop using the Mac."
        case .always: "Every alert also goes to the iPhone, even while you're at the Mac."
        }
    }

    /// Onboarding's "Alerts reach it …": when alerts go to a connected iPhone (a Mac without a lid treats "lid
    /// closed" as away).
    static func phrase(_ timing: PhoneAlertTiming, hasLid: Bool = true) -> String {
        switch timing {
        case .lidClosed where !hasLid: "while you're away from the Mac"
        case .lidClosed: "while the lid is closed"
        case .away: "while you're away from the Mac"
        case .always: "always, also while you're at the Mac"
        }
    }

    /// The iPhone section's footnote: what ignores the timing, and what is set on the iPhone itself.
    static let footnote = "Tests, shutdowns, safety stops and replies to your iPhone taps always reach the iPhone. "
        + "Sounds, banners and Focus are set on the iPhone: Settings → Notifications → Kakureneko."

    /// The menu's note next to "Alerts on this Mac and your iPhone" (nil: nothing worth saying).
    static func menuNote(_ timing: PhoneAlertTiming) -> String? {
        switch timing {
        case .lidClosed: "iPhone only with the lid closed"
        case .away: "iPhone only when you're away"
        case .always: nil
        }
    }
}
