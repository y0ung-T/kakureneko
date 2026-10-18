# Native notifications: Mac + iPhone over iCloud

Status: Mac side implemented and tested (2026-10-17); iPhone app in `iPhone/` (Xcode/project.yml). Replaces ntfy
entirely (D4 superseded, see DECISIONS.md D11).

## 1. Decisions (user, 2026-10-17)

| # | Decision |
|---|---|
| N1 | Notifications are native: macOS notifications from Kakureneko itself + a Kakureneko app for iPhone. No third-party app or server. ntfy is removed entirely. |
| N2 | Every alert shows on the Mac; the iPhone gets it at the same time when its timing allows — by default only with the lid closed (2026-10-17: the user at the Mac doesn't need the phone buzzing too; "When I'm away" and "Always" are the other choices). Settings → Notifications groups everything by scope: This Mac, iPhone, Mac & iPhone. |
| N3 | Transport: CloudKit (container `iCloud.com.kakureneko.Kakureneko`, team 7NRW73MYQZ), PUBLIC database with creator-only permissions (D12: the private database counts against the user's iCloud storage, which can be full). Same Apple Account on both devices = connected; there is no pairing step. |
| N4 | The iPhone app is built for other people too (TestFlight / App Store quality); the Mac app ships with Developer ID later. |
| N5 | Live Activity / Dynamic Island card: phase 2 (needs an APNs key; not in this round). |
| N6 | Identifier prefix `com.kakureneko`; Xcode registers identifiers automatically. |

## 2. Architecture

```
 Mac (Kakureneko.app, SwiftPM)                            iPhone (Kakureneko for iPhone, Xcode)
 ┌──────────────────────────────────────┐               ┌───────────────────────────────────────┐
 │ Coordinator ─ NotificationIntent ─▶  │               │ Notification Service Extension         │
 │ KakurenekoNotify                       │               │  (alerts-v1 push, mutable-content)     │
 │  Templates → Policy → Outbox         │   CloudKit    │  → AlertPresentation.content(…)        │
 │   ├─ MacNotifier (UNUserNotification)│  public DB    │                                       │
 │   └─ CloudRelay ── save Alert ───────┼──────────────▶│ App: Macs, agents, countdown, buttons  │
 │        ▲  save MacStatus ────────────┼──────────────▶│  status via silent push + poll        │
 │        └── fetch Command ◀───────────┼───────────────┤ button tap → save Command              │
 │            (silent push + polling)   │               │ save PhoneDevice                       │
 └──────────────────────────────────────┘               └───────────────────────────────────────┘
```

* Shared code: SwiftPM library **KakurenekoCloud** (`Sources/KakurenekoCloud`, builds for macOS + iOS, no dependencies).
  It owns the schema, record coding, the `CloudStore` protocol (live `CloudKitStore`, fake `InMemoryCloudStore`),
  command validation and `AlertPresentation` (notification content, categories, buttons, tap decoding). Both apps
  use it so an alert looks the same everywhere and buttons decode the same way.
* CloudKit never delivers a subscription push to the device that made the change (Apple QA1917), so the Mac does
  not get its own alerts back, and the iPhone does not hear its own commands.
* Both apps share the bundle id `com.kakureneko.Kakureneko` (one App ID, two platforms). A second Mac WOULD receive
  the first Mac's alert pushes; the Mac app suppresses remote alert presentation in `willPresent`.

## 3. CloudKit schema (public database, default zone, creator-only)

Schema file: `Xcode/CloudKit/schema.ckdb` (`scripts/cloudkit-schema.sh validate|import|export`, needs a CloudKit
management token saved with `xcrun cktool save-token --type management`; KakurenekoCloudTests keeps it in sync with the
code). Every Kakureneko type grants READ + WRITE to `_creator` and CREATE to `_icloud` — no `_world` read — so only the
Apple Account that saved a record can read it, and CloudKit filters every query on the creator (hence the
`___createdBy` index). Indexed: `owner` (QUERYABLE), `___modTime` (QUERYABLE SORTABLE), `___createdBy`, `___recordID`.
Every record carries `owner` = the user's record name (`CKContainer.userRecordID()`, the same on all devices of the
Apple Account); queries and subscriptions filter on it, and a record is trusted only when its server-set creator is
the current user (`CloudKitStore.isTrusted`).

All timestamps are Int64 Unix seconds, booleans Int64 0/1, `schema` = 1 on every record. Every record writes EVERY
field of its type: an absent optional is written as its sentinel (`CloudSchema.Absent`: `""` for text, `Int64.min` for
numbers / timestamps / booleans, `[""]` for an empty list). A CloudKit save only modifies the keys it carries, so an
omitted key would keep its old server value (a cancelled countdown would stay on the phone); writing every field also
means the development schema is complete after the first save of each type.
Record names: `alert-<uuid>`, `command-<uuid>`, `mac-<macID>`, `phone-<deviceID>`.

| Record type | Writer | Fields |
|---|---|---|
| `Alert` | its Mac, once | macID, macName, kind, title (≤120), body (≤600), threadID, replaceKey?, interruption (passive/active/timeSensitive), actions [String] (`keepawake:<s>`, `sleep`, `shutdown`; absent = none), sv, createdAt, expiresAt |
| `Command` | a phone, once; deleted by the Mac after handling | macID, request (`keepawake:<s>`, `sleep`, `shutdown`, `test`, `refresh`), sv?, alertID?, createdAt (= issuedAt), expiresAt, deviceID, deviceName |
| `MacStatus` | its Mac, updated in place | macID, macName, model?, phase, headline, detail?, countdownEndsAt?, keepAwakeUntil?, agentsJSON, batteryPercent?, onBattery, lidClosed, sv, keepAwakeSeconds, shutdownEnabled, canSleep, updatedAt, appVersion |
| `PhoneDevice` | its phone, updated in place | deviceID, name, model, systemVersion, appVersion, alertsAuthorized, timeSensitiveAllowed?, lastSeenAt |

Subscriptions (query subscriptions — the public database has no zone or database subscriptions — each with
`owner == me`):

* `alerts-v1` — `Alert` created → visible push with `mutable-content` and the title / body as `%1$@` localization
  arguments; NO `desiredKeys` (public-database subscriptions accept only ~5; the extension fetches the alert by the
  push's record id). Created by the iPhone app.
* `mac-commands-v1` (`Command` created) and `mac-devices-v1` (`PhoneDevice` created / updated) — silent. Created by
  the Mac.
* `phone-statuses-v1` (`MacStatus` created / updated) — silent. Created by the iPhone app.

Development schema: created on first save (complete, see above). `CloudStore.ensureSubscription` bootstraps a
container where the subscription's record type does not exist yet by saving and deleting one placeholder of every
type (`CloudSchemaBootstrap`; the iPhone's extension shows a placeholder alert as empty, silent content). Production: deploy the
development schema in the CloudKit Console ("Deploy Schema Changes") before the first TestFlight build.

Changes are read with queries (the public database has no change tokens): each record type, `owner == me AND
modificationDate > watermark − 120 s`, sorted by modification date; the watermark is the newest modification date
seen. The overlap absorbs the query index lag (measured ≈ 2 s) and re-delivers recent records (consumers are
idempotent). Each side reads only what it uses: the Mac `Command` changes, the iPhone `Alert` changes.

Deletions are never reported, so the record lifecycle is built around that (2026-10-18 audit):
* **Read whole, replace the copy.** The small types are fetched in full every round (`CloudStore.fetchAll`): the
  Mac's iPhone list and the iPhone's Mac list are replaced by them, so a deleted Mac or iPhone disappears within one
  round. The iPhone tells "the Mac took my command" by the command leaving iCloud (once past the index lag).
* **Prune by server age, not by a local list** (`CloudStore.deleteOwned`, every 6 h on each Mac, daily on the
  iPhone): alerts after 3.5 days, commands after 1 h, Mac statuses and iPhones after 30 days without a save, whoever
  wrote them, so records whose writer is gone (a reinstalled Mac, a deleted app) never pile up.
* **Stable identities.** The iPhone's device id lives in the Keychain (this device only): a reinstall keeps one record;
  a new iPhone restored from a backup gets its own and removes the copied id's record. The Mac's id is derived from
  the machine and user (`MachineIdentity`): wiping Application Support keeps it; a Migration Assistant copy on
  another Mac gets a different one, so one command can never reach two Macs.
* **Account scope.** MacStatus and PhoneDevice record names carry a tag of the Apple Account (public-database names
  are global), and both sides reset their account-bound state when the account tag changes (`CKAccountChanged`).
* **Remove.** The Mac lists iPhones seen in the last 14 days, each with Remove; the iPhone moves Macs silent for a week
  to "Not seen recently" with Remove, and sends them no commands. iPhone alerts off ignores iPhone commands, and
  removes this Mac's records as soon as iCloud can be reached. Requests are chunked at 200 records.

## 4. Flows

### 4.1 Alert (Mac → Mac + iPhone)
1. Coordinator submits a `NotificationIntent`; Templates + Policy work as before (batching, dedupe, reminder,
   rate limit + digest, quiet hours, Remote-Control skip). The Mac shows every alert while its notifications are
   on; the iPhone follows `phoneTiming` (below). Setting
   `minimumWorkSeconds` (default 0 = every turn): a finished / went-quiet turn that worked less is suppressed
   (`shortTurn`); unknown durations and waiting agents always alert.
2. Admission renders an `OutgoingNotification`, then:
   * **MacNotifier** posts it immediately as a local notification (`AlertPresentation.content`, request id from
     `replaceKey` so the countdown replaces itself). Needs notification permission; failures are logged, not retried.
   * **CloudRelay** enqueues it in the persistent outbox and saves it as an `Alert` record (retry with backoff on
     retryable errors, TTL `expiresAt`, coalescing by group key; `drain(deadline:)` before every Kakureneko sleep).
     **iPhone timing** (`phoneTiming`, Settings → Notifications → iPhone → "Send them"): `lidClosed` (default: "Only
     when the lid is closed"), `away` ("When I'm away from the Mac": lid closed, screen locked or no input for
     `awayIdleSeconds`) or `always`. It replaced v2's `presenceGating` (which gated the Mac too) and
     `phoneOnlyWhenLidClosed`; files without it derive it from them. While the timing holds the iPhone back the
     alert is not queued for it (presence = latest submit context, a status report updates the lid; unknown counts
     as away) — except `phoneTimingBypass`: the test, `commandIgnored` (the iPhone's tap feedback reads it),
     `shuttingDown` and safety stops. When only the iPhone could show it, the intent is suppressed (`lidOpen` /
     `present`) and a due needs-input reminder is held. A needs-input wait the Mac showed alone is owed to the
     iPhone (`WaitRecord.phoneDelivered`): the coordinator re-submits still-waiting sessions on every lid close and
     present → away transition, and the iPhone then gets its copy (the Mac does not show it again).
3. iPhone: the push wakes the Notification Service Extension, which rebuilds the content from the payload (or
   fetches the record), removes an older delivered notification with the same `replaceKey`, and shows it with the
   buttons of its category. Time Sensitive for needs-input, countdown and safety stops.

Interruption mapping: priority high/urgent → timeSensitive, default → active, low/min → passive.

### 4.2 Buttons
Categories: every combination of {Keep awake, Sleep now, Shut down} (ids `com.kakureneko.alert[.keepawake+sleep…]`),
registered on both platforms; Sleep / Shut down are destructive and require an unlocked phone.
* **Mac**: the `UNUserNotificationCenter` delegate decodes the tap (`AlertPresentation.buttonTap`) → a
  `RemoteCommand` (provider `mac`) on the dispatcher's command stream.
* **iPhone**: the app's delegate decodes the tap → saves a `Command` record (background task) → the Mac hears the
  `mac-commands-v1` silent push (or its poll), fetches, checks the creator, validates and executes.

Validation on the Mac (`CloudCommand.rejection` + dispatcher): right Mac, not expired, issued ≤ 30 min ago and not
> 5 min in the future, `sv` present for sleep / shut down, unseen command id (replay cache until expiry); the
coordinator still requires `sv == current` for sleep / shut down (otherwise a "commandIgnored" alert). The private
database is writable only by the user's own Apple Account, which replaces ntfy's HMAC signatures.

### 4.3 Status (Mac → iPhone)
The Mac saves its `MacStatus` on every meaningful change (a phase change at once, the rest debounced 5 s) and at
least every 5 min while running. Before it goes dark it reports a final status — asleep (wind-down, `willSleep`),
shut down, or off (quit) — which then stays the reported status until the Mac wakes (or the wind-down is cancelled),
so the publishes that still follow cannot turn "asleep" back into "going to sleep". Older than 12 min (and not asleep / off) = "not
responding" on the phone. `refresh` commands make the Mac republish at once (the app sends one when opened).

### 4.4 Polling (Mac)
Fetch changes on every silent push (plus two quick re-fetches 3 s apart: the query index lags behind saves), every 15 s while an actionable alert is unexpired or the app was
asked to refresh within 2 min (switching to the fast interval wakes the loop at once), otherwise every 5 min.
Exponential backoff on errors, reset only by a successful fetch; the loop never wakes itself from its own failures
(no tight loops); `zoneMissing` → prepare the zone, reset the token; `changeTokenExpired` → fetch from scratch (which
also rebuilds the phone list). Each save is bounded by a 30 s timeout that holds even if CloudKit ignores
cancellation. Alerts of another Mac that arrive as pushes are removed from this Mac's Notification Center.

## 5. iPhone app (`iPhone/`, targets in `Xcode/project.yml`)

* iOS 18+, SwiftUI, Swift 6 strict concurrency, `@Observable` models, no third-party code.
* Targets: `KakurenekoPhone` (app, bundle `com.kakureneko.Kakureneko`), `KakurenekoPhoneAlerts` (Notification Service
  Extension, `com.kakureneko.Kakureneko.alerts`), `KakurenekoPhoneTests` (unit tests on the simulator, fakes only).
* First run: welcome → allow notifications → iCloud check ("sign in with the same Apple Account as your Mac")
  → waiting for a Mac (done when a `MacStatus` appears; skippable).
* Main screen: the Mac (or a list when several): phase, headline, live countdown, keep-awake-until, battery, lid,
  last update / not responding, agents (activity, project, host, since), buttons Keep awake / Sleep now /
  Shut down (if enabled; sleep and shut down confirm first) with "sent → done / Mac didn't respond" feedback.
* Activity: recent alerts (last 3 days) grouped by day. Settings: notification + Time Sensitive status (link to
  Settings), iCloud status, "Send test alert", this iPhone, privacy policy and support links, "See a demo", version.
* Registers for remote notifications, ensures the zone and both subscriptions, saves its `PhoneDevice` record
  (on launch and when authorization changes, at most every 6 h otherwise), polls every 5 s while in the foreground.
* Privacy: records live in the app's PUBLIC CloudKit database, each readable and writable only by the Apple Account
  that created it (N3, D12). Apple hosts it, the developer can see it through Apple's CloudKit tools, and Kakureneko does
  not end-to-end encrypt it. No server of Kakureneko's own, no analytics, no tracking (the privacy manifest declares the
  UserDefaults required-reason API only). The app says "through Apple's iCloud, readable only with your Apple
  Account" and links to the privacy policy; it never claims "private iCloud" or end-to-end encryption.
* Demo: "See a demo" (onboarding's last step, Settings) shows the app on a sample Mac, entirely on fakes, for App
  Review and people without the Mac app (docs/IPHONE-APP.md, "Demo").

## 6. Mac app changes

* KakurenekoNotify: ntfy provider, command stream, HMAC codec, pairing and secrets removed; new `MacNotifier`
  (protocol + live `UserNotificationCenter` implementation) and `CloudRelay` (over `CloudStore`), Mac identity
  (`macID` UUID + computer name) in `notify-state.json`.
* Contracts: `NotificationStatus` → Mac permission, iCloud status, connected iPhones, last delivery, last error;
  `KakurenekoControlling` loses pairing / ntfy calls, gains `requestNotificationPermission()` and
  `handleCloudPush()`; settings drop provider / ntfyServer, gain `macAlerts` / `phoneAlerts`; migration v1 → v2
  sets `presenceGating = .always`.
* App: onboarding "Phone" step becomes "Notifications" (allow Mac notifications, get the iPhone app, live
  "iPhone connected"), settings pane reworked, `UNUserNotificationCenter` delegate + remote-notification
  registration in the app delegate.
* Build: `scripts/build-app.sh` embeds the Mac provisioning profile minted by the `KakurenekoMacSigning` stub
  target and signs with the iCloud / push / time-sensitive entitlements; without a profile it builds the old
  way (Mac notifications only, iCloud "unavailable in this build").

## 6b. First run on both devices

Either app can be installed first. There is no pairing: each side shows the other as soon as its iCloud record
arrives (the Mac's `MacStatus`, the iPhone's `PhoneDevice`), and each side quotes the other's labels.

| | Mac onboarding, step 2 "Your iPhone" (`OnboardingFlow.PhoneSetup`) | iPhone onboarding, step 4 "Your Mac" (`MacSetupScreen`) |
|---|---|---|
| Other side already set up | "iPhone · seen just now", and when alerts reach it | "Connected to <Mac>": Send a test alert, Done |
| Nothing yet | "Get alerts on your iPhone too?" **Set up my iPhone** / **Just this Mac** | "Is Kakureneko on your Mac?" **Yes, it's on my Mac** / **Not yet** |
| Chose to connect | QR code to the iPhone app, three steps ("tap Yes, it's on my Mac"), waiting; after 45 s "Not showing up?" | Yes: "click the cat… choose Set up my iPhone", waiting; after 45 s "Still waiting? What to check". Not yet: kakureneko.com with Send link / Copy link, "I've installed it" |
| Chose not to | Just this Mac turns iPhone alerts **off** (nothing about this Mac goes to iCloud); "Set up my iPhone" undoes it | Skip for now, or See a demo |

The Mac must have "Send alerts to your iPhone" on for the iPhone to see it (§4: no status otherwise), which is why
Just this Mac turns it off and the iPhone's instructions name it.

## 7. Environments and release

* Development builds (Xcode-signed iPhone app, Apple Development-signed Mac app) use the CloudKit **Development**
  environment and the APNs sandbox. TestFlight / App Store iPhone builds and Developer ID Mac builds use
  **Production**. A dev Mac and a production iPhone never see each other's data.
* Release: docs/RELEASE.md (schema deploy to Production, Developer ID profile via `scripts/release-mac.sh profile`,
  notarization, Sparkle, App Store Connect, TestFlight).

## 8. Agent safety rules (in addition to DECISIONS.md)

* Never install onto or launch apps on the user's iPhone, never touch the user's real iCloud data, never create
  identifiers or containers beyond those in `Xcode/project.yml`. Unit tests use `InMemoryCloudStore` only.
* `xcodebuild` builds for the device and simulator tests are fine; the main loop installs and runs on-device tests.
