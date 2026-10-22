# Releasing Kakureneko

How Kakureneko reaches other people's Macs and iPhones. The scripts do the work. The steps marked **(you)** need your
Apple account, your keychain or a decision, so agents never run them.

## Name

The product is **Kakureneko** (隠れ猫, Japanese for "hiding cat"): "Kakureneko for Mac" (`Kakureneko.app`) and
"Kakureneko for iPhone". There is no website: the project lives at **https://github.com/y0ung-T/kakureneko**
(the README, `PRIVACY.md`, Issues for support, Releases for the Mac download). kakureneko.com was taken down on
2026-10-22.

The identifiers carry the same name (DECISIONS D13): the bundle ids (`com.kakureneko.Kakureneko` and friends), the
iCloud container `iCloud.com.kakureneko.Kakureneko`, `~/.kakureneko`, the Claude Code plugin `kakureneko`, the system
files (`/etc/sudoers.d/kakureneko`, `/Library/LaunchDaemons/com.kakureneko.failsafe.plist`), the Swift modules, the
`KAKURENEKO_*` variables and the `kakureneko-notary` keychain profile.

## How it ships

| | Mac app | iPhone app |
|---|---|---|
| Channel | GitHub Releases (`Kakureneko-<version>.dmg`, and `Kakureneko.dmg` for the README's link) | TestFlight beta (external testers: friends) |
| Signing | Developer ID Application, hardened runtime, notarized and stapled | App Store distribution (Xcode automatic signing) |
| iCloud | CloudKit **Production**, production APNs | CloudKit **Production** |
| Updates | Sparkle 2 (`appcast.xml` on `main`, EdDSA-signed) | TestFlight |
| Runs on | macOS 26 or later, Apple silicon and Intel | iOS 18 or later |

**Why not the Mac App Store.** Mac App Store apps must be sandboxed. In the sandbox Kakureneko couldn't:

- ask for the one admin prompt (the sudoers rule for `pmset disablesleep` and the root fail-safe). Nothing else
  keeps a closed MacBook awake on battery.
- pause other apps with `SIGSTOP`/throttling.
- edit agent configs such as `~/.claude/settings.json` without a file picker for each one.

A store version would be alerts only. Amphetamine handles this by sending users outside the store for a separate
helper. A direct download is the honest version of that.

**Development vs. production.** `scripts/install.sh` (Apple Development) and `scripts/build-phone.sh install` use
CloudKit **Development**. The GitHub download and TestFlight builds use **Production**. The two never
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
5. **GitHub (you).** The repository https://github.com/y0ung-T/kakureneko is public; `gh auth login` lets
   `scripts/release-mac.sh publish` create the release.
   - `WEBSITE_URL` in `scripts/release.env` is the repository. The apps derive their links from it: privacy
     `<repo>/blob/main/PRIVACY.md`, support `<repo>/issues`, the iPhone app `<repo>/#iphone` (the README's iPhone
     section) until `IPHONE_APP_URL` is set.
   - `APPCAST_URL` is `appcast.xml` on `main` (raw.githubusercontent.com, cached about 5 minutes). The enclosures point
     at the release assets (`<repo>/releases/download/v<version>/Kakureneko-<version>.dmg`).
   - The old Vercel site is gone: the project `kakureneko` was deleted, and kakureneko.com is no longer attached to
     anything (the domain stays registered at Namecheap until it lapses).
6. **Copyright.** `COPYRIGHT="© 2026 y0ung-T"` in `scripts/release.env`.
7. **TestFlight (you).** App Store Connect → the app → TestFlight:
   - Test Information: a beta description, a feedback email, and the privacy policy URL
     `https://github.com/y0ung-T/kakureneko/blob/main/PRIVACY.md`. "What to Test" is in
     `marketing/app-store/index.html`.
   - Add an external group ("Friends"), add a build to it (the first one goes through Beta App Review), then invite
     testers by email or turn on a public link.
   - A public link can go into `IPHONE_APP_URL` (`https://testflight.apple.com/join/…`) and the README; the Mac
     onboarding's QR code then opens it directly. Without it, the QR code opens the README's iPhone section, which
     can change at any time without a new Mac build.
8. **CloudKit Production (you).** In the CloudKit Console, open `iCloud.com.kakureneko.Kakureneko` → Schema →
   **Deploy Schema Changes…** to Production. **Never click "Reset Environment".** Deploy again whenever
   `Xcode/CloudKit/schema.ckdb` changes; production only accepts additive changes.
   - **Then check Production's security roles.** Alert, Command, MacStatus and PhoneDevice should each give
     `_creator` read and write, `_icloud` create, and nothing to `_world`. The public database's default lets
     anyone read, so if the roles didn't deploy, anyone could read every record.

## Each release

1. Set `VERSION` in `scripts/release.env` (marketing version, shared by both apps). Leave `BUILD_NUMBER` empty: it
   becomes a UTC timestamp, so every build is newer than the last.
2. Write the release notes to `docs/release-notes/<VERSION>.md`. They're optional: they become the GitHub
   Release's text, which the update window's "Version History" links to.
3. **Mac:**
   - `scripts/release-mac.sh check` lists anything missing.
   - `scripts/release-mac.sh all` **(you)** does the following:
     - builds universal with Developer ID and production iCloud;
     - notarizes and staples `Kakureneko.app`;
     - builds the disk image, then signs, notarizes and staples it;
     - checks both with Gatekeeper;
     - creates the GitHub Release `v<version>` with `Kakureneko-<version>.dmg` and `Kakureneko.dmg` (the README links
       `releases/latest/download/Kakureneko.dmg`);
     - adds the signed entry to `appcast.xml`.
   - Commit and push `appcast.xml`. Installed copies see the update within a day, or at once with "Check for
     Updates…".
4. **iPhone:** `scripts/build-phone.sh upload` **(you)** archives and uploads to App Store Connect. Once it has
   processed, add it to the TestFlight group and test it with the downloaded Mac build.
5. **Smoke test** on a Mac that never had Kakureneko (or a new user account):
   - Download from GitHub Releases, open the disk image and drag the app to Applications. Gatekeeper must say
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
  shows the GitHub repository's address with Send link / Copy link; "Yes" shows what to do on the Mac; both switch to "Connected to
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
