# Kakureneko — architecture, contracts and work split (binding)

> The product is **Kakureneko** (`Kakureneko.app`, DECISIONS D13); every module, identifier and path uses that name.

*Written 2026-10-12 by the architect; revised 2026-10-13 after three implementer-perspective reviews (second pass:
the Kit contracts and every card below are the current binding text); updated 2026-10-13 by the integrator after the
nine modules were merged (contract changes are marked "(integration)" and listed in §11.B); updated again after the
adversarial review of the merged build (fixes are marked "(fix)" and listed in §11.C). Inputs: `docs/DECISIONS.md` (binding product
decisions, rename table, dev safety rules) and `docs/research/00-BRIEF.md` (behaviour; uses the old name "Lidless":
apply the rename table). Where this document and the brief disagree on **module structure or a type signature**, this
document wins (it deliberately refines brief §9.1). Where they disagree on **behaviour**, the brief wins unless §11
lists the deviation.*

Nine implementation agents build Kakureneko in parallel, each in a separate copy of the repository, without talking to
each other. They meet only through the contracts in `Sources/KakurenekoKit`. Read §1–§8 completely, then your own spec
card in §9.

---

## 1. Module map

```
                         ┌────────────────────────────── KakurenekoApp (executable, MainActor default) ──┐
                         │  SwiftUI MenuBarExtra(.window), onboarding, settings. Talks ONLY to          │
                         │  `any KakurenekoControlling` + `AppSnapshot`.                                  │
                         └───────────────────────────────┬─────────────────────────────────────────────┘
                                                         │ KakurenekoCoordinator.live()
                         ┌───────────────────────────────▼─────────────────────────────────────────────┐
                         │ KakurenekoCoordinator (actor): main loop, §7.3 power state machine, pause       │
                         │ scheduling, remote commands, notification routing, settings, snapshots.       │
                         │ LiveComposition.swift = the only place naming concrete module types.          │
                         └──┬───────┬────────┬────────┬────────┬────────┬────────┬───────────────────────┘
                            │       │        │        │        │        │        │
   KakurenekoEvents  KakurenekoProcesses  KakurenekoSessions  KakurenekoPower  KakurenekoPause  KakurenekoNotify  KakurenekoInstall
   (inbox, norm.)  (libproc, T3,      (engine, Claude   (IOKit, pmset, (grouping,     (Mac+iCloud,    (agent config
                    topology)          T2 watcher)       safety, admin) rules, journal) HMAC, policy)   installers)
        │                │                   │               │               │              │              │
        └────────────────┴───────────────────┴──────┬────────┴───────────────┴──────────────┴──────────────┘
                                                    ▼
                          KakurenekoKit — contracts: value types, service protocols, side-effect protocols,
                          Paths, settings, clock, logging, dry-run, JSON, test fakes. Foundation + os only.

   KakurenekoHook  (executable `kakureneko-hook`, Darwin + notify only, NO dependencies)      — owner: events
   KakurenekoGuard (executable `kakureneko-guard`, depends on KakurenekoKit + KakurenekoPause)     — owner: pause
```

| Target | Kind | Depends on | Links | Owner |
|---|---|---|---|---|
| `KakurenekoKit` | library | — | Foundation, os, Synchronization | **architect** |
| `KakurenekoEvents` | library | Kit | — | events |
| `KakurenekoProcesses` | library | Kit | IOKit | processes |
| `KakurenekoSessions` | library | Kit | — | sessions |
| `KakurenekoPower` | library | Kit | IOKit | power |
| `KakurenekoPause` | library | Kit | IOKit, CoreAudio | pause |
| `KakurenekoNotify` | library | Kit | (CryptoKit, Network auto-link) | notify |
| `KakurenekoInstall` | library | Kit | (CryptoKit auto-link) | install |
| `KakurenekoCoordinator` | library | Kit + all seven above | — | coordinator |
| `KakurenekoApp` (product `KakurenekoApp` → `Contents/MacOS/Kakureneko`) | executable, `.defaultIsolation(MainActor.self)` | Kit, Coordinator | SwiftUI/AppKit | app |
| `KakurenekoHook` (product `kakureneko-hook`) | executable | nothing | Darwin, notify | events |
| `KakurenekoGuard` (product `kakureneko-guard`) | executable | Kit, Pause | — | pause |
| `KakurenekoKitTests` | Swift Testing | Kit | | architect |
| `Kakureneko<X>Tests` (Events, Processes, Sessions, Power, Pause, Notify, Install, Coordinator, App) | Swift Testing | `Kakureneko<X>` + Kit (Events also builds `KakurenekoHook`, Pause also builds `KakurenekoGuard`, App uses `@testable import KakurenekoApp`) | | owner of X |

System frameworks a module imports (AppKit, CoreGraphics, Network, CryptoKit, CoreAudio, ServiceManagement) are
auto-linked by `import`; the explicit `linkerSettings` above are the ones R08 verified as needed.

## 2. Dependency and visibility rules (binding)

1. A feature library imports **only** `KakurenekoKit` (+ Apple frameworks). Never another feature library. Anything two
   modules exchange is a Kit type or a Kit protocol. `KakurenekoCoordinator` imports all; `KakurenekoGuard` may import
   `KakurenekoPause`.
2. **Public surface = your spec card's "Must export" list**, nothing else. Every other type, function and extension
   is `internal` (tests use `@testable import`). Reason: the coordinator imports every module, so two modules exporting
   a type `Normalizer` or a public extension method with the same name on a Kit type would make the coordinator
   ambiguous. Exception: the pause owner may export types needed by `kakureneko-guard` if they are prefixed `Pause`
   (e.g. `PauseRecovery`).
3. **Never add public extensions to Kit types** (internal extensions are fine).
4. No external package dependencies. No `.xcodeproj`. Swift 6 language mode, the strict settings in `Package.swift`.
5. Binding initializer signatures (marked "Binding signature" in the stubs) must not change. You MAY add parameters
   **with default values** after the existing ones. You may change `final class` ↔ `actor` only where your card allows.
6. Zero warnings is the goal; at minimum no new warnings in your module.

## 3. File ownership, merge procedure, contract changes

| Owner | May edit | Must not edit |
|---|---|---|
| architect | `Package.swift`, `Sources/KakurenekoKit/**`, `Tests/KakurenekoKitTests/**`, `docs/ARCHITECTURE.md` | — |
| events | `Sources/KakurenekoEvents/**`, `Sources/KakurenekoHook/**`, `Tests/KakurenekoEventsTests/**` | everything else |
| processes | `Sources/KakurenekoProcesses/**`, `Tests/KakurenekoProcessesTests/**` | everything else |
| sessions | `Sources/KakurenekoSessions/**`, `Tests/KakurenekoSessionsTests/**` | everything else |
| power | `Sources/KakurenekoPower/**`, `Tests/KakurenekoPowerTests/**` | everything else |
| pause | `Sources/KakurenekoPause/**`, `Sources/KakurenekoGuard/**`, `Tests/KakurenekoPauseTests/**` | everything else |
| notify | `Sources/KakurenekoNotify/**`, `Tests/KakurenekoNotifyTests/**` | everything else |
| install | `Sources/KakurenekoInstall/**`, `Tests/KakurenekoInstallTests/**` | everything else |
| coordinator | `Sources/KakurenekoCoordinator/**`, `Tests/KakurenekoCoordinatorTests/**` | everything else |
| app | `Sources/KakurenekoApp/**`, `Tests/KakurenekoAppTests/**`, `scripts/**`, `Resources/**` | everything else |

**Nobody but the architect edits `KakurenekoKit` or `Package.swift`.** `docs/research/**` and `docs/DECISIONS.md` are
read-only for everyone.

**Merge procedure.** Each agent works in its own copy. At merge time the owned directories above are copied back
verbatim. Your stub file (`Sources/<Target>/<Target>.swift`) may be deleted or split as long as every "Must export"
symbol still exists with its binding signature. Because other agents compile against the *stubs*, your module must
build with the Kit that exists today.

**Contract changes.** If you need something Kit does not provide: work around it locally (internal types, internal
extensions, metadata keys in `AgentEvent.metadata` / `AgentSession.metadata`), keep going, and **REPORT** it in your
final summary under "Contract change requests" (what, why, the workaround you used). Never fork a Kit type.

## 4. Contract summary (`Sources/KakurenekoKit`)

### 4.1 Foundation
| Symbol | Purpose |
|---|---|
| `Paths` | Every filesystem location, derived from an injectable home. `Paths.live()` resolves the home `KAKURENEKO_HOME` → `HOME` → `FileManager` (FileManager/`NSHomeDirectory()` IGNORE `$HOME` on macOS); when the result is not the real home it sets `isHomeOverridden` and ignores `CLAUDE_CONFIG_DIR`/`CODEX_HOME`/`COPILOT_HOME`/`XDG_CONFIG_HOME` (agent dirs then derive from the fake home). `try Paths.temporary()` for tests (`isHomeOverridden == true`). `~/.kakureneko/{bin/kakureneko-hook, inbox{,/.tmp,/bad}, run/{heartbeat,last-events.json}, log, backups/<agent>, recordings, claude-plugin, install-manifest.json}`, fallback inbox `<user tmp>/com.kakureneko/inbox`, `~/Library/Application Support/Kakureneko/{paused.json, outbox.json, secrets.json, notify-state.json, settings.json, resume.json, install/…}`, agent dirs. `agentSubprocessEnvironment` = `extraEnvironment` for every agent CLI (`HOME`, plus the four agent-dir variables pinned inside the fake home ONLY when overridden — setting `CLAUDE_CONFIG_DIR` in a normal run would move Claude's global `.claude.json`). `helperEnvironment` = `HOME` + `KAKURENEKO_HOME` for spawned helpers. `RootPaths` = sudoers drop-in, LaunchDaemon plist, root fail-safe script. |
| `KakurenekoID`, `KakurenekoEnvironment` | Bundle/signing identifiers, ownership marker `/.kakureneko/bin/kakureneko-hook`, Darwin notification `com.kakureneko.inbox`, plugin `kakureneko@kakureneko-local`, iCloud container `iCloud.com.kakureneko.Kakureneko` (`KakurenekoCloud.CloudSchema`); env names `KAKURENEKO_DRY_RUN`, `KAKURENEKO_RECORD`, `KAKURENEKO_HOME`, `KAKURENEKO_INBOX`, `KAKURENEKO_FALLBACK_INBOX` (hook tests), `KAKURENEKO_DEBUG_LOG`. |
| `KakurenekoClock` (`SystemClock`, `TestClock`) | Wall clock + sleep; `TestClock.advance(by:)` drives timers deterministically. Pure engines take `now: Date` instead. (integration) `TestClock.waitForSleepers(_:timeout:)` is bounded by WALL-CLOCK time (default 5 s; the old yield-count bound shrinks under load and remains only as `waitForSleepers(_:maxYields:)`), `sleeperDeadlines` and `waitForSleeper(dueBy:timeout:)` let a test wait until a specific timer is armed. |
| `KakurenekoLogger`, `LogCategory`, `FileLogSink` | os.Logger per category + optional rotated file log. Injected; no global logger. |
| `DryRunPolicy`, `DryRunGate`, `DryRunLedger` | Dry-run decision (env forced or settings requested) consulted per call; ring buffer of "would …" entries. `DryRunGate.setRequested` is COORDINATOR-ONLY, after `thawAll` + `disarm` ran under the old value (§6). (integration) `LiveComposition` creates the gate with the environment policy ONLY; `start()` step 6 applies `settings.general.dryRun`. |
| `AtomicFile` | temp + fsync/`F_FULLFSYNC` + rename, keeps mode. (integration) `followSymlinks: true` follows the WHOLE link chain of the last path component with `readlink` (relative targets against the link's directory, no lexical `..` folding) and replaces the final target, keeping every link; a dangling chain's missing target is created (brief §3.7.2); > `maxSymlinkHops` (32) → `Failure.open(…, ELOOP)`. `finalTarget(of:)` exposes the resolution (installers delete through it, the protected-location guard checks it). |
| `KakurenekoJSON` | The JSON config for all of Kakureneko's own files: ISO 8601 ms dates (exact round-trip for whole-ms dates), sorted keys. |
| `AsyncBroadcaster<T>` | Multi-subscriber `AsyncStream` fan-out: `replayLatest`, `replayFilter` (e.g. replay only `.snapshot` power events), `bufferLimit` (`InboxFile.maxQueuedFiles` for the event inbox). No buffering for future subscribers: **subscribe before `start()`**. |
| `TextSanitizer` | ANSI strip, secret redaction, path → basename, whitespace collapse, 140-char cap (brief §8.4 Detailed). |
| `KakurenekoFormat` | `shortDuration` (`42m`, `1h 5m`), `clockTime` (`14:02`), `projectName(fromCwd:)`. |
| `AgentCLIEnvironment` | (fix, §11.C) `searchPath(executable:home:loginShellPATH:inherited:)`: the `PATH` every agent-CLI subprocess gets (`claude plugin …`, `claude agents --json`, `opencode --version`) — the CLI's directory, its symlink target's directory, the login shell's `PATH` when captured, `~/.local/bin` `~/.bun/bin` `~/.volta/bin` `~/.npm-global/bin` `~/.claude/local`, Homebrew, the inherited `PATH`, `/usr/bin:/bin:/usr/sbin:/sbin`. A launchd-started app's bare `PATH` cannot run `#!/usr/bin/env node` CLIs (exit 127). |
| `DirectoryLayout.ensureUserDirectories` | Creates Kakureneko's own dirs (0700). Never an agent's dir. |
| `KeyedDecodingContainer.tolerantDecode…` | Tolerant decoding helpers used by every persisted Kit type. |

### 4.2 Model (all `Sendable`; `Codable` where persisted or crossing a file boundary)
| Area | Types |
|---|---|
| Agents | `AgentID` (brief §3.1 + `plandex`; tolerant decode, `init(label:)` aliases, `displayName`, `installableInV1`, `claudeCompatibleFamily`), `HostApp` (from bundle id / `TERM_PROGRAM` / env) |
| Events | `NormalizedEvent`, `TurnOutcome`, `NeedsInputKind`, `Tier` (T1–T4), `InboxHeader` + `InboxAncestor` (line-1 schema; ancestors carry `argv0`, path-like `argv1`, `path` = `proc_pidpath`, (integration) `module` = the `-m <module>` of a Python interpreter when `isRecordableModule` (plain dotted identifier ≤ 128 B, re-validated on decode), and `descriptor` for the matcher = `[argv0, "-m", module]` or `[argv0, argv1?]`), `InboxFile` (name format, parse/serialize, caps), `AgentEvent` (normalized + attribution + dedupe identity), `MetadataKey` (+ `sessionStoreDirectory`, `opencodeSessionID`, `claudeSessionStartSource`; (integration) the informational payload extras `claudePermissionMode`, `claudeAgentType`, `sessionEndReason`, `codex`/`gemini`/`copilotSessionStartSource`, `cursorComposerMode`, `agyTerminationReason`, `auggieStopCause`) |
| Processes | `ProcessIdentity` (equality on pid+start only), `AncestorInfo`, `ProcessDescriptor`, `AgentMatch`, `AgentProcess`, `ProcessSnapshot`, `SamplingCadence`, `SessionStoreHint`, `EvidenceKind` (E1–E6; E2 excludes caffeinate/infrastructure/keep-alive respawns; (fix, §11.C) only E1/E2/E3 `countsAsProgress` — E4/E5 alone never refresh the stall guard), `EvidenceSample` (+ (integration) `EvidenceSample.window` = 60 s, the sampler's trailing window shared by Processes and Sessions), `AgentTopology` (+ `sessionHostPIDs`, filled by the coordinator), `IPCPeerHint`, `AutomationHelperHint` |
| Sessions | `SessionKey`, `SessionState`, `AgentSession`, `SessionAggregate` (incl. `stateVersion`, seeded per launch), `SessionEffect`, `ClaudeSessionRecord`, `ClaudeAgentsEntry`, `ClaudeSessionObservation` (+ `lastTurnCompletedAt`/`lastTurnDurationMs`/`lastTurnPendingBackground` from the transcript's `system/turn_duration`), `ClaudeStateSnapshot` (+ `ignoredIdentities`) |
| Power | `LidState`, `KernelPowerFlags` (effective `sleepDisabled` vs ALWAYS-real `kernelSleepDisabled`, `isSimulated`), `ThermalLevel`, `ThermalPressure`, `BatteryWarningLevel`, `PowerSnapshot` (+ `kernelSleepDisabled`, `isClamshellDesktop`), `Presence` (+ (integration) `hasRecentInput`, the one unknown-input rule, §8), `PrivilegedStatus` (+ `simulated`, `failsafeHeartbeatPath`, `heartbeatPathMismatch`, (fix) `failsafeScriptMismatch` — installed fail-safe or plist missing/edited/foreign → not operational —, `needsReinstall`; `simulatedForDryRun(at:)`), `CountdownReason`, `SafetyTrip`, `WindDownReason`, `EndAction`, `PowerPhase` (+ `shutdownPending`), `SleepRecord`, `ResumeEntry` ((integration) `resumeCommand` is injection-safe — cwd always single-quoted, ids bare only when `[A-Za-z0-9._:@%+=,/-]`, else quoted — and runs `cd "$HOME"` without a cwd), `PowerEvent` (+ `userActivity`; `isSnapshot`), `PowerChangeAcknowledger` |
| Pause | `PauseMode`, `PauseAction`, `PauseJournal` / `PauseJournalApp` (+ `simulated`) / `PauseJournalRecord` (exact on-disk schema; LOSSY decoding per app/member with strict identity fields; `init?(identity:…)` only for enriched identities), `ProtectionReason` (P-A…P-K, (fix) `categoryDefault`: R06 §5.4 browsers and chat/mail/meeting apps → Throttle in Freeze mode, downgrade-only), `PausedApp`, `ProtectedApp`, `PauseFailure`, `PauseReport`, `ThawReason`, `GroupingSelfTest` |
| Notify | `NotificationKind`, `NotificationPriority`, `NotificationAction`, `OutgoingNotification`, `RemoteCommandKind`, `RemoteCommand`, `SignedCommand` (wire format, canonical HMAC input, base64url tokens), `ProviderCapabilities`, `DeliveryError`, `DetailLevel`, `PairingInfo`, `PairingState`, `NotificationStatus` (+ `hasAccessToken`), `NotificationIntent` (+ `resolved(SessionKey)`; `countdown(endsAt:reason:finished:waiting:offerShutdown:)`), `NotificationContext` (+ `keepAwakeSeconds`), `NotificationDisposition`, `DrainResult` |
| Install | `IntegrationStatus`, `FileChange`, `PlannedCommand`, `InstallPlan`, `InstallResult`, `InstallManifestEntry`, `InstallManifest`, `HelperDeployment` |
| Settings | `KakurenekoSettings` (+ `GeneralSettings`, `PowerSettings`, `SafetySettings`, `SessionTimers`, `PauseSettings`, `NotificationSettings`, `QuietHours`, `IntegrationSettings`; versioned, tolerant, `normalized()`, `load/save`). Every user-facing range is a public static constant (`SessionTimers.finishCountdownMinutesRange`, `SafetySettings.batteryFloorPercentRange`, …) used by both `normalized()` and the settings UI. `PauseSettings.mode` is throttle/freeze only. |
| UI | `AppSnapshot`, `OperatingMode`, `AppWarning` |

### 4.3 Service protocols (the coordinator composes these; `KakurenekoServices` bundles them)
| Protocol | One-line purpose | Implemented by |
|---|---|---|
| `AgentEventSource` | Watch both inboxes, emit normalized/attributed/deduped `AgentEvent`s; serialized drains; proof of life per integration (persisted). Subscribe BEFORE `start()`; ingest only from the stream (`drainNow()`'s array is informational). (integration) `start()` never throws for transient/recoverable filesystem problems (logs, retries from the safety tick); the coordinator logs any error and keeps starting | `KakurenekoEvents.EventInbox` |
| `AgentSignatureMatching` | Classify a process (exe path + argv[0]/argv[1]) as an agent | `KakurenekoProcesses.AgentMatcher` (Kit has `BasicAgentSignatureMatcher`) |
| `ProcessSampling` | T3 scan + evidence per tick; expensive `AgentTopology` on demand; E3 hints | `KakurenekoProcesses.ProcessScanner` |
| `ProcessLookup` | pid → live `ProcessIdentity` (liveness) | `KakurenekoProcesses.LiveProcessLookup`; Kit reference `KernelProcessLookup` (sysctl `KERN_PROC_PID`; used by the guard, Pause and tests) |
| `ClaudeStateSource` | T2: `~/.claude/sessions` watcher (FSEvents with file events: records are rewritten in place) + `claude agents --json --all` poller → `ClaudeStateSnapshot` | `KakurenekoSessions.ClaudeStateWatcher` |
| `SessionTracking` | Synchronous deterministic session state machine; ingest events/T2/T3, `tick(now)` → `[SessionEffect]`; sessions + aggregate. (fix) `SessionEngine(…, processes:)` takes an optional `ProcessLookup` (production: `LiveProcessLookup`) for the liveness of bound processes no snapshot ever contained | `KakurenekoSessions.SessionEngine` |
| `PowerControlling` | Kernel flags (effective + real), arm/disarm (+ `disarmSynchronously` for signal handlers — (fix) also clears the flag of an arm still in flight and latches "terminating": later `arm()`s throw), heartbeat (only when really armed), sleep/shutdown/display-sleep, (fix) `scheduleDetachedSleep(after:)` (the shutdown's sleep fallback handed to a helper that outlives the app), chime, `PowerSnapshot` | `KakurenekoPower.PowerController` |
| `PowerEventSource` | Lid edges, will-sleep (with acknowledger)/did-wake, power-off, session switch, displays, closed-lid user activity, periodic snapshots (only `.snapshot` replayed) | `KakurenekoPower.PowerMonitor` |
| `SafetyEvaluating` | §7.4 guards with durations → `SafetyTrip?`; stateless `armingBlocker` for arming / staying armed with the lid open | `KakurenekoPower.SafetyMonitor` |
| `PrivilegedInstalling` | Health check (incl. fail-safe heartbeat path), one-prompt install/uninstall, generated scripts | `KakurenekoPower.PrivilegedInstaller` |
| `AppPausing` | Journal recovery, crash handler (sigaction only), sync thaw for termination, guard, self-test, `observe` (P-I history), pause/recheck/thawAll, paused apps | `KakurenekoPause.PauseManager` |
| `LocalNotificationPosting` | Kakureneko's macOS notifications (post, permission, categories, button taps) | `KakurenekoNotify.UserNotificationCenterPoster` (app bundle only) |
| `NotificationDispatching` | Templates + policy + outbox + provider + command stream + pairing (`preparePairing` → `sendPairingRequest`) + access token | `KakurenekoNotify.NotificationDispatcher` |
| `AgentIntegrating` | Statuses, `preview(_:operation:)` (install/uninstall/repair), install/uninstall/repair, helper deployment | `KakurenekoInstall.IntegrationManager` |
| `KakurenekoControlling` | Every UI action (+ `cancelWindDown`, `requestNotificationPermission`, `handleCloudPush`, `previewIntegration(_:operation:)`, (fix) `nonisolated terminateSynchronously()` — the synchronous thaw + disarm of every quit path that may skip `prepareForTermination`) + `snapshots()` stream of `AppSnapshot`. (integration) A `.starting` snapshot's `isDryRun` reflects only `KAKURENEKO_DRY_RUN`; UI side effects wait for the first non-`.starting` snapshot and treat `isDryRun || settings.general.dryRun` as dry-run | `KakurenekoCoordinator.KakurenekoCoordinator` (Kit has `PreviewKakurenekoController`) |

### 4.4 Side-effect protocols (the ONLY way to mutate the system)
| Protocol | Real implementation (module) | Never in tests/agents |
|---|---|---|
| `PrivilegedCommandRunning` (`PrivilegedCommand.setSleepDisabled`, `.checkSudoRule`; argv byte-exact) | `SudoPrivilegedCommandRunner` (Power) | the mutating case |
| `SystemSleeping` (+ (fix) `scheduleDetachedSleep(after:)`: `/bin/sh` in its own session, `sleep N`, then `pmset sleepnow` only if `AppleClamshellState` is Yes) | `IOPMSystemSleeper` (Power) | always |
| `ShutdownRequesting` | `LoginWindowShutdownRequester` (Power) | always |
| `DisplaySleeping` | `PmsetDisplaySleeper` (Power) | always |
| `ProcessSignalling` (stop/cont via audit token, DARWIN_BG priority, terminate, `relaunchApplication(at:)`; pausing calls refuse un-enriched identities; (integration) `isDarwinBackground` reads `proc_pidinfo` `pbi_flags` `PROC_FLAG_EXT_DARWINBG` 0x10000 / `PROC_FLAG_DARWINBG` 0x8000 — `getpriority` does not see an EXTERNAL throttle) | `AuditTokenSignaller` (Pause) | except on processes the test spawned (relaunch: never) |
| `AdministratorScriptRunning` (one admin prompt; (fix) `runAsAdministrator(script:name:arguments:)` runs the script TEXT inline — `/bin/bash -c <script> <name> <args…>` — never a file a same-user process could rewrite during the dialog) | `AppleScriptAdministratorRunner` (Power) | always |
| `CloudStore` (KakurenekoCloud: account, prepare, save, delete, fetch changes, subscriptions) | `CloudKitStore.makeIfEntitled()` (nil without the iCloud entitlement) | the container's public CloudKit database (creator-only) |
| `SubprocessRunning` (`SubprocessRequest.effect` = `.readOnly`/`.mutating`) | `FoundationSubprocessRunner` (Kit) | sudo, pmset, claude plugin install, … |

`SideEffects` bundles them; `SideEffects.gated(real, gate:, ledger:)` wraps each in its `DryRun…` switch;
`SideEffects.dryRun(…)` / `.inert(…)` are pure dry-run sets for tests.

### 4.5 Test support (in Kit, usable by every test target and SwiftUI previews)
`TestClock`, `RecordingHTTPTransport` (scripted responses, controllable line streams), `FakeSubprocessRunner`,
`StaticProcessLookup`, `SideEffects.inert`, one scriptable fake per service protocol (`FakeEventSource`,
`FakeProcessSampler`, `FakeClaudeStateSource`, `FakeSessionTracker`, `FakePowerController`, `FakePowerEventSource`,
`FakeSafetyEvaluator`, `FakePrivilegedInstaller`, `FakeAppPausing`, `FakeNotificationDispatcher`, `FakeIntegrations`),
`FakeCallLog` (one ordered log shared by every fake: `"notify.drain"`, `"pause.thawAll(beforePowerAction)"`,
`"power.disarm"`, `"power.sleep"`, …), `FakeServiceSet(paths:clock:log:dryRun:)` (all fakes on one log and one
`TestClock` + a composed `KakurenekoServices`), `PreviewKakurenekoController` (+ `sampleSnapshot()`).

## 5. Threading model (Swift 6.3 strict concurrency; brief §9.4, R08 §9)

* **Upcoming features on every target:** `NonisolatedNonsendingByDefault` (a plain `nonisolated async` function runs
  on the *caller's* executor), `InferIsolatedConformances`, `MemberImportVisibility` (import Foundation/Darwin/etc. in
  every file that uses them).
* **Libraries are nonisolated.** Only `KakurenekoApp` has `.defaultIsolation(MainActor.self)`.
* **Values:** every cross-module type is a `Sendable` value type.
* **Stateful services:** `final class X: Sendable` with state in `Mutex` (`import Synchronization`), or an `actor`.
  Protocols whose requirements are **synchronous** (`SessionTracking`, `SafetyEvaluating`, `ProcessLookup`,
  `AgentSignatureMatching`, `ProcessSignalling` sync methods, `kernelFlags()`, `touchHeartbeat()`,
  `disarmSynchronously`, `thawAllSynchronously`, stream accessors) cannot be satisfied by actor-isolated methods —
  use a `final class` + `Mutex`, or `nonisolated` members.
* **Never block the coordinator.** Because of `NonisolatedNonsendingByDefault`, a service's `nonisolated async`
  method called by the coordinator actor runs ON the coordinator actor. Any syscall-heavy or I/O-heavy async method
  must be `@concurrent` or hop to its own queue/actor: `sample`, `topology`, inbox drains, file reads, subprocesses,
  IOKit snapshots, and KakurenekoPause's `pause`, `recheck`, `recoverFromJournal`, `selfTest`, `thawAll`, `observe`
  (a `@concurrent` witness satisfies a plain `async` requirement, as `FoundationSubprocessRunner.run` shows). No
  `Thread.sleep`, no `DispatchSemaphore.wait` in async code (the only blocking wait allowed is inside
  `disarmSynchronously`, called from a non-async signal-source handler).
* **Streams:** expose `AsyncStream` via `AsyncBroadcaster`; each `events()`/`snapshots()` call is an independent
  subscription; streams finish on `stop()`. Nothing is buffered for subscribers that do not exist yet, so callers
  **obtain every stream before calling that service's `start()`**.
* **C callbacks** (IOKit, notify, CoreAudio, `DispatchSource`): `@convention(c)` closure with no captures + a
  `final class Box: Sendable` passed through `Unmanaged` (R08 §8). Create every closure handed to GCD/IOKit/Network/
  notify **inside the nonisolated library** (or write `{ @Sendable in … }`); a closure created in the MainActor app
  target traps at runtime (R08 pitfall 1).
* **Non-Sendable tokens in a Mutex:** `ProcessInfo.beginActivity` returns a non-Sendable `NSObjectProtocol`; storing
  it directly in a `Mutex` fails ("'inout sending' parameter…"). Box it:
  `final class ActivityToken: @unchecked Sendable { let raw: any NSObjectProtocol }` in a `Mutex<ActivityToken?>`.
* **Hand-define IOKit message constants** (`0xE0034100`, `0xE0000270`, `0xE0000280`, …; R08 §8). `import notify`
  for `notify_post`. Use `String(decoding:as:)` instead of the deprecated `String(cString: [CChar])`.
* **The app** starts the coordinator in `applicationDidFinishLaunching` (never in a MenuBarExtra `.task`).
* **No global mutable state.** `static let` of immutable values only. ONE exception, in KakurenekoPause only: the
  async-signal-safe crash handler needs a capture-free, preallocated pid buffer:
  `enum CrashThawBuffer { nonisolated(unsafe) static let pids = UnsafeMutablePointer<pid_t>.allocate(capacity: 4096);
  static let count = Atomic<Int>(0) }` (the handler walks `pids[0..<count]`, `kill(pid, SIGCONT)`, resets the
  disposition to `SIG_DFL`, `raise(sig)`).

## 6. Dry-run policy (DECISIONS "Development safety rules")

* `KAKURENEKO_DRY_RUN=1` (truthy: 1/true/yes/on) forces dry-run for the process lifetime; the settings toggle
  `general.dryRun` requests it at runtime (`DryRunGate.setRequested`). `AppSnapshot.isDryRun` shows the effective value.
* (integration) **At launch** the gate holds only the environment policy: `start()` applies `settings.general.dryRun`
  in step 6, AFTER journal recovery (step 2) and the kernel-flag reconcile (step 3), so a crashed REAL run's
  journaled pauses and stale `SleepDisabled` are undone for real (undo runs under the gate that acted). Only
  `KAKURENEKO_DRY_RUN=1` keeps a process from ever touching real state; under it, launch recovery leaves really-paused
  records journaled (logged) for the next normal launch or `kakureneko-guard --recover`.
* Mechanism: the coordinator builds the real `SideEffects` once and wraps it with `SideEffects.gated`. Every wrapper
  consults the gate **per call**: gate on → `DryRunLedger.record(category, action:, detail:)` ("would arm", "would
  sleep", "would throttle pid 123", "would save 1 iCloud record(s) (Alert)") + synthetic success; gate off → forward.
  iCloud reads (account, change fetches) pass through; Mac notification posts and the permission prompt are logged.
  Read-only operations (health checks, GET requests, `.readOnly` subprocesses, `getpriority`) always forward.
* **Toggling at runtime (binding):** the coordinator applies a change of `general.dryRun` as
  `await pausing.thawAll(reason: .pausingDisabled); try? await power.disarm(); dryRun.setRequested(on)`, then re-steps
  the state machine — undo always runs under the gate value that was used to act. `PowerController` remembers
  `armedForReal` and `PauseManager` journals `simulated` per app; a mismatch is logged and surfaced
  (`SideEffectError.failed("dry-run toggled while really armed")`), never silently simulated.
* Ledger action names: `power.arm`, `power.disarm`, `power.sleep`, `power.shutdown`, `power.displaySleep`,
  `power.heartbeat`, `admin.script`, `signal.stop`, `signal.cont`, `priority.background`, `priority.normal`,
  `app.terminate`, `app.relaunch`, `http.<method>`, `subprocess.run`. Modules that gate their own work add:
  `install.write`, `install.delete`, `pause.guard` (PauseManager, when dry-run keeps `startGuard()` from spawning the
  guard), `power.simulatedFlag`. Every module that records its own decisions receives the ONE shared ledger
  explicitly from `LiveComposition` (`PowerController(ledger:)`, `PauseManager(ledger:)`,
  `IntegrationManager(ledger:)`); the "take the ledger of the gated side effect" fallbacks are for tests only. The
  app's own per-process dry-run log (not the Kit ledger) uses `app.loginItem`, `app.automationConsent`,
  `app.reopenSessions`.
* Module duties in dry-run (in addition to using the gated side effects they receive):
  * **Power:** simulate the `SleepDisabled` flag (arm → simulated true; `kernelFlags().sleepDisabled` reports it) but
    ALWAYS report the real kernel value in `kernelSleepDisabled`; skip kernel polling; do not create the power
    assertion; **never touch the heartbeat file** (ledger `power.heartbeat` instead) — a dry-run app must not keep
    the root fail-safe from clearing a real stale flag. `PrivilegedInstaller.install()` refuses a fake home with the
    gate off.
  * **Pause:** run the full decision logic and write the journal with `simulated: true` per app (recovery and the
    guard drop simulated apps without signalling); skip the `isDarwinBackground`/`SSTOP` verification (the
    passthrough reads REAL state) and count the action as succeeded; never spawn the guard; keep the crash-handler
    pid array empty.
  * **Install:** compute plans and diffs; write nothing (no backups, no manifest, no agent files, no plugin files);
    ledger `install.write` per file; `InstallResult.dryRun = true`.
  * **Notify:** publishing is answered by the gated transport (`{"id":"dry-run"}`); the command stream (GET) is real.
  * **Coordinator:** behaves normally (state machine, pushes, pauses) so the developer sees every decision. When
    `healthCheck()` is not operational in dry-run it uses `PrivilegedStatus.simulatedForDryRun(at:)` (mode `.full`,
    `AppWarning(id: "dry-run-privileged-simulated")`). Launch reconcile looks at `kernelSleepDisabled`: if the REAL
    flag is set while the gate is on → critical `AppWarning(id: "kernel-sleep-disabled")` (the root fail-safe will
    clear it because the heartbeat is not touched).
  * **App:** no `SMAppService.register/unregister` (log "would register login item"), no Automation consent prompt.
* Files Kakureneko owns (`~/.kakureneko/**`, app support) are still written in dry-run; use `KAKURENEKO_HOME=<tmp>` to keep a
  dev run away from the real home (agent CLIs then get `paths.agentSubprocessEnvironment`, the hook installed in the
  fake home writes to the fake inbox).
* (final integration) **Lid simulation (developer tool):** `KAKURENEKO_SIMULATE_LID=<absolute path>` makes the lid follow
  a control file (`closed` → lid closed, no external display, no user input since the file was written; anything
  else or no file → real readings; re-read at every 1 Hz poll, so it can be flipped while the app runs). Honoured
  ONLY when the environment forces dry-run (`LidSimulation.fromEnvironment`), so it can never make a real app pause,
  arm or sleep anything. One `LidSimulation` reaches `PowerController` (lid reading, snapshot display/input) and
  `PowerMonitor` (display/input polls; a real clamshell message never contradicts a simulated closed lid).

## 7. Testing rules (binding for every test target)

1. **Swift Testing** (`import Testing`, `@Test`, `#expect`, `#require`). Deterministic, fast (each test < 2 s; whole
   target < 10 s), parallel-safe (no shared fixed paths, no global state).
2. **Temp homes only:** `let paths = try Paths.temporary()`; clean up with
   `defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }`. Never read or write
   the real `~/.claude`, `~/.codex`, `~/.gemini`, `~/.copilot`, `~/.cursor`, `~/.config/opencode`, `~/.aider.conf.yml`,
   `~/.kakureneko`, `~/Library/Application Support/Kakureneko`. **Spawned helpers get `HOME=<temp>` AND
   `KAKURENEKO_HOME=<temp>`** (`paths.helperEnvironment`); `kakureneko-guard` additionally gets `--log <temp path>`.
   Hook tests ALWAYS set both `KAKURENEKO_INBOX` and `KAKURENEKO_FALLBACK_INBOX` to temp directories.
3. **Time:** `TestClock` or explicit `now:` parameters. No wall-clock sleeps longer than ~200 ms; prefer
   `clock.advance(by:)`. (integration) The whole suite runs in ONE process with heavy parallelism, so a task can wait
   hundreds of ms for a thread: wall-clock bounds are for "eventually" (generous, return early) only; never advance
   virtual time past an instant you assert before observing it (advance to `expected − step`, check "not yet",
   advance the last step, then wait generously); wait for a timer with `TestClock.waitForSleepers(_:timeout:)` /
   `waitForSleeper(dueBy:)`; a child process's latency bound takes the best of a few rounds, and an in-process cost
   bound is measured as thread CPU time. Never `await` a task that sleeps on a `TestClock` after a driver that may
   stop advancing (drive until it finishes; cancel it at a generous cap). Every suite carries
   `.timeLimit(.minutes(1))`, so a hang becomes a failure instead of a run that never ends.
4. **No real side effects, ever:** no `sudo`, no `pmset` (except read-only `pmset -g`-style reads are still
   discouraged), no `IOPMSleepSystem`, no shutdown, no admin prompt, no `SMAppService` registration, no notification
   authorization, no `NSRunningApplication.terminate`, no app relaunch, no signals/`setpriority` except to
   **processes the test spawned itself** (e.g. `/bin/sleep 30` launched by the test), no CloudKit or UserNotifications (use
   `RecordingHTTPTransport` or a mock server bound to `127.0.0.1`), no installing into real agent configs, never
   launching `Kakureneko.app`.
5. **Read-only system probes are allowed** (libproc scans, `sysctl`, IORegistry reads, `IOPSCopyPowerSourcesInfo`,
   `bash -n`, `plutil -lint`, `visudo -cf` on a temp file) but assertions must not depend on machine state (battery
   present, lid state, which agents run).
6. Spawn children with `FoundationSubprocessRunner` (it never SIGPIPEs the test process and always reaps/kills its own
   children) or `posix_spawn`; always bound them with a timeout.
7. Locate built helpers next to the test bundle:
   `Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appending(path: "kakureneko-hook")`.
8. Coordinator tests use `FakeServiceSet` (assert cross-service ORDER with `fakes.log`); module tests use their real
   types plus Kit fakes for collaborators. Agent-CLI callers (`ClaudeStateWatcher`, installers) are tested ONLY with
   `FakeSubprocessRunner` (a real runner would read the real `~/.claude`).
9. Never install process-wide signal handling in a test process: never call `installCrashHandlers()` there (test the
   pid-buffer bookkeeping as pure functions, the handler in a spawned helper such as `kakureneko-guard
   --crash-selftest`), and keep `KakurenekoServices.handlesTerminationSignals == false` (the default).

## 8. Cross-module invariants (binding)

* **Process identity** = `(pid, startSec, startUsec)` from the kernel's process start time (`kinfo_proc.kp_proc.p_starttime`
  = `proc_bsdinfo.pbi_start_tvsec/tvusec` — the same value). The hook's `InboxAncestor`, the scanner's `AgentProcess`,
  `LiveProcessLookup` and the journal must all produce identical tuples for the same process; `KernelProcessLookup`
  (Kit) is the reference implementation. `uniqueID`/`pidVersion` are optional enrichments and do not participate in
  equality — but nothing is journaled or paused without them.
* **Presence (integration, one rule):** an UNKNOWN time since user input (`secondsSinceUserInput == nil`) counts
  as AWAY while the lid is effectively closed and as PRESENT while it is open (`Presence.hasRecentInput`). Kit
  `Presence.isAway` (Notify's gating, the coordinator's present → away re-submit) and the coordinator's
  `userPresent` (countdown gating) both use it, so a missing reading never blocks a countdown or a push forever with
  the lid closed. With a KNOWN reading they still differ by design: notifications treat a closed lid as away even
  with recent input, while recent input (Screen Sharing) keeps the coordinator from starting a countdown.
* **Session keys:** Claude = the conversation UUID (`session_id` in hooks == `sessionId` in records == `sessionId` in
  `agents --json`). Codex = `thread-id` (notify) / `session_id` (hooks) — the same conversation id. Gemini =
  `session_id`. Copilot/VS Code = the payload session id. Cursor = `conversation_id`. **opencode = the opencode
  PROCESS** (`SessionKey.fallback(agent: .opencode, identity:)`; the payload's session id goes to
  `metadata[MetadataKey.opencodeSessionID]`, a child's to `opencodeChildSession`; the process is busy while ANY of
  its sessions is busy — KakurenekoEvents aggregates). Agents without an id (Aider, T3-only) use
  `SessionKey.fallback(agent:identity:)` = `pid:<pid>:<startSec>.<usec>`. The engine re-keys a fallback session when a
  real id appears for the same `agentProcess`. A session id is never taken from inherited env
  (`CLAUDE_CODE_SESSION_ID`) when the payload has one.
* **Attribution** (§9.1): the nearest matched non-infrastructure ancestor wins over env markers — `CLAUDE_PID` and
  `CLAUDE_CODE_SESSION_ID` are inherited by every process an agent spawns from Claude's Bash tool.
* **Precedence** (brief §5.2): liveness > state record > hook edges > heuristics.
* **State version:** `SessionAggregate.stateVersion` increments whenever any session (re)enters `.working` for a new
  turn; it is the `sv` in signed sleep/shutdown commands. It is seeded per launch (`SessionEngine(initialStateVersion:)`
  = launch epoch ms in production), so a button minted before a relaunch never matches.
* **Metadata keys** shared across modules are the `MetadataKey` constants (producers never use string literals for a
  key that has a constant).
* **Evidence window:** `EvidenceSample.window` (60 s) is the sampler's trailing window; the engine ignores evidence
  sampled less than one window after a finish (no phantom heuristic turn) or after a wait began (no false waiting
  exit on the work that led up to the prompt).
* **Untrusted input:** every string from an agent payload, record file or iCloud record is capped (≤ 1 KiB per field,
  previews ≤ 140 chars via `TextSanitizer`) before it leaves the producing module. Never act destructively on a single
  event (sleep/shutdown always go through the coordinator's state machine + countdown).
* **Never log secrets** (HMAC key, topics, tokens), payload bodies, prompts or assistant text. Log decisions,
  identities and counts.
* **Time in persisted files:** `KakurenekoJSON` (ISO 8601, ms). Inbox header `ts` is epoch ms (Int64).

---

## 9. Spec cards

Each card lists: owned paths · must-export symbols (binding) · Kit contracts · brief sections · behaviour · acceptance
tests (minimum; add more). "Brief" = `docs/research/00-BRIEF.md`; R0x = `docs/research/0x-*.md`.

### 9.1 events — `KakurenekoEvents` + `kakureneko-hook`

**Owns:** `Sources/KakurenekoEvents/`, `Sources/KakurenekoHook/`, `Tests/KakurenekoEventsTests/`.

**Must export:**
```swift
public final class EventInbox: AgentEventSource {
    public init(paths: Paths, matcher: any AgentSignatureMatching = BasicAgentSignatureMatcher(),
                clock: any KakurenekoClock = SystemClock(), logger: KakurenekoLogger = KakurenekoLogger(.events))
}
```
and the executable `kakureneko-hook` (contract in `Sources/KakurenekoHook/main.swift` header — binding).

**Read:** brief §3.1–3.4, §3.6 (what each installer makes the hook receive), §4.1–4.4; R08 §6.2–6.6 (verified
Darwin-only CLI + inbox code — adapt it: no `emit` subcommand, argv is `<agent> <event>`), R03/R04 §7.2–7.3/R05 for
payload shapes, R02 §1 for Claude hook payloads (§1.3: `CLAUDE_PID`/`CLAUDE_CODE_SESSION_ID` are in the env of EVERY
Claude tool subprocess; §1.4 Notification types).

**`kakureneko-hook`:** Darwin-only Swift (`import Darwin`, `import notify`), no Foundation. Implement the full header
contract:
* exit 0 always (`alarm(2)` + SIGALRM → `_exit(0)`, SIGPIPE ignored), empty stdout except `cursor beforeSubmitPrompt`
  → `{"continue":true}` and `cline *` → `{"cancel":false}`, nothing on stderr;
* payload: if `isatty(STDIN_FILENO) != 0` NEVER read stdin (Aider runs `notifications-command` with
  `subprocess.run(…, shell=True, capture_output=True)`, so stdin is the user's terminal — reading would block Aider's
  prompt for 300 ms and swallow keystrokes; payloadSource `none`); else stdin (300 ms idle poll, 4 MiB cap); a
  trailing JSON-object argv always wins (Codex notify, payloadSource `argv`);
* `--chain -- <argv…>`: (integration) `posix_spawnp` — execvp semantics, a bare program name (`notify-send`,
  `terminal-notifier`, `python3`, exactly as Codex `notify` held it) is resolved through the hook's inherited `PATH`
  like Codex did —, `/dev/null` stdio, `POSIX_SPAWN_SETSID`, default signal dispositions, no wait; append the payload
  as the last argv ONLY when payloadSource == `argv`, otherwise spawn the chained argv unchanged; a program that
  cannot be spawned is logged (exit 0 regardless);
* header = `InboxHeader` (v, agent, event, ts ms, pid, ppid, cwd, payloadSource, env allow-list =
  `InboxHeader.environmentAllowList` minus anything matching TOKEN|KEY|SECRET|PASSWORD, ancestry ≤ 8 via
  `sysctl(KERN_PROC_PID)` incl. `ppid`, `startSec`, `startUsec`, `exe` (= p_comm), `tdev`, and from ONE
  `KERN_PROCARGS2` read per ancestor (reused 16 KiB buffer, argv only): `argv0`, plus `argv1` only when
  `InboxAncestor.isRecordableArgv1` (path-like; argv[1] can be a prompt); `path` = `proc_pidpath` when it succeeds;
  (integration) `module` = the `-m <module>` of a Python interpreter (argv[0] or exec-path basename `python*`), only
  when `InboxAncestor.isRecordableModule` — at most 8 argv strings scanned, never past argc);
* `<root>`: the `.kakureneko` directory containing this binary when its own path (`_NSGetExecutablePath` /
  `proc_pidpath(getpid())`) ends in `/.kakureneko/bin/kakureneko-hook` (keeps a `KAKURENEKO_HOME` dev install inside the
  fake home), else `$HOME/.kakureneko`;
* file `<inbox>/.tmp/<19-digit ns>-<pid>.tmp` (`O_CREAT|O_EXCL|O_CLOEXEC` 0600) → `rename(2)` →
  `notify_post("com.kakureneko.inbox")`; inbox resolution `$KAKURENEKO_INBOX` → `<root>/inbox` (mkdir 0700) → fallback
  `$KAKURENEKO_FALLBACK_INBOX` ?? `confstr(_CS_DARWIN_USER_TEMP_DIR)/com.kakureneko/inbox`; > `InboxFile.maxQueuedFiles`
  → drop; diagnostics to `<root>/log/hook.log` (rotate at 1 MB); `KAKURENEKO_RECORD=1` → also
  `<root>/recordings/<agent>/<event>-<ts>.json` (raw stdin, argv, allow-listed env). The JSON it writes must parse
  with `InboxFile.parse` and serialize only strings it escaped itself (never re-escape the payload).

**`EventInbox`:**
* **Lifecycle:** callers obtain `events()` BEFORE `start()`. (integration) `start()` never throws for an inbox that
  cannot be created/watched right now; it logs and the 30 s safety tick retries. `start()`: `DirectoryLayout`-style creation of both
  inboxes (+ `.tmp`, `bad`), load `paths.lastEventsFile`, the launch drain (yielded to the subscribers that exist at
  that point), then watch both directories (vnode `DispatchSource` on an `O_EVTONLY` fd, `[.write, .rename, .delete]`),
  30 s safety re-drain, GC of `bad/` and `.tmp/` entries older than 24 h, optional `notify_register_dispatch` hint.
  `stop()` finishes every stream.
* **Drains** (launch, vnode, timer, notify hint, `drainNow`) run on ONE private serial queue (or behind a `draining`
  flag): list both inboxes, merge, sort GLOBALLY by file name, ≤ 500 files per pass, then process in that order.
  Parse → normalize → attribute → dedupe → yield → **delete**; unparseable → move to `bad/`. The broadcaster is
  `AsyncBroadcaster<AgentEvent>(bufferLimit: InboxFile.maxQueuedFiles)`. `drainNow()` returns the accepted events for
  information only (they are already on the streams). All file I/O off the caller's actor.
* **Normalizers** (one per agent family, internal): the raw → `NormalizedEvent` tables of brief §3.3 (Claude, Codex
  notify + hooks, Gemini, agy, Copilot/VS Code, Cursor, opencode, Aider) and §3.4 for the Claude-compatible family
  (Droid incl. `Notification idle_prompt` without Stop → `turnFinished(.interrupted)`, Qwen incl. `background_tasks`/
  `crons`, Auggie `agent_stop_cause`, Qoder, CodeBuddy, iFlow, Devin) and Windsurf (`pre_user_prompt` → turnStarted,
  `post_cascade_response` → turnFinished(completed), `post_run_command` → activity). Corrections to the brief
  (binding): Claude `Notification` `agent_completed` → `.activity` (also Copilot `agent_completed`);
  `quota_auto_resume_fired` → `.turnStarted` (Claude resumed WORK); `quota_auto_resume_stale` / `_disabled` →
  `.needsInput(.unknown)` (Claude waits for Enter); `StopFailure` `rate_limit` → `turnFinished(.rateLimited)`, else
  `.error`; `SessionStart` copies `source` (`startup`/`resume`/`clear`/`compact`) into
  `metadata[MetadataKey.claudeSessionStartSource]`. Unknown agent/event → drop with a debug log (never crash). Fill
  `sessionKey` (§8), `turnID`, `cwd` (payload beats header), `transcriptPath`, `messagePreview`
  (`last_assistant_message` / `last-assistant-message` / `prompt_response` → `TextSanitizer`), `waitingFor`
  (Notification `message`, sanitized), `errorDetail` (StopFailure `error`), `backgroundTasksRunning` (Claude
  `Stop.background_tasks` containing a running `subagent`/`workflow`/`teammate`; shell tasks and monitors (passive watchers, e.g. the artifact comment watch) ignored; Qwen
  non-empty `background_tasks`/`crons`), `metadata` (`MetadataKey`). Never take a session id from inherited env
  (`CLAUDE_CODE_SESSION_ID`) when the payload has one.
* **opencode roll-up (owned here):** key by `SessionKey.fallback(agent: .opencode, identity:)` of the opencode process
  (the ancestry entry whose pid equals the payload's `pid`, else the nearest opencode ancestor; if none, fall back to
  the payload session id); keep the payload session id in `metadata[MetadataKey.opencodeSessionID]` (a child's in
  `opencodeChildSession`). Keep `opencodeBusy: [ProcessIdentity: Set<String>]` in the Mutex: `session.status{busy}`
  inserts, `session.status{idle}`/`session.idle`/`session.deleted`/`session.error` removes; emit `.turnStarted` only on
  empty → non-empty and `.turnFinished` (`.error` for `session.error`) only on non-empty → empty;
  `permission.asked`/`question.asked`/`form.created` → `.needsInput` on the process key; other child events → nothing.
* **Attribution** (deliberately differs from brief §4.4 order, see §11):
  1. `agent` = the NEAREST non-infrastructure ancestor that the injected matcher classifies
     (`matcher.match(ancestor.descriptor)`); else
  2. the argv label `AgentID(label:)`, except argv `claude` + `CURSOR_VERSION` set → `.cursor` (Cursor's
     settings.json route); else
  3. env markers (`CURSOR_VERSION` → cursor, `GEMINI_SESSION_ID` → gemini, `AI_AGENT`, `CLAUDE_PID` → claude).
  Copilot is relabelled `.vscode` only when NO `copilot` process is in the ancestry and `Code Helper (Plugin)` is (or
  the payload uses `hook_event_name` + PascalCase), recording `MetadataKey.relabelledFrom`. `agentProcess` = the
  nearest ancestor whose `match.agent == agent`; `CLAUDE_PID` binds only when `agent == .claude` and no other matched
  agent sits between the hook and that pid. `host` = `HostApp.from(environment:)`, else the nearest app ancestor.
* **Dedupe:** drop an event only when the previous ACCEPTED event for the same `sessionKey` has the same
  `dedupeIdentity` and `|Δ occurredAt| ≤ AgentEvent.dedupeWindow` (consecutive duplicates — a second `turnStarted`
  after a short turn is legitimate); keep `lastAccepted: [SessionKey: (identity, at, turnID)]` in the Mutex. Codex
  `notify` and Codex `Stop` with the same `turnID` collapse into one regardless of time.
* `lastEventSeen()` keyed by `AgentID(label: argvAgentLabel)` (the integration that delivered the event: Copilot-file
  events relabelled `.vscode` still prove `.copilot`), persisted atomically to `paths.lastEventsFile` at most once per
  minute and on `stop()`.

**Acceptance tests (minimum):**
1. Hook contract (spawn the built binary with `paths.helperEnvironment` + `KAKURENEKO_INBOX` + `KAKURENEKO_FALLBACK_INBOX`,
   all temp): exit 0; empty stdout and stderr; exactly one `.event` file whose header parses (`agent`, `event`,
   `pid`, `ppid`, `ts`, `cwd`), payload byte-identical to stdin; a fake `MY_SECRET_TOKEN`/`OPENAI_API_KEY` in the
   environment never appears; `TERM_PROGRAM` does; ancestry entries carry `path`, and `argv1` only when path-like.
2. Codex-style trailing JSON argv payload; `--chain -- /bin/sh -c 'touch <marker>'` runs the chained command (marker
   appears) and the hook does not wait for it; with a stdin payload, the chained argv is spawned UNCHANGED;
   (integration) a BARE program name on a temp `PATH` is found and gets the payload appended; not on `PATH` → logged,
   exit 0, event still delivered; `[python3, -m, aider]` parent (a `/bin/sh` stand-in, never a real interpreter) →
   ancestry `module == "aider"`.
3. `cursor beforeSubmitPrompt` prints exactly `{"continue":true}`; `cline TaskComplete` prints exactly `{"cancel":false}`.
4. `KAKURENEKO_INBOX=<temp>/ro` (chmod 0500) + `KAKURENEKO_FALLBACK_INBOX=paths.fallbackInboxDirectory` → the fallback
   inbox gets the file, exit 0. Bad/missing args → exit 0, no output, no file.
5. stdin held open by the parent → hook exits within ~0.5 s; median wall time over 20 runs < 50 ms (debug build OK);
   stdin = a pty slave (`posix_openpt`/`grantpt`/`unlockpt`) → exits in < 50 ms, payloadSource `none`.
6. `KAKURENEKO_RECORD=1` writes a recording.
7. Normalizer fixture tests for every row of brief §3.3 and the §3.4 family + Windsurf (raw payload JSON → expected
   `NormalizedEvent`, `sessionKey`, `turnID`, `backgroundTasksRunning`, previews sanitized), incl. the corrections
   above (`agent_completed`, `quota_auto_resume_*`, `SessionStart.source`).
8. Attribution: ancestry vs argv vs env; Copilot → VS Code relabel only without a `copilot` ancestor; codex notify
   whose ancestry is hook → sh → codex → zsh → claude with `CLAUDE_PID` set → agent `.codex`, `agentProcess` = the
   codex process; node + `…/codex.js` ancestor (via `argv1`) → codex.
9. Dedupe: consecutive duplicate within 2 s → one; `turnStarted, turnFinished, turnStarted` within 2 s → three; same
   event 3 s apart → two; Codex notify + Stop same turn → one.
10. opencode: two sessions of one process busy → idle(child) → idle(root) → exactly one turnStarted and one
    turnFinished on the process key.
11. `EventInbox` end to end on a temp home: subscribe, then `start()` → files written while stopped are delivered; a
    file dropped after start is emitted on `events()` within 1 s; files in both inboxes come out in global file-name
    order; garbage file → `bad/`; old `.tmp` entries GC'd; `lastEventSeen` survives a new `EventInbox` on the same home.

### 9.2 processes — `KakurenekoProcesses`

**Owns:** `Sources/KakurenekoProcesses/`, `Tests/KakurenekoProcessesTests/`.

**Must export:**
```swift
public struct AgentMatcher: AgentSignatureMatching { public init(paths: Paths) }
public struct LiveProcessLookup: ProcessLookup { public init() }
public final class ProcessScanner: ProcessSampling {
    public init(paths: Paths, matcher: AgentMatcher, clock: any KakurenekoClock = SystemClock(),
                logger: KakurenekoLogger = KakurenekoLogger(.processes))
}
```

**Read:** brief §5.3, §5.4, §6.3 (P-A…P-E inputs), §9.4; R08 §7 (verified libproc/sysctl signatures, costs, the
125/3 timebase, `proc_pidpath` nil after auto-update, comm = version string); R06 §2.4, §3.2–3.3 (identity, pty map,
socket peers, listeners); R04 §2.6, §7.5 (signature table); R03 §9, R05 §5 (evidence costs, model endpoints); R02 §4
(incl. §4.1: Claude respawns `caffeinate -i -t 300` every ~4 min while busy).

**Behaviour:**
* `sample(now:)` (`@concurrent`): `proc_listallpids` + `PROC_PIDT_SHORTBSDINFO` for all pids filtered to
  `uid == getuid()`; identity from start time; argv/path only for new identities (cache by identity, reused 64 KiB
  `KERN_PROCARGS2` buffer: argv plus ONLY the env allow-list `VSCODE_ESM_ENTRYPOINT`, `__CFBundleIdentifier`,
  `TERM_PROGRAM`, `CLAUDE_CODE_ENTRYPOINT` into `ProcessDescriptor.environment` — never store or log any other
  variable); match with `AgentMatcher`; for matches compute ancestry (via `KERN_PROC_PID`, works through root-owned
  `login`), host app (`HostApp.from(environment:)` first, else the first ancestor whose executable is inside an
  `.app` bundle → `HostApp.from(bundleID:)`), descendants, cwd, tty (`e_tdev` → `devname`), `isInfrastructure`,
  `isIDEHost`, evidence. Fill `uniqueID`/`pidVersion` where cheap (flavor 17 / audit token) — optional.
* `AgentMatcher`: the full brief §5.3 table + R04 §7.5 long tail. Match on exe path + argv[0]/argv[1] basenames, never
  on `p_comm` alone; exclude `ugrep`/`rg`; `claude daemon`, `claude bg-pty-host`, `claude bg-spare`, `goosed`,
  `kiro-cli-term` are infrastructure (or ignored); `codex app-server` and the VS Code agent host (env
  `VSCODE_ESM_ENTRYPOINT=…agentHostMain`) are IDE hosts. Claude path rules include `~/.local/share/claude/versions/`,
  `ClaudeCode.app/Contents/MacOS/claude`, `…/Claude/claude-code/*/claude`,
  `anthropic.claude-code-*/resources/native-binary/claude`, `CodingAssistant/Agents/Versions/*/claude`. It must work
  on the reduced descriptors built from hook ancestry (`InboxAncestor.descriptor`: path + argv0 + optional argv1, or
  (integration) `[argv0, "-m", module]` for a recorded Python module).
* Evidence (§5.4; window = `EvidenceSample.window`): E1 tree CPU ≥ 3 % of one core over 60 s (`proc_pid_rusage` V4, ticks × `mach_timebase_info`),
  E2 any new descendant in 60 s that is NOT (a) `caffeinate` (exe basename or argv0), (b) matched as agent
  infrastructure, (c) a respawn with the same argv as a descendant of the same tree that exited within the last
  10 min (keep `recentlyExitedArgv: [String: Date]` per tree) — otherwise Claude's caffeinate respawns keep E2 alive
  forever and the stall guard never fires; E3 any write in 60 s to the hinted paths (`updateSessionStoreHints`;
  FSEvents, started in `start()`), E4 a new ESTABLISHED TCP connection to the model-API set (Anthropic
  `160.79.104.0/23`, `2607:6bc0::/48` + IPs resolved every 10 min for the brief's host list) or a socket-count
  change, E5 tty mtime within 30 s, E6 `IOPMCopyAssertionsByProcess` assertion owned by the agent or by a
  `caffeinate` whose ppid is the agent (never a lone `"Electron"` assertion). Keep per-identity history internally;
  report `active`, `treeCPUPercent`, `treeCPUSeconds` (cumulative, for the pause watchdog), counts and timestamps.
  The sustain/exit windows are the SessionEngine's job.
* `topology(for:now:)` (`@concurrent`, ~60 ms budget): agent + descendant identities, tty set, pty-master holders
  (R06 §3.2: `/dev/ptmx` fds whose `vst_rdev` minor equals an agent tty minor), ancestor pids, agent-launched app pids
  (processes inside an `.app` with an agent ancestor, e.g. Playwright Chrome), IPC peers (Unix `unsi_conn_so` ↔ `soi_so`,
  loopback TCP port pairs, pipe handle pairs) and listener owners (P-D), automation helpers (`osascript`, `open`,
  `shortcuts`, `mcpbridge`, `simctl`, `xcodebuild` in agent trees with likely targets: Xcode for `mcpbridge`/`xcodebuild`,
  Simulator for `simctl`, default browser for `open <url>`, unknown otherwise). Set `isComplete = false` if a probe
  failed. Leave `sessionHostPIDs` empty (the coordinator fills it).
* `LiveProcessLookup.identity(of:)`: `sysctl(KERN_PROC_PID)`; nil when gone. It may simply wrap Kit's
  `KernelProcessLookup` (+ optional enrichment); its tuple must equal `KernelProcessLookup`'s.
* Strictly read-only: never signal, never `setpriority`.

**Acceptance tests:** `LiveProcessLookup` returns the test process's own identity (equal to `KernelProcessLookup`'s)
and nil for a dead pid; a child the test spawns (`/bin/sleep 5`) appears in the test process's descendants with the
right ppid; timebase is 125/3 on Apple Silicon (skip on Intel); matcher fixture table covering every §5.3 row and the
R04 long tail (positive and negative cases: version-string comm, replaced binary with nil path, `claude bg-spare`,
`ugrep`, node + `codex.js`, two-process Gemini, cursor-agent `index.js`, `python -m aider`, `python3.12 …/bin/aider`
via `InboxAncestor.descriptor`, VS Code agent host via env); evidence computations as pure functions over synthetic
histories (E1 threshold and 60 s window, E2 churn, **caffeinate respawned every 240 s → E2 never active**, same-argv
keep-alive respawn → not E2, E6 attribution incl. the Electron exclusion); topology builder as a pure function over
synthetic fd/process tables (pty minor matching, socket pairing, listener ownership, helper targets); `sample()`
completes in < 200 ms in debug on this machine.

### 9.3 sessions — `KakurenekoSessions`

**Owns:** `Sources/KakurenekoSessions/`, `Tests/KakurenekoSessionsTests/`.

**Must export:**
```swift
public final class SessionEngine: SessionTracking {
    public init(timers: SessionTimers = SessionTimers(), logger: KakurenekoLogger = KakurenekoLogger(.sessions),
                initialStateVersion: Int = 0)
}
public final class ClaudeStateWatcher: ClaudeStateSource {
    public init(paths: Paths, subprocess: any SubprocessRunning, processes: any ProcessLookup,
                clock: any KakurenekoClock = SystemClock(), logger: KakurenekoLogger = KakurenekoLogger(.sessions))
}
```

**Read:** brief §5.1–5.6, §8.4 (title rule, `{project}`), §2 C3/C5; R02 §3–5, §8 (record schema, status semantics,
`agents --json`, transcripts incl. `system/turn_duration` §5.2/§8.2, the 13 h case §4.1, session_crons §3.4,
parked records §3.2), R04 §7.4.

**`SessionEngine`** (synchronous, deterministic, Mutex-protected; no clock, no I/O). `stateVersion` starts at
`initialStateVersion`. Ignore an `AgentEvent.id` already ingested (bounded set of the last 4,096 ids). Internal
per-session state includes `hasStartEdge` (set by a T1 `.turnStarted`, a T2 record `busy` or a bg `working`),
`hooksLive` (any T1 event seen for this session), the pending settle outcome and `stopSeenThisTurn`.
* **Transitions** (§5.2, precedence liveness > record > hooks > heuristics):
  * `.sessionStarted` creates the session (`.idle(since: now, outcome: nil)`) if missing and refreshes
    cwd/host/metadata; it NEVER changes the state of an existing session (`SessionStart source: compact` fires
    mid-turn).
  * `turnStarted` / record `busy` / bg `working` / T3 working → `.working` (refresh `lastProgressAt`, set
    `turnStartedAt` on entry); `stateVersion += 1` on every entry into working for a NEW turn (not when settle expiry
    returns a session to working, below).
  * `activity` → refresh progress (`.idle` → `.working` only for agents without a turnStarted event: Crush, Auggie;
    `.waiting` → `.working`, see waiting exit).
  * `turnFinished(o)` → `.settling(until: now + settle, outcome: o)` (records `stopSeenThisTurn`). Codex sub-threads:
    a `turnFinished` for a session that never entered working, whose `agentProcess` has another `.working` session of
    the same agent, is treated as `.activity` for that other session.
  * **Settle expiry** (`tick`): a continuation arrived → already working; `backgroundTasksRunning` → `.working`
    (stay); Claude session whose record exists and is `busy` (e.g. a pending session cron, R02 §3.4) →
    `.working(since: turnStartedAt ?? now)`, no effect, `stateVersion` unchanged, pending outcome kept — the finish is
    emitted later by `ingest(claudeState:)` when the record goes `idle`/`shell`; otherwise → `.idle(o)` + `finished`
    effect (never for `.interrupted`) with `workedFor = now − turnStartedAt`.
  * **Record busy → idle/shell:** with a Stop this turn → `.idle(pendingOutcome)` + `finished` (if not already
    emitted). Without a Stop this turn: hooks live for this session → `.idle(.interrupted)`, no effect; else (T2-only:
    plugin not loaded yet, brief C3) if `observation.lastTurnCompletedAt ≥ turnStartedAt` and
    `(lastTurnPendingBackground ?? 0) == 0` → `.idle(.completed)` + `finished` with
    `workedFor = lastTurnDurationMs / 1000`; else `.idle(.interrupted)`, no effect.
  * `needsInput(k)` / record `waiting` (+`waitingFor` → kind: "permission prompt" → permission, "input needed" →
    question, "dialog open" → dialog, else unknown) / bg `blocked` → `.waiting` + one `needsInput` effect per wait.
  * **Waiting exit** (many agents send no resume edge after an approval: Codex `PermissionRequest`, Gemini
    `Notification(ToolPermission)`, Copilot `permission_prompt`): `.waiting` → `.working` (`stateVersion += 1`) on a
    T1 `turnStarted`/`activity`, a T2 `busy`/bg `working`, or — only for sessions WITHOUT a T2 record — progress
    evidence on the bound process (≥ 2 kinds including one of E1/E2/E4) sustained ≥ `heuristicSustain`, (integration)
    counting only samples taken ≥ `EvidenceSample.window` (60 s) after `since` — earlier samples still describe the
    work that produced the prompt (the remote approval is detected ~80 s after the prompt, never falsely at ~20 s). Record `idle`/`shell` → `.idle(nil)`; `turnFinished` → settling. No second `needsInput` for the same wait.
  * `StopFailure rate_limit` / quota → `.idle(.rateLimited)` (+ `finished` effect with that outcome; never working);
    `idleReminder` → nothing; `sessionEnded` / record dead (`identity == nil`) / record deleted (only while
    `sessionsDirectoryReadable`) / process gone → `.ended` + `ended` effect; drop ended sessions after
    `endedRetention`.
* **Stall guard:** `(state.isWorking || state.isSettling) && now − lastProgressAt ≥ stall` → `.stalled` + one
  `stalled` effect; progress evidence (hook event or `EvidenceSample.showsProgress` for the bound process) while
  stalled → `.working`. (fix, §11.C) Evidence progress = a kind that proves work: E1, E2 or E3 (`countsAsProgress`).
  E4/E5 alone never count — idle Claude TUIs write their tty and open a fresh model-API connection every few minutes
  (measured), which kept the R02 §4.1 stale-busy session out of `.stalled` forever. A session bound to an IDE host
  (`isIDEHost`: the extension host holds every extension) gets no progress from that tree when it has a start edge
  (its hooks report tool activity), and only together with E4 when it is driven by heuristic turns (Codex
  `app-server` notify-only); the waiting exit on an IDE host also needs E4.
* **T3 heuristic sessions** (`ingest(processes:)`): a heuristic session (key `SessionKey.fallback`) is created only for
  an `AgentProcess` p where `!p.isInfrastructure`, `(!p.isIDEHost || p.evidence.active.contains(.modelAPISocket))`,
  p is not in the latest `ClaudeStateSnapshot.ignoredIdentities` (parked/spare/daemon), no ancestor or descendant of p
  with the same agent is bound to a session, and no other matched process with the same agent has p in its
  `descendants` (the outermost same-agent process owns the tree: Gemini's two node processes, the Codex npm wrapper,
  Claude teammates and nested `claude -p` are ONE session). Sketch:
  `let relatives = Set(p.ancestors.map(\.identity)).union(p.descendants); let owned = snapshot.agents.contains {
  $0.agent == p.agent && ($0.descendants.contains(p.identity) || (relatives.contains($0.identity) && bound.contains($0.identity))) }`.
  `meetsHeuristicThreshold` sustained ≥ `heuristicSustain` → `.working`; fewer than two kinds for `heuristicExit` →
  `.idle(nil)` + `wentQuiet` effect.
* **Bound sessions without a start edge** (Codex notify-only — the default until hooks are trusted —, agy Stop-only,
  Aider bell-only, Auggie, Cursor `-p`): run the same heuristic tracker on their `agentProcess`'s evidence: ≥ 2 kinds
  sustained `heuristicSustain` → `.working` (`stateVersion += 1`); < 2 kinds for `heuristicExit` → `.idle(nil)` +
  `wentQuiet`, skipped when a T1 `turnFinished` already settled that turn. T1 finishes end the turn as usual. Bound
  sessions WITH a start edge use evidence only for progress (stall guard) and the waiting exit.
* **Liveness from T3:** a session whose `agentProcess` was seen in a `ProcessSnapshot` and is absent from two
  consecutive snapshots → `.ended`. (fix) A bound process no snapshot ever contained is checked with the injected
  `ProcessLookup` (brief §3.2 T4, start-time match): dead on two consecutive snapshots → `.ended(processGone)`;
  alive but unclassified → kept. Without a lookup (`processes: nil`) such sessions are not ended by T3.
* **Replayed inbox files (fix):** an event whose `occurredAt` is more than `staleEventAge` (10 min) before its
  `receivedAt` (written while Kakureneko was not running; the launch drain replays up to 5,000 files) is history: it
  may refresh the descriptive fields of an existing session but never creates a session, changes a state or produces
  an effect (a 3-day-old `Stop` used to push a fresh "finished").
* **Binding & merging:** a T1 session with `agentProcess == nil` binds to the UNIQUE unbound, non-infrastructure
  `AgentProcess` with the same agent and cwd. When a T1/T2 session binds an `agentProcess` that has a fallback-keyed
  session, merge into the real key (keep the earliest `turnStartedAt`, union tiers) — no second session, no second push.
  (fix) Also merge the fallback session of any same-agent process in the same tree (ancestors, descendants, processes
  listing it as a descendant): T3 keys a heuristic session by the OUTERMOST process while a hook binds the NEAREST
  matched ancestor (npm Codex's node wrapper vs the native child, Gemini's two node processes) — it used to stay a
  second session with a duplicate "went quiet" and 5 extra working minutes per turn.
* **T2 merge** per sessionId: interactive status from the record when `record.statusUpdatedAt ≥ agentsPolledAt`, else
  from `agents --json`; background `state` (working/blocked/done/failed/stopped) only from `agents --json`; entries
  with no record (alive bg) from `agents --json`; `sessionsDirectoryReadable == false` never ends sessions. (fix) A
  record rewrite (same status, new `statusUpdatedAt`) is an edge only when the merged status reflects that record
  (a stale entry that outvoted it must not turn into an edge — it finished working turns as interrupted and lost
  finishes), and the watcher stamps `agentsPolledAt` when the CLI STARTS (a record written while it ran is fresher).
* **Fields other modules read (binding):** `metadata[MetadataKey.transcriptPath]` from `AgentEvent.transcriptPath` /
  `ClaudeSessionObservation.transcriptPath` (latest wins) and `metadata[MetadataKey.sessionStoreDirectory]` (the
  transcript path minus `.jsonl`) — the coordinator builds E3 hints from them ((fix) for Claude only the
  `sessionStoreDirectory` subtree: brief §5.4, the main transcript alone is not progress — idle sessions append
  `away_summary`/wake metadata); `remoteControlConnected` =
  `record.bridgeSessionId != nil`; `metadata[claudeKind]`/`[claudeJobID]`/`[claudeEntrypoint]` from the record;
  `title` (observation/event), `cwd` (observation `currentCwd` beats the record's launch cwd), `lastMessagePreview`,
  `waitingFor`, `lastTurnDuration` on every finish.
* `aggregate` via `SessionAggregate.compute` (+ your `stateVersion`, `lastFinishedAt`). `sessions` sorted by
  `displayRank`, then most recent activity.

**`ClaudeStateWatcher`:** read-only. Watch `paths.claudeSessionsDirectory` with FSEvents
(`kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer`, latency 0.2 s; or per-record `O_EVTONLY` vnode
sources `[.write, .extend, .attrib, .delete, .rename]` re-armed on directory changes) — Claude rewrites `<pid>.json` IN
PLACE, which a directory vnode does not report —, debounce 250 ms, PLUS an mtime sweep of `*.json` every
`SamplingCadence.processScanInterval`; tolerate the directory not existing (re-check every 60 s). Read only
`ClaudeSessionRecord.isRecordFileName` files, never `*.key`; ignorable records → their LIVE identities go to
`ignoredIdentities`; liveness = `processes.identity(of: pid)` with `|identity.startSec − procStartEpochSeconds| ≤ 1`;
resolve the transcript (`projects/*/<sessionId>.jsonl`), read only its last ≤ 256 KB backwards for the title
(custom-title → agent-name → ai-title → `record.humanName`), current cwd (last entry's `cwd`), last assistant preview
(sanitized) and the last `system`/`turn_duration` entry (timestamp, `durationMs`, `pendingWorkflowCount +
pendingBackgroundAgentCount`); re-read the tail 1–2 s after a busy → idle change (turn_duration is written just after
the turn). Poll `claude agents --json --all` with the resolved CLI path (`paths.claudeCLICandidate`, else one
`/bin/zsh -lc 'command -v claude'`), stdin `/dev/null`, `extraEnvironment: paths.agentSubprocessEnvironment` +
`DISABLE_AUTOUPDATER=1` + `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, `effect: .readOnly`, timeout 10 s, at the
cadence set by `setCadence` (15 s closed / 60 s open); emit a full `ClaudeStateSnapshot` after every change and poll.
Respect `CLAUDE_CONFIG_DIR` (already in `Paths`). Never write anything under the Claude config dir. Tests MUST use
`FakeSubprocessRunner`.

**Acceptance tests:** the 13 h replay (record `busy`, E6 present, no E1–E5 → `.stalled` exactly at +20 min, one
effect, not working); turnStarted → turnFinished → `finished` at exactly +5 s with `workedFor`; continuation inside
settle cancels it; Claude Stop while the record is still `busy` → working (no effect) at settle expiry, `finished` when
the record goes idle; Stop + record busy for 25 min with no evidence → `.stalled` at +20 min and
`aggregate.anyWorking == false`; busy → idle without Stop with hooks live → interrupted, no effect; **T2-only busy →
idle with a later `turn_duration` → exactly one `finished`** (workedFor from durationMs); one needsInput effect per
wait (second `needsInput` while waiting → none); Codex `PermissionRequest` then E1+E4 → still waiting during the first
evidence window however long it lasts, then 20 s of E1+E4 → working (at +80 s), no repeated needsInput; idleReminder → none; `sessionStarted(compact)` while working → still working; rateLimited never counts as
working; background tasks keep working; T3 sustain (19 s → not working, 20 s → working) and exit window →
`wentQuiet`; **Codex notify ×2 with T3 evidence between them → working → finished, twice**; T3 candidate rules
(Gemini parent+child node → one session; IDE host without E4 → none; ignored identity → none; descendant of a bound
same-agent process → none); duplicate `AgentEvent.id` ignored; ended retention 10 min; `stateVersion` starts at
`initialStateVersion` and increments on each new entry into working (not on settle-expiry re-entry); fallback-key
merge; metadata fields above populated; (fix) the 13 h replay with an E5 (or E4+E5) blip every 16/25 min still stalls
once and never revives; an IDE host's extension noise neither feeds the stall guard nor ends a wait; npm Codex wrapper +
native child = one session, one finish per turn; replayed days-old files produce nothing; a dead never-seen process
ends after two snapshots; a poll racing a record write neither ends a working turn nor loses a finish; watcher on a temp `~/.claude/sessions` with the R02 sample records +
`StaticProcessLookup` + `FakeSubprocessRunner` returning the R02 `agents --json` sample: parked/spare/daemon ignored
(live ones in `ignoredIdentities`), `.key` never opened, dead pid → `identity == nil`, title + turn_duration extracted
from a fixture transcript, **record rewritten in place (`FileHandle` truncate + write, no rename) → snapshot with the
new status within 1 s** (TestClock-advanced debounce), recorded CLI requests carry `agentSubprocessEnvironment`.

### 9.4 power — `KakurenekoPower`

**Owns:** `Sources/KakurenekoPower/`, `Tests/KakurenekoPowerTests/`.

**Must export:**
```swift
public final class PowerController: PowerControlling {
    public init(paths: Paths, privileged: any PrivilegedCommandRunning, systemSleep: any SystemSleeping,
                shutdown: any ShutdownRequesting, displaySleep: any DisplaySleeping, dryRun: DryRunGate,
                clock: any KakurenekoClock = SystemClock(), logger: KakurenekoLogger = KakurenekoLogger(.power),
                ledger: DryRunLedger? = nil)   // (integration) wired explicitly by LiveComposition
}
public final class PowerMonitor: PowerEventSource {
    public init(power: any PowerControlling, clock: any KakurenekoClock = SystemClock(),
                logger: KakurenekoLogger = KakurenekoLogger(.power))
}
public final class SafetyMonitor: SafetyEvaluating { public init(logger: KakurenekoLogger = KakurenekoLogger(.power)) }
public final class PrivilegedInstaller: PrivilegedInstalling {
    public init(paths: Paths, privileged: any PrivilegedCommandRunning, subprocess: any SubprocessRunning,
                administrator: any AdministratorScriptRunning, clock: any KakurenekoClock = SystemClock(),
                logger: KakurenekoLogger = KakurenekoLogger(.power),
                dryRun: DryRunGate? = nil)     // (integration) the gate install()/uninstall() consult; wired explicitly
}
// Real side effects (the coordinator wraps them with SideEffects.gated; they receive the REAL subprocess runner)
public struct SudoPrivilegedCommandRunner: PrivilegedCommandRunning { public init(subprocess: any SubprocessRunning) }
public struct IOPMSystemSleeper: SystemSleeping { public init(subprocess: any SubprocessRunning) }
public struct LoginWindowShutdownRequester: ShutdownRequesting { public init() }
public struct PmsetDisplaySleeper: DisplaySleeping { public init(subprocess: any SubprocessRunning) }
public struct AppleScriptAdministratorRunner: AdministratorScriptRunning { public init() }
```

**Read:** brief §1, §2 C9/C13, §7.1–7.5; R01 §2, §5.2–5.5 (scripts verbatim — rename Lidless → Kakureneko, `lidless` →
`kakureneko`, `dev.lidless.failsafe` → `com.kakureneko.failsafe`), §6, §11.2; R08 §8 (verified IOKit trampolines +
constants), §9; R07 §14 (sleep notification window).

**Behaviour:**
* **Testability (binding shape):** the public binding init forwards to an INTERNAL designated init that also takes
  internal protocols `RootDomainReading` (IOPMrootDomain `SleepDisabled`/`AppleClamshellState`) and
  `PowerAssertionMaking` (IOPMAssertion + `beginActivity`), defaulting to the live ones. Kernel polling uses
  `clock.sleep(for: .milliseconds(100))`, ≤ 50 times. Tests inject fakes for both (never a real assertion, never 5 s
  of real polling). Store the `beginActivity` token boxed (`ActivityToken`, §5).
* `kernelFlags()`: `IOPMrootDomain` `SleepDisabled` + `AppleClamshellState` (never `AppleClamshellCausesSleep`).
  `kernelSleepDisabled` is ALWAYS the real value; in dry-run `sleepDisabled` is the simulated flag and
  `isSimulated == true`.
* `arm()`: `privileged.run(.setSleepDisabled(true))` (non-zero exit → `SideEffectError.notPermitted(stderr)`), poll
  the kernel flag every 100 ms up to 5 s (→ `.timedOut`), create the `PreventUserIdleSystemSleep` assertion
  `KakurenekoID.powerAssertionReason`, `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep, reason:
  KakurenekoID.activityReason)`, touch the heartbeat; remember `armedForReal = !dryRun.isOn`. Dry-run: simulate, no
  assertion, no heartbeat.
* `disarm()`: never short-circuits on internal state — whenever `kernelSleepDisabled == true` (gate off) it runs
  `.setSleepDisabled(false)` and polls for `false` (launch reconcile must clear a flag left by a crashed process); a
  no-op only when the kernel reads false; releases assertion + activity. If the gate state differs from the one used
  at arm time → log an error and throw `SideEffectError.failed("dry-run toggled while really armed")`.
* `disarmSynchronously(timeout:)`: termination path only (non-async signal-source handler): if `armedForReal`, run the
  injected `privileged.run(.setSleepDisabled(false))` in a detached task and wait ≤ `timeout` on a semaphore; true
  when clear. Never spawns anything itself (keeps tests on the injected runner). (fix) A REAL arm whose
  `disablesleep 1` already went out but which has not finished (read-back poll) counts as armed; the call latches
  "terminating" so every later `arm()` throws; a real arm whose command throws (sudo timeout) or fails while the flag
  reads set is reverted unless the flag was already set before it.
* `touchHeartbeat()`: only when `armedForReal`: create/update `paths.heartbeatFile` (0600, dir 0700), mtime = now. In
  dry-run (or not really armed): ledger `power.heartbeat` ("would touch heartbeat") and return.
* `sleepNow()` / `requestShutdown()` / `displaySleepNow()` / (fix) `scheduleDetachedSleep(after:)` delegate to the
  injected side effects. `playLidCloseChime()`
  plays `NSSound(named: "Submarine")` (main thread).
* `snapshot()`: IOPS (percent, AC, charging, time to empty, `IOPSGetBatteryWarningLevel`), `AppleSmartBattery`
  `InstantAmperage < 0` on AC, `ProcessInfo.thermalState`, `notify_get_state("com.apple.system.thermalpressurelevel")`,
  `isLowPowerModeEnabled`, a long-lived `NWPathMonitor` (satisfied/expensive), external display
  (`CGGetOnlineDisplayList` + `CGDisplayIsBuiltin`), `CGEventSource.secondsSinceLastEventType(.combinedSessionState,
  eventType: CGEventType(rawValue: ~0)!)`, `CGSessionCopyCurrentDictionary` `CGSSessionScreenIsLocked`, both flags.
  `@concurrent`.
* `PowerMonitor`: broadcaster `AsyncBroadcaster<PowerEvent>(replayLatest: true, replayFilter: { $0.isSnapshot })`
  (never replays a stale edge); clamshell interest notification (`0xE0034100`, bit 0, edge-detected against the last
  state) + 1 Hz `AppleClamshellState` poll backup — the same poll emits `.userActivity(secondsSinceInput:)` while the
  lid is closed and `secondsSinceUserInput` drops below 2 s (at most once per 10 s); `IORegisterForSystemPower`:
  answer `kIOMessageCanSystemSleep` immediately with `IOAllowPowerChange`, for `kIOMessageSystemWillSleep` emit
  `.willSleep(acknowledger)` and auto-allow after 8 s if the consumer has not; `.didWake`; NSWorkspace
  `willPowerOff`, `sessionDidResignActive`/`BecomeActive` (observers created in this nonisolated module, `@Sendable`
  closures); display reconfiguration → `.externalDisplayChanged`; `.snapshot` every 15 s and on change. `stop()` tears
  everything down (`IODeregisterForSystemPower`, `IONotificationPortDestroy`).
* `SafetyMonitor` (§7.4, deterministic): `evaluate` — on battery and `!allowOnBattery` → `.onBatteryNotAllowed`;
  battery ≤ floor, `warningLevel ≥ .early`, `timeToEmpty < minimumTimeToEmptyMinutes`, draining on AC below the floor;
  thermal `.critical` or pressure ≥ `.trapping` → immediately; `.serious` or pressure `.heavy` continuously for
  `thermalSeriousSeconds` → trip; network unsatisfied continuously for `networkOfflineMinutes`; `now − closedSince ≥
  maxClosedLidHours` → `.maxDuration`. Low Power Mode never trips. `reset()` clears durations. `armingBlocker` —
  STATELESS (R01 §11.2): on battery && `!allowOnBattery`, battery ≤ floor, warning ≥ early, timeToEmpty < limit,
  draining on AC below floor, thermal ≥ `.serious`, pressure ≥ `.heavy` → the matching `SafetyTrip`; never touches
  `evaluate`'s durations.
* `PrivilegedInstaller`: `scripts()` generates `install-privileged.sh` (R01 §5.3 renamed, with these input checks:
  `[[ "$U" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]]` (short names may contain a dot) and `[[ "$HB" == /* && "$HB" != *..* ]]`
  (homes outside /Users are valid); sudoers drop-in `/private/etc/sudoers.d/kakureneko` with
  `# Installed by Kakureneko. Delete this file to revoke.` and
  `<user> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0`; root support dir;
  LaunchDaemon `com.kakureneko.failsafe` with RunAtLoad + StartInterval 60; `xattr -c`; bootout + bootstrap; `visudo -c`),
  `kakureneko-failsafe.sh` template (R01 §5.4 renamed: 150 s heartbeat, 7 % floor, clear flag, `pmset sleepnow` if the lid
  is closed; the heartbeat path on ONE parseable line, e.g. `HB='<path>'`), the plist, and `uninstall-privileged.sh`
  (brief §7.1 uninstall list). `install()`: throws `SideEffectError.failed("KAKURENEKO_HOME override")` when
  `paths.isHomeOverridden` and the gate is off; else calls `administrator.runAsAdministrator(script: installScript,
  name: "install-privileged.sh", arguments: [userName, heartbeatPath])`. (fix, §11.C) Nothing root runs or installs
  comes from a file: the scripts travel INLINE (`bash -c`), the fail-safe template is embedded in the install script
  as a quoted heredoc (`sed` substitutes the heartbeat into `$FAILSAFE.new`, then `mv -f`), and no script is written
  to `paths.installScriptsDirectory` any more (it was rewritable by any same-user process while the password dialog
  was open: same-user → root code execution). `healthCheck()` = `privileged.run(.checkSudoRule)` exit 0 AND
  `subprocess` `/bin/launchctl print system/com.kakureneko.failsafe` (`.readOnly`) exit 0 AND (read-only) parse
  `failsafeHeartbeatPath` from `RootPaths.failsafeScript`; `heartbeatPathMismatch = parsed != paths.heartbeatFile`
  (+ `detail`), which makes it not operational; (fix) with the daemon loaded, a missing, unparseable or edited
  fail-safe (text ≠ `failsafeScript(heartbeatPath: parsed)`) or a missing/different LaunchDaemon plist sets
  `failsafeScriptMismatch` (not operational, warning `failsafe-damaged`); a file the user cannot read is only
  reported. The fail-safe also treats a heartbeat mtime > 60 s in the FUTURE as stale (`heartbeatVerdict`).
* Real side effects: `IOPMSleepSystem(IOPMFindPowerManagement(MACH_PORT_NULL))`, retry once on `0xE00002E2`, fallback
  `/usr/bin/pmset sleepnow` (`.mutating`); (fix) `scheduleDetachedSleep(after:)` = `posix_spawn` of `/bin/sh -c
  'sleep "$1"; ioreg … AppleClamshellState = Yes && exec /usr/bin/pmset sleepnow'` with `POSIX_SPAWN_SETSID`, /dev/null
  stdio, never waited for; polite shutdown via Apple Event `kCoreEventClass`/`kAEShutDown` to
  `com.apple.loginwindow` (`AEDeterminePermissionToAutomateTarget` is the app's onboarding job); `pmset displaysleepnow`;
  `NSAppleScript` `do shell script "/bin/bash -c " & quoted form of <script> & " " & quoted form of <name> & … with
  administrator privileges` on the main thread.

**Acceptance tests (no real pmset/sudo/sleep/admin prompt — dry-run gates and fakes only):** SafetyMonitor table tests
for every guard incl. the 60 s/15 min durations and reset, and `armingBlocker` for every blocker (and that it leaves
`evaluate`'s durations untouched); generated install/failsafe/uninstall scripts pass `bash -n`, the plist passes
`plutil -lint`, the sudoers fragment passes `/usr/sbin/visudo -cf <tempfile>`, exact sudoers line and labels/paths
renamed (no "lidless" anywhere), the install script's checks accept `john.smith` and `/Volumes/x/home/.kakureneko/run/heartbeat`
(run the validation snippet with `bash -c`, never the script); `PowerController` with injected fake root-domain /
assertion makers and a `TestClock`: dry-run `arm()` → `kernelFlags().sleepDisabled == true` while
`kernelSleepDisabled` stays the fake kernel value, ledger has `power.arm`, `touchHeartbeat()` writes NO file (ledger
`power.heartbeat`), `disarm()` reverses; gate off + fake runner: success and timeout paths of the read-back poll,
`disarm()` runs the command when the kernel reads true even without a prior arm, gate flipped between arm and disarm
→ throws; failing fake runner → `arm()` throws `.notPermitted`; really-armed `touchHeartbeat()` updates mtime under a
temp home; `disarmSynchronously` uses the injected runner; `healthCheck()` maps fake subprocess results and detects a
heartbeat-path mismatch; `install()` refuses a temp home with the gate off; `snapshot()` returns sane ranges
(read-only); `PowerMonitor` start/stop does not crash and a late subscriber gets only a `.snapshot`; the 8 s auto-ack
and the `.userActivity` rate limit are unit-tested internal components.

### 9.5 pause — `KakurenekoPause` + `kakureneko-guard`

**Owns:** `Sources/KakurenekoPause/`, `Sources/KakurenekoGuard/`, `Tests/KakurenekoPauseTests/`.

**Must export:**
```swift
public final class PauseManager: AppPausing {   // may become an actor (then installCrashHandlers/thawAllSynchronously/startGuard/stopGuard must be nonisolated)
    public init(paths: Paths, signaller: any ProcessSignalling, processes: any ProcessLookup, dryRun: DryRunGate,
                guardExecutable: URL?, clock: any KakurenekoClock = SystemClock(),
                logger: KakurenekoLogger = KakurenekoLogger(.pause),
                ledger: DryRunLedger? = nil)   // (integration) `pause.guard`; wired explicitly by LiveComposition
}
public struct AuditTokenSignaller: ProcessSignalling { public init() }
```
plus the `kakureneko-guard` CLI (contract in `Sources/KakurenekoGuard/main.swift` header — binding) and, if the guard needs
shared code, public types prefixed `Pause` (e.g. `public enum PauseRecovery`).

**Read:** brief §6 (all), §2 C16; R06 (all: mechanisms, responsibility API, identity, ordering, pty reasoning,
protection rules A–L, static never-list §3.4, journal §4.1, defense in depth §4.2, recommendations §5).

**Behaviour:**
* **Isolation:** `pause`, `recheck`, `recoverFromJournal`, `selfTest`, `thawAll`, `observe` are `@concurrent` (heavy
  syscall load: ~600 responsibility lookups, fd scans, CoreAudio, F_FULLFSYNC). Identity lookups use the injected
  `ProcessLookup` (Kit's `KernelProcessLookup` in the guard).
* **Grouping** (internal protocol `ProcessGrouping`): `{main} ∪ {p : uid == me ∧ responsible(p) == main}` with
  `responsibility_get_pid_responsible_for_pid` via `dlsym(RTLD_DEFAULT, …)`; fallback coalition (`proc_pidinfo`
  flavor 20), then ppid descendants. `selfTest()` reports the method; `freezeAllowed` only for responsibility/coalition.
* **Candidates:** `NSWorkspace.shared.runningApplications` with `.regular`, `isFinishedLaunching`, launched before the
  pause began, same uid. Decisions keyed by pid + audit token, never bundle id. Never Kakureneko itself. **Rule I:** if
  ANY group member has a controlling tty (`kinfo_proc.kp_eproc.e_tdev != NODEV`, read for all members via
  `sysctl KERN_PROC_PID`), protect the whole group with `.notCandidate` (tty jobs must never be signalled — job
  control, and agents the signature table missed).
* **Protection** P-A…P-K exactly as brief §6.3 using the `AgentTopology` (P-A1 via your grouping over
  `allAgentTreePIDs`, P-A2 `ptyMasterHolderPIDs`, P-A3 `ancestorPIDs`, P-A also `sessionHostPIDs` (in-app agents —
  any group containing one is protected), P-B `agentLaunchedAppPIDs`, P-C/P-D `ipcPeers`, P-E `automationHelpers` —
  empty targets → protect/thaw everything), P-F CoreAudio process objects
  (`kAudioHardwarePropertyTranslatePIDToProcessObject` + `kAudioProcessPropertyIsRunningOutput/Input`), P-G download fds
  → Throttle only, P-H `PROC_FLAG_TRACED`, P-I > 20 % of one core over the last 2 min (from the `observe(now:)`
  history; no history → assume busy → Throttle only), P-J the static never-list (R06 §3.4 + `KakurenekoID.bundleIdentifier`),
  P-K `settings.neverPauseBundleIDs` / `settings.enabled`. `topology.isComplete == false` → no Freeze at all. Never
  infer "no agent" from `topology.isEmpty`.
* **Enrichment first:** before journaling, enrich EVERY member's identity (fresh audit token `val[7]` → `pidVersion`,
  flavor 17 `p_uniqueid` → `uniqueID`). Members that cannot be enriched are neither journaled nor signalled
  (`PauseJournalRecord.init?(identity:…)` returns nil; the signaller refuses pausing un-enriched targets anyway).
* **Modes:** Throttle (default) — skip members already darwinbg (`isDarwinBackground == true`: App Tamer,
  `taskpolicy -b`, the user) so restoring to 0 is always correct; `setDarwinBackground(true)` + verify
  `isDarwinBackground == true` ((integration) read from `pbi_flags` `PROC_FLAG_EXT_DARWINBG`, see §4.4). (fix) XNU
  copies an EXTERNAL darwinbg to children forked afterwards: a process started after the pause began whose PARENT is
  a member Kakureneko throttled (journaled, identity verified) — or one adopted the same way — and that is darwinbg now
  is journaled as Kakureneko's own `.darwinBackground` record (`adoptInheritedThrottles`, run by the helper re-scan,
  before a recheck thaws an app for a protection, and by every in-process thaw), so every undo path restores it; a
  member that was darwinbg before the pause, and what it forks, is never adopted. Freeze only if `settings.mode ==
  .freeze` and the self-test allows it (ordering §6.4: journal → main → members → ≤ 5 newcomer rounds → verify
  `SSTOP`, partial failure → thaw the group). (fix) Freeze never journals or stops a member someone else already
  stopped (`SSTOP` before the pause; the main already stopped → nothing), the counterpart of Throttle's darwinbg rule;
  and applies the R06 §5.4 category defaults as a downgrade (`.categoryDefault`): browsers (bundle-id table + apps
  registered for `https`) and chat/mail/meeting apps are throttled, never frozen. Quit only if
  `quitWhenMemoryLow`, memory pressure ≥ warning (lazily-owned memory-pressure source) and `proc_get_dirty` tracked &&
  clean; journal `.terminate` records with the bundle path. In dry-run skip both verifications and count the action as
  succeeded (ledger only).
* **Journal first:** `PauseJournal.write(to: paths.pauseJournalFile)` (F_FULLFSYNC) BEFORE every signal/priority change,
  with `kern.bootsessionuuid` and `simulated: dryRun.isOn` per app. Remove a group from the journal after it is thawed.
  Decoding is lossy (Kit), so one bad record never blocks recovery of the rest. (fix) The app and `kakureneko-guard`
  serialize their read-modify-writes with an advisory `flock` on `paused.json.lock` (`JournalFileLock`, bounded at
  2 s so a stopped holder never blocks the safety net); the app drops records missing on disk (the guard thawed
  them) before every update, the guard holds the lock from its read to its rewrite — a guard rewrite can no longer
  overwrite a record the resumed app appended meanwhile.
* **Thaw:** LIFO per group, whole group in one pass; `thawAll` thaws everything and clears the journal; relaunches
  apps closed by Quit (`signaller.relaunchApplication(at:)`, bundle URL from the journaled path, not activated) only
  for `.lidOpened`, `.userRequest`, `.externalDisplay`, `.userInput` — never for `.willSleep`, `.beforePowerAction`,
  `.willPowerOff`, `.appQuitting`. `thawAllSynchronously(reason:)` = the same thaw from the journal, synchronous,
  no relaunch. `recoverFromJournal`: thaw only records whose boot UUID, start time, uniqueID and fresh `val[7]` all
  match; drop the rest, every `simulated` app and every `.terminate` record (no relaunch); never blanket-SIGCONT.
* **Recheck** (`recheck`): P-C/D/E/F + new agents + `sessionHostPIDs` → thaw that app and protect it for the rest of
  the session; throttle new helpers of throttled apps (every `throttleRescanSeconds`); hard cap `maxPausedHours` →
  thaw all. Re-read the journal first (the guard may have thawed records during a hang; treat missing records as
  already thawed). (fix) A recheck that cannot see (no process table, boot session or grouping) or runs on an
  incomplete topology (`isComplete == false`) thaws every FROZEN app — Freeze is never kept on facts that cannot be
  checked; throttled apps stay.
* **`observe(now:)`:** called every process-scan tick while the lid is closed; keeps a ≤ 2 min `proc_pid_rusage`
  history per candidate group (P-I).
* **Safety nets:** `installCrashHandlers()` — ONLY the `sigaction` handler for SEGV/BUS/ILL/ABRT/TRAP/FPE over the
  preallocated `CrashThawBuffer` (§5 exception; `kill(pid, SIGCONT)` is the only raw `kill` allowed; then `SIG_DFL` +
  `raise`). (fix) With `SA_ONSTACK` and a preallocated (mmap, 256 KiB) alternate signal stack for the installing
  thread and the main thread: a stack overflow faults where no handler frame fits on the exhausted stack. SIGTERM/INT/HUP/QUIT belong to the coordinator (it calls `thawAllSynchronously`). Never install either in a
  test process. `startGuard()` posix_spawns `guardExecutable --watch <getpid()> --journal <path> --log
  <paths.guardLogFile> --pipe-fd <fd>` with `POSIX_SPAWN_SETSID`; the write end is `O_CLOEXEC`; writes `hb\n` every
  10 s and on each heartbeat `waitpid(guard, WNOHANG)` → respawn if it exited unexpectedly. `stopGuard()` writes
  `bye\n` (after `thawAll`), closes the pipe, reaps.
* **Dry-run:** decisions + journal (`simulated: true`) as usual, but never spawn the guard (ledger `pause.guard`) and
  keep the crash-handler array empty.
* **Guard** (header contract): watches the app (kqueue `NOTE_EXIT`, pipe EOF without `bye`, hang = no `hb` for 90 s by
  `CLOCK_UPTIME_RAW`, ignored while the journal is empty); app gone → recover with the same logic and exit; hang →
  thaw the verified records, rewrite the journal without them, keep watching; `bye` → exit without recovery;
  `--recover` one-shot; `--dry-run` logs only; logs ONLY to `--log`; exit 0 always.

**Acceptance tests (signals ONLY to processes the test spawned, e.g. `/bin/sleep 30`):** real `AuditTokenSignaller` on
an ENRICHED identity of an own child: stop → `p_stat == SSTOP` → cont → running; `setDarwinBackground(true)` →
`isDarwinBackground == true` via `pbi_flags` `PROC_FLAG_EXT_DARWINBG` (integration: measured on macOS 26,
`getpriority(PRIO_DARWIN_PROCESS)` stays 0 after an EXTERNAL throttle, so it is not the check) → false → cleared; un-enriched identity → `send(.stop)`/`setDarwinBackground(true)` throw
`.identityMismatch`; wrong start time / pidVersion → throws, nothing sent; journal is written before the signal (a
recording signaller fake reads the journal file at call time) and never contains un-enriched members; protection rules
as pure functions over synthetic groups/topologies (every rule P-A…P-K incl. `sessionHostPIDs`; a group whose helper
has a tty is protected; downgrade-only rules; no P-I history → no Freeze); Freeze refused when the self-test disallows
it or the topology is incomplete; already-darwinbg members are skipped; LIFO thaw order; relaunch only for the allowed
reasons (dry-run signaller ledger `app.relaunch`); recovery drops wrong-boot / reused-pid / simulated / `.terminate`
records; lossy journal with one corrupt record still thaws the others; dry-run pause writes `simulated: true` and
reports success without verification; guard integration (spawned with `paths.helperEnvironment` + `--log`): `--watch
<own short-lived child>` with a journal naming a second, SIGSTOPped own child → when the watched child exits the guard
SIGCONTs the stopped one and clears the journal; `bye` → no recovery; hang (no `hb` past a test-shortened timeout, if
you expose one via a hidden flag) → thaws but keeps running; `--recover` path; `--dry-run` signals nothing; the crash
handler is exercised only in a spawned helper (`kakureneko-guard --crash-selftest`). `PauseManager.pause` tests inject an
internal fake candidate provider (never real apps).

### 9.6 notify — `KakurenekoNotify` (+ `KakurenekoCloud`)

Native notifications replaced ntfy on 2026-10-17 (DECISIONS.md D11). The binding design, schema and flows are in
**docs/NATIVE-NOTIFICATIONS.md**; this card lists the module boundary only.

**Owns:** `Sources/KakurenekoNotify/`, `Tests/KakurenekoNotifyTests/`; `Sources/KakurenekoCloud/` + `Tests/KakurenekoCloudTests/`
(the Mac ⇄ iPhone wire schema, shared verbatim with the iPhone app in `Xcode/project.yml`, builds for macOS and iOS;
CloudKit PUBLIC database with creator-only permissions, D12, schema in `Xcode/CloudKit/schema.ckdb`).

**Must export:**
```swift
public actor NotificationDispatcher: NotificationDispatching {   // remoteCommands() stays nonisolated
    public init(paths: Paths, settings: NotificationSettings, localNotifications: any LocalNotificationPosting,
                cloud: (any CloudStore)?, clock: any KakurenekoClock = SystemClock(), logger: KakurenekoLogger = KakurenekoLogger(.notify))
}
public final class UserNotificationCenterPoster: LocalNotificationPosting   // makeIfAvailable(bundle:logger:): app bundle only
public struct MacIdentity                                                   // computer name, model, app version
```

**Behaviour:** Templates + NotificationPolicy unchanged (presence, 15 s batch, needs-input dedupe + one reminder, rate
limit + digest, quiet hours, Remote-Control skip); presence gating defaults to `always` (N2). Every admitted message is
posted at once as a macOS notification (`AlertPresentation.content`, request id from `replaceKey`) and enqueued in the
persistent outbox, which saves it as a CloudKit `Alert` (retry/backoff/`retryAfter`, TTL, coalescing, `drain(deadline:)`
with a 30 s per-save timeout). The iCloud loop prepares the store (the user's identity) and the Mac inbox
subscriptions, then fetches changes (owner + modification-date queries) on every push (`cloudDidNotify`, plus two quick
re-fetches), every 15 s while a button may still be tapped or after a refresh request, else every 5 min. Phone `Command`s are validated (right Mac, expiry,
age, future skew, `sv` for sleep/shutdown, replay cache persisted BEFORE acting), yielded, then deleted; `sendTest` /
`refreshStatus` are answered by Notify. Mac notification buttons arrive through `LocalNotificationPosting.buttonTaps()`.
`updateMacStatus` saves this Mac's `MacStatus` (phase change at once, else debounced 5 s, heartbeat 5 min, final status
in `drain`). Old alerts are pruned after 3 days; the ntfy `secrets.json` of earlier versions is deleted at load.

**Acceptance tests (`InMemoryCloudStore` + `RecordingLocalNotifications` only; never CloudKit or UserNotifications;
`TestClock`):** both channels and each channel's setting; denied / unavailable Mac permission; no-iCloud builds; retry
classes (network, rate limit with `retryAfter`, permanent, signed out, hanging save + timeout); outbox across a relaunch;
drain at the deadline while a save hangs; dry-run (`DryRunCloudStore`) saves nothing but reads; setup, schema bootstrap,
account recheck, zone loss, token expiry; commands once (replay across relaunch), invalid ones deleted, other Macs'
left alone; Mac button taps; phones listed and forgotten; status identity, debounce, phase change, heartbeat, final
status; pruning; golden templates for every kind × detail level; the full policy suite.

### 9.7 install — `KakurenekoInstall`

**Owns:** `Sources/KakurenekoInstall/`, `Tests/KakurenekoInstallTests/`.

**Must export:**
```swift
public final class IntegrationManager: AgentIntegrating {   // may become an actor
    public init(paths: Paths, subprocess: any SubprocessRunning, dryRun: DryRunGate, ledger: DryRunLedger,
                clock: any KakurenekoClock = SystemClock(), logger: KakurenekoLogger = KakurenekoLogger(.install))
}
```

**Read:** brief §2 C2–C8/C14/C15, §3.3–3.4, §3.6 (snippets A–H; rename every `lidless` → `kakureneko`, hook path →
`paths.hookBinary` absolute literal, plugin → `kakureneko@kakureneko-local`, Copilot file → `~/.copilot/hooks/kakureneko.json`,
opencode plugin → `kakureneko.js`, agy key → `"kakureneko"`, Gemini hook names → `kakureneko-…`), §3.7 (installer rules);
R02 §1.7, §2; R03 (per-agent sections); R04 §3, §7.2; R05 §3–4.

**Behaviour:**
* Internal `IntegrationInstaller` protocol + one installer per v1 agent: Claude (plugin via CLI: write
  `paths.claudePluginDirectory/.claude-plugin/marketplace.json`, `plugins/kakureneko/.claude-plugin/plugin.json`,
  `plugins/kakureneko/hooks/hooks.json` — exec form, `command` = hook path, `args` = [agent, event], `timeout` 5, never
  `async`/`asyncRewake`/`onFailure`, never `PermissionRequest`; the Notification matcher includes `agent_completed` and
  `quota_auto_resume_*`; then `claude plugin marketplace add <dir> --scope user --json` and `claude plugin install
  kakureneko@kakureneko-local --scope user --json` as `.mutating` requests with stdin `/dev/null`; verify with `claude
  plugin list --json` (`.readOnly`); uninstall = `plugin uninstall` + `marketplace remove` + delete the folder),
  Codex (`notify` top-level key before the first table, chaining an existing value with `--chain --`, original kept in
  the manifest and restored byte for byte; `hooks.json` append-only groups; trust step detected read-only from
  `[hooks.state."…"]`; never forge `trusted_hash`; honour `CODEX_HOME`), Gemini (`settings.json` `hooks`, ms
  timeouts), agy (`~/.gemini/config/hooks.json` key `"kakureneko"`), Copilot/VS Code (own file
  `~/.copilot/hooks/kakureneko.json`, `version: 1`, `bash` + `timeoutSec`; never `preToolUse`/`permissionRequest`),
  Cursor (`~/.cursor/hooks.json`, keep `version: 1`; never permission hooks), opencode (own plugin file per snippet G,
  v1 + v2; (fix) an installed opencode older than 1.18.29 — read-only `opencode --version` — gets the legacy
  `export const KakurenekoPlugin = async (input) => …` form, brief §3.6 G), Aider (`~/.aider.conf.yml` `notifications` +
  `notifications-command`, chaining an existing command; (fix) only a command that ran — `notifications: true` — is
  chained, a dormant one is kept in the manifest and restored; an entry of ours is rewritten with the CURRENT hook
  (stale path → `needsRepair`); its originals are rebuilt from the chain whenever the manifest's are missing or
  disagree with it, so a lost manifest never deletes the user's command), the
  Claude-compatible family routine (Droid, Qwen, Auggie with 5000 ms, Qoder, CodeBuddy, iFlow, Devin; R04 §3),
  Windsurf (`~/.codeium/windsurf/hooks.json`). Shell-run entries end with `2>/dev/null; exit 0`.
* **Every agent-CLI subprocess** sets `extraEnvironment: paths.agentSubprocessEnvironment.merging(["DISABLE_AUTOUPDATER":
  "1"]) { $1 }` (a `KAKURENEKO_HOME` run must never read or modify the real `~/.claude`). (fix) plus `PATH =
  AgentCLIEnvironment.searchPath(…)` with the user's login-shell `PATH` (one read-only `/bin/zsh -ilc` run per manager
  lifetime, output after a marker; `LoginShellProbe`): an npm/bun/nvm `claude` is a `#!/usr/bin/env node` script that
  launchd's bare `PATH` cannot run (exit 127 → install rolled back). The same probe reads `CLAUDE_CONFIG_DIR`,
  `CODEX_HOME`, `COPILOT_HOME`, `XDG_CONFIG_HOME`; one the shell sets differently from this process adds a status
  note (`launchctl setenv …` and restart) — install locations still follow this process's `Paths`.
* Rules: offer only agents whose config dir exists (phantom-install rule); `preview(_:operation:)` builds the diff
  for install, uninstall AND repair (`InstallPlan` with unified diffs) before anything is written; `install`/`repair`
  throw `SideEffectError.unavailable("hook helper not deployed")` when `paths.hookBinary` is not an executable file
  (skipped in dry-run); backup to `paths.backupDirectory(for:)/<basename>.<ISO-ts>` before the first edit;
  `AtomicFile.write` (follows symlinks, keeps mode); format-preserving splices (JSON: validate then textual splice into
  the specific array; JSONC: comment-aware — (fix) emptying a container removes only the child's own bytes (its line,
  its comma) and keeps the comments around it, and a child added to a single-line container keeps a comment it held; TOML/YAML: line-oriented single-key splice); re-parse after writing and
  roll back from the backup on failure; every entry contains `KakurenekoID.ownershipMarker`; uninstall/repair remove only
  entries containing it and drop arrays that became empty; owned files are deleted; manifest
  `paths.installManifestFile` (`InstallManifest`, `sha256Before/After`, `chainedOriginal`); `statuses()` re-verifies
  the manifest (missing marker → `needsRepair`); never write `~/.claude/sessions/**`, `settings.local.json`, `.key`
  files, `jobs/**`, `daemon/**`, Codex `[hooks.state]`.
* `deployHelper(from:)`: SHA-256 compare, copy (not symlink) to `paths.hookBinary` with 0755, `DirectoryLayout`.
* Dry-run: plans only; ledger `install.write`/`install.delete` per file and `subprocess.run` (via the gated runner);
  `InstallResult.dryRun = true`; nothing touched on disk.

**Acceptance tests (temp home + fixture configs + `FakeSubprocessRunner`; never the real dotfiles):** install →
uninstall restores every fixture byte for byte (JSON with comments/odd formatting, TOML with comments and tables, YAML
with comments); key order and comments preserved after install; Codex notify chaining/unchaining exact strings (brief
§3.6 B1); an existing user hook entry is kept; re-parse failure (simulate) rolls back; phantom rule (no dir → not
offered, nothing created); symlinked config edits the target; every written entry contains the ownership marker; the
Claude plugin path issues exactly the brief's CLI argv (recorded), with `.mutating`/`.readOnly` marked correctly and
`extraEnvironment` ⊇ `paths.agentSubprocessEnvironment` + `DISABLE_AUTOUPDATER=1` on every recorded request;
`preview` for uninstall and repair shows the diff and writes nothing; install without a deployed helper throws (gate
off) and succeeds in dry-run; `statuses()` flags `needsRepair` after a simulated agent rewrite and `repair` fixes it;
Codex trust detection; dry-run writes nothing; `deployHelper` copies once and skips when the hash matches.

### 9.8 coordinator — `KakurenekoCoordinator`

**Owns:** `Sources/KakurenekoCoordinator/`, `Tests/KakurenekoCoordinatorTests/`.

**Must export:**
```swift
public actor KakurenekoCoordinator: KakurenekoControlling {
    public nonisolated let services: KakurenekoServices
    public init(services: KakurenekoServices, settings: KakurenekoSettings? = nil)
    public static func makeLiveServices(environment: [String: String] = ProcessInfo.processInfo.environment,
                                        bundleURL: URL = Bundle.main.bundleURL) -> KakurenekoServices
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment,
                            bundleURL: URL = Bundle.main.bundleURL) -> KakurenekoCoordinator
}
```
`LiveComposition.swift` (written by the architect) is the composition root; keep its wiring rules. (integration)
Rule 6: every defaulted dry-run/ledger/gate parameter a module appended is passed explicitly. Rule 7: the gate starts
with the environment policy only; settings' dry-run is applied in `start()` step 6.

**Read:** brief §5.6, §6.1, §6.5 (thaw triggers), §7.3 (state machine), §7.4 (trip handling), §7.5 (end action), §8.3
(command execution rules), §8.5, §9.4; DECISIONS D1–D3; §6 of this document (dry-run toggling).

**Behaviour:**
* **`start()`** (idempotent), in this order:
  1. `DirectoryLayout.ensureUserDirectories`; `pausing.installCrashHandlers()`; if `services.handlesTerminationSignals`
     (live only): `signal(sig, SIG_IGN)` + `DispatchSource.makeSignalSource` for SIGTERM/INT/HUP/QUIT (created in this
     library), handler = `pausing.thawAllSynchronously(reason: .appQuitting)` → `power.disarmSynchronously(timeout:
     .seconds(2))` → `exit(0)` (brief §7.3 "thaw, then disarm" on every termination path).
  2. `pausing.recoverFromJournal()` FIRST.
  3. Reconcile with the REAL flag `kernelFlags().kernelSleepDisabled`: true, gate off and nothing working →
     `disarm()`; true while the gate is on → critical `AppWarning(id: "kernel-sleep-disabled")` (never touch the
     heartbeat; the root fail-safe clears it).
     (final integration) The initial effective lid uses the lid from `kernelFlags()` AND the external-display state
     of one `power.snapshot()` taken here, so a session ingested while step 7 starts the services (the first Claude
     record scan) is never evaluated as "closed, no display" on a clamshell desk.
  4. `privileged.healthCheck()` → mode `.full` / `.notificationsOnly`; in dry-run when not operational →
     `PrivilegedStatus.simulatedForDryRun(at:)`, mode `.full`, `AppWarning(id: "dry-run-privileged-simulated")`.
  5. `integrations.deployHelper` when `services.bundledHookHelper != nil`; `pausing.selfTest()`.
  6. Apply settings (`sessions.updateTimers`, `notifications.applySettings`, `dryRun.setRequested(settings.general.dryRun)`
     — nothing is armed or paused yet; recovery and reconcile above ran under the environment-only gate, §6).
  7. **Subscribe, then start:** obtain `events.events()`, `notifications.remoteCommands()`, `powerEvents.events()`,
     `claudeState.snapshots()` and spawn their consumer child tasks FIRST; then `events.start()` (its launch drain
     arrives on the stream — ingest ONLY from streams, never also `drainNow()`'s array), `claudeState.start()`,
     `processes.start()`, `power.start()`, `powerEvents.start()`, `notifications.start()`.
  8. `pausing.startGuard()`; run the main tick loop.
* **Main loop:** every `SamplingCadence.processScanInterval` (5 s closed / 15 s open): `processes.sample` →
  `sessions.ingest(processes:)`, and `pausing.observe(now:)` while the lid is closed; every 1 s: `sessions.tick(now)`;
  route effects; evaluate the predicates; step the power state machine; flush a dirty snapshot; poll
  `notifications.status()` and republish on change. Update `claudeState.setCadence` and
  `processes.updateSessionStoreHints` (from sessions' `agentProcess` + `metadata[MetadataKey.transcriptPath]` /
  `[MetadataKey.sessionStoreDirectory]`) when they change. Use `services.clock` for all time.
* **Predicates** (pure functions on the internal state machine; they REPLACE the brief's undefined "waiting grace"):
  * `waitingGraceActive` = some session is `.waiting(_, since)` with `since + timers.needsInputCountdown > now`.
  * `shouldStayArmed = anyWorking || waitingGraceActive || keepAwakeUntil > now` — drives Disarmed → Armed and blocks
    the 2-min Armed → Disarmed (a waiting session must keep the flag set, or closing the lid sleeps at once, with no
    remote-approval window; bounded so a forgotten prompt cannot disable idle sleep forever).
  * `shouldCountDown = !anyWorking && !(keepAwakeUntil > now)` — drives ClosedAwake → Countdown. Length:
    `anyWaiting ? timers.needsInputCountdown : timers.finishCountdown`. Reason: `.needsInput` if anyWaiting,
    `.wentQuiet` if every finished session since the lid closed `isHeuristicOnly`, else `.finished`.
  * `effectiveLidClosed = power.lid == .closed && !power.externalDisplayConnected` (clamshell desktop counts as OPEN).
  * `userPresent` = recent input per the §8 Presence rule: a known `secondsSinceUserInput < awayIdleSeconds`; an
    UNKNOWN reading counts as present only while the lid is effectively open (integration; was "unknown = absent"
    everywhere, which disagreed with Notify's gating).
* **Power state machine** — a pure internal struct (unit-testable) driven by the actor, brief §7.3 with:
  Disarmed → Armed when `shouldStayArmed ∧ power.keepAwakeWithLidClosed ∧ privileged OK ∧ general.enabled ∧
  safety.armingBlocker(snapshot, settings.safety) == nil` (never in `.notificationsOnly`/`.disabled`); while Armed with
  the lid open re-check `armingBlocker` on every snapshot → blocked: disarm (not sleep) + `AppWarning(id:
  "arming-blocked")`; Armed → ClosedAwake on the `effectiveLidClosed` edge [display sleep if no external display and
  the setting is on; chime per `power.lidCloseSound` (default on battery; never/always); SafetyMonitor every 15 s; schedule pausing]; ClosedAwake → Countdown when
  `shouldCountDown ∧ !userPresent` [submit the countdown intent once]; Countdown → ClosedAwake on anyWorking or
  keep-awake; Countdown → WindingDown(`.countdownElapsed`) on timer (and `!userPresent`) or sleep command;
  ClosedAwake|Countdown|ShutdownPending → WindingDown on SafetyTrip [push first]; → Armed on the effective lid-open
  edge (lid opens, or an external display connects while closed) [thaw, cancel countdown / wind-down]; external
  display disconnected while the lid is closed → ClosedAwake; Armed → Disarmed after `disarmLidOpen` with
  `!shouldStayArmed` and the lid open. Heartbeat: `power.touchHeartbeat()` every 15 s while armed (a no-op unless really
  armed).
  (fix, §11.C) **Re-arm latch:** every Kakureneko-initiated wind-down (countdown, menu/phone sleep, safety trip,
  shutdown and its fallback, sleep retry) records the state version; while that latch holds and the effective lid is
  closed, Disarmed never re-arms — macOS dark-wakes a sleeping Mac in the bag every ~15 min, and the agent that was
  mid-turn when the user asked to sleep is still `.working` then (it used to re-arm into ClosedAwake, with heartbeat).
  Released by the effective lid opening (edge, or Disarmed with the lid open), an explicit keep-awake request, or — not
  after a safety trip — a NEW turn (`stateVersion` beyond the recorded one); a wind-down cancelled before the sleep
  drops it; with the latch a sleep that did not happen retries the sleep instead of re-arming for the same turn. The
  keep-awake override is cleared when the sleep (or the shutdown request) goes out.
  (fix) **Physically closed lid with a display:** a display keeps the lid effectively OPEN, but a virtual, AirPlay or
  Sidecar display in a bag is not a desk: while the PHYSICAL lid is closed and the Mac is held awake the SafetyMonitor
  still runs (12 h cap counted from the physical close, network, sustained thermal), and a trip winds down and sleeps
  when nobody uses the Mac (`!userPresent`).
* **WindingDown** runs as ONE stored `Task` with a generation id: `notifications.drain(deadline: now+10 s)` →
  `pausing.thawAll(.beforePowerAction)` → wait 3 s (clock) → `power.disarm()` → write `resume.json` if the end action
  is shutdown → `power.sleepNow()` (or, shutdown opt-in and no session waiting: `power.requestShutdown()`; still awake
  3 min later → `sleepNow()`). Lid open, keep-awake (menu or phone), `setEnabled(false)` and `cancelWindDown()` cancel
  it before `sleepNow`/`requestShutdown`; re-check generation and phase after EVERY await. (fix) A wind-down decided
  before an await (the trip push) and cancelled before its task started returns to where the (still set) flag belongs
  — Armed by the lid, never Disarmed without a disarm — and its late `.windDown` action is dropped. Quitting while the
  shutdown request is out (`.awaitingShutdown`: loginwindow quits apps first; Terminal's "terminate running
  processes?" may then abort the shutdown) hands the rest of the 3 min fallback to `power.scheduleDetachedSleep` —
  nothing of Kakureneko would be left to sleep the Mac. `disarm()` failure: stop
  touching the heartbeat (the fail-safe clears the flag within 210 s), submit `.warning` (`disarm-failed`), still try
  `sleepNow()`. On wake: Disarmed; submit `.asleep(SleepRecord)`.
* **Shutdown grace:** a valid phone `shutdown` (or the opt-in end action) → `.shutdownPending(at: now + 60 s,
  requestedFromPhone:)` + `.shuttingDown`; at the deadline re-check `sv` and the phase, then wind down with shutdown.
  Cancellable by `cancelWindDown()`, lid open, keep-awake. (fix) `resume.json`: once `requestShutdown()` went out a
  user cancel keeps it (loginwindow may still complete the shutdown); it is deleted after a wake (the Mac only slept)
  or when the fallback window passed with Kakureneko still running, and a launch never offers a manifest written during
  the CURRENT boot (`kern.boottime`, read-only: no shutdown happened since).
* **Pausing:** `pause(topology:settings:now:)` only when `effectiveLidClosed` ∧ no input for `userInputGraceSeconds`
  ∧ `shouldStayArmed` ∧ `lidCloseSettleSeconds` since lid close ∧ mode `.full` ∧ pausing enabled. Before EVERY `pause`
  and `recheck`, over non-ended sessions: `topology.agentIdentities.formUnion(live.compactMap(\.agentProcess));
  topology.sessionHostPIDs = Set(live.compactMap { $0.host?.pid })`. Then `recheck` every `recheckSeconds` with a fresh
  topology; thaw (`thawAll`) on every trigger of brief §6.5.5 (lid open, external display, `.userActivity` / input
  < 5 s, willSleep, willPowerOff, session resigned, before power actions, quitting, pausing disabled, hard cap, no
  agent working) and on the watchdog (an agent claims working but its `treeCPUSeconds` has not advanced for
  `watchdogMinutes` while anything is frozen).
* **Power events:** `.willSleep(ack)` → thaw all, flush the outbox ≤ 5 s, `ack.allow()`; `.didWake` → kick
  notifications (`drain`); `.userActivity` → thaw (`.userInput`); `.externalDisplayChanged` → effective lid edge;
  `.snapshot` → keep the latest, presence (on every present → away transition re-submit `.needsInput` for each
  still-waiting session — Notify dedupes), safety evaluation when lid-closed-awake, `armingBlocker` while armed with
  the lid open.
* **Remote commands:** `keepAwake(s)` → override until now+s (cancels a countdown, a shutdown grace and a wind-down
  not yet at `sleepNow`); `sleep` → only if `stateVersion == aggregate.stateVersion` else submit `.commandIgnored("<Agent>
  in <project> is busy again")`; `shutdown` → only if `power.endAction == .shutdown` and sv matches → shutdown grace;
  `pairConfirm` → refresh notification status + publish. (`stateVersion` is seeded per launch by the engine, so a
  button minted before a relaunch never matches.)
* **Notification routing:** `finished` → `.finished(effect, stillRunning:)`, `needsInput` → `.needsInput(effect,
  awakeUntil:)`, any session leaving `.waiting` → `.resolved(key)`, `stalled`, `wentQuiet`, countdown entry →
  `.countdown(endsAt:, reason:, finished: <finished effects since the lid closed>, waiting: <waiting sessions>,
  offerShutdown:)`, trips → `.safetyTrip`; context = `NotificationContext(now:, presence:, stateVersion:,
  keepAwakeSeconds: settings.power.keepAwakeButtonSeconds)`. (fix) The countdown push is sent only while that very
  countdown still runs (it is executed after the session pushes were awaited; another agent's turn may have cancelled
  it) and its buttons carry the DECISION-time `sv` (`.countdownStarted(endsAt:reason:stateVersion:)`). Nothing is
  pushed while Kakureneko is off except `.resolved` (it sends nothing and cancels Notify's reminder); Notify gets
  `enabled = false` while Kakureneko is off (reminders, batch, digest and queue dropped), the real settings again when on.
* **Settings:** `updateSettings` → normalize, `save(to: paths.settingsFile)`, apply to services; a change of
  `general.dryRun` → `thawAll(.pausingDisabled)` + `disarm()` UNDER THE OLD GATE, then `dryRun.setRequested`, then
  re-step (§6); `general.enabled == false` → cancel wind-down, thaw, disarm, mode `.disabled`. (fix) When the gate flips,
  the privileged status is re-derived at once (no simulated `.full` with the gate off) and decisions stay suspended
  until the fresh health check is applied — a tick in between used to arm FOR REAL on the simulated status.
* **Snapshot:** `AppSnapshot` from sessions (ended excluded), aggregate, phase, last power snapshot, privileged status
  (possibly simulated), keep-awake, paused apps + last report, self-test, notification status, integrations (with
  `lastEventSeen` from `events.lastEventSeen()` — already keyed by integration), resume offer, settings, warnings
  (privileged missing, App Tamer running `KakurenekoID.appTamerBundleIdentifier`, Freeze unavailable, hotspot at lid
  close, Low Power Mode on battery, Mac notifications off, iCloud unavailable, iPhone alerts failing, dry-run, dry-run-privileged-simulated,
  kernel-sleep-disabled, disarm-failed, arming-blocked, heartbeat-path-mismatch, integrations needing repair), dry-run
  ledger tail (≤ 50). Publish through an `AsyncBroadcaster(replayLatest: true)` with LEADING-EDGE coalescing: publish
  immediately when ≥ 250 ms (`services.clock`) passed since the last publish, else mark dirty for the 1 s tick; never
  `await clock.sleep` in the publish path.
* `prepareForTermination()`: cancel wind-down, thaw all, disarm, drain ≤ 2 s, `stopGuard()`, stop services.
  (fix) `nonisolated terminateSynchronously()`: `thawAllSynchronously(.appQuitting)` → `disarmSynchronously(2 s)`,
  never through the actor (the same routine as the SIGTERM handler) — for the app's quit watchdog and
  `applicationWillTerminate`.

**Acceptance tests (`FakeServiceSet` + `TestClock` only; order via `fakes.log`):** the full brief T7 flow (prompt →
lid close → finished → 5 min countdown push → sleep) with `fakes.log.filtered([…]) == ["notify.drain",
"pause.thawAll(beforePowerAction)", "power.disarm", "power.sleep"]`; needs-input → 10 min countdown with reason
`.needsInput` and the waiting session; a waiting session keeps the Mac armed with the lid open for
`needsInputCountdown`, then Armed → Disarmed 2 min later; keep-awake command cancels the countdown; sleep command with
a stale `sv` is ignored with a `commandIgnored` push; shutdown command refused when shutdown is not enabled, accepted →
`shutdownPending` → `cancelWindDown()` returns to ClosedAwake with no `power.shutdown`; safety trip → push then wind
down; lid open during countdown → Armed + thaw; lid open while winding down (before `sleepNow`) → no `power.sleep`;
`armingBlocker` set → never arms, set while armed with the lid open → disarm; lid closed + external display + agent
finishes → no countdown; display disconnect with the lid closed → ClosedAwake; recent user input → no countdown entry;
launch reconcile (journal recovery before anything, stale real flag disarmed; dry-run + real flag set →
`kernel-sleep-disabled` warning, no disarm); dry-run + not-operational health check → simulated `.full`; dry-run toggle
→ `pause.thawAll(pausingDisabled)` and `power.disarm` logged BEFORE the gate flips; `.notificationsOnly` never arms or
pauses; pause scheduled only after 90 s + 60 s idle and not with an external display, and the topology passed to
`pause` carries `sessionHostPIDs`; every thaw trigger calls `thawAll` with the right reason (incl. `.userActivity` →
`.userInput`); willSleep allows the acknowledger; present → away re-submits `needsInput`; leaving `.waiting` submits
`.resolved`; events queued before start (`FakeEventSource.queueForDrain` + `start()`) are ingested exactly once;
settings persist and re-apply; snapshots publish on change without advancing the clock; no signal sources installed
when `handlesTerminationSignals == false`.

### 9.9 app — `KakurenekoApp` (+ `scripts/`, `Resources/`)

**Owns:** `Sources/KakurenekoApp/`, `Tests/KakurenekoAppTests/`, `scripts/`, `Resources/`.

**Must export:** nothing (executable). Keep `@main struct KakurenekoMenuBarApp`, `AppDelegate`, `AppModel` names (tests
use `@testable import KakurenekoApp`).

**Read:** brief §8.6 (onboarding), §6.2 (the "Pausing saves CPU and battery…" sentence), §7.1 (privileged install UX),
§7.5 (resume offer), §9.2 (bundle, signing, launch at login), §9.4; R08 §5 (what works ad-hoc), §9 (Swift 6 patterns),
§10; R07 §17.2 (pairing UX), §17.5 (settings surface).

**Behaviour:**
* `MenuBarExtra(.window)` (prefer `isInserted:`), label reflecting state (working / waiting / closed-lid armed /
  disabled). Menu: status line, sessions (agent display name, project, host, state + duration, waiting text, dismiss for
  stuck ones), power phase and countdown with Keep awake (15 min / 1 h / 2 h) and Sleep now, the shutdown grace /
  wind-down with Cancel (`cancelWindDown()`), paused apps + Resume all, warnings, dry-run banner with the recent ledger
  lines (and "simulated" next to the privileged status when `privileged.simulated`), Settings…, Quit.
* Onboarding window (first launch, `general.onboardingCompleted == false`): (1) closed-lid mode explanation + "Install"
  (one admin prompt via `installPrivilegedHelper`) or "Skip — notifications only"; (2) notifications
  (docs/NATIVE-NOTIFICATIONS.md): "Allow Notifications" (`requestNotificationPermission`), the Kakureneko iPhone app
  (same Apple Account, no pairing; App Store QR once `AppLinks.iPhoneApp` is set), live "iPhone connected" rows from
  `notifications.phones`, "Send Test"; (3) agent integrations from `snapshot.integrations` (only agents whose config dir exists): diff preview sheet
  (`previewIntegration(agent, operation:)` for install, uninstall and repair), install / uninstall / repair, Codex
  trust-step guidance, "last event seen" proof of life; (4) Automation consent for shutdown only when the user enables
  shutdown (`AEDeterminePermissionToAutomateTarget(…, askUserIfNeeded: true)`; skipped in dry-run).
* Settings window: every `KakurenekoSettings` section with the documented ranges — use the public `…Range` constants
  (`SessionTimers.finishCountdownMinutesRange`, `SafetySettings.batteryFloorPercentRange`, …), never copies; edit a
  LOCAL draft of `KakurenekoSettings` and call `updateSettings` on commit (a form bound to `snapshot.settings` would be
  overwritten by every republish); never-pause list editor; "Send test" (`sendTestNotification`); the sentence
  "Pausing saves CPU and battery; it does not free memory unless you allow 'Quit when memory is low'."; launch at login
  via `SMAppService.mainApp` (read `status` every launch; `.notFound` before the first registration is normal;
  re-register when opted in and not `.enabled`; persist via `updateSettings`). When `snapshot.isDryRun`: never call
  `SMAppService.register/unregister` (log "would register login item") and never request Automation consent.
* Lifecycle: create `KakurenekoCoordinator.live()` in `applicationDidFinishLaunching`; `applicationShouldTerminate` →
  `.terminateLater`, `await prepareForTermination()`, then `NSApp.reply(toApplicationShouldTerminate: true)` (a
  watchdog on an injectable `KakurenekoClock` replies after 6 s if prepare hangs — (fix) after running the controller's
  synchronous `terminateSynchronously()`: a normal NSApp exit runs no signal handler; `applicationWillTerminate` calls
  it too, a no-op after a completed prepare). Launch tasks with side effects run on
  the first snapshot whose mode is not `.starting`. Reopen sessions from `snapshot.resumeOffer`
  (`ResumeEntry.resumeCommand` — injection-safe, `cd "$HOME"` without a cwd — in the host terminal), then
  `clearResumeOffer()`.
* Only `KakurenekoControlling` + `AppSnapshot`; previews with `PreviewKakurenekoController`. Never request notification
  authorization (iPhone alerts go through iCloud; the app delegate registers for CloudKit pushes). Closures for GCD/notify from this target must be `{ @Sendable in … }`.
* `scripts/build-app.sh` exists and is verified (keep its behaviour); add `scripts/install.sh` (build, `ditto` to
  `~/Applications/Kakureneko.app`, `open`) — never run it from an agent. Optional `Resources/AppIcon.icns` (the script
  picks it up).

**Acceptance tests:** `AppModel` follows `PreviewKakurenekoController` snapshots; view-model formatting (session rows,
countdown / shutdown-grace text, warning ordering) as pure functions; actions call the controller (assert
`PreviewKakurenekoController.calls`, e.g. `sendPairingRequest`, `cancelWindDown`, `previewIntegration(codex,uninstall)`);
the settings draft is not clobbered by a republish; no `SMAppService` registration, no notification authorization, no
app launch in tests; `scripts/build-app.sh` still produces a bundle that passes `codesign --verify --deep --strict`.

---

## 10. Build, test and bundle commands

```bash
swift build                          # debug, all targets
swift build --build-tests            # + test targets
swift test                           # Swift Testing (+ XCTest runner, 0 tests)
scripts/build-app.sh                 # release build → build/Kakureneko.app, signed (Apple Development identity if present, else ad-hoc)
SIGN_ID=- scripts/build-app.sh debug # ad-hoc debug bundle
codesign --verify --deep --strict --verbose=2 build/Kakureneko.app
KAKURENEKO_DRY_RUN=1 KAKURENEKO_HOME=/tmp/kakureneko-dev build/Kakureneko.app/Contents/MacOS/Kakureneko   # USER ONLY — agents never launch the app
echo closed > /tmp/lid; KAKURENEKO_DRY_RUN=1 KAKURENEKO_HOME=/tmp/kakureneko-dev KAKURENEKO_SIMULATE_LID=/tmp/lid build/Kakureneko.app/Contents/MacOS/Kakureneko   # walk the closed-lid flow (log only)
```

## 11. Deviations from the brief (and why)

### 11.A Architecture (before implementation)

1. **Module split** (brief §9.1 had one `LidlessCore`): nine targets so nine agents can work in parallel; the contract
   layer is `KakurenekoKit`. Behaviour is unchanged.
2. **`AgentID`** adds `plandex` (brief §3.5 lists it as heuristic-only); `continueCLI` encodes as `"continue"`
   (matches hook argv labels); unknown strings decode as `.unknown`.
3. **`SessionState.settling`** carries the pending `TurnOutcome` and **`.ended`** carries its date (needed for
   `idle(o)` after settle and the 10 min drop).
4. **`InboxHeader`** adds optional `payloadSource` and per-ancestor `ppid`/`tdev` (needed for attribution and the pty
   map); all optional, so the brief's example and R08's prototype header still decode.
5. **Hook argv** is `kakureneko-hook <agent> <event>` (brief §4.1); R08's prototype `emit` subcommand is dropped.
6. **Notification kinds** add `shuttingDown`, `commandIgnored`, `warning`, `pairing`, `test` (R07 §16.1, brief §8.3/§8.6),
   and `SignedCommand` adds `cmd: "pair"` for the onboarding Confirm button (R07 §17.2).
7. **`KakurenekoClock`** instead of `Clock` (avoids shadowing `Swift.Clock`).
8. **D2 as one setting:** `PowerSettings.endAction` (`.sleep` default); `.shutdown` also enables the phone "Shut down"
   button.
9. **Extra protocols** not named in the task list: `ProcessLookup` (liveness without a module dependency),
   `AgentSignatureMatching` (Events needs Processes' table by injection), `AdministratorScriptRunning` (so no test can
   ever trigger the admin prompt), `NotificationProvider` lives in Kit (brief §8.1 signature).
10. **Persisted dates** are ISO 8601 with milliseconds (`KakurenekoJSON`), exact round-trip for whole-millisecond dates.
11. **Test support lives in Kit** (`Testing/`) instead of a separate target, so previews and every test target can use
    it; a `KakurenekoAppTests` target was added, and `KakurenekoPauseTests` depends on `KakurenekoGuard` so `swift test`
    builds the guard binary.
12. **`FoundationSubprocessRunner`** sets `F_SETNOSIGPIPE` on the child's stdin pipe (a child that exits without
    reading stdin would otherwise SIGPIPE the parent — found while building this skeleton).
13. **Attribution order** (brief §4.4: env markers → ancestry → argv): ancestry first, then the argv label, then env.
    `CLAUDE_PID`/`CLAUDE_CODE_SESSION_ID` are inherited by every process Claude's Bash tool spawns (R02 §1.3), so an
    agent run from Claude (`codex exec`, `gemini -p`, a nested `claude -p`) would otherwise be relabelled Claude and
    corrupt the parent session. To make ancestry work for node/python agents, `InboxAncestor` gained `argv1` (path-like
    only) and `path`.
14. **opencode sessions are keyed by the opencode process** (brief §8 keyed by root session id): the plugin payload of
    `session.status`/`session.idle` carries only `sessionID`, and the pid is busy while ANY of its sessions is busy
    (R03 §7(g)); KakurenekoEvents aggregates per process.
15. **Dedupe** drops only CONSECUTIVE duplicates per session key within 2 s of `occurredAt` (the brief's ±2 s window
    would drop the second `turnStarted` of a sub-2-s turn and cause a false finish).
16. **Notification mappings:** `quota_auto_resume_fired` → turnStarted, `quota_auto_resume_stale`/`_disabled` →
    needsInput(unknown) (brief: all → rateLimited); `agent_completed` → activity; Claude `SessionStart` never resets an
    existing session (`source: compact` fires mid-turn).
17. **Session engine refinements:** T2-only sessions finish via the transcript's `system/turn_duration` (R02 §8.2);
    bound sessions whose agent has no start edge (Codex notify-only, agy, Aider, Auggie, Cursor `-p`) are driven into
    working by T3; `.waiting` exits on T3 progress for agents with no resume edge; settle expiry with a still-busy
    record returns to working (no endless `.settling`), and the stall guard covers settling; T3 heuristic sessions are
    created only for the outermost, unbound, non-IDE-host, non-ignored process of a tree; E2 ignores `caffeinate` and
    keep-alive respawns (otherwise the 13 h stale-busy case never stalls).
18. **holdAwake** (brief §5.6) is split into `shouldStayArmed` (lid open; waiting counts only for
    `needsInputCountdown`) and `shouldCountDown` (lid closed); the undefined "waiting grace" is gone. Lid closed + an
    external display counts as lid OPEN, and no countdown starts while the user is present.
19. **Termination:** SIGTERM/INT/HUP/QUIT belong to the coordinator (sync thaw → sync disarm → exit) instead of the
    pause module (brief §6.5.2: "thaw, then exit" — which left `SleepDisabled` set); the pause module keeps only the
    `sigaction` crash handler. Guard: heartbeat every 10 s with a 90 s `CLOCK_UPTIME_RAW` hang timeout (brief: 30 s /
    30 s), keeps watching after a hang, `bye` on intentional stop, respawned when it dies.
20. **`Paths.live()` honours `HOME`** after `KAKURENEKO_HOME` (FileManager ignores `$HOME`, so helpers spawned by tests
    would otherwise write the real `~/.kakureneko`); agent CLIs get `paths.agentSubprocessEnvironment`; the hook derives
    its root from its own location.
21. **Dry-run safety:** the real kernel flag is always reported (`kernelSleepDisabled`), the heartbeat is touched only
    when really armed, the privileged status is simulated when missing (so decisions are visible), the pause journal
    marks simulated apps, and toggling dry-run first undoes real effects under the old gate.
22. **State version** is seeded per launch (epoch ms), so signed buttons from a previous run never match.
23. **Pairing** is two calls (`preparePairing` without network, then `sendPairingRequest` after the phone subscribed)
    instead of one; `sendTest` stays a plain message. Needs-input gained a `resolved` intent (reminder cancellation,
    TTL "until the state changes") and the countdown intent carries its reason and the waiting sessions.
24. **Hook stdin:** never read when it is a terminal (Aider); `--chain` appends the payload only when it came from argv.
25. **Pause safety:** any group member with a controlling tty protects the group (R06 rule I, was main-only); nothing
    is journaled or paused without an enriched identity (pidVersion + uniqueID); journal decoding is lossy per record;
    Quit-mode relaunch goes through `ProcessSignalling.relaunchApplication` (dry-run gated).

### 11.B Integration (after the nine modules were merged)

Contract changes made by the integrator (Kit + every affected module, tests included), with the decision on each
module's contract change request:

26. **Composition root wiring** (applied): `LiveComposition` passes every appended dry-run/ledger/gate parameter
    explicitly (`PowerController(ledger:)`, `PrivilegedInstaller(dryRun:)`, `PauseManager(ledger:)`), never relying on
    a default or on "find it inside the gated side effect" fallbacks (power, pause requests).
27. **Settings-requested dry-run at launch** (modified, app request): instead of seeding the gate from settings at
    composition time, the gate starts environment-only and `start()` step 6 applies `general.dryRun` after journal
    recovery and the kernel-flag reconcile, so a crashed real run is undone for real (§6). `.starting` snapshots are
    documented to carry the env-forced value only; the app already waits for a non-`.starting` snapshot.
28. **Presence** (applied, coordinator request): one rule for an unknown input time — away with the lid effectively
    closed, present with it open (`Presence.hasRecentInput`, §8); the coordinator's `userPresent` now uses it.
29. **`kakureneko-hook --chain`** (applied, install request): `posix_spawnp` (PATH lookup, execvp semantics) is now the
    binding contract (the implementation already used it); tested with a bare program name on a temp `PATH`.
30. **`ResumeEntry.resumeCommand`** (applied, app request): `cd "$HOME"` without a cwd (a quoted `'~'` never expands),
    cwd always single-quoted, ids quoted unless shell-inert; verified by executing the command under `/bin/sh` with
    `cd`/`claude` shadowed. The app's workaround was removed (its identifier checks stay as defence in depth).
31. **`python -m <module>`** (applied, processes request): `InboxAncestor.module` (hook records it for Python
    interpreters, plain dotted identifiers only; decode re-validates), `descriptor` = `[argv0, "-m", module]`.
32. **`MetadataKey`** (applied, events request): constants for the informational payload extras; the normalizers use
    them. **`AgentEventSource.start()`** error semantics documented (never throws for recoverable filesystem problems).
33. **`AtomicFile.write(followSymlinks:)`** (applied, install request): follows the whole link chain including a
    dangling one (target created, links kept), ELOOP after 32 hops; `finalTarget(of:)` is shared with the installer's
    deletes and its protected-location guard, which now also checks the exact file that would be written.
34. **`ProcessSignalling.isDarwinBackground`** (applied, pause request): documented as `pbi_flags` (external darwinbg);
    the §9.5 acceptance text no longer says `getpriority == 1`.
35. **`EvidenceSample.window`** (applied, sessions request) shared by Processes and Sessions. **Per-kind evidence
    freshness** (modified, sessions request): instead of a new `lastObservedAt` field, the engine ignores waiting-exit
    evidence sampled less than one window after the wait began (the same hold-off it uses after a finish); the
    leftover E1/E4 of the work that produced a Codex/Gemini/Copilot permission prompt no longer ends the wait ~20 s
    later. Cost: a remote approval is recognised ~80 s after the prompt instead of ~20 s.
36. **`TestClock`** (applied, coordinator request): wall-clock-bounded `waitForSleepers(_:timeout:)`,
    `sleeperDeadlines`, `waitForSleeper(dueBy:)`. Load-sensitive tests were rewritten to assert virtual-time instants
    deterministically (Notify `happensAt`/`happensBy`, the app's termination watchdog on an injected clock, best-of-3
    rounds for the hook's child-process latency bounds, the scanner's 200 ms budget checked as thread CPU time via
    `ScanEngine.lastScanCPUMilliseconds`, generous positive-wait defaults). A real hang found under heavy load (the
    power tests' `driving` helper stopped advancing after 5 s of wall time and then awaited an operation parked on
    the TestClock forever) was fixed, and every suite now has `.timeLimit(.minutes(1))`.
37. **Ledger names**: `pause.guard` is now actually recorded (PauseManager, dry-run `startGuard()`); previews use the
    canonical names; the app's own log names are listed in §6. (Superseded by native notifications: there is no server URL any more.)
38. **Notify "button token"** for custom servers (deferred to v2, notify request): documented in §9.6.

Module deviations from the brief accepted at integration (each module's card text is binding unless listed here):

39. **Events:** the nearest matched ancestor loses to a DIFFERENT effective argv label only when an unmatched
    non-shell program or agent infrastructure sits between them (Cursor CLI under the basic matcher); opencode
    `*.replied`/`form.cancelled` → `.activity`; stdin read budget 1.2 s on top of the 300 ms idle limit; compact header
    rebuild above ~63 KiB; ancestry stops before launchd; proof of life counts dropped-but-parsed events; timestamps
    > 5 min in the future clamp to `receivedAt`; a drain yields ≤ 5,000 events.
40. **Processes:** `agentLaunchedAppPIDs` = app-bundle main executables only; Cursor CLI needs the bundled node AND the
    launcher name or `index.js`; npm Claude infra classified like native; topology has a 1 s hard deadline; E2/E4
    baselines at first sight of a tree.
41. **Sessions:** heuristic hold-off of one evidence window after a finish (also for the waiting exit, item 35); one
    T3-driven session per process; `.stalled` → working bumps `stateVersion`; a record going idle inside the settle
    window finishes at settle expiry.
42. **Power:** `disarmSynchronously` read-back polls real time (termination path); dry-run never calls a non-dry-run
    side effect; `uninstall()` also refuses a fake home with the gate off; extra install-script input checks; the
    battery floor applies on battery (on AC only via "draining on AC").
43. **Pause:** guard hang recovery writes an EMPTY journal instead of deleting it; Quit also needs a complete
    topology; `.terminate` records survive non-relaunching thaws; CoreAudio process-object list per check.
44. **Notify:** presence gating also passes `commandIgnored`/`shuttingDown`; quiet hours lower every kind but
    pairing/test to ≤ 2; a server Retry-After holds all publishing; a countdown replaces queued finished/wentQuiet
    items; nonce cache ≤ 4,096, `exp` ≤ 48 h ahead.
45. **Install:** Aider chains via absolute `/bin/sh -c`; colon-free ISO backups, identical backups skipped; text-only
    removal when the file changed since install; `needsRepair` false when the agent dir is gone; protected-location
    guard and "hooks switched off" notes added; Kakureneko's own hook binary is deployed in dry-run.
46. **Coordinator:** wake → Disarmed then the normal Disarmed → Armed rule; countdown upgrade to needs-input; shutdown
    end action with a waiting session sleeps without the grace; `resume.json` only right before `requestShutdown`;
    integration statuses re-read every 10 min; `thaw()` always calls `thawAll`.
47. **App:** launch tasks wait for a non-`.starting` snapshot; dry-run = snapshot OR settings OR env; settings window
    commits a dirty draft on close; `install.sh` SIGTERMs a running installed copy (user-only script, never run by
    agents).

### 11.C Review fixes (after the adversarial review of the merged build)

Every confirmed finding was fixed with a regression test that fails on the merged sources. Behaviour that now
differs from the brief's literal text, or that refines an item above:

48. **Stall-guard progress = E1/E2/E3** (brief §5.5 says "any of E1–E5"): E4 and E5 alone never refresh
    `lastProgressAt` nor revive a stalled session — idle Claude TUIs write their tty and open a model-API connection
    every few minutes (measured), which defeated the brief's own motivating 13 h case. They still count toward the T3
    two-kind threshold. An IDE host's tree (every extension) gives a hooked session no progress at all, and a
    heuristic-turn session (Codex `app-server`) progress only with E4; the waiting exit on an IDE host needs E4.
49. **E3 for Claude** hints only the `<sessionId>/` subtree, never the main `.jsonl` (now matches brief §5.4).
50. **Replayed inbox files** older than 10 min at receipt are history only (no session, no state change, no push).
    **Never-seen bound processes** are checked with `ProcessLookup` (brief §3.2 T4). **Same-agent relatives' fallback
    sessions merge** into the session a hook binds (npm Codex, Gemini). **T2:** a record rewrite is an edge only when
    the merged status reflects it; `agentsPolledAt` is stamped when the CLI starts.
51. **Re-arm latch after every Kakureneko-initiated sleep** (refines item 46 "wake → Disarmed then the normal rule"):
    with the effective lid closed, Disarmed re-arms only after the lid opens, an explicit keep-awake, or — not after a
    safety trip — a new turn. Keep-awake is cleared when the sleep goes out. A wind-down cancelled before its task
    started keeps the flag accounted for. The countdown push carries the decision-time `sv` and is dropped when its
    countdown already ended.
52. **Kakureneko off:** `.resolved` is still forwarded (it sends nothing) and Notify runs with `enabled = false`.
53. **Shutdown end action:** the 3 min sleep fallback is handed to a detached `/bin/sh` helper when the app quits
    while the request is out (it sleeps only with the lid closed; brief §7.5 put the fallback in-process).
    `resume.json` survives a cancel after the request went out; a launch ignores one written during the current boot.
54. **Privileged install runs inline** (brief §7.1 wrote the scripts to Application Support and ran them from there):
    the install/uninstall scripts are passed as text (`bash -c`) and the fail-safe template is a quoted heredoc
    inside the install script — no root code is read from a user-writable file. The health check compares the
    installed fail-safe and plist with what this version generates (`failsafeScriptMismatch`, warning
    `failsafe-damaged`); after an update that changes the template, closed-lid mode asks for a reinstall. The
    fail-safe treats a future-dated heartbeat as stale.
55. **Power termination:** `disarmSynchronously` also clears an arm in flight and refuses later arms; a failed real
    arm is reverted unless the flag was already set; the dry-run toggle never steps a simulated status with the gate
    off; the app's quit watchdog and `applicationWillTerminate` run `terminateSynchronously()`.
56. **Closed lid with a display attached:** the closed-lid SafetyMonitor guards also run while the PHYSICAL lid is
    closed and the Mac is held awake (the display may be virtual/AirPlay/Sidecar in a bag); a trip sleeps the Mac only
    while nobody uses it. Virtual displays are still counted as external for the effective lid (no reliable API tells
    them apart).
57. **Pause:** children forked by throttled members inherit the throttle and are journaled to be restored (R06 §1.2);
    Freeze leaves already-stopped members alone and applies the R06 §5.4 category defaults (browsers, chat, mail,
    meetings → Throttle; now matches brief §6.2); a blind or incomplete recheck thaws frozen apps; app and guard share
    a journal file lock; the crash handler runs on an alternate signal stack. **Deviation:** the Freeze "breathing"
    option (R06 §5.7) is not implemented in v1, so the Settings toggle was removed (`PauseSettings.breathing` stays
    in the schema for v2).
58. **Install:** agent CLIs get a composed `PATH` incl. the login shell's (`/bin/zsh -ilc`, once, read-only — the brief's
    lookup used `-lc`, which misses `~/.zshrc`, where nvm and most exports live); agent-dir variables set only in the
    login shell are reported, not followed (install targets keep following this process's environment). Aider chains
    only a command that ran, repairs stale hook paths and never trusts empty originals; JSONC splices keep comments
    when a container empties or fills; opencode < 1.18.29 gets the legacy plugin form (brief §3.6 G).
59. **Lid simulation** (not in the brief): a dry-run-only developer tool (`KAKURENEKO_SIMULATE_LID`, §6) so the
    closed-lid flow (pausing decisions on the real process table, countdown, "would sleep") can be walked on a
    developer Mac without closing the lid. Ignored unless `KAKURENEKO_DRY_RUN=1` is in the environment.
60. **Launch effective lid** (bug found in a dry-run launch on a clamshell desk): the external-display state used to
    default to "none" until step 7's first snapshot, so a Claude record ingested during step 7 drove
    disarmed → closedAwake → armed within milliseconds. Step 3 now reads the display state with the lid
    (`LaunchEffectiveLidTests`).
