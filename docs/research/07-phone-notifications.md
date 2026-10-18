> **Superseded (2026-10-17):** Kakureneko no longer uses ntfy. Notifications are native (macOS + the Kakureneko iPhone app over the user's private iCloud): see `docs/NATIVE-NOTIFICATIONS.md` and DECISIONS.md D11. This research is kept for history.

# 07: Phone notifications and two-way control

*Research date: 2026-10-12. Machine: macOS 26.6.2 (25G83), arm64, Xcode 26.6, Swift 6.3.3.*
*Scope: push notifications from the Lidless menu-bar app to the user's phone (iOS and Android), with optional phone-side buttons ("Keep awake 1h", "Sleep now", "Shut down"), using little or no infrastructure.*

**Confidence legend.**
- **[H]** high: verified in official docs or source code, or locally.
- **[M]** medium: official but indirect, or a strong secondary source.
- **[L]** low: inferred or unverified, so test before relying on it.

Each claim names its source: a URL, a file path, or "verified locally by …".

**Safety note.** No message was sent to any real service during this research. All curl and Swift examples ran only against a local mock or echo server on `127.0.0.1`. The scripts are in `/private/tmp/claude-501/-Users-tomasnguyen-Developer/3514aa88-efa8-4a60-97d7-2878eed849d4/scratchpad/research-snippets/` (`curl_examples.sh`, `echo_server.py`, `mock_ntfy.py`, `NtfyClient.swift`, `Watchdog.swift`, `LidlessNotifySketch.swift`).

---

## 0. TL;DR

1. **Default provider: ntfy, on the public `ntfy.sh` server, with self-hosting as an option.** [H]
   - It needs no account and no API key, and it is free: 250 messages/day per IP when anonymous.
   - It has native iOS and Android apps.
   - It is the only zero-infrastructure option that supports **two-way control from the notification itself**. An `http` action button makes the phone POST a command to a *second* ntfy topic, and the Mac subscribes to that topic with a long-lived `GET /<cmdTopic>/json?since=<lastId>` stream.
2. **iOS caveats for ntfy, verified in the `ntfy-ios` source:**
   - Only `view` and `http` action types work on iOS.
   - Tapping an action **brings the ntfy app to the foreground**, which requires unlocking the phone, and then sends the request.
   - Markdown, icons, and notification update/delete are not supported on iOS.
   - The app registers **no URL scheme**, so a `ntfy://` QR code cannot subscribe an iPhone. The user has to enter the bare topic name, which must match `^[-_A-Za-z0-9]{1,64}$`.
   - Android does support `ntfy://ntfy.sh/<topic>?display=Lidless` deep links.
3. **Secondary providers, behind a `NotificationProvider` protocol:**
   - **Telegram bot** (v1). Free, iOS + Android + desktop. It has the best general two-way UX: inline buttons via `callback_query`, plus text commands like `/status` and `/awake 2h`, all through `getUpdates` long polling from the Mac with no server. Setup friction is a BotFather token.
   - **Pushover** (v1). One-way. Very reliable, US$4.99 one-time per platform, has emergency priority and iOS Critical Alerts, and supports E2E encryption.
   - **Later:** Bark (iOS only, E2E, one-way), Home Assistant (excellent background actions for people who already run HA), a generic webhook (Discord, Slack, custom), and email as a fallback.
4. **Not recommended:**
   - **iMessage-to-self via AppleScript.** The dictionary still exists on Messages 26.0, but it needs Messages.app running (which conflicts with "pause all other apps") and an Automation TCC prompt. Whether a self-addressed iMessage alerts the iPhone is unverified.
   - **A native companion iOS app (APNs or CloudKit).** It requires the paid Apple Developer Program; verified in Apple's capability table.
5. **Command security.** The Mac **mints** each command, with an HMAC-SHA256 signature, a single-use nonce, an expiry, and an agent-"state version". The minted command is embedded in the button body. The Mac executes a command only if the signature is valid, the nonce is unused and unexpired, and (for sleep or shutdown) no agent has become busy since the command was minted. Knowing the command topic alone therefore lets nobody shut the Mac down.
6. **Delivery while the lid is closed.**
   - If Lidless keeps the system awake, networking works normally. Once the system really sleeps, no app code runs.
   - Use a **persistent outbox**: retries with exponential backoff and full jitter, a TTL per message kind, coalescing, and gating on `NWPathMonitor`.
   - **Flush before Lidless triggers sleep or shutdown.** The system waits at most **30 s** for a `kIOMessageSystemWillSleep` acknowledgement (verified in `IOPMLib.h`).
   - Use an **app-level idle watchdog** on the subscription stream. Verified locally: `URLSession.bytes(for:)` did **not** time out during 12 s of mid-stream silence, even with request timeouts of 3 s.

---

## 1. What Lidless needs to send and receive

| Event (Lidless → phone) | Urgency | Two-way buttons |
|---|---|---|
| Agent session finished (Claude Code, Codex, Gemini CLI, Cursor, Copilot, aider…) | normal | none (or "Keep awake 1h") |
| Agent needs input or permission | high | "Keep awake 1h", "Sleep now" |
| All agents idle, Mac sleeps or shuts down in N min | normal | "Keep awake 1h", "Sleep now", "Shut down" |
| Mac is now asleep or shutting down | low | none |
| Lidless warning (battery critical, cannot hold the assertion, thermal) | high | "Sleep now" |

Phone → Mac commands are `keepawake(seconds)`, `sleep`, `shutdown`, and optionally `status`, which is a natural fit for Telegram.

Constraints:
- No paid Apple Developer ID.
- Not sandboxed, ad-hoc signed.
- Agent-agnostic.
- It must work while the lid is closed and the user is away from the LAN.

---

## 2. Comparison matrix

| Option | iOS | Android | Cost | Setup friction | Latency / reliability | Privacy | Two-way |
|---|---|---|---|---|---|---|---|
| **ntfy (ntfy.sh)** | ✓ app (v1.7.0) | ✓ app (v1.25.2) | Free anon (250 msg/day per visitor); paid tiers optional | **Lowest**: install app, enter topic | Seconds via FCM→APNs [M] | Topic name = password. Content passes ntfy.sh + Google FCM (+ APNs alert truncated to 100 chars) unless the topic is protected [H] | **Yes**: `http` action → command topic → Mac stream [H] |
| ntfy self-hosted | ✓ (needs `upstream-base-url: https://ntfy.sh`) | ✓ | VPS cost | High | Same | Only a message ID crosses ntfy.sh/FCM/APNs [H] | Yes (plus per-user ACLs) |
| **Telegram bot** | ✓ | ✓ (+ desktop) | Free | Medium: BotFather token + tap a `t.me` link | ~1 s [M] | Telegram cloud chat, not E2E [M] | **Yes**: `callback_query` + text commands via `getUpdates` [H] |
| **Pushover** | ✓ | ✓ (+ desktop) | US$4.99 one-time per platform after a 30-day trial; 10k msg/month [H] | Medium: account + user key + app token | Very reliable; emergency priority repeats [H] | Optional E2E (`encrypted=1`) [H] | No buttons. Only emergency acknowledgement receipts [H] |
| Bark | ✓ only | ✗ | Free (self-hostable server) | Low | APNs-direct [M] | Optional E2E `ciphertext` (AES) [H] | No: tap URL only [H] |
| Home Assistant companion | ✓ | ✓ | Free (remote access via Nabu Casa or VPN) | High unless HA already runs | Good | Your HA instance | **Yes**: actions fire `mobile_app_notification_action`. iOS can run them in the background [H] |
| Discord webhook | ✓ (Discord app) | ✓ | Free | Low-medium | Good | Discord sees content | No (webhook components are ignored for non-app-owned webhooks) [H] |
| Slack webhook | ✓ | ✓ | Free tier | Medium | Good | Slack sees content | Only via a Slack app + Socket Mode (heavy) [H] |
| Gotify | ✗ official (3rd-party iGotify) | ✓ | Self-host | High | WebSocket on Android | Self-hosted | Minimal |
| iMessage via AppleScript | ✓ | ✗ | Free | Medium (Automation TCC) | Unverified for self-messages [L] | Apple E2E | No |
| Native iOS companion (APNs, CloudKit) | ✓ | ✗ | **US$99/yr ADP required** [H] | Very high | Best | Best | Yes |
| Email (SMTP) | ✓ | ✓ | Free | Medium (app password) | Seconds to minutes | Mail provider | No |

---

## 3. ntfy, in depth (recommended default)

### 3.1 Versions (as of 2026-10-12)
- **Server.** The docs' "Current stable releases" table lists **v2.30.0, released Oct 12, 2026** (experimental clustering, SMTP LOGIN auth). The newest tag visible via the GitHub API at research time was **v2.29.0 (2026-10-07)**. [H] (https://docs.ntfy.sh/releases/; verified locally by `gh api repos/binwiederhier/ntfy/releases`)
- **iOS app.** v1.7.0 (May 30, 2026) added images and attachments. **v1.8.0 is unreleased**: priority 5 becomes Critical Alerts, and poll-request matching for protected topics is improved. The main branch has `MARKETING_VERSION = 1.8.0` and `IPHONEOS_DEPLOYMENT_TARGET = 15.0`. [H] (docs/releases.md "Not released yet"; `ntfy.xcodeproj/project.pbxproj`)
- **Android app.** v1.25.2 (July 23, 2026). Minimum Android 8 since v1.20.0. [H]
- **Notable server changes:**
  - v2.16.0 (Jan 2026): update and delete notifications via sequence IDs.
  - v2.23.0: per-visitor topic-creation rate limit.
  - v2.28.0 (Aug 2026): titles capped at 1 KB and tags at 512 B (HTTP 400 beyond that); poll replays capped at 10 MB per topic; HTTP 429 (code 42905) when the poll bandwidth budget is exceeded. [H] (https://docs.ntfy.sh/releases/)

### 3.2 Publishing

**Topic names.** `[-_A-Za-z0-9]{1,64}`. "The topic is essentially a password." Topics are created on the fly. [H] (https://docs.ntfy.sh/publish/#picking-a-topic)

**Header style.** Send `POST` or `PUT https://ntfy.sh/<topic>` with the body as the message. Headers, with their aliases, are case-insensitive. Query parameters must be lowercase. [H] (https://docs.ntfy.sh/publish/#list-of-all-parameters)

| Field | Header (aliases) | Notes |
|---|---|---|
| message | body, or `X-Message` (`Message`, `m`) | over 4,096 bytes or non-UTF-8 → sent as an attachment |
| title | `X-Title` (`Title`, `t`) | ≤ 1 KB (400 if larger) |
| priority | `X-Priority` (`Priority`, `prio`, `p`) | `1`/`min`, `2`/`low`, `3`/`default`, `4`/`high`, `5`/`max`/`urgent` |
| tags | `X-Tags` (`Tags`, `Tag`, `ta`) | comma-separated; emoji shortcodes render as emoji; ≤ 512 B total |
| click | `X-Click` (`Click`) | URL opened on tap |
| actions | `X-Actions` (`Actions`, `Action`) | up to **3** (server constant `actionsMax = 3`, `action/action.go`) |
| markdown | `X-Markdown` (`Markdown`, `md`) = `yes`, or `Content-Type: text/markdown` | **Android and web only** |
| icon | `X-Icon` (`Icon`) | JPEG/PNG, **Android only** |
| attach / filename | `X-Attach` (`Attach`, `a`), `X-Filename` | ntfy.sh: 2 MB per file, 20 MB per visitor, expire after 3 h |
| delay | `X-Delay` (`Delay`, `X-At`, `At`, `X-In`, `In`) | 10 s minimum, 3 d maximum |
| sequence id | `X-Sequence-ID` (`Sequence-ID`, `SID`), or path `/<topic>/<sid>` | update / clear / delete (**Android and web only**) |
| cache | `X-Cache: no` | not stored, so `since=` cannot replay it |
| firebase | `X-Firebase: no` | **disables FCM, so no iOS push and slower Android delivery** |
| email / call | `X-Email`, `X-Call` | ntfy.sh: logged-in users only (call needs Pro) |
| auth | `Authorization: Bearer tk_…` / `Basic …` / `?auth=<base64 header value without '='>` | |

**JSON style (use this in the app).** `POST https://ntfy.sh/`, to the **root** URL and not the topic URL, with `Content-Type: application/json`. Fields: `topic` (required), `message`, `title`, `tags` (array), `priority` (int), `actions` (array), `click`, `attach`, `markdown` (bool), `icon`, `filename`, `delay`, `timezone`, `email`, `call`, `sequence_id`. An empty message becomes `"triggered"`. [H] (https://docs.ntfy.sh/publish/#publish-as-json)

**Response.** JSON containing `id`, `time`, `expires`, `event: "message"`, `topic`, and so on. Lidless should treat a 200 without an `id` as failure, to catch captive-portal HTML. [M]

**Update, clear, and delete.** Publish again with the same sequence ID to replace a notification. Clear with `PUT /<topic>/<sid>/clear` (alias `/read`), and delete with `DELETE /<topic>/<sid>`. Since v2.25.0 there are GET variants: `GET /<topic>/<sid>/clear` and `GET /<topic>/<sid>/delete`. **Not supported by the iOS app.** [H]

**GET webhooks.** `GET /<topic>/publish`, with aliases `/send` and `/trigger`, publishes with parameters in the query string. [H] **Do not use GET-triggered commands.** Link previewers and prefetchers fire GETs; see §15.

### 3.3 Action buttons

Per the docs, `view` and `http` work on Android, iOS, and web. `broadcast` is Android only. `copy` is Android and web only. [H] (https://docs.ntfy.sh/publish/#action-buttons)

**Short header format.** Actions are separated by `;` and fields by `,`:
```
http, <label>, <url>[, method=<METHOD>][, headers.<Name>=<value>][, body=<body>][, clear=true]
```
- Values that contain commas or quotes must be wrapped in `"…"` or `'…'`. Single and double quotes are both accepted (verified in `action/action.go` `parseSection` and `parseQuotedValue`). [H]
- The default method is POST.
- `body` is rejected with GET or HEAD (verified in `action.go`).
- `clear=true` dismisses the notification only if the request succeeds. [H]

**JSON format.**
```json
{"action":"http","label":"Sleep now","url":"https://ntfy.sh/<cmdTopic>","method":"POST","headers":{"X-Firebase":"no"},"body":"<string>","clear":true}
```

**iOS behaviour, from the `ntfy-ios` main-branch source.**
- `Actions.swift` filters to `supportedActions = ["view", "http"]`. Other types are silently dropped. [H]
- `NotificationContent.swift` registers each action as `UNNotificationAction(identifier:, title:, options: [.foreground])`. **Tapping an action launches or foregrounds the ntfy app** (the device must be unlocked). `ActionExecutor.http` then sends the request with `URLSession.shared`, defaulting to POST and attaching the headers and body. There is **no `clear` handling and no success or failure UI on iOS**. [H]
- Android executes `http` actions without opening the app and honours `clear`. [M] (docs + behaviour described in the docs)

### 3.4 Priority mapping on phones

Verified in `ntfy-ios` `NotificationContent.swift`:

| ntfy priority | iOS `interruptionLevel` | Android (docs) |
|---|---|---|
| 1 min | `.passive`, relevance 0 | no sound, collapsed under "Other notifications" |
| 2 low | `.passive`, relevance 0.25 | no sound or vibration |
| 3 default | `.active` | default sound and vibration |
| 4 high | `.timeSensitive` | long vibration, pop-over (FCM `priority: high`) |
| 5 max | `.critical` **only in v1.8.0+ if the user enabled Critical Alerts**, otherwise `.timeSensitive` | very long vibration, pop-over |

Caveat [L/M]: the ntfy iOS entitlements file in the repo lists `aps-environment`, `critical-alerts`, and app groups, but **not** `com.apple.developer.usernotifications.time-sensitive`. Priority 4 may therefore not break through Focus on iOS. Test it on a device.

### 3.5 How delivery to iPhones works (privacy)

Source: `server/server_firebase.go` [H].

- **ntfy.sh, public (unprotected) topic.** Every message goes to Firebase topic = `<topic>`.
  - Android receives a data message with **all fields**: title, message, actions, and so on.
  - iOS receives an APNs **alert** (`mutable-content: 1`) whose body is truncated to **100 characters**, plus all fields as custom data. The Notification Service Extension rebuilds the notification from that data.
  - **Google FCM and Apple APNs both carry the content.**
- **ntfy.sh, protected or reserved topic** (anonymous read denied). The server sends only a `poll_request` (`"message": "New message"`, `poll_id`). The app then fetches the real content with the user's credentials. iOS 1.8.0 (unreleased) "improves poll request subscription matching for protected topics", which suggests rough edges in 1.7.0. [H]
- **Self-hosted with `upstream-base-url: "https://ntfy.sh"`.** Each message makes the server publish a `poll_request` to ntfy.sh, on a topic named with the SHA-256 of the topic URL, containing only the message ID (`X-Poll-ID`). The iPhone's NSE then polls your server, which **must be reachable from the phone**. `upstream-access-token` is needed only if you exceed upstream limits. **Without `upstream-base-url`, iOS delivery can take hours.** [H] (https://docs.ntfy.sh/config/#ios-instant-notifications; `server/server.yml`)
- **Never send `X-Firebase: no` on notify-topic messages.** It would disable the iOS push entirely. Use it only on command-topic messages, which no phone needs. [H] (code path)

### 3.6 Caching, retention, and `since=`
- The default `cache-duration` is **12h**: in memory unless `cache-file` or `database-url` is set. Attachments expire after 3 h. [H] (`server.yml`, config docs)
- **Subscribe endpoints:**
  - `GET /<topic>/json` (NDJSON, `Content-Type: application/x-ndjson`, recommended)
  - `/sse`
  - `/raw`
  - `/ws` (WebSocket, same JSON objects)
  - Several topics at once: `/<t1>,<t2>/json`. [H] (https://docs.ntfy.sh/subscribe/api/)
- **Event types:** `open`, `keepalive`, `message`, `message_delete`, `message_clear`, `poll_request`.
- **Message fields:** `id`, `time`, `expires`, `event`, `topic`, `message`, `title`, `tags`, `priority`, `click`, `actions`, `attachment`, `sequence_id`. [H]
- **`keepalive-interval` defaults to 45s.** The Android app hard-codes a 77 s timeout. [H] (`server.yml`)
- **`since=` accepts:**
  - a duration (`10m`)
  - a Unix timestamp
  - a message ID
  - `all`
  - `latest` (only with `poll=1`)

  `poll=1` returns the cache and closes; it defaults to `since=all`. [H]
- **Gotcha, verified in `message/cache.go` `resolveMessageRowID`.** If `since=<id>` names an unknown or expired message, the server deliberately resolves it to row 0 and **replays the topic's whole retained history** (up to 12 h). The command handler must therefore dedupe nonces and enforce expiry. [H]
- Replays are capped at 10 MB per topic (header `X-Messages-Truncated: 1`). Exceeding the daily bandwidth returns HTTP 429, code 42905. [H]

### 3.7 Rate limits and pricing

**Defaults (self-hosted):**
- `visitor-request-limit-burst: 60`, `visitor-request-limit-replenish: "5s"`
- `visitor-subscription-limit: 30` open connections
- email 16 burst, then 1/h
- attachments 15 MB per file, 100 MB per visitor
- daily bandwidth 500 MB
- `global-topic-limit: 15000`

Visitors are keyed by IPv4 /32 or IPv6 /64. [H] (config docs, `server.yml`)

**ntfy.sh, anonymous:**
- 250 messages/day
- 5 emails/day for free users, and only when logged in
- 2 MB per attachment, 20 MB total
- 200 MB/day bandwidth

Repeated violations can temporarily ban the IP; check `am-i-banned.ntfy.sh`. [H] (https://docs.ntfy.sh/publish/#limitations)

**ntfy.sh paid tiers** (shown as monthly price → annual-billing monthly equivalent) [M] (https://ntfy.sh/):
- Supporter **$6 → $5/mo**: 2,500 msg/day, 3 reserved topics.
- Pro **$12 → $10/mo**: 20,000 msg/day, 10 reserved topics.
- Business **$25 → $20/mo**: 50,000 msg/day, 50 reserved topics.

**Terms** (last updated Jan 26, 2026): topics are public; access control needs a paid plan; FCM is a listed third party; self-hosting is "strongly recommended" for sensitive data. [H] (https://docs.ntfy.sh/terms/)

**Lidless budget.** Realistic usage is under 50 messages/day. The subscription is one long-lived request plus reconnects, and reconnects must back off to at least 5 s to stay within the 1 req / 5 s replenish rate.

### 3.8 Auth and access tokens
- Tokens look like `tk_…`, 32 chars including the prefix. Send them as `Authorization: Bearer tk_…`, or as `-u :tk_…` (basic auth with an empty user), or in `?auth=` (the base64 of the header value with trailing `=` removed). [H]
- **On ntfy.sh, a token grants full account access** apart from changing the password or deleting the account. Do not embed an ntfy.sh account token in an action button. [H] (config docs)
- **Self-hosted ACL example** [H] (config docs; CLI syntax from `docs/config.md`):
  ```
  ntfy user add lidless-mac
  ntfy user add lidless-phone
  ntfy access lidless-mac   'lidless_*'   rw
  ntfy access lidless-phone 'lidless_n_*' ro      # phone reads notifications
  ntfy access lidless-phone 'lidless_c_*' wo      # phone may only write commands
  ntfy token add lidless-mac                       # -> tk_... for the Mac
  ```
  Server config:
  ```yaml
  base-url: "https://ntfy.example.com"
  listen-http: ":2586"
  behind-proxy: true
  cache-file: "/var/cache/ntfy/cache.db"
  cache-duration: "12h"
  auth-file: "/var/lib/ntfy/user.db"
  auth-default-access: "deny-all"
  upstream-base-url: "https://ntfy.sh"   # REQUIRED for timely iOS delivery
  ```

### 3.9 The Mac subscribing to the command topic
- **Endpoint.** Use `GET https://ntfy.sh/<cmdTopic>/json?since=<lastMessageId>` (first run: `since=<now-120s unix>`) as a streaming NDJSON response read with `URLSession.bytes(for:)` and `.lines`. JSON/NDJSON is the officially recommended endpoint. SSE adds no value in Swift. WebSocket (`wss://…/<topic>/ws`) works too and gives you `sendPing`, but it is more code. [H] (docs) / [M] (recommendation)
- **Liveness, verified locally** by `NtfyClient.swift` against `mock_ntfy.py`. With `URLSessionConfiguration.timeoutIntervalForRequest = 3` and `URLRequest.timeoutInterval = 3`, a stream that went silent for 12 s mid-response **did not error**; it "ended cleanly" when the server closed it. **Do not rely on URLSession timeouts as a keepalive watchdog.** [H for this setup]
- **Watchdog, verified locally** by `Watchdog.swift`. Pair the reading task in a `withThrowingTaskGroup` with a second task that throws when no line, keepalive included, has arrived for longer than a limit. It fired 3.1 s after the last line with a 3 s limit, and cancellation ended the `AsyncBytes` loop promptly. For production use **100 s** (2 × 45 s keepalive + slack). [H]
- **Reconnect policy:**
  - Exponential backoff with full jitter: 5 s minimum, 300 s maximum.
  - Reset after a successful 200.
  - On 429, wait at least 60 s.
  - Persist `lastID` (UserDefaults) after each `message` event.
  - Also reconnect immediately on `NSWorkspace.didWakeNotification` and when `NWPathMonitor` reports `.satisfied`.
- **Fallback.** If streaming keeps failing, for example behind a proxy that buffers chunked responses, switch to polling `GET /<cmdTopic>/json?poll=1&since=<lastId>` every 30–60 s. [M]
- **Verified locally end to end against the mock:** minted command → simulated phone POST → the stream delivers it → it is accepted once. A replay of the same message is dropped (`drop replay`), and an unsigned or forged body is dropped (`drop bad-sig`). [H] (NtfyClient run log)

### 3.10 Onboarding facts
- **Android deep link:** `ntfy://<host>/<topic>`, with optional `?display=<name>` and `?secure=false`. `https://<host>/<topic>/subscribe` deep links are **not** supported on Android. [H] (https://docs.ntfy.sh/subscribe/phone/)
- **iOS:**
  - The app's `Info.plist` has **no `CFBundleURLTypes`**, and no `onOpenURL` exists in the sources. There is no QR scanner.
  - `SubscriptionAddView` accepts only a bare topic matching `^[-_A-Za-z0-9]{1,64}$`; a URL is rejected. "Use another server" takes a base URL.
  - So for an iPhone, Lidless must transfer the *topic string*. [H] (`ntfy/Info.plist`, `SubscriptionAddView.swift`)
- App Store: `https://apps.apple.com/us/app/ntfy/id1625396347`. [H]

---

## 4. Pushover
- **Send.** `POST https://api.pushover.net/1/messages.json`.
  - Required: `token`, `user`, `message`.
  - Optional: `title`, `device`, `html`, `monospace`, `priority`, `sound`, `timestamp`, `ttl`, `url`, `url_title`, `attachment`, `attachment_base64` + `attachment_type`, `encrypted`.
  - Limits: `message` ≤ 1024 chars, `title` ≤ 250, `url` ≤ 512, `url_title` ≤ 100; one attachment ≤ 5,242,880 bytes. [H] (https://pushover.net/api)
- **Priorities.**
  - `-2`: no notification.
  - `-1`: quiet.
  - `0`: normal.
  - `1`: high, bypasses quiet hours.
  - `2`: emergency. Requires `retry` (≥ 30 s) and `expire` (≤ 10800 s), with at most 50 retries. Optional `callback` (a public URL) and `tags`. Returns a `receipt`.
- **Receipts.** Poll `GET /1/receipts/{receipt}.json?token=…` no more than every 5 s, for up to a week. Fields: `acknowledged`, `acknowledged_at`, `acknowledged_by`, `acknowledged_by_device`, `last_delivered_at`, `expired`, `expires_at`, `called_back`, `called_back_at`. Cancel with `POST /1/receipts/{receipt}/cancel.json` or `POST /1/receipts/cancel_by_tag/{tag}.json`. [H] (https://pushover.net/api/receipts)
- **Quota.** 10,000 messages/month per **user account** across all of its apps (Teams: 25,000), resetting at 00:00 Central Time on the 1st. Headers `X-Limit-App-Limit`, `X-Limit-App-Remaining`, `X-Limit-App-Reset`; or `GET /1/apps/limits.json?token=…`. [H]
- **Retry rules.**
  - On 4xx, never retry the same request; many 4xx in a short time gets the IP blocked.
  - On 5xx or no response, retry no sooner than 5 s.
  - Use at most 2 concurrent connections, with keep-alive. [H]
- **Validate a user.** `POST /1/users/validate.json` with `token`, `user`, and optionally `device`. [H]
- **E2E encryption.** With `encrypted=1`, `message`, `title`, `url`, and `url_title` are each encrypted as: gzip → AES-256-CBC (PKCS7, random 16-byte IV) → HMAC-SHA256 over IV + ciphertext → base64(IV ‖ ciphertext ‖ HMAC). The 64-hex-character key is entered in the iOS and Android apps. [H] (https://pushover.net/api)
- **iOS Critical Alerts.** Supported for high and emergency priority since app 3.5.2 (2020). Opt-in, with a separate volume setting. [M] (https://blog.pushover.net/posts/2020/2/ios-critical-alerts)
- **Cost.** US$4.99 one-time per platform (iOS, Android, or Desktop) after a 30-day trial. [H] (https://pushover.net/pricing)
- **Two-way.** No action buttons. The only inbound signal is an emergency-priority **acknowledgement**, which Lidless can learn by polling receipts or via `callback`, which needs a public URL. The `url` field can carry a custom scheme. **Verdict: one-way provider.**

---

## 5. Telegram Bot API (Bot API 10.3, Aug 24, 2026)
Source: https://core.telegram.org/bots/api, downloaded and parsed locally. [H]

- **Requests** go to `https://api.telegram.org/bot<token>/<METHOD>`. GET and POST are both accepted, with parameters as a query string, `x-www-form-urlencoded`, JSON, or multipart. Every response carries `ok`. On error it also carries `description`, `error_code`, and optionally `parameters.retry_after`. [H]
- **getUpdates** (long polling from the Mac):
  - `offset`: last `update_id` + 1. An update is confirmed once you call with a higher offset.
  - `limit`: 1–100.
  - `timeout`: seconds; use 50. Short polling is for testing only.
  - `allowed_updates`: `["message","callback_query"]`.
  - Updates are **kept at most 24 hours**.
  - It does **not work while a webhook is set**; call `deleteWebhook` first.
  - Only one poller per bot token: a second Lidless instance gets HTTP 409 Conflict. [H] (409 behaviour [M])
- **sendMessage:** `chat_id`, `text` (1–4096 chars), `parse_mode` (`HTML` or `MarkdownV2`), `entities`, `link_preview_options`, **`disable_notification`** (silent), `protect_content`, `reply_parameters`, `reply_markup`. [H]
- **InlineKeyboardButton:**
  - `text`
  - `callback_data` (**1–64 bytes**)
  - `url`
  - new optional `style`: `"danger"`, `"success"` or `"primary"`
  - Exactly one type field per button. [H]
- **CallbackQuery:** `id`, `from` (User), `message`, `inline_message_id`, `chat_instance`, `data`, `game_short_name`. You **must** call `answerCallbackQuery(callback_query_id, text ≤ 200 chars, show_alert, url, cache_time)`, or the client shows a progress spinner. [H]
- **Edit after an action** with `editMessageReplyMarkup` (empty `inline_keyboard`) and/or `editMessageText`.
- **Rate limits** [H] (https://core.telegram.org/bots/faq):
  - About 1 msg/s per chat; bursts are allowed, but sustained excess returns 429.
  - 20 msg/min in groups.
  - About 30 msg/s overall.
- **Deep link for pairing.** `https://t.me/<bot_username>?start=<param>` sends `/start <param>`. The parameter allows `A-Z a-z 0-9 _ -` and is ≤ 64 chars. [H] (https://core.telegram.org/bots/features#deep-linking)
- **Setup UX:**
  1. In Telegram, the user opens `@BotFather` and sends `/newbot` to get a token.
  2. The user pastes the token into Lidless. Lidless calls `getMe` to validate it, then `deleteWebhook`.
  3. Lidless shows a QR code and link to `t.me/<bot>?start=<pairingCode>`.
  4. The user taps **Start**.
  5. Lidless's `getUpdates` sees `message.text == "/start <pairingCode>"` and stores `chat.id` and `from.id`.
  6. Lidless sends a confirmation.

  Afterwards, **ignore every update whose `from.id` differs from the paired user.** Anyone can message a bot.
- **Managed bots** (`KeyboardButtonRequestManagedBot`, `getManagedBotToken`, `managed_bot` updates) could remove the BotFather step. But they need an always-on "manager" bot holding a token, which is infrastructure, so they are not suitable for v1. [H] (API docs)
- **UX caveat [M].** Telegram notifications do not show inline keyboards, so the user opens the chat (one tap) and then taps a button. In return, Telegram allows **free-form commands at any time** (`/status`, `/sleep`, `/awake 2h`). This is the richest two-way UX.
- **Privacy [M].** Bot chats are Telegram cloud chats, not E2E.

---

## 6. Bark (iOS only)
Source: https://github.com/Finb/Bark, `docs/en-us/*.md`; the repo was pushed 2026-10-12. [H]

- **URL forms:**
  - `GET/POST https://api.day.app/:key/:body`
  - `/:key/:title/:body`
  - `/:key/:title/:subtitle/:body`
  - `POST /push` with JSON including `device_key`
  - Batch with `device_keys` (≤ 10 on the public server).
- **Params:**
  - `title`, `subtitle`, `body`
  - `markdown` (ignores `body`)
  - `group`, `icon` (iOS 15+), `image`, `badge`
  - **`level`**: `active`, `timeSensitive`, `passive`, or `critical` (needs critical permission; `volume` 0–10)
  - `call=1` (rings for 30 s), `sound`
  - `copy`, `url` (tap opens the URL, a scheme, or a universal link), `action` (`alert` or `none`)
  - `ciphertext` + `iv` (E2E)
  - `isArchive`, `ttl`
  - **`id`** (replace; a string; Bark v1.5.2+ and bark-server v2.2.5+)
  - `delete=1` (silent push; needs Background App Refresh)
- **E2E.** AES; the docs show `openssl enc -aes-128-cbc` over the JSON payload. "The content is invisible to the Bark server and Apple APNs." [H]
- **Privacy.** The public server operator can see request logs, so self-host `bark-server` or use encryption. [H] (`docs/en-us/privacy.md`)
- **No action buttons; one-way.** It also ships an MCP endpoint (`https://api.day.app/mcp/{key}`), which is interesting but not relevant here.

---

## 7. Discord and Slack incoming webhooks
- **Discord.** `POST https://discord.com/api/webhooks/{id}/{token}?wait=true`.
  - JSON fields: `content` (≤ 2000), `username`, `avatar_url`, `tts`, `embeds` (≤ 10), `allowed_mentions`, `components`, `flags` (`SUPPRESS_EMBEDS`, `SUPPRESS_NOTIFICATIONS`, `IS_COMPONENTS_V2`).
  - **Interactive components are not allowed for non-application-owned webhooks**, and `components` is ignored unless `with_components=true`. [H] (https://docs.discord.com/developers/resources/webhook)
  - To make sure the phone rings, include `<@USER_ID>` with `allowed_mentions: {"users": ["USER_ID"]}`, or set the channel to "All messages". [M]
  - Two-way would need a bot on the Gateway WebSocket; not v1.
- **Slack.** `POST https://hooks.slack.com/services/T…/B…/…` with `{"text": …, "blocks": […]}`.
  - Missing `text` returns `no_text`.
  - Other errors: `invalid_payload`, `action_prohibited`, `channel_is_archived`, `no_service`, `no_active_hooks`, `team_disabled`, `too_many_attachments`.
  - You cannot override channel, username, or icon, and you cannot delete a message.
  - Slack auto-revokes leaked webhook URLs. [H] (https://docs.slack.dev/messaging/sending-messages-using-incoming-webhooks/)
  - Two-way is possible **without a public URL** via **Socket Mode**: an app-level `xapp-` token calls `apps.connections.open` to get a WebSocket URL, and each `envelope_id` must be acked. Up to 10 connections. Not allowed in the public Slack Marketplace. [H] (https://docs.slack.dev/apis/events-api/using-socket-mode/) Setup is heavy, so not v1.
- **Recommendation.** Offer both as one-way "Webhook" providers with a JSON template.

## 8. Gotify
- **Push.** `POST https://<server>/message` with `X-Gotify-Key: <apptoken>`. Fields: `message` (required), `title`, `priority`, `extras`. [H] (https://gotify.net/docs/pushmsg)
- **Extras:**
  - `client::display.contentType` = `text/markdown`
  - `client::notification.click.url`, `bigImageUrl`
  - `android::action.onReceive.intentUrl`
  - [H] (https://gotify.net/docs/msgextras)
- **Platforms.** The official client is Android only (WebSocket). The only iOS option is the third-party "iGotify" (v1.5.5, 2024), which needs a companion component. [M] Low priority.

## 9. Home Assistant companion app
- **Send.** `POST <HA>/api/services/notify/mobile_app_<device>` with `Authorization: Bearer <long-lived token>`. [H] (https://developers.home-assistant.io/docs/api/rest/)
- **Payload keys** [H] (https://companion.home-assistant.io/docs/notifications/notifications-basic/):
  - `title`, `message`
  - `data.tag` (replace; `message: "clear_notification"` clears it)
  - `data.group`
  - `data.url` (iOS) or `data.clickAction` (Android)
  - `data.subtitle` (iOS) or `data.subject` (Android)
  - `data.push.interruption-level`: `passive`, `active`, `time-sensitive`, or `critical`
  - `data.push.sound`
- **Actions** [H] (https://companion.home-assistant.io/docs/notifications/actionable-notifications/):
  - Each action has `action` (an id), `title`, `uri`, `behavior: textInput`, and `authenticationRequired`.
  - iOS-only keys: `activationMode` (`background` is the default and **fires without opening the app**), `destructive`, and `icon: "sfsymbols:…"`.
  - Up to 3 actions on Android and about 10 on iOS.
  - A tap fires the event `mobile_app_notification_action` with `data.action`, `reply_text`, and (iOS) `action_data`.
- **Mac receives commands** via the HA WebSocket API at `ws(s)://<HA>/api/websocket`:
  1. `{"type":"auth","access_token":…}`
  2. `{"id":1,"type":"subscribe_events","event_type":"mobile_app_notification_action"}`

  [M] (format from HA WebSocket API docs, not fetched this session)
- **Good fit** for users who already run HA with remote access (Nabu Casa or VPN). This is the best iOS action UX: the action runs in the background, with no app launch.

## 10. iMessage-to-self via Messages.app AppleScript
- **The dictionary still exists on macOS 26.6.2** (Messages 26.0). It has `send` ("to a participant or to a chat"), the classes `participant` (`id`, `handle`, `account`), `account` (`service type`, `enabled`, `connection status`), and `chat`, and the service types `iMessage`, `SMS`, and **`RCS`**. [H] (verified locally by `sdef /System/Applications/Messages.app`, read-only)
- **Script:**
  ```applescript
  on run {targetHandle, msg}
    tell application "Messages"
      set svc to 1st account whose service type = iMessage
      send msg to participant targetHandle of svc
    end tell
  end run
  ```
- **Requirements:**
  - Automation (Apple Events) TCC consent for Lidless → Messages, plus `NSAppleEventsUsageDescription`.
  - The `com.apple.security.automation.apple-events` entitlement if the hardened runtime is enabled. [M]
  - **Messages.app must be running and not paused.** That conflicts with Lidless's "pause other apps" unless Messages is allow-listed. A stopped process makes the Apple Event hang until the default timeout (about 2 min). [M]
- **Unknowns [L].** Whether a message sent to *your own* handle alerts the iPhone; reports are inconsistent and no source confirms it. The `participant` lookup is reported to return the wrong participant at times. There are no buttons. **Do not use it as a default.** At most, offer it as an experimental "iMessage (Apple-only)" provider after a device test.

## 11. Apple-native options
- **Companion iOS app with APNs, CloudKit, or Time-Sensitive.** Apple's capability table lists **Push notifications, iCloud: CloudKit, Time Sensitive Notifications, Communication Notifications, and Push to Talk as ADP or ADEP only**. They are **not** available to free "Apple Developer" accounts. Background modes are available to free accounts. [H] (verified locally by parsing https://developer.apple.com/help/account/reference/supported-capabilities-ios)
  - Free-provisioned iOS builds also expire after 7 days. [M]
  - **Requires paid ADP, so it is out of scope for v1.**
  - Future paid path: an iOS companion app plus a CloudKit private-DB `CKQuerySubscription` with `notificationInfo.alertBody`. The Mac writes a record, Apple delivers a visible push, and no server is needed. Or APNs token auth (.p8) through a relay. **Never ship a .p8 inside a distributed Mac app.** [M]
- **Find My.** No messaging API. [H]
- **Shortcuts and Focus.** macOS Shortcuts has no "push to my iPhone" action.
  - iPhone personal automations can trigger on an incoming **Message** or **Email** from a sender or containing text, and run without asking. That could escalate a Lidless email or iMessage (for example, play a sound). Niche. [M]
  - Conversely, an iPhone Shortcut "Get Contents of URL" can POST a *standing* command to the ntfy command topic. This gives a home-screen "Keep my Mac awake" button; see §15 for standing tokens. [M]
- **Experimental: Reminders via EventKit.** The Mac creates an `EKReminder` with an `EKAlarm(absoluteDate: now + 60 s)` in the user's iCloud Reminders. iCloud syncs it, and the iPhone fires the alert. It needs no third party, but it needs Reminders full-access TCC, sync latency is uncertain, and there are no buttons. [L] Worth a 30-minute spike for Apple-only users who refuse third-party apps.
- **Claude Code Remote Control push.** Claude Code itself can push to the Claude mobile app. The `/config` toggles are "Push when Claude decides" and "Push when actions required"; this requires Claude Code ≥ 2.1.110 and the Claude app.
  - It skips pushes while you are focused on the connected terminal.
  - `CLAUDE_CLIENT_PRESENCE_FILE=<path>` suppresses pushes while the file exists.
  - [H] (https://code.claude.com/docs/en/remote-control)
  - It covers **Claude only**, which is why Lidless still needs its own channel. Lidless could manage the presence file (create it while the lid is open and the screen unlocked, delete it when the lid closes), but the user must set the env var themselves. Also offer "don't duplicate Claude's own pushes" as a toggle. [M]

## 12. Email (SMTP)
- Send with curl and an **app-specific password**:
  - iCloud (STARTTLS): `curl --ssl-reqd --url 'smtp://smtp.mail.me.com:587' --user 'me@icloud.com:<app-password>' --mail-from me@icloud.com --mail-rcpt me@icloud.com --upload-file mail.txt`
  - Gmail (implicit TLS): `smtps://smtp.gmail.com:465`
- One-way. Latency is seconds to minutes, and it is low-salience on a phone.
- ntfy.sh can also forward a message to email (`X-Email`), but only for logged-in users (5/day free). [H for ntfy; M for SMTP hosts]
- **Fallback only.**

## 13. Others considered
- **Pushcut** (iOS only). Notification actions can fire web requests and Shortcuts. The free tier is capped at 3 notifications, 2 background actions, and 1 action per notification; Pro is a subscription. [M] (App Store listing via search) Optional later.
- **ntfy Web Push** (PWA on iOS 16.4+). It works, but adds nothing over the native app. iOS web push has no action buttons [M]. Skip.
- **UnifiedPush** (Android only). Skip.
- **SMS** (Twilio, paid), **Signal** and **WhatsApp** (no simple bot API without business onboarding or unofficial clients). Skip.

---

## 14. Delivering from a Mac whose lid is closed

**What the OS does:**
- **If Lidless keeps the system awake** (assertion or `disablesleep`, per the other research reports), the lid only affects the display. Wi-Fi stays associated and normal sockets work. [M]
  - This is consistent with Apple DTS statements and widespread practice, but it was **not empirically tested on this machine** in this session, which could not change power settings. Validate it in the prototype.
- **If the system actually sleeps, no third-party code runs.** Apple DTS: the CPU is suspended. Dark wakes, such as Power Nap, may briefly give processes time, but that is opportunistic: possibly only on AC power, possibly only for some processes, and App Nap applies. `tcpkeepalive=1` and Power Nap serve Apple's own services. **Plan for zero delivery while asleep.** [M] (developer.apple.com/forums/thread/795461 and /thread/829104, via search summaries)
- **Sleep notification window.** `IORegisterForSystemPower` delivers `kIOMessageSystemWillSleep`. The caller must call `IOAllowPowerChange`; "if a caller does not acknowledge… the sleep will continue anyway after a **30 second timeout**". `kIOMessageCanSystemSleep` (idle sleep) can be vetoed with `IOCancelPowerChange`. [H] (verified locally in `$(xcrun --show-sdk-path)/…/IOKit.framework/Headers/pwr_mgt/IOPMLib.h`)
  - Use about 5–8 s of that window to flush a "Mac is going to sleep" notification, then acknowledge.
- **App Nap.** As an `LSUIElement` menu-bar app, Lidless can be App-Napped, which delays timers and reconnects. Hold `ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Agent monitoring")`.
  - Note `NSActivityUserInitiated` **includes** `NSActivityIdleSystemSleepDisabled`, while `…AllowingIdleSystemSleep` excludes it. The sleep policy stays owned by the power module.
  - [H] (verified locally in `NSProcessInfo.h`: `NSActivityUserInitiated = (0x00FFFFFFULL | NSActivityIdleSystemSleepDisabled)`)

**Network failure modes to handle:**
1. **Wi-Fi re-association or roaming** after wake or AP change. Requests fail with `NSURLErrorNotConnectedToInternet` (-1009), `NetworkConnectionLost` (-1005), or `TimedOut` (-1001).
   - Use `waitsForConnectivity = true` plus an `NWPathMonitor` gate.
   - The local `NWPathMonitor` check returned `status=satisfied wifi=true expensive=false constrained=false`. [H] (verified locally by `NtfyClient.swift`)
2. **iPhone Personal Hotspot.** If the Mac is tethered to the phone and the user walks away, the Mac goes offline and the agent probably does too.
   - Detect `NWPath.isExpensive` and Wi-Fi to a hotspot.
   - Warn at lid-close: "You're on your iPhone's hotspot. Lidless can't reach you if you take the phone." [M]
3. **Captive portals and expired hotel Wi-Fi.** These return 200 with HTML. Validate each provider's success body:
   - ntfy: an `id`
   - Telegram: `"ok": true`
   - Pushover: `"status": 1`
   - Bark: `code == 200`
   - Discord: 204, or 200 with `?wait=true`
   - Slack: body `ok`
4. **VPN on-demand, proxies, PAC files.** URLSession honours system proxies automatically. A VPN that drops on lid close (some corporate clients do) blocks delivery.
5. **Daemons Lidless must never pause:** `mDNSResponder`, `configd`, `trustd`, `nsurlsessiond`, `networkserviceproxy`, `nehelper` and VPN extensions, `symptomsd`, `apsd`. Pause only user GUI apps. If the iMessage provider is enabled, also exclude Messages.app. [M]
6. **ntfy rate limits.** A tight reconnect loop burns the 60-request burst. Apply the 5 s minimum backoff and honour 429 / 42905.
7. **Long-lived stream silently dead after a network change.** Use the app-level watchdog (§3.9).

**Outbox design** (implementation-ready; the compiled sketch is in §17.3):
- **Persistence.** Store at `~/Library/Application Support/Lidless/outbox.json`; with no sandbox this is the real path. Each item holds an `id` (UUID), `kind`, `groupKey`, `replaceKey`, payload, `attempts`, `nextAttemptAt`, and `expiresAt`.
- **Coalescing on enqueue.** A newer item with the same `groupKey` replaces the queued one. For example, "sleeping in 5 min" is superseded by "Mac is asleep", and several `finished` events merge into one digest.
- **TTL per kind (drop rather than send stale news):**
  - finished: 6 h
  - needs-input: until the session state changes, maximum 2 h
  - countdown: until the countdown ends
  - "Mac is asleep": 12 h; delivered after wake as "Slept 01:12–07:40".
  - warning: 30 min
- **Retry policy:**
  - Exponential backoff with full jitter: base 2 s, cap 5 min.
  - Honour `Retry-After`, Telegram `parameters.retry_after`, and the Pushover ≥ 5 s rule.
  - Never retry permanent errors: ntfy 400/401/403, Pushover 4xx, Telegram 400/403 such as "bot was blocked by the user". Surface them in the menu bar instead.
- **Triggers for draining:** enqueue, `NWPathMonitor` → `.satisfied`, `NSWorkspace.didWakeNotification`, and a 60 s timer.
- **Before Lidless itself sleeps or shuts down the Mac:** enqueue the final message, call `drain(deadline: now + 10 s)`, then proceed regardless of the result.
- **Idempotency.** ntfy and Telegram have no idempotency key, so a lost response after a successful send can produce a duplicate. Reduce the impact with ntfy `sequence_id = <event id>` (Android replaces instead of stacking), HA `tag`, and Bark `id`.

---

## 15. Command channel security model
Threats:
- Anyone who learns the **notify topic** can read notifications, including the action bodies.
- Anyone who learns the **command topic** can publish to it.
- ntfy.sh caches the command topic for 12 h and **replays all of it** on an unknown `since` id (§3.6).
- GET links get prefetched.

Design:
1. **Two different random topics.** `lidless_<22 base64url chars>` for notify and `lidless_c_<22 chars>` for commands, each 128 bits. Valid charset and length were verified locally: the generated `lidless_bOUCXvxpYUCrtstdBjMExQ` is 30 chars and valid. Store them with other secrets (see Risks: Keychain and ad-hoc signing).
2. **Mint every command on the Mac:**
   ```json
   {"v":1,"cmd":"sleep","arg":null,"nonce":"<12 chars>","exp":<unix>,"sv":<stateVersion>,"sig":"<base64 HMAC-SHA256(key, v|cmd|arg|nonce|exp|sv)>"}
   ```
   The 256-bit key never leaves the Mac. Verified locally: minted bodies verify, and changing `cmd` to `shutdown` fails verification.
3. **Execute only if:** the signature is valid, `exp ≥ now`, the nonce was never seen (keep a nonce→exp map until expiry), and, for `sleep` or `shutdown`, `sv == currentStateVersion`, or no agent has become busy since. Otherwise notify "Ignored: Codex in `web` is busy again".
4. **Shutdown gets a grace period.** On receipt, publish "Shutting down in 60 s [Cancel]" and then act. Telegram can instead edit the message to "Confirm shutdown? [Yes]".
5. **POST-only.** Never accept GET-triggered commands. Telegram uses `callback_data`, not URL buttons.
6. **Standing tokens (optional)** for iOS Shortcuts or widgets: signed commands with a long `exp`, a fixed nonce prefix `standing-…`, rate-limited to 1/min, and revocable in Settings.
7. **Telegram.** Authenticity comes from `from.id == pairedUserId`. `callback_data = "s:<nonce>"` ≤ 64 bytes, with the same expiry and state checks.
8. **Self-hosted ntfy.** Give the phone a separate **write-only** user on `lidless_c_*`. Its token can go in the action `headers.Authorization` without exposing read access.

---

## 16. Message design

### 16.1 Templates
Agent-agnostic: always name the agent, the project folder basename, and the host app.

| Kind | Title | Body | Actions |
|---|---|---|---|
| finished | `Claude Code finished · api` | `Worked 42 min (iTerm). 2 agents still running.` | — |
| needs input | `Codex needs your input · web` | `Waiting for permission since 14:02. Mac stays awake until 14:32 unless you choose.` | Keep awake 1h, Sleep now |
| countdown | `All agents done, sleeping in 5 min` | `Finished: api (Claude Code, 42m), web (Codex, 18m).` | Keep awake 1h, Sleep now, Shut down |
| asleep | `Mac is asleep` | `Slept 14:37 after all agents finished. Battery 64%.` | — |
| shutting down | `Mac is shutting down` | `Requested from your phone at 14:40.` | — |
| warning | `Lidless can't keep your Mac awake` | `Battery 5%. 2 agents still running. Sleeping in 2 min.` | Sleep now |

Use ntfy `tags` for emoji (`white_check_mark`, `raised_hand`, `zzz`, `warning`) rather than emoji in headers. With JSON publishing, UTF-8 in titles is fine. [H]

### 16.2 Priority mapping
| Lidless | ntfy | Pushover | Telegram | Bark `level` | HA `interruption-level` |
|---|---|---|---|---|---|
| needs input / warning | 4 `high` | 1 | normal | `timeSensitive` | `time-sensitive` |
| finished / countdown | 3 `default` | 0 | normal | `active` | `active` |
| asleep / shutting down | 2 `low` | -1 | `disable_notification: true` | `passive` | `passive` |
| quiet hours (any) | min(p, 2) | min(p, -1) | `disable_notification: true` | `passive` | `passive` |
| critical (opt-in only: battery dying with agents running) | 5 | 2 (retry 60, expire 1800) | normal | `critical` | `critical` |

### 16.3 Deduplication and coalescing
- **Settle window.** Report "finished" only after the agent has been idle for at least 20 s; that stability check comes from the detection layer. The notifier then batches for **15 s**. N finishes become **one** message: "3 agents finished: …".
- **If every agent is idle when the batch flushes**, send only the **countdown** message, which lists them, instead of a separate "finished" message.
- **Needs input:**
  - Send immediately and collapse multiple requests within 15 s.
  - Send at most 1 per session per 10 min, with one reminder after 10 min if still waiting.
  - `replaceKey = "input:<session>"`.
- **Global token bucket:** 6 notifications per 10 min. Overflow folds into a digest.
- **Countdown updates** reuse `replaceKey = "lidless-countdown"`. ntfy `sequence_id` replaces on Android and web only, so on iOS **do not update the countdown repeatedly**; send it once.
- **Presence gating.** The default is to notify **only when away**: lid closed, screen locked, or user idle ≥ 5 min. There is an "always" toggle.

### 16.4 Quiet hours
User window (default off; for example 23:00–07:00):
- Downgrade finished, countdown, and asleep to silent (low or passive). They are still delivered, so the morning has a record.
- Needs-input is configurable, defaulting to normal.
- Never drop messages; the phone's Focus still applies on top. [M]

### 16.5 Privacy default for agent output
Detail levels:
- **Private:** "An agent finished".
- **Basic (default):** agent name + folder basename + duration.
- **Detailed (opt-in):** adds the first ≤ 140 chars of the agent's last message, with:
  - ANSI codes stripped
  - absolute paths reduced to basenames
  - token-like strings redacted, using regexes for `sk-…`, `ghp_…`, `xox[abp]-…`, `AKIA…`, `-----BEGIN`, and long base64/hex
  - control characters collapsed

When the user enables Detailed on **ntfy.sh with an unprotected topic**, show a warning: content is readable by anyone with the topic name, and passes through Google FCM and Apple APNs (§3.5). Recommend Detailed only with a self-hosted or protected ntfy, Pushover `encrypted=1`, or Bark `ciphertext`.

---

## 17. Recommendations for Lidless

### 17.1 Providers
1. **v1 default: ntfy.sh**, plus a "Custom ntfy server" option (base URL and `tk_` token, with a note that iOS needs `upstream-base-url`). It is the only zero-setup, two-way, cross-platform choice.
2. **v1 also: Telegram** (two-way, text commands, free) and **Pushover** (one-way, reliable, critical alerts, E2E).
3. **v1.x:** Bark (iOS E2E), Home Assistant (background actions), generic Webhook (Discord, Slack, custom JSON template), Email.
4. **Experimental or later:** the EventKit Reminders spike and iMessage (both Apple-only and unverified); a paid-ADP companion iOS app via CloudKit.
5. **Fan-out.** One primary provider, plus an optional *escalation* provider for needs-input and warnings (for example ntfy plus Pushover emergency).

### 17.2 Onboarding UX (ntfy)
1. **Generate secrets.** Lidless generates the notify topic, the command topic, and the HMAC key.
2. **Install the app.** Show App Store and Play Store QR codes.
3. **Subscribe:**
   - **iPhone:** a big monospace topic with a **Copy** button. Universal Clipboard moves it to the iPhone when Handoff is on. Instructions: "ntfy → + → paste topic → Subscribe". As a fallback, the user can point the iPhone Camera at the topic on screen and use Live Text → Copy. **Don't** show a `ntfy://` QR for iOS; it won't open the app.
   - **Android:** a QR of `ntfy://ntfy.sh/<topic>?display=Lidless`. [H]
4. **Send test.** Lidless publishes "Tap **Confirm** to finish setup", with an `http` action carrying a signed pairing command. When the Mac's stream receives it, onboarding shows "Phone paired, two-way control works". This one tap verifies push delivery, the action path, and the Mac subscription end to end.
5. **Explain plainly:** "Anyone who knows this topic name can read your Lidless notifications. Don't share it."
6. **Telegram onboarding:** see §5. The order is token → `getMe` → `deleteWebhook` → QR `t.me/<bot>?start=<code>` → wait for `/start <code>` → pinned.

### 17.3 Code
The compile-checked sketch is at `/private/tmp/claude-501/-Users-tomasnguyen-Developer/3514aa88-efa8-4a60-97d7-2878eed849d4/scratchpad/research-snippets/LidlessNotifySketch.swift`. It compiles in Swift 6 mode with `xcrun swiftc -swift-version 6 -parse-as-library`, and its publish path ran against a local echo server: JSON-OK, with 3 actions whose bodies each parse as JSON. Key interfaces:

```swift
protocol NotificationProvider: Sendable {
    var id: String { get }
    var capabilities: ProviderCapabilities { get }   // actionButtons, inboundCommands, replaceInPlace, priorityLevels, e2ee
    func validate() async throws                       // onboarding "Send test"
    func send(_ n: OutgoingNotification) async throws(DeliveryError)   // .retryable(after:) / .permanent(String)
    func commands() -> AsyncStream<RemoteCommand>?    // nil for one-way providers
}

struct OutgoingNotification: Codable, Sendable, Identifiable {
    var id = UUID(); var kind: LidlessEventKind; var title: String; var body: String
    var priority: LidlessPriority; var groupKey: String; var replaceKey: String?
    var actions: [RemoteAction] = []; var clickURL: URL? = nil
    var createdAt = Date(); var expiresAt: Date; var stateVersion: Int
}
enum RemoteAction: Codable, Sendable, Equatable { case keepAwake(seconds: Int), sleepNow, shutDown }
```

The ntfy command listener core uses the watchdog pattern verified in §3.9:

```swift
try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask {
        let (bytes, resp) = try await session.bytes(for: req)          // GET /<cmdTopic>/json?since=<lastID>
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        for try await line in bytes.lines { stamp.touch(); await self.handle(line: line, out: out) }
    }
    group.addTask { while true { try await Task.sleep(for: .seconds(1)); if stamp.age > 100 { throw IdleTimeout() } } }
    _ = try await group.next(); group.cancelAll()
}
// then: backoff = random(5 ... min(300, 5 * 2^failures)) seconds; reset failures on HTTP 200
```

The Telegram loop, a sketch from the docs (not executed):
```swift
// POST https://api.telegram.org/bot<TOKEN>/getUpdates  {"offset": lastUpdateId+1, "timeout": 50, "allowed_updates": ["message","callback_query"]}
// URLRequest.timeoutInterval = 65 (> long-poll timeout)
// for u in result: lastUpdateId = u.update_id
//   if let cq = u.callback_query, cq.from.id == pairedUserId { parse cq.data "s:<nonce>" → validate → answerCallbackQuery → editMessageReplyMarkup }
//   if let m = u.message, m.from.id == pairedUserId { "/status" | "/sleep" | "/awake 2h" | "/start <pairing>" }
// on 409 Conflict → another poller/webhook: show error; on 429 → sleep(parameters.retry_after)
```

### 17.4 Ready-to-use curl examples
All of these were linted against a local echo server: every JSON body parsed, nested action bodies parsed, and Telegram `callback_data` came out at 8–12 bytes. They are built from the cited docs. Replace the hosts as shown.

```bash
# ntfy: simple
curl -sS -H "Title: Claude Code finished" -H "Priority: default" -H "Tags: white_check_mark,computer" \
  -d "api-server: finished after 42 min" "https://ntfy.sh/$TOPIC"

# ntfy: header-style actions (quote bodies containing commas)
curl -sS -H "Title: All agents idle" -H "Priority: default" \
  -H "Actions: http, Keep awake 1h, https://ntfy.sh/$CMD_TOPIC, headers.X-Firebase=no, body='$AWAKE_BODY', clear=true; http, Sleep now, https://ntfy.sh/$CMD_TOPIC, headers.X-Firebase=no, body='$SLEEP_BODY', clear=true" \
  -d "Mac will sleep in 5 min." "https://ntfy.sh/$TOPIC"

# ntfy: JSON (what the app should use) - POST to ROOT url
curl -sS https://ntfy.sh/ -H "Content-Type: application/json" -d '{
  "topic": "'"$TOPIC"'", "title": "All agents idle", "priority": 3, "tags": ["zzz"],
  "message": "api (Claude Code), web (Codex) finished. Mac sleeps in 5 min.",
  "sequence_id": "lidless-countdown",
  "actions": [
    {"action":"http","label":"Keep awake 1h","url":"https://ntfy.sh/'"$CMD_TOPIC"'","method":"POST",
     "headers":{"X-Firebase":"no"},"body":"{\"v\":1,\"cmd\":\"keepawake\",\"arg\":\"3600\",\"nonce\":\"7b0d11\",\"exp\":1791815325,\"sv\":42,\"sig\":\"…\"}","clear":true},
    {"action":"http","label":"Sleep now","url":"https://ntfy.sh/'"$CMD_TOPIC"'","method":"POST",
     "headers":{"X-Firebase":"no"},"body":"{\"v\":1,\"cmd\":\"sleep\",\"nonce\":\"9f1c2e\",\"exp\":1791815325,\"sv\":42,\"sig\":\"…\"}","clear":true}
  ]}'

# ntfy: Mac side (stream / poll / delete-by-sequence)
curl -sN "https://ntfy.sh/$CMD_TOPIC/json?since=$LAST_ID"
curl -sS "https://ntfy.sh/$CMD_TOPIC/json?poll=1&since=10m"
curl -sS -X DELETE "https://ntfy.sh/$TOPIC/lidless-countdown"

# Pushover (use --form-string so '@' / '<' are not interpreted by curl)
curl -sS https://api.pushover.net/1/messages.json \
  --form-string "token=$PUSHOVER_APP_TOKEN" --form-string "user=$PUSHOVER_USER_KEY" \
  --form-string "title=Codex needs input" --form-string "message=web: waiting for permission" \
  --form-string "priority=1" --form-string "url=https://github.com/me/web/pull/12" --form-string "url_title=Open PR"
curl -sS https://api.pushover.net/1/messages.json --form-string "token=$PUSHOVER_APP_TOKEN" --form-string "user=$PUSHOVER_USER_KEY" \
  --form-string "message=Battery 5% and 2 agents running" --form-string "priority=2" \
  --form-string "retry=60" --form-string "expire=1800" --form-string "tags=lidless-battery"
curl -sS "https://api.pushover.net/1/receipts/$RECEIPT.json?token=$PUSHOVER_APP_TOKEN"

# Telegram
curl -sS "https://api.telegram.org/bot$TG_TOKEN/getUpdates" -H "Content-Type: application/json" \
  -d '{"offset": 0, "timeout": 50, "allowed_updates": ["message","callback_query"]}'
curl -sS "https://api.telegram.org/bot$TG_TOKEN/sendMessage" -H "Content-Type: application/json" -d '{
  "chat_id": 987654321, "parse_mode": "HTML",
  "text": "<b>All agents idle</b>\napi (Claude Code), web (Codex) finished.\nMac sleeps in 5 min.",
  "reply_markup": {"inline_keyboard": [
    [{"text": "Keep awake 1h", "callback_data": "k3600:7b0d11"}, {"text": "Sleep now", "callback_data": "s:9f1c2e"}],
    [{"text": "Shut down", "callback_data": "x:9f1c2e", "style": "danger"}]]}}'
curl -sS "https://api.telegram.org/bot$TG_TOKEN/answerCallbackQuery" -H "Content-Type: application/json" \
  -d '{"callback_query_id": "<id>", "text": "OK - keeping the Mac awake for 1 h"}'
curl -sS "https://api.telegram.org/bot$TG_TOKEN/editMessageReplyMarkup" -H "Content-Type: application/json" \
  -d '{"chat_id": 987654321, "message_id": 42, "reply_markup": {"inline_keyboard": []}}'

# Bark
curl -sS https://api.day.app/push -H "Content-Type: application/json; charset=utf-8" -d '{
  "device_key": "<key>", "title": "Claude Code needs input", "body": "api: permission requested",
  "level": "timeSensitive", "group": "lidless", "id": "lidless-api-input"}'

# Discord / Slack webhooks
curl -sS "$DISCORD_WEBHOOK_URL?wait=true" -H "Content-Type: application/json" \
  -d '{"username":"Lidless","content":"**All agents idle**: Mac sleeps in 5 min","allowed_mentions":{"parse":[]}}'
curl -sS -X POST "$SLACK_WEBHOOK_URL" -H "Content-type: application/json" \
  -d '{"text":"All agents idle - Mac sleeps in 5 min","blocks":[{"type":"section","text":{"type":"mrkdwn","text":"*All agents idle*\nMac sleeps in 5 min."}}]}'

# Gotify
curl -sS "https://gotify.example.com/message" -H "X-Gotify-Key: $GOTIFY_APP_TOKEN" -H "Content-Type: application/json" \
  -d '{"title":"Codex finished","message":"**web**: done in 18 min","priority":5,"extras":{"client::display":{"contentType":"text/markdown"}}}'

# Home Assistant (actionable)
curl -sS -X POST "$HA/api/services/notify/mobile_app_<device>" -H "Authorization: Bearer $HA_TOKEN" \
  -H "Content-Type: application/json" -d '{"title":"All agents idle","message":"Mac sleeps in 5 min",
  "data":{"tag":"lidless-countdown","group":"lidless","push":{"interruption-level":"time-sensitive"},
  "actions":[{"action":"LIDLESS_KEEPAWAKE_7b0d11","title":"Keep awake 1h"},{"action":"LIDLESS_SLEEP_9f1c2e","title":"Sleep now"},
             {"action":"LIDLESS_SHUTDOWN_9f1c2e","title":"Shut down","destructive":true,"authenticationRequired":true}]}}'
```

The full file, `curl_examples.sh`, refuses to run unless `LINT_BASE` is `http://127.0.0.1:*`.

### 17.5 Settings surface (minimum)
- Provider + "Send test"
- Notify when: away only / always
- Events: finished, needs input, countdown, asleep, warnings
- Detail level: Private / Basic / Detailed
- Quiet hours
- Escalation provider
- "Don't duplicate Claude Code Remote Control pushes"
- Rotate topics and key (invalidates old buttons)

---

## 18. Risks and unknowns
1. **Lid-closed Wi-Fi was not empirically verified in this session** (power settings could not be changed). Validate in the prototype: hold the assertion, close the lid, then send and receive through ntfy every minute for 30 min, on battery and on AC. [M]
2. **Unverified iOS ntfy behaviour:**
   - Priority 4/5 may not break through Focus: there is no time-sensitive entitlement in the repo's entitlements file. Critical alerts only arrive with v1.8.0, which is unreleased.
   - Action taps foreground the app.
   - No `clear` on iOS.
   - No update or delete on iOS, so the countdown stacks.

   Test on a device. [M/L]
3. **ntfy.sh privacy.** Public topics, plus FCM/APNs carrying the content (§3.5). The 12-hour cache is readable by anyone with the topic name. Mitigations: random 128-bit topics, the Basic detail default, the self-host option, and paid reserved topics (but iOS 1.7.0 has protected-topic poll-request rough edges).
4. **ntfy.sh availability and limits.** A single free public service; 250 msg/day per IP. Shared NAT could exhaust it (429), and IP bans are possible. Offer a token or a self-hosted server, plus an escalation provider.
5. **Command security** depends on keeping the HMAC key on the Mac and enforcing nonce, expiry, and state version. A bug in the validation is the dangerous failure mode (remote shutdown). Unit-test it heavily.
6. **Keychain plus ad-hoc signing [M].** Keychain item ACLs are bound to the code signature, and ad-hoc signatures change on every rebuild, so users may get "Lidless wants to use your confidential information" prompts after updates. Options:
   - Use the data-protection keychain with a stable designated requirement, which effectively needs a Developer ID.
   - Or store secrets in `~/Library/Application Support/Lidless/secrets.json` with mode 0600 and accept the weaker protection.
7. **Telegram:**
   - The user must create a bot (friction).
   - Bot messages aren't E2E.
   - Notifications don't show inline buttons. [M]
   - The 24 h update retention means stale callbacks are possible, so enforce expiry.
   - Running two Lidless instances on one token causes a 409.
8. **Pushover cost and quota.** It is a paid app, and has no remote control.
9. **iMessage.** The dictionary exists on 26.0, but whether a self-message alerts the iPhone is unknown, and it needs Messages running (it conflicts with pausing). Also TCC prompts. [L]
10. **Apple-native push and CloudKit require a paid Apple Developer Program membership** (verified). Revisit only if Lidless gets a Developer ID.
11. **Duplicate notifications** with Claude Code's own Remote Control push. Mitigate with the toggle and `CLAUDE_CLIENT_PRESENCE_FILE` guidance.
12. **Date anomaly.** The ntfy docs list server v2.30.0 as released Oct 12, 2026, while the GitHub releases API showed v2.29.0 as newest at research time. Pin behaviour to documented APIs, not versions.
13. **ntfy http actions use POST to the public command topic.** Corporate phone networks or captive portals could block the phone's POST; there is no iOS feedback when that happens.

---

## 19. Verification log (local, read-only)
| What | How |
|---|---|
| ntfy iOS supports only `view` + `http` actions, uses `.foreground`, maps priorities to interruption levels, has no URL scheme, and requires a bare topic | `gh api repos/binwiederhier/ntfy-ios/contents/...` → `Actions.swift`, `ActionExecutor.swift`, `NotificationContent.swift`, `AppDelegate.swift`, `Info.plist`, `ntfy.entitlements`, `SubscriptionAddView.swift`, `project.pbxproj` |
| ntfy FCM/APNs payload, 100-char APNs alert truncation, poll_request for protected topics | `server/server_firebase.go` |
| `since=<unknown id>` replays the full cache | `message/cache.go` (`resolveMessageRowID`) |
| Action parser: max 3 actions, quoting rules, body not allowed with GET | `action/action.go` |
| keepalive 45 s, cache 12 h, upstream semantics, rate-limit defaults | `server/server.yml`, `docs/config.md`, `docs/publish.md`, `docs/subscribe/api.md` |
| Telegram API fields and limits, Bot API 10.3 | downloaded `core.telegram.org/bots/api`, `/bots/faq`, `/bots/features`, parsed locally |
| Apple capability availability (Push, CloudKit, and Time-Sensitive are ADP-only) | downloaded and parsed `developer.apple.com/help/account/reference/supported-capabilities-ios` |
| Messages.app AppleScript dictionary on macOS 26 | `sdef /System/Applications/Messages.app` |
| 30 s sleep-ack timeout; `NSActivity*` constants | `IOPMLib.h`, `NSProcessInfo.h` in the macOS 26 SDK |
| URLSession stream idle timeout does not fire mid-stream; app watchdog works; since-cursor reconnect, nonce dedupe, HMAC | `NtfyClient.swift` + `Watchdog.swift` against `mock_ntfy.py` (127.0.0.1) |
| curl examples produce well-formed requests | `curl_examples.sh` against `echo_server.py` (127.0.0.1) |
| Swift 6 sketch compiles and publishes | `xcrun swiftc -swift-version 6 -parse-as-library LidlessNotifySketch.swift` → run against the echo server |

## Sources
- ntfy:
  - https://docs.ntfy.sh/publish/
  - https://docs.ntfy.sh/subscribe/api/
  - https://docs.ntfy.sh/subscribe/phone/
  - https://docs.ntfy.sh/config/
  - https://docs.ntfy.sh/releases/
  - https://docs.ntfy.sh/terms/
  - https://ntfy.sh/
  - https://github.com/binwiederhier/ntfy
  - https://github.com/binwiederhier/ntfy-ios
- Pushover:
  - https://pushover.net/api
  - https://pushover.net/api/receipts
  - https://pushover.net/pricing
  - https://blog.pushover.net/posts/2020/2/ios-critical-alerts
- Telegram:
  - https://core.telegram.org/bots/api
  - https://core.telegram.org/bots/faq
  - https://core.telegram.org/bots/features
- Bark: https://github.com/Finb/Bark (`docs/en-us/tutorial.md`, `params.md`, `encryption.md`, `privacy.md`)
- Discord: https://docs.discord.com/developers/resources/webhook
- Slack:
  - https://docs.slack.dev/messaging/sending-messages-using-incoming-webhooks/
  - https://docs.slack.dev/apis/events-api/using-socket-mode/
- Gotify:
  - https://gotify.net/docs/pushmsg
  - https://gotify.net/docs/msgextras
- Home Assistant:
  - https://companion.home-assistant.io/docs/notifications/notifications-basic/
  - https://companion.home-assistant.io/docs/notifications/actionable-notifications/
  - https://developers.home-assistant.io/docs/api/rest/
- Apple:
  - https://developer.apple.com/help/account/reference/supported-capabilities-ios
  - https://developer.apple.com/forums/thread/795461
  - https://developer.apple.com/forums/thread/829104
- Claude Code Remote Control push: https://code.claude.com/docs/en/remote-control
