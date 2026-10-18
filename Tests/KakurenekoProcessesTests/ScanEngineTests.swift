@testable import KakurenekoProcesses
import KakurenekoKit
import Foundation
import Testing

private let now0 = Date(timeIntervalSince1970: 1_800_000_000)
private let claudePath = "\(Fixtures.home)/.local/share/claude/versions/2.1.296"
private let terminalPath = "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
private let ttys004: Int32 = 0x1000_0004

/// Terminal → root `login` → zsh → claude (+ caffeinate, uv → python MCP server), plus an unrelated process.
private func terminalClaudeFixture() -> (probe: FakeProbe, claude: ProcessIdentity) {
    let probe = FakeProbe()
    probe.add(pid: 500, ppid: 1, path: terminalPath, argv: [terminalPath])
    probe.add(pid: 501, ppid: 500, uid: FakeProbe.root, comm: "login", path: "/usr/bin/login")
    probe.add(pid: 502, ppid: 501, comm: "zsh", path: "/bin/zsh", argv: ["-zsh"], tdev: ttys004)
    let claude = probe.add(
        pid: 503, ppid: 502, comm: "2.1.296", path: claudePath, argv: ["claude", "--resume"],
        environment: ["TERM_PROGRAM": "Apple_Terminal", "__CFBundleIdentifier": "com.apple.Terminal"],
        tdev: ttys004, cpu: 12, cwd: "\(Fixtures.home)/project")
    probe.add(pid: 504, ppid: 503, comm: "caffeinate", path: "/usr/bin/caffeinate", argv: ["caffeinate", "-i", "-t", "300"], tdev: ttys004)
    probe.add(pid: 505, ppid: 503, comm: "uv", path: "/opt/homebrew/bin/uv", argv: ["uv", "run", "server.py"], tdev: ttys004, cpu: 1)
    probe.add(pid: 506, ppid: 505, comm: "python3.14", path: "/opt/python3.14", argv: ["python3", "server.py"], tdev: ttys004, cpu: 2)
    probe.add(pid: 900, ppid: 1, comm: "Finder", path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")
    probe.setTerminal(ttys004, name: "ttys004", modified: now0.addingTimeInterval(-600))
    return (probe, claude)
}

private let terminalBundles = ["/System/Applications/Utilities/Terminal.app": "com.apple.Terminal"]

@Suite("Scan pipeline (synthetic process table)", .timeLimit(.minutes(1)))
struct ScanEngineTests {
    @Test func buildsTheAgentProcess() throws {
        let (probe, claude) = terminalClaudeFixture()
        probe.setAssertions([504: [PowerAssertionInfo(type: "PreventUserIdleSystemSleep", name: "caffeinate command-line tool")]])
        var engine = ScanEngine()
        let snapshot = engine.scan(probe: probe, context: Fixtures.scanContext(bundleIDs: terminalBundles), now: now0)

        #expect(snapshot.takenAt == now0)
        #expect(snapshot.scannedProcessCount == 7) // every same-uid row (root `login` excluded)
        let agent = try #require(snapshot.agents.first)
        #expect(snapshot.agents.count == 1)
        #expect(agent.identity == claude)
        #expect(agent.identity.uniqueID == 503_000)
        #expect(agent.identity.pidVersion == 510)
        #expect(agent.agent == .claude)
        #expect(!agent.isInfrastructure && !agent.isIDEHost)
        #expect(agent.executablePath == claudePath)
        #expect(agent.argv0 == "claude")
        #expect(agent.arguments == ["claude", "--resume"])
        #expect(agent.ppid == 502)
        #expect(agent.cwd == "\(Fixtures.home)/project")
        #expect(agent.ttyDevice == ttys004)
        #expect(agent.ttyName == "ttys004")
        #expect(agent.firstSeen == now0)

        // Ancestry walks through the root-owned `login` (identity via KERN_PROC_PID), up to launchd (excluded).
        #expect(agent.ancestors.map(\.identity.pid) == [502, 501, 500])
        #expect(agent.ancestors[1].identity == probe.identity(of: 501))
        #expect(agent.ancestors[1].comm == "login")
        #expect(agent.ancestors[2].isApp)
        #expect(agent.ancestors[2].bundleID == "com.apple.Terminal")
        #expect(!agent.ancestors[0].isApp)
        #expect(agent.hostApp == HostApp(bundleID: "com.apple.Terminal", name: "Terminal", pid: 500))

        // Every same-uid descendant.
        #expect(Set(agent.descendants.map(\.pid)) == [504, 505, 506])

        // E6 via the caffeinate child; E5 stale (10 min old tty write).
        #expect(agent.evidence.active == [.powerAssertion])
        #expect(agent.evidence.assertionNames == ["caffeinate command-line tool"])
        #expect(agent.evidence.treeCPUSeconds == 15)
        #expect(agent.evidence.ttyLastActivityAt == now0.addingTimeInterval(-600))
    }

    @Test func hostAppFromTheBundleAncestorWhenTheEnvironmentSaysNothing() throws {
        let probe = FakeProbe()
        let main = "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"
        let plugin = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        let helper = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"
        probe.add(pid: 600, ppid: 1, comm: "Electron", path: main, argv: [main])
        probe.add(pid: 601, ppid: 600, comm: "Code Helper", path: helper, argv: [helper, "--type=utility"]) // pty host
        probe.add(pid: 602, ppid: 601, comm: "zsh", path: "/bin/zsh", argv: ["/bin/zsh", "-il"])
        probe.add(pid: 603, ppid: 602, comm: "2.1.296", path: claudePath, argv: ["claude"])
        probe.add(pid: 610, ppid: 600, comm: "Code Helper (Plu", path: plugin, argv: [plugin, "--type=utility"])
        var engine = ScanEngine()
        let snapshot = engine.scan(
            probe: probe,
            context: Fixtures.scanContext(bundleIDs: [
                "/Applications/Visual Studio Code.app": "com.microsoft.VSCode",
                "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app": "com.microsoft.VSCode.helper",
            ]),
            now: now0)
        #expect(snapshot.agents.map(\.identity.pid) == [603, 610]) // sorted by pid
        let claude = try #require(snapshot.process(pid: 603))
        #expect(claude.hostApp == HostApp(bundleID: "com.microsoft.VSCode", name: "VS Code", pid: 600))
        #expect(claude.ancestors.first { $0.identity.pid == 601 }?.bundleID == "com.microsoft.VSCode.helper")
        let extensionHost = try #require(snapshot.process(pid: 610))
        #expect(extensionHost.agent == .vscode)
        #expect(extensionHost.isIDEHost)
    }

    @Test func argvIsReadOnlyForNewIdentities() {
        let (probe, _) = terminalClaudeFixture()
        var engine = ScanEngine()
        let context = Fixtures.scanContext()
        _ = engine.scan(probe: probe, context: context, now: now0)
        #expect(Set(probe.argumentReads) == [500, 502, 503, 504, 505, 506, 900]) // same uid only
        #expect(engine.lastScanReads == 7)

        probe.resetCounters()
        _ = engine.scan(probe: probe, context: context, now: now0.addingTimeInterval(5))
        #expect(probe.argumentReads.isEmpty)
        #expect(engine.lastScanReads == 0)

        // A new process → exactly one read.
        probe.add(pid: 507, ppid: 503, comm: "git", path: "/usr/bin/git", argv: ["git", "status"])
        probe.resetCounters()
        _ = engine.scan(probe: probe, context: context, now: now0.addingTimeInterval(10))
        #expect(probe.argumentReads == [507])

        // Gone identities are forgotten.
        probe.remove(507)
        probe.remove(900)
        _ = engine.scan(probe: probe, context: context, now: now0.addingTimeInterval(15))
        #expect(engine.cache.count == 6)
        #expect(!engine.cache.keys.contains { $0.pid == 507 || $0.pid == 900 })
    }

    @Test func pidReuseIsANewIdentity() throws {
        let probe = FakeProbe()
        probe.add(pid: 700, ppid: 1, comm: "zsh", path: "/bin/zsh", argv: ["zsh"])
        var engine = ScanEngine()
        let context = Fixtures.scanContext()
        #expect(engine.scan(probe: probe, context: context, now: now0).agents.isEmpty)
        // The pid is reused by an agent (different start time).
        let codex = probe.add(pid: 700, ppid: 1, comm: "codex", path: "/opt/homebrew/bin/codex", argv: ["codex"], startSec: 1_799_999_000)
        let snapshot = engine.scan(probe: probe, context: context, now: now0.addingTimeInterval(5))
        let agent = try #require(snapshot.agents.first)
        #expect(agent.identity == codex)
        #expect(agent.firstSeen == now0.addingTimeInterval(5))
        #expect(engine.cache.count == 1)
    }

    @Test func execIsDetectedThroughTheCommChange() throws {
        // Cursor's launcher: a bash script that `exec -a "$0" node … index.js` — same pid and start time.
        let probe = FakeProbe()
        let launcher = "\(Fixtures.home)/.local/share/cursor-agent/versions/1/cursor-agent"
        let node = "\(Fixtures.home)/.local/share/cursor-agent/versions/1/node"
        let identity = probe.add(pid: 800, ppid: 1, comm: "bash", path: "/bin/bash", argv: ["/bin/bash", launcher])
        var engine = ScanEngine()
        let context = Fixtures.scanContext()
        #expect(engine.scan(probe: probe, context: context, now: now0).agents.isEmpty)
        probe.update(800) { process in
            process.row.comm = "node"
            process.path = node
            process.arguments = ProcArguments(executablePath: node, argv: ["cursor-agent", "--use-system-ca", "\(Fixtures.home)/.local/share/cursor-agent/versions/1/index.js"], environment: [:])
        }
        let snapshot = engine.scan(probe: probe, context: context, now: now0.addingTimeInterval(5))
        let agent = try #require(snapshot.agents.first)
        #expect(agent.identity == identity)
        #expect(agent.agent == .cursor)
        #expect(agent.firstSeen == now0) // same identity: first seen at the first scan
    }

    @Test func youngProcessesAreReadOnceMore() {
        let probe = FakeProbe()
        let wall = Date(timeIntervalSince1970: 1_800_000_000)
        probe.setWallNow(wall)
        // Started 0.4 s ago: may still be between fork and exec.
        probe.add(pid: 810, ppid: 1, comm: "zsh", path: "/bin/zsh", argv: ["zsh"], startSec: 1_800_000_000 - 1)
        probe.update(810) { $0.row.identity?.startUsec = 600_000 }
        var engine = ScanEngine()
        let context = Fixtures.scanContext()
        _ = engine.scan(probe: probe, context: context, now: now0)
        _ = engine.scan(probe: probe, context: context, now: now0.addingTimeInterval(5))
        _ = engine.scan(probe: probe, context: context, now: now0.addingTimeInterval(10))
        #expect(probe.argumentReads == [810, 810])
    }

    @Test func executablePathFallsBackToTheExecPathWhenTheBinaryWasReplaced() throws {
        let probe = FakeProbe()
        // proc_pidpath nil (auto-update deleted the version file); KERN_PROCARGS2 still has the exec path.
        probe.add(pid: 820, ppid: 1, comm: "2.1.288", path: nil, argv: ["claude"], execPath: "\(Fixtures.home)/.local/bin/claude")
        var engine = ScanEngine()
        let snapshot = engine.scan(probe: probe, context: Fixtures.scanContext(), now: now0)
        let agent = try #require(snapshot.agents.first)
        #expect(agent.agent == .claude)
        #expect(agent.executablePath == "\(Fixtures.home)/.local/bin/claude")
    }

    @Test func infrastructureAndNestedAgentsAreReported() throws {
        let probe = FakeProbe()
        probe.add(pid: 1000, ppid: 1, comm: "2.1.296", path: claudePath, argv: ["\(Fixtures.home)/.local/bin/claude", "daemon", "run"])
        probe.add(pid: 1001, ppid: 1000, comm: "2.1.296", path: claudePath, argv: ["claude bg-spare"])
        let node = "/opt/homebrew/bin/node"
        probe.add(pid: 1100, ppid: 1, comm: "node", path: node, argv: ["node", "/opt/homebrew/bin/gemini"])
        probe.add(pid: 1101, ppid: 1100, comm: "node", path: node,
                  argv: [node, "/opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js"])
        var engine = ScanEngine()
        let snapshot = engine.scan(probe: probe, context: Fixtures.scanContext(), now: now0)
        #expect(snapshot.agents.map(\.identity.pid) == [1000, 1001, 1100, 1101])
        #expect(snapshot.process(pid: 1000)?.isInfrastructure == true)
        #expect(snapshot.process(pid: 1001)?.isInfrastructure == true)
        #expect(snapshot.sessionCandidates.map(\.identity.pid) == [1100, 1101])
        // Two-process Gemini: the working child is a descendant of the parent.
        #expect(snapshot.process(pid: 1100)?.descendants.map(\.pid) == [1101])
    }

    @Test func otherUsersDescendantsAreNotReported() throws {
        let probe = FakeProbe()
        probe.add(pid: 1200, ppid: 1, comm: "codex", path: "/opt/homebrew/bin/codex", argv: ["codex"])
        probe.add(pid: 1201, ppid: 1200, uid: FakeProbe.root, comm: "sudo", path: "/usr/bin/sudo")
        probe.add(pid: 1202, ppid: 1200, comm: "git", path: "/usr/bin/git", argv: ["git", "log"])
        var engine = ScanEngine()
        let agent = try #require(engine.scan(probe: probe, context: Fixtures.scanContext(), now: now0).agents.first)
        #expect(agent.descendants.map(\.pid) == [1202])
    }

    @Test func tableFailureYieldsAnEmptySnapshotAndKeepsTheCache() {
        let (probe, _) = terminalClaudeFixture()
        var engine = ScanEngine()
        _ = engine.scan(probe: probe, context: Fixtures.scanContext(), now: now0)
        probe.setTableAvailable(false)
        let snapshot = engine.scan(probe: probe, context: Fixtures.scanContext(), now: now0.addingTimeInterval(5))
        #expect(snapshot.agents.isEmpty)
        #expect(snapshot.scannedProcessCount == 0)
        #expect(engine.cache.count == 7)
    }

    // MARK: Evidence end to end

    /// Sampled every 5 s for 30 min: Claude respawns caffeinate every 240 s while busy-but-stuck → E2 never fires,
    /// E6 holds (attributed caffeinate), so the stall guard can trip. Real work afterwards does fire E2.
    @Test func stuckClaudeWithCaffeinateRespawnsShowsNoChurn() throws {
        let (probe, claude) = terminalClaudeFixture()
        var engine = ScanEngine()
        let context = Fixtures.scanContext()
        var caffeinatePID: Int32 = 504
        var t: TimeInterval = 0
        while t <= 1800 {
            if t > 0, t.truncatingRemainder(dividingBy: 240) == 0 {
                probe.remove(caffeinatePID)
                caffeinatePID += 100
                probe.add(pid: caffeinatePID, ppid: 503, comm: "caffeinate", path: "/usr/bin/caffeinate", argv: ["caffeinate", "-i", "-t", "300"])
            }
            probe.setAssertions([caffeinatePID: [PowerAssertionInfo(type: "PreventUserIdleSystemSleep", name: "caffeinate command-line tool")]])
            let snapshot = engine.scan(probe: probe, context: context, now: now0.addingTimeInterval(t))
            let agent = try #require(snapshot.process(for: claude))
            #expect(!agent.evidence.active.contains(.childChurn), "E2 at t=\(t)")
            #expect(agent.evidence.active.contains(.powerAssertion))
            #expect(!agent.evidence.showsProgress, "progress at t=\(t)")
            t += 5
        }
        probe.add(pid: 3000, ppid: 503, comm: "zsh", path: "/bin/zsh", argv: ["/bin/zsh", "-c", "git status"])
        let snapshot = engine.scan(probe: probe, context: context, now: now0.addingTimeInterval(t))
        #expect(snapshot.process(for: claude)?.evidence.active.contains(.childChurn) == true)
        #expect(snapshot.process(for: claude)?.evidence.newDescendantCount == 1)
    }

    @Test func treeCPUIsSummedOverDescendants() throws {
        let (probe, claude) = terminalClaudeFixture()
        var engine = ScanEngine()
        let context = Fixtures.scanContext()
        _ = engine.scan(probe: probe, context: context, now: now0)
        // Over 60 s: agent +0.9 s, python grandchild +1.2 s → 2.1 s / 60 s = 3.5 %.
        probe.setCPU(503, 12.9)
        probe.setCPU(506, 3.2)
        let snapshot = engine.scan(probe: probe, context: context, now: now0.addingTimeInterval(60))
        let evidence = try #require(snapshot.process(for: claude)?.evidence)
        #expect(abs((evidence.treeCPUPercent ?? 0) - 3.5) < 0.001)
        #expect(evidence.active.contains(.treeCPU))
        #expect(abs((evidence.treeCPUSeconds ?? 0) - 17.1) < 0.001)
    }

    @Test func modelAPIConnectionsDriveE4() throws {
        let (probe, claude) = terminalClaudeFixture()
        var engine = ScanEngine()
        var endpoints = ModelEndpointSet()
        endpoints.resolved = [try #require(IPAddress("104.18.33.45"))]
        let context = Fixtures.scanContext(endpoints: endpoints)
        probe.setFDs(503, [
            Fixtures.tcp(local: "192.168.1.5", 50001, remote: "160.79.104.10", 443),
            Fixtures.tcp(local: "192.168.1.5", 50002, remote: "140.82.112.3", 443), // github: not a model API
        ])
        let first = try #require(engine.scan(probe: probe, context: context, now: now0).process(for: claude))
        #expect(!first.evidence.active.contains(.modelAPISocket)) // baseline
        #expect(first.evidence.modelSocketCount == 1)

        // Unrelated churn on non-model sockets does not count.
        probe.setFDs(503, [
            Fixtures.tcp(local: "192.168.1.5", 50001, remote: "160.79.104.10", 443),
            Fixtures.tcp(local: "192.168.1.5", 50003, remote: "140.82.112.4", 443),
        ])
        let second = try #require(engine.scan(probe: probe, context: context, now: now0.addingTimeInterval(5)).process(for: claude))
        #expect(!second.evidence.active.contains(.modelAPISocket))

        // A new connection (from the MCP grandchild) to a resolved model-API address.
        probe.setFDs(506, [Fixtures.tcp(local: "192.168.1.5", 50010, remote: "104.18.33.45", 443)])
        let third = try #require(engine.scan(probe: probe, context: context, now: now0.addingTimeInterval(10)).process(for: claude))
        #expect(third.evidence.active.contains(.modelAPISocket))
        #expect(third.evidence.modelSocketCount == 2)
        // SYN_SENT / LISTEN sockets are not ESTABLISHED.
        probe.setFDs(506, [Fixtures.tcp(local: "192.168.1.5", 50010, remote: "104.18.33.45", 443, state: TSI_S_SYN_SENT)])
        let fourth = try #require(engine.scan(probe: probe, context: context, now: now0.addingTimeInterval(15)).process(for: claude))
        #expect(fourth.evidence.modelSocketCount == 1)
    }

    @Test func storeWritesAndTTYActivityDriveE3AndE5() throws {
        let (probe, claude) = terminalClaudeFixture()
        let log = SessionStoreWriteLog()
        log.setHints([SessionStoreHint(identity: claude, paths: ["/tmp/kakureneko-test-hint/project/session.jsonl"])])
        log.record(paths: [("/tmp/kakureneko-test-hint/project/session.jsonl", false)], at: now0.addingTimeInterval(-10))
        probe.setTerminal(ttys004, name: "ttys004", modified: now0.addingTimeInterval(-3))
        var engine = ScanEngine()
        let snapshot = engine.scan(probe: probe, context: Fixtures.scanContext(storeWrites: log), now: now0)
        let evidence = try #require(snapshot.process(for: claude)?.evidence)
        #expect(evidence.active == [.sessionStoreWrite, .ttyActivity])
        #expect(evidence.meetsHeuristicThreshold)
        #expect(evidence.lastStoreWriteAt == now0.addingTimeInterval(-10))
    }

    @Test func evidenceHistoryIsDroppedWhenTheAgentExits() {
        let (probe, claude) = terminalClaudeFixture()
        var engine = ScanEngine()
        let context = Fixtures.scanContext()
        _ = engine.scan(probe: probe, context: context, now: now0)
        #expect(engine.trees.keys.contains(claude))
        probe.remove(503)
        _ = engine.scan(probe: probe, context: context, now: now0.addingTimeInterval(5))
        #expect(engine.trees.isEmpty)
    }

    @Test func enrichmentIsSkippedWhenTheIdentityChangedMeanwhile() throws {
        final class RacingProbe: ProcessProbing {
            let base: FakeProbe
            init(base: FakeProbe) { self.base = base }
            func readTable() -> ProcessTable? { base.readTable() }
            // The process vanished between the table read and the flavor-17 read.
            func identity(of pid: Int32) -> ProcessIdentity? { nil }
            func executablePath(of pid: Int32) -> String? { base.executablePath(of: pid) }
            func arguments(of pid: Int32, reader: inout ProcArgsReader) -> ProcArguments? { base.arguments(of: pid, reader: &reader) }
            func cpuSeconds(of pid: Int32) -> Double? { base.cpuSeconds(of: pid) }
            func workingDirectory(of pid: Int32) -> String? { base.workingDirectory(of: pid) }
            func uniqueIdentifier(of pid: Int32) -> (uniqueID: UInt64, pidVersion: UInt32)? { base.uniqueIdentifier(of: pid) }
            func fileDescriptors(of pid: Int32, kinds: FDKinds) -> FDReadResult { base.fileDescriptors(of: pid, kinds: kinds) }
            func powerAssertions() -> [Int32: [PowerAssertionInfo]]? { base.powerAssertions() }
            func terminal(device: Int32) -> (name: String, modified: Date?)? { base.terminal(device: device) }
            func wallClockNow() -> Date { base.wallClockNow() }
        }
        let probe = FakeProbe()
        probe.add(pid: 1300, ppid: 1, comm: "codex", path: "/opt/homebrew/bin/codex", argv: ["codex"])
        var engine = ScanEngine()
        let agent = try #require(engine.scan(probe: RacingProbe(base: probe), context: Fixtures.scanContext(), now: now0).agents.first)
        #expect(agent.identity.uniqueID == nil)
        #expect(agent.identity.pidVersion == nil)
    }

    @Test func caffeinateDetection() {
        #expect(ScanEngine.isCaffeinate(ProcessDescriptor(executablePath: "/usr/bin/caffeinate", argv: ["x"]), comm: "x"))
        #expect(ScanEngine.isCaffeinate(ProcessDescriptor(executablePath: nil, argv: ["caffeinate", "-i"]), comm: ""))
        #expect(ScanEngine.isCaffeinate(ProcessDescriptor(executablePath: nil, argv: []), comm: "caffeinate"))
        #expect(!ScanEngine.isCaffeinate(ProcessDescriptor(executablePath: "/bin/zsh", argv: ["zsh", "-c", "caffeinate"]), comm: "zsh"))
    }
}
