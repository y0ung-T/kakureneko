@testable import KakurenekoProcesses
import KakurenekoKit
import Foundation
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
private func id(_ pid: Int32, start: Int64 = 1_700_000_000) -> ProcessIdentity {
    ProcessIdentity(pid: pid, startSec: start + Int64(pid), startUsec: 0)
}

@Suite("Evidence E1: tree CPU", .timeLimit(.minutes(1)))
struct TreeCPUTests {
    /// Samples every `step` seconds with the tree using `rate` CPU-seconds per second.
    private func run(rate: Double, duration: TimeInterval, step: TimeInterval = 5) -> TreeCPUAccumulator {
        var acc = TreeCPUAccumulator()
        var cpu = 100.0 // lifetime CPU before the first sample
        var t: TimeInterval = 0
        while t <= duration {
            acc.record(members: [(id(10), cpu)], now: at(t))
            cpu += rate * step
            t += step
        }
        return acc
    }

    @Test func thresholdIsThreePercentOfOneCore() {
        let busy = run(rate: 0.031, duration: 120)
        #expect(abs((busy.averagePercent(now: at(120)) ?? 0) - 3.1) < 0.01)
        let inputs = { (acc: TreeCPUAccumulator) in
            EvidenceInputs(cpu: acc, churn: DescendantChurnTracker(), sockets: ModelSocketTracker(), assertionNames: [])
        }
        #expect(inputs(busy).sample(at: at(120)).active.contains(.treeCPU))

        let quiet = run(rate: 0.029, duration: 120)
        #expect(!inputs(quiet).sample(at: at(120)).active.contains(.treeCPU))
        #expect(abs((inputs(quiet).sample(at: at(120)).treeCPUPercent ?? 0) - 2.9) < 0.01)
    }

    @Test func firstSampleHasNoAverageButReportsCumulativeSeconds() {
        var acc = TreeCPUAccumulator()
        acc.record(members: [(id(10), 12.5), (id(11), 0.5)], now: at(0))
        #expect(acc.averagePercent(now: at(0)) == nil)
        #expect(acc.totalSeconds == 13)
        let sample = EvidenceInputs(cpu: acc, churn: .init(), sockets: .init(), assertionNames: []).sample(at: at(0))
        #expect(sample.treeCPUSeconds == 13)
        #expect(sample.treeCPUPercent == nil)
        #expect(!sample.active.contains(.treeCPU))
    }

    @Test func burstOlderThanTheWindowDoesNotCount() {
        var acc = TreeCPUAccumulator()
        acc.record(members: [(id(10), 0)], now: at(0))
        acc.record(members: [(id(10), 30)], now: at(5)) // 30 s of CPU in 5 s (a build)
        var t: TimeInterval = 10
        while t <= 70 {
            acc.record(members: [(id(10), 30)], now: at(t)) // idle afterwards
            t += 5
        }
        #expect((acc.averagePercent(now: at(70)) ?? 100) < 0.01)
        // Within the window the burst dominates.
        var recent = TreeCPUAccumulator()
        recent.record(members: [(id(10), 0)], now: at(0))
        recent.record(members: [(id(10), 3)], now: at(30))
        #expect((recent.averagePercent(now: at(30)) ?? 0) > 9)
    }

    @Test func windowStartIsInterpolated() {
        var acc = TreeCPUAccumulator()
        // 0 → 60 s: 6 CPU-s (10 %), 60 → 120 s: 0.
        acc.record(members: [(id(10), 0)], now: at(0))
        acc.record(members: [(id(10), 6)], now: at(60))
        acc.record(members: [(id(10), 6)], now: at(120))
        #expect((acc.averagePercent(now: at(120)) ?? 1) < 0.001)
        // At t=90 the window [30, 90] holds half of the first segment: 3 CPU-s over 60 s = 5 %.
        var partial = TreeCPUAccumulator()
        partial.record(members: [(id(10), 0)], now: at(0))
        partial.record(members: [(id(10), 6)], now: at(60))
        partial.record(members: [(id(10), 6)], now: at(90))
        #expect(abs((partial.averagePercent(now: at(90)) ?? 0) - 5) < 0.001)
    }

    @Test func cumulativeSecondsAreMonotonicWhenMembersExitAndNewOnesArrive() {
        var acc = TreeCPUAccumulator()
        acc.record(members: [(id(10), 10), (id(11), 5)], now: at(0))
        #expect(acc.totalSeconds == 15)
        // Child 11 exits; agent keeps going.
        acc.record(members: [(id(10), 11)], now: at(5))
        #expect(acc.totalSeconds == 16)
        // New child 12 born inside the window with 2 s already used.
        acc.record(members: [(id(10), 11), (id(12), 2)], now: at(10))
        #expect(acc.totalSeconds == 18)
        // A pid reused by a different process is a new identity: counted from zero, never subtracted.
        acc.record(members: [(id(10), 11), (id(12, start: 1_750_000_000), 0.5)], now: at(15))
        #expect(acc.totalSeconds == 18.5)
        // A member whose counter goes backwards (never happens for a live identity) is clamped.
        acc.record(members: [(id(10), 1), (id(12, start: 1_750_000_000), 0.5)], now: at(20))
        #expect(acc.totalSeconds == 18.5)
    }

    @Test func historyIsPrunedButKeepsAPointBeforeTheWindow() {
        var acc = TreeCPUAccumulator()
        for step in 0...200 { acc.record(members: [(id(10), Double(step) * 0.5)], now: at(Double(step) * 5)) }
        #expect(acc.history.count < 80)
        // 0.5 CPU-s per 5 s = 10 %.
        #expect(abs((acc.averagePercent(now: at(1000)) ?? 0) - 10) < 0.001)
    }

    @Test func sameTimestampRefreshesInsteadOfAppending() {
        var acc = TreeCPUAccumulator()
        acc.record(members: [(id(10), 1)], now: at(0))
        acc.record(members: [(id(10), 2)], now: at(0))
        #expect(acc.history.count == 1)
        #expect(acc.totalSeconds == 2)
    }
}

@Suite("Evidence E2: child churn", .timeLimit(.minutes(1)))
struct ChildChurnTests {
    private func info(_ pid: Int32, _ argv: [String], caffeinate: Bool = false, infra: Bool = false, start: Int64 = 1_700_000_000)
        -> DescendantInfo
    {
        DescendantInfo(
            identity: id(pid, start: start), argvKey: DescendantInfo.argvKey(executablePath: nil, argv: argv, comm: ""),
            isCaffeinate: caffeinate, isInfrastructure: infra)
    }

    @Test func baselineDescendantsAreNotChurn() {
        var tracker = DescendantChurnTracker()
        tracker.update(current: [info(20, ["uv", "run", "mcp"]), info(21, ["python3", "server.py"])], now: at(0))
        #expect(!tracker.isActive(now: at(0)))
        tracker.update(current: [info(20, ["uv", "run", "mcp"]), info(21, ["python3", "server.py"])], now: at(5))
        #expect(!tracker.isActive(now: at(5)))
    }

    @Test func newDescendantIsActiveForSixtySeconds() {
        var tracker = DescendantChurnTracker()
        tracker.update(current: [], now: at(0))
        tracker.update(current: [info(30, ["/bin/zsh", "-c", "git status"])], now: at(5))
        #expect(tracker.isActive(now: at(5)))
        #expect(tracker.newDescendantCount(now: at(5)) == 1)
        tracker.update(current: [], now: at(10))
        #expect(tracker.isActive(now: at(60)))
        #expect(tracker.isActive(now: at(65)))
        tracker.update(current: [], now: at(66))
        #expect(!tracker.isActive(now: at(66)))
        #expect(tracker.newDescendantCount(now: at(66)) == 0)
    }

    @Test func countsEveryNewNonExcludedDescendant() {
        var tracker = DescendantChurnTracker()
        tracker.update(current: [], now: at(0))
        tracker.update(current: [info(31, ["git", "diff"]), info(32, ["rg", "foo"]), info(33, ["npm", "test"])], now: at(5))
        #expect(tracker.newDescendantCount(now: at(5)) == 3)
    }

    /// Claude respawns `caffeinate -i -t 300` every 240 s while busy (R02 §4.1): sampled every 5 s for an hour,
    /// E2 must never fire — otherwise the stall guard never trips on the 13 h stale-busy case.
    @Test func caffeinateRespawnedEvery240SecondsNeverActivatesE2() {
        var tracker = DescendantChurnTracker()
        var pid: Int32 = 5000
        var current = [info(pid, ["caffeinate", "-i", "-t", "300"], caffeinate: true)]
        var t: TimeInterval = 0
        while t <= 3600 {
            if t > 0, t.truncatingRemainder(dividingBy: 240) == 0 {
                pid += 1
                current = [info(pid, ["caffeinate", "-i", "-t", "300"], caffeinate: true)]
            }
            tracker.update(current: current, now: at(t))
            #expect(!tracker.isActive(now: at(t)), "E2 fired at t=\(t)")
            t += 5
        }
    }

    @Test func caffeinateExclusionDoesNotHideRealWork() {
        var tracker = DescendantChurnTracker()
        tracker.update(current: [], now: at(0))
        tracker.update(current: [info(40, ["caffeinate", "-i", "-t", "300"], caffeinate: true), info(41, ["git", "push"])], now: at(5))
        #expect(tracker.newDescendantCount(now: at(5)) == 1)
    }

    @Test func infrastructureDescendantsAreExcluded() {
        var tracker = DescendantChurnTracker()
        tracker.update(current: [], now: at(0))
        tracker.update(current: [info(50, ["claude bg-spare"], infra: true)], now: at(5))
        #expect(!tracker.isActive(now: at(5)))
    }

    @Test func sameArgvKeepAliveRespawnIsNotChurn() {
        var tracker = DescendantChurnTracker()
        let argv = ["node", "/x/mcp-server.js", "--port", "0"]
        tracker.update(current: [info(60, argv)], now: at(0)) // baseline
        tracker.update(current: [], now: at(5)) // it exits
        tracker.update(current: [info(61, argv)], now: at(10)) // respawned with the same argv
        #expect(!tracker.isActive(now: at(10)))
        // Respawn observed in the same sample as the predecessor's exit.
        tracker.update(current: [info(62, argv)], now: at(15))
        #expect(!tracker.isActive(now: at(15)))
    }

    @Test func respawnLoopEveryFewMinutesNeverActivates() {
        var tracker = DescendantChurnTracker()
        let argv = ["/usr/bin/some-keepalive", "--watch"]
        var pid: Int32 = 7000
        tracker.update(current: [info(pid, argv)], now: at(0))
        var t: TimeInterval = 5
        while t <= 1800 {
            if t.truncatingRemainder(dividingBy: 300) == 0 { pid += 1 }
            tracker.update(current: [info(pid, argv)], now: at(t))
            #expect(!tracker.isActive(now: at(t)), "fired at \(t)")
            t += 5
        }
    }

    @Test func differentArgvIsChurn() {
        var tracker = DescendantChurnTracker()
        tracker.update(current: [info(70, ["git", "status"])], now: at(0))
        tracker.update(current: [], now: at(5))
        tracker.update(current: [info(71, ["git", "commit", "-m", "x"])], now: at(10))
        #expect(tracker.isActive(now: at(10)))
    }

    @Test func respawnMemoryExpiresAfterTenMinutes() {
        var tracker = DescendantChurnTracker()
        let argv = ["npm", "test"]
        tracker.update(current: [info(80, argv)], now: at(0))
        tracker.update(current: [], now: at(5)) // exited at t=5
        tracker.update(current: [info(81, argv)], now: at(5 + 601)) // same command again 10 min later = real work
        #expect(tracker.isActive(now: at(606)))
    }

    @Test func argvKeyFallsBackToExecutableOrComm() {
        #expect(DescendantInfo.argvKey(executablePath: "/bin/sleep", argv: [], comm: "sleep") == "exe:/bin/sleep")
        #expect(DescendantInfo.argvKey(executablePath: nil, argv: [], comm: "login") == "exe:login")
        #expect(DescendantInfo.argvKey(executablePath: nil, argv: ["a", "b"], comm: "") != DescendantInfo.argvKey(
            executablePath: nil, argv: ["a b"], comm: ""))
    }
}

@Suite("Evidence E3–E6", .timeLimit(.minutes(1)))
struct OtherEvidenceTests {
    @Test func storeWriteRecency() {
        #expect(RecencyEvidence.storeWriteActive(lastWrite: at(0), now: at(60)))
        #expect(!RecencyEvidence.storeWriteActive(lastWrite: at(0), now: at(61)))
        #expect(RecencyEvidence.storeWriteActive(lastWrite: at(2), now: at(0))) // stamped slightly after `now`
        #expect(!RecencyEvidence.storeWriteActive(lastWrite: nil, now: at(0)))
    }

    @Test func ttyRecencyIsThirtySeconds() {
        #expect(RecencyEvidence.ttyActive(modified: at(0), now: at(30)))
        #expect(!RecencyEvidence.ttyActive(modified: at(0), now: at(31)))
        #expect(!RecencyEvidence.ttyActive(modified: nil, now: at(0)))
    }

    @Test func modelSocketsBaselineThenNewConnection() {
        var tracker = ModelSocketTracker()
        tracker.update(connections: ["a"], now: at(0))
        #expect(!tracker.isActive(now: at(0))) // existence alone is weak
        #expect(tracker.count == 1)
        tracker.update(connections: ["a"], now: at(5))
        #expect(!tracker.isActive(now: at(5)))
        tracker.update(connections: ["a", "b"], now: at(10))
        #expect(tracker.isActive(now: at(10)))
        #expect(tracker.isActive(now: at(70)))
        tracker.update(connections: ["a", "b"], now: at(71))
        #expect(!tracker.isActive(now: at(71)))
    }

    @Test func modelSocketCountChangeOrReplacementCounts() {
        var tracker = ModelSocketTracker()
        tracker.update(connections: ["a", "b"], now: at(0))
        tracker.update(connections: ["a"], now: at(5)) // count change
        #expect(tracker.isActive(now: at(5)))
        var replaced = ModelSocketTracker()
        replaced.update(connections: ["a"], now: at(0))
        replaced.update(connections: ["c"], now: at(5)) // same count, new connection
        #expect(replaced.isActive(now: at(5)))
        #expect(ModelSocketTracker().count == nil)
    }

    @Test func assertionOwnedByTheAgent() {
        let names = AssertionAttribution.names(
            forAgent: 100,
            assertionsByPID: [100: [PowerAssertionInfo(type: "PreventUserIdleSystemSleep", name: "Codex is running an active turn")]],
            caffeinateParents: [:])
        #expect(names == ["Codex is running an active turn"])
    }

    @Test func assertionOfACaffeinateChildOfTheAgent() {
        let assertions: [Int32: [PowerAssertionInfo]] = [
            200: [PowerAssertionInfo(type: "PreventUserIdleSystemSleep", name: "caffeinate command-line tool")],
            300: [PowerAssertionInfo(type: "PreventUserIdleSystemSleep", name: "caffeinate command-line tool")],
        ]
        // caffeinate 200 is the agent's child; caffeinate 300 belongs to someone else.
        let names = AssertionAttribution.names(forAgent: 100, assertionsByPID: assertions, caffeinateParents: [200: 100, 300: 999])
        #expect(names == ["caffeinate command-line tool"])
        let other = AssertionAttribution.names(forAgent: 101, assertionsByPID: assertions, caffeinateParents: [200: 100, 300: 999])
        #expect(other.isEmpty)
    }

    @Test func loneElectronAssertionNeverCounts() {
        let electron: [Int32: [PowerAssertionInfo]] = [100: [PowerAssertionInfo(type: "PreventUserIdleSystemSleep", name: "Electron")]]
        #expect(AssertionAttribution.names(forAgent: 100, assertionsByPID: electron, caffeinateParents: [:]).isEmpty)
        let mixed: [Int32: [PowerAssertionInfo]] = [100: [
            PowerAssertionInfo(type: "PreventUserIdleSystemSleep", name: " electron "),
            PowerAssertionInfo(type: "PreventUserIdleDisplaySleep", name: "Zed is generating"),
            PowerAssertionInfo(type: "x", name: ""),
        ]]
        #expect(AssertionAttribution.names(forAgent: 100, assertionsByPID: mixed, caffeinateParents: [:]) == ["Zed is generating"])
        let inputs = EvidenceInputs(cpu: .init(), churn: .init(), sockets: .init(), assertionNames: [])
        #expect(!inputs.sample(at: at(0)).active.contains(.powerAssertion))
    }

    @Test func assertionNamesAreCappedAndDeduplicated() {
        let long = String(repeating: "x", count: 500)
        let names = AssertionAttribution.names(
            forAgent: 1,
            assertionsByPID: [1: [PowerAssertionInfo(type: "a", name: long), PowerAssertionInfo(type: "b", name: long)]],
            caffeinateParents: [:])
        #expect(names.count == 1)
        #expect(names[0].count == 140)
    }

    @Test func sampleAssemblesEveryKind() {
        var cpu = TreeCPUAccumulator()
        cpu.record(members: [(id(1), 0)], now: at(0))
        cpu.record(members: [(id(1), 6)], now: at(60))
        var churn = DescendantChurnTracker()
        churn.update(current: [], now: at(0))
        churn.update(current: [DescendantInfo(identity: id(2), argvKey: "git")], now: at(60))
        var sockets = ModelSocketTracker()
        sockets.update(connections: [], now: at(0))
        sockets.update(connections: ["x"], now: at(60))
        let sample = EvidenceInputs(
            cpu: cpu, churn: churn, sockets: sockets, lastStoreWrite: at(50), ttyModified: at(45),
            assertionNames: ["caffeinate command-line tool"]
        ).sample(at: at(60))
        #expect(sample.active == Set(EvidenceKind.allCases))
        #expect(sample.sampledAt == at(60))
        #expect(sample.newDescendantCount == 1)
        #expect(sample.modelSocketCount == 1)
        #expect(sample.lastStoreWriteAt == at(50))
        #expect(sample.ttyLastActivityAt == at(45))
        #expect(sample.treeCPUSeconds == 6)
        #expect(sample.meetsHeuristicThreshold)
        #expect(sample.showsProgress)
    }

    @Test func powerAssertionAloneIsNotProgress() {
        let sample = EvidenceInputs(cpu: .init(), churn: .init(), sockets: .init(), assertionNames: ["caffeinate command-line tool"])
            .sample(at: at(0))
        #expect(sample.active == [.powerAssertion])
        #expect(!sample.showsProgress)
        #expect(!sample.meetsHeuristicThreshold)
    }
}
