import KakurenekoKit
import Foundation

/// The Claude-compatible family (DECISIONS "Installers"; brief §3.4; R04 §3, §4): Factory Droid, Qwen Code,
/// Auggie, Qoder, CodeBuddy, iFlow and Devin CLI all take Claude-shaped groups
/// (`"Event": [{ "matcher"?, "hooks": [{ "type": "command", "command", "timeout" }] }]`) in a JSON settings file.
/// One generic routine; a `Spec` per agent carries the file, the events and the timeout unit.
struct ClaudeFamilyInstaller: IntegrationInstaller {
    /// Where an agent keeps its hooks.
    struct Location: Sendable {
        var file: URL
        /// Keys from the root to the object keyed by event name.
        var containerKeys: [String]
    }

    struct Spec: Sendable {
        var agent: AgentID
        /// The agent's directory (phantom-install rule).
        var directory: @Sendable (InstallContext) -> URL
        /// Candidate locations; the first is where install writes unless `activeLocation` picks another.
        var locations: @Sendable (InstallContext) -> [Location]
        /// Index into `locations` of the file the agent actually reads (default 0).
        var activeLocation: @Sendable (InstallContext, [Location]) -> Int = { _, _ in 0 }
        var events: [String]
        /// Seconds for most of the family; Auggie uses milliseconds (brief §3.4).
        var timeout: Int
        var matcher: String?
        var handlerName: String?
        var notes: [String] = []
    }

    let spec: Spec

    var agent: AgentID { spec.agent }

    func configDirectories(_ context: InstallContext) -> [URL] { [spec.directory(context)] }

    func managedFiles(_ context: InstallContext) -> [ManagedFile] {
        let locations = spec.locations(context)
        let active = spec.activeLocation(context, locations)
        let entries = spec.events.map { event in
            HookEventEntries(event: event, entries: [
                HookEntries.claudeStyleGroup(
                    command: context.hook.shell(agent, event), timeout: spec.timeout, matcher: spec.matcher, name: spec.handlerName),
            ])
        }
        return locations.enumerated().map { index, location in
            ManagedFile(
                url: location.file,
                kind: .spliced,
                splicer: JSONHookSplicer(
                    path: context.path(location.file), dialect: .jsonc, containerKeys: location.containerKeys, events: entries),
                role: index == active ? .target : .cleanupOnly
            )
        }
    }

    func notes(_ context: InstallContext) -> [String] {
        var notes = spec.notes
        for file in managedFiles(context) where file.role == .target {
            if let off = HooksSwitch.note(file.url, rules: [HooksSwitch.disableAllHooks], context: context) { notes.append(off) }
        }
        return notes
    }

    // MARK: - The family (R04 §3.3, §3.4, §3.7, §4)

    static let claudeEvents = ["SessionStart", "UserPromptSubmit", "Stop", "Notification", "SessionEnd"]

    static var all: [ClaudeFamilyInstaller] {
        [droid, qwen, auggie, qoder, codebuddy, iflow, devin].map(ClaudeFamilyInstaller.init(spec:))
    }

    /// `~/.factory/hooks.json` (keyed directly by event) wins; Droid reads `settings.json` `"hooks"` only when
    /// `hooks.json` is absent (R04 §2.4).
    static let droid = Spec(
        agent: .droid,
        directory: { $0.paths.homeRelative(".factory") },
        locations: { context in
            [
                Location(file: context.paths.homeRelative(".factory/hooks.json"), containerKeys: []),
                Location(file: context.paths.homeRelative(".factory/settings.json"), containerKeys: ["hooks"]),
            ]
        },
        activeLocation: { context, locations in
            if context.fileSystem.exists(locations[0].file) { return 0 }
            return context.fileSystem.exists(locations[1].file) ? 1 : 0
        },
        events: ["SessionStart", "UserPromptSubmit", "Notification", "Stop", "SessionEnd"],
        timeout: 5,
        notes: ["Droid reads ~/.factory/hooks.json when it exists, otherwise the \"hooks\" key of ~/.factory/settings.json."]
    )

    /// `~/.qwen/settings.json` (or `$QWEN_HOME`, honoured only for the real home).
    static let qwen = Spec(
        agent: .qwen,
        directory: qwenDirectory,
        locations: { [Location(file: qwenDirectory($0).appending(path: "settings.json", directoryHint: .notDirectory), containerKeys: ["hooks"])] },
        events: ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "Notification", "PermissionRequest", "SessionEnd"],
        timeout: 5,
        matcher: "*",
        handlerName: KakurenekoID.claudePluginName
    )

    @Sendable static func qwenDirectory(_ context: InstallContext) -> URL {
        if !context.paths.isHomeOverridden, let value = context.paths.environment["QWEN_HOME"], value.hasPrefix("/") {
            return URL(filePath: value, directoryHint: .isDirectory)
        }
        return context.paths.homeRelative(".qwen")
    }

    /// Augment Auggie: milliseconds.
    static let auggie = Spec(
        agent: .auggie,
        directory: { $0.paths.homeRelative(".augment") },
        locations: { [Location(file: $0.paths.homeRelative(".augment/settings.json"), containerKeys: ["hooks"])] },
        events: ["SessionStart", "Stop", "Notification", "SessionEnd"],
        timeout: 5000,
        notes: ["Auggie reports no reliable needs-input event."]
    )

    static let qoder = Spec(
        agent: .qoder,
        directory: { $0.paths.homeRelative(".qoder") },
        locations: { [Location(file: $0.paths.homeRelative(".qoder/settings.json"), containerKeys: ["hooks"])] },
        events: ["SessionStart", "UserPromptSubmit", "Stop", "Notification", "PermissionRequest", "SessionEnd"],
        timeout: 5
    )

    static let codebuddy = Spec(
        agent: .codebuddy,
        directory: { $0.paths.homeRelative(".codebuddy") },
        locations: { [Location(file: $0.paths.homeRelative(".codebuddy/settings.json"), containerKeys: ["hooks"])] },
        events: claudeEvents,
        timeout: 5
    )

    static let iflow = Spec(
        agent: .iflow,
        directory: { $0.paths.homeRelative(".iflow") },
        locations: { [Location(file: $0.paths.homeRelative(".iflow/settings.json"), containerKeys: ["hooks"])] },
        events: ["SessionStart", "Stop", "Notification", "SessionEnd"],
        timeout: 5
    )

    /// Devin CLI: `~/.config/devin/config.json` → `hooks` (it also reads `~/.claude/settings.json`, which the
    /// Claude plugin route leaves alone).
    static let devin = Spec(
        agent: .devin,
        directory: { $0.paths.homeRelative(".config/devin") },
        locations: { [Location(file: $0.paths.homeRelative(".config/devin/config.json"), containerKeys: ["hooks"])] },
        events: ["SessionStart", "Stop", "PermissionRequest", "SessionEnd"],
        timeout: 5
    )
}
