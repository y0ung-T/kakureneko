import KakurenekoKit
import Foundation

/// OpenAI Codex (brief §3.6 B1/B2, C8; R03 §2): `notify` in `config.toml` (turn complete, no trust needed) plus
/// append-only groups in `hooks.json` (inert until the user reviews them once in `/hooks`). Honours `CODEX_HOME`
/// through `Paths.codexHome`. Never writes `[hooks.state]` / `trusted_hash`.
struct CodexInstaller: IntegrationInstaller {
    let agent = AgentID.codex

    /// `(event, timeout, matcher)` of snippet B2.
    static let events: [(name: String, timeout: Int, matcher: String?)] = [
        ("SessionStart", 5, nil),
        ("UserPromptSubmit", 5, nil),
        ("PermissionRequest", 5, "*"),
        ("Stop", 5, nil),
        ("Interrupt", 1, nil),
        ("SessionEnd", 1, nil),
    ]

    static let trustNote = "Codex runs the new hooks only after a one-time review: open Codex and run /hooks. Turn-complete (notify) works right away."

    func configFile(_ context: InstallContext) -> URL {
        context.paths.codexHome.appending(path: "config.toml", directoryHint: .notDirectory)
    }

    func hooksFile(_ context: InstallContext) -> URL {
        context.paths.codexHome.appending(path: "hooks.json", directoryHint: .notDirectory)
    }

    func configDirectories(_ context: InstallContext) -> [URL] { [context.paths.codexHome] }

    func managedFiles(_ context: InstallContext) -> [ManagedFile] {
        let config = configFile(context)
        let hooks = hooksFile(context)
        let entries = Self.events.map { event in
            HookEventEntries(event: event.name, entries: [
                HookEntries.claudeStyleGroup(
                    command: context.hook.shell(agent, event.name), timeout: event.timeout, matcher: event.matcher),
            ])
        }
        return [
            ManagedFile(url: config, kind: .spliced, splicer: CodexNotifySplicer(path: context.path(config), hookPath: context.hookPath)),
            ManagedFile(url: hooks, kind: .spliced, splicer: JSONHookSplicer(
                path: context.path(hooks),
                dialect: .strict, // serde_json, `deny_unknown_fields` at the top level
                containerKeys: ["hooks"],
                events: entries,
                preamble: [JSONField(key: "description", value: .string("Kakureneko agent-state hooks"))]
            )),
        ]
    }

    func needsTrustStep(_ context: InstallContext) -> Bool {
        guard let hooksText = try? context.fileSystem.readText(hooksFile(context)) else { return false }
        let ours = CodexTrust.ourHandlers(inHooksJSON: hooksText)
        guard !ours.isEmpty else { return false }
        let configText = (try? context.fileSystem.readText(configFile(context))) ?? ""
        return !CodexTrust.isTrusted(ours, stateKeys: CodexTrust.trustedStateKeys(inConfig: configText))
    }

    func notes(_ context: InstallContext) -> [String] {
        var notes = [Self.trustNote]
        guard let text = try? context.fileSystem.readText(configFile(context)),
              let document = try? TOMLDocument(text) else { return notes }
        let values = document.resolvedKeyValues
        if values.contains(where: { ($0.path == ["features", "hooks"] || $0.path == ["features", "codex_hooks"]) && $0.value == .other("false") }) {
            notes.append("Hooks are turned off in config.toml ([features] hooks = false); only notify reports to Kakureneko.")
        }
        let inlineHooks = document.tablePaths.contains { $0.first == "hooks" && $0.dropFirst().first != "state" }
            || values.contains { $0.path.first == "hooks" && $0.path.dropFirst().first != "state" }
        if inlineHooks {
            notes.append("config.toml also defines inline [hooks]; Codex merges them with hooks.json and warns at startup.")
        }
        return notes
    }

    var followUpNote: String? { Self.trustNote }
}
