import KakurenekoKit
import Foundation

/// What every template needs besides the intent's own payload.
struct TemplateContext: Sendable, Hashable {
    var detail: DetailLevel
    var now: Date
    /// Time zone for `{hh:mm}` (injected so golden tests are stable).
    var timeZone: TimeZone
    /// `sv` embedded in signed sleep/shutdown buttons.
    var stateVersion: Int
    /// Duration of the "Keep awake" button.
    var keepAwakeSeconds: Int

    init(detail: DetailLevel, now: Date, timeZone: TimeZone, stateVersion: Int, keepAwakeSeconds: Int) {
        self.detail = detail
        self.now = now
        self.timeZone = timeZone
        self.stateVersion = stateVersion
        self.keepAwakeSeconds = keepAwakeSeconds
    }

    var keepAwake: NotificationAction { .keepAwake(seconds: keepAwakeSeconds) }
    var isPrivate: Bool { detail == .private }
}

/// A `finished` / `wentQuiet` effect held in the 15 s batch (or folded into a countdown).
struct BatchedFinish: Sendable, Hashable {
    enum Kind: Sendable, Hashable { case finished, wentQuiet(sleepsAt: Date?) }
    var kind: Kind
    var effect: SessionEffect

    var isWentQuiet: Bool { if case .wentQuiet = kind { true } else { false } }
}

/// Message templates (brief §8.4 exactly, plus R07 §16.1 shuttingDown / commandIgnored / warning and the
/// test message). The same text shows on the Mac and the iPhone. Detail levels: Private ("An agent finished"), Basic (agent, project,
/// host, durations — the default) and Detailed (+ ≤ 140 sanitized characters of the last message).
///
/// Every agent-derived string goes through `TextSanitizer` again here (defense in depth: producers already
/// sanitize previews). Pure functions of their inputs.
enum NotificationTemplates {
    static let projectLimit = 60
    static let hostLimit = 40
    static let waitingTextLimit = 140
    static let listLimit = 5

    // MARK: finished

    static func finished(_ effect: SessionEffect, stillRunning: Int, context: TemplateContext) -> OutgoingNotification {
        let session = effect.session
        let title: String
        var sentences: [String] = []
        if context.isPrivate {
            title = "An agent finished"
        } else {
            title = withProject("\(session.agent.displayName) finished", project(session))
            let duration = workedFor(effect).map(KakurenekoFormat.shortDuration)
            switch (duration, host(session)) {
            case let (duration?, host?): sentences.append("Worked \(duration) (\(host)).")
            case let (duration?, nil): sentences.append("Worked \(duration).")
            case let (nil, host?): sentences.append("Finished in \(host).")
            case (nil, nil): break
            }
        }
        sentences.append(stillRunningSentence(stillRunning))
        if !context.isPrivate, let note = outcomeNote(effect.outcome) { sentences.append(note) }
        let body = withPreview(sentences.joined(separator: " "), session, context)
        return OutgoingNotification(
            kind: .finished, title: title, body: body,
            groupKey: "finished:\(session.key.description)",
            createdAt: context.now, stateVersion: context.stateVersion)
    }

    // MARK: batch flush (N finishes → one message)

    /// One message for the items of a 15 s batch. A single item uses its own template.
    static func batch(_ items: [BatchedFinish], stillRunning: Int, context: TemplateContext) -> OutgoingNotification? {
        let items = deduplicated(items)
        guard let last = items.last else { return nil }
        if items.count == 1 {
            switch last.kind {
            case .finished: return finished(last.effect, stillRunning: stillRunning, context: context)
            case .wentQuiet(let sleepsAt): return wentQuiet(last.effect, sleepsAt: sleepsAt, context: context)
            }
        }
        let quietCount = items.filter(\.isWentQuiet).count
        let verb = quietCount == 0 ? "finished" : quietCount == items.count ? "went quiet" : "finished or went quiet"
        let title = "\(items.count) agents \(verb)"
        var sentences: [String] = []
        if !context.isPrivate {
            let entries = items.map { finishedEntry($0.effect) }
            sentences.append(capitalizedFirst(verb) + ": " + list(entries) + ".")
        }
        sentences.append(stillRunningSentence(stillRunning))
        let body = withPreview(sentences.joined(separator: " "), latestPreviewSession(items.map(\.effect)), context)
        var actions: [NotificationAction] = []
        if quietCount > 0 { actions = [context.keepAwake, .sleepNow] }
        return OutgoingNotification(
            kind: quietCount == items.count ? .wentQuiet : .finished, title: title, body: body,
            groupKey: "finished:batch:" + items.map(\.effect.session.key.description).joined(separator: ","), actions: actions,
            createdAt: context.now, stateVersion: context.stateVersion)
    }

    // MARK: needs input

    static func needsInput(_ effect: SessionEffect, awakeUntil: Date?, reminder: Bool = false, context: TemplateContext) -> OutgoingNotification {
        let session = effect.session
        let since = waitingSince(effect)
        var title: String
        var body: String
        if context.isPrivate {
            title = "An agent needs your input"
            body = "Waiting since \(clock(since, context))."
        } else {
            title = withProject("\(session.agent.displayName) needs your input", project(session))
            body = waitingSentence(effect, since: since, context: context)
        }
        // One sentence (DESIGN.md §7, notifications): "… since 21:50, and the Mac stays awake until 22:30."
        if let awakeUntil {
            if body.hasSuffix(".") { body.removeLast() }
            body += ", and the Mac stays awake until \(clock(awakeUntil, context))."
        }
        if reminder { title = "Reminder: " + (title.hasPrefix("An agent") ? "an agent" + title.dropFirst("An agent".count) : title) }
        let key = inputGroupKey(session.key)
        return OutgoingNotification(
            kind: .needsInput, title: title, body: withPreview(body, session, context),
            groupKey: key, replaceKey: key, actions: [context.keepAwake, .sleepNow],
            createdAt: context.now, stateVersion: context.stateVersion)
    }

    /// `input:<agent>/<session id>` — the outbox group of a session's needs-input pushes.
    static func inputGroupKey(_ key: SessionKey) -> String { "input:\(key.description)" }

    // MARK: countdown

    static func countdown(endsAt: Date, reason: CountdownReason, finished: [SessionEffect], waiting: [AgentSession],
                          offerShutdown: Bool, context: TemplateContext) -> OutgoingNotification {
        let minutes = minutesUntil(endsAt, context.now)
        let finished = deduplicatedEffects(finished)
        let waiting = deduplicatedSessions(waiting)
        let title: String
        var body: String
        var previewSession: AgentSession? = latestPreviewSession(finished)
        switch reason {
        case .finished:
            title = "All agents done, sleeping in \(minutes) min"
            if context.isPrivate {
                body = finished.isEmpty ? "No agent is working." : (finished.count == 1 ? "1 agent finished." : "\(finished.count) agents finished.")
            } else {
                body = finished.isEmpty ? "No agent is working." : "Finished: \(list(finished.map(finishedEntry)))."
            }
        case .needsInput:
            if context.isPrivate || waiting.count != 1 {
                title = waiting.count > 1
                    ? "\(waiting.count) agents are waiting for you, sleeping in \(minutes) min"
                    : "An agent is waiting for you, sleeping in \(minutes) min"
            } else {
                let first = waiting[0]
                title = withProject("\(first.agent.displayName) is waiting for you", project(first)) + ", sleeping in \(minutes) min"
            }
            if context.isPrivate {
                let earliest = waiting.compactMap(sessionWaitingSince).min()
                body = earliest.map { "Waiting since \(clock($0, context))." } ?? "Waiting for your input."
            } else {
                body = waiting.isEmpty
                    ? "Waiting for your input."
                    : "Waiting: \(list(waiting.map { waitingEntry($0, context) }))."
                if !finished.isEmpty { body += " Finished: \(list(finished.map(finishedEntry)))." }
            }
            previewSession = waiting.first(where: { preview($0) != nil }) ?? previewSession
        case .wentQuiet:
            if context.isPrivate || finished.count != 1 {
                title = finished.count > 1
                    ? "\(finished.count) agents went quiet, sleeping in \(minutes) min"
                    : "An agent went quiet, sleeping in \(minutes) min"
            } else {
                title = "\(finished[0].session.agent.displayName) went quiet, sleeping in \(minutes) min"
            }
            body = (context.isPrivate || finished.isEmpty)
                ? "Finished or waiting for you."
                : "Finished or waiting for you: \(list(finished.map(finishedEntry)))."
        }
        var actions: [NotificationAction] = [context.keepAwake, .sleepNow]
        if offerShutdown { actions.append(.shutDown) }
        return OutgoingNotification(
            kind: .countdown, title: title, body: withPreview(body, previewSession, context),
            groupKey: "countdown", replaceKey: "countdown", actions: actions,
            createdAt: context.now, expiresAt: endsAt, stateVersion: context.stateVersion,
            actionTTL: max(NotificationKind.countdown.actionTTL, endsAt.timeIntervalSince(context.now)))
    }

    // MARK: went quiet / stalled

    static func wentQuiet(_ effect: SessionEffect, sleepsAt: Date?, context: TemplateContext) -> OutgoingNotification {
        let session = effect.session
        let title = context.isPrivate ? "An agent went quiet" : withProject("\(session.agent.displayName) went quiet", project(session))
        var body = "Finished or waiting for you."
        if let sleepsAt { body += " Mac sleeps in \(minutesUntil(sleepsAt, context.now)) min." }
        return OutgoingNotification(
            kind: .wentQuiet, title: title, body: withPreview(body, session, context),
            groupKey: "quiet:\(session.key.description)", actions: [context.keepAwake, .sleepNow],
            createdAt: context.now, stateVersion: context.stateVersion)
    }

    static func stalled(_ effect: SessionEffect, context: TemplateContext) -> OutgoingNotification {
        let session = effect.session
        let title = context.isPrivate ? "An agent looks stuck" : withProject("\(session.agent.displayName) looks stuck", project(session))
        let quietSince = session.lastProgressAt ?? session.lastHookAt ?? session.turnStartedAt
        let idle = quietSince.map { KakurenekoFormat.shortDuration(effect.at.timeIntervalSince($0)) }
        let body = (idle.map { "No activity for \($0)." } ?? "No activity for a while.") + " It no longer keeps your Mac awake."
        return OutgoingNotification(
            kind: .stalled, title: title, body: withPreview(body, session, context),
            groupKey: "stalled:\(session.key.description)", actions: [context.keepAwake],
            createdAt: context.now, stateVersion: context.stateVersion)
    }

    // MARK: power / system messages (no agent content)

    static func safetyTrip(_ trip: SafetyTrip, runningAgents: Int, context: TemplateContext) -> OutgoingNotification {
        let running: String = switch runningAgents {
        case ...0: "No agents were running."
        case 1: "1 agent was still running."
        default: "\(runningAgents) agents were still running."
        }
        return OutgoingNotification(
            kind: .safetyTrip, title: "\(KakurenekoID.appName) is putting your Mac to sleep",
            body: "\(capitalizedFirst(trip.userReason)). \(running)",
            groupKey: "safety", createdAt: context.now, stateVersion: context.stateVersion)
    }

    static func asleep(_ record: SleepRecord, batteryPercent: Int?, context: TemplateContext) -> OutgoingNotification {
        let start = clock(record.startedAt, context)
        let title: String
        if record.endAction == .shutdown {
            title = "Mac shut down at \(start)"
        } else if let end = record.endedAt {
            title = "Mac slept \(start)\u{2013}\(clock(end, context))"
        } else {
            title = "Mac slept at \(start)"
        }
        // One sentence (DESIGN.md §7): the reason, then the battery ("…, with the battery at 64%."); a safety stop
        // already names what tripped it.
        var body: String = switch record.reason {
        case .countdownElapsed: "After all agents finished"
        case .userSleepNow: "You chose Sleep now"
        case .remoteSleep: "Sleep was requested from your phone"
        case .remoteShutdown: "Shutdown was requested from your phone"
        case .safetyTrip(let trip): "Safety: \(trip.userReason)"
        }
        if case .safetyTrip = record.reason {
        } else if let percent = batteryPercent ?? record.batteryPercentAtStart {
            body += ", with the battery at \(percent)%"
        }
        body += "."
        return OutgoingNotification(
            kind: .asleep, title: title, body: body, groupKey: "asleep",
            createdAt: context.now, stateVersion: context.stateVersion)
    }

    static func shuttingDown(at: Date, requestedFromPhone: Bool, context: TemplateContext) -> OutgoingNotification {
        let seconds = max(0, Int(at.timeIntervalSince(context.now).rounded()))
        let interval = seconds < 120 ? "\(seconds) s" : "\(Int((Double(seconds) / 60).rounded())) min"
        let lead = requestedFromPhone ? "Requested from your phone at \(clock(context.now, context))." : "All agents are done."
        let remaining = max(0, at.timeIntervalSince(context.now))
        return OutgoingNotification(
            kind: .shuttingDown, title: "Mac is shutting down",
            body: "\(lead) Shutting down in \(interval). Tap Keep awake to cancel.",
            groupKey: "shutdown", actions: [context.keepAwake],
            createdAt: context.now, expiresAt: max(at, context.now.addingTimeInterval(30)),
            stateVersion: context.stateVersion,
            actionTTL: max(NotificationKind.shuttingDown.actionTTL, remaining))
    }

    /// The reason goes in the body: the iPhone's tap feedback reads it ("<Mac> ignored it. <body>").
    static func commandIgnored(reason: String, context: TemplateContext) -> OutgoingNotification {
        var body = "The command was not run."
        if !context.isPrivate {
            var text = TextSanitizer.sanitize(reason, limit: 120)
            while text.hasSuffix(".") { text.removeLast() }
            if !text.isEmpty { body = text + "." }
        }
        return OutgoingNotification(
            kind: .commandIgnored, title: "Command ignored", body: body,
            groupKey: "ignored", createdAt: context.now, stateVersion: context.stateVersion)
    }

    static func warning(title: String, body: String, context: TemplateContext) -> OutgoingNotification {
        let cleanTitle = TextSanitizer.sanitize(title, limit: 120)
        let cleanBody = TextSanitizer.sanitize(body, limit: 500)
        return OutgoingNotification(
            kind: .warning, title: cleanTitle.isEmpty ? "\(KakurenekoID.appName) warning" : cleanTitle,
            body: cleanBody.isEmpty ? (cleanTitle.isEmpty ? "Open \(KakurenekoID.appName) for details." : cleanTitle) : cleanBody,
            groupKey: "warning:\(cleanTitle)", createdAt: context.now, stateVersion: context.stateVersion)
    }

    static func test(context: TemplateContext) -> OutgoingNotification {
        OutgoingNotification(
            kind: .test, title: "\(KakurenekoID.appName) test", body: "If you see this, notifications work on this device.",
            groupKey: "test", createdAt: context.now, stateVersion: context.stateVersion)
    }

    // MARK: digest (rate-limit overflow)

    /// One message for the notifications folded by the rate limit. A single folded item is sent as is.
    static func digest(_ folded: [OutgoingNotification], context: TemplateContext) -> OutgoingNotification? {
        guard let latest = folded.last else { return nil }
        if folded.count == 1 { return latest }
        let lead = folded.max { ($0.priority, $0.createdAt) < ($1.priority, $1.createdAt) } ?? latest
        let lines = folded.prefix(8).map { "\u{2022} \($0.title)" }
        var body = lines.joined(separator: "\n")
        if folded.count > 8 { body += "\nand \(folded.count - 8) more." }
        let withActions = folded.last { !$0.actions.isEmpty }
        return OutgoingNotification(
            kind: lead.kind, title: "\(folded.count) more updates", body: body,
            priority: folded.map(\.priority).max(),
            groupKey: "digest", actions: withActions?.actions ?? [],
            createdAt: context.now, expiresAt: folded.map(\.expiresAt).max(),
            stateVersion: max(context.stateVersion, folded.map(\.stateVersion).max() ?? 0),
            actionTTL: withActions?.actionTTL)
    }

    // MARK: helpers

    static func waitingSince(_ effect: SessionEffect) -> Date {
        sessionWaitingSince(effect.session) ?? effect.at
    }

    static func sessionWaitingSince(_ session: AgentSession) -> Date? {
        if case .waiting(_, let since) = session.state { return since }
        return nil
    }

    /// Agent type labels that some agents send as their "message" ("permission prompt", "idle_prompt"): not worth
    /// quoting; the kind's own sentence is used instead.
    static let genericWaitingLabels: Set<String> = [
        "permission prompt", "worker permission prompt", "elicitation dialog", "elicitation url dialog",
        "agent needs input", "idle prompt", "notification", "permission", "input needed",
    ]

    static func waitingText(_ effect: SessionEffect) -> String {
        if let text = effect.session.waitingFor.map({ TextSanitizer.sanitize($0, limit: waitingTextLimit) }), !text.isEmpty {
            var trimmed = text
            while trimmed.hasSuffix(".") { trimmed.removeLast() }
            let label = trimmed.lowercased().replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
            // A sentence starts with a capital ("permission prompt" read as a typo in the alert).
            if !trimmed.isEmpty, !genericWaitingLabels.contains(label) { return trimmed.prefix(1).uppercased() + trimmed.dropFirst() }
        }
        var kind = effect.needsInputKind
        if kind == nil, case .waiting(let k, _) = effect.session.state { kind = k }
        switch kind {
        case .question: return "Waiting for your answer"
        case .dialog: return "Waiting for your choice"
        case .unknown: return "Waiting for you"
        case .permission, nil: return "Waiting for permission"
        }
    }

    /// `{text} since {hh:mm}.` (brief §8.4); a text that ends in `?`/`!` reads `{text} Waiting since {hh:mm}.`
    static func waitingSentence(_ effect: SessionEffect, since: Date, context: TemplateContext) -> String {
        let text = waitingText(effect)
        if let last = text.last, last == "?" || last == "!" {
            return "\(text) Waiting since \(clock(since, context))."
        }
        return "\(text) since \(clock(since, context))."
    }

    static func project(_ session: AgentSession) -> String? {
        session.projectName.map { TextSanitizer.sanitize($0, limit: projectLimit) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func host(_ session: AgentSession) -> String? {
        session.host.map { TextSanitizer.sanitize($0.name, limit: hostLimit) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func preview(_ session: AgentSession) -> String? {
        session.lastMessagePreview.map { TextSanitizer.sanitize($0) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func workedFor(_ effect: SessionEffect) -> TimeInterval? {
        effect.workedFor ?? effect.session.lastTurnDuration
    }

    static func withProject(_ base: String, _ project: String?) -> String {
        project.map { "\(base) \u{00B7} \($0)" } ?? base
    }

    /// Appends `“preview”` on a new line at the Detailed level only.
    static func withPreview(_ body: String, _ session: AgentSession?, _ context: TemplateContext) -> String {
        guard context.detail == .detailed, let session, let preview = preview(session) else { return body }
        return body + "\n\u{201C}\(preview)\u{201D}"
    }

    static func stillRunningSentence(_ count: Int) -> String {
        switch count {
        case ...0: "No other agents running."
        case 1: "1 agent still running."
        default: "\(count) agents still running."
        }
    }

    static func outcomeNote(_ outcome: TurnOutcome?) -> String? {
        switch outcome {
        case .error: "It stopped with an error."
        case .rateLimited: "It hit a rate limit."
        default: nil
        }
    }

    /// `api (Claude Code, 42m)` / `api (Claude Code)` / `Claude Code (42m)` / `Claude Code`.
    static func finishedEntry(_ effect: SessionEffect) -> String {
        let agent = effect.session.agent.displayName
        let duration = workedFor(effect).map(KakurenekoFormat.shortDuration)
        if let project = project(effect.session) {
            return "\(project) (\(agent)\(duration.map { ", \($0)" } ?? ""))"
        }
        return agent + (duration.map { " (\($0))" } ?? "")
    }

    /// `api (Claude Code, since 14:02)` / `Claude Code (since 14:02)`.
    static func waitingEntry(_ session: AgentSession, _ context: TemplateContext) -> String {
        let agent = session.agent.displayName
        let since = sessionWaitingSince(session).map { "since \(clock($0, context))" }
        if let project = project(session) {
            return "\(project) (\(agent)\(since.map { ", \($0)" } ?? ""))"
        }
        return agent + (since.map { " (\($0))" } ?? "")
    }

    /// `a, b, c` with at most `listLimit` entries, then `and N more`.
    static func list(_ entries: [String]) -> String {
        guard entries.count > listLimit else { return entries.joined(separator: ", ") }
        return entries.prefix(listLimit).joined(separator: ", ") + " and \(entries.count - listLimit) more"
    }

    static func clock(_ date: Date, _ context: TemplateContext) -> String {
        KakurenekoFormat.clockTime(date, timeZone: context.timeZone)
    }

    /// Whole minutes until `date` (rounded, at least 1).
    static func minutesUntil(_ date: Date, _ now: Date) -> Int {
        max(1, Int((date.timeIntervalSince(now) / 60).rounded()))
    }

    static func capitalizedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    /// Latest effect per session key, ordered by time (ties keep their submission order).
    static func deduplicatedEffects(_ effects: [SessionEffect]) -> [SessionEffect] {
        var latest: [SessionKey: SessionEffect] = [:]
        var order: [SessionKey] = []
        for effect in effects {
            if latest[effect.session.key] == nil { order.append(effect.session.key) }
            if let existing = latest[effect.session.key], existing.at > effect.at { continue }
            latest[effect.session.key] = effect
        }
        return order.compactMap { latest[$0] }.enumerated()
            .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
            .map(\.element)
    }

    /// Latest item per session key, ordered by time (ties keep their submission order).
    static func deduplicated(_ items: [BatchedFinish]) -> [BatchedFinish] {
        var latest: [SessionKey: (offset: Int, item: BatchedFinish)] = [:]
        for (offset, item) in items.enumerated() {
            if let existing = latest[item.effect.session.key], existing.item.effect.at > item.effect.at { continue }
            latest[item.effect.session.key] = (offset, item)
        }
        return latest.values
            .sorted { ($0.item.effect.at, $0.offset) < ($1.item.effect.at, $1.offset) }
            .map(\.item)
    }

    static func deduplicatedSessions(_ sessions: [AgentSession]) -> [AgentSession] {
        var seen: Set<SessionKey> = []
        return sessions.filter { seen.insert($0.key).inserted }
    }

    static func latestPreviewSession(_ effects: [SessionEffect]) -> AgentSession? {
        effects.sorted { $0.at < $1.at }.last { preview($0.session) != nil }?.session
    }
}
