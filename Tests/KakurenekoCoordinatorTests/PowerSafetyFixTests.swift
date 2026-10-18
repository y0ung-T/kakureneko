@testable import KakurenekoCoordinator
import KakurenekoKit
import Foundation
import Synchronization
import Testing

/// Forwards to the fake installer; while `park` is set, `healthCheck` waits until `release`.
final class ParkingPrivilegedInstaller: PrivilegedInstalling {
    let base: FakePrivilegedInstaller
    private let state = Mutex<(park: Bool, parked: Bool, released: Bool)>((false, false, false))
    init(base: FakePrivilegedInstaller) { self.base = base }

    func armParking() { state.withLock { $0.park = true } }
    var isParked: Bool { state.withLock { $0.parked } }
    func release() { state.withLock { $0.released = true } }

    func healthCheck() async -> PrivilegedStatus {
        let park = state.withLock { s -> Bool in
            guard s.park else { return false }
            s.parked = true
            return true
        }
        if park {
            while !state.withLock({ $0.released }) { try? await Task.sleep(for: .milliseconds(1)) }
        }
        return await base.healthCheck()
    }
    func install() async throws { try await base.install() }
    func uninstall() async throws { try await base.uninstall() }
    func scripts() -> PrivilegedScripts { base.scripts() }
}

/// Regression tests for the power-safety review at the coordinator level (each failed before its fix).
@Suite("Power safety fixes (coordinator)", .timeLimit(.minutes(1)))
struct CoordinatorPowerSafetyFixTests {
    /// Dry-run on with a missing install (simulated `.full`); turning dry-run off while an agent works: a tick while
    /// the fresh health check is in flight used to arm FOR REAL on the stale simulated status.
    @Test func turningDryRunOffNeverArmsForRealOnTheSimulatedStatus() async throws {
        var settings = KakurenekoSettings.default
        settings.general.dryRun = true
        let power = Ref<GateObservingPower>()
        let parking = Ref<ParkingPrivilegedInstaller>()
        try await withHarness(settings: settings, privileged: notInstalled, configure: { services, fakes in
            let observed = GateObservingPower(base: fakes.power, gate: fakes.dryRun)
            let parked = ParkingPrivilegedInstaller(base: fakes.privileged)
            services.power = observed
            services.privileged = parked
            power.value = observed
            parking.value = parked
        }) { h in
            let power = try #require(power.value)
            let parking = try #require(parking.value)
            await h.start()
            #expect(await h.snapshot().privileged.simulated)
            _ = await h.startWorking()
            #expect(power.observed.contains("arm gate=true"))

            parking.armParking()
            var next = await h.snapshot().settings
            next.general.dryRun = false
            let coordinator = h.coordinator
            let update = Task { [next] in await coordinator.updateSettings(next) }
            #expect(await waitUntil { parking.isParked })
            await h.tick() // a tick while the health check is in flight
            parking.release()
            await update.value
            await h.tick()
            #expect(!power.observed.contains("arm gate=false"))
            #expect(await h.snapshot().mode == .notificationsOnly)
        }
    }

    /// Lid physically closed with a (possibly virtual/AirPlay) display attached, nobody at the Mac: the closed-lid
    /// guards used to be skipped entirely (effectively "open"). A trip now winds down and sleeps.
    @Test func aClosedLidWithADisplayAttachedStillHasTheClosedLidGuardsWhileAway() async throws {
        try await withHarness { h in
            await h.start()
            _ = await h.startWorking()
            await h.closeLid(lastInputAgo: 900, external: true)
            #expect(await h.phase() == .armed(since: h.now))
            h.fakes.safety.setTrip(.maxDuration(hours: 12))
            await h.advanceAndTick(15)
            #expect(h.intentKinds.contains(.safetyTrip))
            await h.passThawSettle()
            #expect(await waitUntil { h.fakes.power.count(.sleep) == 1 })
        }
    }

    /// The same with someone using the Mac (a real clamshell desk): no trip action.
    @Test func aClamshellDeskInUseIsNotPutToSleepByTheClosedLidGuards() async throws {
        try await withHarness { h in
            await h.start()
            _ = await h.startWorking()
            await h.closeLid(lastInputAgo: 5, external: true)
            h.fakes.safety.setTrip(.maxDuration(hours: 12))
            h.power.lastInputAt = h.now
            await h.advanceAndTick(15)
            #expect(!h.intentKinds.contains(.safetyTrip))
            #expect((await h.phase()).label == "armed")
            #expect(h.fakes.power.count(.sleep) == 0)
        }
    }

    /// The app's last-resort quit path thaws, then disarms, synchronously (never through the actor).
    @Test func terminateSynchronouslyThawsThenDisarms() async throws {
        try await withHarness { h in
            await h.start()
            _ = await h.startWorking()
            h.coordinator.terminateSynchronously()
            #expect(h.log.filtered(["pause.thawAllSynchronously(appQuitting)", "power.disarmSync"])
                    == ["pause.thawAllSynchronously(appQuitting)", "power.disarmSync"])
        }
    }
}
