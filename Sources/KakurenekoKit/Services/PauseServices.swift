import Foundation

/// App pausing (brief §6). Implemented by `KakurenekoPause.PauseManager`.
///
/// Isolation: actor or `final class … : Sendable`. Decisions are keyed by pid + audit token, never by
/// bundle id. All signals/priority changes go through the injected `ProcessSignalling` (dry-run safe).
/// The journal (`PauseJournal`) is written BEFORE every signal or setpriority, and only for ENRICHED identities
/// (`pidVersion` + `uniqueID` known). Syscall-heavy methods (`pause`, `recheck`, `recoverFromJournal`, `selfTest`,
/// `thawAll`, `observe`) are `@concurrent` (they must not run on the coordinator actor).
///
/// The coordinator decides WHEN (lid closed, no external display, no input for 60 s, holdAwake, 90 s
/// after lid close — brief §6.1) and calls `pause`; it calls `recheck` every `recheckSeconds` while
/// anything is paused and `thawAll` on every thaw trigger (§6.5.5). The CPU-not-advancing watchdog is
/// evaluated by the coordinator (it owns evidence), which then calls `thawAll(reason: .watchdog)`.
/// KakurenekoPause never infers "no agent" from `AgentTopology.isEmpty`; only the coordinator decides `holdAwake`.
public protocol AppPausing: Sendable {
    /// Launch recovery: read `paused.json`, thaw every record whose identity still matches (boot UUID,
    /// start time, uniqueID, fresh audit token `val[7] == pidVersion`), drop the rest (and every `simulated`
    /// app and every `.terminate` record, without signalling or relaunching), clear the journal.
    /// Returns the number of processes thawed. Never blanket-SIGCONTs stopped processes.
    func recoverFromJournal() async -> Int
    /// Installs the async-signal-safe `sigaction` handler for SEGV/BUS/ILL/ABRT/TRAP/FPE ONLY (walks a
    /// preallocated pid array with `kill(pid, SIGCONT)`, resets the disposition, re-raises). Once. Never called in
    /// a test process. SIGTERM/INT/HUP/QUIT are owned by the coordinator (thaw → disarm → exit).
    func installCrashHandlers()
    /// Termination paths (coordinator signal sources, `applicationWillTerminate` fallback): nonisolated,
    /// SYNCHRONOUS, LIFO thaw of every real journaled record, clears the journal. Returns processes thawed.
    func thawAllSynchronously(reason: ThawReason) -> Int
    /// Spawns `kakureneko-guard --watch <pid> --journal <path> --log <path> --pipe-fd <fd>` (posix_spawn + SETSID; the
    /// write end of the pipe is O_CLOEXEC so other children never inherit it). Writes `hb\n` every 10 s; reaps
    /// (`waitpid(…, WNOHANG)`) and respawns the guard if it exited unexpectedly. Not spawned in dry-run. Idempotent.
    func startGuard() throws
    /// Writes `bye\n` (only after `thawAll`), closes the pipe; the guard exits without recovery.
    func stopGuard()
    /// Grouping self-test (responsibility → coalition → ppid). Freeze requires `freezeAllowed`.
    func selfTest() async -> GroupingSelfTest
    /// Called by the coordinator on every process-scan tick while the lid is closed (before and during
    /// pausing): keeps a ≤ 2 min `proc_pid_rusage` history per candidate group (rule P-I) and lazily owns the
    /// memory-pressure source (Quit mode).
    func observe(now: Date) async
    /// Pause eligible regular apps per `settings.mode` (Freeze only if the self-test passed; downgrades per
    /// P-G/P-I; protections P-A…P-K). Returns what is paused/protected.
    func pause(topology: AgentTopology, settings: PauseSettings, now: Date) async -> PauseReport
    /// While paused (every 10–15 s): re-evaluate P-C/P-D/P-E/P-F and new agents with a fresh topology;
    /// any match thaws that app and protects it for the rest of the session; throttle newly spawned
    /// helpers of throttled apps (30 s); enforce the hard cap.
    func recheck(topology: AgentTopology, settings: PauseSettings, now: Date) async -> PauseReport
    /// Thaws everything (LIFO per group: helpers first, main last), clears the journal. Returns processes thawed.
    /// Apps closed by Quit mode are relaunched (`ProcessSignalling.relaunchApplication`, not activated) only for
    /// `.lidOpened`, `.userRequest`, `.externalDisplay`, `.userInput` — never before sleep/power-off/quit.
    @discardableResult
    func thawAll(reason: ThawReason) async -> Int
    /// Currently paused apps.
    func pausedApps() async -> [PausedApp]
}
