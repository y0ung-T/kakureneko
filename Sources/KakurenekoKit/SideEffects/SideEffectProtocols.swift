import Foundation

/// Errors from system-mutating operations.
public enum SideEffectError: Error, Sendable, Hashable, LocalizedError {
    /// e.g. `sudo: a password is required` (sudoers rule missing), TCC denied, EPERM.
    case notPermitted(String)
    /// The target process is not the one we journaled (pid reused / audit token `val[7]` mismatch).
    case identityMismatch
    /// The target process no longer exists.
    case processGone
    case commandFailed(exitCode: Int32, stderr: String)
    case timedOut
    /// API/binary missing (e.g. `proc_signal_with_audittoken` unavailable).
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notPermitted(let s): "Not permitted: \(s)"
        case .identityMismatch: "The process changed identity"
        case .processGone: "The process is gone"
        case .commandFailed(let code, let stderr): "Command failed (\(code)): \(stderr)"
        case .timedOut: "Timed out"
        case .unavailable(let s): "Unavailable: \(s)"
        case .failed(let s): s
        }
    }
}

/// Whether a subprocess / operation changes the system. Dry-run blocks `.mutating` only.
public enum SideEffectKind: String, Sendable, Hashable, Codable {
    case readOnly
    case mutating
}

/// The only privileged commands Kakureneko ever runs (argv must match the sudoers rule byte for byte).
public enum PrivilegedCommand: Sendable, Hashable {
    /// `/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 1|0`
    case setSleepDisabled(Bool)
    /// Health check: `/usr/bin/sudo -n -l /usr/bin/pmset -a disablesleep 1` (read-only).
    case checkSudoRule

    public var argv: [String] {
        switch self {
        case .setSleepDisabled(let on):
            [RootPaths.sudo, "-n", RootPaths.pmset, "-a", "disablesleep", on ? "1" : "0"]
        case .checkSudoRule:
            [RootPaths.sudo, "-n", "-l", RootPaths.pmset, "-a", "disablesleep", "1"]
        }
    }

    public var effect: SideEffectKind {
        switch self {
        case .setSleepDisabled: .mutating
        case .checkSudoRule: .readOnly
        }
    }
}

/// Runs `PrivilegedCommand`s (`sudo -n` via `SubprocessRunning`). Real: `KakurenekoPower.SudoPrivilegedCommandRunner`.
public protocol PrivilegedCommandRunning: Sendable {
    func run(_ command: PrivilegedCommand) async throws -> SubprocessResult
}

/// Sleeps the Mac now. Real: `KakurenekoPower.IOPMSystemSleeper` (`IOPMSleepSystem`, retry once on
/// `0xE00002E2`, fallback `/usr/bin/pmset sleepnow`). NEVER called by tests or agents.
public protocol SystemSleeping: Sendable {
    func sleepNow() async throws
    /// Hands a sleep to a detached helper that OUTLIVES this process (`/bin/sh` in its own session): after `delay`,
    /// if the lid is still closed, it runs `/usr/bin/pmset sleepnow` (no root needed). Used only when the app quits
    /// while a polite shutdown is pending (loginwindow quits the app first; a shutdown aborted by another app must
    /// still end in sleep, brief §7.5). Real: `KakurenekoPower.IOPMSystemSleeper`. NEVER called by tests or agents.
    func scheduleDetachedSleep(after delay: Duration) throws
}

/// Polite shutdown (Apple Event `aevt/shut` to loginwindow; needs Automation consent). Real:
/// `KakurenekoPower.LoginWindowShutdownRequester`. NEVER called by tests or agents.
public protocol ShutdownRequesting: Sendable {
    func requestShutdown() async throws
}

/// Display sleep (`/usr/bin/pmset displaysleepnow`). Real: `KakurenekoPower.PmsetDisplaySleeper`.
public protocol DisplaySleeping: Sendable {
    func displaySleepNow() async throws
}

/// Signals sent to paused processes.
public enum ProcessSignalKind: String, Sendable, Hashable, Codable {
    /// SIGSTOP
    case stop
    /// SIGCONT
    case cont
}

/// Process control for app pausing. Real: `KakurenekoPause.AuditTokenSignaller`.
/// Every call re-verifies identity first (start time; fresh audit token `val[7] == pidVersion`; `uniqueID`)
/// and throws `.identityMismatch` / `.processGone` instead of acting. The PAUSING calls — `send(.stop, …)` and
/// `setDarwinBackground(true, …)` — MUST throw `.identityMismatch` when `target.pidVersion == nil ||
/// target.uniqueID == nil` (an un-enriched identity could never be verified by recovery). Thawing calls
/// (`.cont`, `false`) verify whatever is known.
/// Tests may only target processes they spawned themselves.
public protocol ProcessSignalling: Sendable {
    /// `proc_signal_with_audittoken(&token, SIGSTOP|SIGCONT)` — never raw `kill`, never SIGTSTP.
    func send(_ signal: ProcessSignalKind, to target: ProcessIdentity) throws
    /// `setpriority(PRIO_DARWIN_PROCESS, pid, enabled ? PRIO_DARWIN_BG : 0)`.
    func setDarwinBackground(_ enabled: Bool, for target: ProcessIdentity) throws
    /// Whether `target` currently runs DARWIN_BG (verification after throttling; also "already throttled by
    /// someone else → skip"). Read-only; nil when unknown (process gone, identity mismatch).
    ///
    /// Read `proc_pidinfo(PROC_PIDTBSDINFO).pbi_flags`: `PROC_FLAG_EXT_DARWINBG` (0x10000, set by another process's
    /// `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)` — Kakureneko's throttle, App Tamer, `taskpolicy -b`)
    /// or `PROC_FLAG_DARWINBG` (0x8000, the process's own request). NOT `getpriority(PRIO_DARWIN_PROCESS, pid)`:
    /// measured on macOS 26 it keeps returning 0 after an EXTERNAL throttle (it reports only the target's own
    /// request), so it can be at most a fallback when `proc_pidinfo` fails. In dry-run the passthrough reads the
    /// REAL state, so callers skip verification when the gate is on.
    func isDarwinBackground(_ target: ProcessIdentity) -> Bool?
    /// `NSRunningApplication(processIdentifier:)?.terminate()` (Quit mode; opt-in only).
    func terminateApplication(_ target: ProcessIdentity) async throws
    /// Relaunch an app closed by Quit mode: `NSWorkspace.shared.openApplication(at:configuration:)` with
    /// `activates = false` (ledger action `app.relaunch`). The bundle URL is derived from the journaled `path`.
    func relaunchApplication(at bundleURL: URL) async throws
}

/// Runs a bash script INLINE as root — `/bin/bash -c <script> <name> <args…>` — with ONE administrator prompt
/// (`NSAppleScript` `do shell script … with administrator privileges`). The script text travels inside the
/// AppleScript source: root never executes or reads code from a file a same-user process could rewrite while the
/// password dialog is open. Real: `KakurenekoPower.AppleScriptAdministratorRunner`. NEVER called by tests or agents.
public protocol AdministratorScriptRunning: Sendable {
    /// - Parameters:
    ///   - script: the complete bash script.
    ///   - name: `$0` of the script (diagnostics, e.g. `install-privileged.sh`).
    /// - Returns: the script's stdout.
    func runAsAdministrator(script: String, name: String, arguments: [String]) async throws -> String
}
