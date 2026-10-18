// kakureneko-guard — out-of-process pause guard (brief §6.5 item 3, renamed). OWNER: agent "pause".
//
// CONTRACT (binding):
//   kakureneko-guard --watch <app-pid> --journal <path-to-paused.json> --log <path> [--pipe-fd <fd>] [--dry-run]
//       Spawned by PauseManager.startGuard() with posix_spawn + POSIX_SPAWN_SETSID (the app keeps the pipe's write
//       end O_CLOEXEC). Watches the app with kqueue EVFILT_PROC/NOTE_EXIT and the inherited pipe:
//         * `hb\n` lines every 10 s from the app. HANG = no line for 90 s, measured with
//           `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` (excludes system sleep); ignored while the journal is empty.
//           On a hang: thaw the verified records, rewrite the journal WITHOUT them, KEEP watching.
//         * `bye\n` (sent by stopGuard after thawAll) → exit 0 without recovery.
//         * NOTE_EXIT or pipe EOF without `bye` (app died) → recover, then exit 0.
//       Recovery: read the journal (`PauseJournal.read(from:)`, lossy), skip `simulated` apps and `.terminate`
//       records (never signal / relaunch them), thaw every remaining record whose identity still matches (boot
//       UUID, start time, uniqueID, fresh audit token val[7] == pidVersion; SIGCONT / setpriority(…, 0)), LIFO
//       per app, then clear the journal.
//   kakureneko-guard --recover --journal <path> --log <path> [--dry-run]
//       One-shot recovery (same thaw logic), used at login if the app is not running.
//   * Always exits 0. Logs ONLY to the `--log` path (never calls `Paths.live()` when `--log` is given; without it,
//     `Paths.live()` honours KAKURENEKO_HOME → HOME). Never blanket-SIGCONTs stopped processes.
//   * `--dry-run`: log what would be thawed, signal nothing.
//   * Identity lookups use `KernelProcessLookup` (KakurenekoKit) so the tuple equals the journal's.
//   * Hidden `--crash-selftest`: may be used by KakurenekoPauseTests to exercise the crash-handler pid buffer in a
//     separate process (never in the test process itself).
//
// Hidden test flags: `--hang-timeout-ms <ms>` (shortens the 90 s hang timeout);
// `--crash-selftest --pid <pid>… [--signal abrt|segv|bus|ill|trap|fpe|fault]` (installs the real crash handler,
// publishes the pids, dies by the signal; the handler SIGCONTs the pids first).
//
// The implementation lives in KakurenekoPause (`PauseGuard`) so the guard and the app share one thaw routine.

import Darwin
import KakurenekoPause

exit(PauseGuard.run(arguments: CommandLine.arguments))
