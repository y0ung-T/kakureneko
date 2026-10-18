@testable import KakurenekoSessions
import Darwin
import KakurenekoKit
import Foundation
import Testing

/// `PosixClaudeFileAccess`: read-only, regular files only (a FIFO or device can never block the watcher), tail reads
/// for multi-MB transcripts, size caps for records.
@Suite("Claude file access", .timeLimit(.minutes(1)))
struct ClaudeFileAccessTests {
    let access = PosixClaudeFileAccess()

    @Test func readsWholeSmallFilesAndRefusesLargeOnes() throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let url = paths.home.appending(path: "1.json")
        try Data(R02.interactive().utf8).write(to: url)
        #expect(access.readFile(url, maxBytes: ClaudeRecords.maxRecordBytes) == Data(R02.interactive().utf8))
        #expect(access.readFile(url, maxBytes: 10) == nil)
        #expect(access.readFile(paths.home.appending(path: "missing.json"), maxBytes: 1024) == nil)
        #expect(access.readFile(paths.home, maxBytes: 1024) == nil) // a directory
    }

    @Test func tailReadsOnlyTheLastBytes() throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let url = paths.home.appending(path: "big.jsonl")
        let filler = String(repeating: #"{"type":"attachment","attachment":{"type":"hook_success"}}"# + "\n", count: 6000)
        let text = #"{"type":"custom-title","customTitle":"Scrolled away"}"# + "\n" + filler + R02.transcript()
        try Data(text.utf8).write(to: url)
        let tail = try #require(access.readTail(url, maxBytes: TranscriptTail.maxBytes))
        #expect(tail.data.count == TranscriptTail.maxBytes)
        #expect(tail.offset == UInt64(text.utf8.count - TranscriptTail.maxBytes))
        let summary = TranscriptTail.summarize(tail.data, startsAtFileStart: tail.offset == 0)
        #expect(summary.customTitle == "Cursor reveal") // the in-window one; the scrolled-away title is not seen
        #expect(summary.turnDurationMs == 59_800)
        let small = try #require(access.readTail(url, maxBytes: 10_000_000))
        #expect(small.offset == 0)
        #expect(small.data.count == text.utf8.count)
    }

    @Test func fifoIsNeverReadAndNeverBlocks() throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let fifo = paths.home.appending(path: "42.json")
        #expect(mkfifo(fifo.path(percentEncoded: false), 0o600) == 0)
        #expect(access.readFile(fifo, maxBytes: 1024) == nil)
        #expect(access.readTail(fifo, maxBytes: 1024) == nil)
        let stamp = try #require(access.stamp(fifo))
        #expect(!stamp.isRegularFile && !stamp.isDirectory)
        #expect(!access.isExecutableFile(fifo))
    }

    @Test func stampsListingsAndExecutables() throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        #expect(access.listDirectory(paths.home.appending(path: "nope")) == nil)
        #expect(access.stamp(paths.home)?.isDirectory == true)
        let script = paths.home.appending(path: "claude")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: script)
        #expect(!access.isExecutableFile(script))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
        #expect(access.isExecutableFile(script))
        #expect(!access.isExecutableFile(paths.home)) // a directory is not a CLI
        #expect(access.listDirectory(paths.home) == ["claude"])
        let stamp = try #require(access.stamp(script))
        #expect(stamp.size == 17)
        #expect(stamp.isRegularFile)
    }

    @Test func theWatcherNeverWritesUnderTheClaudeConfigDirectory() async throws {
        let f = try WatcherFixture()
        try ClaudeWatcherTests.writeR02Directory(f)
        try f.writeTranscript(directory: "-Users-tomasnguyen-Developer", sessionId: R02.interactiveSession, R02.transcript())
        try f.installCLICandidate()
        f.answerAgents(R02.agentsJSON)
        let before = try Self.tree(f.paths.claudeConfigDirectory)
        let watcher = f.makeWatcher()
        let collector = SnapshotCollector(watcher.snapshots())
        await watcher.start()
        #expect(await collector.first { $0.agents != nil } != nil)
        _ = await watcher.current()
        f.clock.advance(by: .seconds(60))
        #expect(await waitUntil { f.agentsRequests.count == 2 })
        await watcher.stop()
        #expect(try Self.tree(f.paths.claudeConfigDirectory) == before)
    }

    /// Relative path → (size, mtime) of everything under `root`.
    static func tree(_ root: URL) throws -> [String: [Double]] {
        var out: [String: [Double]] = [:]
        let base = root.path(percentEncoded: false)
        guard let walker = FileManager.default.enumerator(atPath: base) else { return out }
        for case let relative as String in walker {
            let attributes = try FileManager.default.attributesOfItem(atPath: (base as NSString).appendingPathComponent(relative))
            let size = (attributes[.size] as? NSNumber)?.doubleValue ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            out[relative] = [size, modified]
        }
        return out
    }
}
