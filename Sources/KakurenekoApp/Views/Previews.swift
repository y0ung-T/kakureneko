// SwiftUI previews (debug builds only), all driven by `PreviewKakurenekoController` + `AppEnvironment.inert()`:
// no coordinator, no system access, no network.

#if DEBUG
import KakurenekoKit
import SwiftUI

extension AppModel {
    /// A model showing `snapshot` at once (applied synchronously) and connected to a `PreviewKakurenekoController`, so
    /// buttons in the preview change the state plausibly.
    static func preview(_ snapshot: AppSnapshot = PreviewKakurenekoController.sampleSnapshot()) -> AppModel {
        let model = AppModel(environment: .inert())
        model.apply(snapshot)
        model.connect(to: PreviewKakurenekoController(snapshot: snapshot), start: false)
        return model
    }
}

/// Snapshot variants for the previews.
enum PreviewSnapshots {
    static func countdown(now: Date = Date()) -> AppSnapshot {
        var snapshot = PreviewKakurenekoController.sampleSnapshot(now: now)
        snapshot.sessions = snapshot.sessions.filter { $0.agent == .codex }
        snapshot.aggregate = SessionAggregate.compute(from: snapshot.sessions, stateVersion: 8, lastFinishedAt: now)
        snapshot.powerPhase = .countdown(endsAt: now.addingTimeInterval(252), reason: .needsInput, closedSince: now.addingTimeInterval(-348))
        snapshot.keepAwakeUntil = nil
        return snapshot
    }

    static func shutdownInDryRun(now: Date = Date()) -> AppSnapshot {
        var snapshot = PreviewKakurenekoController.sampleSnapshot(now: now)
        snapshot.sessions = []
        snapshot.aggregate = .empty
        snapshot.pausedApps = []
        snapshot.isDryRun = true
        snapshot.privileged = .simulatedForDryRun(at: now)
        snapshot.powerPhase = .shutdownPending(at: now.addingTimeInterval(55), requestedFromPhone: true)
        snapshot.settings.power.endAction = .shutdown
        snapshot.dryRunLog = [
            DryRunEntry(id: 1, at: now.addingTimeInterval(-30), category: .power, action: "power.arm", detail: "would run /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 1"),
            DryRunEntry(id: 2, at: now.addingTimeInterval(-12), category: .pause, action: "priority.background", detail: "would throttle pid 92564 (Arc)"),
            DryRunEntry(id: 3, at: now.addingTimeInterval(-2), category: .notify, action: "cloud.save", detail: "would save 1 iCloud record(s) (Alert)"),
        ]
        snapshot.warnings = [
            AppWarning(id: "dry-run", severity: .info, title: "Dry run", message: "Kakureneko only logs what it would do."),
            AppWarning(id: "mac-notifications-off", severity: .info, title: "Mac notifications are off",
                       message: "Allow notifications for Kakureneko in System Settings → Notifications to see alerts on this Mac."),
        ]
        snapshot.resumeOffer = [ResumeEntry(agent: .claude, sessionId: "3514aa88", cwd: "/Users/me/Developer/api", title: nil)]
        return snapshot
    }

    static func firstLaunch() -> AppSnapshot {
        var snapshot = PreviewKakurenekoController.sampleSnapshot()
        snapshot.mode = .notificationsOnly
        snapshot.privileged = PrivilegedStatus(sudoRuleInstalled: false, failsafeLoaded: false, checkedAt: Date(), detail: nil)
        snapshot.settings.general.onboardingCompleted = false
        return snapshot
    }
}

#Preview("Menu · working") {
    MenuContentView(model: .preview())
}

#Preview("Menu · countdown") {
    MenuContentView(model: .preview(PreviewSnapshots.countdown()))
}

#Preview("Menu · shutdown grace, dry run") {
    MenuContentView(model: .preview(PreviewSnapshots.shutdownInDryRun()))
}

#Preview("Settings") {
    SettingsView(model: .preview())
        .frame(width: 800, height: 620)
}

#Preview("Onboarding") {
    OnboardingView(flow: OnboardingFlow(model: .preview(PreviewSnapshots.firstLaunch())))
}

#Preview("Integration preview sheet") {
    IntegrationPreviewSheet(
        model: .preview(),
        state: IntegrationSheetState(plan: InstallPlan(
            agent: .codex, operation: .install,
            changes: [FileChange(path: "~/.codex/hooks.json", kind: .create, before: nil, after: "{}\n",
                                 unifiedDiff: "--- /dev/null\n+++ b/hooks.json\n@@ -0,0 +1,3 @@\n+{\n+  \"hooks\": {}\n+}\n")],
            followUpNote: IntegrationRowModel.codexTrustGuidance)),
        onApply: { _ in }, onClose: {})
}
#endif
