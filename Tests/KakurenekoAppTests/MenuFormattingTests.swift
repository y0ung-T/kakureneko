@testable import KakurenekoApp
import AppKit
import KakurenekoCloud
import KakurenekoKit
import Foundation
import Testing

@MainActor
@Suite("Menu formatting (pure)", .timeLimit(.minutes(1)))
struct MenuFormattingTests {
    private func sample() -> AppSnapshot { PreviewKakurenekoController.sampleSnapshot(now: fixedNow) }

    private func session(_ state: SessionState, agent: AgentID = .claude, title: String? = nil, cwd: String? = "/Users/me/Developer/api",
                         host: HostApp? = HostApp(bundleID: "com.apple.Terminal", name: "Terminal"),
                         tiers: Set<Tier> = [.hook], waitingFor: String? = nil, lastTurn: TimeInterval? = nil) -> AgentSession {
        AgentSession(key: SessionKey(agent: agent, id: "s-\(state.label)"), host: host, cwd: cwd, title: title, state: state,
                     tiers: tiers, waitingFor: waitingFor, lastTurnDuration: lastTurn)
    }

    // MARK: Session rows

    @Test func sampleSessionRows() {
        let rows = SessionRowModel.rows(for: sample(), now: fixedNow)
        #expect(rows.count == 2)
        #expect(rows[0].title == "Refactor auth middleware")
        #expect(rows[0].subtitle == "Claude Code · api · Terminal")
        #expect(rows[0].statusText == "Working · 42m")
        #expect(rows[0].tone == .working)
        #expect(rows[0].detail == nil)
        #expect(!rows[0].canDismiss)
        #expect(rows[1].title == "web")
        #expect(rows[1].subtitle == "Codex · VS Code")
        #expect(rows[1].statusText == "Waiting · 3m")
        #expect(rows[1].detail == "Waiting for permission")
        #expect(rows[1].tone == .waiting)
    }

    @Test func everySessionStateFormats() {
        let now = fixedNow
        let settling = SessionRowModel.make(session(.settling(until: now.addingTimeInterval(3), outcome: .completed)), now: now)
        #expect(settling.statusText == "Finishing…" && settling.tone == .working)

        let idle = SessionRowModel.make(session(.idle(since: now.addingTimeInterval(-300), outcome: .completed), lastTurn: 12 * 60), now: now)
        #expect(idle.statusText == "Idle · 5m")
        #expect(idle.detail == "Finished after 12m")
        #expect(idle.tone == .neutral)

        let interrupted = SessionRowModel.make(session(.idle(since: now, outcome: .interrupted), lastTurn: 60), now: now)
        #expect(interrupted.detail == "Interrupted")

        let stalled = SessionRowModel.make(session(.stalled(since: now.addingTimeInterval(-25 * 60))), now: now)
        #expect(stalled.statusText == "Stuck · 25m")
        #expect(stalled.canDismiss)
        #expect(stalled.tone == .attention)

        let waiting = SessionRowModel.make(session(.waiting(kind: .question, since: now), waitingFor: "  "), now: now)
        #expect(waiting.detail == "Has a question for you")
        let custom = SessionRowModel.make(session(.waiting(kind: .permission, since: now), waitingFor: "Allow Bash(rm build/)?"), now: now)
        #expect(custom.detail == "Allow Bash(rm build/)?")

        let heuristic = SessionRowModel.make(session(.working(since: now.addingTimeInterval(-90)), agent: .goose, cwd: nil, host: nil,
                                                     tiers: [.heuristic]), now: now)
        #expect(heuristic.title == "Goose")
        #expect(heuristic.subtitle == "Goose")
        #expect(heuristic.statusText == "Working · 1m")
        #expect(heuristic.detail == "Detected from activity")

        let ended = SessionRowModel.make(session(.ended(at: now)), now: now)
        #expect(ended.statusText == "Ended")
    }

    @Test func endedSessionsAreNotListed() {
        var snapshot = sample()
        snapshot.sessions.append(session(.ended(at: fixedNow)))
        #expect(SessionRowModel.rows(for: snapshot, now: fixedNow).count == 2)
    }

    @Test func outcomeTexts() {
        #expect(SessionRowModel.outcomeText(.rateLimited, lastTurn: 30) == "Hit a rate limit")
        #expect(SessionRowModel.outcomeText(.error, lastTurn: 120) == "Stopped with an error after 2m")
        #expect(SessionRowModel.outcomeText(.ambiguous, lastTurn: nil) == "Finished or waiting for you")
        #expect(SessionRowModel.outcomeText(nil, lastTurn: nil) == nil)
        #expect(SessionRowModel.outcomeText(nil, lastTurn: 3700) == "Last turn took 1h 1m")
    }

    // MARK: Countdown and phase

    @Test func countdownText() {
        #expect(DurationText.countdown(252) == "4:12")
        #expect(DurationText.countdown(4.2) == "0:05")
        #expect(DurationText.countdown(0) == "0:00")
        #expect(DurationText.countdown(-30) == "0:00")
        #expect(DurationText.countdown(3723) == "1:02:03")
        #expect(DurationText.countdown(600) == "10:00")
    }

    @Test func countdownPhase() {
        var snapshot = sample()
        snapshot.powerPhase = .countdown(endsAt: fixedNow.addingTimeInterval(252), reason: .finished, closedSince: fixedNow.addingTimeInterval(-600))
        let summary = PhaseSummary.make(snapshot: snapshot, now: fixedNow)
        #expect(summary.title == "Sleeping in 4:12")
        #expect(summary.detail == "All agents are done.")
        #expect(summary.deadline == fixedNow.addingTimeInterval(252))
        #expect(summary.actions == [.keepAwake, .sleepNow])
        snapshot.powerPhase = .countdown(endsAt: fixedNow.addingTimeInterval(600), reason: .needsInput, closedSince: fixedNow)
        let waiting = PhaseSummary.make(snapshot: snapshot, now: fixedNow)
        #expect(waiting.title == "Sleeping in 10:00")
        #expect(waiting.detail == "An agent is waiting for you.")
        #expect(PhaseSummary.countdownReason(.wentQuiet) == "Your agents went quiet.")
    }

    @Test func shutdownGraceOffersOnlyCancel() {
        var snapshot = sample()
        snapshot.powerPhase = .shutdownPending(at: fixedNow.addingTimeInterval(42), requestedFromPhone: true)
        let summary = PhaseSummary.make(snapshot: snapshot, now: fixedNow)
        #expect(summary.title == "Shutting down in 0:42")
        #expect(summary.detail == "Requested from your phone.")
        #expect(summary.actions == [.cancelWindDown])
        #expect(summary.tone == .critical)
        snapshot.powerPhase = .shutdownPending(at: fixedNow.addingTimeInterval(60), requestedFromPhone: false)
        #expect(PhaseSummary.make(snapshot: snapshot, now: fixedNow).detail == "All agents are done.")
    }

    @Test func windDownOffersCancelAndExplainsWhy() {
        var snapshot = sample()
        snapshot.powerPhase = .windingDown(reason: .safetyTrip(.batteryFloor(percent: 19)), since: fixedNow)
        let summary = PhaseSummary.make(snapshot: snapshot, now: fixedNow)
        #expect(summary.title == "Going to sleep…")
        #expect(summary.detail == "Safety: battery 19 %.")
        #expect(summary.actions == [.cancelWindDown])
        #expect(PhaseSummary.windDownTitle(.remoteShutdown) == "Shutting down…")
        #expect(PhaseSummary.windDownReason(.userSleepNow) == "You chose Sleep now.")
        #expect(PhaseSummary.windDownReason(.countdownElapsed) == "The countdown finished.")
    }

    @Test func steadyPhases() {
        var snapshot = sample()
        #expect(PhaseSummary.make(snapshot: snapshot, now: fixedNow).title == "Stays awake with the lid closed")
        #expect(PhaseSummary.make(snapshot: snapshot, now: fixedNow).detail == "Armed for 40m.")
        snapshot.powerPhase = .closedAwake(since: fixedNow.addingTimeInterval(-3900))
        #expect(PhaseSummary.make(snapshot: snapshot, now: fixedNow).title == "Lid closed, staying awake")
        #expect(PhaseSummary.make(snapshot: snapshot, now: fixedNow).detail == "For 1h 5m so far.")
        snapshot.powerPhase = .disarmed
        #expect(PhaseSummary.make(snapshot: snapshot, now: fixedNow).title == "Getting ready to stay awake")
        snapshot.aggregate = .empty
        #expect(PhaseSummary.make(snapshot: snapshot, now: fixedNow).title == "Normal sleep")
        snapshot.mode = .notificationsOnly
        #expect(PhaseSummary.make(snapshot: snapshot, now: fixedNow).title == "Notifications only")
        snapshot.mode = .disabled
        #expect(PhaseSummary.make(snapshot: snapshot, now: fixedNow).title == "Kakureneko is off")
    }

    @Test func keepAwakeOverride() {
        var snapshot = sample()
        snapshot.keepAwakeUntil = fixedNow.addingTimeInterval(58 * 60)
        #expect(PhaseSummary.make(snapshot: snapshot, now: fixedNow).actions.contains(.cancelKeepAwake))
        #expect(KeepAwakeText.make(until: snapshot.keepAwakeUntil, now: fixedNow, timeZone: utc) == "Kept awake until 22:58 · 58m left")
        #expect(KeepAwakeText.make(until: fixedNow.addingTimeInterval(-1), now: fixedNow) == nil)
        #expect(KeepAwakeText.make(until: nil, now: fixedNow) == nil)
        snapshot.keepAwakeUntil = fixedNow.addingTimeInterval(-5)
        #expect(!PhaseSummary.make(snapshot: snapshot, now: fixedNow).actions.contains(.cancelKeepAwake))
        #expect(PhaseSummary.keepAwakeOptions.map(\.seconds) == [900, 3600, 7200])
    }

    // MARK: Menu bar icon and header

    @Test func menuBarIconPrecedence() {
        func icon(_ snapshot: AppSnapshot) -> String {
            let icon = MenuBarIcon.make(snapshot: snapshot, now: fixedNow)
            return "\(icon.imageName) \(icon.symbolName)"
        }
        var snapshot = sample()
        #expect(icon(snapshot) == "waiting hand.raised.fill") // one waiting
        snapshot.sessions.removeLast()
        snapshot.aggregate = SessionAggregate.compute(from: snapshot.sessions, stateVersion: 1, lastFinishedAt: nil)
        #expect(icon(snapshot) == "working cup.and.heat.waves.fill")
        snapshot.warnings = [AppWarning(id: "kernel-sleep-disabled", severity: .critical, title: "t", message: "m")]
        #expect(icon(snapshot) == "attention laptopcomputer.trianglebadge.exclamationmark")
        snapshot.powerPhase = .countdown(endsAt: fixedNow.addingTimeInterval(60), reason: .finished, closedSince: fixedNow)
        #expect(icon(snapshot) == "countdown hourglass")
        snapshot.powerPhase = .shutdownPending(at: fixedNow, requestedFromPhone: false)
        #expect(icon(snapshot) == "shutdown power")
        snapshot.powerPhase = .windingDown(reason: .userSleepNow, since: fixedNow)
        #expect(icon(snapshot) == "asleep moon.zzz.fill")
        snapshot.mode = .disabled
        #expect(icon(snapshot) == "off laptopcomputer.slash")

        var idle = AppSnapshot(generatedAt: fixedNow, mode: .full)
        #expect(icon(idle) == "idle laptopcomputer")
        idle.keepAwakeUntil = fixedNow.addingTimeInterval(60)
        #expect(icon(idle) == "keepawake cup.and.saucer.fill")
    }

    /// The design language's state colours: a countdown is drowsy violet, going to sleep indigo, a shutdown or
    /// safety stop critical red (DESIGN.md §2.1).
    @Test func powerCardTones() {
        var snapshot = sample()
        snapshot.powerPhase = .countdown(endsAt: fixedNow.addingTimeInterval(60), reason: .finished, closedSince: fixedNow)
        #expect(PhaseSummary.make(snapshot: snapshot, now: fixedNow).tone == .drowsy)
        #expect(PhaseSummary.make(snapshot: snapshot, now: fixedNow).symbolName == "timer")
        snapshot.powerPhase = .windingDown(reason: .countdownElapsed, since: fixedNow)
        #expect(PhaseSummary.make(snapshot: snapshot, now: fixedNow).tone == .asleep)
        snapshot.powerPhase = .windingDown(reason: .remoteShutdown, since: fixedNow)
        #expect(PhaseSummary.make(snapshot: snapshot, now: fixedNow).tone == .critical)
        snapshot.powerPhase = .windingDown(reason: .safetyTrip(.batteryFloor(percent: 8)), since: fixedNow)
        #expect(PhaseSummary.make(snapshot: snapshot, now: fixedNow).tone == .critical)
        snapshot.powerPhase = .armed(since: fixedNow)
        #expect(PhaseSummary.make(snapshot: snapshot, now: fixedNow).tone == .working)
    }

    @Test func pausedAppsSayTheyResumeBeforeSleep() {
        #expect(PausedAppRowModel.footnote(for: .countdown(endsAt: fixedNow, reason: .finished, closedSince: fixedNow))
            == "Everything resumes before the Mac sleeps.")
        #expect(PausedAppRowModel.footnote(for: .shutdownPending(at: fixedNow, requestedFromPhone: true))
            == "Everything resumes before the Mac shuts down.")
        #expect(PausedAppRowModel.footnote(for: .armed(since: fixedNow)) == nil)
        #expect(PausedAppRowModel.footnote(for: .disarmed) == nil)
    }

    @Test func menuBarSymbolsExist() {
        for name in MenuBarIcon.allSymbolNames {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
        for severity in [AppWarning.Severity.critical, .warning, .info] {
            #expect(NSImage(systemSymbolName: WarningList.symbol(severity), accessibilityDescription: nil) != nil)
        }
        for pane in SettingsPane.allCases {
            #expect(NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: nil) != nil, "\(pane)")
        }
        for step in OnboardingFlow.Step.allCases {
            #expect(NSImage(systemSymbolName: step.symbolName, accessibilityDescription: nil) != nil, "\(step)")
        }
    }

    @Test func headerSubtitle() {
        var snapshot = sample()
        #expect(HeaderText.subtitle(for: snapshot) == "1 working · 1 waiting")
        snapshot.mode = .notificationsOnly
        #expect(HeaderText.subtitle(for: snapshot) == "1 working · 1 waiting · notifications only")
        snapshot.mode = .disabled
        #expect(HeaderText.subtitle(for: snapshot) == "Off · your Mac sleeps as usual")
        #expect(HeaderText.subtitle(for: .placeholder(at: fixedNow)) == "Starting…")
        #expect(HeaderText.subtitle(for: AppSnapshot(generatedAt: fixedNow, mode: .full)) == "No agent is working")
    }

    // MARK: Warnings

    @Test func warningsSortBySeverityStablyAndDedupe() {
        let warnings = [
            AppWarning(id: "dry-run", severity: .info, title: "a", message: ""),
            AppWarning(id: "privileged-missing", severity: .warning, title: "b", message: ""),
            AppWarning(id: "kernel-sleep-disabled", severity: .critical, title: "c", message: ""),
            AppWarning(id: "hotspot", severity: .warning, title: "d", message: ""),
            AppWarning(id: "dry-run", severity: .critical, title: "dup", message: ""),
            AppWarning(id: "disarm-failed", severity: .critical, title: "e", message: ""),
        ]
        #expect(WarningList.sorted(warnings).map(\.id) == ["kernel-sleep-disabled", "disarm-failed", "privileged-missing", "hotspot", "dry-run"])
        #expect(WarningList.sorted([]).isEmpty)
        #expect(WarningList.forMenu(warnings, dryRunBannerShown: true).map(\.id)
            == ["kernel-sleep-disabled", "disarm-failed", "privileged-missing", "hotspot"], "the banner already says dry run")
        #expect(WarningList.forMenu(warnings, dryRunBannerShown: false).map(\.id) == WarningList.sorted(warnings).map(\.id))
        #expect(WarningList.tone(.critical) == .critical)
        #expect(WarningList.tone(.warning) == .attention)
    }

    // MARK: Privileged status

    @Test func privilegedSummaries() {
        #expect(PrivilegedSummary.make(.simulatedForDryRun(at: fixedNow)) ==
                PrivilegedSummary(text: "Closed-lid mode", tone: .attention, offersInstall: false, isSimulated: true))
        #expect(PrivilegedSummary.make(PrivilegedStatus(sudoRuleInstalled: true, failsafeLoaded: true, checkedAt: fixedNow)).text == "Closed-lid mode ready")
        let damaged = PrivilegedSummary.make(PrivilegedStatus(sudoRuleInstalled: true, failsafeLoaded: true, checkedAt: fixedNow,
                                                               failsafeScriptMismatch: true))
        #expect(damaged.tone == .critical && damaged.offersInstall && damaged.text.contains("reinstalling"))
        let mismatch = PrivilegedSummary.make(PrivilegedStatus(sudoRuleInstalled: true, failsafeLoaded: true, checkedAt: fixedNow, heartbeatPathMismatch: true))
        #expect(mismatch.offersInstall && mismatch.tone == .critical)
        #expect(PrivilegedSummary.make(.unknown).text == "Checking closed-lid mode…")
        #expect(PrivilegedSummary.make(PrivilegedStatus(sudoRuleInstalled: true, failsafeLoaded: false, checkedAt: fixedNow)).text
            == "Closed-lid mode incomplete (fail-safe missing)")
        let missing = PrivilegedSummary.make(PrivilegedStatus(sudoRuleInstalled: false, failsafeLoaded: false, checkedAt: fixedNow))
        #expect(missing.text == "Closed-lid mode not installed · notifications only")
        #expect(missing.offersInstall)
    }

    // MARK: Paused apps, phone, dry run, resume

    @Test func pausedAppRows() {
        let rows = sample().pausedApps.map { PausedAppRowModel.make($0, now: fixedNow) }
        #expect(rows.first?.name == "Arc")
        #expect(rows.first?.detail == "Throttled · 14 processes · 1m")
        let frozen = PausedApp(appPID: 1, bundleID: nil, name: "Word", mode: .freeze, memberCount: 1, pausedAt: fixedNow,
                               downgradedBecause: .download)
        #expect(PausedAppRowModel.make(frozen, now: fixedNow).detail == "Frozen · 0s (downloading)")
        #expect(PausedAppRowModel.sectionTitle(count: 2) == "Paused apps (2)")
        #expect(PausedAppRowModel.modeText(.quit) == "Quit to free memory")
    }

    @Test func alertsSummaries() {
        var settings = NotificationSettings()
        settings.phoneTiming = .always // its note is checked on its own below
        let phone = PhoneDevice(deviceID: "p", name: "iPhone", model: "iPhone18,3", systemVersion: "26.6.1", appVersion: "0.1.0",
                                alertsAuthorized: true, lastSeenAt: fixedNow.addingTimeInterval(-180))
        let fresh = AlertsSummary.make(.initial, settings: settings)
        #expect(fresh.text == "Notifications not set up" && !fresh.isReady && fresh.tone == .muted)
        let both = AlertsSummary.make(NotificationStatus(macAuthorization: .authorized, iCloud: .available, phones: [phone]), settings: settings)
        #expect(both.text == "Alerts on this Mac and your iPhone" && both.isReady && both.tone == .success && both.detail == nil)
        var away = settings
        away.phoneTiming = .away
        #expect(AlertsSummary.make(NotificationStatus(macAuthorization: .authorized, iCloud: .available, phones: [phone]), settings: away)
            .detail == "iPhone only when you're away")
        var lidGated = settings
        lidGated.phoneTiming = .lidClosed
        let gated = AlertsSummary.make(NotificationStatus(macAuthorization: .authorized, iCloud: .available, phones: [phone]), settings: lidGated)
        #expect(gated.text == "Alerts on this Mac and your iPhone" && gated.detail == "iPhone only with the lid closed" && gated.tone == .success)
        #expect(AlertsSummary.make(NotificationStatus(macAuthorization: .authorized, iCloud: .available), settings: lidGated).detail == "no iPhone yet")
        let two = AlertsSummary.make(NotificationStatus(macAuthorization: .authorized, iCloud: .available, phones: [phone, phone]), settings: settings)
        #expect(two.text == "Alerts on this Mac and 2 iPhones")
        let macOnly = AlertsSummary.make(NotificationStatus(macAuthorization: .authorized, iCloud: .available, outboxCount: 2), settings: settings)
        #expect(macOnly.text == "Alerts on this Mac" && macOnly.detail == "no iPhone yet · 2 waiting for iCloud")
        let phoneOnly = AlertsSummary.make(NotificationStatus(macAuthorization: .denied, iCloud: .available, phones: [phone]), settings: settings)
        #expect(phoneOnly.text == "Alerts on your iPhone" && phoneOnly.detail == "Mac notifications are off in System Settings")
        let signedOut = AlertsSummary.make(NotificationStatus(macAuthorization: .authorized, iCloud: .noAccount, phones: [phone]), settings: settings)
        #expect(signedOut.text == "Alerts on this Mac" && signedOut.detail == "sign in to iCloud for iPhone alerts")
        var muted = phone
        muted.alertsAuthorized = false
        let failing = AlertsSummary.make(NotificationStatus(macAuthorization: .authorized, iCloud: .available, phones: [muted],
                                                            lastError: "Your iCloud storage is full."), settings: settings)
        #expect(failing.detail == "notifications are off on an iPhone · Your iCloud storage is full.")
        #expect(failing.tone == .attention)
        var off = settings
        off.enabled = false
        #expect(AlertsSummary.make(NotificationStatus(macAuthorization: .authorized), settings: off).text == "Notifications off")
        var macOff = settings
        macOff.macAlerts = false
        #expect(AlertsSummary.make(NotificationStatus(macAuthorization: .authorized), settings: macOff).text == "Notifications not set up")
        #expect(AlertsSummary.phoneLine(phone, now: fixedNow) == "iPhone · seen 3m ago")
        var justSeen = phone
        justSeen.lastSeenAt = fixedNow.addingTimeInterval(-20)
        #expect(AlertsSummary.phoneLine(justSeen, now: fixedNow) == "iPhone · seen just now")
        #expect(AlertsSummary.macPermissionText(.denied) == "Off in System Settings")
    }

    @Test func warningsLinkToWhereTheyAreFixed() {
        func fix(_ id: String) -> WarningFix? {
            WarningList.fix(for: AppWarning(id: id, severity: .warning, title: "t", message: "m"))
        }
        #expect(fix("integration-repair:claude") == .settings(.integrations))
        #expect(fix("integration-repair:claude")?.title == "Repair…")
        #expect(fix("privileged-missing") == .settings(.closedLid))
        #expect(fix("failsafe-damaged")?.title == "Open Closed Lid & Safety…")
        #expect(fix("mac-notifications-off") == .systemNotificationSettings)
        #expect(fix("icloud-unavailable") == .settings(.notifications))
        #expect(fix("freeze-unavailable") == .settings(.pausing))
        #expect(fix("hotspot") == nil, "nothing to change in Kakureneko")
        #expect(fix("kernel-sleep-disabled") == nil, "the fail-safe clears it by itself")
    }

    @Test func menuLayoutKeepsTheSessionsVisible() {
        // The sessions list keeps room for up to two rows however short the screen, and never grows past its rows.
        #expect(SessionRowModel.minimumListHeight(rowCount: 0) == 0)
        #expect(SessionRowModel.minimumListHeight(rowCount: 1) == 48)
        #expect(SessionRowModel.minimumListHeight(rowCount: 5) == 96)
        #expect(SessionRowModel.listMaximumHeight(rowsHeight: 0) == 264, "not measured yet")
        #expect(SessionRowModel.listMaximumHeight(rowsHeight: 110) == 110)
        #expect(SessionRowModel.listMaximumHeight(rowsHeight: 900) == 264)
        #expect(PausedAppRowModel.listMaximumHeight == 3 * PausedAppRowModel.rowHeight)
        // Informational notices (Low Power Mode, dry run, …) take one line; warnings keep their full text.
        let info = AppWarning(id: "low-power-mode", severity: .info, title: "Low Power Mode: agents run slower", message: "m")
        #expect(WarningList.isCompact(info))
        #expect(!WarningList.isCompact(AppWarning(id: "hotspot", severity: .warning, title: "On a phone hotspot", message: "m")))
        #expect(!WarningList.isCompact(AppWarning(id: "disarm-failed", severity: .critical, title: "t", message: "m")))
    }

    @Test func settingsSayWhereTheyApply() {
        #expect(PhoneAlertTiming.allCases.map(PhoneTimingText.title) == ["Only when the lid is closed", "When I'm away from the Mac", "Always"])
        #expect(PhoneAlertTiming.allCases.allSatisfy { !PhoneTimingText.explanation($0).isEmpty })
        #expect(PhoneTimingText.menuNote(.always) == nil)
        #expect(PhoneTimingText.footnote.contains("always reach the iPhone"))
        #expect([SettingScope.mac, .phone, .both].map(\.title) == ["This Mac", "iPhone", "Mac & iPhone"])
        #expect(SettingsCatalog.all.contains { $0.id == SettingsCatalog.awayIdle.id }, "still range-checked")
    }

    @Test func minimumWorkChoices() {
        let choices = SettingsCatalog.minimumWorkChoices(current: 0)
        #expect(choices.map(\.label) == ["Every turn", "30 s", "1 min", "2 min", "5 min", "10 min", "15 min", "30 min", "1 h"])
        let custom = SettingsCatalog.minimumWorkChoices(current: 450)
        #expect(custom.count == 10 && custom.contains { $0.seconds == 450 && $0.label == "7 min 30 s" }, "a hand-set value stays visible")
        #expect(custom.map(\.seconds) == custom.map(\.seconds).sorted())
    }

    @Test func dryRunFeedMergesOrdersAndLimits() {
        let ledger = [
            DryRunEntry(id: 1, at: fixedNow, category: .power, action: "power.arm", detail: "would arm"),
            DryRunEntry(id: 2, at: fixedNow.addingTimeInterval(120), category: .power, action: "power.sleep", detail: "would sleep the Mac now"),
        ]
        let local = [DryRunEntry(id: 1, at: fixedNow.addingTimeInterval(60), category: .app, action: "app.loginItem", detail: "would register login item")]
        let feed = DryRunLine.feed(ledger: ledger, local: local, limit: 10, timeZone: utc)
        #expect(feed.map(\.text) == ["would arm", "would register login item", "would sleep the Mac now"])
        #expect(feed.map(\.time) == ["22:00", "22:01", "22:02"])
        #expect(Set(feed.map(\.id)).count == 3)
        #expect(DryRunLine.feed(ledger: ledger, local: local, limit: 2, timeZone: utc).map(\.action) == ["app.loginItem", "power.sleep"])
        #expect(DryRunLine.feed(ledger: [], local: [], limit: 3).isEmpty)
        #expect(DryRunLine.title(forced: true).contains("KAKURENEKO_DRY_RUN"))
    }

    @Test func resumeOfferText() {
        let entries = [ResumeEntry(agent: .claude, sessionId: "a", cwd: "/x/api", title: nil),
                       ResumeEntry(agent: .claude, sessionId: "b", cwd: "/x/web", title: "Fix login")]
        #expect(ResumeOfferText.title(count: 1) == "Reopen the session from before the shutdown?")
        #expect(ResumeOfferText.title(count: 2) == "Reopen 2 sessions from before the shutdown?")
        #expect(ResumeOfferText.detail(entries) == "api (Claude Code), Fix login (Claude Code)")
    }

    @Test func errorTexts() {
        #expect(ErrorText.describe(SideEffectError.timedOut) == "Timed out")
        #expect(ErrorText.describe(DeliveryError.permanent("HTTP 403")) == "iCloud refused the request: HTTP 403")
        #expect(ErrorText.describe(DeliveryError.retryable(after: nil)) == "iCloud could not be reached. Kakureneko retries automatically.")
        #expect(ErrorText.describe(CancellationError()) == "Cancelled.")
        #expect(!ErrorText.describe(NSError(domain: "x", code: 1)).isEmpty)
    }

    @Test func settingDurations() {
        #expect(DurationText.settingMinutes(5) == "5 min")
        #expect(DurationText.settingMinutes(120) == "2 h")
        #expect(DurationText.elapsed(since: fixedNow.addingTimeInterval(10), now: fixedNow) == "0s")
    }
}
