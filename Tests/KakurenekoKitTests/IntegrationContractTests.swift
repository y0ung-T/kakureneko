import Darwin
import KakurenekoKit
import Foundation
import Testing

/// Contract changes made while integrating the nine modules (ARCHITECTURE §11 "Integration changes").
@Suite("Integration contract changes", .timeLimit(.minutes(1)))
struct IntegrationContractTests {
    // MARK: ResumeEntry.resumeCommand

    /// Runs `command` under `/bin/sh` with `cd` and `claude` replaced by functions that print their arguments
    /// (\u{1}-separated, one \u{2}-terminated record per call): proves what the shell would pass, and that nothing else runs.
    private func shellArguments(of command: String, home: String) async throws -> [[String]] {
        let prelude = #"cd() { printf 'cd'; printf '\001%s' "$@"; printf '\002'; }; claude() { printf 'claude'; printf '\001%s' "$@"; printf '\002'; };"#
        let result = try await FoundationSubprocessRunner().run(SubprocessRequest(
            executable: "/bin/sh",
            arguments: ["-c", prelude + " " + command],
            environment: ["HOME": home, "PATH": "/usr/bin:/bin"],
            timeout: .seconds(10),
            effect: .readOnly
        ))
        #expect(result.exitCode == 0, "stderr: \(result.stderrString)")
        return result.stdoutString.split(separator: "\u{2}", omittingEmptySubsequences: true).map { line in
            line.split(separator: "\u{1}", omittingEmptySubsequences: false).map(String.init)
        }
    }

    @Test func resumeCommandWithoutACwdChangesToHome() async throws {
        let entry = ResumeEntry(agent: .claude, sessionId: "abc-123", cwd: nil, title: nil)
        #expect(entry.resumeCommand == #"cd "$HOME" && claude --resume abc-123"#)
        let empty = ResumeEntry(agent: .claude, sessionId: "abc-123", cwd: "", title: nil)
        #expect(empty.resumeCommand == entry.resumeCommand)
        let calls = try await shellArguments(of: try #require(entry.resumeCommand), home: "/Users/with space")
        #expect(calls == [["cd", "/Users/with space"], ["claude", "--resume", "abc-123"]])
    }

    @Test(arguments: [
        ("/x/it's", "plain-id"),
        ("/tmp/$(printf INJECTED)/`printf X`", "id; printf INJECTED"),
        ("/a b/\"q\"/\\back", "$(id)"),
        ("/new\nline", "'quoted'"),
        ("~", "--help"),
    ])
    func resumeCommandIsInjectionSafe(cwd: String, id: String) async throws {
        let entry = ResumeEntry(agent: .claude, sessionId: id, cwd: cwd, title: nil)
        let command = try #require(entry.resumeCommand)
        let calls = try await shellArguments(of: command, home: "/h")
        #expect(calls == [["cd", cwd], ["claude", "--resume", id]])
    }

    @Test func backgroundJobsAttachAndOtherAgentsHaveNoCommand() async throws {
        let job = ResumeEntry(agent: .claude, sessionId: "s", cwd: "/x", title: nil, kind: "bg", jobId: "job_42")
        #expect(job.resumeCommand == "claude attach job_42")
        let hostile = ResumeEntry(agent: .claude, sessionId: "s", cwd: "/x", title: nil, kind: "bg", jobId: "j`id`")
        #expect(try await shellArguments(of: try #require(hostile.resumeCommand), home: "/h") == [["claude", "attach", "j`id`"]])
        #expect(ResumeEntry(agent: .codex, sessionId: "t", cwd: "/x", title: nil).resumeCommand == nil)
        #expect(ResumeEntry(agent: .claude, sessionId: nil, cwd: "/x", title: nil).resumeCommand == nil)
        #expect(ResumeEntry(agent: .claude, sessionId: "", cwd: "/x", title: nil).resumeCommand == nil)
    }

    // MARK: InboxAncestor.module (python -m)

    @Test func pythonModuleDescriptor() throws {
        let aider = InboxAncestor(pid: 7, startSec: 1, startUsec: 2, exe: "Python", argv0: "/usr/bin/python3", module: "aider")
        #expect(aider.descriptor.argv == ["/usr/bin/python3", "-m", "aider"])
        let script = InboxAncestor(pid: 7, startSec: 1, startUsec: 2, exe: "python3.12", argv0: "python3.12", argv1: "/x/bin/aider")
        #expect(script.descriptor.argv == ["python3.12", "/x/bin/aider"])
        let bare = InboxAncestor(pid: 7, startSec: 1, startUsec: 2, exe: "zsh")
        #expect(bare.descriptor.argv == ["zsh"])

        #expect(InboxAncestor.isRecordableModule("aider"))
        #expect(InboxAncestor.isRecordableModule("aider.main"))
        #expect(InboxAncestor.isRecordableModule("_private.mod_2"))
        for bad in ["", "two words", "a/b", "a..b", ".a", "a.", "1abc", "é", "a;b", "$(id)", String(repeating: "a", count: 129)] {
            #expect(!InboxAncestor.isRecordableModule(bad), "\(bad)")
        }
        #expect(InboxAncestor.isPythonInterpreterName("python3.12"))
        #expect(InboxAncestor.isPythonInterpreterName("/Library/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"))
        #expect(!InboxAncestor.isPythonInterpreterName("node"))

        // Untrusted header: an invalid module is dropped on decode; a valid one round-trips.
        let json = #"[{"pid":1,"startSec":1,"startUsec":0,"module":"aider"},{"pid":2,"startSec":1,"startUsec":0,"module":"rm -rf /"}]"#
        let decoded = try JSONDecoder().decode([InboxAncestor].self, from: Data(json.utf8))
        #expect(decoded.map(\.module) == ["aider", nil])
        let reencoded = try JSONDecoder().decode(InboxAncestor.self, from: JSONEncoder().encode(aider))
        #expect(reencoded == aider)
    }

    // MARK: AtomicFile follows link chains

    @Test func atomicWriteFollowsADanglingLinkChainAndKeepsTheLinks() throws {
        let paths = try Paths.temporary(prefix: "kakureneko-atomic")
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let root = paths.home.deletingLastPathComponent()
        let real = root.appending(path: "real", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        // link1 → link2 (relative) → real/missing/target.json (absolute, dangling: neither the file nor its dir exist)
        let target = real.appending(path: "missing/target.json")
        let link2 = root.appending(path: "link2")
        let link1 = root.appending(path: "link1")
        try FileManager.default.createSymbolicLink(atPath: link2.path(percentEncoded: false), withDestinationPath: target.path(percentEncoded: false))
        try FileManager.default.createSymbolicLink(atPath: link1.path(percentEncoded: false), withDestinationPath: "link2")

        #expect(try AtomicFile.finalTarget(of: link1).path(percentEncoded: false) == target.path(percentEncoded: false))
        try AtomicFile.write(Data("hello".utf8), to: link1, permissions: 0o640)
        #expect(try Data(contentsOf: target) == Data("hello".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link1.path(percentEncoded: false)) == "link2")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link2.path(percentEncoded: false)) == target.path(percentEncoded: false))
        var st = stat()
        #expect(stat(target.path(percentEncoded: false), &st) == 0 && st.st_mode & 0o7777 == 0o640)

        // A second write keeps the mode and still goes through both links.
        try AtomicFile.write(Data("again".utf8), to: link1)
        #expect(try Data(contentsOf: target) == Data("again".utf8))
        #expect(stat(target.path(percentEncoded: false), &st) == 0 && st.st_mode & 0o7777 == 0o640)

        // followSymlinks: false replaces the link itself.
        try AtomicFile.write(Data("own".utf8), to: link2, followSymlinks: false)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link2.path(percentEncoded: false))) == nil)
        #expect(try Data(contentsOf: link2) == Data("own".utf8))
        #expect(try Data(contentsOf: target) == Data("again".utf8))
    }

    @Test func atomicWriteRefusesASymlinkLoop() throws {
        let paths = try Paths.temporary(prefix: "kakureneko-atomic")
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let root = paths.home.deletingLastPathComponent()
        let a = root.appending(path: "a")
        try FileManager.default.createSymbolicLink(atPath: a.path(percentEncoded: false), withDestinationPath: "b")
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: "b").path(percentEncoded: false), withDestinationPath: "a")
        #expect(throws: AtomicFile.Failure.self) { try AtomicFile.write(Data("x".utf8), to: a) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: a.path(percentEncoded: false)) == "b")
    }

    // MARK: Presence

    @Test func unknownInputTimeCountsAsAwayOnlyWithTheLidClosed() {
        #expect(Presence(lidClosed: true, screenLocked: false, secondsSinceUserInput: nil).isAway())
        #expect(!Presence(lidClosed: false, screenLocked: false, secondsSinceUserInput: nil).isAway())
        #expect(Presence(lidClosed: false, screenLocked: true, secondsSinceUserInput: nil).isAway())
        #expect(Presence(lidClosed: false, screenLocked: false, secondsSinceUserInput: 300).isAway(idleThreshold: 300))
        #expect(!Presence(lidClosed: false, screenLocked: false, secondsSinceUserInput: 299).isAway(idleThreshold: 300))
        // Lid closed: always away for notifications, even with recent input.
        #expect(Presence(lidClosed: true, screenLocked: false, secondsSinceUserInput: 1).isAway())
        #expect(Presence.hasRecentInput(secondsSinceUserInput: nil, idleThreshold: 300, lidClosed: false))
        #expect(!Presence.hasRecentInput(secondsSinceUserInput: nil, idleThreshold: 300, lidClosed: true))
        #expect(Presence.hasRecentInput(secondsSinceUserInput: 1, idleThreshold: 300, lidClosed: true))
    }

    // MARK: Shared constants

    @Test func sharedConstants() {
        #expect(EvidenceSample.window == 60)
        let keys = [MetadataKey.transcriptPath, MetadataKey.sessionStoreDirectory, MetadataKey.claudeKind,
                    MetadataKey.claudeJobID, MetadataKey.claudeEntrypoint, MetadataKey.codexClient,
                    MetadataKey.opencodeChildSession, MetadataKey.opencodeSessionID, MetadataKey.claudeSessionStartSource,
                    MetadataKey.relabelledFrom, MetadataKey.claudePermissionMode, MetadataKey.claudeAgentType,
                    MetadataKey.sessionEndReason, MetadataKey.codexSessionStartSource, MetadataKey.geminiSessionStartSource,
                    MetadataKey.copilotSessionStartSource, MetadataKey.cursorComposerMode, MetadataKey.agyTerminationReason,
                    MetadataKey.auggieStopCause]
        #expect(Set(keys).count == keys.count)
    }

    // MARK: Settings

    @Test func defaultsAreAFixedPointOfNormalized() {
        #expect(KakurenekoSettings.default.normalized() == KakurenekoSettings.default)
        #expect(KakurenekoSettings.default.version == 2)
    }

    @Test func version1SettingsMigrateToAlwaysNotifyAndDropNtfy() throws {
        // A real v1 file (ntfy era): presence gating was "awayOnly" by default, provider/server keys exist.
        let v1 = #"""
        {"version":1,"notifications":{"enabled":true,"provider":"ntfy","ntfyServer":"https://ntfy.sh/","detailLevel":"detailed",
         "presenceGating":"awayOnly","awayIdleSeconds":300,"quietHours":{"enabled":false,"startMinute":1380,"endMinute":420},
         "mutedKinds":["stalled"],"rateLimitPerTenMinutes":6,"needsInputReminderMinutes":10},"general":{"onboardingCompleted":true}}
        """#
        let decoded = try KakurenekoJSON.decode(KakurenekoSettings.self, from: Data(v1.utf8)).normalized()
        #expect(decoded.version == 2)
        #expect(decoded.notifications.phoneTiming == .lidClosed, "v1's away-only default is not carried over")
        #expect(decoded.notifications.macAlerts && decoded.notifications.phoneAlerts)
        #expect(decoded.notifications.detailLevel == .detailed && decoded.notifications.mutedKinds == [.stalled], "other choices are kept")
        #expect(decoded.general.onboardingCompleted)
        let encoded = String(decoding: try KakurenekoJSON.encode(decoded), as: UTF8.self)
        #expect(!encoded.contains("ntfy"))
        // A v2 user who chose "away only" keeps it, for the iPhone.
        let v2 = #"{"version":2,"notifications":{"presenceGating":"awayOnly"}}"#
        #expect(try KakurenekoJSON.decode(KakurenekoSettings.self, from: Data(v2.utf8)).normalized().notifications.phoneTiming == .away)
    }

    // MARK: TestClock helpers

    @Test func testClockWaitsForSleepersByWallClockAndReportsDeadlines() async throws {
        let clock = TestClock()
        #expect(await clock.waitForSleepers(1, timeout: .milliseconds(20)) == false)
        let task = Task { try? await clock.sleep(for: .seconds(5)) }
        defer { task.cancel() }
        try #require(await clock.waitForSleepers(1))
        #expect(clock.sleeperDeadlines == [TestClock.defaultStart.addingTimeInterval(5)])
        #expect(await clock.waitForSleeper(dueBy: TestClock.defaultStart.addingTimeInterval(5)))
        #expect(await clock.waitForSleeper(dueBy: TestClock.defaultStart.addingTimeInterval(4), timeout: .milliseconds(20)) == false)
        clock.advance(by: .seconds(5))
        await task.value
        #expect(clock.sleeperDeadlines.isEmpty)
    }
}
