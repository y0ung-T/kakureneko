@testable import KakurenekoSessions
import CoreServices
import KakurenekoKit
import Foundation
import Testing

/// Tolerant decoding of the real Claude shapes (R02 §3, §5): records, `agents --json`, transcript tails, liveness.
@Suite("Claude decoding", .timeLimit(.minutes(1)))
struct ClaudeDecodingTests {
    // MARK: Records

    @Test func r02RecordsDecodeWithUnknownKeys() throws {
        let interactive = try #require(ClaudeSessionRecord.decode(Data(R02.interactive().utf8)))
        #expect(interactive.pid == 96888)
        #expect(interactive.sessionId == R02.interactiveSession)
        #expect(interactive.statusKind == .busy)
        #expect(interactive.humanName == nil) // derived names are not titles
        #expect(!interactive.isIgnorable)
        #expect(interactive.procStartEpochSeconds == R02.startSec(R02.procStart))

        let background = try #require(ClaudeSessionRecord.decode(Data(R02.background.utf8)))
        #expect(background.humanName == "Titulná strana bakalárskej práce (2)")
        #expect(background.jobId == "e5b3e311")
        #expect(background.procStartEpochSeconds == R02.startSec(R02.procStartPadded))

        for text in [R02.parked, R02.spare, R02.daemon, R02.deadDaemonWorker] {
            #expect(try #require(ClaudeSessionRecord.decode(Data(text.utf8))).isIgnorable)
        }
        // Wrong types become nil; a missing pid makes the file unusable.
        let odd = try #require(ClaudeSessionRecord.decode(Data(#"{"pid":"77","status":42,"spare":"yes","statusUpdatedAt":"1791810678765"}"#.utf8)))
        #expect(odd.pid == 77)
        #expect(odd.status == nil)
        #expect(odd.statusUpdatedAt == 1_791_810_678_765)
        #expect(ClaudeSessionRecord.decode(Data(#"{"sessionId":"x"}"#.utf8)) == nil)
        #expect(ClaudeSessionRecord.decode(Data(#"{"pid":96888,"sessionId":"3514"#.utf8)) == nil) // caught mid-rewrite
    }

    @Test(arguments: [("96888.json", true), ("1.json", true), ("96888.0a1b2c3d.key", false), (".fleetview-heartbeat", false),
                      ("roster.json", false), ("96888.json.tmp", false), (".json", false), ("９６.json", false)])
    func onlyNumericJSONFilesAreRecords(name: String, isRecord: Bool) {
        #expect(ClaudeSessionRecord.isRecordFileName(name) == isRecord)
    }

    @Test func recordStringsAreCapped() {
        let long = String(repeating: "a", count: 5000)
        var record = ClaudeSessionRecord(pid: 1, sessionId: long, cwd: long, status: "busy", waitingFor: long, name: long,
                                         bridgeSessionId: long)
        record = ClaudeRecords.capped(record)
        #expect(record.sessionId?.count == ClaudeRecords.maxFieldLength)
        #expect(record.cwd?.count == ClaudeRecords.maxFieldLength)
        #expect(record.waitingFor?.count == ClaudeRecords.maxFieldLength)
        #expect(record.name?.count == ClaudeRecords.maxFieldLength)
        #expect(record.bridgeSessionId?.count == ClaudeRecords.maxFieldLength)
        #expect(record.status == "busy")
    }

    // MARK: Liveness (pid + procStart, R02 §3.6)

    struct LivenessCase: Sendable, CustomTestStringConvertible {
        var name: String
        var record: ClaudeSessionRecord
        var process: ProcessIdentity?
        var alive: Bool
        var testDescription: String { name }
    }

    static let start = R02.startSec(R02.procStart)

    @Test(arguments: [
        LivenessCase(name: "procStart matches", record: .init(pid: 10, procStart: R02.procStart),
                     process: .init(pid: 10, startSec: ClaudeDecodingTests.start, startUsec: 900_000), alive: true),
        LivenessCase(name: "within one second", record: .init(pid: 10, procStart: R02.procStart),
                     process: .init(pid: 10, startSec: ClaudeDecodingTests.start + 1, startUsec: 0), alive: true),
        LivenessCase(name: "pid reused", record: .init(pid: 10, procStart: R02.procStart),
                     process: .init(pid: 10, startSec: ClaudeDecodingTests.start + 2, startUsec: 0), alive: false),
        LivenessCase(name: "no such process", record: .init(pid: 10, procStart: R02.procStart), process: nil, alive: false),
        LivenessCase(name: "no procStart, started before registering",
                     record: .init(pid: 10, startedAt: Double(ClaudeDecodingTests.start + 5) * 1000),
                     process: .init(pid: 10, startSec: ClaudeDecodingTests.start, startUsec: 0), alive: true),
        LivenessCase(name: "no procStart, process younger than the record",
                     record: .init(pid: 10, startedAt: Double(ClaudeDecodingTests.start - 60) * 1000),
                     process: .init(pid: 10, startSec: ClaudeDecodingTests.start, startUsec: 0), alive: false),
        LivenessCase(name: "unparseable procStart falls back to startedAt",
                     record: .init(pid: 10, startedAt: Double(ClaudeDecodingTests.start) * 1000, procStart: "yesterday"),
                     process: .init(pid: 10, startSec: ClaudeDecodingTests.start, startUsec: 0), alive: true),
        LivenessCase(name: "neither", record: .init(pid: 10), process: .init(pid: 10, startSec: ClaudeDecodingTests.start, startUsec: 0), alive: true),
        LivenessCase(name: "pid 0", record: .init(pid: 0), process: .init(pid: 0, startSec: ClaudeDecodingTests.start, startUsec: 0), alive: false),
    ])
    func liveness(_ c: LivenessCase) {
        let lookup = StaticProcessLookup(c.process.map { [$0] } ?? [])
        let identity = ClaudeRecords.verifiedIdentity(of: c.record, lookup: lookup)
        #expect((identity != nil) == c.alive)
        if c.alive { #expect(identity == c.process) }
    }

    // MARK: Paths

    @Test(arguments: [
        ("/Users/tomasnguyen/Developer", "-Users-tomasnguyen-Developer"),
        ("/Users/tomasnguyen/Developer/projects portfolio", "-Users-tomasnguyen-Developer-projects-portfolio"),
        ("/Users/me/bakalárka_2.0", "-Users-me-bakal-rka-2-0"),
    ])
    func projectSlugReplacesEveryNonAlphanumeric(cwd: String, slug: String) {
        #expect(ClaudeRecords.projectSlug(forCwd: cwd) == slug)
    }

    @Test(arguments: [("abc.jsonl", true), ("", false), (".", false), ("..", false), ("../x", false), ("a/b", false), ("a\0b", false)])
    func pathComponentsFromUntrustedIDsAreChecked(name: String, safe: Bool) {
        #expect(ClaudeRecords.isSafePathComponent(name) == safe)
    }

    @Test func fsEventsFilterKeepsRecordsAndRescans() {
        let none = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        #expect(FSEventsDirectoryWatcher.isRelevant(path: "/h/.claude/sessions/96888.json", flags: none))
        #expect(!FSEventsDirectoryWatcher.isRelevant(path: "/h/.claude/sessions/96888.0a1b.key", flags: none))
        #expect(!FSEventsDirectoryWatcher.isRelevant(path: "/h/.claude/sessions/.fleetview-heartbeat", flags: none))
        #expect(!FSEventsDirectoryWatcher.isRelevant(path: "/h/.claude/sessions", flags: none))
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        #expect(FSEventsDirectoryWatcher.isRelevant(path: "/h/.claude/sessions", flags: rescan))
        let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
        #expect(FSEventsDirectoryWatcher.isRelevant(path: "/", flags: dropped))
    }

    // MARK: Transcript tail (R02 §5.2–5.3)

    @Test func transcriptTailYieldsTitleCwdPreviewAndTurnDuration() throws {
        let summary = TranscriptTail.summarize(Data(R02.transcript().utf8), startsAtFileStart: true)
        #expect(summary.customTitle == "Cursor reveal")
        #expect(summary.aiTitle == "Portfolio cursor reveal with blowout")
        #expect(summary.title == "Cursor reveal")
        #expect(summary.currentCwd == "/Users/tomasnguyen/Developer/projects portfolio")
        let preview = try #require(summary.lastAssistantPreview)
        #expect(preview.hasPrefix("Done."))
        #expect(preview.hasSuffix("Tests pass."))
        #expect(!preview.contains("\u{1B}"))
        #expect(!preview.contains("\n"))
        #expect(!preview.contains("Subagent"))
        #expect(summary.turnCompletedAt == KakurenekoJSON.date(fromISO8601: R02.turnCompletedAt))
        #expect(summary.turnDurationMs == 59_800)
        #expect(summary.turnPendingBackground == 1)
    }

    @Test(arguments: [
        ("agent-name beats ai-title", [#"{"type":"ai-title","aiTitle":"AI"}"#, #"{"type":"agent-name","agentName":"Agent"}"#], "Agent"),
        ("the latest ai-title wins", [#"{"type":"ai-title","aiTitle":"Old"}"#, #"{"type":"ai-title","aiTitle":"New"}"#], "New"),
        ("custom-title beats a later ai-title", [#"{"type":"custom-title","customTitle":"Mine"}"#, #"{"type":"ai-title","aiTitle":"AI"}"#], "Mine"),
        ("no title entries", [#"{"type":"user","message":{"content":"hi"}}"#], nil),
    ])
    func titlePrecedence(name: String, lines: [String], title: String?) {
        let summary = TranscriptTail.summarize(Data(lines.joined(separator: "\n").utf8), startsAtFileStart: true)
        #expect(summary.title == title)
    }

    @Test func turnDurationIsTheLastOneAndCountsAreOptional() throws {
        let lines = [
            #"{"type":"system","subtype":"turn_duration","durationMs":1000,"pendingWorkflowCount":3,"timestamp":"2026-10-12T21:00:00.000Z"}"#,
            #"{"type":"system","subtype":"away_summary","content":"recap"}"#,
            #"{"type":"system","subtype":"turn_duration","durationMs":"2500","timestamp":"2026-10-12T22:00:00.000Z"}"#,
        ]
        let summary = TranscriptTail.summarize(Data(lines.joined(separator: "\n").utf8), startsAtFileStart: true)
        #expect(summary.turnDurationMs == 2500)
        #expect(summary.turnPendingBackground == nil)
        #expect(summary.turnCompletedAt == KakurenekoJSON.date(fromISO8601: "2026-10-12T22:00:00.000Z"))
    }

    @Test func tailWindowDropsItsPartialFirstLineAndToleratesGarbage() {
        let text = #"tle":"Cut"}"# + "\n" + [
            "not json at all",
            "[1, 2, 3]",
            #"{"type":"assistant","message":{"content":"Plain string answer"}}"#,
            #"{"type":"ai-title","aiTitle":"Whole"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"x"}]}}"#,
            "",
        ].joined(separator: "\n")
        let tail = TranscriptTail.summarize(Data(text.utf8), startsAtFileStart: false)
        #expect(tail.title == "Whole")
        #expect(tail.lastAssistantPreview == "Plain string answer") // a tool-only entry has no text
        #expect(tail.turnDurationMs == nil)
        // At the start of the file the first line is whole (and here unparseable): nothing else changes.
        #expect(TranscriptTail.summarize(Data(text.utf8), startsAtFileStart: true).title == "Whole")
    }

    @Test func titlesSurviveScrollingOutOfTheTailWindow() {
        let older = TranscriptSummary(customTitle: "Mine", aiTitle: "AI", currentCwd: "/a")
        let newer = TranscriptSummary(aiTitle: "AI 2", turnDurationMs: 5)
        let merged = newer.carryingTitles(from: older)
        #expect(merged.customTitle == "Mine")
        #expect(merged.aiTitle == "AI 2")
        #expect(merged.currentCwd == "/a")
        #expect(merged.turnDurationMs == 5)
    }

    // MARK: `claude agents --json --all` (R02 §3.5)

    @Test func agentsSampleParses() throws {
        let entries = try #require(ClaudeCLI.parseAgents(SubprocessResult(exitCode: 0, stdout: Data(R02.agentsJSON.utf8))))
        #expect(entries.count == 3)
        #expect(entries[0].pid == 24617)
        #expect(entries[0].kind == "background")
        #expect(entries[0].state == "done")
        #expect(entries[0].id == "e5b3e311")
        #expect(entries[1].status == "busy")
        #expect(entries[1].sessionId == "fc061117-c7f7-4b91-9732-b6d60a05cd65")
        #expect(entries[2].pid == nil) // history: no process
        #expect(entries[2].state == "stopped")
    }

    @Test func agentsOutputIsParsedTolerantly() throws {
        let noisy = "Update available!\n" + R02.agentsJSON + "\n"
        #expect(ClaudeCLI.parseAgents(SubprocessResult(exitCode: 0, stdout: Data(noisy.utf8)))?.count == 3)
        let mixed = #"[{"pid":"12","status":"idle"}, 7, {"pid":true,"name":["x"]}, {"sessionId":"\#(String(repeating: "s", count: 3000))"}]"#
        let entries = try #require(ClaudeCLI.parseAgents(SubprocessResult(exitCode: 0, stdout: Data(mixed.utf8))))
        #expect(entries.count == 3)
        #expect(entries[0].pid == 12)
        #expect(entries[1].name == nil)
        #expect(entries[2].sessionId?.count == ClaudeCLI.maxFieldLength)
        #expect(ClaudeCLI.parseAgents(SubprocessResult(exitCode: 0, stdout: Data("[]".utf8))) == [])
    }

    @Test(arguments: [
        SubprocessResult(exitCode: 1, stdout: Data("[]".utf8)),
        SubprocessResult(exitCode: 0, stdout: Data("[]".utf8), timedOut: true),
        SubprocessResult(exitCode: 0, stdout: Data(#"{"error":"not logged in"}"#.utf8)),
        SubprocessResult(exitCode: 0, stdout: Data("garbage".utf8)),
    ])
    func failedAgentsRunsAreNil(result: SubprocessResult) {
        #expect(ClaudeCLI.parseAgents(result) == nil)
    }

    @Test func loginShellLookupTakesTheLastAbsolutePath() {
        let ok = SubprocessResult(exitCode: 0, stdout: Data("Welcome back!\n/opt/homebrew/bin/claude\n".utf8))
        #expect(ClaudeCLI.parseLookup(ok) == "/opt/homebrew/bin/claude")
        #expect(ClaudeCLI.parseLookup(SubprocessResult(exitCode: 0, stdout: Data("claude: aliased to …\n".utf8))) == nil)
        #expect(ClaudeCLI.parseLookup(SubprocessResult(exitCode: 1, stdout: Data("/usr/local/bin/claude\n".utf8))) == nil)
    }

    @Test func cliRequestsAreReadOnlyAndCarryTheAgentEnvironment() throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let agents = ClaudeCLI.agentsRequest(executable: "/x/claude", paths: paths)
        #expect(agents.executable == "/x/claude")
        #expect(agents.arguments == ["agents", "--json", "--all"])
        #expect(agents.stdin == nil)
        #expect(agents.environment == nil)
        #expect(agents.effect == .readOnly)
        #expect(agents.timeout == .seconds(10))
        for (key, value) in paths.agentSubprocessEnvironment { #expect(agents.extraEnvironment[key] == value) }
        // The temp home is an override: the CLI is pinned inside it, never the real ~/.claude.
        let home = paths.home.path(percentEncoded: false)
        #expect(agents.extraEnvironment["HOME"].map { home.hasPrefix($0) } == true)
        #expect(agents.extraEnvironment["CLAUDE_CONFIG_DIR"]?.hasPrefix(home) == true)
        #expect(agents.extraEnvironment["DISABLE_AUTOUPDATER"] == "1")
        #expect(agents.extraEnvironment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1")

        let lookup = ClaudeCLI.lookupRequest(paths: paths)
        #expect(lookup.executable == "/bin/zsh")
        #expect(lookup.arguments == ["-lc", "command -v claude"])
        #expect(lookup.stdin == nil)
        #expect(lookup.effect == .readOnly)
        var agentsWithoutPATH = agents.extraEnvironment
        #expect(agentsWithoutPATH.removeValue(forKey: "PATH") != nil) // the CLI's search path (npm/bun shims)
        #expect(lookup.extraEnvironment == agentsWithoutPATH)
    }
}
