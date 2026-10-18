# 06: Pausing other apps while the lid is closed (Freeze / Throttle / Quit)

> Research for **Lidless**, a native macOS menu-bar app (Swift 6.3, Xcode 26.6, macOS 26.6.2 arm64, M1 Pro, 16 GB, unsandboxed, ad-hoc signed).
> Date: 2026-10-12. Author: research subagent. Investigation was read-only: no signals were sent, no settings were changed, nothing under `~/.claude` was modified.
> Snippets live in `/private/tmp/claude-501/-Users-tomasnguyen-Developer/3514aa88-efa8-4a60-97d7-2878eed849d4/scratchpad/research-snippets/` (`responsible.swift`, `ptymap.swift`, `footprint.swift`, `identity.swift`, `listeners.swift`, `audio.swift`, `policy.swift`, `compilecheck.swift`).
>
> **Confidence legend:** **[H]** high (verified locally or read in primary source code), **[M]** medium (official docs, a reputable secondary source, or strong reasoning), **[L]** low (inference or a single anecdotal source). Each claim names its source.
>
> **OS note:** macOS 27 "Golden Gate" shipped on 2026-09-14 ([MacRumors](https://www.macrumors.com/2026/09/10/macos-27-golden-gate-release-date/)). This Mac still runs 26.6.2, so every private-API finding below must be re-verified on 27. **[M]**

---

## 0. TL;DR

1. **Freeze (`SIGSTOP`/`SIGCONT`) works and has precedent.** St. Clair Software's App Tamer has shipped it since about 2010; v2.8.4 is current and the site lists support for macOS 10.13 through 27. Any unsandboxed same-uid process may stop another same-uid process. **[H]** Sources: App Tamer site and FAQ, the sspai article, XNU `kern_sig.c`.
   - A frozen app uses **zero CPU and zero wakeups**.
   - A frozen app **keeps all of its RAM**. Its pages become the first candidates for compression or swap only once there is memory pressure. **RAM is freed only by quitting.**
2. **Stopping only the main pid is useless.** On this Mac:
   - Arc owns 33 processes.
   - Safari, Word, Notes and Xcode own XPC services whose ppid is 1 (`com.apple.WebKit.Networking`, `WebKit.GPU`, `openAndSavePanelService`, ...).
   - The private **responsibility API** (`responsibility_get_pid_responsible_for_pid`, resolved with `dlsym`) returns exactly these groups.
   - The resource coalition id (private `proc_pidinfo` flavor 20) matches it for normal apps.

   **[H]** verified locally by `./responsible`.
3. **Critical: never freeze the app that hosts an agent.** On this Mac, **all agents and their MCP servers are "owned" by Terminal.app**: 83 responsible processes, about 7.1 GB footprint and 90 % CPU. A naive "freeze Terminal and its helpers" would freeze every agent. **[H]** `./responsible`, `./footprint`.
   - **Stalled reader:** even if the agent itself keeps running, a frozen reader of the pty master blocks the agent after **≤ about 2 KB** of output. XNU `ttwrite` sleeps once the output queue passes `t_hiwat`, which is capped at `TTMAXHIWAT` = 2048. Node.js makes TTY stdout **blocking** (`setBlocking(true)`), so the whole event loop stops. **[H]** XNU `tty.c`/`tty.h`, Node `lib/tty.js`.
   - **VS Code:** VS Code's ptyHost pauses the pty once 100,000 characters are unacknowledged by the renderer. **[H]** VS Code `FlowControlConstants`.
   - **tmux:** tmux decouples. It discards output and redraws later instead of blocking panes. **[M]** tmux `tty.c`.
4. **Agent → tty → pty-master holder** can be computed in about 60 ms for about 400 processes:
   - Read `kinfo_proc.e_tdev` (minor = pty index).
   - Find every fd whose `PROC_PIDFDVNODEPATHINFO` path is `/dev/ptmx`. `minor(vst_rdev)` = pty index (master major 15, slave major 16).

   **[H]** verified by `./ptymap`: Terminal holds `ttys000`–`ttys007`, and Claude's own host process holds `ttys009`.
5. **Throttle (`setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)`) is allowed for same-uid targets.** In XNU, `do_background_proc` checks only uid plus MACF.
   - It gives low CPU priority (E-cores on Apple Silicon per App Tamer), throttled I/O tier and background sockets.
   - Children inherit it.
   - **[H]** XNU `kern_resource.c`, `task_policy.c`. App Tamer's "efficiency cores" option uses exactly this, per sspai **[M]**.
   - Neither `pid_suspend()` nor App Nap is usable by a third party. `pid_suspend` needs task-port-level authorization; App Nap cannot be forced from outside. **[H]/[M]**
6. **Crash safety is mandatory.** Lidless must:
   - write a journal before it stops anything;
   - identify processes by **audit token (pid + pidversion)** and use the public `proc_signal_with_audittoken()`. The pid space wrapped about every 2–6 h on this machine under agent load (measured 260–770 new pids/min). **[H]**
   - run a tiny guard process that thaws on Lidless exit, recover at launch and login, and thaw before sleep, logout or shutdown:
     - loginwindow gives apps 45 s, then aborts logout. **[M]**
     - Unanswered sleep notifications delay sleep by 30 s. **[M]** (QA1340)
     - A stopped process with a SIGTERM *handler* will not run it until `SIGCONT`. A stopped process *without* a handler dies at once (XNU treats default-kill like `SIGKILL`). **[H]** (XNU `kern_sig.c`)

---

## 1. Mechanisms

### 1.1 Freeze = `SIGSTOP` / `SIGCONT`

**Semantics (XNU, `bsd/kern/kern_sig.c` and `bsd/sys/signalvar.h`, xnu main fetched 2026-10-12)** **[H]**
- `SIGSTOP` cannot be caught or ignored.
  - Its property is `SA_STOP`.
  - Delivery sets `p_stat = SSTOP` and calls `stop()` → `task_suspend_internal`. The whole task (all threads) stops.
  - The parent gets `SIGCHLD` unless it set `SA_NOCLDSTOP`. For GUI apps the parent is launchd.
- `SIGCONT` sets `P_CONTINUED` and calls `task_resume_internal`. Any signals that became pending while the process was stopped are then delivered.
- `SIGKILL` always kills a stopped process.
- **A default-action kill signal with no handler (for example `SIGTERM` to a process that never installed a handler) "needs to act like SIGKILL"**, so it also kills a stopped process at once.
  - A process that **has** a handler keeps the signal pending until `SIGCONT`. Examples: Chromium and Electron install one, as do many daemons that use `DispatchSource`.
  - So the claim "SIGTERM is queued until SIGCONT" holds only for processes that handle SIGTERM.
- Use **`SIGSTOP`, never `SIGTSTP`**. Apps and terminals can catch or ignore `SIGTSTP`.
- **Permission:** POSIX `kill(2)` rules apply. Same real or effective uid is enough, plus the MACF signal check, which only matters if the caller is sandboxed. Lidless is unsandboxed, so it can stop any of the user's own processes. It cannot stop root or other users' processes (WindowServer, `login`, `sshd`, network extensions). **[H]** XNU `psignal_by_audit_token` → `cansignal_nomac`. Precedent: App Tamer, ForceNap, bgviewer, App Freezer (below).

**Precedent: App Tamer (St. Clair Software)** **[M]** (vendor docs plus third-party review)

- **Mechanism.**
  - "Stop" sends `SIGSTOP` when an app goes to the background and `SIGCONT` when you return.
  - "CPU limit" duty-cycles `SIGSTOP`/`SIGCONT`.
  - "Run on efficiency cores" uses `setpriority(PRIO_DARWIN_BG)`.

  Sources: [sspai review of App Tamer 3.0 beta, 2026](https://sspai.com/prime/story/manage-macos-background-activities-with-app-tamer), [Apple forum thread 127650](https://developer.apple.com/forums/thread/127650) (App Tamer's SIGCONTs made LLDB stop, because LLDB stops on SIGCONT).
- **Defaults** ([FAQ](https://www.stclairsoft.com/AppTamer/faq.html)):
  - Mail is slowed to 25 %, Spotlight to 20 % and Time Machine to 50 %.
  - Browsers were slowed to 2 %; v2.8.3 changed this to 10 % to cut audio and video stutter.
  - Photoshop, Word, InDesign and Preview are **stopped**.
- **Exclusions and guidance** (FAQ, [Managing apps](https://www.stclairsoft.com/AppTamer/help/pages/managing.html), [Preferences](https://www.stclairsoft.com/AppTamer/help/pages/preferences.html)):
  - "The Finder should usually be left running because it provides services to a lot of other applications."
  - Mail: "slow but not stop it." Apps receiving internet data: "slowed but not stopped." Floating UI utilities: slow, not stop.
  - It never stops or slows anything while **any** sound is playing ("will keep the app running whenever sound is coming from any app or sound source").
  - It never stops browsers while they download.
  - It **periodically wakes stopped apps "for a few seconds"** (default every 5 min).
  - There is a configurable "settle" delay before stopping, because "many apps only copy data to the clipboard once they're in the background."
  - Optional: "don't slow/stop when the Mac has been idle more than X min."
- **Known problems.**
  - Stopped apps "do not respond to macOS' checks to see if they're running", so you get a beachball. Clicking the window wakes the app.
  - Chrome and Firefox show "page/script isn't responding" if stopped too long. The vendor suggests slowing them to 1 % instead.
  - Old conflicts with other utilities (Macworld) and with Xcode/LLDB (SIGCONT).
  - v2.0.3 fixed apps hanging at restart or shutdown.
- **Helper processes and crash safety** ([release notes](https://stclairsoft.com/AppTamer/release_notes.html)):
  - v2.2: "helper processes such as Safari Web Content, Safari Networking" are stopped and started with the app.
  - v2.3.4: helper-process control for browsers, Spotlight, backup tools.
  - v2.8.1: "automatically deactivates if App Tamer crashes or is forced to quit."
  - v2.8.2: restores process priority after a crash.
  - **v2.8.4: on launch it "will restart processes that have been stopped by other apps or tools."** This matters for Lidless: if the user also runs App Tamer, its launch resumes apps that Lidless stopped. (See Risks.)
  - It uses a privileged helper in `/Library/LaunchDaemons` and `/Library/PrivilegedHelperTools` to control root processes (Spotlight, Time Machine). Lidless should **not** do that.
- **Other precedents.**
  - [ForceNap](https://gitblind.noratr.app/omikun/ForceNap) (Sierra era): beachball, "Not responding" in Activity Monitor; crash recovery not handled.
  - bgviewer (MIT, macOS 13+, SIGSTOP/SIGCONT).
  - [App Freezer](https://www.raycast.com/changxu_song/appfreezer) (Aug 2026): a native agent that "manages process trees, sends signals, applies safety rules, and persists recovery state." **[M]**

**Effects of freezing a GUI app**

| Area | What happens | Conf. / source |
|---|---|---|
| **WindowServer / UI** | The app stops draining its event queue. After a few seconds of pending events the cursor over its windows becomes the spinning wait cursor, and Force Quit and Activity Monitor show "(Not Responding)". Once resumed it processes the backlog and recovers. With the lid closed and no input, very few events reach it. | [M] App Tamer FAQ, ForceNap README, [Wikipedia](https://en.wikipedia.org/wiki/Spinning_pinwheel) (~4 s threshold per MacPaw, [L]) |
| **CPU / energy** | 0 % CPU and 0 timer wakeups for every frozen process. Measured on this Mac (lid open, 10 s window, `proc_pid_rusage` V6): **all non-agent regular apps together = about 14 % of one core and about 71 mW** of billed energy. Arc was 4.6 % / 34 mW; TextEdit 5.5 % / 20 mW; Finder 1.8 % / 12 mW; Spotify, Word, Xcode, Notes and Safari were under 2 mW each. With the lid closed, App Nap already throttles much of this, so typical savings are **tens to a few hundred mW**. A runaway tab, WebGL page, Electron animation or game launcher can be **watts**. | [H] `./footprint`; App Nap note [M] |
| **RAM** | Nothing is freed. `phys_footprint` is unchanged, because compressed pages still count. Under pressure, the stopped app's untouched anonymous pages age into the inactive queue first and get compressed or swapped first. Clean file-backed pages are evicted. This Mac is already under memory load: 4.65 GB of 6 GB swap used, and the compressor holds 1,481,787 × 16 KB ≈ 22.6 GB of data in 362,436 pages ≈ 5.5 GB (ratio about **4.1 : 1**). Footprint of all regular apps is 15.8 GB, of which **7.1 GB is the agents (Terminal group)** and about 8.7 GB is everything else (Arc alone 6.7 GB). Freezing makes that 8.7 GB **cheap to reclaim** (≈ 2 GB if compressed at 4:1, or swapped out) once the agent needs memory; **quitting** frees it. On lid open, resuming apps fault pages back in, which can make them briefly sluggish. | [H] `vm_stat`, `sysctl vm.swapusage`, `./footprint`; VM behaviour [M] |
| **Timers** | `mach_absolute_time` keeps advancing while a process is stopped. On Apple Silicon it does **not** advance during system sleep. So on `SIGCONT` every overdue `NSTimer` or `DispatchSourceTimer` fires once, immediately and coalesced. Apps get **no** `NSWorkspace.didWakeNotification` because the system never slept, so logic that only refreshes on wake will not run. | [M] reasoning from XNU/libdispatch semantics |
| **Network** | The kernel TCP stack keeps working: it ACKs into the socket buffer, then advertises a zero window, and answers kernel keepalives, so TCP connections do not die by themselves. **Application-level heartbeats** do fail: WebSocket ping/pong (Slack, Discord, Teams), MQTT, IMAP IDLE (about 29 min), HTTP/2 and QUIC idle timeouts. Servers close those sessions and the app reconnects when resumed, much as after a network change. App Tamer's guidance ("apps receiving internet data: slow, don't stop") and its 5-minute "wake for a few seconds" exist for this reason. | [M] reasoning + App Tamer FAQ |
| **Audio** | The app's CoreAudio IO thread stops, so playback cuts out or glitches. Do not freeze any app that is producing or capturing audio. It can be detected with **public** CoreAudio process objects (macOS 14.2+): `kAudioHardwarePropertyProcessObjectList` → `kAudioProcessPropertyPID`, `kAudioProcessPropertyIsRunningOutput`, `kAudioProcessPropertyIsRunningInput`. Verified readable without any prompt (27 audio clients, none playing). | [H] SDK `AudioHardware.h` + `./audio`; App Tamer audio rule [M] |
| **iCloud / file coordination** | The sync daemons (`bird`, `cloudd`, `fileproviderd`) are system processes and keep running. But if the frozen app is an `NSFilePresenter` or is in the middle of coordinated I/O, other coordinated readers or writers (fileproviderd, other apps) can wait for it. Apple TN2408 warns of deadlock "when a process is suspended mid coordinated I/O". CLI agents do not use `NSFileCoordinator`, so the agent's own file writes are not blocked. | [L]/[M] [TN2408 via mjtsai](https://mjtsai.com/blog/2014/11/21/) |
| **Pasteboard** | If the frozen app owns lazily-provided (promised) clipboard data, `pbpaste` or a paste in another app waits for it. App Tamer's settle delay exists partly for clipboard data. | [L]/[M] App Tamer prefs |
| **Apple Events / XPC / Mach IPC to the app** | `osascript -e 'tell app "X"'`, `open -a X`/`open URL` (LaunchServices sends an AE to a running app), Xcode's `mcpbridge` and similar block until their timeout. The AE default is about 2 min. **This IPC cannot be detected via file descriptors.** | [M] reasoning; `xcrun --find mcpbridge` → `/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge` [H] |
| **Power assertions** | IOPM assertions held by a frozen app stay held (for example `PreventUserIdleSystemSleep` from a video app). Forced sleep (`IOPMSleepSystem`, lid) is not blocked by idle-sleep assertions. | [M] |
| **Logout / shutdown** | loginwindow sends each app a quit Apple Event and gives it **45 s**. A frozen app cannot reply, so you get "Your Mac hasn't logged out/shut down because X failed to quit." Background processes get an AE and then SIGKILL. | [M] [Eclectic Light, 2023](https://eclecticlight.co/2023/03/18/loginwindow-does-more-than-log-you-in/), 1Password/Bitwarden community threads |
| **System sleep** | Apps registered with `IORegisterForSystemPower` must acknowledge `kIOMessageSystemWillSleep`. A frozen one cannot, so **sleep is delayed by 30 s**. | [M] [Apple QA1340](https://developer.apple.com/library/archive/qa/qa1340/_index.html) |
| **Debuggers / job control** | A traced process (`P_LTRACED`, `PROC_FLAG_TRACED`) must not be touched, because LLDB stops on SIGCONT. For a CLI process that is a foreground job of an interactive shell, the shell sees it stop and **moves it to the background** ("zsh: suspended (signal)"); after `SIGCONT` it may get `SIGTTIN` when it reads the tty. Never signal processes that have a controlling tty. | [H] forum 127650 (Apple DTS); job-control behaviour [M] |

### 1.2 Throttle = `PRIO_DARWIN_BG` (what `taskpolicy -b -p <pid>` does)

- **API:**
  ```swift
  setpriority(PRIO_DARWIN_PROCESS, id_t(pid), PRIO_DARWIN_BG)
  ```
  This is public (`<sys/resource.h>`: `PRIO_DARWIN_PROCESS = 4`, `PRIO_DARWIN_BG = 0x1000`). Undo with `setpriority(PRIO_DARWIN_PROCESS, pid, 0)`. Read the state back with `getpriority(PRIO_DARWIN_PROCESS, pid)` (1 = background). **[H]** SDK header; `man taskpolicy` (`-b`, `-B`, `-p pid`).
- **Permission:** XNU `do_background_proc()` returns `EPERM` only if the caller is not root **and** neither the caller's uid nor ruid equals the target's uid. Then it runs `mac_proc_check_sched` (the sandbox hook). **So an unsandboxed same-uid app may do it.** The policy is recorded as **external** darwinbg (`TASK_POLICY_EXTERNAL, TASK_POLICY_DARWIN_BG`), which is separate from the app's own internal requests. **[H]** XNU `bsd/kern/kern_resource.c`. Not executed here, because of the read-only rule.
- **Effects** (`osfmk/kern/task_policy.c`) **[H]**:
  - darwinbg → `tep_lowpri_cpu` (lowest priority band);
  - `tep_all_sockets_bg` and `tep_new_sockets_bg` (background network traffic class);
  - I/O tier `trp_bg_iotier` (default `THROTTLE_LEVEL_TIER2`);
  - watchers bg;
  - turnstile boost clamped.
  
  It is **not** cancelled by importance boosts. On Apple Silicon App Tamer says it "instructs the system to run the app on the processor's efficiency cores" **[M]**.
- **Inheritance:** `task_policy_create()` copies `trp_ext_darwinbg` to children. Helpers spawned while throttled start throttled, and Lidless must clear them too. A crash leaves apps throttled until they exit; App Tamer fixed exactly this bug in v2.6.3 and v2.8.2. **[H]** XNU / **[M]** release notes.
- **Not available:**
  - `PRIO_DARWIN_ROLE`: same-uid is allowed but the constants are private, and RunningBoard sets roles too.
  - `PRIO_DARWIN_GAME_MODE` and `PRIO_DARWIN_RUNAWAY_MITIGATION`: both need private entitlements.
  
  **[H]** XNU `kern_resource.c`.
- **Hard throttle (optional):** duty-cycle `SIGSTOP`/`SIGCONT` (App Tamer's CPU %). It enforces a cap, but costs wakeups and has the same hang-detector risks. Use it only for runaway apps.

### 1.3 Not usable

- **`pid_suspend()`/`pid_resume()`** (`task_pidsuspend`, which iOS/RunningBoard uses). In XNU (`bsd/kern/kern_proc.c`) a non-root caller needs `task_for_pid_posix_check` **or** the private `PROCESS_RESUME_SUSPEND_ENTITLEMENT`. It then goes through `mac_proc_check_suspend_resume` **and** a taskgated `TASK_FLAVOR_CONTROL` upcall, which is the same authorization as `task_for_pid`: debugger entitlement or developer tools, and denied for hardened targets. Not viable for an ad-hoc-signed app. **[H]** source (not executed).
- **App Nap.** It is a system heuristic: not foreground, not visibly drawing, not audible, no IOKit or `NSProcessInfo` assertions, no OpenGL. It lifts automatically on an XPC message or Apple Event. **No API lets one app force App Nap onto another.** The only external knob is the per-app user default `NSAppSleepDisabled`, which only *disables* it, and Lidless must not write other apps' preferences. Apple itself notes App Nap measures "do not necessarily save energy." With the lid closed every window is invisible, so napping apps nap anyway, and Freeze adds value mainly for apps that opt out or stay busy. **[M]** [Apple Energy Guide, App Nap](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html).
- **`NSRunningApplication.hide()`** "Attempts to hide the receiver." With the lid closed every window is already invisible, so it adds nothing. **[H]** SDK header `NSRunningApplication.h`.
- **RunningBoard (`runningboardd`)** tracks app and XPC lifecycle and assertions and is undocumented. LaunchServices itself starts apps suspended and sends `SIGCONT` ([Eclectic Light 2025](https://eclecticlight.co/2025/07/10/what-does-runningboard-do-1-app-launching/)). Third parties have no suspend API. The private `RunningBoardServices` framework (`RBSProcessHandle`) could only be used to *observe*; not recommended. **[M]**

### 1.4 Quit = `NSRunningApplication.terminate()`

- `terminate()` "Attempts to quit the receiver normally. @return YES if the request was successfully sent ... This method may return before the receiver exits; you should observe the terminated property or listen for the notification." `forceTerminate()` is the forced variant. **[H]** SDK header. Under the hood it sends the `kAEQuitApplication` Apple Event, which triggers save dialogs. App Tamer: "those alerts will still pop up ... App Tamer doesn't auto-OK them."
- **Safe-to-quit signal (public API):** `proc_get_dirty(pid, &flags)` in `<libproc.h>`. The flags are `PROC_DIRTY_TRACKED` 0x1, `PROC_DIRTY_ALLOWS_IDLE_EXIT` 0x2 and `PROC_DIRTY_IS_DIRTY` 0x4 (`<sys/proc_info.h>`). Measured:
  - TextEdit, Terminal, Finder and Xcode: `0x5` (tracked + dirty, so sudden termination is currently disabled).
  - Arc, Safari, Notes, Spotify and Word: `0x0` (not tracked).
  - Info.plist `NSSupportsSuddenTermination` was YES for TextEdit, Terminal, Xcode, Keynote, Pages and Numbers, and false for Arc, Safari and WhatsApp.
  
  Rule: treat **TRACKED && !IS_DIRTY** as "clean, quitting is safe". Anything else needs user opt-in. **[H]** `./identity`; mapping to `NSProcessInfo.disableSuddenTermination` is **[M]**.
- **Relaunch:** `NSWorkspace.shared.openApplication(at:configuration:)` with `configuration.activates = false`. Windows come back only if the app restores its own state (browsers restore tabs), or if the user turned off System Settings › Desktop & Dock › "Close windows when quitting an application" (`NSQuitAlwaysKeepsWindows`). **[M]**
- Quit is the **only** mode that actually frees RAM.

### 1.5 Mode comparison

| | Freeze (SIGSTOP) | Throttle (DARWIN_BG) | Quit (terminate) |
|---|---|---|---|
| CPU / wakeups | 0 | Low priority + E-cores; timers still fire | 0 |
| RAM freed | Only under pressure (compress/swap) | No | **Yes** |
| Network sessions | Heartbeats time out; app reconnects on resume | Stay alive (background class) | Gone; restored on relaunch |
| Audio / UI | Stops; beachball | Works, slower | n/a |
| Crash risk if Lidless dies | Apps **frozen forever** until thawed | Apps stay slow until they exit | Apps stay quit |
| Breaks agent if misapplied | **Yes, hard hang** | Rarely (slower) | Yes (lost service) |
| Needs | same uid | same uid | same uid; AE; dirty check |

---

## 2. Finding every process that belongs to an app

### 2.1 What does not work
- **Only the main pid.** XPC services (WebKit Networking/GPU/WebContent, `openAndSavePanelService`, QuickLook) have **ppid 1** (launchd).
- **The ppid tree via `proc_pidinfo(PROC_PIDTBSDINFO)`.** It fails for processes you do not own. Terminal's children are the root-owned setuid `login`, so the walk found **0** descendants for Terminal even though `ps` shows `Terminal → login → zsh → claude`. If you use the ppid tree at all, take it from `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_ALL)` (`kinfo_proc.kp_eproc.e_ppid`), which works across uids. **[H]** `./responsible` vs `./ptymap`.

### 2.2 Responsibility API (private, stable since about 10.14, used by TCC, Chromium, Qt, LLDB)
- **Signature:** `pid_t responsibility_get_pid_responsible_for_pid(pid_t pid);`
  - It is exported by `/usr/lib/system/libquarantine.dylib` (part of libSystem) and is even listed in the SDK stub `MacOSX.sdk/usr/lib/system/libquarantine.tbd`.
  - Siblings in the same stub: `responsibility_get_uniqueid_responsible_for_pid`, `responsibility_get_responsible_audit_token_for_audit_token`, `responsibility_spawnattrs_setdisclaim(posix_spawnattr_t, int)`.
  - **[H]** `grep` of the SDK `.tbd`. Chromium declares `extern "C" pid_t responsibility_get_pid_responsible_for_pid(pid_t);` ([process_info_mac.mm](https://chromium.googlesource.com/chromium/src/+/606f178bd02294de6187be5c0f4e2dcd86058dfa/base/process/process_info_mac.mm)). The Qt blog explains the semantics and `disclaim` ([2022-02-04](https://www.qt.io/blog/the-curious-case-of-the-responsible-process)).
- **Behaviour observed** **[H]**:
  - It returns `-1` for every process **not owned by the caller**: 194 failures = exactly the 592 − 398 other-uid pids.
  - For self-responsible processes (anything LaunchServices launched) it returns the pid itself.
  - Responsibility **survives reparenting**: an orphaned `claude` with ppid 1 is still attributed to Terminal.
  - Children launched from Terminal, iTerm2, VS Code or CLion are attributed to that host app unless they were spawned with `responsibility_spawnattrs_setdisclaim(attr, 1)` (Qt blog **[M]**).
- **Exact working code** (`responsible.swift`, compiled with `swiftc -O responsible.swift -o responsible`, run 2026-10-12 on macOS 26.6.2):

```swift
// READ-ONLY research snippet for Lidless (06-app-pausing).
// For every NSWorkspace "regular" app, count the processes it is *responsible* for
// (private responsibility API, resolved via dlsym), compare with the ppid-descendant
// count, and (best effort) the resource coalition id. Sends no signals, changes nothing.
//
// Build:  swiftc -O responsible.swift -o responsible && ./responsible
import AppKit
import Darwin

// MARK: - Private API via dlsym (libquarantine.dylib, part of libSystem; exported in the SDK .tbd)
// pid_t responsibility_get_pid_responsible_for_pid(pid_t pid);
typealias RespPidFn = @convention(c) (pid_t) -> pid_t
let RTLD_DEFAULT_HANDLE = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT == (void *)-2 on Darwin
guard let respSym = dlsym(RTLD_DEFAULT_HANDLE, "responsibility_get_pid_responsible_for_pid") else {
    fatalError("responsibility_get_pid_responsible_for_pid not found")
}
let responsiblePid = unsafeBitCast(respSym, to: RespPidFn.self)

// MARK: - libproc helpers (public)
func allPids() -> [pid_t] {
    let n = proc_listallpids(nil, 0)
    guard n > 0 else { return [] }
    var buf = [pid_t](repeating: 0, count: Int(n) + 64)
    let got = buf.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    return Array(buf.prefix(Int(max(got, 0)))).filter { $0 > 0 }
}

func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
    return r == size ? info : nil
}

func procName(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 1024)
    let n = proc_name(pid, &buf, UInt32(buf.count))
    if n > 0 { return String(cString: buf) }
    var pbuf = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
    if proc_pidpath(pid, &pbuf, UInt32(pbuf.count)) > 0 { return (String(cString: pbuf) as NSString).lastPathComponent }
    return "?"
}

// Private flavor PROC_PIDCOALITIONINFO (20) from xnu bsd/sys/proc_info_private.h:
// struct proc_pidcoalitioninfo { uint64_t coalition_id[COALITION_NUM_TYPES /*2*/]; uint64_t reserved1, reserved2, reserved3; };
func coalitionIDs(_ pid: pid_t) -> (resource: UInt64, jetsam: UInt64)? {
    var buf = [UInt64](repeating: 0, count: 5)
    let size = Int32(buf.count * 8)
    let r = buf.withUnsafeMutableBytes { proc_pidinfo(pid, 20, 0, $0.baseAddress, size) }
    return r == size ? (buf[0], buf[1]) : nil
}

// MARK: - Snapshot
let me = getuid()
let pids = allPids()
var ppidOf: [pid_t: pid_t] = [:]
var uidOf: [pid_t: uid_t] = [:]
var respOf: [pid_t: pid_t] = [:]
var coalOf: [pid_t: UInt64] = [:]
var respFailures = 0, coalFailures = 0
for p in pids {
    if let bi = bsdInfo(p) { ppidOf[p] = pid_t(bi.pbi_ppid); uidOf[p] = bi.pbi_uid }
    let r = responsiblePid(p)
    if r > 0 { respOf[p] = r } else { respFailures += 1 }
    if let c = coalitionIDs(p) { coalOf[p] = c.resource } else { coalFailures += 1 }
}
var childrenOf: [pid_t: [pid_t]] = [:]
for (c, pp) in ppidOf { childrenOf[pp, default: []].append(c) }
func descendants(_ root: pid_t) -> [pid_t] {
    var out: [pid_t] = [], stack = childrenOf[root] ?? []
    while let p = stack.popLast() { out.append(p); stack.append(contentsOf: childrenOf[p] ?? []) }
    return out
}
var responsibleSet: [pid_t: [pid_t]] = [:]
for (p, r) in respOf where r != p { responsibleSet[r, default: []].append(p) }

print("total pids: \(pids.count)  same-uid: \(uidOf.values.filter { $0 == me }.count)  responsibility lookups failed: \(respFailures)  coalition lookups failed: \(coalFailures)")
print("")
print(String(format: "%-34@ %6@ %5@ %5@ %5@ %5@  %@", "app (bundle id)" as NSString, "pid" as NSString, "resp" as NSString, "tree" as NSString, "coal" as NSString, "ppid1" as NSString, "sample of responsible processes" as NSString))
let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
var totalResp = 0
for app in apps.sorted(by: { ($0.localizedName ?? "") < ($1.localizedName ?? "") }) {
    let pid = app.processIdentifier
    let resp = responsibleSet[pid] ?? []
    let tree = descendants(pid)
    let coalPeers: Int = { guard let c = coalOf[pid], c != 0 else { return -1 }; return coalOf.filter { $0.value == c && $0.key != pid }.count }()
    let launchdChildren = resp.filter { ppidOf[$0] == 1 }.count // e.g. XPC services: ppid 1 but attributed to the app
    totalResp += resp.count
    var names: [String: Int] = [:]
    for p in resp { names[procName(p), default: 0] += 1 }
    let sample = names.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key)x\($0.value)" }.joined(separator: ", ")
    let label = "\(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "-"))"
    print(String(format: "%-34@ %6d %5d %5d %5d %5d  %@", String(label.prefix(34)) as NSString, pid, resp.count, tree.count, coalPeers, launchdChildren, sample as NSString))
}
print("\nprocesses attributed to regular apps via responsibility: \(totalResp)")

// Where do agent CLIs land? (claude / codex / gemini / aider / opencode / copilot / cursor-agent)
let agentNames = ["claude", "codex", "gemini", "aider", "opencode", "copilot", "cursor-agent", "goose", "amp", "cline"]
print("\nagent-like processes -> responsible app:")
for p in pids.sorted() {
    let n = procName(p)
    guard agentNames.contains(where: { n.lowercased().hasPrefix($0) }) else { continue }
    let r = respOf[p] ?? -1
    let rApp = NSRunningApplication(processIdentifier: r)
    print("  pid \(p) \(n)  ppid \(ppidOf[p] ?? -1) (\(procName(ppidOf[p] ?? 0)))  responsible \(r) (\(rApp?.bundleIdentifier ?? procName(r)))")
}
```

- **Output** (reformatted). Totals: 592 pids, 398 same-uid, 194 responsibility failures (= other-uid), 0 coalition failures.

| App (bundle id) | pid | responsible procs | ppid-tree (via proc_pidinfo) | same resource coalition | of which ppid==1 | Sample |
|---|---|---|---|---|---|---|
| Arc (`company.thebrowser.Browser`) | 92564 | **33** | 31 | 33 | 2 | Browser Helper (Renderer)×26, Browser Helper×5, `com.apple.SafariPlatformSupport`, `com.apple.AuthenticationService` |
| Finder | 1313 | 0 | 0 | 0 | 0 | |
| Microsoft Word | 98152 | **6** | 0 | 6 | 6 | `com.apple.WebKit.GPU`, `QuickLookUIService`, `com.apple.appkit.xpc.openAndSavePanelService`, `com.apple.WebKit.Networking` |
| Notes | 14245 | 1 | 0 | 1 | 1 | `GroupSessionService` |
| Safari | 77761 | 1 | 0 | 1 | 1 | `com.apple.WebKit.Networking` |
| Spotify | 8994 | 8 | 6 | 8 | 2 | Spotify Helper×5, Spotify Helper (Renderer)×2, SafariPlatformSupport |
| **Terminal** | 44124 | **83** | 0 (`login` is root-owned) | **97** | 7 | **node×19, zsh×16, python3.14×7, uv×7** (the agents' MCP servers) |
| TextEdit | 61366 | 0 | 0 | 0 | 0 | |
| Xcode | 59805 | 3 | 0 | 3 | 3 | GPUToolsCompatService, GPUToolsAgentService, `com.apple.dt.SKAgent` |

- **Gotcha found:** the name-based agent scan only matched one process. **Claude Code sets its process name (`p_comm`) to its version** (`2.1.296`, `2.1.295`, `2.1.289`, ...). Agent detection must use `proc_pidpath` (`~/.local/share/claude/versions/<ver>`, `~/.local/bin/claude`, `.../ClaudeCode.app/Contents/MacOS/claude`), not the name. **[H]** `ps`, `./ptymap`.

### 2.3 Coalitions (private flavor, read-only)
- `proc_pidinfo(pid, 20 /*PROC_PIDCOALITIONINFO*/, 0, &buf, 40)` → `struct proc_pidcoalitioninfo { uint64_t coalition_id[2] /*RESOURCE, JETSAM*/; uint64_t reserved1..3; }`. **[H]** XNU `bsd/sys/proc_info_private.h`.
- XNU exempts flavor 20 from the same-user check (`PROC_PIDT_SHORTBSDINFO`, `PROC_PIDUNIQIDENTIFIERINFO`, `PROC_PIDPATHINFO`, `PROC_PIDCOALITIONINFO` and `PROC_PIDPLATFORMINFO` are `NO_CHECK_SAME_USER`), so it works on root processes too: 0 failures in 592. **[H]** XNU `proc_info.c` + `./responsible`.
- For normal apps the coalition equals the responsibility group (Arc 33/33, Word 6/6, Spotify 8/8). Coalitions are **broader**: everything Terminal launched, *including a self-responsible `claude` reparented to launchd* (pid 24556), shares Terminal's coalition 121473 (97 members, including root `login`s). **[H]** `./ptymap`.
- `coalition_info_resource_usage(cid, &cru, sz)` (exported in `libsystem_kernel`) could report per-app energy, but the header is private. Treat it as optional and check it in a spike. **[L]**
- **Use:** responsibility as the primary grouping, coalition as a cross-check and fallback, `sysctl` ppid descendants as the last resort. Put all three behind a `ProcessGrouping` protocol.

### 2.4 Race-free identity (pid reuse is real here)
- **Measured pid allocation:** pid 96806 at 15:05:12, pid 1228 at 15:21:59 (after wrapping at 99,999), pid 15053 at 15:40:14. That is **about 260–770 new pids/min** with agents running, so **the pid space wraps every about 2–6 h**. A night with the lid closed will almost certainly reuse pids. **[H]** `ps -o lstart`; `PID_MAX` 99999 per XNU **[M]**.
- **Public race-free signal API** (`<libproc.h>`):
  ```c
  int proc_signal_with_audittoken(audit_token_t *audittoken, int sig);
  ```
  XNU resolves the token with `proc_ident_for_audit_token()`, which **rejects the call (ESRCH) if `token.val[7]` (pidversion) does not match**, then applies the normal `cansignal_nomac` and MACF checks. **[H]** XNU `proc_info.c` (`psignal_by_audit_token`). It compiles and links from Swift: `nm -u` shows `_proc_signal_with_audittoken` (binary never run).
- **Getting a token for a same-uid pid:** `task_name_for_pid(mach_task_self_, pid, &name)` + `task_info(name, TASK_AUDIT_TOKEN, ...)`. This worked for all 9 regular apps. `tok.val.7` equals `p_idversion` from the private `PROC_PIDUNIQIDENTIFIERINFO` (17) flavor, which also gives a 64-bit `p_uniqueid` that is never reused within a boot. **[H]** `./identity`.
- **Journal identity tuple:** `{pid, pidversion, uniqueid, pbi_start_tvsec, pbi_start_tvusec, executablePath, bundleID}` plus header `kern.bootsessionuuid` (here `4B5EADB3-AD06-410E-83BD-8CE9B4A773A4`). **[H]** `sysctl`.

### 2.5 Order of stop and continue
Freezing several processes is not atomic; there is no public "cgroup freezer". **[M]** (reasoning plus precedent; untested because signals were banned in this phase):
1. **Stop the app's main process first.** It then cannot spawn or relaunch helpers, react to helper SIGCHLD, or start hang timers against its helpers. Chromium's browser shows "Page Unresponsive" for renderers that stop answering; App Tamer saw such warnings.
2. In the same tight loop (microseconds), stop **all other members** (renderers, GPU, XPC services).
3. **Re-enumerate** the group (responsible pid == main). Stop newcomers, repeat until stable (at most about 5 rounds), then verify `kinfo_proc.kp_proc.p_stat == SSTOP` (4) for each member.
4. **Continue in reverse order (LIFO):** helpers and XPC services first, the main app last. Servers are ready before the client's backlog of overdue timers and IPC fires, which matches App Tamer's practice of controlling helpers together with the app.
5. Do the whole group within one run-loop turn. Never leave an app half-frozen for longer than milliseconds.

---

## 3. What must never be paused

### 3.1 Why the process that owns the agent's TTY is critical (verified reasoning)
- **XNU pty write path** (`bsd/kern/tty.c` `ttwrite`, `ttsetwater`; `bsd/sys/tty.h`). **[H]**
  - The slave's output queue high-water mark is `t_hiwat = roundup(clamp(lowat + ospeed/10, TTMINHIWAT, TTMAXHIWAT), CBSIZE)` with `TTMAXHIWAT = roundup(2048, CBSIZE)`.
  - When `t_outq.c_cc > hiwat`, `ttwrite` goes to `ovhiwat`:
    - **blocking fd:** it sleeps in `ttysleep(..., "ttywri", t_timeout)`. `t_timeout` is 0 unless `TIOCSDRAINWAIT` sets it, which means wait forever.
    - **non-blocking fd:** it returns `EWOULDBLOCK`.
  - The master side (`ptcread`) reads straight from `t_outq`, so there is no extra buffer.
  - **So a frozen pty-master reader stalls the agent after about 2 KB of output.**
- **Node.js** (`lib/tty.js`, `WriteStream`): `this._handle.setBlocking(true)` with the comment "local TTYs tend to be quite fast and this behavior has become expected due historical functionality on OS X". A Node-based agent (Gemini CLI, Codex npm shim, and others) therefore blocks its **whole event loop** in `write()`. Rust CLIs (Codex) use blocking stdout by default. Claude Code is a Bun-compiled native binary whose TTY write mode was not verified; assume it blocks. **[H]** for Node; **[M]** for others.
- **VS Code / Cursor / Windsurf:** ptyHost pauses the pty when the renderer has not acknowledged `HighWatermarkChars = 100000` characters, and resumes at `LowWatermarkChars = 5000`. **Freezing just the VS Code window or renderer stalls an agent in its integrated terminal after about 100 K characters**, even though ptyHost is still running. **[H]** [`src/vs/platform/terminal/common/terminal.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/platform/terminal/common/terminal.ts). The whole VS Code app group must be protected.
- **iTerm2:** pty masters are held by `iTermServer` (ppid 1) **and** passed to the iTerm2 main process, which does the reading. Freezing iTerm2 stalls agents. **[M]**
- **tmux / screen:** the tmux *server* (CLI, ppid 1, never a regular app) holds the panes' pty masters. When the outer terminal is slow or frozen, `tty_block_maybe()` discards output for that client and redraws later. tmux has paused client updates rather than pane reads since 2010 and discards since 2017. **Agents inside tmux are therefore insulated from a frozen terminal emulator**, which is worth recommending to users. **[M]** [tmux `tty.c` (OpenBSD xref)](https://src.rcs.uwaterloo.ca/xref/openbsd-src/usr.bin/tmux/tty.c).
- **SSH:**
  - *Remote agent, local terminal:* the local `ssh` client (a child of the terminal) blocks writing to the frozen terminal's pty, stops reading the socket, the channel window fills, and the remote agent blocks. **[M]**
  - *Local agent, user connected remotely:* `sshd` (root) holds the master, cannot be frozen, and is fine. **[H]**
- **Claude Code background sessions:** `claude bg-pty-host` (pid 35831) and the self-hosted `claude` (pid 24556) hold their own pty masters (`ttys001`, `ttys009`). They are CLI processes, never regular apps, and so are never candidates. **[H]** `./ptymap`.

### 3.2 Mapping agent → controlling tty → pty-master holder (verified)

Key parts of `ptymap.swift` (verified output below):
```swift
// controlling tty of ANY pid (works for root-owned `login` too):
// sysctl {CTL_KERN, KERN_PROC, KERN_PROC_ALL} -> kinfo_proc.kp_eproc.e_tdev (dev_t; -1 = none), .e_ppid
// master holders: same-uid pids, PROC_PIDLISTFDS -> PROX_FDTYPE_VNODE -> PROC_PIDFDVNODEPATHINFO
func vnodePath(_ pid: pid_t, _ fd: Int32) -> (String, UInt32)? {
    var vi = vnode_fdinfowithpath()
    let sz = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
    guard proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &vi, sz) == sz else { return nil }
    var p = vi.pvip.vip_path
    let s = withUnsafeBytes(of: &p) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    return (s, vi.pvip.vip_vi.vi_stat.vst_rdev)
}
func minor(_ d: UInt32) -> UInt32 { d & 0xffffff }
// path == "/dev/ptmx"  => this pid holds the master of pty #minor(vst_rdev)   (master rdev 0x0f0000NN)
// agent's e_tdev       => /dev/ttysNNN with minor NNN                           (slave  rdev 0x100000NN)
// devname(e_tdev, S_IFCHR) -> "ttys004"
```
Verified output (abridged):
```
2.1.295  pid 9220  tty=ttys000 masters=[44124:com.apple.Terminal] responsible=44124:com.apple.Terminal ancestors=[9179:zsh, 9178:login, 44124:com.apple.Terminal]
2.1.296  pid 76720 tty=ttys004 masters=[44124:com.apple.Terminal] responsible=44124:com.apple.Terminal
2.1.289  pid 24617 tty=ttys009 masters=[24556:claude]  (Claude's own pty host, ppid 1; still in Terminal's coalition)
2.1.296  pid 35816 tty=-       (claude daemon, no tty)  responsible=44124:com.apple.Terminal
uv (MCP) pid 96953 tty=ttys006 masters=[44124:com.apple.Terminal] (MCP servers inherit the agent's tty)
```
`stat` confirms `/dev/ptmx` is 15,8, `/dev/ttys000` is 16,0 and `/dev/ttys009` is 16,9. A full scan of about 400 same-uid processes took **0.06 s**. **[H]**

### 3.3 Smart (dynamic) protection rules, all feasible with public and read-only APIs
An app (all its members) is **Protected** if **any** of the following is true. Rules A–C are re-evaluated before freezing; rules D–F every 10–15 s while frozen.
- **A. Agent host.**
  1. An agent process or any of its descendants is *responsible to* the app (catches Terminal, VS Code and Claude.app sessions).
  2. **Or** a member holds the pty master of any agent's tty (§3.2).
  3. **Or** the app appears in the ancestor chain of any agent (`kinfo_proc` walk).
- **B. Launched by an agent.** The app's main pid has an agent in its ancestry.
  - Verified example: a Playwright Chrome. `Google Chrome` pid 1228 ← `node` 1227 ← `zsh` 1226 ← `claude` 76720 ← ... ← Terminal, started with `--headless --remote-debugging-pipe --user-data-dir=/var/folders/.../playwright_chromiumdev_profile-...`.
  - It reports bundle id `com.google.Chrome` with **activation policy `.prohibited`**.
  - **So act per pid, never per bundle id.** The user's own Chrome has the same bundle id.
  - **[H]** `ps`, `./policy`.
- **C. IPC peer.** A member has a connection to an agent tree:
  - **Unix sockets:** match `socket_fdinfo.psi.soi_proto.pri_un.unsi_conn_so` of one end with `psi.soi_so` of the other. Verified: it found agent↔MCP pairs and the Claude daemon's `/tmp/cc-daemon-501/<id>/control.sock`. **[H]**
  - **Loopback TCP:** pair `tcpsi_ini.insi_lport`/`insi_fport` on 127.0.0.1/::1. Examples: Blender MCP, a CDP port, Ollama 11434, LM Studio 1234, Postgres 5432. Implemented; **[M]** (no live example today).
  - **Pipes:** `PROC_PIDFDPIPEINFO` `pipe_handle` ↔ `pipe_peerhandle`, which covers `--remote-debugging-pipe`. **[M]**
  - **Claude in Chrome:** installed for Chrome *and* Arc. `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json` → `"path": "/Users/tomasnguyen/.claude/chrome/chrome-native-host", "type": "stdio"`. The browser spawns the native host as its child (so it is responsible to the browser), and the host talks to Claude Code, so rule C protects the browser. The host↔CLI socket path was not observed (bridge idle). **[H]** manifest / **[M]** socket.
- **D. Connect-to-frozen-listener (thaw on demand).**
  - **TCP:** if any agent-tree socket's foreign 127.0.0.1 port equals a LISTEN socket (`tcpsi_state == TSI_S_LISTEN` = 1) owned by a frozen app, thaw that app and protect it. The kernel completes `connect()` into a frozen listener's backlog, so the agent side is visible.
  - **Unix sockets:** compare the agent socket's peer path (`unsi_caddr`) with frozen listeners' `unsi_addr` where `soi_options & SO_ACCEPTCONN`.
  - Today only Spotify (TCP 57621/7768), Chromium `SingletonSocket`s (Arc, Spotify) and Terminal's agent-spawned dev servers (TCP 3123, 5252–5258, ...) listen. **Note:** `SingletonSocket` is how `open`/second-instance launches hand URLs to a running Chromium. **[H]** `./listeners`.
- **E. Automation helpers in an agent tree.** `osascript`, `shortcuts`, `open`, `xcrun mcpbridge`/`mcpbridge` (Xcode MCP over XPC), `simctl`/`xcodebuild` (→ Simulator) target apps over Apple Events or XPC, which cannot be seen in fds. Thaw the likely target (Xcode for `mcpbridge`, the default browser for `open <url>`), or thaw all frozen apps if unknown. **[M]**
- **F. Audio.** `kAudioProcessPropertyIsRunningOutput` or `...Input` on any member, for example a call or music. Configurable. **[H]**
- **G. Downloads.** A member holds an fd whose vnode path ends in `.crdownload` (Chromium), `.part` (Firefox) or is inside a `*.download` bundle (Safari). Use Throttle instead of Freeze. **[M]**
- **H. Traced.** `PROC_FLAG_TRACED` in `pbi_flags` (debugger attached). **[H]** header / forum 127650.
- **I. Has a controlling tty.** A member with `e_tdev != -1` is a CLI job and must never be signalled. **[H]**
- **J. Not a regular app.** Only `NSRunningApplication.activationPolicy == .regular` is a candidate. Here that means 9 regular apps; the 42 `.accessory` (menu-bar utilities, input methods, agents) and 39 `.prohibited` are never candidates. **[H]** `./policy`.
- **K. Launched after the freeze began, or `isFinishedLaunching == false`.** Leave these alone; they are likely agent- or remote-user-initiated.
- **L. Busy at lid close.** Sustained > about 20 % of one core over the 2 min before freezing (render, export, compile): Throttle instead, and tell the user on their phone.

### 3.4 Static default never-pause list (bundle IDs)
Bundle IDs marked ✓ were read from this Mac's `Info.plist` files. The rest are **[M]** from general knowledge or **[L]** where marked "verify".

| Category | Bundle IDs |
|---|---|
| Lidless itself + guard | `<your.lidless.bundle.id>`, guard helper (not an app) |
| Terminals (agent hosts) | `com.apple.Terminal` ✓, `com.googlecode.iterm2`, `com.mitchellh.ghostty`, `com.github.wez.wezterm`, `org.alacritty`, `net.kovidgoyal.kitty`, `dev.warp.Warp-Stable`, `co.zeit.hyper`, `org.tabby` (verify) |
| IDEs / editors (agent hosts) | `com.microsoft.VSCode` ✓, `com.microsoft.VSCodeInsiders`, `com.vscodium`, `com.todesktop.230313mzl4w4u92` (Cursor), `com.exafunction.windsurf` (verify), `dev.zed.Zed`, `dev.zed.Zed-Preview`, prefix `com.jetbrains.`, `com.google.android.studio`, `com.apple.dt.Xcode` ✓ (Xcode 26 agents + `mcpbridge`), `com.sublimetext.4`, `com.panic.Nova` |
| AI desktop apps (agent hosts) | `com.anthropic.claudefordesktop` ✓, `com.openai.chat` (ChatGPT), Codex desktop (verify id) |
| Dev infrastructure / VMs | `com.apple.iphonesimulator`, `com.docker.docker`, `dev.kdrag0n.MacVirt` (OrbStack), `io.podman_desktop.PodmanDesktop`, `com.utmapp.UTM`, `com.parallels.desktop.console`, `com.vmware.fusion`, `com.postgresapp.Postgres2`, `com.tinyapp.DBngin`, `de.appsolute.MAMP`, `de.beyondco.herd` (verify) |
| Local LLM servers | `com.electron.ollama` (Ollama), `ai.elementlabs.lmstudio` |
| Network / VPN | `io.tailscale.ipn.macos`, `io.tailscale.ipn.macsys`, `com.cloudflare.1dot1dot1dot1.macos` (WARP), `com.wireguard.macos`, `net.mullvad.vpn`, `ch.protonvpn.mac`, `at.obdev.littlesnitch` (UI) |
| Password managers / SSH agents | `com.1password.1password` (its SSH agent socket is `~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock`, [1Password docs](https://www.1password.dev/ssh/agent/compatibility)), `com.agilebits.onepassword7`, `com.bitwarden.desktop`, `com.maxgoedjen.Secretive.Host`, `org.keepassxc.keepassxc`. A frozen SSH-agent app makes `git push`/`ssh` hang. |
| Security / MDM | `com.microsoft.wdav`, `com.microsoft.wdav.shim` ✓ (LSUIElement), any EDR UI |
| Remote access (user may check in) | `com.apple.ScreenSharing`, `com.teamviewer.TeamViewer`, `com.philandro.anydesk`, `com.p5sys.jump.mac.viewer` |
| macOS system UI and tools | `com.apple.finder` ✓ (App Tamer guidance), `com.apple.systempreferences`, `com.apple.ActivityMonitor`, `com.apple.Console`, `com.apple.ScriptEditor2`, `com.apple.shortcuts`, `com.apple.Automator`, `com.apple.DiskUtility`, `com.apple.installer`, `com.apple.MigrateAssistant`, `com.apple.keychainaccess` |
| Input / accessibility / window and display utilities (usually `.accessory` already) | `pro.betterdisplay.BetterDisplay` ✓, `com.MrKai77.Loop` ✓, `com.logitech.Logi-Options` ✓, `com.logi.optionsplus`, `org.pqrs.Karabiner-Elements.Settings`, `com.hegenberg.BetterTouchTool`, `com.raycast.macos`, `com.runningwithcrayons.Alfred`, `org.hammerspoon.Hammerspoon`, `com.stairways.keyboardmaestro.engine`, `com.knollsoft.Rectangle`, `com.if.Amphetamine` |

---

## 4. Crash safety and lifecycle

### 4.1 Write-ahead journal
`~/Library/Application Support/Lidless/paused.json`. Write it **before** each signal or `setpriority` call, using atomic write (temp file + `rename`) and `fcntl(F_FULLFSYNC)`:
```json
{
  "schema": 1,
  "bootSessionUUID": "4B5EADB3-AD06-410E-83BD-8CE9B4A773A4",
  "lidlessPid": 4242,
  "startedAt": "2026-10-12T23:10:04Z",
  "apps": [
    { "bundleID": "company.thebrowser.Browser", "appPid": 92564, "mode": "throttle",
      "members": [ { "pid": 92564, "pidVersion": 2146524, "uniqueID": 1234567, "startSec": 1790774478, "startUsec": 221234,
                     "path": "/Applications/Arc.app/Contents/MacOS/Arc", "action": "darwinbg" } ] },
    { "bundleID": "com.microsoft.Word", "appPid": 98152, "mode": "freeze",
      "members": [ { "pid": 98152, "pidVersion": 3727695, "uniqueID": 2345678, "startSec": 1791810785, "startUsec": 379262,
                     "path": "/Applications/Microsoft Word.app/Contents/MacOS/Microsoft Word", "action": "sigstop" } ] }
  ]
}
```
**Thaw a record** only if all of these hold, then call `proc_signal_with_audittoken(&tok, SIGCONT)` (or `setpriority(PRIO_DARWIN_PROCESS, pid, 0)`):
- the boot session UUID matches;
- the start time matches;
- the uniqueid matches (flavor 17);
- a freshly obtained audit token has `val.7 == pidVersion`.

Otherwise drop the record. Identifying by start time alone defeats pid reuse; the audit token closes the remaining race.

### 4.2 Defense in depth
1. **In-process.**
   - `applicationShouldTerminate` / `applicationWillTerminate` → thaw all.
   - `DispatchSource.makeSignalSource` for `SIGTERM`, `SIGINT`, `SIGHUP`, `SIGQUIT` → thaw, then exit.
   - For crash signals (`SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGABRT`, `SIGTRAP`, `SIGFPE`), a `sigaction` handler that walks a **preallocated C array** of pids and calls `kill(pid, SIGCONT)`. `kill` is async-signal-safe; do no allocation, no Swift runtime and no locks. Pid reuse in the instant of a crash is negligible, and `SIGCONT` to a running process is harmless.
   - [M] (standard POSIX practice; untested here.)
2. **Out-of-process guard** (covers `SIGKILL`, Force Quit, a hang, or Lidless itself being SIGSTOP'd).
   - A tiny helper `Lidless.app/Contents/MacOS/lidless-guard`, spawned with `posix_spawn` + `POSIX_SPAWN_SETSID`.
   - It watches Lidless with `kqueue` `EVFILT_PROC`/`NOTE_EXIT` **and** an inherited pipe (EOF = parent gone) **and** a heartbeat: if Lidless stops heart-beating for more than 30 s while it is not asleep, assume a hang.
   - On trigger it reads the journal, thaws, and exits.
   - [M]
3. **Launch recovery.** On every Lidless start, and from a login-time LaunchAgent, read the journal and thaw.
   - Optionally (like App Tamer 2.8.4) offer "Resume all stopped apps", which lists processes with `p_stat == SSTOP` that are responsible to a regular app, have no tty and are not traced.
   - **Do not** blindly `SIGCONT` every stopped process: that would resume users' `^Z` jobs and debuggee processes.
   - None were stopped at measurement time. **[H]** `./identity`.
   - LaunchAgent: `~/Library/LaunchAgents/<id>.guard.plist` with `ProgramArguments=[".../lidless-guard","--recover"]` and `RunAtLoad=true`.
     - Register it with `SMAppService.agent(plistName:)` (macOS 13+) if ad-hoc signing allows. **(unknown; verify)**
     - Otherwise copy the plist and `launchctl bootstrap gui/$UID <plist>`. Background Task Management will show a "Background item added" notice either way. **[M]**
4. **Thaw triggers** (any one is enough):
   - lid opens (IOKit `AppleClamshellState` → false);
   - `NSWorkspace.didWakeNotification` / `screensDidWakeNotification`;
   - **before** sleep (`willSleepNotification`, `kIOMessageSystemWillSleep`) and **before** Lidless-initiated sleep or shutdown;
   - `NSWorkspace.willPowerOffNotification` (logout, restart, shutdown);
   - `sessionDidResignActiveNotification`;
   - an external display is connected (`CGDisplayRegisterReconfigurationCallback`);
   - user input (`CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)` < 5 s, which also catches remote control);
   - no agent busy (prelude to sleep);
   - Lidless quits or the user turns it off;
   - a hard cap, for example 12 h frozen.
5. **Ordering before power actions.** Thaw, wait about 3–5 s so apps can process their backlog and reconnect, then sleep or shut down.
   - Prefer **sleep** to shutdown. Shutdown goes through loginwindow's 45 s quit dance, and any app with unsaved changes cancels it.
   - Frozen apps would otherwise (a) block logout or shutdown and (b) delay sleep by 30 s if they registered for power notifications.

---

## 5. Recommendations for Lidless

1. **When to pause.** Only when **all** of these hold:
   - the lid is closed;
   - no external display is connected and there is no recent user input;
   - at least one agent is *working* (see the agent-detection report);
   - a **settle delay** (default 90 s) has passed.
   
   Otherwise keep everything running. If no agent is working, thaw and then sleep; do not pause.
2. **Candidates.** `NSWorkspace.shared.runningApplications` that meet all of:
   - `activationPolicy == .regular`;
   - `isFinishedLaunching`;
   - launched before the pause started;
   - not in the static never-list (§3.4) or the user's list;
   - not matched by the dynamic rules A–L (§3.3).
   
   **Key every decision by pid (plus audit token), never by bundle id.**
3. **Group membership.** `members = {main} ∪ {p : uid(p) == getuid() && responsible(p) == main}`, using `responsibility_get_pid_responsible_for_pid` via `dlsym`. Fallback order: coalition id (flavor 20), then `sysctl` ppid descendants. If **any** member is an agent, a tty holder or IPC-connected (rules A, C, I), the **whole app is protected**.
4. **Default modes by category** (user-overridable; the first match wins):

   | Category | Default | Why |
   |---|---|---|
   | Never-list / dynamic-protected | **None** | Correctness of the agent |
   | Browsers (Arc, Chrome, Safari, Firefox, Edge, Brave) | **Throttle** (DARWIN_BG) | Agents drive them (Claude in Chrome, CDP); downloads; App Tamer slows browsers rather than stopping them because of hang warnings |
   | Chat, mail, meetings (Slack `com.tinyspeck.slackmacgap` ✓, Discord `com.hnc.Discord` ✓, Teams `com.microsoft.teams2` ✓, Outlook ✓, Mail, Messages, WhatsApp ✓, Zoom `us.zoom.xos` ✓) | **Throttle** (None if audio is active) | Keeps sessions alive; App Tamer: "slow, don't stop" for apps receiving internet data |
   | Media players (Spotify ✓, Music, TV, Podcasts, VLC, IINA) | **Freeze** when silent, None when playing | Rule F |
   | Documents and productivity (Word ✓, Excel ✓, PowerPoint ✓, Pages ✓, Numbers ✓, Keynote ✓, Notes, TextEdit, Preview, OneNote ✓, Goodnotes ✓) | **Freeze** | App Tamer stops Word and Preview by default |
   | Creative and pro (Final Cut ✓, Logic ✓, FL Studio ✓, CapCut ✓, Pixelmator ✓, Motion ✓, Compressor ✓, Blender ✓, GarageBand ✓) | **Freeze if idle at lid close, otherwise Throttle** | Exports and renders (rule L); Blender may be MCP-driven (rule C) |
   | Games and launchers (Steam ✓, League/Riot ✓, Minecraft ✓) | **Freeze** | Pure waste while away |
   | Anything else regular | **Freeze** | User's stated goal |
   | Quit | **Opt-in only**, and only if `proc_get_dirty` is TRACKED and not DIRTY, **and** memory pressure is warn or critical (`DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])` or `sysctl kern.memorystatus_vm_pressure_level` ≥ 2; it is 1 now) | Only mode that frees RAM; avoids save dialogs |

5. **Freeze algorithm** (pseudo-code; *untested*, since signals were not allowed in this phase):
   ```swift
   func freeze(_ app: AppGroup) throws {
       var members = app.snapshotMembers()               // main first, then helpers
       try journal.append(app, members, action: .sigstop) // write-ahead + F_FULLFSYNC
       for round in 0..<5 {
           for m in members where !m.isStopped { _ = m.signal(SIGSTOP) } // proc_signal_with_audittoken
           let fresh = app.snapshotMembers().filter { !members.contains($0) }
           if fresh.isEmpty { break }
           try journal.append(app, fresh, action: .sigstop); members += fresh
       }
       guard members.allSatisfy({ $0.pStat == SSTOP || !$0.isAlive }) else { thaw(app); throw PauseError.partial }
   }
   func thaw(_ app: AppGroup) {                           // LIFO: helpers first, main last
       for m in app.journalMembers.reversed() where m.identityStillMatches { _ = m.signal(SIGCONT) }
       journal.remove(app)
   }
   ```
   Throttle uses the same journal with `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)`. Re-scan every 30 s to throttle newly spawned helpers (they inherit, but XPC services launched by launchd do not). Undo with `setpriority(..., 0)`.
6. **Thaw-on-demand monitor** while paused, every 10–15 s (each scan takes about 60 ms):
   - rules C and D (sockets), E (automation helpers), F (audio), and new agents appearing;
   - any match thaws that app and marks it protected for the rest of the session.
7. **Optional "breathing"** for Freeze mode, the App Tamer pattern: thaw each frozen app for about 5 s every 10 min so heartbeats and syncs happen. Off by default if chat apps use Throttle.
8. **Crash safety** as in §4: journal, in-process handlers, guard helper, recovery at launch and login, audit-token identity, and thaw before sleep, power-off and logout.
9. **Transparency.**
   - Show the paused apps with their mode in the menu bar, plus a one-click "Resume all".
   - Send the phone a summary, for example "Paused 6 apps (Word, Spotify, Steam …), throttled Arc, Slack; protected Terminal (2 agents)".
   - Log every decision with `os_log` (subsystem `…lidless`, category `pause`).
10. **Set expectations in the UI.** "Pausing saves CPU and battery; it does **not** free memory unless you choose 'Quit when memory is low'."
11. **Phase-1 spike tests** to run on a *test* app before shipping, since they were not runnable in this read-only phase:
    - TextEdit / Notes / Word: freeze 10 min, check the beachball and that recovery is clean.
    - Chrome and Arc with a YouTube tab: freeze, resume, check for a hang dialog.
    - Slack and Discord: freeze 15 min, check that they reconnect and how long it takes.
    - Spotify playing: check that rule F protects it.
    - `setpriority` on another pid: `getpriority` returns 1 and child helpers inherit it.
    - Kill Lidless with `kill -9` and confirm the guard thaws.
    - Logout while frozen, to reproduce the "failed to quit" path.
    - Sleep while frozen, to measure the 30 s delay.
    - A VS Code integrated-terminal agent with VS Code *not* frozen (sanity check).
    - Write 3 KB to a pty whose master holder is a frozen test app, to confirm the stall.

---

## 6. Risks and unknowns

1. **Private APIs** (`responsibility_*`, flavor 20 coalition, flavor 17 uniqueid) are undocumented and could change, notably in **macOS 27**, which shipped 2026-09-14 and is not yet on this Mac. Mitigate with the coalition then ppid fallbacks and a startup self-test. **[M]**
2. **Agent dependencies that cannot be detected.** Mach, XPC and Apple-Event IPC (`osascript`, `open`, Xcode `mcpbridge`, Shortcuts) and NSFileCoordinator or pasteboard waits on a frozen app can stall an agent tool call. Lidless might then wrongly think the agent is still "working" and never sleep. Mitigations: rules E and D, generous protection, a per-agent "never pause anything" switch, and a watchdog that thaws all if an agent's CPU time has not advanced for N minutes while its status says busy. **[M]**
3. **App-specific recovery after a long freeze** is unmeasured. Browser "page unresponsive" dialogs, Electron reconnect storms, apps that rely on `didWake` to refresh, iCloud document presenters, and a SQLite write lock held at freeze time are all possible. App Tamer's 15 years of shipping SIGSTOP suggests these problems are rare but real. **[M]**
4. **Energy savings are modest** (about 71 mW measured, lid open) unless something is misbehaving. **RAM is not freed by Freeze.** Users may expect more. **[H]**
5. **Pid reuse** is frequent on agent-heavy machines (wrap every 2–6 h). Any code path that signals by raw pid without the audit-token check can stop an unrelated process. **[H]**
6. **Ad-hoc signing:** whether `SMAppService.agent` registration works with ad-hoc signatures is **unknown**. `launchctl bootstrap` works, but BTM notifications appear. No Developer ID is required for the signals or `setpriority` themselves. **[M]**
7. **Conflicts with other tools.**
   - App Tamer 2.8.4 resumes processes stopped by others when it launches.
   - Debuggers: LLDB stops on SIGCONT.
   - Other freezers (App Freezer, bgviewer).
   
   Detect App Tamer (`com.stclairsoft.AppTamer`) and warn. **[M]**
8. **Job control and CLI processes.** Signalling anything with a controlling tty breaks shells' job control. The design excludes them, but a bug here could freeze the agent itself. **[H]**
9. **Logout, shutdown and sleep with frozen apps.** A Lidless crash during sleep, with the guard also dead (for example on a reboot), is harmless because the processes are gone. A crash with the guard alive is handled. Both dead and the system awake leaves apps frozen until the next login recovery. **[M]**
10. **Bundle-ID collisions.** Agent-launched headless Chrome (`.prohibited`) shares `com.google.Chrome` with the user's Chrome. Every rule must work per pid. **[H]**
11. **Claude Code specifics.**
    - `p_comm` is the version string.
    - Background sessions own their ptys (`claude bg-pty-host`).
    - The Claude daemon and its sessions are responsible to Terminal even after reparenting.
    
    Any naive rule keyed on names or ppid misses them. **[H]**
12. **Not tested in this phase:** sending `SIGSTOP`/`SIGCONT`, `setpriority` and `terminate` against other processes. The rules forbade it. All claims about runtime behaviour come from XNU source, vendor docs and precedent.

---

## 7. Sources
- XNU (apple-oss-distributions/xnu, `main`, fetched 2026-10-12):
  - `bsd/kern/kern_sig.c`, `bsd/sys/signalvar.h`
  - `bsd/kern/kern_proc.c` (`pid_suspend`, `task_for_pid_posix_check`)
  - `bsd/kern/kern_resource.c` (`do_background_proc`, `proc_set_darwin_role`, runaway/game mode)
  - `osfmk/kern/task_policy.c`
  - `bsd/kern/tty.c`, `bsd/sys/tty.h`
  - `bsd/kern/proc_info.c` (`psignal_by_audit_token`, same-user exemptions)
  - `bsd/sys/proc_info.h`, `bsd/sys/proc_info_private.h`, `bsd/sys/coalition.h`
  - <https://github.com/apple-oss-distributions/xnu>
- macOS 26 SDK (Xcode 26.6): `usr/include/libproc.h`, `sys/proc_info.h`, `sys/resource.h`, `usr/lib/system/libquarantine.tbd`, `AppKit/NSRunningApplication.h`, `CoreAudio/AudioHardware.h`.
- App Tamer: <https://www.stclairsoft.com/AppTamer/>, [FAQ](https://www.stclairsoft.com/AppTamer/faq.html), [Managing apps](https://www.stclairsoft.com/AppTamer/help/pages/managing.html), [Preferences](https://www.stclairsoft.com/AppTamer/help/pages/preferences.html), [Release notes](https://stclairsoft.com/AppTamer/release_notes.html), [sspai review (2026)](https://sspai.com/prime/story/manage-macos-background-activities-with-app-tamer), [Apple forum 127650](https://developer.apple.com/forums/thread/127650).
- Other tools: [ForceNap](https://gitblind.noratr.app/omikun/ForceNap), [App Freezer (Raycast, Aug 2026)](https://www.raycast.com/changxu_song/appfreezer).
- Responsibility API: [Qt blog 2022-02-04](https://www.qt.io/blog/the-curious-case-of-the-responsible-process), [Chromium process_info_mac.mm](https://chromium.googlesource.com/chromium/src/+/606f178bd02294de6187be5c0f4e2dcd86058dfa/base/process/process_info_mac.mm).
- Terminal and agent I/O: [Node `lib/tty.js`](https://github.com/nodejs/node/blob/main/lib/tty.js), [VS Code `terminal.ts` FlowControlConstants](https://github.com/microsoft/vscode/blob/main/src/vs/platform/terminal/common/terminal.ts), [tmux `tty.c`](https://src.rcs.uwaterloo.ca/xref/openbsd-src/usr.bin/tmux/tty.c).
- Apple:
  - [App Nap (Energy Efficiency Guide)](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html)
  - [QA1340 sleep notifications](https://developer.apple.com/library/archive/qa/qa1340/_index.html)
  - TN2408 (quoted at [mjtsai 2014-11-21](https://mjtsai.com/blog/2014/11/21/))
- Eclectic Light: [loginwindow (2023)](https://eclecticlight.co/2023/03/18/loginwindow-does-more-than-log-you-in/), [RunningBoard 1 (2025)](https://eclecticlight.co/2025/07/10/what-does-runningboard-do-1-app-launching/), [RunningBoard 4 (2025)](https://eclecticlight.co/2025/07/31/what-does-runningboard-do-4-assertions/).
- 1Password SSH agent: <https://www.1password.dev/ssh/agent/compatibility>.
- Wait cursor: <https://en.wikipedia.org/wiki/Spinning_pinwheel>.
- macOS 27 release: <https://www.macrumors.com/2026/09/10/macos-27-golden-gate-release-date/>.
- Local verification (2026-10-12, macOS 26.6.2 25G83, M1 Pro 16 GB):
  - `./responsible`, `./ptymap`, `./footprint`, `./identity`, `./listeners`, `./audio`, `./policy`
  - `swiftc -typecheck`/link check of `compilecheck.swift` (never run)
  - `ps -axo`, `stat -f %Hr/%Lr /dev/ptmx /dev/ttys*`, `vm_stat`, `sysctl vm.swapusage kern.memorystatus_vm_pressure_level kern.bootsessionuuid`, `pmset -g assertions` (read-only), `PlistBuddy -c Print` on `/Applications/*.app/Contents/Info.plist`
