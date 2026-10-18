# 02 — Claude Code: detecting WORKING vs FINISHED vs WAITING, locally and reliably

Research date: 2026-10-12. Machine: macOS 26.6.2 (25G83) arm64.
Claude Code under test: **2.1.296** (`~/.local/bin/claude` -> `~/.local/share/claude/versions/2.1.296`, BUILD_TIME `2026-10-09T01:31:52Z`, GIT_SHA `fdb6c17a`, read from the binary's embedded strings).
Other Claude Code binaries on this machine: `~/.local/share/claude/versions/2.1.294`, `2.1.295`, `ClaudeCode.app` (used for `bg-pty-host` and daemon helpers), and the Claude desktop app's bundled copy at `~/Library/Application Support/Claude/claude-code/2.1.289/<hash>/claude.app/Contents/MacOS/claude`.

Confidence tags: **[H]** high (verified locally or quoted from official docs/source), **[M]** medium (inferred from source strings or partial evidence), **[L]** low (plausible, not verified).

Source keys used throughout:

| Key | Source |
|---|---|
| DOC-HOOKS | https://code.claude.com/docs/en/hooks (raw `.md` fetched 2026-10-12) |
| DOC-PLUGMAN | https://code.claude.com/docs/en/plugins-reference (plugin manifest reference) |
| DOC-PLUGCLI | https://code.claude.com/docs/en/plugins/cli-reference |
| DOC-MKT | https://code.claude.com/docs/en/plugins/marketplace-reference |
| DOC-AGENTS | https://code.claude.com/docs/en/agent-view |
| DOC-DIR | https://code.claude.com/docs/en/claude-directory |
| DOC-SESS | https://code.claude.com/docs/en/sessions |
| DOC-RC | https://code.claude.com/docs/en/remote-control |
| DOC-ENV | https://code.claude.com/docs/en/env-vars |
| DOC-SET | https://code.claude.com/docs/en/settings-reference |
| DOC-TERM | https://code.claude.com/docs/en/terminal-config |
| DOC-DESK | https://code.claude.com/docs/en/desktop |
| DOC-VSC | https://code.claude.com/docs/en/vs-code |
| DOC-HEADLESS | https://code.claude.com/docs/en/headless |
| DOC-XMSG | https://code.claude.com/docs/en/cross-session-messaging |
| DOC-MOBILE | https://code.claude.com/docs/en/mobile |
| DOC-WEB | https://code.claude.com/docs/en/claude-code-on-the-web |
| CHANGELOG | https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md (top entry 2.1.296) |
| BIN | `strings` of `~/.local/share/claude/versions/2.1.296`, searched read-only (scratch copy in `research-snippets/strings-2.1.296.txt`) |
| LOCAL | read-only commands on this machine (each one is named where it is used) |

---

## 0. TL;DR

1. **Use Claude Code's own presence records.** Every live session writes `~/.claude/sessions/<pid>.json`. It carries `status` ∈ {`busy`, `shell`, `idle`, `waiting`} plus `waitingFor`. This is the best low-latency local signal, but its schema is undocumented [H: BIN + LOCAL]. The **supported** interface over the same data is `claude agents --json [--all]`, which takes 0.18 s per call and wrote no files under `~/.claude` in my test [H: DOC-AGENTS + LOCAL].
2. **`busy` means "a turn is running OR delegated work is active"** (background subagents and workflows). `shell` means "idle, but a background shell task is running". `waiting` means a dialog or prompt is blocking, with `waitingFor` ∈ {`permission prompt`, `input needed`, `dialog open`, `sandbox request`, `worker request`, `goal proposal`} [H: BIN].
3. **`busy` can go stale.** On this machine, session pid 76720 stayed `busy` for about 13.5 h. Its background workflow was killed at 01:29 and the Mac clamshell-slept at 01:29:49. The status was not rewritten until the user resumed at 15:04 [H: LOCAL]. Lidless therefore needs a progress or stall guard and must not treat `busy` alone as proof of work.
4. **Claude Code already runs `caffeinate -i -t 300` as a child process while `busy`.** It respawns it every 240 s and releases it 30 s after leaving `busy` [H: BIN + LOCAL]. `-i` only blocks idle sleep, though. The power log shows `Entering Sleep state due to 'Clamshell Sleep'` while Claude's caffeinate assertion was held [H: LOCAL `pmset -g log`]. So Claude Code does not survive a lid close by itself, and that gap is exactly Lidless's job. The caffeinate child is a handy, free busy indicator (`IOPMCopyAssertionsByProcess` → parent pid) [H: LOCAL Swift probe].
5. **Hooks give rich, event-driven data.** The useful events are `Stop` (has `last_assistant_message` and `background_tasks`), `StopFailure`, `Notification` (`permission_prompt`, `idle_prompt`, `elicitation_*`, `agent_needs_input`, `agent_completed`), `UserPromptSubmit`, `SessionStart`, and `SessionEnd`. Two caveats:
   - **`Stop` does not fire on user interrupt.**
   - **Another hook can veto the stop** (`decision: "block"`, `/goal`). A `Stop` event is therefore a candidate "finished", not proof.

   Our hook must always exit 0, print nothing, and never return `decision`/`continue` [H: DOC-HOOKS].
6. **Ship the hooks as a Claude Code plugin from a local-directory marketplace.** Do not hand-edit `~/.claude/settings.json`. Install and uninstall are clean CLI calls (`claude plugin marketplace add <dir>`, `claude plugin install lidless@lidless-local`). The plugin is visible in `/plugin` and `/hooks`. Trade-off: plugin hooks reach already-running sessions only after `/reload-plugins` or a restart, whereas settings.json edits are picked up live by the file watcher [H: DOC-PLUGCLI, DOC-HOOKS]. The session-record polling covers the gap.
7. **Sleep is safe; shutdown is lossy.** Sessions survive system sleep, and the background supervisor reconnects on wake. Shutdown kills every process:
   - Interactive sessions are recoverable with `claude --resume <sessionId>` or `--continue`. An interrupted tool call is marked "cut off", and background work is noted as unfinished.
   - Background sessions show as `failed` (if under 48 h) or `stopped` (if over 48 h) and resume when you reply or attach [H: DOC-SESS, DOC-AGENTS].

   So Lidless should prefer sleep and only shut down when every session is idle, and it should save a resume manifest before shutting down.

---

## 1. Hooks (verified against 2.1.296)

### 1.1 Full event list

The binary's own event array, in this exact order [H: BIN]:

```
PreToolUse, PostToolUse, PostToolUseFailure, PostToolBatch, Notification, UserPromptSubmit,
UserPromptExpansion, SessionStart, SessionEnd, Stop, StopFailure, SubagentStart, SubagentStop,
PreCompact, PostCompact, PreModelSwitch, PostModelSwitch, PermissionRequest, PermissionDenied,
Setup, TeammateIdle, TaskCreated, TaskCompleted, Elicitation, ElicitationResult, ConfigChange,
WorktreeCreate, WorktreeRemove, InstructionsLoaded, CwdChanged, FileChanged, DirectoryAdded,
MessageDisplay
```

That is 33 events, which matches the docs table [H: DOC-HOOKS]. No dedicated "idle" event exists. Idleness surfaces through `Notification` with `idle_prompt`, through `Stop`, and through the session record's `status`.

### 1.2 Events relevant to Lidless

| Event | When it fires (docs) | Matcher | Key stdin fields (beyond common) | Can it block? |
|---|---|---|---|---|
| `SessionStart` | New session / resume / clear / compact / fork. Runs in background at launch; first response waits for it | `startup` `resume` `clear` `compact` `fork` | `source`, optional `model`, `agent_type`, `session_title`, resume stats (`seconds_since_last_response`, ...) | No, but **plain stdout is injected into Claude's context** |
| `UserPromptSubmit` | Before each prompt, **also** on `/loop` and cron firings, background-subagent reports, and cross-session messages | none (always fires) | `prompt`, optional `session_title` | **Yes** (exit 2 or `{"decision":"block"}` drops the prompt). Default timeout 30 s; plain stdout is added to context |
| `Stop` | Main agent finished responding. **Not on user interrupt.** API errors fire `StopFailure` instead | none | `stop_hook_active`, `last_assistant_message`, `background_tasks[]`, `session_crons[]` | **Yes** (exit 2 or `decision:"block"` makes Claude keep going) |
| `StopFailure` | Turn ended by an API error | `error` values below | `error`, optional `error_details`, `last_assistant_message` (the error string) | No (output ignored except `terminalSequence`) |
| `Notification` | See 1.4 | `notification_type` | `message`, optional `title`, `notification_type` | No (exit code and stderr ignored) |
| `SubagentStop` | Subagent finished | agent type | `agent_id`, `agent_type`, `agent_transcript_path`, `last_assistant_message`, `stop_hook_active`, `background_tasks`, `session_crons` | **Yes** (keeps the subagent running) |
| `PermissionRequest` | Tool call needs a decision (immediate, no 6 s delay) | tool name | `tool_name`, `tool_input`, `permission_suggestions` | Via JSON `decision` object only; exit 2 is not honored. **In non-prompting sessions, if no hook decides, the call is denied** (existing behavior) |
| `SessionEnd` | Exit, `/clear`, interactive `/resume` switch | `clear` `resume` `logout` `prompt_input_exit` `other` | `reason` | No. **Default budget 1.5 s** (raised by per-hook `timeout`, max 60 s, **but plugin hook timeouts do not raise it**; `CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS` overrides) |

`StopFailure.error` values: `rate_limit`, `overloaded`, `authentication_failed`, `oauth_org_not_allowed`, `account_on_hold`, `billing_error`, `invalid_request`, `model_not_found`, `server_error`, `max_output_tokens`, `cloud_credential_error`, `unknown` [H: DOC-HOOKS].

**Common input fields** [H: DOC-HOOKS]:
- `session_id`
- `prompt_id`
- `transcript_path`: written asynchronously and may lag. At `Stop` time the final message is not guaranteed to be in it, so use `last_assistant_message` instead.
- `cwd`
- `scratchpad_dir` (2.1.257+)
- `permission_mode` (`default|plan|acceptEdits|auto|dontAsk|bypassPermissions`)
- `effort.level`
- `hook_event_name`
- `agent_id` and `agent_type` when inside a subagent

Example Stop payload (docs, verbatim shape):

```json
{
  "session_id": "abc123",
  "transcript_path": "~/.claude/projects/.../00893aaf-19fa-41d2-8238-13269b9b3ca0.jsonl",
  "cwd": "/Users/...",
  "permission_mode": "default",
  "hook_event_name": "Stop",
  "stop_hook_active": true,
  "last_assistant_message": "I've completed the refactoring. Here's a summary...",
  "background_tasks": [
    { "id": "task-001", "type": "shell", "status": "running",
      "description": "tail logs", "command": "tail -f /var/log/syslog" }
  ],
  "session_crons": [
    { "id": "cron-001", "schedule": "0 9 * * 1-5", "recurring": true, "prompt": "check the build" }
  ]
}
```

`background_tasks[].type` labels: `shell`, `subagent`, `monitor`, `workflow`, `teammate`, `cloud session`, `MCP task`. Docs: these arrays "let hooks distinguish 'session is done' from 'session is paused waiting for background work to wake it back up'" [H: DOC-HOOKS].

### 1.3 Environment available to hook processes

| Variable | Notes | Confidence |
|---|---|---|
| `CLAUDE_PID` | The Claude Code process id (2.1.214+). Join key to `~/.claude/sessions/<pid>.json` | [H: DOC-ENV; LOCAL: my tool subprocess saw `CLAUDE_PID=96888`] |
| `CLAUDE_CODE_SESSION_ID` | Equals `session_id`; updated on `/clear` | [H: DOC-ENV + LOCAL] |
| `CLAUDE_CODE_MESSAGING_SOCKET` | e.g. `/tmp/cc-socks/<pid>.sock` | [H: DOC-ENV + LOCAL] |
| `CLAUDE_CODE_MESSAGING_TOKEN` | **Secret.** Never log it | [H: DOC-ENV] |
| `CLAUDE_CODE_ENTRYPOINT` | `cli`, `claude-desktop`, `claude-vscode`, `sdk-ts`, `sdk-py`, `local-agent`, ... | [H: LOCAL `cli`; M: other values from BIN] |
| `CLAUDE_CODE_EXECPATH` | Path of the running Claude binary. Useful for locating the CLI to call `claude agents --json` | [H: LOCAL] |
| `CLAUDECODE=1`, `CLAUDE_CODE_CHILD_SESSION=1`, `CLAUDE_EFFORT`, `CLAUDE_PROJECT_DIR`, `CLAUDE_PLUGIN_ROOT`, `CLAUDE_PLUGIN_DATA` | `CLAUDE_PLUGIN_*` only for plugin hooks | [H: DOC-ENV / DOC-PLUGMAN] |
| `CLAUDE_JOB_DIR` | Only in background (`kind:"bg"`) sessions: `~/.claude/jobs/<id>` | [H: DOC-ENV] |

The tool-subprocess environment observed locally (hooks get the same set per docs):
`CLAUDECODE=1`, `CLAUDE_CODE_CHILD_SESSION=1`, `CLAUDE_CODE_ENTRYPOINT=cli`, `CLAUDE_CODE_EXECPATH=/Users/tomasnguyen/.local/share/claude/versions/2.1.296`, `CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/96888.sock`, `CLAUDE_CODE_SESSION_ATTENDED=1`, `CLAUDE_CODE_SESSION_ID=3514aa88-…`, `CLAUDE_EFFORT=xhigh`, `CLAUDE_PID=96888` [H: LOCAL `env`].

### 1.4 Notification types and timing

The binary enumerates 17 types [H: BIN]:

```
permission_prompt, idle_prompt, auth_success, elicitation_dialog, agent_needs_input, agent_completed,
elicitation_url_dialog, worker_permission_prompt, push_notification, computer_use_enter, computer_use_exit,
quota_auto_resume_fired, quota_auto_resume_stale, quota_auto_resume_disabled, model_refusal_fallback,
auth_storage_failure, plugin_notification
```

The docs list 12 of them as matchers. Timing per the docs [H: DOC-HOOKS]:
- **`permission_prompt`** fires about 6 s after the prompt appears. In terminal sessions each keystroke defers it. In SDK-hosted sessions (Desktop and VS Code) it fires about 6 s after the request with no keystroke deferral.
- **`idle_prompt`** fires about 60 s after Claude finished, only if you have not typed since and no background agent is running. It is not sent during a usage-limit wait. The threshold is `messageIdleNotifThresholdMs`, default `60000` [H: BIN default config].
- **`elicitation_dialog` and `elicitation_url_dialog`** have the same 6 s gate.
- **`agent_needs_input` and `agent_completed`** fire for background sessions **only while agent view (`claude agents`) is open in a terminal.**
- **`quota_auto_resume_*`** concern claude.ai usage-limit waits. `quota_auto_resume_stale` means the limit reset while the computer slept more than about 30 min, so Claude waits for Enter.
- Hooks fire **even if `preferredNotifChannel` is `notifications_disabled`.**

Example payload:

```json
{ "session_id": "abc123", "transcript_path": "...", "cwd": "/Users/...",
  "hook_event_name": "Notification", "message": "Claude needs your permission",
  "title": "Permission needed", "notification_type": "permission_prompt" }
```

### 1.5 Exit codes and stdout: what could accidentally BLOCK the agent (critical)

From DOC-HOOKS [H]:
- **Exit 0:** success. If stdout is a single JSON object it is parsed. Otherwise it is plain text, which is **added to Claude's context on `UserPromptSubmit`, `UserPromptExpansion`, `SessionStart`, `PostModelSwitch`**. stderr is never shown to Claude on exit 0.
- **Exit 2:** blocking error. It blocks `PreToolUse`, `UserPromptSubmit`, `UserPromptExpansion`, `Stop` (Claude keeps working), `SubagentStop`, `TeammateIdle`, `TaskCreated`, `TaskCompleted`, `ConfigChange`, `PostToolBatch` (stops the loop), `PreCompact`, `PreModelSwitch`, `Elicitation`, `ElicitationResult`, and `Worktree*`. It is ignored for `Notification`, `SessionStart`, `SessionEnd`, `StopFailure`, `PermissionRequest`, `PostToolUse*`, and others.
- **Any other non-zero:** non-blocking error, but the **transcript shows `Failed with non-blocking status code: …`** (user-visible noise).
- **JSON fields that change behavior:**
  - `{"continue": false}` stops Claude entirely, on any event.
  - `{"decision": "block", "reason": "…"}` blocks on `Stop`, `SubagentStop`, `UserPromptSubmit`, `PostToolUse*`, `PostToolBatch`, `ConfigChange`, `PreCompact`, and `TaskCreated`.
  - `hookSpecificOutput.permissionDecision` affects `PreToolUse`.
  - `hookSpecificOutput.additionalContext` on `Stop` feeds text back and **keeps the turn going**.
  - `systemMessage` warns the user.
  - `terminalSequence` emits OSC/BEL.
- **Async hooks** (`"async": true`, command type only): run in background with no timeout enforced. Their `additionalContext` and `systemMessage` **are delivered to Claude on the next turn.** Never use `asyncRewake`, because exit 2 then **wakes Claude immediately**.
- `onFailure: "block"` (2.1.295+) turns a hook failure or timeout into a block. **Never set it.**
- Stop-loop protection: after 8 consecutive Stop-hook continuations Claude overrides (`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`).
- History: a 2.1.290 fix addressed *"Claude replying in an endless loop when a plugin's async Stop hook passes an unquoted script path under a folder with a space, such as Application Support"* [H: CHANGELOG 2.1.290]. Use **exec form (`args`)** so paths with spaces are safe.

**Lidless hook contract** (must hold for every event):
1. Always exit 0, including on internal errors (wrap everything).
2. Write **nothing** to stdout. Stay silent on stderr too.
3. Never emit `decision`, `continue`, `additionalContext`, `systemMessage`, `permissionDecision`, or `terminalSequence`.
4. Use `type: "command"` with exec form (`command` = absolute path, `args` = list). Set `timeout: 5`. No `async` on `Stop` or `SessionEnd`, since `-p` kills async hooks at teardown [H: DOC-HOOKS]. No `onFailure`, no `asyncRewake`.
5. Finish in under 100 ms and under the 1.5 s `SessionEnd` budget. A throwaway compiled Swift helper that reads stdin, parses JSON, and sends to a socket ran in **0.01–0.04 s** warm and 0.32 s on its very first (cold) exec [H: LOCAL `research-snippets/hookprobe.swift`].
6. Do not register `PreToolUse`, `PermissionRequest`, `PostToolBatch`, or `ConfigChange`. They are not needed, and they are the events where mistakes block work.

### 1.6 Execution semantics

From DOC-HOOKS [H]:
- All matching hooks run **in parallel**.
- An identical handler in several settings files runs once. Plugin and skill copies stay separate, so do not install both a plugin hook and a settings.json hook, or it runs twice.
- Default timeouts: 600 s for `command`/`http`/`mcp_tool`, except 30 s on `UserPromptSubmit`. `SessionEnd` has the 1.5 s budget.
- Matchers: `"*"`, `""`, or omitted match all. A string of `[A-Za-z0-9_ ,|-]` is exact or a list. Anything else is an unanchored JavaScript regex. `Stop` and `UserPromptSubmit` ignore matchers.
- Shell form runs `sh -c`. Exec form (`args` present) spawns directly with no shell.
- **Workspace trust:** in interactive sessions Claude Code *"holds back hooks from every settings file, including your own `~/.claude/settings.json`, until you accept the workspace trust dialog"*. `-p` and SDK sessions treat the folder as trusted.
- Hooks are disabled by `"disableAllHooks": true`, by managed `allowManagedHooksOnly`, by `--bare`, and by `--safe-mode` (narrowed) [H: DOC-SET, DOC-HEADLESS].
- Live reload: *"Direct edits to hooks in settings files are normally picked up automatically by the file watcher."* Plugin changes need `/reload-plugins` or a new session [H: DOC-HOOKS, DOC-PLUGCLI].
- Debugging: `/hooks` shows each hook with its source. The `--debug` log has lines like `Hooks: Stop [cmd] finished with status 0 (31ms)` (2.1.296+) [H: DOC-HOOKS].
- **HTTP hooks** (`type:"http"`) POST the same JSON. Connection refused or non-2xx is a **non-blocking error**, so it is visible noise when Lidless is not running. Prefer the command type [H: DOC-HOOKS].

### 1.7 settings.json structure and safe merging

The user's current `~/.claude/settings.json` has **no `hooks` key**. It contains `enabledPlugins` (vercel, swift-lsp, supabase), `effortLevel`, `modelSettings`, `tui`, `theme`, and `autoMode` [H: LOCAL]. The installed `vercel` plugin already ships hooks (`SessionStart`, `PostToolUse`, `SessionEnd`) in `~/.claude/plugins/cache/claude-plugins-official/vercel/0.50.0/hooks/hooks.json`, which is a live example of plugin hooks coexisting [H: LOCAL].

If the settings.json route is used (fallback), the exact shape is:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command",
                     "command": "/Users/<you>/Library/Application Support/Lidless/bin/lidless-hook",
                     "args": ["claude", "Stop"],
                     "timeout": 5 } ] }
    ],
    "Notification": [
      { "matcher": "permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input|agent_completed",
        "hooks": [ { "type": "command", "command": "/Users/<you>/Library/Application Support/Lidless/bin/lidless-hook",
                     "args": ["claude", "Notification"], "timeout": 5 } ] }
    ]
  }
}
```

Merge algorithm (if ever needed):
1. Read and parse. On parse failure, abort and do not write.
2. For each event, append **one** matcher group, but only if no existing handler has `command == <our helper path>`. Leave other groups untouched.
3. Preserve unknown keys and key order. Use an order-preserving JSON library or a minimal textual splice. `JSONSerialization` with `.sortedKeys` would reorder the user's file.
4. Back up to `settings.json.lidless-bak-<ts>`, write to a temp file in the same directory, `fsync`, then `rename()` atomically. If the path is a symlink, write through to the target.
5. Uninstall removes only groups whose every handler's `command` is ours, then drops event arrays that became empty.
6. Never touch `settings.local.json`. On this machine it contains literal API keys in permission rules, which is one more reason Lidless should not parse or rewrite user config it does not own [H: LOCAL].

Caveat: Claude Code itself rewrites `settings.json` (via `/config`, plugin enable, and similar). Concurrent writes could race [M]. That is a key reason to prefer the plugin route, where Claude Code does all writes itself.

---

## 2. Plugins: ship the hooks as a plugin

Yes. Plugins can ship `hooks/hooks.json`. *"When a plugin is enabled, its hooks merge with your user and project hooks"* [H: DOC-HOOKS, DOC-PLUGMAN].

**Layout** (copy to a stable path, not inside an app bundle that can be translocated or moved):

```
~/Library/Application Support/Lidless/claude-marketplace/
├── .claude-plugin/
│   └── marketplace.json
└── plugins/lidless/
    ├── .claude-plugin/plugin.json
    ├── hooks/hooks.json
    └── bin/lidless-hook          (ad-hoc signed Mach-O helper)
```

`marketplace.json` (`name`, `owner`, and `plugins` are required) [H: DOC-MKT]:

```json
{
  "name": "lidless-local",
  "owner": { "name": "Lidless" },
  "description": "Local marketplace installed by the Lidless menu-bar app",
  "plugins": [ { "name": "lidless", "source": "./plugins/lidless",
                 "description": "Reports agent activity to Lidless. Never blocks Claude." } ]
}
```

`plugin.json` (`name` is the only required key). The name must not start with `claude-` or contain reserved words, and `lidless` is fine [H: DOC-PLUGMAN]:

```json
{ "name": "lidless", "version": "1.0.0",
  "description": "Notifies the Lidless menu-bar app about session start/stop/needs-input. Never blocks.",
  "author": { "name": "Lidless" } }
```

`hooks/hooks.json` (the `"hooks"` wrapper is required in a hooks file) [H: DOC-PLUGMAN]:

```json
{
  "description": "Lidless activity reporter (always exit 0, no stdout)",
  "hooks": {
    "SessionStart":     [ { "hooks": [ { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/bin/lidless-hook", "args": ["claude","SessionStart"],     "timeout": 5 } ] } ],
    "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/bin/lidless-hook", "args": ["claude","UserPromptSubmit"], "timeout": 5 } ] } ],
    "Stop":             [ { "hooks": [ { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/bin/lidless-hook", "args": ["claude","Stop"],             "timeout": 5 } ] } ],
    "StopFailure":      [ { "hooks": [ { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/bin/lidless-hook", "args": ["claude","StopFailure"],      "timeout": 5 } ] } ],
    "Notification":     [ { "matcher": "permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input|agent_completed|quota_auto_resume_fired|quota_auto_resume_stale|quota_auto_resume_disabled",
                            "hooks": [ { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/bin/lidless-hook", "args": ["claude","Notification"],     "timeout": 5 } ] } ],
    "SessionEnd":       [ { "hooks": [ { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/bin/lidless-hook", "args": ["claude","SessionEnd"],       "timeout": 1 } ] } ]
  }
}
```

`${CLAUDE_PLUGIN_ROOT}` is substituted in `command` and `args`, and is also exported to the hook process [H: DOC-PLUGMAN]. In exec form each `args` element is one argument, so `Application Support` (with its space) is safe. One open point: the exec-form docs say `command` is "resolved as an executable on PATH". An absolute substituted path should work, but verify on the first install [M].

**Install and uninstall** (non-interactive; run from the app using the resolved `claude` path) [H: DOC-PLUGCLI]:

```bash
claude plugin marketplace add "$HOME/Library/Application Support/Lidless/claude-marketplace" --scope user --json
claude plugin install lidless@lidless-local --scope user --json
# uninstall
claude plugin uninstall lidless@lidless-local --scope user --json
claude plugin marketplace remove lidless-local --json
```

`--json` prints one JSON object on the last stdout line (2.1.268+, or 2.1.287+ for `marketplace add`). Exit code 0 means success and 1 means failure. A directory-source marketplace is *"read in place"* and is not pinned by `version` [H: DOC-PLUGCLI, DOC-PLUGMAN]. Do not run these commands from inside a Claude Code Bash tool, where `-y` is ignored; it is not needed here anyway because there is no `command` source.

**Plugin vs settings.json:**

| | Plugin | Direct settings.json edit |
|---|---|---|
| Install/uninstall | Official CLI. Claude Code writes its own files. Clean removal | Lidless must parse, merge, and atomically rewrite user JSON |
| Visibility | `/plugin` and `/hooks` label it "plugin: lidless". The user can disable it in one click | Shows as user-settings hook |
| Running sessions | **Only after `/reload-plugins` or a new session** | Picked up live by the file watcher |
| If Lidless.app is deleted | Plugin load error in `/plugin` Errors tab [M] | Every event logs `Failed with non-blocking status code: … No such file` in transcripts |
| SessionEnd budget | Plugin `timeout` does not raise the 1.5 s budget (fine for a fast helper) | Per-hook timeout can raise it |
| Requires `claude` CLI | Yes, at install time | No |

**Recommendation:** use the plugin. Cover sessions that were already running at install time with the session-record polling in §3, and optionally tell the user to run `/reload-plugins`.

---

## 3. Session presence records: `~/.claude/sessions/<pid>.json`

### 3.1 What is documented

From DOC-DIR [H]: *"`sessions/`: holds one small file per running session, used to detect concurrent sessions and crashes. It isn't part of the age-based sweep: Claude Code removes each file when its session exits and clears crash leftovers on the next launch."*

**The JSON schema, including `status`, is not documented.** The supported read path is `claude agents --json` (§3.5). A third-party tool's write-up corroborates the busy/idle/shell/waiting vocabulary and also calls it undocumented [L: https://github.com/OpenAfterHours/abeam/pull/1].

### 3.2 Observed files (read-only `cat`, 2026-10-12 15:17 CEST)

All 8 records belong to live processes, with no stale files [H: LOCAL `ps`]. Each record is accompanied by `<pid>.<sha256>.key` (the messaging peer token, mode 0600). **Lidless must never read those.**

```json
{"pid":96888,"sessionId":"3514aa88-efa8-4a60-97d7-2878eed849d4","cwd":"/Users/tomasnguyen/Developer",
 "startedAt":1791810326817,"procStart":"Mon Oct 12 13:05:23 2026","version":"2.1.296","peerProtocol":1,
 "peerFeatures":["notify_idle","reply_across_default_dirs","artifact_yield"],"kind":"interactive","entrypoint":"cli",
 "pidDomain":"darwin","messagingSocketPath":"/tmp/cc-socks/96888.sock","name":"developer-40","nameSource":"derived",
 "nameSince":1791810326817,"status":"busy","updatedAt":1791810678765,"statusUpdatedAt":1791810678765}

{"pid":24617,"sessionId":"e5b3e311-326c-4b68-847f-51f7e4ee6a7b","cwd":"/Users/tomasnguyen/Desktop/bakalarka",
 "kind":"bg","entrypoint":"cli","name":"Titulná strana bakalárskej práce (2)","nameSource":"peer","jobId":"e5b3e311",
 "status":"idle","statusUpdatedAt":1791323191564, "...": "..."}

{"pid":44386,"sessionId":"99b32bd6-…","kind":"interactive","status":"idle","statusUpdatedAt":1790979977529,
 "updatedAt":1791212724873,"parkedJobId":"e5b3e311", "...": "..."}
```

Snapshot of all records with live signals (signals.py sampled a 15 s window) [H: LOCAL `research-snippets/signals.py`]:

| pid | kind | status | statusAge | tree CPU | caffeinate child | main transcript age |
|---|---|---|---|---|---|---|
| 9220 | interactive | idle | 2.9 d | 0.5 % | no | 1408 s* |
| 23139 | interactive | idle | 2.9 d | 0.5 % | no | 1408 s* |
| 24617 | bg | idle | 5.7 d | 0.9 % | no | 1408 s* |
| 44386 | interactive (parked) | idle | 9.6 d | 0.7 % | no | 6.9 d |
| 55583 | interactive | idle | 5.7 d | 0.5 % | no | 1408 s* |
| 76720 | interactive | **busy** (workflow running) | 5.7 min | **0.1 %** | **yes** | 66 s |
| 96654 | interactive | idle | 3.0 d | 0.7 % | no | 1408 s* |
| 96888 | interactive | **busy** (waiting on this workflow) | 16 min | **18 %** | **yes** | **642 s** |

\* Six idle sessions' transcripts were all modified at **15:04:10**, one second before `powerd` logged `com.apple.powermanagement.lidopen` at 15:04:11. Idle sessions re-appended metadata entries (`last-prompt`, `ai-title`, `mode`, `permission-mode`, `atis-latch`, `pr-link`) around wake. **Transcript mtime is therefore not a reliable work signal on its own** [H: LOCAL observation; M: cause].

### 3.3 Full field schema (from the 2.1.296 reader and writer code) [M: BIN; fields marked * observed locally, H]

| Field | Meaning |
|---|---|
| `pid`*, `procStart`* | `procStart` is exactly `TZ=UTC LC_ALL=C ps -o lstart= -p <pid>` trimmed. Readers use pid + procStart to reject PID reuse [H: LOCAL compared 3 pids] |
| `sessionId`* | Conversation UUID, which is the transcript filename. Changes on `/clear` and `/resume` [M] |
| `cwd`* | **Launch** cwd. Transcript entries carry the current cwd, which can differ: 76720's file says `/Users/tomasnguyen`, while entries say `/Users/tomasnguyen/Developer/projects portfolio` [H: LOCAL] |
| `startedAt`*, `updatedAt`*, `statusUpdatedAt`* | Epoch ms. **`statusUpdatedAt` changes only when `status` or `waitingFor` is (re)written. It is rewritten when the computed status or waitingFor changes, so a long `busy` keeps an old timestamp** [H: BIN `g$e` + LOCAL] |
| `kind`* | `interactive` \| `bg` \| `daemon` \| `daemon-worker` [H: BIN enum] |
| `entrypoint`* | `cli`, `claude-desktop`, `claude-desktop-3p`, `local-agent` (desktop surfaces), `claude-vscode`, `sdk-ts`, `sdk-py`, `remote`, ... [M: BIN] |
| `status`* | `busy` \| `shell` \| `idle` \| `waiting` [H: BIN enum `["busy","shell","idle","waiting"]`] |
| `waitingFor` | Present when `status:"waiting"`: `permission prompt`, `input needed`, `dialog open`, `sandbox request`, `worker request`, `goal proposal` [H: BIN] |
| `name`*, `nameSource`*, `nameSince`*, `formerNames` | `nameSource` ∈ `user`, `peer`, `derived` (auto `dirname-xx`), `collision`, `auto`, `hook`. `derived` names like `developer-40` are not human friendly |
| `jobId`* | Present when `kind:"bg"`: the background job short id = `~/.claude/jobs/<id>` |
| `parkedJobId`* | The interactive session moved its conversation into that background job (`←` or `/background`). Claude's own reader **skips parked records**, and `claude agents --json` omits pid 44386 [H: BIN + LOCAL] |
| `spare` | A pre-warmed background process that has not been claimed. Ignore it |
| `bridgeSessionId` | Remote Control connection id when RC is active [M] |
| `messagingSocketPath`*, `peerProtocol`*, `peerFeatures`* | Cross-session messaging (§3.7) |
| `state`, `detail`, `tempo` (`active`\|`idle`\|`blocked`), `needs` | Written by sessions only while **agent view** is open (`~/.claude/sessions/.fleetview-heartbeat` touched within the last 5 s); `detail` is a Haiku summary [M: BIN]. Do not touch the heartbeat file |
| `pidDomain`*, `tmux`, `hostSessionId`, `logPath`, `agent` | Misc. `tmux` is set when running inside tmux |

### 3.4 How `status` is computed (2.1.296)

Interactive TUI path, decoded from BIN [H for the logic as read; names are minified]:

```js
function eve(h){
  const T = waitingReason(h);               // see below
  if (T !== undefined) return {status:"waiting", waitingFor:T, working:false};
  return {status: (h.isLoading || h.delegatedActive) ? "busy" : "idle", waitingFor: undefined, working: h.isQueryActive};
}
function waitingReason(h){
  if (h.queuedElicitation) return "input needed";
  if (h.topDialogWaitingFor !== undefined) return h.topDialogWaitingFor; // registry; unknown dialogs default to "permission prompt"
  if (h.pendingWorkerRequest) return "worker request";
  if (h.pendingSandboxRequest) return "sandbox request";
  if (h.isShowingLocalJSXCommand && !h.isResponseStreaming && !h.delegatedActive) return "dialog open";
}
// then: status = (status==="idle" && hasBackgroundShellTasks) ? "shell" : status
// and:  if (status==="busy") acquireSleepInhibitor()   // caffeinate, see §6.3
```

The SDK-hosted path (Desktop, VS Code, `-p`) maps `{running:"busy", requires_action:"waiting", idle:"idle"}`. `waitingFor` is `"input needed"` for AskUserQuestion/dialog tools and otherwise `"permission prompt"` [M: BIN].

Meaning for Lidless:
- **`busy`** covers a running turn **or** running background subagents and workflows. Docs: *"A running subagent, workflow, or monitor counts as working, and so does a pending session-scoped scheduled task"* [H: DOC-AGENTS].
- **`shell`** means Claude is idle but a background shell (dev server, `tail -f`) is alive. Treat it as **not working** for sleep decisions; dev servers run forever.
- **`waiting`** means it needs the human. With the lid closed, nobody can answer, so push once, then treat it as "not working" after a grace period.
- **`idle`** means done.

### 3.5 The supported interface: `claude agents --json`

Documented as *"the supported way to read session state from outside Claude Code, for example from a status bar"* [H: DOC-AGENTS]. Changelog: added in 2.1.145; `waitingFor` in 2.1.162; `--all`, `id`, `state` in 2.1.169; blocked prompts shown as needs-input in 2.1.212; the raw-mode TTY bug fixed in 2.1.257 [H: CHANGELOG].

| Field | Present | Values |
|---|---|---|
| `cwd`, `kind`, `startedAt` | always | `kind`: `interactive` \| `background` |
| `id` | background | short id (`claude attach/logs/stop <id>`) |
| `state` | background | `working`, `blocked`, `done`, `failed`, `stopped` |
| `pid`, `status` | while the process is alive | `busy`, `waiting`, `idle` (docs list three values; how `shell` is surfaced is unverified [L]) |
| `waitingFor` | `status=waiting` | as above |
| `sessionId`, `name` | when set | |

Local run (`DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 claude agents --json --all < /dev/null`):
- Exit 0, 19 entries: 13 background sessions with `state` (done/stopped) and 6 live interactive sessions with `status`.
- **Parked pid 44386 omitted.**
- **0.17–0.18 s** wall, 0.12 s user CPU.
- **No files under `~/.claude` modified** (checked with `find -newer marker`) [H: LOCAL].

Sample entries:

```json
{"pid":24617,"id":"e5b3e311","cwd":"/Users/tomasnguyen/Desktop/bakalarka","kind":"background","startedAt":1791212730037,
 "sessionId":"e5b3e311-326c-4b68-847f-51f7e4ee6a7b","name":"Titulná strana bakalárskej práce (2)","status":"idle","state":"done"}
{"pid":76720,"cwd":"/Users/tomasnguyen","kind":"interactive","startedAt":1791719069628,
 "sessionId":"fc061117-c7f7-4b91-9732-b6d60a05cd65","name":"tomasnguyen-3f","status":"busy"}
```

Notes:
- GUI apps do not inherit the shell `PATH`, so resolve the absolute binary: `~/.local/bin/claude` (symlink), `CLAUDE_CODE_EXECPATH` captured from a hook, or `/bin/zsh -lc 'command -v claude'` once.
- Run it with stdin `/dev/null`.
- Background `state` semantics [H: DOC-AGENTS]: `working` = turn running or between self-driven steps (`/loop`, CI wait); `blocked` = needs the human; `done` = finished and ready for the next prompt; `failed` and `stopped`.

### 3.6 Lifecycle, update, and deletion

- **Created** at session registration with `status` unset until the first status write. **Deleted** synchronously in `process.on("exit")` and also in the cleanup handler [H: BIN]. Crash leftovers are cleared on the next launch [H: DOC-DIR]. 2.1.246 fixed *"headless sessions not cleaning up stale entries in `~/.claude/sessions` left by sessions that exited uncleanly"* [H: CHANGELOG].
- **Liveness check the same way Claude does:** `kill(pid, 0)` (sends no signal) or `proc_pidinfo`, **plus** a `procStart` match to defeat PID reuse [H: BIN `_a()` uses `process.kill(n,0)`; `isSameProcess(pid, procStart)`].
- Not registered for agent-team teammates (an `agentId` team context) or for nested child sessions without persistence (`CLAUDE_CODE_CHILD_SESSION`) [M: BIN `FU()` → `Jc()`].
- `-p` sessions bind an inbox socket "like an interactive one … and appear in the listing", which implies they also register a record. `--bare` does neither [M: DOC-XMSG + DOC-HEADLESS]. Docs say *"`--bare` … will become the default for `-p` in a future release"*, so future `-p` runs may be invisible to both hooks and records [H: DOC-HEADLESS].

### 3.7 Background ("bg") sessions, daemon, and jobs

**Process tree** observed locally [H: LOCAL `ps`]:
```
launchd(1) ─ ClaudeCode.app/.../claude --bg-pty-host /tmp/cc-daemon-501/0a5f4ad1/pty/e5b3e311.sock …   (pid 24556)
              └─ ~/.local/share/claude/versions/2.1.289 --session-id e5b3e311-… --fork-session --resume <jsonl>   (pid 24617, kind:"bg")
Terminal ─ login ─ zsh ─ claude -c (44386, parked) ─ claude daemon run --origin transient --spawned-by {...}   (35816 = supervisor)
                                                     └─ claude bg-pty-host … --bg-spare …  └─ claude bg-spare   (pre-warmed spare)
```

Exclude `claude daemon run`, `claude bg-pty-host`, and `claude bg-spare` from "agent" counts. Only pids with a session record are sessions.

**Files** [H: LOCAL; documented as "not a stable interface" in DOC-AGENTS]:
- `~/.claude/daemon.lock` holds `{pid, version, startedAt, origin:"transient", spawnedBy:{label,cwd,pid}, procStart, launchTarget}`.
- `~/.claude/daemon.status.json` holds `{supervisorPid, supervisorProcStart, writtenAt, workers:{}}`.
- `~/.claude/daemon/roster.json` has `{proto:1, supervisorPid, updatedAt, workers:{<shortId>:{pid, procStart, sessionId, rendezvousSock, ptySock, cliVersion, startedAt, attempt, cwd, dispatch:{source:"slash", launch:{mode:"resume", fork:true, …}, seed:{intent,name}}, rvAuth, ptyAuth, replPid, replProcStart}}}`. **`rvAuth` and `ptyAuth` are secrets.**
- `~/.claude/jobs/<shortId>/state.json` has `{state, detail, tempo, inFlight:{tasks,queued,kinds,drainableMonitors}, tokens, output:{result}, children, needs, suggestedReply, template:"bg", intent, name, nameSource, sessionId, resumeSessionId, daemonShort, cliVersion, cwd, createdAt, updatedAt, firstTerminalAt, lastTerminalAt, backend:"daemon", …}`.
  - Observed `state` values: `done` (10), `stopped` (3). The reader enum also has `starting`, `running`, `resuming`, `adopted`, `crashed`, `working`, `blocked`, `failed` [M: BIN].
  - `output.result` and `detail` are good human summaries for push text.
- `~/.claude/jobs/<id>/timeline.jsonl` has lines `{"at": ISO, "state": "working"|"blocked"|"done", "detail": "...", "text": ""}`.
- `~/.claude/jobs/<id>/adopt.json` lists background shells handed over from an exiting process (pid, procStart, command). Example: an orphaned `npm run dev:preview` (pid 16035, ppid 1) still alive from a dead session.

**Supervisor behavior** [H: DOC-AGENTS]:
- It stops idle or finished unattached sessions after about 1 h (`bg retire …: idle-prompt, idle 73m` in `~/.claude/daemon.log`).
- It restarts crashed ones.
- *"Sessions are also preserved when your machine sleeps … the supervisor reconnects to them instead of treating the time gap as idle"*.
- Shutdown stops them, and they show `failed` if under 48 h or `stopped` if over 48 h.
- `CLAUDE_CONFIG_DIR` creates a separate supervisor instance.

**`peerFeatures`:**
- `notify_idle` means the session supports the `SendMessage` `notify_when_idle` subscription (one notice when the session next goes idle or exits) over its Unix socket `/tmp/cc-socks/<pid>.sock` (2.1.236+) [H: DOC-XMSG; BIN constant `Uvr="notify_idle"`].
- `artifact_yield` and `reply_across_default_dirs` are peer-protocol capabilities [M].

This is a peer protocol, not a public API. Lidless should not speak it.

---

## 4. Telling a session is truly active without hooks

| Signal | Correlation with real work | Cost | Verdict |
|---|---|---|---|
| Record `status` (or `agents --json`) | Exact for "turn or delegated work in flight". **Can stay `busy` for hours after background work dies** (§4.1) | ~0 (file watch) | **Primary** |
| `caffeinate` child of the claude pid (`PreventUserIdleSystemSleep`, name `caffeinate command-line tool`) | Equals `status=="busy"` (+30 s). Same staleness | `IOPMCopyAssertionsByProcess` + `sysctl` ppid | Confirmation only. Verified: assertions found with parent pids 96888 and 76720 [H: LOCAL `research-snippets/assertions.swift`] |
| Process-tree CPU (claude + descendants) | **Weak.** A busy session running a workflow showed 0.1 %; a busy TUI waiting on a workflow showed 18 %; idle sessions 0.5–0.9 % (MCP children and TUI timers) | `proc_pidinfo` per pid | Stall heuristic only |
| Main transcript mtime | **Weak.** Busy-with-workflow main file 642 s old; idle files bumped on wake | stat | Do not use alone |
| Max mtime over `~/.claude/projects/<slug>/<sessionId>.jsonl` **and** `<sessionId>/subagents/**` (and `workflows/`, `tool-results/`) | Good progress signal: workflow subagent files under `…/fc061117-…/subagents/workflows/wf_7b508d34-bbf/agent-*.jsonl` were updated every few seconds while busy [H: LOCAL] | FSEvents on `~/.claude/projects` | **Use for the stall guard** |
| Active Bash-tool children: `/bin/zsh -c source ~/.claude/shell-snapshots/snapshot-zsh-…` under the claude pid | Means a command is running (build, tests). Background shells look the same and can live forever | ps tree | Stall-guard input; exclude `shell`-status sessions |
| Last transcript entry | `assistant` with `stop_reason:"tool_use"` = mid-turn; `system`/`turn_duration` = a turn just ended (§5) | Tail read | Good "finished" confirmation |

### 4.1 Case study: the "13 h busy" session (pid 76720) [H: LOCAL transcript + workflow JSON + `pmset -g log`]

| Time (CEST) | Event |
|---|---|
| 01:25:14 | Status written `busy` (`statusUpdatedAt` 1791761114630) |
| 01:27:03 | Main turn launched background `Workflow` `wf_7b508d34-bbf`. The turn ended at 01:27:06 with `system/turn_duration` `pendingWorkflowCount: 1` |
| 01:29:31 | Workflow ended `status: "killed"`, `error: "Error: Workflow aborted"` (durationMs 148554) |
| 01:29:49 | `Entering Sleep state due to 'Clamshell Sleep'`. Claude's caffeinate (PID 90043) was holding `PreventUserIdleSystemSleep` and did not prevent it |
| 01:48 → 15:01 | During DarkWakes, Claude kept respawning caffeinate every ~4 min (`ClientDied … 00:03:59` lines). It still believed it was busy |
| 15:04:11 | Lid opened |
| 15:04:42 | User typed "Resume the paused workflow …". A real workflow ran again, so status stayed `busy`. It was rewritten at 15:21:54 |

Conclusion: `busy` persisted for about 13.5 h with **no transcript or subagent writes**. Lidless must apply a **progress timeout**, e.g. "busy, no writes in the session's project subtree for ≥ 20 min, no running Bash-tool child, and tree CPU < 1 %" counts as **stalled**. A stalled session should not keep the Mac awake, and Lidless should notify the user that it looks stuck.

---

## 5. Building a human-friendly phone notification

### 5.1 Where the transcript lives

- `~/.claude/projects/<project>/<sessionId>.jsonl`, where `<project>` is the launch cwd with every non-alphanumeric character replaced by `-`. Names over 200 characters are truncated and a hash is appended [H: DOC-SESS, DOC-DIR].
- Prefer the hook's `transcript_path`. Otherwise **glob `~/.claude/projects/*/<sessionId>.jsonl`**, because the cwd can change and the slug rule has edge cases.
- Subagents live at `<project>/<sessionId>/subagents/agent-<id>.jsonl` (+ `.meta.json`, e.g. `{"agentType":"workflow-subagent","description":"…","workflowPhase":"Verify","spawnDepth":1}`). Workflows live at `<project>/<sessionId>/workflows/wf_*.json` with `{runId, status:"completed"|"killed", summary, durationMs, totalTokens, …}`. Large outputs go in `tool-results/` [H: LOCAL, DOC-DIR].
- Files can be large (up to 45 MB here), so **read from the end** (last ~256 KB) and scan lines backwards.
- `cleanupPeriodDays` defaults to 30 [H: DOC-SET].

### 5.2 JSONL entry types

Observed across the 25 most recent transcripts [H: LOCAL `research-snippets/tx_types.py`]:

| `type` | Count | Use |
|---|---|---|
| `assistant` | 9494 | `message.{model,id,role,content[],stop_reason,usage}`. `content[].type` ∈ `text`, `thinking`, `tool_use`. `stop_reason` ∈ `tool_use` (8909), `end_turn` (577), `stop_sequence`, null. Plus `uuid`, `parentUuid`, `timestamp` (ISO UTC), `isSidechain`, `sessionId`, `cwd`, `gitBranch`, `version`, `entrypoint`, `requestId` |
| `user` | 5433 | `message.content` is a string (typed prompt) or `[{type:"tool_result"\|"text"\|"image"}]`. Human prompts have `origin:{"kind":"human"}`, `promptSource:"typed"`, `turnPosition:{promptIndex,turnIndex}`. Others: `origin.kind` = `task-notification` / `peer` |
| `system` | 500 | `subtype`: **`turn_duration`** (`durationMs`, `messageCount`, optional `pendingWorkflowCount`, `pendingBackgroundAgentCount`, `sessionKind`); **`away_summary`** (`content` = a friendly recap written about 3 min after a turn when you are away, "disable recaps in /config"); `compact_boundary`; `stop_hook_summary` (`hookCount`, `preventedContinuation`, `stopReason`); `local_command`; `informational` |
| `attachment` | 7496 | `attachment.type` e.g. `total_tokens_reminder`, `queued_command`, `hook_success`, `hook_system_message`, `task_reminder`, … (ignore) |
| `queue-operation` | 914 | `operation` ∈ `enqueue`/`dequeue`/`remove`, `content` (e.g. `<task-notification>` XML) |
| `last-prompt` | 1494 | `{lastPrompt, leafUuid}`. Last human prompt text |
| `ai-title` | 1474 | `{aiTitle}`, e.g. `"Portfolio cursor reveal with blowout"` |
| `custom-title` | 3 | `{customTitle}` (user `/rename`) |
| `agent-name` | 639 | `{agentName}` (background sessions) |
| `cost-state` | 34 | `{totalCostUSD, totalDuration, totalLinesAdded, totalLinesRemoved, modelUsage}` |
| `continued-in` | 5 | `{continuedInSessionId}` |
| `mode`, `permission-mode`, `atis-latch`, `pr-link`, `file-history-*` | many | Metadata (`pr-link`: `{prNumber, prUrl, prRepository}`) |

The schema is undocumented except for the file's purpose [H: DOC-DIR]. Parse defensively.

### 5.3 Recipe for the push text

- **Title** (first available): latest `custom-title.customTitle` → latest `agent-name.agentName` (bg) → latest `ai-title.aiTitle` → record `name` if `nameSource` ∈ {`user`,`peer`,`auto`} → `basename(cwd)`. Derived names like `developer-40` are poor.
- **Project:** `basename` of the **entry** `cwd` from the last assistant entry, which beats the record's launch cwd. Add `gitBranch` if not `HEAD`.
- **Body:**
  - Use `Stop.last_assistant_message`.
  - Fallback 1: the last `assistant` entry with `isSidechain:false`, `stop_reason:"end_turn"`, joining its `text` blocks.
  - Fallback 2: for bg jobs, `jobs/<id>/state.json` `output.result` or `detail`.
  - Collapse whitespace and strip Markdown. Cap at about 180 characters, because pushes truncate.
- **Duration:**
  - Preferred: the `system/turn_duration.durationMs` that follows the final assistant entry. It is written just after the turn, so re-read 1–2 s after `Stop`.
  - Otherwise: Lidless's own timer from `UserPromptSubmit` (or the record's busy transition) to the finish event.
- **Extras:** a PR link from `pr-link`; cost from `cost-state` if present.
- **Needs-input body:** `Notification.message` (e.g. "Claude needs your permission to use Bash") or `waitingFor`.
- **Error body:** `StopFailure.error` (e.g. `rate_limit`) + `error_details`.
- **Privacy:** assistant text can contain code or secrets (transcripts are unencrypted [H: DOC-DIR]). Offer a "titles only" push mode.

---

## 6. Overlapping Claude Code features (October 2026)

### 6.1 Built-in local notifications

- `preferredNotifChannel` ∈ `auto` | `terminal_bell` | `iterm2` | `iterm2_with_bell` | `kitty` | `ghostty` | `notifications_disabled`. It covers task completion and waiting permission prompts, and only fires when you appear away from the terminal [H: DOC-SET, DOC-TERM, BIN].
- The Desktop app sends an OS notification when a Code session finishes and you are not viewing it [H: DOC-DESK].
- Agent view sends `agent_needs_input` / `agent_completed`, but only while it is open [H: DOC-AGENTS].
- Terminals implementing the OSC 7501 "Program Status Protocol" show working/waiting/done (2.1.295+) [H: DOC-TERM].

These are local-only and not useful with the lid closed.

### 6.2 Remote Control and mobile push (overlaps Lidless goal 3)

- **Remote Control** connects the Claude iOS/Android app or claude.ai/code to a **local** session. Ways to start it:
  - `claude remote-control` (server mode)
  - `claude --remote-control`
  - `/remote-control` (or `/rc`) in the CLI, the VS Code extension, or the Desktop Code tab
  - auto-connect via `"remoteControlAtStartup": true`

  It requires a Pro/Max/Team/Enterprise claude.ai login (no API keys or custom `ANTHROPIC_BASE_URL`) [H: DOC-RC].
- **Push:** with RC connected, Claude can push to the phone. The `/config` toggles are `agentPushNotifEnabled` ("Push when Claude decides", default false) and `inputNeededNotifEnabled` ("Push when actions required", default false). *"Claude decides when to push … there is no per-event configuration."* Pushes are skipped while you are focused on the terminal [H: DOC-RC, DOC-SET]. A `PushNotification` tool exists (added in 2.1.110) [H: CHANGELOG].
- **`CLAUDE_CLIENT_PRESENCE_FILE`** (2.1.181+): while this marker file exists, RC pushes are suppressed, and it is checked once per push event [H: DOC-ENV, DOC-RC]. Lidless could create the file while the lid is open and the user is active, and delete it when the lid closes. That needs an env var in Claude's environment (settings.json `env`), which is optional and touches user config.
- RC limits:
  - The local `claude` process must keep running. RC *"reconnects automatically when your machine comes back online"* after sleep.
  - In server mode, Claude Code gives up after about 10 min of network outage.
  - The 2.1.287 changelog fixed *"Remote Control sessions … stopping mid-turn when the Mac went to idle sleep"*.
  - While a remote-controlled turn runs, Claude Code holds its sleep inhibitor, capped at 1 h, plus up to 15 min while waiting on the user [M: BIN constants `GI=3600000`, `VI=900000`].
- **Dispatch** (Desktop, Pro/Max only): a push when a Dispatch-spawned Code session finishes or needs approval [H: DOC-DESK].
- **Cloud and teleport:** `claude --cloud "task"` creates a *new* cloud session, and `--teleport` pulls cloud to local. *"You can't push an existing terminal session to the cloud"* [H: DOC-WEB]. So Lidless cannot offload a running local session before shutdown.

**Implication:** Claude's own push only covers Claude, needs RC plus a subscription, and fires when the model decides. Lidless's push is agent-agnostic and deterministic. Offer the user a choice per agent: "Claude: use Lidless push (default) or rely on Claude Remote Control push". Avoid double notifications by enabling only one.

### 6.3 Claude Code's own keep-awake (verified)

From BIN, class `Vo` [H]:
- Constants `Qs=300`, `Js=240000`, `Zs=30000`.
- macOS only. It spawns `["caffeinate", ["-i", "-t", "300"]]`, restarts it every 240 s while the refcount is above 0, and kills it (SIGKILL) 30 s after release.
- It is acquired when the presence `status === "busy"`, and also by the Remote Control keep-awake logic.

Local evidence [H]:
- `ps`: `caffeinate -i -t 300` children of pids 76720 and 96888, both `busy`.
- `pmset -g assertions`: `pid …(caffeinate) PreventUserIdleSystemSleep "caffeinate command-line tool"`.
- `pmset -g log`: `ClientDied … 00:03:59` every 4 min.
- Clamshell sleep still happened at 01:29:49.

The 2.1.83 changelog fixed *"`caffeinate` process not properly terminating when Claude Code exits"* [H: CHANGELOG]. There is no user setting to change this behavior [M: BIN; no env/setting found].

**Implications for Lidless:**
- Claude's `-i` assertion does not cover lid-close (clamshell) sleep, so Lidless must provide that.
- Lidless's "no agent working" logic must not depend on system-wide idle-sleep assertions. A stale busy session keeps one forever.

### 6.4 VS Code, JetBrains, and Desktop entrypoints

- `~/.claude/settings.json` (hooks and enabled plugins) is **shared by the CLI, the VS Code extension, and Desktop local Code sessions** [H: DOC-VSC, DOC-DESK].
- Desktop and VS Code host Claude Code through the Agent SDK `canUseTool` path. `permission_prompt` fires about 6 s after a request (2.1.233+) [H: DOC-HOOKS].
- The records' `entrypoint` distinguishes `claude-desktop` and `claude-vscode`. The fleet code maps them to "desktop" and "vscode" surfaces [M: BIN].
- Desktop runs its own bundled binary, which can be an older version (here 2.1.289). Features may lag [H: LOCAL path].
- The VS Code extension is **not installed** on this machine and the Desktop app was not running, so neither was verified live [H: LOCAL].
- JetBrains runs the CLI in the IDE terminal (expected `entrypoint: "cli"`) [L].

### 6.5 Headless `claude -p` and subagents

- `-p` runs hooks (`Stop`, `SessionEnd`) unless `--bare` is used. Async hooks are killed at teardown. There is no trust dialog [H: DOC-HOOKS, DOC-HEADLESS].
- `-p` and SDK sessions are excluded from `--continue` and the picker but can be resumed by ID [H: DOC-SESS].
- Subagents fire `SubagentStart` and `SubagentStop`, including internal and workflow subagents. While any subagent or workflow runs, the parent's record stays `busy` [H: DOC-HOOKS + LOCAL].

---

## 7. After sleep or shutdown: resume semantics

- **Sleep:** processes freeze and resume.
  - Background sessions are preserved, and the supervisor detects clock jumps (2.1.142).
  - Changelog fixes from 2.1.200 to 2.1.290 handle streams, subagents, and workflows interrupted by sleep. Example: *"Fixed background agents failing with 'Agent stalled' and Workflow tool subagents restarting from their prompt when a Mac woke from sleep"* (2.1.290) [H: CHANGELOG].
  - A request mid-flight at sleep may need a retry. Most are auto-continued [M].
- **Shutdown:**
  - Interactive TUI sessions die. `claude --continue` (most recent session in the cwd) or `claude --resume <sessionId|name|transcript-path>` restores the history, model, permission mode, active goal, and unexpired scheduled tasks.
  - **A tool that was running is marked cut off.** Background Bash and monitor tasks are not restored. Background subagents and workflows appear as unfinished notes.
  - `CLAUDE_CODE_RESUME_INTERRUPTED_TURN=1` (SDK mode) auto-continues an interrupted turn, bounded by `CLAUDE_CODE_RESUME_INTERRUPTED_TURN_MAX_AGE_MS` [H: DOC-SESS, DOC-ENV].
  - Background sessions show `failed` (under 48 h, reply or attach to restart) or `stopped` ("ended while the background service was off"; press Enter twice). `claude respawn <id>` reruns the original prompt [H: DOC-AGENTS].
  - Rate-limit waits: after more than about 30 min of sleep, `quota_auto_resume_stale` means Claude waits for Enter instead of auto-continuing [H: DOC-HOOKS].

**Implications:** prefer sleep. Shut down only when every live session is `idle`/`shell` (and bg `state` ∈ `done`/`failed`/`stopped`). Before shutting down, write a resume manifest such as `{sessionId, cwd(entry), title, entrypoint, kind, jobId}` per session, so Lidless can offer "Reopen" on next login (open Terminal with `cd <cwd> && claude --resume <sessionId>`, or `claude attach <id>` for bg). A `waiting` session should never trigger shutdown, because the prompt would be lost; sleep instead.

---

## 8. Recommendations for Lidless (Claude Code adapter)

### 8.1 Architecture: four layers, cheapest first

1. **L1, passive presence (always on, zero install).**
   - Watch `~/.claude/sessions/` with `DispatchSource.makeFileSystemObjectSource` on the directory fd (or FSEvents), read-only.
   - Parse `<pid>.json` with the regex `^\d+\.json$` and ignore `*.key` and `.fleetview-heartbeat`.
   - Validate liveness with `kill(pid,0)` (no signal delivered) or `proc_pidinfo`, plus a `procStart` match.
   - Ignore `spare==true`, `parkedJobId != nil`, and `kind ∈ {daemon, daemon-worker}`.
   - Map `status` → {busy, waiting(waitingFor), idle, shell}.
2. **L1b, supported cross-check.** Poll `claude agents --json --all` every 10–15 s while the lid is closed, and every 60 s otherwise.
   - Use it to get bg `state` (`working/blocked/done/failed/stopped`) and to survive schema drift in the record files.
   - If both sources disagree, trust `agents --json` for state and L1 for timing.
3. **L2, event hooks (plugin `lidless@lidless-local`).**
   - Provides `UserPromptSubmit` (turn start), `Stop` (candidate finish, with `last_assistant_message` and `background_tasks`), `StopFailure`, `Notification` (needs-input and idle confirmation), and `SessionStart`/`SessionEnd`.
   - The helper sends `{event, agent:"claude", pid:$CLAUDE_PID, entrypoint:$CLAUDE_CODE_ENTRYPOINT, execPath:$CLAUDE_CODE_EXECPATH, receivedAt, payload}` to Lidless.
   - Transport: a **Unix stream socket** at `~/Library/Application Support/Lidless/agent.sock` with a 250 ms connect/send timeout. Keep `sun_path` under 104 bytes.
   - On failure, append the event to `~/Library/Application Support/Lidless/spool/` and exit 0.
   - Do **not** use `SOCK_DGRAM`: `net.local.dgram.maxdgram` is 2048 bytes here, and Stop payloads can be larger [H: LOCAL `sysctl`].
   - Cap the payload at about 64 KB.
4. **L3, progress and stall guard.**
   - Track max mtime over `projects/*/<sessionId>.jsonl` and `projects/*/<sessionId>/**` via FSEvents.
   - Track process-tree CPU delta and the presence of Bash-tool children (`zsh -c source …/shell-snapshots/…`).
   - Optionally use the caffeinate child via `IOPMCopyAssertionsByProcess`.

### 8.2 Per-session state machine

| From → To | Trigger | Lidless action |
|---|---|---|
| any → WORKING | record `busy`, or `UserPromptSubmit` hook | Mark working and start the turn timer |
| WORKING → NEEDS_INPUT | record `waiting` (immediate) or `Notification` `permission_prompt`/`elicitation_*`/`agent_needs_input`, or bg `state:"blocked"` | Push "Needs you: <title> — <message/waitingFor>" (once per wait). After a grace period (10–15 min, configurable) the session no longer counts as working |
| WORKING → FINISHED | record `busy→idle`/`shell` **and** a `Stop` was seen this turn (or the transcript tail shows `system/turn_duration` after the last human prompt). Debounce 3–5 s with no new `UserPromptSubmit` or busy, so a `/goal`/Stop-hook continuation is not misread | Push "Done: <title> (<duration>) — <summary>". If `Stop.background_tasks` is non-empty and still running, wait |
| WORKING → INTERRUPTED | `busy→idle` with no `Stop` (user Esc, or a remote interrupt via RC) | No push, or a quiet one |
| WORKING → ERROR | `StopFailure` | Push "Stopped: rate_limit/overloaded/…". For `rate_limit`, mark it "paused until reset" and do not keep the Mac awake for it |
| WORKING → STALLED | `busy` but no subtree writes for ≥ 20 min, no Bash-tool child, tree CPU < 1 % | Push "Looks stuck", then treat as not working |
| any → GONE | record deleted, pid dead, or `SessionEnd` | Drop it. Record for the resume manifest |
| `idle_prompt` Notification | about 60 s after finish with no background agents | Use as a settle confirmation. Do not push twice |

**"No agent working"** (Claude part of goal 4): every live Claude session is IDLE, SHELL, ERROR(paused), STALLED, GONE, or NEEDS_INPUT past its grace period, **and** every bg job has `state` ∈ {done, failed, stopped} or blocked past grace. Then prefer **sleep**. Shut down only if no session is NEEDS_INPUT, and only after writing the resume manifest.

### 8.3 Swift model for the session record (tolerant decoding)

```swift
struct ClaudeSessionRecord: Decodable {
    let pid: Int32
    let sessionId: String?
    let cwd: String?
    let startedAt: Double?
    let procStart: String?          // "Mon Oct 12 13:05:23 2026" = TZ=UTC `ps -o lstart=`
    let version: String?
    let kind: String?               // interactive | bg | daemon | daemon-worker
    let entrypoint: String?         // cli | claude-desktop | claude-vscode | sdk-ts | ...
    let status: String?             // busy | shell | idle | waiting   (undocumented)
    let waitingFor: String?         // permission prompt | input needed | dialog open | sandbox request | worker request | goal proposal
    let statusUpdatedAt: Double?
    let updatedAt: Double?
    let name: String?
    let nameSource: String?
    let jobId: String?
    let parkedJobId: String?
    let spare: Bool?
    let bridgeSessionId: String?    // Remote Control connected
}
// procStart check: format kinfo_proc.kp_proc.p_starttime in UTC with strftime("%a %b %e %H:%M:%S %Y")
```

### 8.4 Install, uninstall, and UX

- On first run, explain the plugin. Call `claude plugin marketplace add …` and `claude plugin install lidless@lidless-local --scope user --json` using the resolved absolute `claude` path. Afterwards, tell the user that already-open sessions pick it up after `/reload-plugins` or a restart; L1 covers them in the meantime.
- Provide "Remove Claude integration", which runs uninstall plus `marketplace remove`. Also remove the plugin folder.
- Detect `disableAllHooks`, `allowManagedHooksOnly`, or a missing plugin (`claude plugin list --json`) and degrade to L1, L1b, and L3 silently.
- Never write: `~/.claude/sessions/**`, `.fleetview-heartbeat`, `jobs/**`, `daemon/**`, `settings.local.json`, or any `.key` file. Never read `.key` files, `roster.json` auth fields, or `CLAUDE_CODE_MESSAGING_TOKEN`.

### 8.5 "Pause other apps" exemptions (Claude-specific)

For each live Claude session pid, exempt:
- the pid itself and **its entire descendant tree**: MCP servers (`uv`/python here), Bash-tool shells, build tools, `caffeinate`;
- **its ancestors up to the GUI host**: `Terminal.app` (pid 44124 here), iTerm2, VS Code, Cursor, or `Claude.app`;
- the supervisor stack: `claude daemon run`, `claude bg-pty-host`, `claude bg-spare`.

Why the GUI host: stopping it would stop draining the PTY or stdio pipe. The TUI redraws constantly, so the agent would block on write [M: reasoning about PTY back-pressure; not tested]. Background sessions are hosted by `bg-pty-host` under launchd, so they keep running even if Terminal is paused [H: LOCAL process tree].

### 8.6 Minimal hook helper behavior

```
read stdin (cap 1 MB) → parse JSON leniently (on failure keep raw size only)
event := argv[2]; agent := argv[1]
env  := CLAUDE_PID, CLAUDE_CODE_SESSION_ID, CLAUDE_CODE_ENTRYPOINT, CLAUDE_CODE_EXECPATH, TERM_PROGRAM, __CFBundleIdentifier
truncate last_assistant_message to 4 KB; drop transcript contents; never include tokens
try connect(AF_UNIX, SOCK_STREAM, agent.sock) with SO_SNDTIMEO=250ms → write one JSON line → close
else write spool/<epochms>-<pid>-<event>.json (O_CREAT|O_EXCL, 0600)
exit(0)    // ALWAYS; nothing on stdout or stderr
```

---

## 9. Risks / unknowns

1. **Undocumented schema.** The record `status`, `waitingFor`, and `statusUpdatedAt` fields, the transcript entry types, and `jobs/*/state.json` are internal. `jobs` files are explicitly "not a stable interface" [H: DOC-AGENTS]. Mitigation: tolerant decoding, a cross-check against `claude agents --json`, and a version-gated parser (record `version`).
2. **Stale `busy`.** Demonstrated for 13.5 h after a killed background workflow plus clamshell sleep. Claude Code also held its idle-sleep assertion throughout. A stall guard is mandatory, and it risks false "stuck" verdicts during long silent commands (e.g. a 40-min build with no transcript writes but CPU in children).
3. **`Stop` is not proof of completion.** It does not fire on interrupt, and parallel user hooks (including `/goal`) can block the stop and continue the turn. Debounce and confirm with the record status or `turn_duration`.
4. **Hooks may not run.** Causes:
   - `--bare` (planned to become the default for `-p`)
   - `disableAllHooks`
   - managed `allowManagedHooksOnly`
   - workspace-trust dialog not yet accepted
   - plugin installed after the session started (needs `/reload-plugins`)
   - folder trust in VS Code/Desktop is untested

   Detection must work without hooks.
5. **Entrypoints not verified live:** VS Code (extension not installed), Desktop Code tab (app not running; bundled CLI 2.1.289 lags), JetBrains, `-p` (I did not run one, to avoid writing transcripts). Whether `-p` writes a record is inferred from DOC-XMSG [M].
6. **`claude agents --json` side effects in future versions** (e.g. starting the supervisor). In 2.1.296 it wrote nothing under `~/.claude` [H for this version only]. Do not poll it faster than about every 10 s.
7. **CLI discovery from a GUI app:** multiple binaries and versions (`versions/2.1.29x`, `ClaudeCode.app`, the Desktop-bundled one); `~/.local/bin` is not on a GUI app's PATH; `CLAUDE_CONFIG_DIR` creates a separate `~/.claude` root, so Lidless should honor it if set in the user's environment.
8. **Rate-limit and quota waits:** the record status during a usage-limit wait is unverified. If it reads `busy`, Lidless would keep the Mac awake for hours. Use `StopFailure:rate_limit` and `quota_auto_resume_*` notifications to classify it.
9. **Agent-team teammates** do not register records [M: BIN]. Their activity shows only through the lead session's status and the `TeammateIdle`/`TaskCompleted` hooks [L].
10. **Transcript mtime noise:** idle sessions append metadata on wake (observed). Never use main-file mtime alone.
11. **Privacy:** push bodies derived from `last_assistant_message` may leak code or secrets to the push provider. Make content opt-in.
12. **Double notifications** if the user also enables Remote Control push (`agentPushNotifEnabled`/`inputNeededNotifEnabled`). Offer a single source of truth, or manage `CLAUDE_CLIENT_PRESENCE_FILE`.
13. **PTY back-pressure** when pausing terminal hosts is reasoned, not tested. Verify experimentally before shipping the "pause apps" feature.
14. **Exec-form `command` resolution with an absolute `${CLAUDE_PLUGIN_ROOT}` path:** docs say "resolved as an executable on PATH". Verify that an absolute path works in 2.1.296 (expected yes) [M].
15. **No Apple Developer ID needed for any of this.** Plugin install, hooks, file reads, and `IOPMCopyAssertionsByProcess` all work unsandboxed with ad-hoc signing [H: LOCAL compiled and ran the probes unsigned]. The first exec of a freshly built helper took 0.32 s, so pre-warm it once at install.

---

## Appendix A: read-only commands and snippets used

- `cat ~/.claude/sessions/*.json`; `ps -axo pid,ppid,stat,%cpu,etime,time,tty,comm|args`; `TZ=UTC LC_ALL=C ps -o lstart= -p <pid>`
- `pmset -g assertions`; `pmset -g log | grep …` (01:29:49 `Clamshell Sleep`; caffeinate `ClientDied` cadence; 15:04:11 `lidopen`)
- `strings -n 6 ~/.local/share/claude/versions/2.1.296 > research-snippets/strings-2.1.296.txt` plus a Python context search (`research-snippets/ctx.py`)
- `research-snippets/tx_summary.py`, `tx_types.py`: transcript entry-type census
- `research-snippets/signals.py`: per-session CPU, caffeinate child, transcript age
- `research-snippets/assertions.swift`: `IOPMCopyAssertionsByProcess` → caffeinate → parent pid (found 96888 and 76720)
- `research-snippets/hookprobe.swift`: hook-helper startup timing (0.01–0.04 s warm)
- `claude agents --json --all < /dev/null` (19 entries, 0.18 s, no `~/.claude` writes)
- `sysctl net.local.dgram.maxdgram` = 2048

All snippets are under `/private/tmp/claude-501/-Users-tomasnguyen-Developer/3514aa88-efa8-4a60-97d7-2878eed849d4/scratchpad/research-snippets/`. No `sudo` was used, no settings were changed, no signals were sent, and nothing under `~/.claude` was written.
