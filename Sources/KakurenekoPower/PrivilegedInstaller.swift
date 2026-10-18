// KakurenekoPower — PrivilegedInstaller: one-prompt install/uninstall of the sudoers rule + root fail-safe, and the
// side-effect-free health check.
// OWNER: agent "power". Spec card: docs/ARCHITECTURE.md §9.4. Brief §7.1; R01 §5; DECISIONS D3; ARCHITECTURE §6.
//
// The admin prompt goes through the injected `AdministratorScriptRunning` (gated: dry-run only records
// `admin.script`). The health check is read-only: `sudo -n -l …` through the privileged runner, `launchctl print`
// through the subprocess runner (`.readOnly`), and a plain read of the installed root fail-safe script.

import KakurenekoKit
import Foundation

/// One-time admin install (sudoers + root fail-safe) and its health check.
public final class PrivilegedInstaller: PrivilegedInstalling {
    private let paths: Paths
    private let privileged: any PrivilegedCommandRunning
    private let subprocess: any SubprocessRunning
    private let administrator: any AdministratorScriptRunning
    private let clock: any KakurenekoClock
    private let logger: KakurenekoLogger
    private let dryRun: DryRunGate?
    private let failsafeScriptURL: URL
    private let launchDaemonPlistURL: URL
    private let generator: PrivilegedScriptGenerator

    /// The error `install()` throws for a fake home with the gate off (a fake home must never be baked into the root
    /// fail-safe, and a dev run must never touch the real root install).
    static let homeOverrideMessage = "KAKURENEKO_HOME override"

    /// Binding signature. `privileged` runs the read-only `sudo -n -l` check; `subprocess` runs
    /// `launchctl print system/com.kakureneko.failsafe` (read-only); `administrator` runs the admin prompt.
    /// - Parameter dryRun: the gate consulted by `install()`/`uninstall()`. When nil, the gate of the gated
    ///   `administrator` (`DryRunAdministratorScriptRunner`) is used; with neither, the gate counts as OFF.
    public convenience init(
        paths: Paths,
        privileged: any PrivilegedCommandRunning,
        subprocess: any SubprocessRunning,
        administrator: any AdministratorScriptRunning,
        clock: any KakurenekoClock = SystemClock(),
        logger: KakurenekoLogger = KakurenekoLogger(.power),
        dryRun: DryRunGate? = nil
    ) {
        self.init(paths: paths, privileged: privileged, subprocess: subprocess, administrator: administrator,
                  clock: clock, logger: logger, dryRun: dryRun, failsafeScriptURL: RootPaths.failsafeScript,
                  launchDaemonPlistURL: RootPaths.launchDaemonPlist)
    }

    /// Designated (internal) initializer: tests point `failsafeScriptURL` and `launchDaemonPlistURL` at temp files.
    init(
        paths: Paths,
        privileged: any PrivilegedCommandRunning,
        subprocess: any SubprocessRunning,
        administrator: any AdministratorScriptRunning,
        clock: any KakurenekoClock,
        logger: KakurenekoLogger,
        dryRun: DryRunGate?,
        failsafeScriptURL: URL,
        launchDaemonPlistURL: URL
    ) {
        self.paths = paths
        self.privileged = privileged
        self.subprocess = subprocess
        self.administrator = administrator
        self.clock = clock
        self.logger = logger
        self.dryRun = dryRun ?? (administrator as? DryRunAdministratorScriptRunner)?.gate
        self.failsafeScriptURL = failsafeScriptURL
        self.launchDaemonPlistURL = launchDaemonPlistURL
        self.generator = PrivilegedScriptGenerator(userName: paths.userName)
    }

    /// The heartbeat path the app touches (and the fail-safe must watch).
    var heartbeatPath: String { paths.heartbeatFile.path(percentEncoded: false) }

    /// True when side effects are only logged.
    private var gateIsOn: Bool { dryRun?.isOn ?? false }

    // MARK: - PrivilegedInstalling

    /// `sudo -n -l /usr/bin/pmset -a disablesleep 1` exits 0 AND `launchctl print system/com.kakureneko.failsafe` exits
    /// 0 AND the heartbeat path parsed from the installed fail-safe equals `paths.heartbeatFile` AND the installed
    /// fail-safe and LaunchDaemon plist are exactly what this version generates (a missing, emptied or edited script
    /// is no fail-safe: a loaded daemon running `/bin/bash <missing>` protects nothing). A file the user cannot read
    /// (EACCES) cannot be verified and is only reported.
    @concurrent
    public func healthCheck() async -> PrivilegedStatus {
        var problems: [String] = []

        let sudoRule: Bool
        do {
            let result = try await privileged.run(.checkSudoRule)
            sudoRule = result.succeeded
            if !sudoRule { problems.append("sudo rule missing") }
        } catch {
            sudoRule = false
            problems.append("sudo rule check failed: \(error.localizedDescription)")
        }

        let failsafe: Bool
        do {
            let result = try await subprocess.run(SubprocessRequest(
                executable: RootPaths.launchctl,
                arguments: ["print", "system/\(KakurenekoID.launchDaemonLabel)"],
                timeout: .seconds(10),
                maxOutputBytes: 256 << 10,
                effect: .readOnly
            ))
            failsafe = result.succeeded
            if !failsafe { problems.append("fail-safe daemon not loaded") }
        } catch {
            failsafe = false
            problems.append("fail-safe check failed: \(error.localizedDescription)")
        }

        let installed = Self.read(failsafeScriptURL)
        var parsed: String?
        var mismatch = false
        var damaged = false
        switch installed {
        case .text(let text):
            parsed = PrivilegedScriptGenerator.parseHeartbeatPath(fromFailsafeScript: text)
            if let parsed {
                mismatch = Self.normalized(parsed) != Self.normalized(heartbeatPath)
                if mismatch {
                    problems.append("fail-safe watches \(parsed), expected \(heartbeatPath) (reinstall closed-lid mode)")
                }
                if text != generator.failsafeScript(heartbeatPath: parsed) {
                    damaged = true
                    problems.append("the installed fail-safe script differs from this version's (reinstall closed-lid mode)")
                }
            } else if failsafe {
                damaged = true
                problems.append("could not read the fail-safe's heartbeat path (reinstall closed-lid mode)")
            }
        case .missing:
            if failsafe {
                damaged = true
                problems.append("the fail-safe script is missing (reinstall closed-lid mode)")
            }
        case .unreadable:
            if failsafe { problems.append("could not read the fail-safe's heartbeat path") }
        }
        if failsafe {
            switch Self.read(launchDaemonPlistURL) {
            case .text(let plist) where plist != generator.launchDaemonPlist:
                damaged = true
                problems.append("the fail-safe's LaunchDaemon differs from this version's (reinstall closed-lid mode)")
            case .missing:
                damaged = true
                problems.append("the fail-safe's LaunchDaemon plist is missing (reinstall closed-lid mode)")
            case .text, .unreadable:
                break
            }
        }

        let status = PrivilegedStatus(
            sudoRuleInstalled: sudoRule,
            failsafeLoaded: failsafe,
            checkedAt: clock.now(),
            detail: problems.isEmpty ? "installed" : problems.joined(separator: "; "),
            failsafeHeartbeatPath: parsed,
            heartbeatPathMismatch: mismatch,
            failsafeScriptMismatch: damaged
        )
        logger.info("privileged health check: sudo \(sudoRule), fail-safe \(failsafe), heartbeat mismatch \(mismatch), fail-safe damaged \(damaged)")
        return status
    }

    enum InstalledFile: Equatable {
        case text(String)
        case missing
        /// Exists but cannot be read by this user (EACCES …): cannot be verified.
        case unreadable
    }

    /// Read-only, ≤ 1 MiB.
    static func read(_ url: URL) -> InstalledFile {
        do {
            guard let data = try AtomicFile.readIfExists(url) else { return .missing }
            guard data.count <= 1 << 20 else { return .unreadable }
            return .text(String(decoding: data, as: UTF8.self))
        } catch {
            return .unreadable
        }
    }

    /// Runs `install-privileged.sh <user> <heartbeat>` INLINE with one admin prompt (no script file: root must never
    /// run or install code a same-user process could rewrite while the dialog is open). Refuses a fake home with the
    /// gate off.
    @concurrent
    public func install() async throws {
        try refuseFakeHomeForReal(operation: "install")
        let user = paths.userName
        guard PrivilegedScriptGenerator.isValidUserName(user) else {
            throw SideEffectError.failed("unsupported user name for the sudoers rule: \(user)")
        }
        guard PrivilegedScriptGenerator.isValidHeartbeatPath(heartbeatPath) else {
            throw SideEffectError.failed("unsupported heartbeat path: \(heartbeatPath)")
        }
        logger.notice("running the privileged install (one admin prompt)")
        let output = try await administrator.runAsAdministrator(
            script: generator.installScript, name: Self.installScriptName, arguments: [user, heartbeatPath]
        )
        logger.notice("privileged install finished: \(Self.lastLine(output))")
    }

    /// Admin-prompt uninstall: clear the flag, bootout, remove the plist, the drop-in and the root support dir;
    /// `visudo -c`. Refuses a fake home with the gate off (a dev run must not remove the real install).
    @concurrent
    public func uninstall() async throws {
        try refuseFakeHomeForReal(operation: "uninstall")
        logger.notice("running the privileged uninstall (one admin prompt)")
        let output = try await administrator.runAsAdministrator(
            script: generator.uninstallScript, name: Self.uninstallScriptName, arguments: []
        )
        logger.notice("privileged uninstall finished: \(Self.lastLine(output))")
    }

    public func scripts() -> PrivilegedScripts { generator.scripts }

    // MARK: - Internals

    private func refuseFakeHomeForReal(operation: String) throws {
        if paths.isHomeOverridden && !gateIsOn {
            logger.error("privileged \(operation) refused: the home is overridden (\(paths.displayPath(paths.home))) and dry-run is off")
            throw SideEffectError.failed(Self.homeOverrideMessage)
        }
    }

    /// `$0` of the inline scripts.
    static let installScriptName = "install-privileged.sh"
    static let uninstallScriptName = "uninstall-privileged.sh"

    static func normalized(_ path: String) -> String {
        URL(filePath: path, directoryHint: .notDirectory).standardizedFileURL.path(percentEncoded: false).trimmingSlash
    }

    private static func lastLine(_ output: String) -> String {
        let line = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return line.isEmpty ? "(no output)" : String(line.prefix(200))
    }
}
