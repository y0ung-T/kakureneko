import KakurenekoKit
import KakurenekoPower
import Foundation
import Testing

@Suite("KakurenekoPower smoke", .timeLimit(.minutes(1)))
struct PowerSmokeTests {
    /// Builds every Power type with dry-run side effects only (nothing here may touch pmset or sleep).
    @Test func typesConformToContract() async throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let ledger = DryRunLedger()
        let effects = SideEffects.inert(ledger: ledger)
        let power: any PowerControlling = PowerController(
            paths: paths, privileged: effects.privileged, systemSleep: effects.systemSleep, shutdown: effects.shutdown,
            displaySleep: effects.displaySleep, dryRun: .alwaysOn(), clock: TestClock())
        let _: any PowerEventSource = PowerMonitor(power: power, clock: TestClock())
        let _: any SafetyEvaluating = SafetyMonitor()
        let _: any PrivilegedInstalling = PrivilegedInstaller(
            paths: paths, privileged: effects.privileged, subprocess: FakeSubprocessRunner(), administrator: effects.administrator, clock: TestClock())
        // Real side-effect types exist with the binding initializers (constructed, never invoked).
        let fake = FakeSubprocessRunner()
        let _: any PrivilegedCommandRunning = SudoPrivilegedCommandRunner(subprocess: fake)
        let _: any SystemSleeping = IOPMSystemSleeper(subprocess: fake)
        let _: any ShutdownRequesting = LoginWindowShutdownRequester()
        let _: any DisplaySleeping = PmsetDisplaySleeper(subprocess: fake)
        let _: any AdministratorScriptRunning = AppleScriptAdministratorRunner()
    }
}
