@testable import KakurenekoProcesses
import KakurenekoKit
import Foundation
import Testing

/// One matcher fixture: a descriptor and the expected classification (nil = not an agent).
struct MatchCase: Sendable, CustomTestStringConvertible {
    let name: String
    let descriptor: ProcessDescriptor
    let expected: AgentMatch?

    var testDescription: String { name }

    init(_ name: String, path: String?, argv: [String], comm: String? = nil, env: [String: String] = [:], _ expected: AgentMatch?) {
        self.name = name
        descriptor = ProcessDescriptor(executablePath: path, argv: argv, comm: comm, environment: env)
        self.expected = expected
    }
}

private func agent(_ id: AgentID, infra: Bool = false, ide: Bool = false) -> AgentMatch {
    AgentMatch(agent: id, isInfrastructure: infra, isIDEHost: ide)
}

private let home = Fixtures.home
private let claudeVersion = "\(home)/.local/share/claude/versions/2.1.296"
private let cursorNode = "\(home)/.local/share/cursor-agent/versions/2026.10.01-e373342/node"
private let cursorIndex = "\(home)/.local/share/cursor-agent/versions/2026.10.01-e373342/index.js"
private let node = "/opt/homebrew/Cellar/node/26.0.0/bin/node"
private let pythonApp = "/opt/homebrew/Cellar/python@3.12/3.12.7/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"

/// brief §5.3 table, row by row.
let briefTableCases: [MatchCase] = [
    // Claude Code: install locations + argv0 `claude`; comm is the version string.
    MatchCase("claude native (versions dir)", path: claudeVersion, argv: ["claude"], comm: "2.1.296", agent(.claude)),
    MatchCase("claude --resume", path: claudeVersion, argv: ["claude", "--resume"], comm: "2.1.296", agent(.claude)),
    MatchCase("claude ClaudeCode.app", path: "/Applications/ClaudeCode.app/Contents/MacOS/claude", argv: ["claude"], agent(.claude)),
    MatchCase("claude Claude.app Code tab",
              path: "\(home)/Library/Application Support/Claude/claude-code/2.1.290/claude", argv: ["claude"], agent(.claude)),
    MatchCase("claude VS Code extension binary",
              path: "\(home)/.vscode/extensions/anthropic.claude-code-2.1.296-darwin-arm64/resources/native-binary/claude",
              argv: ["claude", "--output-format", "stream-json"], agent(.claude)),
    MatchCase("claude Xcode CodingAssistant",
              path: "\(home)/Library/Developer/Xcode/CodingAssistant/Agents/Versions/26.1/claude", argv: ["claude"], agent(.claude)),
    MatchCase("claude Homebrew cask", path: "/opt/homebrew/Caskroom/claude-code/2.1.296/claude", argv: ["claude"], agent(.claude)),
    MatchCase("claude via symlink argv0 path", path: claudeVersion, argv: ["\(home)/.local/bin/claude"], agent(.claude)),
    MatchCase("claude daemon = infrastructure", path: claudeVersion,
              argv: ["\(home)/.local/bin/claude", "daemon", "run", "--origin"], agent(.claude, infra: true)),
    MatchCase("claude bg-spare (rewritten argv0) = infrastructure", path: claudeVersion, argv: ["claude bg-spare"],
              agent(.claude, infra: true)),
    MatchCase("claude bg-pty-host (rewritten argv0) = infrastructure", path: claudeVersion, argv: ["claude bg-pty-host"],
              agent(.claude, infra: true)),
    MatchCase("claude --bg-pty-host flag = infrastructure", path: claudeVersion, argv: ["claude", "--bg-pty-host", "7"],
              agent(.claude, infra: true)),
    MatchCase("claude prompt mentioning daemon is not infrastructure", path: claudeVersion,
              argv: ["claude", "-p", "restart the daemon"], agent(.claude)),
    MatchCase("claude multi-call ugrep is never an agent", path: claudeVersion, argv: ["ugrep", "-r", "foo"], comm: "2.1.296", nil),
    MatchCase("claude multi-call rg is never an agent", path: claudeVersion, argv: ["rg", "--files"], nil),
    MatchCase("version-string comm alone never matches", path: nil, argv: [], comm: "2.1.296", nil),
    MatchCase("comm `claude` alone never matches", path: nil, argv: [], comm: "claude", nil),
    MatchCase("replaced binary: nil path, argv0 claude", path: nil, argv: ["claude"], comm: "2.1.288", agent(.claude)),
    MatchCase("replaced binary: nil path, absolute version argv0", path: nil,
              argv: ["\(home)/.local/share/claude/versions/2.1.288"], agent(.claude)),
    MatchCase("replaced binary: nil path, bg-spare argv0", path: nil, argv: ["claude bg-spare"], agent(.claude, infra: true)),
    MatchCase("npm claude-code via node", path: node,
              argv: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"], agent(.claude)),
    MatchCase("npm claude-code daemon via node = infrastructure", path: node,
              argv: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js", "daemon", "run"],
              agent(.claude, infra: true)),
    MatchCase("Claude Desktop app main is not Claude Code", path: "/Applications/Claude.app/Contents/MacOS/Claude",
              argv: ["/Applications/Claude.app/Contents/MacOS/Claude"], nil),

    // Codex
    MatchCase("codex native", path: "/opt/homebrew/bin/codex", argv: ["codex"], agent(.codex)),
    MatchCase("codex exec", path: "/opt/homebrew/bin/codex", argv: ["codex", "exec", "fix it"], agent(.codex)),
    MatchCase("codex app-server = IDE host",
              path: "\(home)/.vscode/extensions/openai.chatgpt-1.0/bin/macos-aarch64/codex", argv: ["codex", "app-server"],
              agent(.codex, ide: true)),
    MatchCase("codex inside Codex.app resources = IDE host", path: "/Applications/Codex.app/Contents/Resources/codex",
              argv: ["/Applications/Codex.app/Contents/Resources/codex", "app-server"], agent(.codex, ide: true)),
    MatchCase("node + bin/codex", path: node, argv: ["node", "/opt/homebrew/bin/codex"], agent(.codex)),
    MatchCase("node + codex.js", path: node, argv: ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"],
              agent(.codex)),
    MatchCase("node + codex.js (relative)", path: node, argv: ["node", "codex.js", "exec"], agent(.codex)),
    MatchCase("Codex.app GUI main is not the CLI", path: "/Applications/Codex.app/Contents/MacOS/Codex",
              argv: ["/Applications/Codex.app/Contents/MacOS/Codex"], nil),

    // Gemini CLI: two node processes per session.
    MatchCase("gemini parent node + bin/gemini", path: node, argv: ["node", "/opt/homebrew/bin/gemini"], agent(.gemini)),
    MatchCase("gemini relaunched child (full node path, node options)", path: node,
              argv: [node, "--max-old-space-size=8192",
                     "/opt/homebrew/Cellar/gemini-cli/0.9.0/libexec/lib/node_modules/@google/gemini-cli/dist/index.js"],
              agent(.gemini)),
    MatchCase("gemini --experimental-acp = IDE host", path: node,
              argv: ["node", "/opt/homebrew/bin/gemini", "--experimental-acp"], agent(.gemini, ide: true)),

    // Antigravity, Copilot
    MatchCase("agy", path: "/usr/local/bin/agy", argv: ["agy"], agent(.agy)),
    MatchCase("copilot native", path: "/opt/homebrew/bin/copilot", argv: ["copilot"], agent(.copilot)),
    MatchCase("copilot npm package", path: node, argv: ["node", "/opt/homebrew/lib/node_modules/@github/copilot/index.js"],
              agent(.copilot)),
    MatchCase("copilot language server is not the CLI", path: node,
              argv: ["node", "/x/node_modules/@github/copilot-language-server/dist/language-server.js", "--stdio"], nil),

    // Cursor CLI
    MatchCase("cursor-agent bundled node + launcher argv0", path: cursorNode,
              argv: ["cursor-agent", "--use-system-ca", cursorIndex], agent(.cursor)),
    MatchCase("cursor agent (argv0 agent) + index.js", path: cursorNode, argv: ["\(home)/.local/bin/agent", cursorIndex, "-p", "x"],
              agent(.cursor)),
    MatchCase("cursor bundled node + index.js without launcher argv0", path: cursorNode, argv: ["node", cursorIndex],
              agent(.cursor)),
    MatchCase("cursor bundled node running another script is not the agent", path: cursorNode,
              argv: ["node", "\(home)/.local/share/cursor-agent/versions/2026.10.01-e373342/worker.js"], nil),

    // opencode / kilo
    MatchCase("opencode", path: "/opt/homebrew/bin/opencode", argv: ["opencode"], agent(.opencode)),
    MatchCase("opencode.exe (npm native)", path: "/opt/homebrew/lib/node_modules/opencode-ai/bin/opencode.exe",
              argv: ["opencode.exe"], agent(.opencode)),
    MatchCase("kilo", path: "/opt/homebrew/bin/kilo", argv: ["kilo"], agent(.kilo)),
    MatchCase("kilocode", path: "/opt/homebrew/bin/kilocode", argv: ["kilocode"], agent(.kilo)),
    MatchCase("kilo acp = IDE host", path: "/opt/homebrew/bin/kilo", argv: ["kilo", "acp"], agent(.kilo, ide: true)),

    // Aider
    MatchCase("python3.12 …/bin/aider", path: pythonApp, argv: ["/opt/homebrew/opt/python@3.12/bin/python3.12", "\(home)/.local/bin/aider"],
              agent(.aider)),
    MatchCase("python -m aider", path: pythonApp, argv: ["python3", "-m", "aider", "--model", "x"], agent(.aider)),
    MatchCase("Python -maider.main", path: pythonApp, argv: ["Python", "-maider.main"], agent(.aider)),
    MatchCase("python -c mentioning aider is not aider", path: pythonApp, argv: ["python3", "-c", "import aider"], nil),
    MatchCase("python other script", path: pythonApp, argv: ["python3", "/tmp/build.py"], nil),
    MatchCase("python -m other module", path: pythonApp, argv: ["python3", "-m", "http.server"], nil),

    // IDE hosts
    MatchCase("VS Code extension host", path: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)",
              argv: ["/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)", "--type=utility"],
              agent(.vscode, ide: true)),
    MatchCase("Cursor extension host", path: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)",
              argv: ["Cursor Helper (Plugin)"], agent(.cursor, ide: true)),
    MatchCase("VS Code agent host via env", path: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper",
              argv: ["/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper", "--type=utility"],
              env: ["VSCODE_ESM_ENTRYPOINT": "vs/platform/agentHost/node/agentHostMain"], agent(.vscode, ide: true)),
    MatchCase("plain Code Helper without the env is not an agent", path: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper",
              argv: ["Code Helper"], env: ["VSCODE_ESM_ENTRYPOINT": "vs/workbench/api/node/extensionHostProcess"], nil),
    MatchCase("Code Helper (Renderer) is not an agent", path: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Renderer).app/Contents/MacOS/Code Helper (Renderer)",
              argv: ["Code Helper (Renderer)"], nil),
    MatchCase("Chrome Helper (Plugin) is not an IDE host", path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Plugin).app/Contents/MacOS/Google Chrome Helper (Plugin)",
              argv: ["Google Chrome Helper (Plugin)"], nil),
    MatchCase("Windsurf extension host", path: "/Applications/Windsurf.app/Contents/Frameworks/Windsurf Helper (Plugin).app/Contents/MacOS/Windsurf Helper (Plugin)",
              argv: ["Windsurf Helper (Plugin)"], agent(.windsurf, ide: true)),
    MatchCase("Zed = IDE host", path: "/Applications/Zed.app/Contents/MacOS/zed", argv: ["/Applications/Zed.app/Contents/MacOS/zed"],
              agent(.zed, ide: true)),
]

/// R04 §7.5 long tail.
let longTailCases: [MatchCase] = [
    MatchCase("amp", path: "/opt/homebrew/bin/amp", argv: ["amp"], agent(.amp)),
    MatchCase("amp.exe", path: "/opt/homebrew/lib/node_modules/@ampcode/cli/bin/amp.exe", argv: ["amp.exe"], agent(.amp)),
    MatchCase("droid", path: "\(home)/.local/bin/droid", argv: ["droid"], agent(.droid)),
    MatchCase("qwen via node", path: node, argv: ["node", "/opt/homebrew/bin/qwen"], agent(.qwen)),
    MatchCase("qwen package", path: node, argv: ["node", "/x/lib/node_modules/@qwen-code/qwen-code/cli.js"], agent(.qwen)),
    MatchCase("crush", path: "/opt/homebrew/bin/crush", argv: ["crush"], agent(.crush)),
    MatchCase("kiro-cli", path: "/usr/local/bin/kiro-cli", argv: ["kiro-cli"], agent(.kiro)),
    MatchCase("kiro-cli-chat", path: "/usr/local/bin/kiro-cli-chat", argv: ["kiro-cli-chat", "chat"], agent(.kiro)),
    MatchCase("kiro-cli-term is shell integration", path: "/usr/local/bin/kiro-cli-term", argv: ["kiro-cli-term"], nil),
    MatchCase("auggie via node", path: node, argv: ["node", "/opt/homebrew/bin/auggie"], agent(.auggie)),
    MatchCase("auggie package", path: node, argv: ["node", "/x/node_modules/@augmentcode/auggie/augment.mjs"], agent(.auggie)),
    MatchCase("cline", path: "/opt/homebrew/bin/cline", argv: ["cline"], agent(.cline)),
    MatchCase("goose", path: "/opt/homebrew/bin/goose", argv: ["goose", "session"], agent(.goose)),
    MatchCase("goosed = infrastructure", path: "/Applications/Goose.app/Contents/Resources/bin/goosed", argv: ["goosed", "agent"],
              agent(.goose, infra: true)),
    MatchCase("Goose.app main is not the CLI", path: "/Applications/Goose.app/Contents/MacOS/Goose", argv: ["Goose"], nil),
    MatchCase("openhands (python)", path: pythonApp, argv: ["python3", "\(home)/.local/bin/openhands"], agent(.openhands)),
    MatchCase("openhands-acp", path: pythonApp, argv: ["python3", "\(home)/.local/bin/openhands-acp"], agent(.openhands)),
    MatchCase("cn via node", path: node, argv: ["node", "/opt/homebrew/bin/cn"], agent(.continueCLI)),
    MatchCase("continue package", path: node, argv: ["node", "/x/node_modules/@continuedev/cli/dist/index.js"], agent(.continueCLI)),
    MatchCase("kimi-code title", path: node, argv: ["kimi-code"], agent(.kimi)),
    MatchCase("kimi", path: "\(home)/.local/bin/kimi", argv: ["kimi"], agent(.kimi)),
    MatchCase("vibe (python)", path: pythonApp, argv: ["python3", "\(home)/.local/bin/vibe"], agent(.vibe)),
    MatchCase("vibe-acp", path: "\(home)/.local/bin/vibe-acp", argv: ["vibe-acp"], agent(.vibe)),
    MatchCase("plandex", path: "/usr/local/bin/plandex", argv: ["plandex"], agent(.plandex)),
    MatchCase("pdx", path: "/usr/local/bin/pdx", argv: ["pdx"], agent(.plandex)),
    MatchCase("grok", path: "/opt/homebrew/bin/grok", argv: ["grok"], agent(.grok)),
    MatchCase("grok agent stdio = IDE host", path: "/opt/homebrew/bin/grok", argv: ["grok", "agent", "stdio"], agent(.grok, ide: true)),
    MatchCase("devin", path: "\(home)/.local/bin/devin", argv: ["devin"], agent(.devin)),
    MatchCase("kilo/kilocode node script", path: node, argv: ["node", "/x/node_modules/@kilocode/cli/index.js"], agent(.kilo)),
    MatchCase("pi title", path: node, argv: ["pi"], agent(.pi)),
    MatchCase("pi-rpc title", path: node, argv: ["pi-rpc"], agent(.pi)),
    MatchCase("omp", path: "/opt/homebrew/bin/omp", argv: ["omp"], agent(.pi)),
    MatchCase("qodercli via node", path: node, argv: ["node", "/opt/homebrew/bin/qodercli"], agent(.qoder)),
    MatchCase("codebuddy", path: "/opt/homebrew/bin/codebuddy", argv: ["codebuddy"], agent(.codebuddy)),
    MatchCase("cbc", path: "/opt/homebrew/bin/cbc", argv: ["cbc"], agent(.codebuddy)),
    MatchCase("iflow", path: "/opt/homebrew/bin/iflow", argv: ["iflow"], agent(.iflow)),
    MatchCase("junie", path: "/opt/homebrew/bin/junie", argv: ["junie"], agent(.junie)),
    MatchCase("junie --acp=true = IDE host", path: "/opt/homebrew/bin/junie", argv: ["junie", "--acp=true"], agent(.junie, ide: true)),
    MatchCase("acli rovodev", path: "/opt/homebrew/bin/acli", argv: ["acli", "rovodev", "run"], agent(.rovo)),
    MatchCase("acli without rovodev is not an agent", path: "/opt/homebrew/bin/acli", argv: ["acli", "jira", "workitem"], nil),
    MatchCase("hermes", path: "\(home)/.local/bin/hermes", argv: ["hermes"], agent(.hermes)),
    MatchCase("oz (Warp agent)", path: "/usr/local/bin/oz", argv: ["oz"], agent(.warp)),
    MatchCase("Warp.app stable is a host, not an agent", path: "/Applications/Warp.app/Contents/MacOS/stable", argv: ["stable"], nil),
]

/// Things that must never match.
let negativeCases: [MatchCase] = [
    MatchCase("zsh", path: "/bin/zsh", argv: ["-zsh"], nil),
    MatchCase("zsh -c mentioning @openai/codex", path: "/bin/zsh", argv: ["/bin/zsh", "-c", "npx @openai/codex exec hi"], nil),
    MatchCase("echo claude (argv1 of a non-interpreter)", path: "/bin/echo", argv: ["echo", "claude"], nil),
    MatchCase("node server.js", path: node, argv: ["node", "server.js"], nil),
    MatchCase("node -e with an agent name", path: node, argv: ["node", "-e", "require('codex')"], nil),
    MatchCase("npm", path: node, argv: ["node", "/opt/homebrew/bin/npm", "run", "dev"], nil),
    MatchCase("caffeinate", path: "/usr/bin/caffeinate", argv: ["caffeinate", "-i", "-t", "300"], nil),
    MatchCase("codexx", path: "/usr/local/bin/codexx", argv: ["codexx"], nil),
    MatchCase("empty descriptor", path: nil, argv: [], nil),
    MatchCase("uv MCP server", path: "\(home)/Library/Application Support/Claude/uv-runtime/uv-0.9.7-darwin-arm64/uv",
              argv: ["uv", "run", "server.py"], nil),
]

@Suite("Agent signature table", .timeLimit(.minutes(1)))
struct AgentMatcherTests {
    let matcher = AgentMatcher(paths: Paths(home: URL(filePath: Fixtures.home)))

    @Test(arguments: briefTableCases)
    func briefTable(_ fixture: MatchCase) {
        #expect(matcher.match(fixture.descriptor) == fixture.expected, "\(fixture.name)")
    }

    @Test(arguments: longTailCases)
    func longTail(_ fixture: MatchCase) {
        #expect(matcher.match(fixture.descriptor) == fixture.expected, "\(fixture.name)")
    }

    @Test(arguments: negativeCases)
    func negatives(_ fixture: MatchCase) {
        #expect(matcher.match(fixture.descriptor) == nil, "\(fixture.name)")
    }

    @Test func everyAgentWithAProcessSignatureIsCovered() {
        let covered = Set((briefTableCases + longTailCases).compactMap { $0.expected?.agent })
        // In-app agents without a process of their own (session hosts filled by the coordinator) are not matchable.
        let inAppOnly: Set<AgentID> = [.xcode, .jetbrains, .unknown]
        let missing = Set(AgentID.allCases).subtracting(covered).subtracting(inAppOnly)
        #expect(missing.isEmpty, "agents without a fixture: \(missing.sorted())")
    }

    @Test func claudeVersionsDirectoryFollowsInjectedHome() throws {
        let temp = try TempHome()
        let home = temp.paths.home.path(percentEncoded: false)
        let matcher = AgentMatcher(paths: temp.paths)
        let path = (home.hasSuffix("/") ? home : home + "/") + ".local/share/claude/versions/2.1.300"
        // argv0 is the version file itself (no `claude` name anywhere): only the path rule can match.
        let descriptor = ProcessDescriptor(executablePath: path, argv: [path, "--continue"], comm: "2.1.300")
        #expect(matcher.match(descriptor) == AgentMatch(agent: .claude))
    }

    // MARK: Reduced descriptors from hook ancestry (`InboxAncestor.descriptor`)

    @Test func inboxAncestorPythonAider() {
        let ancestor = InboxAncestor(
            pid: 4100, ppid: 4000, startSec: 1, startUsec: 2, exe: "Python",
            argv0: "/opt/homebrew/opt/python@3.12/bin/python3.12", argv1: "\(Fixtures.home)/.local/bin/aider", path: pythonApp)
        #expect(matcher.match(ancestor.descriptor) == AgentMatch(agent: .aider))
    }

    /// `python -m aider`: the hook records only the module (`InboxAncestor.module`), and the reduced descriptor
    /// `[argv0, "-m", module]` is enough for the interpreter rule.
    @Test func inboxAncestorPythonModule() {
        func ancestor(_ module: String?, argv0: String = "python3", path: String? = nil) -> InboxAncestor {
            InboxAncestor(pid: 4101, ppid: 4000, startSec: 1, startUsec: 2, exe: "Python", argv0: argv0, path: path, module: module)
        }
        #expect(matcher.match(ancestor("aider").descriptor) == AgentMatch(agent: .aider))
        #expect(matcher.match(ancestor("aider.main", argv0: "/opt/homebrew/bin/python3.12", path: pythonApp).descriptor) == AgentMatch(agent: .aider))
        #expect(matcher.match(ancestor("openhands.cli").descriptor)?.agent == .openhands)
        #expect(matcher.match(ancestor("http.server").descriptor) == nil)
        #expect(matcher.match(ancestor(nil).descriptor) == nil, "without the module a bare interpreter is no agent")
    }

    @Test func inboxAncestorNativeClaudeWithVersionComm() {
        let ancestor = InboxAncestor(pid: 9220, startSec: 1, startUsec: 2, exe: "2.1.296", argv0: "claude", path: claudeVersion)
        #expect(matcher.match(ancestor.descriptor) == AgentMatch(agent: .claude))
    }

    @Test func inboxAncestorReplacedClaudeBinary() {
        // proc_pidpath nil after an auto-update; argv0 still says claude.
        let ancestor = InboxAncestor(pid: 9220, startSec: 1, startUsec: 2, exe: "2.1.288", argv0: "claude")
        #expect(matcher.match(ancestor.descriptor) == AgentMatch(agent: .claude))
        // Only the version-string comm: never a match.
        let commOnly = InboxAncestor(pid: 9221, startSec: 1, startUsec: 2, exe: "2.1.288")
        #expect(matcher.match(commOnly.descriptor) == nil)
    }

    @Test func inboxAncestorClaudeBgSpareIsInfrastructure() {
        let ancestor = InboxAncestor(pid: 9300, startSec: 1, startUsec: 2, exe: "2.1.296", argv0: "claude bg-spare", path: claudeVersion)
        #expect(matcher.match(ancestor.descriptor) == AgentMatch(agent: .claude, isInfrastructure: true))
    }

    @Test func inboxAncestorNodeCodexAndGemini() {
        let codex = InboxAncestor(pid: 1, startSec: 1, startUsec: 0, exe: "node", argv0: "node",
                                  argv1: "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js", path: node)
        #expect(matcher.match(codex.descriptor) == AgentMatch(agent: .codex))
        let gemini = InboxAncestor(pid: 2, startSec: 1, startUsec: 0, exe: "node", argv0: node,
                                   argv1: "/opt/homebrew/bin/gemini", path: node)
        #expect(matcher.match(gemini.descriptor) == AgentMatch(agent: .gemini))
    }

    @Test func inboxAncestorCursorLauncher() {
        // `exec -a "$0" node --use-system-ca index.js`: argv1 is an option (not recorded), argv0 is the launcher name.
        let cursor = InboxAncestor(pid: 3, startSec: 1, startUsec: 0, exe: "node", argv0: "cursor-agent", path: cursorNode)
        #expect(matcher.match(cursor.descriptor) == AgentMatch(agent: .cursor))
        let withScript = InboxAncestor(pid: 4, startSec: 1, startUsec: 0, exe: "node", argv0: "agent", argv1: cursorIndex, path: cursorNode)
        #expect(matcher.match(withScript.descriptor) == AgentMatch(agent: .cursor))
    }

    @Test func inboxAncestorShellIsNotAnAgent() {
        let shell = InboxAncestor(pid: 5, startSec: 1, startUsec: 0, exe: "zsh", argv0: "-zsh", path: "/bin/zsh")
        #expect(matcher.match(shell.descriptor) == nil)
        let login = InboxAncestor(pid: 6, startSec: 1, startUsec: 0, exe: "login") // root-owned: no path, no argv
        #expect(matcher.match(login.descriptor) == nil)
    }

    // MARK: Helpers

    @Test func hostedModeIsExactSubcommandsAndFlagsOnly() {
        #expect(AgentSignatureRules.isHostedMode(["app-server"]))
        #expect(AgentSignatureRules.isHostedMode(["mcp-server"]))
        #expect(AgentSignatureRules.isHostedMode(["acp"]))
        #expect(AgentSignatureRules.isHostedMode(["agent", "stdio"]))
        #expect(AgentSignatureRules.isHostedMode(["--model", "x", "--acp"]))
        #expect(AgentSignatureRules.isHostedMode(["--stdio"]))
        #expect(!AgentSignatureRules.isHostedMode(["exec", "run the app-server tests"]))
        #expect(!AgentSignatureRules.isHostedMode(["agent"]))
        #expect(!AgentSignatureRules.isHostedMode([]))
    }

    @Test func nodeScriptSkipsOptionsAndTheirValues() {
        #expect(AgentSignatureRules.nodeScript(["node", "--max-old-space-size", "8192", "/x/gemini"])?.value == "/x/gemini")
        #expect(AgentSignatureRules.nodeScript(["node", "-r", "ts-node/register", "app.ts"])?.value == "app.ts")
        #expect(AgentSignatureRules.nodeScript(["node", "--inspect=9229", "/x/codex.js"])?.value == "/x/codex.js")
        #expect(AgentSignatureRules.nodeScript(["node", "--", "/x/cn"])?.value == "/x/cn")
        #expect(AgentSignatureRules.nodeScript(["node", "-e", "1"]) == nil)
        #expect(AgentSignatureRules.nodeScript(["node"]) == nil)
    }

    @Test func argv0NamesSplitRewrittenTitles() {
        let names = Argv0Names("/Users/x/.local/bin/claude bg-spare")
        #expect(names.command == "claude")
        #expect(names.extraWords == ["bg-spare"])
        #expect(Argv0Names("Code Helper (Plugin)").full == "Code Helper (Plugin)")
    }

    @Test func claudeInstallPathRules() {
        let rules = Fixtures.rules
        #expect(rules.isClaudeInstallPath("/Users/other/.local/share/claude/versions/2.0.0"))
        #expect(rules.isClaudeInstallPath("/A/ClaudeCode.app/Contents/MacOS/claude"))
        #expect(!rules.isClaudeInstallPath("claude"))
        #expect(!rules.isClaudeInstallPath("/usr/local/bin/claude-helper"))
        #expect(!rules.isClaudeInstallPath("/x/resources/native-binary/claude")) // not an anthropic extension dir
        #expect(!rules.isClaudeInstallPath(nil))
    }

    @Test func basicKitMatcherAgreesOnTheMainCLIs() {
        // The production matcher is a superset of Kit's minimal table for plain argv0 names.
        let basic = BasicAgentSignatureMatcher()
        for name in ["claude", "codex", "agy", "copilot", "cursor-agent", "opencode", "kilo", "aider", "droid", "goose", "crush"] {
            let descriptor = ProcessDescriptor(executablePath: "/usr/local/bin/\(name)", argv: [name])
            #expect(matcher.match(descriptor)?.agent == basic.match(descriptor)?.agent, "\(name)")
        }
    }
}
