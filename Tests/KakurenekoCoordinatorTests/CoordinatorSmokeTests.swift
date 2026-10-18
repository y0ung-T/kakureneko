import KakurenekoCoordinator
import KakurenekoKit
import Foundation
import Testing

@Suite("KakurenekoCoordinator smoke", .timeLimit(.minutes(1)))
struct CoordinatorSmokeTests {
    /// The coordinator runs entirely on Kit fakes (FakeServiceSet): no real side effects.
    @Test func coordinatorPublishesSnapshots() async throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let fakes = FakeServiceSet(paths: paths)
        let coordinator = KakurenekoCoordinator(services: fakes.services, settings: .default)
        let controller: any KakurenekoControlling = coordinator
        var iterator = controller.snapshots().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.mode == .starting)
        await controller.keepAwake(for: 600)
        let next = await iterator.next()
        #expect(next?.keepAwakeUntil == fakes.clock.now().addingTimeInterval(600))
    }

    /// The live composition root builds with KAKURENEKO_DRY_RUN and a fake home (nothing is started).
    @Test func liveCompositionBuildsInDryRun() throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let services = KakurenekoCoordinator.makeLiveServices(
            environment: ["KAKURENEKO_DRY_RUN": "1", "KAKURENEKO_HOME": paths.home.path(percentEncoded: false)],
            bundleURL: URL(filePath: "/tmp/NotABundle"))
        #expect(services.dryRun.isOn && services.dryRun.isForcedByEnvironment)
        #expect(services.paths.home == paths.home)
        #expect(services.bundledHookHelper == nil)
    }

    /// Composition wiring (LiveComposition rules 6–7): the controller records its dry-run-only decisions in the ONE
    /// shared ledger, helpers come from `Contents/Helpers`, and the settings-requested dry-run is not applied before
    /// `start()` (journal recovery and the kernel-flag reconcile undo a crashed real run for real). Nothing is
    /// started; with `KAKURENEKO_DRY_RUN=1` forced, `touchHeartbeat()` (never really armed) only writes the ledger.
    @Test func liveCompositionWiresTheSharedLedgerAndAppliesSettingsDryRunAtStart() throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let home = paths.home.path(percentEncoded: false)
        var settings = KakurenekoSettings.default
        settings.general.dryRun = true
        try settings.save(to: paths.settingsFile)
        let bundle = paths.home.deletingLastPathComponent().appending(path: "Kakureneko.app", directoryHint: .isDirectory)

        let forced = KakurenekoCoordinator.makeLiveServices(
            environment: ["KAKURENEKO_DRY_RUN": "1", "KAKURENEKO_HOME": home, "HOME": home], bundleURL: bundle)
        #expect(forced.bundledHookHelper?.path(percentEncoded: false).hasSuffix("Kakureneko.app/Contents/Helpers/kakureneko-hook") == true)
        #expect(forced.bundledGuardHelper?.path(percentEncoded: false).hasSuffix("Kakureneko.app/Contents/Helpers/kakureneko-guard") == true)
        try forced.power.touchHeartbeat()
        #expect(forced.ledger.entries.map(\.action).contains("power.heartbeat"))
        #expect(!FileManager.default.fileExists(atPath: forced.paths.heartbeatFile.path(percentEncoded: false)))
        #expect(forced.handlesTerminationSignals)

        // Without the environment override, settings' dry-run waits for start() step 6.
        let requested = KakurenekoCoordinator.makeLiveServices(environment: ["KAKURENEKO_HOME": home, "HOME": home], bundleURL: bundle)
        #expect(!requested.dryRun.isOn)
        #expect(!requested.dryRun.isForcedByEnvironment)
    }
}
