import Darwin
import KakurenekoKit
@testable import KakurenekoPause
import Foundation
import Testing

/// P-A…P-K, the mode choice and the P-I history as pure functions over synthetic groups and topologies.
@Suite("Protection rules", .timeLimit(.minutes(1)))
struct ProtectionRulesTests {
    static let now = TestClock.defaultStart

    /// Group: main 500 (bundle `com.example.app`), helpers 501, 502.
    static func group(bundleID: String? = "com.example.app", helperTTY: Int32? = nil, mainTTY: Int32? = nil,
                      ancestors: [pid_t] = [1], audio: Bool = false, traced: Bool = false) -> GroupFacts {
        let main = ProcessEntry(pid: 500, ppid: 1, uid: 501, startSec: 1, startUsec: 0, ttyDevice: mainTTY)
        let helpers = [
            ProcessEntry(pid: 501, ppid: 500, uid: 501, startSec: 2, startUsec: 0),
            ProcessEntry(pid: 502, ppid: 500, uid: 501, startSec: 3, startUsec: 0, ttyDevice: helperTTY),
        ]
        return GroupFacts(app: AppCandidate(pid: 500, bundleID: bundleID, localizedName: "Example"),
                          main: main, members: [main] + helpers, mainAncestors: ancestors,
                          audioActive: audio, traced: traced)
    }

    static func context(_ topology: AgentTopology = AgentTopology(builtAt: now),
                        settings: PauseSettings = PauseSettings(), selfPIDs: Set<pid_t> = [4242]) -> ProtectionContext {
        ProtectionContext(topology: topology, settings: settings, selfPIDs: selfPIDs)
    }

    static func identity(_ pid: pid_t) -> ProcessIdentity { ProcessIdentity(pid: pid, startSec: 9, startUsec: 0) }

    @Test func plainGroupIsUnprotected() {
        #expect(ProtectionRules.protections(for: Self.group(), in: Self.context()).isEmpty)
    }

    @Test func emptyTopologyNeverMeansNoAgent() {
        // `isEmpty` is diagnostics only: rules evaluate the sets, an empty topology protects nothing by itself and
        // nothing is inferred from it.
        let topology = AgentTopology(builtAt: Self.now)
        #expect(topology.isEmpty)
        #expect(ProtectionRules.protections(for: Self.group(), in: Self.context(topology)).isEmpty)
    }

    @Test func agentHostRuleA1AgentOrDescendantInGroup() {
        let agent = AgentTopology(builtAt: Self.now, agentIdentities: [Self.identity(502)])
        #expect(ProtectionRules.protections(for: Self.group(), in: Self.context(agent)) == [.agentHost])
        let descendant = AgentTopology(builtAt: Self.now, descendantIdentities: [Self.identity(501)])
        #expect(ProtectionRules.protections(for: Self.group(), in: Self.context(descendant)) == [.agentHost])
    }

    @Test func agentHostRuleA2PtyMasterHolder() {
        let topology = AgentTopology(builtAt: Self.now, ptyMasterHolderPIDs: [501])
        #expect(ProtectionRules.protections(for: Self.group(), in: Self.context(topology)) == [.agentHost])
    }

    @Test func agentHostRuleA3AncestorChain() {
        let topology = AgentTopology(builtAt: Self.now, ancestorPIDs: [500, 77])
        #expect(ProtectionRules.protections(for: Self.group(), in: Self.context(topology)) == [.agentHost])
    }

    @Test func agentHostSessionHostPIDs() {
        // In-app agents (VS Code Copilot, Cursor IDE …): no matched agent process, only the session's host app pid.
        let topology = AgentTopology(builtAt: Self.now, sessionHostPIDs: [500])
        #expect(!topology.isEmpty)
        #expect(ProtectionRules.protections(for: Self.group(), in: Self.context(topology)) == [.agentHost])
        let helperHost = AgentTopology(builtAt: Self.now, sessionHostPIDs: [502])
        #expect(ProtectionRules.protections(for: Self.group(), in: Self.context(helperHost)) == [.agentHost],
                "any group CONTAINING a session host is protected")
    }

    @Test func launchedByAgentRuleB() {
        let topology = AgentTopology(builtAt: Self.now, agentLaunchedAppPIDs: [500])
        #expect(ProtectionRules.protections(for: Self.group(), in: Self.context(topology)) == [.launchedByAgent])
        // Defense in depth: the main's own ancestry contains an agent-tree pid.
        let viaAncestry = AgentTopology(builtAt: Self.now, descendantIdentities: [Self.identity(900)])
        let reasons = ProtectionRules.protections(for: Self.group(ancestors: [900, 800, 1]), in: Self.context(viaAncestry))
        #expect(reasons == [.launchedByAgent])
    }

    @Test func ipcPeerAndListenerRulesCD() {
        let peer = AgentTopology(builtAt: Self.now, ipcPeers: [IPCPeerHint(peerPID: 501, kind: .unixSocket, agentSidePID: 900)])
        #expect(ProtectionRules.protections(for: Self.group(), in: Self.context(peer)) == [.ipcPeer])
        let tcp = AgentTopology(builtAt: Self.now, ipcPeers: [IPCPeerHint(peerPID: 500, kind: .loopbackTCP, agentSidePID: 900)])
        #expect(ProtectionRules.protections(for: Self.group(), in: Self.context(tcp)) == [.ipcPeer])
        let pipe = AgentTopology(builtAt: Self.now, ipcPeers: [IPCPeerHint(peerPID: 502, kind: .pipe, agentSidePID: 900)])
        #expect(ProtectionRules.protections(for: Self.group(), in: Self.context(pipe)) == [.ipcPeer])
        let listener = AgentTopology(builtAt: Self.now, ipcPeers: [IPCPeerHint(peerPID: 502, kind: .listener, agentSidePID: 900)])
        #expect(ProtectionRules.protections(for: Self.group(), in: Self.context(listener)) == [.listenerInUse])
        let elsewhere = AgentTopology(builtAt: Self.now, ipcPeers: [IPCPeerHint(peerPID: 777, kind: .unixSocket, agentSidePID: 900)])
        #expect(ProtectionRules.protections(for: Self.group(), in: Self.context(elsewhere)).isEmpty)
    }

    @Test func automationRuleE() {
        let helper = Self.identity(900)
        let unknownTarget = AgentTopology(builtAt: Self.now, automationHelpers: [AutomationHelperHint(helper: helper, tool: "osascript")])
        #expect(ProtectionRules.protections(for: Self.group(), in: Self.context(unknownTarget)) == [.automationTarget],
                "unknown target → protect everything")
        let targeted = AgentTopology(builtAt: Self.now, automationHelpers: [
            AutomationHelperHint(helper: helper, tool: "mcpbridge", likelyTargetBundleIDs: ["com.apple.dt.Xcode"]),
        ])
        #expect(ProtectionRules.protections(for: Self.group(), in: Self.context(targeted)).isEmpty)
        #expect(ProtectionRules.protections(for: Self.group(bundleID: "com.apple.dt.Xcode"), in: Self.context(targeted))
            .contains(.automationTarget))
    }

    @Test func audioTracedAndNeverListsFHJK() {
        #expect(ProtectionRules.protections(for: Self.group(audio: true), in: Self.context()) == [.audio])
        #expect(ProtectionRules.protections(for: Self.group(traced: true), in: Self.context()) == [.traced])
        #expect(ProtectionRules.protections(for: Self.group(bundleID: "com.apple.Terminal"), in: Self.context()) == [.staticNeverList])
        #expect(ProtectionRules.protections(for: Self.group(bundleID: "com.jetbrains.intellij"), in: Self.context()) == [.staticNeverList])
        let userList = PauseSettings.with { $0.neverPauseBundleIDs = ["com.example.app"] }
        #expect(ProtectionRules.protections(for: Self.group(), in: Self.context(settings: userList)) == [.userNeverList])
    }

    @Test func ttyOnAnyMemberProtectsTheGroup() {
        #expect(ProtectionRules.protections(for: Self.group(helperTTY: 0x1000004), in: Self.context()) == [.notCandidate])
        #expect(ProtectionRules.protections(for: Self.group(mainTTY: 0x1000001), in: Self.context()) == [.notCandidate])
    }

    @Test func kakurenekoItselfAndItsGuard() {
        #expect(ProtectionRules.protections(for: Self.group(bundleID: KakurenekoID.bundleIdentifier), in: Self.context())
            .contains(.kakurenekoItself))
        #expect(ProtectionRules.protections(for: Self.group(), in: Self.context(selfPIDs: [4242, 502])) == [.kakurenekoItself])
    }

    @Test func reasonsAccumulateInRuleOrder() {
        let topology = AgentTopology(builtAt: Self.now, ptyMasterHolderPIDs: [500],
                                     ipcPeers: [IPCPeerHint(peerPID: 501, kind: .unixSocket, agentSidePID: 9)])
        let reasons = ProtectionRules.protections(for: Self.group(helperTTY: 3, audio: true), in: Self.context(topology))
        #expect(reasons == [.agentHost, .ipcPeer, .audio, .notCandidate])
        #expect(!reasons.contains { $0.downgradesOnly })
    }

    @Test func downgradeOnlyRules() {
        #expect(ProtectionReason.download.downgradesOnly && ProtectionReason.busyAtLidClose.downgradesOnly)
        #expect(ProtectionRules.downgrades(downloadInProgress: false, busyFraction: 0.05).isEmpty)
        #expect(ProtectionRules.downgrades(downloadInProgress: true, busyFraction: 0.05) == [.download])
        #expect(ProtectionRules.downgrades(downloadInProgress: false, busyFraction: 0.5) == [.busyAtLidClose])
        #expect(ProtectionRules.downgrades(downloadInProgress: false, busyFraction: 0.20).isEmpty, "> 20 %, not ≥")
        #expect(ProtectionRules.downgrades(downloadInProgress: false, busyFraction: nil) == [.busyAtLidClose],
                "no P-I history → assume busy → no Freeze")
    }

    static func choice(_ requested: PauseMode, permitted: Bool = true, downgrades: [ProtectionReason] = [],
                       quit: Bool = false) -> String {
        let result = ProtectionRules.mode(requested: requested, freezePermitted: permitted, downgrades: downgrades,
                                          quitEligible: quit)
        return "\(result.mode.rawValue)/\(result.downgradedBecause?.rawValue ?? "-")"
    }

    @Test func modeChoice() {
        #expect(Self.choice(.throttle) == "throttle/-")
        #expect(Self.choice(.freeze) == "freeze/-")
        #expect(Self.choice(.freeze, permitted: false) == "throttle/uncertain", "self-test or topology forbids Freeze")
        #expect(Self.choice(.freeze, downgrades: [.busyAtLidClose]) == "throttle/P-I")
        #expect(Self.choice(.freeze, downgrades: [.download, .busyAtLidClose]) == "throttle/P-G")
        #expect(Self.choice(.throttle, quit: true) == "quit/-")
        #expect(Self.choice(.freeze, downgrades: [.download], quit: true) == "throttle/P-G", "a download blocks Quit too")
        #expect(Self.choice(.quit) == "throttle/-", ".quit as a mode means throttle (Quit is gated by quitWhenMemoryLow)")
    }

    @Test func staticNeverList() {
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
                   "dev.zed.Zed", "com.apple.dt.Xcode", "com.anthropic.claudefordesktop", "com.openai.chat",
                   "com.1password.1password", "com.apple.finder", "com.apple.systempreferences",
                   "com.apple.ActivityMonitor", "com.docker.docker", KakurenekoID.bundleIdentifier,
                   "com.jetbrains.pycharm", "com.jetbrains.WebStorm"] {
            #expect(NeverPauseList.contains(id), "\(id)")
        }
        for id in ["com.microsoft.Word", "com.spotify.client", "com.tinyspeck.slackmacgap", "com.google.Chrome", ""] {
            #expect(!NeverPauseList.contains(id), "\(id)")
        }
        #expect(!NeverPauseList.contains(nil))
    }
}

/// P-I history (`observe(now:)` samples, 2-minute window).
@Suite("CPU history (P-I)", .timeLimit(.minutes(1)))
struct CPUHistoryTests {
    static let t0 = TestClock.defaultStart
    static let main = ProcessIdentity(pid: 10, startSec: Int64(t0.timeIntervalSince1970) - 3600, startUsec: 0)
    static let helper = ProcessIdentity(pid: 11, startSec: Int64(t0.timeIntervalSince1970) - 3600, startUsec: 0)

    @Test func noHistoryOrTooShortIsNil() {
        var history = CPUHistory()
        #expect(history.busyFraction(for: Self.main, now: Self.t0) == nil)
        history.record([Self.main: [Self.main: 0]], at: Self.t0)
        #expect(history.busyFraction(for: Self.main, now: Self.t0) == nil, "one sample")
        history.record([Self.main: [Self.main: 1_000_000]], at: Self.t0.addingTimeInterval(10))
        #expect(history.busyFraction(for: Self.main, now: Self.t0.addingTimeInterval(10)) == nil, "< 30 s span")
    }

    @Test func fractionOfOneCoreOverTheWindow() throws {
        var history = CPUHistory()
        history.record([Self.main: [Self.main: 0, Self.helper: 0]], at: Self.t0)
        // 60 s later: main used 6 s, helper 12 s → 18 s / 60 s = 0.30 of one core.
        let t1 = Self.t0.addingTimeInterval(60)
        history.record([Self.main: [Self.main: 6_000_000_000, Self.helper: 12_000_000_000]], at: t1)
        let fraction = try #require(history.busyFraction(for: Self.main, now: t1))
        #expect(abs(fraction - 0.30) < 0.0001)
        #expect(ProtectionRules.downgrades(downloadInProgress: false, busyFraction: fraction) == [.busyAtLidClose])
    }

    @Test func idleGroupIsBelowThreshold() throws {
        var history = CPUHistory()
        history.record([Self.main: [Self.main: 5_000]], at: Self.t0)
        let t1 = Self.t0.addingTimeInterval(90)
        history.record([Self.main: [Self.main: 9_000_000_000]], at: t1) // 9 s over 90 s = 10 %
        let fraction = try #require(history.busyFraction(for: Self.main, now: t1))
        #expect(fraction < ProtectionRules.busyThreshold)
    }

    @Test func oldSamplesLeaveTheWindowAndUnseenGroupsAreForgotten() throws {
        var history = CPUHistory()
        let other = ProcessIdentity(pid: 20, startSec: 1, startUsec: 0)
        history.record([Self.main: [Self.main: 0], other: [other: 0]], at: Self.t0)
        history.record([Self.main: [Self.main: 100_000_000_000]], at: Self.t0.addingTimeInterval(60))
        #expect(history.series[other] == nil, "not seen in the newest scan")
        // 200 s later the first two samples are outside the 120 s window.
        history.record([Self.main: [Self.main: 100_000_000_000]], at: Self.t0.addingTimeInterval(200))
        history.record([Self.main: [Self.main: 100_000_000_000]], at: Self.t0.addingTimeInterval(240))
        let fraction = try #require(history.busyFraction(for: Self.main, now: Self.t0.addingTimeInterval(240)))
        #expect(fraction == 0, "the burst happened before the window")
        #expect(history.series[Self.main]?.count == 2)
    }

    @Test func memberStartedInsideTheWindowCountsFromZero() throws {
        var history = CPUHistory()
        history.record([Self.main: [Self.main: 0]], at: Self.t0)
        let newcomer = ProcessIdentity(pid: 12, startSec: Int64(Self.t0.timeIntervalSince1970) + 10, startUsec: 0)
        let t1 = Self.t0.addingTimeInterval(40)
        history.record([Self.main: [Self.main: 0, newcomer: 20_000_000_000]], at: t1)
        let fraction = try #require(history.busyFraction(for: Self.main, now: t1))
        #expect(abs(fraction - 0.5) < 0.0001, "20 s of CPU in 40 s")
    }
}
