# Privacy Policy

Effective date: October 22, 2026

This policy covers Kakureneko for Mac and Kakureneko for iPhone. It says what each one stores, where, for how long,
and who can see it.

## The short version

- There is no Kakureneko account and no server of our own. Your Mac and your iPhone talk through Apple's iCloud.
- What goes through iCloud: alerts, your Mac's status, the requests your iPhone sends (button taps, and a status
  refresh when you open the app), and a small record for each iPhone. Alerts are deleted after three days.
- Other iCloud users can't read your records. They are not end-to-end encrypted, though, and as the developer we can
  technically see them through Apple's tools.
- No analytics, no tracking, no ads. The only third-party code is Sparkle, which the Mac app uses to check for
  updates.
- Everything else stays on your Mac.

## Who we are

Kakureneko is made by [y0ung-T](https://github.com/y0ung-T), an independent developer. We decide how the data
described here is used, and we're the people to contact about it.

We don't sell, rent or share your data, and we don't use it for advertising. The only other parties involved are
Apple, which hosts iCloud, delivers the notifications and distributes the iPhone beta through TestFlight, and GitHub,
which hosts the Mac app's downloads and updates.

## On your Mac

Kakureneko for Mac runs on your Mac and keeps its data there:

- Settings, the alerts waiting to be sent, and the list of your iPhones, in `~/Library/Application Support/Kakureneko`.
- Logs, in `~/.kakureneko/log`. They record what Kakureneko decided (for example that it kept the Mac awake or slowed
  an app down), not your prompts or the agents' messages.
- What each agent session is doing right now, and backups of agent settings it changed, in `~/.kakureneko`.

To know what an agent is doing, Kakureneko reads the events its hook writes and the agent's own session files on your
Mac. To decide which apps to slow down, it looks at the apps running on your Mac. None of that leaves the Mac, except
what goes into an alert or the Mac's status, described below.

Kakureneko changes an agent's configuration files only when you ask it to. It shows you the exact change first and
backs up the file before writing.

## Between your Mac and iPhone

The Mac app and the iPhone app exchange a few records through CloudKit, Apple's iCloud database service. There is no
server of ours in between.

### Where the records are stored

The records are stored at Apple, in Kakureneko's **public** CloudKit database. "Public" is Apple's name for the
database that belongs to the app rather than to your personal iCloud. It does not mean anyone can read it:

- **Other iCloud users can't.** Each record can be read and changed only by the Apple Account that created it. Your
  Macs and iPhones signed in to your Apple Account can read your records; nobody else's devices can.
- **It doesn't use your iCloud storage.** The space comes from Kakureneko's allowance at Apple, not from your plan.
- **It isn't end-to-end encrypted.** Data travels encrypted between your devices and iCloud, but Kakureneko doesn't
  add encryption of its own. Apple hosts the data under [Apple's privacy policy](https://www.apple.com/legal/privacy/).
- **We can access it.** As the developer, we can open Kakureneko's public database with Apple's CloudKit tools. We
  don't use the data for anything except running Kakureneko, and we only look at it to fix a problem you report to us.

The records are tied to a random identifier that iCloud gives your Apple Account for Kakureneko. We can't see your
name or email address from it. Your Mac's name is included, though, and it often contains a first name (for example
"Alex's MacBook Pro"). You can change it in System Settings → General → Sharing.

### When iCloud is used

Kakureneko for Mac writes to iCloud only while "Send alerts to your iPhone" is on (Settings → Notifications; it's on
by default) and the Mac is signed in to iCloud. Until an iPhone with Kakureneko has connected, it writes only a bare
status (the Mac's name, model and Kakureneko's version, and whether it's awake), so the iPhone app can find the Mac,
and no alerts. Once an iPhone has connected, it keeps the Mac's full status record up to date and writes alerts when
their timing allows, by default only while the lid is closed. Turning that setting off deletes the Mac's status
record and the alerts it saved, and nothing more is written until you turn it on again.

Kakureneko for iPhone uses iCloud as soon as you open it on an iPhone that's signed in to iCloud.

### What the records contain

| Record | Written by | What it holds | Kept |
|---|---|---|---|
| **Alert** | Your Mac, once for each alert | The alert's title and text (see [What an alert says](#what-an-alert-says)), the kind of alert, its buttons, how urgent it is, your Mac's name and a random ID for the Mac, a grouping key made of the agent and its session ID, when it was sent, and when its buttons stop working. | Three days. Your Mac then deletes it. |
| **Mac status** | Your Mac, while Kakureneko runs | Your Mac's name and model, Kakureneko's version, what Kakureneko is doing (for example "Lid closed · 2 agents working"), the sleep countdown, the battery level, whether it's on battery, whether the lid is closed, your Keep awake and shut-down settings, and the agent sessions that are running: the agent's name, the project folder's name, the app it runs in, what it's doing and since when. | One record per Mac, replaced on every change. Before any iPhone has connected, it holds only the Mac's name, model, Kakureneko's version and settings, and what Kakureneko is doing, without the agents, battery or lid. When Kakureneko quits or the Mac sleeps, it's replaced by a short status without the agent list. Deleted when you turn off "Send alerts to your iPhone", uninstall Kakureneko, tap Remove on the iPhone, or after 30 days without an update. |
| **Command** | Your iPhone, when you tap a button | What you asked for (Keep awake and for how long, Sleep now, Shut down, a test alert, or a status refresh), which Mac and alert it's for, when you asked and when the request expires, a random ID for your iPhone, and the device name iOS gives apps ("iPhone"). | Until your Mac reads it, normally a few seconds. Your Mac then deletes it. |
| **iPhone** | Your iPhone, when the app starts or a permission changes, otherwise at most every six hours | A random ID for this installation of the app, the device name iOS gives apps ("iPhone"), the model, the iOS version, the app version, whether notifications and Time Sensitive alerts are allowed, and when the app last checked in. | One record per iPhone, replaced each time. Deleted when you tap Remove on the Mac, or after 30 days without an update. |

Every record also carries the random identifier of your Apple Account (so your devices find your records) and the
timestamps iCloud adds itself. CloudKit also keeps a standard user record for every Apple Account that uses
Kakureneko; Kakureneko stores nothing in it.

Alerts reach your iPhone through Apple's push notification service. The iPhone app keeps a copy of the last three
days of alerts and your Macs' latest status on the iPhone itself. Deleting the app deletes that copy.

## What an alert says

You choose how much an alert says in Kakureneko for Mac, under Settings → Notifications → Detail. The same text
appears on your Mac and your iPhone.

| Detail level | Alert titles and text contain |
|---|---|
| **Private** | No agent or project names: "An agent finished", "An agent needs your input", with counts and times. |
| **Basic** (default) | The agent's name, the project folder's name, the app it runs in (for example Terminal) and how long it worked. When an agent waits for you, also what it's waiting for, in up to 140 characters: the permission it asks for, or its question. |
| **Detailed** | Everything in Basic, plus up to 140 characters of the agent's last message. |

Before any text from an agent leaves your Mac, Kakureneko removes things that look like API keys, access tokens and
private keys, and shortens file paths to the file name. This is a safety net, not a guarantee: if your agents handle
sensitive text, choose Private.

The detail level also applies to the Mac status: at Private it lists only which agents are running and what they're
doing, without project folder or app names. At Basic and Detailed it includes them.

## How long it's kept

- **Alerts:** three days. Your Macs, and the iPhone app once a day, delete alerts older than three and a half days,
  whichever Mac sent them, so they don't stay behind when a Mac is gone.
- **Commands:** until the Mac reads them, normally seconds. One no Mac read is deleted after an hour.
- **Mac status:** one per Mac, replaced on every update. Deleted when you turn off "Send alerts to your iPhone",
  uninstall Kakureneko, tap Remove on the iPhone, or after 30 days without an update.
- **iPhone records:** one per iPhone, kept when you reinstall the app. Deleted when you tap Remove on the Mac
  (Settings → Notifications) or after 30 days without an update.
- **On your Mac and iPhone:** until you delete Kakureneko. The iPhone app's copy of alerts only covers the last three
  days.

## Updates for the Mac app

Kakureneko for Mac uses [Sparkle](https://sparkle-project.org/), an open-source updater, to check for new versions.
When it checks, it downloads a small update feed from this GitHub repository, and new versions come from its GitHub
Releases. Like any web request, this shows GitHub your IP address; GitHub handles it under
[its privacy statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement). The
request also names the version of Kakureneko you have. Sparkle can send an optional system profile (hardware and
macOS details); Kakureneko leaves it turned off and adds nothing to the request, so it isn't sent.

## Crash reports

Neither app has a crash reporter of its own.

- **iPhone:** TestFlight shares crash reports, and any feedback you send through TestFlight, with us. If you turned on
  "Share With App Developers" (Settings → Privacy & Security → Analytics & Improvements), Apple also shares usage
  statistics for the app with us. You can turn that off there at any time.
- **Mac:** Kakureneko sends no crash reports to us. macOS may send them to Apple if you share Mac analytics with Apple,
  under Apple's privacy policy. If something goes wrong, you can send us a report or a log yourself.

## Permissions

- **Notifications** (Mac and iPhone): to show alerts. On iPhone, Time Sensitive alerts let the important ones, such
  as "an agent needs you", through Focus.
- **iCloud** (Mac and iPhone): to exchange the records above. Kakureneko uses the Apple Account your devices are
  already signed in to.
- **Administrator approval, once** (Mac): to install closed-lid mode. The [README](README.md#closed-lid-mode) says
  exactly what it installs.
- **Automation** (Mac): only if you choose "Shut down" when agents are done, so Kakureneko can ask macOS to shut down.

## Your choices

- **Say less:** choose the Private detail level in Kakureneko for Mac (Settings → Notifications → Detail).
- **Stop iPhone alerts:** turn off "Send alerts to your iPhone" in Settings → Notifications. The Mac's status and the
  alerts it saved are deleted from iCloud, and nothing more is written there.
- **Remove the iPhone app:** it stops writing to iCloud. Its iPhone record is deleted after 30 days without an update
  by any of your devices still running Kakureneko, or at once when you tap Remove on the Mac (Settings →
  Notifications).
- **Remove Kakureneko from your Mac:** Settings → General → Uninstall Kakureneko… removes Kakureneko and everything
  it put on your Mac, and first deletes the Mac's status and its alerts from iCloud. If the Mac is offline at that
  moment, they stay; contact us and we'll delete them.
- **Ask us:** you can ask what we hold about you, and ask us to delete your iCloud records.

## Children

Kakureneko is a tool for software developers. It isn't directed at children, and we don't knowingly collect data
from children under 13, or the minimum age where you live.

## Changes to this policy

When we change this policy, we update this file and the effective date at the top. Its history is in this
repository's commits.

## Contact

Questions or requests about your data: [open an issue](https://github.com/y0ung-T/kakureneko/issues), or contact
[y0ung-T](https://github.com/y0ung-T) through GitHub if you'd rather not write in public.
