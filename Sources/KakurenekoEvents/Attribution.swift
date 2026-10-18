import KakurenekoKit
import Foundation

/// Who produced an inbox event (ARCHITECTURE §9.1 "Attribution", deliberately differing from brief §4.4, see
/// ARCHITECTURE §11.13):
///
/// 1. the NEAREST non-infrastructure ancestor the injected matcher classifies — unless the argv label names a
///    different agent AND an unmatched program or agent infrastructure separates the hook from that ancestor (it is
///    then an OUTER agent hosting an agent the matcher does not know; see `hasSeparator`); else
/// 2. the argv label (`AgentID(label:)`), except argv `claude` + `CURSOR_VERSION` → `.cursor`; else
/// 3. env markers (`CURSOR_VERSION`, `GEMINI_SESSION_ID`, `AI_AGENT`, the R04 §2.6 project markers, `CLAUDE_PID`).
///
/// `CLAUDE_PID` and `CLAUDE_CODE_SESSION_ID` are inherited by EVERY process Claude's Bash tool spawns, so they
/// never outrank the ancestry (`codex exec` run from Claude is Codex).
struct Attribution: Equatable {
    var agent: AgentID
    /// Nearest ancestor matched as `agent` (or the `CLAUDE_PID` process when it binds).
    var agentProcess: ProcessIdentity?
    var host: HostApp?
    /// argv label that was overridden (`copilot` → `vscode`).
    var relabelledFrom: String?
    /// Identity for `SessionKey.fallback` when the payload has no session id: `agentProcess`, else the nearest
    /// ancestor that is not a shell or wrapper (Aider's python behind `sh -c`).
    var fallbackIdentity: ProcessIdentity?
}

enum AttributionResolver {
    /// Resolves `bundleIdentifier(forAppBundleAt:)` lookups (Info.plist reads, cached by the pipeline).
    typealias BundleLookup = (String) -> String?

    static func resolve(
        header: InboxHeader,
        payload: RawPayload,
        matcher: any AgentSignatureMatching,
        bundleLookup: BundleLookup
    ) -> Attribution {
        let ancestry = header.ancestry
        let matches: [AgentMatch?] = ancestry.map { matcher.match($0.descriptor) }
        let argvAgent = AgentID(label: header.agent)
        let env = header.env

        var agent: AgentID
        var relabelledFrom: String?
        let hasCopilotAncestor = matches.contains { $0?.agent == .copilot }
        // Step 2's answer, needed to judge step 1 (argv `claude` + `CURSOR_VERSION` names Cursor, not Claude).
        let labelled = argvAgent == .unknown ? AgentID.unknown : argvLabelAgent(argvAgent, env: env)
        if argvAgent == .copilot, !hasCopilotAncestor,
           ancestry.contains(where: isVSCodeExtensionHost) || CopilotNormalizer.isVSCodeLocalPayload(payload) {
            // The Copilot hook file is also read by the VS Code Local harness (brief §3.6 E).
            agent = .vscode
            relabelledFrom = header.agent
        } else if let nearestIndex = matches.firstIndex(where: { $0 != nil && !$0!.isInfrastructure }),
                  let nearest = matches[nearestIndex],
                  !(labelled != .unknown && labelled != nearest.agent
                    && hasSeparator(before: nearestIndex, ancestry: ancestry, matches: matches)) {
            agent = nearest.agent
        } else if labelled != .unknown {
            agent = labelled
        } else {
            agent = environmentAgent(env) ?? .unknown
        }
        if relabelledFrom == nil, agent != argvAgent, argvAgent != .unknown, agent != .unknown {
            relabelledFrom = header.agent
        }

        // agentProcess: the nearest ancestor matched as `agent` (sessions are never infrastructure).
        var agentProcess: ProcessIdentity?
        if let index = matches.firstIndex(where: { $0?.agent == agent && !($0?.isInfrastructure ?? true) }) {
            agentProcess = ancestry[index].identity
        } else if agent == .claude, let claudePID = env["CLAUDE_PID"].flatMap({ Int32($0) }),
                  let index = ancestry.firstIndex(where: { $0.pid == claudePID }),
                  !matches[..<index].contains(where: { $0 != nil && $0!.agent != .claude }) {
            // CLAUDE_PID binds only when no other matched agent sits between the hook and that pid.
            agentProcess = ancestry[index].identity
        }

        return Attribution(
            agent: agent,
            agentProcess: agentProcess,
            host: host(environment: env, ancestry: ancestry, bundleLookup: bundleLookup),
            relabelledFrom: relabelledFrom,
            fallbackIdentity: agentProcess ?? nearestNonShellAncestor(ancestry)?.identity
        )
    }

    /// Step 2: the argv label, except argv `claude` + `CURSOR_VERSION` → `.cursor` (Cursor runs Claude-format hooks).
    static func argvLabelAgent(_ argvAgent: AgentID, env: [String: String]) -> AgentID {
        argvAgent == .claude && env["CURSOR_VERSION"] != nil ? .cursor : argvAgent
    }

    /// True when something other than a shell/wrapper sits between the hook and the matched ancestor at `index`: an
    /// UNMATCHED program, or agent infrastructure (`claude bg-pty-host` hosts the shells of other programs). Then the
    /// matched ancestor is an OUTER agent (e.g. Claude running a Cursor CLI the matcher does not recognise) and the
    /// integration named in argv is the better witness: attributing to the outer agent would corrupt its session —
    /// exactly what ancestry-first attribution exists to prevent (ARCHITECTURE §11.13). Only consulted when the argv
    /// label disagrees with the nearest match.
    static func hasSeparator(before index: Int, ancestry: [InboxAncestor], matches: [AgentMatch?]) -> Bool {
        ancestry[..<index].indices.contains { i in
            if let match = matches[i] { return match.isInfrastructure }
            return !isWrapper(ancestry[i])
        }
    }

    // MARK: - Env markers

    /// Step 3 of the attribution order.
    static func environmentAgent(_ env: [String: String]) -> AgentID? {
        if env["CURSOR_VERSION"] != nil { return .cursor }
        if env["GEMINI_SESSION_ID"] != nil { return .gemini }
        if let marker = env["AI_AGENT"], let agent = agent(fromAIAgentMarker: marker) { return agent }
        let projectMarkers: [(String, AgentID)] = [
            ("FACTORY_PROJECT_DIR", .droid), ("QWEN_PROJECT_DIR", .qwen), ("AUGMENT_CONVERSATION_ID", .auggie),
            ("DEVIN_PROJECT_DIR", .devin), ("GROK_SESSION_ID", .grok), ("OPENHANDS_SESSION_ID", .openhands),
            ("CRUSH_SESSION_ID", .crush),
        ]
        for (name, agent) in projectMarkers where env[name] != nil { return agent }
        if env["CLAUDE_PID"] != nil { return .claude }
        return nil
    }

    /// `AI_AGENT=claude-code_2-1-288_harness` → claude, `AI_AGENT=crush` → crush.
    static func agent(fromAIAgentMarker marker: String) -> AgentID? {
        let name = marker.split(separator: "_").first.map(String.init) ?? marker
        let agent = AgentID(label: name)
        return agent == .unknown ? nil : agent
    }

    // MARK: - Ancestry helpers

    /// Shells and wrappers between an agent and its hook (`sh -c`, `$SHELL -lc`, `env`, …).
    static let wrapperNames: Set<String> = [
        "sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "env", "nohup", "timeout", "gtimeout", "xargs",
        "time", "stdbuf", "caffeinate",
    ]

    static func nearestNonShellAncestor(_ ancestry: [InboxAncestor]) -> InboxAncestor? {
        ancestry.first { !isWrapper($0) }
    }

    /// A shell or wrapper by argv[0], executable path or `p_comm` basename (`-zsh` login shells included).
    static func isWrapper(_ ancestor: InboxAncestor) -> Bool {
        let names = [ancestor.argv0, ancestor.path, ancestor.exe].compactMap { $0 }.map { name -> String in
            var base = (name as NSString).lastPathComponent
            if base.hasPrefix("-") { base.removeFirst() } // login shells: "-zsh"
            return base
        }
        return names.contains { wrapperNames.contains($0) }
    }

    /// The VS Code extension host (`Code Helper (Plugin)`, Insiders/VSCodium variants). `p_comm` is cut to 16
    /// characters (`Code Helper (Plu`).
    static func isVSCodeExtensionHost(_ ancestor: InboxAncestor) -> Bool {
        for candidate in [ancestor.argv0, ancestor.path].compactMap({ $0 }) {
            let base = (candidate as NSString).lastPathComponent
            if base.hasSuffix("Helper (Plugin)") && (base.hasPrefix("Code") || base.hasPrefix("VSCodium")) {
                return true
            }
        }
        return ancestor.exe?.hasPrefix("Code Helper (Pl") ?? false
    }

    // MARK: - Host app

    /// `HostApp.from(environment:)` first (pid filled from the ancestry when the same app is there), else the
    /// nearest ancestor inside an `.app` bundle (the main process of the OUTERMOST bundle preferred: a
    /// `Code Helper (Plugin)` belongs to VS Code).
    static func host(environment: [String: String], ancestry: [InboxAncestor], bundleLookup: BundleLookup) -> HostApp? {
        let apps = ancestry.compactMap { ancestor -> (pid: Int32, bundlePath: String, isMain: Bool)? in
            guard let location = appBundleLocation(ancestor.path ?? ancestor.argv0) else { return nil }
            return (ancestor.pid, location.bundlePath, location.isMainExecutable)
        }
        if var host = HostApp.from(environment: environment) {
            if let bundleID = host.bundleID,
               let match = apps.first(where: { $0.isMain && bundleLookup($0.bundlePath) == bundleID })
                ?? apps.first(where: { bundleLookup($0.bundlePath) == bundleID }) {
                host.pid = match.pid
            }
            return host
        }
        guard let nearest = apps.first else { return nil }
        let pid = apps.first(where: { $0.bundlePath == nearest.bundlePath && $0.isMain })?.pid ?? nearest.pid
        if let host = HostApp.from(bundleID: bundleLookup(nearest.bundlePath), pid: pid) { return host }
        let name = ((nearest.bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        return name.isEmpty ? nil : HostApp(bundleID: nil, name: name, pid: pid)
    }

    /// `/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/…` →
    /// (`/Applications/Cursor.app`, isMainExecutable: false); `/Applications/X.app/Contents/MacOS/X` → main.
    static func appBundleLocation(_ executable: String?) -> (bundlePath: String, isMainExecutable: Bool)? {
        guard let executable, executable.hasPrefix("/"), let range = executable.range(of: ".app/") else { return nil }
        let bundlePath = String(executable[..<range.lowerBound]) + ".app"
        let rest = executable[range.upperBound...]
        let isMain = rest.hasPrefix("Contents/MacOS/") && !rest.dropFirst("Contents/MacOS/".count).contains("/")
        return (bundlePath, isMain)
    }
}
