import Darwin
import KakurenekoKit
import Foundation
import Testing

@Suite("KakurenekoSettings", .timeLimit(.minutes(1)))
struct SettingsTests {
    @Test func defaultsMatchDecisionsAndBrief() {
        let s = KakurenekoSettings.default
        #expect(s.version == KakurenekoSettings.currentVersion)
        // D1: battery allowed, 20 % floor, 12 h cap, 7 % root floor.
        #expect(s.safety.allowOnBattery)
        #expect(s.safety.batteryFloorPercent == 20)
        #expect(s.safety.maxClosedLidHours == 12)
        #expect(s.safety.hardFloorPercent == 7)
        #expect(s.safety.minimumTimeToEmptyMinutes == 25)
        #expect(s.safety.networkOfflineMinutes == 15)
        #expect(s.safety.thermalSeriousSeconds == 60)
        #expect(s.power.lidCloseSound == .onBattery)
        // D2: sleep by default, shutdown opt-in.
        #expect(s.power.endAction == .sleep)
        #expect(!s.power.shutdownEnabled)
        #expect(s.power.keepAwakeButtonSeconds == 3600)
        // N1/N2: native alerts on the Mac and the iPhone, also while the user is at the Mac; D4: Basic detail.
        #expect(s.notifications.macAlerts && s.notifications.phoneAlerts)
        #expect(s.notifications.phoneTiming == .lidClosed, "iPhone alerts only with the lid closed")
        #expect(s.notifications.minimumWorkSeconds == 0, "every finished turn alerts")
        #expect(s.notifications.detailLevel == .basic)
        #expect(s.notifications.awayIdleSeconds == 300)
        #expect(!s.notifications.quietHours.enabled)
        #expect(s.notifications.rateLimitPerTenMinutes == 6)
        #expect(!s.notifications.skipClaudeRemoteControlSessions)
        // D6 + §6: Throttle default, quit-on-low-memory off.
        #expect(s.pausing.enabled)
        #expect(s.pausing.mode == .throttle)
        #expect(!s.pausing.quitWhenMemoryLow)
        #expect(s.pausing.lidCloseSettleSeconds == 90)
        #expect(s.pausing.userInputGraceSeconds == 60)
        #expect(s.pausing.neverPauseBundleIDs.isEmpty)
        // §5.6 timers.
        #expect(s.timers.settle == 5)
        #expect(s.timers.notifyBatch == 15)
        #expect(s.timers.finishCountdown == 5 * 60)
        #expect(s.timers.needsInputCountdown == 10 * 60)
        #expect(s.timers.stall == 20 * 60)
        #expect(s.timers.heuristicExit == 5 * 60)
        #expect(s.timers.heuristicSustain == 20)
        #expect(s.timers.disarmLidOpen == 2 * 60)
        // General.
        #expect(s.general.enabled)
        #expect(!s.general.launchAtLogin)
        #expect(!s.general.dryRun)
        #expect(!s.general.onboardingCompleted)
    }

    @Test func codableRoundTrip() throws {
        var s = KakurenekoSettings.default
        s.safety.batteryFloorPercent = 35
        s.power.endAction = .shutdown
        s.pausing.mode = .freeze
        s.pausing.neverPauseBundleIDs = ["com.spotify.client", "com.tinyspeck.slackmacgap"]
        s.notifications.detailLevel = .private
        s.notifications.mutedKinds = [.stalled, .asleep]
        s.notifications.quietHours = QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 6 * 60)
        s.integrations.dismissedAgents = [.aider, .cursor]
        let data = try KakurenekoJSON.encode(s)
        let decoded = try KakurenekoJSON.decode(KakurenekoSettings.self, from: data)
        #expect(decoded == s)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"detailLevel\" : \"private\""))
        #expect(text.contains("\"mutedKinds\" : ["))
    }

    @Test func tolerantDecodingFillsDefaults() throws {
        let json = #"""
        {"version": 1,
         "safety": {"batteryFloorPercent": 30, "allowOnBattery": "not-a-bool", "futureKey": 1},
         "pausing": {"mode": "hibernate"},
         "notifications": {"mutedKinds": ["finished", "nonsense"]},
         "integrations": {"dismissedAgents": ["codex", "agent-from-the-future"]},
         "unknownSection": {"x": 1}}
        """#
        let s = try KakurenekoJSON.decode(KakurenekoSettings.self, from: Data(json.utf8))
        #expect(s.safety.batteryFloorPercent == 30)
        #expect(s.safety.allowOnBattery == true) // wrong type → default
        #expect(s.pausing.mode == .throttle) // unknown enum → default
        #expect(s.notifications.mutedKinds == [.finished])
        #expect(s.integrations.dismissedAgents == [.codex])
        #expect(s.power == PowerSettings()) // missing section → defaults
        #expect(s.timers == SessionTimers())
    }

    @Test func minimumWorkSecondsRoundTripsAndClamps() throws {
        var s = KakurenekoSettings.default
        s.notifications.minimumWorkSeconds = 300
        #expect(try KakurenekoJSON.decode(KakurenekoSettings.self, from: KakurenekoJSON.encode(s)).notifications.minimumWorkSeconds == 300)
        s.notifications.minimumWorkSeconds = -5
        #expect(s.normalized().notifications.minimumWorkSeconds == 0)
        s.notifications.minimumWorkSeconds = 99_999
        #expect(s.normalized().notifications.minimumWorkSeconds == NotificationSettings.minimumWorkSecondsRange.upperBound)
    }

    @Test func phoneTimingRoundTripsAndComesFromTheSettingsItReplaced() throws {
        for timing in PhoneAlertTiming.allCases {
            var s = KakurenekoSettings.default
            s.notifications.phoneTiming = timing
            let data = try KakurenekoJSON.encode(s)
            #expect(try KakurenekoJSON.decode(KakurenekoSettings.self, from: data).notifications.phoneTiming == timing)
            let text = String(decoding: data, as: UTF8.self)
            #expect(!text.contains("presenceGating") && !text.contains("phoneOnlyWhenLidClosed"), "replaced keys are not written")
        }
        func legacy(_ notifications: String) throws -> PhoneAlertTiming {
            try KakurenekoJSON.decode(KakurenekoSettings.self, from: Data(#"{"version": 2, "notifications": {\#(notifications)}}"#.utf8))
                .normalized().notifications.phoneTiming
        }
        #expect(try legacy(#""phoneAlerts": true"#) == .lidClosed, "neither key: the default")
        #expect(try legacy(#""phoneOnlyWhenLidClosed": true, "presenceGating": "awayOnly""#) == .lidClosed)
        #expect(try legacy(#""phoneOnlyWhenLidClosed": false, "presenceGating": "always""#) == .always)
        #expect(try legacy(#""phoneOnlyWhenLidClosed": false, "presenceGating": "awayOnly""#) == .away)
        #expect(try legacy(#""presenceGating": "awayOnly""#) == .away, "a v2 user who chose away only")
        #expect(try legacy(#""phoneTiming": "bogus", "presenceGating": "awayOnly""#) == .away, "unreadable: derived")
    }

    @Test func lidCloseSoundRoundTripsAndComesFromTheSwitchItReplaced() throws {
        for sound in LidCloseSound.allCases {
            var s = KakurenekoSettings.default
            s.power.lidCloseSound = sound
            let data = try KakurenekoJSON.encode(s)
            #expect(try KakurenekoJSON.decode(KakurenekoSettings.self, from: data).power.lidCloseSound == sound)
            #expect(!String(decoding: data, as: UTF8.self).contains("lidCloseChimeOnBattery"), "the replaced key is not written")
        }
        func legacy(_ power: String) throws -> LidCloseSound {
            try KakurenekoJSON.decode(KakurenekoSettings.self, from: Data(#"{"version": 2, "power": {\#(power)}}"#.utf8)).power.lidCloseSound
        }
        #expect(try legacy(#""endAction": "sleep""#) == .onBattery, "neither key: the default")
        #expect(try legacy(#""lidCloseChimeOnBattery": true"#) == .onBattery)
        #expect(try legacy(#""lidCloseChimeOnBattery": false"#) == .off)
        #expect(try legacy(#""lidCloseSound": "always", "lidCloseChimeOnBattery": false"#) == .always, "the new key wins")
        #expect(try legacy(#""lidCloseSound": "bogus", "lidCloseChimeOnBattery": false"#) == .off, "unreadable: derived")
    }

    @Test func lidCloseSoundPlaysPerPowerSource() {
        #expect(!LidCloseSound.off.plays(onBattery: true) && !LidCloseSound.off.plays(onBattery: false))
        #expect(LidCloseSound.onBattery.plays(onBattery: true) && !LidCloseSound.onBattery.plays(onBattery: false))
        #expect(LidCloseSound.always.plays(onBattery: true) && LidCloseSound.always.plays(onBattery: false))
    }

    @Test func normalizedClampsRanges() {
        var s = KakurenekoSettings.default
        s.safety.batteryFloorPercent = 3
        s.safety.maxClosedLidHours = 99
        s.timers.finishCountdownMinutes = 0
        s.timers.needsInputCountdownMinutes = 500
        s.timers.settleSeconds = 60
        s.pausing.neverPauseBundleIDs = ["b", "a", "b", ""]
        let n = s.normalized()
        #expect(n.safety.batteryFloorPercent == 10)
        #expect(n.safety.maxClosedLidHours == 24)
        #expect(n.timers.finishCountdownMinutes == 1)
        #expect(n.timers.needsInputCountdownMinutes == 120)
        #expect(n.timers.settleSeconds == 5) // fixed
        #expect(n.pausing.neverPauseBundleIDs == ["a", "b"])
    }

    @Test func loadAndSaveFile() throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        // Missing → defaults.
        #expect(KakurenekoSettings.load(from: paths.settingsFile) == KakurenekoSettings.default.normalized())
        var s = KakurenekoSettings.default
        s.general.onboardingCompleted = true
        try s.save(to: paths.settingsFile)
        var st = stat()
        #expect(stat(paths.settingsFile.path(percentEncoded: false), &st) == 0)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect(KakurenekoSettings.load(from: paths.settingsFile).general.onboardingCompleted)
        // Corrupt → defaults.
        try Data("{not json".utf8).write(to: paths.settingsFile)
        #expect(KakurenekoSettings.load(from: paths.settingsFile) == KakurenekoSettings.default.normalized())
    }

    @Test func quietHoursWindow() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func at(_ h: Int, _ m: Int) -> Date { utc.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: h, minute: m))! }
        let overnight = QuietHours(enabled: true, startMinute: 23 * 60, endMinute: 7 * 60)
        let tz = TimeZone(identifier: "UTC")!
        #expect(overnight.contains(at(23, 30), timeZone: tz))
        #expect(overnight.contains(at(3, 0), timeZone: tz))
        #expect(!overnight.contains(at(12, 0), timeZone: tz))
        #expect(!overnight.contains(at(7, 0), timeZone: tz))
        let disabled = QuietHours(enabled: false)
        #expect(!disabled.contains(at(3, 0), timeZone: tz))
    }

    @Test func presenceAway() {
        #expect(Presence(lidClosed: true, screenLocked: false, secondsSinceUserInput: 0).isAway())
        #expect(Presence(lidClosed: false, screenLocked: true, secondsSinceUserInput: 0).isAway())
        #expect(Presence(lidClosed: false, screenLocked: false, secondsSinceUserInput: 301).isAway())
        #expect(!Presence(lidClosed: false, screenLocked: false, secondsSinceUserInput: 10).isAway())
    }
}
