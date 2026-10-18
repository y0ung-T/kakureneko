# 01 — Keeping an Apple Silicon MacBook awake with the lid closed, then putting it to sleep

*Lidless research series · written 2026-10-12 · scope: power, lid, sleep, Wi-Fi, thermal/battery safety, sleep/shutdown*

| | |
|---|---|
| Machine investigated | MacBook (Apple Silicon, arm64), **macOS 26.6.2 (25G83)**, Xcode 26.6, Swift 6.3.3 |
| Apple sources read | `xnu-12377.121.6` (kernel `IOPMrootDomain`), `PowerManagement-1846.120.8.0.1` (pmset, powerd; tag dated 2026-06-05), `IOKitUser-100231.120.3` (IOPMLib), plus the Xcode 26.6 MacOSX SDK headers |
| Method | Read-only. No `sudo`, no `pmset` writes, no signals. Small read-only Swift/C probes were built and run in `…/scratchpad/research-snippets/` |
| Confidence key | **High**: Apple source or SDK header, or verified on this Mac. **Medium**: consistent third-party hands-on reports, or inferred from source without a device test. **Low**: a single report, or a hypothesis |

> Line numbers like `IOPMrootDomain.cpp:7803` refer to the files at the tags listed above, fetched from `github.com/apple-oss-distributions/*`.

---

## 0. TL;DR

1. **The only third-party way to stop lid-close sleep on a MacBook with no external display is the kernel flag `SleepDisabled`.** You set it with `pmset -a disablesleep 1`, and only root can set it. It works on battery and on AC, on macOS 26 and on 27. Public IOPM assertions and `caffeinate` don't stop lid sleep. The lid-close paths that avoid it are each closed to us: Apple-private entitlements, external display plus AC, or a private selector that has been shown not to work. *(High)*
2. `SleepDisabled` blocks **every** kind of system sleep: idle, lid, Apple-menu, `pmset sleepnow`/`IOPMSleepSystem`, **low-battery emergency sleep and thermal-emergency sleep**. It does not block display sleep, shutdown or restart. It is **system-wide**, so `-a/-b/-c` make no difference. It is **written to disk and re-applied at boot**, so it persists across reboots. `pmset -g` shows it as ` SleepDisabled  1` under `System-wide power settings:`. *(High, from source)*
3. Because the kernel's own low-battery and thermal sleeps are switched off, **Lidless must run its own battery and thermal cut-offs**. It also needs a fail-safe that does not depend on the app being alive (§5.4). *(High)*
4. The flag must be set **before the lid closes**. The kernel starts clamshell sleep synchronously in the lid interrupt path, so an app that waits to see "lid closed" before acting is too late. *(High, from source)*
5. **Clearing the flag while the lid is closed does not put the Mac to sleep.** The kernel does not re-check the lid when the flag changes, and live `PreventUserIdleSystemSleep` assertions block idle sleep. For example, Claude Code runs `caffeinate -i -t 300` itself (verified on this Mac). Lidless must clear the flag, **wait until the kernel shows `SleepDisabled = No`**, and then call `IOPMSleepSystem()`. The console user can make that call without root. *(High)*
6. **Privileges for an ad-hoc-signed personal app.** Use a **`/etc/sudoers.d/lidless` NOPASSWD rule for exactly the two `pmset` commands**, plus a **root-owned fail-safe LaunchDaemon**. Both are installed once with `osascript … with administrator privileges`. This approach does not depend on code signing at all. `SMAppService.daemon` is the cleaner long-term option, but Apple DTS says ad-hoc signing causes registration and approval problems. Sign with at least a free "Apple Development" (Personal Team) identity before moving to it. *(High/Medium)*
7. **For shutdown, sending `kAEShutDown` to loginwindow needs Automation (TCC) consent.** This was verified on this Mac: the result was "would require user consent" (-1744). Running apps can cancel that shutdown; Terminal and iTerm2 ask before closing running processes. `shutdown -h now` needs root and kills everything without asking. **The default end-of-session action should be sleep, not shutdown.** *(High/Medium)*
8. **Prior art and a name clash.** At least five 2026 open-source apps already do "keep awake with the lid closed for AI agents" using `pmset disablesleep`, and **one of them is already called "Lidless"** (`github.com/nghialuong/Lidless`, MIT, June 2026). See §4 and §12.

---

## 1. How lid-close sleep actually works (kernel path)

All sleep requests end in `IOPMrootDomain` in xnu. The steps that matter are these (`xnu-12377.121.6/iokit/Kernel/IOPMrootDomain.cpp`):

| Step | Code | What it means for us |
|---|---|---|
| Lid closes; the lid driver sends `kIOPMClamshellClosed` to `handlePowerNotification()` | `:8935-8951` | Clients are notified (`sendClientClamshellNotification`, which sets the `AppleClamshellState` property and sends the `kIOPMMessageClamshellStateChange` message), then `eval_clamshell = true` |
| `if (shouldSleepOnClamshellClosed()) privateSleepSystem(kIOPMSleepReasonClamshell)` | `:9055-9066` | Synchronous, inside the kernel. A user-space reaction cannot get there first |
| `shouldSleepOnClamshellClosed() = !clamshellDisabled && !(desktopMode && acAdaptorConnected) && !clamshellSleepDisableMask` | `:4594-4604` | "Clamshell mode" means an external display (desktopMode) **plus AC**. `clamshellSleepDisableMask` is owned by powerd |
| `privateSleepSystem()` → `if (!checkSystemSleepEnabled()) return kIOReturnNotPermitted;` | `:3025-3038` | **This is the gate that `SleepDisabled` closes** |
| `checkSystemSleepAllowed()`: `if (userDisabledAllSleep) { err = kPMUserDisabledAllSleep; break; }` comes **before** the `lowBatteryCondition` / `thermalEmergencyState` checks | `:7803-7860` | "Conditions above pegs the system at full wake." Low-battery and thermal emergency sleeps are blocked as well |
| A change in AC adapter state (`kIOPMSetACAdaptorConnected`) or desktop mode also sets `eval_clamshell = true` | `:8961-8992` | Plugging or unplugging power with the lid closed re-runs the lid-sleep decision. This is the likely cause of the "session dies on power-source change" reports against Amphetamine on Apple Silicon |
| `kPowerEventUserDisabledSleep` handler: `userDisabledAllSleep = (arg0 == kOSBooleanTrue); break;` | `:8556-8558` | Changing the flag starts **no** re-evaluation. That is why clearing it with the lid closed does not sleep the Mac |

The bits of `kIOPMMessageClamshellStateChange` (SDK `IOKit/pwr_mgt/IOPM.h:426-440`) are `kClamshellStateBit = 1<<0` (lid closed) and `kClamshellSleepBit = 1<<1` (`shouldSleepOnClamshellClosed()`). The sleep bit does **not** take `SleepDisabled` into account, so it can read 1 even when sleep is disabled. Use bit 0 only. *(High, source)*

---

## 2. `pmset -a disablesleep 1` (the `SleepDisabled` flag)

### 2.1 What the command actually does *(High, source)*

1. `pmset` parses `disablesleep <n>` into a **system-wide** dictionary: `CFDictionarySetValue(local_system_power_settings, kIOPMSleepDisabledKey, val ? kCFBooleanTrue : kCFBooleanFalse)` (`pmset/pmset.m:5841-5864`). The power-source flags `-a/-b/-c/-u` are **not** consulted for this key. The function comment reads: *"system_power_settings: system-wide settings, not tied to power source. like 'disablesleep'"* (`pmset.m:5111`).
2. `pmset` calls `IOPMSetSystemPowerSetting(key, value)` (`pmset.m:806`). The comment there: *"We write the settings to disk here; PM configd picks them up and sends them to xnu from configd space."*
3. `IOPMSetSystemPowerSetting` (`IOKitUser/pwr_mgt.subproj/IOPMEnergyPrefs.c:1624-1670`) does the following:
   - returns `kIOReturnNotPrivileged` unless `getuid()==0 || geteuid()==0`. **Root is required.**
   - writes `CFPreferencesSetValue("SystemPowerSettings", dict, "com.apple.PowerManagement", kCFPreferencesAnyUser, kCFPreferencesCurrentHost)` and synchronizes it.
   - sends `notify_post(kIOPMPrefsChangeNotify)`.
4. powerd's `PMSettingsPrefsHaveChanged()` calls `PMActivateSystemPowerSettings()`, which calls `IORegistryEntrySetCFProperty(rootDomain, "SleepDisabled", kCFBooleanTrue/False)` (`pmconfigd/PMSettings.m:1338-1356, 1384-1390`). The kernel then sets `userDisabledAllSleep` (`IOPMrootDomain.cpp:2129-2133, 8556-8558`).
5. **At boot**, `PMSettings_prime()` calls `PMActivateSystemPowerSettings()` with the comment *"Activate non-power source specific, PM settings namely disable sleep"* (`PMSettings.m:1157-1170`). **The setting therefore persists across reboots.**

**Where it lives on disk.** This was verified on this Mac: `CFPreferencesCopyValue("SystemPowerSettings", "com.apple.PowerManagement", AnyUser, CurrentHost)` returns the dictionary stored in **`/Library/Preferences/com.apple.PowerManagement.plist`**. It currently holds `{ "Update DarkWakeBG Setting" = 1 }`, and `SleepDisabled` would be added beside that key. The UUID-suffixed `com.apple.PowerManagement.<host-UUID>.plist` holds the per-source settings (Hibernate Mode, LowPowerMode, TTYSPreventSleep, and so on), not this one. *(High, verified locally with `plutil -p` and the `clamshell.swift` probe)*

**Pass a CFBoolean, not a number.** powerd checks `kCFBooleanTrue == CFDictionaryGetValue(…)`, and `pmset -g` prints `(b==kCFBooleanTrue)`. The Adrafinil developers wrote that a direct `IOPMSetSystemPowerSetting("SleepDisabled", CFNumber(1))` "returns success, pmset -g still reports 0, Mac sleeps". That is the result you would expect from passing a CFNumber. *(High, source)*

### 2.2 What it disables

| Sleep trigger | Blocked by `SleepDisabled=1`? | Confidence / source |
|---|---|---|
| Idle sleep (sleep timer) | Yes | High: `checkSystemSleepAllowed` |
| **Lid close (clamshell)**, battery or AC | **Yes** | High: source. Hands-on: lidawake "M5 / Tahoe 26.4 … core lid-closed awake — on AC AND on battery … zero sleep in `pmset -g log`" (TESTING.md, 2026-06-29). Sleepless "confirmed firsthand on macOS 26.3". Adrafinil "tested on macOS 26 and 27" |
| Apple menu ▸ Sleep, `pmset sleepnow`, `IOPMSleepSystem()` | Yes. `IOPMSleepSystem` returns `kIOReturnNotPermitted` (0xE00002E2) | High: `privateSleepSystem` |
| Power-button short press ("Sleep On Power Button 1") | Yes, because it also ends in `privateSleepSystem` | Medium: inferred |
| **Low-battery emergency sleep** (`kIOPMSleepReasonLowPower`) | **Yes. The battery will run down to the hardware cut-off.** | High: checked before `lowBatteryCondition` (`:7812-7820`). NoSleep's author added "Smart mode" after "a run on battery drained the Mac to 0%" |
| **Kernel thermal-emergency sleep** | **Yes** (hardware/SMC thermal shutdown still applies) | High: source |
| `pmset schedule sleep …` | Yes | Medium: same gate |
| Standby / hibernate | Never reached, because there is no sleep | High |
| Display sleep (timers, `pmset displaysleepnow`) | **No** | High |
| Shutdown / restart | **No** | High |

### 2.3 Scope, persistence and verification

- **Scope:** system-wide. `pmset -a disablesleep 1`, `pmset -b disablesleep 1` and `pmset disablesleep 1` all have the same effect. *(High, source)*
- **Persistence:** **survives reboot**, because powerd re-applies it at boot. Sleepless's README says it "reverts on reboot", which **contradicts the source**. machinefriendly.com and kanaries.net both say it persists. Assume it persists and clear it at boot (§5.4). *(High)*
- **`pmset -g` while set** (`pmset.m:1188-1203`, `show_system_power_settings()`):
  ```
  System-wide power settings:
   SleepDisabled		1
  Currently in use:
   …
  ```
  The value shown comes from the **persisted prefs**. The **kernel's live state** is the IORegistry property, readable without root:
  `ioreg -r -n IOPMrootDomain -d 1 | grep '"SleepDisabled"'` gives `"SleepDisabled" = Yes`. Lidless should trust the kernel property. On this Mac today: `"SleepDisabled" = No`, and the `System-wide power settings:` header prints with no lines under it (verified with `pmset -g`).
- **Reports of it breaking on macOS 15, 26 or 27:** none found. One blog (pasqualepillitteri.it) claims that "since Ventura disablesleep isn't enough on Apple Silicon". Hands-on test logs on 26.3, 26.4 and 27.0 contradict it (lidawake TESTING.md: "This Mac moved to macOS 27.0 (Golden Gate, build 26A428) on 2026-09-20 … `pmset disablesleep` works; still absent from the man page"). The Amphetamine Apple Silicon failures (Amphetamine-Enhancer issue #28, opened 2022 and still open in Nov 2025) concern Amphetamine's own mechanism. Users in that thread fixed them with `sudo pmset -a disablesleep 1`. *(High)*
- **Undocumented:** `disablesleep` is not in `man pmset` on 26.6.2 (verified). It is a string in `/usr/bin/pmset` (`strings` shows `disablesleep`, `SleepDisabled`). Apple could change it without notice. *(High)*

---

## 3. Alternatives, and whether they stop lid sleep

| Mechanism | Stops lid sleep? | Needs | Notes |
|---|---|---|---|
| `IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep)` / `caffeinate -i` | **No** | nothing | SDK `IOPMLib.h:274-292`: *"The system may still sleep for lid close, Apple menu, low battery, or other sleep reasons."* Released automatically if the process dies. *(High)* |
| `kIOPMAssertionTypePreventSystemSleep` / `caffeinate -s` | **Not on battery**. On AC: possibly a *dark wake*, untested (see note) | nothing | SDK `IOPMLib.h:1013-1023` marks it deprecated with *"not supported in any OS X releases"*. Yet `caffeinate -s` still uses it, and powerd still maps it to the kernel CPU assertion bit (`PMAssertions.c:5433-5438`). `man caffeinate`: *"valid only when system is running on AC power."* *(High for the battery case)* |
| `kIOPMAssertNetworkClientActive` / `IOPMDeclareNetworkClientActivity` | Not on battery. AC: same as above | nothing | SDK: *"keeps the system awake in dark or full wake, as long as the system is on AC power."* *(High for what the docs say)* |
| `caffeinate -m` / `-d` / `-u` | No | nothing | disk / display / user-activity only |
| Assertion property `AppliesOnLidClose` | Yes | **Apple-private entitlement `com.apple.private.iokit.assertonlidclose`** | powerd rejects callers that lack it (`PMAssertions.c:2571-2578`). The entitlement string is in `/System/Library/CoreServices/powerd.bundle/powerd` (verified with `strings`). Unavailable to third parties. *(High)* |
| Assertion property `AppliesToLimitedPower` (keep `PreventSystemSleep` active on battery) | n/a | Apple-private `com.apple.private.iokit.assertonbattery` | Same. *(High)* |
| `IORegistryEntrySetCFProperty(IOPMrootDomain, "SleepDisabled", kCFBooleanTrue)` | n/a | Apple-private `com.apple.private.iokit.rootdomain-set-property` | `IOPMrootDomain::setProperties` returns `kIOReturnNotPermitted` without it, **even for root** (`:2017-2048`). Adrafinil saw 0xE00002E2 as root on 26.3. *(High)* |
| `IOPMSetSystemPowerSetting(CFSTR("SleepDisabled"), kCFBooleanTrue)` (private but exported; `dlsym` finds it on 26.6.2) | Yes | **root** | This is exactly what `pmset` does. Shelling out to `/usr/bin/pmset` is simpler and uses Apple's tested path. *(High)* |
| `IOPMSetSleepDisabled` | n/a | n/a | **Does not exist** (`dlsym` finds nothing on 26.6.2, verified). *(High)* |
| `RootDomainUserClient` selector `kPMSetClamshellSleepState` (sets `clamshellSleepDisableMask`) | **Reported not to work** | no privilege check in the kernel | The kernel dispatches it with no entitlement or privilege check (`RootDomainUserClient.cpp:444-451, 615-619`). But powerd owns that mask bit (`kClamshellSleepDisablePowerd`) and re-evaluates it on every wake and assertion change (`PMAssertions.c:1389-1470`, `pmconfigd.m:400-437`). Adrafinil, on a real device running 26.3: "returns kIOReturnSuccess, Mac still sleeps". Do not use. *(Medium)* |
| Clamshell mode: external display (or HDMI dummy plug) + **AC** + input device | Yes, but **only on AC** | hardware | `!(desktopMode && acAdaptorConnected)`. Unplugging AC re-evaluates and sleeps. *(High)* |
| Kernel extensions (old NoSleep.kext, Insomnia.kext) | n/a | Reduced Security on Apple Silicon | Not viable. *(Medium)* |
| "Prevent automatic sleeping on power adapter when the display is off" (System Settings ▸ Battery ▸ Options), i.e. `pmset -c sleep 0` | No | admin | Idle sleep only. *(High)* |

**Is there any way to stop lid sleep without root? On battery, no.** *(High)* On AC there is one untested hypothesis *(Low)*. A `PreventSystemSleep` or `NetworkClientActive` assertion keeps the kernel CPU assertion bit set. When the lid closes, the system moves from full wake to dark wake: the display goes off and apps receive "will sleep". The dark-to-sleep step is then **cancelled** because `askChangeDownDone()` runs `checkSystemCanSleep()`, which honors the CPU assertion (`IOPMrootDomain.cpp:3856-3874, 7877-7880`). That would leave the Mac in dark wake for as long as the assertion holds and AC stays connected. It matches the Masset article (June 2026), which says `caffeinate -s` holds a closed lid on AC. Adrafinil says public assertions "won't keep a lid-closed Mac awake", but it may have tested only idle assertions. Even if the hypothesis holds, it fails on unplug, and dark wake has lower capabilities. Use it only as a documented fallback after testing (§13).

---

## 4. How existing apps do it

| App | Closed-lid mechanism on Apple Silicon | Privilege path | Safeguards | Source / confidence |
|---|---|---|---|---|
| **Amphetamine** (App Store, sandboxed) | "Closed-Display Mode". On Apple Silicon it relies on a separately downloaded **Power Protect** script plus a config file, added in 5.3/5.3.1 *"to address unexpected session behavior on Apple Silicon Macs when connecting or disconnecting an external power source"*. Users on issue #28 fixed failures with `sudo pmset -a disablesleep 1`. The script's contents could not be retrieved, but a "script + config file that runs without authentication" points to `pmset` plus a sudoers-style grant. | Script outside the sandbox (Power Protect). Version 5.3 needed admin or Touch ID each run; 5.3.1 removed the prompt | Battery-% trigger, timers. **Amphetamine Enhancer ▸ Closed-Display Mode Fail-Safe** is described only as *"Adds a fail-safe for the closed-display mode feature"*; its implementation was not visible | App Store notes; mac.softpedia changelog for 5.3.2; github.com/x74353/Amphetamine-Enhancer (README, issue #28). *Medium* |
| **KeepingYouAwake** | **None.** README: works "only … on desktop Macs and portable Macs with the lid open" | none (wraps `caffeinate`) | battery-% auto-off | github.com/newmarcel/KeepingYouAwake. *High* |
| **Lungo** (Sindre Sorhus) | **None** unless charger plus external display. FAQ: *"This is a macOS limitation … Your laptop could easily overheat."* | none | — | sindresorhus.com/lungo. *High* |
| **Caffeinated** | Not found. No public implementation details | — | — | *Unknown* |
| **Coca 2.0** | "adds closed-lid support"; mechanism not stated | ? | timers | 9to5mac, 2026-06-12. *Low* |
| **NoSleep** (old, Prokofiev) / **InsomniaX** | Intel-era **kernel extensions**, some later builds with a pmset toggle | kext | — | softpedia/filehorse listings. *Low–Medium* |
| **Theine** | IOPM assertions only, so no lid support | none | — | *Low* |
| **Lidless** (nghialuong, MIT, Jun 2026, 188★) | `pmset -a disablesleep 0/1` run from a **root helper registered with `SMAppService.daemon`**, over XPC with `setCodeSigningRequirement` (team ID) | SMAppService, Developer ID, notarized | **Heartbeat watchdog in the helper: restores sleep if no check-in for 90 s** (checks every 30 s). Pause-when-hot, only-while-charging, low-battery cut-off, auto-off timer | github.com/nghialuong/Lidless `Sources/Helper/HelperService.swift`, `project.yml`. *High* |
| **lidawake** (zaYco, MIT source, paid builds) | `pmset disablesleep` from an SMAppService root helper; **`pmset displaysleepnow` on lid close** "so a closed lid isn't left backlit" | SMAppService plist with `KeepAlive`, `ThrottleInterval 10`, `ExitTimeOut 5`; XPC with mutual signature checks | Battery floor (battery use is **opt-in**, floor default 20%), `ThermalGuard` disarms at `.serious`/`.critical`, an XPC-invalidation dead-man switch (~1.5–2 s), a hang watchdog, an audible warning when the lid closes on battery, and a summary when the lid opens | github.com/zayco-it/lidawake (`Sources/Helper/Watchdog.swift`, `Sources/App/ThermalGuard.swift`, `PowerPolicy.swift`, `TESTING.md`). *High* |
| **Adrafinil** (MIT, macOS 26.4+, 506★) | Root helper exposes only `setSleepBlocked(Bool)`. Runs `/usr/bin/pmset -a disablesleep 0/1` with a 10 s timeout, plus a `PreventUserIdleSystemSleep` assertion. **Agent-aware**: hooks for Claude Code, Codex, Cursor, Cline, Gemini CLI, aider, opencode and others | SMAppService LaunchDaemon with **`RunAtLoad` + `KeepAlive`**. The helper **clears `disablesleep` on construction** (crash and boot recovery) | SMC CPU-temperature cut-off (default 80 °C, read every 15 s only while blocking, lid closed), battery cut-off, chime on lid close, summary on lid open | github.com/kageroumado/adrafinil (`AdrafinilHelper/SleepBlocker.swift`, `LaunchDaemon.plist`, `Monitors/*`). *High* |
| **Sleepless** (MIT) | `pmset disablesleep` called directly with `sudo` | **sudoers**: `<you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1` | Battery floor 5–50% (default 15%), 1–2 h auto-off, reverts in Low Power Mode on battery | github.com/Aboudjem/Sleepless. *High* |
| **NoSleep** (99.co, 2026) | `pmset disablesleep`. "Smart mode" watches agent activity, lets the Mac sleep when done, backs off before the battery empties | not stated (unsigned app) | added after a run drained the battery to 0% | producthunt.com/posts/1229762. *Medium* |

**Common safeguard patterns** (adopt all of them):
- Clear the flag on helper start (boot recovery).
- Clear it when the app crashes or quits (XPC invalidation or heartbeat).
- A **hang** watchdog. A frozen app holds the flag *and* takes its own battery and thermal guards down with it.
- Battery floor, thermal cut-off, auto-off timer.
- Default to "AC only" and make battery use opt-in.
- An audible cue when the lid closes, because a notification can't be seen with the lid shut.

---

## 5. Privileged execution for a non-sandboxed, ad-hoc-signed personal app

### 5.1 Options compared

| Option | Works with ad-hoc signing? | One-time UX | Robustness | Verdict |
|---|---|---|---|---|
| **`/etc/sudoers.d/lidless` NOPASSWD for the exact `pmset` commands** + `sudo -n` | **Yes.** Signing is irrelevant | One admin dialog at install | Survives rebuilds and moves of the app. Sudo matches arguments **literally** | **Recommended for Phase 1** |
| **Root fail-safe LaunchDaemon** in `/Library/LaunchDaemons` (classic, file-based) | Yes | Same admin dialog. macOS 13+ shows a "Background Items Added" notification | Independent of the app's health | **Recommended companion** |
| `SMAppService.daemon(plistName:)` + XPC helper | **Problematic.** DTS (Quinn, forum thread 799910, Sept 2025): *"you should be signing both your embedded helper and your app with the same Apple-issued code-signing identity. If, for example, you are using ad hoc signing … you will see problems like this"* (approval lost after restart). A **free Personal Team "Apple Development"** identity counts as Apple-issued; the thread's author was on a free profile | User toggles it in **System Settings ▸ General ▸ Login Items & Extensions** (Tahoe label: "App Background Activity" / "Allow in the Background") and authenticates as admin. `register()` first throws `SMAppServiceErrorDomain` code 1 until approved | Best long-term design (no password, signature-checked XPC). Every rebuild changes the signature, so the stale job must be fully unregistered and re-registered (nghialuong's `reregister()` notes) | **Phase 2**, once signed with Apple Development or Developer ID |
| `osascript -e 'do shell script "pmset -a disablesleep 1" with administrator privileges'` every time | Yes | **Password every toggle** | Unusable when the lid is closed (no one can type) | Install-time only |
| `AuthorizationExecuteWithPrivileges` | Yes | Password | Deprecated since 10.7 (SDK `Authorization.h:427-431`). The symbol is still exported on 26.6.2 (verified with `dlsym`), but it is unavailable to Swift | No |
| `SMJobBless` | Needs matching signing requirements, effectively Developer ID | Password | Deprecated in macOS 13. Copies the helper out of the bundle, which hits the macOS 27 quarantine-on-copy problem lidawake documented | No |

### 5.2 Exact sudoers drop-in *(syntax verified locally with `visudo -cf`, no root needed)*

File **`/private/etc/sudoers.d/lidless`**: mode `0440`, owner `root:wheel`, and **no dot in the file name** (sudo skips names that contain `.` or end in `~`, per `man sudoers` on this Mac).

```sudoers
# Installed by Lidless. Delete this file to revoke.
tomasnguyen ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
```

- `visudo -cf lidless.sudoers.test` → `parsed OK` (verified). A malformed line is reported as `syntax error` (also verified), so always validate before installing. A broken drop-in can break `sudo` for everyone.
- Requires `#includedir /private/etc/sudoers.d` in `/etc/sudoers`. Apple's sudo package ships this line, and `/private/etc/sudoers.d` exists on this Mac. `/etc/sudoers` is `0440 root`, so it could not be read here. The installer runs `visudo -c`, which lists every file it parses, to confirm. *(Medium-High)*
- `pmset sleepnow` does **not** need sudo (§9.1). Add a shutdown line **only** if the user opts into the hard-shutdown fallback: `tomasnguyen ALL=(root) NOPASSWD: /sbin/shutdown -h now`.
- **Health check with no side effects:** `sudo -n -l /usr/bin/pmset -a disablesleep 1` exits 0 and prints the command if the rule is present, and exits 1 otherwise (`man sudo`: `-l` with a command; `-n` never prompts).
- **Security note:** any process running as the user can now toggle `SleepDisabled`. The worst case is a Mac kept awake (heat and battery), which is why the fail-safe below exists. That is acceptable for a personal tool, but it is still a trade-off.

### 5.3 One-time installer (run from the app while the lid is open)

The app writes `install-privileged.sh` and `lidless-failsafe.sh` into its Application Support folder, then runs:

```applescript
do shell script "/bin/bash " & quoted form of "/Users/tomasnguyen/Library/Application Support/Lidless/install/install-privileged.sh" & " " & quoted form of "tomasnguyen" & " " & quoted form of "/Users/tomasnguyen/Library/Application Support/Lidless/heartbeat" with administrator privileges
```

(From Swift: `NSAppleScript(source:)!.executeAndReturnError(&err)`, or `/usr/bin/osascript -e …`.)

`install-privileged.sh` *(syntax verified with `bash -n`; the embedded plist passed `plutil -lint`)*:

```bash
#!/bin/bash
set -euo pipefail
U="$1"; HB="$2"
[[ "$U" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "bad user name" >&2; exit 2; }
[[ "$HB" == /Users/"$U"/* ]]      || { echo "bad heartbeat path" >&2; exit 2; }
SRC="$(cd "$(dirname "$0")" && pwd)"
DIR="/Library/Application Support/Lidless"

# 1) sudoers drop-in. The file name must NOT contain '.' or end in '~' (sudo skips those).
T=$(/usr/bin/mktemp /tmp/lidless-sudoers.XXXXXX)
printf '%s\n' "# Installed by Lidless. Delete this file to revoke." \
  "$U ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0" > "$T"
/usr/sbin/visudo -cf "$T"                                   # syntax-check the fragment first
/usr/bin/install -m 0440 -o root -g wheel "$T" /private/etc/sudoers.d/lidless
/bin/rm -f "$T"
/usr/sbin/visudo -c                                         # whole config (incl. drop-ins) must parse

# 2) Root-owned fail-safe (user session cannot edit it). Regenerated, never copied, so no
#    com.apple.quarantine xattr can follow it from a downloaded bundle (macOS 27 launchd refuses those).
/bin/mkdir -p "$DIR"
/usr/bin/sed "s|__HEARTBEAT_PATH__|$HB|" "$SRC/lidless-failsafe.sh" > "$DIR/lidless-failsafe.sh"
/usr/sbin/chown -R root:wheel "$DIR"; /bin/chmod 0755 "$DIR" "$DIR/lidless-failsafe.sh"
/bin/cat > /Library/LaunchDaemons/dev.lidless.failsafe.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>dev.lidless.failsafe</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Library/Application Support/Lidless/lidless-failsafe.sh</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>60</integer>
    <key>ProcessType</key><string>Background</string>
</dict>
</plist>
EOF
/usr/sbin/chown root:wheel /Library/LaunchDaemons/dev.lidless.failsafe.plist
/bin/chmod 0644 /Library/LaunchDaemons/dev.lidless.failsafe.plist
/usr/bin/xattr -c /Library/LaunchDaemons/dev.lidless.failsafe.plist "$DIR/lidless-failsafe.sh" 2>/dev/null || true
/bin/launchctl bootout system/dev.lidless.failsafe 2>/dev/null || true
/bin/launchctl bootstrap system /Library/LaunchDaemons/dev.lidless.failsafe.plist
echo "lidless privileged install OK"
```

### 5.4 Fail-safe script (runs as root at boot and every 60 s) *(syntax verified with `bash -n`; the parsing lines were tested read-only on this Mac)*

```bash
#!/bin/bash
# /Library/Application Support/Lidless/lidless-failsafe.sh   (root:wheel 0755)
set -u
PMSET=/usr/bin/pmset
HB="__HEARTBEAT_PATH__"          # substituted at install time
MAX_AGE=150                      # s without an app heartbeat (app touches the file every 30 s)
HARD_FLOOR=7                     # % battery: last-resort floor, below the app's own floor

rd() { /usr/sbin/ioreg -r -n IOPMrootDomain -d 1 | /usr/bin/awk -F'= ' -v k="\"$1\"" '$0 ~ k {gsub(/ /,"",$2); print $2; exit}'; }

[ "$(rd SleepDisabled)" = "Yes" ] || exit 0          # nothing to protect

reason=""
now=$(/bin/date +%s)
boot=$(/usr/sbin/sysctl -n kern.boottime | /usr/bin/sed -E 's/^\{ sec = ([0-9]+),.*/\1/')
if [ ! -f "$HB" ]; then
  reason="no heartbeat file"
else
  hb=$(/usr/bin/stat -f %m "$HB")
  if [ "$hb" -lt "$boot" ]; then reason="stale from before boot"
  elif [ $((now - hb)) -gt "$MAX_AGE" ]; then reason="heartbeat $((now - hb))s old"
  fi
fi
batt=$($PMSET -g batt)
if [ -z "$reason" ] && echo "$batt" | /usr/bin/grep -q "'Battery Power'"; then
  pct=$(echo "$batt" | /usr/bin/grep -Eo '[0-9]+%' | /usr/bin/head -1 | /usr/bin/tr -d %)
  if [ -n "$pct" ] && [ "$pct" -le "$HARD_FLOOR" ]; then reason="battery ${pct}%"; fi
fi
[ -n "$reason" ] || exit 0

/usr/bin/logger -t lidless-failsafe "restoring sleep: $reason"
$PMSET -a disablesleep 0
# If the lid is shut, nothing re-triggers clamshell sleep: sleep explicitly.
for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(rd SleepDisabled)" = "No" ] && break; /bin/sleep 0.5; done
[ "$(rd AppleClamshellState)" = "Yes" ] && $PMSET sleepnow
exit 0
```

Uninstall (also run with admin privileges): `pmset -a disablesleep 0; launchctl bootout system/dev.lidless.failsafe; rm -f /Library/LaunchDaemons/dev.lidless.failsafe.plist /private/etc/sudoers.d/lidless; rm -rf "/Library/Application Support/Lidless"; visudo -c`.

### 5.5 Calling it from Swift *(type-checks under `swiftc -swift-version 6`; deliberately not executed)*

```swift
enum SleepControl {
    enum Failure: Error { case notAuthorized(String), timeout }

    static func setDisableSleep(_ on: Bool) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]   // must match sudoers byte-for-byte
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw Failure.notAuthorized(String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        }
        // pmset writes prefs; powerd applies them asynchronously. Wait for the *kernel*.
        let deadline = Date().addingTimeInterval(5)
        while RootDomain.sleepDisabled != on {
            if Date() > deadline { throw Failure.timeout }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}
```

(Run it off the main actor. `RootDomain.sleepDisabled` reads the IORegistry property; see §6.)

### 5.6 Phase 2: SMAppService helper (when signed with Apple Development or Developer ID)

These details are copied from projects that work (nghialuong/Lidless, lidawake, Adrafinil) and Apple DTS's "Getting Started with SMAppService" (forum thread 802443, Sept 2025, tested with Xcode 26.0):

- The plist goes in `Contents/Library/LaunchDaemons/<label>.plist` and is registered with `SMAppService.daemon(plistName: "<label>.plist").register()`. Expected statuses are `.notRegistered`, `.requiresApproval`, `.enabled` and `.notFound`. `SMAppService.openSystemSettingsLoginItems()` can silently do nothing for `LSUIElement` apps, so also open `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`.
- Keys: `Label`, **`BundleProgram`** (bundle-relative, e.g. `Contents/MacOS/LidlessHelper`), `MachServices {<label>: true}`, `AssociatedBundleIdentifiers [<app id>]`, **`RunAtLoad true` + `KeepAlive true`** so the helper clears the flag at boot and survives crashes, and `ThrottleInterval 10`.
- Helper target: `GENERATE_INFOPLIST_FILE = YES` and `CREATE_INFOPLIST_SECTION_IN_BINARY = YES`, so the tool has a code identity for the launch constraint. Hardened runtime. Copy Files phase "Executables" with code-sign-on-copy.
- XPC listener: `newConnection.setCodeSigningRequirement("identifier \"<app id>\" and anchor apple generic and certificate leaf[subject.OU] = \"<TEAMID>\"")` before `resume()`. **Ad-hoc signing cannot satisfy `anchor apple generic`.** That is one more reason Phase 2 needs an Apple-issued identity.
- Helper-side heartbeat watchdog (90 s), clearing on XPC invalidation, and clearing on helper start. lidawake's watchdog uses an uptime clock, which does not advance during sleep.
- Debug with `sudo launchctl print system/<label>` and reset approvals with `sfltool resetbtm`.
- macOS 27: lidawake found that `SMAppService` jobs are submitted by `smd` and are **not** blocked by a quarantined nested plist, whereas a copied-out `/Library/LaunchDaemons` plist that carries `com.apple.quarantine` fails (`Bootstrap failed: 5`). Lidless's Phase 1 installer regenerates its files and runs `xattr -c`, which covers this case.

---

## 6. Detecting lid state and power events from Swift

### 6.1 Snippet that was built and run on this Mac (read-only)

`/private/tmp/claude-501/-Users-tomasnguyen-Developer/3514aa88-efa8-4a60-97d7-2878eed849d4/scratchpad/research-snippets/clamshell.swift`, built with `swiftc -O clamshell.swift -o clamshell && ./clamshell`:

```swift
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

func rootDomainProperty(_ key: String) -> Any? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(service) }
    return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue()
}

let clamshellClosed = (rootDomainProperty("AppleClamshellState") as? Bool)      // nil => no lid
let clamshellCausesSleep = (rootDomainProperty("AppleClamshellCausesSleep") as? Bool)
let sleepDisabled = (rootDomainProperty("SleepDisabled") as? Bool)
print("AppleClamshellState (lid closed) =", clamshellClosed.map(String.init(describing:)) ?? "nil")
print("AppleClamshellCausesSleep        =", clamshellCausesSleep.map(String.init(describing:)) ?? "nil")
print("SleepDisabled (kernel)           =", sleepDisabled.map(String.init(describing:)) ?? "nil")
// … plus CFPreferences SystemPowerSettings, IOPS battery, thermalState, IOPMCopyAssertionsStatus
```

Actual output (lid open, on battery):

```
AppleClamshellState (lid closed) = false
AppleClamshellCausesSleep        = false
SleepDisabled (kernel)           = false
DesktopMode                      = 0
System Capabilities              = 15
CFPrefs SystemPowerSettings (AnyUser, CurrentHost) = Optional({ "Update DarkWakeBG Setting" = 1; })
Providing power source           = Battery Power
  InternalBattery-0: 72/100 state=Battery Power charging=0 timeToEmpty=136min
IOPSGetBatteryWarningLevel       = 1 (1=none, 2=early(<=20 min left), 3=final(<=10 min left))
ProcessInfo.thermalState         = nominal
ProcessInfo.isLowPowerModeEnabled= false
```

Notes:
- **Use `IOServiceGetMatchingService(…, IOServiceMatching("IOPMrootDomain"))`.** Adrafinil reports that the path `IOService:/IOResources/IOPMrootDomain` does not resolve on 26.3. *(Medium)*
- **Do not rely on `AppleClamshellCausesSleep`.** The kernel updates it only when it sends a clamshell notification, so it is stale between events. It reads `No` here with the lid open on battery, where a fresh evaluation would say `Yes`. It also ignores `SleepDisabled`. *(High, source plus observation)*
- `IOPMSleepEnabled()` (public) only checks for the `IOSleepSupported` property. It is **not** related to `SleepDisabled` (`IOKitUser/IOPMLib.c:404-424`). *(High)*

### 6.2 Event listener, also built and run (`lidwatch.swift`)

```swift
// iokit_family_msg(sub_iokit_powermanagement, 0x100) = 0xE0000000 | (13<<14) | 0x100
let kIOPMMessageClamshellStateChangeValue: UInt32 = 0xE003_4100
let kMsgCanSystemSleep: UInt32 = 0xE000_0270, kMsgSystemWillSleep: UInt32 = 0xE000_0280,
    kMsgSystemWillNotSleep: UInt32 = 0xE000_0290, kMsgSystemHasPoweredOn: UInt32 = 0xE000_0300,
    kMsgSystemWillPowerOn: UInt32 = 0xE000_0320          // SDK IOMessage.h:137-175

// Lid: general-interest notification on IOPMrootDomain
IOServiceAddInterestNotification(notifyPort, rootDomain, kIOGeneralInterest, { _, _, type, arg in
    guard type == kIOPMMessageClamshellStateChangeValue else { return }
    let bits = UInt(bitPattern: arg)
    let closed    = bits & UInt(kClamshellStateBit) != 0   // bit 0
    let willSleep = bits & UInt(kClamshellSleepBit) != 0   // bit 1 (ignores SleepDisabled!)
}, nil, &notifier)

// Sleep/wake: must IOAllowPowerChange() on CanSystemSleep/WillSleep (else sleep is delayed ~30 s)
rootConnect = IORegisterForSystemPower(nil, &sysPort, { _, _, type, arg in
    if type == kMsgCanSystemSleep || type == kMsgSystemWillSleep { IOAllowPowerChange(rootConnect, Int(bitPattern: arg)) }
}, &sysNotifier)
```

Output on this Mac:
```
kIOPMMessageClamshellStateChange = 0xE0034100
now: lidClosed=false causesSleep=false sleepDisabled=false
IOServiceAddInterestNotification -> OK
IORegisterForSystemPower -> OK
  pid 565 powerd: PreventUserIdleSystemSleep 'Powerd - Prevent sleep while display is on'
  pid 1025 sharingd: PreventUserIdleSystemSleep 'Handoff'
  pid 4826 caffeinate: PreventUserIdleSystemSleep 'caffeinate command-line tool'
  pid 7677 caffeinate: PreventUserIdleSystemSleep 'caffeinate command-line tool'
```

A Swift-6-strict version for the app (an `@MainActor` class that passes `Unmanaged` refcon into the C callbacks and uses `MainActor.assumeIsolated`) **type-checks with `swiftc -swift-version 6`**: `research-snippets/PowerKit_typecheck.swift` (`LidPowerMonitor`).

**Event semantics:**
- `kIOPMMessageClamshellStateChange` also fires on **AC plug/unplug and desktop-mode changes** (`IOPMrootDomain.cpp:8961-8992`), so always compare against the last known state.
- With `SleepDisabled=1`, `kIOMessageSystemWillSleep` and `NSWorkspace.willSleepNotification` do **not** fire on lid close, because no sleep happens. `NSWorkspace.screensDidSleepNotification` fires when the panel turns off.
- `kIOMessageCanSystemSleep` is sent only for **idle** sleep. It can be vetoed with `IOCancelPowerChange`, but **demand sleep (lid, menu, `sleepnow`) cannot be vetoed**.
- `NSWorkspace.willSleepNotification`, `didWakeNotification`, `screensDidSleepNotification` and `screensDidWakeNotification` are fine for UI, but use IOKit for policy. *(High/Medium)*
- Polling `AppleClamshellState` at 1 Hz, as lidawake does, is an acceptable belt-and-braces backup.

**The panel may stay lit.** lidawake calls `pmset displaysleepnow` on lid close "so a closed lid isn't left backlit". An HN commenter on Adrafinil also noted that "pmset alone doesn't turn the display off when the lid closes". `pmset displaysleepnow` uses `SLSDisplayManagerRequestDisplaysIdle()` (`pmset.m:986-991`) and does not appear to need root. Call it on every lid-close edge while armed, and skip it when an external display is online (`CGGetOnlineDisplayList` + `CGDisplayIsBuiltin`). *(Medium)*

---

## 7. Network with the lid closed and sleep disabled

- With `SleepDisabled=1` the system **never leaves full wake** (`System Capabilities = 15`, which includes network). Wi-Fi disconnects that people report on MacBooks are tied to *system sleep* (and to `tcpkeepalive`, "Wake for network access" / `womp`, and `networkoversleep`, all of which only matter **during** sleep). All three hands-on agent apps (lidawake, Adrafinil, Sleepless/NoSleep) depend on agents reaching cloud APIs with the lid closed, and lidawake's test log records "network traffic" observed every tick while closed. **Expect Wi-Fi to stay associated.** *(Medium-High; no Apple document states it)*
- Display off does **not** take Wi-Fi down on macOS 26: nothing found, and the source shows no such path. *(Medium)*
- **Low Power Mode** (System Settings ▸ Battery ▸ Energy Mode, chosen separately for battery and adapter; `pmset -g` → `lowpowermode`). Apple only says it "reduces energy use". It should throttle CPU and background work, not disconnect Wi-Fi. Read it with `ProcessInfo.processInfo.isLowPowerModeEnabled` and `NSProcessInfoPowerStateDidChange`. Sleepless treats "Low Power Mode on battery" as a stop condition. *(Medium)*
- Unknowns: 802.11 power-save latency when idle, and whether a closed lid weakens the signal (the antennas sit near the hinge or display). *(Low)* Lidless should watch `NWPathMonitor` and end a closed-lid session if the path stays unsatisfied for N minutes (the agent can't work offline anyway).
- **Not network, but related:** Apple Silicon laptops **disconnect the microphone in hardware when the lid closes** (Apple Platform Security guide). Voice-driven agents stop hearing. *(High)*

---

## 8. Thermal and battery safety for a closed laptop (it may be in a bag)

### APIs (all without root)
| Signal | API | Notes |
|---|---|---|
| Thermal state | `ProcessInfo.processInfo.thermalState` (`.nominal/.fair/.serious/.critical`), `ProcessInfo.thermalStateDidChangeNotification` | lidawake disarms at `.serious`/`.critical` and comments that on Apple Silicon `.fair` already means mild throttling. *(High)* |
| Thermal pressure | `notify_register_check("com.apple.system.thermalpressurelevel")` + `notify_get_state` → `OSThermalPressureLevel` {0 nominal, 1 moderate, 2 heavy, 3 trapping, **4 sleeping**} (SDK `libkern/OSThermalNotification.h`) | Verified on this Mac: `thermal pressure level = 0 nominal` (`thermpressure.swift`). Level "sleeping" means the OS *wants* to sleep, which `SleepDisabled` prevents. *(High)* |
| CPU/SoC temperature | AppleSMC user client (keys `Tp*`/`Te*` as `flt `; Intel `TC0P`) | Private but readable as the user (Adrafinil's LaunchAgent does it). Optional. *(Medium)* |
| Battery % / AC / time left | `IOPSCopyPowerSourcesInfo`, `IOPSCopyPowerSourcesList`, `IOPSGetPowerSourceDescription` → `kIOPSCurrentCapacityKey`, `kIOPSMaxCapacityKey`, `kIOPSPowerSourceStateKey` ("AC Power"/"Battery Power"), `kIOPSIsChargingKey`, `kIOPSTimeToEmptyKey`. `IOPSGetProvidingPowerSourceType` | Verified (output in §6.1). Change notifications: `IOPSNotificationCreateRunLoopSource`, or notify keys `com.apple.system.powersources.source` / `.timeremaining` / `.lowbattery` *(High)* |
| Low-battery level | `IOPSGetBatteryWarningLevel()` → 1 none, **2 early: ≤20 min of runtime**, 3 final: ≤10 min (SDK `IOPowerSources.h:75-97`) | *(High)* |
| Draining while on AC | `AppleSmartBattery` → `InstantAmperage` < 0 (an underpowered USB-C charger) | lidawake uses this so the battery floor also applies while plugged in but draining. *(Medium)* |
| Low Power Mode | `ProcessInfo.isLowPowerModeEnabled` | *(High)* |

A Swift-6 `PowerSnapshot.current()` combining all of these type-checks in `PowerKit_typecheck.swift`.

### Recommended thresholds (closed lid, armed)
The kernel's own low-battery and thermal sleeps are **off** while `SleepDisabled=1`, so these become hard rules:
- **Battery:** battery use is **opt-in, default off**, as in lidawake. When it is on: stop at **≤20%** (configurable 10–50%). Also stop at `IOPSGetBatteryWarningLevel() >= 2`, or when `timeToEmpty < 25 min`, whichever comes first. The root fail-safe has a hard floor at **7%** in case the app is wedged.
- **Thermal:** stop immediately at `.critical` or pressure ≥ `trapping`. Stop at `.serious` (or pressure `heavy`) if it lasts **60 s** with the lid closed. Optionally stop if SMC CPU temperature ≥ **95 °C** for 2 min (Adrafinil defaults to 80 °C). Apple Silicon sits at 90–100 °C under load with the lid open, so a strict 80 °C limit ends heavy sessions early.
- **Bag detection (heuristic):** lid closed **and** on battery **and** thermal state rising. Play a sound when the lid closes on battery (lidawake's lesson: notifications can't be seen).
- **Auto-off cap:** an optional maximum closed-lid session length (e.g. 8 h).
- When a cut-off trips: send a phone notification ("Lidless put your Mac to sleep: battery 19%"), then **clear the flag → wait for the kernel → `IOPMSleepSystem()`**.

---

## 9. Ending the session: sleep or shutdown

### 9.1 Sleep
- **`IOPMSleepSystem(IOPMFindPowerManagement(MACH_PORT_NULL))`.** SDK: *"For security purposes, caller must be root or the console user."* The kernel's `secureSleepSystemOptions` allows `kIOClientPrivilegeLocalUser` or admin (`RootDomainUserClient.cpp:95-110`). **No root needed from the GUI app.** `pmset sleepnow` is the same call, and it prints "You must run this as root" only on `kIOReturnNotPrivileged`. On this Mac, opening the user client as uid 501 succeeded (`privsyms.swift`: `IOPMFindPowerManagement port = 3855`). Sleep itself was not triggered. *(High)*
- With `SleepDisabled=1`, `IOPMSleepSystem` returns **`kIOReturnNotPermitted` (0xE00002E2)**. Required order:
  1. `sudo -n /usr/bin/pmset -a disablesleep 0`
  2. Poll `IOPMrootDomain["SleepDisabled"]` until `false` (usually milliseconds; time out after 5 s)
  3. `IOPMSleepSystem()`, retrying once on 0xE00002E2
- **Clearing the flag with the lid closed does *not* sleep the Mac.** The flag handler starts no re-evaluation (§1). Idle sleep is held off by assertions; on this Mac at the moment: powerd, sharingd ("Handoff"), and **two `caffeinate -i -t 300` processes whose parent is `claude`**, i.e. Claude Code keeps idle sleep away by itself while it runs (verified with `ps`). `ttyskeepawake 1` also lets active ttys block idle sleep. **Always call `IOPMSleepSystem` explicitly.** Demand sleep ignores `PreventUserIdleSystemSleep` (SDK). A later AC plug/unplug would also re-evaluate the lid and sleep the Mac. *(High)*
- Demand sleep can still stop in **dark wake** if a process holds `PreventSystemSleep`/`NetworkClientActive` on AC (dark→sleep is cancelled, `IOPMrootDomain.cpp:3856-3874`). That is acceptable. If it matters, log it with `IOPMCopyAssertionsByProcess`. *(Medium)*
- Effect on terminal sessions: **everything is frozen and resumes on wake.** tmux, shells and Claude Code processes survive. Open HTTP streams to model APIs may time out, which doesn't matter because the agent is idle. On Apple Silicon this is the best balance of energy saved and nothing lost. **Recommended default end action.**

### 9.2 Shutdown options

| Method | Root? | Other permission | Can apps cancel? | Notes |
|---|---|---|---|---|
| Apple Event `kAEShutDown` (`'shut'`) to loginwindow: `osascript -e 'tell application "loginwindow" to «event aevtshut»'`, or `AESend` to `{0, kSystemProcess}` (Apple QA1134) | No | **Automation TCC consent.** Verified on this Mac: `AEDeterminePermissionToAutomateTarget(com.apple.loginwindow, 'aevt','shut', askUserIfNeeded:false)` → **-1744 errAEEventWouldRequireUserConsent** (`aeperm.swift`). Needs `NSAppleEventsUsageDescription`, and with hardened runtime the `com.apple.security.automation.apple-events` entitlement | **Yes** (QA1134: *"can be cancelled by running applications"*) | No confirmation dialog. **Ask for consent during onboarding while the lid is open**, because nobody can click "OK" behind a closed lid |
| `«event aevtrsdn»` (`kAEShowShutdownDialog`) | No | same TCC | Yes | **Shows** the "Shut down now?" dialog, which auto-confirms after its countdown (about 60 s, *Medium*). Pointless behind a closed lid; prefer `'shut'` |
| `tell application "System Events" to shut down` | No | TCC for System Events (`com.apple.systemevents`; not running here, so consent could not be checked) | Yes | Same polite path through loginwindow (*Medium*) |
| `sudo -n /sbin/shutdown -h now` (needs its own sudoers line) | **Yes** | none | **No** | launchd sends SIGTERM to everything, then SIGKILL. Apps get no save prompt and unsaved work is lost (apps using autosave or Versions are fine) |
| `IOKit kPMShutdownSystem` | — | — | — | **Unsupported** in the kernel (`RootDomainUserClient.cpp:579-587`) *(High)* |

**What blocks a polite shutdown in practice:**
- an editor with unsaved changes (VS Code or Cursor show a "Save changes?" sheet);
- **Terminal.app ("Ask before closing: Only if there are processes other than the login shell and …")** with a running `claude`, `codex` or `node` process;
- iTerm2's "Confirm quit".

loginwindow then aborts with "Shut Down was interrupted …" and **the Mac stays on**, with nobody there to answer. *(Medium, standard macOS behavior)*

**Consequences for terminal sessions:** all shells, tmux servers and agent processes are terminated. Claude Code transcripts are persisted, so `claude --resume` works, but in-flight tool calls are lost.

**Recommendation:** default to **sleep**. Offer "Shut down when done" as opt-in. It sends `'shut'` to loginwindow; if the Mac is still up 3 minutes later, Lidless falls back to `IOPMSleepSystem()` (sleep was already re-enabled). Do **not** use `shutdown -h now` unless the user explicitly opts in to "force".

---

## 10. Assertions and `disablesleep` together; how to verify state

- They are independent layers. `SleepDisabled` short-circuits `checkSystemSleepAllowed()` **before** any assertion is considered, so while it is set, assertions don't matter. They still appear in `pmset -g assertions`. Once it is cleared, `PreventUserIdleSystemSleep` again blocks only **idle** sleep, while the lid is open or closed. *(High, source)*
- **The lid has to be "armed" before it closes.** The kernel sleeps synchronously on the lid interrupt. Lidless should set `SleepDisabled=1` while **any agent is busy**, whatever the lid state. With the lid open this also disables idle sleep, which is fine because an agent is working. Also hold a `PreventUserIdleSystemSleep` assertion named e.g. "Lidless: agent active". The kernel releases it if the app dies, and it makes the state visible in `pmset -g assertions`. This is the design Adrafinil and lidawake use. *(High)*
- **Agent-agnostic hint, as a side finding:** `IOPMCopyAssertionsByProcess()` (public, no root) lists who holds `PreventUserIdleSystemSleep`. Claude Code's `caffeinate -i -t 300` children are one example. Other agents and IDEs may do the same. It is useful as a corroborating "busy" signal for the agent-detection work (see 02-*). *(Medium)*
- **Verification commands** (none need root):
  - `pmset -g | head -3` → ` SleepDisabled 1` (persisted prefs)
  - `ioreg -r -n IOPMrootDomain -d 1 | grep -E '"(SleepDisabled|AppleClamshellState)"'` (kernel truth)
  - `pmset -g assertions` (who prevents idle sleep)
  - `pmset -g log | grep -E " (Sleep|Wake|DarkWake) "` (prove that no sleep happened while the lid was closed)
  - `pmset -g therm` (thermal warnings; currently "No thermal warning level has been recorded")

---

## 11. Recommendations for Lidless

1. **Mechanism:** `SleepDisabled` via `/usr/bin/pmset -a disablesleep 0|1`, called through `sudo -n` and the exact sudoers rule in §5.2. Do not call private IOKit setters in-process, use `kPMSetClamshellSleepState`, or depend on dummy displays.
2. **State machine (power layer):**
   - `Idle` → **`Armed`** when ≥1 agent is busy **and** the policy allows it (on AC, or battery opt-in above the floor; thermal ≤ `.fair`; heartbeat OK). On entry: set the flag, hold a `PreventUserIdleSystemSleep` assertion, start the heartbeat file (touch it every 30 s).
   - `Armed` + lid-close edge → **`ClosedAwake`**: run `pmset displaysleepnow` if there's no external display, play a sound if on battery, start the closed-lid safety monitors (battery, thermal, network, max duration), and pause other apps (separate report).
   - `ClosedAwake` and the last agent finishes → send the phone notification, then a **grace period** (default 2 min after "finished", 15 min after "needs input/permission" so the user can answer from the phone) → **`WindingDown`**: clear the flag, wait for the kernel, `IOPMSleepSystem()` (or the opt-in shutdown flow in §9.2).
   - Any safety trip → notify, then the same wind-down. Lid opens → back to `Armed`, or to `Idle` (clear the flag) if no agent is busy.
   - On app launch: **reconcile.** If the kernel flag is set and no agent is busy, clear it (crash recovery). On `applicationWillTerminate`: clear it.
3. **Fail-safe:** the root LaunchDaemon from §5.4: boot clear, stale-heartbeat clear (150 s), hard battery floor 7%, explicit `sleepnow` if the lid is closed. It does not depend on the app or on code signing.
4. **Defaults:** AC-only. Battery opt-in with a 20% floor. Thermal stop at `.serious` for 60 s or `.critical` immediately. End action: sleep. Shutdown is opt-in with a sleep fallback.
5. **Onboarding (lid open):** (a) the admin install, (b) the Automation consent for loginwindow if shutdown is enabled (trigger it with `AEDeterminePermissionToAutomateTarget(…, askUserIfNeeded: true)`), (c) the notification permission.
6. **Phase 2:** once signed with a free Personal Team (Apple Development) identity or Developer ID, replace sudoers with an `SMAppService` root helper: single `setSleepDisabled(Bool)` endpoint, signature-checked XPC, `RunAtLoad`+`KeepAlive`, clear on start, 90 s heartbeat watchdog. Keep the policy in the unprivileged app.
7. **Telemetry while closed:** once a minute, log the kernel `SleepDisabled`, lid state, power source, battery %, thermal state and pressure, and `NWPathMonitor` status, then show a summary when the lid opens (as lidawake and Adrafinil do).
8. **Naming:** `github.com/nghialuong/Lidless` (MIT, 188★, same purpose) already exists. Decide whether that matters for distribution or the bundle ID (`dev.lidless.*` is used in the snippets above).

---

## 12. Risks / unknowns

| # | Risk / unknown | Severity | Mitigation |
|---|---|---|---|
| 1 | `disablesleep` is **undocumented** and could change in a macOS update | High | A health check on every launch (`sudo -n -l …`, then set and read back the kernel flag), plus a test after each OS update. It still works on 27.0 (lidawake, Sep 2026) |
| 2 | **Kernel low-battery and thermal emergency sleeps are disabled** while the flag is set; the battery can reach the hardware cut-off (abrupt power loss) | High | App guards plus the independent root fail-safe (7% floor) |
| 3 | The flag **persists across reboot** and crashes, so the Mac can get stuck unable to sleep | High | Boot clear (`RunAtLoad`), stale-heartbeat clear |
| 4 | A wedged app (alive but hung) holds the flag and its guards are frozen with it | High | Heartbeat from a timer the guards also depend on, checked by the root fail-safe |
| 5 | A Mac in a bag overheats; MacBook Air has no fan | High | Thermal policy (§8), lid-close sound on battery, AC-only default |
| 6 | The panel may stay backlit behind the closed lid | Medium | `pmset displaysleepnow` on lid close (needs a device check) |
| 7 | The sudoers rule lets any same-user process keep the Mac awake | Low–Med | Exact-argument rule; fail-safe; Phase 2 XPC with signature checks |
| 8 | Ad-hoc signing: `SMAppService` daemons are unreliable (DTS), and XPC code-requirement checks are impossible | Medium | Phase 1 sudoers; move to an Apple Development identity later |
| 9 | Shutdown needs TCC consent (verified: would prompt) and can be blocked by apps or Terminal | Medium | Default to sleep; ask for consent in onboarding; fall back to sleep |
| 10 | Clearing the flag with the lid closed does not sleep the Mac (source) | Medium | Always call `IOPMSleepSystem` after the kernel confirms |
| 11 | Wi-Fi stability and latency with the lid closed are not proven by Apple documents | Medium | `NWPathMonitor` watchdog; test plan step 3 |
| 12 | GUI-hosted agents (VS Code/Cursor extension host, Cline, Copilot) may be throttled by App Nap or timer coalescing while the display is off | Medium (unknown) | Test; consider asking the user rather than writing `NSAppSleepDisabled` into other apps' defaults |
| 13 | The screen locks when the lid closes, which breaks GUI-automation agents. The login keychain normally stays unlocked, so CLI token refresh should still work (*Low*) | Low–Med | Document it |
| 14 | `AppleClamshellCausesSleep` and `kClamshellSleepBit` are stale or ignore `SleepDisabled` | Low | Use only `AppleClamshellState` / bit 0 |
| 15 | The AC-only root-free dark-wake hypothesis (§3) is untested | Low | Test plan step 7 before relying on it |
| 16 | The Lid-close hardware mic disconnect affects voice agents | Low | Document it |
| 17 | macOS 27: launchd refuses quarantined, file-loaded LaunchDaemon plists | Low | The installer regenerates files and runs `xattr -c` |
| 18 | Name collision with an existing open-source "Lidless" | Low–Med | Product decision |

---

## 13. On-device test plan (this investigation was read-only; run these yourself)

1. **Install:** run the installer (§5.3). Then `sudo -n -l /usr/bin/pmset -a disablesleep 1` should print the command, and `visudo -c` should list `/private/etc/sudoers.d/lidless: parsed OK`.
2. **Set and observe:** `sudo -n /usr/bin/pmset -a disablesleep 1; pmset -g | head -3; ioreg -r -n IOPMrootDomain -d1 | grep SleepDisabled`. Expect `SleepDisabled 1` / `= Yes`. Confirm the fail-safe clears it within about 60–150 s if no heartbeat file exists. That doubles as a test of the fail-safe.
3. **Closed lid on battery, 10 min:** `touch` the heartbeat in a loop. Run `ping -i 5 1.1.1.1 | while read l; do echo "$(date +%T) $l"; done > /tmp/lid.log &` and `research-snippets/lidwatch 900`. Close the lid, reopen, then check that `/tmp/lid.log` has no gaps and that `pmset -g log | grep -E " (Sleep|Wake|DarkWake) " | tail`.
4. **Panel backlight:** with the lid closed, look at the gap at the hinge in a dark room, with and without `pmset displaysleepnow`.
5. **Clear with the lid closed:** schedule `sleep 120; sudo -n pmset -a disablesleep 0` before closing the lid. Expect **no** sleep (ping continues). Then run `pmset sleepnow` over SSH or a timer and expect sleep.
6. **Reboot persistence:** set the flag, temporarily disable the fail-safe (`sudo launchctl bootout system/dev.lidless.failsafe`), reboot, run `pmset -g`. Expect `SleepDisabled 1`. Re-enable the fail-safe and watch it clear the flag.
7. **AC-only root-free hypothesis:** with the flag 0, on AC, run `caffeinate -s &`, close the lid for 5 min with the ping log running, and look for `DarkWake` and continuous pings.
8. **Shutdown politeness:** with Terminal running `claude`, send `osascript -e 'tell application "loginwindow" to «event aevtshut»'` (accept the TCC prompt) and observe whether Terminal blocks it.

---

## 14. Sources

**Apple source code (fetched 2026-10-12):**
- xnu `IOPMrootDomain.cpp`, `RootDomainUserClient.cpp`, `IOPM.h`: https://github.com/apple-oss-distributions/xnu/tree/xnu-12377.121.6/iokit
- PowerManagement `pmset/pmset.m`, `pmconfigd/PMSettings.m`, `PMAssertions.c`, `pmconfigd.m`, `caffeinate/caffeinate.c`: https://github.com/apple-oss-distributions/PowerManagement/tree/PowerManagement-1846.120.8.0.1
- IOKitUser `pwr_mgt.subproj/IOPMEnergyPrefs.c`, `IOPMLib.c`: https://github.com/apple-oss-distributions/IOKitUser/tree/IOKitUser-100231.120.3

**SDK headers (Xcode 26.6):** `IOKit/pwr_mgt/IOPMLib.h`, `IOPM.h`, `IOKit/IOMessage.h`, `IOKit/ps/IOPowerSources.h`, `libkern/OSThermalNotification.h`, `AE/AERegistry.h`, `Security/Authorization.h`

**Apple docs and DTS:**
- QA1134 (restart/shutdown via loginwindow Apple Events): https://developer.apple.com/library/archive/qa/qa1134/_index.html
- "Getting Started with SMAppService" (Sept 2025): https://developer.apple.com/forums/thread/802443
- DTS on ad-hoc signing and SMAppService: https://developer.apple.com/forums/thread/799910
- Low Power Mode: https://support.apple.com/en-us/101613
- Tahoe Login Items wording / admin-approval notes (vendor): https://www.bresink.com/osx/300423785/Docs-en/pgs/0120-Notes.html

**Prior-art apps (source read where available):**
- https://github.com/nghialuong/Lidless
- https://github.com/zayco-it/lidawake (TESTING.md, CHANGELOG.md, Sources/)
- https://github.com/kageroumado/adrafinil, discussion at https://hn.svelte.dev/item/48701512
- https://github.com/Aboudjem/Sleepless
- https://www.producthunt.com/posts/1229762 (NoSleep)
- https://github.com/x74353/Amphetamine-Enhancer, issue #28: https://github.com/x74353/Amphetamine-Enhancer/issues/28
- Amphetamine changelog: https://mac.softpedia.com/progChangelog/Amphetamine-Changelog-140109.html
- https://github.com/newmarcel/KeepingYouAwake
- https://sindresorhus.com/lungo
- https://9to5mac.com/2026/06/12/how-to-keep-your-mac-awake-even-when-your-macbook-lid-is-closed/

**Secondary articles (lower weight):**
- https://www.getmasset.com/resources/blog/keep-your-mac-awake-for-ai-agents (2026-06-05)
- https://blog.openreplay.com/mac-awake-overnight-agent-runs-caffeinate/ (2026-08-01)
- https://docs.kanaries.net/articles/how-to-make-mac-not-sleep (2026-08-19)
- https://macky.dev/blog/keep-macbook-awake-lid-closed-remote-access (2026-10-04)
- https://www.machinefriendly.com/blog/keep-macbook-awake-lid-closed-awaketoggle
- https://pasqualepillitteri.it/en/news/779/disable-laptop-sleep-lid-close-ai-agents (the disputed "not enough on Apple Silicon" claim)
- https://github.com/Moarram/wake

**Verified locally on this Mac** (all read-only; snippets in `/private/tmp/claude-501/-Users-tomasnguyen-Developer/3514aa88-efa8-4a60-97d7-2878eed849d4/scratchpad/research-snippets/`):
- `pmset -g`, `pmset -g custom`, `pmset -g assertions`, `pmset -g batt`, `pmset -g therm`
- `ioreg -r -n IOPMrootDomain -d 1`
- `plutil -p /Library/Preferences/com.apple.PowerManagement*.plist`
- `strings /usr/bin/pmset`, `strings …/powerd.bundle/powerd`
- `man pmset|caffeinate|sudo|sudoers`
- `clamshell.swift`, `lidwatch.swift`, `aeperm.swift`, `privsyms.swift`, `thermpressure.swift`, `syms2.c`, `aewp.c`
- `PowerKit_typecheck.swift` (`swiftc -swift-version 6 -typecheck`)
- `visudo -cf` on the drop-in
- `bash -n` / `plutil -lint` on the `lidless-install/*` scripts
- `ps` parentage of `caffeinate`
