// How the model's values read on screen: phase pills, the "not responding" state, countdown / keep-awake times,
// battery, which buttons work, alert icons, the Activity list's days and the feedback line under the buttons.
// Pure functions of a value and `now` (no SwiftUI), so every rule is unit-tested; the views map `Tint` to the design
// language's state colours (Views/Palette.swift).

import KakurenekoCloud
import Foundation

/// The design language's state set ("design language/DESIGN.md" §2.1): each has a fill, a text colour per
/// appearance and a tint.
enum Tint: Sendable, Hashable {
    /// The accent (amber; amber-ink as text).
    case accent
    /// An agent is working, the Mac stays awake (amber).
    case working
    /// An agent needs you (pink: normal, not a warning).
    case waiting
    /// A sleep or shutdown countdown (violet).
    case drowsy
    /// Asleep (indigo).
    case asleep
    /// A warning (orange).
    case attention
    /// A safety stop, an error, shutting down (red).
    case critical
    /// Done, success (green).
    case finished
    /// Nothing happening, off, pending (grey).
    case idle
}

/// `CloudAlert.kind` values the Mac sends (`NotificationKind` raw values in KakurenekoKit, which is macOS-only).
enum AlertKind {
    static let finished = "finished"
    static let needsInput = "needsInput"
    static let countdown = "countdown"
    static let wentQuiet = "wentQuiet"
    static let stalled = "stalled"
    static let safetyTrip = "safetyTrip"
    static let asleep = "asleep"
    static let shuttingDown = "shuttingDown"
    static let commandIgnored = "commandIgnored"
    static let warning = "warning"
    static let test = "test"
}

/// Icon of an alert in the Activity list.
struct AlertKindStyle: Hashable, Sendable {
    var symbol: String
    var tint: Tint
    /// VoiceOver name of the kind.
    var name: String

    init(kind: String) {
        switch kind {
        case AlertKind.finished: (symbol, tint, name) = ("checkmark.circle.fill", .finished, "Finished")
        case AlertKind.needsInput: (symbol, tint, name) = ("hand.raised.fill", .waiting, "Needs input")
        case AlertKind.countdown: (symbol, tint, name) = ("timer", .drowsy, "Sleep countdown")
        case AlertKind.wentQuiet: (symbol, tint, name) = ("ellipsis.bubble.fill", .attention, "Went quiet")
        case AlertKind.stalled: (symbol, tint, name) = ("clock.badge.exclamationmark.fill", .attention, "Stalled")
        case AlertKind.safetyTrip: (symbol, tint, name) = ("exclamationmark.octagon.fill", .critical, "Safety stop")
        case AlertKind.asleep: (symbol, tint, name) = ("moon.zzz.fill", .asleep, "Slept")
        case AlertKind.shuttingDown: (symbol, tint, name) = ("power.circle.fill", .critical, "Shutting down")
        case AlertKind.commandIgnored: (symbol, tint, name) = ("xmark.circle.fill", .idle, "Button ignored")
        case AlertKind.warning: (symbol, tint, name) = ("exclamationmark.triangle.fill", .attention, "Warning")
        case AlertKind.test: (symbol, tint, name) = ("bell.badge.fill", .accent, "Test")
        default: (symbol, tint, name) = ("bell.fill", .idle, "Alert")
        }
    }
}

/// The pill that names a Mac's phase.
struct PhaseStyle: Hashable, Sendable {
    var title: String
    var symbol: String
    var tint: Tint

    init(_ phase: MacPhase) {
        switch phase {
        case .off: (title, symbol, tint) = ("Kakureneko off", "power", .idle)
        case .idle: (title, symbol, tint) = ("Idle", "moon", .idle)
        case .working: (title, symbol, tint) = ("Working", "cup.and.heat.waves.fill", .working)
        case .lidClosedAwake: (title, symbol, tint) = ("Awake, lid closed", "cup.and.heat.waves.fill", .working)
        case .countdown: (title, symbol, tint) = ("Sleeping soon", "timer", .drowsy)
        case .shutdownPending: (title, symbol, tint) = ("Shutting down soon", "power", .critical)
        case .windingDown: (title, symbol, tint) = ("Going to sleep", "moon.zzz.fill", .asleep)
        case .asleep: (title, symbol, tint) = ("Asleep", "moon.zzz.fill", .asleep)
        case .shutDown: (title, symbol, tint) = ("Shut down", "power", .idle)
        }
    }

    private init(title: String, symbol: String, tint: Tint) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
    }

    /// A running Mac that stopped publishing its status.
    static let notResponding = PhaseStyle(title: "Not responding", symbol: "exclamationmark.triangle.fill", tint: .critical)
}

/// Icon and name of an agent's activity.
struct AgentActivityStyle: Hashable, Sendable {
    var symbol: String
    var tint: Tint
    var title: String

    init(_ activity: AgentSummary.Activity) {
        switch activity {
        case .working: (symbol, tint, title) = ("cup.and.heat.waves.fill", .working, "Working")
        case .waiting: (symbol, tint, title) = ("hand.raised.fill", .waiting, "Waiting for you")
        case .finished: (symbol, tint, title) = ("checkmark.circle.fill", .finished, "Finished")
        case .stalled: (symbol, tint, title) = ("exclamationmark.triangle.fill", .attention, "Stalled")
        case .idle: (symbol, tint, title) = ("pause.circle.fill", .idle, "Idle")
        }
    }
}

/// Battery row: SF Symbol, text and VoiceOver label.
struct BatteryPresentation: Hashable, Sendable {
    var symbol: String
    var text: String
    var accessibilityLabel: String

    init(percent: Int?, onBattery: Bool) {
        guard let percent else {
            (symbol, text, accessibilityLabel) = onBattery
                ? ("battery.100percent", "On battery", "On battery power")
                : ("powerplug.fill", "Power adapter", "On power adapter")
            return
        }
        let level = min(100, max(0, percent))
        if !onBattery {
            symbol = "battery.100percent.bolt"
        } else {
            symbol = switch level {
            case ..<13: "battery.0percent"
            case ..<38: "battery.25percent"
            case ..<63: "battery.50percent"
            case ..<88: "battery.75percent"
            default: "battery.100percent"
            }
        }
        let source = onBattery ? "on battery" : "plugged in"
        text = "\(level)%, \(source)"
        accessibilityLabel = "Battery \(level) percent, \(source)"
    }
}

/// One Mac's status as its screen shows it at `now`.
struct MacStatusPresentation {
    let status: MacStatus
    let now: Date

    /// Running but silent for longer than `MacStatus.staleAfter` (crashed, offline, out of power).
    var isStale: Bool { status.isStale(at: now) }

    /// Asleep, shut down or Kakureneko switched off: commands would wait unanswered.
    var isDormant: Bool {
        switch status.phase {
        case .asleep, .shutDown, .off: true
        default: false
        }
    }

    var phaseStyle: PhaseStyle { isStale ? .notResponding : PhaseStyle(status.phase) }

    /// End of the sleep / shutdown countdown while it is still running (only in those phases: an older Mac build
    /// could leave a stale end time behind).
    var countdownEnd: Date? {
        guard !isStale, status.phase == .countdown || status.phase == .shutdownPending,
              let end = status.countdownEndsAt, end > now else { return nil }
        return end
    }

    /// "Sleeps in" / "Shuts down in".
    var countdownLabel: String { status.phase == .shutdownPending ? "Shuts down in" : "Sleeps in" }

    /// End of a keep-awake period that is still running.
    var keepAwakeUntil: Date? {
        guard let until = status.keepAwakeUntil, until > now else { return nil }
        return until
    }

    var battery: BatteryPresentation { BatteryPresentation(percent: status.batteryPercent, onBattery: status.onBattery) }

    var lidText: String { status.lidClosed ? "Closed" : "Open" }

    /// "Keep awake 1h".
    var keepAwakeTitle: String { CloudAction.keepAwake(seconds: status.keepAwakeSeconds).title }

    /// Keep awake is harmless, so it stays available while the Mac is silent (it waits in iCloud for 10 minutes).
    var canKeepAwake: Bool { !isDormant }

    /// Sleep and shut down end the agents' work: only for a Mac that is answering and says it would accept them.
    var canSleep: Bool { status.canSleep && !isStale && !isDormant }

    var showsShutDown: Bool { status.shutdownEnabled }

    var canShutDown: Bool { status.shutdownEnabled && !isStale && !isDormant }

    /// The Soot pose beside the status ("design language/DESIGN.md" §5), or none: never while the Mac is silent or
    /// counting down (the countdown is the point of that screen), off or shut down.
    var poseName: String? {
        guard !isStale else { return nil }
        switch status.phase {
        case .countdown, .shutdownPending, .windingDown, .off, .shutDown:
            return nil
        case .asleep, .idle:
            return "sleep"
        case .working, .lidClosedAwake:
            if status.agents.contains(where: { $0.activity == .waiting }) { return "wave" }
            if keepAwakeUntil != nil && status.agents.allSatisfy({ $0.activity != .working }) { return "coffee" }
            return status.phase == .lidClosedAwake ? "hide" : "sit"
        }
    }

    /// The order of the screen's sections: during a countdown the buttons come first.
    var controlsFirst: Bool { countdownEnd != nil }
}

/// One day of the Activity list.
struct ActivityDay: Identifiable, Hashable, Sendable {
    /// Start of the day (the section id).
    var day: Date
    /// Newest first.
    var alerts: [CloudAlert]

    var id: Date { day }

    /// Groups newest-first alerts by calendar day, newest day first.
    static func group(_ alerts: [CloudAlert], calendar: Calendar) -> [ActivityDay] {
        var days: [ActivityDay] = []
        for alert in alerts.sorted(by: { $0.createdAt > $1.createdAt }) {
            let day = calendar.startOfDay(for: alert.createdAt)
            if days.last?.day == day {
                days[days.count - 1].alerts.append(alert)
            } else {
                days.append(ActivityDay(day: day, alerts: [alert]))
            }
        }
        return days
    }
}

extension CommandFeedback {
    /// The sentence under the buttons (or the test row).
    func message(macName: String) -> String {
        switch phase {
        case .sending: return "Sending…"
        case .sent: return "Sent. Waiting for \(macName)…"
        case .received: return "\(macName) received it."
        case .done: return Self.doneMessage(request, macName: macName)
        case .ignored(let reason): return "\(macName) ignored it. \(reason)"
        case .noResponse: return "\(macName) didn't respond. It may be asleep or offline."
        case .queued: return "Couldn't reach iCloud. Kakureneko will send it when you're back online."
        case .failed(let reason): return "Couldn't send. \(reason)"
        }
    }

    var symbol: String {
        switch phase {
        case .sending, .sent: "arrow.up.circle"
        case .received, .done: "checkmark.circle.fill"
        case .ignored: "xmark.circle.fill"
        case .noResponse: "exclamationmark.triangle.fill"
        case .queued: "clock.arrow.circlepath"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    var tint: Tint {
        switch phase {
        case .sending, .sent, .queued: .idle
        case .received, .done: .finished
        case .ignored, .noResponse: .attention
        case .failed: .critical
        }
    }

    private static func doneMessage(_ request: CloudRequest, macName: String) -> String {
        switch request {
        case .keepAwake: "\(macName) will stay awake."
        case .sleepNow: "\(macName) is going to sleep."
        case .shutDown: "\(macName) is shutting down."
        case .sendTest: "\(macName) sent a test alert."
        case .refreshStatus: "\(macName) updated its status."
        }
    }
}

extension CloudAccountStatus {
    /// Settings row value.
    var shortTitle: String {
        switch self {
        case .available: "Connected"
        case .noAccount: "Not Signed In"
        case .restricted: "Restricted"
        case .temporarilyUnavailable: "Temporarily Unavailable"
        case .couldNotDetermine: "Unknown"
        case .unavailableInThisBuild: "Unavailable"
        }
    }

    /// One sentence for the iPhone (the shared `explanation` of `.noAccount` names the Mac's System Settings).
    var phoneExplanation: String {
        switch self {
        case .noAccount: "Sign in to iCloud in Settings with the same Apple Account as your Mac."
        default: explanation
        }
    }
}

extension NotificationAuthorization {
    /// Settings row value.
    var statusTitle: String {
        switch status {
        case .notDetermined: "Not Set Up"
        case .denied: "Off"
        case .authorized: "On"
        case .provisional: "Delivered Quietly"
        }
    }

    var timeSensitiveTitle: String {
        switch timeSensitive {
        case true?: "On"
        case false?: "Off"
        case nil: "Unknown"
        }
    }
}

/// Times as the screens word them, relative to an injectable `now`.
enum TimeText {
    /// "Just now", "3 minutes ago", "2 hours ago".
    static func ago(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "13:02" today, "Mon 13:02" on another day (localized).
    static func clock(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now)
            ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
