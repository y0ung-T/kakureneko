# Kakureneko — backlog

Open items from the pre-release audit (2026-10-18). Each one says what is wrong, what is needed to do it, and the
exact steps. Tick an item off by deleting it once it's done.

## Before release

### 1. TestFlight beta (release blocker)

Needs: App Store Connect.

1. App Store Connect → Apps → + → New App (iOS, bundle id `com.kakureneko.Kakureneko`), if it doesn't exist yet.
2. `scripts/build-phone.sh upload`, then TestFlight → Test Information: beta description, feedback email, privacy
   policy URL `https://github.com/y0ung-T/kakureneko/blob/main/PRIVACY.md`.
3. An external group for friends with the build (Beta App Review), then email invites or a public link.
4. With a public link: put it in the README's iPhone section, and in `IPHONE_APP_URL` for the next Mac build.

## Needs a device

### 2. Fail-safe sleeps a clamshell desk Mac after a crash

What: with the lid closed on an external display (desk mode) and Kakureneko armed, a crash, `kill -9` or a hang over
150 s makes the root fail-safe clear the flag and run `pmset sleepnow`: the desk Mac sleeps within ~3.5 min and the
agent run stops. Same check in the detached sleep script.

Needs: a MacBook on power, an external display, the admin install (full mode), an agent running (armed).

1. Close the lid, keep working on the external display. Note:
   `ioreg -r -n IOPMrootDomain -d 1 | grep -E 'SleepDisabled|AppleClamshellState|AppleClamshellCausesSleep'`
2. In Terminal: `log stream --predicate 'eventMessage CONTAINS "restoring sleep"'`
3. `killall -9 Kakureneko`. Within ~3.5 min: "restoring sleep" in the log and the Mac sleeps (confirms the bug).
4. Wake it; lid still closed, display connected: `sudo pmset -a disablesleep 0`, then the `ioreg` line again.
   **The value that decides the fix: `AppleClamshellCausesSleep`.** `No` with the display connected = the fix is safe.
5. Bag case (must keep working): lid closed, NO display, armed; `killall -9 Kakureneko` over Screen Sharing / SSH →
   the Mac must sleep within ~3.5 min.
6. Fix (only if step 4 read `No`): in `Sources/KakurenekoPower/PrivilegedScripts.swift` change
   `[ "$(rd AppleClamshellState)" = "Yes" ] && $PMSET sleepnow` to also require
   `[ "$(rd AppleClamshellCausesSleep)" = "Yes" ]`; same in the detached sleep script in `RealSideEffects.swift`;
   update `failsafeTemplateKeepsR01Behaviour`. The app sees the installed fail-safe is out of date and asks for one
   admin prompt to repair it. Then repeat steps 3 (desk Mac stays awake) and 5 (bag Mac sleeps).
   Note: the fail-safe's own heat and 25 h limits (item below) also sleep a desk Mac; with this fix they still restore
   sleep but only a Mac whose lid closing causes sleep is put to sleep.

### 3. Verify the fail-safe's heat and time limits on the device

Done in code (2026-10-19): with the lid closed, the root fail-safe restores sleep at thermal pressure trapping (3)
or worse, heavy (2) for over 15 min, or 25 h with sleep disabled (`safetyLimits`, `safetyVerdict`; clocks in
`/var/run/kakureneko-{closed,hot}-since`, cleared at boot and on uninstall). `notifyutil -g
com.apple.system.thermalpressurelevel` reads `0` on the development MacBook Pro, so the level is readable.

1. After updating the app, accept the admin prompt that repairs the fail-safe (its script changed).
2. Lid closed, armed: `sudo ls -l /var/run/kakureneko-closed-since` exists within a minute; open the lid → it is
   gone within a minute.
3. Time limit, quick: in a development build set `MAX_CLOSED` to `120` (in `safetyLimits`), repair the install,
   close the lid armed, and watch `log stream --predicate 'eventMessage CONTAINS "restoring sleep"'`: "lid closed
   for 0h" after ~3 min and the Mac sleeps. Put `25 * 3600` back and repair again.
4. Repeat item 2's bag case (step 5) to make sure the normal crash path still sleeps the Mac.

### 4. One Mac's alerts may show as banners on another Mac

What: both Macs use bundle id `com.kakureneko.Kakureneko`, so the iPhone's `alerts-v1` CloudKit subscription
probably pushes every alert to every Mac too. Suppression is only in `willPresent` (called while the app is
frontmost, which a menu-bar app almost never is); removal runs on the push callback and the 60 s tick. Every push
also triggers a fetch plus two burst fetches.

Needs: two Macs on the same Apple Account, Kakureneko on both, "Send alerts to your iPhone" on, an iPhone set up.

1. On Mac A: Settings → Notifications → Send them: **Always**. Let an agent finish (or ask a question) on Mac A.
2. Watch Mac B: a banner, or Mac A's alert in Mac B's Notification Center, confirms it.
3. On one Mac alone: one finished agent should give ONE notification there, not the Mac's own plus an iCloud copy.
4. Fix if either shows up, in `Sources/KakurenekoNotify/NotificationDispatcher.swift`: about 1 s after each
   CloudKit push, run the removal of other Macs' alerts (`removeRemoteAlerts`); decode `CKNotification`'s
   `subscriptionID` and do the burst fetches only for the command and iPhone subscriptions.
