import KakurenekoKit
import KakurenekoPause
import Foundation
import Testing

@Suite("KakurenekoPause smoke", .timeLimit(.minutes(1)))
struct PauseSmokeTests {
    /// The public surface compiles against the Kit contract (binding signatures).
    @Test func pauseManagerConformsToContract() async throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let ledger = DryRunLedger()
        let manager: any AppPausing = PauseManager(
            paths: paths, signaller: DryRunProcessSignaller(gate: .alwaysOn(), ledger: ledger),
            processes: StaticProcessLookup(), dryRun: .alwaysOn(), guardExecutable: nil, clock: TestClock())
        #expect(await manager.pausedApps().isEmpty)
        #expect(await manager.recoverFromJournal() == 0)
        let _: any ProcessSignalling = AuditTokenSignaller()
        #expect(PauseGuard.defaultHangTimeout == .seconds(90))
    }

    @Test func guardBinaryExitsZero() async throws {
        let guardURL = Products.guardExecutable
        try #require(FileManager.default.isExecutableFile(atPath: guardURL.path(percentEncoded: false)), "build the kakureneko-guard product first")
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let result = try await FoundationSubprocessRunner().run(SubprocessRequest(
            executable: guardURL.path(percentEncoded: false),
            arguments: ["--recover", "--journal", paths.pauseJournalFile.path(percentEncoded: false),
                        "--log", paths.guardLogFile.path(percentEncoded: false), "--dry-run"],
            environment: paths.helperEnvironment, // HOME + KAKURENEKO_HOME: never the real ~/.kakureneko
            timeout: .seconds(5),
            effect: .readOnly
        ))
        #expect(result.exitCode == 0)
    }

    @Test func guardExitsZeroOnBadArguments() async throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let result = try await FoundationSubprocessRunner().run(SubprocessRequest(
            executable: Products.guardExecutable.path(percentEncoded: false),
            arguments: ["--bogus", "--log", paths.guardLogFile.path(percentEncoded: false)],
            environment: paths.helperEnvironment,
            timeout: .seconds(5),
            effect: .readOnly
        ))
        #expect(result.exitCode == 0)
        let log = (try? String(contentsOf: paths.guardLogFile, encoding: .utf8)) ?? ""
        #expect(log.contains("bad arguments"))
    }
}
