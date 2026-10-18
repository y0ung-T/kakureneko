import KakurenekoKit
import Foundation

/// Gemini CLI (brief §3.6 C; R03 §3): `~/.gemini/settings.json` → `hooks`, timeouts in ms, `name`d handlers.
/// The file is JSON with comments (Gemini strips them before parsing).
struct GeminiInstaller: IntegrationInstaller {
    let agent = AgentID.gemini

    static let events: [(name: String, handler: String)] = [
        ("SessionStart", "kakureneko-session-start"),
        ("BeforeAgent", "kakureneko-busy"),
        ("AfterAgent", "kakureneko-turn-done"),
        ("Notification", "kakureneko-needs-input"),
        ("SessionEnd", "kakureneko-session-end"),
    ]

    func settingsFile(_ context: InstallContext) -> URL {
        context.paths.geminiDirectory.appending(path: "settings.json", directoryHint: .notDirectory)
    }

    func configDirectories(_ context: InstallContext) -> [URL] { [context.paths.geminiDirectory] }

    func managedFiles(_ context: InstallContext) -> [ManagedFile] {
        let file = settingsFile(context)
        let entries = Self.events.map { event in
            HookEventEntries(event: event.name, entries: [
                HookEntries.claudeStyleGroup(
                    command: context.hook.shell(agent, event.name), timeout: 5000, name: event.handler, nameFirst: true),
            ])
        }
        return [ManagedFile(url: file, kind: .spliced, splicer: JSONHookSplicer(
            path: context.path(file), dialect: .jsonc, containerKeys: ["hooks"], events: entries))]
    }

    func notes(_ context: InstallContext) -> [String] {
        HooksSwitch.note(settingsFile(context), rules: [HooksSwitch.geminiHooksEnabled], context: context).map { [$0] } ?? []
    }
}

/// Antigravity CLI `agy` (brief §3.6 D; R03 §4): `~/.gemini/config/hooks.json`, one top-level key `"kakureneko"`
/// (the file is keyed by hook name, so ours is additive). Stop only; timeout in seconds.
struct AgyInstaller: IntegrationInstaller {
    let agent = AgentID.agy
    static let hookName = KakurenekoID.claudePluginName // "kakureneko"

    func hooksFile(_ context: InstallContext) -> URL {
        context.paths.geminiDirectory.appending(path: "config/hooks.json", directoryHint: .notDirectory)
    }

    func configDirectories(_ context: InstallContext) -> [URL] {
        [
            context.paths.geminiDirectory.appending(path: "config", directoryHint: .isDirectory),
            context.paths.geminiDirectory.appending(path: "antigravity-cli", directoryHint: .isDirectory),
        ]
    }

    func managedFiles(_ context: InstallContext) -> [ManagedFile] {
        let file = hooksFile(context)
        let stop = JSONLiteral.compact(.fields([
            "type": .string("command"),
            "command": .string(context.hook.shell(agent, "Stop")),
            "timeout": .int(5),
        ]))
        return [ManagedFile(url: file, kind: .spliced, splicer: JSONHookSplicer(
            path: context.path(file), dialect: .jsonc, containerKeys: [Self.hookName],
            events: [HookEventEntries(event: "Stop", entries: [stop])]))]
    }

    func notes(_ context: InstallContext) -> [String] {
        ["Antigravity only reports Stop; busy and needs-input come from process heuristics."]
    }
}
