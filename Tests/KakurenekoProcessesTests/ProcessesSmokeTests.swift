import KakurenekoKit
import KakurenekoProcesses
import Foundation
import Testing

@Suite("KakurenekoProcesses smoke", .timeLimit(.minutes(1)))
struct ProcessesSmokeTests {
    @Test func scannerConformsToContract() async throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let matcher = AgentMatcher(paths: paths)
        let scanner: any ProcessSampling = ProcessScanner(paths: paths, matcher: matcher, clock: TestClock())
        let now = Date()
        let snapshot = await scanner.sample(now: now)
        let topology = await scanner.topology(for: snapshot, now: now)
        #expect(topology.builtAt == now)
        let _: any AgentSignatureMatching = matcher
        let _: any ProcessLookup = LiveProcessLookup()
    }
}
