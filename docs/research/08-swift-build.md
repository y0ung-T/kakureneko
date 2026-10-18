# 08 — Building & shipping Lidless from the terminal (Xcode 26.6 / Swift 6.3, SwiftPM + bundling script)

Research date: **2026-10-12**. Machine: macOS **26.6.2 (25G83)** arm64, Xcode **26.6 (17F113)**, Swift **6.3.3** (`swiftlang-6.3.3.1.3`, clang-2100.1.1.101), macOS SDK **26.5 (25F70)** (Xcode 26.6 ships the 26.5 SDK, verified with `xcrun --show-sdk-version`), SwiftPM 6.3.3, Swift Testing library version 1902.

Everything marked **verified** was built and run on this machine. The throwaway prototypes are in
`/private/tmp/claude-501/-Users-tomasnguyen-Developer/3514aa88-efa8-4a60-97d7-2878eed849d4/scratchpad/research-snippets/`. That directory is temporary, so every file that matters is copied into this report.

- `LidlessProto/`: the full package. It has the app, CLI, core library, a probe tool, tests and `scripts/build-app.sh`.
- `IPCBench/`: the IPC latency benchmark (listener, six senders and a driver).
- `snips/`: single-file experiments (concurrency pitfalls, unix socket path limits, KERN_PROCARGS2 buffers, embedded Info.plist).
- `clash/`: reproduces the case-insensitive product-name clash.

Confidence levels: **H** = verified locally or in official Apple/Swift docs. **M** = good secondary evidence or a strong inference. **L** = unverified.

---

## TL;DR (decisions)

| Decision | Choice | Confidence |
|---|---|---|
| Build system | **SwiftPM package only** (no .xcodeproj, xcodegen or Tuist) plus `scripts/build-app.sh`, which assembles and signs `Lidless.app`. A clean release build of the app and CLI takes about 12 s. Incremental builds take 1–2 s. | H (verified) |
| Manifest | `// swift-tools-version: 6.2`, `platforms: [.macOS(.v26)]`, Swift 6 language mode. The app target uses `.defaultIsolation(MainActor.self)`. | H (verified) |
| Product names | App product **`LidlessApp`** (renamed to `Contents/MacOS/Lidless` in the bundle) and CLI product **`lidless`**. Products named `Lidless` and `lidless` **break the build** on case-insensitive APFS. | H (verified) |
| CLI location in bundle | `Lidless.app/Contents/Helpers/lidless`. Apple's bundle rules allow helper tools in `Contents/Helpers/`. A separate directory also avoids a case clash with `Contents/MacOS/Lidless`. | H |
| Signing | Inside-out `codesign --force --sign "$SIGN_ID" --options runtime`. Default `SIGN_ID=-` (ad-hoc). Using the user's **existing "Apple Development: … (52L356TDBT)" identity** is recommended so TCC grants survive rebuilds. | H (ad-hoc verified) / M (dev identity) |
| Hook → app IPC | **File-drop inbox** (`~/Library/Application Support/Lidless/inbox`), written atomically with `rename(2)` and watched with a `DispatchSource` vnode source. The CLI is **Foundation-free**: about 4.2 ms wall time median, about 4 ms from spawn until the app receives the event. Events queue up while the app is not running. | H (verified) |
| Concurrency | `@Observable` model, MainActor by default in the app target. Monitors own C resources and expose `AsyncStream`s. Use `@concurrent` for off-main work. GCD and IOKit closures must be created in nonisolated code or marked `@Sendable`, otherwise they **trap at runtime** and the compiler gives no warning. | H (verified) |
| Tests | Use `swift test`. Swift Testing (`import Testing`) and XCTest run in the same run. Test targets can depend on **executable** targets, including the SwiftUI app and the CLI. | H (verified) |

---

## 1. Recommended repository layout

```
lidless/
├── Package.swift
├── Sources/
│   ├── LidlessCore/          # library: ALL logic (testable). Foundation + IOKit + libproc. No SwiftUI.
│   │   ├── AgentEvent.swift      # inbox file format, payload decoding
│   │   ├── EventInbox.swift      # drain + DispatchSource watcher -> AsyncStream
│   │   ├── ProcessScanner.swift  # libproc / sysctl
│   │   ├── AgentMatcher.swift    # process -> agent classification
│   │   ├── Power.swift           # IOPMrootDomain reads, clamshell notifications, IOPS, assertions
│   │   └── SystemPower.swift     # IORegisterForSystemPower sleep/wake
│   ├── LidlessUI/            # (optional) library with SwiftUI views -> Xcode previews work for library targets
│   ├── LidlessApp/           # executable: @main App, AppDelegate, wiring only    (product "LidlessApp")
│   └── LidlessCLI/           # executable: Darwin-only hook CLI, no dependencies  (product "lidless")
├── Tests/
│   ├── LidlessCoreTests/     # Swift Testing; also spawns the built `lidless` binary
│   └── LidlessAppTests/      # optional; @testable import LidlessApp works
├── Resources/
│   ├── Info.plist
│   └── AppIcon.icns          # optional (iconutil / actool), referenced by CFBundleIconFile
├── scripts/
│   ├── build-app.sh          # verified (below)
│   └── install.sh            # copies to ~/Applications, symlinks the CLI (not run during research)
└── docs/research/…
```

`.gitignore`: `.build/`, `build/`, `*.xcodeproj` (optional), `.swiftpm/xcode/` (Xcode workspace state created by `xed .`).

**Case-clash proof (H, verified, `research-snippets/clash`).** Products `.executable(name: "Lidless")` and `.executable(name: "lidless")` in one package share `.build/arm64-apple-macosx/debug/Lidless.product/Objects.LinkFileList` and the output path on case-insensitive APFS (`touch CaseTest; ls casetest` succeeds on this Mac). Both runs of `swift build` failed. Which target failed was random from run to run:

```
error: link command failed with exit code 1 (use -v to see invocation)
Undefined symbols for architecture arm64:
  "_AppT_main", referenced from:
      _main in command-line-aliases-file
ld: symbol(s) not found for architecture arm64
```

The fix is to give the products names that differ case-insensitively (`LidlessApp` and `lidless`) and rename the binary while bundling. Two binaries in the same bundle directory have the same problem, so `Contents/MacOS/Lidless` and `Contents/MacOS/lidless` cannot coexist. Put the CLI in `Contents/Helpers/`.

---

## 2. `Package.swift` (verified: builds with zero warnings, 9 tests pass)

```swift
// swift-tools-version: 6.2
import PackageDescription

// Swift 6 language mode is implied by tools-version >= 6.0.
let strict: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"), // SE-0461 (Xcode 26 "Approachable Concurrency")
    .enableUpcomingFeature("InferIsolatedConformances"),      // SE-0470
    .enableUpcomingFeature("MemberImportVisibility"),          // SE-0444
]

let package = Package(
    name: "Lidless",
    platforms: [.macOS(.v26)],
    products: [
        // Product names must differ case-insensitively ("Lidless" vs "lidless" clash on APFS).
        .executable(name: "LidlessApp", targets: ["LidlessApp"]),
        .executable(name: "lidless", targets: ["LidlessCLI"]),
    ],
    targets: [
        .target(name: "LidlessCore",
                swiftSettings: strict,
                linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "LidlessApp",
                          dependencies: ["LidlessCore"],
                          swiftSettings: strict + [.defaultIsolation(MainActor.self)]), // SE-0466
        .executableTarget(name: "LidlessCLI",
                          dependencies: [],          // deliberately dependency-free: fast startup
                          swiftSettings: strict),
        .testTarget(name: "LidlessCoreTests",
                    dependencies: ["LidlessCore", "LidlessCLI"], // listing LidlessCLI makes `swift test` build the binary
                    swiftSettings: strict),
        .testTarget(name: "LidlessAppTests",
                    dependencies: ["LidlessApp"],
                    swiftSettings: strict),
    ]
)
```

Notes:
- `swift-tools-version: 6.3` is also accepted. `6.4` fails with "using Swift tools version 6.4.0 but the installed version is 6.3.3" (H, verified). Keep **6.2**: it already has `.defaultIsolation` and `.macOS(.v26)`.
- Binaries record `minos 26.0, sdk 26.5` (`vtool -show-build`) (H).
- `swift build --build-system swiftbuild` (the Swift Build engine, still a preview in 6.3) also builds this package (verified, about 13 s clean). Its bin path is `.build/out/Products/Release`, so the script always asks for `--show-bin-path`. Keep the default `native` build system for now (H). Swift 6.3 was released 2026-03-24, and its SwiftPM work centred on this Swift Build preview ([swift.org](https://swift.org/blog/swift-6.3-released/)) (M).

---

## 3. `Resources/Info.plist` (verified: LSUIElement honoured, `NSApp.activationPolicy() == .accessory`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>      <string>en</string>
	<key>CFBundleExecutable</key>             <string>Lidless</string>
	<key>CFBundleIdentifier</key>             <string>dev.lidless.Lidless</string>   <!-- pick your own reverse-DNS; prototype used dev.lidless.research-proto -->
	<key>CFBundleInfoDictionaryVersion</key>  <string>6.0</string>
	<key>CFBundleName</key>                   <string>Lidless</string>
	<key>CFBundleDisplayName</key>            <string>Lidless</string>
	<key>CFBundlePackageType</key>            <string>APPL</string>
	<key>CFBundleShortVersionString</key>     <string>0.0.0</string>  <!-- replaced by build-app.sh -->
	<key>CFBundleVersion</key>                <string>0</string>      <!-- replaced by build-app.sh -->
	<key>LSMinimumSystemVersion</key>         <string>26.0</string>
	<key>LSUIElement</key>                    <true/>
	<key>LSApplicationCategoryType</key>      <string>public.app-category.developer-tools</string>
	<key>NSPrincipalClass</key>               <string>NSApplication</string>
	<key>NSHumanReadableCopyright</key>       <string>Personal build</string>
	<!-- Add only when a feature needs it:
	<key>CFBundleIconFile</key>               <string>AppIcon</string>
	<key>NSAppleEventsUsageDescription</key>  <string>Lidless asks apps to quit/hide while the lid is closed.</string>
	-->
</dict>
</plist>
```

---

## 4. `scripts/build-app.sh` (verified: produces a valid 436 KB bundle)

```bash
#!/usr/bin/env bash
# Build Lidless.app from the SwiftPM package. Usage: scripts/build-app.sh [debug|release]
# Env: VERSION (default 0.1.0), BUILD_NUMBER (default: git commit count or 1), SIGN_ID (default "-" = ad-hoc)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SIGN_ID="${SIGN_ID:--}"
APP="build/Lidless.app"

swift build -c "$CONFIG" --arch arm64 --product LidlessApp
swift build -c "$CONFIG" --arch arm64 --product lidless
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/LidlessApp" "$APP/Contents/MacOS/Lidless"     # CFBundleExecutable
cp "$BIN/lidless"    "$APP/Contents/Helpers/lidless"   # hook CLI (different dir: case-insensitive FS!)
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Copy SwiftPM resource bundles if any target ever declares resources:
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done

# Sign inside-out (Apple discourages --deep for signing). Hardened runtime is harmless ad-hoc.
codesign --force --sign "$SIGN_ID" --timestamp=none --options runtime \
         --identifier dev.lidless.cli "$APP/Contents/Helpers/lidless"
codesign --force --sign "$SIGN_ID" --timestamp=none --options runtime "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Built $APP ($VERSION/$BUILD_NUMBER, signed with '$SIGN_ID')"
```

Verified output and inspection (H):

```
build/Lidless.app: valid on disk
build/Lidless.app: satisfies its Designated Requirement
$ codesign -dv --verbose=4 build/Lidless.app
Identifier=dev.lidless.research-proto
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20500 size=891 flags=0x10002(adhoc,runtime) hashes=21+3 location=embedded
Signature=adhoc
Info.plist entries=14
TeamIdentifier=not set
Runtime Version=26.5.0
Sealed Resources version=2 rules=13 files=1
$ codesign -d -r- build/Lidless.app
# designated => cdhash H"1f5bb88b7420f79ad2d2399fdc34d7c8113cd205"
$ spctl --assess --type execute -vv build/Lidless.app
build/Lidless.app: rejected
```

Bundle contents: `Contents/{Info.plist, PkgInfo, MacOS/Lidless (359,600 B), Helpers/lidless (79,152 B), Resources/, _CodeSignature/CodeResources}`. The CLI links only libSystem and the OS Swift runtime (`otool -L`).

Signing details (H, verified):
- Raw SwiftPM binaries are already **linker-signed**: `flags=0x20002(adhoc,linker-signed)` with `Info.plist=not bound`. That is enough to run them, but the bundle's Info.plist and resources are not sealed. **Always re-sign the bundle** after assembly.
- `codesign --force --deep -s - Lidless.app` also produces a valid bundle. However, the nested CLI gets an auto-generated identifier, `lidless-55554944b57d69604eeb30f4ab78139b18fd090d`, and no hardened runtime. Sign inside-out with an explicit `--identifier`, as above.
- Ad-hoc **DR = `cdhash H"…"`**, so every rebuild is "different code" to macOS. Apple's TN3127: *"Ad hoc signed code… has a DR but it's tied to that specific version of the code… Without a DR, macOS can't track this authorization across versions of your app."* ([TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)) (H).
- This Mac already has a usable identity: `security find-identity -v -p codesigning` lists `"Apple Development: nguyentomas0949@gmail.com (52L356TDBT)"` (H, verified read-only). Signing with it (`SIGN_ID="Apple Development: nguyentomas0949@gmail.com (52L356TDBT)" scripts/build-app.sh`) gives the stable DR `identifier "…" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: …" and certificate 1[field.1.2.840.113635.100.6.2.1]` (TN3127) (M). **Not executed**, because a keychain access prompt could appear; the user should try it once interactively. No paid program is needed, but the certificate expires and must be renewed through Xcode.

---

## 5. What works and what breaks with ad-hoc signing (no paid Developer ID)

| Capability | Result on this machine | Confidence / source |
|---|---|---|
| Launch a locally built ad-hoc `.app` (via `open` or by exec'ing `Contents/MacOS/Lidless`) | Works. Locally built files carry no quarantine xattr. | H, verified |
| `LSUIElement` (no Dock icon) | `activationPolicy` = 1 (`.accessory`) | H, verified |
| **`UNUserNotificationCenter`** from the ad-hoc **bundle** | `UNUserNotificationCenter.current().notificationSettings()` returns `authorizationStatus = 0` (`.notDetermined`), so the centre is reachable and nothing crashes. `requestAuthorization` / `add(_:)` were **not** called because they create an entry under System Settings > Notifications. Third-party docs say *"An ad-hoc signature will be sufficient"* ([desktop-notifier](https://desktop-notifier.readthedocs.io/)). | H (reachable) / M (delivery) |
| `UNUserNotificationCenter` from a **bare executable** (`swift run`, `.build/.../LidlessApp`, or Xcode "Run" of the package scheme) | **Crashes**: `NSInternalInconsistencyException`, reason: `'bundleProxyForCurrentProcess is nil: mainBundle.bundleURL file:///…/.build/arm64…'`. Embedding an Info.plist with `-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist` sets `Bundle.main.bundleIdentifier` but **still crashes**. Guard with `Bundle.main.bundleURL.pathExtension == "app"`. | H, verified |
| `SMAppService.mainApp.status` | `3` = `.notFound` for the never-registered prototype in a temp dir. Quinn (DTS), hedged: *"the `.notFound` status means that the system has never seen your service… If you register and then unregister the service, the status goes to the more expected `.notRegistered`"* ([forum 719862](https://developer.apple.com/forums/thread/719862)). Do not treat `.notFound` as an error at first launch. | H (value) / M (meaning) |
| `SMAppService.mainApp.register()` ad-hoc | **Not executed** (it would add a Login Item). Real-world evidence: the Insomnia menu-bar app ad-hoc signs "a fresh bundle on every run" via `install.sh` and uses `SMAppService.mainApp.register()`. It re-registers at launch because it suspects the registration is tied to "the bundle's signature and location" ([PR #35](https://github.com/krishhgg/Insomnia/pull/35)). Expect it to work, but re-check `status` on every launch. | M |
| `SMAppService.agent(plistName:)` | The plist must be in `Contents/Library/LaunchAgents/`. A LaunchAgent "is immediately bootstrapped" on register ([register() docs](https://developer.apple.com/documentation/servicemanagement/smappservice/register())). Untested with ad-hoc signing; `status` for a missing plist = 3 `.notFound` (verified). | M/L |
| `SMAppService.daemon(plistName:)` (root helper, e.g. for `pmset disablesleep`) | Needs admin approval in System Settings. Developers saw "Item from unidentified developer" and a daemon that "does not run" on Sequoia even with Developer ID ([forum 757463](https://developer.apple.com/forums/thread/757463)). With ad-hoc signing: **high risk, avoid in v1**. | M |
| TCC-gated features (Automation/Apple Events, Accessibility, Screen Recording, Desktop/Documents folders) | Work, but the grant is bound to the cdhash, so you are **re-prompted after every rebuild** (TN3127). Use the Apple Development identity to get a stable DR. | H (doc) |
| Gatekeeper for other people | `spctl --assess` → `rejected` (verified). Downloaded (quarantined) copies need "Open Anyway" or `xattr -dr com.apple.quarantine`. The Control-click bypass was removed in Sequoia ([OSnews](https://www.osnews.com/story/141055/bug-or-intentional-macos-15-1-completely-removes-ability-to-launch-unsigned-applications/)). Homebrew is ending support for casks that fail Gatekeeper on 2026-09-01 (secondary reports, e.g. [TomatoBar #102](https://github.com/ivoronin/TomatoBar/issues/102)). **Notarization requires a paid Developer ID ($99/yr)**, which is flagged. A good path with no paid account is **build from source** (`git clone && scripts/install.sh`): local builds are never quarantined. | H / M |
| APNs remote push to the Mac | Requires `aps-environment` entitlement plus a provisioning profile (paid program). Not needed: phone push should go through a third-party HTTPS relay (another research doc). | M |

---

## 6. The `lidless` hook CLI and IPC

### 6.1 Requirements → design
Agent hooks (Claude Code `Stop`/`Notification`, Gemini CLI hooks, Codex `notify`, Cursor/Copilot hooks…) spawn the CLI synchronously. It must:
- finish in well under 50 ms;
- **never** write to stdout, because Claude Code parses hook stdout JSON;
- **always** exit 0, because exit 2 blocks Claude;
- never hang;
- work even when Lidless is not running.

### 6.2 Measured comparison (H, verified; `IPCBench`, N=100 sequential spawns, release builds, posix_spawn → waitpid)

| Transport (sender process) | CLI wall time median / p95 / max | spawn → app receive median / p95 | Survives app not running? | Notes |
|---|---|---|---|---|
| no-op binary, `import Darwin` only (baseline) | 2.68 / 3.03 / 3.05 ms | — | — | process-spawn floor |
| no-op binary, `import Foundation` (baseline) | 4.18 / 5.37 / 7.16 ms | — | — | Foundation adds about 1.5 ms |
| **File drop, Darwin-only `lidless` CLI** | **4.18 / 9.65 / 25.4 ms** | **4.02 / 8.75 ms** | **Yes (queues)** | recommended |
| File drop, Foundation (`JSONSerialization` + `Data.write(.atomic)`) | 7.03 / 17.15 / 19.8 ms | 6.49 / 15.37 ms | Yes | slower, more allocations |
| BSD `AF_UNIX` stream socket client (non-blocking connect) | 2.80 / 6.04 / 9.0 ms | 2.55 / 4.88 ms | **No** (ECONNREFUSED → event lost) | fastest, not durable |
| `NWConnection(to: .unix(path:), using: .tcp)` | 5.66 / 8.53 / 10.6 ms | 5.16 / 7.07 ms | No | works on macOS 26 (below) |
| `DistributedNotificationCenter.postNotificationName(…, userInfo:, deliverImmediately: true)` | 3.84 / 4.38 / 4.6 ms | 4.14 / 4.79 ms | No | userInfo arrives (non-sandboxed); Apple: delivery latency "unbounded", may be "dropped" when the queue fills, not secure |
| Loopback HTTP | not prototyped | — | No | needs port management plus an auth token; Foundation or curl startup ≥ Foundation baseline. Not recommended. |

The same `lidless` CLI fed a realistic Claude `Stop` JSON on stdin took median 4.30 ms, p95 5.00 ms, max 7.03 ms (Python `subprocess.run` harness). Other measured behaviour:
- **stdin left open by the parent:** 305–306 ms, bounded by the 300 ms `poll`.
- **Bad arguments:** exit 0, 0 stdout bytes.
- **Unwritable inbox:** exit 0.
- **Codex-style payload passed as the last argv:** exit 0, payload stored verbatim.

The first, cold benchmark run had one 31 ms outlier for the no-op binary, so spawn jitter dominates. Everything stays under 50 ms.

**Recommendation: file drop.** It is the only option that is durable when the app is down, after a crash, or during an update. It is equally fast. It needs no ports or socket paths. You can debug it with `ls`, and it works the same from any agent. As a free extra, the CLI also calls `notify_post("dev.lidless.inbox")`. The listener received 103 of 103 posts. The app does not need it because the vnode source fires immediately, but it can serve as a wake-up hint for any future design.

### 6.3 Network.framework and unix sockets on macOS 26 (H, verified)
- Listener: `let p = NWParameters.tcp; p.requiredLocalEndpoint = .unix(path: "n.sock"); try NWListener(using: p)` reaches `.ready` and accepts connections. Client: `NWConnection(to: .unix(path:), using: .tcp)` works. **Relative paths work** for both NW and BSD sockets (resolved against the cwd).
- `sockaddr_un.sun_path` is **104 bytes** on Darwin (Linux has 108).
  - **Pitfall 1:** `NWConnection(to: .unix(path: <153-byte path>), using: .tcp)` **traps (SIGTRAP, exit 133) inside the initializer**.
  - **Pitfall 2:** `NWListener` with a 163-byte path reports **`.ready` but creates no socket file**.
  - BSD `bind()` with a path truncated to 103 bytes "succeeds" on the wrong path.
  - So if you ever use sockets, keep the path short (e.g. `~/Library/Application Support/Lidless/s`, which is 64 bytes for this user) and check `utf8.count < 104` before calling any API.

### 6.4 Inbox file format (implemented and verified)
File name: `<epoch_ns>-<pid>.event`, 19-digit ns, so a lexicographic sort is chronological.
- **Line 1:** a small JSON header that the CLI writes itself (only strings it controls are escaped).
- **The rest:** the agent payload, byte-for-byte. The CLI never parses or re-escapes the agent's JSON, and a malformed payload can never corrupt the header.

```
{"v":1,"agent":"claude","event":"Stop","ts":1791811783024,"pid":7940,"ppid":7938,"cwd":"/Users/x/proj"}
{"session_id":"e5b3e311-…","transcript_path":"…/e5b3e311.jsonl","cwd":"/Users/x/Developer/lidless","permission_mode":"default","hook_event_name":"Stop","stop_hook_active":false}
```

How events move through the inbox:
- **Write:** the CLI writes `<inbox>/.tmp/<name>.tmp` (`O_CREAT|O_EXCL|O_CLOEXEC`, mode 0600) and then `rename(2)`s it into `<inbox>/<name>.event`, which is atomic on the same volume.
- **Drain:** the app reads, parses and deletes each file. Files that fail to parse move to `<inbox>/bad/`.
- **Startup:** queued events are drained at launch. The verified end-to-end lag was ~240 ms for 2 events written before launch and 0–1 ms for live events, all delivered on the main actor.

### 6.5 `Sources/LidlessCLI/main.swift` (verified)

```swift
// lidless — tiny hook CLI. Contract: NEVER block, NEVER print to stdout, ALWAYS exit 0.
//   lidless emit <agent> <event> [payload]   payload = last argv (Codex `notify` style) or stdin (Claude/Gemini hooks)
import Darwin
import notify   // notify_post lives in its own Clang module, NOT in Darwin ("cannot find 'notify_post' in scope")

signal(SIGALRM) { _ in _exit(0) }   // hard watchdog: gone within 2 s with status 0
alarm(2)
signal(SIGPIPE, SIG_IGN)

@inline(__always) func bail() -> Never { exit(0) }

let args = CommandLine.arguments
guard args.count >= 4, args[1] == "emit" else { bail() }
let agent = args[2], event = args[3]

var payload: [UInt8] = []
if args.count >= 5 {
    payload = Array(args[4].utf8)
} else if isatty(STDIN_FILENO) == 0 {
    // Read to EOF, never wait > 300 ms for the next chunk, cap at 4 MiB.
    var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    var chunk = [UInt8](repeating: 0, count: 65_536)
    while payload.count < 4 << 20 {
        guard poll(&pfd, 1, 300) > 0 else { break }
        let n = chunk.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
        if n <= 0 { break }
        payload.append(contentsOf: chunk[0..<n])
    }
}

func jsonString(_ s: String) -> String {
    var o = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": o += "\\\""
        case "\\": o += "\\\\"
        case "\n": o += "\\n"
        case "\r": o += "\\r"
        case "\t": o += "\\t"
        case _ where u.value < 0x20: o += "\\u00" + String(u.value, radix: 16).leftPad(2)
        default: o.unicodeScalars.append(u)
        }
    }
    return o + "\""
}
extension String { func leftPad(_ n: Int) -> String { String(repeating: "0", count: max(0, n - count)) + self } }

var cwdBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
let cwd: String = getcwd(&cwdBuf, cwdBuf.count) != nil
    ? String(decoding: cwdBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
let nowNs = clock_gettime_nsec_np(CLOCK_REALTIME)
let header = "{\"v\":1,\"agent\":\(jsonString(agent)),\"event\":\(jsonString(event)),\"ts\":\(nowNs / 1_000_000),"
    + "\"pid\":\(getpid()),\"ppid\":\(getppid()),\"cwd\":\(jsonString(cwd))}\n"

func inboxDir() -> String {
    if let p = getenv("LIDLESS_INBOX"), p.pointee != 0 { return String(cString: p) }
    let home = getenv("HOME").map { String(cString: $0) } ?? "/tmp"
    return home + "/Library/Application Support/Lidless/inbox"
}
let dir = inboxDir()
let tmpDir = dir + "/.tmp"
func mkdirP(_ path: String) {
    if mkdir(path, 0o700) == 0 || errno == EEXIST { return }
    var cur = ""
    for comp in path.split(separator: "/") { cur += "/" + comp; _ = mkdir(cur, 0o700) }
}
mkdirP(tmpDir)

let base = "\(nowNs)-\(getpid())"
let tmpPath = tmpDir + "/" + base + ".tmp"
let finalPath = dir + "/" + base + ".event"
let fd = open(tmpPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
guard fd >= 0 else { bail() }
var bytes = Array(header.utf8); bytes.append(contentsOf: payload)
var off = 0
while off < bytes.count {
    let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + off, $0.count - off) }
    if n <= 0 { break }
    off += n
}
close(fd)
if rename(tmpPath, finalPath) != 0 { unlink(tmpPath) }
notify_post("dev.lidless.inbox")   // optional wake-up hint (~free)
exit(0)
```

Hook wiring examples (exact schemas belong to the agent-hooks research doc; these are for orientation, M):
- Claude Code `~/.claude/settings.json`: `{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"$HOME/Applications/Lidless.app/Contents/Helpers/lidless\" emit claude Stop"}]}]}}`
- Codex `~/.codex/config.toml`: `notify = ["/Users/<you>/Applications/Lidless.app/Contents/Helpers/lidless", "emit", "codex", "notify"]`. Codex appends the JSON as the last argv, which the CLI stores as the payload. Verified with a synthetic `agent-turn-complete` argv.
- Always use an **absolute path** to the CLI. GUI-launched IDEs (VS Code, Cursor) often have a different `PATH`. An optional convenience symlink is `~/.local/bin/lidless`, which already exists on `PATH` for this user.

### 6.6 App side: `EventInbox` (core library, verified)

```swift
public enum EventInbox {
    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let p = environment["LIDLESS_INBOX"], !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Lidless/inbox", directoryHint: .isDirectory)
    }
    public struct Received: Sendable { public var fileName: String; public var result: Result<AgentEvent, any Error>; public var receivedAtNanos: UInt64 }

    public static func drain(_ dir: URL) -> [Received] { /* list, sort, read, AgentEvent.parse, delete; bad -> dir/bad/ */ }

    /// Watch the directory and stream drained events; cancelling the consuming Task tears the source down.
    public static func watch(_ dir: URL, safetyInterval: Duration = .seconds(30)) -> AsyncStream<Received> {
        AsyncStream { continuation in
            try? FileManager.default.createDirectory(at: dir.appending(path: ".tmp"), withIntermediateDirectories: true)
            let queue = DispatchQueue(label: "lidless.inbox", qos: .utility)
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continuation.finish(); return }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
            source.setEventHandler { for r in drain(dir) { continuation.yield(r) } }
            source.setCancelHandler { close(fd) }
            let timer = DispatchSource.makeTimerSource(queue: queue)              // safety re-drain
            let secs = Double(safetyInterval.components.seconds)
            timer.schedule(deadline: .now() + secs, repeating: secs, leeway: .seconds(5))
            timer.setEventHandler { for r in drain(dir) { continuation.yield(r) } }
            continuation.onTermination = { _ in source.cancel(); timer.cancel() }
            source.activate(); timer.activate()
            queue.async { for r in drain(dir) { continuation.yield(r) } }        // events queued while not running
        }
    }
}
```

This compiles cleanly in the **nonisolated library**. If you paste the same closures into the MainActor-default app target or into `main.swift`, they trap at runtime (§9).

Why a vnode source and not FSEvents: for a single directory, a `DISPATCH_SOURCE_TYPE_VNODE` source on an `O_EVTONLY` fd fires right after the `rename` (0–1 ms measured) with no coalescing latency to tune. FSEvents (`FSEventStreamCreate`) is the right tool for recursive trees. That is not needed here (M).

---

## 7. libproc / sysctl from Swift (verified; `LidlessCore/ProcessScanner.swift`)

Key signatures as imported into Swift 6.3 (H):
- `proc_listallpids(_ buffer: UnsafeMutableRawPointer!, _ buffersize: Int32) -> Int32`. With `nil, 0` it returns the **count**. With a buffer, pass the size in **bytes**; the return value is the count.
- `proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &proc_bsdinfo, Int32(MemoryLayout<proc_bsdinfo>.size))` (size 136). The return value equals the size on success. Fields: `pbi_ppid`, `pbi_uid`, `pbi_comm` (16-char tuple), `pbi_name` (32-char tuple), `pbi_start_tvsec`, `e_tdev` (`0xFFFFFFFF` = NODEV, i.e. no tty).
- `proc_pidpath(pid, &buf, UInt32(4*MAXPATHLEN))`.
- `proc_pid_rusage(pid, RUSAGE_INFO_V4, ptr)` where `ptr: UnsafeMutablePointer<rusage_info_t?>`. Use `withUnsafeMutablePointer(to: &ri) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }`.
- `proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &proc_vnodepathinfo, size)`. Read cwd from `pvi_cdir.vip_path` (a tuple; read it with `withUnsafeBytes`).
- `sysctl([CTL_KERN, KERN_PROCARGS2, pid])`. The buffer layout is `int32 argc | exec_path\0 | \0-padding | argv… | envp…`. Parse argv only.

Measured results (H, verified):

| Fact | Evidence |
|---|---|
| **`ri_user_time` / `ri_system_time` (and `pti_total_user/system`) are mach absolute-time ticks on Apple Silicon**, not ns. `mach_timebase_info` = **125/3** (41.67 ns/tick). | pid 76720: raw sum read as ns = 14.25 s; × 125/3 = **593.72 s**; `ps -o time` = **9:53.72** ✓. pid 96888: 72.83 s vs `ps` 1:12.83 ✓ |
| `PROC_PIDTBSDINFO` **fails with EPERM for other users' processes**. `PROC_PIDT_SHORTBSDINFO` (`proc_bsdshortinfo`: `pbsi_ppid`, `pbsi_uid`, `pbsi_comm`) and `sysctl KERN_PROC_PID` (`kinfo_proc`) work for **all** pids. Use them to walk parent chains through root-owned `login`. | 634 pids: TBSDINFO ok=420 (`errno 1` ×213), SHORTBSDINFO ok=633, KERN_PROC_PID ok=633, `proc_pid_rusage` ok=420 |
| **Native Claude Code: `pbi_comm` = `pbi_name` = version string** ("2.1.296"). The binary is `~/.local/share/claude/versions/<semver>` (the symlink `~/.local/bin/claude` points there). Match on **argv[0] basename** or the path, never on comm. Claude also runs `ugrep` from the same binary (argv[0] `ugrep`), and its daemon children rewrite argv[0] (`"claude bg-spare"`, `"claude bg-pty-host"`). | scanner output, 13 matches |
| **`proc_pidpath` returns nil when the executable was replaced by an auto-update** (old version file deleted). The pids running 2.1.288 and 2.1.289 had `path=nil`. Fall back to argv[0]. | scanner output |
| Cost for ~590 pids (release build) | `PROC_PIDTBSDINFO` **0.32 ms** total · `proc_pidpath` 1.07 ms · `proc_pid_rusage` 0.74 ms · `PROC_PIDVNODEPATHINFO` 0.64 ms · `KERN_PROCARGS2` **9.6 ms with a fresh 1 MiB (KERN_ARGMAX) buffer per pid → 3.2 ms with one reused 1 MiB buffer → 2.4 ms with a reused 16 KiB buffer** (no ENOMEM for 420 pids; short buffers truncate silently, and argv comes first) |
| Full scan (every call, every pid) | **~9.8 ms median** with the reused 64 KiB argv buffer (15.4 ms before). A cheap scan (list + BSD info only) takes **0.29–0.34 ms**. Inside the app, the agent scan found 12 agent processes in 17.6 ms on its first run. |

Recommended scan strategy: run a cheap pass every few seconds (`proc_listallpids` + `PROC_PIDTBSDINFO`, filtered to `pbi_uid == getuid()`). Fetch argv, path, rusage and cwd only for candidates and for new pids. Cache by `(pid, pbi_start_tvsec)` to survive pid reuse. Compute CPU% as Δ`cpuNanos` / Δwall.

Observed on this machine (H): every busy Claude Code session had a child **`caffeinate -i -t 300`** (pids 2091 and 3447, parents 96888 and 76720), visible via `IOPMCopyAssertionsByProcess` / `pmset -g assertions` as `PreventUserIdleSystemSleep "caffeinate command-line tool"`. This is a cheap "Claude is working" signal (M). Note that `-i` does **not** prevent lid-close sleep.

---

## 8. IOKit from Swift (verified read-only)

```swift
import IOKit; import IOKit.ps; import IOKit.pwr_mgt

// IOPMrootDomain properties (exact registry keys: "AppleClamshellState", "AppleClamshellCausesSleep", "SleepDisabled")
let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
defer { IOObjectRelease(svc) }
let closed = IORegistryEntryCreateCFProperty(svc, kAppleClamshellStateKey as CFString, kCFAllocatorDefault, 0)?
    .takeRetainedValue() as? Bool
```
Probe output: `RootDomainState(clamshellClosed: false, clamshellCausesSleep: false, sleepDisabled: false)`. This matches `ioreg -r -n IOPMrootDomain`. `kAppleClamshellStateKey` and `kAppleClamshellCausesSleepKey` **are** imported as Swift strings (H).

**Constants that are C macros are not imported into Swift.** Define them by hand. The values were derived from SDK headers `IOMessage.h`, `IOReturn.h`, `mach/error.h` and `pwr_mgt/IOPM.h` (H):

```swift
// iokit_family_msg(sub_iokit_powermanagement, 0x100) = (0x38<<26) | (13<<14) | 0x100
let kIOPMMessageClamshellStateChange: UInt32 = 0xE003_4100   // arg bits: kClamshellStateBit=1<<0, kClamshellSleepBit=1<<1
// iokit_common_msg(x) = 0xE0000000 | x
let kIOMessageCanSystemSleep: UInt32     = 0xE000_0270
let kIOMessageSystemWillSleep: UInt32    = 0xE000_0280
let kIOMessageSystemWillNotSleep: UInt32 = 0xE000_0290
let kIOMessageSystemHasPoweredOn: UInt32 = 0xE000_0300
let kIOMessageSystemWillPowerOn: UInt32  = 0xE000_0320
```
Swift reports `cannot find 'kIOMessageCanSystemSleep' in scope` for the macros (verified).

**Clamshell interest notification.** This is the C-callback → `AsyncStream` trampoline. It is Swift 6 clean, and registration returned `KERN_SUCCESS` (verified). The lid was not closed during research.

```swift
public final class ClamshellObserver {              // not Sendable: own it from one actor / the MainActor
    private final class Box: Sendable {              // only Sendable state crosses into the C callback
        let continuation: AsyncStream<ClamshellEvent>.Continuation
        init(_ c: AsyncStream<ClamshellEvent>.Continuation) { continuation = c }
    }
    public let events: AsyncStream<ClamshellEvent>
    private let port: IONotificationPortRef
    private var notifier: io_object_t = IO_OBJECT_NULL
    private let box: Box
    private let queue = DispatchQueue(label: "lidless.iokit")

    public init?() {
        let (stream, cont) = AsyncStream.makeStream(of: ClamshellEvent.self, bufferingPolicy: .bufferingNewest(16))
        events = stream; box = Box(cont)
        guard let p = IONotificationPortCreate(kIOMainPortDefault) else { return nil }
        port = p
        IONotificationPortSetDispatchQueue(port, queue)          // callbacks arrive on `queue`
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(root) }
        let callback: IOServiceInterestCallback = { refcon, _, messageType, messageArgument in   // @convention(c): no captures
            guard let refcon, messageType == 0xE003_4100 else { return }
            let box = Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue()
            let bits = Int(bitPattern: messageArgument)                                         // bitfield smuggled in a pointer
            box.continuation.yield(ClamshellEvent(closed: bits & 1 != 0, causesSleep: bits & 2 != 0))
        }
        guard IOServiceAddInterestNotification(port, root, kIOGeneralInterest, callback,
                                               Unmanaged.passUnretained(box).toOpaque(), &notifier) == KERN_SUCCESS
        else { IONotificationPortDestroy(port); return nil }
    }
    deinit { if notifier != IO_OBJECT_NULL { IOObjectRelease(notifier) }; IONotificationPortDestroy(port); box.continuation.finish() }
}
```

**Sleep/wake (`IORegisterForSystemPower`).** It registered successfully (verified). You **must** answer `kIOMessageCanSystemSleep` and `kIOMessageSystemWillSleep` with `IOAllowPowerChange(rootPort, Int(bitPattern: messageArgument))`, or `IOCancelPowerChange` (which can only veto **idle** sleep). If you don't, the system waits about 30 s. The root port is only known after registration returns. Pass it to the callback through `Mutex<io_connect_t>` (`import Synchronization`, macOS 15+) inside the Sendable box. Tear down with `IODeregisterForSystemPower(&notifier)`, `IOServiceClose(root)` and `IONotificationPortDestroy`.

**Power source:**
- `IOPSCopyPowerSourcesInfo()?.takeRetainedValue()`
- `IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue()` → "Battery Power" / "AC Power"
- `IOPSCopyPowerSourcesList` + `IOPSGetPowerSourceDescription`, with keys `kIOPSCurrentCapacityKey`, `kIOPSMaxCapacityKey`, `kIOPSIsChargingKey`, `kIOPSTimeToEmptyKey`

Probe output: `Battery Power, 77 %, not charging, 213 min`. For change notifications, use `notify_register_dispatch(kIOPSNotifyPowerSource, …)` or `IOPSNotificationCreateRunLoopSource` (M, not prototyped).

**Assertions.** `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)` / `IOPMAssertionRelease(id)` compiles as an RAII `final class PowerAssertion: Sendable`. It was **not executed**. `IOPMCopyAssertionsByProcess(&Unmanaged<CFDictionary>?)` (read-only) works and lists pid → assertion types (verified). Note: no user-level assertion prevents **clamshell** sleep. That requires `SleepDisabled` (root) or the external-display clamshell conditions; see the power research doc.

---

## 9. Swift 6 strict-concurrency patterns and the pitfalls hit

Patterns that compiled with **zero warnings** and ran correctly (H, verified):

1. **App target: `.defaultIsolation(MainActor.self)`** (SE-0466, settable per target in SwiftPM 6.2).
   - The model is `@Observable final class AppModel` and is implicitly `@MainActor`.
   - Keep non-UI fields `@ObservationIgnored`.
   - `@NSApplicationDelegateAdaptor` owns the model.
2. **Start monitors in `applicationDidFinishLaunching`, not in `.task {}` on the `MenuBarExtra` content.** That view only exists while the popover is open.
3. **Library target stays nonisolated** (no default isolation). C resources such as fds, IONotificationPorts and DispatchSources live in `final class` owners. The owners expose `AsyncStream`s, which the MainActor model consumes with `for await` inside `Task { [weak self] in … }`. The loop body runs on the main actor (verified: `onMain=true`).
4. **C callback trampolines:** a `@convention(c)` closure with no captures, plus a `final class Box: Sendable` that holds only Sendable things (`AsyncStream.Continuation`, `Mutex<…>`), passed through `Unmanaged.passUnretained(box).toOpaque()` as `refcon`. The owner keeps `box` alive.
5. **Off-main work:** `@concurrent nonisolated static func scanAgents() async -> [ProcSnapshot]`. Verified: with `NonisolatedNonsendingByDefault` on, a plain `nonisolated async` function called from the main actor **runs on the main thread** (`true`). The `@concurrent` version does not (`false`). Without the upcoming feature, both run off-main. Since Xcode 26 templates turn the feature on, **mark every CPU/syscall-heavy async function `@concurrent`**.
6. **Polling:** `try await Task.sleep(for: .seconds(5), tolerance: .seconds(2))` in a Task loop is simpler than `Timer` and lets the OS coalesce wakeups. The idle prototype app had **~14–15 MiB phys_footprint**, 0.16 s total CPU (mostly startup), and **4 interrupt wakeups per 8 s** with a 5 s poll (verified via `proc_pid_rusage`).
7. **Small shared state touched from callbacks:** `Mutex` from `import Synchronization` (macOS 15+). It is Sendable with no `@unchecked`.

Pitfalls hit, with exact diagnostics (H, verified):

| # | Pitfall | Symptom | Fix |
|---|---|---|---|
| 1 | Closure passed to `DispatchSource.setEventHandler`, `NWListener` handlers, `DistributedNotificationCenter.addObserver(…queue: nil)` or `notify_register_dispatch` **from `main.swift` top-level code or a MainActor-isolated method** | No compile diagnostic. **Runtime crash** `EXC_BREAKPOINT/SIGTRAP` (exit 133) in `_dispatch_assert_queue_fail ← dispatch_assert_queue ← _swift_task_checkIsolatedSwift ← swift_task_isCurrentExecutorWithFlagsImpl`. The closure inherited `@MainActor` and ran on a background queue. | Write `{ @Sendable in … }`, or build the closure inside a nonisolated library function (as `EventInbox.watch` does) |
| 2 | `Timer.scheduledTimer { _ in self.ticks += 1 }` in a MainActor type | `warning: main actor-isolated property 'ticks' can not be mutated from a Sendable closure` | `MainActor.assumeIsolated { … }` (Timer on the main run loop), or use a `Task.sleep` loop |
| 3 | `Thread.isMainThread` inside an async function | `error: class property 'isMainThread' is unavailable from asynchronous contexts` | Use `pthread_main_np() != 0` for diagnostics, or better, express isolation with types |
| 4 | `nonisolated async` work silently on main (feature 5 above) | UI hitches | `@concurrent` |
| 5 | `notify_post` | `error: cannot find 'notify_post' in scope` with only `import Darwin` | `import notify` |
| 6 | `String(cString: [CChar])` | `warning: 'init(cString:)' is deprecated: Use String(decoding: array, as: UTF8.self) instead, after truncating the null termination.` | `String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)` |
| 7 | IOKit message macros | `cannot find 'kIOMessageCanSystemSleep' in scope` | Hand-defined constants (§8) |
| 8 | `NWConnection` with a unix path of 104 bytes or more | SIGTRAP inside the initializer | Check length first |
| 9 | Test readiness race | Senders ran before the listener's sources were armed, so events were missed | Create a readiness marker after everything is armed |

---

## 10. Testing (verified)

- `swift test` with the Xcode 26.6 toolchain runs **XCTest and Swift Testing in one invocation**. Output: `Executed 1 test, with 0 failures` (XCTest), then `✔ Test run with 9 tests in 2 suites passed` (Swift Testing; parameterized `@Test(arguments:)`, `#expect`, `#require`, `#expect(throws:)` all work). Full `swift test`, including the build, took about 10 s.
- **Testing an executable target works.** `@testable import LidlessApp` (a SwiftUI `@main` App with MenuBarExtra) passed `@MainActor @Test func appModelStartsEmpty()`.
- **CLI integration test:** a test target that lists `"LidlessCLI"` in its dependencies makes `swift test` link the `lidless` binary into the products dir. The test locates it via `Bundle.main.bundleURL` (the `.xctest` bundle) → `deletingLastPathComponent()` → `lidless`, spawns it with `LIDLESS_INBOX` pointing at a temp dir, and parses the drop with `EventInbox.drain`. It also asserts **stdout is empty** and the exit status is 0 (verified passing).
- Side note: Foundation `Process` spawning the CLI took about 65–70 ms per launch, compared with about 4 ms via `posix_spawn` or Python. That is test-harness overhead only.
- Recommended test split:
  - `LidlessCoreTests`: parsing, inbox, matcher, scanner self-check (`ProcessScanner.scan { $0.pbi_pid == getpid() }`), timebase (`numer == 125 && denom == 3` on Apple Silicon), and read-only IOKit reads.
  - `LidlessAppTests`: model logic only.
  - Never request notification authorization or register login items in tests.

---

## 11. Agent-drivable dev loop (all commands verified unless noted)

```bash
swift build                                  # debug, ~10 s clean / ~1-2 s incremental
swift test                                   # XCTest + Swift Testing
scripts/build-app.sh debug                   # or release (default); SIGN_ID=... VERSION=... optional
LIDLESS_INBOX=/tmp/x LIDLESS_DEBUG_LOG=/tmp/x.log build/Lidless.app/Contents/MacOS/Lidless   # foreground run, real bundle
build/Lidless.app/Contents/Helpers/lidless emit claude Stop <<<'{"session_id":"t"}'           # inject an event
open build/Lidless.app                       # normal launch (registers with LaunchServices)
codesign -dv --verbose=4 build/Lidless.app; codesign -d -r- build/Lidless.app
xed .                                        # open the package in Xcode (edit/debug; "Run" = bare binary -> no notifications)
```

For research, the prototype app accepted `--probe <file>` (a read-only self-report, then terminate) and `--exit-after <s>`. Keep something like `--exit-after` in debug builds so agents can run the app without ever signalling it.

Not run (it writes outside the scratchpad); suggested `scripts/install.sh` (L):
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh release
DEST="${DEST:-$HOME/Applications}"; mkdir -p "$DEST" "$HOME/.local/bin"
rm -rf "$DEST/Lidless.app" && ditto build/Lidless.app "$DEST/Lidless.app"
ln -sf "$DEST/Lidless.app/Contents/Helpers/lidless" "$HOME/.local/bin/lidless"
open "$DEST/Lidless.app"
```
(For upgrades, first ask the running app to quit, e.g. with a `lidless emit lidless quit` control event that the app honours. Avoid `osascript … quit`, which needs Automation TCC.)

---

## Recommendations for Lidless

1. **Adopt the SwiftPM-only layout** (§1) with the verified `Package.swift`, `Info.plist` and `build-app.sh` (§2–4). Do not add an `.xcodeproj`. If an icon is wanted, add `Resources/AppIcon.icns` (via `iconutil`) plus `CFBundleIconFile`. Alternatively, compile an asset catalog with `xcrun actool` (present, version 26.6) inside the script.
2. **Name the products `LidlessApp` and `lidless`.** Rename the app binary to `Contents/MacOS/Lidless`. Ship the CLI at `Contents/Helpers/lidless` with its own signing identifier `dev.lidless.cli`.
3. **Signing:** make `SIGN_ID` default to the Apple Development identity when `security find-identity -v -p codesigning` finds one, else fall back to `-`. This keeps TCC and Login-Items identity stable across rebuilds. Sign inside-out with `--options runtime`. Developer ID and notarization are only needed for distribution to others, which requires the paid program; for now, document "build from source".
4. **Hook IPC = file-drop inbox:**
   - Use the Darwin-only CLI and the two-part file format (§6).
   - The app watches with a vnode source, re-drains every 30 s, and drains at launch.
   - CLI contract: no stdout, exit 0 always, 2 s `alarm` watchdog, 300 ms stdin idle timeout, 4 MiB cap.
   - Keep the inbox at mode 0700. Treat payloads as untrusted. Cap the files processed per drain, and garbage-collect `bad/` and stale `.tmp/` files older than a day.
5. **Core/UI split:**
   - All logic goes in `LidlessCore` (nonisolated, testable).
   - The app target is MainActor-by-default and holds wiring only.
   - Every closure handed to GCD, IOKit, Network or notify is either created in core code or explicitly `@Sendable`.
   - Heavy async work is `@concurrent`.
   - Bridge C callbacks to `AsyncStream` through Sendable boxes.
6. **Process scanning:**
   - Run a cheap BSD-info pass on a 3–5 s `Task.sleep` with tolerance, and fetch argv/path/rusage/cwd only for candidates.
   - Reuse a 64 KiB `KERN_PROCARGS2` buffer.
   - Use `PROC_PIDT_SHORTBSDINFO` to walk parents.
   - Convert `ri_*_time` with `mach_timebase_info`.
   - Detect Claude by argv[0] or path (`/.local/share/claude/versions/`), never by `pbi_comm`, and exclude `ugrep`/`rg`.
7. **Power:** use `ClamshellObserver` and `SystemPowerObserver` exactly as in §8, with hand-defined message constants. Always ack sleep messages.
8. **Notifications:**
   - Create `UNUserNotificationCenter` only when `Bundle.main.bundleURL.pathExtension == "app"`.
   - Request authorization from a user action in the popover (first-run onboarding).
   - Implement `nonisolated func userNotificationCenter(_:willPresent:) async -> UNNotificationPresentationOptions { [.banner, .sound, .list] }`. This compiled in the MainActor-default target.
   - Local Mac notifications are a bonus; phone delivery goes through an HTTPS relay (separate doc).
9. **Launch at login:**
   - Offer a toggle that calls `SMAppService.mainApp.register()`/`unregister()`.
   - Read `status` on every launch: `.notFound` before the first registration is normal; re-register if the user opted in and the status is not `.enabled`.
   - If ad-hoc registration proves flaky, fall back to `SMAppService.agent(plistName:)` with a plist in `Contents/Library/LaunchAgents` (`BundleProgram` = `Contents/MacOS/Lidless`, `KeepAlive` true, which also gives crash-relaunch).
   - Avoid `SMAppService.daemon` and any root helper in v1.
10. **MenuBarExtra:** use `.menuBarExtraStyle(.window)`. Apple: "An app that only shows in the menu bar will be automatically terminated if the user removes the extra from the menu bar" ([MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)). Lidless must keep running, so prefer the `MenuBarExtra(isInserted:)` initializer and verify that hiding the item does not quit the app.
11. **Tests:** Swift Testing by default. Keep one XCTest only if needed. Include the CLI integration test (§10) so the hook contract (no stdout, exit 0, parseable drop) is enforced in CI or by agents.

---

## Risks / unknowns

- **Not verified, to avoid changing system state:**
  - actual notification authorization and delivery for an ad-hoc bundle;
  - `SMAppService.mainApp.register()` / `.agent` with ad-hoc signing;
  - signing with the Apple Development identity (possible keychain prompt);
  - clamshell callback delivery (the lid was never closed);
  - the visual rendering of the MenuBarExtra (no screenshot, since Screen Recording TCC would be needed).

  Each needs one interactive check by the user.
- **Ad-hoc identity churn:** every rebuild changes the cdhash, which re-prompts TCC (TN3127). It may also affect SMAppService and BTM records (suspected by the Insomnia PR, unconfirmed). Mitigation: the Apple Development identity, plus re-checking status at launch.
- **Agent sandboxes:**
  - The CLI may run inside an agent's sandbox (Codex Seatbelt `workspace-write`, Gemini CLI sandbox profiles, Claude Code's sandbox). There, writes to `~/Library/Application Support/Lidless/inbox` might be denied.
  - Not verified. A plausible fallback is a second inbox in the per-user temp dir (`confstr(_CS_DARWIN_USER_TEMP_DIR)`, the same for the app and the CLI), which both sides would watch.
  - Verify per agent in the hooks research.
- **stdin held open by an agent:** this costs up to 300 ms per hook (the poll timeout), still under most hook timeouts. A hung CLI is impossible because of the 2 s `alarm` → `_exit(0)`.
- **Spoofing:** any same-user process can drop events, post distributed notifications or connect to sockets. This is the same for every IPC option. Never act destructively (shutdown) on a single event; corroborate with process state.
- **`KERN_PROCARGS2` with a short buffer:** it truncated silently in testing (no ENOMEM for 420 processes with 16 KiB). M confidence that this holds for all processes. 64 KiB is used to be safe.
- **Network.framework unix sockets** misbehave silently or trap on paths of 104 bytes or more. This only matters if sockets are added later.
- **Distributed notifications** are documented as expensive, with "unbounded" latency, possibly "dropped", and not secure ([DistributedNotificationCenter](https://developer.apple.com/documentation/foundation/distributednotificationcenter)). They are not suitable as the primary channel.
- **Toolchain drift:** Xcode 26.6 ships SDK 26.5. `--build-system swiftbuild` is a preview with a different bin path. A future Swift may change the default; the script uses `--show-bin-path`, which handles that.
- **Distribution to others** needs either the paid Developer ID plus notarization (flagged) or build-from-source. Homebrew casks that fail Gatekeeper are being disabled (secondary sources).
- **Leftover from the research run:** launching the prototype with `open` registered `dev.lidless.research-proto` (in the temp scratchpad) with LaunchServices. This is harmless and is pruned when the bundle disappears. No notification, login-item, TCC, pmset or keychain state was touched.

---

## Sources

- Apple: [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) · [register()](https://developer.apple.com/documentation/servicemanagement/smappservice/register()) · [agent(plistName:)](https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:)) · [daemon(plistName:)](https://developer.apple.com/documentation/servicemanagement/smappservice/daemon(plistname:)) · [SMAppService.Status](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum)
- Apple: [TN3127 Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) · [Placing content in a bundle](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle) · [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra) · [DistributedNotificationCenter](https://developer.apple.com/documentation/foundation/distributednotificationcenter) · [NWEndpoint](https://developer.apple.com/documentation/network/nwendpoint)
- Apple forums: [757463 privileged daemon "unidentified developer"](https://developer.apple.com/forums/thread/757463) · [719862 SMAppService status](https://developer.apple.com/forums/thread/719862) · [756756 unix socket + Network framework](https://developer.apple.com/forums/thread/756756) · [837941 macOS 26.5 UN remote push](https://developer.apple.com/forums/thread/837941)
- Swift: [Swift 6.2 released (2025-09-15)](https://www.swift.org/blog/swift-6.2-released/) · [Swift 6.3 released (2026-03-24)](https://swift.org/blog/swift-6.3-released/)
- Third-party: [desktop-notifier docs (ad-hoc sufficient for UN)](https://desktop-notifier.readthedocs.io/) · [Insomnia PR #35 (ad-hoc + SMAppService.mainApp)](https://github.com/krishhgg/Insomnia/pull/35) · [theevilbit: SMAppService notes](https://theevilbit.github.io/posts/smappservice/) · [OSnews: Sequoia Gatekeeper bypass removal](https://www.osnews.com/story/141055/bug-or-intentional-macos-15-1-completely-removes-ability-to-launch-unsigned-applications/) · [TomatoBar #102 (Homebrew Gatekeeper cask deprecation)](https://github.com/ivoronin/TomatoBar/issues/102)
- Local verification commands: `swift --version`, `xcodebuild -version`, `xcrun --show-sdk-version`, `swift build/test`, `scripts/build-app.sh`, `codesign -dv/-d -r-/--verify`, `spctl --assess`, `security find-identity -v -p codesigning`, `vtool -show-build`, `otool -L`, `ioreg -r -n IOPMrootDomain`, `pmset -g assertions`, `ps -axo …`, plus the prototype probes `LidlessProbe procs|units|bench|percall|power|listen`, `IPCBench` and `snips/*`.
