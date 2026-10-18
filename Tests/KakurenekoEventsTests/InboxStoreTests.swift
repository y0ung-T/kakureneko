import Darwin
@testable import KakurenekoEvents
import KakurenekoKit
import Foundation
import Testing

/// File-level building blocks: listing/reading/quarantine/GC (`InboxStore`), proof of life (`LastEventStore`), the
/// untrusted payload view (`RawPayload`) and the field caps (`FieldLimits`).
@Suite("Inbox store and payload limits", .timeLimit(.minutes(1)))
struct InboxStoreTests {
    // MARK: InboxStore

    @Test func listingMergesBothInboxesAndSeparatesJunk() throws {
        let home = try TempHome()
        let store = InboxStore(paths: home.paths)
        let primary = home.paths.inboxDirectory
        let fallback = home.paths.fallbackInboxDirectory
        for directory in [primary, fallback] {
            try FileManager.default.createDirectory(at: directory.appending(path: "bad"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: directory.appending(path: ".tmp"), withIntermediateDirectories: true)
        }
        try Data().write(to: primary.appending(path: "0000000000000000002-1.event"))
        try Data().write(to: fallback.appending(path: "0000000000000000001-1.event"))
        try Data().write(to: fallback.appending(path: "0000000000000000002-1.event")) // same name in both: primary first
        try Data().write(to: primary.appending(path: ".DS_Store"))
        try Data().write(to: primary.appending(path: "readme.md"))
        try Data().write(to: primary.appending(path: ".tmp/0000000000000000000-1.tmp"))
        try Data().write(to: primary.appending(path: "bad/0000000000000000000-9.event"))

        let listing = store.list()
        #expect(listing.candidates.map { "\($0.inboxIndex):\($0.name)" } == [
            "1:0000000000000000001-1.event", "0:0000000000000000002-1.event", "1:0000000000000000002-1.event",
        ])
        #expect(listing.junk.map(\.name) == ["readme.md"], "hidden entries and sub-directories are never touched")
        #expect(InboxStore(inboxes: [home.paths.home.appending(path: "missing")]).list() == InboxStore.Listing(candidates: [], junk: []))
    }

    @Test func boundedReadsNeverFollowSymlinksOrBlockOnFIFOs() throws {
        let home = try TempHome()
        let directory = try home.scratch("reads")
        let regular = directory.appending(path: "a.event")
        try Data("hello\nworld".utf8).write(to: regular)
        #expect(InboxStore.read(regular.path(percentEncoded: false)) == .data(Data("hello\nworld".utf8)))
        #expect(InboxStore.read(regular.path(percentEncoded: false), maxBytes: 3) == .unusable("too large (11 bytes)"))
        #expect(InboxStore.read(directory.appending(path: "gone.event").path(percentEncoded: false)) == .vanished)

        let link = directory.appending(path: "link.event").path(percentEncoded: false)
        #expect(symlink(regular.path(percentEncoded: false), link) == 0)
        guard case .unusable = InboxStore.read(link) else {
            Issue.record("a symlink must not be read")
            return
        }
        let fifo = directory.appending(path: "fifo.event").path(percentEncoded: false)
        #expect(mkfifo(fifo, 0o600) == 0)
        #expect(InboxStore.read(fifo) == .unusable("not a regular file"), "O_NONBLOCK open, never a blocking read")
    }

    @Test func quarantineMovesTheEntryItselfIntoBad() throws {
        let home = try TempHome()
        let inbox = try home.scratch("inbox")
        let entry = InboxStore.Entry(name: "x.event", inboxIndex: 0, directory: inbox)
        try Data("x".utf8).write(to: inbox.appending(path: "x.event"))
        #expect(InboxStore.quarantine(entry))
        #expect(InboxFiles.entries(in: inbox.appending(path: "bad")) == ["x.event"])
        #expect(InboxStore.quarantine(entry), "already gone counts as quarantined")
        #expect(InboxStore.remove(entry))
    }

    @Test func garbageCollectionUsesTheGivenWallClock() throws {
        let home = try TempHome()
        let store = InboxStore(paths: home.paths)
        let temporary = home.paths.inboxTempDirectory
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let file = temporary.appending(path: "a.tmp")
        try Data().write(to: file)
        let modified = Date().addingTimeInterval(-3_600)
        try InboxFiles.setModified(file, modified)
        #expect(store.collectGarbage(now: modified.addingTimeInterval(InboxFile.garbageCollectionAge - 10)) == 0)
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        #expect(store.collectGarbage(now: modified.addingTimeInterval(InboxFile.garbageCollectionAge + 10)) == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    // MARK: LastEventStore

    @Test func lastEventStoreRoundTripsAndToleratesJunk() throws {
        let home = try TempHome()
        let store = LastEventStore(file: home.paths.lastEventsFile)
        #expect(store.load().values.isEmpty)
        #expect(store.load().failure == nil, "a missing file is not a failure")

        let values: [AgentID: Date] = [.claude: Fixture.t0, .copilot: Fixture.t0.addingTimeInterval(2.5), .unknown: Fixture.t0]
        try store.save(values)
        let loaded = store.load()
        #expect(loaded.values == [.claude: Fixture.t0, .copilot: Fixture.t0.addingTimeInterval(2.5)], "unknown is never persisted")
        #expect(loaded.failure == nil)

        try Data(#"{"claude":"2026-10-12T22:00:00.000Z","bogus-agent":"2026-10-12T22:00:00.000Z","codex":true,"gemini":1791842400,"cursor-agent":"2026-10-12T23:00:00Z","agy":"not a date"}"#.utf8)
            .write(to: home.paths.lastEventsFile)
        let tolerant = store.load()
        #expect(tolerant.values == [
            .claude: Fixture.t0,
            .gemini: Date(timeIntervalSince1970: 1_791_842_400),
            .cursor: Fixture.t0.addingTimeInterval(3_600), // alias label
        ])
        try Data("[1,2]".utf8).write(to: home.paths.lastEventsFile)
        #expect(store.load().failure != nil)
        #expect(store.load().values.isEmpty)
    }

    // MARK: RawPayload

    @Test func rawPayloadIsATolerantView() {
        let payload = RawPayload(data: Data(#"{"s":"x","empty":"","n":9007199254740993,"f":1.5,"b":true,"bs":"FALSE","null":null,"o":{"k":"v"},"a":[{"t":"1"},2,"three"],"deep":[[[[[[[[[[1]]]]]]]]]]}"#.utf8))
        #expect(payload.string("missing", "empty", "s") == "x", "empty strings are skipped")
        #expect(payload.string("n") == "9007199254740993", "integers above 2^53 keep every digit")
        #expect(payload.string("f") == "1.5")
        #expect(payload.string("b") == nil, "a boolean is never a string")
        #expect(payload.bool("b") == true)
        #expect(payload.bool("bs") == false)
        #expect(payload.bool("s") == nil)
        #expect(!payload.has("null"))
        #expect(payload.has("o"))
        #expect(payload.object("o")?.string("k") == "v")
        #expect(payload.objects("a").count == 1)
        #expect(payload.strings("a") == ["2", "three"])
        #expect(RawPayload(data: Data("[1]".utf8)).isEmpty)
        #expect(RawPayload(data: Data("not json".utf8)).isEmpty)
        #expect(RawPayload(data: Data()).isEmpty)
    }

    @Test func hostileNestingIsCut() {
        let depth = JSONValue.maxDepth + 20
        let json = String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth)
        let payload = RawPayload(data: Data(json.utf8))
        var current: RawPayload? = payload
        var levels = 0
        while let next = current?.object("a") {
            current = next
            levels += 1
        }
        #expect(levels < JSONValue.maxDepth)
    }

    // MARK: FieldLimits

    @Test func fieldsAreCappedOnCharacterBoundaries() {
        #expect(FieldLimits.capped(nil) == nil)
        #expect(FieldLimits.capped("  \n ") == nil)
        #expect(FieldLimits.capped("  id  ") == "id")
        let long = String(repeating: "é", count: 2_000) // 2 bytes each
        let capped = FieldLimits.capped(long)
        #expect(capped?.utf8.count == FieldLimits.maxFieldBytes)
        #expect(FieldLimits.capped("🙂🙂", maxBytes: 5) == "🙂")
    }

    @Test func displayTextIsSanitized() {
        #expect(FieldLimits.sanitized(nil) == nil)
        #expect(FieldLimits.sanitized("\u{1B}[1m\u{1B}[0m") == nil, "nothing printable left")
        let text = FieldLimits.sanitized("token ghp_abcdefghijklmnopqrstuvwxyz0123 at /Users/me/x/y.swift " + String(repeating: "z ", count: 200))
        #expect(text?.hasPrefix("token [redacted] at y.swift") == true)
        #expect((text?.count ?? 0) <= TextSanitizer.defaultLimit)
    }

    @Test func metadataIsBoundedAndDeterministic() {
        var values: [String: String] = [:]
        for index in 0..<40 { values[String(format: "k%02d", index)] = "v\(index)" }
        values["empty"] = " "
        values["long"] = String(repeating: "x", count: 5_000)
        let capped = FieldLimits.metadata(values)
        #expect(capped.count == FieldLimits.maxMetadataEntries)
        #expect(capped["empty"] == nil)
        #expect(Set(capped.keys) == Set((0..<16).map { String(format: "k%02d", $0) }), "sorted keys win")
        #expect(capped["k00"] == "v0")
        #expect(capped.values.allSatisfy { $0.utf8.count <= FieldLimits.maxFieldBytes })
    }

    // MARK: Events assembled by the pipeline are capped

    @Test func everyUntrustedStringLeavesTheModuleCapped() throws {
        var harness = PipelineHarness()
        let huge = String(repeating: "A", count: 10_000)
        let payload = try JSONSerialization.data(withJSONObject: [
            "session_id": huge, "cwd": "/" + huge, "transcript_path": "/" + huge, "prompt_id": huge,
            "last_assistant_message": huge, "permission_mode": huge,
        ])
        let event = try harness.accept("claude", "Stop", String(decoding: payload, as: UTF8.self))
        #expect(event.sessionKey.id.utf8.count <= FieldLimits.maxFieldBytes)
        #expect((event.cwd?.utf8.count ?? 0) <= FieldLimits.maxFieldBytes)
        #expect((event.transcriptPath?.utf8.count ?? 0) <= FieldLimits.maxFieldBytes)
        #expect((event.turnID?.utf8.count ?? 0) <= 256)
        #expect((event.messagePreview?.count ?? 0) <= TextSanitizer.defaultLimit)
        #expect(event.metadata.values.allSatisfy { $0.utf8.count <= FieldLimits.maxFieldBytes })
        #expect(event.argvAgentLabel == "claude")
    }

    @Test func futureTimestampsAreClampedToArrival() throws {
        var harness = PipelineHarness()
        let arrival = Fixture.t0
        let fromTheFuture = harness.send("claude", "Stop", #"{"session_id":"s"}"#, at: 3_600, receivedAt: arrival)
        #expect(fromTheFuture.event?.occurredAt == arrival)
        let slightlyAhead = harness.send("claude", "UserPromptSubmit", #"{"session_id":"s"}"#, at: 30, receivedAt: arrival)
        #expect(slightlyAhead.event?.occurredAt == arrival.addingTimeInterval(30), "small skew is kept")
    }

    @Test func droidIdlePromptWithoutStopEndsTheOpenTurn() throws {
        var harness = PipelineHarness()
        let idle = #"{"session_id":"d1","notification_type":"idle_prompt","message":"Droid is waiting"}"#
        _ = try harness.accept("droid", "UserPromptSubmit", #"{"session_id":"d1"}"#, at: 0)
        let cancelled = try harness.accept("droid", "Notification", idle, at: 5)
        #expect(cancelled.event == .turnFinished(.interrupted), "Droid sends idle_prompt INSTEAD of Stop on cancel")
        // After a regular Stop (turn closed) the same notification is only a reminder.
        _ = try harness.accept("droid", "UserPromptSubmit", #"{"session_id":"d1"}"#, at: 10)
        _ = try harness.accept("droid", "Stop", #"{"session_id":"d1"}"#, at: 20)
        #expect(try harness.accept("droid", "Notification", idle, at: 80).event == .idleReminder)
        // While the turn waits for a permission answer, idle_prompt means "still waiting".
        _ = try harness.accept("droid", "UserPromptSubmit", #"{"session_id":"d1"}"#, at: 100)
        _ = try harness.accept("droid", "Notification", #"{"session_id":"d1","notification_type":"permission_prompt"}"#, at: 101)
        #expect(try harness.accept("droid", "Notification", idle, at: 160).event == .idleReminder)
        // Claude's idle_prompt is never a turn end.
        _ = try harness.accept("claude", "UserPromptSubmit", #"{"session_id":"c1"}"#, at: 200)
        #expect(try harness.accept("claude", "Notification", #"{"session_id":"c1","notification_type":"idle_prompt"}"#, at: 205).event == .idleReminder)
    }
}
