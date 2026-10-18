import KakurenekoKit
import Foundation

/// Signature table (brief §5.3 + R04 §7.5 + R03 §9.1). Pure; also injected into KakurenekoEvents for attribution.
///
/// Matching uses the executable path and the argv[0]/argv[1] basenames, never `p_comm` alone (Claude Code's
/// `p_comm` is its version string). It works on full scanner descriptors and on the reduced descriptors built from
/// hook ancestry (`InboxAncestor.descriptor`: path + argv0 + a path-like argv1).
public struct AgentMatcher: AgentSignatureMatching {
    private let rules: AgentSignatureRules

    /// Binding signature. `paths.home` locates `~/.local/share/claude/versions/` etc.
    public init(paths: Paths) {
        rules = AgentSignatureRules(home: paths.home.path(percentEncoded: false))
    }

    public func match(_ process: ProcessDescriptor) -> AgentMatch? {
        rules.match(process)
    }
}

/// The rule set behind `AgentMatcher` (internal so tests can exercise the helpers).
struct AgentSignatureRules: Sendable {
    /// `<home>/.local/share/claude/versions/` and `<home>/.local/share/cursor-agent/versions/` for this home.
    let claudeVersionsPrefix: String
    let cursorVersionsPrefix: String

    init(home: String) {
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        claudeVersionsPrefix = trimmed + "/.local/share/claude/versions/"
        cursorVersionsPrefix = trimmed + "/.local/share/cursor-agent/versions/"
    }

    // MARK: Tables

    /// Native executables and process titles (exe basename or argv[0] basename, `.exe` stripped). Case-sensitive:
    /// GUI apps such as `Codex.app/Contents/MacOS/Codex` or `Goose.app/…/Goose` must not match.
    static let nameTable: [String: AgentID] = [
        "claude": .claude, "codex": .codex, "gemini": .gemini, "agy": .agy, "copilot": .copilot, "cursor-agent": .cursor,
        "opencode": .opencode, "kilo": .kilo, "kilocode": .kilo, "aider": .aider,
        "droid": .droid, "qwen": .qwen, "auggie": .auggie, "openhands": .openhands, "openhands-acp": .openhands,
        "devin": .devin, "qodercli": .qoder, "codebuddy": .codebuddy, "cbc": .codebuddy, "iflow": .iflow,
        "grok": .grok, "kimi": .kimi, "kimi-code": .kimi, "vibe": .vibe, "vibe-acp": .vibe,
        "kiro-cli": .kiro, "kiro-cli-chat": .kiro, "goose": .goose, "goosed": .goose, "cline": .cline,
        "amp": .amp, "pi": .pi, "pi-rpc": .pi, "omp": .pi, "junie": .junie, "hermes": .hermes, "crush": .crush,
        "plandex": .plandex, "pdx": .plandex, "oz": .warp, "acli": .rovo,
    ]

    /// Scripts run by a JS (node/bun) or Python interpreter: basename of the script argument with `.js`/`.cjs`/
    /// `.mjs`/`.py` stripped (`node …/bin/codex`, `node …/codex.js`, `python3.12 …/bin/aider`).
    static let scriptTable: [String: AgentID] = [
        "claude": .claude, "codex": .codex, "gemini": .gemini, "copilot": .copilot, "opencode": .opencode,
        "kilo": .kilo, "kilocode": .kilo, "qwen": .qwen, "auggie": .auggie, "cn": .continueCLI,
        "qodercli": .qoder, "codebuddy": .codebuddy, "cbc": .codebuddy, "iflow": .iflow, "droid": .droid,
        "amp": .amp, "cline": .cline, "grok": .grok, "devin": .devin, "pi": .pi, "omp": .pi, "junie": .junie,
        "kimi": .kimi, "kimi-code": .kimi, "aider": .aider, "openhands": .openhands, "openhands-acp": .openhands,
        "vibe": .vibe, "vibe-acp": .vibe, "hermes": .hermes,
    ]

    /// npm package directories that identify the script argument of a JS runtime (component match, so
    /// `@github/copilot-language-server` does not match `@github/copilot`).
    static let packageMarkers: [(marker: String, agent: AgentID)] = [
        ("/@anthropic-ai/claude-code/", .claude),
        ("/@openai/codex/", .codex), ("/@openai/codex-darwin", .codex),
        ("/@google/gemini-cli/", .gemini),
        ("/@github/copilot/", .copilot), ("/@github/copilot-darwin", .copilot),
        ("/@qwen-code/qwen-code/", .qwen),
        ("/@augmentcode/auggie/", .auggie),
        ("/@continuedev/cli/", .continueCLI),
        ("/@qoder-ai/qodercli/", .qoder),
        ("/@tencent-ai/codebuddy-code/", .codebuddy),
        ("/@iflow-ai/iflow-cli/", .iflow),
        ("/@jetbrains/junie-cli/", .junie),
        ("/@ampcode/cli/", .amp), ("/@sourcegraph/amp/", .amp),
        ("/opencode-ai/", .opencode), ("/@opencode/cli/", .opencode),
        ("/@kilocode/cli/", .kilo),
        ("/@earendil-works/pi-coding-agent/", .pi), ("/@mariozechner/pi-coding-agent/", .pi),
        ("/@oh-my-pi/pi-coding-agent/", .pi),
    ]

    /// `python -m <module>` → agent.
    static let pythonModules: [String: AgentID] = [
        "aider": .aider, "aider.main": .aider, "openhands": .openhands, "openhands.cli": .openhands, "vibe": .vibe,
    ]

    /// Electron extension hosts (`<App> Helper (Plugin)`) are IDE hosts of the in-app agents.
    static let extensionHostApps: [String: AgentID] = [
        "Code": .vscode, "Code - Insiders": .vscode, "VSCodium": .vscode, "Cursor": .cursor, "Windsurf": .windsurf,
        "Devin": .windsurf, "Antigravity": .agy, "Kiro": .kiro, "Qoder": .qoder, "CodeBuddy": .codebuddy,
    ]

    /// Tools the Claude Code binary also runs as (multi-call): same exe path, different argv[0]. Never agents.
    static let multiCallTools: Set<String> = ["ugrep", "rg", "bfs"]
    /// Shell integrations that look like agents but are not (R04 §7.5: `kiro-cli-term`).
    static let ignoredNames: Set<String> = ["kiro-cli-term"]
    /// Claude Code infrastructure (protected from pausing, never a session): `claude daemon`, `claude bg-pty-host`,
    /// `claude bg-spare` (argv[0] may be rewritten to `"claude bg-spare"`).
    static let claudeInfrastructureWords: Set<String> = ["daemon", "bg-pty-host", "bg-spare", "--bg-pty-host", "--bg-spare"]
    static let claudeInfrastructureFlags: Set<String> = ["--bg-pty-host", "--bg-spare"]
    /// Other agents' infrastructure.
    static let infrastructureNames: Set<String> = ["goosed"]
    /// Interpreters.
    static let jsRuntimes: Set<String> = ["node", "nodejs", "bun"]
    /// Node options that take a separate value argument (skipped when looking for the script).
    static let nodeValueOptions: Set<String> = [
        "-r", "--require", "--import", "--loader", "--experimental-loader", "-C", "--conditions", "--title",
        "--env-file", "--inspect-port", "--max-old-space-size", "--stack-size", "--input-type",
    ]
    static let nodeEvalOptions: Set<String> = ["-e", "--eval", "-p", "--print", "-i", "--interactive"]
    static let pythonValueOptions: Set<String> = ["-W", "-X", "--check-hash-based-pycs"]

    // MARK: Matching

    func match(_ process: ProcessDescriptor) -> AgentMatch? {
        let argv = process.argv
        let argv0 = argv.first ?? ""
        let names = Argv0Names(argv0)
        let exePath = process.executablePath.flatMap { $0.isEmpty ? nil : $0 }
        let exeBase = exePath.map { Self.stripExe(Self.basename($0)) }

        // 0. Multi-call tools of the Claude binary and shell integrations are never agents.
        if Self.multiCallTools.contains(names.command) || Self.multiCallTools.contains(names.full) { return nil }
        if Self.ignoredNames.contains(names.command) || Self.ignoredNames.contains(names.full)
            || exeBase.map(Self.ignoredNames.contains) == true {
            return nil
        }

        // 1. VS Code agent host (a plain `Code Helper` identified by its ESM entry point; brief §5.3).
        if let entry = process.environment["VSCODE_ESM_ENTRYPOINT"], entry.contains("agentHost") {
            let helperApp = [names.full, exeBase].compactMap { $0 }.lazy.compactMap(Self.helperAppName).first
            return AgentMatch(agent: helperApp.flatMap { Self.extensionHostApps[$0] } ?? .vscode, isIDEHost: true)
        }

        // 2. Electron extension hosts (`Code Helper (Plugin)`, `Cursor Helper (Plugin)`, …).
        for name in [names.full, exeBase].compactMap({ $0 }) {
            if let app = Self.pluginHostAppName(name), let agent = Self.extensionHostApps[app] {
                return AgentMatch(agent: agent, isIDEHost: true)
            }
        }

        // 3. Claude Code by install location — also via an absolute argv[0] when the binary was replaced
        //    (`proc_pidpath` nil after an auto-update) or the version file itself is argv[0].
        if isClaudeInstallPath(exePath) || isClaudeInstallPath(argv0) {
            return claudeMatch(argv: argv, names: names)
        }

        // 4. Cursor CLI: bundled node under `~/.local/share/cursor-agent/versions/*/`, started by the `agent`/
        //    `cursor-agent` launcher (`exec -a "$0" node [--use-system-ca] index.js`, R03 §9.1).
        if let exePath, exeBase == "node", isCursorAgentPath(exePath) {
            let script = Self.nodeScript(argv)
            let launcher = names.command == "agent" || names.command == "cursor-agent"
            if launcher || script.map({ Self.basename($0.value) == "index.js" }) == true {
                let rest = script.map { Array(argv[($0.index + 1)...]) } ?? Array(argv.dropFirst())
                return AgentMatch(agent: .cursor, isIDEHost: Self.isHostedMode(rest))
            }
        }

        // 5. Zed (agent panel; IDE host, R05 §5.2).
        if let exePath, Self.isZedApp(exePath) { return AgentMatch(agent: .zed, isIDEHost: true) }

        // 6. Interpreters: the script (or `-m` module) decides. `agent`/`cursor-agent` is Cursor's `exec -a "$0" node`
        //    launcher (checked here too in case the bundled node was replaced and its path is gone).
        if Self.jsRuntimes.contains(names.command) || exeBase.map(Self.jsRuntimes.contains) == true
            || names.command == "agent" || names.command == "cursor-agent" {
            if let match = matchJavaScript(argv: argv, names: names, exeBase: exeBase) { return match }
        }
        if Self.isPython(names.command) || exeBase.map(Self.isPython) == true {
            if let match = Self.matchPython(argv: argv) { return match }
        }

        // 7. Native executables and process titles.
        let exeIsAppMain = exePath.map(AppBundlePaths.isAppMainExecutable) ?? false
        var candidates: [String] = []
        for name in [names.command, names.full] where !name.isEmpty && !candidates.contains(name) {
            if exeIsAppMain && name == exeBase { continue }
            candidates.append(name)
        }
        if let exeBase, !exeIsAppMain, !candidates.contains(exeBase) { candidates.append(exeBase) }
        for name in candidates {
            if let match = matchName(Self.stripExe(name), argv: argv, names: names) { return match }
        }
        return nil
    }

    // MARK: Agent-specific rules

    private func claudeMatch(argv: [String], names: Argv0Names) -> AgentMatch {
        var infrastructure = names.extraWords.contains { Self.claudeInfrastructureWords.contains($0) }
        if argv.count > 1, Self.claudeInfrastructureWords.contains(argv[1]) { infrastructure = true }
        if argv.contains(where: { Self.claudeInfrastructureFlags.contains($0) }) { infrastructure = true }
        return AgentMatch(
            agent: .claude,
            isInfrastructure: infrastructure,
            isIDEHost: !infrastructure && Self.isHostedMode(Array(argv.dropFirst()))
        )
    }

    private func matchName(_ name: String, argv: [String], names: Argv0Names) -> AgentMatch? {
        guard let agent = Self.nameTable[name] else { return nil }
        let arguments = Array(argv.dropFirst())
        switch agent {
        case .claude:
            return claudeMatch(argv: argv, names: names)
        case .rovo:
            // `acli` is the Atlassian CLI; only `acli rovodev …` is the agent.
            guard arguments.first == "rovodev" else { return nil }
            return AgentMatch(agent: .rovo, isIDEHost: Self.isHostedMode(Array(arguments.dropFirst())))
        default:
            if Self.infrastructureNames.contains(name) { return AgentMatch(agent: agent, isInfrastructure: true) }
            return AgentMatch(agent: agent, isIDEHost: Self.isHostedMode(arguments))
        }
    }

    private func matchJavaScript(argv: [String], names: Argv0Names, exeBase: String?) -> AgentMatch? {
        guard let script = Self.nodeScript(argv) else { return nil }
        let rest = Array(argv[(script.index + 1)...])
        let hosted = Self.isHostedMode(rest)
        let scriptBase = Self.basename(script.value)
        // Cursor CLI launcher: `exec -a "$0" node index.js` → argv0 `agent`/`cursor-agent`, script `…/index.js`.
        let launcherArgv0 = (names.command == "agent" || names.command == "cursor-agent")
            && (exeBase == nil || exeBase.map(Self.jsRuntimes.contains) == true)
        if scriptBase == "index.js", isCursorAgentPath(script.value) || launcherArgv0 {
            return AgentMatch(agent: .cursor, isIDEHost: hosted)
        }
        guard Self.jsRuntimes.contains(names.command) || exeBase.map(Self.jsRuntimes.contains) == true || exeBase == nil
        else { return nil }
        var agent = Self.packageMarkers.first { script.value.contains($0.marker) }?.agent
        if agent == nil { agent = Self.scriptTable[Self.stripScriptExtension(scriptBase)] }
        guard let agent else { return nil }
        if agent == .claude {
            // npm-installed Claude Code (`node …/@anthropic-ai/claude-code/cli.js daemon`): same infrastructure rules.
            return claudeMatch(argv: [script.value] + rest, names: Argv0Names(""))
        }
        return AgentMatch(agent: agent, isIDEHost: hosted)
    }

    static func matchPython(argv: [String]) -> AgentMatch? {
        var index = 1
        while index < argv.count {
            let arg = argv[index]
            if arg == "-m" {
                guard index + 1 < argv.count else { return nil }
                let module = argv[index + 1]
                guard let agent = pythonModules[module] else { return nil }
                return AgentMatch(agent: agent, isIDEHost: isHostedMode(Array(argv.dropFirst(index + 2))))
            }
            if arg.hasPrefix("-m"), arg.count > 2 {
                guard let agent = pythonModules[String(arg.dropFirst(2))] else { return nil }
                return AgentMatch(agent: agent, isIDEHost: isHostedMode(Array(argv.dropFirst(index + 1))))
            }
            if arg == "-c" { return nil }
            if pythonValueOptions.contains(arg) {
                index += 2
                continue
            }
            if arg.hasPrefix("-") {
                index += 1
                continue
            }
            let scriptName = stripScriptExtension(basename(arg))
            guard let agent = scriptTable[scriptName] else { return nil }
            return AgentMatch(agent: agent, isIDEHost: isHostedMode(Array(argv.dropFirst(index + 1))))
        }
        return nil
    }

    // MARK: Path rules

    /// Claude Code install locations (brief §5.3; R05 §5.2).
    func isClaudeInstallPath(_ path: String?) -> Bool {
        guard let path, path.hasPrefix("/") else { return false }
        if path.hasPrefix(claudeVersionsPrefix) || path.contains("/.local/share/claude/versions/") { return true }
        if path.hasSuffix("/ClaudeCode.app/Contents/MacOS/claude") { return true }
        let c = path.split(separator: "/", omittingEmptySubsequences: true)
        let n = c.count
        guard n >= 4, c[n - 1] == "claude" else { return false }
        // …/Claude/claude-code/<version>/claude (Claude.app Code tab)
        if c[n - 3] == "claude-code", c[n - 4] == "Claude" { return true }
        // …/anthropic.claude-code-<v>/resources/native-binary/claude (VS Code / Cursor extension)
        if c[n - 2] == "native-binary", c[n - 3] == "resources", c[n - 4].hasPrefix("anthropic.claude-code-") { return true }
        // …/CodingAssistant/Agents/Versions/<v>/claude (Xcode)
        if n >= 5, c[n - 3] == "Versions", c[n - 4] == "Agents", c[n - 5] == "CodingAssistant" { return true }
        return false
    }

    func isCursorAgentPath(_ path: String) -> Bool {
        path.hasPrefix(cursorVersionsPrefix) || path.contains("/cursor-agent/versions/")
    }

    static func isZedApp(_ path: String) -> Bool {
        guard path.hasSuffix(".app/Contents/MacOS/zed"), let bundle = AppBundlePaths.bundle(ofMainExecutable: path) else {
            return false
        }
        return basename(bundle).hasPrefix("Zed")
    }

    // MARK: Helpers

    /// `Code Helper (Plugin)` → `Code`.
    static func pluginHostAppName(_ name: String) -> String? {
        let suffix = " Helper (Plugin)"
        guard name.hasSuffix(suffix), name.count > suffix.count else { return nil }
        return String(name.dropLast(suffix.count))
    }

    /// `Cursor Helper`, `Code Helper (Plugin)` → `Cursor`, `Code`.
    static func helperAppName(_ name: String) -> String? {
        if let plugin = pluginHostAppName(name) { return plugin }
        guard let range = name.range(of: " Helper") else { return nil }
        return String(name[..<range.lowerBound])
    }

    /// Agents running under a host (IDE / ACP client / app): `codex app-server`, `codex mcp-server`, `kilo acp`,
    /// `junie --acp=true`, `gemini --experimental-acp`, `grok agent stdio`, `--stdio` (R03 §2(a), R04 §7.5).
    /// Only exact subcommands/flags are considered — never free text.
    static func isHostedMode(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        if ["app-server", "mcp-server", "acp", "acp-daemon"].contains(first) { return true }
        if first == "agent", arguments.count > 1, arguments[1] == "stdio" { return true }
        for arg in arguments.prefix(8) {
            if arg == "--acp" || arg.hasPrefix("--acp=") || arg == "--experimental-acp" || arg == "--stdio" { return true }
        }
        return false
    }

    /// The script argument of a node/bun command line (first non-option argument), skipping node options and their
    /// values. nil for `-e`/`-p` evaluations.
    static func nodeScript(_ argv: [String]) -> (index: Int, value: String)? {
        var index = 1
        while index < argv.count {
            let arg = argv[index]
            if nodeEvalOptions.contains(arg) { return nil }
            if arg == "--" {
                return index + 1 < argv.count ? (index + 1, argv[index + 1]) : nil
            }
            if arg.hasPrefix("-") {
                index += (nodeValueOptions.contains(arg) && !arg.contains("=")) ? 2 : 1
                continue
            }
            if arg.isEmpty {
                index += 1
                continue
            }
            return (index, arg)
        }
        return nil
    }

    static func isPython(_ name: String) -> Bool {
        name.lowercased().hasPrefix("python")
    }

    static func basename(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        guard let slash = trimmed.lastIndex(of: "/") else { return String(trimmed) }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    static func stripExe(_ name: String) -> String {
        name.hasSuffix(".exe") && name.count > 4 ? String(name.dropLast(4)) : name
    }

    static func stripScriptExtension(_ name: String) -> String {
        for ext in [".js", ".cjs", ".mjs", ".py"] where name.hasSuffix(ext) && name.count > ext.count {
            return String(name.dropLast(ext.count))
        }
        return stripExe(name)
    }
}

/// The names argv[0] can contribute (process titles may be rewritten: `claude bg-spare`, `npm run dev`).
struct Argv0Names: Sendable, Hashable {
    /// Basename of the whole argv[0] (`Code Helper (Plugin)`, `claude bg-spare`).
    let full: String
    /// Basename of the first whitespace-separated token (`claude` for `claude bg-spare`).
    let command: String
    /// The remaining tokens of a rewritten title (`["bg-spare"]`).
    let extraWords: [String]

    init(_ argv0: String) {
        full = AgentSignatureRules.basename(argv0)
        let tokens = argv0.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        command = tokens.first.map(AgentSignatureRules.basename) ?? ""
        extraWords = Array(tokens.dropFirst())
    }
}
