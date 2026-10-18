# Kakureneko — product decisions (binding)

Decided by the user on 2026-10-12. These override `research/00-BRIEF.md` wherever they differ.

## Name and identifiers (D5)

The research documents use the working name "Lidless". The product is **Kakureneko**: every identifier, path, bundle id, env var and prefix is `Kakureneko`/`kakureneko`/`KAKURENEKO` (D13). Every identifier is renamed mechanically:

| Brief (Lidless) | Kakureneko |
|---|---|
| `Lidless.app`, product `LidlessApp` | `Kakureneko.app` (binary `Contents/MacOS/Kakureneko`), SwiftPM product `KakurenekoApp` |
| bundle id `dev.lidless.Lidless` | `com.kakureneko.Kakureneko` |
| `lidless-hook` (helper), `dev.lidless.hook` | `kakureneko-hook`, signing identifier `com.kakureneko.hook` |
| `lidless-guard`, `dev.lidless.guard` | `kakureneko-guard`, `com.kakureneko.guard` |
| `~/.lidless/` (bin, inbox, run, log, backups, recordings, claude-plugin, install-manifest.json) | `~/.kakureneko/` (same subpaths) |
| `~/Library/Application Support/Lidless/` | `~/Library/Application Support/Kakureneko/` |
| `/Library/Application Support/Lidless/` (root fail-safe script) | `/Library/Application Support/Kakureneko/` |
| `/private/etc/sudoers.d/lidless` | `/private/etc/sudoers.d/kakureneko` |
| LaunchDaemon `dev.lidless.failsafe` | `com.kakureneko.failsafe` |
| Darwin notification `dev.lidless.inbox` | `com.kakureneko.inbox` |
| Claude plugin `lidless@lidless-local` | `kakureneko@kakureneko-local` |
| ownership marker `/.lidless/bin/lidless-hook` | `/.kakureneko/bin/kakureneko-hook` |
| ntfy topics `lidless_<22>` / `lidless_c_<22>` | `kakureneko_<22>` / `kakureneko_c_<22>` |
| env `LIDLESS_RECORD`, `LIDLESS_*` | `KAKURENEKO_RECORD`, `KAKURENEKO_*` |
| sequence ids / titles "Lidless …" | "Kakureneko …" |

## Defaults chosen by the user

- **D1 Lid closed on battery:** allowed. Safety limits: 20 % battery floor, thermal cut-offs, a chime on lid close while on battery, a 12 h cap, and the root fail-safe (7 %).
- **D2 End action:** **sleep** (default). Shutdown is an opt-in setting that falls back to sleep. The phone "Shut down" button only appears when shutdown is enabled.
- **D3 Privileged install:** yes. One admin prompt during onboarding installs the sudoers rule and the root fail-safe daemon. Without it, Kakureneko runs in "notifications only" mode.
- **D4 Phone channel:** ~~ntfy~~ — superseded by D11 (2026-10-17). The default detail level stays Basic.
- **D11 Native notifications (2026-10-17):** alerts are macOS notifications from Kakureneko itself plus the Kakureneko
  iPhone app, connected through the user's private CloudKit database (container `iCloud.com.kakureneko.Kakureneko`, team
  7NRW73MYQZ); no third-party app or server, no pairing (same Apple Account = connected). ntfy is removed entirely.
  Every alert shows on the Mac and the iPhone at the same time, also while the user is at the Mac (presence gating
  default `always`; v1 settings migrate). The iPhone app is built for TestFlight / App Store; the Lock Screen /
  Dynamic Island live card is phase 2. Design: docs/NATIVE-NOTIFICATIONS.md.
- **D12 Public CloudKit database (2026-10-17):** the records live in the container's PUBLIC database, not the
  private one: private-database data counts against the user's iCloud storage (the user's own iCloud was full —
  2 KB free — and every save failed with "Quota exceeded"). Public-database storage comes from the app's CloudKit
  allowance. Privacy: every record type is readable and writable by its creator only (no world read, schema in
  `Xcode/CloudKit/schema.ckdb`, applied with `scripts/cloudkit-schema.sh`); every record carries `owner` and the
  apps trust a record only when its server-set creator is the current user.
- **D13 One name everywhere (2026-10-18):** the product is **Kakureneko** (隠れ猫, "hiding cat"), website
  kakureneko.com, and every identifier says so: the apps and their texts, the bundle ids (`com.kakureneko.*`), the
  iCloud container `iCloud.com.kakureneko.Kakureneko` (a new container; its schema was imported from
  `Xcode/CloudKit/schema.ckdb`), `~/.kakureneko` and `~/Library/Application Support/Kakureneko`, the hook
  (`kakureneko-hook`), the Claude Code plugin `kakureneko@kakureneko-local`, the sudoers file and the fail-safe daemon
  (`com.kakureneko.failsafe`), the log subsystem, the `KAKURENEKO_*` variables, the Swift modules, targets and
  types, and the Xcode project. Nothing had shipped, so there is no migration: the earlier development install was
  removed with its own Uninstall and the renamed app set up from scratch.
- **D6 Memory:** "Quit idle apps when memory is low" exists and is **off** by default.

## Scope for v1 (this build)

- **Everything in milestones M0–M5:** skeleton, detection, phone, power, the v1 agent installers, and Throttle pausing.
- **Freeze:** M6 is implemented with every protection rule, but it sits behind the setting "Pause mode: Throttle (default) / Freeze (experimental)". It is enabled by default only after on-device spike tests pass.
- **Installers:**
  - Claude Code, Codex, Gemini CLI, Antigravity, Copilot CLI / VS Code, Cursor, opencode, Aider.
  - The Claude-compatible family (Factory Droid, Qwen Code, Auggie, Qoder, CodeBuddy, iFlow, Devin), through one generic routine.
  - Windsurf.
- **Detection:** the T3 heuristic tier covers every other agent.
- **Shutdown:** opt-in, with a resume manifest.

## Development safety rules (binding for every agent and every test)

- **Never** call `sudo`, never change `pmset` or any system setting, and never call `IOPMSleepSystem`, `pmset sleepnow` or `displaysleepnow`. Never shut down.
- **Never** send SIGSTOP/SIGCONT, call `setpriority`, or call `terminate()` on any process the test did not spawn itself.
- **Never** write to the real `~/.claude`, `~/.codex`, `~/.gemini`, `~/.copilot`, `~/.cursor`, `~/.config/opencode`, `~/.aider.conf.yml` or `~/.kakureneko`. Installers and stores take an injectable home/root directory, and tests use a temp dir.
- **Never** touch CloudKit or `UNUserNotificationCenter` from tests: use `InMemoryCloudStore` and `RecordingLocalNotifications`. Never install onto or launch anything on the user's iPhone, and never create Apple-developer identifiers beyond those in `Xcode/project.yml`.
- Every system-mutating operation goes through an injectable protocol. The real app also honours `KAKURENEKO_DRY_RUN=1`: it logs each decision ("would arm", "would sleep", "would throttle pid 123", "would save 1 iCloud record(s) …") instead of acting. That makes it safe to launch on the developer's Mac.
