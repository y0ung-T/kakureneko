@testable import KakurenekoProcesses
import Darwin
import KakurenekoKit
import Foundation
import Testing

private let now0 = Date(timeIntervalSince1970: 1_800_000_000)
private let me = FakeProbe.me

private func row(_ pid: Int32, _ ppid: Int32, uid: UInt32 = me, comm: String = "", tdev: Int32? = nil, start: Int64? = nil) -> ProcessRow {
    ProcessRow(
        pid: pid, ppid: ppid, uid: uid, comm: comm,
        identity: uid == me ? ProcessIdentity(pid: pid, startSec: start ?? (1_700_000_000 + Int64(pid)), startUsec: 0) : nil,
        tdev: tdev)
}

private func ident(_ pid: Int32) -> ProcessIdentity { ProcessIdentity(pid: pid, startSec: 1_700_000_000 + Int64(pid), startUsec: 0) }

private let ttys004: Int32 = 0x1000_0004
private let ttys006: Int32 = 0x1000_0006
private func ptmx(_ minor: UInt32) -> FDEntry { .ptyMaster(minor: minor) }

private let builder = TopologyBuilder(
    bundleIdentifier: { path in
        ["/Applications/Safari.app": "com.apple.Safari", "/Applications/Arc.app": "company.thebrowser.Browser"][path]
    },
    defaultBrowserBundleID: { "company.thebrowser.Browser" }
)

/// Terminal(500) → login(501, root) → zsh(502) → claude(503) → { uv(505) → python(506), node(539) → Chromium(540),
/// git(541), dev server(507) }, plus a `claude bg-pty-host`(530, agent infrastructure) owning another pty, and outsiders.
private func baseTable(extra: [ProcessRow] = []) -> ProcessTable {
    ProcessTable(currentUID: me, rows: [
        row(500, 1, comm: "Terminal"),
        row(501, 500, uid: 0, comm: "login"),
        row(502, 501, comm: "zsh", tdev: ttys004),
        row(503, 502, comm: "2.1.296", tdev: ttys004),
        row(505, 503, comm: "uv", tdev: ttys004),
        row(506, 505, comm: "python3.14", tdev: ttys004),
        row(507, 503, comm: "node", tdev: ttys004),
        row(539, 503, comm: "node", tdev: ttys004),
        row(540, 539, comm: "Chromium"),
        row(541, 503, comm: "git", tdev: ttys004),
        row(530, 1, comm: "2.1.296"),
        row(531, 530, comm: "zsh", tdev: ttys006),
        row(520, 1, comm: "iTermServer-3.6"),
        row(600, 1, comm: "Claude"),
        row(610, 1, comm: "2.1.296"),
        row(620, 1, comm: "Google Chrome"),
        row(630, 1, comm: "ollama"),
        row(631, 1, comm: "postgres"),
        row(640, 1, comm: "Arc"),
        row(650, 1, comm: "Safari"),
        row(660, 1, comm: "client"),
        row(670, 1, comm: "Spotify"),
    ] + extra)
}

@Suite("Topology builder (pure)", .timeLimit(.minutes(1)))
struct TopologyBuilderTests {
    private func input(_ table: ProcessTable = baseTable(), fds: [Int32: [FDEntry]] = [:], paths: [Int32: String] = [:],
                       arguments: [Int32: [String]] = [:], agents: [ProcessIdentity] = [ident(503), ident(530)], complete: Bool = true)
        -> TopologyInput
    {
        TopologyInput(
            builtAt: now0, table: table, agents: agents, executablePaths: paths, arguments: arguments,
            fileDescriptors: fds, probesComplete: complete)
    }

    @Test func treeTTYsAndPtyMasterHoldersByMinor() {
        let topology = builder.build(input(fds: [
            500: [ptmx(4), ptmx(9)], // Terminal holds the agent's pty (and an unrelated one)
            520: [ptmx(7)], // iTermServer with someone else's pty
            530: [ptmx(6)], // claude bg-pty-host holds the pty of its own shell
            600: [ptmx(5)],
        ]))
        #expect(topology.ttyDevices == [ttys004, ttys006])
        #expect(topology.ptyMasterHolderPIDs == [500, 530])
        #expect(deviceMinor(UInt32(bitPattern: ttys004)) == 4)
        #expect(deviceMinor(0x0F00_0004) == 4) // /dev/ptmx master rdev (R06 §3.2: 0x0f0000NN)
        #expect(deviceMinor(0x1000_0009) == 9) // /dev/ttys009 slave rdev (0x100000NN)
    }

    @Test func agentsDescendantsAndAncestors() {
        let topology = builder.build(input())
        #expect(topology.builtAt == now0)
        #expect(topology.agentIdentities == [ident(503), ident(530)])
        #expect(Set(topology.descendantIdentities.map(\.pid)) == [505, 506, 507, 539, 540, 541, 531])
        #expect(topology.ancestorPIDs == [502, 501, 500])
        #expect(topology.sessionHostPIDs.isEmpty) // the coordinator fills it
        #expect(topology.isComplete)
        #expect(topology.directlyProtectedPIDs.isSuperset(of: [500, 501, 502, 503, 505, 506, 530, 531, 540]))
        #expect(!topology.directlyProtectedPIDs.contains(520))
    }

    @Test func exitedOrReusedAgentsAreDropped() {
        // 503 was reused by another process (different start time); 999 is gone.
        let table = ProcessTable(currentUID: me, rows: [row(503, 1, comm: "zsh", start: 1_750_000_000), row(504, 503)])
        let topology = builder.build(input(table, agents: [ident(503), ident(999)]))
        #expect(topology.agentIdentities.isEmpty)
        #expect(topology.descendantIdentities.isEmpty)
        #expect(topology.ancestorPIDs.isEmpty)
    }

    @Test func agentLaunchedAppsAreAppExecutablesInAgentTrees() {
        let topology = builder.build(input(paths: [
            540: "/Users/tester/Library/Caches/ms-playwright/chromium-1140/chrome-mac/Chromium.app/Contents/MacOS/Chromium",
            541: "/Applications/Xcode.app/Contents/Developer/usr/bin/git", // a toolchain CLI inside a bundle: not an app
            539: "/opt/homebrew/bin/node",
            503: "/Applications/ClaudeCode.app/Contents/MacOS/claude", // the agent itself is not "launched by an agent"
            620: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", // the user's own Chrome: no agent ancestor
        ]))
        #expect(topology.agentLaunchedAppPIDs == [540])
    }

    @Test func unixSocketPeersPairConnAndSo() {
        let topology = builder.build(input(fds: [
            505: [Fixtures.unix(0xA, peer: 0xB)],
            600: [Fixtures.unix(0xB, peer: 0xA)], // Claude Desktop on the other end
            506: [Fixtures.unix(0xC, peer: 0xD)],
            503: [Fixtures.unix(0xD, peer: 0xC)], // tree-internal pair: not a peer
        ]))
        #expect(topology.ipcPeers == [IPCPeerHint(peerPID: 600, kind: .unixSocket, agentSidePID: 505)])
    }

    @Test func unixPathListenerOwnersAreReported() {
        let path = "/tmp/cc-daemon-501/abc/control.sock"
        let topology = builder.build(input(fds: [
            503: [Fixtures.unix(0x10, peer: 0, peerPath: path)], // connecting, not yet accepted
            610: [Fixtures.unix(0x20, path: path, listening: true)],
        ]))
        #expect(topology.ipcPeers == [IPCPeerHint(peerPID: 610, kind: .listener, agentSidePID: 503, detail: path)])
    }

    @Test func loopbackTCPPairsAndListeners() {
        let topology = builder.build(input(fds: [
            // CDP: agent tree ↔ Chrome accepted socket (paired by ports).
            506: [Fixtures.tcp(local: "127.0.0.1", 50000, remote: "127.0.0.1", 9222),
                  // Ollama: connect into a listener with no accepted socket visible (e.g. frozen app).
                  Fixtures.tcp(local: "127.0.0.1", 50001, remote: "127.0.0.1", 11434, state: TSI_S_SYN_SENT),
                  // Postgres on ::1 listener via IPv6 loopback.
                  Fixtures.tcp(local: "::1", 50002, remote: "::1", 5432),
                  // Model API: not loopback.
                  Fixtures.tcp(local: "192.168.1.5", 50003, remote: "160.79.104.10", 443)],
            620: [Fixtures.tcp(local: "127.0.0.1", 9222, remote: "127.0.0.1", 50000), Fixtures.listener("127.0.0.1", 9222)],
            630: [Fixtures.listener("0.0.0.0", 11434)],
            631: [Fixtures.listener("::", 5432)],
            670: [Fixtures.listener("192.168.1.5", 11434)], // bound to a LAN address only: not reachable via loopback
        ]))
        #expect(topology.ipcPeers == [
            IPCPeerHint(peerPID: 620, kind: .loopbackTCP, agentSidePID: 506, detail: "127.0.0.1:9222"),
            IPCPeerHint(peerPID: 630, kind: .listener, agentSidePID: 506, detail: "127.0.0.1:11434"),
            IPCPeerHint(peerPID: 631, kind: .listener, agentSidePID: 506, detail: "::1:5432"),
        ])
    }

    @Test func pipePeersPairHandles() {
        let topology = builder.build(input(fds: [
            540: [.pipe(handle: 0x100, peer: 0x200)], // --remote-debugging-pipe
            640: [.pipe(handle: 0x200, peer: 0x100)],
            541: [.pipe(handle: 0x300, peer: 0x400)],
            539: [.pipe(handle: 0x400, peer: 0x300)], // internal
        ]))
        #expect(topology.ipcPeers == [IPCPeerHint(peerPID: 640, kind: .pipe, agentSidePID: 540)])
    }

    @Test func outsidersConnectedToAgentTreeListeners() {
        let topology = builder.build(input(fds: [
            507: [Fixtures.listener("127.0.0.1", 3000), Fixtures.unix(0x50, path: "/tmp/agent.sock", listening: true)],
            650: [Fixtures.tcp(local: "127.0.0.1", 51000, remote: "127.0.0.1", 3000)], // a browser on the dev server
            660: [Fixtures.unix(0x60, peer: 0, peerPath: "/tmp/agent.sock")],
        ]))
        #expect(topology.ipcPeers == [
            IPCPeerHint(peerPID: 650, kind: .loopbackTCP, agentSidePID: 507, detail: "127.0.0.1:3000"),
            IPCPeerHint(peerPID: 660, kind: .unixSocket, agentSidePID: 507, detail: "/tmp/agent.sock"),
        ])
    }

    @Test func automationHelpersAndTargets() throws {
        let table = baseTable(extra: [
            row(701, 503, comm: "osascript"), row(702, 503, comm: "simctl"), row(703, 503, comm: "mcpbridge"),
            row(704, 503, comm: "open"), row(705, 503, comm: "open"), row(706, 503, comm: "shortcuts"),
            row(707, 503, comm: "osascript"), row(708, 503, comm: "xcodebuild"), row(709, 503, comm: "open"),
            row(800, 1, comm: "osascript"), // not in an agent tree
        ])
        let topology = builder.build(input(table, paths: [
            701: "/usr/bin/osascript", 702: "/Applications/Xcode.app/Contents/Developer/usr/bin/simctl",
            703: "/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge", 704: "/usr/bin/open", 705: "/usr/bin/open",
            706: "/usr/bin/shortcuts", 707: "/usr/bin/osascript", 708: "/usr/bin/xcodebuild", 709: "/usr/bin/open",
            800: "/usr/bin/osascript",
        ], arguments: [
            701: ["osascript", "-e", "tell application \"Music\" to play"],
            702: ["simctl", "boot", "iPhone 17"],
            703: ["mcpbridge"],
            704: ["open", "https://localhost:3000/"],
            705: ["open", "-a", "Safari", "index.html"],
            706: ["shortcuts", "run", "Lights"],
            707: ["osascript", "-e", "tell application \"System Events\" to keystroke \"a\""],
            708: ["xcodebuild", "-scheme", "App", "test"],
            709: ["open", "notes.txt"],
        ]))
        let byPID = Dictionary(uniqueKeysWithValues: topology.automationHelpers.map { ($0.helper.pid, $0) })
        #expect(Set(byPID.keys) == [701, 702, 703, 704, 705, 706, 707, 708, 709])
        #expect(byPID[701]?.likelyTargetBundleIDs == ["com.apple.Music"])
        #expect(byPID[702]?.tool == "simctl")
        #expect(byPID[702]?.likelyTargetBundleIDs == ["com.apple.iphonesimulator"])
        #expect(byPID[703]?.likelyTargetBundleIDs == ["com.apple.dt.Xcode"])
        #expect(byPID[704]?.likelyTargetBundleIDs == ["company.thebrowser.Browser"]) // default browser
        #expect(byPID[705]?.likelyTargetBundleIDs == ["com.apple.Safari"])
        #expect(byPID[706]?.likelyTargetBundleIDs == []) // unknown → thaw everything
        #expect(byPID[707]?.likelyTargetBundleIDs == [])
        #expect(byPID[708]?.likelyTargetBundleIDs == ["com.apple.dt.Xcode"])
        #expect(byPID[709]?.likelyTargetBundleIDs == [])
        #expect(byPID[701]?.helper == ProcessIdentity(pid: 701, startSec: 1_700_000_701, startUsec: 0))
    }

    @Test func incompleteProbesPropagate() {
        #expect(!builder.build(input(complete: false)).isComplete)
    }

    @Test func fallbackUsesTheSnapshotAndIsIncomplete() {
        let agent = AgentProcess(
            identity: ident(503), agent: .claude, argv0: "claude", ttyDevice: ttys004, ppid: 502,
            ancestors: [AncestorInfo(identity: ident(502)), AncestorInfo(identity: ProcessIdentity(pid: 501, startSec: 1, startUsec: 0))],
            descendants: [ident(505)], evidence: .none(at: now0), firstSeen: now0)
        let topology = TopologyBuilder.fallback(snapshot: ProcessSnapshot(takenAt: now0, agents: [agent]), now: now0)
        #expect(!topology.isComplete)
        #expect(topology.agentIdentities == [ident(503)])
        #expect(topology.descendantIdentities == [ident(505)])
        #expect(topology.ttyDevices == [ttys004])
        #expect(topology.ancestorPIDs == [502, 501])
    }
}

@Suite("Automation helper targets", .timeLimit(.minutes(1)))
struct AutomationHelperTargetTests {
    private let bundles: (String) -> String? = { ["/Applications/Arc.app": "company.thebrowser.Browser"][$0] }

    @Test func toolResolution() {
        #expect(AutomationHelperTargets.tool(executablePath: "/usr/bin/xcrun", argv: ["xcrun", "simctl", "list"], comm: "xcrun")?.tool == "simctl")
        #expect(AutomationHelperTargets.tool(executablePath: "/usr/bin/xcrun", argv: ["xcrun", "--sdk", "iphoneos", "simctl", "boot"], comm: "xcrun")?.arguments == ["boot"])
        #expect(AutomationHelperTargets.tool(executablePath: "/usr/bin/xcrun", argv: ["xcrun", "clang"], comm: "xcrun") == nil)
        #expect(AutomationHelperTargets.tool(executablePath: nil, argv: [], comm: "osascript")?.tool == "osascript")
        #expect(AutomationHelperTargets.tool(executablePath: "/bin/zsh", argv: ["zsh", "-c", "open x"], comm: "zsh") == nil)
    }

    @Test func openTargets() {
        func targets(_ arguments: [String]) -> [String] {
            AutomationHelperTargets.openTargets(arguments, bundleIdentifier: bundles, defaultBrowser: { "default.browser" })
        }
        #expect(targets(["-b", "com.apple.dt.Xcode", "x.xcodeproj"]) == ["com.apple.dt.Xcode"])
        #expect(targets(["-a", "/Applications/Arc.app", "https://x"]) == ["company.thebrowser.Browser"])
        #expect(targets(["-a", "Google Chrome"]) == ["com.google.Chrome"])
        #expect(targets(["-a", "Some Unknown App"]) == [])
        #expect(targets(["-e", "notes.txt"]) == ["com.apple.TextEdit"])
        #expect(targets(["-R", "/tmp"]) == ["com.apple.finder"])
        #expect(targets(["https://a", "http://b"]) == ["default.browser"])
        #expect(targets(["https://a", "file.txt"]) == [])
        #expect(targets(["-t", "file.txt"]) == [])
        #expect(targets([]) == [])
        #expect(targets(["-u", "https://example.com"]) == ["default.browser"])
        #expect(targets(["-a", "Safari", "--args", "-a", "Xcode"]) == ["com.apple.Safari"])
    }

    @Test func osascriptTargets() {
        func targets(_ arguments: [String]) -> [String] { AutomationHelperTargets.osascriptTargets(arguments, bundleIdentifier: bundles) }
        #expect(targets(["-e", "tell application \"Safari\" to activate"]) == ["com.apple.Safari"])
        #expect(targets(["-e", "tell application id \"com.example.app\" to quit"]) == ["com.example.app"])
        #expect(targets(["-l", "JavaScript", "-e", "Application('Xcode').activate()"]) == ["com.apple.dt.Xcode"])
        #expect(targets(["-e", "tell app \"Finder\"", "-e", "tell application \"Notes\""]) == ["com.apple.finder", "com.apple.Notes"])
        #expect(targets(["-e", "tell application \"System Events\" to key code 1"]) == [])
        #expect(targets(["-e", "display dialog \"hi\""]) == []) // no application: unknown
        #expect(targets(["script.scpt"]) == [])
        #expect(targets(["-"]) == [])
        #expect(targets(["-e", "tell application \"Mystery\""]) == [])
        #expect(targets(["-e", "set happy to 1"]) == [])
    }

    @Test func applicationReferenceParsing() {
        let refs = AutomationHelperTargets.applicationReferences(in: "tell application \"Music\"\nApplication('Mail')\napp \"Notes\"\nmyapp \"x\"")
        #expect(refs == [.name("Music"), .name("Mail"), .name("Notes")])
    }

    @Test func helperTargetsFromTheToolName() {
        let none: () -> String? = { nil }
        #expect(AutomationHelperTargets.targets(tool: "mcpbridge", arguments: [], bundleIdentifier: bundles, defaultBrowser: none) == ["com.apple.dt.Xcode"])
        #expect(AutomationHelperTargets.targets(tool: "xcodebuild", arguments: [], bundleIdentifier: bundles, defaultBrowser: none) == ["com.apple.dt.Xcode"])
        #expect(AutomationHelperTargets.targets(tool: "simctl", arguments: [], bundleIdentifier: bundles, defaultBrowser: none) == ["com.apple.iphonesimulator"])
        #expect(AutomationHelperTargets.targets(tool: "shortcuts", arguments: ["run", "x"], bundleIdentifier: bundles, defaultBrowser: none) == [])
        // `open <url>` with no known default browser → unknown.
        #expect(AutomationHelperTargets.targets(tool: "open", arguments: ["https://x"], bundleIdentifier: bundles, defaultBrowser: none) == [])
    }
}

@Suite("Topology collector (synthetic system)", .timeLimit(.minutes(1)))
struct TopologyCollectorTests {
    private func fixture() -> (FakeProbe, ProcessSnapshot) {
        let probe = FakeProbe()
        probe.add(pid: 500, ppid: 1, comm: "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
        probe.add(pid: 501, ppid: 500, uid: FakeProbe.root, comm: "login", path: "/usr/bin/login")
        probe.add(pid: 502, ppid: 501, comm: "zsh", path: "/bin/zsh", argv: ["-zsh"], tdev: ttys004)
        let claude = probe.add(pid: 503, ppid: 502, comm: "2.1.296", path: "\(Fixtures.home)/.local/share/claude/versions/2.1.296",
                               argv: ["claude"], tdev: ttys004)
        probe.add(pid: 504, ppid: 503, comm: "osascript", path: "/usr/bin/osascript",
                  argv: ["osascript", "-e", "tell application \"Xcode\" to build"], tdev: ttys004)
        probe.add(pid: 505, ppid: 503, uid: FakeProbe.root, comm: "sudo", path: "/usr/bin/sudo") // other user's tree member
        probe.add(pid: 600, ppid: 1, comm: "Claude", path: "/Applications/Claude.app/Contents/MacOS/Claude")
        probe.setFDs(500, [ptmx(4)])
        probe.setFDs(503, [Fixtures.unix(0xA, peer: 0xB)])
        probe.setFDs(600, [Fixtures.unix(0xB, peer: 0xA)])
        let agent = AgentProcess(identity: claude, agent: .claude, argv0: "claude", evidence: .none(at: now0), firstSeen: now0)
        return (probe, ProcessSnapshot(takenAt: now0, agents: [agent]))
    }

    @Test func collectsFromEverySameUIDProcessAndOtherUsersTreeMembers() throws {
        let (probe, snapshot) = fixture()
        let input = try #require(TopologyCollector().collect(snapshot: snapshot, now: now0, probe: probe, cachedDescriptors: { _ in [:] }))
        #expect(Set(probe.fdReads) == [500, 502, 503, 504, 600, 505]) // root `login` outside the tree is skipped
        #expect(input.probesComplete)
        #expect(input.extraIdentities[505] == probe.identity(of: 505))
        #expect(input.arguments.keys.sorted() == [504]) // argv only for helper candidates
        let topology = builder.build(input)
        #expect(topology.ptyMasterHolderPIDs == [500])
        #expect(topology.ipcPeers == [IPCPeerHint(peerPID: 600, kind: .unixSocket, agentSidePID: 503)])
        #expect(topology.automationHelpers.map(\.likelyTargetBundleIDs) == [["com.apple.dt.Xcode"]])
        #expect(topology.descendantIdentities.contains { $0.pid == 505 })
        #expect(topology.ancestorPIDs == [502, 501, 500])
    }

    @Test func cachedDescriptorsAvoidRereads() throws {
        let (probe, snapshot) = fixture()
        let osascript = try #require(probe.identity(of: 504))
        let cached = ProcessDescriptor(executablePath: "/usr/bin/osascript", argv: ["osascript", "-e", "tell application \"Notes\""])
        let input = try #require(TopologyCollector().collect(
            snapshot: snapshot, now: now0, probe: probe, cachedDescriptors: { ids in ids.contains(osascript) ? [osascript: cached] : [:] }))
        #expect(!probe.argumentReads.contains(504))
        #expect(!probe.pathReads.contains(504))
        #expect(input.arguments[504] == cached.argv)
    }

    @Test func probeFailuresMakeTheTopologyIncomplete() throws {
        let (probe, snapshot) = fixture()
        probe.setFDResult(600, .failed(EPERM))
        let failed = try #require(TopologyCollector().collect(snapshot: snapshot, now: now0, probe: probe, cachedDescriptors: { _ in [:] }))
        #expect(!failed.probesComplete)

        // A process that exited meanwhile is not a failure.
        probe.setFDResult(600, .gone)
        let gone = try #require(TopologyCollector().collect(snapshot: snapshot, now: now0, probe: probe, cachedDescriptors: { _ in [:] }))
        #expect(gone.probesComplete)
    }

    @Test func deadlineStopsCollectionAndMarksIncomplete() throws {
        let (probe, snapshot) = fixture()
        let input = try #require(TopologyCollector(deadline: .zero).collect(
            snapshot: snapshot, now: now0, probe: probe, cachedDescriptors: { _ in [:] }))
        #expect(!input.probesComplete)
    }

    @Test func tableFailureReturnsNil() {
        let (probe, snapshot) = fixture()
        probe.setTableAvailable(false)
        #expect(TopologyCollector().collect(snapshot: snapshot, now: now0, probe: probe, cachedDescriptors: { _ in [:] }) == nil)
    }

    @Test func agentsThatExitedSinceTheSnapshotAreDropped() throws {
        let (probe, snapshot) = fixture()
        probe.remove(503)
        let input = try #require(TopologyCollector().collect(snapshot: snapshot, now: now0, probe: probe, cachedDescriptors: { _ in [:] }))
        #expect(input.agents.isEmpty)
        #expect(builder.build(input).agentIdentities.isEmpty)
    }
}
