@testable import KakurenekoPower
import KakurenekoKit
import Foundation
import Testing

/// Generated privileged artifacts are validated READ-ONLY (`bash -n`, `plutil -lint`, `visudo -cf` on temp files, the
/// input-check snippet with `bash -c`). No script is ever executed; no admin prompt is ever shown.
@Suite("Privileged scripts", .timeLimit(.minutes(1)))
struct PrivilegedScriptsTests {
    static let generator = PrivilegedScriptGenerator(userName: "tester")
    static let heartbeat = "/Users/tester/.kakureneko/run/heartbeat"

    @Test func sudoersLineIsExact() {
        #expect(Self.generator.sudoersLine
            == "tester ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0")
        #expect(Self.generator.sudoersFragment
            == "# Installed by Kakureneko. Delete this file to revoke.\ntester ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0\n")
        #expect(Self.generator.scripts.sudoersLine == Self.generator.sudoersLine)
    }

    @Test func everythingIsRenamed() {
        let scripts = Self.generator.scripts
        let all = [scripts.installScript, scripts.failsafeScriptTemplate, scripts.launchDaemonPlist, scripts.uninstallScript,
                   scripts.sudoersLine, Self.generator.sudoersFragment]
        for text in all {
            #expect(!text.lowercased().contains("lidless"))
        }
        #expect(scripts.installScript.contains(#"SUDOERS="/private/etc/sudoers.d/kakureneko""#))
        #expect(scripts.installScript.contains(#"LABEL="com.kakureneko.failsafe""#))
        #expect(scripts.installScript.contains(#"FAILSAFE="/Library/Application Support/Kakureneko/kakureneko-failsafe.sh""#))
        #expect(scripts.installScript.contains(#"PLIST="/Library/LaunchDaemons/com.kakureneko.failsafe.plist""#))
        #expect(scripts.installScript.contains(#"DIR="/Library/Application Support/Kakureneko""#))
        #expect(!scripts.installScript.contains("$SRC"))
        #expect(scripts.installScript.contains("<<'KAKURENEKO_FAILSAFE_TEMPLATE'"))
        #expect(scripts.installScript.contains(#"/bin/mv -f "$FAILSAFE.new" "$FAILSAFE""#))
        #expect(scripts.installScript.contains("/usr/sbin/visudo -cf \"$T\""))
        #expect(scripts.installScript.contains("/usr/sbin/visudo -c;") || scripts.installScript.contains("/usr/sbin/visudo -c\n"))
        #expect(scripts.installScript.contains("/usr/bin/install -m 0440 -o root -g wheel"))
        #expect(scripts.installScript.contains("/usr/bin/xattr -c"))
        #expect(scripts.installScript.contains(#"/bin/launchctl bootout "system/$LABEL""#))
        #expect(scripts.installScript.contains(#"/bin/launchctl bootstrap system "$PLIST""#))
        #expect(scripts.launchDaemonPlist.contains("<string>com.kakureneko.failsafe</string>"))
        #expect(scripts.launchDaemonPlist.contains("<string>/Library/Application Support/Kakureneko/kakureneko-failsafe.sh</string>"))
        #expect(scripts.failsafeScriptTemplate.contains("logger -t kakureneko-failsafe"))
        #expect(scripts.uninstallScript.contains(#"/bin/launchctl bootout "system/com.kakureneko.failsafe""#))
        #expect(scripts.uninstallScript.contains("/private/etc/sudoers.d/kakureneko"))
        #expect(scripts.uninstallScript.contains("/Library/LaunchDaemons/com.kakureneko.failsafe.plist"))
        #expect(scripts.uninstallScript.contains(#"/bin/rm -rf "/Library/Application Support/Kakureneko""#))
        #expect(scripts.uninstallScript.contains("/usr/bin/pmset -a disablesleep 0"))
        #expect(scripts.uninstallScript.contains("/usr/sbin/visudo -c"))
    }

    @Test func failsafeTemplateKeepsR01Behaviour() {
        let template = Self.generator.failsafeScriptTemplate
        #expect(template.contains("HB='__HEARTBEAT_PATH__'"))
        #expect(template.contains("MAX_AGE=150"))
        #expect(template.contains("HARD_FLOOR=7"))
        #expect(template.contains(#"[ "$(rd SleepDisabled)" = "Yes" ] || exit 0"#))
        #expect(template.contains("$PMSET -a disablesleep 0"))
        #expect(template.contains(#"[ "$(rd AppleClamshellState)" = "Yes" ] && $PMSET sleepnow"#))
        #expect(template.contains("kern.boottime"))
        // The heartbeat path sits on exactly one parseable line.
        let script = Self.generator.failsafeScript(heartbeatPath: Self.heartbeat)
        #expect(script.components(separatedBy: "\n").filter { $0.hasPrefix("HB=") } == ["HB='\(Self.heartbeat)'"])
        #expect(!script.contains("__HEARTBEAT_PATH__"))
    }

    @Test func scriptsPassBashSyntaxCheck() async throws {
        let paths = try temporaryPaths()
        defer { cleanup(paths) }
        let scripts = Self.generator.scripts
        let files: [(String, String)] = [
            ("install-privileged.sh", scripts.installScript),
            ("kakureneko-failsafe-template.sh", scripts.failsafeScriptTemplate),
            ("kakureneko-failsafe.sh", Self.generator.failsafeScript(heartbeatPath: Self.heartbeat)),
            ("uninstall-privileged.sh", scripts.uninstallScript),
        ]
        for (name, text) in files {
            let path = try writeTemp(text, named: name, in: paths.home)
            let result = try await runTool("/bin/bash", ["-n", path])
            #expect(result.exitCode == 0, "\(name): \(result.stderrString)")
            #expect(text.hasPrefix("#!/bin/bash\n"))
        }
    }

    @Test func launchDaemonPlistLintsAndHasTheRightKeys() async throws {
        let paths = try temporaryPaths()
        defer { cleanup(paths) }
        let plist = Self.generator.launchDaemonPlist
        let path = try writeTemp(plist, named: "com.kakureneko.failsafe.plist", in: paths.home)
        let lint = try await runTool("/usr/bin/plutil", ["-lint", path])
        #expect(lint.exitCode == 0, "\(lint.stdoutString)\(lint.stderrString)")
        let decoded = try #require(try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any])
        #expect(decoded["Label"] as? String == "com.kakureneko.failsafe")
        #expect(decoded["ProgramArguments"] as? [String] == ["/bin/bash", "/Library/Application Support/Kakureneko/kakureneko-failsafe.sh"])
        #expect(decoded["RunAtLoad"] as? Bool == true)
        #expect(decoded["StartInterval"] as? Int == 60)
    }

    @Test func installScriptEmbedsThePlistVerbatim() throws {
        let install = Self.generator.installScript
        let start = try #require(install.range(of: "<<'EOF'\n"))
        let end = try #require(install.range(of: "\nEOF\n", range: start.upperBound..<install.endIndex))
        let embedded = String(install[start.upperBound..<end.lowerBound])
        #expect(embedded == Self.generator.launchDaemonPlist.trimmingCharacters(in: .newlines))
    }

    @Test func sudoersFragmentPassesVisudo() async throws {
        let paths = try temporaryPaths()
        defer { cleanup(paths) }
        let good = try writeTemp(Self.generator.sudoersFragment, named: "kakureneko", in: paths.home)
        let result = try await runTool("/usr/sbin/visudo", ["-cf", good])
        #expect(result.exitCode == 0, "\(result.stdoutString)\(result.stderrString)")
        // Sanity: the validator does reject a malformed rule.
        let bad = try writeTemp("tester ALL=(root NOPASSWD /usr/bin/pmset\n", named: "broken", in: paths.home)
        #expect(try await runTool("/usr/sbin/visudo", ["-cf", bad]).exitCode != 0)
        // A dotted short name is valid sudoers syntax too.
        let dotted = try writeTemp(PrivilegedScriptGenerator(userName: "john.smith").sudoersFragment, named: "dotted", in: paths.home)
        #expect(try await runTool("/usr/sbin/visudo", ["-cf", dotted]).exitCode == 0)
    }

    struct InputCase: Sendable, CustomTestStringConvertible {
        var user: String
        var heartbeat: String
        var accepted: Bool
        var testDescription: String { "\(user) \(heartbeat.debugDescription) → \(accepted)" }
    }

    static let inputCases: [InputCase] = [
        InputCase(user: "tester", heartbeat: "/Users/tester/.kakureneko/run/heartbeat", accepted: true),
        InputCase(user: "john.smith", heartbeat: "/Users/john.smith/.kakureneko/run/heartbeat", accepted: true),
        InputCase(user: "john.smith", heartbeat: "/Volumes/x/home/.kakureneko/run/heartbeat", accepted: true),
        InputCase(user: "_svc-user", heartbeat: "/private/var/home/.kakureneko/run/heartbeat", accepted: true),
        InputCase(user: "Tom", heartbeat: "/Users/Tom/My Home/.kakureneko/run/heartbeat", accepted: true),
        InputCase(user: "1abc", heartbeat: "/Users/x/.kakureneko/run/heartbeat", accepted: false),
        InputCase(user: "bad user", heartbeat: "/Users/x/.kakureneko/run/heartbeat", accepted: false),
        InputCase(user: "", heartbeat: "/Users/x/.kakureneko/run/heartbeat", accepted: false),
        InputCase(user: "x;rm", heartbeat: "/Users/x/.kakureneko/run/heartbeat", accepted: false),
        InputCase(user: "tester", heartbeat: "relative/heartbeat", accepted: false),
        InputCase(user: "tester", heartbeat: "", accepted: false),
        InputCase(user: "tester", heartbeat: "/Users/tester/../root/heartbeat", accepted: false),
        InputCase(user: "tester", heartbeat: "/Users/te'ster/heartbeat", accepted: false),
        InputCase(user: "tester", heartbeat: "/Users/tester/a|b", accepted: false),
        InputCase(user: "tester", heartbeat: "/Users/tester/a&b", accepted: false),
        InputCase(user: "tester", heartbeat: #"/Users/tester/a\b"#, accepted: false),
        InputCase(user: "tester", heartbeat: "/Users/tester/a\nb", accepted: false),
    ]

    /// Runs ONLY the validation snippet (`bash -c`), never the install script.
    @Test(arguments: inputCases)
    func installInputChecks(_ input: InputCase) async throws {
        let snippet = PrivilegedScriptGenerator.inputValidation + "\necho ok\n"
        let result = try await runTool("/bin/bash", ["-c", snippet, "bash", input.user, input.heartbeat])
        if input.accepted {
            #expect(result.exitCode == 0, "\(result.stderrString)")
            #expect(result.stdoutString == "ok\n")
        } else {
            #expect(result.exitCode == 2)
            #expect(result.stdoutString.isEmpty)
        }
        // The Swift mirrors agree with bash.
        let swiftAccepts = PrivilegedScriptGenerator.isValidUserName(input.user)
            && PrivilegedScriptGenerator.isValidHeartbeatPath(input.heartbeat)
        #expect(swiftAccepts == input.accepted)
    }

    @Test func installScriptContainsTheChecksVerbatim() {
        let install = Self.generator.installScript
        #expect(install.contains(#"[[ "$U" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ && "$U" != "ALL" ]]"#))
        #expect(install.contains(#"[[ "$HB" == /* && "$HB" != *..* ]]"#))
        #expect(install.contains(PrivilegedScriptGenerator.inputValidation))
        #expect(install.contains("set -euo pipefail"))
    }

    /// The embedded heredoc + `sed` produce EXACTLY `failsafeScript(heartbeatPath:)` — what the health check compares
    /// the installed copy with. Runs only those lines of the install script, writing a temp file.
    @Test func theEmbeddedTemplateInstallsExactlyTheGeneratedFailsafe() async throws {
        let paths = try temporaryPaths()
        defer { cleanup(paths) }
        let lines = Self.generator.installScript.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.hasPrefix("/usr/bin/sed \"s|") })
        let end = try #require(lines.firstIndex { $0 == PrivilegedScriptGenerator.failsafeHeredocDelimiter })
        let snippet = lines[start...end].joined(separator: "\n") + "\n"
        let target = paths.home.appending(path: "failsafe.sh").path(percentEncoded: false)
        let heartbeat = "/Users/Tom Smith/.kakureneko/run/heartbeat"
        let result = try await runTool("/bin/bash", ["-c", "set -euo pipefail; HB=\"$1\"; FAILSAFE=\"$2\"\n" + snippet,
                                                     "bash", heartbeat, target])
        #expect(result.exitCode == 0, "\(result.stderrString)")
        let written = try String(contentsOfFile: target + ".new", encoding: .utf8)
        #expect(written == Self.generator.failsafeScript(heartbeatPath: heartbeat))
    }

    /// Review finding: a heartbeat with a FUTURE mtime (clock stepped back after the touch, or a forged `touch -t`)
    /// was never stale. Runs exactly the template's verdict snippet with synthetic values (never the root script).
    @Test(arguments: [
        (hb: 1_000_000, now: 1_000_010, boot: 900_000, reason: ""),
        (hb: 1_000_000, now: 1_000_200, boot: 900_000, reason: "heartbeat 200s old"),
        (hb: 800_000, now: 1_000_010, boot: 900_000, reason: "stale from before boot"),
        (hb: 1_000_000, now: 1_000_000 - 30, boot: 900_000, reason: ""),
        (hb: 1_000_000, now: 1_000_000 - 3600, boot: 900_000, reason: "heartbeat in the future"),
    ])
    func heartbeatVerdict(_ input: (hb: Int, now: Int, boot: Int, reason: String)) async throws {
        #expect(Self.generator.failsafeScriptTemplate.contains(PrivilegedScriptGenerator.heartbeatVerdict))
        let script = "hb=\(input.hb); now=\(input.now); boot=\(input.boot); MAX_AGE=150; reason=\"\"\n"
            + PrivilegedScriptGenerator.heartbeatVerdict + "\nprintf '%s' \"$reason\""
        let result = try await runTool("/bin/bash", ["-c", script])
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == input.reason)
    }

    @Test func heartbeatPathParser() {
        let parse = PrivilegedScriptGenerator.parseHeartbeatPath(fromFailsafeScript:)
        #expect(parse(Self.generator.failsafeScript(heartbeatPath: Self.heartbeat)) == Self.heartbeat)
        #expect(parse(Self.generator.failsafeScript(heartbeatPath: "/Users/Tom/My Home/.kakureneko/run/heartbeat"))
            == "/Users/Tom/My Home/.kakureneko/run/heartbeat")
        #expect(parse(Self.generator.failsafeScriptTemplate) == nil, "placeholder is not a path")
        #expect(parse("#!/bin/bash\nHB=\"/a/b\"   # comment\n") == "/a/b")
        #expect(parse("#!/bin/bash\n  HB=/a/b # comment\n") == "/a/b")
        #expect(parse("#!/bin/bash\nexit 0\n") == nil)
        #expect(parse("HB='/unterminated\n") == nil)
    }
}

/// `PrivilegedInstaller`: health check mapping, install/uninstall gating. Fakes only.
@Suite("PrivilegedInstaller", .timeLimit(.minutes(1)))
struct PrivilegedInstallerTests {
    /// A recording `launchctl` + scripted `sudo -n -l`, and the installed fail-safe at a temp path.
    final class Rig: Sendable {
        let paths: Paths
        let clock = TestClock()
        let sudo: ScriptedPrivilegedRunner
        let subprocess: FakeSubprocessRunner
        let administrator = RecordingAdministrator()
        let failsafe: URL
        let plist: URL
        let ledger = DryRunLedger()

        init(sudoExit: Int32 = 0, launchctlExit: Int32 = 0) throws {
            paths = try temporaryPaths()
            sudo = ScriptedPrivilegedRunner { _ in SubprocessResult(exitCode: sudoExit) }
            subprocess = FakeSubprocessRunner { _ in SubprocessResult(exitCode: launchctlExit) }
            failsafe = paths.home.appending(path: "root/kakureneko-failsafe.sh")
            plist = paths.home.appending(path: "root/com.kakureneko.failsafe.plist")
        }

        deinit { cleanup(paths) }

        func installer(dryRun: DryRunGate? = nil, administrator: (any AdministratorScriptRunning)? = nil) -> PrivilegedInstaller {
            PrivilegedInstaller(paths: paths, privileged: sudo, subprocess: subprocess,
                                administrator: administrator ?? self.administrator, clock: clock,
                                logger: KakurenekoLogger(.power), dryRun: dryRun, failsafeScriptURL: failsafe,
                                launchDaemonPlistURL: plist)
        }

        /// What `install-privileged.sh` leaves behind: the fail-safe for `heartbeat` and the LaunchDaemon plist.
        func installFailsafe(heartbeat: String) throws {
            let generator = PrivilegedScriptGenerator(userName: paths.userName)
            try FileManager.default.createDirectory(at: failsafe.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(generator.failsafeScript(heartbeatPath: heartbeat).utf8).write(to: failsafe)
            try Data(generator.launchDaemonPlist.utf8).write(to: plist)
        }

        var heartbeat: String { paths.heartbeatFile.path(percentEncoded: false) }
    }

    @Test func healthyInstall() async throws {
        let rig = try Rig()
        try rig.installFailsafe(heartbeat: rig.heartbeat)
        let status = await rig.installer().healthCheck()
        #expect(status.sudoRuleInstalled)
        #expect(status.failsafeLoaded)
        #expect(status.failsafeHeartbeatPath == rig.heartbeat)
        #expect(!status.heartbeatPathMismatch)
        #expect(status.isOperational)
        #expect(status.checkedAt == rig.clock.now())
        #expect(!status.simulated)
        #expect(status.detail == "installed")
        // Read-only probes only.
        #expect(rig.sudo.commands == [.checkSudoRule])
        let launchctl = try #require(rig.subprocess.requests.first)
        #expect(rig.subprocess.requests.count == 1)
        #expect(launchctl.executable == "/bin/launchctl")
        #expect(launchctl.arguments == ["print", "system/com.kakureneko.failsafe"])
        #expect(launchctl.effect == .readOnly)
        #expect(rig.administrator.recorded.isEmpty)
    }

    @Test func missingSudoRule() async throws {
        let rig = try Rig(sudoExit: 1)
        try rig.installFailsafe(heartbeat: rig.heartbeat)
        let status = await rig.installer().healthCheck()
        #expect(!status.sudoRuleInstalled)
        #expect(status.failsafeLoaded)
        #expect(!status.isOperational)
        #expect(status.detail?.contains("sudo rule missing") == true)
    }

    @Test func failsafeNotLoaded() async throws {
        let rig = try Rig(launchctlExit: 113)
        let status = await rig.installer().healthCheck()
        #expect(status.sudoRuleInstalled)
        #expect(!status.failsafeLoaded)
        #expect(status.failsafeHeartbeatPath == nil)
        #expect(!status.heartbeatPathMismatch)
        #expect(!status.isOperational)
        #expect(status.detail?.contains("fail-safe daemon not loaded") == true)
    }

    @Test func heartbeatPathMismatchIsNotOperational() async throws {
        let rig = try Rig()
        try rig.installFailsafe(heartbeat: "/Users/someone-else/.kakureneko/run/heartbeat")
        let status = await rig.installer().healthCheck()
        #expect(status.sudoRuleInstalled && status.failsafeLoaded)
        #expect(status.failsafeHeartbeatPath == "/Users/someone-else/.kakureneko/run/heartbeat")
        #expect(status.heartbeatPathMismatch)
        #expect(!status.isOperational)
        #expect(status.detail?.contains("/Users/someone-else/.kakureneko/run/heartbeat") == true)
        #expect(status.detail?.contains(rig.heartbeat) == true)
    }

    @Test func trailingSlashOrDotSegmentsAreNotAMismatch() async throws {
        let rig = try Rig()
        let dir = rig.paths.runDirectory.path(percentEncoded: false)
        try rig.installFailsafe(heartbeat: (dir.hasSuffix("/") ? dir : dir + "/") + "./heartbeat")
        let status = await rig.installer().healthCheck()
        #expect(!status.heartbeatPathMismatch)
        #expect(status.isOperational)
    }

    /// A fail-safe this user cannot read (EACCES) cannot be verified: reported, not counted as damaged.
    @Test func unreadableFailsafeWithLoadedDaemonIsReported() async throws {
        let rig = try Rig()
        try rig.installFailsafe(heartbeat: rig.heartbeat)
        chmod(rig.failsafe.path(percentEncoded: false), 0o000)
        defer { chmod(rig.failsafe.path(percentEncoded: false), 0o600) }
        let status = await rig.installer().healthCheck()
        #expect(status.failsafeHeartbeatPath == nil)
        #expect(!status.heartbeatPathMismatch)
        #expect(!status.failsafeScriptMismatch)
        #expect(status.detail?.contains("could not read the fail-safe's heartbeat path") == true)
    }

    @Test func throwingProbesCountAsMissing() async throws {
        let rig = try Rig()
        rig.sudo.setResponder { _ in throw SideEffectError.unavailable("no sudo") }
        rig.subprocess.setHandler { _ in throw SideEffectError.unavailable("no launchctl") }
        let status = await rig.installer().healthCheck()
        #expect(!status.sudoRuleInstalled && !status.failsafeLoaded && !status.isOperational)
    }

    @Test func installRefusesATemporaryHomeWithTheGateOff() async throws {
        let rig = try Rig()
        let installer = rig.installer(dryRun: .off())
        await #expect(throws: SideEffectError.failed("KAKURENEKO_HOME override")) { try await installer.install() }
        await #expect(throws: SideEffectError.failed("KAKURENEKO_HOME override")) { try await installer.uninstall() }
        #expect(rig.administrator.recorded.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: rig.paths.privilegedInstallScript.path(percentEncoded: false)))
    }

    @Test func unknownGateCountsAsOff() async throws {
        // No gate and an ungated administrator: a fake home must still be refused.
        let rig = try Rig()
        await #expect(throws: SideEffectError.failed("KAKURENEKO_HOME override")) { try await rig.installer().install() }
        #expect(rig.administrator.recorded.isEmpty)
    }

    @Test func publicInitTakesTheGateFromTheGatedAdministrator() async throws {
        let paths = try temporaryPaths()
        defer { cleanup(paths) }
        let ledger = DryRunLedger()
        let gate = DryRunGate.off()
        let real = RecordingAdministrator()
        let gated = DryRunAdministratorScriptRunner(passthrough: real, gate: gate, ledger: ledger)
        let installer = PrivilegedInstaller(paths: paths, privileged: ScriptedPrivilegedRunner(), subprocess: FakeSubprocessRunner(),
                                            administrator: gated, clock: TestClock())
        await #expect(throws: SideEffectError.failed("KAKURENEKO_HOME override")) { try await installer.install() }
        gate.setRequested(true)
        try await installer.install()
        #expect(real.recorded.isEmpty, "dry-run: the admin prompt is only ledgered")
        let entries = ledger.entries(action: "admin.script")
        #expect(entries.count == 1)
        #expect(entries.first?.detail == "would run install-privileged.sh with administrator privileges")
    }

    /// Review finding (TOCTOU): root used to run `/bin/bash <user-writable file>` and install the fail-safe from
    /// another user-writable file, both rewritable while the password dialog was open. The scripts now travel inline,
    /// and nothing is written to (or read from) the user's install directory.
    @Test func installRunsTheGeneratedScriptInlineAndWritesNoFiles() async throws {
        let rig = try Rig()
        try await rig.installer(dryRun: .alwaysOn()).install()
        let call = try #require(rig.administrator.recorded.first)
        #expect(rig.administrator.recorded.count == 1)
        let generator = PrivilegedScriptGenerator(userName: "tester")
        #expect(call.script == generator.installScript)
        #expect(call.name == "install-privileged.sh")
        #expect(call.arguments == ["tester", rig.heartbeat])
        for url in [rig.paths.privilegedInstallScript, rig.paths.failsafeScriptTemplate, rig.paths.privilegedUninstallScript] {
            #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)), "\(url.lastPathComponent)")
        }
        // The fail-safe template is embedded (quoted heredoc), never read from a file next to the script.
        #expect(generator.installScript.contains(generator.failsafeScriptTemplate + PrivilegedScriptGenerator.failsafeHeredocDelimiter + "\n"))
        #expect(!generator.installScript.contains("$SRC"))
        #expect(!generator.installScript.contains("dirname"))
    }

    @Test func dryRunUninstallRunsTheUninstallScriptInlineWithoutArguments() async throws {
        let rig = try Rig()
        try await rig.installer(dryRun: .alwaysOn()).uninstall()
        let call = try #require(rig.administrator.recorded.first)
        #expect(call.script == PrivilegedScriptGenerator(userName: "tester").uninstallScript)
        #expect(call.name == "uninstall-privileged.sh")
        #expect(call.arguments.isEmpty)
    }

    // MARK: Health check verifies the installed root artifacts

    /// A loaded daemon whose script was deleted runs `/bin/bash <missing>`: no fail-safe → not operational.
    @Test func aLoadedDaemonWithoutItsFailsafeScriptIsNotOperational() async throws {
        let rig = try Rig()
        let status = await rig.installer().healthCheck()
        #expect(status.sudoRuleInstalled && status.failsafeLoaded)
        #expect(status.failsafeScriptMismatch)
        #expect(!status.isOperational)
        #expect(status.detail?.contains("missing") == true)
    }

    @Test func anEmptiedOrEditedFailsafeIsNotOperational() async throws {
        let rig = try Rig()
        try rig.installFailsafe(heartbeat: rig.heartbeat)
        try Data().write(to: rig.failsafe) // a failed re-install truncated it
        var status = await rig.installer().healthCheck()
        #expect(status.failsafeScriptMismatch && !status.isOperational)

        // Keeps the HB line (so the old check passed) but never clears the flag.
        let generator = PrivilegedScriptGenerator(userName: rig.paths.userName)
        let tampered = generator.failsafeScript(heartbeatPath: rig.heartbeat).replacingOccurrences(of: "$PMSET -a disablesleep 0", with: "true")
        try Data(tampered.utf8).write(to: rig.failsafe)
        status = await rig.installer().healthCheck()
        #expect(status.failsafeHeartbeatPath == rig.heartbeat)
        #expect(!status.heartbeatPathMismatch)
        #expect(status.failsafeScriptMismatch && !status.isOperational)
    }

    @Test func aMissingOrForeignLaunchDaemonPlistIsNotOperational() async throws {
        let rig = try Rig()
        try rig.installFailsafe(heartbeat: rig.heartbeat)
        try Data("<plist/>".utf8).write(to: rig.plist)
        #expect(await rig.installer().healthCheck().failsafeScriptMismatch)
        try FileManager.default.removeItem(at: rig.plist)
        let status = await rig.installer().healthCheck()
        #expect(status.failsafeScriptMismatch && !status.isOperational)
    }

    @Test func invalidUserNameIsRefusedBeforeAnyPrompt() async throws {
        let base = try temporaryPaths()
        defer { cleanup(base) }
        let paths = Paths(home: base.home, userName: "bad user", userTempDirectory: base.userTempDirectory,
                          environment: [:], isHomeOverridden: true)
        let administrator = RecordingAdministrator()
        let installer = PrivilegedInstaller(paths: paths, privileged: ScriptedPrivilegedRunner(), subprocess: FakeSubprocessRunner(),
                                            administrator: administrator, clock: TestClock(), dryRun: .alwaysOn())
        await #expect(throws: SideEffectError.self) { try await installer.install() }
        #expect(administrator.recorded.isEmpty)
    }

    @Test func scriptsMatchTheGenerator() throws {
        let rig = try Rig()
        let scripts = rig.installer().scripts()
        #expect(scripts == PrivilegedScriptGenerator(userName: "tester").scripts)
        #expect(scripts.sudoersLine.hasPrefix("tester ALL=(root) NOPASSWD: "))
    }
}
