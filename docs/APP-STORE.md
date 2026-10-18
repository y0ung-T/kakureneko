# Kakureneko for iPhone: App Store Connect

Everything to paste into App Store Connect for the iPhone app (bundle id `com.kakureneko.Kakureneko`, iPhone only,
iOS 18+). Written 2026-10-18 from the code (`iPhone/`, `Sources/KakurenekoCloud/`, `Xcode/CloudKit/schema.ckdb`) and
the website in `site/`. The website is **https://kakureneko.com** (`WEBSITE_URL` in `scripts/release.env`, which
`scripts/build-phone.sh` passes on as the `KAKURENEKO_WEBSITE_URL` build setting, so the in-app links match).

The product is called Kakureneko, and so are its identifiers (bundle id, iCloud container, modules).

Every line marked **TODO** needs a human before submission.

---

## 1. App information

| Field | Value |
|---|---|
| Name (30) | **Kakureneko** (10). If it's taken, in order of preference: **Kakureneko: Agent Alerts** (24) · **Kakureneko Agent Watch** (22) · **Kakureneko: Coding Alerts** (25) |
| Subtitle (30) | **Alerts from your coding agents** (30). The name says nothing about what the app does, so the subtitle has to. Alternatives: *Know when your agents finish* (28) · *Your agents, with the lid shut* (30). With the name "Kakureneko: Agent Alerts" or "Kakureneko: Coding Alerts", use *Know when your agents finish* so the subtitle doesn't repeat the name. |
| Primary category | Developer Tools (matches `LSApplicationCategoryType` in `Xcode/project.yml`) |
| Secondary category | Utilities |
| Primary language | English (U.S.) |
| Bundle ID | `com.kakureneko.Kakureneko` |
| SKU | `kakureneko-iphone` (anything unique; never shown) |
| Content rights | "Does your app contain, show, or access third-party content?" **No** |
| Copyright | `2026 REPLACE-ME` **TODO**: legal name |
| Price | **TODO** (the description and the website don't mention a price) |

The App Store name doesn't have to match the home screen name: the app's `CFBundleDisplayName` is "Kakureneko"
whichever store name you end up with.
Keep Apple trademarks ("Mac", "iPhone") out of the name.

## 2. Version information (1.0)

### Promotional text (170)

> Close the lid and walk away. Kakureneko tells you when your coding agents finish or need you, and lets you keep your Mac awake or put it to sleep from your iPhone.

163 characters. It can be changed at any time without a new build.

### Description (4000)

```
Kakureneko for iPhone is the companion to Kakureneko for Mac, a menu bar app that keeps your Mac awake while AI coding agents work, even with the lid closed, and lets it sleep again when they're done.

Close the lid, leave, and your iPhone keeps you in the loop:

• Know when an agent finishes, and how long it worked.
• See when an agent needs your input, such as a permission or a question.
• Get a countdown before your Mac goes to sleep.
• Keep awake or Sleep now, right from the notification.
• See your Mac at a glance: what it's doing, each agent session, the battery, the lid and the countdown.
• Look back over the last three days of alerts.
• Several Macs on one Apple Account show up side by side.

There's no pairing and no account. Use the same Apple Account on your iPhone and your Mac, and they find each other through iCloud. Alerts that need you are Time Sensitive, so they get through Focus.

Works with Claude Code, Codex, Gemini CLI, Cursor, Copilot CLI, opencode, Aider, Windsurf and other coding agents running on your Mac.

No analytics, no tracking, no ads. Alerts are deleted after three days.

Requires Kakureneko for Mac on a Mac with macOS 26 or later, available at kakureneko.com. To look around first, open Settings in the app and choose See a demo.

Kakureneko (隠れ猫) is Japanese for "hiding cat", like Soot, our cat, who keeps watch behind the closed lid.
```

1,386 characters. Notes:

* The last line explains the name. Keep it last: the first lines are what shows before "more".

* The agent names are there as a factual compatibility list. Keep them out of the keywords (guideline 2.3.7 forbids
  other companies' trademarks in keywords).
* If the Mac app is ever sold rather than free, don't put its price or a purchase link in this listing or in the
  iPhone app; check guideline 3.1.1 / 3.1.3 first.

### Keywords (100, comma-separated, no spaces)

```
ai,llm,developer,notify,lid,closed,awake,sleep,laptop,terminal,cli,remote,status,battery,hiding,cat
```

99 characters. It leaves out words already in the name and subtitle ("kakureneko", "alerts", "coding", "agents"):
the App Store indexes those anyway. "hiding,cat" is for people who remember the name's meaning or the cat; it
replaces "monitor", the weakest of the old words. To keep "monitor" instead, drop "hiding" (100):

```
ai,llm,developer,notify,lid,closed,awake,sleep,laptop,terminal,cli,remote,monitor,status,battery,cat
```

If the subtitle doesn't say "coding agents", use this one (98):

```
ai,llm,coding,agent,developer,notify,lid,awake,sleep,laptop,terminal,cli,remote,status,battery,cat
```

### URLs

| Field | Value |
|---|---|
| Support URL | `https://kakureneko.com/support/` |
| Marketing URL | `https://kakureneko.com/` |
| Privacy Policy URL | `https://kakureneko.com/privacy/` |

Use the trailing slashes: the site is folder-per-page (`site/privacy/index.html`). The iPhone app builds the same
addresses from `KAKURENEKO_WEBSITE_URL` (`iPhone/App/Model/WebsiteLinks.swift`); the Mac app from `KakurenekoWebsiteURL`
(`Sources/KakurenekoApp/Support/AppLinks.swift`).

### What's New (1.0)

```
The first version of Kakureneko for iPhone.

• Alerts from Kakureneko on your Mac when an agent finishes, needs you, or the Mac is about to sleep.
• Keep awake and Sleep now, from the notification or the app.
• Your Mac's status, agents, battery and countdown at a glance.
• The last three days of alerts.
• A demo with a sample Mac, in Settings.
```

(App Store Connect doesn't show What's New for a first version; keep it for TestFlight's "What to Test".)

## 3. Age rating

Answer **None** / **No** to everything. Result: **4+**.

| Section | Question | Answer |
|---|---|---|
| In-app controls | Parental controls | No |
| | Age assurance | No |
| Capabilities | Unrestricted web access | No (the app only opens the website's privacy and support pages, and iOS Settings) |
| | User-generated content | No (alerts show text from the user's own agents, to that user only; nothing is shared between users) |
| | Messaging and chat | No |
| | Advertising | No |
| Mature themes | Profanity or crude humor · Horror or fear · Alcohol, tobacco or drugs | None |
| Medical or wellness | Medical or treatment information · Health or wellness topics | None / No |
| Sexuality or nudity | All | None |
| Violence | Cartoon or fantasy · Realistic · Prolonged graphic · Guns or other weapons | None |
| Chance-based activities | Simulated gambling · Contests · Gambling · Loot boxes | None / No |

"Made for Kids": **No**.

## 4. App Privacy ("nutrition label")

### Does it count as "collected"?

Apple's definition: data is *collected* when it is transmitted off the device in a way that lets the developer (or
its partners) access it for longer than needed to service the request in real time. Two facts settle it:

* **The records live in the developer's own CloudKit container, in its PUBLIC database** (D12,
  `Xcode/CloudKit/schema.ckdb`). Apple hosts it as our service provider; data a service provider keeps on our
  behalf counts as ours. Creator-only security roles keep other users out, but the developer can open the public
  database in the CloudKit Console (Production) and read records. That's "access".
* **It stays longer than one request**: alerts for three days, commands until the Mac reads them, and the Mac status
  and iPhone records until they're removed or 30 days pass without an update (the apps prune them by server time).

So the conservative and, as far as we can tell, correct answer is **yes, the app collects data**. (Data in a user's
*private* CloudKit database, which the developer can't read, is usually treated as not collected. That isn't our
setup.)

**Linked to the user: yes.** Every record carries `owner` (the CloudKit user record name, an account-level ID that
is the same on all of the user's devices) and the server-set creator. It's pseudonymous (we can't see a name or
email), but it identifies one account, and Apple's "not linked" bar requires de-identified data.

**Tracking: no.** Nothing is combined with other companies' data or shared with data brokers. There are no
third-party SDKs in the iPhone app.

**Purpose: App Functionality only** for every type. No analytics, no advertising, no personalisation.

**The Mac app's records count too.** Alerts and the Mac status are written by Kakureneko for Mac (which has no App
Store label, being a Developer ID download), but they sit in the same container and exist to be shown by this app.
Declaring them here is the conservative reading.

### Answers

"Do you or your third-party partners collect data from this app?" **Yes, we collect data from this app.**

| Data type (App Store Connect) | What it is in Kakureneko | Linked | Tracking | Purposes |
|---|---|---|---|---|
| Identifiers → **User ID** | `owner` (CloudKit user record name) and the record creator, on every record | Yes | No | App Functionality |
| Identifiers → **Device ID** | `deviceID`: a random ID per app install, in `PhoneDevice` and `Command` records | Yes | No | App Functionality |
| Usage Data → **Product Interaction** | `Command` records: the button tapped (Keep awake + duration, Sleep now, Shut down, test, refresh) and when; `PhoneDevice.lastSeenAt` | Yes | No | App Functionality |
| User Content → **Other User Content** | Alert title and body (agent name, project folder name, host app, durations; the agent's question or permission request, ≤140 chars; at "Detailed", ≤140 chars of the agent's last message); the Mac's user-chosen computer name; the agent session list in `MacStatus` | Yes | No | App Functionality |
| Other Data → **Other Data Types** | Device info: iPhone model identifier, iOS version, app version, notification and Time Sensitive permission (`PhoneDevice`); Mac model, battery level, on-battery and lid state, power phase, Keep awake / shutdown settings (`MacStatus`) | Yes | No | App Functionality |

Everything else: **not collected** (contact info, health, financial, location, sensitive info, contacts, browsing and
search history, purchases, diagnostics, advertising data).

Edge cases and how they were decided:

* **The Mac's name** (`macName`, e.g. "Alex's MacBook Pro") can contain a first name. It's declared as Other User
  Content, not Contact Info → Name: Kakureneko never asks for a name and doesn't use it as one. If you want the
  strictest possible label, also tick Contact Info → Name (Linked, App Functionality).
* **Device model / OS version** are filed as Other Data rather than Diagnostics, because they're shown to the user
  ("iPhone connected") and not used to measure performance. Either choice is defensible; don't declare both.
* **Crash reports** are not declared. The app has no crash SDK. What users choose to share with developers through
  Apple (Settings → Privacy & Security → Analytics & Improvements) is collected by Apple under the user's consent.
  Re-check Apple's current wording before submitting; adding Diagnostics → Crash Data (Not linked, App
  Functionality) costs nothing if in doubt.
* **APNs**: push delivery is Apple's platform service, not collection by us.
* **UserDefaults / the local cache** stay on the device and aren't collection.

### Privacy manifest (done)

`iPhone/App/Resources/PrivacyInfo.xcprivacy` declares the same five types as the label above, so the manifest and
the App Store answers agree. If you change the answers, change it too:

```xml
<key>NSPrivacyCollectedDataTypes</key>
<array>
    <dict>
        <key>NSPrivacyCollectedDataType</key><string>NSPrivacyCollectedDataTypeUserID</string>
        <key>NSPrivacyCollectedDataTypeLinked</key><true/>
        <key>NSPrivacyCollectedDataTypeTracking</key><false/>
        <key>NSPrivacyCollectedDataTypePurposes</key>
        <array><string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string></array>
    </dict>
    <dict>
        <key>NSPrivacyCollectedDataType</key><string>NSPrivacyCollectedDataTypeDeviceID</string>
        <key>NSPrivacyCollectedDataTypeLinked</key><true/>
        <key>NSPrivacyCollectedDataTypeTracking</key><false/>
        <key>NSPrivacyCollectedDataTypePurposes</key>
        <array><string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string></array>
    </dict>
    <dict>
        <key>NSPrivacyCollectedDataType</key><string>NSPrivacyCollectedDataTypeProductInteraction</string>
        <key>NSPrivacyCollectedDataTypeLinked</key><true/>
        <key>NSPrivacyCollectedDataTypeTracking</key><false/>
        <key>NSPrivacyCollectedDataTypePurposes</key>
        <array><string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string></array>
    </dict>
    <dict>
        <key>NSPrivacyCollectedDataType</key><string>NSPrivacyCollectedDataTypeOtherUserContent</string>
        <key>NSPrivacyCollectedDataTypeLinked</key><true/>
        <key>NSPrivacyCollectedDataTypeTracking</key><false/>
        <key>NSPrivacyCollectedDataTypePurposes</key>
        <array><string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string></array>
    </dict>
    <dict>
        <key>NSPrivacyCollectedDataType</key><string>NSPrivacyCollectedDataTypeOtherDataTypes</string>
        <key>NSPrivacyCollectedDataTypeLinked</key><true/>
        <key>NSPrivacyCollectedDataTypeTracking</key><false/>
        <key>NSPrivacyCollectedDataTypePurposes</key>
        <array><string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string></array>
    </dict>
</array>
```

## 5. Export compliance

`ITSAppUsesNonExemptEncryption` = **NO** is already set (`INFOPLIST_KEY_ITSAppUsesNonExemptEncryption` in
`Xcode/project.yml`), so App Store Connect won't ask per build. That's correct: the app has no cryptography of its
own and only uses what iOS provides (TLS for CloudKit and push). If App Store Connect ever asks anyway, the answer
is "None of the algorithms mentioned above"; no documentation and no French declaration are needed.

## 6. App Review

### Sign-in

"Sign-in required": **No**. There's no account. Real use needs an iCloud account, which the reviewer's device
already has.

### Contact information

**TODO**: first name, last name, phone and email of the person App Review should contact. Use an address you
read: `support@kakureneko.com` only once its forwarding is set up (docs/RELEASE.md, one-time setup).

### Notes (paste)

```
Kakureneko for iPhone is the companion to Kakureneko for Mac, a menu bar app distributed outside the Mac App Store (notarized Developer ID download from https://kakureneko.com). The Mac app keeps a MacBook awake while AI coding agents (command-line tools such as Claude Code or Codex) work, even with the lid closed, and lets it sleep when they're done. It sends alerts and its status to this app through the user's iCloud account (CloudKit). There is no account or server of our own and no pairing: the same Apple Account on both devices is enough.

Without a Mac running Kakureneko, the app has nothing to show and waits for a Mac. To review it without a Mac, use the built-in demo:
1. Launch the app and go through the welcome steps (notifications, iCloud).
2. On the last step ("Waiting for your Mac"), tap "See a demo". It's also in the Settings tab: "See a demo".
3. The demo runs on a sample Mac: agents working and waiting, the sleep countdown, Keep awake / Sleep now (they answer like a real Mac), and the Activity list. Nothing is sent to iCloud or to any Mac. "End demo" in Settings returns to the real app.

Demo video (real Mac and iPhone together): https://REPLACE-ME

To test with a real Mac: install Kakureneko for Mac from https://kakureneko.com on a Mac with macOS 26 or later, sign in to the same Apple Account as the iPhone, and turn on Settings → Notifications → "Send alerts to your iPhone" with "Send them: Always". Then tap "Send Test Alert" in the iPhone app's Settings tab.

Permissions and background modes:
- Notifications, including Time Sensitive: used for "an agent needs your input" and safety stops, so they get through Focus.
- Background mode "remote-notification": CloudKit silent pushes that keep the Mac's status in the app up to date.
- A Notification Service Extension formats each alert from its CloudKit record.

The app has no in-app purchases, ads, analytics or third-party SDKs.
```

**TODO** before pasting: record the demo video and put its link where it says `https://REPLACE-ME` (an unlisted
video, or a file on the website); confirm the demo button labels and where they are in the
build you submit (they were being added while this was written: `iPhone/App/Views/OnboardingView.swift` and
`SettingsView.swift`, "See a demo" / "End demo").

## 7. Screenshots

**Done (2026-10-18):** `marketing/app-store/screenshots/01-lid-closed.png` … `06-no-account.png`, 1320 × 2868,
opaque. Upload them in that order under "iPhone 6.9" Display". `marketing/app-store/index.html` previews the listing
and has every field above ready to copy (serve it with `python3 -m http.server 4322 --directory marketing/app-store`).
They're rendered from `marketing/app-store/source/screens.html` by `marketing/app-store/render.sh` (headless Chrome,
then `scripts/flatten-png.swift`); the phone screens are the Simulator captures in `marketing/screenshots/iphone`.

| # | File | Caption | Screen |
|---|---|---|---|
| 1 | `01-lid-closed` | Close the lid. Your agents keep working. | `-KakurenekoDemo working` |
| 2 | `02-needs-you` | Know when an agent needs you. | `-KakurenekoDemo waiting`, with the alert drawn over it (below) |
| 3 | `03-countdown` | Keep it awake, or let it sleep. | `-KakurenekoDemo countdown` |
| 4 | `04-activity` | The last three days, in one list. | `-KakurenekoDemo oneMac -KakurenekoDemoTab activity` |
| 5 | `05-several-macs` | Same Apple Account. No pairing. | `-KakurenekoDemo severalMacs`, Soot peeking at the bottom |
| 6 | `06-no-account` | Nothing to sign up for. | `-KakurenekoDemo firstRun` (welcome step) |

Shot 2's alert card is drawn in HTML from the real alert's texts (`DemoFixtures.alerts`: "Codex needs your input",
subtitle "Studio", the session as body), the real thumbnail (`alert-wave.png`) and the real long-press buttons
("Keep awake 1h", "Sleep now" in red as a destructive action). The Simulator can't show it for real: demo mode
sends nothing, and the app can't get notification permission without a tap. To replace it with a real capture,
take one on a 6.9" iPhone with a real Mac and swap the file. Retake the phone screens with the Simulator locale set
to `en_US` and `-KakurenekoDemoClock 9:41`, or the times read 24-hour.

The plan this followed:

Required: **6.9-inch display**, portrait, **1320 × 2868** (iPhone 16 Pro Max / 17 Pro Max; 1290 × 2796 is also
accepted). Smaller iPhone sizes are scaled from it. iPhone only: no iPad screenshots (`TARGETED_DEVICE_FAMILY` = 1).
Up to 10 per localisation; the plan uses 6.

How to make them (Simulator, iPhone 17 Pro Max):

* Debug build with `-KakurenekoDemo <scenario>` (and `-KakurenekoDemoTab activity|settings`): the app runs on the demo
  fixtures without the demo banner. Don't use `-KakurenekoDemoCover YES` for store screenshots.
* Clean status bar first:
  `xcrun simctl status_bar booted override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4`
* Capture: `xcrun simctl io booted screenshot <file>.png`.
* Lock Screen notifications can't come from the fixtures. Take #2 on a real 6.9" iPhone with a real Mac, or try
  `xcrun simctl push` with a sample payload (the extension may show it without buttons when it can't fetch the
  record).

Layout per DESIGN.md: `paper` (#F4F2EC) background, the caption on top in SF Pro Bold, ink (#121212), no
gradients, no device-frame shadows. Captions are plain sentences without exclamation marks. At most one Soot pose
per screenshot (optional, only on #1 and #6).

| # | Screen | How | Caption |
|---|---|---|---|
| 1 | The Mac screen: lid closed, two agents working, battery | `-KakurenekoDemo working` | Close the lid. Your agents keep working. |
| 2 | Lock Screen notification "… needs your input" with Keep awake 1h · Sleep now (long-pressed) | real device, or `simctl push` | Know when an agent needs you. |
| 3 | Countdown "All agents done, sleeping in …" with the buttons | `-KakurenekoDemo countdown` | Keep it awake, or let it sleep. |
| 4 | Mac detail with the agent list: one working, one waiting, one finished | `-KakurenekoDemo waiting` | Every agent, at a glance. |
| 5 | Activity tab, grouped by day | `-KakurenekoDemo oneMac -KakurenekoDemoTab activity` | The last three days of alerts. |
| 6 | Several Macs side by side (or the iCloud onboarding step) | `-KakurenekoDemo severalMacs` | Same Apple Account. No pairing. |

The fixtures' text follows the Mac app's real templates (`iPhone/App/Model/Demo.swift`), so the screenshots show
what users will actually see. No invented numbers, ratings or reviews.

Optional: a 15–30 s App Preview (the lid closing, the alert arriving, Keep awake). It can reuse the review demo
video.

## 8. Before you submit (checklist)

- [ ] Deploy the CloudKit schema to **Production** (CloudKit Console → Deploy Schema Changes), then check in the
      Console that Production's **security roles** match `schema.ckdb`: `_creator` READ + WRITE and `_icloud` CREATE on
      Alert, Command, MacStatus and PhoneDevice, and **no `_world` read**. The public database's default role lets
      the world read; if roles didn't deploy, every record would be readable by anyone.
- [ ] Publish `site/` and confirm `https://kakureneko.com/privacy/` and `https://kakureneko.com/support/` load.
- [ ] Set up `support@kakureneko.com` (Namecheap email forwarding) and send it a test.
- [ ] Fill the website's TODOs (effective date, legal name, App Store link). Screenshots: done.
- [x] `PrivacyInfo.xcprivacy` matches section 4, and the in-app privacy wording no longer says "private iCloud".
- [x] `WEBSITE_URL=https://kakureneko.com` in `scripts/release.env` (it becomes `KAKURENEKO_WEBSITE_URL`).
- [ ] Check the archive's `aps-environment` is `production`.
- [ ] Record the demo video; fill the App Review contact.
