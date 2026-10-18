@testable import KakurenekoProcesses
import KakurenekoKit
import Foundation
import Synchronization
import Testing

private let claudePath = "\(Fixtures.home)/.local/share/claude/versions/2.1.296"

/// A scanner over a synthetic probe, with a fake DNS resolver (tests never touch the network).
private func makeScanner(
    paths: Paths, probe: FakeProbe, clock: any KakurenekoClock = TestClock(), resolver: @escaping HostResolver = { _ in [] }
) -> ProcessScanner {
    ProcessScanner(
        paths: paths,
        signatureMatcher: AgentSignatureRules.matcherForTests,
        clock: clock,
        logger: KakurenekoLogger(.processes),
        probe: probe,
        resolver: resolver,
        bundles: BundleIdentifierCache(reader: { _ in nil }),
        defaultBrowser: { "com.apple.Safari" },
        storeEventLatency: 0.02
    )
}

private func claudeProbe() -> (FakeProbe, ProcessIdentity) {
    let probe = FakeProbe()
    probe.add(pid: 400, ppid: 1, comm: "zsh", path: "/bin/zsh", argv: ["-zsh"], tdev: 0x1000_0002)
    let claude = probe.add(pid: 401, ppid: 400, comm: "2.1.296", path: claudePath, argv: ["claude"], tdev: 0x1000_0002)
    probe.add(pid: 402, ppid: 401, comm: "open", path: "/usr/bin/open", argv: ["open", "https://example.com"])
    probe.add(pid: 300, ppid: 1, comm: "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
    probe.setFDs(300, [.ptyMaster(minor: 2)])
    return (probe, claude)
}

@Suite("ProcessScanner", .timeLimit(.minutes(1)))
struct ProcessScannerTests {
    @Test func sampleAndTopologyThroughTheService() async throws {
        let temp = try TempHome()
        let (probe, claude) = claudeProbe()
        let scanner = makeScanner(paths: temp.paths, probe: probe)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = await scanner.sample(now: now)
        #expect(snapshot.agents.map(\.identity) == [claude])
        #expect(scanner.cachedIdentityCount == 4)

        let topology = await scanner.topology(for: snapshot, now: now)
        #expect(topology.builtAt == now)
        #expect(topology.agentIdentities == [claude])
        #expect(topology.ptyMasterHolderPIDs == [300])
        #expect(topology.ancestorPIDs == [400])
        #expect(topology.automationHelpers.map(\.likelyTargetBundleIDs) == [["com.apple.Safari"]])
        #expect(topology.sessionHostPIDs.isEmpty)
        #expect(topology.isComplete)
        // Helper argv came from the scan cache: no re-read during topology.
        #expect(probe.argumentReads.filter { $0 == 402 }.count == 1)
    }

    @Test func topologyFallsBackWhenTheTableIsUnavailable() async throws {
        let temp = try TempHome()
        let (probe, claude) = claudeProbe()
        let scanner = makeScanner(paths: temp.paths, probe: probe)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = await scanner.sample(now: now)
        probe.setTableAvailable(false)
        let topology = await scanner.topology(for: snapshot, now: now)
        #expect(!topology.isComplete)
        #expect(topology.agentIdentities == [claude])
        #expect(topology.descendantIdentities.map(\.pid) == [402])
        #expect(topology.ancestorPIDs == [400])
    }

    @Test func startAndStopAreIdempotentAndResolveEndpointsWithTheInjectedResolver() async throws {
        let temp = try TempHome()
        let (probe, _) = claudeProbe()
        let clock = TestClock()
        let resolved = Mutex(0)
        let scanner = makeScanner(paths: temp.paths, probe: probe, clock: clock, resolver: { host in
            resolved.withLock { $0 += 1 }
            return host == "api.anthropic.com" ? [ip("160.79.104.1")] : []
        })
        await scanner.start()
        await scanner.start()
        #expect(scanner.isStoreWatcherRunning)
        #expect(await clock.waitForSleepers(1))
        #expect(scanner.endpointRefreshCount == 1)
        #expect(resolved.withLock { $0 } == ModelEndpointRegistry.hosts.count)
        #expect(scanner.currentEndpoints.resolved == [ip("160.79.104.1")])
        await scanner.stop()
        await scanner.stop()
        #expect(!scanner.isStoreWatcherRunning)
        clock.advance(by: .seconds(3600))
        await Task.yield()
        #expect(scanner.endpointRefreshCount == 1) // the refresh loop is gone
    }

    @Test func storeHintsDriveE3FromRealFileSystemEvents() async throws {
        let temp = try TempHome()
        let (probe, claude) = claudeProbe()
        let clock = SystemClock()
        let scanner = makeScanner(paths: temp.paths, probe: probe, clock: clock)
        let project = temp.paths.home.appending(path: ".claude/projects/-tmp-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transcript = project.appending(path: "11111111-2222-3333-4444-555555555555.jsonl")
        let subagents = project.appending(path: "11111111-2222-3333-4444-555555555555")

        await scanner.updateSessionStoreHints([SessionStoreHint(
            identity: claude, paths: [transcript.path(percentEncoded: false), subagents.path(percentEncoded: false)])])
        await scanner.start()
        #expect(scanner.watchedStoreRoots.count == 1)

        let before = await scanner.sample(now: Date())
        #expect(before.process(for: claude)?.evidence.active.contains(.sessionStoreWrite) == false)

        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: subagents.appending(path: "agent-1.jsonl"))
        var written: Date?
        for _ in 0..<150 {
            written = scanner.storeWriteLog.lastWrite(for: claude)
            if written != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(written != nil, "no FSEvents write observed within 1.5 s")
        let after = await scanner.sample(now: Date())
        #expect(after.process(for: claude)?.evidence.active.contains(.sessionStoreWrite) == true)

        // Hints for a different identity: writes no longer attributed.
        await scanner.updateSessionStoreHints([])
        #expect(scanner.storeWriteLog.lastWrite(for: claude) == nil)
        #expect(scanner.watchedStoreRoots.isEmpty)
        await scanner.stop()
    }

    @Test func publicInitializerMatchesTheBindingSignature() throws {
        let temp = try TempHome()
        // Binding call shapes used by KakurenekoCoordinator (no start(): no FSEvents, no DNS).
        let a = ProcessScanner(paths: temp.paths, matcher: AgentMatcher(paths: temp.paths))
        let b = ProcessScanner(paths: temp.paths, matcher: AgentMatcher(paths: temp.paths), clock: TestClock(),
                               logger: KakurenekoLogger(.processes))
        let samplers: [any ProcessSampling] = [a, b]
        #expect(samplers.count == 2)
    }
}
