// The demo (Model/Demo.swift): its store runs on its own in-memory iCloud and recording notification center, the
// simulated Mac answers the buttons and keeps its status fresh, and DemoMode starts and ends it without touching the
// real store. Also the website links derived from the Info.plist (Model/WebsiteLinks.swift).

import KakurenekoCloud
import Foundation
import Testing

@MainActor
@Suite("Demo")
struct DemoTests {
    let studio = DemoFixtures.studioID

    /// A prepared demo on a hand-advanced clock (discarded by the caller).
    func demo(_ scenario: DemoFixtures.Scenario = .oneMac, clock: ManualClock = ManualClock()) async -> DemoEnvironment {
        let demo = DemoEnvironment(scenario, clock: clock.phoneClock)
        await demo.prepare()
        return demo
    }

    func commands(in demo: DemoEnvironment) async -> [CloudCommand] {
        await demo.cloud.items(ofType: CloudSchema.RecordType.command).compactMap {
            if case .command(let command) = $0 { command } else { nil }
        }
    }

    @Test func theDemoShowsASampleMacPastOnboarding() async {
        let demo = await demo()
        defer { demo.discard() }
        #expect(demo.store.hasCompletedOnboarding)
        #expect(demo.store.account == .available)
        #expect(demo.store.macs.map(\.macID) == [studio])
        #expect(demo.store.alerts.count == DemoFixtures.alerts(now: Date()).count)
        let status = demo.store.status(for: studio)
        #expect(status?.agents.contains { $0.activity == .waiting } == true, "the demo shows an agent waiting for you")
        #expect(status.map { demo.store.presentation(of: $0).canSleep } == true, "and working buttons")
    }

    @Test func aDemoCommandGoesToTheDemosInMemoryCloudOnly() async throws {
        // A real install alongside: its cloud and notification center must hear nothing from the demo.
        let real = Harness()
        try await real.macSaves(.status(Fixture.status(updatedAt: real.clock.now)))
        let realStore = real.makeStore()
        await realStore.sync()
        await real.cloud.clearOperations()
        let categoriesBefore = real.notifications.registeredCategories.count

        let demo = await demo()
        defer { demo.discard() }
        await demo.store.keepAwake(macID: studio)
        await demo.store.sleepNow(macID: studio)

        let sent = await commands(in: demo).map(\.request.wireValue).sorted()
        #expect(sent == ["keepawake:3600", "sleep"], "both commands are in the demo's iCloud")
        #expect(demo.store.pendingCommands.isEmpty)
        #expect(await real.cloud.operations.isEmpty, "the real store's iCloud saw nothing")
        #expect(await real.commands().isEmpty)
        #expect(real.notifications.registeredCategories.count == categoriesBefore)
        #expect(real.notifications.posted.isEmpty)
        #expect(realStore.macs.map(\.macID) == ["mac-1"], "the real store still shows the real Mac")
    }

    @Test func theDemosNotificationsAreRecordedNotShown() async {
        let clock = ManualClock()
        let demo = await demo(clock: clock)
        defer { demo.discard() }
        #expect(!demo.notifications.registeredCategories.isEmpty, "the categories went to the demo's fake center")

        let expired = AlertPresentation.ButtonTap(request: .sleepNow, alertID: "a-1", macID: studio, stateVersion: 12,
                                                  expiresAt: clock.now.addingTimeInterval(-1))
        #expect(await demo.store.handleButtonTap(expired, macName: "Studio") == .expired)
        #expect(demo.notifications.posted.map(\.identifier) == [LocalNotice.expiredAlert(macID: studio, macName: "Studio").identifier])
    }

    @Test func theSimulatedMacAnswersKeepAwake() async throws {
        let clock = ManualClock()
        let demo = await demo(clock: clock)
        defer { demo.discard() }
        let before = try #require(demo.store.status(for: studio))
        await demo.store.keepAwake(macID: studio)
        clock.advance(2)

        #expect(await demo.answerCommands())
        await demo.store.sync(force: true)
        #expect(await commands(in: demo).isEmpty, "the Mac deletes the commands it handled")
        let after = try #require(demo.store.status(for: studio))
        #expect(after.stateVersion == before.stateVersion + 1)
        #expect(after.keepAwakeUntil == clock.now.addingTimeInterval(TimeInterval(before.keepAwakeSeconds)))
        #expect(demo.store.feedback[FeedbackSlot(macID: studio, channel: .controls)]?.phase == .done)
    }

    @Test func sleepNowPutsTheSampleMacToSleep() async throws {
        let demo = await demo()
        defer { demo.discard() }
        await demo.store.sleepNow(macID: studio)
        await demo.answerCommands()
        await demo.store.sync(force: true)
        let status = try #require(demo.store.status(for: studio))
        #expect(status.phase == .asleep)
        #expect(status.agents.isEmpty)
        #expect(!demo.store.presentation(of: status).canSleep)
    }

    @Test func keepAwakeEndsTheCountdown() async throws {
        let demo = await demo(.countdown)
        defer { demo.discard() }
        #expect(demo.store.presentation(of: try #require(demo.store.status(for: studio))).countdownEnd != nil)
        await demo.store.keepAwake(macID: studio)
        await demo.answerCommands()
        await demo.store.sync(force: true)
        let status = try #require(demo.store.status(for: studio))
        #expect(status.phase == .lidClosedAwake)
        #expect(status.countdownEndsAt == nil)
        #expect(demo.store.presentation(of: status).keepAwakeUntil != nil)
    }

    @Test func aTestAlertShowsUpInActivity() async {
        let demo = await demo()
        defer { demo.discard() }
        let count = demo.store.alerts.count
        await demo.store.sendTestAlert()
        await demo.answerCommands()
        await demo.store.sync(force: true)
        #expect(demo.store.alerts.count == count + 1)
        #expect(demo.store.alerts.first?.kind == AlertKind.test)
    }

    @Test func theSampleMacKeepsItsStatusFreshAndItsCountdownRunsOut() async throws {
        let clock = ManualClock()
        let working = await demo(clock: clock)
        defer { working.discard() }
        for _ in 0..<30 { // 15 minutes, longer than a Mac may stay silent
            clock.advance(30)
            await working.tick()
        }
        let status = try #require(working.store.status(for: studio))
        #expect(status.updatedAt == clock.now)
        #expect(!working.store.presentation(of: status).isStale)

        let countdownClock = ManualClock()
        let countdown = await demo(.countdown, clock: countdownClock)
        defer { countdown.discard() }
        countdownClock.advance(300)
        await countdown.tick()
        #expect(countdown.store.status(for: studio)?.phase == .asleep)
    }

    @Test func demoModeStartsAndEndsWithoutTouchingTheRealStore() async throws {
        let real = Harness()
        try await real.macSaves(.status(Fixture.status(updatedAt: real.clock.now)))
        let realStore = real.makeStore()
        await realStore.sync()
        realStore.selectedTab = .activity

        let mode = DemoMode(device: real.device)
        #expect(!mode.isActive)
        mode.start()
        let session = try #require(mode.session)
        #expect(mode.isActive)
        #expect(session.store !== realStore)
        mode.start()
        #expect(mode.session === session, "starting twice keeps the running demo")
        await session.prepare()
        await session.store.keepAwake(macID: studio)

        await mode.end().value
        #expect(!mode.isActive)
        #expect(mode.session == nil)
        #expect(!FileManager.default.fileExists(atPath: session.cacheDirectory.path()), "the demo's cache is gone")
        #expect(UserDefaults.standard.persistentDomain(forName: DemoMode.defaultsSuite)?.isEmpty ?? true)
        #expect(realStore.selectedTab == .activity)
        #expect(realStore.macs.map(\.macID) == ["mac-1"])
        #expect(await real.commands().isEmpty)
    }
}

@Suite("Website links")
struct WebsiteLinksTests {
    @Test(arguments: [nil, "", "  ", "$(KAKURENEKO_WEBSITE_URL)", "example.org", "ftp://example.org", "https://",
                      "https://example.org/?a=1"] as [String?])
    func aMissingOrMalformedValueFallsBackToTheProductWebsite(_ value: String?) {
        let links = WebsiteLinks(infoValue: value)
        #expect(links.home == WebsiteLinks.fallback)
        #expect(links.home.absoluteString == "https://kakureneko.com/")
        #expect(links.privacyPolicy.absoluteString == "https://kakureneko.com/privacy/")
        #expect(links.support.absoluteString == "https://kakureneko.com/support/")
    }

    @Test func pagesHangOffTheWebsite() {
        let links = WebsiteLinks(infoValue: "https://example.org")
        #expect(links.home.absoluteString == "https://example.org/")
        #expect(links.privacyPolicy.absoluteString == "https://example.org/privacy/")
        #expect(links.support.absoluteString == "https://example.org/support/")

        let nested = WebsiteLinks(infoValue: "https://example.com/kakureneko/")
        #expect(nested.home.absoluteString == "https://example.com/kakureneko/")
        #expect(nested.privacyPolicy.absoluteString == "https://example.com/kakureneko/privacy/")
    }

    @Test func aNonStringValueFallsBack() {
        #expect(WebsiteLinks(infoValue: 42).home == WebsiteLinks.fallback)
    }
}
