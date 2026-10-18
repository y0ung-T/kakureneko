# 04: Long-tail terminal AI agents: turn-complete, needs-input and session signals

*Research date: 2026-10-12. Machine: macOS 26.6.2 (25G83), arm64. Scope: the long tail of agent CLIs beyond Claude Code, Codex, Gemini, Copilot, Cursor and OpenCode (those are covered in the companion report). The method was read-only. It used official docs, GitHub source (via `gh api` and sparse clones in the scratchpad), npm and PyPI registry metadata, unpacked npm tarballs grepped for strings and never executed, and one local Swift snippet.*

**Confidence legend:** **H** = taken from official docs or source code fetched today, or verified locally. **M** = from a single official source that conflicts with another, or from a reputable third-party integrator (CodeIsland, peon-ping, codeburn) that reads the real files. **L** = inferred, secondhand, or not reproducible here.

**Local machine:** none of the long-tail agents in this report are installed (verified locally: `ls ~/.factory ~/.qwen ~/.kiro ~/.augment ~/.cline ~/.continue ~/.openhands ~/.kimi-code ~/.vibe ~/.grok ~/.config/{amp,goose,crush,kilo}`, all absent). Only Claude Code and `~/.copilot` exist. Every per-agent fact below therefore comes from docs or source. None comes from observing the live agent on this Mac.

---

## 0. TL;DR

1. **Most of the long tail now has deterministic lifecycle hooks, and many copy Claude Code's format.** Factory Droid, Qwen Code, Augment Auggie, OpenHands, Devin CLI, Qoder, CodeBuddy and iFlow use the Claude-style `{"hooks":{"Stop":[{"hooks":[{"type":"command","command":...}]}]}}` JSON with `hook_event_name` on stdin. Continue `cn` also loads this format but does not fire events. Grok Build uses the same shape with camelCase payload keys. Goose, Kimi Code, Kiro V3, Mistral Vibe, Cline, Crush, Rovo Dev and Hermes each have their own format. Amp, Kilo and Pi expose a TypeScript plugin API instead of shell hooks.
2. **Some agents have no usable turn hook.** Warp's built-in agent (closed, in-app), Plandex (dormant since Oct 2025), Continue `cn` (hook loader ships, but no Stop or Notification call sites in 1.5.47), Junie CLI (only `SessionStart` is documented) and Crush (only `PreToolUse`) need fallbacks: session-file watchers, process heuristics, or a PTY wrapper.
3. **Hooks in `~/.claude/settings.json` run in more than one tool.** Continue `cn`, Devin CLI, Grok Build and Cursor (third-party hooks) all load it, and Droid offers to import it. A Lidless hook installed there will be invoked by several agents, so the handler must identify the real caller from env markers and the parent-process chain, and must deduplicate.
4. **A careless hook can keep an agent running or block it.** `Stop` hooks are stop-gates in Droid, Qwen, Goose, Kimi, Augment, OpenHands, Devin and Kiro V3. Kiro V3 continues for another turn when a `Stop` hook exits with **code 1**. Goose and Grok parse `{"decision":"block"}` from stdout. Crush halts the turn on exit **49**. The Lidless hook must **always exit 0, print nothing to stdout, finish in under 100 ms, and never wait on the app.**
5. **Process identification works without privileges, but `p_comm` is unreliable.** Verified locally with `research-snippets/agentscan.swift`: `KERN_PROCARGS2` returns the exe path, argv and **environment** of same-user processes. The kernel `pbi_comm` for Claude Code is the version string `2.1.296`, and Node CLIs show up as `node`. Match on the exe path, argv and `process.title`. Kimi Code sets `kimi-code` and Pi sets `pi`. Qwen and Auggie set none, so they appear as `node …/qwen` and `node …/auggie`.
6. **Prior art to reuse:** **CodeIsland** (MIT, Swift, macOS, 2.5k★) already installs hooks for 30+ agents into exactly these config files, bridges them over `/tmp/codeisland-<uid>.sock`, and pushes to the phone via Bark, ntfy or Telegram. **peon-ping** (MIT, 5k★) has adapters for Amp (thread-file watcher), Kiro, Qwen, Kimi, Kilo, iFlow, Rovo Dev, Grok and DeepAgents. **codeburn** documents every agent's on-disk session store.

---

## 1. Capability matrix

The status column gives the latest version seen on 2026-10-12. "Turn end" means the agent finished responding and is waiting for the user. "Needs input" means a permission or approval prompt, or an idle wait.

| Agent | Status (version) | Process as seen by Lidless | User config for hooks | Turn end | Needs input | Session start / end | Format | Can block? | On-disk state | Conf. |
|---|---|---|---|---|---|---|---|---|---|---|
| **Sourcegraph Amp** | active (npm `@ampcode/cli` 0.0.1791806555) | native `amp` (npm exe file is `amp.exe`) | plugin `~/.config/amp/plugins/*.ts` (Bun) | plugin `agent.end` {status} | none known | `session.start` / none | TS plugin API | `tool.call` can reject; `agent.end` can `continue` | `~/.local/share/amp/threads/T-*.json` | M |
| **Block Goose** | active (v1.54.0) | native `goose`; desktop `goosed` | `~/.agents/plugins/<name>/hooks/hooks.json` | `Stop` (per turn, `last_assistant_message`) | none | `SessionStart` / `SessionEnd` | Open-Plugins / Claude-like | `Stop` and `PreToolUse`: exit 2 or stdout `{"decision":"block"}` | `~/.local/share/goose/sessions/sessions.db` | H |
| **Factory Droid** | active (0.238.0) | native `droid` | `~/.factory/hooks.json`, else `~/.factory/settings.json` `"hooks"` | `Stop` | `Notification` (`permission_prompt`, `idle_prompt`, `elicitation_dialog`) | `SessionStart` / `SessionEnd` | Claude-compatible | yes (`Stop` exit 2 or `decision:block`) | `~/.factory/sessions/<slug>/*.jsonl` | H |
| **Qwen Code** | active (0.25.1) | `node …/qwen` (no process.title) | `~/.qwen/settings.json` `"hooks"` | `Stop` (+`background_tasks`, `crons`) | `Notification` (`permission_prompt`, `idle_prompt`), `PermissionRequest` | `SessionStart` / `SessionEnd` | Claude-compatible (22 events) | yes | `~/.qwen/projects/<p>/chats/*.jsonl` | H |
| **Charm Crush** | active (v0.98.1) | native Go `crush` | `~/.config/crush/crush.json` `"hooks"` | **no hook** (built-in desktop notification) | **no hook** | none | Claude-like, `PreToolUse` only | `PreToolUse`: 2 = deny, 49 = halt turn | `<proj>/.crush/crush.db` + `~/.local/share/crush/projects.json` | H |
| **Kiro CLI** (ex-Amazon Q `q`) | active (3.0, Oct 2026) | native `kiro-cli`, `kiro-cli-chat`, `kiro-cli-term` | V3: `~/.kiro/hooks/*.json`; 2.x: `~/.kiro/agents/<agent>.json` | `Stop` / `stop` | none | `SessionStart` (`agentSpawn`) / none | own JSON | V3 `Stop`: exit **1** or `decision:block` → continues | `~/.kiro/sessions/cli/<id>.jsonl` | M |
| **Augment Auggie** | active (0.36.0) | `node …/auggie` (augment.mjs) | `~/.augment/settings.json` `"hooks"` | `Stop` (`agent_stop_cause`) | `Notification` (type `info`, unclear) | `SessionStart` / `SessionEnd` | Claude-like, but timeouts in **ms** | `Stop`: `hookSpecificOutput.decision:block` | `~/.augment/sessions/` (L) | H/M |
| **Cline CLI** (+ VS Code ext.) | active (3.0.70) | native `cline` | executable files in `~/.cline/hooks/` or `~/Documents/Cline/Hooks/` | `TaskComplete` (`hookName:"agent_end"`) | none (CLI auto-approves by default) | `TaskStart` / `SessionShutdown` | file-per-event | `cancel:true` JSON | `~/.cline/data/sessions/<id>/`, `db/sessions.db` | H |
| **Warp built-in agent** (Oz) | active | `Warp.app/…/stable` (in-app); `oz` CLI | **none** | none (native Warp notifications only) | none | none | n/a | n/a | `…/dev.warp.Warp-Stable/warp.sqlite` (`ai_queries`) | M |
| **Plandex** | **dormant** (cli/v2.2.1, 2025-07; Cloud shut 2025-11) | Go `plandex` / `pdx` | none | none | none | none | n/a | n/a | server-side; `~/.plandex-home-v2/` | H |
| **OpenHands CLI** | active (1.16.0) | Python `openhands` (uv tool), `openhands-acp` | `~/.openhands/hooks.json` (**shadowed** by a project `.openhands/hooks.json`) | `Stop` | none via hooks; `base_state.json` `execution_status=waiting_for_confirmation` | `SessionStart` / `SessionEnd` | Claude-compatible (snake or Pascal) | `Stop`: exit 2 / `decision:deny` | `~/.openhands/conversations/<id>/base_state.json` | H |
| **Continue CLI (`cn`)** | slowing (1.5.47, 2026-06) | `node …/cn` | loads `~/.continue/settings.json` **and `~/.claude/settings.json`** | **not fired** in 1.5.47 | not fired | not fired | Claude-compatible types | n/a | `~/.continue/sessions/` (L) | M |
| **Kimi Code CLI** (new TS) | active (`@moonshot-ai/kimi-code` 2.1.1) | `kimi-code` (process.title), cmd `kimi` | `~/.kimi-code/config.toml` `[[hooks]]` | `Stop`, `StopFailure`, `Interrupt` | `PermissionRequest` (observe-only) | `SessionStart` / `SessionEnd`, `SessionHeartbeat` | own TOML | `Stop`/`PreToolUse`/`UserPromptSubmit`: exit 2 | `~/.kimi-code/sessions/session_*/agents/*/wire.jsonl` | H |
| ↳ legacy `kimi-cli` (Python) | **archived** (1.52.0) | `kimi` | `~/.kimi/config.toml` | wire `TurnEnd` | — | — | — | — | `~/.kimi/sessions/<hash>/<uuid>/wire.jsonl` | H |
| **Mistral Vibe** | active (2.26.1) | Python `vibe`, `vibe-acp` | `~/.vibe/hooks.toml` | `post_agent` | none (bell and title "Action Required") | none | own TOML | tool hooks only | `~/.vibe/logs/session/*/meta.json`, `messages.jsonl` | H |
| **Grok Build** (xAI) | active (1.0.50) | native `grok` | `~/.grok/hooks/*.json` (+ reads `.claude/settings.json`, `.cursor/hooks.json`) | `Stop`, `StopFailure` | `Notification`, `PermissionDenied` | `SessionStart` / `SessionEnd` | Claude-shaped, **camelCase payload** | docs: only `PreToolUse`; integrators: `Stop` is a gate | `~/.grok/sessions/<cwd>/<uuid>/updates.jsonl` (`turn_completed`) | M |
| **Devin CLI** (Cognition) | active (3000.11.3) | native `devin` | `~/.config/devin/config.json` `"hooks"` **+ `~/.claude/settings.json`** | `Stop` | `PermissionRequest` | `SessionStart` / `SessionEnd` | Claude-compatible | exit 2 / `decision:block` | `~/.local/share/devin/cli/sessions.db` | H |
| **Kilo CLI** (OpenCode fork) | active (7.8.8) | native `kilo` | plugin `~/.config/kilo/plugins/*.ts` | `session.idle` | `permission.asked`, `question.asked` | `session.created` / `session.deleted` | OpenCode plugin | plugin | OpenCode-style store (L) | M |
| **Pi / Oh-My-Pi** | active (pi 1.1.0, omp 18.10.1) | `pi` (process.title), `omp` | `~/.pi/agent/extensions/*.ts`, `~/.omp/agent/extensions/*.ts` | `agent_end` | n/a (no approval system by default) | `session_start` / `session_shutdown` | TS extension | extension | `~/.pi/agent/sessions/`, `~/.omp/agent/sessions/` | M |
| **Qoder CLI / CodeBuddy / iFlow** | active / active / stale (May 2026) | `node …/qodercli`, `codebuddy`/`cbc`, `iflow` | `~/.qoder/settings.json`, `~/.codebuddy/settings.json`, `~/.iflow/settings.json` | `Stop` | `Notification`, `PermissionRequest` | `SessionStart` / `SessionEnd` | Claude-compatible | Claude semantics | various | M |
| **Rovo Dev CLI** (Atlassian) | active | `acli rovodev` | `~/.rovodev/config.yml` `eventHooks` | `on_complete` | `on_tool_permission` | `on_session_start` / `on_session_end` | own YAML (event in argv) | fire-and-forget | transcript (deleted after hook) | M |
| **Hermes Agent** (Nous) | active | `hermes` | `~/.hermes/config.yaml` `hooks:` | `post_llm_call` (and `on_session_end` fires **every turn**) | `pre_approval_request` | `on_session_start` / `on_session_finalize` | own YAML | — | `~/.hermes/state.db` | M |
| **Junie CLI** (JetBrains) | active | `junie` | `~/.junie/config.json` | **only `SessionStart` documented** | — | `SessionStart` | own | — | — | M |

Native `amp`, `droid`, `cline`, `grok`, `kilo`, `goose`, `crush` and `kiro-cli*` are single-file binaries. Their npm packages are thin shims plus a per-platform optional dependency, for example `@factory/cli-darwin-arm64` and `@cline/cli-darwin-arm64` (verified via `npm view … optionalDependencies`).

---

## 2. Cross-cutting findings (read first)

### 2.1 The Claude-compatible family, and who else reads `~/.claude/settings.json` (H/M)

| Reads Claude's files | Which files | Source |
|---|---|---|
| **Continue `cn`** | `~/.claude/settings.json`, `.claude/settings.json`, `.claude/settings.local.json` (merged with `~/.continue/settings.json`) | `continuedev/continue` `extensions/cli/src/hooks/hookConfig.ts` (H) |
| **Devin CLI** | `~/.claude.json`, `~/.claude/settings.json`, `~/.claude/settings.local.json`, plus project `.claude/*`, when `read_config_from.claude` is on (the default) | docs.devin.ai hooks overview (H) |
| **Grok Build** | `.claude/settings.json` and `.cursor/hooks.json`, with Claude tool names mapped automatically | docs.x.ai/build/features/hooks (H; user-level vs project-level not stated) |
| **Cursor IDE/CLI** | `~/.claude/settings.json` as the lowest-priority of 7 sources when "third-party hooks" is on. A known parse bug for Stop-only configs (forum, Cursor 2.6.11) | cursor.com/docs/reference/third-party-hooks (M) |
| **Factory Droid** | not at runtime; v0.26.3 (2025-11-18) "detects and imports hooks from Claude Code CLI with interactive prompts" | Factory changelog (M) |
| **Mistral Vibe** | loads Claude Code **plugins** (`.claude-plugin/plugin.json` with hooks; `HookProtocol.CLAUDE_CODE`), not `settings.json` | `vibe/core/plugins/_claude.py`, `vibe/core/hooks/models.py` (H) |

**Consequence for Lidless:** a single `Stop` hook in `~/.claude/settings.json` can fire from Claude Code, cn (once wired), Devin, Grok and Cursor. Each of those tools may also run the hook Lidless installed in its own config, so the same turn end can arrive twice. The handler must:

- attribute the event from its **own environment and parent chain**, not from which config file it was installed in (§2.6);
- deduplicate on `(agent, session_id, normalized_event, 2-second window)`.

### 2.2 Stop hooks are gates: the Lidless hook must be inert (H)

| Agent | What keeps the agent running |
|---|---|
| Droid | `Stop` exit 2 (stderr fed back), or stdout `{"decision":"block","reason":…}` |
| Qwen | exit 2 (stderr to model) or JSON `decision` |
| **Kiro V3** | **exit code 1** or `{"decision":"block","reason":"…"}` → "make Kiro continue for another turn". Exit 2 is *not* used for Stop. |
| Goose | exit 2, or stdout starting with `{` and containing `"decision":"block"` (capped by `GOOSE_STOP_HOOK_BLOCK_CAP`) |
| Kimi Code | `Stop` exit 2 → "a message can be appended to let the model continue" (re-triggers once, `stop_hook_active`) |
| Augment | `hookSpecificOutput.decision:"block"` on Stop |
| OpenHands | exit 2 or `{"decision":"deny"}`; `async: true` hooks can never block |
| Devin | exit 2 / `decision:block` |
| Grok | docs say only `PreToolUse` blocks; peon-ping found that decision-like JSON on stdout keeps Grok working, and discards output |
| Crush | `PreToolUse` exit 49 halts the whole turn |

**Rule:** `lidless-hook` exits `0` in all paths, including crash and timeout paths. It writes **nothing** to stdout (diagnostics go to a log file, never stderr either, because several agents surface stderr in the transcript). It needs **no network** and never waits for the Lidless app. Where an agent supports it, Lidless marks the hook `async` (OpenHands `"async": true`; CodeIsland also marks Claude-family status hooks async).

### 2.3 Turn vs. session semantics, and cancellations (H unless noted)

- *Per turn* (fires every time the agent hands control back): Droid/Qwen/cn/Devin/Grok `Stop`, Goose `Stop` ("accept or block a completed assistant turn", `ops_stop_hook.rs`), Kiro `stop` ("at the end of each turn"), Kimi `Stop`, Augment `Stop` (`agent_stop_cause: end_turn`), Amp `agent.end` ("finished handling a user prompt"), Vibe `post_agent` ("after an assistant turn with no pending tool calls"), Cline `agent_end`, Kilo `session.idle`, Pi `agent_end`, Rovo `on_complete`, Hermes `post_llm_call`.
- **Traps:**
  - **Hermes** `on_session_end` fires after every turn; the true end is `on_session_finalize` (CodeIsland source comment, M).
  - **Droid:** cancelling a turn emits `Notification` with `idle_prompt` *instead of* `Stop` (Factory docs, H).
  - **Kimi:** user interrupt fires `Interrupt` *instead of* `Stop`; API failure fires `StopFailure`.
  - **Augment:** `agent_stop_cause` ∈ `end_turn | interrupted | max_iterations | error`.
  - **Amp:** `agent.end.status` ∈ `done | error | cancelled`.
- **Background work outlives the turn.** Qwen's `Stop` payload carries `background_tasks` and `crons`. Kimi has `TaskStarted` and `Notification` `task.completed`. Warp's Claude plugin now reports pending background work on Stop (commit 2026-10-08). A "turn ended" event is therefore **not** proof that the machine can sleep. Lidless must also check for live child processes of the agent (§7.4).

### 2.4 Shadowing, precedence and trust (H)

- **Factory:** `~/.factory/hooks.json` wins; `settings.json` `"hooks"` is read **only if `hooks.json` is absent**. A Droid save migrates the legacy `.factory/hooks/hooks.json`.
- **OpenHands:** `HookConfig.load()` takes the **first** of `<cwd>/.openhands/hooks.json`, `~/.openhands/hooks.json`, and does not merge them. A repo with its own hooks file silently disables the user-level Lidless hook.
- **Kiro 2.x:** hooks live inside an *agent* file and fire only when that agent is active. CodeIsland notes that users must launch `kiro --agent codeisland`. Kiro **V3** (2.13+ with `--v3`, default from 3.0) adds global `~/.kiro/hooks/` that "run in every workspace".
- **Grok:** project hooks need `/hooks-trust` or `--trust`; user hooks do not. **Vibe:** project `hooks.toml` loads only in trusted folders, and same-`name` entries in the project file win. **Hermes:** hooks must be approved once. **Junie:** project `.junie/config.json` hooks are ignored by default.
- **Cursor:** `~/.cursor/hooks.json` outranks the Claude files.

### 2.5 Timeout units differ (H)

| Agent | Units and default |
|---|---|
| Droid | seconds, default 60 |
| Qwen | command hooks in seconds, default 60; values ≥ 1000 are treated as ms "for backward compatibility"; http hooks default 600 s |
| Augment | **milliseconds**, default 60000 |
| Kiro 2.x | `timeout_ms`, default 30000 |
| Kiro V3 | seconds, default 60, `0` = none |
| Goose | seconds, default 30 |
| Kimi | seconds 1–600, default 30 |
| Grok | seconds, default 5 |
| Vibe | float seconds, default 60 |
| OpenHands | seconds, default 60 |
| Crush | seconds, default 30 |

Lidless should write `5` seconds, or `5000` for Augment and Kiro 2.x.

### 2.6 Identifying the caller and the agent process on macOS (verified locally, H)

`research-snippets/agentscan.swift` (`proc_listallpids` + `proc_pidinfo(PROC_PIDTBSDINFO)` + `sysctl(KERN_PROCARGS2)`), run unprivileged, produced:

```
pid=96888 ppid=96662 agent=claude p_comm=2.1.296 exe=/Users/tomasnguyen/.local/bin/claude
   argv=["claude"]
   env-markers=["__CFBundleIdentifier=com.apple.Terminal", "TERM_PROGRAM=Apple_Terminal", ...]
pid=35816 ppid=44386 agent=claude p_comm=2.1.296 exe=/Users/tomasnguyen/.local/bin/claude
   argv=["/Users/tomasnguyen/.local/bin/claude", "daemon", "run", "--origin"]
   env-markers=[..., "AI_AGENT=claude-code_2-1-288_harness", "CLAUDE_CODE_ENTRYPOINT=cli"]
```

Findings from that run:

- **Kernel `p_comm` ≠ `ps -o comm`.** For Claude Code, `pbi_comm` is the basename of the symlink target (`versions/2.1.296`). `ps -o comm` shows argv[0], which `process.title` can rewrite. Compare npm, which shows `npm exec vite`. Match on **exe path, argv[0] basename and argv[1] script path**, never on `p_comm` alone.
- **Node CLIs:**
  - Kimi Code sets `process.title = "kimi-code"` (bundle constant `PROCESS_NAME`).
  - Pi sets `process.title = "pi"`, or `pi-rpc` in RPC mode.
  - **Qwen, Auggie, Qodercli and cn set no title**, so they appear as `node /opt/homebrew/bin/qwen` and similar.
  - Several npm bins are native files named `*.exe` on macOS: `@ampcode/cli/bin/amp.exe`, `opencode.exe`, `claude.exe`. Match both `amp` and `amp.exe`.
  - All of the above comes from npm tarballs unpacked and grepped, not executed.
- **Environment of other same-user processes is readable** (no entitlement needed; Lidless is not sandboxed).
- **Env markers inherited by hook processes**, which the hook handler should test:

| Marker | Agent |
|---|---|
| `AI_AGENT=claude-code_<ver>_harness` (emerging convention, see §9.4), `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT` | Claude Code |
| `CRUSH=1`, `AGENT=crush`, `AI_AGENT=crush`, `CRUSH_EVENT`, `CRUSH_SESSION_ID` | Crush |
| `FACTORY_PROJECT_DIR`, `DROID_PLUGIN_ROOT` | Droid |
| `QWEN_PROJECT_DIR` | Qwen |
| `AUGMENT_PROJECT_DIR`, `AUGMENT_CONVERSATION_ID`, `AUGMENT_HOOK_EVENT`; `AUGMENT_AGENT` per @vercel/detect-agent | Augment |
| `DEVIN_PROJECT_DIR` | Devin |
| `GROK_HOOK_EVENT`, `GROK_SESSION_ID`, `GROK_WORKSPACE_ROOT` | Grok |
| `OPENHANDS_EVENT_TYPE`, `OPENHANDS_SESSION_ID`, `OPENHANDS_PROJECT_DIR` | OpenHands |
| `PLUGIN_ROOT` | Goose (ambiguous) |
| `CLINE_*` dirs if set | Cline |

  If no marker matches, walk `ppid` upward from the hook process until an exe or argv matches a known agent signature.

### 2.7 Some agents already hold sleep assertions (H)

`pmset -g assertions` (read-only, run locally) shows Claude Code spawning `caffeinate -i -t 300` (children of the `claude` pids). Qwen Code ships `packages/core/src/services/sleepInhibitor.ts`, which spawns **`caffeinate -is`** while running. Kilo has an opt-in "keep awake" (`/usr/bin/caffeinate -i -w <pid>`).

This is a free "agent is working" signal: `IOPMCopyAssertionsByProcess` → assertion owner `caffeinate` → ppid is an agent. It is **not** enough for the lid-closed case. `-i` only prevents idle sleep, and `-s` applies only on AC power, so the agent's own assertion does not keep a closed laptop on battery awake. That remains Lidless's job.

---

## 3. Per-agent details: the 14 requested

### 3.1 Sourcegraph Amp

- **Version / status:** npm `@sourcegraph/amp` → `@ampcode/cli` `0.0.1791806555-g425e34` (published 2026-10-12). Native, Bun-compiled. Recommended install is the binary installer (H, `npm view`).
- **(a) Process:** native `amp`. When installed through npm the exe file is `…/@ampcode/cli/bin/amp.exe` (H). It runs headless as `amp -x/--execute … --stream-json` (M, ampcode.com/news/streaming-json). Thread ids look like `T-<uuid>`.
- **(b) Config:**
  - `~/.config/amp/settings.json` or `.jsonc` (user)
  - nearest `.amp/settings.json` (workspace)
  - managed settings at `/Library/Application Support/ampcode/managed-settings.json`
  - All keys use the `amp.` prefix (H, ampcode.com/docs/cli/settings).
- **(c) Mechanism:** there is **no `amp.hooks` setting** (H). Built-in `amp.notifications.enabled` (default `true`) "plays a sound when the agent finishes or is waiting for input". Over SSH, or with `AMP_FORCE_BEL`, it sends a terminal bell instead (H).

  The deterministic route is the **Plugin API** (H, ampcode.com/manual/plugin-api). Plugins are TypeScript files in `~/.config/amp/plugins/` (system) or `.amp/plugins/` (project), executed with Bun. They are managed with `amp plugins add <url>` or reloaded with `plugins: reload`.

  | Event | Payload |
  |---|---|
  | `session.start` | `thread:{id}` |
  | `agent.start` | `thread, message, id` |
  | `agent.end` | `thread, message, id, status: "done"\|"error"\|"cancelled", messages` |
  | `tool.call` | can return `allow`, `reject-and-continue`, `modify`, `synthesize` or `error` |
  | `tool.result` | — |

  Handlers get `ctx.ui.notify(msg)` and `ctx.$` (a shell runner that never throws).

  Older mirrors say plugins need `PLUGINS=all amp`, a magic header comment, and the binary install (not npm). The current official page does **not** mention this. (M/L: **verify on install**.)

  Sketch, not tested; verify import and type names against the manual:

  ```ts
  // ~/.config/amp/plugins/lidless.ts
  import { connect } from "node:net";
  const SOCK = `${process.env.HOME}/.lidless/run/hook.sock`;
  function send(ev: Record<string, unknown>) {
    try { const s = connect(SOCK); s.on("error", () => {}); s.end(JSON.stringify({ agent: "amp", ...ev }) + "\n"); } catch {}
  }
  export default function (amp: any) {
    amp.on("session.start", async (e: any) => { send({ event: "SessionStart", session_id: e.thread?.id }); });
    amp.on("agent.start",   async (e: any) => { send({ event: "UserPromptSubmit", session_id: e.thread?.id }); });
    amp.on("agent.end",     async (e: any) => { send({ event: "Stop", session_id: e.thread?.id, status: e.status }); }); // return nothing → never auto-continue
  }
  ```
- **(d) Payload:** see the event table above. Thread ids are `T-…`.
- **(e) Blocking:** `tool.call` return values gate tools. An `agent.end` handler that returns a `continue` action starts another turn (`maxContinuations`, default 5). **Return nothing.**
- **(f) State:** `~/.local/share/amp/threads/T-*.json` (override `AMP_DATA_DIR`), one JSON document per thread with `messages[]` (M: codeburn `docs/providers/amp.md`, peon-ping `adapters/amp.sh`).
- **(g) Fallback:** FSEvents on `threads/`. peon-ping's heuristic treats a thread as finished when the file has been unchanged for ≥ 1 s and the last message has `role:"assistant"` with `text` content and **no** `tool_use`. Needs-input is not detectable via plugin or files (unknown). The PTY or bell path catches it when `AMP_FORCE_BEL` is set.
- **Confidence:** plugin events H; enablement requirements M/L; the thread-file format M (reverse-engineered).

### 3.2 Block Goose

- **Version / status:** v1.54.0 (2026-10-08), 55k★. Hooks were announced 2026-05-14 (H).
- **(a) Process:** native Rust `goose` (CLI). Goose Desktop runs `goosed`. The ACP entry is `goose acp` (registry, H). Process names are M.
- **(b) Config:**
  - general config `~/.config/goose/config.yaml` (provider, extensions)
  - **hooks live in plugins**: `~/.agents/plugins/<name>/hooks/hooks.json` (user) or `<project>/.agents/plugins/<name>/` (project), auto-discovered at startup
  - disable a plugin via `disabledPlugins` in `~/.config/goose/settings.json` (H, goose-docs.ai hooks guide)
- **(c) Mechanism:** "follows the Open Plugins hooks specification" (that spec, now agent-plugins.org v1, actually **excludes** hooks; see §9.3). Events (H, `crates/goose/src/hooks/mod.rs`): `SessionStart`, `SessionEnd`, `Stop`, `UserPromptSubmit`, `PreToolUse`, `PreToolUseResult`, `PostToolUse`, `PostToolUseFailure`, `BeforeReadFile`, `AfterFileEdit`, `BeforeShellExecution`, `AfterShellExecution`. `SubagentStart`/`SubagentStop` are not emitted. There is **no Notification or permission event.**

  ```json
  // ~/.agents/plugins/lidless/hooks/hooks.json   (plus a minimal plugin.json, as in examples/plugins/hello-hooks)
  { "hooks": {
      "SessionStart":     [{ "hooks": [{ "type": "command", "command": "/Users/USER/.lidless/bin/lidless-hook --agent goose", "timeout": 5 }] }],
      "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "/Users/USER/.lidless/bin/lidless-hook --agent goose", "timeout": 5 }] }],
      "Stop":             [{ "hooks": [{ "type": "command", "command": "/Users/USER/.lidless/bin/lidless-hook --agent goose", "timeout": 5 }] }],
      "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "/Users/USER/.lidless/bin/lidless-hook --agent goose", "timeout": 5 }] }]
  } }
  ```
- **(d) Payload (`HookContext`):**
  - always present: `event`, `session_id`
  - optional: `matcher_context`, `tool_call_id`, `tool_name`, `tool_input`, `tool_output`, `message`, `last_assistant_message` (on Stop: the trailing assistant text), `working_dir`, `decision`, `policy_evaluated`, `blocked_by`, `reason`
  - The env var `PLUGIN_ROOT` is set. **The key is `event`, not `hook_event_name`.** (H)
- **(e) Blocking:** only `PreToolUse` and `Stop` can block, via exit 2 or stdout `{"decision":"block","reason":…}` (stdout must start with `{`). Failures and timeouts are logged and fail open. `on_failure` applies to `PreToolUse` only (H).
- **(f) State:** `~/.local/share/goose/sessions/sessions.db` (SQLite; `XDG_DATA_HOME` and `GOOSE_PATH_ROOT` override) (M, codeburn).
- **(g) Fallback:** poll sessions.db (read-only, WAL-safe) for the last message role and time. For needs-input, use a heuristic: `PreToolUse` seen, no `PostToolUse` within 20 s, and goose CPU ≈ 0 while `GOOSE_MODE` is `approve` or `smart_approve` → probably waiting for approval.
- **Note:** `~/.agents/plugins/` is a shared cross-agent location. The Cline SDK also scans `.agents/plugins` for agent-plugins.org packages (`sdk/packages/shared/src/storage/paths.ts`), so the handler must not assume the caller is goose without checking (§2.6).

### 3.3 Factory Droid

- **Version / status:** 0.238.0 (npm `droid` and `@factory/cli`, 2026-10-10). Native binary through per-platform optional deps (H). It is in the ACP registry as `droid exec --output-format acp-daemon`.
- **(a) Process:** `droid`, installed via `curl -fsSL https://app.factory.ai/cli | sh` → `~/.local/bin/droid` (M). Headless mode is `droid exec`.
- **(b) Config:**
  - Hooks go in `~/.factory/hooks.json` (user) or `.factory/hooks.json` (project), keyed directly by event name.
  - **If `hooks.json` is absent**, Droid reads the `"hooks"` key of the matching `settings.json` (`~/.factory/settings.json`, `.factory/settings.json`, `.factory/settings.local.json`).
  - The legacy `.factory/hooks/hooks.json` still loads and is migrated on save (H, docs.factory.com hooks reference).
  - Docs disagree slightly: one page still lists only `settings.json`. CodeIsland and Entire write `settings.json`.
- **(c) Events:** `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Notification`, `Stop`, `SubagentStop`, `PreCompact`, `SessionStart`, `SessionEnd` (H). Built-in sounds: `completionSound` (default `fx-ok01`), `awaitingInputSound` (`fx-ack01`), `soundFocusMode` (`always|focused|unfocused`) in `~/.factory/settings.json` (H).

  ```json
  // ~/.factory/hooks.json  (if this file exists, merge here; otherwise merge the same map under "hooks" in ~/.factory/settings.json)
  {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "/Users/USER/.lidless/bin/lidless-hook --agent droid", "timeout": 5 }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "/Users/USER/.lidless/bin/lidless-hook --agent droid", "timeout": 5 }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "/Users/USER/.lidless/bin/lidless-hook --agent droid", "timeout": 5 }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "/Users/USER/.lidless/bin/lidless-hook --agent droid", "timeout": 5 }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "/Users/USER/.lidless/bin/lidless-hook --agent droid", "timeout": 5 }] }]
  }
  ```
- **(d) Payload:**
  - common: `session_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`, optional `message_id`
  - `Notification`: `message`, `notification_type` ∈ `permission_prompt | idle_prompt | auth_success | elicitation_dialog`
  - `Stop`: `stop_hook_active`, `tool_execution_count`, `elapsed_time`
  - `SessionStart`: `source` ∈ `startup | resume | clear | compact`
  - `SessionEnd`: `reason` ∈ `clear | logout | prompt_input_exit | other`, `session_duration_ms`, `message_count`
  - Scalar common fields are also exported as env vars, and `FACTORY_PROJECT_DIR` is set (H).
- **(e) Blocking:** exit 2 = block or feedback (Stop feeds stderr back to Droid). JSON `decision:"block"` on Stop/SubagentStop prevents stopping. `SessionEnd` cannot block (H).
- **(f) State:** `~/.factory/sessions/<subdir>/*.jsonl` (`$FACTORY_DIR` override) (M, codeburn).
- **(g) Fallback:** tail the JSONL, plus process liveness.
- **Gotcha:** cancel → `Notification(idle_prompt)` instead of `Stop`. Treat `idle_prompt` as "idle", not as "finished, notify".

### 3.4 Qwen Code

- **Version / status:** `@qwen-code/qwen-code` 0.25.1 (2026-10-11), Node ≥ 22. Gemini-CLI lineage. It has a `qwen serve` multi-workspace daemon mode (H, settings.md).
- **(a) Process:** `node …/qwen` (bin `cli-entry.js`); no `process.title` on macOS (H, bundle grep). ACP: `qwen --acp`.
- **(b) Config:** `~/.qwen/settings.json` (override the directory with `QWEN_HOME`), project `.qwen/settings.json`. "Hooks are enabled by default"; turn them off with `"disableAllHooks": true` (H).
- **(c) Events (22):** `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PostToolBatch`, `UserPromptSubmit`, `UserPromptExpansion`, `SessionStart`, `SessionEnd`, `SessionDelete`, `MessageDisplay`, `Stop`, `StopFailure`, `SubagentStart`, `SubagentStop`, `PreCompact`, `PostCompact`, `Notification`, `PermissionRequest`, `PermissionDenied`, `TodoCreated`, `TodoCompleted`, `InstructionsLoaded`. Handler types are `command`, `http`, `prompt` and `function` (H). Built-in: `general.terminalBell` (default **true**) "when a response completes or needs approval" (H).

  ```json
  // ~/.qwen/settings.json → "hooks"
  "hooks": {
    "SessionStart":      [{ "matcher": "*", "hooks": [{ "type": "command", "command": "/Users/USER/.lidless/bin/lidless-hook --agent qwen", "timeout": 5, "name": "lidless" }] }],
    "UserPromptSubmit":  [{ "matcher": "*", "hooks": [{ "type": "command", "command": "/Users/USER/.lidless/bin/lidless-hook --agent qwen", "timeout": 5, "name": "lidless" }] }],
    "Stop":              [{ "matcher": "*", "hooks": [{ "type": "command", "command": "/Users/USER/.lidless/bin/lidless-hook --agent qwen", "timeout": 5, "name": "lidless" }] }],
    "StopFailure":       [{ "matcher": "*", "hooks": [{ "type": "command", "command": "/Users/USER/.lidless/bin/lidless-hook --agent qwen", "timeout": 5, "name": "lidless" }] }],
    "Notification":      [{ "matcher": "*", "hooks": [{ "type": "command", "command": "/Users/USER/.lidless/bin/lidless-hook --agent qwen", "timeout": 5, "name": "lidless" }] }],
    "PermissionRequest": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "/Users/USER/.lidless/bin/lidless-hook --agent qwen", "timeout": 5, "name": "lidless" }] }],
    "SessionEnd":        [{ "matcher": "*", "hooks": [{ "type": "command", "command": "/Users/USER/.lidless/bin/lidless-hook --agent qwen", "timeout": 5, "name": "lidless" }] }]
  }
  ```
  An `http` hook type exists (`{"type":"http","url":…}`), but **private-network targets are blocked by default**: localhost needs `security.allowPrivateNetworkHooks` in *managed* settings. Use `command`.
- **(d) Payload:**
  - common: `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `timestamp`, `permission_mode` (+ `agent_id`, `prompt_id`, `source_type`, `source_id`)
  - `Stop`: `stop_hook_active`, `last_assistant_message`, `context_usage`, `context_limit`, `input_tokens`, **`background_tasks`, `crons`**
  - `Notification`: `message`, `title?`, `notification_type` ∈ `permission_prompt | idle_prompt | auth_success`
  - `SessionStart`: `source`, `model`, `agent_type?`
  - `SessionEnd`: `reason` ∈ `clear | logout | prompt_input_exit | bypass_permissions_disabled | other`
  - `PermissionRequest`: `tool_name`, `tool_input`, `permission_suggestions?`
  - (H)
- **(e) Blocking:** exit 2 blocks (stderr → model); JSON `decision`/`continue`/`hookSpecificOutput` as in Claude (H).
- **(f) State:** `~/.qwen/projects/<project>/chats/*.jsonl` (`QWEN_DATA_DIR`) (M, codeburn); `~/.qwen/tmp/<project_hash>/` (H).
- **(g) Fallback:** `caffeinate -is` child while busy (§2.7); JSONL tail.

### 3.5 Charm Crush

- **Version / status:** v0.98.1 (2026-10-09), Go (H).
- **(a) Process:** `crush` (Go). npm `@charmland/crush` is a JS launcher (`run-crush.js`) for the Go binary, so a `node` parent may appear (M).
- **(b) Config:** `~/.config/crush/crush.json` (global), `crush.json` or `.crush.json` (project; project hooks win) (H).
- **(c) Mechanism:** "Crush currently supports just one hook, `PreToolUse`" (H, `docs/hooks/README.md`); `docs/hooks/FUTURE.md` sketches more. Desktop notifications are built in: "when a tool call requires your permission, and when the agent finishes its turn", **only when the terminal is unfocused and reports focus**. Disable with `options.disable_notifications`. The implementation uses `beeep` (`internal/ui/notification/native_beeep.go`). Internally `notify.TypeAgentFinished = "agent_finished"` (H) is not exposed externally.

  ```jsonc
  // ~/.config/crush/crush.json — activity heartbeat only (fires per top-level tool call)
  { "hooks": { "PreToolUse": [ { "name": "lidless", "matcher": ".*", "command": "/Users/USER/.lidless/bin/lidless-hook --agent crush --event PreToolUse", "timeout": 5 } ] } }
  ```
- **(d) Payload:** `event`, `session_id`, `cwd`, `tool_name`, `tool_input`. Env: `CRUSH=1`, `AGENT=crush`, `AI_AGENT=crush`, `CRUSH_EVENT`, `CRUSH_TOOL_NAME`, `CRUSH_SESSION_ID`, `CRUSH_CWD`, `CRUSH_PROJECT_DIR`, `CRUSH_TOOL_INPUT_COMMAND`, `CRUSH_TOOL_INPUT_FILE_PATH` (H).
- **(e) Blocking:** 0 = ok (stdout parsed as JSON with `decision`, `halt`, `reason`, `context`, `updated_input`); **2 = deny**; **49 = halt the turn**; anything else = ignored (H). Lidless must not print a `decision`: `"allow"` would skip the permission prompt.
- **(f) State:** per-project SQLite `<project>/.crush/crush.db`, registry `~/.local/share/crush/projects.json` (`CRUSH_GLOBAL_DATA` / `XDG_DATA_HOME`) (M, codeburn, schema checked against v0.66.1).
- **(g) Fallback:** turn end = no `PreToolUse` heartbeat for N s and crush CPU ≈ 0, or the latest assistant message in `crush.db` is finished (schema unknown, L). Needs-input is not observable except through Crush's own notification. A PTY wrapper doesn't help either, because Crush uses OS notifications, not BEL.

### 3.6 Kiro CLI (formerly Amazon Q Developer CLI `q`)

- **Version / status:** CLI V3 early access was in 2.8, and global hooks arrived in 2.13 (`--v3`). 2.28 / 3.0 (≈ 2026-10-01..05) made 3.0 the switch target (M, kiro.dev changelog and Havoptic). The old repo `aws/amazon-q-developer-cli` is still public (last push 2026-08).
- **(a) Process:** install script `curl -fsSL https://cli.kiro.dev/install | bash` defines `BINARY_NAME="kiro-cli"` and `CHAT_BINARY_NAME="kiro-cli-chat"`. On macOS the app bundle is `/Applications/Kiro CLI.app/Contents/MacOS/…`. `kiro-cli-term` appears as a shell child (shell integration). The chat process is `kiro-cli-chat` (M). Legacy names are `q` and `qchat` (L).
- **(b) Config:**
  - **V3** (recommended): standalone `~/.kiro/hooks/*.json` (global, all workspaces) and `.kiro/hooks/*.json` (workspace); both run.
  - **2.x**: a `"hooks"` object inside an agent file (`~/.kiro/agents/<name>.json` or `.kiro/agents/<name>.json`) that fires only for that agent.
  - Run `kiro-cli agent migrate` or `/upgrade-agent` to convert (H, kiro.dev hooks-migration and hooks pages).
- **(c) Triggers:**
  - V3: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostFileCreate`, `PostFileSave`, `PostFileDelete`, `PreTaskExec`, `PostTaskExec`, `Stop`, `Manual`
  - 2.x: `agentSpawn`, `userPromptSubmit`, `preToolUse`, `postToolUse`, `stop`
  - **No Notification or permission trigger** (H)

  ```json
  // ~/.kiro/hooks/lidless.json  (V3)
  { "version": "v1", "hooks": [
    { "name": "lidless-session", "trigger": "SessionStart",     "action": { "type": "command", "command": "/Users/USER/.lidless/bin/lidless-hook --agent kiro --event SessionStart" },     "timeout": 5 },
    { "name": "lidless-prompt",  "trigger": "UserPromptSubmit", "action": { "type": "command", "command": "/Users/USER/.lidless/bin/lidless-hook --agent kiro --event UserPromptSubmit" }, "timeout": 5 },
    { "name": "lidless-stop",    "trigger": "Stop",             "action": { "type": "command", "command": "/Users/USER/.lidless/bin/lidless-hook --agent kiro --event Stop" },             "timeout": 5 }
  ] }
  ```
  2.x fallback, merged into the agent the user actually runs (`kiro-cli settings chat.defaultAgent` tells you which, M):
  `"hooks": { "agentSpawn": [{"command": "…/lidless-hook --agent kiro --event SessionStart", "timeout_ms": 5000}], "userPromptSubmit": [{…}], "stop": [{…}] }`
- **(d) Payload:**
  - 2.x open-source doc: `{"hook_event_name":"stop","cwd":"…"}`
  - kiro.dev: `{"hook_event_name":"stop","cwd","session_id","assistant_response"}`
  - Tool hooks add `tool_name`, `tool_input` (`tool_response` on post).
  - V3 payload field names are **not documented** (M/L). Pass `--event` in argv and tolerate any casing.
- **(e) Blocking:**
  - 2.x: exit 2 blocks only `preToolUse`; other non-zero codes → STDERR warning; stop hooks "do not use matchers"; caching via `cache_ttl_seconds`.
  - **V3 `Stop`: exit 1 or `{"decision":"block"}` → Kiro continues for another turn.** `UserPromptSubmit` non-zero → output forwarded as context. V3 adds an optional `confirm` block on Stop hooks (asks the user before running).
  - (H)
- **(f) State:** `~/.kiro/sessions/cli/<id>.jsonl` (events `{version, kind, data}`) + `<id>.json` (`session_state` metering) (M, codeburn).
- **(g) Fallback:** process `kiro-cli-chat` CPU plus JSONL tail. For needs-input, use the PreToolUse-without-PostToolUse heuristic.

### 3.7 Augment Auggie CLI

- **Version / status:** `@augmentcode/auggie` 0.36.0 (2026-10-09), Node ≥ 20 (H). ACP: `auggie --acp`.
- **(a) Process:** `node …/auggie` (bin `augment.mjs`). **No `process.title`** in the bundle (H, grep).
- **(b) Config precedence:**
  1. `/etc/augment/settings.json`
  2. `<ws>/.augment/settings.local.json`
  3. `<ws>/.augment/settings.json`
  4. `~/.augment/settings.json`

  The same `settings.json` also holds `notificationMode` (`off | bell | desktop_notification`; bell when asking for input since 0.20.0) (H docs and bundle).
- **(c) Events (docs):** `PreToolUse`, `PostToolUse`, `Stop`, `SessionStart`, `SessionEnd`; "Notification" is listed as a possible `hook_event_name`. The 0.36.0 bundle additionally builds `{hook_event_name:"Notification", notification_type:"info", notification_message}` and `{hook_event_name:"PromptSubmit", user_prompt}` payloads (H, bundle grep; semantics M). Notification never carries a permission type in what was seen.

  ```json
  // ~/.augment/settings.json → "hooks"   (timeouts in MILLISECONDS)
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "/Users/USER/.lidless/bin/lidless-hook --agent auggie", "timeout": 5000 }] }],
    "Stop":         [{ "hooks": [{ "type": "command", "command": "/Users/USER/.lidless/bin/lidless-hook --agent auggie", "timeout": 5000 }] }],
    "Notification": [{ "hooks": [{ "type": "command", "command": "/Users/USER/.lidless/bin/lidless-hook --agent auggie", "timeout": 5000 }] }],
    "SessionEnd":   [{ "hooks": [{ "type": "command", "command": "/Users/USER/.lidless/bin/lidless-hook --agent auggie", "timeout": 5000 }] }]
  }
  ```
- **(d) Payload:**
  - common: `hook_event_name`, **`conversation_id`** (not `session_id`), `workspace_roots[]`
  - `Stop`: `agent_stop_cause` ∈ `end_turn | interrupted | max_iterations | error`; `conversation` only with `includeConversationData`
  - Env: `AUGMENT_PROJECT_DIR`, `AUGMENT_CONVERSATION_ID`, `AUGMENT_HOOK_EVENT`, `AUGMENT_TOOL_NAME` (H)
- **(e) Blocking:** exit 2 blocks only `PreToolUse`; Stop can return `hookSpecificOutput.decision:"block"`. PreToolUse/PostToolUse/Stop run **synchronously** (H).
- **(f) State:** `~/.augment/sessions/` and `~/.augment/session.json` appear as strings in the bundle (L).
- **(g) Fallback:** no `PromptSubmit` in docs, so "busy" between turns is inferred from the first `PreToolUse` or from process CPU.

### 3.8 Cline CLI (and the Cline VS Code extension)

- **Version / status:** npm `cline` 3.0.70 (2026-10-12). The repo was restructured around a Cline **SDK** (`sdk/`), with `apps/cli`, `apps/vscode` and `apps/cline-hub` (H).
- **(a) Process:** native `cline` via `@cline/cli-darwin-arm64` (H). ACP: `cline --acp`. A local "hub" exists (`CLINE_HUB_PORT`, default 25463; `cline hub status`). The extension runs inside VS Code's extension host (`Code Helper (Plugin)`).
- **(b) Config:**
  - Hook **directories**, searched in order: `~/Documents/Cline/Hooks/`, `~/.cline/hooks/`, `<ws>/.clinerules/hooks/` (deprecated), `<ws>/.cline/hooks/`, plus `--hooks-dir` / `CLINE_HOOKS_DIR` (H, `resolveHooksConfigSearchPaths`).
  - Data lives in `~/.cline/data/` (`CLINE_DIR`, `CLINE_DATA_DIR`).
  - The extension needs Settings → Features → Enable Hooks.
- **(c) Mechanism:** one executable file per event, named exactly after it, optionally with an extension from `"" .sh .bash .zsh .js .mjs .cjs .ts .mts .cts .py .ps1`. SDK map (H, `hook-file-config.ts`):

  | File | `hookName` in payload |
  |---|---|
  | `TaskStart` | `agent_start` |
  | `TaskResume` | `agent_resume` |
  | `TaskCancel` | `agent_abort` |
  | `TaskComplete` | `agent_end` |
  | `TaskError` | `agent_error` |
  | `PreToolUse` | `tool_call` |
  | `PostToolUse` | `tool_result` |
  | `UserPromptSubmit` | `prompt_submit` |
  | `PreCompact` | — |
  | `SessionShutdown` | `session_shutdown` |

  The legacy extension used the PascalCase names as `hookName`.

  ```sh
  # ~/.cline/hooks/TaskComplete   (chmod +x; same shim for TaskStart, TaskCancel, TaskError, SessionShutdown, UserPromptSubmit)
  #!/bin/sh
  /Users/USER/.lidless/bin/lidless-hook --agent cline --event TaskComplete >/dev/null 2>&1
  printf '{"cancel":false}'
  exit 0
  ```
  The `{"cancel":false}` keeps the legacy extension parser happy. `cancel:false` is harmless (M).
- **(d) Payload:** `clineVersion`, `hookName`, `timestamp` (ms epoch, as a string), `taskId`, `sessionContext{rootSessionId,hookLogPath}`, `workspaceRoots[]`, `workspaceInfo{rootPath,latestGitBranchName,…}`, `userId`, `agent_id`, `parent_agent_id`, `iteration`, `turn` (agent_end), `error{name,message}` (agent_error), `reason` (abort/shutdown), `taskComplete{taskMetadata}` (H, `sdk/packages/shared/src/hooks/events.ts`).
- **(e) Blocking:** stdout JSON `cancel`, `contextModification` / `context`, `errorMessage`, `review`, `overrideInput`. Run-start hooks are fire-and-forget unless `blockingRunStartHooks`; tool hooks have a 120 s default timeout (H).
- **(f) State:**
  - CLI: `~/.cline/data/sessions/<id>/<id>.json` (`started_at`, `ended_at`, usage) and `<id>.messages.json`; `~/.cline/data/db/sessions.db`
  - Extension: `…/globalStorage/saoudrizwan.claude-dev/tasks/<id>/ui_messages.json`
  - (M, codeburn)
- **(g) Fallback:** `cline --json` emits `run_result` with `finishReason` (headless only). The CLI defaults to `--auto-approve true`, so needs-input is rare in the CLI.

### 3.9 Warp built-in agent (Warp "Agent", Oz)

- **Status:** Warp's agent runs inside `Warp.app` (process `stable` for the Stable channel, M). On 2026-02-10 Warp launched **Oz** (cloud agent orchestration) with the `oz` CLI (`warp-cli` is deprecated): `oz agent run --prompt …` runs locally and headless (H, docs.warp.dev Oz quickstart).
- **(c) Mechanism:** **no external hooks for Warp's own agent.**
  - Warp shows Complete, Request and Error notifications in-app, and as "native system-level desktop alerts" when Warp is unfocused (H).
  - For *third-party* CLI agents Warp consumes signals itself: the Claude Code plugin `warpdotdev/claude-code-warp` emits **OSC 777** to `warp://cli-agent` with JSON; Codex uses OSC 9 (`[tui] notification_condition="always"`); OpenCode uses `@warp-dot-dev/opencode-warp` (H).
  - Lidless cannot subscribe to any of these. They go from the agent to Warp over the PTY.
- **(f) State:** `~/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite` (official path, H). Tables `agent_conversations`, `ai_queries` (`start_ts`, `working_directory`, `model_id`, `output_status` as a JSON-quoted string, e.g. `"Completed"`) and `blocks` (M, codeburn reverse-engineering).
- **(g) Fallback:**
  1. Open `warp.sqlite` **read-only** (`file:…?mode=ro`), poll the latest `ai_queries` row and treat non-`Completed` output with a recent `start_ts` as busy (L, values unverified).
  2. Warp process CPU plus children of Warp shells.
  3. Not recommended: reading other apps' notifications from the usernoted DB needs Full Disk Access and is fragile.

  For `oz agent run`, watch the `oz` process lifetime.

### 3.10 Plandex

- **Status:** **dormant.** Plandex Cloud shut down 2025-11-07 ("winding down", 2025-10-03). Last CLI release `cli/v2.2.1` (2025-07-16); last push 2025-10-03 (H). Self-hosting still works.
- **(a) Process:** Go `plandex` (alias `pdx`); server `plandex-server` (Docker or local) (M).
- **(b) Config:** `~/.plandex-home-v2/` (`auth.json`, `accounts.json`, `cache/`); project `.plandex-v2/` (H, `app/cli/fs/fs.go`).
- **(c)–(e):** no hooks and no notifications (H, repo tree has no notify/bell code in the CLI).
- **(f) State:** plans live server-side (Postgres).
- **(g) Fallback:** process lifetime plus CPU, and network activity to the server. **Recommendation:** best-effort support only.

### 3.11 OpenHands CLI

- **Version / status:** PyPI `openhands` 1.16.0 (2026-05-08), repo `OpenHands/OpenHands-CLI` (pushed 2026-10-12). SDK `software-agent-sdk` v1.54.0 (H).
- **(a) Process:** console scripts `openhands = openhands_cli.entrypoint:main` and `openhands-acp` (H, pyproject). Installed via uv, so `ps` shows the venv `python3.x` with argv `…/bin/openhands` (M).
- **(b) Config:** `~/.openhands/` (`OPENHANDS_PERSISTENCE_DIR`). Hooks come from the **first existing** of `<cwd>/.openhands/hooks.json` or `~/.openhands/hooks.json` (H, `HookConfig.load`).
- **(c) Events:** `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Stop`, `SessionStart`, `SessionEnd`. Keys may be snake_case or PascalCase, with or without the `{"hooks":{…}}` wrapper. "The hooks format is compatible with Claude Code hooks" (H).

  ```json
  // ~/.openhands/hooks.json
  { "hooks": {
    "SessionStart":     [{ "matcher": "*", "hooks": [{ "command": "/Users/USER/.lidless/bin/lidless-hook --agent openhands", "timeout": 5, "async": true }] }],
    "UserPromptSubmit": [{ "matcher": "*", "hooks": [{ "command": "/Users/USER/.lidless/bin/lidless-hook --agent openhands", "timeout": 5, "async": true }] }],
    "Stop":             [{ "matcher": "*", "hooks": [{ "command": "/Users/USER/.lidless/bin/lidless-hook --agent openhands", "timeout": 5, "async": true }] }],
    "SessionEnd":       [{ "matcher": "*", "hooks": [{ "command": "/Users/USER/.lidless/bin/lidless-hook --agent openhands", "timeout": 5, "async": true }] }]
  } }
  ```
- **(d) Payload:** `event_type`, `tool_name`, `tool_input`, `session_id`, `working_dir` (+ `tool_response`, `message`). Env: `OPENHANDS_EVENT_TYPE`, `OPENHANDS_TOOL_NAME`, `OPENHANDS_PROJECT_DIR`, `OPENHANDS_SESSION_ID` (H).
- **(e) Blocking:** 0 = proceed; 2 = deny; JSON `decision` overrides the exit code; `async` hooks never block (H).
- **(f) State, the best fallback of any agent:** `~/.openhands/conversations/<id>/base_state.json` holds field `execution_status` ∈ `idle | running | paused | waiting_for_confirmation | finished | error | stuck | deleting`, plus `events/event-NNNNN-<id>.json` (H, `locations.py` and `conversation/state.py`).
- **(g) Fallback:** FSEvents on `conversations/*/base_state.json`. `running` = busy; `waiting_for_confirmation` = needs input; `finished`/`idle`/`error` = done. **This also covers the project-hooks shadowing problem.**

### 3.12 Continue CLI (`cn`)

- **Version / status:** `@continuedev/cli` 1.5.47 (published 2026-06-18; no release since). The main repo is active but its releases focus on the VS Code extension (H).
- **(a) Process:** `node …/cn` (bin `dist/cn.js`) (H).
- **(b) Config:** hook loader (H, `hookConfig.ts`) merges, lowest to highest precedence:
  1. `~/.claude/settings.json`
  2. `$CONTINUE_GLOBAL_DIR` or `~/.continue/settings.json`
  3. `.claude/settings.json`
  4. `.continue/settings.json`
  5. `.claude/settings.local.json`
  6. `.continue/settings.local.json`
- **(c) Events (types):** `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`, `UserPromptSubmit`, `SessionStart`, `SessionEnd`, `Stop`, `Notification`, `SubagentStart`, `SubagentStop`, `PreCompact`, `ConfigChange`, `TeammateIdle`, `TaskCompleted`, `WorktreeCreate`, `WorktreeRemove`. These match Claude's schemas "so that any hook written for `claude` works with `cn`".
- **Wired?** **No, not in 1.5.47 or main as of 2026-07-20.** `fireStop`, `fireNotification`, `fireSessionStart` and similar have no call sites outside `src/hooks/`. The published bundle contains `hook_event_name` literals only for the git-ai integration's `PreToolUse`/`PostToolUse` (M/H, sparse clone grep plus npm tarball grep).
- **(f) State:** `~/.continue/sessions/*.json` (L).
- **(g) Fallback:** process heuristics. If Continue ever wires the hooks, Lidless's Claude hooks will start firing from `cn` automatically, so the handler's caller detection must tell `cn` apart from `claude` (parent `node …/cn`).

### 3.13 Kimi Code CLI (Moonshot)

- **Version / status:**
  - **New:** `@moonshot-ai/kimi-code` 2.1.1 (2026-09-24, TypeScript, repo `MoonshotAI/kimi-code`, 7.8k★).
  - **Legacy:** PyPI `kimi-cli` 1.52.0 is "[Archived] Legacy Python Kimi CLI, no longer maintained". The ACP registry still lists `kimi acp` 1.52.0. Migrate with `kimi migrate`.
  - (H)
- **(a) Process:** command `kimi`, `process.title = "kimi-code"` (H, bundle).
- **(b) Config:** `~/.kimi-code/config.toml` (`KIMI_CODE_HOME`); legacy `~/.kimi/config.toml`. `[[hooks]]` entries allow only `event`, `matcher`, `command`, `timeout`; extra keys make the config fail to load (H docs; the source type also has `cwd`/`env`).
- **(c) Events (H, `packages/agent-core-v2/src/features/externalHooks/internal/types.ts`):** `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`, `PermissionResult`, `UserPromptSubmit`, `UserPromptQueued`, `TurnStarted`, `Stop`, `StopFailure`, `Interrupt`, `SessionStart`, `SessionEnd`, `SessionHeartbeat`, `SubagentStart`, `SubagentStop`, `TaskStarted`, `PreCompact`, `PostCompact`, `Notification` (matcher e.g. `task\.completed`, about background tasks).

  ```toml
  # ~/.kimi-code/config.toml
  [[hooks]]
  event = "TurnStarted"
  command = "/Users/USER/.lidless/bin/lidless-hook --agent kimi"
  timeout = 5
  [[hooks]]
  event = "Stop"
  command = "/Users/USER/.lidless/bin/lidless-hook --agent kimi"
  timeout = 5
  [[hooks]]
  event = "StopFailure"
  command = "/Users/USER/.lidless/bin/lidless-hook --agent kimi"
  timeout = 5
  [[hooks]]
  event = "Interrupt"
  command = "/Users/USER/.lidless/bin/lidless-hook --agent kimi"
  timeout = 5
  [[hooks]]
  event = "PermissionRequest"
  command = "/Users/USER/.lidless/bin/lidless-hook --agent kimi"
  timeout = 5
  [[hooks]]
  event = "SessionStart"
  command = "/Users/USER/.lidless/bin/lidless-hook --agent kimi"
  timeout = 5
  [[hooks]]
  event = "SessionEnd"
  command = "/Users/USER/.lidless/bin/lidless-hook --agent kimi"
  timeout = 5
  ```
- **(d) Payload:**
  - base: `hook_event_name`, `session_id`, `session_title`, `client_type` (e.g. `kimi_code_cli`), `cwd`
  - `TurnStarted`: `turn_id`, `origin_kind` (`user|task|system_trigger`), `origin_name`, `prompt`
  - `SessionStart`: `source` (`startup|resume`), `model`, `profile`
  - `SessionEnd` matcher: `exit|archive`
  - `SessionHeartbeat`: `uptime_ms`
  - `TaskStarted`: `task_id`, `description`, `detached`
  - `Interrupt`: `reason`
  - (H)
- **(e) Blocking:** only `PreToolUse`, `Stop` and `UserPromptSubmit`. Exit 2 = block (stderr reason); everything fails open (H).
- **(f) State:** `~/.kimi-code/sessions/session_*/state.json` (`workDir`) + `agents/<id>/wire.jsonl` (M, codeburn). Legacy `~/.kimi/sessions/<hash>/<uuid>/wire.jsonl` uses JSON-RPC `message.type` ∈ `TurnBegin | TurnEnd | CompactionBegin | SubagentEvent | …` (M, peon-ping `kimi.sh`).
- **(g) Fallback:** wire.jsonl tail (`TurnEnd`). `SessionHeartbeat` doubles as a liveness ping.

### 3.14 Mistral Vibe

- **Version / status:** PyPI `mistral-vibe` 2.26.1 (2026-10-09). Hooks have been stable since **2.21.0** (2026-07-17; `enable_experimental_hooks` removed, types renamed) (H, CHANGELOG).
- **(a) Process:** console scripts `vibe`, `vibe-acp`, `vibe-app-server` (H, pyproject); Python via uv.
- **(b) Config:** `~/.vibe/config.toml` and `~/.vibe/hooks.toml` (`VIBE_HOME`); project `./.vibe/hooks.toml` only in trusted folders, and project entries win on `name` clashes (H). Built-in `enable_notifications = true` (default) gives a terminal **bell plus tab title** "Task Complete" or "Action Required" via `TextualNotificationAdapter` (H, source).
- **(c) Types:** `pre_tool` (per tool call, **before the permission prompt**), `post_tool`, `post_agent` ("after an assistant turn with no pending tool calls"). There is no session start or end (H).

  ```toml
  # ~/.vibe/hooks.toml
  [[hooks]]
  name = "lidless-post-agent"
  type = "post_agent"
  command = "/Users/USER/.lidless/bin/lidless-hook --agent vibe --event post_agent"
  timeout = 5.0

  [[hooks]]
  name = "lidless-pre-tool"
  type = "pre_tool"
  command = "/Users/USER/.lidless/bin/lidless-hook --agent vibe --event pre_tool"
  timeout = 5.0
  ```
- **(d) Payload:**
  - all types: `session_id`, `parent_session_id`, `transcript_path`, `cwd`, `hook_event_name`
  - `pre_tool`: `tool_name`, `tool_call_id`, `tool_input`
  - `post_tool`: adds `tool_status` (`success|failure|cancelled`), `tool_output`, `tool_output_text`, `tool_error`, `duration_ms`
  - (H)
- **(e) Blocking:** tool hooks can deny with stdout `{"decision":"deny","reason":…}`. Malformed stdout is a warning, or a deny when `strict = true`. A non-zero exit is a failure, not a block (H).
- **(f) State:** `~/.vibe/logs/session/<…>/meta.json` (+ `messages.jsonl`; sub-agents under `agents/`) (M, codeburn).
- **(g) Fallback:** needs-input = `pre_tool` with no `post_tool` within N s and the process idle. The PTY wrapper can catch BEL and the OSC title "Action Required".

---

## 4. Other agents with meaningful adoption (2026)

Selection basis: the ACP registry (41 agents, `cdn.agentclientprotocol.com/registry/v1/latest/registry.json`), CodeIsland's and peon-ping's supported lists, codeburn's 40+ providers, and 2026 rankings (morphllm, pinggy).

| Agent | Process | Hook config | Turn end / needs input / session | Notes | Conf. |
|---|---|---|---|---|---|
| **Grok Build** (xAI) | native `grok` (npm `@xai-official/grok` 1.0.50; ACP `grok agent stdio`) | `~/.grok/hooks/*.json`, `{"hooks":{Event:[{matcher?,hooks:[{type:"command"\|"http",command,timeout}]}]}}`; **no `matcher` on lifecycle events** | `Stop`, `StopFailure` / `Notification`, `PermissionDenied` / `SessionStart`, `SessionEnd` (+ `UserPromptSubmit`, `PreCompact`, `PostCompact`, `Subagent*`) | payload is **camelCase**: `hookEventName`, `sessionId`, `cwd`, `workspaceRoot`, `toolName`, `toolInput`; env `GROK_HOOK_EVENT`, `GROK_SESSION_ID`; fail-open; also reads `.claude/settings.json` and `.cursor/hooks.json`; sessions `~/.grok/sessions/<cwd>/<uuid>/updates.jsonl` with `sessionUpdate:"turn_completed"` | H (docs.x.ai) / M |
| **Devin CLI** (Cognition) | native `devin` (ACP `devin acp`) | `~/.config/devin/config.json` `"hooks"`; project `.devin/hooks.v1.json`; **also `~/.claude/settings.json` and `~/.claude.json`** | `Stop` / `PermissionRequest` / `SessionStart`, `SessionEnd` (+ `PostCompaction`) | stdin `hook_event_name`, `session_id`, `prompt_id`; env `DEVIN_PROJECT_DIR`; 0 / 2 = block; sessions `~/.local/share/devin/cli/sessions.db` | H |
| **Kilo CLI** | native `kilo`/`kilocode` (7.8.8; ACP `kilo acp`) | OpenCode-style TS plugin `~/.config/kilo/plugins/*.ts` | `session.idle` / `permission.asked`, `question.asked` / `session.created`, `session.deleted`, `session.error`, `session.status` | fork of OpenCode; optional keep-awake `caffeinate -i -w <pid>` | M (peon-ping plugin) |
| **Pi** (`@earendil-works/pi-coding-agent` 1.1.0, moved from `@mariozechner/…`) / **Oh My Pi** (`@oh-my-pi/pi-coding-agent` 18.10.1) | `pi` / `omp` (process.title) | TS extension `~/.pi/agent/extensions/*.ts` / `~/.omp/agent/extensions/*.ts`, `export default (pi) => { pi.on(…) }` | `agent_end` / — / `session_start`, `session_shutdown` (+ `before_agent_start`, `tool_call`, `tool_result`, `session_compact`) | sessions `~/.pi/agent/sessions/`, `~/.omp/agent/sessions/` | M (CodeIsland `codeisland-pi.ts`) |
| **Qoder CLI** (Alibaba) | `node …/qodercli` (`@qoder-ai/qodercli` 1.1.68; ACP `--acp`) | `~/.qoder/settings.json` (CN build: `~/.qoder-cn/`) | Claude events incl. `PermissionRequest`, `Notification` | Claude-compatible | M (CodeIsland) |
| **CodeBuddy Code** (Tencent) | `node …/codebuddy` (`@tencent-ai/codebuddy-code` 2.164.0; bins `codebuddy`, `cbc`) | `~/.codebuddy/settings.json` | Claude events | Claude fork | M |
| **iFlow CLI** | `node …/iflow` (0.5.19, last publish 2026-05) | `~/.iflow/settings.json` | `Stop`, `Notification`, `SessionStart`/`SessionEnd`, `SubagentStop`, `SetUpEnvironment` | Claude-style; looks stale | M (peon-ping) |
| **Rovo Dev CLI** (Atlassian) | `acli rovodev run` | `~/.rovodev/config.yml` → `eventHooks.events[{name, commands[{command}]}]` | `on_complete` / `on_tool_permission` / `on_session_start`, `on_session_end` (+ `on_user_prompt`, `on_tool_start`, `on_tool_end`, `on_error`) | event name only via **argv** (put it in the command); JSON on stdin; hooks are async fire-and-forget; transcript deleted when the hook exits | M (peon-ping; Atlassian blog 2026-01-26) |
| **Hermes Agent** (Nous) | `hermes` | `~/.hermes/config.yaml` `hooks:` map (snake_case) | `post_llm_call` / `pre_approval_request` / `on_session_start`, `on_session_finalize` | **`on_session_end` fires every turn**; hooks need one-time approval; state `~/.hermes/state.db` | M (CodeIsland) |
| **Junie CLI** (JetBrains) | `junie` (`@jetbrains/junie-cli`; ACP `junie --acp=true`) | `~/.junie/config.json` `"hooks"` (project ignored by default) | **only `SessionStart`** documented (sources `startup`, `resume`; 10 s default timeout) | needs fallback | M |
| **Antigravity CLI** (`agy`, Google; replaced consumer Gemini CLI 2026-06-18) | `agy` (closed source) | `~/.gemini/config/hooks.json` as a named-config object; **stdin has no event name**, so pass `--event` in argv | `Stop` / — / — | likely covered with Gemini in the companion report | L/M (CodeIsland) |
| Also seen | Trae CLI (`~/.trae/traecli.yaml`, snake_case events incl. `permission_request`, `notification`), ZCode (`~/.zcode/cli/config.json`, strict 7-event schema), MiniMax Code (`mcode`, plugin hooks), DeepAgents CLI (`~/.deepagents/hooks.json`, events `task.complete`, `input.required`, `permission.request`, `session.start`, `session.end`), ECA, OpenClaw, Command Code, Forge, mux, Codebuff (`~/.config/manicode/`), Letta Code, Stakpak, VT Code, Poolside `pool` | | | | M |

---

## 5. Cross-agent standards

### 5.1 Agent Client Protocol (ACP; Zed, with JetBrains as co-maintainer)

- **What it is:** JSON-RPC 2.0 over the agent's **stdio**, between an editor (client) and an agent subprocess. Protocol v1 (H, agentclientprotocol.com):
  - `session/prompt` → result `{"stopReason": "end_turn" | "max_tokens" | "max_turn_requests" | "refusal" | "cancelled"}`
  - streaming `session/update`, where `sessionUpdate` ∈ `agent_message_chunk`, `agent_thought_chunk`, `tool_call`, `tool_call_update`, `plan`, `usage_update`, `notice`, …
  - agent→client `session/request_permission`
  - `session/cancel`
- **Registry:** live 2026-01-28, stabilized 2026-03-09, 41 agents. Launch commands from `registry.json` are useful **process signatures** for agents started by Zed or JetBrains:

  | Launch command | Agent |
  |---|---|
  | `auggie --acp` | Augment |
  | `cline --acp` | Cline |
  | `droid exec --output-format acp-daemon` | Droid |
  | `gemini --acp` | Gemini |
  | `goose acp` | Goose |
  | `grok agent stdio` | Grok |
  | `kilo acp` | Kilo |
  | `kimi acp` | Kimi |
  | `vibe-acp` | Vibe |
  | `qwen --acp --experimental-skills` | Qwen |
  | `opencode acp` | OpenCode |
  | `devin acp` | Devin |
  | `cursor-agent acp` | Cursor |
  | `junie --acp=true` | Junie |
  | `@qoder-ai/qodercli --acp` | Qoder |
  | `@agentclientprotocol/claude-agent-acp` | Claude adapter |
  | `@agentclientprotocol/codex-acp` | Codex adapter |
  | `amp-acp` | Amp (community) |

  (H)
- **Relevance to Lidless: low as an observation channel.** ACP is a private pipe between the editor and the agent, and a third party cannot attach to it. It would matter only if Lidless itself *hosted* agents (an "ACP client" mode such as `lidless run <agent>`), in which case `stopReason` and `request_permission` give perfect signals. When agents run under ACP their own hook configs still load, so the hooks above still fire. Process detection should treat the `--acp`/`acp` argv as "agent running inside an editor".

### 5.2 AGENTS.md and the Agentic AI Foundation

- AGENTS.md is an instruction file standard, not an event channel. Amp, for example, loads `~/.config/agents/skills` and `~/.agents/skills`. It was donated to the Linux Foundation's Agentic AI Foundation (AAIF) alongside MCP and goose in Dec 2025 (M, from prior knowledge; not re-verified today).
- The only Lidless-relevant use would be instructing agents to run a notify command at the end of every task. That is prompt-level, unreliable and intrusive, so **it is not recommended**.

### 5.3 "Open Plugins" / Agent Plugins spec

- `open-plugins.com` now redirects to **agent-plugins.org**, Spec v1.0.0 "Published". It defines **only skills and MCP servers** and explicitly leaves "commands, hooks, agents, rules, and LSP servers" as client-specific (H).
- Goose says it "follows the Open Plugins hooks specification", but in practice it uses the Claude-shaped `hooks/hooks.json` inside a plugin dir. Cline's SDK discovers `.agents/plugins/*/plugin.json` too.

### 5.4 Hooks convergence and the `AI_AGENT` env convention

- **No formal cross-agent hooks standard exists as of Oct 2026.** A June 2026 survey (codex.danielvaughan.com) calls the convergence "not coordinated" and proposes a "Hook Interoperability Protocol" (M).
- The de facto standard is Claude Code's shape: event names `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`, `SessionEnd`, the `hook_event_name` key, and exit 2 = block.
- **`AI_AGENT` env var:** an emerging convention for "who is the agent", read by `@vercel/detect-agent` 1.2.6. Observed locally as `AI_AGENT=claude-code_2-1-288_harness` in a Claude child. Crush sets `AI_AGENT=crush`. `@vercel/detect-agent` also checks `CLAUDECODE`, `CURSOR_AGENT`, `GEMINI_CLI`, `CODEX_THREAD_ID`/`CODEX_SANDBOX`, `AUGMENT_AGENT`, `OPENCODE=1`, `ANTIGRAVITY_AGENT`, `COPILOT_MODEL` (H, unpacked npm bundle).

---

## 6. Generic notifier projects (prior art, cheap source of exact formats)

| Project | License / activity | Agents covered | Mechanism | Value for Lidless |
|---|---|---|---|---|
| **CodeIsland** (`wxtsky/CodeIsland`) | MIT, Swift macOS app, 2.5k★, pushed 2026-10-11 | 30+: Claude, Codex, Gemini, Antigravity, Cursor, Grok, Qoder (+CN, Work), Trae (+CLI), Factory, CodeBuddy, StepFun, WorkBuddy, Qwen, Copilot, Kimi, Kiro, Hermes, ZCode, MiniMax, Cline, OpenCode, MiMo, Pi, OMP, OpenClaw, DeepSeek Harness, AiWork | `ConfigInstaller.swift` (4.3k lines) merges hooks into each tool's config with `~/.codeisland/codeisland-bridge --source <agent>`; hook → **Unix socket `/tmp/codeisland-<uid>.sock`** (nc fallback); push via **Bark, ntfy, Telegram**, Slack, DingTalk, Feishu or WeCom; presence policy (screen locked, idle seconds) | **Closest prior art.** Per-agent event lists, timeouts (Qwen in ms, Kiro converted to `timeout_ms`) and format quirks are all in one Swift file. Reuse ideas, or code with MIT attribution. |
| **peon-ping** (`PeonPing/peon-ping`) | MIT, 5k★, pushed 2026-10-06 | Claude, Amp, Gemini, Copilot, Codex, Cursor, OpenCode, Kilo, Kiro (+IDE), Kimi, Windsurf, Antigravity, OpenClaw, Rovo Dev, DeepAgents, omp, Qwen, iFlow, Trae, ECA, Grok | per-agent `adapters/*.sh` normalize to Claude-style "CESP" JSON; **file watchers** for Amp (threads) and Kimi (wire.jsonl), the latter with a LaunchAgent | exact payload mappings for Kiro, Qwen, Rovo, Grok, iFlow and DeepAgents; the Amp/Kimi watcher heuristics |
| **codeburn** (`getagentseal/codeburn`) | — | 45 providers | parses on-disk session stores | `docs/providers/*.md` is the best index of session-file paths and formats (used in §3–4) |
| **code-notify** (`mylee04/code-notify`) | MIT, 288★ | Claude, Codex, Gemini, oh-my-pi | writes hooks; desktop, voice, Slack/Discord | small; little long-tail coverage |
| **ai-agent-notifier** (`DevinoSolutions`) | **AGPL-3.0** (avoid copying code) | Claude, Codex, Gemini, Cursor | toasts plus **ntfy** phone push | ntfy flow reference |
| **agent-notifier skill** (crossoverjie) | — | Claude, Copilot CLI, Cursor, Codex, Aider, OpenCode | hook-driven | — |
| **Vibe Island** (vibeisland.app) | paid, closed | 26 incl. Droid, Qwen, Kimi, Kiro, Amp, Mistral Vibe, Hermes, Pi, Grok, CodeBuddy | notch app | proves demand; no code |
| **Warp `claude-code-warp`** | official | Claude | OSC 777 `warp://cli-agent` JSON | shows the terminal-side signal model (§3.9) |

---

## 7. Recommendations for Lidless

### 7.1 Signal architecture (four tiers, all feeding one normalized event bus)

1. **Tier 1: native hooks** (deterministic). Lidless ships `lidless-hook`, a tiny native Swift CLI inside the app bundle, copied or symlinked to `~/.lidless/bin/lidless-hook`. The path has no spaces and is the same for every agent. Installers write the **literal absolute path**, because Factory, Rovo and others do not expand `~`.

   | Agent | Target | Events |
   |---|---|---|
   | Droid | `~/.factory/hooks.json`, or `settings.json` if no `hooks.json` | `SessionStart`, `UserPromptSubmit`, `Notification`, `Stop`, `SessionEnd` |
   | Qwen | `~/.qwen/settings.json` | + `StopFailure`, `PermissionRequest` |
   | Augment | `~/.augment/settings.json` | timeouts in ms |
   | OpenHands | `~/.openhands/hooks.json` | `async:true` |
   | Kimi Code | `~/.kimi-code/config.toml` | |
   | Mistral Vibe | `~/.vibe/hooks.toml` | |
   | Kiro V3 | `~/.kiro/hooks/lidless.json` | |
   | Goose | `~/.agents/plugins/lidless/hooks/hooks.json` | |
   | Grok | `~/.grok/hooks/lidless.json` | |
   | Devin | rely on `~/.claude/settings.json`, or `~/.config/devin/config.json` | dedupe |
   | Qoder, CodeBuddy, iFlow | `~/.<tool>/settings.json` | |
   | Cline | `~/.cline/hooks/<Event>` | shim scripts |
   | Rovo Dev | `~/.rovodev/config.yml` | event in argv |
   | Hermes | `~/.hermes/config.yaml` | user must approve |
   | Crush | `~/.config/crush/crush.json` | `PreToolUse` heartbeat only |

2. **Tier 2: plugins** for plugin-only agents: Amp (`~/.config/amp/plugins/lidless.ts`), Kilo (`~/.config/kilo/plugins/lidless.ts`), Pi and OMP (`~/.pi|.omp/agent/extensions/lidless.ts`). Each plugin writes one NDJSON line to the Lidless socket directly (Bun and Node both have `node:net`).
3. **Tier 3: session-store watchers** (FSEvents, read-only, debounced):
   - OpenHands `base_state.json` `execution_status`. Best; it also covers shadowed hooks.
   - Amp `threads/T-*.json`
   - Kimi `wire.jsonl`
   - Goose `sessions.db`
   - Crush `.crush/crush.db` (via `projects.json`)
   - Droid `sessions/*.jsonl`
   - Qwen `projects/*/chats/*.jsonl`
   - Vibe `logs/session/*/meta.json`
   - Kiro `sessions/cli/*.jsonl`
   - Cline `data/sessions/*`
   - Warp `warp.sqlite` (`ai_queries`)

   Open SQLite with `file:…?mode=ro` and short-lived connections. Never write, and never hold locks across polls.
4. **Tier 4: process heuristics** (works for anything, including Plandex, Warp, `cn` and Junie):
   - an agent-process registry from `proc_listallpids` + `KERN_PROCARGS2` (verified, §2.6) with the signature table below;
   - CPU-time deltas (`proc_pid_rusage`);
   - live children (tool executions, test runs);
   - `caffeinate` children (Claude, Qwen, Kilo) via `IOPMCopyAssertionsByProcess`;
   - optionally, active TCP to model endpoints.
   - An opt-in **PTY wrapper** (`lidless wrap -- <agent …>`, or shell aliases) can see BEL, OSC 9/777 and title changes from any TUI (Qwen bell, Vibe "Action Required" title, Amp with `AMP_FORCE_BEL=1`, Augment `notificationMode: bell`, Droid `completionSound: bell`).

### 7.2 `lidless-hook` contract (all agents)

- **Invocation:** `lidless-hook --agent <id> [--event <Name>]`. `--event` is required for Rovo Dev, Antigravity, Cline and Vibe, and recommended for Kiro and Crush. The payload is on stdin. Read it with a **1–2 s deadline** and a 1 MiB cap, and tolerate an empty or closed stdin.
- **Behaviour:** parse JSON loosely, accepting `hook_event_name` / `hookEventName` / `event` / `event_type` / `hookName` / argv `--event`. Then add:
  - `agent_detected`: from env markers (§2.6) or the ppid walk; this overrides `--agent` when they disagree, and both are recorded
  - `agent_pid`: the first ancestor matching an agent signature
  - `tty` (via `ttyname` on fd 0 of the ancestor, or `TERM_PROGRAM`, `ITERM_SESSION_ID`, `__CFBundleIdentifier`)
  - `cwd`, a monotonic timestamp, and `raw` (the payload truncated to about 16 KB, with `last_assistant_message`/`assistant_response` capped at about 500 chars for the push body)
- **Transport:** one NDJSON line to the `AF_UNIX` `SOCK_STREAM` socket `~/.lidless/run/hook.sock` (dir `0700`; keep the path short because `sun_path` is ≤ 104 bytes; the server checks the peer uid via `getpeereid`). Connect timeout 50 ms. **If the app is not running, append to `~/.lidless/spool/events.jsonl` with `O_APPEND`** for replay on launch.
- **Exit:** always `exit(0)`, never write to stdout, and log to `~/.lidless/log/hook.log`. Install `signal(SIGPIPE, SIG_IGN)`. Use no Python, jq or bash (macOS has no python3 without the developer tools; peon-ping depends on it).
- **Uninstall marker:** every installed entry contains the unique substring `/.lidless/bin/lidless-hook`, so uninstall and repair can remove exactly Lidless's entries, as CodeIsland's `containsOurHook` does. Back up every file before the first edit (`<file>.lidless-backup-<ts>`). Preserve comments in JSONC, TOML and YAML (use format-preserving editors). Re-validate after writing; if the agent's parser might reject the file, roll back.

### 7.3 Normalization map (raw → Lidless event)

| Lidless event | Raw names |
|---|---|
| `session_start` | `SessionStart`, `agentSpawn`, `session.start` (Amp), `session_start` (Pi), `on_session_start`, `TaskStart`/`agent_start` (Cline), `session.created` (Kilo) |
| `turn_start` (→ busy) | `UserPromptSubmit`, `userPromptSubmit`, `PromptSubmit` (Auggie), `TurnStarted` (Kimi), `agent.start` (Amp), `before_agent_start` (Pi), `pre_llm_call` (Hermes), `on_user_prompt` (Rovo), `prompt_submit`/`TaskResume` (Cline) |
| `activity` (→ busy heartbeat) | `PreToolUse`/`PostToolUse` and equivalents (Crush, Vibe `pre_tool`/`post_tool`, Kiro tool hooks), `SessionHeartbeat` (Kimi) |
| `turn_end` (→ idle; push "finished") | `Stop`/`stop`, `agent.end{status:done}`, `agent_end` (Cline, Pi), `post_agent` (Vibe), `post_llm_call` (Hermes), `on_complete` (Rovo), `session.idle` (Kilo), Augment `Stop{agent_stop_cause:end_turn\|max_iterations}` |
| `turn_error` (→ idle; push "failed") | `StopFailure`, `agent_error`/`TaskError`, `session.error`, `on_error`, `agent.end{status:error}`, Augment `Stop{agent_stop_cause:error}` |
| `turn_cancelled` (→ idle; no push) | `Interrupt` (Kimi), `TaskCancel`/`agent_abort`, `agent.end{status:cancelled}`, Augment `interrupted`, Droid `Notification{idle_prompt}` right after a turn without `Stop` |
| `needs_input` (→ waiting; push "needs you") | `Notification{permission_prompt\|elicitation_dialog}`, `PermissionRequest`, `permission.asked`/`question.asked` (Kilo), `on_tool_permission` (Rovo), `pre_approval_request` (Hermes), OpenHands `execution_status=waiting_for_confirmation` |
| `idle_prompt` (→ idle reminder) | `Notification{idle_prompt}` (Droid, Qwen) |
| `session_end` | `SessionEnd`, `SessionShutdown`/`session_shutdown`, `session.deleted`, `on_session_finalize` (Hermes; **not** `on_session_end`), `session_shutdown` (Pi), process exit |
| `background_done` (info) | Kimi `Notification{task.completed}` |

### 7.4 Busy/idle engine (feeds lid-closed sleep and shutdown decisions)

- A session is **busy** from `turn_start` or `activity` until `turn_end`, `turn_error`, `turn_cancelled` or `needs_input`.
- **Liveness guard:** a session whose `agent_pid` is gone, or whose `procStart` changed, is ended. This defends against stale "busy" states like the 13-hour one already seen in `~/.claude/sessions`.
- **Activity guard:** if busy but no events for `T_quiet` (e.g. 10 min), the agent tree's CPU stays under 1 % over the window, and there are no descendant processes, downgrade to `stale-idle` and log it.
- **Post-turn guard before sleep or shutdown:** after the last `turn_end`, require:
  - all sessions idle for `T_grace` (user setting, default 5–10 min);
  - no agent-descendant processes alive (background shells, dev servers started by the agent);
  - Qwen `background_tasks`/`crons` = 0 when reported;
  - no pending Kimi `TaskStarted` without `task.completed`.
- **Needs-input while the lid is closed:** push to the phone. Whether to then sleep is a product decision: there is no remote approval path yet, but CodeIsland shows one is possible. The suggested default is to sleep after the grace period, because nothing can progress until the user returns.

### 7.5 Agent signature table for the process registry

Match the exe basename **or** argv[0] basename **or** the argv[1] script path:

```
amp|amp.exe → amp          droid → droid            node … /qwen|@qwen-code/qwen-code → qwen
crush → crush               kiro-cli|kiro-cli-chat → kiro (ignore kiro-cli-term = shell integration)
node … /auggie|@augmentcode/auggie → auggie          cline → cline
goose|goosed → goose        (python) … /bin/openhands|openhands-acp → openhands
node … /cn|@continuedev/cli → continue               kimi-code (title) | kimi → kimi
(python) … /bin/vibe|vibe-acp → vibe                 plandex|pdx → plandex
grok → grok   devin → devin   kilo|kilocode → kilo   pi|pi-rpc|omp → pi
node … /qodercli → qoder   codebuddy|cbc → codebuddy   iflow → iflow   junie → junie
acli + argv "rovodev" → rovodev   hermes → hermes   oz → warp-oz   Warp.app/Contents/MacOS/stable → warp (host, not agent)
```

Argv containing `--acp`, ` acp`, `acp-daemon` or `agent stdio` means "running under an editor via ACP".

### 7.6 Rollout order (effort vs. coverage)

1. Hook installers for the Claude-compatible group (Droid, Qwen, Auggie, OpenHands, Devin, Qoder, CodeBuddy, iFlow). One merge routine covers all of them.
2. Kimi TOML, Vibe TOML, Kiro V3 JSON, Grok, Goose plugin, Cline shims.
3. Plugins for Amp, Kilo and Pi.
4. Watchers for OpenHands, Amp, Crush, Warp, and legacy Kimi.
5. The process-heuristic backstop for everything, and the optional PTY wrapper.

Each installer is opt-in per agent, detected by config-dir existence. Do not create `~/.<tool>` for agents that are not installed (CodeIsland's "phantom install" rule).

### 7.7 Testing

For every agent, run a "payload recorder" mode (`lidless-hook --record`) that dumps raw stdin, argv and env to `~/.lidless/recordings/<agent>/<event>-<ts>.json`. Then build the normalizer from recorded fixtures, not from docs. This is how peon-ping found that Rovo pipes stdin and deletes transcripts, and how CodeIsland found that Antigravity omits `hook_event_name` and that Grok rejects matchers.

---

## 8. Risks / unknowns

- **Kiro V3 stdin field names are undocumented.** Pages variously show `hook_event_name: "stop"`, with or without `session_id`/`assistant_response`. Use argv `--event` and record real payloads. 2.x hooks fire only for the agent they live in. V3 `Stop` exit **1** continues the turn, so a crashing hook could cause unwanted continuations.
- **Amp plugins:** unclear whether `PLUGINS=all`, a magic header, or the binary (non-npm) install is still required; the official page no longer says. There is no needs-input signal, and the thread-file format is reverse-engineered.
- **Factory precedence:** docs disagree (`hooks.json` vs `settings.json`). Writing to the wrong file silently does nothing when `hooks.json` exists. Droid's auto-import of Claude hooks may duplicate Lidless entries without the `--agent droid` marker.
- **OpenHands:** project `.openhands/hooks.json` fully shadows the user file. Rely on the `base_state.json` watcher.
- **Continue `cn`:** the hooks loader ships, but events are not fired (as of 1.5.47 and main 2026-07-20). If Continue wires them later, Lidless's Claude hooks will fire from `cn` too.
- **Shared `~/.claude/settings.json`:** Devin, Grok, Cursor and cn run Claude hooks. Payloads differ: Grok uses camelCase, and cn/Devin `transcript_path` points to their own stores. Mis-attribution means wrong notifications ("Claude finished" when Devin did). Mitigate with env and ppid detection and dedupe.
- **Augment `Notification`:** only `notification_type:"info"` was seen in the bundle, with no permission type. Needs-input for Auggie is effectively undetectable except via bell mode and a PTY wrapper. Timeouts are in **ms**, so writing `5` means 5 ms and the hook would be killed.
- **Goose:** no Notification or permission events. Needs-input relies on heuristics.
- **Crush:** only `PreToolUse`. Turn end and needs-input must be inferred, and Crush's own notifications go to macOS, not to Lidless.
- **Warp's built-in agent:** no API. `warp.sqlite` columns and `output_status` values are reverse-engineered by a third party and may change. Reading while Warp writes needs `mode=ro` and tolerance for `SQLITE_BUSY`.
- **Plandex:** effectively abandoned; best-effort only.
- **Version churn:** several of these products ship daily: Amp has a build-hash version, CodeBuddy and Qwen release weekly. Event names have already been renamed (Vibe 2.21: `post_agent_turn` → `post_agent`; Kiro V3 PascalCase; Cline SDK `TaskComplete` → `hookName:"agent_end"`). The installer needs a per-agent minimum-version gate and a "repair" button.
- **Trust prompts:** Grok project hooks, Hermes approval, Vibe trusted folders and Cursor's third-party toggle can each leave a "correctly installed" hook inert. Surface the install state in the UI by checking that a recorded event actually arrived.
- **Security:** the hook binary runs inside every agent with the user's privileges, and it receives prompts and tool inputs. Keep it minimal, signed with ad-hoc signing at minimum, and never forward raw payloads off-device by default. The push notification should carry only a short, user-configurable summary.
- **Process detection limits:** `process.title` can change at runtime. Node agents without titles need argv parsing, and wrappers (npx, bunx, uvx, Homebrew shims) add an intermediate process. `KERN_PROCARGS2` returns env only for same-uid processes, which is fine for Lidless.
- **`caffeinate`-based signals** exist only for Claude, Qwen and opt-in Kilo, and are not a general solution.
- **Not verified on a live install** (nothing is installed on this Mac): every per-agent claim except Claude process facts comes from docs, source, bundles or integrators. Plan a test matrix of real installs before shipping each installer.

---

## 9. Sources

**Official docs**
- Factory: https://docs.factory.com/reference/hooks-reference.md (redirect from docs.factory.ai), https://docs.factory.com/guides/hooks/notifications.md, https://docs.factory.ai/cli/configuration/settings
- Amp: https://ampcode.com/docs/cli/settings, https://ampcode.com/manual/plugin-api, https://ampcode.com/docs/customize/global-plugins-and-skills, https://ampcode.com/news/streaming-json
- Kiro: https://kiro.dev/docs/cli/v3/hooks-migration/, https://kiro.dev/docs/hooks/, https://kiro.dev/docs/hooks/actions/, https://kiro.dev/docs/cli/2x-reference/, https://kiro.dev/changelog/cli/2-13/, https://kiro.dev/changelog/cli/2-28/, https://cli.kiro.dev/install, https://github.com/aws/amazon-q-developer-cli/blob/main/docs/hooks.md
- Goose: https://goose-docs.ai/docs/guides/context-engineering/hooks/, https://goose-docs.ai/blog/2026/05/14/goose-hooks
- Qwen Code: https://qwenlm.github.io/qwen-code-docs/en/users/features/hooks/, https://raw.githubusercontent.com/QwenLM/qwen-code/main/docs/users/configuration/settings.md
- Augment: https://docs.augmentcode.com/cli/hooks.md, https://docs.augmentcode.com/cli/config, https://www.augmentcode.com/changelog/auggie-cli-0-20-0-release-notes
- Cline: https://docs.cline.bot/cline-cli/cli-reference, https://docs.cline.bot/cline-cli/configuration, https://docs.cline.bot/sdk/plugins, https://mintlify.wiki/cline/cline/customization/hooks
- Warp: https://docs.warp.dev/agents/capabilities/agent-notifications.md, https://docs.warp.dev/features/session-management/session-restoration, https://docs.warp.dev/reference/cli/quickstart, https://www.warp.dev/newsroom/2026/2/10/warp-launches-oz-the-orchestration-platform-for-cloud-coding-agents
- Plandex: https://plandex.ai/blog/winding-down
- OpenHands: https://docs.openhands.dev/openhands/usage/customization/hooks.md, https://docs.openhands.dev/sdk/guides/convo-persistence.md
- Kimi: https://www.kimi.com/code/docs/en/kimi-code-cli/customization/hooks.html
- Mistral Vibe: https://docs.mistral.ai/vibe/code/cli/hooks, https://docs.mistral.ai/vibe/code/cli/configuration
- Grok Build: https://docs.x.ai/build/features/hooks
- Devin: https://docs.devin.ai/cli/extensibility/hooks/overview.md
- Junie: https://junie.jetbrains.com/docs/junie-cli-hooks.html
- Cursor: https://cursor.com/docs/reference/third-party-hooks, https://forum.cursor.com/t/no-way-to-opt-out-of-third-party-claude-code-codex-config-loading-the-flag-is-hardcoded/166558
- Rovo Dev: https://www.atlassian.com/blog/developer/streamline-rovo-dev-cli-with-event-hooks, https://support.atlassian.com/rovo/docs/manage-rovo-dev-cli-settings
- ACP: https://agentclientprotocol.com/protocol/prompt-turn, https://agentclientprotocol.com/registry/index, https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json, https://zed.dev/blog/acp-registry
- Agent Plugins: https://agent-plugins.org/agent-builders/components/hooks

**Source code read via `gh api`, raw.githubusercontent or sparse clone**
- `cline/cline`: `sdk/packages/core/src/hooks/hook-file-config.ts`, `sdk/packages/core/src/hooks/subprocess.ts`, `sdk/packages/shared/src/hooks/events.ts`, `sdk/packages/shared/src/storage/paths.ts`, `apps/cli/package.json`
- `continuedev/continue`: `extensions/cli/src/hooks/{types,hookConfig,fireHook,HookService}.ts` (HEAD 2026-07-20)
- `MoonshotAI/kimi-code`: `packages/agent-core-v2/src/features/externalHooks/internal/types.ts`, `docs/en/customization/hooks.md`
- `mistralai/mistral-vibe`: `vibe/core/hooks/models.py`, `vibe/core/plugins/_claude.py`, `vibe/cli/textual_ui/notifications/*`, `pyproject.toml`, `CHANGELOG.md`
- `block/goose`: `crates/goose/src/hooks/mod.rs`, `crates/goose/src/agents/state_machine/ops_stop_hook.rs`
- `charmbracelet/crush`: `docs/hooks/README.md`, `docs/hooks/FUTURE.md`, `internal/agent/notify/notify.go`
- `OpenHands/OpenHands-CLI`: `openhands_cli/setup.py`, `locations.py`, `pyproject.toml`
- `OpenHands/software-agent-sdk`: `openhands/sdk/hooks/config.py`, `conversation/state.py`
- `QwenLM/qwen-code`: `packages/core/src/services/sleepInhibitor.ts`
- `Kilo-Org/kilocode`: `packages/core/src/kilocode/caffeination.ts`
- `plandex-ai/plandex`: `app/cli/fs/fs.go`
- `warpdotdev/claude-code-warp`: `README.md`

**Integrators / prior art**
- https://github.com/wxtsky/CodeIsland (`Sources/CodeIsland/ConfigInstaller.swift`, `Resources/codeisland-pi.ts`, `Sources/CodeIslandCore/PushChannel.swift`, `PushPolicy.swift`, README)
- https://github.com/PeonPing/peon-ping (`adapters/{amp,kiro,qwen,kimi,rovodev,kilo,iflow,grok,deepagents,eca,omp}.sh`, `adapters/kilo/peon-ping.ts`)
- https://github.com/getagentseal/codeburn (`docs/providers/*.md`)
- https://github.com/mylee04/code-notify
- https://github.com/DevinoSolutions/ai-agent-notifier
- https://vibeisland.app
- https://codex.danielvaughan.com/2026/06/25/agent-hook-convergence-codex-cli-claude-code-gemini-cli-kiro-opencode-portable-governance/

**Registries:** `npm view` (versions, bins, optional deps, publish times) for every npm package named above; PyPI JSON for `kimi-cli`, `mistral-vibe`, `openhands`; npm tarballs unpacked and grepped (not executed): `@augmentcode/auggie@0.36.0`, `@moonshot-ai/kimi-code@2.1.1`, `@qwen-code/qwen-code@0.25.1`, `@qoder-ai/qodercli@1.1.68`, `@earendil-works/pi-coding-agent@1.1.0`, `@continuedev/cli@1.5.47`, `@vercel/detect-agent@1.2.6`.

**Verified locally:** `ps -axo pid,ppid,comm,args` (comm = rewritten argv[0]; Claude's `caffeinate -i -t 300` children); `pmset -g assertions` (caffeinate PreventUserIdleSystemSleep owned by Claude children); `research-snippets/agentscan.swift`, compiled with `swiftc -O` and run unprivileged (exe, argv and env of same-user processes via `KERN_PROCARGS2`; `pbi_comm` = `2.1.296` for Claude Code; `AI_AGENT=claude-code_2-1-288_harness`); absence of all long-tail agent config dirs in `$HOME`.
