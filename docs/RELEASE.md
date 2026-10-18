# Releasing Kakureneko

How Kakureneko reaches other people's Macs and iPhones. The scripts do the work. The steps marked **(you)** need your
Apple account, your keychain or a decision, so agents never run them.

## Name

The product is **Kakureneko** (隠れ猫, Japanese for "hiding cat"): "Kakureneko for Mac" (`Kakureneko.app`) and
"Kakureneko for iPhone". The website is **https://kakureneko.com**.

The identifiers carry the same name (DECISIONS D13): the bundle ids (`com.kakureneko.Kakureneko` and friends), the
iCloud container `iCloud.com.kakureneko.Kakureneko`, `~/.kakureneko`, the Claude Code plugin `kakureneko`, the system
files (`/etc/sudoers.d/kakureneko`, `/Library/LaunchDaemons/com.kakureneko.failsafe.plist`), the Swift modules, the
`KAKURENEKO_*` variables and the `kakureneko-notary` keychain profile.

## How it ships

| | Mac app | iPhone app |
|---|---|---|
| Channel | Download from the website (`Kakureneko-<version>.dmg`) | App Store (TestFlight first) |
| Signing | Developer ID Application, hardened runtime, notarized and stapled | App Store distribution (Xcode automatic signing) |
| iCloud | CloudKit **Production**, production APNs | CloudKit **Production** |
| Updates | Sparkle 2 (`site/updates/appcast.xml`, EdDSA-signed) | App Store |
| Runs on | macOS 26 or later, Apple silicon and Intel | iOS 18 or later |

**Why not the Mac App Store.** Mac App Store apps must be sandboxed. In the sandbox Kakureneko couldn't:

- ask for the one admin prompt (the sudoers rule for `pmset disablesleep` and the root fail-safe). Nothing else
  keeps a closed MacBook awake on battery.
- pause other apps with `SIGSTOP`/throttling.
- edit agent configs such as `~/.claude/settings.json` without a file picker for each one.

A store version would be alerts only. Amphetamine handles this by sending users outside the store for a separate
helper. A direct download is the honest version of that.

**Development vs. production.** `scripts/install.sh` (Apple Development) and `scripts/build-phone.sh install` use
CloudKit **Development**. The website download and TestFlight/App Store builds use **Production**. The two never
see each other's data: test a TestFlight iPhone build with the downloaded Mac build, not with `install.sh`.

## One-time setup

1. **Developer ID certificate (you).** Open Xcode → Settings → Accounts, select team 7NRW73MYQZ, then
   Manage Certificates… → + → **Developer ID Application**. Only the Account Holder can create it.
   `scripts/release-mac.sh check` confirms it's in the keychain.
2. **Notary credentials (you).** At account.apple.com → Sign-In and Security → App-Specific Passwords, make a
   password for "notarytool". Then run:
   ```
   xcrun notarytool store-credentials kakureneko-notary --apple-id <your Apple Account> --team-id 7NRW73MYQZ
   ```
   It asks for the password, which stays in your keychain.
3. **Sparkle key (you).** Run `scripts/release-mac.sh keys`. It creates the EdDSA key in your login keychain and
   writes the public key into `scripts/release.env`. **Back it up:**
   `.build/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/somewhere-safe/kakureneko-sparkle-key`. Every installed
   copy trusts only this key. If you lose it, users must download the next version by hand.
4. **Developer ID provisioning profile (you).** Run `scripts/release-mac.sh profile`. Xcode archives the
   `KakurenekoMacSigning` stub and exports it with Developer ID, which creates the profile (iCloud, push) for
   `com.kakureneko.Kakureneko`, saved to `build/release/DeveloperID.provisionprofile`. The command lists what the
   profile grants. If it doesn't grant Time Sensitive notifications, the build signs without that key (alerts still
   work, they just can't break through Focus).
5. **The website (you deploy).**
   - The domain is **kakureneko.com**. `scripts/release.env` already has `WEBSITE_URL=https://kakureneko.com`; the
     Mac app's links, the update feed and the iPhone app's privacy and support links all derive from it. The site's
     canonical and Open Graph tags use the same address.
   - `site/` is a plain static site: index, `privacy/`, `support/`, `iphone/`, `download/`, `updates/`. Any static
     host works (Vercel, Netlify, Cloudflare Pages, GitHub Pages). Point kakureneko.com's DNS at it and serve it from
     the root of the domain (`404.html` links with root-relative paths).
   - Serve `updates/appcast.xml` without long caching.
   - Fill in the `TODO(release)` comments in `site/`: the policy's effective date, the legal name, the web host and
     how long it keeps logs, the two commitments the policy asks you to confirm, and the App Store link.
6. **Support address (you).** Set up `support@kakureneko.com` (Namecheap email forwarding to an inbox you read) and
   send it a test. The support and privacy pages already show it, each with a `TODO(release)` reminder to remove
   once it works.
7. **Copyright (you).** Set `COPYRIGHT` in `scripts/release.env`, e.g. `© 2026 Your Name`.
8. **CloudKit Production (you).** In the CloudKit Console, open `iCloud.com.kakureneko.Kakureneko` → Schema →
   **Deploy Schema Changes…** to Production. **Never click "Reset Environment".** Deploy again whenever
   `Xcode/CloudKit/schema.ckdb` changes; production only accepts additive changes.
   - **Then check Production's security roles.** Alert, Command, MacStatus and PhoneDevice should each give
     `_creator` read and write, `_icloud` create, and nothing to `_world`. The public database's default lets
     anyone read, so if the roles didn't deploy, anyone could read every record.
9. **App Store Connect (you).**
   - Create the app: platform iOS, bundle id `com.kakureneko.Kakureneko`, any SKU.
   - Fill the listing from `docs/APP-STORE.md`: texts, privacy answers, review notes and the demo. Screenshots are
     in `marketing/screenshots/iphone/`.
   - Once the app is live, put its App Store URL in `IPHONE_APP_URL`. The Mac onboarding's QR code then opens the
     App Store directly instead of the website's iPhone page.

## Each release

1. Set `VERSION` in `scripts/release.env` (marketing version, shared by both apps). Leave `BUILD_NUMBER` empty: it
   becomes a UTC timestamp, so every build is newer than the last.
2. Write the release notes to `site/updates/<VERSION>.html`. They're optional; the update window links to them.
3. **Mac:**
   - `scripts/release-mac.sh check` lists anything missing.
   - `scripts/release-mac.sh all` **(you)** does the following:
     - builds universal with Developer ID and production iCloud;
     - notarizes and staples `Kakureneko.app`;
     - builds the disk image, then signs, notarizes and staples it;
     - checks both with Gatekeeper;
     - copies it to `site/download/Kakureneko-<version>.dmg` and `site/download/Kakureneko.dmg` (the website's
       download buttons point at the latter);
     - adds the signed entry to `site/updates/appcast.xml`.
   - Deploy `site/`. Installed copies see the update within a day, or at once with "Check for Updates…".
4. **iPhone:** `scripts/build-phone.sh upload` **(you)** archives and uploads to App Store Connect. Test it in
   TestFlight with the downloaded Mac build, then submit it for review.
5. **Smoke test** on a Mac that never had Kakureneko (or a new user account):
   - Download from the site, open the disk image and drag the app to Applications. Gatekeeper must say
     "downloaded from the internet" and nothing worse.
   - Go through onboarding: closed-lid install, notifications, an agent hook, then "Open at login" and updates.
   - Close the lid with an agent working.
   - Check that the iPhone (TestFlight) gets the alert.
   - Use Settings → General → Uninstall Kakureneko… and check that nothing is left: `/etc/sudoers.d/kakureneko`,
     `/Library/LaunchDaemons/com.kakureneko.failsafe.plist`, `/Library/Application Support/Kakureneko/`, `~/.kakureneko`
     and the agent configs.

## What a new user gets

- **Moving to Applications.** Opened from the disk image or Downloads, Kakureneko offers to move itself into
  Applications and relaunch (`ApplicationsFolder.swift`). Running from a disk image or a translocated copy would
  leave the login item pointing at a path that disappears.
- **Onboarding** (`OnboardingFlow.swift`) has four steps:
  1. Closed-lid mode: one admin prompt, or skip and get alerts only.
  2. Alerts: Mac notifications, then "Set up my iPhone" (QR code to the iPhone app, connects by itself) or "Just this
     Mac" (iPhone alerts off). An iPhone that came first shows as connected.
  3. Agent hooks, with a diff before each change.
  4. When agents are done: sleep or shut down, plus "Open Kakureneko at login" (preset on) and "Check for updates
     automatically" (preset on, Developer ID builds only).
- **The iPhone app** walks through notifications and iCloud, then asks "Is Kakureneko on your Mac?". "Not yet"
  shows kakureneko.com with Send link / Copy link; "Yes" shows what to do on the Mac; both switch to "Connected to
  <Mac>" when it appears (docs/NATIVE-NOTIFICATIONS.md §6b). App Review and curious users can tap "See a demo" there
  and in Settings.
- **Updates:** a daily background check. A found update shows as a row in the menu ("Kakureneko 1.1 is available ·
  Install…"). Settings → General has "Check for Updates…" and the automatic-check toggle.
- **Uninstall** (Settings → General → Uninstall Kakureneko…) removes the following, in this order:
  1. closed-lid mode (admin prompt; cancelling stops the uninstall);
  2. every agent hook;
  3. the login item;
  4. after quitting, `~/.kakureneko`, Application Support, caches and preferences;
  5. finally, the app goes to the Trash.

  iCloud records expire on their own. The iPhone shows the Mac until it's removed there.

## When something fails

- **Notarization rejected:** `xcrun notarytool log <submission id> --keychain-profile kakureneko-notary` shows why.
  Usually it's an unsigned or untimestamped binary. Every binary in `build-app.sh` is signed with `--timestamp` in
  distribution builds, including Sparkle's `Autoupdate` and `Updater.app`.
- **The app quits right away after a Developer ID build:** an entitlement isn't granted by the profile. Compare
  `codesign -d --entitlements - build/Kakureneko.app` with the list printed by `scripts/release-mac.sh profile`.
- **iPhone and Mac don't see each other:** one of them is a development build (see "Development vs. production"
  above), or the schema isn't deployed to Production yet.
- **Sparkle says the update is improperly signed:** the appcast entry was signed with a different key than the one
  in the installed app's `SUPublicEDKey`. Restore the backed-up key.
