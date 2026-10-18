# 05 — Detecting start and finish of AI agents that run inside IDEs and GUI apps (macOS, October 2026)

Research date: 2026-10-12. Machine: macOS 26.6.2 (25G83), arm64, Xcode 26.6, VS Code 1.135.0, Claude Code 2.1.296.
Scope: agents that run inside an IDE or desktop app, not plain terminal CLIs. CLI agents are covered elsewhere and are mentioned here only when an IDE embeds them.
Rules followed: read-only. No sudo, no signals, no changes to settings or agent config files. Throwaway probes are in
`/private/tmp/claude-501/-Users-tomasnguyen-Developer/3514aa88-efa8-4a60-97d7-2878eed849d4/scratchpad/research-snippets/` (`rusage.swift`, `assertions.swift`, `sockets.swift`, `procargs.swift`, `scan.swift`).

Confidence tags: **[H]** high (official docs, source code, or verified locally), **[M]** medium (official but incomplete, or inferred from code), **[L]** low (third-party, forum, or my inference).

---

## 0. TL;DR

1. **Hooks are now common.** By October 2026, most of the important IDE agents have a documented lifecycle-hook system that runs a shell command, and in some cases an HTTP POST, with a JSON payload. This covers Claude Code in every host, Cursor, VS Code's own agent ("Local" harness), GitHub Copilot CLI and SDK sessions, Codex (CLI, IDE extension and the ChatGPT desktop app's Codex mode), Windsurf/Devin Desktop Cascade, Cline, Gemini CLI, Junie CLI (EAP), and opencode/Kilo through plugins. Lidless should ship **one hook shim** (`lidless-hook <source>`) and install a small, merged entry per agent. This is the **only reliable way to detect "finished" and "needs input"**. [H]
2. **Gaps without hooks.** Zed's native agent, JetBrains AI Assistant/Junie in the IDE, Xcode's built-in agent sessions, Roo Code (repo **archived 2026-05-15**), Continue's IDE extension, and Copilot Chat's own Local mode for "needs input" have no usable completion hook. These need behavioral detection. [H/M]
3. **New cheap signal: power assertions.** Many agents now hold a sleep assertion while they work. Verified locally: **interactive Claude Code spawns `caffeinate -i -t 300` as a child while busy**, restarts it every 240 s, and kills it 30 s after going idle. Codex (TUI, opt-in), the Codex app ("Prevent sleep while running"), Zed (`agent.prevent_idle_sleep`, on by default), Cursor (an Electron wakelock during agent runs, per Cursor staff), Copilot Chat (an experiment-gated `powerSaveBlocker`), Kilo (opt-in `caffeinate -i -w <pid>`) and JetBrains Air (option) do the same. `IOPMCopyAssertionsByProcess()` works without privileges and costs about 0.9 ms. [H for Claude Code, Codex and Zed source; M/L for the others]
4. **Second cheap signal: established sockets to model API endpoints.** Use libproc per candidate process (`proc_pidinfo(PROC_PIDLISTFDS)` + `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`). Verified: two busy Claude Code sessions had 9 and 11 ESTABLISHED TCP connections to `160.79.104.10:443`, which is in Anthropic's published `160.79.104.0/23`. Five idle sessions had **zero** TCP sockets. A scan takes 0.4 ms for 7 pids. [H]
5. **Avoid continuous `nettop`.** Measured on this machine: `nettop -P -L 4 -s 5` used **about 19 s of CPU in 15 s of wall time (about 130 % CPU)**. A single one-shot `nettop -P -L 1` costs about 0.05 s of CPU but takes about 5 s of wall time. If byte counts are needed, take one one-shot sample per minute and diff it. [H, verified]
6. **CPU of Electron helpers is noisy.** Indexing, language servers and idle bugs push `… Helper (Plugin)` to 25–1200 % CPU with no agent running. Use CPU only as a supporting signal. [M]
7. **Recommended tiers.**
   - Tier A: hooks (authoritative for start, finish and needs input).
   - Tier B: agent state files plus agent-attributed power assertions.
   - Tier C: per-process model-API sockets and child-process churn of known agent binaries and IDE helpers.
   - Tier D: CPU, nettop bytes and workspace file writes as tie-breakers.
   - Declare "no agent working" only after every tier has been quiet for a grace period and no "needs input" is pending.

---

## 1. Local verification results (read-only)

| # | What | Result | How verified |
|---|---|---|---|
| L1 | Claude Code process naming | `ps comm` shows `claude` (argv[0]). `proc_name()` returns the **version string** (`2.1.296`) because the executable is `~/.local/share/claude/versions/2.1.296`. `nettop` shows it as `2.1.296.<pid>`. After an auto-update, `proc_pidpath()` returns `""` for an old process whose binary was deleted (pid 24617, version 2.1.289). | `rusage.swift`, `nettop` |
| L2 | Busy Claude Code holds a sleep assertion | `pid 843 caffeinate -i -t 300` (parent 76720, busy session) and `pid 265 caffeinate -i -t 300` (parent 96888, busy session). Idle sessions have no caffeinate child. `pmset -g assertions`: `PreventUserIdleSystemSleep named: "caffeinate command-line tool"`. | `pmset -g assertions`, `ps`, `assertions.swift` |
| L3 | Implementation in the 2.1.296 binary | `class … {refCount… acquire(){…spawnInhibitor(),startRestartInterval()} release(){… setTimeout(…,30000)} getSpawnArgs(){… if(macos) return ["caffeinate",["-i","-t","300"]]}}`, restart interval 240000 ms. `acquire()` is called from the REPL UI when status becomes `busy` and from the remote-control "bridge_turn_keep_awake" path. It was **not** seen in the SDK/stream-json path, so it is probably absent when the binary is driven by the VS Code extension, Xcode or the Agent SDK. | `strings` on the binary |
| L4 | Sockets of busy vs idle Claude sessions | busy 76720: 9 TCP, all to 160.79.104.10:443 ESTABLISHED. Busy 96888: 30 TCP, 11 to Anthropic. Idle 23139, 9220, 96654, 55583, 44386: 0 TCP. 0.4 ms total. | `sockets.swift`, `nettop -m tcp` |
| L5 | CPU of busy vs idle Claude | 2 s window: busy 96888 15.9 %; busy 76720 2.2 % (waiting on a tool); idle 0.4–2.3 %. CPU alone does not separate busy from idle. | `rusage.swift` |
| L6 | Full process scan cost | `proc_listallpids` + `proc_pidpath` + `proc_pid_rusage` over 577 pids: 7.4 ms. `IOPMCopyAssertionsByProcess`: 0.93 ms per call. | `scan.swift` |
| L7 | nettop cost | one-shot `-L 1`: 5.05 s wall, 0.05 s CPU. Continuous `-L 4 -s 5` (with or without `-d`): 15 s wall, **≈19.3 s CPU**. | `/usr/bin/time -p nettop …` |
| L8 | Reading argv and env of same-user processes | `sysctl KERN_PROCARGS2` works without privileges. Example: bg Claude pid 24617 `env CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_SESSION_KIND=bg`. Terminal sessions show `__CFBundleIdentifier=com.apple.Terminal`, `TERM_PROGRAM=Apple_Terminal`. This shows which GUI app launched the session. | `procargs.swift` (only whitelisted keys printed) |
| L9 | Claude session registry | `~/.claude/sessions/<pid>.json` has `entrypoint` (from `CLAUDE_CODE_ENTRYPOINT`). Values present in the binary: `cli`, `claude-vscode`, `claude-desktop`, `sdk-ts`, `sdk-py`, `sdk-cli`, `local-agent`. The registry is written for every process except teammate subagents and child sessions (`FU()` gate `Jc()`), so IDE- and desktop-hosted sessions should register too. `status`/`statusUpdatedAt` change only on transitions: the two busy sessions were 951 s and 1587 s old. | binary strings; session files |
| L10 | VS Code 1.135.0 bundle | Helpers: `Code Helper.app`, `Code Helper (Plugin).app`, `Code Helper (Renderer).app`, `Code Helper (GPU).app`. **All share bundle id `com.microsoft.VSCode.helper`.** Copilot is built in (`Resources/app/extensions/copilot`). The new **Agent Host** is a utility process `{type:"agentHost", name:"agent-host", entryPoint:"vs/platform/agentHost/node/agentHostMain"}` with args `--logsPath … --user-data-dir … --telemetry-level …`. It does not set `allowLoadingUnsignedLibraries`, so it runs as plain `Code Helper`. The extension host sets `allowLoadingUnsignedLibraries: true` (microsoft/vscode `extensionHostStarter.ts`), so it runs as **`Code Helper (Plugin)`**. | `PlistBuddy`, `out/main.js`, GitHub source |
| L11 | VS Code user state | `~/Library/Application Support/Code/User/globalStorage/agent-host.db` (SQLite: `sessions(session_uri, provider, start_time, external, registration_source)`, `metadata`) and `agent-host-config.json` (`codexAgentEnabled`, `claudeMultiRootEnabled`, `showExternalSessions`, `terminalAutoApproveRules`, …). VS Code was not running, so its live process tree could **not** be observed. | `sqlite3 -readonly` |
| L12 | Xcode 26.6 coding intelligence | Frameworks `IDEIntelligenceAgents`, **`IDEIntelligenceACP`** (Agent Client Protocol client: `NewSessionRequest`, `PermissionRequest`, `CreateTerminalRequest`, …), `IDEIntelligenceGemini`, `IDEIntelligenceChat`. `/Applications/Xcode.app/Contents/Developer/usr/bin/agent` is a sh wrapper: `exec mcpbridge run-agent "$@"`. `IDEIntelligenceAgents` strings: `--input-format=stream-json`, `--output-format=stream-json`, `Set CLAUDE_CONFIG_DIR to Claude Agent config directory`, `ClaudeAgentConfig`, `Override CODEX_HOME`, `app-server`, `codex_hooks`, `APPLE_CLAUDE_CODE_DANGEROUSLY_BYPASS_HOOKS`, `Sending initialize request with hooks`. `~/Library/Developer/Xcode/CodingAssistant` does not exist on this machine (feature not used yet). | `strings` |
| L13 | Claude.app (desktop) | `~/Library/Application Support/Claude/claude-code/2.1.289/` (bundled CLI for the Code tab), `claude-code-vm/`, `claude-code-sessions/<acct>/<org>/scheduled-tasks.json`, `local-agent-mode-sessions/<acct>/<org>/local_<uuid>.json` (Cowork). Cowork session keys: `sessionId, processName, cliSessionId, cwd, createdAt, lastActivityAt, model, isArchived, isAgentCompleted, vmProcessName, hostLoopMode, …`. Claude.app was not running. | `ls`, key-only dump |
| L14 | Installed IDE-side agents | VS Code (Copilot built in; no 3rd-party AI extensions installed), Xcode 26.6, Claude.app, PyCharm (old). **Not installed:** Cursor, Windsurf/Devin Desktop, Zed, ChatGPT/Codex app, `~/.codex`, `~/.cursor`, `~/.gemini`, `~/.codeium`. | `ls` |
| L15 | DNS of model hosts (today) | `api.anthropic.com → 160.79.104.10`; `api.openai.com → 162.159.140.245, 172.66.0.243` (Cloudflare anycast); `chatgpt.com → 172.64.155.209, 104.18.32.47`; `api2.cursor.sh → 3.92.129.183, 52.21.130.202, 34.225.159.174` (AWS); `api.githubcopilot.com → 140.82.112.22`; `api.individual.githubcopilot.com → 140.82.114.21`; `generativelanguage.googleapis.com → 172.217.x.4`; `server.self-serve.windsurf.com → 34.49.14.144`; `inference.codeium.com → 192.34.20.166`. Only Anthropic publishes a stable dedicated range. | `dig +short` |

---

## 2. Summary matrix

Legend for "Finish signal": ✅ documented hook event · ⚠️ partial or caveated · ❌ none.

| Agent / host | Hook config (user level) | Start | Finish | Needs input | Best fallback |
|---|---|---|---|---|---|
| Claude Code in terminal, VS Code ext, JetBrains plugin, Claude.app Code tab | `~/.claude/settings.json` | `UserPromptSubmit` ✅ | `Stop` / `StopFailure` ✅ | `Notification` (`permission_prompt`, `idle_prompt`, `agent_needs_input`, `elicitation_dialog`) ✅, **⚠️ does not fire in VS Code ext**; `PermissionRequest` | `~/.claude/sessions/<pid>.json` + caffeinate child + Anthropic sockets |
| Claude Agent inside **Xcode** | `$CLAUDE_CONFIG_DIR` = `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/settings.json` (inferred) | ⚠️ | ⚠️ | ⚠️ | Anthropic sockets of the Xcode-spawned `claude` |
| **Cursor** IDE (Agent/Composer) | `~/.cursor/hooks.json` (`version:1`) | `beforeSubmitPrompt` ✅ | `stop {status}` ✅, `sessionEnd {reason}` | ❌ (no event) | Electron wakelock of Cursor main + `Cursor Helper (Plugin)` sockets |
| **VS Code** Copilot agent, Local harness | `~/.copilot/hooks/*.json` (+ `.github/hooks/*.json`) | `UserPromptSubmit` ✅ | `Stop` ✅ | ❌ (OS notification only) | `Code Helper (Plugin)` sockets/CPU; Copilot `powerSaveBlocker` (experimental) |
| VS Code Agent Host: Copilot sessions | Copilot SDK hooks = Copilot CLI format (`~/.copilot/hooks/*.json`) | `userPromptSubmitted` ✅ | `agentStop` ✅ | `permissionRequest` / `notification` (CLI only) ⚠️ | `Code Helper` (agent-host) sockets |
| VS Code Agent Host: Claude sessions | Claude Agent SDK (settings sources unknown) | ⚠️ | ⚠️ | ⚠️ | child `claude` binary sockets |
| **Codex** CLI / IDE ext / ChatGPT-app Codex mode | `~/.codex/hooks.json` or `[hooks]` in `~/.codex/config.toml`; legacy `notify` | `UserPromptSubmit` ✅ | `Stop` ✅, `Interrupt`, legacy `notify` `agent-turn-complete` | `PermissionRequest` ✅ | `codex` process sockets; Codex assertion "Codex is running an active turn" (TUI opt-in) |
| **Windsurf / Devin Desktop** Cascade | `~/.codeium/windsurf/hooks.json` | `pre_user_prompt` ✅ | `post_cascade_response` ✅ (async) | ❌ | `language_server_macos_arm` sockets/CPU [L] |
| **Cline** (VS Code / JetBrains) | `~/Documents/Cline/Hooks/<HookName>` (executable files) | `TaskStart` / `TaskResume` / `UserPromptSubmit` ✅ | `TaskComplete`, `TaskCancel` ✅ | ❌ | extension-host sockets |
| **Roo Code** | — (repo archived 2026-05-15, last v3.54.0) | ❌ | ❌ | ❌ | extension-host sockets |
| **Kilo Code** (new, OpenCode-based) | plugins (`session.idle`, `permission.asked`); VS Code `kilo-code.new.attention.*` | ✅ (plugin) | ✅ (plugin) | ✅ (plugin) | opt-in `caffeinate -i -w <pid>` |
| **Continue** | CLI (`cn`) has Claude-compatible hooks (per commit); IDE: none documented | ⚠️ | ⚠️ | ❌ | extension-host sockets |
| **Zed** agent panel | none | ❌ | ❌ (OS notification `agent.notify_when_agent_waiting`) | ❌ | Zed `NSProcessInfo` activity assertion (`agent.prevent_idle_sleep`, default on) |
| Zed external agents (ACP) | the agent's own hooks (Claude Agent SDK / codex-acp / gemini) | ⚠️ | ⚠️ | ⚠️ | adapter process sockets |
| **JetBrains** AI Assistant / Junie (IDE) / ACP agents | Junie **CLI** `~/.junie/config.json` (EAP; "ACP and server hosts don't invoke hooks yet") | ❌ in IDE | ❌ in IDE | ❌ | JetBrains Air prevent-sleep option; agent child process sockets |
| **Xcode** 26.x coding intelligence | none of its own; per-agent config under `CodingAssistant/` | ⚠️ | ⚠️ | ❌ | sockets of Xcode-spawned `claude`/`codex` |
| **Claude.app** Cowork (local agent mode) | VM-based; no host hooks found | ❌ | `isAgentCompleted`, `lastActivityAt` in session JSON [M] | ❌ | `local-agent-mode-sessions/*.json` mtime + VM CPU |
| **ChatGPT desktop app** (Chat/Work/Codex merged 2026-07-09) | Codex mode → Codex hooks (in-app trust review since 26.506) | ✅ (Codex) | ✅ (Codex) | ✅ (Codex) | app "Prevent sleep while running" assertion |
| **Gemini CLI** (also embedded via ACP / Gemini Code Assist) | `~/.gemini/settings.json` | `BeforeAgent` ✅ | `AfterAgent` ✅ | `Notification` (`ToolPermission`) ✅ | process sockets |

---

## 3. Per-agent details

### 3.1 Claude Code in IDE hosts (VS Code extension, JetBrains plugin, Claude.app Code tab, Agent SDK hosts)

**Hooks fire in every host.** The official hooks reference says Claude Code "fires the same hook events wherever it runs: sessions in the terminal, IDE extensions, the Desktop app, and cloud sessions". Cloud sessions do not read the local `~/.claude/settings.json`. [H] Source: https://code.claude.com/docs/en/hooks

- **Config files:** `~/.claude/settings.json` (user), `<proj>/.claude/settings.json`, and `<proj>/.claude/settings.local.json`. Lidless must **merge** into the user file and never overwrite it. [H]
- **Events Lidless needs:**
  - `SessionStart`, `UserPromptSubmit` (turn start), `Stop` (turn finished; input includes `last_assistant_message`; no matcher, always fires), and `StopFailure` (turn ended by an API error; matchers `rate_limit`, `overloaded`, `authentication_failed`, `billing_error`, `server_error`, `unknown`, …).
  - `Notification`, with `notification_type` ∈ {`permission_prompt`, `idle_prompt`, `auth_success`, `elicitation_dialog`, `elicitation_url_dialog`, `elicitation_complete`, `elicitation_response`, `agent_needs_input`, `agent_completed`, `quota_auto_resume_fired`, `quota_auto_resume_stale`, `quota_auto_resume_disabled`}.
  - `PermissionRequest`, and `SessionEnd` (reasons `clear`, `resume`, `logout`, `prompt_input_exit`, `other`).
  - [H]
- **Common input fields:** `session_id`, `prompt_id`, `transcript_path`, `cwd`, `scratchpad_dir` (≥2.1.257), `permission_mode`, `effort.level`, `hook_event_name`, `agent_id`, `agent_type`. [H]
- **Handler types:** `command` (supports `"async": true`, which never blocks the agent) and `http` (`{"type":"http","url":…,"timeout":…,"headers":{…},"allowedEnvVars":[…]}`, sent as a JSON POST; non-2xx responses are non-blocking errors). [H]
- **Default timeouts:** 600 s for command/http hooks; 30 s on `UserPromptSubmit`; `SessionEnd` hooks share a 1.5 s budget. [H]
- **VS Code extension caveats:**
  - Issue #66482, "The Notification hook never fires when Claude Code runs as the VSCode native extension", was confirmed again on extension 2.1.186 and closed 2026-08-05 as *not planned / inactive*. In the same report, `Stop` **does** fire. So in VS Code, **needs-input must use `PermissionRequest` plus behavioral fallback**. [H for the issue state; M that it still reproduces in 2.1.29x]
  - Earlier issue #53774 (user-level hooks ignored in 2.1.120 ext) was fixed and closed 2026-06-02. [H]
  - Source: https://github.com/anthropics/claude-code/issues/66482
- **Process shape:**
  - The extension runs a bundled native `claude` (Nixpkgs packaging points at `…/anthropic.claude-code-<ver>/resources/native-binary/claude`) as a child of `Code Helper (Plugin)`. [M]
  - JetBrains runs `claude` in the IDE terminal: it is the interactive CLI, so the caffeinate signal and the session registry apply. [M]
  - Claude.app's Code tab uses `~/Library/Application Support/Claude/claude-code/<ver>/claude` with entrypoint `claude-desktop`. [M, local dir L13]
- **Session registry:** expect `~/.claude/sessions/<pid>.json` with `entrypoint: "claude-vscode"` or `"claude-desktop"` (L9). Lidless should **verify this on first run** and fall back to sockets if it is missing. [M]
- **Sleep assertion:** caffeinate is spawned from the interactive REPL, so it is reliable for terminal and JetBrains-terminal sessions. It is probably absent for VS Code-ext, Xcode and Agent SDK sessions (L3). [M]

### 3.2 Cursor IDE (Agent / Composer / background agents)

Source: https://cursor.com/docs/hooks (fetched 2026-10-12). [H unless noted]

- **Locations (all merged, priority high→low):**
  - Enterprise `/Library/Application Support/Cursor/hooks.json`
  - Team (dashboard, synced every 30 min)
  - Project `<root>/.cursor/hooks.json` (requires a trusted workspace; relative paths resolve from the project root)
  - **User `~/.cursor/hooks.json`** (runs from `~/.cursor/`)
- **Format:** `{"version": 1, "hooks": {"<event>": [{"command": "...", "type": "command", "timeout": 30, "matcher": "...", "loop_limit": 5, "failClosed": false}]}}`.
- **Events:**
  - Agent: `sessionStart`, `sessionEnd`, `preToolUse`, `postToolUse`, `postToolUseFailure`, `subagentStart`, `subagentStop`, `beforeShellExecution`, `afterShellExecution`, `beforeMCPExecution`, `afterMCPExecution`, `beforeReadFile`, `afterFileEdit`, `beforeSubmitPrompt`, `preCompact`, `stop`, `afterAgentResponse`, `afterAgentThought`
  - Tab: `beforeTabFileRead`, `afterTabFileEdit`
  - App: `workspaceOpen`
- **Common input:** `conversation_id`, `generation_id` (changes per user message), `model`, `model_id`, `model_params`, `hook_event_name`, `cursor_version`, `workspace_roots[]`, `user_email`, `transcript_path`.
- **Payloads Lidless needs:**
  - `beforeSubmitPrompt` → `prompt`, `attachments[]`; output `{"continue": true|false, "user_message"}`. **Lidless must answer `{"continue":true}`.**
  - `stop` → `status` ∈ `completed|aborted|error`, `loop_count`; output `followup_message` (a non-empty value auto-submits a new prompt, so Lidless must output nothing or `{}`).
  - `afterAgentResponse` → `text`.
  - `sessionStart` → `session_id`, `is_background_agent`, `composer_mode` (`agent|ask|edit`). Fire-and-forget.
  - `sessionEnd` → `session_id`, `reason` ∈ `completed|aborted|error|window_close|user_close`, `duration_ms`, `is_background_agent`, `final_status`, `error_message`.
- **Blocking semantics:**
  - Exit 0 → stdout JSON is used. Exit 2 → block. Other non-zero, crash or timeout → fail-open unless `failClosed:true`.
  - **Permission hooks** (`beforeShellExecution`, `beforeMCPExecution`, `beforeReadFile`, `beforeTabFileRead`, `subagentStart`, `preToolUse`) **block on invalid JSON** even when `failClosed` is false. **Lidless must not register any permission hook.**
- **Env vars passed to hooks:** `CURSOR_PROJECT_DIR`, `CURSOR_VERSION`, `CURSOR_USER_EMAIL`, `CURSOR_TRANSCRIPT_PATH`, `CURSOR_CODE_REMOTE`, `CLAUDE_PROJECT_DIR` (alias).
- **Third-party hooks:**
  - Cursor "supports loading hooks from third-party tools like Claude Code". `loop_limit` defaults to `null` for Claude Code hooks.
  - Consequence: **Lidless's Claude Code hooks may also fire inside Cursor.** The shim must attribute by env (`CURSOR_VERSION` present → source `cursor`) and dedupe. [M; the details page returned 404]
- **Cloud agents** do not load the user-level `~/.cursor/hooks.json`, which is fine because they run remotely.
- **No "needs input" event.** Staff confirm that system notifications are **off by default** (Settings → Notifications → System Notifications) and fire only when the window is unfocused. [M, forum]
- **Sleep:** Cursor staff (2026-05-06): "Cursor does keep the system active when there's an agent actively running (via an Electron wakelock)" but "can't override … when you close your screenlid". This should appear as a `NoIdleSleepAssertion` owned by the Cursor main process, probably named `"Electron"`. [M] Source: https://forum.cursor.com/t/add-option-to-disable-computer-sleep-while-an-agent-is-running/159837
- **Network hosts:** `api2.cursor.sh` (most API), `api5.cursor.sh` (agent), `api3.cursor.sh` (Tab, HTTP/2), `repo42.cursor.sh` (indexing), `api4.cursor.sh`, `*.gcpp.cursor.sh`. Wildcards `*.cursor.sh`, `*.cursorapi.com`, `*.cursor-cdn.com`, `*.cursorvm.com`. IPs are AWS and change. [H] Source: https://cursor.com/docs/enterprise/network-configuration
- **Process names:** `Cursor Helper (Plugin)` is the extension host and indexer. Forum reports show it hitting **1284 % CPU while indexing**, so CPU is noisy. [M]

### 3.3 VS Code + GitHub Copilot agent mode (VS Code 1.135, Oct 2026)

**Three harnesses.** VS Code now runs chat sessions on separate harnesses, each with its own hook system. [H] Source: https://code.visualstudio.com/docs/agent-customization/hooks

| Session target | Runs in | Hook implementation |
|---|---|---|
| Local (classic Copilot agent mode) | Extension host (`Code Helper (Plugin)`) | **VS Code Local hooks** |
| Copilot | **Agent Host** (`Code Helper`, type `agentHost`) | Copilot SDK hooks (same as Copilot CLI) |
| Claude | Agent Host | Claude Agent SDK |
| Codex | Agent Host or the OpenAI Codex extension | Codex runtime |
| Cloud | provider infra | cloud agent |

**Local harness hooks (Preview)** [H] Sources: https://code.visualstudio.com/docs/agent-customization/hooks and https://code.visualstudio.com/docs/agents/reference/hooks-reference.md
- **Settings:**
  - `chat.useHooks` (default **true**)
  - `chat.hookFilesLocations` (default `{}`; folder or `.json` paths, relative or `~`)
  - `chat.useClaudeHooks` (default **false**; reads `~/.claude/settings.json` and `.claude/settings*.json`, **ignores matchers**)
  - `chat.useCustomizationsInParentRepositories`
  - **There is no `chat.hooks` setting.**
- **Locations:**
  - Workspace `.github/hooks/*.json` (subject to Workspace Trust)
  - **User `~/.copilot/hooks/*.json`**
  - Custom-agent `.agent.md` frontmatter `hooks`
  - Plugin `hooks.json`
- **Events:** `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PreCompact`, `SubagentStart`, `SubagentStop`, `Stop` ("the current agent execution is about to stop").
- **Format:** `{"hooks":{"Stop":[{"type":"command","command":"…","osx":"…","timeout":15,"env":{…}}]}}`. Also accepted: the Copilot format (`version` + lowerCamelCase events, mapped) and the Claude format.
- **stdin:** `timestamp` (ISO 8601), `cwd`, `session_id`, `hook_event_name`, `transcript_path`. Per event: `SessionStart.source` (`"new"`), `UserPromptSubmit.prompt`, `Stop.stop_hook_active`, `SubagentStop.agent_id/agent_type/stop_hook_active`, `PreToolUse.tool_name/tool_input/tool_use_id`, `PreCompact.trigger`.
- **Output:** `continue`, `stopReason`, `systemMessage`, `decision:"block"` + `reason` (Stop/SubagentStop/PostToolUse), `hookSpecificOutput`.
- **Exit codes:** 0 = ok, 2 = blocking (stderr goes to the model), other = warning.
- **Timeout:** default **30 s**.
- **Troubleshooting:** Output channel "GitHub Copilot Chat Hooks"; command "Chat: Configure Hooks" or `/hooks`.

**Copilot SDK / Copilot CLI hooks** (used by Agent Host Copilot sessions) [H for CLI; M that the Agent Host uses the identical loader] Source: https://docs.github.com/en/copilot/reference/hooks-reference
- **Locations:** `~/.copilot/hooks/*.json` (or `$COPILOT_HOME/hooks/`), inline `hooks` in `~/.copilot/settings.json`, repo `.github/hooks/*.json`, `.github/copilot/settings(.local).json`, and **repo** `.claude/settings.json`. `~/.copilot/config.json` is **no longer** read for hooks.
- **Format:** `{"version":1,"hooks":{"agentStop":[{"type":"command","bash":"…","timeoutSec":30}]}}`. Types are `command`, `http`, `prompt`.
- **Events:** `sessionStart`, `sessionEnd` (`reason` ∈ `complete|error|abort|timeout|user_exit`), `userPromptSubmitted`, `userPromptTransformed`, `preToolUse`, `permissionRequest` (CLI only), `postToolUse`, `postToolUseFailure`, **`agentStop`** (`transcriptPath`, `stopReason`, `stop_hook_active`), `subagentStart`, `subagentStop`, `preCompact`, `errorOccurred`, `notification` (CLI only).
- **Payload casing:** camelCase events carry camelCase fields with a Unix-ms `timestamp`. PascalCase events carry snake_case fields with an ISO timestamp.
- **Exit codes:** 2 is a warning, except deny for `preToolUse` / `permissionRequest`. Other non-zero codes are fail-open, except `preToolUse` fails closed. **Lidless must never register `preToolUse` here.**
- **Shared directory hazard:** `~/.copilot/hooks/*.json` is read by **both** the VS Code Local harness and Copilot CLI/SDK, and their schemas differ (`command` vs `bash`, PascalCase vs camelCase). A third-party package notes that "the VS Code Copilot extension and the Copilot CLI … have incompatible hook schemas". Lidless should write one file whose entries carry **both** `command` and `bash` keys and test both consumers. [M]

**Notifications** (VS Code built-in, not hooks) [H] Source: https://code.visualstudio.com/docs/agents/reference/ai-settings
- `chat.notifyWindowOnConfirmation`: `off | windowNotFocused` (default) `| always`. OS notification when a session needs input.
- `chat.notifyWindowOnResponseReceived`: same values. OS notification when a response arrives.
- Accessibility signals: `accessibility.signals.chatResponseReceived`, `chatUserActionRequired`, `chatRequestSent`.
- `sessions.showApplicationBadge`: Dock badge with the count of sessions needing attention. Default false on Stable, true on Insiders.
- `chat.agentsControl.enabled`: command-center in-progress and unread badges.
- Lidless **cannot read these OS notifications.** The Notification Center DB is private and TCC-protected. The Dock badge could be read through the Accessibility API (`AXStatusLabel` on Dock items), which needs the Accessibility permission. [M]

**Agent Host settings** (experimental): `chat.agentHost.claudeAgent.enabled` (default true), `chat.agentHost.codexAgent.enabled` (false), `chat.agents.claude.preferAgentHost` (true), `chat.editor.codex.preferAgentHost` (false), `github.copilot.chat.claudeAgent.enabled` (true), `chat.agentSessions.showExternal` (`none`…`all`). [H]

**Extension API / power** [H, source: microsoft/vscode `main` Oct 2026]
- VS Code exposes `vscode.env.power.startPowerSaveBlocker(type)` with types `'prevent-app-suspension' | 'prevent-display-sleep'`, plus `onDidSuspend` and `onDidResume`.
- Copilot Chat (`extensions/copilot/src/extension/prompt/node/chatMLFetcher.ts`) calls `this._powerService.acquirePowerSaveBlocker()` around chat requests when the experiment `ConfigKey.TeamInternal.ChatRequestPowerSaveBlocker` is on. It releases **2 minutes** after the last request (`RELEASE_DELAY_MS = 2*60*1000`).
- Electron's blocker appears as `NoIdleSleepAssertion` named `"Electron"` owned by the main `Code` process. Evidence for this mapping comes from a Claude Desktop issue showing `PID 658(Claude) Released NoIdleSleepAssertion "Electron"` [M].
- The signal is **experiment-gated, so unreliable**.
- A Lidless **companion VS Code extension** is possible (it could watch `vscode.chat`/terminal APIs). However, there is no stable public API to observe *other* extensions' chat sessions, and building on a proposed API needs Insiders. Not recommended for v1. [M]

**Network:** Copilot API hosts are `*.githubcopilot.com`, `*.individual.githubcopilot.com` (Pro/Pro+ since 2026-03-02), business/enterprise variants, and `copilot-proxy.githubusercontent.com`. [H] Source: https://docs.github.com/en/enterprise-cloud@latest/copilot/reference/copilot-allowlist-reference

### 3.4 OpenAI Codex: IDE extension, ChatGPT desktop app (Codex mode), Xcode, CLI

- **Product status:** Codex became part of the **ChatGPT desktop app** on 2026-07-09 (build 26.707). A compat `/Applications/Codex.app` and the `Codex.dmg` name remain [M]. Hooks went GA on 2026-05-14, and "Codex app 26.506: Added an in-app trust review flow for hooks" (2026-05-08), so **hooks run in the app**. [H] Source: https://learn.chatgpt.com/docs/changelog
- **Hooks** [H] Source: https://learn.chatgpt.com/docs/hooks.md (redirect from developers.openai.com/codex/hooks)
  - **Locations:** `~/.codex/hooks.json`, inline `[hooks]` in `~/.codex/config.toml`, and `<repo>/.codex/hooks.json` / `config.toml` (repo layer only when trusted). All matching hooks run.
  - **Events:** turn-scoped `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PreCompact`, `PostCompact`, `UserPromptSubmit`, `SubagentStop`, `Stop`; `Interrupt`; `SessionStart`, `SubagentStart`; `SessionEnd` (main thread only; runs on archive/delete, normal close, or **after 30 idle minutes not open in any connected client**).
  - **Common stdin:** `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `model`. Turn events add `turn_id`. Most events add `permission_mode`. `Stop` adds `stop_hook_active`, `last_assistant_message`. `PermissionRequest` adds `tool_name`, `tool_input` (+`description`).
  - **Output:**
    - On exit 0, `Stop` needs either no output or valid JSON. Plain text is invalid.
    - `{"decision":"block","reason":…}` continues the turn.
    - `continue:false` overrides.
    - Exit 2 blocks with stderr as the reason.
  - **Timeouts:** default **600 s**. `SessionEnd`/`Interrupt` default 1 s (max 3 s).
  - **Trust: non-managed hooks must be reviewed and trusted** (`/hooks` in CLI, or the app's trust review), and trust is keyed by hash. **Lidless cannot auto-trust**; it must guide the user. `--dangerously-bypass-hook-trust` exists only per invocation.
  - **Feature flag:** `[features] hooks = false` disables hooks (deprecated alias `codex_hooks`).
  - **Handler types:** `command`, `mcp_tool` (`prompt`/`agent` are parsed and skipped).
- **Legacy `notify`** [H] Source: openai/codex `codex-rs/hooks/src/legacy_notify.rs`
  - Config: `notify = ["/abs/path/prog", "arg1"]` in `config.toml`. Codex runs the program with the JSON appended as the **last argv argument**; stdin/stdout are null.
  - Fires on `AfterAgent`, i.e. turn complete. Payload: `{"type":"agent-turn-complete","thread-id":…,"turn-id":…,"cwd":…,"client":"codex-tui"|…,"input-messages":[…],"last-assistant-message":…}`.
  - Lives in the shared hooks crate, so it **also works for app-server clients** (IDE ext, app); the `client` field distinguishes them.
  - **No trust step needed**, which makes it a good completion-only fallback. `notify` is a single value, so Lidless must chain any existing value.
- **IDE extension process:** spawns its bundled `codex app-server` (JSON-RPC over stdio). The override setting is `chatgpt.cliExecutable`. [M]
- **App-server protocol** [H]: notifications `turn/started`, `turn/completed`, `thread/status/changed` (`notLoaded|idle|systemError|active{activeFlags}`), and approval requests `item/commandExecution/requestApproval`, `item/fileChange/requestApproval`, `item/permissions/requestApproval`, `item/tool/requestUserInput`. A third party **cannot attach to the IDE's stdio app-server**. A separate `codex app-server --listen unix://PATH` is possible, but it would not see threads owned by another server process. Not useful for observation.
- **Sleep** [H] Source: openai/codex `codex-rs/utils/sleep-inhibitor/src/macos.rs`, `features/src/lib.rs`
  - TUI only: experimental feature `prevent_idle_sleep` (default **false**) creates `IOPMAssertionCreateWithName("PreventUserIdleSystemSleep", "Codex is running an active turn")` while a turn runs.
  - The app has a General setting "Prevent sleep while running" (macOS/Linux). [H, https://learn.chatgpt.com/docs/reference/settings.md]
  - Its assertion owner and name are unknown. [L]
- **Xcode-hosted Codex** runs with `CODEX_HOME` overridden to `~/Library/Developer/Xcode/CodingAssistant/codex/` (guides; L12 string "Override CODEX_HOME"). **`~/.codex/hooks.json` is not used there.** Lidless would have to install into that directory as well. [M]

### 3.5 Cline (VS Code, JetBrains, CLI)

Source: https://mintlify.wiki/cline/cline/customization/hooks (mirror; official docs.cline.bot hook pages now stub to "SDK Plugins"); Cline v3.36 launch post. [M]
- **Hook names** (one executable file each, **no extension**, `chmod +x`): `TaskStart`, `TaskResume`, `TaskCancel`, `TaskComplete` (fires when `attempt_completion` succeeds), `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `PreCompact`.
- **Global dir:** **`~/Documents/Cline/Hooks/`**. Project dir: `.clinerules/hooks/`. Global hooks run before workspace hooks.
- **Enabling:** Settings → Features → **Enable Hooks**, plus a per-hook toggle in the Hooks tab. **The user must enable these in the UI.**
- **stdin:** `taskId`, `hookName`, `clineVersion`, `timestamp` (ms string), `workspaceRoots[]`, `userId`, `model{provider,slug}`, plus `taskComplete:{task}` / `taskStart:{task}` / etc.
- **stdout:** `{"cancel":false,"contextModification":"","errorMessage":""}`. Only stdout is parsed.
- **Missing events:** there is no "waiting for approval" event and no turn end other than task completion.
- **Newer SDK plugin system** (`@cline/sdk`, `AgentPlugin` with hooks `beforeRun/afterRun/beforeTool/afterTool/beforeModel/afterModel/onEvent`) is for the SDK and CLI. Whether the VS Code extension still reads file hooks after the SDK migration is **unconfirmed**. [L]
- **TCC hazard:** `~/Documents` is TCC-protected, so writing there may trigger a "Lidless would like to access files in your Documents folder" prompt.

### 3.6 Roo Code and Kilo Code

- **Roo Code:** GitHub `RooCodeInc/Roo-Code` is **archived** (`archived=true`, last release v3.54.0 on 2026-05-15). It never shipped lifecycle hooks; "Task Sync" (v3.28) streams tasks to Roo Cloud. Treat it as hook-less and use the extension-host fallback. [H for archive status via `gh api`]
- **Kilo Code** (actively developed; the new extension is backed by the Kilo CLI, an **OpenCode fork**) [H, source: Kilo-Org/kilocode]:
  - Plugins receive `event` callbacks: `session.status` (`busy`/`retry`/idle), `session.idle`, `session.error`, `session.deleted`, `permission.asked`, … (docs `packages/kilo-docs/pages/automate/extending/plugins.md`). The plugin directory path for Kilo is unverified: OpenCode uses `~/.config/opencode/plugins/`, and Kilo probably uses a `kilo` equivalent. [L for path]
  - VS Code notification settings: `kilo-code.new.attention.enabled`, `.sound`, `.OSNotifications`, `.notifications` (all default false). They alert on turn complete, needs input, needs permission and error. [H] Source: https://kilo.ai/docs/getting-started/settings/notifications
  - **Keep Awake** (opt-in `/caffeinate`): spawns `/usr/bin/caffeinate -i -w <extension pid>` while any session is busy. [H, `packages/core/src/kilocode/caffeination.ts`, `kilo-vscode/tests/unit/caffeination-inhibitor.test.ts`]

### 3.7 Continue

A commit in `continuedev/continue` `extensions/cli` adds a **Claude Code–compatible hooks system** (16 events, shell and HTTP handlers, regex matchers) for the `cn` CLI [L, mirror commit]. Nothing is documented for the VS Code/JetBrains extension. Treat the IDE as hook-less. [L]

### 3.8 Windsurf → Devin Desktop (Cascade)

Source: https://docs.devin.ai/desktop/cascade/hooks.md [H]
- **Rebrand:** Windsurf is now **Devin Desktop**. Legacy paths are honoured, and transcripts still go to `~/.windsurf/transcripts/`.
- **Locations:**
  - System `/Library/Application Support/Devin/hooks.json` (legacy `/Library/Application Support/Windsurf/hooks.json`)
  - **User `~/.codeium/windsurf/hooks.json`** (JetBrains plugin: `~/.codeium/hooks.json`)
  - Workspace `.devin/hooks.json` (legacy `.windsurf/hooks.json`)
  - Cloud dashboard
  - Merge order: cloud → system → user → workspace. Not loaded in Restricted Mode.
- **Format:** `{"hooks":{"post_cascade_response":[{"command":"…","show_output":false,"working_directory":"…"}]}}`. `command` runs via `bash -c`; `~` is **not** supported in `working_directory`.
- **12 events:** `pre_read_code`, `post_read_code`, `pre_write_code`, `post_write_code`, `pre_run_command`, `post_run_command`, `pre_mcp_tool_use`, `post_mcp_tool_use`, `pre_user_prompt`, **`post_cascade_response`** (async, after Cascade completes a response), `post_cascade_response_with_transcript` (`tool_info.transcript_path` = `~/.windsurf/transcripts/{trajectory_id}.jsonl`, 0600, max 100 files), `post_setup_worktree`.
- **Common stdin:** `agent_action_name`, `trajectory_id` (conversation), `execution_id` (turn), `timestamp`, `model_name`, `tool_info`. For `post_cascade_response`, `tool_info.response` is the full markdown, which is sensitive.
- **Blocking:** only the 5 pre-hooks can block, via exit 2. Other exit codes proceed. No timeout is documented.
- **No needs-input event.**
- **Process:** the Codeium/Windsurf architecture runs a `language_server_macos_arm` child. Its name is reported for Antigravity, a Codeium-derived product. [L]

### 3.9 Zed (agent panel and ACP external agents)

[H, source: zed-industries/zed `assets/settings/default.json`, `crates/gpui_macos/src/platform.rs`, https://zed.dev/docs/ai/agent-panel, https://zed.dev/docs/ai/external-agents]
- **No hook system.**
- **Settings:**
  - `agent.notify_when_agent_waiting`: default `"primary_screen"`; OS notification when the agent finishes or waits and Zed is in the background.
  - `agent.play_sound_when_agent_done`
  - **`agent.prevent_idle_sleep`**: default **true**. Implemented with `NSProcessInfo beginActivity(.userInitiated, reason)` (`AppleActivity::begin`), so a `PreventUserIdleSystemSleep` assertion **owned by the `zed` process exists exactly while a thread is generating**. This is a good signal. The reason string was not located. [M]
- **External agents** use the ACP registry (`zed: acp registry`) or custom `"agent_servers": {"x": {"type":"custom","command":"node","args":[…],"env":{}}}`. Listed: Claude, Codex, OpenCode, Copilot, Cursor, Pi, Gemini CLI, Poolside. Each runs as a child process of Zed with its own runtime and config. Whether their native hooks fire depends on the adapter:
  - Claude: Claude Agent SDK; may honour `~/.claude/settings.json` if the adapter loads user settings. [L]
  - Codex: codex-core, so `~/.codex/hooks.json` probably applies. [M]
  - Gemini: native, so `~/.gemini/settings.json` hooks apply. [M]

### 3.10 JetBrains AI Assistant, Junie, Air

- **AI Assistant (2026.x):** hosts ACP agents (Codex, Claude Agent, Junie, plus the registry; custom agents in `~/.jetbrains/acp.json`). No documented completion hook or notification setting. [M] Source: https://blog.jetbrains.com/ko/idea/2026/08/how-to-use-ai-agents-in-intellij-idea-with-acp/
- **Junie CLI hooks (EAP, page dated 2026-10-08):** `~/.junie/config.json`, events `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `Stop`, `StopFailure`, `PermissionRequest`, `SessionEnd`. Claude-like format. Project hooks ignored unless passed via `--config-location`. **"ACP and server hosts don't invoke hooks yet"**, so Junie inside the IDE does **not** fire hooks. [H] Source: https://junie.jetbrains.com/docs/junie-cli-hooks.html
- **JetBrains Air:** a macOS option prevents sleep while an agent works (July 2026 release). [L]
- **Claude Code JetBrains plugin:** see §3.1 (CLI in the IDE terminal, so everything works).

### 3.11 Xcode 26 coding intelligence (26.3 → 26.6)

- **History:** Xcode 26.3 (Feb 2026) added agentic coding with **Claude Agent** and **Codex**, plus MCP (`xcrun mcpbridge`). [H] Source: https://www.infoq.com/news/2026/02/xcode-26-3-agentic-coding
- **Local strings (L12):**
  - Claude Code is launched in **stream-json SDK mode**, with `CLAUDE_CONFIG_DIR` set to `…/CodingAssistant/ClaudeAgentConfig`. Hooks and the session registry therefore live **under that dir, not `~/.claude`**.
  - Xcode itself sends an SDK `initialize` with its own hooks.
  - An env var `APPLE_CLAUDE_CODE_DANGEROUSLY_BYPASS_HOOKS` exists (semantics unknown; it may disable user hooks).
  - Codex runs as `app-server` with `CODEX_HOME` overridden.
  - [M]
- **Paths** (third-party guides, Feb 2026): `~/Library/Developer/Xcode/CodingAssistant/Agents/Versions/<xcode-ver>/{claude,codex}` (bundled binaries), `…/ClaudeAgentConfig/` (Claude config, skills), `…/codex/config.toml`. [M] Source: https://mehmetbaykar.com/posts/agentic-coding-in-xcode-26-3/
- **ACP:** Xcode 26.6 ships `IDEIntelligenceACP.framework` and `IDEIntelligenceGemini.framework`, so ACP-based third-party agents are probably supported now. User-facing configuration was not verified. [M]
- **Detection:** sockets and CPU of `claude`/`codex` children of `Xcode` (path under `CodingAssistant/Agents/`). Optionally install Claude hooks into `ClaudeAgentConfig/settings.json`, subject to the bypass env caveat.

### 3.12 Claude desktop app (Claude.app): Code tab and Cowork

- **Code tab:** runs the Claude Code CLI (bundled under `~/Library/Application Support/Claude/claude-code/<ver>/`). Hooks from `~/.claude/settings.json` fire ("the Desktop app" is listed in the hooks docs). Expect a session-registry entry with `entrypoint:"claude-desktop"`. [H for hooks; M for registry]
- **Cowork (local agent mode):** runs in a **VM** (`claude-code-vm/`). Per-session JSON at `~/Library/Application Support/Claude/local-agent-mode-sessions/<account>/<org>/local_<uuid>.json` has `lastActivityAt` (epoch ms), `isAgentCompleted`, `isArchived`, `cliSessionId`, `cwd`. Usable as a **polling signal** (mtime + `lastActivityAt`). It is undocumented and may change. [M, L13]
- **Sleep:** the `keepAwakeEnabled` setting uses `caffeinate -d` (prevents display sleep too). There is also a known bug: an `"Electron"` NoIdleSleepAssertion was held for the app's whole lifetime (issue closed not planned, 2026-05-28). **The `"Electron"` assertion is therefore not evidence of agent activity.** [M] Sources: https://claudeissues.com/issue/36872-claude-desktop-keep-awake-should-not-prevent-display-sleep and https://claudeissues.com/issue/45769-macos-claude-desktop-holds-noidlesleepassertion-indefinitely-preventing-system-s

### 3.13 ChatGPT desktop app

- Chat, Work and Codex are merged (2026-07-09). Codex mode is covered in §3.4.
- "Work" and agent mode run mostly in the cloud. Nothing local needs keeping awake, except "local chats" when *Prevent sleep while running* is on. [M]

### 3.14 Gemini CLI and opencode, as embedded in IDEs

- **Gemini CLI** hooks in `~/.gemini/settings.json` [H] Source: https://geminicli.com/docs/hooks/reference.md
  - Events: `BeforeTool`, `AfterTool`, `BeforeAgent`, `AfterAgent` (`prompt`, `prompt_response`, `stop_hook_active`), `BeforeModel`, `BeforeToolSelection`, `AfterModel`, `SessionStart`, `SessionEnd`, `Notification` (`notification_type:"ToolPermission"`, `message`, `details`), `PreCompress`.
  - Common fields: `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `timestamp`.
  - `timeout` is in **ms** (default 60000). Exit 2 blocks. stdout must be JSON only.
  - Older docs required `tools.enableHooks` + `hooks.enabled`. [M]
- **opencode:** plugins in `~/.config/opencode/plugins/*.js|ts` exporting `async (ctx) => ({ event: async ({event}) => … })`. Events include `session.idle`, `session.status`, `session.error`, `permission.asked`, `permission.replied`. [H] Source: https://opencode.ai/docs/plugins/

---

## 4. Lidless hook integration design (Tier A)

### 4.1 One shim, many agents

- **Binary:** ship `Lidless.app/Contents/Helpers/lidless-hook` (small Swift CLI) and copy it to a **space-free absolute path** such as `~/.lidless/bin/lidless-hook`. Windsurf runs commands via `bash -c` and does not expand `~` in `working_directory`, and several agents are fragile with spaces. Write the expanded absolute path, e.g. `/Users/<u>/.lidless/bin/lidless-hook`.
- **Invocation:** `lidless-hook <source> [<event-override>]`. Event names come from the payload (`hook_event_name`, `agent_action_name`, `hookName`, `type`) or from argv for Cline file hooks and Codex `notify`.
- **Input:** read stdin with a 1 MiB cap and a 200 ms timeout. Codex `notify` passes JSON as the last argv argument instead.
- **Privacy:** by default, **drop content fields**: `prompt`, `text`, `response`, `tool_info.response`, `last_assistant_message`, `prompt_response`, `tool_input`, `input-messages`, `last-assistant-message`. An opt-in setting can keep the first 200 characters of the final message for the phone notification.
- **Enrichment:**
  - `ancestry`: walk `getppid()` → `proc_pidinfo(PROC_PIDTBSDINFO).pbi_ppid` up to 6 levels, recording `(pid, proc_pidpath, start time)`. The first non-shell ancestor is the **agent pid** (e.g. `claude`, `codex`, `Cursor Helper (Plugin)`, `Code Helper (Plugin)`). Lidless watches it with kqueue `EVFILT_PROC/NOTE_EXIT`, so a crash without `Stop` still ends the session.
  - Selected env: `CURSOR_VERSION`, `CURSOR_PROJECT_DIR`, `CLAUDE_PROJECT_DIR`, `TERM_PROGRAM`, `__CFBundleIdentifier`, `CODEX_HOME`, `CLAUDE_CONFIG_DIR`.
- **Delivery:** send one datagram to the Unix socket `~/.lidless/run/hook.sock` (dir 0700). Use `SOCK_DGRAM`, `O_NONBLOCK`, and a 50 ms budget. If Lidless is not running, drop the event silently.
- **Exit and stdout (always exit 0, never block):**

  | Source | stdout |
  |---|---|
  | Cursor `beforeSubmitPrompt` | `{"continue":true}` |
  | Cursor other events | `{}` |
  | Cline | `{"cancel":false}` |
  | Gemini | `{}` |
  | Claude, Codex, VS Code, Copilot, Windsurf, Junie | empty |
- **Dedup:** key on `(source, session_id|conversation_id|trajectory_id|taskId|thread-id, event, ts±2s)`. If a Claude-format event arrives with `CURSOR_VERSION` set, re-label it `cursor` (third-party hooks). The same applies to VS Code `chat.useClaudeHooks` and to Copilot CLI reading repo `.claude/settings.json`.

### 4.2 Normalized event model

```swift
enum AgentEventKind { case sessionStart, turnStart, heartbeat, needsInput, turnEnd(Outcome), sessionEnd }
enum Outcome { case completed, aborted, error }
struct AgentEvent { let source: String; let host: String?; let sessionKey: String
                    let kind: AgentEventKind; let agentPID: pid_t?; let cwd: String?; let at: Date }
```

| Source | turnStart | turnEnd | needsInput | sessionEnd / other |
|---|---|---|---|---|
| claude | `UserPromptSubmit` | `Stop` (completed), `StopFailure` (error) | `Notification` ∈ {permission_prompt, elicitation_dialog, elicitation_url_dialog, agent_needs_input}; `PermissionRequest` | `SessionEnd`; `Notification idle_prompt` = "still waiting" reminder |
| cursor | `beforeSubmitPrompt` | `stop` (`status`) | — | `sessionEnd`; `postToolUse` = heartbeat |
| codex | `UserPromptSubmit` | `Stop`; `Interrupt` (aborted); legacy notify `agent-turn-complete` | `PermissionRequest` | `SessionEnd` |
| vscode-local | `UserPromptSubmit` | `Stop` | — | `PostToolUse` = heartbeat |
| copilot (CLI/Agent Host) | `userPromptSubmitted` | `agentStop`; `errorOccurred` | `permissionRequest`, `notification` | `sessionEnd` |
| windsurf | `pre_user_prompt` | `post_cascade_response` | — | `post_*` = heartbeat |
| cline | `TaskStart`, `TaskResume`, `UserPromptSubmit` | `TaskComplete` (completed), `TaskCancel` (aborted) | — | `PostToolUse` = heartbeat |
| gemini | `BeforeAgent` | `AfterAgent` | `Notification` (ToolPermission) | `SessionEnd` |
| opencode/kilo plugin | `session.status` busy | `session.idle`; `session.error` | `permission.asked` | `session.deleted` |
| junie-cli | `UserPromptSubmit` | `Stop`, `StopFailure` | `PermissionRequest` | `SessionEnd` |

### 4.3 Exact snippets to merge (install = JSON/TOML merge + timestamped backup + uninstall marker)

**Claude Code: `~/.claude/settings.json`** (merge into `hooks`; keep the user's own entries)
```json
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "/Users/U/.lidless/bin/lidless-hook claude", "async": true }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "/Users/U/.lidless/bin/lidless-hook claude", "async": true }] }],
    "PermissionRequest":[{ "hooks": [{ "type": "command", "command": "/Users/U/.lidless/bin/lidless-hook claude", "async": true }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "/Users/U/.lidless/bin/lidless-hook claude", "async": true }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "/Users/U/.lidless/bin/lidless-hook claude", "async": true }] }],
    "StopFailure":      [{ "hooks": [{ "type": "command", "command": "/Users/U/.lidless/bin/lidless-hook claude", "async": true }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "/Users/U/.lidless/bin/lidless-hook claude", "async": true }] }]
  }
}
```
Notes:
- An `http` handler (`"type":"http","url":"http://127.0.0.1:<port>/hook/claude"`) also works and needs no shim. However, it carries **no PID**, exposes a localhost port that browsers can reach (CSRF/DNS-rebinding), and needs a token via `headers` + `allowedEnvVars`. **Prefer the command shim.**
- Verify that `"async": true` is accepted on every event Lidless registers. [M]
- Xcode's Claude agent needs the same block in `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/settings.json` (path inferred). [M]

**Cursor: `~/.cursor/hooks.json`**
```json
{
  "version": 1,
  "hooks": {
    "sessionStart":       [{ "command": "/Users/U/.lidless/bin/lidless-hook cursor", "timeout": 5 }],
    "beforeSubmitPrompt": [{ "command": "/Users/U/.lidless/bin/lidless-hook cursor", "timeout": 5 }],
    "postToolUse":        [{ "command": "/Users/U/.lidless/bin/lidless-hook cursor", "timeout": 5 }],
    "stop":               [{ "command": "/Users/U/.lidless/bin/lidless-hook cursor", "timeout": 5 }],
    "sessionEnd":         [{ "command": "/Users/U/.lidless/bin/lidless-hook cursor", "timeout": 5 }]
  }
}
```
Do **not** add `preToolUse`, `beforeShellExecution`, `beforeMCPExecution`, `beforeReadFile` or `subagentStart`: these are permission hooks that block on bad JSON.

**Codex: `~/.codex/hooks.json`** (the user must then trust it via `/hooks` in the CLI or the app's review flow)
```json
{
  "hooks": {
    "SessionStart":      [{ "hooks": [{ "type": "command", "command": "/Users/U/.lidless/bin/lidless-hook codex", "timeout": 5 }] }],
    "UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "/Users/U/.lidless/bin/lidless-hook codex", "timeout": 5 }] }],
    "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "/Users/U/.lidless/bin/lidless-hook codex", "timeout": 5 }] }],
    "Stop":              [{ "hooks": [{ "type": "command", "command": "/Users/U/.lidless/bin/lidless-hook codex", "timeout": 5 }] }],
    "Interrupt":         [{ "hooks": [{ "type": "command", "command": "/Users/U/.lidless/bin/lidless-hook codex", "timeout": 1 }] }],
    "SessionEnd":        [{ "hooks": [{ "type": "command", "command": "/Users/U/.lidless/bin/lidless-hook codex", "timeout": 1 }] }]
  }
}
```
Completion-only alternative with no trust step, in `~/.codex/config.toml`:
```toml
notify = ["/Users/U/.lidless/bin/lidless-hook", "codex-notify"]
```

**VS Code Local + Copilot CLI/SDK: `~/.copilot/hooks/lidless.json`** (read by both consumers; must be validated in both)
```json
{
  "version": 1,
  "hooks": {
    "SessionStart":     [{ "type": "command", "command": "/Users/U/.lidless/bin/lidless-hook vscode", "bash": "/Users/U/.lidless/bin/lidless-hook copilot", "timeout": 5, "timeoutSec": 5 }],
    "UserPromptSubmit": [{ "type": "command", "command": "/Users/U/.lidless/bin/lidless-hook vscode", "bash": "/Users/U/.lidless/bin/lidless-hook copilot", "timeout": 5, "timeoutSec": 5 }],
    "Stop":             [{ "type": "command", "command": "/Users/U/.lidless/bin/lidless-hook vscode", "bash": "/Users/U/.lidless/bin/lidless-hook copilot", "timeout": 5, "timeoutSec": 5 }]
  }
}
```
If either consumer rejects the mixed form, use separate files. The safest split is VS Code's `chat.hookFilesLocations` pointing at `~/.lidless/hooks/vscode/` (requires editing VS Code `settings.json`) and `~/.copilot/hooks/lidless.json` in pure Copilot format (`userPromptSubmitted`, `agentStop`, `notification`, `permissionRequest`, `sessionEnd`).

**Windsurf / Devin Desktop: `~/.codeium/windsurf/hooks.json`**
```json
{ "hooks": {
  "pre_user_prompt":       [{ "command": "/Users/U/.lidless/bin/lidless-hook windsurf", "show_output": false }],
  "post_run_command":      [{ "command": "/Users/U/.lidless/bin/lidless-hook windsurf", "show_output": false }],
  "post_cascade_response": [{ "command": "/Users/U/.lidless/bin/lidless-hook windsurf" }]
} }
```

**Cline: executable files in `~/Documents/Cline/Hooks/`** (`TaskStart`, `TaskResume`, `TaskCancel`, `TaskComplete`, `UserPromptSubmit`), each containing:
```sh
#!/bin/sh
exec /Users/U/.lidless/bin/lidless-hook cline "$(basename "$0")"
```
The user must also enable hooks in Cline's settings and the Hooks tab.

**Gemini CLI: `~/.gemini/settings.json`**
```json
{ "hooks": {
  "BeforeAgent":  [{ "matcher": "*", "hooks": [{ "type": "command", "command": "/Users/U/.lidless/bin/lidless-hook gemini", "timeout": 5000 }] }],
  "AfterAgent":   [{ "matcher": "*", "hooks": [{ "type": "command", "command": "/Users/U/.lidless/bin/lidless-hook gemini", "timeout": 5000 }] }],
  "Notification": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "/Users/U/.lidless/bin/lidless-hook gemini", "timeout": 5000 }] }]
} }
```

**opencode: `~/.config/opencode/plugins/lidless.js`**
```js
export const Lidless = async ({ $ }) => ({
  event: async ({ event }) => {
    if (["session.status","session.idle","session.error","permission.asked","session.deleted"].includes(event.type)) {
      await $`/Users/U/.lidless/bin/lidless-hook opencode ${event.type}`.nothrow().quiet();
    }
  },
});
```

---

## 5. Generic fallback detector for IDE-embedded agents (Tiers B to D)

### 5.1 Signal evaluation

| Signal | API (Swift-callable, no privileges) | Cost (measured) | Reliability as "agent working" | Notes |
|---|---|---|---|---|
| **B1 Agent state files** | `DispatchSource.makeFileSystemObjectSource` / FSEvents on `~/.claude/sessions`, `~/Library/Application Support/Claude/local-agent-mode-sessions/**`, `~/.codex/sessions/**` (rollout jsonl mtime), `~/.windsurf/transcripts/`, Cursor `transcript_path` | ~0 | Claude `status` is **high for busy→idle edges** but goes stale (only updated on transitions; L9). Must be paired with pid liveness and `procStart` check. Others: mtime = activity proxy, medium. | Codex rollout path not re-verified here (no `~/.codex` locally) [L] |
| **B2 Power assertions attributed to agents** | `IOPMCopyAssertionsByProcess(&dict)` → `[pid: [[AssertType, AssertName, …]]]`; attribute by owner pid or by **parent pid** for `caffeinate` | 0.93 ms | High for Claude Code interactive (caffeinate child, 30 s tail), Zed (default on), Codex TUI/app (opt-in). Medium for Cursor/Copilot (Electron `"Electron"` name is generic; Copilot's is experiment-gated with a 2-min tail). **Never trust a long-lived `"Electron"` assertion alone** (Claude Desktop bug). | Poll every 10–15 s. |
| **C1 Established TCP to model APIs** | `proc_pidinfo(PROC_PIDLISTFDS)` → `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` → `soi_kind == SOCKINFO_TCP`, `tcpsi_state == TSI_S_ESTABLISHED` (4), `tcpsi_ini.insi_faddr` | 0.4 ms / 7 pids | High for processes that talk to the API themselves (`claude`, `codex`, `gemini`, `cursor-agent`, `copilot`). Medium for Electron IDEs, where traffic may go through the Chromium **Network Service** helper (`--utility-sub-type=network.mojom.NetworkService`) rather than the extension host. | Anthropic: exact CIDRs `160.79.104.0/23`, `2607:6bc0::/48`. Others: maintain a set of IPs from periodic `getaddrinfo` of known hosts (api.openai.com, chatgpt.com, `*.githubcopilot.com`, `api2/api5.cursor.sh`, `generativelanguage.googleapis.com`, `server.self-serve.windsurf.com`, `inference.codeium.com`). Cloudflare anycast IPs are shared, so require that the process be a known agent or IDE. Keep-alive lingering after idle not measured [L]. |
| **C2 Byte counters** | one-shot `nettop -P -L 1 -x -J bytes_in,bytes_out` every 60 s, diff per pid | 0.05 s CPU, 5 s wall per sample; **continuous mode ≈130 % CPU** | Medium. Counts cover live sockets only, so values drop when sockets close. Process key is the 15-char truncated name plus pid. | Private `NetworkStatistics.framework` (`NStatManager*`) gives push updates but is undocumented. Avoid in v1. |
| **C3 Child process churn** | `proc_listchildpids(pid)` polled, or `kqueue EVFILT_PROC NOTE_FORK/NOTE_EXEC/NOTE_EXIT` on IDE helper pids (same uid, no entitlement). `KERN_PROCARGS2` for argv/env. | full scan 7.4 ms / 577 pids | Medium-high while an agent runs tools (git, rg, node, test runners). Zero during pure "thinking" phases. | EndpointSecurity would be ideal but needs the `com.apple.developer.endpoint-security.client` entitlement (paid Developer ID + Apple approval). **Not viable.** |
| **D1 CPU deltas** | `proc_pid_rusage(pid, RUSAGE_INFO_V6)` `ri_user_time + ri_system_time` (mach units × timebase) | ~µs per pid | **Low alone.** Busy Claude 2–16 % vs idle 0.4–2.3 %; Electron helpers spike from indexing. | `ri_billed_energy` read 0 (unusable). |
| **D2 Workspace writes** | FSEvents on workspace roots (from hooks `cwd`/`workspace_roots`, or the IDE's recent-workspaces state) | low | Low-medium: dev servers and builds also write. | `~/Documents`, `~/Desktop`, `~/Downloads` need TCC Files & Folders consent. |
| **D3 Dock badge / AX** | `AXUIElement` of Dock → `AXStatusLabel` | low | Low. Only for apps that badge "needs attention" (VS Code `sessions.showApplicationBadge`). | Needs the Accessibility permission. Optional. |
| ✗ Notification Center scraping | — | — | — | Private, TCC-protected DB. Do not use. |

### 5.2 Identifying candidate processes (no bundle ids for helpers)

- **Agent binaries:** match on `proc_pidpath` and argv[0] together, because of L1 (version-named executable and deleted binaries).
  - Claude Code: `…/.local/share/claude/versions/*`, `…/Claude/claude-code/*/claude`, `…/anthropic.claude-code-*/resources/native-binary/claude`, `…/CodingAssistant/Agents/Versions/*/claude`; argv[0] `claude`.
  - Codex: argv contains `app-server` → Codex app-server.
  - Interpreted agents (`node …/gemini`, `node …/copilot`, `python … aider`, `opencode`, `kilo`, `cursor-agent`): match on argv.
- **IDE helpers** (Electron):
  - `<App> Helper (Plugin)` = extension host. This is VS Code `Code Helper (Plugin)` [H, L10], plus `Cursor Helper (Plugin)` and Windsurf/Devin equivalents.
  - VS Code **Agent Host** = plain `Code Helper` whose argv contains `--logsPath` and env `VSCODE_ESM_ENTRYPOINT=vs/platform/agentHost/node/agentHostMain` (L10). [M]
  - Network Service = `… Helper` with `--utility-sub-type=network.mojom.NetworkService`. [M]
  - All VS Code helpers share bundle id `com.microsoft.VSCode.helper`, so **group by the main app pid (ancestor) and the executable path, not by bundle id**.
- **Native IDE hosts:**
  - `zed` (assertion owner)
  - `Xcode` → children under `CodingAssistant/Agents/`
  - JetBrains `idea`/`pycharm` → ACP agent children (`claude`, `codex`, `junie`, `node …`)
  - Claude.app VM (Virtualization.framework XPC) for Cowork
- **Host attribution for terminals:** read `__CFBundleIdentifier` and `TERM_PROGRAM` from the agent's `KERN_PROCARGS2` env (L8). Examples: `com.microsoft.VSCode` / `vscode`, `com.todesktop.230313mzl4w4u92` (Cursor) [L], `com.apple.Terminal`.

### 5.3 Reference snippets (verified to compile on Swift 6.3 / macOS 26.6)

```swift
// Power assertions by process (B2) — from research-snippets/assertions.swift
var ref: Unmanaged<CFDictionary>?
if IOPMCopyAssertionsByProcess(&ref) == kIOReturnSuccess,
   let byPid = ref?.takeRetainedValue() as? [NSNumber: [[String: Any]]] {
    for (pid, list) in byPid { for a in list {
        let type = a[kIOPMAssertionTypeKey as String] as? String   // "PreventUserIdleSystemSleep", "NoIdleSleepAssertion", …
        let name = a[kIOPMAssertionNameKey as String] as? String   // "caffeinate command-line tool", "Codex is running an active turn", "Electron", …
        // attribute: owner pid, or parent pid when owner is /usr/bin/caffeinate
    } }
}
```
```swift
// Established TCP remotes of a pid (C1) — from research-snippets/sockets.swift
let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
var fds = [proc_fdinfo](repeating: .init(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
    var si = socket_fdinfo()
    guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, Int32(MemoryLayout<socket_fdinfo>.size)) == Int32(MemoryLayout<socket_fdinfo>.size),
          si.psi.soi_kind == SOCKINFO_TCP, si.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_ESTABLISHED else { continue }
    let ini = si.psi.soi_proto.pri_tcp.tcpsi_ini   // insi_vflag (INI_IPV4/INI_IPV6), insi_faddr, insi_fport (network order)
}
```
Other APIs in use: `proc_pid_rusage(pid, RUSAGE_INFO_V6, …)` for CPU; `proc_listchildpids` / `proc_listallpids` for trees; `sysctl([CTL_KERN, KERN_PROCARGS2, pid])` for argv/env; `proc_pidinfo(PROC_PIDTBSDINFO)` for ppid and start time.

### 5.4 Tiered strategy and state machine

Per **agent session** (from hooks) and per **candidate process group** (from scanning), keep `state ∈ {working, needsInput, idle, ended}` with `lastEvidenceAt`.

1. **Tier A (hooks, authoritative).**
   - `turnStart` → working. `turnEnd` → idle and **phone push "finished"** (with outcome). `needsInput` → needsInput and **push "needs you"**. `sessionEnd` or agent pid exit → ended.
   - **Watchdog:** if a session has been `working` for over 10 min with no hook heartbeat **and** Tier B/C for its agent pid are quiet for 5 min, mark it `idle?` and push "went quiet". This covers crashes and missed `Stop` events.
2. **Tier B (state files and attributed assertions).**
   - Claude registry `busy` counts **only if** the pid is alive, `procStart` matches, and (caffeinate child **or** C1 sockets exist).
   - An agent-attributed assertion means working, with the agent's own tail (Claude 30 s, Copilot 2 min).
3. **Tier C (behavioral, for hook-less hosts).**
   - Candidate group is **working** if, within a sliding 60 s window, *at least two* hold: C1 ESTABLISHED socket to a model endpoint with bytes increasing (C2 sample) or new connections; C3 a child spawn/exec under the group; D1 CPU > 10 % of one core averaged over 30 s; D2 workspace write.
   - Enter after 20 s sustained. Exit after **5 min** quiet (agents can "think" for minutes, but streaming keeps sockets busy).
4. **Lid-closed policy input.** "Agents working" = any session or group in `working`. If something is in `needsInput`, keep awake for a configurable window (default 30 min) for remote approval, then allow sleep. "No agent working" = everything `idle/ended` for a grace period (default 5 min) **and** no Tier-B assertions from agents.
5. **Process protection** (for the "pause other apps" feature). Never SIGSTOP any process belonging to an app bundle or process group that hosts a `working` or `needsInput` agent. That includes the IDE main process (Electron main brokers extension-host IPC), all `… Helper` processes (Network Service, GPU, Renderer: some agents may run loops in the renderer [L]), and all descendants of the agent pid (tool commands, dev servers).

---

## 6. Recommendations for Lidless

1. **Build the hook shim plus a per-agent installer first.** It is the highest-value, lowest-risk component: authoritative finish and needs-input events, and the data for phone notifications.
   - **Default-on targets:** Claude Code, Cursor, Codex (with a trust walkthrough, or the `notify` fallback), Windsurf/Devin, VS Code Local, Copilot CLI, Gemini CLI, opencode.
   - **Opt-in targets:** Cline (TCC + UI enable steps), Xcode's Claude/Codex config dirs, Junie CLI.
   - **Installer rules:** JSON/TOML **merge** (never overwrite), backups in `~/.lidless/backups/`, an idempotent marker on every entry (`lidless-hook` substring), a one-click uninstall, and a re-check on launch in case agents rewrote their files.
2. **Use a Unix-domain datagram socket, not an HTTP port.** It gives peer filesystem permissions and no exposure to browsers. Add a localhost HTTP endpoint only if a user explicitly wants Claude `type:"http"` hooks, and then require a bearer token.
3. **Attribute every hook to a live pid** via the shim's ancestry walk, and monitor that pid with `kqueue NOTE_EXIT`. This is what makes the system safe when hooks are missed.
4. **Implement Tier B early.** `IOPMCopyAssertionsByProcess` every 15 s and the Claude session registry are cheap and cover the user's main workflow (Claude Code in Terminal) even before hooks are installed.
5. **Implement Tier C with libproc, not nettop.** Rescan candidate pids every 5 s while the lid is closed and every 15 s while it is open (about 10 ms per scan). Use nettop only as an optional one-shot each minute. **Never run nettop continuously** (about 130 % CPU measured).
6. **Maintain a model-endpoint table** with a resolver task. Start from Anthropic's fixed CIDRs plus DNS results for OpenAI, ChatGPT, Copilot, Cursor, Google and Windsurf hosts. Only count sockets owned by recognized agent or IDE process groups.
7. **For phone "needs input",** rely on hook events where they exist (Claude `Notification`/`PermissionRequest`, Codex `PermissionRequest`, Copilot `permissionRequest`/`notification`, Gemini `Notification`, opencode `permission.asked`). For the rest (Cursor, VS Code Local, Windsurf, Cline, Zed, JetBrains, Xcode), send a softer "agent went quiet (finished or waiting)" push when Tier C goes from working to quiet.
8. **Write a first-run self-test.** For each detected agent, show which signals are live (hooks installed and seen, registry entries with the correct `entrypoint`, assertion seen while busy). Let the user run a 1-line test prompt to confirm `turnStart`/`turnEnd` arrive.
9. **Do not depend on** EndpointSecurity (entitlement), NetworkStatistics private API, Notification Center scraping, or proprietary IDE internals (Cursor/Windsurf state DBs) for v1.
10. **Flag for the product spec:** none of the agents' own "keep awake" features survive a lid close on battery (Cursor and Codex docs/staff say so explicitly). Lidless's clamshell handling (other reports) remains necessary, and Lidless must not treat their assertions as proof that the Mac will stay awake.

---

## 7. Risks / unknowns

- **Schema churn.** Every hook system above is labeled Preview, EAP or new in 2026. Field names have already changed (VS Code `chat.hookFilesLocations`; Copilot `~/.copilot/config.json` → `hooks/`; Windsurf → Devin paths; Codex `codex_hooks` → `hooks`). The installer must be version-aware and re-validated on each agent update. [H]
- **Shared `~/.copilot/hooks/` directory** read by two consumers with different schemas. A mixed `command`+`bash` entry is untested. [M]
- **Double firing via third-party loaders.** Cursor loads Claude Code hooks, VS Code optionally loads Claude hooks, and Copilot CLI reads repo `.claude/settings.json`. Without correct dedup and attribution, Lidless could show wrong agent names. [M]
- **Claude Code `Notification` hook does not fire in the VS Code extension** (issue #66482, closed not planned). It is unknown whether `PermissionRequest` fires there in SDK mode. [M]
- **VS Code Agent Host Claude sessions:** unknown whether the Claude Agent SDK integration loads user settings (hooks) or registers in `~/.claude/sessions`. Process shape (child `claude` of `Code Helper`) not observed live, because VS Code was not running. [L]
- **Xcode:** hooks for Xcode-run Claude would live under `CLAUDE_CONFIG_DIR` (inferred). `APPLE_CLAUDE_CODE_DANGEROUSLY_BYPASS_HOOKS` may disable them. `~/Library/Developer/Xcode/CodingAssistant/` did not exist locally. [M/L]
- **Codex hook trust** requires a user action per hook hash. Updating the shim command line invalidates trust. Keep the command string stable forever (no version in path). [H]
- **Cline:** file-hook support after the SDK-plugin migration is unconfirmed. `~/Documents` triggers a TCC prompt. Hooks must be enabled in the UI. [M/L]
- **Kilo plugin directory** unverified. Roo Code is archived (no future hooks). Continue IDE has no hooks. [M]
- **Claude session registry staleness.** `status` updates only on transitions, so a crashed or hung process can show `busy` indefinitely (observed: "busy" for 13 h earlier in this project). Always corroborate. [H]
- **caffeinate signal scope.** It is spawned only by the interactive REPL (and the remote-control bridge). Its absence does not prove idleness for SDK-hosted Claude. [M]
- **Electron `"Electron"` assertions are generic.** They can be held for the whole app lifetime (Claude Desktop bug) or be experiment-gated (Copilot). Cursor's wakelock name and owner are unverified. [M]
- **Keep-alive lingering:** how long agent processes keep ESTABLISHED sockets after a turn ends was not measured. Tune the C1 window empirically (recommendation: require bytes growth via C2 or new connections, not mere existence, for Electron apps). [L]
- **Electron network routing:** whether Copilot, Cursor and Windsurf traffic leaves from the extension host, the Network Service helper, or a language-server child is not verified per product. Monitor the whole app process group. [M]
- **Renderer throttling with the lid closed:** Chromium may throttle occluded renderers. If an IDE runs agent orchestration in the renderer, it could slow down regardless of Lidless's awake state. Unknown per product. [L]
- **nettop output format** (15-char truncated names, `name.pid`, live-socket totals) is undocumented and may change. Continuous nettop is too expensive. [H for measured cost]
- **No paid Developer ID assumed.** Everything above works ad-hoc signed and unsandboxed. EndpointSecurity and Network Extension-based per-flow accounting would need entitlements and are **excluded**. Accessibility (Dock badge) and Files & Folders (Documents) are TCC prompts, not entitlements. [H]
- **Not verified live on this machine:** Cursor, Windsurf/Devin, Zed, ChatGPT/Codex app, JetBrains AI and Xcode agent sessions are not installed or not in use here, so their process trees and assertion names come from docs and source, not observation.

---

## 8. Sources (accessed 2026-10-12)

Official docs and changelogs:
- Claude Code hooks reference: https://code.claude.com/docs/en/hooks
- Anthropic IP addresses: https://platform.claude.com/docs/en/api/ip-addresses
- Cursor hooks: https://cursor.com/docs/hooks · network: https://cursor.com/docs/enterprise/network-configuration
- VS Code hooks: https://code.visualstudio.com/docs/agent-customization/hooks · reference: https://code.visualstudio.com/docs/agents/reference/hooks-reference.md · AI settings: https://code.visualstudio.com/docs/agents/reference/ai-settings
- GitHub Copilot hooks reference: https://docs.github.com/en/copilot/reference/hooks-reference · allowlist: https://docs.github.com/en/enterprise-cloud@latest/copilot/reference/copilot-allowlist-reference
- Codex hooks: https://learn.chatgpt.com/docs/hooks.md · app-server: https://learn.chatgpt.com/docs/app-server.md · app settings: https://learn.chatgpt.com/docs/reference/settings.md · changelog: https://learn.chatgpt.com/docs/changelog
- Devin Desktop (Windsurf) Cascade hooks: https://docs.devin.ai/desktop/cascade/hooks.md
- Zed: https://zed.dev/docs/ai/agent-panel · https://zed.dev/docs/ai/external-agents
- Junie CLI hooks: https://junie.jetbrains.com/docs/junie-cli-hooks.html
- JetBrains ACP tutorial: https://blog.jetbrains.com/ko/idea/2026/08/how-to-use-ai-agents-in-intellij-idea-with-acp/
- Gemini CLI hooks: https://geminicli.com/docs/hooks/reference.md
- opencode plugins: https://opencode.ai/docs/plugins/
- Kilo notifications: https://kilo.ai/docs/getting-started/settings/notifications
- Cline hooks (mirror): https://mintlify.wiki/cline/cline/customization/hooks · Cline SDK plugins: https://docs.cline.bot/sdk/plugins

Source code (GitHub, default branch, 2026-10-12, read via `gh api`):
- openai/codex: `codex-rs/hooks/src/legacy_notify.rs`, `codex-rs/utils/sleep-inhibitor/src/macos.rs`, `codex-rs/features/src/lib.rs`
- microsoft/vscode: `extensions/copilot/src/extension/power/vscode-node/powerService.ts`, `extensions/copilot/src/extension/prompt/node/chatMLFetcher.ts`, `src/vs/platform/extensions/electron-main/extensionHostStarter.ts`, `src/vs/platform/utilityProcess/electron-main/utilityProcess.ts`
- zed-industries/zed: `assets/settings/default.json`, `crates/gpui_macos/src/platform.rs`, `crates/agent_settings/src/agent_settings.rs`
- Kilo-Org/kilocode: `packages/kilo-vscode/src/services/caffeination/*`, `packages/core/src/kilocode/caffeination.ts`
- Repo status: `gh api repos/RooCodeInc/Roo-Code` (archived), anthropics/claude-code issues #66482, #53774, #21736

Third-party and forum (lower confidence):
- Cursor staff on wakelock: https://forum.cursor.com/t/add-option-to-disable-computer-sleep-while-an-agent-is-running/159837
- Claude Desktop keep-awake / Electron assertion issues: https://claudeissues.com/issue/36872-claude-desktop-keep-awake-should-not-prevent-display-sleep · https://claudeissues.com/issue/45769-macos-claude-desktop-holds-noidlesleepassertion-indefinitely-preventing-system-s
- Xcode 26.3 agent paths: https://mehmetbaykar.com/posts/agentic-coding-in-xcode-26-3/ · https://swiftwithmajid.com/2026/02/10/agentic-coding-in-xcode/ · https://www.infoq.com/news/2026/02/xcode-26-3-agentic-coding

Local verification commands: `ps -axo pid,ppid,pcpu,rss,etime,comm`, `pmset -g assertions`, `nettop -P -L 1 -x -J bytes_in,bytes_out`, `nettop -L 1 -n -m tcp -x -J bytes_in,bytes_out,state`, `/usr/bin/time -p nettop …`, `dig +short`, `strings` on `~/.local/share/claude/versions/2.1.296` and Xcode frameworks, `sqlite3 -readonly …/agent-host.db`, `PlistBuddy` on the VS Code helpers, plus the Swift probes listed at the top.
