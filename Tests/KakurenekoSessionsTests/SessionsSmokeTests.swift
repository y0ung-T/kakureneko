import KakurenekoKit
import KakurenekoSessions
import Foundation
import Testing

@Suite("KakurenekoSessions smoke", .timeLimit(.minutes(1)))
struct SessionsSmokeTests {
    @Test func engineAndWatcherConformToContract() async throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let engine: any SessionTracking = SessionEngine(timers: SessionTimers())
        _ = engine.tick(now: Date())
        let watcher: any ClaudeStateSource = ClaudeStateWatcher(
            paths: paths, subprocess: FakeSubprocessRunner(), processes: StaticProcessLookup(), clock: TestClock())
        _ = await watcher.current()
    }
}
