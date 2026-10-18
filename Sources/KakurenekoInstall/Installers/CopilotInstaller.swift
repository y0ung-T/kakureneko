import KakurenekoKit
import Foundation

/// GitHub Copilot CLI + VS Code Local agent (brief §3.6 E, C7; R03 §5, R05 §3.3): our own file
/// `<COPILOT_HOME>/hooks/kakureneko.json` in pure Copilot format (`version: 1`, lowerCamelCase, `bash`,
/// `timeoutSec`). Never `preToolUse` (fails closed) or `permissionRequest`.
struct CopilotInstaller: IntegrationInstaller {
    let agent = AgentID.copilot

    static let notificationMatcher = "permission_prompt|elicitation_dialog|agent_idle|agent_completed"
    static let events = ["sessionStart", "userPromptSubmitted", "agentStop", "errorOccurred", "notification", "sessionEnd"]

    func hooksFile(_ context: InstallContext) -> URL {
        context.paths.copilotHome.appending(path: "hooks/\(KakurenekoID.claudePluginName).json", directoryHint: .notDirectory)
    }

    func configDirectories(_ context: InstallContext) -> [URL] { [context.paths.copilotHome] }

    func document(_ context: InstallContext) -> JSONLiteral {
        let hooks = Self.events.map { event -> JSONField in
            var fields: [JSONField] = [JSONField(key: "type", value: .string("command"))]
            if event == "notification" { fields.append(JSONField(key: "matcher", value: .string(Self.notificationMatcher))) }
            fields.append(JSONField(key: "bash", value: .string(context.hook.shell(agent, event))))
            fields.append(JSONField(key: "timeoutSec", value: .int(5)))
            return JSONField(key: event, value: .array([.compact(.object(fields))]))
        }
        return .fields(["version": .int(1), "hooks": .object(hooks)])
    }

    func managedFiles(_ context: InstallContext) -> [ManagedFile] {
        let file = hooksFile(context)
        return [ManagedFile(url: file, kind: .ownedFile, splicer: OwnedFileSplicer(
            path: context.path(file),
            content: JSONRenderer().renderDocument(document(context)),
            validation: .json,
            locationIsOwned: false
        ))]
    }

    func notes(_ context: InstallContext) -> [String] {
        var notes = ["One file serves Copilot CLI and the VS Code Local agent; VS Code reports no needs-input event."]
        let settings = context.paths.copilotHome.appending(path: "settings.json", directoryHint: .notDirectory)
        if let off = HooksSwitch.note(settings, rules: [HooksSwitch.disableAllHooks], context: context) { notes.append(off) }
        return notes
    }
}
