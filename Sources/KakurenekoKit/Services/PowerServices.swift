import Foundation

/// Power mechanisms (brief §7.1–7.2). Implemented by `KakurenekoPower.PowerController`.
/// The §7.3 state machine itself lives in KakurenekoCoordinator; this protocol only performs actions
/// and reads state.
///
/// Isolation: `final class … : Sendable`. IOKit reads are synchronous; mutating actions go through
/// injected side-effect protocols (`PrivilegedCommandRunning`, `SystemSleeping`, `ShutdownRequesting`,
/// `DisplaySleeping`) so dry-run and tests never touch the system. In dry-run the controller keeps a
/// *simulated* `SleepDisabled` flag so arm/disarm "succeed" without polling the kernel.
///
/// The controller remembers whether it REALLY armed (`armedForReal`: gate off at arm time). If the gate state
/// at disarm differs from the one used at arm, it logs an error and throws
/// `SideEffectError.failed("dry-run toggled while really armed")` instead of silently simulating the undo of a
/// real action (the coordinator must disarm BEFORE flipping the gate, see `DryRunGate.setRequested`).
public protocol PowerControlling: Sendable {
    /// Reconciles internal state at launch (no system changes).
    func start() async
    /// IOPMrootDomain `SleepDisabled` + `AppleClamshellState`. `sleepDisabled` is the simulated flag in dry-run;
    /// `kernelSleepDisabled` is ALWAYS the real kernel value.
    func kernelFlags() -> KernelPowerFlags
    /// Arm: `sudo -n /usr/bin/pmset -a disablesleep 1`, poll the kernel until `SleepDisabled == true`
    /// (≤ 5 s, 100 ms steps via the injected clock), create the `PreventUserIdleSystemSleep` assertion
    /// "Kakureneko: agent active", begin `ProcessInfo` activity. Throws `SideEffectError` (e.g. `.notPermitted`
    /// without the sudoers rule, `.timedOut` if the kernel never reports the flag).
    func arm() async throws
    /// Disarm: `… disablesleep 0`, poll until `false` (≤ 5 s), release assertion + activity. NOT short-circuited
    /// on internal state: whenever the kernel reads `SleepDisabled == true` it runs the command (launch reconcile
    /// must clear a flag left by a crashed process); a no-op only when the kernel reads false.
    func disarm() async throws
    /// Termination path only (coordinator SIGTERM/INT/HUP/QUIT handler — a non-async context): runs the injected
    /// privileged runner's `.setSleepDisabled(false)` in a detached task and waits ≤ `timeout`. Acts only when
    /// this process really armed; dry-run aware. Returns true when the flag is (or already was) clear.
    func disarmSynchronously(timeout: Duration) -> Bool
    /// Touches `Paths.heartbeatFile` (mtime = now; creates it 0600, dir 0700) ONLY when this process really armed
    /// (gate off at arm time). In dry-run it records ledger action `power.heartbeat` and returns: a dry-run app
    /// must never keep the root fail-safe from clearing a REAL stale flag. Called by the 15 s tick while armed.
    func touchHeartbeat() throws
    /// `IOPMSleepSystem` (retry once on `0xE00002E2`, fallback `pmset sleepnow`) via `SystemSleeping`.
    func sleepNow() async throws
    /// Polite shutdown (Apple Event to loginwindow) via `ShutdownRequesting`.
    func requestShutdown() async throws
    /// The shutdown's sleep fallback, handed to a detached helper that outlives the app (`SystemSleeping
    /// .scheduleDetachedSleep`): called by `prepareForTermination` when the app quits while a shutdown request is out.
    func scheduleDetachedSleep(after delay: Duration) throws
    /// `pmset displaysleepnow` via `DisplaySleeping`.
    func displaySleepNow() async throws
    /// Plays the lid-close "Submarine" chime (bag hint; when is `PowerSettings.lidCloseSound`). Harmless; plays in dry-run too.
    func playLidCloseChime()
    /// Fresh `PowerSnapshot` (battery, thermal, network, displays, user idle, lid, flag incl. `kernelSleepDisabled`).
    func snapshot() async -> PowerSnapshot
}

/// Power/lid/sleep events (brief §7.2). Implemented by `KakurenekoPower.PowerMonitor`.
///
/// Isolation: `final class … : Sendable`; IOKit callbacks use `@convention(c)` trampolines with a
/// `Sendable` box (R08 §8), Network/notify/NSWorkspace observers are created in this nonisolated module.
/// Sleep messages are ALWAYS acknowledged (`IOAllowPowerChange`): `willSleep` carries a
/// `PowerChangeAcknowledger` that is auto-allowed after ≤ 8 s if the consumer has not called `allow()`.
public protocol PowerEventSource: Sendable {
    /// Registers clamshell interest (+ 1 Hz `AppleClamshellState` poll backup, which also emits `.userActivity`
    /// while the lid is closed), `IORegisterForSystemPower`, `NWPathMonitor`, display reconfiguration,
    /// NSWorkspace session/power-off observers, and a 15 s snapshot timer. Idempotent. Callers subscribe first.
    func start() async
    func stop() async
    /// Fan-out stream. A new subscriber first receives the latest `.snapshot` if any — never a stale edge
    /// (`AsyncBroadcaster(replayLatest: true, replayFilter: { $0.isSnapshot })`).
    func events() -> AsyncStream<PowerEvent>
}

/// Safety policy (brief §7.4). Implemented by `KakurenekoPower.SafetyMonitor`.
///
/// Isolation: synchronous, deterministic, `final class … : Sendable` (Mutex). `evaluate` remembers durations
/// (thermal serious for 60 s, network unsatisfied for 15 min) between calls; `armingBlocker` is stateless.
public protocol SafetyEvaluating: Sendable {
    /// Call with every snapshot while the lid is closed and the Mac is held awake (≥ every 15 s).
    /// Returns the first guard that trips, or nil. Guards: battery floor (and warning level ≥ early,
    /// timeToEmpty < limit, draining on AC below the floor), on-battery-not-allowed, thermal critical /
    /// pressure ≥ trapping immediately, serious / heavy for `thermalSeriousSeconds`, network offline for
    /// `networkOfflineMinutes`, closed-lid duration ≥ `maxClosedLidHours`.
    func evaluate(_ snapshot: PowerSnapshot, closedSince: Date, settings: SafetySettings, now: Date) -> SafetyTrip?
    /// STATELESS: may the Mac be (or stay) armed with the lid OPEN? nil = allowed. Blocks on: on battery and
    /// `!allowOnBattery`; battery ≤ floor; warning level ≥ early; timeToEmpty < limit; draining on AC below the
    /// floor; thermal ≥ serious; pressure ≥ heavy. Checked before Disarmed → Armed and on every snapshot while
    /// Armed with the lid open (blocked → disarm, not sleep). Never touches `evaluate`'s duration state.
    func armingBlocker(_ snapshot: PowerSnapshot, settings: SafetySettings) -> SafetyTrip?
    /// Forget accumulated durations (lid opened, disarmed).
    func reset()
}

/// Generated privileged-install artifacts (brief §7.1; R01 §5.3–5.4 renamed).
public struct PrivilegedScripts: Sendable, Hashable {
    /// `install-privileged.sh` (args: user name, heartbeat path).
    public var installScript: String
    /// `kakureneko-failsafe.sh` template containing `__HEARTBEAT_PATH__`.
    public var failsafeScriptTemplate: String
    /// LaunchDaemon plist text.
    public var launchDaemonPlist: String
    /// `uninstall-privileged.sh`.
    public var uninstallScript: String
    /// The exact sudoers line, e.g. `tester ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0`.
    public var sudoersLine: String

    public init(installScript: String, failsafeScriptTemplate: String, launchDaemonPlist: String, uninstallScript: String, sudoersLine: String) {
        self.installScript = installScript
        self.failsafeScriptTemplate = failsafeScriptTemplate
        self.launchDaemonPlist = launchDaemonPlist
        self.uninstallScript = uninstallScript
        self.sudoersLine = sudoersLine
    }
}

/// One-time admin install of the sudoers rule + root fail-safe (D3). Implemented by
/// `KakurenekoPower.PrivilegedInstaller`.
///
/// Isolation: `final class … : Sendable`. The admin prompt goes through `AdministratorScriptRunning`
/// (never called in tests). The health check is read-only (`SubprocessRunning`, `.readOnly`).
public protocol PrivilegedInstalling: Sendable {
    /// `sudo -n -l /usr/bin/pmset -a disablesleep 1` exits 0 AND `launchctl print system/com.kakureneko.failsafe`
    /// succeeds AND the heartbeat path parsed (read-only) from the installed root fail-safe script equals
    /// `Paths.heartbeatFile` (else `heartbeatPathMismatch`, not operational) AND the installed fail-safe and plist
    /// are what this version generates (else `failsafeScriptMismatch`, not operational).
    func healthCheck() async -> PrivilegedStatus
    /// Runs the install script INLINE with one admin prompt (no script file root could be handed by a same-user
    /// process). Throws `SideEffectError.failed("KAKURENEKO_HOME override")` when `paths.isHomeOverridden` and the gate
    /// is off (a fake home must never be baked into the root fail-safe).
    func install() async throws
    /// Admin-prompt uninstall: disarm, bootout, remove plist, sudoers drop-in and root support dir; `visudo -c`.
    func uninstall() async throws
    /// The generated text (preview + tests: `bash -n`, `plutil -lint`, `visudo -cf` can validate it read-only).
    func scripts() -> PrivilegedScripts
}
