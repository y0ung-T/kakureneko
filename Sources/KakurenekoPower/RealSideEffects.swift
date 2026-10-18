// KakurenekoPower — the REAL system-mutating side effects (the coordinator wraps each with `SideEffects.gated`, so in
// dry-run none of these is ever reached). NEVER invoked by tests or agents: tests only construct them, or drive
// their pure parts (argv, AppleScript source, retry/fallback logic) through injected fakes.
// OWNER: agent "power". Spec card: docs/ARCHITECTURE.md §9.4 ("Real side effects"). Brief §7.1–7.2, §7.5;
// R01 §5.5, §9.

import AppKit
import CoreServices
import KakurenekoKit
import Foundation
import IOKit
import IOKit.pwr_mgt

// MARK: - sudo -n pmset

/// `/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 1|0` and `sudo -n -l …` through a REAL (ungated) runner.
/// The argv is `PrivilegedCommand.argv`, byte for byte (the sudoers rule matches arguments literally).
public struct SudoPrivilegedCommandRunner: PrivilegedCommandRunning {
    private let subprocess: any SubprocessRunning

    /// Binding signature.
    public init(subprocess: any SubprocessRunning) { self.subprocess = subprocess }

    public func run(_ command: PrivilegedCommand) async throws -> SubprocessResult {
        try await subprocess.run(Self.request(for: command))
    }

    /// The exact request: `sudo -n` never prompts (a missing rule fails fast with "a password is required").
    static func request(for command: PrivilegedCommand) -> SubprocessRequest {
        let argv = command.argv
        return SubprocessRequest(
            executable: argv[0],
            arguments: Array(argv.dropFirst()),
            timeout: .seconds(15),
            maxOutputBytes: 64 << 10,
            effect: command.effect
        )
    }
}

// MARK: - Sleep

/// `IOPMSleepSystem(IOPMFindPowerManagement(MACH_PORT_NULL))`, retry once on 0xE00002E2, fallback `pmset sleepnow`.
public struct IOPMSystemSleeper: SystemSleeping {
    private let subprocess: any SubprocessRunning
    private let sleepCall: @Sendable () -> IOReturn
    private let retryDelay: Duration
    private let spawnDetached: @Sendable ([String]) throws -> Void

    /// Binding signature.
    public init(subprocess: any SubprocessRunning) {
        self.init(subprocess: subprocess, sleepCall: IOPMSystemSleeper.requestSystemSleep, retryDelay: .milliseconds(500))
    }

    /// Internal seam: tests replace the IOKit call and the detached spawn (neither is EVER executed in tests).
    init(subprocess: any SubprocessRunning, sleepCall: @escaping @Sendable () -> IOReturn, retryDelay: Duration,
         spawnDetached: @escaping @Sendable ([String]) throws -> Void = IOPMSystemSleeper.posixSpawnDetached) {
        self.subprocess = subprocess
        self.sleepCall = sleepCall
        self.retryDelay = retryDelay
        self.spawnDetached = spawnDetached
    }

    /// `/bin/sh -c <detachedSleepScript> kakureneko-sleep-fallback <seconds>` in its own session, not waited for:
    /// it survives the app being quit by loginwindow and dies with the session if the shutdown goes through.
    public func scheduleDetachedSleep(after delay: Duration) throws {
        try spawnDetached(Self.detachedSleepArgv(after: delay))
    }

    static func detachedSleepArgv(after delay: Duration) -> [String] {
        ["/bin/sh", "-c", detachedSleepScript, "kakureneko-sleep-fallback", String(max(1, delay.components.seconds))]
    }

    /// Waits `$1` seconds, then sleeps the Mac only if the lid is still closed (open = the user is at the Mac, who
    /// also cancels the in-app fallback). `pmset sleepnow` needs no root.
    static let detachedSleepScript = #"/bin/sleep "$1"; "#
        + #"/usr/sbin/ioreg -r -n IOPMrootDomain -d 1 | /usr/bin/grep -q '"AppleClamshellState" = Yes' "#
        + #"&& exec \#(RootPaths.pmset) sleepnow; exit 0"#

    /// posix_spawn with /dev/null stdio, a new session (`POSIX_SPAWN_SETSID`), close-on-exec by default, default
    /// signal dispositions and an empty mask; never waited for (reaped by launchd once the app exits).
    static let posixSpawnDetached: @Sendable ([String]) throws -> Void = { arguments in
        guard let path = arguments.first else { throw SideEffectError.failed("posix_spawn: no executable") }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGPIPE, SIGCHLD, SIGALRM] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attributes, &argv, &envp)
        guard rc == 0 else { throw SideEffectError.failed("posix_spawn \(path): \(String(cString: strerror(rc)))") }
    }

    @concurrent
    public func sleepNow() async throws {
        var result = sleepCall()
        if result == IOKitReturn.notPermitted {
            // SleepDisabled may still be clearing (powerd applies prefs asynchronously): retry once.
            try? await Task.sleep(for: retryDelay)
            result = sleepCall()
        }
        if result == IOKitReturn.success { return }
        let fallback = try await subprocess.run(SubprocessRequest(
            executable: RootPaths.pmset, arguments: ["sleepnow"], timeout: .seconds(15), effect: .mutating))
        guard fallback.succeeded else {
            let stderr = fallback.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SideEffectError.commandFailed(
                exitCode: fallback.exitCode,
                stderr: "IOPMSleepSystem \(IOKitReturn.describe(result)); pmset sleepnow: \(stderr)")
        }
    }

    /// The real call (console user; no root needed — R01 §9.1).
    static let requestSystemSleep: @Sendable () -> IOReturn = {
        let connection = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard connection != IO_OBJECT_NULL else { return IOKitReturn.notPrivileged }
        defer { IOServiceClose(connection) }
        return IOPMSleepSystem(connection)
    }
}

// MARK: - Shutdown

/// Apple Event `aevt/shut` to `com.apple.loginwindow` (polite: apps may cancel it; needs Automation consent, which the
/// app requests during onboarding with `AEDeterminePermissionToAutomateTarget`).
public struct LoginWindowShutdownRequester: ShutdownRequesting {
    /// Binding signature.
    public init() {}

    @concurrent
    public func requestShutdown() async throws {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow")
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AppleEventCode.coreEventClass,
            eventID: AppleEventCode.shutDown,
            targetDescriptor: target,
            returnID: AppleEventCode.autoGenerateReturnID,
            transactionID: AppleEventCode.anyTransactionID
        )
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 30)
        } catch {
            throw Self.map(error as NSError)
        }
    }

    /// `errAEEventNotPermitted` / `…WouldRequireUserConsent` → `.notPermitted`; anything else → `.failed`.
    static func map(_ error: NSError) -> SideEffectError {
        switch error.code {
        case AppleEventCode.eventNotPermitted, AppleEventCode.eventWouldRequireUserConsent:
            .notPermitted("Automation permission for loginwindow is missing (\(error.code))")
        default:
            .failed("shutdown Apple Event failed (\(error.code)): \(error.localizedDescription)")
        }
    }
}

// MARK: - Display sleep

/// `/usr/bin/pmset displaysleepnow` (no root needed).
public struct PmsetDisplaySleeper: DisplaySleeping {
    private let subprocess: any SubprocessRunning

    /// Binding signature.
    public init(subprocess: any SubprocessRunning) { self.subprocess = subprocess }

    public func displaySleepNow() async throws {
        let result = try await subprocess.run(Self.request)
        guard result.succeeded else {
            throw SideEffectError.commandFailed(exitCode: result.exitCode,
                                                stderr: result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static let request = SubprocessRequest(executable: RootPaths.pmset, arguments: ["displaysleepnow"],
                                           timeout: .seconds(10), effect: .mutating)
}

// MARK: - Admin prompt

/// `NSAppleScript` `do shell script "/bin/bash -c " & quoted form of <script> & … with administrator privileges` (one
/// prompt), on the main thread. Runs in-process, so no Automation TCC is involved. The script text is part of the
/// AppleScript source compiled here: nothing root runs comes from a user-writable file.
public struct AppleScriptAdministratorRunner: AdministratorScriptRunning {
    /// Binding signature.
    public init() {}

    public func runAsAdministrator(script: String, name: String, arguments: [String]) async throws -> String {
        let source = Self.appleScriptSource(script: script, name: name, arguments: arguments)
        let outcome: Result<String, SideEffectError> = await MainActor.run {
            var errorInfo: NSDictionary?
            guard let script = NSAppleScript(source: source) else {
                return .failure(.failed("could not compile the administrator AppleScript"))
            }
            let output = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                return .failure(Self.map(errorInfo))
            }
            return .success(output.stringValue ?? "")
        }
        return try outcome.get()
    }

    /// `do shell script "/usr/bin/env -i PATH=… /bin/bash --noprofile --norc -c " & quoted form of "<script>" & " " &
    /// quoted form of "<name>" & " " & quoted form of "<arg>" … with administrator privileges`. Every value is an
    /// AppleScript string literal (`\` and `"` escaped) passed through `quoted form of`, so the shell sees each one as
    /// a single word. The root shell starts with an empty environment: nothing the user's session exports
    /// (`BASH_ENV`, exported functions, `PATH`) reaches it.
    static func appleScriptSource(script: String, name: String, arguments: [String]) -> String {
        var parts = ["\"\(rootShell) \"", "quoted form of \(appleScriptLiteral(script))", "\" \"",
                     "quoted form of \(appleScriptLiteral(name))"]
        for argument in arguments {
            parts.append("\" \"")
            parts.append("quoted form of \(appleScriptLiteral(argument))")
        }
        return "do shell script " + parts.joined(separator: " & ") + " with administrator privileges"
    }

    static let rootShell = "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash --noprofile --norc -c"

    /// An AppleScript string literal.
    static func appleScriptLiteral(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func map(_ info: NSDictionary) -> SideEffectError {
        let number = (info[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        let message = (info[NSAppleScript.errorMessage] as? String) ?? "unknown error"
        if number == AppleEventCode.userCanceled { return .notPermitted("administrator prompt cancelled") }
        return .failed("administrator script failed (\(number)): \(message)")
    }
}

// MARK: - Chime

enum SystemSound {
    /// `NSSound(named:)?.play()`; main actor (AppKit).
    @MainActor
    static func play(_ name: String) -> Bool {
        NSSound(named: NSSound.Name(name))?.play() ?? false
    }
}
