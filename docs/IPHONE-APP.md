# Kakureneko for iPhone — structure

Status: implemented 2026-10-17. The design is `docs/NATIVE-NOTIFICATIONS.md` (§5 is this app); this page maps it to
the code. Everything CloudKit- or notification-shaped goes through the shared SwiftPM library `KakurenekoCloud`
(`Sources/KakurenekoCloud`), so the Mac and the iPhone agree on records, ids, notification content and buttons.

## Name

People see **Kakureneko** (隠れ猫, "hiding cat"; DECISIONS D13): the home
screen (`CFBundleDisplayName` Kakureneko; the notification extension's is Kakureneko Alerts), onboarding, Settings,
empty states, notices and the website (https://kakureneko.com). The identifiers carry the same name: bundle ids
`com.kakureneko.Kakureneko` and `.alerts`, the iCloud container `iCloud.com.kakureneko.Kakureneko`, the targets
`KakurenekoPhone` / `KakurenekoPhoneAlerts` and the Xcode project `Kakureneko.xcodeproj`.

## Targets (`Xcode/project.yml`, generated with XcodeGen)

| Target | Sources | What it is |
|---|---|---|
| `KakurenekoPhone` | `iPhone/App` | The app (`com.kakureneko.Kakureneko`, iOS 18+, SwiftUI, Swift 6, complete strict concurrency, approachable concurrency + member import visibility like the package). `Info.plist` only adds `UIBackgroundModes: remote-notification` (no build setting exists for it); everything else is generated. |
| `KakurenekoPhoneAlerts` | `iPhone/NotificationService` | Notification Service Extension (`com.kakureneko.Kakureneko.alerts`) for `alerts-v1` pushes. |
| `KakurenekoPhoneTests` | `iPhone/Tests` + `iPhone/App/Model` | Swift Testing unit tests. No host app: the model sources are compiled into the bundle, so launching the app (and its live `CloudKitStore`) never happens in tests. In the `KakurenekoPhone` scheme's test action. |

## App layout

```
iPhone/App
├── KakurenekoPhoneApp.swift      @main: scene, scenePhase → store (polling only while active)
├── AppDelegate.swift           owns PhoneStore; remote-notification registration; zone-v1 silent push → sync;
│                               CKAccountChanged; UNUserNotificationCenter delegate (banners, taps, buttons in a
│                               background task)
├── Model/                      no UIKit/SwiftUI; also compiled into the tests
│   ├── PhoneStore.swift        @MainActor @Observable model: account, setup, sync, commands, queue, device record,
│   │                           categories, feedback, persistence
│   ├── ZoneSnapshot.swift      statuses per Mac + 3-day alerts; applies fetched changes (placeholders, deletions,
│   │                           from-scratch replacement)
│   ├── CommandFeedback.swift   FeedbackBoard: sending → sent → received/done/ignored/no response (30 s)/queued/failed
│   ├── SyncPolicy.swift        ConnectionState, SyncOutcome, RetryBackoff (5 s … 5 min), DeviceRecordPolicy (6 h)
│   ├── PhoneCache.swift        PhoneCacheFile (JSON in Application Support) + PhonePreferences (UserDefaults)
│   ├── PhoneEnvironment.swift  PhoneClock, DeviceInfo, NotificationAuthorization, LocalNotice, NotificationCenterClient
│   ├── Presentation.swift      pills, staleness, countdown, battery, alert icons, Activity days, feedback sentences
│   ├── NotificationResponseAction.swift  tap/button decoding (via AlertPresentation.buttonTap)
│   ├── Demo.swift              DemoFixtures (sample Macs + alerts), DemoEnvironment (a PhoneStore on fakes + a
│   │                           simulated Mac), DemoMode (the app's "See a demo" switch); ships in Release
│   ├── WebsiteLinks.swift      privacy / support / Mac download URLs from the Info.plist's KakurenekoWebsiteURL
│   ├── MacSetup.swift          onboarding's "Your Mac": question → get the Mac app / waiting → Connected
│   └── RecordingNotificationCenter.swift fake notification center: tests, previews and the demo
├── Platform/                   live implementations (app only)
│   ├── SystemNotificationCenter.swift
│   └── LiveEnvironment.swift   DeviceInfo.current, PhoneStore.live(), BackgroundTask
├── Views/                      RootView (AppRootView: the real app, the demo over it; onboarding / tabs),
│                               OnboardingView, Macs/ (tab, list, detail + controls), ActivityView, SettingsView,
│                               Components (AppLinks, DemoBanner, …), Palette (design language colours, buttons,
│                               Soot), PreviewSupport (Debug only: PreviewHost, and the `-KakurenekoDemo` launch
│                               arguments that run the whole app on a demo scenario in the Simulator)
└── Resources/                  Assets.xcassets (AccentColor, 1024 px opaque AppIcon from scripts/make-phone-icon.swift),
                                PrivacyInfo.xcprivacy (no tracking, no collected data, UserDefaults CA92.1)
```

## Privacy (what the app may claim)

Records live in the app's PUBLIC CloudKit database (`Xcode/CloudKit/schema.ckdb`, D12), each readable and writable
only by the Apple Account that created it. Apple hosts it, the developer can see it through Apple's CloudKit tools,
and Kakureneko does not end-to-end encrypt it. The app therefore says "through Apple's iCloud, readable only with your
Apple Account", "no server of its own", "no analytics", and never "private iCloud", "end-to-end", "only your devices
can see" or "nobody else can see". The privacy manifest's collected-data list must match the App Store Connect
privacy answers.

## Demo (App Review, and anyone without the Mac app yet)

"See a demo" on onboarding's last step ("Your Mac") and in Settings starts `DemoMode`: a
`DemoEnvironment` with its own `PhoneStore` on an `InMemoryCloudStore`, a throwaway cache directory and defaults
suite, and `RecordingNotificationCenter`, showing one sample Mac (`DemoFixtures.Scenario.oneMac`: lid closed, an
agent working, one waiting, one finished; recent alerts). A simulated Mac answers the buttons two seconds later
(Keep awake, Sleep now, Shut down, Send test alert), republishes its status every 30 s and sleeps when a countdown
runs out. `AppRootView` shows it as a full-screen cover over the real app, under a "Demo" banner with End demo; the
real store, its iCloud sync, pushes and notification buttons keep running underneath, untouched, and the real
screens keep their state (onboarding step, navigation). Tapping a real notification ends the demo. Nothing from the
demo reaches iCloud or the system's notifications (`DemoTests`). Debug builds also have launch arguments for the
Simulator (`-KakurenekoDemo oneMac|working|waiting|countdown|severalMacs|stale|noMac|noICloud|firstRun`,
`-KakurenekoDemoTab activity|settings`, `-KakurenekoDemoStep waitingForMac`, `-KakurenekoDemoCover YES`,
`-KakurenekoDemoClock 9:41`); those replace the live store entirely and never ship.

## Links

`KAKURENEKO_WEBSITE_URL` (Xcode/project.yml, default `https://kakureneko.com`; `WEBSITE_URL` in scripts/release.env
overrides it) → Info.plist `KakurenekoWebsiteURL` → `AppLinks`: privacy policy `<site>/privacy/`, support
`<site>/support/`, Get Kakureneko for Mac `<site>/`. A missing or malformed value falls back to
`https://kakureneko.com/` (`WebsiteLinks.fallback`).

## Behaviour summary

* **Sync**: account check → `prepareZone` → `ensureSubscription(.alerts)` + `(.zoneChanges)` (re-ensured every 24 h or
  after zone loss) → `fetchAllChanges(since: token)`. `.zoneMissing` recreates the zone and refetches from scratch,
  `.changeTokenExpired` refetches from scratch (a from-scratch fetch replaces the cache), network / rate limit back
  off (CloudKit's hint wins), `.notSignedIn` / signing out clears the account's cached data. Triggers: launch,
  every foreground, in the foreground every 5 s while a command waits for its Mac (else every 20 s), `zone-v1` pushes, pull-to-refresh, an alert shown in the foreground.
* **Commands**: `issuedAt` now, `expiresAt` = the alert's expiry or now + 10 min, `sv` = the alert's or the status'.
  Written ahead into the persistent queue, saved, dequeued on success; retried on launch / foreground / a successful
  poll, dropped once the Mac would reject them. `refresh` commands (opening the app, pull-to-refresh; Macs whose
  status is older than 60 s, at most once a minute each) are never queued.
* **Buttons on notifications**: decoded off the main actor, then saved inside `UIApplication.beginBackgroundTask`.
  If saving fails, or the background time expires first, the command stays queued and a local notification says
  "Couldn't reach <Mac> — Open Kakureneko to retry". Buttons of an expired alert send nothing (a notice explains).
* **Device record**: first foreground activation of each launch, any change of notification permission / device /
  app version, else at most every 6 h.
* **Extension**: `CKQueryNotification` → `CloudRecordCoding.alert(pushFields:recordName:)`, else
  `CloudKitStore.fetch(.alert(id))` → `AlertPresentation.content(…, showMacName: true)`; delivered notifications
  with the same `replaceKey` and Mac are removed first; `serviceExtensionTimeWillExpire` delivers the best content
  so far (`NotificationDelivery`, exactly once).

## Build, test, ship

`scripts/build-phone.sh build|test|install|archive|upload` (see its header).

* `build` (Debug, the connected iPhone, nothing installed) and `test` (simulator, fakes only) are safe for agents.
  `install`, `archive` and `upload` are for humans.
* Versions: `archive` / `upload` read `scripts/release.env` when it exists: `VERSION` → `MARKETING_VERSION`,
  `BUILD_NUMBER` → `CURRENT_PROJECT_VERSION` (default: the UTC time `date -u +%Y%m%d%H%M`, so every upload is
  higher), `WEBSITE_URL` → `KAKURENEKO_WEBSITE_URL` (every mode). Without the file, project.yml's values apply.
  Environment variables win over the file.
* `upload` archives, writes `build/ExportOptions.plist` (method `app-store-connect`, destination `upload`, automatic
  signing, team 7NRW73MYQZ, `manageAppVersionAndBuildNumber` false) and runs `xcodebuild -exportArchive
  -allowProvisioningUpdates`, which uploads to App Store Connect. It then prints `aps-environment` and
  `com.apple.developer.icloud-container-environment` of what was uploaded (from `build/export/DistributionSummary.plist`):
  both must be production. `archive` prints the archived app's (development-signed) values.
* Screenshots: `marketing/screenshots/iphone/` (6.9", 1320 × 2868, flattened PNG; `01-working`, `02-countdown`,
  `03-waiting`, `04-activity`, `05-welcome`, plus `dark-01-working` and `dark-02-countdown` for the website). Made on
  the iPhone 17 Pro Max simulator from the Debug build with `-KakurenekoDemo <scenario>` (`working`, `countdown`,
  `waiting`, `oneMac -KakurenekoDemoTab activity`, `firstRun`; dark ones with `xcrun simctl ui <udid> appearance dark`)
  and `-KakurenekoDemoClock 9:41` (Debug only: the app writes its times as if it were 9:41 at launch, so "Working
  since 9:16 AM" sits beside the status bar), the simulator set to en_US (`defaults write -g AppleLocale en_US` and
  `AppleLanguages (en-US)` via `simctl spawn`, then reboot it; otherwise the status bar reads 09:41), `xcrun simctl
  status_bar <udid> override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3`,
  `xcrun simctl io <udid> screenshot`, then `scripts/flatten-png.swift` (no alpha). The website's half-size copies
  (660 × 1434, `sips -Z 1434`): `site/assets/shots/iphone-mac.png` (01-working), `iphone-mac-dark.png`
  (dark-01-working), `iphone-countdown.png` (02-countdown), `iphone-countdown-dark.png` (dark-02-countdown).
* Before the first TestFlight build: deploy the CloudKit development schema to production, publish `/privacy/` and
  `/support/` on https://kakureneko.com (the app's default; App Store Connect needs the same URLs), and tell App
  Review about "See a demo" (the app needs the Mac app; the demo shows it without one).
