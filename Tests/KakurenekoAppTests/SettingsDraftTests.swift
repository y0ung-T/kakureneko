@testable import KakurenekoApp
import KakurenekoKit
import Foundation
import Testing

@MainActor
@Suite("Settings draft", .timeLimit(.minutes(1)))
struct SettingsDraftTests {
    // MARK: Pure merge

    @Test func cleanDraftFollowsRepublishes() {
        let draft = SettingsDraft(.default)
        var remote = KakurenekoSettings.default
        remote.safety.batteryFloorPercent = 30
        draft.rebase(onto: remote)
        #expect(draft.value == remote)
        #expect(!draft.isDirty)
    }

    @Test func editsSurviveARepublishOfOtherFields() {
        let draft = SettingsDraft(.default)
        draft.value.safety.batteryFloorPercent = 35
        draft.value.timers.finishCountdownMinutes = 9
        var remote = KakurenekoSettings.default
        remote.pausing.neverPauseBundleIDs = ["com.spotify.client"]
        remote.general.launchAtLogin = true
        draft.rebase(onto: remote)
        #expect(draft.value.safety.batteryFloorPercent == 35)
        #expect(draft.value.timers.finishCountdownMinutes == 9)
        #expect(draft.value.pausing.neverPauseBundleIDs == ["com.spotify.client"])
        #expect(draft.value.general.launchAtLogin)
        #expect(draft.base == remote)
        #expect(draft.isDirty)
    }

    @Test func theUsersEditWinsOverAConcurrentChangeOfTheSameField() {
        let draft = SettingsDraft(.default)
        draft.value.notifications.detailLevel = .private
        var remote = KakurenekoSettings.default
        remote.notifications.detailLevel = .detailed
        draft.rebase(onto: remote)
        #expect(draft.value.notifications.detailLevel == .private)
    }

    @Test func nestedStructsAndSetsMergePerField() {
        let draft = SettingsDraft(.default)
        draft.value.notifications.quietHours.enabled = true
        draft.value.notifications.mutedKinds = [.stalled]
        var remote = KakurenekoSettings.default
        remote.notifications.quietHours.startMinute = 22 * 60
        remote.integrations.dismissedAgents = [.aider]
        draft.rebase(onto: remote)
        #expect(draft.value.notifications.quietHours == QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60))
        #expect(draft.value.notifications.mutedKinds == [.stalled])
        #expect(draft.value.integrations.dismissedAgents == [.aider])
    }

    @Test func commitPayloadAppliesOnlyTheEditsOntoTheLatestSettings() {
        let draft = SettingsDraft(.default)
        draft.value.pausing.mode = .freeze
        var latest = KakurenekoSettings.default
        latest.pausing.neverPauseBundleIDs = ["com.apple.Music"]
        latest.general.onboardingCompleted = true
        let payload = draft.commitPayload(latest: latest)
        #expect(payload.pausing.mode == .freeze)
        #expect(payload.pausing.neverPauseBundleIDs == ["com.apple.Music"])
        #expect(payload.general.onboardingCompleted)
        draft.markCommitted(payload)
        #expect(!draft.isDirty && draft.value == payload)
    }

    @Test func commitPayloadIsNormalized() {
        let draft = SettingsDraft(.default)
        draft.value.safety.batteryFloorPercent = 99
        draft.value.timers.settleSeconds = 1
        let payload = draft.commitPayload(latest: .default)
        #expect(payload.safety.batteryFloorPercent == SafetySettings.batteryFloorPercentRange.upperBound)
        #expect(payload.timers.settleSeconds == SessionTimers().settleSeconds)
    }

    @Test func revertDropsTheEdits() {
        let draft = SettingsDraft(.default)
        draft.value.power.endAction = .shutdown
        #expect(draft.isDirty)
        draft.revert()
        #expect(!draft.isDirty)
        #expect(draft.value.power.endAction == .sleep)
    }

    @Test func mergeShortcutsAndRoundTrip() {
        var a = KakurenekoSettings.default
        a.notifications.macAlerts = false
        #expect(SettingsMerge.merge(base: .default, local: .default, remote: a) == a)
        #expect(SettingsMerge.merge(base: .default, local: a, remote: .default) == a)
        var b = KakurenekoSettings.default
        b.safety.allowOnBattery = false
        let merged = SettingsMerge.merge(base: .default, local: a, remote: b)
        #expect(merged.notifications.macAlerts == a.notifications.macAlerts)
        #expect(merged.safety.allowOnBattery == false)
    }

    // MARK: Through the model and the snapshot stream

    /// Spec acceptance: the settings draft is not clobbered by a republish.
    @Test func draftIsNotClobberedByARepublish() async throws {
        let (model, controller) = try await connectedModel()
        model.settingsDraft.value.safety.maxClosedLidHours = 6
        await controller.setNeverPause(bundleID: "com.valvesoftware.steam", true) // republishes settings
        #expect(await waitUntil { model.snapshot.settings.pausing.neverPauseBundleIDs == ["com.valvesoftware.steam"] })
        #expect(model.settingsDraft.value.safety.maxClosedLidHours == 6)
        #expect(model.settingsDraft.value.pausing.neverPauseBundleIDs == ["com.valvesoftware.steam"])
        #expect(model.settingsDraft.isDirty)
        // A republish that does not touch settings (e.g. a keep-awake) changes nothing either.
        await controller.keepAwake(for: 600)
        #expect(await waitUntil { model.snapshot.keepAwakeUntil != nil })
        #expect(model.settingsDraft.value.safety.maxClosedLidHours == 6)
    }

    @Test func commitSendsUpdateSettingsAndCleansTheDraft() async throws {
        let (model, controller) = try await connectedModel()
        model.settingsDraft.value.timers.finishCountdownMinutes = 12
        await controller.setNeverPause(bundleID: "com.apple.Music", true)
        await model.commitSettings()
        let settings = await controller.currentSnapshot().settings
        #expect(settings.timers.finishCountdownMinutes == 12)
        #expect(settings.pausing.neverPauseBundleIDs == ["com.apple.Music"]) // not reverted by the commit
        #expect(await controller.calls == ["setNeverPause(com.apple.Music,true)", "updateSettings"])
        #expect(!model.settingsDraft.isDirty)
        #expect(await waitUntil { model.snapshot.settings.timers.finishCountdownMinutes == 12 })
        #expect(!model.settingsDraft.isDirty)
    }

    @Test func commitWithoutEditsSendsNothing() async throws {
        let (model, controller) = try await connectedModel()
        await model.commitSettings()
        #expect(await controller.calls.isEmpty)
    }

    @Test func enablingShutdownAsksForAutomationConsent() async throws {
        let consent = RecordingAutomationConsent(result: .granted)
        let (model, _) = try await connectedModel(environment: .inert(automation: consent))
        model.settingsDraft.value.power.endAction = .shutdown
        await model.commitSettings()
        #expect(consent.requestCount == 1)
        #expect(model.automationConsent == .granted)
        // Committing something else later does not ask again.
        model.settingsDraft.value.power.displaySleepOnLidClose = false
        await model.commitSettings()
        #expect(consent.requestCount == 1)
    }

    @Test func dryRunNeverAsksForAutomationConsent() async throws {
        let consent = RecordingAutomationConsent()
        var snapshot = PreviewKakurenekoController.sampleSnapshot()
        snapshot.isDryRun = true
        let (model, _) = try await connectedModel(snapshot: snapshot, environment: .inert(automation: consent))
        model.settingsDraft.value.power.endAction = .shutdown
        await model.commitSettings()
        #expect(consent.requestCount == 0)
        #expect(model.automationConsent == .skippedInDryRun)
        #expect(model.localDryRunLog.map(\.detail) == ["would ask for permission to shut down the Mac"])
    }

    @Test func updateSettingsNowReadsTheLatestSettings() async throws {
        let (model, controller) = try await connectedModel()
        await controller.setNeverPause(bundleID: "com.apple.TV", true)
        // The model may not have seen that republish yet; the immediate update still keeps it.
        await model.updateSettingsNow { $0.notifications.detailLevel = .private }
        let settings = await controller.currentSnapshot().settings
        #expect(settings.notifications.detailLevel == .private)
        #expect(settings.pausing.neverPauseBundleIDs == ["com.apple.TV"])
        // No change → no call.
        await model.updateSettingsNow { $0.notifications.detailLevel = .private }
        #expect(await controller.calls.filter { $0 == "updateSettings" }.count == 1)
    }
}
