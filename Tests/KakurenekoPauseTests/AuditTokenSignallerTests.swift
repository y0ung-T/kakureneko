import Darwin
import KakurenekoKit
@testable import KakurenekoPause
import Foundation
import Testing

/// The real `AuditTokenSignaller` — ONLY against `/bin/sleep` children this test spawned itself.
@Suite("AuditTokenSignaller (spawned children only)", .timeLimit(.minutes(1)))
struct AuditTokenSignallerTests {
    let signaller = AuditTokenSignaller()

    @Test func stopAndContinueAnEnrichedChild() async throws {
        let child = try SpawnedChild.sleep()
        defer { child.terminate() }
        let target = try child.enriched
        #expect(target.pidVersion != nil && target.uniqueID != nil)

        try signaller.send(.stop, to: target)
        #expect(await eventually { child.isStopped }, "p_stat == SSTOP after SIGSTOP")
        try signaller.send(.cont, to: target)
        #expect(await eventually { !child.isStopped }, "running again after SIGCONT")
        #expect(child.isAlive)
    }

    @Test func darwinBackgroundRoundTrip() throws {
        let child = try SpawnedChild.sleep()
        defer { child.terminate() }
        let target = try child.enriched
        #expect(signaller.isDarwinBackground(target) == false)

        try signaller.setDarwinBackground(true, for: target)
        #expect(signaller.isDarwinBackground(target) == true)
        // An EXTERNAL darwinbg (setpriority from another process) shows in pbi_flags (PROC_FLAG_EXT_DARWINBG) —
        // `getpriority(PRIO_DARWIN_PROCESS, otherPid)` reports only the target's own request and stays 0.
        #expect(Kernel.isExternallyDarwinBackground(child.pid) == true)
        errno = 0
        let priority = getpriority(PRIO_DARWIN_PROCESS, id_t(child.pid))
        #expect(errno == 0 && (priority == 0 || priority == 1))

        try signaller.setDarwinBackground(false, for: target)
        #expect(signaller.isDarwinBackground(target) == false)
        #expect(Kernel.isExternallyDarwinBackground(child.pid) == false)
    }

    @Test func pausingCallsRefuseUnenrichedIdentities() async throws {
        let child = try SpawnedChild.sleep()
        defer { child.terminate() }
        let plain = try child.identity
        #expect(plain.pidVersion == nil && plain.uniqueID == nil)

        #expect(throws: SideEffectError.identityMismatch) { try signaller.send(.stop, to: plain) }
        #expect(throws: SideEffectError.identityMismatch) { try signaller.setDarwinBackground(true, for: plain) }
        #expect(!child.isStopped)
        #expect(signaller.isDarwinBackground(plain) == false)

        // Thawing calls verify whatever is known: an un-enriched identity may still be continued/unthrottled.
        await child.stop()
        try signaller.send(.cont, to: plain)
        #expect(await eventually { !child.isStopped })
        try signaller.setDarwinBackground(false, for: plain)
    }

    @Test func wrongIdentityThrowsAndSendsNothing() async throws {
        let child = try SpawnedChild.sleep()
        defer { child.terminate() }
        let good = try child.enriched

        var wrongStart = good
        wrongStart.startUsec = good.startUsec == 0 ? 1 : 0
        #expect(throws: SideEffectError.identityMismatch) { try signaller.send(.stop, to: wrongStart) }
        #expect(throws: SideEffectError.identityMismatch) { try signaller.setDarwinBackground(true, for: wrongStart) }

        var wrongVersion = good
        wrongVersion.pidVersion = good.pidVersion.map { $0 &+ 1 }
        #expect(throws: SideEffectError.identityMismatch) { try signaller.send(.stop, to: wrongVersion) }
        #expect(throws: SideEffectError.identityMismatch) { try signaller.setDarwinBackground(true, for: wrongVersion) }

        var wrongUnique = good
        wrongUnique.uniqueID = good.uniqueID.map { $0 &+ 1 }
        #expect(throws: SideEffectError.identityMismatch) { try signaller.send(.stop, to: wrongUnique) }

        try? await Task.sleep(for: .milliseconds(30))
        #expect(!child.isStopped, "nothing was sent")
        #expect(signaller.isDarwinBackground(good) == false)
        #expect(signaller.isDarwinBackground(wrongStart) == nil, "read-only check also verifies the identity")
    }

    @Test func goneProcessReportsProcessGone() async throws {
        let child = try SpawnedChild.sleep()
        let target = try child.enriched
        child.terminate()
        #expect(throws: SideEffectError.processGone) { try signaller.send(.cont, to: target) }
        #expect(throws: SideEffectError.processGone) { try signaller.send(.stop, to: target) }
        #expect(throws: SideEffectError.processGone) { try signaller.setDarwinBackground(false, for: target) }
        #expect(signaller.isDarwinBackground(target) == nil)
    }

    @Test func verifiedTokenCarriesPidVersion() throws {
        let child = try SpawnedChild.sleep()
        defer { child.terminate() }
        let target = try child.enriched
        let token = try AuditTokenSignaller.verifiedToken(for: target)
        #expect(Int32(bitPattern: token.val.5) == child.pid)
        #expect(token.val.7 == target.pidVersion)
    }

    /// The fallback token (pid + pidversion only) is accepted by `proc_signal_with_audittoken`, and a stale
    /// pidversion is rejected with ESRCH — the property the signaller relies on when `task_name_for_pid` is refused.
    @Test func synthesizedTokenIsRaceFree() async throws {
        let child = try SpawnedChild.sleep()
        defer { child.terminate() }
        let target = try child.enriched
        let version = try #require(target.pidVersion)

        var stale = Kernel.synthesizedToken(pid: child.pid, pidVersion: version &+ 1)
        let rejected = proc_signal_with_audittoken(&stale, SIGSTOP)
        #expect(rejected != 0)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!child.isStopped)

        var token = Kernel.synthesizedToken(pid: child.pid, pidVersion: version)
        #expect(proc_signal_with_audittoken(&token, SIGSTOP) == 0)
        #expect(await eventually { child.isStopped })
        #expect(proc_signal_with_audittoken(&token, SIGCONT) == 0)
        #expect(await eventually { !child.isStopped })
    }

    @Test func relaunchRefusesNonApplicationURLs() async throws {
        // Never launches anything: the URL is rejected before NSWorkspace is asked.
        await #expect(throws: SideEffectError.self) {
            try await signaller.relaunchApplication(at: URL(filePath: "/bin/sleep"))
        }
        await #expect(throws: SideEffectError.self) {
            try await signaller.relaunchApplication(at: URL(filePath: "/nonexistent/Nothing.app", directoryHint: .isDirectory))
        }
    }
}
