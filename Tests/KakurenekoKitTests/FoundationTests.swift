import Darwin
import KakurenekoKit
import Foundation
import Testing

@Suite("Foundation utilities", .timeLimit(.minutes(1)))
struct FoundationTests {
    // MARK: TextSanitizer

    @Test func sanitizerStripsANSIAndRedactsSecrets() {
        let raw = "\u{1B}[32mDone\u{1B}[0m. Key sk-abcdefghijklmnop1234 and ghp_ABCDEFGHIJKLMNOPQRSTUV and AKIAABCDEFGHIJKLMNOP"
        let out = TextSanitizer.sanitize(raw, limit: 500)
        #expect(!out.contains("\u{1B}"))
        #expect(out.hasPrefix("Done."))
        #expect(!out.contains("sk-abcdefghijklmnop1234"))
        #expect(!out.contains("ghp_"))
        #expect(!out.contains("AKIA"))
        #expect(out.contains(TextSanitizer.redactionMarker))
    }

    @Test func sanitizerReducesPathsAndCollapsesWhitespace() {
        let out = TextSanitizer.sanitize("Edited /Users/me/proj/src/main.swift\n\n and  ~/notes/todo.md\tok", limit: 500)
        #expect(out == "Edited main.swift and todo.md ok")
    }

    @Test func sanitizerRedactsPEMAndLongHex() {
        let pem = "before -----BEGIN PRIVATE KEY-----\nMIIEv\n-----END PRIVATE KEY----- after"
        #expect(TextSanitizer.sanitize(pem, limit: 500) == "before [redacted] after")
        let hex = TextSanitizer.sanitize("token 0123456789abcdef0123456789abcdef01 end", limit: 500)
        #expect(hex == "token [redacted] end")
    }

    @Test func sanitizerTruncatesTo140() {
        let long = String(repeating: "word ", count: 100)
        let out = TextSanitizer.sanitize(long)
        #expect(out.count <= 140)
        #expect(out.hasSuffix("…"))
        #expect(TextSanitizer.sanitize("short") == "short")
    }

    // MARK: Formatting

    @Test func shortDurations() {
        #expect(KakurenekoFormat.shortDuration(35) == "35s")
        #expect(KakurenekoFormat.shortDuration(42 * 60) == "42m")
        #expect(KakurenekoFormat.shortDuration(65 * 60) == "1h 5m")
        #expect(KakurenekoFormat.shortDuration(2 * 3600) == "2h")
        #expect(KakurenekoFormat.shortDuration(76 * 3600) == "3d 4h")
        #expect(KakurenekoFormat.clockTime(Date(timeIntervalSince1970: 1_791_842_400), timeZone: TimeZone(identifier: "UTC")!) == "22:00")
        #expect(KakurenekoFormat.projectName(fromCwd: "/Users/me/Developer/api/") == "api")
        #expect(KakurenekoFormat.projectName(fromCwd: nil) == nil)
    }

    // MARK: AsyncBroadcaster

    @Test func broadcasterFansOutAndReplays() async {
        let b = AsyncBroadcaster<Int>(replayLatest: true)
        b.yield(1)
        let s1 = b.stream()
        let s2 = b.stream()
        #expect(b.subscriberCount == 2)
        b.yield(2)
        b.finish()
        var got1: [Int] = []
        for await v in s1 { got1.append(v) }
        var got2: [Int] = []
        for await v in s2 { got2.append(v) }
        #expect(got1 == [1, 2])
        #expect(got2 == [1, 2])
        // After finish, new streams end immediately.
        var late: [Int] = []
        for await v in b.stream() { late.append(v) }
        #expect(late.isEmpty)
    }

    @Test func broadcasterWithoutReplay() async {
        let b = AsyncBroadcaster<String>()
        b.yield("lost")
        let s = b.stream()
        b.yield("seen")
        b.finish()
        var got: [String] = []
        for await v in s { got.append(v) }
        #expect(got == ["seen"])
    }

    // MARK: TestClock

    @Test func testClockAdvancesSleepers() async throws {
        let clock = TestClock()
        let start = clock.now()
        let task = Task {
            try await clock.sleep(for: .seconds(300))
            return clock.now()
        }
        defer { task.cancel() } // never leave it parked if a check below fails
        // `#require`: advancing before the sleeper registered would move its deadline and park it forever.
        try #require(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(299))
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .seconds(1))
        let woke = try await task.value
        #expect(woke.timeIntervalSince(start) == 300)
    }

    @Test func testClockCancellation() async {
        let clock = TestClock()
        let task = Task { () -> Bool in
            do {
                try await clock.sleep(for: .seconds(60))
                return false
            } catch {
                return error is CancellationError
            }
        }
        _ = await clock.waitForSleepers(1)
        task.cancel()
        #expect(await task.value)
        #expect(clock.sleeperCount == 0)
    }

    // MARK: AtomicFile

    @Test func atomicFileWritesWithPermissionsAndFollowsSymlinks() throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let file = paths.home.appending(path: "dir/sub/file.json")
        try AtomicFile.write(Data("one".utf8), to: file, permissions: 0o600)
        var st = stat()
        #expect(stat(file.path(percentEncoded: false), &st) == 0 && st.st_mode & 0o777 == 0o600)
        // Replace keeps the existing mode when permissions == nil.
        try AtomicFile.write(Data("two".utf8), to: file)
        #expect(stat(file.path(percentEncoded: false), &st) == 0 && st.st_mode & 0o777 == 0o600)
        #expect(try AtomicFile.readIfExists(file) == Data("two".utf8))
        #expect(try AtomicFile.readIfExists(paths.home.appending(path: "missing")) == nil)
        // Symlink: the target is replaced, the link survives.
        let link = paths.home.appending(path: "link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        try AtomicFile.write(Data("three".utf8), to: link)
        #expect(try String(contentsOf: file, encoding: .utf8) == "three")
        let attrs = try FileManager.default.attributesOfItem(atPath: link.path(percentEncoded: false))
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        // No temp files left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path(percentEncoded: false))
        #expect(leftovers == ["file.json"])
    }

    // MARK: JSON dates

    @Test func kakurenekoJSONDates() throws {
        let date = Date(timeIntervalSince1970: 1_791_842_400.123)
        let encoded = try KakurenekoJSON.encode([date], pretty: false)
        #expect(String(decoding: encoded, as: UTF8.self) == #"["2026-10-12T22:00:00.123Z"]"#)
        let back = try KakurenekoJSON.decode([Date].self, from: encoded)
        #expect(abs(back[0].timeIntervalSince(date)) < 0.001)
        let plain = try KakurenekoJSON.decode([Date].self, from: Data(#"["2026-10-12T22:00:00Z", 1791842400]"#.utf8))
        #expect(plain[0] == plain[1])
        // Exact round trip for whole-millisecond dates, including ones before 1970.
        for ms: Int64 in [1_791_811_783_024, 1_791_842_400_000, 1, -1_500, 999] {
            let d = Date(timeIntervalSince1970: Double(ms) / 1000)
            #expect(KakurenekoJSON.date(fromISO8601: KakurenekoJSON.iso8601String(from: d)) == d)
        }
        #expect(KakurenekoJSON.iso8601String(from: Date(timeIntervalSince1970: -1.5)) == "1969-12-31T23:59:58.500Z")
        #expect(KakurenekoJSON.date(fromISO8601: "2026-10-12T22:00:00.1239Z") == Date(timeIntervalSince1970: 1_791_842_400.124))
    }

    // MARK: Logging

    @Test func fileLogSinkWritesAndRotates() throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let sink = FileLogSink(url: paths.appLogFile, maxBytes: 200, minimumLevel: .info)
        let logger = KakurenekoLogger(.coordinator, sink: sink)
        logger.debug("hidden")
        for i in 0..<10 { logger.info("line \(i) with some padding text") }
        let current = try String(contentsOf: paths.appLogFile, encoding: .utf8)
        #expect(!current.contains("hidden"))
        #expect(current.contains("[coordinator]"))
        #expect(FileManager.default.fileExists(atPath: paths.appLogFile.path(percentEncoded: false) + ".1"))
    }
}
