// KakurenekoPause — pausing other apps while agents work with the lid closed (brief §6, R06; ARCHITECTURE §9.5).
// OWNER: agent "pause" (also owns Sources/KakurenekoGuard and Tests/KakurenekoPauseTests).
//
// Public surface (binding): `PauseManager` (AppPausing), `AuditTokenSignaller` (ProcessSignalling) and, for the
// `kakureneko-guard` executable, `PauseGuard`. Everything else is internal.
//
// Files:
//   PauseManager.swift            lifecycle, recovery, thaw, guard spawning/heartbeat, crash-handler bookkeeping
//   PauseManager+Pausing.swift    pause / recheck: candidates, rules, Throttle / Freeze / Quit, helper re-scan
//   ProtectionRules.swift         P-A…P-K as pure functions, mode choice, P-I CPU history
//   ProcessGrouping.swift         responsibility (dlsym) → coalition → ppid grouping + self-test
//   Candidates.swift              NSWorkspace regular apps as Sendable snapshots
//   NeverPauseList.swift          rule P-J static list
//   JournalStore.swift            write-ahead `paused.json` (F_FULLFSYNC) + async serial lock
//   PauseRecovery.swift           verified thaw of journal records (shared with the guard)
//   CrashHandlers.swift           CrashThawBuffer (§5 exception) + sigaction crash handler
//   GuardLauncher.swift           posix_spawn of kakureneko-guard, heartbeat pipe
//   PauseGuard.swift              the kakureneko-guard program (watch / recover / crash self-test)
//   AuditTokenSignaller.swift     the real ProcessSignalling
//   KernelProbes.swift, SystemProbe.swift, AudioActivity.swift   read-only kernel / CoreAudio probes
