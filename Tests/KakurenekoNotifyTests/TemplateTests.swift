@testable import KakurenekoNotify
import KakurenekoKit
import Foundation
import Testing

/// Golden tests for every template (brief §8.4, R07 §16.1) × detail level × countdown reason.
/// Time zone UTC; `now` = 22:00; the Claude session is "api" in iTerm2, the Codex session "web" in Terminal.
@Suite("Templates", .timeLimit(.minutes(1)))
struct TemplateTests {
    typealias T = NotificationTemplates

    struct Golden: Sendable {
        var title: String
        var body: String
    }

    static let previewLine = "\n\u{201C}\(Fixtures.preview)\u{201D}"

    func check(_ n: OutgoingNotification, _ golden: Golden, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(n.title == golden.title, sourceLocation: sourceLocation)
        #expect(n.body == golden.body, sourceLocation: sourceLocation)
    }

    // MARK: finished

    @Test(arguments: DetailLevel.allCases)
    func finished(detail: DetailLevel) {
        let n = T.finished(Fixtures.finished(), stillRunning: 2, context: Fixtures.templateContext(detail))
        switch detail {
        case .private: check(n, Golden(title: "An agent finished", body: "2 agents still running."))
        case .basic: check(n, Golden(title: "Claude Code finished \u{00B7} api", body: "Worked 42m (iTerm2). 2 agents still running."))
        case .detailed:
            check(n, Golden(title: "Claude Code finished \u{00B7} api", body: "Worked 42m (iTerm2). 2 agents still running." + Self.previewLine))
        }
        #expect(n.kind == .finished)
        #expect(n.priority == .default)
        #expect(n.actions.isEmpty)
        #expect(n.groupKey == "finished:claude/c-1")
        #expect(n.replaceKey == nil)
        #expect(n.expiresAt == Fixtures.start.addingTimeInterval(6 * 3600))
    }

    @Test func finishedVariants() {
        let ctx = Fixtures.templateContext()
        var session = Fixtures.claude()
        session.host = nil
        check(T.finished(Fixtures.finished(session), stillRunning: 0, context: ctx),
              Golden(title: "Claude Code finished \u{00B7} api", body: "Worked 42m. No other agents running."))
        check(T.finished(Fixtures.finished(workedFor: nil), stillRunning: 1, context: ctx),
              Golden(title: "Claude Code finished \u{00B7} api", body: "Finished in iTerm2. 1 agent still running."))
        check(T.finished(Fixtures.finished(outcome: .error), stillRunning: 0, context: ctx),
              Golden(title: "Claude Code finished \u{00B7} api", body: "Worked 42m (iTerm2). No other agents running. It stopped with an error."))
        check(T.finished(Fixtures.finished(outcome: .rateLimited), stillRunning: 0, context: ctx),
              Golden(title: "Claude Code finished \u{00B7} api", body: "Worked 42m (iTerm2). No other agents running. It hit a rate limit."))
        session.cwd = nil
        session.lastTurnDuration = 65
        check(T.finished(Fixtures.finished(session, workedFor: nil), stillRunning: 0, context: ctx),
              Golden(title: "Claude Code finished", body: "Worked 1m. No other agents running."))
    }

    // MARK: needs input

    @Test(arguments: DetailLevel.allCases)
    func needsInput(detail: DetailLevel) {
        let n = T.needsInput(Fixtures.needsInput(), awakeUntil: Fixtures.at(22, 30), context: Fixtures.templateContext(detail))
        switch detail {
        case .private:
            check(n, Golden(title: "An agent needs your input", body: "Waiting since 21:50, and the Mac stays awake until 22:30."))
        case .basic, .detailed: // Codex has no preview: Detailed adds nothing
            check(n, Golden(title: "Codex needs your input \u{00B7} web",
                            body: "Codex needs your permission to run npm install since 21:50, and the Mac stays awake until 22:30."))
        }
        #expect(n.kind == .needsInput)
        #expect(n.priority == .high)
        #expect(n.actions == [.keepAwake(seconds: 3600), .sleepNow])
        #expect(n.groupKey == "input:codex/x-1")
        #expect(n.replaceKey == "input:codex/x-1")
        #expect(n.stateVersion == 42)
        #expect(n.actionTTL == 2 * 3600)
        #expect(n.expiresAt == Fixtures.start.addingTimeInterval(2 * 3600))
    }

    @Test func needsInputVariants() {
        let ctx = Fixtures.templateContext()
        check(T.needsInput(Fixtures.needsInput(Fixtures.codex(waitingFor: nil)), awakeUntil: nil, context: ctx),
              Golden(title: "Codex needs your input \u{00B7} web", body: "Waiting for permission since 21:50."))
        check(T.needsInput(Fixtures.needsInput(Fixtures.codex(waitingFor: "Allow npm install?")), awakeUntil: nil, context: ctx),
              Golden(title: "Codex needs your input \u{00B7} web", body: "Allow npm install? Waiting since 21:50."))
        // A bare type label ("permission prompt", as Claude Code sends it) reads as the kind's sentence; other agent
        // text starts with a capital; with Keep awake held, it is still one sentence.
        check(T.needsInput(Fixtures.needsInput(Fixtures.codex(waitingFor: "permission prompt")), awakeUntil: nil, context: ctx),
              Golden(title: "Codex needs your input \u{00B7} web", body: "Waiting for permission since 21:50."))
        check(T.needsInput(Fixtures.needsInput(Fixtures.codex(waitingFor: "idle_prompt")), awakeUntil: nil, context: ctx),
              Golden(title: "Codex needs your input \u{00B7} web", body: "Waiting for permission since 21:50."))
        check(T.needsInput(Fixtures.needsInput(Fixtures.codex(waitingFor: "approve the migration")), awakeUntil: Fixtures.at(22, 30), context: ctx),
              Golden(title: "Codex needs your input \u{00B7} web",
                     body: "Approve the migration since 21:50, and the Mac stays awake until 22:30."))
        var question = Fixtures.codex(waitingFor: nil)
        question.state = .waiting(kind: .question, since: Fixtures.at(21, 55))
        check(T.needsInput(SessionEffect(kind: .needsInput, session: question, at: Fixtures.at(21, 55)), awakeUntil: nil, context: ctx),
              Golden(title: "Codex needs your input \u{00B7} web", body: "Waiting for your answer since 21:55."))
        // Reminder wording.
        check(T.needsInput(Fixtures.needsInput(), awakeUntil: nil, reminder: true, context: ctx),
              Golden(title: "Reminder: Codex needs your input \u{00B7} web",
                     body: "Codex needs your permission to run npm install since 21:50."))
        check(T.needsInput(Fixtures.needsInput(), awakeUntil: nil, reminder: true, context: Fixtures.templateContext(.private)),
              Golden(title: "Reminder: an agent needs your input", body: "Waiting since 21:50."))
        // Detailed shows the preview of a waiting Claude session.
        let claudeWaiting = Fixtures.claude(state: .waiting(kind: .permission, since: Fixtures.at(21, 58)))
        check(T.needsInput(SessionEffect(kind: .needsInput, session: claudeWaiting, at: Fixtures.at(21, 58)), awakeUntil: nil,
                           context: Fixtures.templateContext(.detailed)),
              Golden(title: "Claude Code needs your input \u{00B7} api", body: "Waiting for permission since 21:58." + Self.previewLine))
        // A custom keep-awake duration shapes the button.
        let custom = TemplateContext(detail: .basic, now: Fixtures.start, timeZone: Fixtures.utc, stateVersion: 1, keepAwakeSeconds: 900)
        #expect(T.needsInput(Fixtures.needsInput(), awakeUntil: nil, context: custom).actions.first?.label == "Keep awake 15m")
    }

    // MARK: countdown (three reasons)

    func countdownFinished(_ detail: DetailLevel, offerShutdown: Bool = false) -> OutgoingNotification {
        T.countdown(endsAt: Fixtures.at(22, 5), reason: .finished,
                    finished: [Fixtures.finished(), Fixtures.finished(Fixtures.codex(), workedFor: 1080)],
                    waiting: [], offerShutdown: offerShutdown, context: Fixtures.templateContext(detail))
    }

    @Test(arguments: DetailLevel.allCases)
    func countdownAllDone(detail: DetailLevel) {
        let n = countdownFinished(detail)
        let finished = "Finished: api (Claude Code, 42m), web (Codex, 18m)."
        switch detail {
        case .private: check(n, Golden(title: "All agents done, sleeping in 5 min", body: "2 agents finished."))
        case .basic: check(n, Golden(title: "All agents done, sleeping in 5 min", body: finished))
        case .detailed: check(n, Golden(title: "All agents done, sleeping in 5 min", body: finished + Self.previewLine))
        }
        #expect(n.kind == .countdown)
        #expect(n.priority == .default)
        #expect(n.actions == [.keepAwake(seconds: 3600), .sleepNow])
        #expect(n.groupKey == "countdown")
        #expect(n.replaceKey == "countdown")
        #expect(n.expiresAt == Fixtures.at(22, 5)) // TTL = the countdown end
        #expect(n.actionTTL == NotificationKind.countdown.actionTTL)
    }

    @Test func countdownOffersShutdownAndLongButtons() {
        #expect(countdownFinished(.basic, offerShutdown: true).actions == [.keepAwake(seconds: 3600), .sleepNow, .shutDown])
        let long = T.countdown(endsAt: Fixtures.start.addingTimeInterval(120 * 60), reason: .finished, finished: [],
                               waiting: [], offerShutdown: false, context: Fixtures.templateContext())
        check(long, Golden(title: "All agents done, sleeping in 120 min", body: "No agent is working."))
        #expect(long.actionTTL == 120 * 60) // buttons outlive a 2 h countdown
    }

    @Test(arguments: DetailLevel.allCases)
    func countdownWaiting(detail: DetailLevel) {
        let n = T.countdown(endsAt: Fixtures.at(22, 10), reason: .needsInput, finished: [], waiting: [Fixtures.codex()],
                            offerShutdown: false, context: Fixtures.templateContext(detail))
        switch detail {
        case .private:
            check(n, Golden(title: "An agent is waiting for you, sleeping in 10 min", body: "Waiting since 21:50."))
        case .basic, .detailed:
            check(n, Golden(title: "Codex is waiting for you \u{00B7} web, sleeping in 10 min", body: "Waiting: web (Codex, since 21:50)."))
        }
        #expect(n.actions == [.keepAwake(seconds: 3600), .sleepNow])
    }

    @Test func countdownWaitingVariants() {
        let two = T.countdown(endsAt: Fixtures.at(22, 10), reason: .needsInput, finished: [Fixtures.finished()],
                              waiting: [Fixtures.codex(), Fixtures.claude(state: .waiting(kind: .question, since: Fixtures.at(21, 59)))],
                              offerShutdown: false, context: Fixtures.templateContext())
        check(two, Golden(title: "2 agents are waiting for you, sleeping in 10 min",
                          body: "Waiting: web (Codex, since 21:50), api (Claude Code, since 21:59). Finished: api (Claude Code, 42m)."))
        let none = T.countdown(endsAt: Fixtures.at(22, 10), reason: .needsInput, finished: [], waiting: [],
                               offerShutdown: false, context: Fixtures.templateContext())
        check(none, Golden(title: "An agent is waiting for you, sleeping in 10 min", body: "Waiting for your input."))
    }

    @Test(arguments: DetailLevel.allCases)
    func countdownWentQuiet(detail: DetailLevel) {
        let quiet = SessionEffect(kind: .wentQuiet, session: Fixtures.aider(), at: Fixtures.start)
        let n = T.countdown(endsAt: Fixtures.at(22, 5), reason: .wentQuiet, finished: [quiet], waiting: [],
                            offerShutdown: false, context: Fixtures.templateContext(detail))
        switch detail {
        case .private: check(n, Golden(title: "An agent went quiet, sleeping in 5 min", body: "Finished or waiting for you."))
        case .basic, .detailed:
            check(n, Golden(title: "Aider went quiet, sleeping in 5 min", body: "Finished or waiting for you: proj (Aider)."))
        }
    }

    // MARK: went quiet / stalled

    @Test(arguments: DetailLevel.allCases)
    func wentQuiet(detail: DetailLevel) {
        let effect = SessionEffect(kind: .wentQuiet, session: Fixtures.aider(), at: Fixtures.start)
        let n = T.wentQuiet(effect, sleepsAt: Fixtures.at(22, 5), context: Fixtures.templateContext(detail))
        let body = "Finished or waiting for you. Mac sleeps in 5 min."
        switch detail {
        case .private: check(n, Golden(title: "An agent went quiet", body: body))
        case .basic, .detailed: check(n, Golden(title: "Aider went quiet \u{00B7} proj", body: body))
        }
        #expect(n.actions == [.keepAwake(seconds: 3600), .sleepNow])
        #expect(T.wentQuiet(effect, sleepsAt: nil, context: Fixtures.templateContext()).body == "Finished or waiting for you.")
    }

    @Test(arguments: DetailLevel.allCases)
    func stalled(detail: DetailLevel) {
        let effect = SessionEffect(kind: .stalled, session: Fixtures.claude(state: .stalled(since: Fixtures.start)), at: Fixtures.start)
        let n = T.stalled(effect, context: Fixtures.templateContext(detail))
        let body = "No activity for 20m. It no longer keeps your Mac awake."
        switch detail {
        case .private: check(n, Golden(title: "An agent looks stuck", body: body))
        case .basic: check(n, Golden(title: "Claude Code looks stuck \u{00B7} api", body: body))
        case .detailed: check(n, Golden(title: "Claude Code looks stuck \u{00B7} api", body: body + Self.previewLine))
        }
        #expect(n.actions == [.keepAwake(seconds: 3600)])
        #expect(n.priority == .default)
    }

    // MARK: system messages (no agent content: identical at every detail level)

    @Test(arguments: DetailLevel.allCases)
    func safetyTrip(detail: DetailLevel) {
        let ctx = Fixtures.templateContext(detail)
        let n = T.safetyTrip(.batteryFloor(percent: 19), runningAgents: 2, context: ctx)
        check(n, Golden(title: "Kakureneko is putting your Mac to sleep", body: "Battery 19 %. 2 agents were still running."))
        #expect(n.priority == .high)
        #expect(n.actions.isEmpty)
        check(T.safetyTrip(.thermalCritical, runningAgents: 1, context: ctx),
              Golden(title: "Kakureneko is putting your Mac to sleep", body: "Too hot. 1 agent was still running."))
        check(T.safetyTrip(.networkOffline(minutes: 15), runningAgents: 0, context: ctx),
              Golden(title: "Kakureneko is putting your Mac to sleep", body: "Offline 15 min. No agents were running."))
    }

    @Test(arguments: DetailLevel.allCases)
    func asleep(detail: DetailLevel) {
        let ctx = Fixtures.templateContext(detail, now: Fixtures.at(7, 41, dayOffset: 1))
        let record = SleepRecord(startedAt: Fixtures.at(1, 12, dayOffset: 1), endedAt: Fixtures.at(7, 40, dayOffset: 1),
                                 reason: .countdownElapsed, batteryPercentAtStart: 70)
        let n = T.asleep(record, batteryPercent: 64, context: ctx)
        check(n, Golden(title: "Mac slept 01:12\u{2013}07:40", body: "After all agents finished, with the battery at 64%."))
        #expect(n.priority == .low)
        #expect(n.expiresAt == ctx.now.addingTimeInterval(12 * 3600))
        var remote = record
        remote.reason = .remoteSleep
        remote.endedAt = nil
        check(T.asleep(remote, batteryPercent: nil, context: ctx),
              Golden(title: "Mac slept at 01:12", body: "Sleep was requested from your phone, with the battery at 70%."))
        var shutdown = record
        shutdown.endAction = .shutdown
        shutdown.reason = .safetyTrip(.batteryFloor(percent: 19))
        check(T.asleep(shutdown, batteryPercent: nil, context: ctx),
              Golden(title: "Mac shut down at 01:12", body: "Safety: battery 19 %."))
    }

    @Test(arguments: DetailLevel.allCases)
    func shuttingDown(detail: DetailLevel) {
        let ctx = Fixtures.templateContext(detail)
        let n = T.shuttingDown(at: Fixtures.start.addingTimeInterval(60), requestedFromPhone: true, context: ctx)
        check(n, Golden(title: "Mac is shutting down",
                        body: "Requested from your phone at 22:00. Shutting down in 60 s. Tap Keep awake to cancel."))
        #expect(n.actions == [.keepAwake(seconds: 3600)])
        #expect(n.priority == .low)
        check(T.shuttingDown(at: Fixtures.at(22, 5), requestedFromPhone: false, context: ctx),
              Golden(title: "Mac is shutting down", body: "All agents are done. Shutting down in 5 min. Tap Keep awake to cancel."))
    }

    @Test(arguments: DetailLevel.allCases)
    func commandIgnored(detail: DetailLevel) {
        let n = T.commandIgnored(reason: "Codex in web is busy again.", context: Fixtures.templateContext(detail))
        if detail == .private {
            check(n, Golden(title: "Command ignored", body: "The command was not run."))
        } else {
            check(n, Golden(title: "Command ignored", body: "Codex in web is busy again."))
        }
        #expect(n.priority == .low)
    }

    @Test(arguments: DetailLevel.allCases)
    func warning(detail: DetailLevel) {
        let n = T.warning(title: "You're on your iPhone's hotspot", body: "Kakureneko can't reach you if you take the phone.",
                          context: Fixtures.templateContext(detail))
        check(n, Golden(title: "You're on your iPhone's hotspot", body: "Kakureneko can't reach you if you take the phone."))
        #expect(n.priority == .high)
        #expect(n.expiresAt == Fixtures.start.addingTimeInterval(30 * 60))
        check(T.warning(title: "", body: "", context: Fixtures.templateContext(detail)),
              Golden(title: "Kakureneko warning", body: "Open Kakureneko for details."))
    }

    @Test(arguments: DetailLevel.allCases)
    func test(detail: DetailLevel) {
        let test = T.test(context: Fixtures.templateContext(detail))
        check(test, Golden(title: "Kakureneko test", body: "If you see this, notifications work on this device."))
        #expect(test.kind == .test)
        #expect(test.actions.isEmpty)
    }

    // MARK: batch and digest

    @Test(arguments: DetailLevel.allCases)
    func batchOfFinishes(detail: DetailLevel) throws {
        let items = [BatchedFinish(kind: .finished, effect: Fixtures.finished()),
                     BatchedFinish(kind: .finished, effect: Fixtures.finished(Fixtures.codex(), workedFor: 1080, at: Fixtures.start.addingTimeInterval(1)))]
        let n = try #require(T.batch(items, stillRunning: 1, context: Fixtures.templateContext(detail)))
        let body = "Finished: api (Claude Code, 42m), web (Codex, 18m). 1 agent still running."
        switch detail {
        case .private: check(n, Golden(title: "2 agents finished", body: "1 agent still running."))
        case .basic: check(n, Golden(title: "2 agents finished", body: body))
        case .detailed: check(n, Golden(title: "2 agents finished", body: body + Self.previewLine))
        }
        #expect(n.kind == .finished)
        #expect(n.actions.isEmpty)
    }

    @Test func batchVariants() throws {
        let ctx = Fixtures.templateContext()
        let quiet = BatchedFinish(kind: .wentQuiet(sleepsAt: nil), effect: SessionEffect(kind: .wentQuiet, session: Fixtures.aider(), at: Fixtures.start))
        let mixed = try #require(T.batch([BatchedFinish(kind: .finished, effect: Fixtures.finished()), quiet], stillRunning: 0, context: ctx))
        check(mixed, Golden(title: "2 agents finished or went quiet",
                            body: "Finished or went quiet: api (Claude Code, 42m), proj (Aider). No other agents running."))
        #expect(mixed.actions == [.keepAwake(seconds: 3600), .sleepNow])
        // A single item uses its own template; duplicates of a session collapse to the latest.
        let single = try #require(T.batch([BatchedFinish(kind: .finished, effect: Fixtures.finished(at: Fixtures.at(21, 59))),
                                           BatchedFinish(kind: .finished, effect: Fixtures.finished())], stillRunning: 0, context: ctx))
        check(single, Golden(title: "Claude Code finished \u{00B7} api", body: "Worked 42m (iTerm2). No other agents running."))
        #expect(T.batch([quiet], stillRunning: 0, context: ctx)?.kind == .wentQuiet)
        #expect(T.batch([], stillRunning: 0, context: ctx) == nil)
        // Long lists are capped.
        let many = (0..<7).map { i in
            BatchedFinish(kind: .finished, effect: Fixtures.finished(Fixtures.claude(id: "c\(i)", cwd: "/w/p\(i)"), workedFor: 60,
                                                                     at: Fixtures.start.addingTimeInterval(Double(i))))
        }
        let capped = try #require(T.batch(many, stillRunning: 0, context: ctx))
        #expect(capped.title == "7 agents finished")
        #expect(capped.body.hasSuffix("p4 (Claude Code, 1m) and 2 more. No other agents running."))
    }

    @Test func digestOfFoldedMessages() throws {
        let ctx = Fixtures.templateContext()
        let stalled = T.stalled(SessionEffect(kind: .stalled, session: Fixtures.claude(), at: Fixtures.start), context: ctx)
        let input = T.needsInput(Fixtures.needsInput(), awakeUntil: nil, context: ctx)
        let digest = try #require(T.digest([stalled, input], context: ctx))
        check(digest, Golden(title: "2 more updates",
                             body: "\u{2022} Claude Code looks stuck \u{00B7} api\n\u{2022} Codex needs your input \u{00B7} web"))
        #expect(digest.priority == .high)
        #expect(digest.kind == .needsInput)
        #expect(digest.actions == input.actions)
        #expect(digest.groupKey == "digest")
        #expect(T.digest([stalled], context: ctx) == stalled)
        #expect(T.digest([], context: ctx) == nil)
    }

    // MARK: privacy and sanitization

    @Test func privateLevelLeaksNoAgentContent() throws {
        let ctx = Fixtures.templateContext(.private)
        let quiet = SessionEffect(kind: .wentQuiet, session: Fixtures.aider(), at: Fixtures.start)
        let rendered: [OutgoingNotification] = [
            T.finished(Fixtures.finished(), stillRunning: 1, context: ctx),
            T.needsInput(Fixtures.needsInput(), awakeUntil: nil, context: ctx),
            T.needsInput(Fixtures.needsInput(), awakeUntil: nil, reminder: true, context: ctx),
            T.countdown(endsAt: Fixtures.at(22, 5), reason: .finished, finished: [Fixtures.finished()], waiting: [], offerShutdown: true, context: ctx),
            T.countdown(endsAt: Fixtures.at(22, 5), reason: .needsInput, finished: [Fixtures.finished()], waiting: [Fixtures.codex()], offerShutdown: false, context: ctx),
            T.countdown(endsAt: Fixtures.at(22, 5), reason: .wentQuiet, finished: [quiet], waiting: [], offerShutdown: false, context: ctx),
            T.wentQuiet(quiet, sleepsAt: nil, context: ctx),
            T.stalled(SessionEffect(kind: .stalled, session: Fixtures.claude(), at: Fixtures.start), context: ctx),
            T.commandIgnored(reason: "Codex in web is busy again", context: ctx),
            try #require(T.batch([BatchedFinish(kind: .finished, effect: Fixtures.finished()),
                                  BatchedFinish(kind: .finished, effect: Fixtures.finished(Fixtures.codex()))], stillRunning: 0, context: ctx)),
        ]
        for n in rendered {
            let text = n.title + "\n" + n.body
            for secret in ["api", "web", "proj", "Claude", "Codex", "Aider", "iTerm2", "Terminal", "parser", "npm"] {
                #expect(!text.contains(secret), "\(n.kind.rawValue) leaks \(secret): \(text)")
            }
        }
    }

    @Test func detailedPreviewIsSanitized() {
        let raw = "\u{1B}[31mDone\u{1B}[0m: wrote /Users/me/src/api/secret/config.json with key sk-abcdefghijklmnop1234"
        let session = Fixtures.claude(preview: raw)
        let n = T.finished(Fixtures.finished(session), stillRunning: 0, context: Fixtures.templateContext(.detailed))
        #expect(n.body == "Worked 42m (iTerm2). No other agents running.\n\u{201C}Done: wrote config.json with key [redacted]\u{201D}")
        let longPreview = Fixtures.claude(preview: String(repeating: "word ", count: 80))
        let capped = T.finished(Fixtures.finished(longPreview), stillRunning: 0, context: Fixtures.templateContext(.detailed))
        let quoted = capped.body.components(separatedBy: "\n").last ?? ""
        #expect(quoted.count <= TextSanitizer.defaultLimit + 2)
        #expect(!T.finished(Fixtures.finished(session), stillRunning: 0, context: Fixtures.templateContext(.basic)).body.contains("Done"))
    }

    @Test func untrustedProjectAndHostNamesAreSanitized() {
        var session = Fixtures.claude()
        session.cwd = "/Users/me/src/\u{1B}[1mevil\u{1B}[0m\nproject"
        session.host = HostApp(bundleID: nil, name: String(repeating: "H", count: 100))
        let n = T.finished(Fixtures.finished(session), stillRunning: 0, context: Fixtures.templateContext())
        #expect(!n.title.contains("\u{1B}"))
        #expect(!n.title.contains("\n"))
        #expect(n.body.count < 100)
    }
}
