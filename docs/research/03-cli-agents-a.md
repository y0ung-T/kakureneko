# 03 — Terminal AI agents (part A): turn-complete / needs-input / session signals

Scope: OpenAI Codex CLI, Google Gemini CLI (and its consumer successor **Antigravity CLI `agy`**), GitHub Copilot CLI, Cursor CLI (`agent` / `cursor-agent`), opencode (v1 and v2), Aider.
Claude Code is covered elsewhere. One overlap is called out below: Cursor CLI also runs the hooks in `~/.claude/settings.json`.

Research date: **2026-10-12**. Machine: macOS 26.6.2 arm64. Everything was read-only. No agent config was modified, no process was signalled, and nothing was installed.

Confidence tags: **[H]** high (official docs plus source or binary verified), **[M]** medium (one official source, or source read without a runtime test), **[L]** low (forum, third-party, or inference).

---

## 0. TL;DR matrix

| Agent (version checked) | Turn finished / idle | Needs approval / input | Session start | Session end | Install path for Lidless | One-command-only? |
|---|---|---|---|---|---|---|
| **Codex CLI** rust-v0.162.1 (2026-10-09) | `notify` argv (`agent-turn-complete`, no trust needed) **and** hook `Stop` | hook `PermissionRequest` (runs in the approval path before the UI shows) | hook `SessionStart` | hook `SessionEnd` (1 s timeout, max 3 s), `Interrupt` | `~/.codex/config.toml` `notify` + `~/.codex/hooks.json` | **`notify` yes, so we must chain.** Hooks are arrays. User hooks need **one-time trust in `/hooks`**. |
| **Gemini CLI** v0.63.0 stable (2026-10-06) | hook `AfterAgent` | hook `Notification` (`notification_type: "ToolPermission"`) | `SessionStart` | `SessionEnd` (best effort, not awaited) | `~/.gemini/settings.json` `hooks` | No (arrays) |
| **Antigravity CLI `agy`** 1.3.3 (2026-10-10) | hook `Stop` (`fullyIdle`, `terminationReason`) | **no hook**. `statusLine`/`title` command gets `tool_confirmation_pending` and `agent_state` on every state change | none | none | `~/.gemini/config/hooks.json` (keyed by hook name) | Hooks no. `statusLine`/`title` yes, so chain. |
| **Copilot CLI** v1.0.95 (2026-10-09) | hook `agentStop`, plus `notification` with `agent_idle` | hook `notification` with `permission_prompt` / `elicitation_dialog` | `sessionStart` | `sessionEnd` | **own file** `~/.copilot/hooks/lidless.json` | No (all files merged) |
| **Cursor CLI** 2026.10.01-e373342 | hook `stop`: interactive only and flaky. **Not emitted with `-p`** | **no CLI hook** | `sessionStart` | `sessionEnd` (unreliable in CLI) | `~/.cursor/hooks.json` | No (arrays). Also runs **`~/.claude/settings.json` hooks**. |
| **opencode** v1.19.0 / v2.0.27 | plugin event `session.status` `{type:"idle"}` (`session.idle` is deprecated) | plugin events `permission.asked`, `question.asked` (v1) / `form.created` (v2) | `session.created` | `session.deleted`, or process exit | own file `~/.config/opencode/plugins/lidless.js` | No (plugins additive) |
| **Aider** v0.86.0 (2025-08-09; main 0.86.3.dev, last commit 2026-05-22) | `notifications-command` (same trigger for idle **and** confirm prompts, no payload) | same command, indistinguishable | none | none (process exit) | `~/.aider.conf.yml` | **Yes, so we must chain.** |

The universal rule for every hook: **our command must exit 0 and print nothing to stdout or stderr**, or `{}` where JSON is expected. Several agents treat exit 2, a non-zero exit, or a JSON `decision` as "block, keep the agent going". See §1 and §11.

---

## 1. Shared design: the `lidless-hook` helper

Every agent integration below calls one tiny native helper. Its contract:

- **Path:** use a **stable, space-free** path such as `~/.lidless/bin/lidless-hook`, as a symlink into `Lidless.app/Contents/Helpers/lidless-hook`. **[H]** There are two reasons:
  1. Codex stores a *hash of the hook definition*. Any change to the command string turns the hook back into "Modified" and it needs re-review. (Source: `codex-rs/hooks/src/engine/discovery.rs` `hook_trust_status`/`hook_hash`.)
  2. Aider (`shell=True`), Gemini (`bash -c`), Cursor, Copilot (`bash`) and Codex (`$SHELL -lc`) all pass the string through a shell, so spaces in `~/Library/Application Support` would need fragile quoting.
- **Argv:** `lidless-hook <agent> <event> [--chain -- <original argv…>]`.
- **Input:** read stdin to EOF with a cap of about 1 s and 1 MiB. For Codex `notify` and Aider there is no stdin; Codex's JSON is the **last argv**.
- **Enrichment:** walk `getppid()` upward until a process matches an agent signature (§9.1). That pid is the session key. Also record `cwd`, the controlling tty (`/dev/ttysNNN`), and env vars (`CURSOR_VERSION`, `CURSOR_PROJECT_DIR`, `GEMINI_SESSION_ID`, `COPILOT_HOME`, …).
- **Delivery:** send one datagram to the Lidless app on a Unix socket (for example `~/.lidless/run/events.sock`). If the app is not running, drop a file into a spool directory. Never block for more than about 50 ms.
- **Output:** **print nothing**, or exactly `{}` for JSON hook protocols. **Always exit 0.** Never write to stderr.
  - Gemini parses stderr when stdout is empty and shows it as a `systemMessage`. (Source: `packages/core/src/hooks/hookRunner.ts` `textToParse = stdout.trim() || stderr.trim()`.) **[H]**
- **Robust command wrapper for shells that may outlive Lidless:** `"$HOME/.lidless/bin/lidless-hook" gemini AfterAgent 2>/dev/null; exit 0`
  - This means a missing helper (exit 127 plus "not found" on stderr) can never be read as a blocking decision. This matters for Gemini: any exit code other than 0 or 1 becomes `decision: "deny"`, and on `AfterAgent` that **forces the agent to continue**. (Source: `hookRunner.ts` `convertPlainTextToHookOutput`; `core/client.ts` lines ~1032–1062.) **[H]**

---

## 2. OpenAI Codex CLI

Versions: latest stable **rust-v0.162.1 (2026-10-09)**; 0.163.0-alpha.5 (2026-10-10). Source read at `openai/codex@6c372fb` (2026-10-12). Not installed on this Mac (`which codex` → not found; no `~/.codex`). **[H]** (Sources: `gh api repos/openai/codex/releases`; local `which`.)

### (a) Process identification **[H]** (source: `codex-cli/bin/codex.js`)

- **npm (`npm i -g @openai/codex`):**
  - Parent `node` runs `<prefix>/bin/codex` (→ `@openai/codex/bin/codex.js`). Its argv[0] is `node`.
  - That parent `spawn()`s the native binary `<prefix>/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex`. The child's argv[0] is that full path and its executable basename is `codex`.
- **Homebrew cask / standalone:** a single native `codex` process.
- **Sub-modes in argv[1]:**
  - `exec`: non-interactive.
  - `app-server`: used by the TUI internally, the VS Code "Codex" extension and the Codex desktop app.
  - `mcp-server`.
- **Detection rule:** executable basename `codex`, or `node` whose argv[1] basename is `codex` or `codex.js`.

### (b) Config paths **[H]** (source: learn.chatgpt.com/docs/config-file/config-reference, learn.chatgpt.com/docs/hooks)

- `~/.codex/config.toml` (or `$CODEX_HOME/config.toml`).
- `~/.codex/hooks.json`.
- Project `.codex/hooks.json` and `.codex/config.toml`. These are loaded only when the project layer is trusted.

### (c) Mechanisms

**1. Legacy `notify`: turn complete only.** **[H]** (source: `codex-rs/hooks/src/legacy_notify.rs`; `codex-rs/core/src/config/mod.rs` doc comment)

```toml
# ~/.codex/config.toml   (top-level key, NOT under [tui])
notify = ["/Users/<you>/.lidless/bin/lidless-hook", "codex", "notify"]
```

- Codex spawns the argv **directly, with no shell**, and appends **one extra argv**: the JSON payload.
- stdin, stdout and stderr are all `/dev/null`.
- It is fire-and-forget: `spawn()`, then it never waits. There is no timeout and no way to affect the agent.
- It fires only on `HookEvent::AfterAgent`, after each completed turn, for every client:
  - `client` is the app-server client name, for example `"codex-tui"`; the VS Code extension sends its own name.
  - It does **not** fire on approval requests. It is not tied to hook trust.

**2. Lifecycle hooks: stable, enabled by default (`[features] hooks = true`; `codex_hooks` is a deprecated alias).** **[H]** (source: `codex-rs/features/src/lib.rs`: `key: "hooks", stage: Stable, default_enabled: true`; learn.chatgpt.com/docs/hooks)

- **Events:** `SessionStart`, `SessionEnd`, `SubagentStart`, `SubagentStop`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PreCompact`, `PostCompact`, `UserPromptSubmit`, `Stop`, `Interrupt`. There is **no `Notification` event**.
- **`hooks.json` format:**
  - The top level allows only `description` and `hooks` (`deny_unknown_fields`).
  - Each matcher group is `{matcher?, hooks:[…]}`.
  - Each handler is `{type:"command", command, timeout (sec), async (bool), statusMessage, commandWindows, additionalContextLimit}`, or `{type:"mcp_tool", server, tool, input, timeout}`.
  - (Source: `codex-rs/config/src/hook_config.rs`.)

```json
{
  "description": "Lidless agent-state hooks",
  "hooks": {
    "SessionStart":      [{ "hooks": [{ "type": "command", "command": "\"$HOME/.lidless/bin/lidless-hook\" codex SessionStart 2>/dev/null; exit 0", "timeout": 5 }] }],
    "UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "\"$HOME/.lidless/bin/lidless-hook\" codex UserPromptSubmit 2>/dev/null; exit 0", "timeout": 5 }] }],
    "PermissionRequest": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "\"$HOME/.lidless/bin/lidless-hook\" codex PermissionRequest 2>/dev/null; exit 0", "timeout": 5 }] }],
    "Stop":              [{ "hooks": [{ "type": "command", "command": "\"$HOME/.lidless/bin/lidless-hook\" codex Stop 2>/dev/null; exit 0", "timeout": 5 }] }],
    "Interrupt":         [{ "hooks": [{ "type": "command", "command": "\"$HOME/.lidless/bin/lidless-hook\" codex Interrupt 2>/dev/null; exit 0", "timeout": 1 }] }],
    "SessionEnd":        [{ "hooks": [{ "type": "command", "command": "\"$HOME/.lidless/bin/lidless-hook\" codex SessionEnd 2>/dev/null; exit 0", "timeout": 1 }] }]
  }
}
```

The equivalent inline TOML is `[[hooks.Stop]]` / `[[hooks.Stop.hooks]] type="command" command="…" timeout=5`. If the same layer has both `hooks.json` and inline `[hooks]`, Codex merges them and **warns at startup**. **[H]**

### (d) Payloads and influence on the agent

- **`notify` argv JSON (wire shape is a test fixture):** **[H]** (source: `legacy_notify.rs` tests)

  ```json
  {"type":"agent-turn-complete","thread-id":"b5f6c1c2-…","turn-id":"12345","cwd":"/Users/example/project","client":"codex-tui","input-messages":["Rename `foo`…"],"last-assistant-message":"Rename complete…"}
  ```

  `client` is omitted when it is unknown. `last-assistant-message` may be `null`.
- **Hook stdin JSON (snake_case)** **[H]** (source: `codex-rs/hooks/schema/generated/*.command.input.schema.json`):
  - `Stop`: `session_id, turn_id, transcript_path (nullable), cwd, hook_event_name, model, permission_mode, stop_hook_active, last_assistant_message (nullable)`.
  - `PermissionRequest`: `session_id, turn_id, transcript_path, cwd, hook_event_name, model, permission_mode, tool_name, tool_input (with .description), agent_id?, agent_type?`.
  - `SessionStart`: `…, source` (`startup|resume|clear|compact`).
  - `SessionEnd`: `session_id, transcript_path, cwd, hook_event_name, reason` (currently always `"other"`).
  - `Interrupt`: `session_id, turn_id, transcript_path, cwd, hook_event_name, model, permission_mode`.
- **Influence (dangerous if mishandled):** **[H]** (source: docs + `stop.command.output.schema.json`)
  - **Exit 2 on `Stop` = "block", which makes Codex continue with the stderr reason as a new prompt.**
  - JSON `{"decision":"block","reason":…}` does the same.
  - `continue:false` ends the run.
  - `PermissionRequest` can return allow/deny via `hookSpecificOutput`.
  - `Stop` and `SubagentStop` expect JSON or nothing on exit 0; **plain text is invalid**.
  - Exit 0 with empty stdout is plain success.
  - So the helper must print nothing (or `{}`) and exit 0.

### (e) On-disk state without hooks **[M]** (source: `codex-rs/rollout/src/{recorder.rs,policy.rs,rollout_file_name.rs,compression.rs}`, `protocol/src/protocol.rs`)

- **Rollout path:** `~/.codex/sessions/YYYY/MM/DD/rollout-YYYY-MM-DDThh-mm-ss-<thread_uuid>.jsonl`. Old ones may be compressed to `.jsonl.zst`, or moved to `~/.codex/archived_sessions/`.
- **Persisted lines** are `event_msg` items for `task_started` (alias `turn_started`), `task_complete` (alias `turn_complete`) and `turn_aborted`. The last of these lines tells you busy or idle.
- **Approval requests are NOT persisted** (`ExecApprovalRequest`, `RequestPermissions` and `RequestUserInput` are in the "transient" list), so needs-input cannot be inferred from disk.
- **Other files:** `~/.codex/history.jsonl` holds prompts only; logs are in `$CODEX_HOME/log/`.

### (f) Chaining

- **`notify` is a single argv array, so Lidless must chain an existing value** **[H]**:

  ```toml
  notify = ["/Users/<you>/.lidless/bin/lidless-hook","codex","notify","--chain","--","<original argv0>","<original arg1>"]
  ```

  The helper re-executes the original argv with the JSON appended as the last argument, which preserves the original semantics. On uninstall, restore the saved original value.
- **Hooks:** append our matcher group to the arrays. Never replace the user's groups.

### (g) Caveats

- **Trust gate (biggest caveat).** **[H]** (source: `discovery.rs` `hook_trust_status`, TUI strings "Hooks need review" / "N hooks need review before they can run.")
  - User-layer hooks are "non-managed", so they **do not run until the user approves them once in `/hooks`**.
  - Approval is stored as `[hooks.state."<source>:<event>:<group>:<handler>"] trusted_hash = "…"` in `~/.codex/config.toml`.
  - In `codex exec` untrusted hooks silently don't run, unless the user passes `--dangerously-bypass-hook-trust`.
  - Lidless should **not** forge `trusted_hash`. Ask the user to open Codex once and approve. Until then, rely on `notify`, which needs no trust.
  - Only system/MDM layers are "managed", and those need root or `requirements.toml`, so that route is out of scope.
- **Timeouts and async.** **[H]**
  - The default hook timeout is **600 s**, so always set `timeout`.
  - `SessionEnd` and `Interrupt` default to 1 s, clamped at 3 s, and `SessionEnd` always runs synchronously.
  - `"async": true` runs a hook in the background, with at most 8 concurrent per session; background hooks are cancelled when the session ends.
  - Hooks run via `$SHELL -lc` in a **new session (setsid)** with a scrubbed environment, so `$PPID` is the codex process.
- **Subagents.** `notify` fires once per thread turn. Spawned sub-threads also produce `AfterAgent`, so dedupe by `thread-id`/`cwd`. **[M]**

---

## 3. Google Gemini CLI

Versions: stable **v0.63.0 (2026-10-06)**, preview v0.64.0-preview.1, nightly 0.65.0. Source read at `google-gemini/gemini-cli@9b6e026` (2026-10-09). Not installed locally. **[H]**

> **Status change:** Since **2026-06-18**, Gemini CLI no longer serves Google AI Pro/Ultra or free individual users. They were moved to **Antigravity CLI (`agy`)** (§4). Gemini CLI remains available for paid Gemini API keys and Enterprise or Code Assist Standard. **[H]** (Sources: developers.googleblog.com "An important update: transitioning Gemini CLI to Antigravity CLI", 2026-05-19; geminicli.com banner.)

### (a) Process **[H]** (source: `packages/cli/package.json` bin `gemini → dist/index.js`; `packages/cli/src/utils/relaunch.ts`)

- It is node-based. The parent is `node <prefix>/bin/gemini …`, with argv[0] `node`.
- Unless `GEMINI_CLI_NO_RELAUNCH` is set, the parent **relaunches itself** as a child: `spawn(process.execPath, [...nodeArgs, script, ...args])` with env `GEMINI_CLI_NO_RELAUNCH=true` and an IPC channel.
  - So there are **two node processes per session**, and the child does the work.
  - The child's argv[0] is the full node path (for example `/opt/homebrew/Cellar/node/26.0.0/bin/node`).
- Homebrew installs `gemini-cli` (`/opt/homebrew/Cellar/gemini-cli/<v>/libexec/lib/node_modules/@google/gemini-cli/dist/index.js`).
- Gemini CLI does not set `process.title`.
- **Detection:** a `node` process whose argv contains `@google/gemini-cli` or whose argv[1] basename is `gemini`.

### (b) Config **[H]** (source: geminicli.com/docs/hooks, last updated 2026-04-13)

- Project `.gemini/settings.json`.
- User `~/.gemini/settings.json`.
- System `/etc/gemini-cli/settings.json`.
- Extensions.
- `hooksConfig.enabled` defaults to **true** (`packages/cli/src/config/settingsSchema.ts`), so no flag is needed. `/hooks enable-all|disable-all` exists.

### (c) Mechanism

Events: `BeforeTool, AfterTool, BeforeAgent, AfterAgent, Notification, SessionStart, SessionEnd, PreCompress, BeforeModel, AfterModel, BeforeToolSelection`. **[H]** (source: `packages/core/src/hooks/types.ts` `HookEventName`)

```json
// ~/.gemini/settings.json  (merge into existing "hooks"; keep user entries)
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "name": "lidless-session-start", "type": "command",
        "command": "\"$HOME/.lidless/bin/lidless-hook\" gemini SessionStart 2>/dev/null; exit 0", "timeout": 3000 }] }],
    "BeforeAgent":  [{ "hooks": [{ "name": "lidless-busy", "type": "command",
        "command": "\"$HOME/.lidless/bin/lidless-hook\" gemini BeforeAgent 2>/dev/null; exit 0", "timeout": 3000 }] }],
    "AfterAgent":   [{ "hooks": [{ "name": "lidless-turn-done", "type": "command",
        "command": "\"$HOME/.lidless/bin/lidless-hook\" gemini AfterAgent 2>/dev/null; exit 0", "timeout": 3000 }] }],
    "Notification": [{ "hooks": [{ "name": "lidless-needs-input", "type": "command",
        "command": "\"$HOME/.lidless/bin/lidless-hook\" gemini Notification 2>/dev/null; exit 0", "timeout": 3000 }] }],
    "SessionEnd":   [{ "hooks": [{ "name": "lidless-session-end", "type": "command",
        "command": "\"$HOME/.lidless/bin/lidless-hook\" gemini SessionEnd 2>/dev/null; exit 0", "timeout": 3000 }] }]
  }
}
```

- `timeout` is in **milliseconds**; the default is 60000. **[H]**
- `matcher` is optional. For lifecycle events it is an exact string, and `"*"`/empty matches all.
- `sequential` on a group makes the hooks in it run serially; otherwise they run in parallel.

### (d) Payload and influence **[H]** (source: hooks reference page, `types.ts`, `hookRunner.ts`)

- **stdin JSON:** `session_id, transcript_path, cwd, hook_event_name, timestamp`, plus event fields:
  - `AfterAgent`: `prompt, prompt_response, stop_hook_active`.
  - `BeforeAgent`: `prompt`.
  - `Notification`: `notification_type` (only `"ToolPermission"` exists), `message`, `details` (serialised confirmation details).
  - `SessionStart`: `source` (`startup|resume|clear`).
  - `SessionEnd`: `reason` (`exit|clear|logout|prompt_input_exit|other`).
- **env:** `GEMINI_PROJECT_DIR, GEMINI_PLANS_DIR, GEMINI_CWD, GEMINI_SESSION_ID, CLAUDE_PROJECT_DIR` (compat), plus a sanitised `process.env`. Commands run in `bash -c` with `cwd = input.cwd`.
- **Influence:**
  - Exit 0 means stdout is parsed as JSON. Exit 1 is a warning.
  - **Any other non-zero exit, including 127, is `deny`.**
  - On `AfterAgent`, a blocking decision makes the agent **continue with the reason as a retry prompt**.
  - Empty stdout plus empty stderr means no effect, but **stderr text is used if stdout is empty**.
  - Hence the `2>/dev/null; exit 0` wrapper.

### (e) Disk state **[M]** (source: `packages/core/src/config/storage.ts`, `chatRecordingTypes.ts`)

- `~/.gemini/tmp/<project-id>/chats/session-*.json` holds chat recordings.
- There is no explicit busy flag. The file mtime only shows recent activity.

### (f) Chaining

Not needed: hooks are arrays merged across user, project and system. **[H]**

### (g) Caveats

- Hooks are **synchronous**. Gemini waits for all matching hooks before continuing, so keep the helper under about 50 ms. **[H]**
- `SessionEnd` is best effort and not awaited. `PreCompress` is async. **[H]**
- **Project** hooks are fingerprinted and need trust; user hooks do not. **[H]** (source: `trustedHooks.ts`)
- `AfterAgent` fires only on the outermost agent call with no pending tool calls. That is exactly "turn done". **[H]** (source: `core/client.ts` ~l.225–255)

---

## 4. Antigravity CLI (`agy`): the Gemini CLI successor for consumers

Version **1.3.3 (2026-10-10)** (`google-antigravity/antigravity-cli` releases). The repo is a docs/forum repo; the CLI itself is **closed-source and built in Go**. **[H]** (Sources: Google blog 2026-05-19; repo README.)

- **(a) Process:**
  - Installed by `curl -fsSL https://antigravity.google/cli/install.sh | bash` to **`~/.local/bin/agy`**, a native binary. **[H]** (source: downloaded `install.sh`, `TARGET_DIR="$HOME/.local/bin"`, `BINARY_PATH="$TARGET_DIR/agy"`)
  - Extra processes may exist: a `remote-control` daemon, background-task daemons, and plugin MCP servers (per CHANGELOG). **[M]**
- **(b) Config:**
  - Global hooks: `~/.gemini/config/hooks.json`.
  - CLI settings: `~/.gemini/antigravity-cli/settings.json`. These can also hold hooks plus `statusLine` and `title`.
  - Workspace hooks: `.agents/hooks.json`.
  - (Source: antigravity.google/docs/hooks, /docs/cli/statusline, /docs/cli/title.) **[H]**
- **(c) Hooks:**
  - Events: `PreToolUse`, `PostToolUse`, `PreInvocation`, `PostInvocation`, `Stop`. There are **no Notification, SessionStart or SessionEnd** events.
  - The file is keyed by hook *name*, so ours is additive:

  ```json
  // ~/.gemini/config/hooks.json   (add a top-level key; keep others)
  { "lidless": { "Stop": [ { "type": "command", "command": "\"$HOME/.lidless/bin/lidless-hook\" agy Stop 2>/dev/null; exit 0", "timeout": 5 } ] } }
  ```

  - `timeout` is in seconds; the default is 30. **[H]**
- **Needs-input signal:**
  - The `statusLine` and `title` commands are run "**whenever the agent state changes**".
  - Their stdin JSON includes `agent_state` (`initializing|idle|thinking|working|tool_use`), **`tool_confirmation_pending` (bool)**, `pending_input_count`, `task_count`, `conversation_id`/`session_id`, `cwd`, `transcript_path`, `workspace.{current_dir,project_dir}`, and `version`. **[H]** (source: /docs/cli/statusline "Available JSON fields")
  - Config: `"statusLine": {"type":"command","command":"…","stack_with_default":true}`. stdout is rendered.
  - Because the user may already have a statusline, Lidless must **chain** it: run the user's command and pass its stdout through. If there is none, print an empty string with `stack_with_default: true`. **[M]** (Whether an empty line renders cleanly is not verified.)
- **(d) Stop payload:**
  - Fields: `conversationId, workspacePaths, transcriptPath, artifactDirectoryPath, modelName, executionNum, terminationReason, error?, fullyIdle` (camelCase).
  - Output `{"decision":"continue","reason":…}` keeps the agent running, so we output `{}` or nothing.
  - Exit-code semantics are **undocumented**. **[H/L]**
- **(e) Disk:** a conversation-history SQLite DB exists (CHANGELOG mentions it). Its path is unverified. **[L]**
- **(g) Caveats:**
  - A forum report says `Stop`/`PostToolUse` hooks did not fire in Antigravity IDE 1.107.0 on Windows (IDE, not CLI). **[L]**
  - A CHANGELOG fix stopped `/btw` side-questions from running hooks.

---

## 5. GitHub Copilot CLI

Versions: stable **v1.0.95 (2026-10-09)**, pre-release 1.0.96-2. The CLI is closed-source. **Local verification:**

- VS Code **1.135.0** bundles `@github/copilot-darwin-arm64` **1.0.81-0** at `/Applications/Visual Studio Code.app/Contents/Resources/app/node_modules.asar.unpacked/@github/copilot-darwin-arm64/`.
- The user's `~/.copilot/` contains only `config.json` (comment: *"User settings belong in settings.json. This file is managed automatically."*, `firstLaunchAt 2026-08-09`) and `logs/process-*.log`.
- Those logs show "*Starting CLI in server mode (stdio)*", i.e. **VS Code launched the Copilot CLI runtime**; there is no standalone `copilot` on PATH. **[H]** (verified locally: `cat ~/.copilot/logs/process-1788959335458-52549.log`, package.json)

### (a) Process **[H]** (source: bundled `npm-loader.js`)

- **npm `@github/copilot`:** `node <prefix>/bin/copilot` (`npm-loader.js`) runs `spawnSync` on the native platform binary `…/@github/copilot-darwin-arm64/copilot`, whose argv[0] is that full path.
- **Homebrew or install script:** a native `copilot` process.
- **Inside VS Code:** the runtime runs in server/stdio mode, hosted by VS Code. **[M]**
- **Detection:** executable basename `copilot`, or argv containing `@github/copilot`.

### (b) Config **[H]** (source: docs.github.com/en/copilot/reference/copilot-cli-reference/cli-hooks-reference; settings schema strings in `runtime.node`)

- User settings: `~/.copilot/settings.json`. The CLI **no longer reads `~/.copilot/config.json` for hooks**.
- User hook files: **`~/.copilot/hooks/*.json`** (or `$COPILOT_HOME/hooks/`).
- Repo: `.github/hooks/*.json`, `.github/copilot/settings(.local).json`, **`.claude/settings(.local).json`**.
- Policy: `/etc/github-copilot/policy.d/*.json`.
- Plugins: `hooks.json`.
- **All sources are merged and all matching entries run.**
- `disableAllHooks` and `disabledHooks` (content-hash keys) exist. No trust prompt for user hooks was found. **[M]**

### (c) Mechanism

Events, verified in `runtime.node` strings of 1.0.81 and in the docs: `sessionStart, sessionEnd, userPromptSubmitted, userPromptTransformed, preToolUse, preMcpToolCall, postToolUse, postToolUseFailure, errorOccurred, agentStop, subagentStart, subagentStop, preCompact, permissionRequest, notification`. **[H]**

PascalCase aliases (`Stop`, `SessionStart`, `Notification`, `PermissionRequest`, …) switch the payload to snake_case and ISO timestamps.

```json
// ~/.copilot/hooks/lidless.json   (our own file; no merging needed)
{
  "version": 1,
  "hooks": {
    "sessionStart":        [{ "type": "command", "bash": "\"$HOME/.lidless/bin/lidless-hook\" copilot sessionStart 2>/dev/null; exit 0", "timeoutSec": 5 }],
    "userPromptSubmitted": [{ "type": "command", "bash": "\"$HOME/.lidless/bin/lidless-hook\" copilot userPromptSubmitted 2>/dev/null; exit 0", "timeoutSec": 5 }],
    "agentStop":           [{ "type": "command", "bash": "\"$HOME/.lidless/bin/lidless-hook\" copilot agentStop 2>/dev/null; exit 0", "timeoutSec": 5 }],
    "notification":        [{ "type": "command", "matcher": "permission_prompt|elicitation_dialog|agent_idle|agent_completed",
                              "bash": "\"$HOME/.lidless/bin/lidless-hook\" copilot notification 2>/dev/null; exit 0", "timeoutSec": 5 }],
    "sessionEnd":          [{ "type": "command", "bash": "\"$HOME/.lidless/bin/lidless-hook\" copilot sessionEnd 2>/dev/null; exit 0", "timeoutSec": 5 }]
  }
}
```

- Fields: `type` (`command|http|prompt`), `bash`/`powershell`/`command`, or `exec` + `args` (no shell, CLI only), plus `cwd`, `env`, `timeoutSec` (default **30**), and `matcher` (regex anchored as `^(?:…)$`). **[H]**
- HTTP hooks to `http://localhost` need `COPILOT_HOOK_ALLOW_LOCALHOST=1`. Prefer command hooks.
- Use `notification`/`permission_prompt` for "needs approval" rather than `permissionRequest`. `permissionRequest` runs *before the rules engine for every tool decision*, even ones that will be auto-approved. **[H]** (settings description string in `runtime.node`)

### (d) Payloads and influence **[H]** (source: hooks reference)

- **`agentStop`:** `{sessionId, timestamp(ms), cwd, transcriptPath, stopReason:"end_turn", stop_hook_active}`.
- **`notification`:** `{sessionId, timestamp, cwd, hook_event_name:"Notification", message, title?, notification_type}`, where `notification_type` is one of:
  - `shell_completed`, `shell_detached_completed`
  - `agent_completed`: a background subagent finished.
  - `agent_idle`: a background agent is waiting.
  - `permission_prompt`
  - `elicitation_dialog`
- **`sessionStart`:** `{…, source: startup|resume|new, initialPrompt?}`.
- **`sessionEnd`:** `{…, reason: complete|error|abort|timeout|user_exit}`. `/clear` fires `sessionEnd(user_exit)` for the old session.
- **Influence:**
  - `agentStop` `{"decision":"block"}` forces another turn, with a runaway guard after 8 blocks.
  - Exit 2 is only a *warning* for `agentStop`.
  - Other non-zero exits fail open, except `preToolUse`.
  - `notification` is **fire-and-forget and never blocks**.
  - Output is capped at 10 MiB.

### (e) Disk state **[M]** (source: strings in bundled `app.js`/`runtime.node`)

- `~/.copilot/session-state/<sessionId>/events.jsonl`: every session event is recorded through `session.on("*")` and flushed with a debounce. Persisted types include `session.start`, `assistant.turn_start`, `assistant.turn_end`, `session.idle`, `permission.requested`, `permission.completed`, `user_input.requested`, `session.shutdown` (from `schemas/session-events.schema.json`).
- Whether ephemeral types (for example `session.idle`) are actually persisted is **unverified** **[L]**.
- Also present: `~/.copilot/session-store.db`, and `~/.copilot/logs/process-<ms>-<pid>.log` (verified locally).

### (f) Chaining

Not needed: drop our own file into `~/.copilot/hooks/`. **[H]**

### (g) Caveats

- The `notification` hook is CLI-only. **None of these hooks fire under the Copilot *cloud* agent**, except repo `.github/hooks` there.
- Whether user-level hooks apply when VS Code hosts the Copilot CLI runtime in server mode is **unverified** **[L]**.
- A built-in `"notifications": true` setting shows **OS notifications** for attention requests and idle turns. That is useful to know, but it is local only.
- A `statusLine.command` with `refreshInterval` exists too.

---

## 6. Cursor CLI (`agent`, legacy alias `cursor-agent`)

Version **2026.10.01-e373342** (current `https://cursor.com/install` script, fetched 2026-10-12). The package was downloaded to the scratchpad **for reading only** and was not installed. **[H]**

### (a) Process **[H]** (source: package `cursor-agent` launcher script)

- The install script symlinks `~/.local/bin/agent` and `~/.local/bin/cursor-agent` to `~/.local/share/cursor-agent/versions/<ver>/cursor-agent`, a **bash script**.
- That script runs `exec -a "$0" "$SCRIPT_DIR/node" [--use-system-ca] "$SCRIPT_DIR/index.js" "$@"`. As a result:
  - **`ps -o comm` shows argv[0] = `$0`**, for example `/Users/me/.local/bin/agent`.
  - The real executable (`proc_pidpath`/`proc_name`) is the **bundled `node`** (v26.8.1) inside `~/.local/share/cursor-agent/versions/<ver>/`.
  - argv[2] ends in `/index.js`.
- Env `CURSOR_INVOKED_AS=<basename $0>`.
- **New:** `agent persist list|attach|stop <session>` creates **persistent sessions on a tmux server**. Lidless should treat those tmux-hosted agent processes as sessions too. **[H]** (strings in `index.js`)

### (b) Config **[H]** (source: cursor.com/docs/agent/hooks; `190.index.js` loader)

- Hook sources:
  - User `~/.cursor/hooks.json`; user hooks run with cwd `~/.cursor/`.
  - Project `<root>/.cursor/hooks.json`.
  - Enterprise `/Library/Application Support/Cursor/hooks.json`.
  - Team: dashboard-synced to `~/.cursor/managed/active-team-hooks/hooks.json`.
  - Plugin `hooks/hooks.json`.
- **Claude Code settings files:** the CLI also loads hooks from **`~/.claude/settings.json`**, `<root>/.claude/settings.json` and `<root>/.claude/settings.local.json`, and dedupes them against Cursor hooks (`claudeUserConfigPath`, `parseClaudeConfig`, `dedupeClaudeHooksAgainstCursorHooks`).
  - **Consequence:** a Claude Code `Stop` hook that Lidless installs will **also run under Cursor CLI**, with a Cursor payload. The helper must tell them apart by `CURSOR_VERSION` (env) or a `cursor_version` payload field. **[H]**
- Other files: `~/.cursor/cli-config.json`, `~/.cursor/projects/<workspace-id>/…`, `~/.cursor/chats/…/store.db` (SQLite). **[M]**

### (c) Mechanism

```json
// ~/.cursor/hooks.json  (merge: append to arrays, keep "version")
{
  "version": 1,
  "hooks": {
    "sessionStart":       [{ "command": "\"$HOME/.lidless/bin/lidless-hook\" cursor sessionStart 2>/dev/null; exit 0", "timeout": 5 }],
    "beforeSubmitPrompt": [{ "command": "\"$HOME/.lidless/bin/lidless-hook\" cursor beforeSubmitPrompt 2>/dev/null; exit 0", "timeout": 5 }],
    "stop":               [{ "command": "\"$HOME/.lidless/bin/lidless-hook\" cursor stop 2>/dev/null; exit 0", "timeout": 5 }],
    "sessionEnd":         [{ "command": "\"$HOME/.lidless/bin/lidless-hook\" cursor sessionEnd 2>/dev/null; exit 0", "timeout": 5 }]
  }
}
```

- Per-script fields: `command`, `type` (`command|prompt`), `timeout` (seconds), `loop_limit`, `failClosed` (default false), `matcher`. **[H]**
- These same user hooks **also fire for the Cursor IDE agent**, which is a bonus for agent-agnostic coverage. **[H]**

### (d) Payload and influence **[H]** (docs, plus verified field mapping in `index.js`)

- **Common fields:** `conversation_id, generation_id, model, hook_event_name, cursor_version, workspace_roots, user_email, transcript_path`.
- **`stop`:** `status` (`completed|aborted|error`), `loop_count`, plus `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens` (bundle).
- **`sessionStart`:** `session_id, is_background_agent, composer_mode?`.
- **`sessionEnd`:** `session_id, reason (completed|aborted|error|window_close|user_close), duration_ms, is_background_agent, final_status, error_message?`.
- **env:** `CURSOR_PROJECT_DIR, CURSOR_VERSION, CURSOR_USER_EMAIL, CURSOR_TRANSCRIPT_PATH, CURSOR_CODE_REMOTE, CLAUDE_PROJECT_DIR`.
- **Influence:**
  - `stop` → `followup_message` **auto-submits a new prompt**, with a loop limit of 5.
  - Exit 2 equals `permission:"deny"`. Other non-zero exits fail open unless `failClosed`.
  - **Invalid JSON from permission hooks blocks.**
  - So print nothing or `{}`.

### (e) Disk state

`~/.cursor/chats/<hash>/<chatId>/store.db` is SQLite with no documented status field. **[L]**

### (f) Chaining

Not needed: arrays. Merge JSON carefully; the file is strict JSON. **[H]**

### (g) Caveats (major) **[M]**

Sources: forum.cursor.com threads 148316 (staff, 2026-01-08 → 2026-06-07), 156220 (staff, 2026-03-30), 169059 (staff, 2026-08-21/25).

- **Interactive local CLI:** staff said in April 2026 that `beforeShellExecution`, `afterShellExecution`, `afterFileEdit`, `postToolUse`, **`stop`** and `sessionStart` work.
- **Non-interactive `agent -p`:** **`stop`, `beforeSubmitPrompt` and `afterAgentResponse` are NOT emitted**. This is a "known gap" with no timeline as of 2026-08-25.
- **Other gaps:**
  - `afterAgentResponse`/`afterAgentThought` are never dispatched in the CLI.
  - `sessionEnd` is unreliable.
  - Cloud agents fire no lifecycle hooks.
  - A Linux report (2026.08.11) says no hooks fire at all.
- **There is no "waiting for approval" hook in the CLI.** Use the fallback heuristics in §9.2: tty output recency plus no child processes.
- Hooks are dispatched on request from Cursor's backend (`hookExecutor.executeHookForStep` inside a server-request switch). Behaviour can therefore change server-side without a CLI update. **[M]**

---

## 7. opencode (anomalyco/opencode, formerly sst/opencode)

There are **two live lines**:

- **v1.19.0** (GitHub Release 2026-10-11).
- **v2.0.27** (tag 2026-10-12, `dev` branch, packages `@opencode/*`). The docs banner says "New OpenCode v2 is now available".
- Not installed locally. **[H]** (Sources: `gh api …/releases`, `…/tags`, `packages/cli/package.json` 2.0.27.)

### (a) Process **[M]** (source: v2 `packages/cli/bin/opencode.cjs`)

- A native Bun-compiled binary named `opencode`, installed by curl (`~/.opencode/bin/opencode`), Homebrew, or npm.
- With npm (`opencode-ai` for v1, `@opencode/cli` for v2) there is a `node` wrapper parent that `spawn()`s the platform binary `…/@opencode/cli-darwin-arm64/…/opencode`.
- The TUI and the HTTP server run in the same process tree.
- **Detection:** executable basename `opencode`.

### (b) Config **[H]** (source: opencode.ai/docs/plugins, updated 2026-10-12; opencode.ai/v2/docs/plugins)

- Global plugins: **`~/.config/opencode/plugins/`**. Project plugins: `.opencode/plugins/`. Both auto-load `.js`/`.ts` files.
- Config: `~/.config/opencode/opencode.json(c)`. Its `"plugin"` array (v1) or `"plugins"` array (v2) loads npm packages, cached in `~/.cache/opencode/node_modules/`.

### (c) Mechanism: one file that works on both v1 (≥1.18.29 object form) and v2

The v2 docs say *"default-export one object with a V1 `server()` function and a V2 `setup()` function. V2 ignores `server()`"*. Object form is supported from v1.18.29. **[H]**

```js
// ~/.config/opencode/plugins/lidless.js
import { spawn } from "node:child_process"            // Bun implements node:child_process
const HOOK = `${process.env.HOME}/.lidless/bin/lidless-hook`
function emit(kind, payload) {
  try {
    const p = spawn(HOOK, ["opencode", kind], { stdio: ["pipe", "ignore", "ignore"], detached: true })
    p.on("error", () => {}); p.stdin.end(JSON.stringify({ ...payload, pid: process.pid })); p.unref()
  } catch {}
}
function handle(event, ctx) {
  const t = event?.type, props = event?.properties ?? event?.data ?? event
  if (t === "session.status" || t === "session.idle" || t === "session.created" || t === "session.deleted" ||
      t === "session.error" || t === "permission.asked" || t === "permission.replied" ||
      t === "question.asked" || t === "form.created" || t === "form.replied")
    emit(t, { type: t, properties: props, directory: ctx?.directory })
}
export default {
  id: "lidless",
  // v1: Plugin = (input: {client, project, directory, worktree, serverUrl, $}) => Promise<Hooks>
  server: async (input) => ({ event: async ({ event }) => handle(event, input) }),
  // v2: Plugin.define-compatible object; ctx.event.subscribe() -> AsyncIterable<OpenCodeEvent>
  setup: async (ctx) => {
    const ac = new AbortController()
    ;(async () => { for await (const ev of ctx.event.subscribe({ signal: ac.signal })) handle(ev, ctx) })().catch(() => {})
    return () => ac.abort()
  },
}
```

Older v1 (<1.18.29) only accepts the function export form: `export const LidlessPlugin = async (input) => ({ event: … })`. **[H]**

### (d) Event payloads **[H]**

Sources: v1.19.0 `packages/sdk/js/src/v2/gen/types.gen.ts`; v2 `packages/schema/src/session-status-event.ts`, `permission.ts`, `form.ts`.

- **`session.status`** → `properties: {sessionID, status}`, where `status` is one of:
  - `{type:"idle"}`
  - `{type:"busy"}`
  - `{type:"retry", attempt, message, next, action?}`
- **`session.idle`** → `{sessionID}`. It is marked **deprecated** in v2; prefer `session.status`.
- **`permission.asked`** → `{id, sessionID, permission, patterns[], metadata, always[], tool?}`.
- **`question.asked`** (v1) → `{id, sessionID, questions[], tool?}`.
- **`form.created`** (v2) → `{form}`, with `form.replied` and `form.cancelled` as follow-ups.
- **Influence:**
  - The `event` hook is observe-only.
  - Separate hooks can mutate behaviour: `permission.ask` (v1 `output.status = "allow"|"deny"`), and v2 `ctx.permission.hook("evaluate")`. **Do not register those.**
  - The plugin runs **in-process**, so it must never throw or block. Hence the detached `spawn` with errors swallowed.

### (e) Hookless state **[M]**

- In v1, the server exposes **`GET /session/status`** and the SSE streams **`GET /event`** and **`/global/event`** (SDK `url:` entries). `PluginInput.serverUrl` gives the base URL.
  - A plugin could report its port to Lidless, which could then poll. The port is otherwise random, so Lidless would need `lsof`.
- Status is *ephemeral* (not persisted). The DB lives in `~/.local/share/opencode/…` (v2 uses `opencode-next.db`). **[L]**

### (f) Chaining

Not needed. **[H]**

### (g) Caveats

- `session.status` fires for **subagent child sessions** too. Treat the pid as busy if **any** session is busy, and decide "finished" when all of them are idle. Alternatively, look up `parentID` via `client.session.get` (v1). **[M]**
- The exact v2 event envelope for plugins (`properties` vs `data`) was not runtime-tested; the code above handles both. **[L]**
- npm plugins are installed with Bun at startup; a local file avoids any network dependency. **[H]**

---

## 8. Aider

Version **v0.86.0 (2025-08-09)** is the last release. `main` is `0.86.3.dev`, with its last commit on 2026-05-22. The project is effectively in maintenance. **[H]**

### (a) Process **[H]** (source: `pyproject.toml` `aider = "aider.main:main"`, standard shebang semantics)

- It is Python. With uv, pipx or brew, the `aider` script has a shebang to a venv python.
- `ps` shows argv[0] = the interpreter path (for example `~/.local/share/uv/tools/aider-chat/bin/python3.12`), and **argv[1] = `…/bin/aider`**.
- `python -m aider` is also possible.
- **Detection:** the executable basename starts with `python`/`Python`, **and** argv[1] has basename `aider` or argv contains `-m aider`.

### (b) Config **[H]** (source: `aider/main.py` l.464–476; `sample.aider.conf.yml`)

- `.aider.conf.yml` in the cwd, in the git root, and in `~/.aider.conf.yml`.
- Env: `AIDER_NOTIFICATIONS`, `AIDER_NOTIFICATIONS_COMMAND`, or a `.env` file.
- A repo-level file can override ours.

### (c) Mechanism **[H]** (source: `aider/io.py` `ring_bell`, `llm_started`, `get_input`, `confirm_ask`, `prompt_ask`)

```yaml
# ~/.aider.conf.yml
notifications: true                      # REQUIRED: the command is ignored unless this is true
notifications-command: "\"$HOME/.lidless/bin/lidless-hook\" aider waiting --ppid $PPID 2>/dev/null; exit 0"
```

- After the LLM has run (`llm_started()` sets `bell_on_next_input`), the **next** `get_input()` (prompt for the next message), `confirm_ask()` (yes/no approval such as "Run shell command?" or "Add file?") or `prompt_ask()` calls `ring_bell()`.
- `ring_bell()` runs `subprocess.run(cmd, shell=True, capture_output=True)`.
- If `notifications: true` is set but no command, aider uses `terminal-notifier` or `osascript`.

### (d) Payload and influence

- **No payload at all**: no argv JSON and no stdin.
- **"Done" and "needs approval" are indistinguishable**. The message is fixed: "Aider is waiting for your input".
- `$PPID` inside `/bin/sh -c` is the aider python pid.
- stdout is captured and ignored. A non-zero exit only prints a warning. It **cannot** affect the agent. **[H]**

### (e) Disk state

- `<git root>/.aider.chat.history.md` and `.aider.input.history` are appended per message. Only the mtime is useful. **[M]**

### (f) Chaining

- **Single command, so chain it.** If the user had a `notifications-command`, Lidless rewrites it to `lidless-hook aider waiting --chain -- '<old cmd>'`, and the helper runs the old command via `sh -c`.
- If the user had `notifications: true` with no command, the old behaviour was the OS default notification. Chain to `osascript` to preserve it, or tell the user. **[H]**

### (g) Caveats

- `subprocess.run` is **synchronous with no timeout**. Aider's prompt waits for our command, so the helper must return in milliseconds. **[H]**
- There is no session start/end signal. Use process lifetime (kqueue `NOTE_EXIT`).

---

## 9. Hookless fallbacks and agent-agnostic detection (all verified locally)

### 9.1 Identify agent processes correctly **[H]**

Verified with `scratchpad/research-snippets/procinfo.swift` and `agentscan.swift`, which call `proc_name`, `proc_pidpath` and `sysctl KERN_PROCARGS2`.

- **On macOS, `ps -o comm` prints argv[0], which is spoofable.**
  - Test: `bash -c 'exec -a my-fake-argv0 /bin/sleep 4'` gave `ps comm = my-fake-argv0`, while `proc_name = sleep` and `proc_pidpath = /bin/sleep`.
  - Cursor's launcher relies on exactly this (`exec -a "$0" node …`).
- **Claude Code's `proc_name` is its version string** (`2.1.295`), because the executable is `~/.local/share/claude/versions/2.1.295`. Its argv[0] is `claude`.
- **The Claude binary is multi-call:** a `ugrep` child shows exe = the claude binary. Matching on exe path alone gives false positives, so also check argv[0].
- **`proc_pidpath` returns empty** for processes whose binary was replaced or deleted by an auto-update (seen for 2 Claude pids). Fall back to `KERN_PROCARGS2` (exec path plus argv).
- **Never match on free-text argv of shells.** A `zsh -c "<long command mentioning @openai/codex>"` matched a naive rule.
- **Recommended signature:** (exe basename, argv[0] basename, argv[1] basename) checked against this table:

| Agent | exe basename | argv[0] basename | argv[1] |
|---|---|---|---|
| Codex | `codex` (native) | `codex` or full vendor path | `exec`/`app-server`/… or none |
| Codex npm wrapper | `node` | `node` | `…/bin/codex` or `codex.js` |
| Gemini CLI | `node` | `node` / full node path | `…/bin/gemini` or `…/@google/gemini-cli/dist/index.js` |
| Antigravity | `agy` | `agy` | — |
| Copilot CLI | `copilot` | `copilot` / full pkg path | — (npm wrapper: `node …/bin/copilot`) |
| Cursor CLI | `node` (in `~/.local/share/cursor-agent/versions/*/`) | `agent` or `cursor-agent` | `--use-system-ca` then `…/index.js` |
| opencode | `opencode` | `opencode` | `serve`/`run`/… |
| Aider | `python3.x`/`Python` | python path | `…/bin/aider` (or `-m aider`) |
| Claude Code | `<version>` or `claude` | `claude` | `daemon`/`bg-spare`/`bg-pty-host`/… are *infrastructure*, not sessions |

### 9.2 Busy/idle heuristics when no hook fires

- **TTY output recency (strong, agent-agnostic):**
  - TUIs repaint spinners and stream tokens while busy, and the pty slave's **`st_mtime` updates on every write**. **[H]**
  - Verified: the busy Claude session's `/dev/ttys004` had mtime equal to "now". Idle sessions had mtimes 20–35 min old.
  - Use `stat()` on the agent's controlling tty (`proc_pidinfo PROC_PIDTBSDINFO` → `e_tdev`, then map to `/dev/ttysNNN`). Treat "no write for N seconds" as idle-or-waiting.
  - Caveat: animated idle UIs or terminal resizes cause spurious writes. **[M]**
- **CPU delta** of the agent pid plus all descendants (`proc_pid_rusage(RUSAGE_INFO_V4)` `ri_user_time + ri_system_time`, mach-timebase-converted). Polling every 5–10 s is cheap. Idle Node/Bun TUIs sit near 0%. **[M]**
- **Child processes:** running tools spawn `bash`, `zsh`, `rg`, `node`, `python` and similar. If any non-infrastructure descendant exists, treat the agent as busy. **[M]**
- **Exit:** a kqueue `EVFILT_PROC` with `NOTE_EXIT` on each agent pid works without privileges for same-user processes. **[H]**
- **Wrapper command** (`lidless run -- codex …` with a PTY proxy): the most accurate option but intrusive. Use it only as an opt-in last resort. **[M]**

---

## 10. Recommendations for Lidless

1. **Build one helper (`lidless-hook`) and one event socket.** Install a **stable symlink** at `~/.lidless/bin/lidless-hook`, so Codex trust hashes and shell quoting stay stable. The helper must:
   - Read argv and stdin.
   - Find the agent pid by walking parents.
   - Post to the app and print nothing (or `{}`).
   - **Always exit 0.**

   Every installed command string uses the `"…/lidless-hook" <agent> <event> 2>/dev/null; exit 0` wrapper.
2. **Make installation opt-in per agent, with a diff preview and a backup** (`*.lidless-backup`). Per agent:
   - **Codex:**
     - Add or chain `notify`. This gives turn-complete immediately with no trust needed.
     - Add the `hooks.json` entries for `SessionStart`, `UserPromptSubmit`, `PermissionRequest`, `Stop`, `Interrupt` and `SessionEnd`, with explicit `timeout`s.
     - Show the user a one-time "open Codex → `/hooks` → trust" instruction. Detect untrusted state by checking whether `[hooks.state."…"]` exists in `~/.codex/config.toml`, read-only.
   - **Gemini CLI:** merge into `~/.gemini/settings.json` `hooks`: `SessionStart`, `BeforeAgent`, `AfterAgent`, `Notification` and `SessionEnd`.
   - **Antigravity:** add the `"lidless"` key with `Stop` to `~/.gemini/config/hooks.json`. Optionally chain `statusLine` to get `tool_confirmation_pending` and `agent_state`.
   - **Copilot CLI:** write a separate `~/.copilot/hooks/lidless.json` covering `sessionStart`, `userPromptSubmitted`, `agentStop`, `notification` (permission/elicitation/idle) and `sessionEnd`.
   - **Cursor CLI:** append to `~/.cursor/hooks.json`: `sessionStart`, `beforeSubmitPrompt`, `stop` and `sessionEnd`. Because the CLI is flaky, **always combine with heuristics**.
   - **opencode:** drop `~/.config/opencode/plugins/lidless.js`, the dual v1/v2 object.
   - **Aider:** set `notifications: true` and chain `notifications-command` in `~/.aider.conf.yml`.
3. **Use a state machine per agent pid.**
   - **busy** ← `UserPromptSubmit`/`BeforeAgent`/`beforeSubmitPrompt`/`session.status busy`/`task_started`, or tty activity, or child processes present.
   - **waiting-for-approval** ← `PermissionRequest`/`Notification(ToolPermission)`/`notification(permission_prompt|elicitation_dialog)`/`permission.asked`/`question.asked`/`form.created`/`tool_confirmation_pending=true`.
   - **idle (turn done)** ← `notify`/`Stop`/`AfterAgent`/`agentStop`/`stop`/`session.status idle`/Aider bell.
   - **gone** ← `SessionEnd`/`NOTE_EXIT`.
   - **Debounce "idle" by 5–10 s** before pushing to the phone, because some agents auto-continue (Stop-hook blocks, queued prompts, subagents).
4. **Phone push only on edge transitions** busy→idle and busy→waiting. Include the agent name, the cwd basename, and the first 140 characters of `last-assistant-message`/`prompt_response` where available (Codex, Gemini). Make message content opt-in for privacy.
5. **"No agent working" (to allow sleep) = every detected agent pid is idle, waiting, or gone, and the tty has been quiet ≥ N min, and CPU is low.** Hooks give fast, precise edges; heuristics are the safety net for Cursor `-p`, Aider and unknown agents.
6. **Dedupe the Claude Code × Cursor overlap.** If Lidless installs Claude Code hooks in `~/.claude/settings.json`, Cursor CLI will run them too. In the helper, classify as Cursor when `CURSOR_VERSION` is set or `cursor_version` is in the payload.
7. **Uninstall must restore** the saved `notify` / `notifications-command` / `statusLine` values and remove only Lidless entries, matched by the helper path, not by index.
8. **Nothing here requires sudo, a paid Developer ID, or a sandbox exception.** All files are in the user's home. The helper is a plain CLI and can be ad-hoc signed.

---

## 11. Risks / unknowns

- **Codex hook trust:** user hooks are inert until approved in `/hooks`, and any change to the command string invalidates trust. `codex exec` and possibly the VS Code/app-server clients may never show the review UI. Mitigation: rely on `notify` for turn-complete. **[H]**
- **Codex `notify` is a deprecated "legacy" path.** A `TODO: Remove this hook … when legacy notify support is removed` comment exists in `legacy_notify.rs`, so it could disappear in a future release. **[H]**
- **Accidental "keep going" loops:**
  - Codex `Stop` exit 2, Gemini `AfterAgent` exit ∉ {0,1}, Cursor `stop` `followup_message`, Copilot/agy `decision`.
  - A buggy or missing helper could make agents run forever and burn tokens. The `2>/dev/null; exit 0` wrapper and a no-stdout helper are mandatory. **[H]**
- **Synchronous hooks slow the agent:** Gemini (all hooks awaited), Aider (no timeout), and Codex/Copilot/Cursor sync events. The helper must be fast (Swift/C, no runtime startup). **[H]**
- **Cursor CLI hook support is incomplete and server-driven:** no `stop` in `-p` mode, no approval hook, a Linux bug, and behaviour can change without a client update. **[M]**
- **Antigravity CLI is closed-source and moving fast.** It has no needs-input hook (statusLine chaining is a workaround), exit-code semantics are undocumented, and the DB path is unknown. **[M/L]**
- **opencode v1/v2 split:**
  - The v2 plugin event envelope was not runtime-tested.
  - `session.idle` is deprecated.
  - Subagent sessions emit their own idle/busy events.
  - Plugin load errors can surface in the user's TUI. **[M/L]**
- **Copilot CLI inside VS Code (this user's actual setup):**
  - It is unverified whether `~/.copilot/hooks/*.json` fire for VS Code–hosted Copilot CLI sessions.
  - It is unverified whether `events.jsonl` persists `session.idle`.
  - VS Code's own Copilot Chat agent hooks are a different system, covered in the IDE report. **[L]**
- **Gemini CLI relevance:** consumer users were cut off on 2026-06-18, so many users will be on `agy` instead. Support both. **[H]**
- **Config precedence:** repo-level `.aider.conf.yml`, project `.gemini/settings.json`, and `disableAllHooks` in Copilot settings can override or disable our user-level entries. Lidless should show per-agent "hook verified" status by recording the last time each agent's hook actually fired. **[M]**
- **Heuristic false positives:** tty writes from resize or animations, background dev servers that are children of an agent shell, and long-running `sleep`/`watch` commands. Combine signals and use generous thresholds. **[M]**
- **Not runtime-tested end to end:** none of these agents are installed on this Mac, so no hook was observed firing locally. Payloads and semantics come from current docs and source or binary inspection, as dated above.

---

## 12. Sources

- Codex:
  - https://learn.chatgpt.com/docs/hooks (redirect from developers.openai.com/codex/hooks)
  - https://learn.chatgpt.com/docs/config-file/config-reference
  - github.com/openai/codex @6c372fb: `codex-rs/hooks/src/legacy_notify.rs`, `codex-rs/hooks/src/engine/{discovery.rs,command_runner.rs}`, `codex-rs/hooks/schema/generated/*.json`, `codex-rs/config/src/hook_config.rs`, `codex-rs/features/src/lib.rs`, `codex-rs/rollout/src/*`, `codex-cli/bin/codex.js`
  - Release rust-v0.162.1 (2026-10-09)
- Gemini CLI:
  - https://geminicli.com/docs/hooks/ (updated 2026-04-13)
  - https://geminicli.com/docs/hooks/reference/ (updated 2026-04-10)
  - github.com/google-gemini/gemini-cli @9b6e026: `packages/core/src/hooks/{types.ts,hookRunner.ts,hookSystem.ts,trustedHooks.ts}`, `packages/core/src/core/client.ts`, `packages/cli/src/config/settingsSchema.ts`, `packages/cli/src/utils/relaunch.ts`
  - Release v0.63.0 (2026-10-06)
- Antigravity:
  - https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/ (2026-05-19)
  - https://antigravity.google/docs/hooks
  - https://antigravity.google/docs/cli/statusline
  - https://antigravity.google/docs/cli/title
  - github.com/google-antigravity/antigravity-cli (README, CHANGELOG, `examples/title/title.sh`, release 1.3.3 2026-10-10)
  - https://antigravity.google/cli/install.sh (read only)
- Copilot CLI:
  - https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-hooks-reference
  - https://docs.github.com/en/copilot/reference/hooks-reference
  - Local bundle `/Applications/Visual Studio Code.app/Contents/Resources/app/node_modules.asar.unpacked/@github/copilot-darwin-arm64/` (v1.0.81-0: `npm-loader.js`, `app.js`, `schemas/session-events.schema.json`, `prebuilds/darwin-arm64/runtime.node` strings)
  - `~/.copilot/{config.json,logs/}`
  - github.com/github/copilot-cli release v1.0.95 (2026-10-09)
- Cursor CLI:
  - https://cursor.com/docs/agent/hooks
  - https://cursor.com/install (2026.10.01-e373342); package `downloads.cursor.com/lab/2026.10.01-e373342/darwin/arm64/agent-cli-package.tar.gz` (read only: `cursor-agent`, `index.js`, `190.index.js`)
  - forum.cursor.com/t/148316, /156220, /169059, /148511
- opencode:
  - https://opencode.ai/docs/plugins/ (2026-10-12)
  - https://opencode.ai/v2/docs/plugins
  - https://opencode.ai/v2/docs/build/plugins
  - github.com/anomalyco/opencode `dev` @bcf23b6 (v2.0.27: `packages/plugin`, `packages/schema/src/{session-status-event.ts,permission.ts,form.ts,event-manifest.ts}`, `packages/cli/bin/opencode.cjs`)
  - Tag v1.19.0: `packages/plugin/src/index.ts`, `packages/sdk/js/src/v2/gen/types.gen.ts`
- Aider:
  - https://aider.chat/docs/usage/notifications.html
  - github.com/Aider-AI/aider @5dc9490 (2026-05-22): `aider/io.py`, `aider/args.py`, `aider/main.py`, `aider/website/assets/sample.aider.conf.yml`
  - Release v0.86.0 (2025-08-09)
- Local verification snippets (read-only):
  - `/private/tmp/claude-501/-Users-tomasnguyen-Developer/3514aa88-efa8-4a60-97d7-2878eed849d4/scratchpad/research-snippets/procinfo.swift`
  - `/private/tmp/claude-501/-Users-tomasnguyen-Developer/3514aa88-efa8-4a60-97d7-2878eed849d4/scratchpad/research-snippets/agentscan.swift`
  - tty `stat` comparison against `~/.claude/sessions/<pid>.json`
