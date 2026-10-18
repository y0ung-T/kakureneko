import AppKit
import Darwin
import KakurenekoKit
import Foundation

/// Real signaller: `task_name_for_pid` + `task_info(TASK_AUDIT_TOKEN)` → `proc_signal_with_audittoken`,
/// `setpriority(PRIO_DARWIN_PROCESS, …)`, `NSRunningApplication.terminate()`,
/// `NSWorkspace.openApplication(at:configuration:)` (activates = false).
///
/// Every call re-verifies the target first — live start time (pid reuse), `p_uniqueid` (flavor 17) and a fresh
/// audit token whose `val[7]` equals the known pidversion — and throws `.identityMismatch` / `.processGone` instead
/// of acting. Pausing calls (`send(.stop)`, `setDarwinBackground(true)`) refuse un-enriched identities outright.
/// Never raw `kill`, never `SIGTSTP`. The coordinator wraps this in `DryRunProcessSignaller` (dry-run gate).
public struct AuditTokenSignaller: ProcessSignalling {
    /// Binding signature.
    public init() {}

    public func send(_ signal: ProcessSignalKind, to target: ProcessIdentity) throws {
        if signal == .stop, !target.isEnriched { throw SideEffectError.identityMismatch }
        var token = try Self.verifiedToken(for: target)
        let rc = proc_signal_with_audittoken(&token, signal == .stop ? SIGSTOP : SIGCONT)
        guard rc == 0 else { throw Self.signalError(code: rc > 0 ? rc : errno, target: target) }
    }

    public func setDarwinBackground(_ enabled: Bool, for target: ProcessIdentity) throws {
        if enabled, !target.isEnriched { throw SideEffectError.identityMismatch }
        _ = try Self.verifiedToken(for: target)
        // setpriority has no audit-token variant: verify before, act, verify again (and undo a throttle that hit a
        // process which reused the pid in between — practically impossible, but cheap to rule out).
        if setpriority(PRIO_DARWIN_PROCESS, id_t(target.pid), enabled ? PRIO_DARWIN_BG : 0) != 0 {
            throw Self.signalError(code: errno, target: target)
        }
        guard let after = Kernel.entry(of: target.pid) else { throw SideEffectError.processGone }
        guard after.identity == target else {
            if enabled { _ = setpriority(PRIO_DARWIN_PROCESS, id_t(target.pid), 0) }
            throw SideEffectError.identityMismatch
        }
    }

    public func isDarwinBackground(_ target: ProcessIdentity) -> Bool? {
        guard Kernel.entry(of: target.pid)?.identity == target else { return nil }
        return Kernel.isDarwinBackground(target.pid)
    }

    public func terminateApplication(_ target: ProcessIdentity) async throws {
        _ = try Self.verifiedToken(for: target)
        guard let app = NSRunningApplication(processIdentifier: target.pid) else { throw SideEffectError.processGone }
        guard app.terminate() else { throw SideEffectError.failed("pid \(target.pid) refused to quit") }
    }

    public func relaunchApplication(at bundleURL: URL) async throws {
        var isDirectory: ObjCBool = false
        guard bundleURL.pathExtension == "app",
              FileManager.default.fileExists(atPath: bundleURL.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SideEffectError.unavailable("not an application bundle: \(bundleURL.lastPathComponent)")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: SideEffectError.failed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: Verification

    /// A fresh audit token for `target` after checking start time, `p_uniqueid` and pidversion. Falls back to a
    /// synthesized `(pid, pidversion)` token when `task_name_for_pid` is refused — `proc_signal_with_audittoken`
    /// resolves exactly those two fields and rejects a stale pidversion with `ESRCH`.
    static func verifiedToken(for target: ProcessIdentity) throws -> audit_token_t {
        guard let entry = Kernel.entry(of: target.pid), !entry.isZombie else { throw SideEffectError.processGone }
        guard entry.identity == target else { throw SideEffectError.identityMismatch }
        guard let unique = Kernel.uniqueIdentifier(of: target.pid) else {
            throw Kernel.entry(of: target.pid) == nil ? SideEffectError.processGone : SideEffectError.identityMismatch
        }
        if let known = target.uniqueID, known != unique.uniqueID { throw SideEffectError.identityMismatch }
        let expected = target.pidVersion ?? unique.idVersion
        guard unique.idVersion == expected else { throw SideEffectError.identityMismatch }
        let token = Kernel.auditToken(of: target.pid) ?? Kernel.synthesizedToken(pid: target.pid, pidVersion: expected)
        guard token.val.7 == expected else { throw SideEffectError.identityMismatch }
        // A reuse between the reads above would change the start time.
        guard Kernel.entry(of: target.pid)?.identity == target else { throw SideEffectError.identityMismatch }
        return token
    }

    static func signalError(code: Int32, target: ProcessIdentity) -> SideEffectError {
        switch code {
        case ESRCH:
            // Either gone, or the pidversion no longer matches (the kernel rejected a stale token).
            return Kernel.entry(of: target.pid) == nil ? .processGone : .identityMismatch
        case EPERM, EACCES:
            return .notPermitted("pid \(target.pid): \(String(cString: strerror(code)))")
        default:
            return .failed("pid \(target.pid): \(String(cString: strerror(code)))")
        }
    }
}
