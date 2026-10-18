@testable import KakurenekoProcesses
import Darwin
import KakurenekoKit
import Foundation
import Synchronization
import Testing

@Suite("KERN_PROCARGS2 parser", .timeLimit(.minutes(1)))
struct ProcArgsParserTests {
    @Test func parsesArgvAndOnlyTheAllowListedEnvironment() throws {
        let bytes = ProcArgsParser.encode(
            executablePath: "/Users/x/.local/bin/claude",
            argv: ["claude", "--resume", "fix the bug"],
            environment: [
                "PATH=/usr/bin", "ANTHROPIC_API_KEY=sk-ant-secret", "TERM_PROGRAM=Apple_Terminal",
                "__CFBundleIdentifier=com.apple.Terminal", "CLAUDE_CODE_ENTRYPOINT=cli",
                "VSCODE_ESM_ENTRYPOINT=vs/platform/agentHost/node/agentHostMain", "TERM_PROGRAM_VERSION=455",
                "CLAUDE_CODE_SESSION_ID=abc", "HOME=/Users/x",
            ])
        let parsed = try #require(ProcArgsParser.parse(bytes))
        #expect(parsed.executablePath == "/Users/x/.local/bin/claude")
        #expect(parsed.argv == ["claude", "--resume", "fix the bug"])
        #expect(parsed.environment == [
            "TERM_PROGRAM": "Apple_Terminal",
            "__CFBundleIdentifier": "com.apple.Terminal",
            "CLAUDE_CODE_ENTRYPOINT": "cli",
            "VSCODE_ESM_ENTRYPOINT": "vs/platform/agentHost/node/agentHostMain",
        ])
        #expect(Set(ProcArgsParser.environmentAllowList) == [
            "VSCODE_ESM_ENTRYPOINT", "__CFBundleIdentifier", "TERM_PROGRAM", "CLAUDE_CODE_ENTRYPOINT",
        ])
    }

    @Test func capsArgumentsCountAndBytes() throws {
        let many = (0..<100).map { "arg\($0)" }
        let parsed = try #require(ProcArgsParser.parse(ProcArgsParser.encode(executablePath: "/bin/x", argv: many, environment: ["TERM_PROGRAM=x"])))
        #expect(parsed.argv.count == ProcArgsParser.maxArguments)
        #expect(parsed.environment == ["TERM_PROGRAM": "x"]) // still found after the skipped argv entries

        let huge = [String(repeating: "a", count: 3000), String(repeating: "b", count: 3000), "c"]
        let capped = try #require(ProcArgsParser.parse(ProcArgsParser.encode(executablePath: "/bin/x", argv: huge, environment: [])))
        #expect(capped.argv.reduce(0) { $0 + $1.utf8.count } <= ProcArgsParser.maxArgumentBytes)
        #expect(capped.argv.first?.count == 3000)
    }

    @Test func capsEnvironmentValues() throws {
        let value = String(repeating: "v", count: 5000)
        let parsed = try #require(ProcArgsParser.parse(ProcArgsParser.encode(executablePath: "/bin/x", argv: ["x"], environment: ["TERM_PROGRAM=" + value])))
        #expect(parsed.environment["TERM_PROGRAM"]?.utf8.count == ProcArgsParser.maxEnvironmentValueBytes)
    }

    @Test func prefixOfAnAllowListedNameIsNotAMatch() throws {
        let parsed = try #require(ProcArgsParser.parse(ProcArgsParser.encode(
            executablePath: "/bin/x", argv: ["x"], environment: ["TERM_PROGRAMX=1", "TERM_PROGRAM_VERSION=2", "TERM=xterm"])))
        #expect(parsed.environment.isEmpty)
    }

    @Test func truncatedAndCorruptBuffers() throws {
        #expect(ProcArgsParser.parse([UInt8]()) == nil)
        #expect(ProcArgsParser.parse([1, 0]) == nil)
        var negative = [UInt8](repeating: 0, count: 8)
        negative[3] = 0x80 // argc < 0
        #expect(ProcArgsParser.parse(negative) == nil)
        var absurd = [UInt8](repeating: 0, count: 8)
        absurd[3] = 0x7F // argc ≈ 2^30
        #expect(ProcArgsParser.parse(absurd) == nil)

        // A buffer cut in the middle of argv keeps what it has (argv comes first).
        let full = ProcArgsParser.encode(executablePath: "/bin/sleep", argv: ["sleep", "100"], environment: ["TERM_PROGRAM=x"])
        let cut = Array(full.prefix(4 + "/bin/sleep".utf8.count + 1 + 3 + "sleep".utf8.count + 2))
        let parsed = try #require(ProcArgsParser.parse(cut))
        #expect(parsed.argv.first == "sleep")
        #expect(parsed.environment.isEmpty)
    }

    @Test func emptyExecPathAndNoArguments() throws {
        let parsed = try #require(ProcArgsParser.parse(ProcArgsParser.encode(executablePath: "", argv: [], environment: [])))
        #expect(parsed.executablePath == nil)
        #expect(parsed.argv.isEmpty)
    }
}

@Suite("Process table", .timeLimit(.minutes(1)))
struct ProcessTableTests {
    private func row(_ pid: Int32, _ ppid: Int32, uid: UInt32 = FakeProbe.me, status: UInt32 = 2) -> ProcessRow {
        ProcessRow(pid: pid, ppid: ppid, uid: uid, status: status,
                   identity: uid == FakeProbe.me ? ProcessIdentity(pid: pid, startSec: Int64(pid), startUsec: 0) : nil)
    }

    @Test func descendantsAndAncestors() {
        let table = ProcessTable(currentUID: FakeProbe.me, rows: [
            row(10, 1), row(11, 10), row(12, 11), row(13, 11), row(14, 10, uid: 0), row(15, 14), row(20, 1),
        ])
        #expect(table.descendants(of: 10) == [11, 12, 13, 14, 15])
        #expect(table.descendants(of: 20).isEmpty)
        #expect(table.ancestors(of: 15) == [14, 10])
        #expect(table.ancestors(of: 10).isEmpty) // launchd excluded
        #expect(table.sameUIDRows.map(\.pid).sorted() == [10, 11, 12, 13, 15, 20])
        #expect(table.contains(ProcessIdentity(pid: 12, startSec: 12, startUsec: 0)))
        #expect(!table.contains(ProcessIdentity(pid: 12, startSec: 99, startUsec: 0)))
    }

    @Test func zombiesAreNotChildren() {
        let table = ProcessTable(currentUID: FakeProbe.me, rows: [row(10, 1), row(11, 10, status: LibProc.zombieStatus)])
        #expect(table.descendants(of: 10).isEmpty)
        #expect(table.sameUIDRows.map(\.pid) == [10])
    }

    @Test func cyclesTerminate() {
        let table = ProcessTable(currentUID: FakeProbe.me, rows: [row(10, 11), row(11, 10), row(12, 12)])
        #expect(table.ancestors(of: 10) == [11])
        #expect(table.descendants(of: 10) == [11])
        #expect(table.descendants(of: 12).isEmpty)
    }
}

@Suite("App bundles and host app", .timeLimit(.minutes(1)))
struct AppBundleTests {
    @Test func bundlePaths() {
        let plugin = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        #expect(AppBundlePaths.outermostBundle(containing: plugin) == "/Applications/Visual Studio Code.app")
        #expect(AppBundlePaths.bundle(ofMainExecutable: plugin) == "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app")
        #expect(!AppBundlePaths.isAppMainExecutable(plugin))
        #expect(AppBundlePaths.isAppMainExecutable("/Applications/Safari.app/Contents/MacOS/Safari"))
        #expect(!AppBundlePaths.isAppMainExecutable("/Applications/Xcode.app/Contents/Developer/usr/bin/git"))
        #expect(AppBundlePaths.isInsideAppBundle("/Applications/Xcode.app/Contents/Developer/usr/bin/git"))
        #expect(!AppBundlePaths.isInsideAppBundle("/usr/bin/git"))
        #expect(AppBundlePaths.bundle(ofMainExecutable: "relative/X.app/Contents/MacOS/X") == nil)
    }

    @Test func bundleIdentifierCacheReadsOncePerBundle() {
        let reads = Mutex(0)
        let cache = BundleIdentifierCache(reader: { path in
            reads.withLock { $0 += 1 }
            return path == "/A.app" ? "com.a" : nil
        })
        #expect(cache.bundleIdentifier(ofBundle: "/A.app") == "com.a")
        #expect(cache.bundleIdentifier(ofBundle: "/A.app") == "com.a")
        #expect(cache.bundleIdentifier(ofBundle: "/B.app") == nil)
        #expect(cache.bundleIdentifier(ofBundle: "/B.app") == nil) // negative results are cached too
        #expect(reads.withLock { $0 } == 2)
    }

    @Test func infoPlistReaderOnATempBundle() throws {
        let temp = try TempHome()
        let bundle = temp.paths.home.appending(path: "Fake.app")
        try FileManager.default.createDirectory(at: bundle.appending(path: "Contents"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.kakureneko.test.fake"], format: .xml, options: 0)
        try plist.write(to: bundle.appending(path: "Contents/Info.plist"))
        #expect(BundleIdentifierCache.readInfoPlist(bundle.path(percentEncoded: false)) == "com.kakureneko.test.fake")
        #expect(BundleIdentifierCache.readInfoPlist(temp.paths.home.appending(path: "Missing.app").path(percentEncoded: false)) == nil)
    }

    @Test func hostFromEnvironmentFirst() {
        let bundles = BundleIdentifierCache(reader: { _ in "com.googlecode.iterm2" })
        let ancestors = [
            AncestorInfo(identity: ProcessIdentity(pid: 2, startSec: 1, startUsec: 0), executablePath: "/bin/zsh"),
            AncestorInfo(identity: ProcessIdentity(pid: 1, startSec: 1, startUsec: 0),
                         executablePath: "/Applications/iTerm.app/Contents/MacOS/iTerm2", bundleID: "com.googlecode.iterm2", isApp: true),
        ]
        let fromTerm = HostAppResolver.host(environment: ["TERM_PROGRAM": "iTerm.app"], ancestors: ancestors, bundles: bundles)
        #expect(fromTerm == HostApp(bundleID: "com.googlecode.iterm2", name: "iTerm2", pid: 1))
        // tmux: known TERM_PROGRAM without a bundle → no pid.
        let tmux = HostAppResolver.host(environment: ["TERM_PROGRAM": "tmux"], ancestors: ancestors, bundles: bundles)
        #expect(tmux == HostApp(bundleID: nil, name: "tmux"))
        // No environment: the bundle ancestor.
        let fromAncestry = HostAppResolver.host(environment: [:], ancestors: ancestors, bundles: bundles)
        #expect(fromAncestry == HostApp(bundleID: "com.googlecode.iterm2", name: "iTerm2", pid: 1))
        #expect(HostAppResolver.host(environment: [:], ancestors: [ancestors[0]], bundles: bundles) == nil)
    }
}

/// Test helper: a literal address that must parse.
func ip(_ literal: String) -> IPAddress { IPAddress(literal)! }

@Suite("Model endpoints (E4)", .timeLimit(.minutes(1)))
struct ModelEndpointTests {
    @Test func addresses() throws {
        #expect(IPAddress("127.0.0.1") == .v4(0x7F00_0001))
        #expect(ip("127.1.2.3").isLoopback)
        #expect(ip("::1").isLoopback)
        #expect(ip("::").isUnspecified)
        #expect(ip("0.0.0.0").isUnspecified)
        #expect(IPAddress("::ffff:160.79.104.1") == IPAddress("160.79.104.1")) // v4-mapped normalises to v4
        #expect(IPAddress("not an ip") == nil)
        #expect(IPAddress("2607:6bc0::10")?.description == "2607:6bc0::10")
        #expect(IPAddress("10.1.2.3")?.description == "10.1.2.3")
    }

    @Test func cidrMembership() throws {
        let anthropic = try #require(CIDRBlock("160.79.104.0/23"))
        #expect(anthropic.contains(ip("160.79.104.0")))
        #expect(anthropic.contains(ip("160.79.105.255")))
        #expect(!anthropic.contains(ip("160.79.106.0")))
        #expect(!anthropic.contains(ip("2607:6bc0::1")))
        let v6 = try #require(CIDRBlock("2607:6bc0::/48"))
        #expect(v6.contains(ip("2607:6bc0:0:ffff::1")))
        #expect(!v6.contains(ip("2607:6bc0:1::1")))
        #expect(CIDRBlock("1.2.3.4/33") == nil)
        #expect(CIDRBlock("1.2.3.4") == nil)
        #expect(try #require(CIDRBlock("0.0.0.0/0")).contains(ip("8.8.8.8")))
        #expect(try #require(CIDRBlock("::/0")).contains(ip("2001:db8::1")))
        #expect(try #require(CIDRBlock("2001:db8::/128")).contains(ip("2001:db8::")))
    }

    @Test func endpointSetCombinesStaticRangesAndResolvedAddresses() throws {
        var set = ModelEndpointSet()
        #expect(set.contains(ip("160.79.104.77")))
        #expect(set.contains(ip("2607:6bc0::5")))
        #expect(!set.contains(ip("162.159.140.245")))
        set.resolved = [ip("162.159.140.245")]
        #expect(set.contains(ip("162.159.140.245")))
    }

    @Test func registryResolvesAtStartAndEveryTenMinutes() async throws {
        let clock = TestClock()
        let calls = Mutex<[String]>([])
        let registry = ModelEndpointRegistry(
            resolver: { host in
                calls.withLock { $0.append(host) }
                return host == "api.openai.com" ? [ip("162.159.140.245")] : []
            },
            clock: clock, logger: KakurenekoLogger(.processes))
        registry.start()
        registry.start() // idempotent
        #expect(await clock.waitForSleepers(1))
        #expect(registry.refreshCount == 1)
        #expect(calls.withLock { $0.count } == ModelEndpointRegistry.hosts.count)
        #expect(registry.current.contains(ip("162.159.140.245")))

        clock.advance(by: .seconds(599))
        await Task.yield()
        #expect(registry.refreshCount == 1)
        clock.advance(by: .seconds(1))
        #expect(await clock.waitForSleepers(1)) // refreshed, then asleep again
        #expect(registry.refreshCount == 2)
        registry.stop()
        #expect(ModelEndpointRegistry.hosts.contains("api.anthropic.com"))
        #expect(ModelEndpointRegistry.hosts.contains("api.openai.com"))
        #expect(ModelEndpointRegistry.hosts.contains("api2.cursor.sh"))
    }

    @Test func failedResolutionKeepsPreviousAddresses() async throws {
        let answer = Mutex<[IPAddress]>([ip("1.2.3.4")])
        let registry = ModelEndpointRegistry(
            resolver: { host in host == "api.anthropic.com" ? answer.withLock { $0 } : [] },
            clock: TestClock(), logger: KakurenekoLogger(.processes))
        await registry.refresh()
        answer.withLock { $0 = [] }
        await registry.refresh()
        #expect(registry.current.contains(ip("1.2.3.4")))
        #expect(registry.refreshCount == 2)
    }
}

@Suite("Session-store write log (E3)", .timeLimit(.minutes(1)))
struct SessionStoreWriteLogTests {
    private let identity = ProcessIdentity(pid: 42, startSec: 1, startUsec: 2)
    private let other = ProcessIdentity(pid: 43, startSec: 1, startUsec: 2)
    private let t = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func pathMatching() {
        #expect(SessionStoreWriteLog.matches(eventPath: "/a/b/s.jsonl", hint: "/a/b/s.jsonl", recursive: false))
        #expect(SessionStoreWriteLog.matches(eventPath: "/a/b/s/sub/agent.jsonl", hint: "/a/b/s", recursive: false))
        #expect(!SessionStoreWriteLog.matches(eventPath: "/a/b/s2.jsonl", hint: "/a/b/s", recursive: false))
        #expect(!SessionStoreWriteLog.matches(eventPath: "/a/b", hint: "/a/b/s.jsonl", recursive: false))
        #expect(SessionStoreWriteLog.matches(eventPath: "/a/b/", hint: "/a/b/s.jsonl", recursive: true)) // rescan subtree
    }

    @Test func recordsWritesPerIdentity() {
        let log = SessionStoreWriteLog()
        log.setHints([
            SessionStoreHint(identity: identity, paths: ["/x/proj/abc.jsonl", "/x/proj/abc/"]),
            SessionStoreHint(identity: other, paths: ["/x/proj/def.jsonl"]),
        ])
        log.record(paths: [("/x/proj/abc/subagents/1.jsonl", false)], at: t)
        #expect(log.lastWrite(for: identity) == t)
        #expect(log.lastWrite(for: other) == nil)
        // Older event timestamps never move the last write backwards.
        log.record(paths: [("/x/proj/abc.jsonl", false)], at: t.addingTimeInterval(-5))
        #expect(log.lastWrite(for: identity) == t)
        // Dropping a hint forgets its writes.
        log.setHints([SessionStoreHint(identity: other, paths: ["/x/proj/def.jsonl"])])
        #expect(log.lastWrite(for: identity) == nil)
        #expect(log.hintedPaths == ["/x/proj/def.jsonl"])
    }

    @Test func relativeHintsAreIgnoredAndSymlinkedPrefixesResolve() {
        #expect(SessionStoreWriteLog.forms(of: "relative/path").isEmpty)
        // /tmp is a symlink to /private/tmp on macOS: FSEvents reports the resolved path.
        let forms = SessionStoreWriteLog.forms(of: "/tmp/kakureneko-nonexistent-\(UUID().uuidString)/s.jsonl")
        #expect(forms.count == 2)
        #expect(forms[1].hasPrefix("/private/tmp/"))
    }

    @Test func watchRootsAreNearestExistingDirectoriesCollapsed() throws {
        let temp = try TempHome()
        let home = temp.paths.home
        let project = home.appending(path: ".claude/projects/-Users-x-proj")
        try FileManager.default.createDirectory(at: project.appending(path: "abc"), withIntermediateDirectories: true)
        let homePath = home.path(percentEncoded: false)
        let projectPath = SessionStoreWriteLog.trimmed(project.path(percentEncoded: false))
        let roots = SessionStoreWriteLog.watchRoots(for: [
            projectPath + "/abc.jsonl", // file not created yet → its directory
            projectPath + "/abc", // existing directory → itself, collapsed into the project dir
            homePath + "/nonexistent.jsonl", // would be the bare home → skipped
        ], home: homePath)
        #expect(roots == [SessionStoreWriteLog.realPath(projectPath) ?? projectPath]) // resolved (`/private/var/…`)
        // Both forms of the same hint (as given + resolved) collapse into one root.
        let forms = SessionStoreWriteLog.forms(of: projectPath + "/abc.jsonl")
        #expect(SessionStoreWriteLog.watchRoots(for: forms, home: homePath).count == 1)
    }
}

@Suite("Default browser cache", .timeLimit(.minutes(1)))
struct DefaultBrowserTests {
    @Test func lookupIsCached() {
        let calls = Mutex(0)
        let resolver = DefaultBrowserResolver(lookup: {
            calls.withLock { $0 += 1 }
            return "com.apple.Safari"
        })
        #expect(resolver.bundleID() == "com.apple.Safari")
        #expect(resolver.bundleID() == "com.apple.Safari")
        #expect(calls.withLock { $0 } == 1)
    }
}
