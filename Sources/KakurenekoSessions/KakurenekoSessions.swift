// KakurenekoSessions — SessionEngine state machine + timers + stall guard + aggregation, Claude T2 watcher
// (~/.claude/sessions/*.json, read-only), `claude agents --json --all` poller, Claude transcript helpers.
// OWNER: agent "sessions". Spec card: docs/ARCHITECTURE.md §9.3. Brief §5.1–5.6, §8.4 (titles);
// R02 §3–5, §8.
//
// Public surface (binding, ARCHITECTURE §9.3 "Must export"): `SessionEngine`, `ClaudeStateWatcher`.
// Everything else in this module is internal (tests use `@testable import`).
//
// Layout:
//   Engine/   SessionEngine (public, Mutex) → EngineState (value-type state machine), split by input:
//             +Events (T1), +ClaudeState (T2 merge + transitions), +Processes (T3 liveness, evidence, heuristic
//             sessions), +Timers (settle expiry, stall guard, heuristic exit, retention, dismissal);
//             EngineModel holds the per-session tracking types.
//   Claude/   ClaudeStateWatcher (public) → ClaudeWatchRuntime (tasks: debounce, poll, sweep, directory re-check,
//             tail re-reads) → ClaudeStateCore (actor: reads, polls, emits); ClaudeRecords (liveness, caps),
//             TranscriptTail (tail summarizer), ClaudeCLI (`agents --json` request/parse), FSEventsDirectoryWatcher,
//             ClaudeFileAccess (read-only POSIX file access, injectable for tests).
//
// Isolation (ARCHITECTURE §5): nonisolated library. `SessionEngine` is synchronous and deterministic (no clock,
// no I/O, every method takes `now`). `ClaudeStateWatcher` does all file and subprocess I/O on its own actor
// (`ClaudeStateCore`), never on the caller's executor; the FSEvents callback arrives on a private serial queue and
// reaches Swift through an `Unmanaged` box.
