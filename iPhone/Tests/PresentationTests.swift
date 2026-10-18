// Presentation rules: stale / dormant Macs, countdown and keep-awake times, phase pills, battery, alert icons,
// Activity days, feedback sentences, the cache file and the sync backoff.

import KakurenekoCloud
import Foundation
import Testing

@Suite("Presentation")
struct PresentationTests {
    let now = Fixture.t0

    @Test func aSilentMacIsNotResponding() {
        let fresh = MacStatusPresentation(status: Fixture.status(updatedAt: now.addingTimeInterval(-60)), now: now)
        #expect(!fresh.isStale)
        #expect(fresh.phaseStyle == PhaseStyle(.working))
        #expect(fresh.canSleep && fresh.canKeepAwake)

        let silent = MacStatusPresentation(status: Fixture.status(updatedAt: now.addingTimeInterval(-MacStatus.staleAfter - 1),
                                                                  shutdownEnabled: true), now: now)
        #expect(silent.isStale)
        #expect(silent.phaseStyle == .notResponding)
        #expect(!silent.canSleep && !silent.canShutDown, "never sleep or shut down a Mac that does not answer")
        #expect(silent.canKeepAwake)
        #expect(silent.showsShutDown)
    }

    @Test func dormantMacsAreNeverStaleAndOfferNoButtons() {
        for phase in [MacPhase.asleep, .shutDown, .off] {
            let p = MacStatusPresentation(status: Fixture.status(phase: phase, updatedAt: now.addingTimeInterval(-86400),
                                                                 shutdownEnabled: true), now: now)
            #expect(!p.isStale && p.isDormant, "\(phase)")
            #expect(p.phaseStyle == PhaseStyle(phase))
            #expect(!p.canKeepAwake && !p.canSleep && !p.canShutDown, "\(phase)")
        }
    }

    @Test func countdownAndKeepAwakeOnlyWhileRunning() {
        let running = MacStatusPresentation(status: Fixture.status(phase: .countdown, updatedAt: now,
                                                                   keepAwakeUntil: now.addingTimeInterval(600),
                                                                   countdownEndsAt: now.addingTimeInterval(120)), now: now)
        #expect(running.countdownEnd == now.addingTimeInterval(120))
        #expect(running.countdownLabel == "Sleeps in")
        #expect(running.keepAwakeUntil == now.addingTimeInterval(600))

        let later = MacStatusPresentation(status: running.status, now: now.addingTimeInterval(121))
        #expect(later.countdownEnd == nil)
        #expect(later.keepAwakeUntil != nil)
        let muchLater = MacStatusPresentation(status: running.status, now: now.addingTimeInterval(601))
        #expect(muchLater.keepAwakeUntil == nil)

        let shutdown = MacStatusPresentation(status: Fixture.status(phase: .shutdownPending, updatedAt: now,
                                                                    countdownEndsAt: now.addingTimeInterval(3600)), now: now)
        #expect(shutdown.countdownLabel == "Shuts down in")
        let stale = MacStatusPresentation(status: shutdown.status, now: now.addingTimeInterval(MacStatus.staleAfter + 1))
        #expect(stale.countdownEnd == nil, "a silent Mac's countdown means nothing")
    }

    @Test func everyPhaseHasItsOwnPill() {
        let styles = MacPhase.allCases.map(PhaseStyle.init)
        #expect(Set(styles.map(\.title)).count == MacPhase.allCases.count)
        #expect(styles.allSatisfy { !$0.symbol.isEmpty })
        #expect(!styles.contains(.notResponding))
    }

    /// The design language's state set (DESIGN.md §2.1): awake is amber, the countdown violet, asleep indigo, a
    /// silent Mac red; pills read as sentences.
    @Test func pillsUseTheDesignStates() {
        #expect(PhaseStyle(.lidClosedAwake).tint == .working)
        #expect(PhaseStyle(.lidClosedAwake).title == "Awake, lid closed")
        #expect(PhaseStyle(.working).tint == .working)
        #expect(PhaseStyle(.countdown).tint == .drowsy)
        #expect(PhaseStyle(.countdown).title == "Sleeping soon")
        #expect(PhaseStyle(.asleep).tint == .asleep)
        #expect(PhaseStyle(.shutdownPending).tint == .critical)
        #expect(PhaseStyle(.idle).tint == .idle)
        #expect(PhaseStyle.notResponding.tint == .critical)
        #expect(AgentActivityStyle(.waiting).tint == .waiting)
        #expect(AlertKindStyle(kind: AlertKind.needsInput).tint == .waiting)
        #expect(AlertKindStyle(kind: AlertKind.countdown).tint == .drowsy)
        #expect(AlertKindStyle(kind: AlertKind.finished).tint == .finished)
    }

    /// Soot beside the status: hiding with the lid closed, waving when an agent waits, asleep when the Mac is; none
    /// during a countdown or for a silent Mac. The buttons come first during a countdown.
    @Test func thePoseFollowsTheMac() {
        func pose(_ phase: MacPhase, agents: [AgentSummary.Activity] = [.working], keepAwake: Bool = false,
                  updatedAt: Date? = nil) -> String? {
            var status = Fixture.status(phase: phase, updatedAt: updatedAt ?? now,
                                        keepAwakeUntil: keepAwake ? now.addingTimeInterval(600) : nil)
            status.agents = agents.map { AgentSummary(agent: "Codex", project: nil, host: nil, activity: $0, since: now) }
            return MacStatusPresentation(status: status, now: now).poseName
        }
        #expect(pose(.lidClosedAwake) == "hide")
        #expect(pose(.working) == "sit")
        #expect(pose(.lidClosedAwake, agents: [.working, .waiting]) == "wave")
        #expect(pose(.lidClosedAwake, agents: [.finished], keepAwake: true) == "coffee")
        #expect(pose(.asleep) == "sleep")
        #expect(pose(.idle, agents: []) == "sleep")
        #expect(pose(.countdown) == nil)
        #expect(pose(.off) == nil)
        #expect(pose(.lidClosedAwake, updatedAt: now.addingTimeInterval(-MacStatus.staleAfter - 1)) == nil)

        let counting = MacStatusPresentation(status: Fixture.status(phase: .countdown, updatedAt: now,
                                                                    countdownEndsAt: now.addingTimeInterval(120)), now: now)
        #expect(counting.controlsFirst)
        #expect(!MacStatusPresentation(status: Fixture.status(updatedAt: now), now: now).controlsFirst)
    }

    @Test func battery() {
        #expect(BatteryPresentation(percent: 81, onBattery: true).symbol == "battery.75percent")
        #expect(BatteryPresentation(percent: 81, onBattery: true).text == "81%, on battery")
        #expect(BatteryPresentation(percent: 5, onBattery: true).symbol == "battery.0percent")
        #expect(BatteryPresentation(percent: 100, onBattery: true).symbol == "battery.100percent")
        #expect(BatteryPresentation(percent: 40, onBattery: false).symbol == "battery.100percent.bolt")
        #expect(BatteryPresentation(percent: 40, onBattery: false).accessibilityLabel == "Battery 40 percent, plugged in")
        #expect(BatteryPresentation(percent: nil, onBattery: false).text == "Power adapter")
    }

    @Test func everyAlertKindHasAnIcon() {
        let kinds = [AlertKind.finished, AlertKind.needsInput, AlertKind.countdown, AlertKind.wentQuiet, AlertKind.stalled,
                     AlertKind.safetyTrip, AlertKind.asleep, AlertKind.shuttingDown, AlertKind.commandIgnored, AlertKind.warning,
                     AlertKind.test]
        let styles = kinds.map(AlertKindStyle.init(kind:))
        let fallback = AlertKindStyle(kind: "somethingNew")
        #expect(Set(styles.map(\.symbol)).count == kinds.count)
        #expect(!styles.contains(fallback))
        #expect(fallback.symbol == "bell.fill")
    }

    @Test func activityIsGroupedByDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let midnight = calendar.startOfDay(for: now)
        let alerts = [
            Fixture.alert("yesterday", createdAt: midnight.addingTimeInterval(-60)),
            Fixture.alert("today-early", createdAt: midnight.addingTimeInterval(60)),
            Fixture.alert("today-late", createdAt: midnight.addingTimeInterval(3600)),
        ]
        let days = ActivityDay.group(alerts, calendar: calendar)
        #expect(days.map(\.day) == [midnight, midnight.addingTimeInterval(-86400)])
        #expect(days.map { $0.alerts.map(\.id) } == [["today-late", "today-early"], ["yesterday"]])
    }

    @Test func feedbackSentences() {
        func line(_ phase: CommandFeedback.Phase, _ request: CloudRequest = .sleepNow) -> String {
            CommandFeedback(commandID: "c", request: request, phase: phase, issuedAt: now, changedAt: now, baseline: nil)
                .message(macName: "Studio")
        }
        #expect(line(.sent) == "Sent. Waiting for Studio…")
        #expect(line(.done) == "Studio is going to sleep.")
        #expect(line(.done, .shutDown) == "Studio is shutting down.")
        #expect(line(.noResponse) == "Studio didn't respond. It may be asleep or offline.")
        #expect(line(.ignored("It is busy again.")) == "Studio ignored it. It is busy again.")
        #expect(line(.queued) == "Couldn't reach iCloud. Kakureneko will send it when you're back online.")
    }

    /// The product is Kakureneko wherever a person reads its name (the identifiers keep "kakureneko").
    @Test @MainActor func theAppCallsItselfKakureneko() {
        #expect(PhaseStyle(.off).title == "Kakureneko off")
        #expect(LocalNotice.couldNotReach(macID: "m", macName: "Studio").body == "Open Kakureneko to retry.")
        #expect(LocalNotice.expiredAlert(macID: "m", macName: "Studio").body == "Open Kakureneko to see what Studio is doing now.")
        let testAlert = DemoFixtures.alerts(now: now).first { $0.kind == AlertKind.test }
        #expect(testAlert?.body == "Kakureneko on Studio can reach this iPhone.")
    }

    @Test func backoffDoublesUpToFiveMinutesAndHonoursHints() {
        var backoff = RetryBackoff()
        #expect((0..<8).map { _ in backoff.nextDelay(hint: nil) } == [5, 10, 20, 40, 80, 160, 300, 300])
        backoff.reset()
        #expect(backoff.nextDelay(hint: 30) == 30)
        #expect(backoff.nextDelay(hint: 1) == 10)
    }

    @Test func anUnreadableCacheStartsFresh() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PhoneCacheFile(directory: directory)
        #expect(file.load() == PhoneCache())

        var cache = PhoneCache()
        cache.statuses = [Fixture.status(updatedAt: now)]
        cache.changeToken = CloudChangeToken(data: Data([1, 2, 3]))
        try file.save(cache)
        #expect(file.load() == cache)

        try Data("not json".utf8).write(to: file.url)
        #expect(file.load() == PhoneCache())

        cache.version = PhoneCache.currentVersion + 1
        try file.save(cache)
        #expect(file.load() == PhoneCache(), "a newer app's cache is not misread")
    }
}
