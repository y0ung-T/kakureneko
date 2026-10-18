import KakurenekoInstall
import KakurenekoKit
import Foundation
import Testing

@Suite("KakurenekoInstall smoke", .timeLimit(.minutes(1)))
struct InstallSmokeTests {
    /// Temp home + fake subprocess runner: never touches the real ~/.claude, ~/.codex, …
    @Test func managerConformsToContract() async throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let manager: any AgentIntegrating = IntegrationManager(
            paths: paths, subprocess: FakeSubprocessRunner(), dryRun: .off(), ledger: DryRunLedger(), clock: TestClock())
        _ = await manager.statuses()
    }
}
