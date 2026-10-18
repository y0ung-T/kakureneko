// KakurenekoInstall — agent integrations (brief §3.6–3.7; ARCHITECTURE §9.7).
//
// `IntegrationManager` is the only public type. Installers (`Installers/`) are pure descriptions of which files
// hold which entries; splicers (`Splice/`) are pure, format-preserving text transforms. Every side effect lives
// here: phantom-install and helper checks, backups, atomic writes, re-parse + rollback, the install manifest,
// the Claude CLI, dry-run.

import KakurenekoKit
import Foundation
import Synchronization

/// Every agent integration (brief §3.6–3.7).
///
/// Isolation: a `Sendable` final class. Operations (statuses, previews, install/uninstall/repair, helper deployment)
/// run one at a time through an async FIFO lock (they all read and write the shared install manifest), and every
/// public method is `@concurrent`, so file I/O and CLI calls never run on the caller's actor (ARCHITECTURE §5).
public final class IntegrationManager: AgentIntegrating {
    private let paths: Paths
    /// The injected runner wrapped in Kit's dry-run switch: mutating CLI calls become `subprocess.run` ledger lines
    /// while the gate is on, even when the caller passed an ungated runner.
    private let subprocess: any SubprocessRunning
    private let dryRun: DryRunGate
    private let ledger: DryRunLedger
    private let clock: any KakurenekoClock
    private let logger: KakurenekoLogger
    let fileSystem: any InstallFileSystem
    let installers: [any IntegrationInstaller]
    private let claudeLocator: ClaudeCLILocator
    private let loginShell: LoginShellProbe
    private let opencodeVersion = Mutex<OpenCodeVersion?>(nil)
    private let lock = AsyncSerialLock()
    private let backups: BackupStore
    private let manifestStore: ManifestStore

    /// Binding signature.
    /// - Parameters:
    ///   - subprocess: the dry-run-gated runner. Mark `claude plugin install/uninstall/marketplace add/remove` as
    ///     `.mutating`, `claude plugin list --json` / `--version` as `.readOnly`. Every agent-CLI request sets
    ///     `extraEnvironment: paths.agentSubprocessEnvironment` + `DISABLE_AUTOUPDATER=1`.
    ///   - dryRun/ledger: when the gate is on, never write files; record "would write <path>" instead.
    public convenience init(
        paths: Paths,
        subprocess: any SubprocessRunning,
        dryRun: DryRunGate,
        ledger: DryRunLedger,
        clock: any KakurenekoClock = SystemClock(),
        logger: KakurenekoLogger = KakurenekoLogger(.install)
    ) {
        self.init(
            paths: paths,
            subprocess: subprocess,
            dryRun: dryRun,
            ledger: ledger,
            clock: clock,
            logger: logger,
            fileSystem: LiveInstallFileSystem(),
            claudeLocator: ClaudeCLILocator(),
            loginShell: LoginShellProbe()
        )
    }

    /// Full initializer (tests inject a file system that can corrupt writes and a CLI locator that ignores the
    /// Mac's real `/opt/homebrew/bin/claude`).
    init(
        paths: Paths,
        subprocess: any SubprocessRunning,
        dryRun: DryRunGate,
        ledger: DryRunLedger,
        clock: any KakurenekoClock,
        logger: KakurenekoLogger,
        fileSystem: any InstallFileSystem,
        claudeLocator: ClaudeCLILocator,
        loginShell: LoginShellProbe = LoginShellProbe(enabled: false),
        installers: [any IntegrationInstaller] = IntegrationManager.defaultInstallers
    ) {
        self.paths = paths
        self.subprocess = DryRunSubprocessRunner(passthrough: subprocess, gate: dryRun, ledger: ledger)
        self.dryRun = dryRun
        self.ledger = ledger
        self.clock = clock
        self.logger = logger
        self.fileSystem = fileSystem
        self.installers = installers
        self.claudeLocator = claudeLocator
        self.loginShell = loginShell
        backups = BackupStore(paths: paths, fileSystem: fileSystem)
        manifestStore = ManifestStore(paths: paths, fileSystem: fileSystem, logger: logger)
    }

    /// One installer per agent of `AgentID.installableInV1`.
    static var defaultInstallers: [any IntegrationInstaller] {
        var list: [any IntegrationInstaller] = [
            ClaudePluginInstaller(), CodexInstaller(), GeminiInstaller(), AgyInstaller(), CopilotInstaller(),
            CursorInstaller(), OpenCodeInstaller(), AiderInstaller(),
        ]
        list += ClaudeFamilyInstaller.all
        list.append(WindsurfInstaller())
        return list
    }

    var context: InstallContext {
        InstallContext(paths: paths, fileSystem: fileSystem, opencodeVersion: opencodeVersion.withLock { $0 })
    }

    /// Re-reads the installed opencode's version (read-only `opencode --version`, 10 s) before an opencode
    /// preview/install/status: older v1 needs the legacy plugin form. No opencode binary found → unknown.
    func refreshOpencodeVersion() async {
        var candidates = OpenCodeInstaller.binaryCandidates(paths)
        if let login = await loginShell.values(runner: subprocess, environment: agentEnvironment), let path = login.path {
            candidates += path.split(separator: ":").map { URL(filePath: String($0)).appending(path: "opencode").path(percentEncoded: false) }
        }
        guard let binary = candidates.first(where: { fileSystem.isExecutableFile(URL(filePath: $0)) }) else {
            opencodeVersion.withLock { $0 = nil }
            return
        }
        let request = SubprocessRequest(executable: binary, arguments: ["--version"],
                                        extraEnvironment: await cliEnvironment(for: binary), stdin: nil,
                                        timeout: .seconds(10), maxOutputBytes: 64 << 10, effect: .readOnly)
        let version = (try? await subprocess.run(request)).flatMap { $0.succeeded ? OpenCodeVersion.parse($0.stdoutString) : nil }
        opencodeVersion.withLock { $0 = version }
    }

    func installer(for agent: AgentID) -> (any IntegrationInstaller)? {
        installers.first { $0.agent == agent }
    }

    /// `extraEnvironment` of every agent-CLI request (ARCHITECTURE §9.7): a `KAKURENEKO_HOME` run never touches the
    /// real `~/.claude`.
    var agentEnvironment: [String: String] {
        paths.agentSubprocessEnvironment.merging(["DISABLE_AUTOUPDATER": "1"]) { $1 }
    }

    /// `agentEnvironment` + a `PATH` that finds the interpreter of a `#!/usr/bin/env node` CLI (npm, bun, nvm,
    /// Homebrew node, the legacy `~/.claude/local` wrapper): a GUI app inherits launchd's bare `PATH`
    /// (`AgentCLIEnvironment`).
    func cliEnvironment(for cli: String) async -> [String: String] {
        let login = await loginShell.values(runner: subprocess, environment: agentEnvironment)
        let path = AgentCLIEnvironment.searchPath(executable: cli, home: paths.home, loginShellPATH: login?.path,
                                                  inherited: ProcessInfo.processInfo.environment["PATH"])
        return agentEnvironment.merging(["PATH": path]) { $1 }
    }

    /// Notes for agents whose directory variable the user's login shell sets differently from this process
    /// (launched by launchd, Kakureneko cannot see `~/.zshrc` exports): the integration goes to the directory below,
    /// which the agent may not read.
    func loginShellDirectoryNote(for agent: AgentID) async -> String? {
        guard !paths.isHomeOverridden,
              let login = await loginShell.values(runner: subprocess, environment: agentEnvironment) else { return nil }
        let variable: String
        switch agent {
        case .claude: variable = "CLAUDE_CONFIG_DIR"
        case .codex: variable = "CODEX_HOME"
        case .copilot, .vscode: variable = "COPILOT_HOME"
        case .opencode: variable = "XDG_CONFIG_HOME"
        default: return nil
        }
        guard let shellValue = login.agentDirectories[variable] else { return nil }
        let own = paths.environment[variable].map { $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0 }
        let shell = shellValue.hasSuffix("/") && shellValue.count > 1 ? String(shellValue.dropLast()) : shellValue
        guard own != shell else { return nil }
        return "Your shell sets \(variable)=\(shellValue), but Kakureneko was started without it and uses its default "
            + "location. Run `launchctl setenv \(variable) \"\(shellValue)\"` and restart Kakureneko so the integration goes where \(agent.displayName) reads it."
    }

    // MARK: - AgentIntegrating

    @concurrent
    public func statuses() async -> [IntegrationStatus] {
        await lock.withLock {
            let manifest = manifestStore.load()
            var result: [IntegrationStatus] = []
            for agent in AgentID.installableInV1 {
                guard let installer = installer(for: agent) else {
                    result.append(IntegrationStatus(agent: agent, supported: false, configDirExists: false))
                    continue
                }
                result.append(await status(of: installer, manifest: manifest, claudeState: nil))
            }
            return result
        }
    }

    @concurrent
    public func preview(_ agent: AgentID, operation: InstallPlan.Operation) async throws -> InstallPlan {
        try await lock.withLock {
            let installer = try requireInstaller(agent)
            let manifest = manifestStore.load()
            var computed = try await compute(installer, operation, manifest: manifest)
            if operation != .uninstall, !dryRun.isOn, !computed.plan.isEmpty, !fileSystem.isExecutableFile(paths.hookBinary) {
                computed.plan.warnings.append("The Kakureneko hook helper is not deployed yet; installing will fail until Kakureneko deploys it.")
            }
            return computed.plan
        }
    }

    @concurrent
    public func install(_ agent: AgentID) async throws -> InstallResult {
        try await lock.withLock { try await perform(agent, .install) }
    }

    @concurrent
    public func uninstall(_ agent: AgentID) async throws -> InstallResult {
        try await lock.withLock { try await perform(agent, .uninstall) }
    }

    @concurrent
    public func repair(_ agent: AgentID) async throws -> InstallResult {
        try await lock.withLock { try await perform(agent, .repair) }
    }

    @concurrent
    public func deployHelper(from bundledHelper: URL) async throws -> HelperDeployment {
        try await lock.withLock { try deployHelperLocked(from: bundledHelper) }
    }

    // MARK: - Planning

    /// One file write of an operation.
    struct FileStep: Sendable {
        let file: ManagedFile
        /// Bytes before the operation (nil = the file did not exist).
        let before: Data?
        let beforeText: String?
        /// Desired text (nil = delete the file).
        let after: String?
        /// Whether the written text must contain our entries (install) or must not (uninstall/cleanup).
        let expectOurs: Bool
    }

    /// One `claude` CLI call.
    struct CommandStep: Sendable {
        let command: ClaudePluginInstaller.Command
        let request: SubprocessRequest
    }

    /// Everything `perform` needs, computed without side effects (beyond read-only CLI queries).
    struct ComputedOperation: Sendable {
        var plan: InstallPlan
        var steps: [FileStep]
        var commands: [CommandStep]
        var verify: CommandStep?
        var removeDirectories: [URL]
        /// Final manifest entries for the agent (install/repair; empty for uninstall).
        var manifestEntries: [InstallManifestEntry]
        /// The plan has CLI commands but no `claude` executable was found.
        var cliMissing: Bool
    }

    private func requireInstaller(_ agent: AgentID) throws -> any IntegrationInstaller {
        guard let installer = installer(for: agent) else {
            throw SideEffectError.unavailable("Kakureneko has no installer for \(agent.displayName)")
        }
        return installer
    }

    private func requireAvailable(_ installer: any IntegrationInstaller) throws {
        let context = context
        guard installer.isAvailable(context) else {
            let locations = installer.configDirectories(context).map(context.display).joined(separator: " or ")
            throw SideEffectError.unavailable(
                "\(installer.agent.displayName) is not set up on this Mac (\(locations.isEmpty ? "no config" : locations) not found)")
        }
    }

    func compute(
        _ installer: any IntegrationInstaller,
        _ operation: InstallPlan.Operation,
        manifest: InstallManifest
    ) async throws -> ComputedOperation {
        if installer is OpenCodeInstaller { await refreshOpencodeVersion() }
        let context = context
        if operation != .uninstall { try requireAvailable(installer) }
        let agent = installer.agent
        let entries = manifest.entries(for: agent)
        let now = clock.now()
        var steps: [FileStep] = []
        var finalEntries: [InstallManifestEntry] = []

        var files = installer.managedFiles(context)
        if operation == .uninstall { files += foreignFiles(entries, known: files) }

        for file in files {
            let data = try fileSystem.read(file.url)
            let text = try data.map { try InstallText.decode($0, path: file.path) }
            let previous = entries.last { $0.file == file.path }
            switch (operation, file.role) {
            case (.install, .target), (.repair, .target):
                let outcome = try file.splicer.install(into: text, previous: previous)
                let modified = outcome.text != text
                if modified {
                    steps.append(FileStep(file: file, before: data, beforeText: text, after: outcome.text, expectOurs: true))
                }
                // `sha256Before` names the user's file as it was before Kakureneko's entries went in (the backup
                // uninstall restores byte for byte). Updating entries of ours keeps it; re-adding entries the agent
                // dropped makes the current file the new original.
                let sha256Before: String? = if let previous, let text, file.splicer.containsOurs(text) {
                    previous.sha256Before
                } else if modified || previous == nil {
                    data.map(Digest.sha256Hex)
                } else {
                    previous?.sha256Before
                }
                finalEntries.append(InstallManifestEntry(
                    agent: agent,
                    file: file.path,
                    kind: file.kind,
                    sha256Before: sha256Before,
                    sha256After: Digest.sha256Hex(outcome.text),
                    chainedOriginal: outcome.chainedOriginal,
                    installedAt: (modified || previous == nil) ? now : (previous?.installedAt ?? now)
                ))
            case (.install, .cleanupOnly), (.repair, .cleanupOnly), (.uninstall, _):
                guard let text, file.splicer.containsOurs(text) else { continue }
                let desired: String?
                if operation == .uninstall, case .restore(let original) = exactRestoration(file, current: text, previous: previous, agent: agent) {
                    desired = original
                } else {
                    desired = try file.splicer.uninstall(from: text, previous: previous)
                }
                if desired != text {
                    steps.append(FileStep(file: file, before: data, beforeText: text, after: desired, expectOurs: false))
                }
            }
        }

        var computed = ComputedOperation(
            plan: InstallPlan(agent: agent, operation: operation),
            steps: steps,
            commands: [],
            verify: nil,
            removeDirectories: [],
            manifestEntries: finalEntries,
            cliMissing: false
        )
        if let claude = installer as? ClaudePluginInstaller {
            await planClaudeCommands(claude, operation, entries: entries, into: &computed)
        }
        for url in steps.map(\.file.url) + computed.removeDirectories {
            if let reason = ProtectedLocations.violation(url, paths: paths) {
                logger.error("refusing a planned change of a protected location for \(agent.rawValue)")
                throw InstallError.protectedLocation(path: context.display(url), reason: reason)
            }
        }

        computed.plan.changes = steps.map { step in
            FileChange(
                path: step.file.path,
                kind: step.beforeText == nil ? .create : (step.after == nil ? .delete : .modify),
                before: step.beforeText,
                after: step.after,
                unifiedDiff: UnifiedDiff.make(old: step.beforeText, new: step.after, label: context.display(step.file.url))
            )
        }
        computed.plan.commands = computed.commands.map {
            PlannedCommand(executable: $0.request.executable, arguments: $0.request.arguments, purpose: $0.command.purpose)
        }
        if operation != .uninstall, !computed.plan.isEmpty { computed.plan.followUpNote = installer.followUpNote }
        return computed
    }

    /// Claude: write the plugin files, then `marketplace add` + `plugin install` (stdin `/dev/null`), then verify
    /// with `plugin list --json`; uninstall = `plugin uninstall` + `marketplace remove` + delete the folder.
    private func planClaudeCommands(
        _ claude: ClaudePluginInstaller,
        _ operation: InstallPlan.Operation,
        entries: [InstallManifestEntry],
        into computed: inout ComputedOperation
    ) async {
        let context = context
        let cli = await claudeLocator.locate(paths: paths, fileSystem: fileSystem, runner: subprocess, environment: agentEnvironment)
        var commands: [ClaudePluginInstaller.Command] = []
        switch operation {
        case .install, .repair:
            if !computed.steps.isEmpty || cli == nil {
                commands = [claude.marketplaceAdd(context), claude.pluginInstall]
            } else {
                switch await queryClaudeState(cli: cli) {
                case .enabled: commands = []
                case .disabled: commands = [claude.pluginEnable]
                case .absent, .unknown: commands = [claude.marketplaceAdd(context), claude.pluginInstall]
                }
            }
            if !commands.isEmpty {
                computed.verify = step(claude.pluginList, cli: cli ?? "claude", environment: await cliEnvironment(for: cli ?? "claude"))
            }
        case .uninstall:
            let present = !entries.isEmpty || !computed.steps.isEmpty
                || claude.ownedDirectories(context).contains(where: fileSystem.exists)
            if present {
                commands = [claude.pluginUninstall, claude.marketplaceRemove]
                computed.removeDirectories = claude.ownedDirectories(context).filter(fileSystem.exists)
            }
        }
        let environment = await cliEnvironment(for: cli ?? "claude")
        computed.commands = commands.map { step($0, cli: cli ?? "claude", environment: environment) }
        if cli == nil, !commands.isEmpty {
            computed.cliMissing = true
            computed.plan.warnings.append(
                "The claude command was not found (looked in ~/.local/bin, Homebrew and your login shell's PATH).")
        }
    }

    private func step(_ command: ClaudePluginInstaller.Command, cli: String, environment: [String: String]) -> CommandStep {
        CommandStep(command: command, request: SubprocessRequest(
            executable: cli,
            arguments: command.arguments,
            extraEnvironment: environment,
            stdin: nil, // /dev/null
            timeout: command.effect == .mutating ? .seconds(120) : .seconds(30),
            maxOutputBytes: 1 << 20,
            effect: command.effect
        ))
    }

    /// `claude plugin list --json` (read-only; runs in dry-run too).
    private func queryClaudeState(cli: String?) async -> ClaudePluginState {
        guard let cli, let claude = installer(for: .claude) as? ClaudePluginInstaller else { return .unknown }
        let request = step(claude.pluginList, cli: cli, environment: await cliEnvironment(for: cli)).request
        guard let result = try? await subprocess.run(request) else { return .unknown }
        return ClaudePluginState.parse(result)
    }

    /// Manifest files that are not among the installer's current files (e.g. `CODEX_HOME` changed since the
    /// install): uninstall still cleans them, with the splicer of the same-named file.
    private func foreignFiles(_ entries: [InstallManifestEntry], known: [ManagedFile]) -> [ManagedFile] {
        let knownPaths = Set(known.map(\.path))
        var result: [ManagedFile] = []
        for entry in entries where !knownPaths.contains(entry.file) && !result.contains(where: { $0.path == entry.file }) {
            let url = URL(filePath: entry.file, directoryHint: .notDirectory)
            if let twin = known.first(where: { $0.url.lastPathComponent == url.lastPathComponent }) {
                result.append(ManagedFile(url: url, kind: entry.kind, splicer: twin.splicer))
            } else if entry.kind != .spliced {
                result.append(ManagedFile(url: url, kind: entry.kind, splicer: OwnedFileSplicer(
                    path: entry.file, content: "", validation: .text, locationIsOwned: entry.kind == .cliPlugin)))
            }
        }
        return result
    }

    enum RestoreDecision: Equatable {
        case notApplicable
        /// Put this text back (nil = delete the file: it did not exist before we created it).
        case restore(String?)
    }

    /// Uninstall of a file nobody touched since our install: put back the backed-up original byte for byte.
    ///
    /// Self-verifying: the backup whose SHA-256 is the manifest's `sha256Before` is used only when installing
    /// into it again yields exactly the current text (so current == original + our entries) and it holds nothing
    /// of ours. Otherwise the caller falls back to the surgical removal.
    func exactRestoration(_ file: ManagedFile, current: String, previous: InstallManifestEntry?, agent: AgentID) -> RestoreDecision {
        guard let previous else { return .notApplicable }
        let original: String?
        if let sha = previous.sha256Before {
            guard let data = backups.find(agent: agent, basename: file.url.lastPathComponent, sha256: sha),
                  let text = try? InstallText.decode(data, path: file.path) else { return .notApplicable }
            original = text
        } else {
            original = nil
        }
        if let original, file.splicer.containsOurs(original) { return .notApplicable }
        guard let reinstalled = try? file.splicer.install(into: original, previous: nil), reinstalled.text == current else {
            return .notApplicable
        }
        return .restore(original)
    }

    // MARK: - Applying

    private func perform(_ agent: AgentID, _ operation: InstallPlan.Operation) async throws -> InstallResult {
        let installer = try requireInstaller(agent)
        if operation != .uninstall {
            try requireAvailable(installer)
            if !dryRun.isOn, !fileSystem.isExecutableFile(paths.hookBinary) {
                throw SideEffectError.unavailable("hook helper not deployed")
            }
        }
        let now = clock.now()
        let manifest = manifestStore.load()
        let computed = try await compute(installer, operation, manifest: manifest)
        let context = context

        if dryRun.isOn {
            for step in computed.steps {
                let verb = step.after == nil ? "delete" : (step.before == nil ? "create" : "modify")
                ledger.record(.install, action: step.after == nil ? "install.delete" : "install.write",
                              detail: "would \(verb) \(context.display(step.file.url))")
            }
            for directory in computed.removeDirectories {
                ledger.record(.install, action: "install.delete", detail: "would delete \(context.display(directory))")
            }
            for command in computed.commands {
                _ = try? await subprocess.run(command.request) // the gated runner records `subprocess.run`
            }
            logger.notice("dry run \(operation.rawValue) \(agent.rawValue): \(computed.steps.count) file(s), \(computed.commands.count) command(s)")
            var messages = ["Dry run: nothing was written."]
            messages += computed.plan.warnings
            return InstallResult(
                plan: computed.plan,
                dryRun: true,
                messages: messages,
                status: await status(of: installer, manifest: manifest, claudeState: nil)
            )
        }

        if computed.cliMissing, operation != .uninstall {
            throw SideEffectError.unavailable("Claude Code CLI not found; install Claude Code or add it to ~/.local/bin")
        }

        var messages: [String] = []
        var backupPaths: [String] = []
        var claudeState: ClaudePluginState?

        if operation == .uninstall {
            if computed.cliMissing {
                messages.append("Claude Code's CLI was not found, so the plugin registration could not be removed; run `claude plugin uninstall \(KakurenekoID.claudePluginReference)` later.")
            } else {
                try await run(computed.commands)
                if !computed.commands.isEmpty { claudeState = .absent }
            }
            backupPaths = try apply(computed.steps, agent: agent, now: now)
            for directory in computed.removeDirectories {
                do {
                    try fileSystem.removeTree(directory)
                } catch {
                    logger.warning("could not remove \(context.display(directory)): \(error.localizedDescription)")
                }
            }
        } else {
            backupPaths = try apply(computed.steps, agent: agent, now: now)
            do {
                try await run(computed.commands)
            } catch {
                rollback(computed.steps)
                throw error
            }
            if let verify = computed.verify {
                let result = try? await subprocess.run(verify.request)
                claudeState = result.map(ClaudePluginState.parse) ?? .unknown
                switch claudeState {
                case .enabled?: break
                case .disabled?: messages.append("Claude Code lists the plugin but it is disabled; enable it with /plugin.")
                case .absent?: messages.append("Claude Code did not list the plugin after installing it; try Repair.")
                case .unknown?, nil: messages.append("Could not confirm the plugin with `claude plugin list`.")
                }
            }
        }

        // Manifest: drop the agent's entries, then record what holds our entries now.
        let stored = manifestStore.load()
        var updated = stored
        updated.entries.removeAll { $0.agent == agent }
        if operation != .uninstall { updated.entries += computed.manifestEntries }
        if ManifestStore.normalized(updated) != ManifestStore.normalized(stored) {
            do {
                try manifestStore.save(updated, now: now)
            } catch {
                logger.error("could not save the install manifest: \(error.localizedDescription)")
                messages.append("The install manifest could not be saved (\(error.localizedDescription)).")
            }
        }

        if computed.steps.isEmpty, computed.commands.isEmpty {
            messages.insert(operation == .uninstall ? "Nothing of Kakureneko's was installed." : "Already up to date.", at: 0)
        } else {
            for step in computed.steps {
                let verb = step.after == nil ? "Removed" : (step.before == nil ? "Created" : "Updated")
                messages.append("\(verb) \(context.display(step.file.url))")
            }
            if operation != .uninstall, let note = installer.followUpNote { messages.append(note) }
        }
        logger.notice("\(operation.rawValue) \(agent.rawValue): \(computed.steps.count) file(s), \(computed.commands.count) command(s), \(backupPaths.count) backup(s)")
        return InstallResult(
            plan: computed.plan,
            backups: backupPaths,
            dryRun: false,
            messages: messages,
            status: await status(of: installer, manifest: updated, claudeState: claudeState)
        )
    }

    /// Runs the CLI steps in order; a non-zero exit that is not a benign "already done" fails the operation.
    private func run(_ commands: [CommandStep]) async throws {
        for command in commands {
            let result = try await subprocess.run(command.request)
            if result.succeeded { continue }
            let output = (result.stdoutString + "\n" + result.stderrString).lowercased()
            if command.command.benignFailures.contains(where: { output.contains($0) }) { continue }
            let detail = result.timedOut
                ? "timed out"
                : String(TextSanitizer.sanitize(result.stderrString.isEmpty ? result.stdoutString : result.stderrString).prefix(300))
            throw InstallError.cliFailed(command: "claude " + command.command.arguments.prefix(3).joined(separator: " "),
                                         detail: "exit \(result.exitCode): \(detail)")
        }
    }

    /// Backs up, writes, re-reads and re-parses every step; on any failure restores every file of the operation
    /// from its backed-up bytes and rethrows. Returns the new backup paths.
    private func apply(_ steps: [FileStep], agent: AgentID, now: Date) throws -> [String] {
        var written: [FileStep] = []
        var backupPaths: [String] = []
        do {
            for step in steps {
                if step.file.kind == .spliced, let before = step.before,
                   let backup = try backups.backup(before, of: step.file.url, agent: agent, at: now) {
                    backupPaths.append(backup.path(percentEncoded: false))
                }
                written.append(step)
                if let after = step.after {
                    try fileSystem.write(InstallText.encode(after), to: step.file.url, permissions: nil)
                } else {
                    try fileSystem.remove(step.file.url)
                }
                try verify(step)
            }
        } catch {
            rollback(written)
            logger.error("install step failed for \(agent.rawValue); rolled back \(written.count) file(s): \(error.localizedDescription)")
            throw error
        }
        return backupPaths
    }

    /// The re-parse check (brief §3.7.3): the bytes on disk must be exactly what we meant to write, parse in the
    /// file's format, and contain (or no longer contain) our entries.
    private func verify(_ step: FileStep) throws {
        let path = step.file.path
        guard let after = step.after else {
            guard !fileSystem.exists(step.file.url) else {
                throw InstallError.verificationFailed(path: path, reason: "the file is still there")
            }
            return
        }
        guard let data = try fileSystem.read(step.file.url) else {
            throw InstallError.verificationFailed(path: path, reason: "the file is missing after writing")
        }
        do {
            let text = try InstallText.decode(data, path: path)
            try step.file.splicer.validate(text)
            guard step.file.splicer.containsOurs(text) == step.expectOurs else {
                throw InstallError.verificationFailed(path: path, reason: step.expectOurs ? "our entries are missing" : "our entries are still there")
            }
            guard data == InstallText.encode(after) else {
                throw InstallError.verificationFailed(path: path, reason: "the written bytes differ from the plan")
            }
        } catch let error as InstallError {
            if case .verificationFailed = error { throw error }
            throw InstallError.verificationFailed(path: path, reason: error.errorDescription ?? "it does not parse")
        }
    }

    /// Restores the pre-operation bytes of every step (reverse order). Best effort: failures are logged.
    private func rollback(_ steps: [FileStep]) {
        for step in steps.reversed() {
            do {
                if let before = step.before {
                    try fileSystem.write(before, to: step.file.url, permissions: nil)
                } else {
                    try fileSystem.remove(step.file.url)
                }
            } catch {
                logger.error("rollback of \(context.display(step.file.url)) failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Status

    func status(
        of installer: any IntegrationInstaller,
        manifest: InstallManifest,
        claudeState: ClaudePluginState?
    ) async -> IntegrationStatus {
        if installer is OpenCodeInstaller, installer.isAvailable(context) { await refreshOpencodeVersion() }
        let context = context
        let agent = installer.agent
        let entries = manifest.entries(for: agent)
        var notes = installer.notes(context)
        var complete = true
        var ours = false
        for file in installer.managedFiles(context) {
            do {
                let text = try fileSystem.readText(file.url)
                let has = text.map(file.splicer.containsOurs) ?? false
                ours = ours || has
                switch file.role {
                case .target:
                    let previous = entries.last { $0.file == file.path }
                    if try file.splicer.install(into: text, previous: previous).text != text { complete = false }
                case .cleanupOnly:
                    if has { complete = false }
                }
            } catch {
                complete = false
                notes.append((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
        var installed = ours
        if installer is ClaudePluginInstaller, ours || !entries.isEmpty {
            let state: ClaudePluginState
            if let claudeState {
                state = claudeState
            } else {
                let cli = await claudeLocator.locate(paths: paths, fileSystem: fileSystem, runner: subprocess, environment: agentEnvironment)
                state = await queryClaudeState(cli: cli)
            }
            switch state {
            case .enabled:
                break
            case .disabled:
                complete = false
                notes.append("The plugin is disabled in Claude Code.")
            case .absent:
                installed = false
                complete = false
            case .unknown:
                notes.append("Could not confirm the plugin with the claude CLI.")
            }
        }
        let available = installer.isAvailable(context)
        // Repair needs the agent; when its configuration is gone, uninstall just clears Kakureneko's record.
        let needsRepair = available && (ours || !entries.isEmpty) && !complete
        if !available, !entries.isEmpty {
            notes.append("\(agent.displayName)'s configuration was removed; uninstalling clears Kakureneko's record of it.")
        }
        if installed, !fileSystem.isExecutableFile(paths.hookBinary) {
            notes.append("The hook helper is not deployed; no events can arrive until Kakureneko deploys it.")
        }
        if let note = await loginShellDirectoryNote(for: agent) { notes.append(note) }
        return IntegrationStatus(
            agent: agent,
            supported: true,
            configDirExists: available,
            installed: installed,
            needsRepair: needsRepair,
            needsTrustStep: installed && installer.needsTrustStep(context),
            configFiles: installer.displayFiles(context),
            notes: notes
        )
    }

    // MARK: - Helper deployment

    /// Copies (never symlinks) the bundled helper to `~/.kakureneko/bin/kakureneko-hook` with mode 0755 when its SHA-256
    /// differs; atomic replace. Kakureneko's own file, so it is deployed in dry-run too (ARCHITECTURE §6).
    private func deployHelperLocked(from bundledHelper: URL) throws -> HelperDeployment {
        guard let data = try fileSystem.read(bundledHelper), !data.isEmpty else {
            throw SideEffectError.unavailable("bundled hook helper missing at \(bundledHelper.path(percentEncoded: false))")
        }
        let sha = Digest.sha256Hex(data)
        try DirectoryLayout.ensureUserDirectories(paths)
        let destination = paths.hookBinary
        let destinationPath = destination.path(percentEncoded: false)
        if !fileSystem.isSymbolicLink(destination), fileSystem.isExecutableFile(destination),
           let existing = try? fileSystem.read(destination), Digest.sha256Hex(existing) == sha {
            return HelperDeployment(path: destinationPath, sha256: sha, copied: false)
        }
        try fileSystem.replaceItem(data, at: destination, permissions: 0o755)
        guard let written = try fileSystem.read(destination), Digest.sha256Hex(written) == sha,
              fileSystem.isExecutableFile(destination) else {
            throw SideEffectError.failed("the hook helper at \(paths.displayPath(destination)) did not verify after copying")
        }
        logger.notice("deployed hook helper (\(data.count) bytes)")
        return HelperDeployment(path: destinationPath, sha256: sha, copied: true)
    }
}
