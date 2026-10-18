import Darwin
@testable import KakurenekoHook
import KakurenekoKit
import Foundation
import Testing

/// Unit tests of the Darwin-only hook internals, and their parity with the Kit reference types (the hook cannot link
/// KakurenekoKit, so every mirrored constant and rule is checked here).
@Suite("kakureneko-hook internals", .timeLimit(.minutes(1)))
struct HookInternalsTests {
    // MARK: Parity with KakurenekoKit

    @Test func constantsMirrorTheKit() {
        #expect(HookEnvironment.allowList == InboxHeader.environmentAllowList)
        #expect(HookConstants.inboxDarwinNotification == KakurenekoID.inboxDarwinNotification)
        #expect(HookConstants.ownBinarySuffix == KakurenekoID.ownershipMarker)
        #expect(HookConstants.fallbackInboxRelativePath == KakurenekoID.fallbackInboxRelativePath)
        #expect(HookConstants.maxQueuedFiles == InboxFile.maxQueuedFiles)
        #expect(HookConstants.maxPayloadBytes == InboxFile.maxPayloadBytes)
        #expect(HookConstants.maxHeaderBytes == InboxFile.maxHeaderBytes)
        #expect(HookConstants.headerVersion == InboxHeader.currentVersion)
        #expect(HookConstants.inboxVariable == KakurenekoEnvironment.inbox)
        #expect(HookConstants.fallbackInboxVariable == KakurenekoEnvironment.fallbackInbox)
        #expect(HookConstants.recordVariable == KakurenekoEnvironment.record)
    }

    @Test(arguments: ["CLAUDE_CODE_MESSAGING_TOKEN", "OPENAI_API_KEY", "my_secret", "DB_PASSWORD", "apiKey", "TERM_PROGRAM",
                      "CLAUDE_PID", "KEYCHAIN", "tokenizer"])
    func forbiddenNamesMatchTheKitRule(name: String) {
        #expect(HookEnvironment.isForbidden(name) == InboxHeader.isForbiddenEnvironmentName(name))
    }

    @Test func noAllowListedNameIsForbidden() {
        for name in HookEnvironment.allowList { #expect(!HookEnvironment.isForbidden(name), "\(name)") }
    }

    @Test(arguments: ["/Users/x/bin/aider", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js", "-c", "run",
                      "/path with space/x", "fix the bug in /src/main.swift", "./relative/path", "/" + String(repeating: "a", count: 511),
                      "/" + String(repeating: "a", count: 512), "/tab\there", ""])
    func argv1RuleMatchesTheKit(value: String) {
        #expect(HookAncestry.isRecordableArgv1(value) == InboxAncestor.isRecordableArgv1(value))
    }

    @Test func fileStemMatchesInboxFileName() {
        let stem = HookInbox.fileStem(epochNanoseconds: 1_791_811_783_024_000_123)
        #expect(stem + ".event" == InboxFile.fileName(epochNanoseconds: 1_791_811_783_024_000_123, pid: getpid()))
        let short = HookInbox.fileStem(epochNanoseconds: 42)
        #expect(short + ".event" == InboxFile.fileName(epochNanoseconds: 42, pid: getpid()))
        #expect(short.hasPrefix("0000000000000000042-"))
    }

    @Test func truthyMatchesTheKitRule() {
        for value in ["1", "true", "TRUE", "yes", "On", " 1 ", "0", "false", "", "no", "2"] {
            let duplicated = strdup(value)
            defer { free(duplicated) }
            #expect(HookEnvironment.isTruthy(duplicated) == KakurenekoEnvironment.isTruthy(value), "\(value)")
        }
        #expect(!HookEnvironment.isTruthy(nil))
    }

    // MARK: Invocation parsing

    @Test func parsesAgentEventChainAndTrailingJSON() throws {
        let plain = try #require(HookInvocation(arguments: ["hook", "claude", "Stop"]))
        #expect(plain.agent == "claude")
        #expect(plain.event == "Stop")
        #expect(plain.chain.isEmpty)
        #expect(plain.argvPayload == nil)
        #expect(plain.hasValidLabels)

        let codex = try #require(HookInvocation(arguments: ["hook", "codex", "notify", "--chain", "--", "X", "a", #" {"type":"x"} "#]))
        #expect(codex.chain == ["X", "a"])
        #expect(codex.argvPayload == Array(#" {"type":"x"} "#.utf8))

        let aider = try #require(HookInvocation(arguments: ["hook", "aider", "waiting", "--chain", "--", "sh", "-c", "say hi"]))
        #expect(aider.chain == ["sh", "-c", "say hi"])
        #expect(aider.argvPayload == nil)

        let noSeparator = try #require(HookInvocation(arguments: ["hook", "aider", "waiting", "--chain", "notify-send"]))
        #expect(noSeparator.chain == ["notify-send"])

        #expect(HookInvocation(arguments: ["hook", "claude"]) == nil)
        #expect(HookInvocation(arguments: ["hook"]) == nil)
    }

    @Test(arguments: [("claude", true), ("continue", true), ("kiro-cli", true), ("pi.rpc", true), ("Stop", true),
                      ("session.status", true), ("pre_user_prompt", true), ("", false), ("-x", false), ("bad/agent", false),
                      ("a b", false), ("é", false), ("x;rm", false), (String(repeating: "a", count: 64), true),
                      (String(repeating: "a", count: 65), false), ("..", false)])
    func labelValidation(label: String, valid: Bool) {
        #expect(HookInvocation.isValidLabel(label) == valid)
    }

    @Test func jsonObjectDetection() {
        #expect(HookInvocation.looksLikeJSONObject(#"{"a":1}"#))
        #expect(HookInvocation.looksLikeJSONObject("\n {} \t"))
        #expect(!HookInvocation.looksLikeJSONObject("[1]"))
        #expect(!HookInvocation.looksLikeJSONObject("{unterminated"))
        #expect(!HookInvocation.looksLikeJSONObject(""))
    }

    // MARK: JSON writer

    @Test func headerJSONRoundTripsThroughInboxFileParse() throws {
        let invocation = try #require(HookInvocation(arguments: ["hook", "claude", "Stop"]))
        let hostile = "quote\" backslash\\ newline\n tab\t nul\u{0} bell\u{7} del\u{7F} ls\u{2028} emoji🙂 é"
        let header = HookHeader.make(
            invocation: invocation,
            timestampMilliseconds: 1_791_811_783_024,
            payloadSource: .stdin,
            environment: [("TERM_PROGRAM", hostile), ("CLAUDE_PID", "96888")],
            ancestry: [HookAncestor(pid: 96_888, ppid: 96_880, startSec: 1_791_810_323, startUsec: 1_234, exe: "2.1.296",
                                    argv0: hostile, argv1: "/Users/x/bin/claude", path: "/Users/x/.local/share/claude/versions/2.1.296",
                                    tdev: -1)]
        )
        var file = header
        file.append(0x0A)
        let payload = Array(#"{"raw":"payload \" never re-escaped"}"#.utf8)
        file.append(contentsOf: payload)
        let parsed = try InboxFile.parse(Data(file))
        #expect(parsed.header.agent == "claude")
        #expect(parsed.header.event == "Stop")
        #expect(parsed.header.ts == 1_791_811_783_024)
        #expect(parsed.header.pid == getpid())
        #expect(parsed.header.payloadSource == "stdin")
        #expect(parsed.header.env["TERM_PROGRAM"] == hostile)
        #expect(parsed.header.env["CLAUDE_PID"] == "96888")
        let ancestor = try #require(parsed.header.ancestry.first)
        #expect(ancestor.pid == 96_888)
        #expect(ancestor.ppid == 96_880)
        #expect(ancestor.startSec == 1_791_810_323)
        #expect(ancestor.startUsec == 1_234)
        #expect(ancestor.exe == "2.1.296")
        #expect(ancestor.argv0 == hostile)
        #expect(ancestor.argv1 == "/Users/x/bin/claude")
        #expect(ancestor.controllingTTY == nil)
        #expect(parsed.payload == Data(payload))
        #expect(!header.contains(0x0A), "the header is exactly one line")
    }

    @Test func escapeHeavyHeadersAreCompactedBelowTheAppLimit() throws {
        let invocation = try #require(HookInvocation(arguments: ["hook", "claude", "Stop"]))
        // Raw lengths are capped, but every control character escapes to 6 bytes (`\u0001`).
        let hostile = String(repeating: "\u{1}", count: HookConstants.maxValueBytes)
        let environment = HookEnvironment.allowList.map { (name: $0, value: hostile) }
        let ancestry = (0..<HookConstants.maxAncestors).map { index in
            HookAncestor(pid: Int32(100 + index), ppid: Int32(101 + index), startSec: 1_791_800_000, startUsec: 7, exe: "node",
                         argv0: hostile, argv1: "/opt/homebrew/bin/gemini", path: "/x/" + String(repeating: "\u{2}", count: 900), tdev: -1)
        }
        let full = HookHeader.make(invocation: invocation, timestampMilliseconds: 1, payloadSource: .stdin,
                                   environment: environment, ancestry: ancestry, cwd: "/w")
        #expect(full.count > InboxFile.maxHeaderBytes, "the app would reject this header")

        let bounded = HookHeader.bounded(invocation: invocation, timestampMilliseconds: 1, payloadSource: .stdin,
                                         environment: environment, ancestry: ancestry, cwd: "/w")
        #expect(bounded.count <= HookHeader.byteBudget)
        let parsed = try InboxFile.parse(Data(bounded + [0x0A]))
        #expect(parsed.header.env.count == HookEnvironment.allowList.count)
        #expect(parsed.header.ancestry.count == HookConstants.maxAncestors)
        let first = try #require(parsed.header.ancestry.first)
        #expect(first.argv1 == "/opt/homebrew/bin/gemini", "short paths survive compaction")
        #expect(first.path == nil, "an over-long path is dropped, never truncated into a wrong one")
        #expect(first.argv0.map { $0.allSatisfy { $0 == "\u{1}" } } == true)
        #expect(first.identity == ProcessIdentity(pid: 100, startSec: 1_791_800_000, startUsec: 7))

        // Ordinary headers are never compacted.
        let normal = HookHeader.bounded(invocation: invocation, timestampMilliseconds: 1, payloadSource: .none,
                                        environment: [("TERM_PROGRAM", "Apple_Terminal")], ancestry: Array(ancestry.prefix(1)), cwd: "/w")
        #expect(normal == HookHeader.make(invocation: invocation, timestampMilliseconds: 1, payloadSource: .none,
                                          environment: [("TERM_PROGRAM", "Apple_Terminal")], ancestry: Array(ancestry.prefix(1)), cwd: "/w"))
    }

    @Test func writerCapsTheEscapedBodyOnScalarBoundaries() {
        func encoded(_ value: String, _ maxBytes: Int) -> String {
            var json = HookJSONWriter()
            json.string(value, maxBytes: maxBytes)
            return String(decoding: json.bytes, as: UTF8.self)
        }
        #expect(encoded("ééé", 3) == "\"é\"")
        #expect(encoded("\n\n", 3) == #""\n""#)
        #expect(encoded("ab", .max) == "\"ab\"")
        #expect(encoded("\u{1}x", 5) == "\"\"", "a 6-byte escape never gets cut in half")
        #expect(HookJSONWriter.escapedLength("a\"\u{1}é") == 1 + 2 + 6 + 2)
    }

    @Test func truncationKeepsScalarBoundaries() {
        #expect(HookText.truncated("abc", maxBytes: 10) == "abc")
        #expect(HookText.truncated("éééé", maxBytes: 3) == "é")
        #expect(HookText.truncated("🙂🙂", maxBytes: 5) == "🙂")
    }

    // MARK: Ancestry (read-only probes of this test process)

    @Test func ancestryOfThisProcessMatchesTheKernelReferenceLookup() throws {
        let ancestry = HookAncestry.collect(startingAt: getpid())
        let first = try #require(ancestry.first)
        let reference = try #require(KernelProcessLookup().identity(of: getpid()))
        #expect(first.pid == reference.pid)
        #expect(first.startSec == reference.startSec)
        #expect(first.startUsec == reference.startUsec)
        #expect(first.ppid == getppid())
        #expect(first.path != nil)
        #expect(first.argv0 != nil)
        #expect(ancestry.count <= HookConstants.maxAncestors)
        #expect(Set(ancestry.map(\.pid)).count == ancestry.count, "no ancestor twice")
        #expect(!ancestry.contains { $0.pid <= 1 }, "launchd is excluded")
        if ancestry.count > 1 { #expect(ancestry[1].pid == getppid()) }
    }

    @Test func undersizedArgumentBufferGrowsInsteadOfReportingTheTail() throws {
        // Start with a tiny buffer: the kernel would copy the TAIL of the argument area. The reader must notice the
        // full buffer, grow it once and report this process's real argv[0].
        var tiny = [UInt8](repeating: 0, count: 8)
        let size = try #require(HookAncestry.readArgumentArea(of: getpid(), into: &tiny))
        #expect(tiny.count > 8)
        #expect(size < tiny.count)
        let parsed = HookAncestry.parseArguments(tiny, size: size)
        #expect(parsed.argv0 == CommandLine.arguments.first.map { HookText.truncated($0, maxBytes: HookAncestry.maxArgv0Bytes) })

        var normal = [UInt8](repeating: 0, count: HookAncestry.argumentBufferSize)
        let reference = HookAncestry.arguments(of: getpid(), buffer: &normal)
        #expect(reference.argv0 == parsed.argv0)
    }

    @Test func parseArgumentsHandlesTruncatedAndHostileAreas() {
        func area(argc: Int32, _ strings: [String], padding: Int = 3) -> [UInt8] {
            var bytes = withUnsafeBytes(of: argc.littleEndian) { Array($0) }
            for (index, string) in strings.enumerated() {
                bytes += Array(string.utf8) + [0]
                if index == 0 { bytes += [UInt8](repeating: 0, count: padding) }
            }
            return bytes
        }
        let ok = area(argc: 2, ["/bin/bash", "/bin/sh", "/tmp/run.sh", "ENV=secret"])
        let parsed = HookAncestry.parseArguments(ok, size: ok.count)
        #expect(parsed.argv0 == "/bin/sh")
        #expect(parsed.argv1 == "/tmp/run.sh")

        let prompt = area(argc: 2, ["/x/claude", "claude", "fix the login bug /src/a.swift"])
        #expect(HookAncestry.parseArguments(prompt, size: prompt.count).argv1 == nil, "argv[1] with whitespace is never recorded")

        let single = area(argc: 1, ["/x/node", "node", "/never/env/var"])
        let singleParsed = HookAncestry.parseArguments(single, size: single.count)
        #expect(singleParsed.argv0 == "node")
        #expect(singleParsed.argv1 == nil, "argc bounds argv: environment strings are never read")

        var cut = area(argc: 2, ["/bin/bash", "/bin/sh", "/tmp/run.sh"])
        cut.removeLast(3) // argv[1] lost its terminator
        let cutParsed = HookAncestry.parseArguments(cut, size: cut.count)
        #expect(cutParsed.argv0 == "/bin/sh")
        #expect(cutParsed.argv1 == nil)

        #expect(HookAncestry.parseArguments([1, 0, 0, 0], size: 4).argv0 == nil)
        #expect(HookAncestry.parseArguments(area(argc: 0, ["/x", "y"]), size: 12).argv0 == nil)
    }

    /// `python -m aider` (ARCHITECTURE §11 integration change): the module of a Python interpreter is recorded when
    /// it is a plain dotted identifier — and nothing else from argv[2…] ever is.
    @Test func pythonModuleIsRecordedOnlyForPythonAndOnlyAsAnIdentifier() {
        func area(argc: Int32, _ strings: [String]) -> [UInt8] {
            var bytes = withUnsafeBytes(of: argc.littleEndian) { Array($0) }
            for (index, string) in strings.enumerated() {
                bytes += Array(string.utf8) + [0]
                if index == 0 { bytes += [0, 0, 0] }
            }
            return bytes
        }
        func parse(_ strings: [String], argc: Int32? = nil) -> (argv0: String?, argv1: String?, module: String?) {
            let bytes = area(argc: argc ?? Int32(strings.count - 1), strings)
            return HookAncestry.parseArguments(bytes, size: bytes.count)
        }
        let plain = parse(["/usr/bin/python3", "python3", "-m", "aider", "--yes-always"])
        #expect(plain.argv0 == "python3")
        #expect(plain.argv1 == nil, "-m is not path-like")
        #expect(plain.module == "aider")
        #expect(parse(["/opt/homebrew/bin/python3.12", "python3.12", "-u", "-X", "dev", "-W", "ignore", "-m", "aider.main"]).module == "aider.main")
        #expect(parse(["/usr/bin/python3", "python3", "-maider"]).module == "aider")
        // The framework build's exec path identifies Python even with an unusual argv[0].
        #expect(parse(["/Library/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python", "aider-wrapper", "-m", "aider"]).module == "aider")
        // Scripts, -c and non-identifiers never yield a module (argv[1] keeps its own path rule).
        let script = parse(["/usr/bin/python3", "python3", "/x/bin/aider", "-m", "aider"])
        #expect(script.module == nil)
        #expect(script.argv1 == "/x/bin/aider")
        #expect(parse(["/usr/bin/python3", "python3", "-c", "import aider", "-m", "aider"]).module == nil)
        #expect(parse(["/usr/bin/python3", "python3", "-m", "fix the login bug"]).module == nil)
        #expect(parse(["/usr/bin/python3", "python3", "-m", "../evil"]).module == nil)
        #expect(parse(["/usr/bin/python3", "python3", "-m"]).module == nil)
        // Not a Python interpreter.
        #expect(parse(["/usr/local/bin/node", "node", "-m", "aider"]).module == nil)
        // argc bounds the scan: the module would be an environment string.
        #expect(parse(["/usr/bin/python3", "python3", "-m", "aider"], argc: 2).module == nil)
        // Header JSON carries it and the app decodes it into the descriptor the matcher sees.
        let invocation = HookInvocation(arguments: ["hook", "aider", "waiting"])!
        let header = HookHeader.make(invocation: invocation, timestampMilliseconds: 1, payloadSource: .none, environment: [],
                                     ancestry: [HookAncestor(pid: 9, ppid: 8, startSec: 1, startUsec: 2, exe: "Python",
                                                             argv0: "python3", tdev: -1, module: "aider")], cwd: "/x")
        let decoded = try? JSONDecoder().decode(InboxHeader.self, from: Data(header))
        #expect(decoded?.ancestry.first?.module == "aider")
        #expect(decoded?.ancestry.first?.descriptor.argv == ["python3", "-m", "aider"])
    }

    // MARK: Diagnostics log

    @Test func hookLogRotatesAtOneMegabyte() throws {
        let home = try TempHome()
        let root = home.paths.kakurenekoDirectory.path(percentEncoded: false)
        let invocation = try #require(HookInvocation(arguments: ["hook", "claude", "Stop"]))
        HookLog.write(root: root, invocation: invocation, "first")
        let log = home.paths.hookLogFile
        let first = try String(contentsOf: log, encoding: .utf8)
        #expect(first.hasSuffix("claude Stop: first\n"))
        #expect(first.contains("pid=\(getpid())"))

        // Grow the log past 1 MB: the next line starts a fresh file and the old one becomes hook.log.1.
        let handle = try FileHandle(forWritingTo: log)
        try handle.truncate(atOffset: UInt64(HookConstants.logRotateBytes))
        try handle.close()
        HookLog.write(root: root, invocation: invocation, "second")
        #expect(try String(contentsOf: log, encoding: .utf8).hasSuffix("claude Stop: second\n"))
        let rotated = log.deletingLastPathComponent().appending(path: "hook.log.1")
        #expect(try FileManager.default.attributesOfItem(atPath: rotated.path(percentEncoded: false))[.size] as? Int == HookConstants.logRotateBytes)
        var info = stat()
        #expect(stat(log.path(percentEncoded: false), &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }

    // MARK: Root and inbox resolution (pure)

    @Test func rootResolution() {
        #expect(HookFiles.root(executablePath: "/Users/x/.kakureneko/bin/kakureneko-hook", home: "/Users/y") == "/Users/x/.kakureneko")
        #expect(HookFiles.root(executablePath: "/tmp/fake/home/.kakureneko/bin/kakureneko-hook", home: "/Users/y") == "/tmp/fake/home/.kakureneko")
        #expect(HookFiles.root(executablePath: "/Applications/Kakureneko.app/Contents/Helpers/kakureneko-hook", home: "/tmp/h") == "/tmp/h/.kakureneko")
        #expect(HookFiles.root(executablePath: nil, home: "/tmp/h") == "/tmp/h/.kakureneko")
        #expect(HookFiles.root(executablePath: "/x/.kakureneko/bin/kakureneko-hook-old", home: "/tmp/h") == "/tmp/h/.kakureneko")
    }

    @Test func inboxResolution() {
        #expect(HookInbox.primaryInbox(root: "/h/.kakureneko", override: nil) == "/h/.kakureneko/inbox")
        #expect(HookInbox.primaryInbox(root: "/h/.kakureneko", override: "/tmp/inbox/") == "/tmp/inbox")
        #expect(HookInbox.fallbackInbox(override: nil, userTemp: "/var/folders/xy/T") == "/var/folders/xy/T/com.kakureneko/inbox")
        #expect(HookInbox.fallbackInbox(override: "/tmp/fb//", userTemp: "/var/folders/xy/T") == "/tmp/fb")
        #expect(HookInbox.fallbackInbox(override: nil, userTemp: nil) == nil)
        #expect(HookFiles.trimmedTrailingSlash("/") == "/")
    }
}
