@testable import KakurenekoApp
import KakurenekoKit
import Foundation
import Testing

@MainActor
@Suite("Settings catalog and input validation", .timeLimit(.minutes(1)))
struct SettingsCatalogTests {
    /// Every UI range IS the Kit constant (never a copy).
    @Test func rangesAreTheKitConstants() {
        let expected: [String: ClosedRange<Int>] = [
            "power.keepAwakeButtonSeconds": PowerSettings.keepAwakeButtonSecondsRange,
            "safety.batteryFloorPercent": SafetySettings.batteryFloorPercentRange,
            "safety.minimumTimeToEmptyMinutes": SafetySettings.minimumTimeToEmptyMinutesRange,
            "safety.thermalSeriousSeconds": SafetySettings.thermalSeriousSecondsRange,
            "safety.networkOfflineMinutes": SafetySettings.networkOfflineMinutesRange,
            "safety.maxClosedLidHours": SafetySettings.maxClosedLidHoursRange,
            "timers.finishCountdownMinutes": SessionTimers.finishCountdownMinutesRange,
            "timers.needsInputCountdownMinutes": SessionTimers.needsInputCountdownMinutesRange,
            "timers.stallMinutes": SessionTimers.stallMinutesRange,
            "timers.heuristicExitMinutes": SessionTimers.heuristicExitMinutesRange,
            "pausing.lidCloseSettleSeconds": PauseSettings.lidCloseSettleSecondsRange,
            "pausing.userInputGraceSeconds": PauseSettings.userInputGraceSecondsRange,
            "pausing.recheckSeconds": PauseSettings.recheckSecondsRange,
            "pausing.throttleRescanSeconds": PauseSettings.throttleRescanSecondsRange,
            "pausing.maxPausedHours": PauseSettings.maxPausedHoursRange,
            "pausing.watchdogMinutes": PauseSettings.watchdogMinutesRange,
            "notifications.awayIdleSeconds": NotificationSettings.awayIdleSecondsRange,
            "notifications.rateLimitPerTenMinutes": NotificationSettings.rateLimitPerTenMinutesRange,
            "notifications.needsInputReminderMinutes": NotificationSettings.needsInputReminderMinutesRange,
        ]
        let catalog = Dictionary(uniqueKeysWithValues: SettingsCatalog.all.map { ($0.id, $0.range) })
        #expect(catalog == expected)
    }

    /// The UI clamps exactly like `normalized()`, and every key path edits the field its id names.
    @Test func uiClampMatchesNormalized() {
        for spec in SettingsCatalog.all {
            for probe in [spec.range.lowerBound - 1000, spec.range.upperBound + 1000, spec.range.lowerBound, spec.range.upperBound] {
                var settings = KakurenekoSettings.default
                settings[keyPath: spec.keyPath] = probe
                #expect(settings.normalized()[keyPath: spec.keyPath] == spec.clamp(probe), "\(spec.id) @ \(probe)")
            }
            // The default sits inside the range; steps are positive.
            #expect(spec.range.contains(KakurenekoSettings.default[keyPath: spec.keyPath]), "\(spec.id)")
            #expect(spec.step >= 1, "\(spec.id)")
            #expect(!spec.title.isEmpty)
        }
    }

    @Test func keyPathsAreDistinct() {
        let paths = SettingsCatalog.all.map(\.keyPath)
        #expect(Set(paths).count == paths.count)
        var settings = KakurenekoSettings.default
        settings[keyPath: SettingsCatalog.keepAwakeButton.keyPath] = 7200
        #expect(settings.power.keepAwakeButtonSeconds == 7200)
    }

    @Test func unitsFormatValues() {
        #expect(SettingUnit.seconds.format(45) == "45 s")
        #expect(SettingUnit.seconds.format(300) == "5 min")
        #expect(SettingUnit.seconds.format(3600) == "1 h")
        #expect(SettingUnit.seconds.format(90) == "1 min 30 s")
        #expect(SettingUnit.minutes.format(90) == "1 h 30 min")
        #expect(SettingUnit.hours.format(1) == "1 hour")
        #expect(SettingUnit.hours.format(12) == "12 hours")
        #expect(SettingUnit.percent.format(20) == "20 %")
        #expect(SettingUnit.perTenMinutes.format(6) == "6 per 10 min")
        #expect(SettingsCatalog.keepAwakeButton.rangeText == "5 min – 12 h")
    }

    @Test func pausingSentenceIsExact() {
        #expect(SettingsCatalog.pausingMemorySentence
            == "Pausing saves CPU and battery; it does not free memory unless you allow 'Quit when memory is low'.")
    }

    @Test func fixedTimersAreListed() {
        let fixed = SettingsCatalog.fixedTimers(SessionTimers())
        #expect(fixed.map(\.value) == ["5 s", "15 s", "20 s", "2 min", "10 min"])
    }

    @Test func mutableKindsExcludeTheTest() {
        #expect(!NotificationKindText.mutable.contains(.test))
        #expect(Set(NotificationKindText.mutable).count == NotificationKind.allCases.count - 1)
        for kind in NotificationKind.allCases { #expect(!NotificationKindText.name(kind).isEmpty) }
    }

    // MARK: Quiet hours

    @Test func quietHoursConversionsRoundTrip() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        for minute in [0, 59, 7 * 60, 23 * 60, 1439] {
            let date = QuietHoursText.date(fromMinute: minute, reference: fixedNow, calendar: calendar)
            #expect(QuietHoursText.minute(from: date, calendar: calendar) == minute)
        }
        #expect(QuietHoursText.minute(from: QuietHoursText.date(fromMinute: 5000, reference: fixedNow, calendar: calendar), calendar: calendar) == 1439)
        #expect(QuietHoursText.range(QuietHours()) == "23:00 – 07:00")
        #expect(QuietHoursText.clock(65) == "01:05")
    }

    @Test func bundleIdentifierInput() {
        #expect(BundleIDInput.normalize(" com.spotify.client ") == "com.spotify.client")
        #expect(BundleIDInput.normalize("com.todesktop.230313mzl4w4u92") == "com.todesktop.230313mzl4w4u92")
        #expect(BundleIDInput.normalize("Spotify") == nil)
        #expect(BundleIDInput.normalize(".com.x") == nil)
        #expect(BundleIDInput.normalize("com..x") == nil)
        #expect(BundleIDInput.normalize("com.x/../y") == nil)
        #expect(BundleIDInput.normalize("com.exämple.x") == nil)
    }
}
