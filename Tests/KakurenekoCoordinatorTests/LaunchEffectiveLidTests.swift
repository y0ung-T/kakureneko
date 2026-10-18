// Launch on a clamshell desk (lid closed, external display): a session ingested while `start()` brings the services
// up must be evaluated with the lid effectively OPEN. Found in a dry-run launch: the first Claude record scan arrived
// before the first power snapshot, and the coordinator went disarmed → closedAwake → armed within 6 ms.

@testable import KakurenekoCoordinator
import KakurenekoKit
import Foundation
import Synchronization
import Testing

/// Delivers one snapshot from `start()` and returns only after the coordinator handled it, recording the power phase
/// at that moment, so the ingest lands in the middle of `start()` (deterministically, unlike the live watcher).
private final class EagerClaudeStateSource: ClaudeStateSource {
    private let base: FakeClaudeStateSource
    private let snapshot: ClaudeStateSnapshot
    private let coordinator = Mutex<KakurenekoCoordinator?>(nil)
    private let phase = Mutex<PowerPhase?>(nil)

    init(base: FakeClaudeStateSource, snapshot: ClaudeStateSnapshot) {
        self.base = base
        self.snapshot = snapshot
    }

    func attach(_ coordinator: KakurenekoCoordinator) { self.coordinator.withLock { $0 = coordinator } }
    var phaseWhenHandled: PowerPhase? { phase.withLock { $0 } }

    func start() async {
        await base.start()
        guard let coordinator = coordinator.withLock({ $0 }) else { return }
        base.emit(snapshot)
        guard await waitUntil({ await coordinator.handled.claudeSnapshots > 0 }) else { return }
        let current = await coordinator.machine.phase
        phase.withLock { $0 = current }
    }

    func stop() async { await base.stop() }
    func snapshots() -> AsyncStream<ClaudeStateSnapshot> { base.snapshots() }
    func current() async -> ClaudeStateSnapshot { await base.current() }
    func setCadence(_ cadence: SamplingCadence) async { await base.setCadence(cadence) }
}

@Suite("Launch: effective lid before the first snapshot", .timeLimit(.minutes(1)))
struct LaunchEffectiveLidTests {
    @Test func aSessionIngestedDuringStartOnAClamshellDeskIsNeverClosedLid() async throws {
        var eager: EagerClaudeStateSource?
        try await withHarness(configure: { services, fakes in
            let source = EagerClaudeStateSource(
                base: fakes.claudeState,
                snapshot: ClaudeStateSnapshot(takenAt: fakes.clock.now(), sessions: [], agents: nil, agentsPolledAt: nil,
                                              sessionsDirectoryReadable: true, ignoredIdentities: []))
            eager = source
            services.claudeState = source
        }) { h in
            let source = try #require(eager)
            source.attach(h.coordinator)
            h.power.lid = .closed
            h.power.externalDisplay = true
            h.scriptPower()
            h.setSessions([Fixture.session("s1", state: .working(since: h.now), agentPID: 100, hostPID: 4242,
                                           turnStartedAt: h.now)])
            await h.start()

            let phase = try #require(source.phaseWhenHandled, "the snapshot was not handled during start()")
            #expect(phase.label == "armed", "clamshell desk: the lid is effectively open (was \(phase.label))")
            #expect(await h.phase().label == "armed")
            #expect(await !h.coordinator.effectiveLidClosed)
        }
    }

    @Test func aReallyClosedLidWithoutADisplayIsClosedFromTheStart() async throws {
        var eager: EagerClaudeStateSource?
        try await withHarness(configure: { services, fakes in
            let source = EagerClaudeStateSource(
                base: fakes.claudeState,
                snapshot: ClaudeStateSnapshot(takenAt: fakes.clock.now(), sessions: [], agents: nil, agentsPolledAt: nil,
                                              sessionsDirectoryReadable: true, ignoredIdentities: []))
            eager = source
            services.claudeState = source
        }) { h in
            let source = try #require(eager)
            source.attach(h.coordinator)
            h.power.lid = .closed
            h.power.externalDisplay = false
            h.scriptPower()
            h.setSessions([Fixture.session("s1", state: .working(since: h.now), agentPID: 100, hostPID: 4242,
                                           turnStartedAt: h.now)])
            await h.start()

            #expect(source.phaseWhenHandled?.label == "closedAwake")
            #expect(await h.phase().label == "closedAwake")
        }
    }
}
