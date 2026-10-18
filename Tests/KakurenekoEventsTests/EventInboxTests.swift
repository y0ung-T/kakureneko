import Darwin
@testable import KakurenekoEvents
import KakurenekoKit
import Foundation
import Testing

/// `EventInbox` end to end on a temp home (ARCHITECTURE §9.1 acceptance 11 + lifecycle): subscribe, then start;
/// launch drain; live delivery; global ordering across both inboxes; quarantine; GC; proof of life.
@Suite("EventInbox", .timeLimit(.minutes(1)))
struct EventInboxTests {
    static func makeInbox(
        _ home: TempHome,
        clock: any KakurenekoClock = TestClock(),
        notifyHint: Bool = false,
        maxFilesPerPass: Int = 500,
        maxPassesPerDrain: Int = 20
    ) -> EventInbox {
        var options = EventInbox.Options()
        options.observeDarwinNotification = notifyHint
        options.maxFilesPerPass = maxFilesPerPass
        options.maxPassesPerDrain = maxPassesPerDrain
        options.bundleIdentifierLookup = { _ in nil }
        return EventInbox(paths: home.paths, matcher: BasicAgentSignatureMatcher(), clock: clock,
                          logger: KakurenekoLogger(.events), options: options)
    }

    /// A Claude `Stop` for session `s<index>`, written `index` seconds after `t0`; file name ns = ts ms + `index`.
    @discardableResult
    static func writeStop(_ index: Int, to inbox: URL, agent: String = "claude", event: String = "Stop",
                          payload: String? = nil) throws -> URL {
        let date = Fixture.t0.addingTimeInterval(TimeInterval(index))
        let header = Fixture.header(agent, event, at: date, pid: Int32(10_000 + index))
        let ns = UInt64(Fixture.ms(date)) * 1_000_000 + UInt64(index)
        return try InboxFiles.write(header, payload: payload ?? #"{"session_id":"s\#(index)"}"#, to: inbox, nanoseconds: ns)
    }

    // MARK: Launch drain and ordering

    @Test func launchDrainDeliversQueuedFilesInGlobalOrderToExistingSubscribers() async throws {
        let home = try TempHome()
        let primary = home.paths.inboxDirectory
        let fallback = home.paths.fallbackInboxDirectory
        // Written while the app was down, interleaved across BOTH inboxes.
        for index in 0..<8 { try Self.writeStop(index, to: index.isMultiple(of: 2) ? primary : fallback) }

        let inbox = Self.makeInbox(home)
        let first = EventRecorder(inbox.events())
        let second = EventRecorder(inbox.events())
        try await inbox.start()
        let late = EventRecorder(inbox.events())

        let events = await first.wait(for: 8)
        #expect(events.map(\.sessionKey.id) == (0..<8).map { "s\($0)" }, "global file-name order across both inboxes")
        #expect(events.allSatisfy { $0.event == .turnFinished(.completed) && $0.agent == .claude && $0.tier == .hook })
        #expect(events.map(\.id) == events.map(\.id).sorted())
        #expect(await second.wait(for: 8).map(\.id) == events.map(\.id), "every subscription gets every event")
        #expect(InboxFiles.eventFiles(in: primary).isEmpty && InboxFiles.eventFiles(in: fallback).isEmpty, "processed files are deleted")
        await inbox.stop()
        #expect(late.events.isEmpty, "nothing is buffered for subscribers that did not exist yet")
    }

    /// Acceptance 11: a file dropped after start is emitted within 1 s. The TestClock never advances, so the 30 s
    /// safety re-drain cannot fire: ANY delivery proves the vnode watcher (waited for generously). The latency bound
    /// (both inboxes within 2 s, i.e. ~1 s each) is the best of up to three rounds, so time spent waiting for a CPU
    /// on a busy machine does not count against the watcher.
    @Test func fileDroppedAfterStartArrivesWithinOneSecond() async throws {
        let home = try TempHome()
        let inbox = Self.makeInbox(home) // vnode only: no notify hint, TestClock never advances the safety tick
        let recorder = EventRecorder(inbox.events())
        try await inbox.start()

        var best = Duration.seconds(3_600)
        for round in 0..<3 {
            let started = ContinuousClock.now
            try Self.writeStop(2 * round + 1, to: home.paths.inboxDirectory)
            #expect(await recorder.wait(for: 2 * round + 1).count == 2 * round + 1)
            try Self.writeStop(2 * round + 2, to: home.paths.fallbackInboxDirectory)
            #expect(await recorder.wait(for: 2 * round + 2).count == 2 * round + 2, "the fallback inbox is watched too")
            best = min(best, ContinuousClock.now - started)
            if best < .seconds(2) { break }
        }
        #expect(best < .seconds(2), "best round took \(best)")
        await inbox.stop()
    }

    @Test func realHookToEventInboxEndToEnd() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Products.hookPath))
        let home = try TempHome()
        let inbox = Self.makeInbox(home, clock: TestClock(start: Date()), notifyHint: true)
        let recorder = EventRecorder(inbox.events())
        try await inbox.start()

        let payload = #"{"session_id":"e2e-1","cwd":"/Users/x/e2e","hook_event_name":"Notification","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}"#
        let result = await HookRunner.run(["claude", "Notification"],
                                          environment: home.hookEnvironment(extra: ["TERM_PROGRAM": "iTerm.app"]),
                                          stdin: .data(Data(payload.utf8)))
        #expect(result.exitCode == 0)
        let event = try #require(await recorder.wait(for: 1).first)
        #expect(event.agent == .claude)
        #expect(event.argvAgentLabel == "claude")
        #expect(event.rawEventName == "Notification")
        #expect(event.event == .needsInput(.permission))
        #expect(event.sessionKey == SessionKey(agent: .claude, id: "e2e-1"))
        #expect(event.cwd == "/Users/x/e2e")
        #expect(event.waitingFor == "Claude needs your permission to use Bash")
        #expect(event.host?.name == "iTerm2")
        #expect(InboxFile.parseFileName(event.id)?.pid == result.pid, "the event id is the inbox file name")
        #expect(abs(event.occurredAt.timeIntervalSinceNow) < 30)
        #expect(await inbox.lastEventSeen()[.claude] != nil)
        await inbox.stop()
    }

    // MARK: Bad input

    @Test func junkAndUnparseableEntriesGoToBadAndNeverBlockTheRest() async throws {
        let home = try TempHome()
        let primary = home.paths.inboxDirectory
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        let scratch = try home.scratch("outside")
        let target = scratch.appending(path: "target.txt")
        try Data("do not touch".utf8).write(to: target)

        try Data("no newline at all".utf8).write(to: primary.appending(path: "0000000000000000001-1.event"))
        try Data("{not json}\n{}".utf8).write(to: primary.appending(path: "0000000000000000002-1.event"))
        try Data(#"{"v":0,"agent":"claude","event":"Stop","ts":1}"#.utf8 + [0x0A]).write(to: primary.appending(path: "0000000000000000003-1.event"))
        try Data("hello".utf8).write(to: primary.appending(path: "notes.txt"))
        #expect(symlink(target.path(percentEncoded: false), primary.appending(path: "0000000000000000004-1.event").path(percentEncoded: false)) == 0)
        #expect(mkfifo(primary.appending(path: "0000000000000000005-1.event").path(percentEncoded: false), 0o600) == 0)
        let big = primary.appending(path: "0000000000000000006-1.event")
        #expect(FileManager.default.createFile(atPath: big.path(percentEncoded: false), contents: nil))
        #expect(truncate(big.path(percentEncoded: false), off_t(InboxStore.maxFileBytes + 1)) == 0) // sparse
        try Self.writeStop(7, to: primary)
        try Self.writeStop(8, to: primary, agent: "no-such-agent") // parseable but unknown: deleted, not quarantined

        let inbox = Self.makeInbox(home)
        let recorder = EventRecorder(inbox.events())
        try await inbox.start()
        let events = await recorder.wait(for: 1)
        #expect(events.map(\.sessionKey.id) == ["s7"])

        let bad = InboxFiles.entries(in: home.paths.inboxBadDirectory)
        #expect(bad == ["0000000000000000001-1.event", "0000000000000000002-1.event", "0000000000000000003-1.event",
                        "0000000000000000004-1.event", "0000000000000000005-1.event", "0000000000000000006-1.event", "notes.txt"])
        #expect(InboxFiles.entries(in: primary) == [".tmp", "bad"], "the inbox is empty again")
        #expect(try String(contentsOf: target, encoding: .utf8) == "do not touch", "a symlink is moved, never followed")
        var info = stat()
        #expect(lstat(home.paths.inboxBadDirectory.appending(path: "0000000000000000004-1.event").path(percentEncoded: false), &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFLNK)
        await inbox.stop()
    }

    @Test func staleTemporaryAndBadEntriesAreGarbageCollected() async throws {
        let home = try TempHome()
        let old = Date().addingTimeInterval(-25 * 3600)
        var expectedGone: [URL] = []
        var expectedKept: [URL] = []
        for inbox in home.paths.allInboxDirectories {
            for sub in [".tmp", "bad"] {
                let directory = inbox.appending(path: sub, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let stale = directory.appending(path: "stale-\(sub).x")
                let fresh = directory.appending(path: "fresh-\(sub).x")
                try Data("x".utf8).write(to: stale)
                try Data("x".utf8).write(to: fresh)
                try InboxFiles.setModified(stale, old)
                expectedGone.append(stale)
                expectedKept.append(fresh)
            }
            // A directory a user put into bad/ is never removed.
            let nested = inbox.appending(path: "bad/keep-dir", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try InboxFiles.setModified(nested, old)
            expectedKept.append(nested)
        }
        let inbox = Self.makeInbox(home)
        try await inbox.start()
        for url in expectedGone { #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)), "\(url.lastPathComponent)") }
        for url in expectedKept { #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)), "\(url.lastPathComponent)") }
        await inbox.stop()
    }

    // MARK: Proof of life

    @Test func proofOfLifeSurvivesANewInboxOnTheSameHome() async throws {
        let home = try TempHome()
        let clock = TestClock()
        try Self.writeStop(1, to: home.paths.inboxDirectory)
        // A Copilot-file event relabelled `.vscode` still proves the COPILOT integration.
        try Self.writeStop(2, to: home.paths.inboxDirectory, agent: "copilot", event: "agentStop",
                           payload: #"{"session_id":"v","hook_event_name":"Stop","cwd":"/w"}"#)
        let first = Self.makeInbox(home, clock: clock)
        let recorder = EventRecorder(first.events())
        try await first.start()
        let events = await recorder.wait(for: 2)
        #expect(events.map(\.agent) == [.claude, .vscode])
        let seen = await first.lastEventSeen()
        #expect(seen == [.claude: clock.now(), .copilot: clock.now()])
        await first.stop()

        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: home.paths.lastEventsFile)) as? [String: String])
        #expect(Set(object.keys) == ["claude", "copilot"])
        var info = stat()
        #expect(stat(home.paths.lastEventsFile.path(percentEncoded: false), &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)

        let second = Self.makeInbox(home, clock: clock)
        #expect(await second.lastEventSeen() == seen, "readable before start()")
        try await second.start()
        #expect(await second.lastEventSeen() == seen)
        await second.stop()
    }

    @Test func proofOfLifeIsWrittenAtMostOncePerMinute() async throws {
        let home = try TempHome()
        let clock = TestClock()
        let inbox = Self.makeInbox(home, clock: clock)
        try await inbox.start()
        func persisted() -> Set<String> {
            guard let data = try? Data(contentsOf: home.paths.lastEventsFile),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return Set(object.keys)
        }
        try Self.writeStop(1, to: home.paths.inboxDirectory)
        await inbox.drainNow()
        #expect(await eventually { persisted() == ["claude"] }, "the first change is written at once")

        try Self.writeStop(2, to: home.paths.inboxDirectory, agent: "codex", event: "notify",
                           payload: #"{"type":"agent-turn-complete","thread-id":"t","turn-id":"1"}"#)
        await inbox.drainNow()
        #expect(await inbox.lastEventSeen()[.codex] != nil)
        #expect(persisted() == ["claude"], "not again within a minute")

        clock.advance(by: .seconds(61))
        await inbox.drainNow()
        #expect(await eventually { persisted() == ["claude", "codex"] })

        try Self.writeStop(3, to: home.paths.inboxDirectory, agent: "gemini", event: "AfterAgent")
        await inbox.drainNow()
        await inbox.stop()
        #expect(persisted() == ["claude", "codex", "gemini"], "stop() always flushes")
    }

    @Test func corruptProofOfLifeFileReadsAsEmpty() async throws {
        let home = try TempHome()
        try FileManager.default.createDirectory(at: home.paths.runDirectory, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: home.paths.lastEventsFile)
        let inbox = Self.makeInbox(home)
        try await inbox.start()
        #expect(await inbox.lastEventSeen().isEmpty)
        try Self.writeStop(1, to: home.paths.inboxDirectory)
        await inbox.drainNow()
        await inbox.stop()
        #expect(LastEventStore(file: home.paths.lastEventsFile).load().values.keys.contains(.claude), "replaced on the next write")
    }

    // MARK: Watching resilience

    @Test func safetyTickRecoversInboxesThatWereUnusableAtStart() async throws {
        let home = try TempHome()
        let clock = TestClock()
        // Both inbox paths are regular FILES: nothing can be created or watched.
        for inbox in home.paths.allInboxDirectories {
            try FileManager.default.createDirectory(at: inbox.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("blocker".utf8).write(to: inbox)
        }
        let inbox = Self.makeInbox(home, clock: clock)
        let recorder = EventRecorder(inbox.events())
        try await inbox.start() // never throws
        #expect(await clock.waitForSleepers(1), "the safety timer is running")

        for url in home.paths.allInboxDirectories { try FileManager.default.removeItem(at: url) }
        try Self.writeStop(1, to: home.paths.inboxDirectory)
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.events.isEmpty, "not watched yet")

        clock.advance(by: .seconds(30))
        #expect(await recorder.wait(for: 1).count == 1, "the 30 s safety tick re-arms and drains")
        // Watched from now on: delivery without advancing the clock.
        try Self.writeStop(2, to: home.paths.fallbackInboxDirectory)
        #expect(await recorder.wait(for: 2).count == 2)
        await inbox.stop()
    }

    @Test func deletedInboxDirectoryIsRecreatedAndStillWatched() async throws {
        let home = try TempHome()
        let inbox = Self.makeInbox(home)
        let recorder = EventRecorder(inbox.events())
        try await inbox.start()
        try FileManager.default.removeItem(at: home.paths.inboxDirectory)
        #expect(await eventually {
            FileManager.default.fileExists(atPath: home.paths.inboxTempDirectory.path(percentEncoded: false))
        }, "the watcher re-creates the inbox (with .tmp/)")
        try Self.writeStop(1, to: home.paths.inboxDirectory)
        #expect(await recorder.wait(for: 1).count == 1)
        await inbox.stop()
    }

    @Test func startCreatesPrivateDirectories() async throws {
        let home = try TempHome()
        let inbox = Self.makeInbox(home)
        try await inbox.start()
        for directory in home.paths.allInboxDirectories.flatMap({ [$0, $0.appending(path: ".tmp"), $0.appending(path: "bad")] }) {
            var info = stat()
            #expect(stat(directory.path(percentEncoded: false), &info) == 0, "\(directory.path(percentEncoded: false))")
            #expect(info.st_mode & 0o777 == 0o700)
        }
        await inbox.stop()
    }

    // MARK: Drains

    @Test func drainsAreBoundedPerPassAndKeepOrder() async throws {
        let home = try TempHome()
        for index in 0..<8 { try Self.writeStop(index, to: index < 4 ? home.paths.fallbackInboxDirectory : home.paths.inboxDirectory) }
        let inbox = Self.makeInbox(home, maxFilesPerPass: 3, maxPassesPerDrain: 2)
        let recorder = EventRecorder(inbox.events())
        // Before start(): nothing is watched, so each drainNow() is exactly one bounded drain.
        let firstDrain = await inbox.drainNow()
        #expect(firstDrain.map(\.sessionKey.id) == ["s0", "s1", "s2", "s3", "s4", "s5"], "2 passes × 3 files")
        let secondDrain = await inbox.drainNow()
        #expect(secondDrain.map(\.sessionKey.id) == ["s6", "s7"])
        #expect(await inbox.drainNow().isEmpty)
        #expect(await recorder.wait(for: 8).map(\.sessionKey.id) == (0..<8).map { "s\($0)" }, "drainNow's events are on the stream too")
        await inbox.stop()
    }

    @Test func lifecycleIsIdempotentAndStopFinishesEveryStream() async throws {
        let home = try TempHome()
        let inbox = Self.makeInbox(home)
        let recorder = EventRecorder(inbox.events())
        try await inbox.start()
        try await inbox.start()
        try Self.writeStop(1, to: home.paths.inboxDirectory)
        #expect(await recorder.wait(for: 1).count == 1)
        await inbox.stop()
        await inbox.stop()
        #expect(await recorder.waitForFinish())
        let afterStop = EventRecorder(inbox.events())
        #expect(await afterStop.waitForFinish(), "a stream obtained after stop() is already finished")

        try Self.writeStop(2, to: home.paths.inboxDirectory)
        #expect(await inbox.drainNow().isEmpty, "a stopped inbox processes nothing")
        #expect(InboxFiles.eventFiles(in: home.paths.inboxDirectory).count == 1, "and deletes nothing")
        try await inbox.start()
        #expect(InboxFiles.eventFiles(in: home.paths.inboxDirectory).count == 1, "start() after stop() is a no-op")
    }

    @Test func droppedEventsAreDeletedButStillProveLife() async throws {
        let home = try TempHome()
        try Self.writeStop(1, to: home.paths.inboxDirectory, event: "ConfigChange") // known agent, ignored event
        let inbox = Self.makeInbox(home)
        let recorder = EventRecorder(inbox.events())
        try await inbox.start()
        #expect(await inbox.drainNow().isEmpty)
        #expect(recorder.events.isEmpty)
        #expect(InboxFiles.eventFiles(in: home.paths.inboxDirectory).isEmpty)
        #expect(InboxFiles.entries(in: home.paths.inboxBadDirectory).isEmpty)
        #expect(await inbox.lastEventSeen()[.claude] != nil, "the hook is wired: proof of life")
        await inbox.stop()
    }
}
