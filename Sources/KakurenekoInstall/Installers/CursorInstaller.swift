import KakurenekoKit
import Foundation

/// Cursor IDE agent + CLI (brief §3.6 F; R03 §6, R05 §3.2): `~/.cursor/hooks.json`, keep `"version": 1`, append
/// to the arrays. Never permission hooks (`preToolUse`, `beforeShellExecution`, `beforeMCPExecution`,
/// `beforeReadFile`, `subagentStart` block on invalid JSON).
struct CursorInstaller: IntegrationInstaller {
    let agent = AgentID.cursor

    static let events = ["sessionStart", "beforeSubmitPrompt", "postToolUse", "stop", "sessionEnd"]

    func hooksFile(_ context: InstallContext) -> URL {
        context.paths.cursorDirectory.appending(path: "hooks.json", directoryHint: .notDirectory)
    }

    func configDirectories(_ context: InstallContext) -> [URL] { [context.paths.cursorDirectory] }

    func managedFiles(_ context: InstallContext) -> [ManagedFile] {
        let file = hooksFile(context)
        let entries = Self.events.map { event in
            HookEventEntries(event: event, entries: [
                .compact(.fields(["command": .string(context.hook.shell(agent, event)), "timeout": .int(5)])),
            ])
        }
        return [ManagedFile(url: file, kind: .spliced, splicer: JSONHookSplicer(
            path: context.path(file), dialect: .strict, containerKeys: ["hooks"], events: entries,
            preamble: [JSONField(key: "version", value: .int(1))]))]
    }

    func notes(_ context: InstallContext) -> [String] {
        ["The Cursor CLI with -p sends no stop event; process heuristics cover it."]
    }
}
