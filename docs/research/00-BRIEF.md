# 00 — Lidless v1 engineering brief

*Written 2026-10-12 by the lead architect. Inputs: research reports 01–08 in this folder (09-prior-art is missing; its content is covered by 01 §4 and 04 §6), plus additional read-only checks done for this brief (§2). Target machine: macOS 26.6.2 (25G83) arm64, M1 Pro 16 GB, Xcode 26.6, Swift 6.3.3, Claude Code 2.1.296.*

**How to use this document.** It is the single source of truth for implementation agents. Where it disagrees with an individual report, **this brief wins** (the reason is given in §2). Report references look like `R01 §5.4` (report 01, section 5.4).

**Confidence tags** (same as the reports):
- **[H]** high: verified locally, or read in official docs or source code.
- **[M]** medium: an official but indirect source, or a strong inference.
- **[L]** low: unverified; test before relying on it.

---

## 0. Executive summary

| Goal | Verdict | Mechanism (v1) | Confidence |
|---|---|---|---|
| (1) Lid closed while an agent works → Mac stays awake, network stays up | **Feasible. Needs one admin prompt at install.** | The kernel flag `SleepDisabled`, set with `/usr/bin/pmset -a disablesleep 1\|0` through a narrow `sudoers` rule. A root **fail-safe** LaunchDaemon backs it up. We set the flag ("arm") *before* the lid closes, whenever an agent is working. No root-free mechanism exists on battery. | H (kernel source + hands-on reports on 26.x/27.0); Wi-Fi with the lid closed is M (test) |
| (2) Pause other apps while the lid is closed | **Feasible, with strict protection rules.** | Per-app process groups (responsibility API). **Throttle** (`PRIO_DARWIN_BG`) for browsers and chat; **Freeze** (`SIGSTOP` by audit token) for documents, media and games; **Quit** is opt-in and the only mode that frees RAM. **Never pause any app that hosts an agent** (terminal, IDE, AI desktop app, pty-master holder). Write-ahead journal, out-of-process guard, thaw before sleep. | H for the APIs and the reasons for protection; M for the runtime effects (no signals were sent during research) |
| (3) Phone push when an agent finishes or needs input | **Feasible without a paid Apple account.** | **ntfy** (public `ntfy.sh`, or a self-hosted server) is the default channel. Two-way buttons ("Keep awake 1h", "Sleep now", "Shut down") go through a second, HMAC-signed command topic. Events come from **agent hooks** (deterministic), **Claude's session records**, and **process heuristics** as the safety net. | H for the APIs; M for iOS delivery details |
| (4) No agent working (lid closed) → Mac sleeps or shuts down | **Feasible. Default end action: sleep.** | Countdown (5 min after "finished", 10 min after "needs input"). Then thaw apps → clear the flag → wait until the kernel reports `SleepDisabled=No` → `IOPMSleepSystem()`. Polite shutdown (Apple Event to loginwindow) is opt-in, with sleep as the fallback. | H (sleep path); M (shutdown, which other apps can block) |

**Agent-agnostic coverage** uses four tiers that feed one normalized event bus:
1. Native hooks or plugins installed per agent (the authoritative edges).
2. Agent state files (Claude `~/.claude/sessions/<pid>.json`, OpenHands `base_state.json`, …).
3. A generic process registry with evidence sampling: CPU of the whole process tree, child churn, model-API sockets, tty activity, agent-owned power assertions.
4. A stall and liveness guard, so a stale "busy" never keeps the Mac awake forever.

**Nothing in v1 requires a paid Apple Developer ID.** The two things that do — notarized distribution to other people, and native APNs/CloudKit push to a companion iOS app — are deferred. Build from source; sign with the user's existing free "Apple Development" identity when available, so TCC grants stay stable across rebuilds.

---

## 1. Facts that drive the design (verified)

1. **Only `SleepDisabled` stops lid sleep on battery without an external display.**
   - `IOPMrootDomain::privateSleepSystem()` returns `kIOReturnNotPermitted` when `checkSystemSleepEnabled()` is false. That function calls `checkSystemSleepAllowed(0,0)`, which checks `userDisabledAllSleep` first.
   - The lid path (`shouldSleepOnClamshellClosed`) and the AC-change path (`eval_clamshell = true`) both end in `privateSleepSystem`.
   - The `kPowerEventUserDisabledSleep` handler only assigns the flag and starts **no re-evaluation**.
   - [H, read for this brief in `xnu-12377.121.6/iokit/Kernel/IOPMrootDomain.cpp`: `checkSystemSleepAllowed` l.7804, `checkSystemSleepEnabled` l.7914, `privateSleepSystem` l.3025, handler l.8556, AC handler l.8976.]
   - Consequences:
     - The flag also disables the kernel's low-battery and thermal emergency sleeps.
     - It persists across reboot (powerd re-applies it at boot).
     - Clearing it with the lid closed does **not** sleep the Mac. [H, R01 §1–2]
2. **Setting the flag requires root**, through `IOPMSetSystemPowerSetting`. Setting the IORegistry property directly needs a private entitlement, even for root. Assertions (`caffeinate -i/-s`) do not stop lid sleep on battery. [H, R01 §3]
3. **Claude Code already runs `caffeinate -i -t 300` while `busy`.** That assertion only blocks idle sleep; clamshell sleep still happened at 01:29:49 on this Mac. [H, R02 §6.3]
4. **Claude's `~/.claude/sessions/<pid>.json` `status` (`busy|shell|idle|waiting`) can stay stale for hours.** A session stayed `busy` for 13.5 h after its workflow was killed. A "process exists" or "status busy" check is not enough. [H, R02 §4.1]
5. **Freezing the app that holds an agent's pty master stalls the agent.** It happens after ≤ 2 KB of output (XNU `TTMAXHIWAT`), because Node sets TTY stdout to blocking. In VS Code it happens after 100 K unacknowledged characters. On this Mac **every agent and MCP server is "responsible" to Terminal.app** (83 processes). [H source, R06 §3.1]
6. **Hooks can block or loop agents if mishandled.**
   - Exit 2 or JSON `decision:block` on Stop-type events makes Claude, Codex, Droid, Qwen, Goose, Kimi, Devin, Copilot and Cursor (`followup_message`) keep going.
   - Gemini treats any exit code other than 0 or 1 that has text as `deny`.
   - Kiro V3 continues on exit **1**.
   - **Our helper must exit 0 and print nothing**, with two exceptions listed in §4.2. [H, R03 §1, R04 §2.2]
7. **Pid reuse is real.** The pid space wrapped every 2–6 h on this Mac under agent load. Every signal must go through `proc_signal_with_audittoken`. [H, R06 §2.4]
8. **Ad-hoc signatures change on every rebuild** (designated requirement = cdhash). As a result:
   - TCC grants (Automation for shutdown) re-prompt after every rebuild.
   - `SMAppService.daemon` is unreliable.
   - XPC code-signing requirements can't be satisfied.

   The user already has `Apple Development: nguyentomas0949@gmail.com (52L356TDBT)` in the keychain [H, R08 §4].

---

## 2. Cross-check: contradictions found and how they are resolved

| # | Topic | Reports disagree | Resolution (binding) | Evidence |
|---|---|---|---|---|
| C1 | Hook → app transport | R02/R04: Unix **stream** socket + spool. R03/R05: Unix **datagram** socket (R05: drop if the app is down). R08: **file-drop inbox** | **File-drop inbox** (R08 design). The CLI writes `tmp` then `rename(2)` into `~/.lidless/inbox/`; the app watches it with a vnode `DispatchSource` and re-drains every 30 s. It is durable when the app is down or updating, costs 4 ms median end to end, needs no socket path, and can be debugged with `ls`. Datagrams are rejected because `net.local.dgram.maxdgram = 2048` and Stop payloads are larger. | R08 §6.2 measured [H]; R02 §8.1 `sysctl` [H] |
| C2 | Helper path and name | R02: `~/Library/Application Support/Lidless/bin/lidless-hook`. R03/R04/R05: `~/.lidless/bin/lidless-hook`. R08: `Lidless.app/Contents/Helpers/lidless` | **`~/.lidless/bin/lidless-hook`, a *copy* (not a symlink) of `Lidless.app/Contents/Helpers/lidless-hook`.** The app re-copies it at launch when its SHA-256 differs. The path has no spaces, so shell-run hooks need no quoting. The command string never changes, so the Codex trust hash stays valid. It survives app moves and deletion (no "command not found" noise in agent transcripts). Installers write the **literal absolute path** (`/Users/<user>/.lidless/bin/lidless-hook`), because Factory, Rovo and Windsurf do not expand `~`/`$HOME`. | R03 §1, R04 §7.1 [H] |
| C3 | How Claude Code hooks are installed | R02: local **plugin** marketplace. R05/R08: merge into `~/.claude/settings.json` | **Plugin** `lidless@lidless-local`. Cursor CLI/IDE, Devin, Grok, Continue `cn` and VS Code (`chat.useClaudeHooks`) all load hooks from `~/.claude/settings.json`; putting our hook there would make it fire inside other agents with the wrong attribution. With a plugin, Claude Code also does all writes to its own config. **Verified locally:** the `claude plugin marketplace add/list/remove`, `plugin install/uninstall/enable/disable` subcommands exist in the 2.1.296 binary. Running sessions pick the plugin up only after `/reload-plugins` or a restart; the session-record watcher (Tier 2) covers that gap. `settings.json` merge stays as a fallback only for Claude Code versions without the plugin CLI. | R02 §2; R04 §2.1; R05 §3.3; strings of 2.1.296 [H] |
| C4 | Claude hooks: `async` or sync | R05: `"async": true` on everything. R02: sync | **Sync, `timeout: 5`, exec form (`command` + `args`).** The helper takes about 4 ms. Async hooks are killed at `-p` teardown, and `asyncRewake` would wake the model on exit 2. **Verified in the 2.1.296 schema:** `args` ("exec form … spawned directly … no shell"), `async`, `asyncRewake`, `onFailure` ("continue" default; "block" ignored on Stop). Never set `async`, `asyncRewake` or `onFailure`. Exec form also keeps the user's shell rc output out of hook stdout. | strings-2.1.296 (`ap()` schema) [H] |
| C5 | Claude `PermissionRequest` hook | R05: register it, because `Notification` never fires in the VS Code extension (#66482). R02: don't (it is a decision point) | **Don't register it.** Needs-input in the VS Code extension and Desktop comes from the session record (`status:"waiting"`, `waitingFor`), which the SDK path writes (`requires_action → waiting`). That gives the same coverage without touching a decision hook. | R02 §3.4 [M], R05 §3.1 [H] |
| C6 | Gemini hook stdout | R05: print `{}`. R03: print nothing | **Print nothing.** Verified in `packages/core/src/hooks/hookRunner.ts` (main): `textToParse = stdout.trim() \|\| stderr.trim()`; if empty, `output` stays `undefined` and `success = exitCode === 0`. | gh api fetch for this brief [H] |
| C7 | Copilot / VS Code shared `~/.copilot/hooks/` | R03: pure Copilot-CLI format. R05: a mixed `command`+`bash` entry, because the VS Code Local harness "has a different schema" | **Pure Copilot format** (`"version": 1`, lowerCamelCase events, `bash`, `timeoutSec`). VS Code docs now say the Local parser recognizes a Copilot file by its "numeric `version` property and lower camel case events" and "maps Copilot event and command property names to the Local format". One file serves Copilot CLI, Agent Host Copilot sessions and the VS Code Local harness. | code.visualstudio.com/docs/agent-customization/hooks, fetched 2026-10-12 [H]; `bash` mapping [M], verify with the recorder |
| C8 | Codex `notify` payload and constraint | (R03 and R05 agree) | Confirmed. (1) `notify: Option<Vec<String>>` is **one argv array**. (2) Codex appends **one** extra argv with kebab-case JSON `{"type":"agent-turn-complete","thread-id","turn-id","cwd","client"?, "input-messages":[…],"last-assistant-message":…\|null}`. (3) stdin, stdout and stderr are `/dev/null`; Codex spawns and never waits. (4) It is marked `TODO: Remove … when legacy notify support is removed`. **Chain** any existing value. | `codex-rs/hooks/src/legacy_notify.rs`, `core/src/config/mod.rs` (main, fetched for this brief) [H] |
| C9 | Does `disablesleep` work on Apple Silicon / Tahoe? | One blog (pasqualepillitteri.it): "not enough since Ventura". The Sleepless README footnote: "reported to fail on power-source changes" | **It works.** The kernel gate is verified in source (§1 item 1), and hands-on logs exist for 26.3, 26.4 and 27.0 (lidawake, Adrafinil). The AC plug/unplug path re-evaluates the lid but goes through the same gated `privateSleepSystem`, so the flag still blocks it. The Amphetamine failures concern Amphetamine's own mechanism. **Test plan item T3 still covers unplug/replug with the lid closed.** | xnu source [H]; R01 §2.3 [H]; WebSearch 2026-10-12 [M] |
| C10 | Default battery policy | R01 (following lidawake): AC-only by default, battery opt-in | **Battery allowed by default with a 20 % floor**, because the user's stated core use case is "close the lid and the session keeps going", and they are on battery today. Thermal guards, a lid-close chime on battery and the root 7 % hard floor make this safe enough. **Listed as user decision D1.** | user request; R01 §8 |
| C11 | Grace periods | R01: 2 min after finish, 15 min after input. R02: 10–15 min input. R04: 5–10 min. R05: 5 min finish / 30 min input | **Settle 5 s → notify batch 15 s → finish countdown 5 min**. **Needs-input countdown 10 min.** **Stall threshold 20 min.** **Heuristic exit window 5 min.** All are configurable (§5.6). The countdown push carries "Keep awake 1h" and "Sleep now" buttons. | synthesis |
| C12 | End action | All reports: sleep by default. The user asked for "turn off" | **Default: sleep.** Sleep preserves every session (they resume when the lid opens). Shutdown kills interactive sessions and can be **blocked** by Terminal's "Ask before closing" or by unsaved documents, and nobody can answer the dialog behind a closed lid. Shutdown is opt-in with a sleep fallback. **User decision D2.** | R01 §9, R02 §7 |
| C13 | Privileged helper | R01: sudoers now, `SMAppService.daemon` later. R08: avoid `SMAppService.daemon` in v1 | **v1: sudoers drop-in + file-based root LaunchDaemon fail-safe**, installed once with an admin prompt. **v2:** `SMAppService.daemon` XPC helper, once the app is signed with a stable Apple identity. | R01 §5, R08 §5 [H/M] |
| C14 | Cline hook directory | R05: `~/Documents/Cline/Hooks/` (the extension). R04: `~/.cline/hooks/` (CLI SDK search path) | **`~/.cline/hooks/` by default** (CLI; no TCC prompt). `~/Documents/Cline/Hooks/` is opt-in for the VS Code extension: it triggers a Documents TCC prompt, and the user must also enable hooks in Cline's UI. | R04 §3.8, R05 §3.5 |
| C15 | Event name in payload vs argv | Antigravity, Rovo, Cline and some Kiro payloads lack an event name | **The helper argv always carries the event name** (`lidless-hook <agent> <event>`). Payload fields are a secondary source. | R04 §7.2 |
| C16 | Pausing terminal or IDE hosts | R02 reasoned "probably blocks"; R06 proved it from XNU source | **Never pause an agent host** (rule P-A in §6.3). | R06 §3.1 [H] |
| C17 | Socket evidence (R05) vs CPU/transcript evidence (R02) | Different primary heuristics | **Combine them** in an evidence score (§5.4). No single signal is trusted alone. | R02 §4, R05 §5 |
| C18 | `SMAppService` / `UNUserNotificationCenter` with ad-hoc signing | — | `UNUserNotificationCenter` is reachable from an ad-hoc **`.app`** (status `.notDetermined`) but **crashes from a bare executable** (`swift run`); guard on `Bundle.main.bundleURL.pathExtension == "app"`. Delivery is unverified and v1 does not depend on it (the phone path is ntfy). `SMAppService.mainApp` (login item) is expected to work; re-check `status` at every launch. `SMAppService.daemon` is not used in v1. | R08 §5 [H/M] |
| C19 | `NWListener` on Unix sockets | — | It works on macOS 26 (`requiredLocalEndpoint = .unix(path:)`), but **traps or silently fails for paths ≥ 104 bytes**. v1 doesn't use sockets (C1). If one is ever added, put it at `~/.lidless/run/s` and assert `utf8.count < 104`. | R08 §6.3 [H] |

---

## 3. (b) Agent support matrix

### 3.1 Internal event model (binding)

```swift
public enum AgentID: String, Codable, Sendable {
    case claude, codex, gemini, agy, copilot, vscode, cursor, opencode, kilo, aider
    case droid, qwen, auggie, openhands, devin, qoder, codebuddy, iflow, grok, kimi, vibe, kiro, goose
    case cline, windsurf, amp, pi, junie, rovo, hermes, crush, continueCLI, warp, zed, xcode, jetbrains, unknown
}
public enum NormalizedEvent: Sendable, Equatable {
    case sessionStarted
    case turnStarted                      // -> busy
    case activity                         // heartbeat: tool pre/post, Kimi SessionHeartbeat, Cursor postToolUse
    case turnFinished(TurnOutcome)
    case needsInput(NeedsInputKind)
    case idleReminder                     // Claude/Droid/Qwen idle_prompt: "still waiting", never a second push
    case sessionEnded
}
public enum TurnOutcome: String, Codable, Sendable { case completed, interrupted, error, rateLimited, ambiguous }
public enum NeedsInputKind: String, Codable, Sendable { case permission, question, dialog, unknown }
```

`ambiguous` is used for Aider's bell, which fires for both "done" and "confirm". It is treated as idle, and the push says "Aider is waiting for you".

### 3.2 Tiers

| Tier | What it is | Gives |
|---|---|---|
| **T1 native hook/plugin** | Our entry in the agent's own config, calling `lidless-hook` | Precise edges, push content |
| **T2 state file** | Read-only watcher on the agent's own state (Claude `sessions/*.json` + `claude agents --json`, OpenHands `base_state.json`, Codex rollout JSONL, Copilot `session-state/*/events.jsonl`, Claude Cowork `local-agent-mode-sessions/*.json`) | Current state, survives missed hooks |
| **T3 process heuristic** | Process registry (`proc_listallpids` + `KERN_PROCARGS2` signature match) plus evidence sampling (§5.4) | Coverage for hook-less agents; corroboration for everything else |
| **T4 guards** | pid liveness (`kqueue NOTE_EXIT` + start-time match), stall guard, max-duration cap | Stops stale states from keeping the Mac awake |

### 3.3 v1 matrix: agents with installers in v1 (default-on when the agent's config dir exists)

The placeholder `$HOOK` is the literal path `/Users/tomasnguyen/.lidless/bin/lidless-hook`; the installer substitutes `NSHomeDirectory()`. "Shell-run" agents get the suffix `2>/dev/null; exit 0`, so a missing helper can never be read as a block.

| Agent (hosts) | Detection tiers | Config file Lidless writes | Raw → internal events | Notes / caveats |
|---|---|---|---|---|
| **Claude Code** (CLI in any terminal, VS Code ext, JetBrains, Claude.app Code tab) | T1 plugin + **T2 `~/.claude/sessions/<pid>.json`** + `claude agents --json --all` + T3 (caffeinate child, Anthropic sockets 160.79.104.0/23) | `~/.lidless/claude-plugin/` marketplace, installed with the CLI (snippet A) | `SessionStart`→sessionStarted · `UserPromptSubmit`→turnStarted · `Stop`→turnFinished(completed) *candidate* · `StopFailure` (`rate_limit`→rateLimited, else error) · `Notification` {`permission_prompt`→permission, `elicitation_dialog`/`elicitation_url_dialog`→question, `agent_needs_input`→unknown} → needsInput · `idle_prompt`→idleReminder · `SessionEnd`→sessionEnded · record `busy`→working, `waiting`→needsInput(`waitingFor`), `idle`/`shell`→idle | `Stop` is not fired on user interrupt (`busy→idle` with no Stop = interrupted). Another Stop hook (`/goal`) can veto the stop, hence the 5 s settle. Respect `CLAUDE_CONFIG_DIR`. Never read `*.key`, `roster.json` auth fields or the messaging token. Xcode's Claude uses `CodingAssistant/ClaudeAgentConfig` (v1.1). |
| **OpenAI Codex** (CLI, IDE ext, ChatGPT-app Codex mode) | T1 `notify` (no trust needed) + T1 hooks.json (needs a one-time trust step) + T3 | `~/.codex/config.toml` top-level `notify` (snippet B1), `~/.codex/hooks.json` (snippet B2). Respect `$CODEX_HOME` | `notify agent-turn-complete`→turnFinished(completed) · `UserPromptSubmit`→turnStarted · `Stop`→turnFinished(completed) (dedupe with notify by `turn-id`) · `Interrupt`→turnFinished(interrupted) · `PermissionRequest`→needsInput(permission) · `SessionStart`/`SessionEnd` | Hooks are inert until the user approves them in `/hooks` (or the app's review flow). **Never forge `trusted_hash`.** Until then `notify` gives "finished" only. Detect trust read-only by checking for `[hooks.state."…"]` in config.toml. Xcode's Codex uses `CodingAssistant/codex` (v1.1). |
| **Gemini CLI** (paid API and Enterprise users) | T1 + T3 | `~/.gemini/settings.json` → `hooks` (snippet C). Timeouts in **ms** | `SessionStart` · `BeforeAgent`→turnStarted · `AfterAgent`→turnFinished(completed) · `Notification` (`ToolPermission`)→needsInput(permission) · `SessionEnd` | Hooks are synchronous: keep the helper fast. Project hooks need trust; user hooks don't. |
| **Antigravity CLI `agy`** (consumer successor of Gemini CLI, since 2026-06-18) | T1 (Stop only) + T3 | `~/.gemini/config/hooks.json`, top-level key `"lidless"` (snippet D) | `Stop`→turnFinished (`terminationReason`/`fullyIdle`) · busy and needs-input from T3 | Closed source; exit-code semantics undocumented. The `statusLine` chaining for `tool_confirmation_pending` is deferred to v1.1. |
| **GitHub Copilot CLI** + **VS Code Local agent** + VS Code Agent Host Copilot sessions | T1 + T3 (`Code Helper (Plugin)` group) | `~/.copilot/hooks/lidless.json` (own file; snippet E) | `sessionStart` · `userPromptSubmitted`→turnStarted · `agentStop`→turnFinished · `errorOccurred`→turnFinished(error) · `notification` {`permission_prompt`, `elicitation_dialog`}→needsInput · {`agent_idle`}→idleReminder · `sessionEnd`. In VS Code Local the same file maps to `SessionStart`/`UserPromptSubmit`/`Stop` | VS Code Local has **no needs-input event**; the T3 "went quiet" push covers it. The user's VS Code 1.135 bundles the Copilot runtime 1.0.81. |
| **Cursor** (IDE agent + CLI `agent`/`cursor-agent`) | T1 + T3 | `~/.cursor/hooks.json` (snippet F) | `sessionStart` · `beforeSubmitPrompt`→turnStarted · `postToolUse`→activity · `stop` {`completed`→completed, `aborted`→interrupted, `error`→error} · `sessionEnd` | **The CLI with `-p` emits no `stop`; there is no needs-input hook.** Rely on T3. Never register permission hooks (`preToolUse`, `beforeShellExecution`, `beforeMCPExecution`, `beforeReadFile`, `subagentStart`): they **block on invalid JSON**. |
| **opencode** v1 (≥ 1.18.29) and v2 | T1 plugin + T3 | `~/.config/opencode/plugins/lidless.js` (snippet G) | `session.status{busy}`→turnStarted · `session.status{idle}` / `session.idle`→turnFinished · `session.error`→turnFinished(error) · `permission.asked` / `question.asked` / `form.created`→needsInput · `session.created` / `session.deleted` | Child (subagent) sessions emit their own status events: the pid counts as busy while **any** of its sessions is busy. |
| **Aider** | T1 bell + T3 | `~/.aider.conf.yml` (snippet H) | bell→turnFinished(ambiguous) · start and end come from process lifetime | One command only, so **chain** any existing value. The command runs synchronously with no timeout. A repo-level `.aider.conf.yml` overrides ours. |

### 3.4 v1.1: installers (one Claude-compatible merge routine covers most of these)

The formats and exact snippets are in **R04 §3** and **R05 §4.3**. Corrections that bind:
- Always pass the event in argv.
- Write timeouts as **5 s**, except **Augment 5000 ms** and **Kiro 2.x `timeout_ms: 5000`**.
- Give OpenHands `"async": true`.

| Agent | File | Events (→ internal) | Notes |
|---|---|---|---|
| Factory Droid | `~/.factory/hooks.json` if it exists, else the `"hooks"` key of `~/.factory/settings.json` | SessionStart, UserPromptSubmit, Notification, Stop, SessionEnd | On cancel Droid emits `Notification idle_prompt` *instead of* Stop: map that to turnFinished(interrupted) |
| Qwen Code | `~/.qwen/settings.json` | + StopFailure, PermissionRequest | Stop carries `background_tasks`/`crons`: wait while they are non-empty |
| Augment Auggie | `~/.augment/settings.json` | SessionStart, Stop (`agent_stop_cause`), Notification, SessionEnd | **ms timeouts**; no reliable needs-input |
| OpenHands | `~/.openhands/hooks.json` + **T2 `~/.openhands/conversations/*/base_state.json`** | `execution_status`: `running`→working, `waiting_for_confirmation`→needsInput, `finished`/`idle`/`error`→idle | A project `.openhands/hooks.json` shadows the user file, so T2 is primary |
| Devin CLI | `~/.config/devin/config.json` | Claude events | It also reads `~/.claude/settings.json` (harmless with the plugin route) |
| Qoder / CodeBuddy / iFlow | `~/.qoder/settings.json`, `~/.codebuddy/settings.json`, `~/.iflow/settings.json` | Claude events | |
| Grok Build | `~/.grok/hooks/lidless.json` | Stop, StopFailure, Notification, SessionStart, SessionEnd | camelCase payload; no matcher on lifecycle events |
| Kimi Code | `~/.kimi-code/config.toml` `[[hooks]]` | TurnStarted, Stop, StopFailure, Interrupt, PermissionRequest, SessionStart, SessionEnd | Only `event`/`matcher`/`command`/`timeout` are allowed |
| Mistral Vibe | `~/.vibe/hooks.toml` | `post_agent`→turnFinished, `pre_tool`→activity | No session events |
| Kiro V3 | `~/.kiro/hooks/lidless.json` | SessionStart, UserPromptSubmit, Stop | **Exit 1 on Stop continues the turn**, so the helper contract is critical |
| Goose | `~/.agents/plugins/lidless/hooks/hooks.json` + `plugin.json` | SessionStart, UserPromptSubmit, Stop, SessionEnd | The payload key is `event` |
| Cline (CLI) | `~/.cline/hooks/{TaskStart,TaskResume,TaskCancel,TaskComplete,TaskError,UserPromptSubmit,SessionShutdown}` shims | per R04 §3.8 | The shim prints `{"cancel":false}` |
| Windsurf / Devin Desktop | `~/.codeium/windsurf/hooks.json` | `pre_user_prompt`→turnStarted, `post_cascade_response`→turnFinished, `post_run_command`→activity | No needs-input |
| Amp / Kilo / Pi | TS plugin or extension files (R04 §3.1, §4) | `agent.end` / `session.idle` / `agent_end` | Plugins write the inbox by spawning `lidless-hook` |
| Claude in Xcode, Codex in Xcode | `~/Library/Developer/Xcode/CodingAssistant/{ClaudeAgentConfig/settings.json, codex/hooks.json}` | as Claude / Codex | Paths are inferred [M]; `APPLE_CLAUDE_CODE_DANGEROUSLY_BYPASS_HOOKS` may disable them |

### 3.5 Heuristic-only (T3) in v1

Zed agent panel (Zed holds a `PreventUserIdleSystemSleep` activity while generating, default on), JetBrains AI/Junie inside the IDE, Xcode native sessions, the Warp built-in agent, Crush (`PreToolUse` heartbeat optional), Continue `cn`, Plandex, Roo Code (archived), Claude Cowork (T2 `lastActivityAt`), and any unknown CLI that matches nothing.

The push for these is the softer **"agent went quiet (finished or waiting)"**.

### 3.6 Exact snippets the installer writes (v1)

**A. Claude Code plugin** (files under `~/.lidless/claude-plugin/`; the installer then runs the CLI):

`~/.lidless/claude-plugin/.claude-plugin/marketplace.json`
```json
{
  "name": "lidless-local",
  "owner": { "name": "Lidless" },
  "description": "Local marketplace installed by the Lidless menu-bar app",
  "plugins": [ { "name": "lidless", "source": "./plugins/lidless",
                 "description": "Reports agent activity to Lidless. Never blocks Claude." } ]
}
```

`~/.lidless/claude-plugin/plugins/lidless/.claude-plugin/plugin.json`
```json
{ "name": "lidless", "version": "1.0.0",
  "description": "Notifies the Lidless menu-bar app about session start/stop/needs-input. Never blocks.",
  "author": { "name": "Lidless" } }
```

`~/.lidless/claude-plugin/plugins/lidless/hooks/hooks.json`
```json
{
  "description": "Lidless activity reporter (always exit 0, no stdout)",
  "hooks": {
    "SessionStart":     [ { "hooks": [ { "type": "command", "command": "/Users/tomasnguyen/.lidless/bin/lidless-hook", "args": ["claude","SessionStart"],     "timeout": 5 } ] } ],
    "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": "/Users/tomasnguyen/.lidless/bin/lidless-hook", "args": ["claude","UserPromptSubmit"], "timeout": 5 } ] } ],
    "Stop":             [ { "hooks": [ { "type": "command", "command": "/Users/tomasnguyen/.lidless/bin/lidless-hook", "args": ["claude","Stop"],             "timeout": 5 } ] } ],
    "StopFailure":      [ { "hooks": [ { "type": "command", "command": "/Users/tomasnguyen/.lidless/bin/lidless-hook", "args": ["claude","StopFailure"],      "timeout": 5 } ] } ],
    "Notification":     [ { "matcher": "permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input|agent_completed|quota_auto_resume_fired|quota_auto_resume_stale|quota_auto_resume_disabled",
                            "hooks": [ { "type": "command", "command": "/Users/tomasnguyen/.lidless/bin/lidless-hook", "args": ["claude","Notification"],     "timeout": 5 } ] } ],
    "SessionEnd":       [ { "hooks": [ { "type": "command", "command": "/Users/tomasnguyen/.lidless/bin/lidless-hook", "args": ["claude","SessionEnd"],       "timeout": 1 } ] } ]
  }
}
```

Install and uninstall. Use the resolved absolute `claude` path (`~/.local/bin/claude`, else `/bin/zsh -lc 'command -v claude'` once). Run with stdin `/dev/null` and env `DISABLE_AUTOUPDATER=1`.
```bash
claude plugin marketplace add "/Users/tomasnguyen/.lidless/claude-plugin" --scope user --json
claude plugin install lidless@lidless-local --scope user --json
# uninstall
claude plugin uninstall lidless@lidless-local --scope user --json
claude plugin marketplace remove lidless-local --json
```
After installing, tell the user that open sessions pick the plugin up after `/reload-plugins` or a restart (T2 covers them meanwhile).

**Verify on first install** that `claude plugin list --json` shows the plugin enabled, and that a recorded event arrives. The `--json` flags come from R02 [H, docs]; the subcommand names were confirmed in the binary.

**B1. Codex `notify`** in `~/.codex/config.toml`, as a top-level key placed before the first `[table]`:
```toml
notify = ["/Users/tomasnguyen/.lidless/bin/lidless-hook", "codex", "notify"]
```
If the user already had `notify = ["X", "a"]`, write:
```toml
notify = ["/Users/tomasnguyen/.lidless/bin/lidless-hook", "codex", "notify", "--chain", "--", "X", "a"]
```
Save the original in the install manifest; uninstall restores it byte for byte.

**B2. Codex hooks** `~/.codex/hooks.json`. The top level may contain only `description` and `hooks`. Append our groups; never replace the user's.
```json
{
  "description": "Lidless agent-state hooks",
  "hooks": {
    "SessionStart":      [{ "hooks": [{ "type": "command", "command": "/Users/tomasnguyen/.lidless/bin/lidless-hook codex SessionStart 2>/dev/null; exit 0", "timeout": 5 }] }],
    "UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "/Users/tomasnguyen/.lidless/bin/lidless-hook codex UserPromptSubmit 2>/dev/null; exit 0", "timeout": 5 }] }],
    "PermissionRequest": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "/Users/tomasnguyen/.lidless/bin/lidless-hook codex PermissionRequest 2>/dev/null; exit 0", "timeout": 5 }] }],
    "Stop":              [{ "hooks": [{ "type": "command", "command": "/Users/tomasnguyen/.lidless/bin/lidless-hook codex Stop 2>/dev/null; exit 0", "timeout": 5 }] }],
    "Interrupt":         [{ "hooks": [{ "type": "command", "command": "/Users/tomasnguyen/.lidless/bin/lidless-hook codex Interrupt 2>/dev/null; exit 0", "timeout": 1 }] }],
    "SessionEnd":        [{ "hooks": [{ "type": "command", "command": "/Users/tomasnguyen/.lidless/bin/lidless-hook codex SessionEnd 2>/dev/null; exit 0", "timeout": 1 }] }]
  }
}
```

**C. Gemini CLI** `~/.gemini/settings.json`. Merge into `"hooks"` and keep the user's entries. Timeouts are in ms.
```json
{ "hooks": {
  "SessionStart": [{ "hooks": [{ "name": "lidless-session-start", "type": "command", "command": "/Users/tomasnguyen/.lidless/bin/lidless-hook gemini SessionStart 2>/dev/null; exit 0", "timeout": 5000 }] }],
  "BeforeAgent":  [{ "hooks": [{ "name": "lidless-busy",          "type": "command", "command": "/Users/tomasnguyen/.lidless/bin/lidless-hook gemini BeforeAgent 2>/dev/null; exit 0",  "timeout": 5000 }] }],
  "AfterAgent":   [{ "hooks": [{ "name": "lidless-turn-done",     "type": "command", "command": "/Users/tomasnguyen/.lidless/bin/lidless-hook gemini AfterAgent 2>/dev/null; exit 0",   "timeout": 5000 }] }],
  "Notification": [{ "hooks": [{ "name": "lidless-needs-input",   "type": "command", "command": "/Users/tomasnguyen/.lidless/bin/lidless-hook gemini Notification 2>/dev/null; exit 0", "timeout": 5000 }] }],
  "SessionEnd":   [{ "hooks": [{ "name": "lidless-session-end",   "type": "command", "command": "/Users/tomasnguyen/.lidless/bin/lidless-hook gemini SessionEnd 2>/dev/null; exit 0",   "timeout": 5000 }] }]
} }
```

**D. Antigravity** `~/.gemini/config/hooks.json`. Add one top-level key and keep the others. Timeout is in seconds.
```json
{ "lidless": { "Stop": [ { "type": "command", "command": "/Users/tomasnguyen/.lidless/bin/lidless-hook agy Stop 2>/dev/null; exit 0", "timeout": 5 } ] } }
```

**E. Copilot CLI + VS Code Local** `~/.copilot/hooks/lidless.json`. This is our own file, so no merge is needed.
```json
{
  "version": 1,
  "hooks": {
    "sessionStart":        [{ "type": "command", "bash": "/Users/tomasnguyen/.lidless/bin/lidless-hook copilot sessionStart 2>/dev/null; exit 0", "timeoutSec": 5 }],
    "userPromptSubmitted": [{ "type": "command", "bash": "/Users/tomasnguyen/.lidless/bin/lidless-hook copilot userPromptSubmitted 2>/dev/null; exit 0", "timeoutSec": 5 }],
    "agentStop":           [{ "type": "command", "bash": "/Users/tomasnguyen/.lidless/bin/lidless-hook copilot agentStop 2>/dev/null; exit 0", "timeoutSec": 5 }],
    "errorOccurred":       [{ "type": "command", "bash": "/Users/tomasnguyen/.lidless/bin/lidless-hook copilot errorOccurred 2>/dev/null; exit 0", "timeoutSec": 5 }],
    "notification":        [{ "type": "command", "matcher": "permission_prompt|elicitation_dialog|agent_idle|agent_completed",
                              "bash": "/Users/tomasnguyen/.lidless/bin/lidless-hook copilot notification 2>/dev/null; exit 0", "timeoutSec": 5 }],
    "sessionEnd":          [{ "type": "command", "bash": "/Users/tomasnguyen/.lidless/bin/lidless-hook copilot sessionEnd 2>/dev/null; exit 0", "timeoutSec": 5 }]
  }
}
```
The helper tells VS Code Local apart from Copilot CLI by ancestry (`Code Helper (Plugin)` vs `copilot`) and payload casing (`hook_event_name` + PascalCase from VS Code). It relabels the agent as `vscode` when the ancestry says so. **Never register `preToolUse` or `permissionRequest`** here: `preToolUse` fails closed.

**F. Cursor** `~/.cursor/hooks.json`. Keep `"version": 1` and append to the arrays.
```json
{
  "version": 1,
  "hooks": {
    "sessionStart":       [{ "command": "/Users/tomasnguyen/.lidless/bin/lidless-hook cursor sessionStart 2>/dev/null; exit 0", "timeout": 5 }],
    "beforeSubmitPrompt": [{ "command": "/Users/tomasnguyen/.lidless/bin/lidless-hook cursor beforeSubmitPrompt 2>/dev/null; exit 0", "timeout": 5 }],
    "postToolUse":        [{ "command": "/Users/tomasnguyen/.lidless/bin/lidless-hook cursor postToolUse 2>/dev/null; exit 0", "timeout": 5 }],
    "stop":               [{ "command": "/Users/tomasnguyen/.lidless/bin/lidless-hook cursor stop 2>/dev/null; exit 0", "timeout": 5 }],
    "sessionEnd":         [{ "command": "/Users/tomasnguyen/.lidless/bin/lidless-hook cursor sessionEnd 2>/dev/null; exit 0", "timeout": 5 }]
  }
}
```

**G. opencode** `~/.config/opencode/plugins/lidless.js` (one file for v1 and v2):
```js
import { spawn } from "node:child_process"
const HOOK = "/Users/tomasnguyen/.lidless/bin/lidless-hook"
const KEEP = new Set(["session.status","session.idle","session.created","session.deleted","session.error",
                      "permission.asked","permission.replied","question.asked","form.created","form.replied"])
function emit(type, payload) {
  try {
    const p = spawn(HOOK, ["opencode", type], { stdio: ["pipe", "ignore", "ignore"], detached: true })
    p.on("error", () => {}); p.stdin.on("error", () => {})
    p.stdin.end(JSON.stringify({ ...payload, pid: process.pid })); p.unref()
  } catch {}
}
function handle(event, ctx) {
  const t = event?.type
  if (KEEP.has(t)) emit(t, { type: t, properties: event?.properties ?? event?.data ?? null, directory: ctx?.directory ?? null })
}
export default {
  id: "lidless",
  server: async (input) => ({ event: async ({ event }) => handle(event, input) }),          // v1 (>= 1.18.29)
  setup: async (ctx) => {                                                                   // v2
    const ac = new AbortController()
    ;(async () => { for await (const ev of ctx.event.subscribe({ signal: ac.signal })) handle(ev, ctx) })().catch(() => {})
    return () => ac.abort()
  },
}
```
For opencode < 1.18.29, write instead `export const LidlessPlugin = async (input) => ({ event: async ({ event }) => handle(event, input) })`. Kilo (v1.1) uses the same file in `~/.config/kilo/plugins/lidless.js`.

**H. Aider** `~/.aider.conf.yml`. Use a format-preserving edit and keep the user's comments.
```yaml
notifications: true
notifications-command: "/Users/tomasnguyen/.lidless/bin/lidless-hook aider waiting 2>/dev/null; exit 0"
```
If the user had a command `X`, write `"/Users/…/lidless-hook aider waiting --chain -- sh -c 'X' 2>/dev/null; exit 0"`. If they had `notifications: true` with no command, chain to Aider's default (`osascript` notification) so their local alert keeps working.

### 3.7 Installer rules (all agents)

1. **Per-agent opt-in.** The UI shows the diff before writing. Only touch agents whose config dir already exists; never create `~/.<tool>` ("phantom install" rule).
2. **Backup** to `~/.lidless/backups/<agent>/<basename>.<ISO-ts>` before the first edit. Write a temp file in the same dir, `fsync`, then `rename()`. Follow symlinks to their target.
3. **Format-preserving edits.** Never re-serialize with sorted keys.
   - JSON: parse to validate, then splice textually into the specific array.
   - JSONC: comment-aware splice.
   - TOML/YAML: line-oriented splice of one key.
   
   **Re-parse after writing; on failure, roll back from the backup.**
4. **Ownership marker:** every entry contains the substring `/.lidless/bin/lidless-hook`. Uninstall and repair remove only entries that contain it, then drop event arrays that became empty. Files we own outright (`~/.copilot/hooks/lidless.json`, the plugins) are deleted.
5. **Install manifest** `~/.lidless/install-manifest.json`: `{agent, file, sha256Before, sha256After, chainedOriginal?, installedAt, helperVersion}`. At launch, re-verify each entry. If an agent rewrote the file and dropped our entry, show "Repair".
6. **Proof of life:** the UI shows per agent "hook installed / **last event seen at**". "Installed" is not "working" until an event has arrived (trust prompts, workspace trust and `disableAllHooks` can leave a hook inert).
7. **Recorder mode:** `LIDLESS_RECORD=1` makes the helper also copy the raw stdin, argv and allow-listed env to `~/.lidless/recordings/<agent>/<event>-<ts>.json`. Normalizers are unit-tested against recorded fixtures, not against docs.
8. **Never write** `~/.claude/sessions/**`, `.fleetview-heartbeat`, `jobs/**`, `daemon/**`, `settings.local.json`, any `.key` file, or Codex `[hooks.state]`.

---

## 4. The `lidless-hook` helper and the inbox (binding contract)

### 4.1 Invocation

```
lidless-hook <agent> <event> [--chain -- <argv...>]
```
- **Payload:** stdin (read to EOF, `poll` idle limit 300 ms, cap 4 MiB), **or**, when argv after `<event>` (and after any chained argv) ends with a JSON object, that last argv (Codex `notify`).
- **`--chain`:** `posix_spawn` the chained argv plus the payload as the last argv. Use stdio `/dev/null`, `POSIX_SPAWN_SETSID`, and do not wait.

### 4.2 Contract (unit-tested in CI; R08 §10)

- **Always `exit(0)`.** `alarm(2)` + `SIGALRM → _exit(0)`, `signal(SIGPIPE, SIG_IGN)`.
- **stdout is empty**, except:
  - `cursor beforeSubmitPrompt` → `{"continue":true}`
  - `cline *` → `{"cancel":false}`

  Never write to stderr. Diagnostics go to `~/.lidless/log/hook.log` (rotate at 1 MB).
- Darwin-only Swift (`import Darwin`, `import notify`): no Foundation, no Python/jq/bash. Median cost is 4.2 ms (R08 measured).
- Never print `decision`, `continue:false`, `additionalContext`, `systemMessage` or `permissionDecision`.

### 4.3 Inbox file

The file is `~/.lidless/inbox/<19-digit epoch-ns>-<pid>.event`. It is written as `~/.lidless/inbox/.tmp/<name>.tmp` (`O_CREAT|O_EXCL|O_CLOEXEC`, 0600), then `rename(2)`d into place. The directory mode is 0700. After the rename the helper calls `notify_post("dev.lidless.inbox")`.
- **Line 1** is a header the helper builds itself:
  ```json
  {"v":1,"agent":"claude","event":"Stop","ts":1791811783024,"pid":7940,"ppid":7938,"cwd":"/Users/x/proj",
   "env":{"CLAUDE_PID":"96888","CLAUDE_CODE_SESSION_ID":"…","CLAUDE_CODE_ENTRYPOINT":"cli","TERM_PROGRAM":"Apple_Terminal","__CFBundleIdentifier":"com.apple.Terminal"},
   "ancestry":[{"pid":96888,"startSec":1791810323,"startUsec":1234,"exe":"2.1.296","argv0":"claude"}, …]}
  ```
- **The rest** is the agent payload, byte for byte (never re-escaped).
- **`ancestry`:** up to 8 levels via `sysctl({CTL_KERN, KERN_PROC, KERN_PROC_PID, pid})` (works through root-owned `login`). `argv0` is read with a reused 16 KiB `KERN_PROCARGS2` buffer, argv only. This is what binds an event to a live agent pid.
- **Env allow-list** (nothing else, ever):
  - Claude: `CLAUDE_PID`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_EXECPATH`, `CLAUDE_CONFIG_DIR`, `CLAUDE_PROJECT_DIR`
  - Cursor, Codex, Gemini, Copilot: `CURSOR_VERSION`, `CURSOR_PROJECT_DIR`, `CODEX_HOME`, `GEMINI_SESSION_ID`, `GEMINI_CWD`, `COPILOT_HOME`
  - Others: `AI_AGENT`, `FACTORY_PROJECT_DIR`, `QWEN_PROJECT_DIR`, `AUGMENT_CONVERSATION_ID`, `DEVIN_PROJECT_DIR`, `GROK_SESSION_ID`, `OPENHANDS_SESSION_ID`, `CRUSH_SESSION_ID`
  - Host: `TERM_PROGRAM`, `__CFBundleIdentifier`, `TMUX`, `ITERM_SESSION_ID`
  - **Never** `CLAUDE_CODE_MESSAGING_TOKEN` or anything matching `/TOKEN|KEY|SECRET|PASSWORD/`.
- **Sandbox fallback:** if `~/.lidless/inbox` is not writable (an agent sandbox), write to `$(confstr _CS_DARWIN_USER_TEMP_DIR)/dev.lidless/inbox/`. The app watches both.
- **Back-pressure:** if the inbox holds more than 5,000 files (app gone for days), the helper drops the event and exits 0.

### 4.4 App side

`EventInbox.watch()` (R08 §6.6, compiled in the nonisolated core library) works like this:
- A vnode `DispatchSource` on an `O_EVTONLY` fd, plus a 30 s safety re-drain and a drain at launch.
- Each file is parsed and then deleted; failures go to `inbox/bad/`.
- Garbage-collect `bad/` and `.tmp/` entries older than 24 h.
- Payloads are untrusted input: cap fields, ignore unknown keys.
- **Never act destructively (sleep or shutdown) on a single event.** Corroborate with state (any same-user process can drop a file).

**Attribution and dedupe.** The agent label comes from env markers first (for example, `CURSOR_VERSION` set → `cursor`), then the ancestry signature (§5.3), then argv. Dedupe key: `(agent, sessionKey, normalizedEvent, ±2 s)`. Codex `notify` and the Codex `Stop` hook for the same `turn-id` collapse into one.

---

## 5. (c) Session state model

### 5.1 Entities

```swift
struct SessionKey: Hashable, Sendable { let agent: AgentID; let id: String }
// id = session_id | thread-id | conversation_id | taskId | trajectory_id ; fallback "pid:<pid>:<startSec>.<usec>"
struct AgentSession {
    var key: SessionKey
    var agentPID: pid_t?;  var pidStart: timeval?        // bound from ancestry / CLAUDE_PID / record.pid
    var host: HostApp?                                    // Terminal, iTerm2, VS Code, Cursor, Claude.app … (from __CFBundleIdentifier / ancestry)
    var cwd: String?; var title: String?
    var state: SessionState
    var turnStartedAt: Date?; var lastHookAt: Date?; var lastProgressAt: Date?
    var tiers: Set<Tier>                                  // which tiers have seen it
}
enum SessionState: Sendable {
    case working(since: Date)
    case settling(until: Date)           // turnFinished seen, waiting 5 s for a continuation
    case waiting(kind: NeedsInputKind, since: Date)
    case idle(since: Date, outcome: TurnOutcome?)
    case stalled(since: Date)            // claims busy, no progress ≥ 20 min
    case ended
}
```

### 5.2 Transition rules (precedence: liveness > state record > hook edges > heuristics)

| Trigger | Transition |
|---|---|
| `turnStarted` hook, Claude record `busy`, opencode `session.status busy`, OpenHands `running`, T3 "working" (§5.4) | → `working` (refresh `lastProgressAt`) |
| `activity` hook | refresh `lastProgressAt` (no state change, except `idle` → `working` for agents without a turnStarted event, e.g. Crush, Auggie) |
| `turnFinished(o)` | → `settling(until: now+5 s)`. Then, if no `turnStarted`/`activity`/record-`busy` arrives → `idle(o)` and emit **FinishedEvent**. For Claude, also require record `status ∈ {idle, shell}` (or the record is missing). If `Stop.background_tasks` contains a running `subagent`/`workflow`/`monitor`/`teammate`, stay `working` (shell-type background tasks are ignored). |
| Claude record `busy → idle` with **no** Stop this turn | → `idle(.interrupted)`; no "finished" push |
| `needsInput(k)`, Claude record `waiting` (+`waitingFor`), OpenHands `waiting_for_confirmation`, bg job `state:"blocked"` | → `waiting(k)`; emit **NeedsInputEvent** once per wait |
| `StopFailure rate_limit` / `quota_auto_resume_*` | → `idle(.rateLimited)` (never keeps the Mac awake) |
| `idleReminder` | no transition; never a second push |
| `sessionEnded`, `NOTE_EXIT` on `agentPID`, start-time mismatch, record deleted | → `ended`; drop after 10 min |
| `working` and **no progress evidence for 20 min** (§5.5) | → `stalled`; push "<title> looks stuck (no activity for 20 min)" once; counts as **not working** |
| Progress evidence returns while `stalled` | → `working` |

### 5.3 Process registry (T3) and the signature table

- **Cheap pass every 5 s** (lid closed) or **15 s** (lid open): `proc_listallpids` + `PROC_PIDT_SHORTBSDINFO` (works for every pid), filtered to `uid == getuid()`. Cost ≈ 0.3 ms.
- For new pids only: `proc_pidpath`, plus `KERN_PROCARGS2` argv into a reused 64 KiB buffer. Cache by `(pid, startSec, startUsec)`.
- **Match on (exe path, argv[0] basename, argv[1] basename), never on `p_comm`.** Claude's `p_comm` is its version string (`2.1.296`). `proc_pidpath` is nil after an auto-update; fall back to argv.

| Agent | Match rule |
|---|---|
| Claude Code | path under `~/.local/share/claude/versions/`, `ClaudeCode.app/Contents/MacOS/claude`, `…/Claude/claude-code/*/claude`, `anthropic.claude-code-*/resources/native-binary/claude`, `CodingAssistant/Agents/Versions/*/claude`, **and** argv0 basename `claude`. Exclude argv0 `ugrep`/`rg` and `claude daemon`, `claude bg-pty-host`, `claude bg-spare` (infrastructure; protected from pausing, but not sessions). |
| Codex | exe basename `codex`; or `node` + argv1 basename `codex`/`codex.js`. `app-server` = IDE/app host |
| Gemini CLI | `node` + argv contains `@google/gemini-cli` or argv1 basename `gemini` (two node processes per session: the child does the work) |
| Antigravity | exe `agy` |
| Copilot CLI | exe `copilot` or argv contains `@github/copilot` |
| Cursor CLI | exe is bundled `node` under `~/.local/share/cursor-agent/versions/*/`, argv0 `agent`/`cursor-agent`, argv ends `/index.js` |
| opencode / kilo | exe `opencode`/`opencode.exe`/`kilo`/`kilocode` |
| Aider | exe basename starts with `python`/`Python` and argv1 basename `aider` or argv contains `-m aider` |
| Long tail | R04 §7.5 table (droid, qwen, auggie, openhands, kimi-code, vibe, kiro-cli-chat, goose, grok, devin, pi/omp, qodercli, codebuddy/cbc, iflow, junie, acli+rovodev, hermes, crush, cn, plandex) |
| IDE hosts | `… Helper (Plugin)` = extension host; VS Code Agent Host = `Code Helper` with env `VSCODE_ESM_ENTRYPOINT=vs/platform/agentHost/node/agentHostMain`; group helpers by the main app pid (all VS Code helpers share bundle id `com.microsoft.VSCode.helper`) |

### 5.4 Evidence sampling (per agent process tree)

Sampled every 5 s while the lid is closed and 15 s while open. A full scan is about 10 ms.

| Evidence | API | Counts as progress when |
|---|---|---|
| **E1 tree CPU** | `proc_pid_rusage(RUSAGE_INFO_V4)` `ri_user_time + ri_system_time` × `mach_timebase_info` (**125/3 on Apple Silicon: the values are ticks, not ns**), summed over the agent and all descendants | ≥ 3 % of one core averaged over 60 s |
| **E2 child churn** | new descendant pids (exec of git, rg, node, test runners; Claude's Bash tool = `zsh -c source …/shell-snapshots/…`) | any new non-infrastructure descendant in 60 s |
| **E3 session-store writes** | FSEvents on `~/.claude/projects/*/<sessionId>.jsonl` **and `<sessionId>/**`** (subagents, workflows), Codex rollouts, Copilot `session-state`, etc. | any write in 60 s. The **main transcript mtime alone is not used**: idle sessions rewrite metadata on wake. |
| **E4 model-API sockets** | `proc_pidinfo(PROC_PIDLISTFDS)` → `PROC_PIDFDSOCKETINFO`, ESTABLISHED TCP to Anthropic `160.79.104.0/23`, `2607:6bc0::/48`, or to IPs resolved every 10 min for `api.openai.com`, `chatgpt.com`, `*.githubcopilot.com`, `api2/api5.cursor.sh`, `generativelanguage.googleapis.com`, `server.self-serve.windsurf.com` | a **new** connection to the set, or a socket count change (existence alone is weak because keep-alive lingering was not measured) |
| **E5 tty activity** | `stat()` on the agent's `/dev/ttysNNN` (from `e_tdev`) | mtime within 30 s |
| **E6 agent assertions** | `IOPMCopyAssertionsByProcess` (0.9 ms); owner = agent, or `caffeinate` whose ppid = agent (Claude, Qwen, Kilo), Zed activity, Codex "Codex is running an active turn" | present (but **never** a lone `"Electron"` assertion: Claude Desktop holds one forever) |

**T3-only agents** (no hooks) are `working` when at least **two** of E1–E6 hold within a sliding 60 s window, sustained for 20 s. They go back to idle after **5 min** with fewer than two.

### 5.5 Stall guard (fixes the "13 h busy" case)

A session in `working` keeps `lastProgressAt` fresh through any hook event or any of E1–E5. If `now - lastProgressAt ≥ 20 min` → `stalled`.

A 40-minute build counts as progress through E1/E2 (CPU in the descendants). A session blocked on network for 20 min with zero CPU is treated as stalled, which is acceptable.

### 5.6 Global aggregation and timers

```
anyWorking   = ∃ session in .working                                         (stalled excluded)
anyWaiting   = ∃ session in .waiting
keepAwakeOverride = until-date set by the phone "Keep awake 1h" or the menu "Keep awake for…"
holdAwake    = anyWorking || keepAwakeOverride > now || (anyWaiting && waitingGrace not expired)
```

| Timer | Default | Range | Purpose |
|---|---|---|---|
| settle | 5 s | fixed | Stop-hook or `/goal` continuations, queued prompts |
| notify batch | 15 s | fixed | N finishes → one push |
| finish countdown (lid closed, nothing working, nothing waiting) | **5 min** | 1–60 min | time to tap "Keep awake 1h"; catches auto-continuations |
| needs-input countdown | **10 min** | 2–120 min | remote approval via Claude Remote Control or SSH; lid open wakes anyway |
| stall | 20 min | 10–120 min | §5.5 |
| T3 exit window | 5 min | 2–30 min | heuristic agents "thinking" |
| disarm with lid open | 2 min | fixed | release the flag when nothing works |

---

## 6. (d) App-pausing design

### 6.1 When

All of the following must hold:
- the lid is closed (`AppleClamshellState == Yes`);
- no external display is online (`CGGetOnlineDisplayList` + `CGDisplayIsBuiltin`);
- there was no user input in the last 60 s (`CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)`);
- `holdAwake` is true;
- a **settle delay of 90 s** has passed since the lid closed.

If nothing is working, Lidless does not pause; it goes to wind-down instead.

**v1 ships in two steps:**
1. **v1.0: Throttle only** (no hangs, nothing to recover).
2. **v1.1: Freeze**, enabled after the spike tests in §12 pass.

### 6.2 Modes

| Mode | API | Use |
|---|---|---|
| **Throttle** | `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)`; undo with `setpriority(…, 0)`; verify with `getpriority` = 1. Re-scan every 30 s for new helpers (launchd-spawned XPC services do not inherit) | Browsers, chat, mail, meetings, creative apps busy at lid close, any app with a download in progress |
| **Freeze** | `proc_signal_with_audittoken(&token, SIGSTOP)` / `SIGCONT`. The token comes from `task_name_for_pid` + `task_info(TASK_AUDIT_TOKEN)`, and its `val[7]` must equal the journaled pidversion. **Never use `SIGTSTP` or raw `kill`, except in the crash handler.** | Documents and productivity, silent media players, games and launchers, "anything else regular" |
| **Quit** (opt-in) | `NSRunningApplication.terminate()`. Only if `proc_get_dirty` = TRACKED && !DIRTY **and** memory pressure ≥ warning (`DispatchSource.makeMemoryPressureSource`). Relaunch on lid open with `NSWorkspace.openApplication(at:configuration:)`, `activates = false` | The only mode that frees RAM |

Defaults by category follow R06 §5.4. The UI says plainly: **"Pausing saves CPU and battery; it does not free memory unless you allow 'Quit when memory is low'."**

### 6.3 Candidates and protection

**Candidates:** `NSWorkspace.shared.runningApplications` that are `activationPolicy == .regular`, `isFinishedLaunching`, and launched before the pause began. Everything else is never touched: `.accessory` and `.prohibited` apps, daemons, anything with a controlling tty, root or other-user processes.

**Decisions are keyed by pid plus audit token, never by bundle id.** Agent-launched headless Chrome shares `com.google.Chrome` with the user's Chrome.

**Group** = `{main} ∪ {p : uid == me && responsibility_get_pid_responsible_for_pid(p) == main}`. The function is resolved via `dlsym(RTLD_DEFAULT, …)` from libquarantine. If it is missing, fall back to the resource coalition (`proc_pidinfo` flavor 20), then to `sysctl` ppid descendants. Put all three behind one `ProcessGrouping` protocol with a self-test at startup.

**An app is protected (whole group untouched) if any of these hold:**

| Rule | Condition |
|---|---|
| **P-A agent host (pty-host protection)** | (1) Any agent process, or any descendant of one, is responsible to the app. **Or** (2) a group member holds the **pty master** of any agent's tty: agent `kinfo_proc.e_tdev` minor == `minor(vst_rdev)` of a member fd whose `PROC_PIDFDVNODEPATHINFO` path is `/dev/ptmx` (R06 §3.2, ~60 ms for 400 pids). **Or** (3) the app is in any agent's ancestor chain (`KERN_PROC` walk). This catches Terminal, iTerm2 (`iTermServer` + main), VS Code / Cursor / Windsurf (whole group: the renderer acks pty flow control), Zed, JetBrains, Xcode, Claude.app and ChatGPT. |
| P-B launched by an agent | the app's main pid has an agent ancestor (Playwright and CDP browsers) |
| P-C IPC peer | Unix-socket peer (`unsi_conn_so` ↔ `soi_so`), loopback TCP peer, or pipe peer with an agent tree. This covers the Claude-in-Chrome native host in Chrome or Arc. |
| P-D listener in use | an agent-tree socket connects to a LISTEN port or a Unix path owned by the app → thaw and protect (also re-checked while paused) |
| P-E automation helpers | an agent tree runs `osascript`, `open`, `shortcuts`, `mcpbridge`, `simctl` or `xcodebuild` → thaw the likely target (Xcode, Simulator, the default browser), or thaw everything if the target is unknown |
| P-F audio | `kAudioProcessPropertyIsRunningOutput` or `…Input` on any member (CoreAudio process objects, macOS 14.2+) |
| P-G download | a member fd ends in `.crdownload`/`.part`/`.download` → Throttle, never Freeze |
| P-H traced | `PROC_FLAG_TRACED` |
| P-I busy at lid close | > 20 % of one core over the last 2 min → Throttle instead of Freeze |
| P-J static never-list | R06 §3.4. Includes: terminals; IDEs and editors (`com.microsoft.VSCode`, `com.todesktop.230313mzl4w4u92`, `dev.zed.Zed`, `com.jetbrains.*`, `com.apple.dt.Xcode`); AI apps (`com.anthropic.claudefordesktop`, `com.openai.chat`); Docker/OrbStack/VMs; Ollama/LM Studio; VPNs; password managers and SSH agents (1Password, Bitwarden, Secretive); security/EDR; remote access; Finder; System Settings; Activity Monitor; Lidless itself. If the iMessage provider is ever enabled, also Messages. |
| P-K user list | per-app "never pause" plus a global "pause nothing" switch |

**Re-checks while paused** run every 10–15 s: rules P-C, P-D, P-E, P-F and new agents. Any match **thaws that app and protects it for the rest of the session**.

**Watchdog:** if an agent claims `working` but its tree CPU has not advanced for 5 min while apps are frozen, thaw everything. We may be the reason it is stuck (undetectable XPC or Apple Event dependency).

### 6.4 Ordering

**Freeze:**
1. Write the journal (fsync).
2. SIGSTOP the main process first.
3. SIGSTOP all members in one tight loop.
4. Re-enumerate the group and stop newcomers, at most 5 rounds.
5. Verify `p_stat == SSTOP` for each member. On a partial failure, thaw the group.

**Thaw:** LIFO (helpers and XPC services first, main last). Do a whole group within one run-loop turn, then remove the group from the journal.

**Before any power action:** thaw everything, wait **3 s**, then sleep or shut down. Frozen apps would delay sleep by 30 s and block logout or shutdown.

### 6.5 Crash recovery (defense in depth)

1. **Journal:** `~/Library/Application Support/Lidless/paused.json` (schema in R06 §4.1). Written **before** every signal or `setpriority`, using an atomic rename and `F_FULLFSYNC`. Identity tuple: `{pid, pidVersion, uniqueID, startSec, startUsec, path, bundleID}` plus `kern.bootsessionuuid`. Thaw a record only if the boot UUID, start time and uniqueID match **and** a fresh audit token has `val[7] == pidVersion`.
2. **In-process handlers:**
   - `applicationWillTerminate` → thaw all.
   - `DispatchSource.makeSignalSource` for SIGTERM, SIGINT, SIGHUP and SIGQUIT → thaw, then exit.
   - A `sigaction` crash handler for SEGV/BUS/ILL/ABRT/TRAP/FPE walks a **preallocated C array** of pids and calls `kill(pid, SIGCONT)`. No allocation and no Swift runtime in the handler.
3. **Out-of-process guard** `Lidless.app/Contents/Helpers/lidless-guard`:
   - Spawned with `posix_spawn` + `POSIX_SPAWN_SETSID`.
   - It watches the app with `kqueue EVFILT_PROC NOTE_EXIT`, an inherited pipe (EOF), and a 30 s heartbeat over that pipe.
   - On trigger it reads the journal, thaws, restores priorities, and exits.
4. **Launch recovery:** every app start (and therefore every login, through `SMAppService.mainApp`) runs the journal recovery first. **Never** blanket-`SIGCONT` all stopped processes: that would resume the user's `^Z` jobs and debuggees.
5. **Thaw triggers:**
   - lid opens; an external display connects; user input;
   - `willSleep`/`kIOMessageSystemWillSleep`, `willPowerOff`, `sessionDidResignActive`;
   - before any Lidless sleep or shutdown;
   - Lidless quits or is turned off;
   - a hard cap of 12 h.
6. **Conflicts:** if App Tamer (`com.stclairsoft.AppTamer`) is running, warn the user. Its launch resumes processes that others stopped.

---

## 7. (e) Power design

### 7.1 Privileged install (one admin prompt, during onboarding with the lid open)

The app writes the two scripts below to `~/Library/Application Support/Lidless/install/` and runs:
```applescript
do shell script "/bin/bash " & quoted form of "/Users/tomasnguyen/Library/Application Support/Lidless/install/install-privileged.sh" & " " & quoted form of "tomasnguyen" & " " & quoted form of "/Users/tomasnguyen/.lidless/run/heartbeat" with administrator privileges
```
(From Swift: `NSAppleScript(source:)?.executeAndReturnError(&err)`. The call runs in-process, so no Automation TCC is involved.)

`install-privileged.sh` is **R01 §5.3 verbatim** (syntax checked with `bash -n`; the plist passed `plutil -lint`; the sudoers line passed `visudo -cf`). It does the following:
- **Sudoers rule.** It validates and installs **`/private/etc/sudoers.d/lidless`** (0440 root:wheel; the name has no dot) containing:
  ```sudoers
  # Installed by Lidless. Delete this file to revoke.
  tomasnguyen ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
  ```
- **Fail-safe script.** It generates `/Library/Application Support/Lidless/lidless-failsafe.sh` (root:wheel 0755; R01 §5.4 verbatim, with `HB` substituted). Each run:
  - exits if the kernel `SleepDisabled` ≠ Yes;
  - otherwise clears the flag when the heartbeat is missing, older than boot, or **older than 150 s**, or when battery ≤ **7 %**;
  - after clearing, runs `pmset sleepnow` if the lid is closed.
- **LaunchDaemon.** It installs `/Library/LaunchDaemons/dev.lidless.failsafe.plist` (`RunAtLoad` + `StartInterval 60`), runs `xattr -c` on it, then `launchctl bootout` and `launchctl bootstrap system`.
- **Validation.** It runs `visudo -c` at the end.

**Health check** (no side effects, run at every launch):
- `sudo -n -l /usr/bin/pmset -a disablesleep 1` exits 0.
- `launchctl print system/dev.lidless.failsafe` succeeds.

If either fails, the menu shows "Closed-lid mode not installed" and Lidless never pauses or relies on staying awake.

**Uninstall** (admin): `pmset -a disablesleep 0; launchctl bootout system/dev.lidless.failsafe; rm -f /Library/LaunchDaemons/dev.lidless.failsafe.plist /private/etc/sudoers.d/lidless; rm -rf "/Library/Application Support/Lidless"; visudo -c`.

**Flagged:** any same-user process can now toggle `SleepDisabled`. The worst case is a Mac kept awake, and the fail-safe bounds it. **v2** moves to an `SMAppService.daemon` XPC helper with `setCodeSigningRequirement`, once the app is signed with a stable Apple identity.

### 7.2 Exact commands and APIs

| Action | Command / API | Root? |
|---|---|---|
| Arm | `/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 1` (argv must match sudoers byte for byte), then poll the kernel `IOPMrootDomain["SleepDisabled"] == true` (≤ 5 s, 100 ms steps) | via sudoers |
| Disarm | `/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0`, then poll for `false` | via sudoers |
| Kernel truth | `IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))` + `IORegistryEntryCreateCFProperty(…,"SleepDisabled"/"AppleClamshellState")`. **Never use `AppleClamshellCausesSleep` or `kClamshellSleepBit`** (stale; they ignore `SleepDisabled`) | no |
| Visibility assertion while armed | `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep, on, "Lidless: agent active", &id)` | no |
| Keep Lidless itself un-napped while armed | `ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Lidless monitoring")` | no |
| Lid edges | `IOServiceAddInterestNotification(port, rootDomain, kIOGeneralInterest, cb, …)`, message `0xE0034100`, **bit 0** = closed (it also fires on AC changes, so compare with the last state), plus a 1 Hz poll of `AppleClamshellState` as backup | no |
| Sleep/wake | `IORegisterForSystemPower`; **always** `IOAllowPowerChange` on `0xE0000270`/`0xE0000280`. Hand-defined constants (R08 §8) | no |
| Panel off on lid close | `/usr/bin/pmset displaysleepnow`, when no external display is online | no [M] |
| Sleep now | `IOPMSleepSystem(IOPMFindPowerManagement(MACH_PORT_NULL))`; retry once on `0xE00002E2`; fallback `/usr/bin/pmset sleepnow` | no (console user) |
| Polite shutdown (opt-in) | Apple Event `kCoreEventClass`/`kAEShutDown` (`'aevt'/'shut'`) to `com.apple.loginwindow` (`osascript -e 'tell application "loginwindow" to «event aevtshut»'`). Needs `NSAppleEventsUsageDescription`, the `com.apple.security.automation.apple-events` entitlement, and Automation consent requested during onboarding via `AEDeterminePermissionToAutomateTarget(…, askUserIfNeeded: true)` | no (TCC) |
| Power/thermal | `IOPSCopyPowerSourcesInfo` (`kIOPSCurrentCapacityKey`, `kIOPSPowerSourceStateKey`, `kIOPSTimeToEmptyKey`), `IOPSGetBatteryWarningLevel()`, `AppleSmartBattery.InstantAmperage < 0` (draining on AC), `ProcessInfo.thermalState`, `notify_get_state("com.apple.system.thermalpressurelevel")`, `ProcessInfo.isLowPowerModeEnabled`, `NWPathMonitor` | no |

### 7.3 Power state machine

```
Disarmed ──(holdAwake && policyAllows && privilegedOK)──▶ Armed
    actions: arm flag; assertion; activity; heartbeat timer (touch ~/.lidless/run/heartbeat every 30 s)
Armed ──(lid-close edge)──▶ ClosedAwake
    actions: displaysleepnow (no ext display); chime if on battery; start SafetyMonitor @15 s; schedule pause (90 s)
ClosedAwake ──(!holdAwake)──▶ Countdown(T = anyWaiting ? 10 min : 5 min)   [push countdown message with buttons]
Countdown ──(holdAwake again | keepAwake cmd)──▶ ClosedAwake
Countdown ──(timer | sleepNow cmd)──▶ WindingDown
ClosedAwake|Countdown ──(SafetyTrip)──▶ WindingDown               [push reason first]
ClosedAwake|Countdown ──(lid-open edge)──▶ Armed                     [thaw all; summary; cancel countdown]
Armed ──(!holdAwake for 2 min, lid open)──▶ Disarmed                 [disarm flag; release assertion]
WindingDown: outbox.drain(≤10 s) → thaw all → sleep 3 s → disarm → wait kernel SleepDisabled==No (≤5 s)
             → release assertion → write resume manifest → IOPMSleepSystem()  (or opt-in shutdown flow)
             → on wake: Disarmed; push "Slept 01:12–07:40" from the outbox
```

- **On launch (reconcile):** if the kernel flag is `Yes` and nothing is working, disarm. Recover the pause journal. Drain the inbox.
- **On `applicationWillTerminate`:** thaw, then disarm.
- **The heartbeat is touched by the same 15 s SafetyMonitor tick that evaluates battery and thermal.** If the policy loop hangs, the root fail-safe sees a stale heartbeat and clears the flag within ≤ 150 + 60 s.

### 7.4 Safety policy (the kernel's own emergency sleeps are disabled while armed)

| Guard | Default | Action |
|---|---|---|
| Battery allowed with lid closed | **Yes (D1)** | if No: wind down whenever the Mac is on battery |
| Battery floor | **20 %** (10–50) | also trips at `IOPSGetBatteryWarningLevel() >= 2`, `timeToEmpty < 25 min`, and when draining on AC below the floor |
| Root hard floor | 7 % | fail-safe script, independent of the app |
| Thermal | `.critical` or pressure ≥ `trapping` → immediately; `.serious` or pressure `heavy` for 60 s → trip | |
| Low Power Mode on battery | warn only (agents keep working, slower) | |
| Network | `NWPathMonitor` unsatisfied for **15 min** → trip (the agent can't reach its API anyway) | |
| Max closed-lid duration | **12 h** (1–24) | trip |
| Bag hint | on battery and lid closed: play `NSSound(named: "Submarine")` once at lid close | |

When a guard trips: push "Lidless put your Mac to sleep: battery 19 % (2 agents still running)" through the outbox, then go to WindingDown.

### 7.5 End action

**Default: sleep** (`hibernatemode 3` and `standby 1` let macOS move into deep standby on its own later).

**Opt-in "Shut down when done" (D2):**
- Allowed only if **no session is `waiting`**; otherwise fall back to sleep.
- Write the resume manifest `~/Library/Application Support/Lidless/resume.json`: `[{agent, sessionId, cwd, title, kind, jobId, host}]`.
- Send `kAEShutDown` to loginwindow. If the Mac is still up 3 min later (Terminal "Ask before closing", unsaved documents), fall back to `IOPMSleepSystem()`; the flag is already cleared.
- At next login, offer "Reopen sessions": open the host terminal with `cd <cwd> && claude --resume <sessionId>`, or `claude attach <id>` for background sessions.
- **No forced `shutdown -h now` in v1.**

---

## 8. (f) Notification design

### 8.1 Providers

- **v1 default: ntfy.** Public `https://ntfy.sh` with **two random 128-bit topics**: notify `lidless_<22 base64url>` and commands `lidless_c_<22 base64url>`. A "Custom ntfy server" option takes a base URL and a `tk_…` token; note in the UI that iOS needs `upstream-base-url: https://ntfy.sh` on the self-hosted server.
- **v1.1:** Telegram bot (two-way, text commands, `getUpdates` long-poll, pairing via `t.me/<bot>?start=<code>`). Pushover (one-way, `encrypted=1`, emergency priority as an escalation channel).
- **Later:** Bark, Home Assistant, generic webhook, email.
- **Not used:** iMessage AppleScript (needs Messages running, which conflicts with pausing), native APNs or CloudKit (paid ADP).
- All providers sit behind one protocol, plus a persistent outbox:

```swift
protocol NotificationProvider: Sendable {
    var id: String { get }
    var capabilities: ProviderCapabilities { get }          // actionButtons, inboundCommands, replaceInPlace, e2ee
    func validate() async throws                              // onboarding "Send test"
    func send(_ n: OutgoingNotification) async throws(DeliveryError)   // .retryable(after:) / .permanent(String)
    func commands() -> AsyncStream<RemoteCommand>?           // nil for one-way providers
}
```

### 8.2 Publishing (ntfy JSON to the root URL)

```http
POST https://ntfy.sh/
Content-Type: application/json

{"topic":"<notifyTopic>","title":"All agents done, sleeping in 5 min","priority":3,"tags":["zzz"],
 "message":"api (Claude Code, 42m), web (Codex, 18m) finished.","sequence_id":"lidless-countdown",
 "actions":[
  {"action":"http","label":"Keep awake 1h","url":"https://ntfy.sh/<cmdTopic>","method":"POST","headers":{"X-Firebase":"no"},"body":"<signed keepawake 3600>","clear":true},
  {"action":"http","label":"Sleep now","url":"https://ntfy.sh/<cmdTopic>","method":"POST","headers":{"X-Firebase":"no"},"body":"<signed sleep>","clear":true}]}
```

- Success means HTTP 200 **and** a JSON body with an `id`, which catches captive portals.
- **Never** send `X-Firebase: no` on notify-topic messages (it kills iOS push).
- At most 3 actions per message.
- On iOS, tapping an action **opens the ntfy app** before it POSTs; there is no `clear`, update or delete. So send the countdown once; don't update it.

### 8.3 Command channel

**Subscription:** `GET https://ntfy.sh/<cmdTopic>/json?since=<lastId>` (first run: `since=<now-120>`), streamed with `URLSession.bytes(for:)`.
- An app-level watchdog fires after **100 s** with no line (keepalive is 45 s). URLSession timeouts do not fire mid-stream; verified in R07.
- Reconnect with full-jitter backoff 5–300 s, at least 60 s after a 429, and immediately on wake or when `NWPathMonitor` becomes satisfied. Persist `lastId`.

**Command body**, minted on the Mac:
```json
{"v":1,"cmd":"sleep","arg":null,"nonce":"<12 chars>","exp":1791815325,"sv":42,"sig":"<base64 HMAC-SHA256(key, v|cmd|arg|nonce|exp|sv)>"}
```
`cmd` ∈ `keepawake` (arg seconds), `sleep`, `shutdown` (only if shutdown is enabled).

**Execute only if:**
- the signature is valid;
- `exp ≥ now` (button TTL: countdown 30 min, needs-input 2 h);
- the nonce is unseen (keep nonces until expiry; ntfy replays the **whole 12 h cache** when `since=` names an unknown id);
- for `sleep`/`shutdown`: `sv == currentStateVersion`, i.e. no agent became busy since the command was minted. Otherwise push "Ignored: Codex in web is busy again".

`shutdown` additionally publishes "Shutting down in 60 s" and acts after 60 s. Never accept GET-triggered commands.

### 8.4 Message templates (Basic detail level, the default)

| Kind | ntfy priority | Title | Body | Buttons |
|---|---|---|---|---|
| finished | 3 | `{Agent} finished · {project}` | `Worked {duration} ({host}). {n} agents still running.` | — |
| needs input | 4 | `{Agent} needs your input · {project}` | `{permission/question text, or "Waiting for permission"} since {hh:mm}. Mac stays awake until {hh:mm}.` | Keep awake 1h, Sleep now |
| countdown | 3 | `All agents done, sleeping in {m} min` | `Finished: {project} ({Agent}, {dur}), …` | Keep awake 1h, Sleep now[, Shut down] |
| went quiet (T3 only) | 3 | `{Agent} went quiet · {project}` | `Finished or waiting for you. Mac sleeps in {m} min.` | Keep awake 1h, Sleep now |
| stalled | 3 | `{Agent} looks stuck · {project}` | `No activity for 20 min. It no longer keeps your Mac awake.` | Keep awake 1h |
| safety trip | 4 | `Lidless is putting your Mac to sleep` | `{reason}: battery 19 % / too hot / offline 15 min. {n} agents were still running.` | — |
| asleep (delivered after wake) | 2 | `Mac slept {hh:mm}–{hh:mm}` | `After all agents finished. Battery {p} %.` | — |

- `{Agent}` is the display name (Claude Code, Codex, Gemini CLI, Antigravity, Copilot, Cursor, opencode, Aider, …).
- `{project}` is the basename of the session's *current* cwd (for Claude, the last transcript entry's `cwd`; the record's cwd is the launch cwd).
- `{host}` comes from `__CFBundleIdentifier`/ancestry.
- **Title** source order for Claude: `custom-title` → `agent-name` → `ai-title` → record `name` if `nameSource ∈ {user, peer, auto}` → cwd basename.
- **Detail levels:**
  - Private: "An agent finished".
  - **Basic** (default).
  - Detailed (opt-in): adds ≤ 140 chars of `last_assistant_message` / `last-assistant-message` / `prompt_response`, after stripping ANSI, reducing paths to basenames, redacting `sk-…`, `ghp_…`, `xox?-…`, `AKIA…`, `-----BEGIN` and long hex/base64. Show a warning when Detailed is used on public ntfy.sh (content passes through FCM and APNs).

### 8.5 Policy

- **Presence gating:** push only when **away** (lid closed, screen locked, or no user input ≥ 5 min). There is an "always" toggle.
- **Coalescing:** 15 s batch; one needs-input push per session per wait, plus one reminder after 10 min; a global bucket of 6 per 10 min; overflow goes into a digest. If everything is idle when a batch flushes, send only the countdown message.
- **Outbox** `~/Library/Application Support/Lidless/outbox.json`:
  - TTLs: finished 6 h, needs-input until the state changes (max 2 h), countdown until it ends, asleep 12 h, warning 30 min.
  - Retries with exponential full-jitter backoff (2 s → 5 min). No retries on 400/401/403.
  - Drain on enqueue, path-satisfied, wake and a 60 s timer, and **before every Lidless-initiated sleep (≤ 10 s)**.
- **Quiet hours:** optional, default off. Downgrade to priority 2 and never drop.
- **Claude Remote Control overlap:** a toggle, "Don't push for Claude sessions with Remote Control connected" (record `bridgeSessionId` present). Default off.

### 8.6 Onboarding (one tap proves everything)

1. Generate the topics and the HMAC key.
2. Show App Store and Play Store QR codes.
3. Subscribe:
   - **iPhone:** a big monospace topic with a "Copy" button (Universal Clipboard). The ntfy iOS app has **no URL scheme**, so no QR here.
   - **Android:** a QR for `ntfy://ntfy.sh/<topic>?display=Lidless`.
4. "Send test": a message with a signed **Confirm** button. When the Mac's stream receives it, show "Phone paired, two-way works".

**Secrets** (topics, HMAC key, tokens) are stored in `~/Library/Application Support/Lidless/secrets.json` (0600). Keychain item ACLs bind to the code signature and would re-prompt after every ad-hoc rebuild. Move to Keychain once signing is stable.

---

## 9. (g) Packaging, IPC and build layout

### 9.1 Repository (SwiftPM only; no .xcodeproj)

```
lidless/
├── Package.swift
├── Sources/
│   ├── LidlessCore/                 # nonisolated, testable; Foundation+IOKit+libproc+CoreAudio+Network; no SwiftUI
│   │   ├── Events/      AgentEvent.swift, EventInbox.swift, Normalizer+<Agent>.swift, Dedupe.swift
│   │   ├── Sessions/    SessionEngine.swift, ClaudeSessionsWatcher.swift, ClaudeAgentsPoller.swift, StateFileWatchers.swift
│   │   ├── Processes/   ProcessScanner.swift, AgentMatcher.swift, EvidenceSampler.swift, PtyMap.swift, Grouping.swift
│   │   ├── Power/       RootDomain.swift, SleepControl.swift, ClamshellObserver.swift, SystemPowerObserver.swift,
│   │   │                PowerSnapshot.swift, SafetyMonitor.swift, PowerStateMachine.swift, Shutdown.swift
│   │   ├── Pause/       PauseManager.swift, ProtectionRules.swift, PauseJournal.swift, Signaller.swift (audit tokens)
│   │   ├── Notify/      NotificationProvider.swift, NtfyProvider.swift, Outbox.swift, CommandCodec.swift (HMAC), Templates.swift
│   │   ├── Install/     IntegrationInstaller.swift (protocol), ClaudePlugin.swift, Codex.swift, Gemini.swift, Agy.swift,
│   │   │                Copilot.swift, Cursor.swift, OpenCode.swift, Aider.swift, TextualJSONSplice.swift, Manifest.swift,
│   │   │                PrivilegedInstall.swift (+ embedded scripts)
│   │   └── Settings.swift
│   ├── LidlessApp/                  # @main SwiftUI MenuBarExtra(.window); wiring only; defaultIsolation(MainActor)
│   ├── LidlessHook/                 # product "lidless-hook": Darwin-only; contract §4
│   └── LidlessGuard/                # product "lidless-guard": thaws from journal when the app dies
├── Tests/LidlessCoreTests/          # Swift Testing; recorded hook fixtures; spawns the built lidless-hook
├── Resources/ Info.plist, Lidless.entitlements, AppIcon.icns (optional)
└── scripts/ build-app.sh, install.sh
```

```swift
// swift-tools-version: 6.2
import PackageDescription
let strict: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]
let package = Package(
    name: "Lidless",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "LidlessApp",    targets: ["LidlessApp"]),     // renamed to Contents/MacOS/Lidless
        .executable(name: "lidless-hook",  targets: ["LidlessHook"]),
        .executable(name: "lidless-guard", targets: ["LidlessGuard"]),
    ],
    targets: [
        .target(name: "LidlessCore", swiftSettings: strict,
                linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreAudio")]),
        .executableTarget(name: "LidlessApp", dependencies: ["LidlessCore"],
                          swiftSettings: strict + [.defaultIsolation(MainActor.self)]),
        .executableTarget(name: "LidlessHook", dependencies: [], swiftSettings: strict),
        .executableTarget(name: "LidlessGuard", dependencies: [], swiftSettings: strict),
        .testTarget(name: "LidlessCoreTests", dependencies: ["LidlessCore", "LidlessHook"], swiftSettings: strict),
    ]
)
```

This is R08's verified manifest, with the hook product renamed and the guard added [M until built]. **Never name two products `Lidless` and `lidless`**: they clash on case-insensitive APFS (R08 verified).

### 9.2 Bundle and signing

- **Bundle layout:**
  - `Lidless.app/Contents/MacOS/Lidless`
  - `Contents/Helpers/lidless-hook` (identifier `dev.lidless.hook`)
  - `Contents/Helpers/lidless-guard` (identifier `dev.lidless.guard`)
  - `Contents/Info.plist`: R08 §3, plus `NSAppleEventsUsageDescription` = "Lidless asks macOS to shut down when your agents are done (only if you enable it)." `LSUIElement` true, `LSMinimumSystemVersion` 26.0, `CFBundleIdentifier` `dev.lidless.Lidless` (see D5).
  - `Resources/Lidless.entitlements`: `com.apple.security.automation.apple-events = true`. Not sandboxed.
- **`scripts/build-app.sh`** is R08 §4 with these changes:
  - Copy both helpers into `Contents/Helpers/`.
  - Sign inside-out with `--options runtime`, then sign the app with `--entitlements Resources/Lidless.entitlements`.
  - **`SIGN_ID` defaults to the first `Apple Development:` identity** from `security find-identity -v -p codesigning`, else `-` (ad-hoc). The stable designated requirement keeps the Automation TCC grant and the login item across rebuilds.
- **`scripts/install.sh`:**
  - Build, then `ditto` to `~/Applications/Lidless.app` and `open` it.
  - On first launch the app copies `lidless-hook` to `~/.lidless/bin/` (0755) and creates `~/.lidless/{inbox,run,log,backups}` (0700).
  - Upgrades ask the running app to quit through a control event (`lidless-hook lidless quit`), never through `osascript`.
- **Launch at login:** `SMAppService.mainApp.register()` behind a toggle. Read `status` at every launch (`.notFound` before the first registration is normal); re-register if the user opted in and the status is not `.enabled`.
- **Distribution to others** is build-from-source only. Notarization needs a paid Developer ID (flagged; out of scope).

### 9.3 IPC summary

| Path | Mechanism |
|---|---|
| agent hook → app | file-drop inbox `~/.lidless/inbox` (+ temp-dir fallback) + `notify_post("dev.lidless.inbox")` hint |
| app → root | `sudo -n /usr/bin/pmset -a disablesleep 0\|1` (sudoers) |
| root fail-safe ← app | heartbeat file mtime `~/.lidless/run/heartbeat` |
| app ↔ guard | inherited pipe (EOF + heartbeat lines) + `kqueue NOTE_EXIT`; the guard reads `paused.json` |
| app ↔ phone | HTTPS to ntfy (publish + NDJSON stream) |
| app ← Claude state | read-only vnode/FSEvents on `~/.claude/sessions`, `~/.claude/projects`; `claude agents --json --all` every 15 s (lid closed) / 60 s (open) with stdin `/dev/null` |

### 9.4 Swift 6 rules (each one cost a crash in R08's prototype)

- Every closure handed to GCD, IOKit, Network or notify is created in `LidlessCore` (nonisolated) or written `{ @Sendable in … }`. Otherwise it **traps at runtime** under the MainActor default.
- CPU or syscall-heavy async work is `@concurrent`.
- C callbacks use a `@convention(c)` closure + a `final class Box: Sendable` passed via `Unmanaged`.
- `Mutex` (Synchronization) for small shared state.
- Hand-define the IOKit message constants.
- `import notify` for `notify_post`.
- Start monitors in `applicationDidFinishLaunching`, never in a `MenuBarExtra` `.task`.

---

## 10. (h) Risks / unknowns (ranked)

| # | Risk | Likelihood × impact | Mitigation |
|---|---|---|---|
| 1 | **Closed laptop on battery or in a bag overheats or runs flat.** The kernel's own low-battery and thermal sleeps are disabled while armed | M × **High** | App guards (§7.4); the root fail-safe (7 % floor, 150 s heartbeat, boot clear); chime on lid close on battery; 12 h cap; D1 lets the user choose AC-only |
| 2 | **Freezing breaks an agent** (pty back-pressure, undetectable XPC/Apple-Event/pasteboard/file-coordination dependency) → the agent hangs, and the Mac then stays awake for nothing | M × High | Never pause agent hosts (P-A … P-E); Throttle-first rollout; thaw-on-demand re-checks; a "CPU not advancing for 5 min → thaw all" watchdog; spike tests before enabling Freeze |
| 3 | **False "working"** (stale `busy`, Electron assertions, lingering sockets) → the Mac never sleeps | M × M | Stall guard 20 min; evidence needs ≥ 2 signals for T3; agent assertions only when attributed; 12 h cap; "looks stuck" push |
| 4 | **False "finished"** (Stop vetoed by `/goal`, interrupt, subagent still running) → premature sleep | M × Low–M | 5 s settle; Claude record cross-check; `background_tasks` check; 5 min countdown with "Keep awake" button. **Sleep is non-destructive**: work resumes when the lid opens |
| 5 | **A hook breaks an agent** (stdout/exit code read as block → infinite continuation and token burn; or a slow hook) | Low × High | Helper contract + CI test (empty stdout, exit 0, ≤ 50 ms); `2>/dev/null; exit 0` wrapper; exec form for Claude; never register permission/decision hooks; `alarm(2)` |
| 6 | **Config corruption** from editing other tools' files | Low × High | Backups, format-preserving splice, re-parse + rollback, own files where possible, ownership marker, manifest + Repair |
| 7 | **`disablesleep` changes in a macOS update** (undocumented, not in `man pmset`) | Low × High | Health check at launch (set, read back the kernel, clear); re-test after each OS update; it still worked on 27.0 per lidawake (Sep 2026) |
| 8 | **Remote command abuse** (remote sleep or shutdown) | Low × M | HMAC + nonce + expiry + state version; key never leaves the Mac; shutdown has a 60 s delay and is opt-in |
| 9 | **Lid-closed Wi-Fi / network** not proven on this Mac | Low × High | Test T3/T4; `NWPathMonitor` guard; warn when on iPhone Personal Hotspot (`isExpensive`) |
| 10 | **Panel stays backlit** behind the closed lid | M × Low | `pmset displaysleepnow` on lid close (test T5) |
| 11 | **ntfy.sh privacy and availability** (public topics; FCM/APNs carry content; 250 msg/day/IP) | M × Low | Basic detail default; 128-bit topics; self-host option; escalation provider in v1.1 |
| 12 | **Private APIs** (`responsibility_*`, coalition flavor 20, flavor 17) change on macOS 27 | M × M | Grouping fallbacks + startup self-test; Freeze is disabled if the self-test fails |
| 13 | **Ad-hoc signing churn** (TCC re-prompts for shutdown, login item, keychain) | H × Low | Sign with the Apple Development identity; secrets in a 0600 file |
| 14 | **Agent schema churn** (hooks are Preview/EAP in many tools; Codex `notify` is "legacy") | H × M | Recorder fixtures, per-agent min-version gates, "last event seen" UI, T2/T3 fallbacks |
| 15 | **Pid reuse** (wrap every 2–6 h) | H × High if ignored | Audit-token signalling only; journal identity tuple; `(pid, start)` keys everywhere |
| 16 | **Agent sandboxes** deny writes to `~/.lidless/inbox` from hooks | Low–M × M | Temp-dir fallback inbox; T2/T3 still work |
| 17 | **sudoers rule** lets any same-user process keep the Mac awake | Low × Low | Exact-argument rule; fail-safe bounds it; v2 XPC helper |
| 18 | **Shutdown blocked** by Terminal or unsaved documents | H × Low | Sleep fallback after 3 min; shutdown only when no session is waiting |
| 19 | **Name collision** with `github.com/nghialuong/Lidless` (MIT, same purpose) | — | D5 |

**Unknowns to settle on the device** (all need the user present; see §12):
- whether VS Code ext and Desktop Claude sessions write `~/.claude/sessions` records with `waiting`;
- whether VS Code maps the `bash` key in Copilot-format files;
- the opencode v2 event envelope;
- how long agent sockets stay open after a turn;
- `displaysleepnow` with the lid closed;
- unplug/replug with the lid closed;
- `task_name_for_pid` under the hardened runtime.

---

## 11. (i) Decisions that are genuinely the user's

Everything else has a default and a setting.

1. **D1: Closed-lid on battery.** Default: **allowed, stops at 20 %**, with thermal guards and a chime on lid close. Alternative: AC-only (safer for a laptop in a bag).
2. **D2: End action when agents are done.** Default: **sleep** (sessions resume when the lid opens). Alternative: polite shutdown, which closes terminal sessions (they are resumable with `claude --resume`), can be blocked by "unsaved changes" or Terminal's "Ask before closing", and falls back to sleep.
3. **D3: The one-time admin install.** It adds a sudoers rule for exactly `pmset -a disablesleep 0|1` plus a root fail-safe daemon. Without it, goal (1) is impossible on battery, and Lidless only does notifications.
4. **D4: Phone channel and privacy.** Default: **public ntfy.sh** (free, no account; message text passes through ntfy, Google FCM and Apple APNs; Basic detail = agent + folder + duration, no code). Alternatives: a self-hosted ntfy, or Telegram (v1.1).
5. **D5: Name and bundle id.** Keep "Lidless" / `dev.lidless.Lidless`, even though an MIT app with the same name and purpose exists on GitHub. For personal use this is harmless; it matters only if you publish.
6. **D6: Memory.** Allow "Quit idle apps when memory is low"? Default **off**. Freeze and Throttle save CPU and battery but free no RAM; Quit frees RAM but closes apps (clean ones only, relaunched when the lid opens).

---

## 12. Recommendations for Lidless (build order and acceptance)

Order by risk: detection and notifications first, then power, then pausing (the riskiest part).

| Milestone | Scope | Accept when |
|---|---|---|
| **M0 Skeleton** | Package, `build-app.sh` (Apple Development signing auto-detect), MenuBarExtra listing sessions, `~/.lidless` layout, Settings | `swift test` is green; the bundle passes `codesign --verify --deep --strict` |
| **M1 Detection core** | `lidless-hook` (contract tests), EventInbox, Claude T2 watcher + `agents --json` poller, ProcessScanner/AgentMatcher, EvidenceSampler, SessionEngine with all timers, Claude plugin installer | The user's 8 Claude sessions show correctly (≤ 1 working, the others idle). A test prompt produces turnStarted → turnFinished within 5 s. The old 13 h-busy pattern turns into `stalled` after 20 min in a replay test |
| **M2 Phone** | ntfy provider, outbox, command stream + HMAC, onboarding pairing, templates, presence gating | One-tap pairing works. Replayed or forged commands are dropped (unit tests). A finished push arrives within 30 s |
| **M3 Power** | Privileged install + health check, arming, lid observer, SafetyMonitor + heartbeat, wind-down → sleep, reconcile at launch, fail-safe | On-device tests T1–T8 pass (below) |
| **M4 More agents** | Codex (notify + hooks + trust walkthrough), Gemini, agy, Copilot/VS Code, Cursor, opencode, Aider installers, with diff preview, backup, manifest, repair | The recorder captures a real event for each installed agent; uninstall restores files byte for byte |
| **M5 Pausing (Throttle)** | Grouping (responsibility → coalition → ppid), protection rules P-A…P-K, journal, guard, thaw triggers | With 2 Claude sessions in Terminal and the lid closed: Terminal, VS Code and Claude.app are never touched; Arc and Slack are throttled; everything is restored on lid open and after `kill -9` of Lidless |
| **M6 Pausing (Freeze)** | SIGSTOP via audit tokens, ordering, crash handler, App Tamer warning, breathing off | R06 §5.11 spike tests pass: Word/Notes freeze ok; Chrome/Arc no hang dialog after 10 min; Slack reconnects; a 3 KB write to a pty whose master holder is frozen stalls (confirms P-A); logout and sleep with apps frozen are handled |
| **M7 Long tail** | §3.4 installers, T2 watchers (OpenHands, Copilot `events.jsonl`, Codex rollouts), Telegram + Pushover, shutdown opt-in with resume manifest, Xcode `CodingAssistant` installs | per-agent recorder fixtures |

**On-device validation plan** (the user runs these; the research was read-only):
- **T1** Install the privileged parts, then `sudo -n -l /usr/bin/pmset -a disablesleep 1` and `visudo -c`.
- **T2** Arm, then check `pmset -g | head -3` → `SleepDisabled 1` and `ioreg -r -n IOPMrootDomain -d1 | grep SleepDisabled` → `Yes`. Stop the heartbeat and confirm the fail-safe clears the flag within ≤ 3.5 min.
- **T3** Lid closed on battery for 10 min with `ping -i 5 1.1.1.1` logged. No gaps; `pmset -g log | grep -E " (Sleep|Wake|DarkWake) "` shows no sleep. Repeat with **AC unplug and replug while the lid is closed**.
- **T4** With the lid closed, receive an ntfy push and send a command every minute for 30 min.
- **T5** Panel backlight with and without `pmset displaysleepnow` (dark room, look at the hinge).
- **T6** Disarm with the lid closed → no sleep; then `IOPMSleepSystem` → sleeps.
- **T7** The full flow: a Claude prompt → close the lid → finished push → 5 min countdown → sleep → open the lid → the session is intact.
- **T8** Opt-in shutdown with `claude` running in Terminal: observe the block, then the sleep fallback after 3 min.

---

## 13. Sources

- **Reports (this folder):**
  - `01-power-lid-sleep.md` (xnu, PowerManagement, IOKitUser sources; lidawake, Adrafinil, Sleepless, nghialuong/Lidless)
  - `02-claude-code.md` (hooks docs; 2.1.296 binary; local session records)
  - `03-cli-agents-a.md` (Codex, Gemini, agy, Copilot CLI, Cursor CLI, opencode, Aider)
  - `04-cli-agents-b.md` (long tail; CodeIsland, peon-ping, codeburn)
  - `05-ide-agents.md` (Cursor, VS Code harnesses, Codex app, Windsurf, Cline, Zed, JetBrains, Xcode, evidence costs)
  - `06-app-pausing.md` (XNU signal, tty and task-policy source; App Tamer; local probes)
  - `07-phone-notifications.md` (ntfy server/iOS sources, Telegram, Pushover, Apple capability table)
  - `08-swift-build.md` (verified SwiftPM layout, IPC benchmark, ad-hoc signing matrix, Swift 6 pitfalls)
- **Checks done for this brief (2026-10-12):**
  - `apple-oss-distributions/xnu` @ `xnu-12377.121.6` `iokit/Kernel/IOPMrootDomain.cpp`: `checkSystemSleepEnabled` → `checkSystemSleepAllowed(0,0)` checks `userDisabledAllSleep`; `privateSleepSystem` gate; `kPowerEventUserDisabledSleep` handler; AC-change `eval_clamshell`; `checkSystemCanSustainFullWake` only affects display power-on (via `gh api`) [H]
  - `openai/codex` main `codex-rs/hooks/src/legacy_notify.rs` (payload, argv append, null stdio, spawn without wait, removal TODO) and `codex-rs/core/src/config/mod.rs` (`notify: Option<Vec<String>>`) [H]
  - `google-gemini/gemini-cli` main `packages/core/src/hooks/hookRunner.ts` (empty stdout and stderr → no output) [H]
  - https://code.visualstudio.com/docs/agent-customization/hooks and https://code.visualstudio.com/docs/agents/reference/hooks-reference (user `~/.copilot/hooks/*.json`; Copilot-format detection and mapping; `chat.useClaudeHooks` off by default; exit codes; 30 s default timeout) [H]
  - Claude Code 2.1.296 binary strings (`research-snippets/strings-2.1.296.txt`): command-hook schema `args` (exec form), `async`, `asyncRewake`, `onFailure` semantics; `plugin marketplace add/list/remove`, `plugin install/uninstall/enable/disable` [H]
  - Web search for "disablesleep macOS 26 Tahoe lid closed battery" (Sleepless README footnote on power-source changes; a pasqualepillitteri.it blog claim; NoSleep battery-drain report): https://github.com/Aboudjem/Sleepless, https://pasqualepillitteri.it/en/news/779/disable-laptop-sleep-lid-close-ai-agents, https://www.producthunt.com/posts/1229762 [M]
