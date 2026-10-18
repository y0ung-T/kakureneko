// kakureneko-hook — the agent hook helper (brief §4.1–4.3, renamed). OWNER: agent "events".
//
// CONTRACT (binding, unit-tested by KakurenekoEventsTests by spawning the built binary):
//   kakureneko-hook <agent> <event> [--chain -- <argv...>]
//   * ALWAYS exit 0. `alarm(2)` + SIGALRM → `_exit(0)`; `signal(SIGPIPE, SIG_IGN)`.
//   * stdout EMPTY, except `cursor beforeSubmitPrompt` → `{"continue":true}` and `cline *` → `{"cancel":false}`.
//     Never write to stderr. Diagnostics → `<root>/log/hook.log` (rotate at 1 MB).
//   * Darwin-only Swift (`import Darwin`, `import notify`) — NO Foundation, no dependencies.
//   * Payload: if `isatty(STDIN_FILENO) != 0`, NEVER read stdin (Aider runs the hook with the user's terminal as
//     stdin: reading would block its prompt and swallow keystrokes) → payloadSource "none". Otherwise stdin (read
//     to EOF, 300 ms poll idle limit, 4 MiB cap). In both cases, when the argv after <event> (and after any
//     chained argv) ends with a JSON object, that last argv is the payload instead (Codex `notify`,
//     payloadSource "argv").
//   * `--chain -- <argv…>`: posix_spawnp the chained argv (execvp semantics: a bare program name such as
//     `notify-send` or `terminal-notifier` — exactly as Codex `notify` held it — is resolved through the hook's
//     inherited `PATH`, like Codex did), appending the payload as the last argv ONLY when payloadSource == "argv"
//     (Codex notify); otherwise spawn the chained argv unchanged. stdio /dev/null, POSIX_SPAWN_SETSID, default
//     signal dispositions, do not wait. A program that cannot be found/spawned is logged; the hook still exits 0.
//   * Root resolution (`<root>` = Kakureneko's `.kakureneko` dir): if this binary's own path
//     (`_NSGetExecutablePath` / `proc_pidpath(getpid())`) ends in `/.kakureneko/bin/kakureneko-hook`, `<root>` is that
//     `.kakureneko` dir (so a `KAKURENEKO_HOME` dev install stays inside the fake home); otherwise `$HOME/.kakureneko`.
//   * Inbox file: `<inbox>/.tmp/<19-digit ns>-<pid>.tmp` (O_CREAT|O_EXCL|O_CLOEXEC, 0600) → rename(2) to
//     `<inbox>/<19-digit ns>-<pid>.event`; dir mode 0700; then `notify_post("com.kakureneko.inbox")`.
//     Line 1 = `InboxHeader` JSON (schema in KakurenekoKit/Model/Inbox.swift), rest = payload byte for byte.
//   * Inbox resolution: `$KAKURENEKO_INBOX` (tests) → `<root>/inbox` → if not writable, the fallback
//     `$KAKURENEKO_FALLBACK_INBOX` (tests) ?? `$(confstr _CS_DARWIN_USER_TEMP_DIR)/com.kakureneko/inbox`.
//     > 5,000 queued files → drop, exit 0. Hook tests ALWAYS set both KAKURENEKO_INBOX and KAKURENEKO_FALLBACK_INBOX.
//   * Env allow-list = `InboxHeader.environmentAllowList`; never any name matching TOKEN|KEY|SECRET|PASSWORD.
//   * Ancestry: ≤ 8 levels via sysctl KERN_PROC_PID (ppid, startSec, startUsec, exe = p_comm, tdev) + one
//     KERN_PROCARGS2 read per ancestor (reused 16 KiB buffer, argv only — never env): `argv0`, and `argv1` ONLY
//     when `InboxAncestor.isRecordableArgv1` (contains "/", no whitespace, ≤ 512 bytes; argv[1] can be a prompt)
//     + `path` = `proc_pidpath` (absent on failure) + `module` = the `-m <module>` of a Python interpreter
//     (argv[0]/exec path basename `python*`), ONLY when `InboxAncestor.isRecordableModule` (plain dotted
//     identifier, ≤ 128 bytes); at most 8 argv strings are scanned, never past argc.
//   * `KAKURENEKO_RECORD=1`: also write raw stdin/argv/allow-listed env to
//     `<root>/recordings/<agent>/<event>-<ts>.json`.
//
// Implementation: HookMain.swift (orchestration), HookInvocation.swift (argv), HookPayload.swift (stdin),
// HookAncestry.swift (sysctl/libproc), HookJSON.swift (header/recording JSON), HookFiles.swift (root, inbox,
// log, recordings), HookChain.swift (posix_spawn). Every function lives outside this file so nothing inherits
// the main actor isolation of top-level code (R08 §9 pitfall 1).

import Darwin

HookMain.run(CommandLine.arguments)
