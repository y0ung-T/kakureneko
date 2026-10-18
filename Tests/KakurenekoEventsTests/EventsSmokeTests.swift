import KakurenekoEvents
import KakurenekoKit
import Foundation
import Testing

/// Public-surface smoke tests: only what the coordinator can see (`EventInbox` through `AgentEventSource`).
@Suite("KakurenekoEvents smoke", .timeLimit(.minutes(1)))
struct EventsSmokeTests {
    @Test func eventInboxConformsToContract() async throws {
        let home = try TempHome()
        let inbox: any AgentEventSource = EventInbox(paths: home.paths, matcher: BasicAgentSignatureMatcher(), clock: TestClock())
        let recorder = EventRecorder(inbox.events()) // subscribe BEFORE start (the launch drain goes to existing subscribers)
        try await inbox.start()
        #expect(await inbox.drainNow().isEmpty)
        await inbox.stop()
        #expect(await recorder.waitForFinish(), "stop() finishes every stream")
        #expect(recorder.events.isEmpty)
    }

    /// Hook contract (brief §4.2): exit 0, empty stdout, empty stderr — even for a normal Stop event.
    @Test func hookBinaryHonoursExitAndOutputContract() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Products.hookPath), "build the kakureneko-hook product first")
        let home = try TempHome()
        // Hook tests ALWAYS set both inbox overrides (never the real per-user fallback inbox).
        let result = await HookRunner.run(["claude", "Stop"], environment: home.hookEnvironment(),
                                          stdin: .data(Data(#"{"session_id":"s1","hook_event_name":"Stop"}"#.utf8)))
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
        #expect(InboxFiles.eventFiles(in: home.paths.inboxDirectory).count == 1)
    }
}
