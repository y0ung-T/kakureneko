// Pure view-model formatting for the menu bar item and the menu window.
//
// Everything here is a deterministic function of an `AppSnapshot` (or one of its parts) and an explicit `now`,
// so the tests can pin every string against `PreviewKakurenekoController` snapshots. Views only map `Tone` to a
// color and lay the strings out; they never format on their own.

import KakurenekoCloud
import KakurenekoKit
import Foundation

/// Visual tone of a row, badge or banner: the design language's state set (DESIGN.md §2.1; the views map it to its
/// fill, text and tint colours).
nonisolated enum Tone: String, Sendable, Hashable {
    /// Idle: nothing happening.
    case neutral
    /// An agent is working, the Mac stays awake (amber).
    case working
    /// An agent needs you (pink: normal, not a warning).
    case waiting
    /// A sleep or shutdown countdown (violet).
    case drowsy
    /// Going to sleep, asleep (indigo).
    case asleep
    /// A warning (orange).
    case attention
    /// A safety stop, an error, shutting down (red).
    case critical
    /// Done, ready (green).
    case success
    /// Off.
    case muted
}

// MARK: - Durations

nonisolated enum DurationText {
    /// Live countdown: `4:12`, `0:05`, `1:02:03` (never negative).
    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        let paddedSeconds = secs < 10 ? "0\(secs)" : "\(secs)"
        if hours > 0 {
            let paddedMinutes = minutes < 10 ? "0\(minutes)" : "\(minutes)"
            return "\(hours):\(paddedMinutes):\(paddedSeconds)"
        }
        return "\(minutes):\(paddedSeconds)"
    }

    /// `42m` since `date` (clamped at 0), using the shared `KakurenekoFormat.shortDuration`.
    static func elapsed(since date: Date, now: Date) -> String {
        KakurenekoFormat.shortDuration(max(0, now.timeIntervalSince(date)))
    }

    /// Human duration for settings values given in seconds: `45 s`, `5 min`, `1 h`, `1 h 30 min`.
    static func settingSeconds(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        if seconds % 60 != 0 { return "\(seconds / 60) min \(seconds % 60) s" }
        return settingMinutes(seconds / 60)
    }

    /// Human duration for settings values given in minutes: `5 min`, `1 h`, `2 h 30 min`.
    static func settingMinutes(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}

// MARK: - Header and menu bar icon

nonisolated enum HeaderText {
    /// Subtitle under the app name in the menu header.
    static func subtitle(for snapshot: AppSnapshot) -> String {
        switch snapshot.mode {
        case .starting:
            return "Starting…"
        case .disabled:
            return "Off · your Mac sleeps as usual"
        case .full, .notificationsOnly:
            let status = snapshot.statusLine
            let base = status == "Idle" ? "No agent is working" : status
            return snapshot.mode == .notificationsOnly ? "\(base) · notifications only" : base
        }
    }
}

/// The menu bar glyph: working / waiting / closed-lid armed / countdown / disabled (spec card §9.9). `imageName` is
/// the cat-head template image (`Resources/MenuBar/<name>.png`, DESIGN.md §6.2); `symbolName` the SF Symbol used
/// when the artwork is missing (outside the app bundle).
nonisolated struct MenuBarIcon: Sendable, Hashable {
    var imageName: String
    var symbolName: String
    var accessibilityLabel: String

    /// Every symbol the label can show (tests check they all resolve on this macOS).
    static let allSymbolNames = [
        "laptopcomputer.slash", "moon.zzz.fill", "power", "hourglass",
        "laptopcomputer.trianglebadge.exclamationmark", "hand.raised.fill", "cup.and.heat.waves.fill",
        "cup.and.saucer.fill", "laptopcomputer",
    ]

    /// Every template image (tests check each has a 1x and a 2x file in Resources/MenuBar).
    static let allImageNames = ["off", "asleep", "shutdown", "countdown", "attention", "waiting", "working", "keepawake", "idle"]

    static func make(snapshot: AppSnapshot, now: Date) -> MenuBarIcon {
        if snapshot.mode == .disabled {
            return MenuBarIcon(imageName: "off", symbolName: "laptopcomputer.slash", accessibilityLabel: "Kakureneko is off")
        }
        switch snapshot.powerPhase {
        case .windingDown:
            return MenuBarIcon(imageName: "asleep", symbolName: "moon.zzz.fill", accessibilityLabel: "Kakureneko: going to sleep")
        case .shutdownPending:
            return MenuBarIcon(imageName: "shutdown", symbolName: "power", accessibilityLabel: "Kakureneko: shutting down soon")
        case .countdown:
            return MenuBarIcon(imageName: "countdown", symbolName: "hourglass", accessibilityLabel: "Kakureneko: sleep countdown")
        case .disarmed, .armed, .closedAwake:
            break
        }
        if snapshot.warnings.contains(where: { $0.severity == .critical }) {
            return MenuBarIcon(imageName: "attention", symbolName: "laptopcomputer.trianglebadge.exclamationmark",
                               accessibilityLabel: "Kakureneko needs attention")
        }
        if snapshot.aggregate.anyWaiting {
            return MenuBarIcon(imageName: "waiting", symbolName: "hand.raised.fill",
                               accessibilityLabel: "Kakureneko: an agent is waiting for you")
        }
        if snapshot.aggregate.anyWorking {
            let armed = snapshot.powerPhase.isArmed
            return MenuBarIcon(imageName: "working", symbolName: "cup.and.heat.waves.fill",
                               accessibilityLabel: armed ? "Kakureneko: agents working, staying awake with the lid closed"
                                                         : "Kakureneko: agents working")
        }
        if let until = snapshot.keepAwakeUntil, until > now {
            return MenuBarIcon(imageName: "keepawake", symbolName: "cup.and.saucer.fill",
                               accessibilityLabel: "Kakureneko: keeping your Mac awake")
        }
        return MenuBarIcon(imageName: "idle", symbolName: "laptopcomputer", accessibilityLabel: "Kakureneko: idle")
    }
}

// MARK: - Sessions

/// One row in the sessions list.
nonisolated struct SessionRowModel: Sendable, Hashable, Identifiable {
    /// The sessions list never shrinks below this (up to two rows), however short the screen: under height
    /// pressure the other sections give way (a row is ≈ 46 pt, one with a waiting line ≈ 62 pt).
    static func minimumListHeight(rowCount: Int) -> CGFloat { CGFloat(min(rowCount, 2)) * 48 }

    /// The list scrolls beyond 264 pt and is never taller than its rows (0 = not measured yet).
    static func listMaximumHeight(rowsHeight: CGFloat) -> CGFloat { rowsHeight > 0 ? min(rowsHeight, 264) : 264 }

    var id: SessionKey
    /// `Refactor auth middleware` (title → project → agent).
    var title: String
    /// `Claude Code · api · Terminal`.
    var subtitle: String
    /// `Working · 42m`.
    var statusText: String
    /// Waiting text, outcome or stall explanation.
    var detail: String?
    var tone: Tone
    /// Stuck sessions get a visible dismiss button (all rows offer it in their context menu).
    var canDismiss: Bool

    static func rows(for snapshot: AppSnapshot, now: Date) -> [SessionRowModel] {
        snapshot.sessions.filter { !$0.state.isEnded }.map { make($0, now: now) }
    }

    static func make(_ session: AgentSession, now: Date) -> SessionRowModel {
        let agentName = session.agent.displayName
        let title = session.displayTitle
        var parts = [agentName]
        if let project = session.projectName, project != title { parts.append(project) }
        if let host = session.host?.name, !host.isEmpty, host != agentName { parts.append(host) }
        let subtitle = parts.joined(separator: " · ")

        var detail: String?
        let status: String
        let tone: Tone
        switch session.state {
        case .working(let since):
            status = "Working · \(DurationText.elapsed(since: since, now: now))"
            tone = .working
            if session.isHeuristicOnly { detail = "Detected from activity" }
        case .settling:
            status = "Finishing…"
            tone = .working
        case .waiting(let kind, let since):
            status = "Waiting · \(DurationText.elapsed(since: since, now: now))"
            tone = .waiting
            detail = clean(session.waitingFor) ?? waitingText(kind)
        case .idle(let since, let outcome):
            status = "Idle · \(DurationText.elapsed(since: since, now: now))"
            tone = .neutral
            detail = outcomeText(outcome, lastTurn: session.lastTurnDuration)
        case .stalled(let since):
            status = "Stuck · \(DurationText.elapsed(since: since, now: now))"
            tone = .attention
            detail = "No activity, so it no longer keeps your Mac awake"
        case .ended:
            status = "Ended"
            tone = .muted
        }
        return SessionRowModel(id: session.key, title: title, subtitle: subtitle, statusText: status,
                               detail: detail, tone: tone, canDismiss: session.state.isStalled)
    }

    static func waitingText(_ kind: NeedsInputKind) -> String {
        switch kind {
        case .permission: "Waiting for permission"
        case .question: "Has a question for you"
        case .dialog: "Waiting in a dialog"
        case .unknown: "Waiting for you"
        }
    }

    static func outcomeText(_ outcome: TurnOutcome?, lastTurn: TimeInterval?) -> String? {
        let base: String
        switch outcome {
        case .completed: base = "Finished"
        case .interrupted: base = "Interrupted"
        case .error: base = "Stopped with an error"
        case .rateLimited: base = "Hit a rate limit"
        case .ambiguous: base = "Finished or waiting for you"
        case nil: return lastTurn.map { "Last turn took \(KakurenekoFormat.shortDuration($0))" }
        }
        guard let lastTurn, outcome == .completed || outcome == .error else { return base }
        return "\(base) after \(KakurenekoFormat.shortDuration(lastTurn))"
    }

    private static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - Power phase

/// Buttons the power card offers.
nonisolated struct PhaseActions: OptionSet, Sendable, Hashable {
    let rawValue: Int
    static let keepAwake = PhaseActions(rawValue: 1 << 0)
    static let sleepNow = PhaseActions(rawValue: 1 << 1)
    static let cancelWindDown = PhaseActions(rawValue: 1 << 2)
    static let cancelKeepAwake = PhaseActions(rawValue: 1 << 3)
}

/// The power card: phase title, explanation, live deadline and the buttons that apply.
nonisolated struct PhaseSummary: Sendable, Hashable {
    var title: String
    var detail: String
    var tone: Tone
    var symbolName: String
    /// Countdown or shutdown deadline (the view refreshes the title every second).
    var deadline: Date?
    var actions: PhaseActions

    /// The keep-awake menu offers these durations (spec: 15 min / 1 h / 2 h).
    static let keepAwakeOptions: [(seconds: TimeInterval, title: String)] = [
        (15 * 60, "15 minutes"), (3600, "1 hour"), (2 * 3600, "2 hours"),
    ]

    static func make(snapshot: AppSnapshot, now: Date) -> PhaseSummary {
        var actions: PhaseActions = [.keepAwake, .sleepNow]
        var summary: PhaseSummary
        switch snapshot.powerPhase {
        case .disarmed:
            if snapshot.mode == .disabled {
                summary = PhaseSummary(title: "Kakureneko is off", detail: "Your Mac sleeps as usual when the lid closes.",
                                       tone: .muted, symbolName: "laptopcomputer.slash", deadline: nil, actions: actions)
            } else if snapshot.mode == .notificationsOnly {
                summary = PhaseSummary(title: "Notifications only",
                                       detail: "Closing the lid sleeps your Mac. Install closed-lid mode to keep agents running.",
                                       tone: .attention, symbolName: "bell.badge.fill", deadline: nil, actions: actions)
            } else if snapshot.aggregate.anyWorking {
                summary = PhaseSummary(title: "Getting ready to stay awake", detail: "An agent is working.",
                                       tone: .working, symbolName: "cup.and.heat.waves.fill", deadline: nil, actions: actions)
            } else {
                summary = PhaseSummary(title: "Normal sleep", detail: "Nothing is working, so your Mac sleeps as usual.",
                                       tone: .neutral, symbolName: "moon.fill", deadline: nil, actions: actions)
            }
        case .armed(let since):
            summary = PhaseSummary(title: "Stays awake with the lid closed",
                                   detail: "Armed for \(DurationText.elapsed(since: since, now: now)).",
                                   tone: .working, symbolName: "cup.and.heat.waves.fill", deadline: nil, actions: actions)
        case .closedAwake(let since):
            summary = PhaseSummary(title: "Lid closed, staying awake",
                                   detail: "For \(DurationText.elapsed(since: since, now: now)) so far.",
                                   tone: .working, symbolName: "moon.stars.fill", deadline: nil, actions: actions)
        case .countdown(let endsAt, let reason, _):
            summary = PhaseSummary(title: "Sleeping in \(DurationText.countdown(endsAt.timeIntervalSince(now)))",
                                   detail: countdownReason(reason), tone: .drowsy, symbolName: "timer",
                                   deadline: endsAt, actions: actions)
        case .shutdownPending(let at, let fromPhone):
            actions = [.cancelWindDown]
            summary = PhaseSummary(title: "Shutting down in \(DurationText.countdown(at.timeIntervalSince(now)))",
                                   detail: fromPhone ? "Requested from your phone." : "All agents are done.",
                                   tone: .critical, symbolName: "power", deadline: at, actions: actions)
        case .windingDown(let reason, _):
            actions = [.cancelWindDown]
            summary = PhaseSummary(title: windDownTitle(reason), detail: windDownReason(reason), tone: windDownTone(reason),
                                   symbolName: "moon.zzz.fill", deadline: nil, actions: actions)
        }
        if let until = snapshot.keepAwakeUntil, until > now {
            summary.actions.insert(.cancelKeepAwake)
        }
        return summary
    }

    static func countdownReason(_ reason: CountdownReason) -> String {
        switch reason {
        case .finished: "All agents are done."
        case .needsInput: "An agent is waiting for you."
        case .wentQuiet: "Your agents went quiet."
        }
    }

    /// Shutting down and safety stops are critical; any other wind-down is the Mac going to sleep.
    static func windDownTone(_ reason: WindDownReason) -> Tone {
        switch reason {
        case .remoteShutdown, .safetyTrip: .critical
        default: .asleep
        }
    }

    static func windDownTitle(_ reason: WindDownReason) -> String {
        if case .remoteShutdown = reason { return "Shutting down…" }
        return "Going to sleep…"
    }

    static func windDownReason(_ reason: WindDownReason) -> String {
        switch reason {
        case .countdownElapsed: "The countdown finished."
        case .userSleepNow: "You chose Sleep now."
        case .remoteSleep: "Requested from your phone."
        case .remoteShutdown: "Requested from your phone."
        case .safetyTrip(let trip): "Safety: \(trip.userReason)."
        }
    }
}

nonisolated enum KeepAwakeText {
    /// `Kept awake until 15:02 · 58m left`, nil when no override is active.
    static func make(until: Date?, now: Date, timeZone: TimeZone = .current) -> String? {
        guard let until, until > now else { return nil }
        let left = KakurenekoFormat.shortDuration(until.timeIntervalSince(now))
        return "Kept awake until \(KakurenekoFormat.clockTime(until, timeZone: timeZone)) · \(left) left"
    }
}

// MARK: - Privileged status

nonisolated struct PrivilegedSummary: Sendable, Hashable {
    var text: String
    var tone: Tone
    /// Show the "Install…" affordance.
    var offersInstall: Bool
    /// Show the "simulated" badge (dry-run substitute status).
    var isSimulated: Bool

    static func make(_ status: PrivilegedStatus) -> PrivilegedSummary {
        if status.simulated {
            return PrivilegedSummary(text: "Closed-lid mode", tone: .attention, offersInstall: false, isSimulated: true)
        }
        if status.isOperational {
            return PrivilegedSummary(text: "Closed-lid mode ready", tone: .success, offersInstall: false, isSimulated: false)
        }
        if status.heartbeatPathMismatch {
            return PrivilegedSummary(text: "Closed-lid mode needs reinstalling (fail-safe watches another heartbeat)",
                                     tone: .critical, offersInstall: true, isSimulated: false)
        }
        if status.failsafeScriptMismatch {
            return PrivilegedSummary(text: "Closed-lid mode needs reinstalling (fail-safe missing or damaged)",
                                     tone: .critical, offersInstall: true, isSimulated: false)
        }
        if status.checkedAt == nil {
            return PrivilegedSummary(text: "Checking closed-lid mode…", tone: .muted, offersInstall: false, isSimulated: false)
        }
        if status.sudoRuleInstalled != status.failsafeLoaded {
            let missing = status.sudoRuleInstalled ? "fail-safe" : "sleep rule"
            return PrivilegedSummary(text: "Closed-lid mode incomplete (\(missing) missing)", tone: .critical,
                                     offersInstall: true, isSimulated: false)
        }
        return PrivilegedSummary(text: "Closed-lid mode not installed · notifications only", tone: .attention,
                                 offersInstall: true, isSimulated: false)
    }
}

// MARK: - Warnings

/// Where a warning's fix lives: a settings pane, or System Settings → Notifications.
nonisolated enum WarningFix: Sendable, Hashable {
    case settings(SettingsPane)
    case systemNotificationSettings

    /// The link under the warning in the menu.
    var title: String {
        switch self {
        case .settings(.integrations): "Repair…"
        case .settings(let pane): "Open \(pane.title)…"
        case .systemNotificationSettings: "Open System Settings…"
        }
    }
}

nonisolated enum WarningList {
    /// The fix for a warning (`AppWarning.id`, see its doc comment), or nil when there is nothing to change (a
    /// hotspot, Low Power Mode, the critical kernel flag the fail-safe clears by itself).
    static func fix(for warning: AppWarning) -> WarningFix? {
        if warning.id.hasPrefix("integration-repair:") { return .settings(.integrations) }
        switch warning.id {
        case "privileged-missing", "failsafe-damaged", "arming-blocked", "disarm-failed", "heartbeat-path-mismatch":
            return .settings(.closedLid)
        case "mac-notifications-off": return .systemNotificationSettings
        case "icloud-unavailable", "phone-alerts-error": return .settings(.notifications)
        case "app-tamer", "freeze-unavailable": return .settings(.pausing)
        case "dry-run", "dry-run-privileged-simulated": return .settings(.advanced)
        default: return nil
        }
    }

    /// Informational notices take one line (their explanation is the tooltip); warnings and critical ones keep
    /// their full text.
    static func isCompact(_ warning: AppWarning) -> Bool { warning.severity == .info }

    /// Critical first, then warnings, then info; stable within a severity; duplicate ids dropped (first wins).
    static func sorted(_ warnings: [AppWarning]) -> [AppWarning] {
        var seen = Set<String>()
        let unique = warnings.filter { seen.insert($0.id).inserted }
        return unique.enumerated().sorted { lhs, rhs in
            let l = rank(lhs.element.severity)
            let r = rank(rhs.element.severity)
            return l != r ? l < r : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// The menu's list: `sorted`, without the `dry-run` warning while the menu's dry-run banner already says it.
    static func forMenu(_ warnings: [AppWarning], dryRunBannerShown: Bool) -> [AppWarning] {
        sorted(warnings).filter { !(dryRunBannerShown && $0.id == dryRunWarningID) }
    }

    /// `AppWarning.id` of the coordinator's dry-run notice (SnapshotBuilder).
    static let dryRunWarningID = "dry-run"

    static func rank(_ severity: AppWarning.Severity) -> Int {
        switch severity {
        case .critical: 0
        case .warning: 1
        case .info: 2
        }
    }

    static func tone(_ severity: AppWarning.Severity) -> Tone {
        switch severity {
        case .critical: .critical
        case .warning: .attention
        case .info: .neutral
        }
    }

    static func symbol(_ severity: AppWarning.Severity) -> String {
        switch severity {
        case .critical: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }
}

// MARK: - Paused apps

nonisolated struct PausedAppRowModel: Sendable, Hashable, Identifiable {
    /// One row (name + detail line + spacing), and the list's height before it scrolls (≈ 3 rows).
    static let rowHeight: CGFloat = 38
    static let listMaximumHeight: CGFloat = 3 * rowHeight

    var id: Int32
    var name: String
    var detail: String
    var bundleID: String?

    static func make(_ app: PausedApp, now: Date) -> PausedAppRowModel {
        var parts = [modeText(app.mode)]
        if app.memberCount > 1 { parts.append("\(app.memberCount) processes") }
        parts.append(DurationText.elapsed(since: app.pausedAt, now: now))
        var detail = parts.joined(separator: " · ")
        if let reason = app.downgradedBecause { detail += " (\(reason.explanation))" }
        return PausedAppRowModel(id: app.appPID, name: app.name, detail: detail, bundleID: app.bundleID)
    }

    static func modeText(_ mode: PauseMode) -> String {
        switch mode {
        case .throttle: "Throttled"
        case .freeze: "Frozen"
        case .quit: "Quit to free memory"
        }
    }

    /// Section title: `Paused apps (2)`.
    static func sectionTitle(count: Int) -> String { count == 0 ? "Paused apps" : "Paused apps (\(count))" }

    /// The note under the list while the Mac counts down to sleep or shutdown (paused apps are thawed first).
    static func footnote(for phase: PowerPhase) -> String? {
        switch phase {
        case .countdown: "Everything resumes before the Mac sleeps."
        case .shutdownPending: "Everything resumes before the Mac shuts down."
        default: nil
        }
    }
}

// MARK: - Alerts (Mac + iPhone)

/// Where alerts show, for the menu row and the Notifications pane: "Alerts on this Mac and your iPhone".
nonisolated struct AlertsSummary: Sendable, Hashable {
    var text: String
    var detail: String?
    var tone: Tone
    /// At least one channel shows alerts (the menu offers "Send test" instead of "Set up…").
    var isReady: Bool

    static func make(_ status: NotificationStatus, settings: NotificationSettings) -> AlertsSummary {
        guard settings.enabled else {
            return AlertsSummary(text: "Notifications off", detail: nil, tone: .muted, isReady: false)
        }
        let onMac = settings.macAlerts && status.macAuthorization.canPost
        let phones = settings.phoneAlerts && status.iCloud.isAvailable ? status.phones : []
        let text: String
        switch (onMac, phones.count) {
        case (true, 0): text = "Alerts on this Mac"
        case (true, 1): text = "Alerts on this Mac and your iPhone"
        case (true, let n): text = "Alerts on this Mac and \(n) iPhones"
        case (false, 0): text = "Notifications not set up"
        case (false, 1): text = "Alerts on your iPhone"
        case (false, let n): text = "Alerts on \(n) iPhones"
        }
        var details: [String] = []
        if settings.macAlerts, status.macAuthorization == .denied { details.append("Mac notifications are off in System Settings") }
        if settings.phoneAlerts {
            switch status.iCloud {
            case .noAccount: details.append("sign in to iCloud for iPhone alerts")
            case .restricted: details.append("iCloud is restricted")
            case .unavailableInThisBuild: details.append("this build has no iCloud")
            case .available: if phones.isEmpty { details.append("no iPhone yet") }
            case .temporarilyUnavailable, .couldNotDetermine: break
            }
            if phones.contains(where: { !$0.alertsAuthorized }) { details.append("notifications are off on an iPhone") }
            if !phones.isEmpty, let note = PhoneTimingText.menuNote(settings.phoneTiming) { details.append(note) }
        }
        if status.outboxCount > 0 { details.append("\(status.outboxCount) waiting for iCloud") }
        if let error = status.lastError, !error.isEmpty { details.append(error) }
        let ready = onMac || !phones.isEmpty
        let tone: Tone = !ready ? (status.lastError == nil ? .muted : .critical) : (status.lastError == nil ? .success : .attention)
        return AlertsSummary(text: text, detail: details.isEmpty ? nil : details.joined(separator: " · "), tone: tone, isReady: ready)
    }

    /// "iPhone18,3 · seen 3 min ago".
    /// "iPhone · seen 3m ago" ("seen just now" under a minute). iOS only gives apps the name "iPhone"; the model is a
    /// code like "iPhone18,3", so it's left out.
    static func phoneLine(_ phone: PhoneDevice, now: Date) -> String {
        let name = phone.name.isEmpty ? "iPhone" : phone.name
        let age = now.timeIntervalSince(phone.lastSeenAt)
        let seen = age < 60 ? "seen just now" : "seen \(DurationText.elapsed(since: phone.lastSeenAt, now: now)) ago"
        return "\(name) · \(seen)"
    }

    /// "Allowed", "Off in System Settings", …
    static func macPermissionText(_ authorization: MacAlertAuthorization) -> String {
        switch authorization {
        case .authorized: "Allowed"
        case .provisional: "Delivered quietly"
        case .denied: "Off in System Settings"
        case .notDetermined: "Not allowed yet"
        case .unavailable: "Unavailable in this build"
        }
    }
}

// MARK: - Dry run

/// One line of the dry-run banner (coordinator ledger + the app's own "would …" lines).
nonisolated struct DryRunLine: Sendable, Hashable, Identifiable {
    var id: String
    var at: Date
    var time: String
    var text: String
    var action: String

    /// Newest last, at most `limit` lines. `local` are the app's own entries (login item, consent, reopen).
    static func feed(ledger: [DryRunEntry], local: [DryRunEntry], limit: Int, timeZone: TimeZone = .current) -> [DryRunLine] {
        let tagged = ledger.map { ("c\($0.id)", $0) } + local.map { ("a\($0.id)", $0) }
        let ordered = tagged.enumerated().sorted { lhs, rhs in
            lhs.element.1.at != rhs.element.1.at ? lhs.element.1.at < rhs.element.1.at : lhs.offset < rhs.offset
        }.map(\.element)
        return ordered.suffix(max(0, limit)).map { id, entry in
            DryRunLine(id: id, at: entry.at, time: KakurenekoFormat.clockTime(entry.at, timeZone: timeZone),
                       text: entry.detail.isEmpty ? entry.action : entry.detail, action: entry.action)
        }
    }

    /// Banner title.
    static func title(forced: Bool) -> String {
        forced ? "Dry run (KAKURENEKO_DRY_RUN) · nothing is changed" : "Dry run · nothing is changed"
    }
}

// MARK: - Resume offer

nonisolated enum ResumeOfferText {
    static func title(count: Int) -> String {
        count == 1 ? "Reopen the session from before the shutdown?" : "Reopen \(count) sessions from before the shutdown?"
    }

    /// `api (Claude Code), web (Claude Code)`.
    static func detail(_ entries: [ResumeEntry]) -> String {
        entries.map { entry in
            let name = entry.title ?? KakurenekoFormat.projectName(fromCwd: entry.cwd) ?? entry.agent.displayName
            return "\(name) (\(entry.agent.displayName))"
        }.joined(separator: ", ")
    }
}
