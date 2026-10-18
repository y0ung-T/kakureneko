import KakurenekoCloud
@testable import KakurenekoNotify
import KakurenekoKit
import Foundation
import Testing

/// The iCloud side of the dispatcher (docs/NATIVE-NOTIFICATIONS.md §4): setup, change fetches (push + polling),
/// phone commands (validation, replay, deletion), Mac notification buttons, phones, the Mac's status, pruning.
@Suite("iCloud sync", .timeLimit(.minutes(1)))
struct CloudSyncTests {
    func report(_ phase: MacPhase = .working, headline: String = "1 agent working", sv: Int = 42) -> MacStatusReport {
        MacStatusReport(phase: phase, headline: headline, agents: [AgentSummary(agent: "Claude Code", project: "api", activity: .working)],
                        batteryPercent: 80, onBattery: true, stateVersion: sv, keepAwakeSeconds: 3600, canSleep: true)
    }

    func phone(_ id: String = "p1", seen: Date = Fixtures.start, authorized: Bool = true) -> PhoneDevice {
        PhoneDevice(deviceID: id, name: "iPhone", model: "iPhone18,3", systemVersion: "26.6.1", appVersion: "0.1.0",
                    alertsAuthorized: authorized, timeSensitiveAllowed: true, lastSeenAt: seen)
    }

    // MARK: Setup

    @Test func startSetsUpTheZoneAndTheZoneSubscription() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        #expect(await h.cloud?.zoneExists == true)
        #expect(await h.cloud?.subscriptions == [.macInbox])
        #expect(await h.dispatcher.status().iCloud == .available)
        await h.dispatcher.stop()
    }

    @Test func aFreshDevelopmentSchemaIsBootstrapped() async throws {
        let cloud = InMemoryCloudStore()
        await cloud.setRequiresSchemaBootstrap(true)
        let h = try Harness(cloud: cloud)
        defer { h.cleanup() }
        try await h.startReady()
        #expect(await cloud.subscriptions == [.macInbox])
        #expect(await cloud.allItems.isEmpty, "the placeholders are gone again")
        await h.dispatcher.stop()
    }

    @Test func withoutAnAccountAlertsStayOnTheMacAndICloudIsCheckedAgain() async throws {
        let cloud = InMemoryCloudStore(account: .noAccount)
        let h = try Harness(cloud: cloud)
        defer { h.cleanup() }
        await h.dispatcher.start()
        #expect(await eventually { await h.dispatcher.status().iCloud == .noAccount })
        _ = await h.dispatcher.submit(.stalled(SessionEffect(kind: .stalled, session: Fixtures.claude(), at: Fixtures.start)),
                                      context: Fixtures.context())
        #expect(await eventually { h.posted.count == 1 })
        #expect(await h.dispatcher.status().outboxCount == 0, "nothing queues for an iCloud that is known to be missing")
        await cloud.setAccount(.available)
        #expect(await happensBy(h.clock, within: .seconds(600)) { await h.dispatcher.cloudReadyForTesting })
        #expect(await h.dispatcher.status().iCloud == .available)
        await h.dispatcher.stop()
    }

    @Test func aDeletedZoneIsSetUpAgain() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        await h.cloud?.deleteZone()
        await h.dispatcher.cloudDidNotify()
        #expect(await eventually { await !h.dispatcher.cloudReadyForTesting })
        #expect(await happensBy(h.clock, within: .seconds(30)) { await h.dispatcher.cloudReadyForTesting })
        #expect(await h.cloud?.zoneExists == true)
        await h.dispatcher.stop()
    }

    @Test func anExpiredChangeTokenFetchesEverythingAgain() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        let collector = CommandCollector(h.dispatcher.remoteCommands())
        await h.cloud?.failNext(.fetchChanges, with: .changeTokenExpired)
        try await h.phoneCommand(.keepAwake(seconds: 1800), sv: nil)
        await h.dispatcher.cloudDidNotify()
        #expect(await eventually { collector.kinds == [.keepAwake(seconds: 1800)] })
        await h.dispatcher.stop()
    }

    // MARK: Phone commands

    @Test func phoneCommandsRunOnceAndAreDeleted() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        let collector = CommandCollector(h.dispatcher.remoteCommands())
        let command = try await h.phoneCommand(.sleepNow, sv: 42)
        await h.dispatcher.cloudDidNotify()
        #expect(await eventually { collector.commands.count == 1 })
        let received = try #require(collector.commands.first)
        #expect(received.kind == .sleep)
        #expect(received.stateVersion == 42)
        #expect(received.commandID == command.id)
        #expect(received.source == .phone(name: "iPhone"))
        #expect(await eventually { await h.cloud?.contains(.command(command.id)) == false })
        #expect(await h.dispatcher.status().lastCommandAt == h.clock.now())
        // The same command again (a retried save on the phone): never executed twice.
        try await h.cloud?.save([.command(command)])
        await h.dispatcher.cloudDidNotify()
        #expect(await eventually { await h.cloud?.contains(.command(command.id)) == false })
        #expect(collector.commands.count == 1)
        await h.dispatcher.stop()
    }

    @Test func theReplayCacheSurvivesARelaunch() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        let command = try await h.phoneCommand(.keepAwake(seconds: 3600), sv: nil)
        await h.dispatcher.cloudDidNotify()
        #expect(await eventually { await h.cloud?.contains(.command(command.id)) == false })
        await h.dispatcher.stop()
        let relaunched = h.relaunch()
        let collector = CommandCollector(relaunched.remoteCommands())
        try await h.cloud?.save([.command(command)])
        await relaunched.start()
        #expect(await eventually { await h.cloud?.contains(.command(command.id)) == false })
        await settle()
        #expect(collector.commands.isEmpty)
        await relaunched.stop()
    }

    @Test func invalidCommandsAreDeletedWithoutRunning() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        let collector = CommandCollector(h.dispatcher.remoteCommands())
        let expired = try await h.phoneCommand(.sleepNow, issuedAt: Fixtures.start.addingTimeInterval(-700), lifetime: 600)
        let tooOld = try await h.phoneCommand(.keepAwake(seconds: 60), sv: nil, issuedAt: Fixtures.start.addingTimeInterval(-3600), lifetime: 7200)
        let future = try await h.phoneCommand(.shutDown, issuedAt: Fixtures.start.addingTimeInterval(600))
        let noSV = try await h.phoneCommand(.sleepNow, sv: nil)
        await h.dispatcher.cloudDidNotify()
        for id in [expired.id, tooOld.id, future.id, noSV.id] {
            #expect(await eventually { await h.cloud?.contains(.command(id)) == false })
        }
        await settle()
        #expect(collector.commands.isEmpty)
        await h.dispatcher.stop()
    }

    @Test func aTapThatArrivesTooLateIsAnsweredOnce() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        _ = try await h.phoneCommand(.sleepNow, issuedAt: Fixtures.start.addingTimeInterval(-700), lifetime: 600)
        _ = try await h.phoneCommand(.keepAwake(seconds: 60), issuedAt: Fixtures.start.addingTimeInterval(-650), lifetime: 600)
        _ = try await h.phoneCommand(.refreshStatus, issuedAt: Fixtures.start.addingTimeInterval(-700), lifetime: 600)
        await h.dispatcher.cloudDidNotify()
        // The iPhone's feedback reads the answer; two late taps with one reason give one answer, a refresh none.
        #expect(await eventually { await h.saved.contains { $0.kind == "commandIgnored" } })
        await h.dispatcher.cloudDidNotify()
        await settle()
        let answers = await h.saved.filter { $0.kind == "commandIgnored" }
        #expect(answers.map(\.body) == ["It reached this Mac too late (the Mac was asleep or offline)."])
        await h.dispatcher.stop()
    }

    @Test func anotherMacsCommandsAreLeftAlone() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        let collector = CommandCollector(h.dispatcher.remoteCommands())
        let other = try await h.phoneCommand(.sleepNow, macID: UUID().uuidString)
        await h.dispatcher.cloudDidNotify()
        await settle()
        #expect(await h.cloud?.contains(.command(other.id)) == true, "that Mac still has to see it")
        #expect(collector.commands.isEmpty)
        await h.dispatcher.stop()
    }

    @Test func testAndRefreshRequestsAreAnsweredByNotify() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        let collector = CommandCollector(h.dispatcher.remoteCommands())
        await h.dispatcher.updateMacStatus(report())
        #expect(await eventually { await h.statuses.count == 1 })
        h.clock.advance(by: .seconds(30))
        try await h.phoneCommand(.refreshStatus, sv: nil)
        try await h.phoneCommand(.sendTest, sv: nil)
        await h.dispatcher.cloudDidNotify()
        #expect(await eventually { await h.statuses.first?.updatedAt == h.clock.now() }, "refresh republishes the status at once")
        #expect(await eventually { await h.savedTitles == ["Kakureneko test"] })
        #expect(await eventually { h.posted.map(\.title) == ["Kakureneko test"] })
        #expect(await h.dispatcher.pollIntervalForTesting == 15, "fast polling after a refresh")
        #expect(collector.commands.isEmpty, "the coordinator never sees these")
        await h.dispatcher.stop()
    }

    @Test func pushesFetchAtOnceAndPollingCatchesWhatPushesMiss() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        #expect(await h.dispatcher.pollIntervalForTesting == 300)
        let collector = CommandCollector(h.dispatcher.remoteCommands())
        try await h.phoneCommand(.keepAwake(seconds: 600), sv: nil)
        await settle()
        #expect(collector.commands.isEmpty, "no push yet")
        // No push arrives at all (silent pushes are best effort): the 5 min poll picks it up.
        #expect(await happensBy(h.clock, within: .seconds(300), step: .seconds(10)) { collector.commands.count == 1 })
        // An alert with buttons makes the poll fast while its buttons can be tapped.
        _ = await h.dispatcher.submit(.stalled(SessionEffect(kind: .stalled, session: Fixtures.claude(), at: h.clock.now())),
                                      context: Fixtures.context(h.clock.now()))
        #expect(await eventually { await h.saved.count == 1 })
        #expect(await h.dispatcher.pollIntervalForTesting == 15)
        await h.dispatcher.stop()
    }

    // MARK: Mac notification buttons

    @Test func macNotificationButtonsBecomeCommands() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        let collector = CommandCollector(h.dispatcher.remoteCommands())
        let mac = await h.dispatcher.macIDForTesting
        let expires = h.clock.now().addingTimeInterval(300)
        h.local.tap(AlertPresentation.ButtonTap(request: .sleepNow, alertID: "A1", macID: mac, stateVersion: 42, expiresAt: expires))
        #expect(await eventually { collector.commands.count == 1 })
        #expect(collector.commands.first?.kind == .sleep)
        #expect(collector.commands.first?.source == .macNotification)
        #expect(collector.commands.first?.stateVersion == 42)
        // The same button again, another Mac's, an expired one, and a sleep without sv: all ignored.
        h.local.tap(AlertPresentation.ButtonTap(request: .sleepNow, alertID: "A1", macID: mac, stateVersion: 42, expiresAt: expires))
        h.local.tap(AlertPresentation.ButtonTap(request: .sleepNow, alertID: "A2", macID: "other", stateVersion: 42, expiresAt: expires))
        h.local.tap(AlertPresentation.ButtonTap(request: .sleepNow, alertID: "A3", macID: mac, stateVersion: 42, expiresAt: Fixtures.start))
        h.local.tap(AlertPresentation.ButtonTap(request: .sleepNow, alertID: "A4", macID: mac, stateVersion: nil, expiresAt: expires))
        h.local.tap(AlertPresentation.ButtonTap(request: .keepAwake(seconds: 3600), alertID: "A5", macID: mac, stateVersion: nil, expiresAt: expires))
        #expect(await eventually { collector.commands.count == 2 })
        await settle()
        #expect(collector.kinds == [.sleep, .keepAwake(seconds: 3600)])
        await h.dispatcher.stop()
    }

    // MARK: Phones

    @Test func phonesAppearAndDisappear() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        #expect(await !h.dispatcher.status().phoneConnected)
        try await h.cloud?.save([.device(phone()), .device(phone("p2", seen: Fixtures.start.addingTimeInterval(-40 * 86_400)))])
        await h.dispatcher.cloudDidNotify()
        #expect(await eventually { await h.dispatcher.status().phones.map(\.deviceID) == ["p1"] }, "a phone gone for 40 days is not listed")
        #expect(await h.dispatcher.status().phoneConnected)
        try await h.cloud?.delete([CloudItem.device(phone()).id])
        await h.dispatcher.cloudDidNotify()
        #expect(await eventually { await h.dispatcher.status().phones.isEmpty })
        await h.dispatcher.stop()
    }

    /// "Waiting for your iPhone…": no push came for the iPhone's new record (they are best effort), and the 5-minute
    /// poll would leave the spinner going for minutes after the iPhone's setup.
    @Test func waitingForAnIPhoneLooksEveryFewSeconds() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        await h.dispatcher.lookForPhones()
        #expect(await h.dispatcher.pollIntervalForTesting == 15)
        await settle()
        try await h.cloud?.save([.device(phone())])
        #expect(await happensBy(h.clock, within: .seconds(20), step: .seconds(5)) { await h.dispatcher.status().phones.count == 1 },
                "found without a push, within one quick poll")
        h.clock.advance(by: .seconds(11 * 60))
        #expect(await h.dispatcher.pollIntervalForTesting == 300, "back to the slow poll after 10 minutes")
        await h.dispatcher.stop()
    }

    @Test func anIPhoneCanBeRemovedFromTheList() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        try await h.cloud?.save([.device(phone()), .device(phone("p2"))])
        await h.dispatcher.cloudDidNotify()
        #expect(await eventually { await h.dispatcher.status().phones.count == 2 })
        await h.dispatcher.forgetPhone(deviceID: "p2")
        #expect(await h.dispatcher.status().phones.map(\.deviceID) == ["p1"])
        #expect(await h.cloud?.contains(CloudItem.device(phone("p2")).id) == false, "its record left iCloud")
        await h.dispatcher.stop()
    }

    @Test func anotherAppleAccountStartsOver() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        try await h.cloud?.save([.device(phone())])
        await h.dispatcher.cloudDidNotify()
        #expect(await eventually { await h.dispatcher.status().phones.count == 1 })
        await h.dispatcher.stop()
        // Signed in to another Apple Account (its iCloud is empty): nothing of the old account is shown.
        try await h.cloud?.delete([CloudItem.device(phone()).id])
        await h.cloud?.setAccountTag("account-b")
        let relaunched = h.relaunch()
        await relaunched.start()
        #expect(await eventually { await relaunched.cloudReadyForTesting })
        #expect(await relaunched.status().phones.isEmpty)
        await relaunched.stop()
    }

    @Test func iPhoneCommandsAreIgnoredWhileIPhoneAlertsAreOff() async throws {
        var settings = NotificationSettings()
        settings.phoneAlerts = false
        let h = try Harness(settings: settings)
        defer { h.cleanup() }
        try await h.startReady()
        let collector = CommandCollector(h.dispatcher.remoteCommands())
        let command = try await h.phoneCommand(.sleepNow)
        await h.dispatcher.cloudDidNotify()
        #expect(await eventually { await h.cloud?.contains(CloudItem.command(command).id) == false }, "handled and deleted")
        #expect(collector.kinds.isEmpty, "never acted on")
        await h.dispatcher.stop()
    }

    @Test func theMacIDComesFromTheMachine() async throws {
        let h = try Harness(configure: { $0.machineMacID = { "8B1A2C3D-0000-5000-8000-000000000001" } })
        defer { h.cleanup() }
        #expect(await h.dispatcher.macIDForTesting == "8B1A2C3D-0000-5000-8000-000000000001")
        // Derived: the same machine and user give the same id; another machine or user another one.
        let a = MachineIdentity.derive(platformUUID: "PLATFORM-1", userID: 501)
        #expect(a == MachineIdentity.derive(platformUUID: "PLATFORM-1", userID: 501))
        #expect(a != MachineIdentity.derive(platformUUID: "PLATFORM-2", userID: 501))
        #expect(a != MachineIdentity.derive(platformUUID: "PLATFORM-1", userID: 502))
        #expect(UUID(uuidString: a) != nil, "shaped as a UUID (the stored state requires one)")
    }

    @Test func recordsWhoseWriterIsGoneArePrunedByAge() async throws {
        let h = try Harness(configure: { $0.pruneInterval = 60 })
        defer { h.cleanup() }
        let cloud = try #require(h.cloud)
        try await h.startReady()
        // Left by a Mac that is gone: a command for it, its status, an old iPhone; and a fresh iPhone.
        let orphan = try await h.phoneCommand(.refreshStatus, lifetime: 3 * 86_400, macID: "gone-mac")
        let goneStatus = CloudItem.status(MacStatus(macID: "gone-mac", macName: "Old", model: nil, phase: .idle, headline: "",
                                                    agents: [], batteryPercent: nil, onBattery: false, lidClosed: false,
                                                    stateVersion: 0, keepAwakeSeconds: 3600, canSleep: true,
                                                    updatedAt: Fixtures.start, appVersion: "1"))
        try await cloud.save([goneStatus, .device(phone("old"))])
        await cloud.setModified(CloudItem.command(orphan).id, at: h.clock.now().addingTimeInterval(-2 * 3600))
        await cloud.setModified(goneStatus.id, at: h.clock.now().addingTimeInterval(-31 * 86_400))
        await cloud.setModified(CloudItem.device(phone("old")).id, at: h.clock.now().addingTimeInterval(-31 * 86_400))
        try await cloud.save([.device(phone("fresh"))])
        #expect(await happensBy(h.clock, within: .seconds(180), step: .seconds(30)) {
            let orphanGone = await !cloud.contains(CloudItem.command(orphan).id)
            let statusGone = await !cloud.contains(goneStatus.id)
            let oldGone = await !cloud.contains(CloudItem.device(phone("old")).id)
            return orphanGone && statusGone && oldGone
        })
        #expect(await cloud.contains(CloudItem.device(phone("fresh")).id), "a recent iPhone stays")
        await h.dispatcher.stop()
    }

    @Test func iPhoneAlertsOffWhileOfflineRemovesTheMacOnceICloudIsBack() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        let cloud = try #require(h.cloud)
        try await h.startReady()
        await h.dispatcher.updateMacStatus(report())
        #expect(await eventually { await h.statuses.count == 1 })
        await h.dispatcher.stop()
        // Turned off while iCloud can't be reached: remembered, done at the next setup.
        await cloud.setAccount(.noAccount)
        var off = h.settings
        off.phoneAlerts = false
        let offline = h.relaunch(settings: off)
        await offline.start()
        await offline.applySettings(h.settings) // on (as stored) …
        await offline.applySettings(off)        // … then off without iCloud
        await offline.stop()
        await cloud.setAccount(.available)
        let back = h.relaunch(settings: off)
        await back.start()
        #expect(await eventually { await h.statuses.isEmpty }, "the status left iCloud once it could")
        await back.stop()
    }

    // MARK: Status

    @Test func statusIsSavedWithTheMacsIdentity() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        await h.dispatcher.updateMacStatus(report())
        #expect(await eventually { await h.statuses.count == 1 })
        let status = try #require(await h.statuses.first)
        #expect(status.macID == (await h.dispatcher.macIDForTesting))
        #expect(status.macName == "Studio" && status.model == "MacBook Pro (16-inch, 2021)" && status.appVersion == "1.0 (7)")
        #expect(status.phase == .working && status.headline == "1 agent working" && status.stateVersion == 42)
        #expect(status.batteryPercent == 80 && status.onBattery && status.canSleep)
        #expect(status.updatedAt == h.clock.now())
        await h.dispatcher.stop()
    }

    @Test func statusBeforeICloudIsReadyIsSavedOnceItIs() async throws {
        let cloud = InMemoryCloudStore(account: .noAccount)
        let h = try Harness(cloud: cloud)
        defer { h.cleanup() }
        await h.dispatcher.start()
        await h.dispatcher.updateMacStatus(report())
        await settle()
        #expect(await h.statuses.isEmpty)
        await cloud.setAccount(.available)
        #expect(await happensBy(h.clock, within: .seconds(600)) { await h.statuses.count == 1 })
        await h.dispatcher.stop()
    }

    @Test func changesAreDebouncedAndPhaseChangesGoAtOnce() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        await h.dispatcher.updateMacStatus(report())
        #expect(await eventually { await h.statuses.first?.headline == "1 agent working" })
        await h.dispatcher.updateMacStatus(report(headline: "2 agents working"))
        #expect(await happensAt(h.clock, after: .seconds(5)) { await h.statuses.first?.headline == "2 agents working" })
        await h.dispatcher.updateMacStatus(report(.lidClosedAwake, headline: "Lid closed · 2 agents working"))
        #expect(await eventually { await h.statuses.first?.phase == .lidClosedAwake }, "a phase change is not debounced")
        // Unchanged reports are not saved again.
        let saves = await h.cloud?.count(.save) ?? 0
        await h.dispatcher.updateMacStatus(report(.lidClosedAwake, headline: "Lid closed · 2 agents working"))
        h.clock.advance(by: .seconds(10))
        await settle()
        #expect(await h.cloud?.count(.save) == saves)
        await h.dispatcher.stop()
    }

    @Test func aHeartbeatKeepsTheStatusFresh() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        await h.dispatcher.updateMacStatus(report())
        #expect(await eventually { await h.statuses.first?.updatedAt == Fixtures.start })
        #expect(await happensBy(h.clock, within: .seconds(360), step: .seconds(10)) {
            await (h.statuses.first?.updatedAt ?? .distantPast) >= Fixtures.start.addingTimeInterval(300)
        })
        await h.dispatcher.stop()
    }

    @Test func drainSavesTheFinalStatusBeforeSleep() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        await h.dispatcher.updateMacStatus(report())
        #expect(await eventually { await h.statuses.first?.phase == .working })
        await h.dispatcher.updateMacStatus(report(headline: "about to sleep")) // debounced, not saved yet
        var asleep = report(.asleep, headline: "Asleep")
        asleep.canSleep = false
        await h.dispatcher.updateMacStatus(asleep)
        _ = await h.dispatcher.drain(deadline: h.clock.now().addingTimeInterval(10))
        #expect(await h.statuses.first?.phase == .asleep)
        await h.dispatcher.stop()
    }

    // MARK: iPhone alerts off

    @Test func withIPhoneAlertsOffNothingAboutTheMacIsSaved() async throws {
        var settings = NotificationSettings()
        settings.phoneAlerts = false
        let h = try Harness(settings: settings)
        defer { h.cleanup() }
        try await h.startReady()
        await h.dispatcher.updateMacStatus(report())
        _ = await happensBy(h.clock, within: .seconds(180), step: .seconds(30)) { false }
        #expect(await h.statuses.isEmpty, "no status while iPhone alerts are off")
        await h.dispatcher.stop()
    }

    @Test func turningIPhoneAlertsOffRemovesTheMacFromICloudAndOnBringsItBack() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.startReady()
        await h.dispatcher.enqueue(OutgoingNotification(kind: .warning, title: "t", body: "b", groupKey: "g", createdAt: Fixtures.start))
        await h.dispatcher.updateMacStatus(report())
        #expect(await eventually { await h.statuses.count == 1 }, "status")
        #expect(await eventually { await h.saved.count == 1 }, "alert")
        var off = h.settings
        off.phoneAlerts = false
        await h.dispatcher.applySettings(off)
        #expect(await h.statuses.isEmpty, "the status is deleted before applySettings returns (Uninstall relies on it)")
        // Every alert this Mac saved, also one whose save was still in flight.
        #expect(await eventually { await h.saved.isEmpty })
        await h.dispatcher.updateMacStatus(report(headline: "still working"))
        _ = await happensBy(h.clock, within: .seconds(120), step: .seconds(30)) { false }
        #expect(await h.statuses.isEmpty, "nothing new while off")
        await h.dispatcher.applySettings(h.settings)
        #expect(await eventually { await h.statuses.first?.headline == "still working" }, "back on: saved again at once")
        await h.dispatcher.stop()
    }

    // MARK: Pruning and legacy

    @Test func oldAlertsArePrunedFromICloud() async throws {
        let h = try Harness(configure: {
            $0.alertRetention = 120
            $0.alertPruneMargin = 0
            $0.pruneInterval = 60
        })
        defer { h.cleanup() }
        try await h.startReady()
        await h.dispatcher.enqueue(OutgoingNotification(kind: .warning, title: "old", body: "b", groupKey: "g", createdAt: Fixtures.start))
        #expect(await eventually { await h.saved.count == 1 })
        #expect(await happensBy(h.clock, within: .seconds(240), step: .seconds(10)) { await h.saved.isEmpty })
        await h.dispatcher.stop()
    }

    @Test func theNtfySecretsOfEarlierVersionsAreDeletedAtStart() async throws {
        let paths = try Paths.temporary()
        try FileManager.default.createDirectory(at: paths.legacySecretsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1}"#.utf8).write(to: paths.legacySecretsFile)
        let h = try Harness(paths: paths)
        defer { h.cleanup() }
        _ = await h.dispatcher.status()
        #expect(!FileManager.default.fileExists(atPath: paths.legacySecretsFile.path(percentEncoded: false)))
    }
}
