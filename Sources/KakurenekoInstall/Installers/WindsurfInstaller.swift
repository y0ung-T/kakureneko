import KakurenekoKit
import Foundation

/// Windsurf / Devin Desktop Cascade (brief §3.4; R05 §3.8): `~/.codeium/windsurf/hooks.json` → `hooks`.
struct WindsurfInstaller: IntegrationInstaller {
    let agent = AgentID.windsurf

    static let events = ["pre_user_prompt", "post_cascade_response", "post_run_command"]

    func hooksFile(_ context: InstallContext) -> URL {
        context.paths.windsurfDirectory.appending(path: "hooks.json", directoryHint: .notDirectory)
    }

    func configDirectories(_ context: InstallContext) -> [URL] { [context.paths.windsurfDirectory] }

    func managedFiles(_ context: InstallContext) -> [ManagedFile] {
        let file = hooksFile(context)
        let entries = Self.events.map { event in
            HookEventEntries(event: event, entries: [
                .compact(.fields(["command": .string(context.hook.shell(agent, event)), "show_output": .bool(false)])),
            ])
        }
        return [ManagedFile(url: file, kind: .spliced, splicer: JSONHookSplicer(
            path: context.path(file), dialect: .jsonc, containerKeys: ["hooks"], events: entries))]
    }

    func notes(_ context: InstallContext) -> [String] {
        ["Cascade reports no needs-input event; process heuristics cover waiting."]
    }
}
