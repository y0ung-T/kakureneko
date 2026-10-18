// LidSimulation: the dry-run-only developer tool that makes Kakureneko see a closed lid. Temp control files only; the
// monitor runs on a TestClock with manual observers (nothing touches the system).

@testable import KakurenekoPower
import KakurenekoKit
import Foundation
import Testing

@Suite("Lid simulation (dry-run developer tool)", .timeLimit(.minutes(1)))
struct LidSimulationTests {
    private func makeControlFile() throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kakureneko-lidsim-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appending(path: "lid", directoryHint: .notDirectory))
    }

    @Test func honouredOnlyWhenTheEnvironmentForcesDryRun() {
        let key = KakurenekoEnvironment.simulateLid
        #expect(LidSimulation.fromEnvironment([key: "/tmp/lid"]) == nil)
        #expect(LidSimulation.fromEnvironment([key: "/tmp/lid", KakurenekoEnvironment.dryRun: "0"]) == nil)
        #expect(LidSimulation.fromEnvironment([key: "relative/lid", KakurenekoEnvironment.dryRun: "1"]) == nil)
        #expect(LidSimulation.fromEnvironment([KakurenekoEnvironment.dryRun: "1"]) == nil)
        let simulation = LidSimulation.fromEnvironment([key: "/tmp/lid", KakurenekoEnvironment.dryRun: "yes"])
        #expect(simulation?.controlFile.path(percentEncoded: false) == "/tmp/lid")
    }

    @Test func readingsFollowTheControlFile() throws {
        let (directory, file) = try makeControlFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let simulation = LidSimulation(controlFile: file)

        // No file: every reading passes through.
        #expect(!simulation.isSimulatingClosed)
        #expect(simulation.clamshellClosed(real: false) == false)
        #expect(simulation.clamshellClosed(real: nil) == nil)
        #expect(simulation.externalDisplayConnected(real: true))
        #expect(simulation.secondsSinceUserInput(real: 3) == 3)

        try " Closed\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)],
                                              ofItemAtPath: file.path(percentEncoded: false))
        #expect(simulation.isSimulatingClosed)
        #expect(simulation.clamshellClosed(real: false) == true)
        #expect(simulation.clamshellClosed(real: nil) == true)
        #expect(!simulation.externalDisplayConnected(real: true))
        let idle = try #require(simulation.secondsSinceUserInput(real: 0.5))
        #expect(idle >= 120 + LidSimulation.simulatedIdleBeforeClose && idle < 600 + LidSimulation.simulatedIdleBeforeClose,
                "the last input happened a day before the control file was written")
        #expect(SimulatedRootDomain(base: FakeRootDomain(sleepDisabled: true, clamshellClosed: false), simulation: simulation)
            .clamshellClosed() == true)
        #expect(SimulatedRootDomain(base: FakeRootDomain(sleepDisabled: true, clamshellClosed: false), simulation: simulation)
            .sleepDisabled() == true, "the kernel flag is never simulated here")
        #expect(!SimulatedDisplayReader(base: FakeDisplays(true), simulation: simulation).externalDisplayConnected())

        for other in ["open", "", "closed-ish", "yes"] {
            try other.write(to: file, atomically: true, encoding: .utf8)
            #expect(!simulation.isSimulatingClosed, "\(other)")
            #expect(SimulatedInputReader(base: FakeInput(2), simulation: simulation).secondsSinceUserInput() == 2)
            #expect(SimulatedDisplayReader(base: FakeDisplays(true), simulation: simulation).externalDisplayConnected())
        }
    }

    @Test func aRealClamshellMessageNeverReopensASimulatedClosedLid() async throws {
        let (directory, file) = try makeControlFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "closed".write(to: file, atomically: true, encoding: .utf8)
        let simulation = LidSimulation(controlFile: file)
        let clock = TestClock()
        let power = FakePowerController(clock: clock)
        power.setLidClosed(true) // what a PowerController built with the same simulation reports
        let observer = ManualObserver()
        let monitor = PowerMonitor(
            power: power, clock: clock, logger: KakurenekoLogger(.power), observers: [observer],
            displays: SimulatedDisplayReader(base: FakeDisplays(true), simulation: simulation),
            input: SimulatedInputReader(base: FakeInput(0), simulation: simulation),
            lidSimulation: simulation
        )
        let recorder = EventRecorder(monitor.events())
        defer { recorder.cancel() }
        await monitor.start()
        #expect(await recorder.wait { !$0.snapshots.isEmpty })
        #expect(recorder.snapshots.first?.lid == .closed)
        #expect(recorder.snapshots.first?.externalDisplayConnected == false)

        observer.deliver(.clamshellMessage(closed: false)) // the real (open) lid, e.g. on an AC change
        observer.deliver(.willPowerOff) // marker: everything delivered before it was processed
        #expect(await recorder.wait { $0.all.contains(.willPowerOff) })
        #expect(recorder.lidEdges.isEmpty, "the simulated closed lid holds")
        await monitor.stop()
    }

    /// Clamshell mode: the REAL lid is already closed (external display), so the monitor's `lidClosedSince` predates
    /// the control file. Writing `closed` must read as "display gone, nobody here", never as closed-lid user input.
    @Test func simulatingOnAClamshellMacReportsNoClosedLidInput() async throws {
        let (directory, file) = try makeControlFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "open".write(to: file, atomically: true, encoding: .utf8)
        let simulation = LidSimulation(controlFile: file)
        let clock = TestClock()
        let power = FakePowerController(clock: clock)
        power.setLidClosed(true) // really closed
        let observer = ManualObserver()
        let monitor = PowerMonitor(
            power: power, clock: clock, logger: KakurenekoLogger(.power), observers: [observer],
            displays: SimulatedDisplayReader(base: FakeDisplays(true), simulation: simulation),
            input: SimulatedInputReader(base: FakeInput(0.5), simulation: simulation),
            lidSimulation: simulation
        )
        let recorder = EventRecorder(monitor.events())
        defer { recorder.cancel() }
        await monitor.start()
        #expect(await recorder.wait { !$0.snapshots.isEmpty })

        try "closed".write(to: file, atomically: true, encoding: .utf8)
        for _ in 0..<12 { // a dozen 1 Hz polls
            _ = await waitUntil { clock.sleeperCount >= MonitorRig.baseSleepers }
            clock.advance(by: .seconds(1))
        }
        #expect(await recorder.wait { $0.displayEdges == [false] })
        observer.deliver(.willPowerOff)
        #expect(await recorder.wait { $0.all.contains(.willPowerOff) })
        #expect(recorder.userActivities.isEmpty, "no closed-lid input is simulated")
        #expect(recorder.lidEdges.isEmpty)
        await monitor.stop()
    }
}
