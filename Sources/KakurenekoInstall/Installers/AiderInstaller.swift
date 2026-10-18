import KakurenekoKit
import Foundation

/// Aider (brief §3.6 H; R03 §8): `~/.aider.conf.yml`. Aider has no config directory of its own beyond the
/// `~/.aider` cache folder, so it is offered when either exists.
struct AiderInstaller: IntegrationInstaller {
    let agent = AgentID.aider

    func configDirectories(_ context: InstallContext) -> [URL] { [context.paths.homeRelative(".aider")] }

    func isAvailable(_ context: InstallContext) -> Bool {
        context.fileSystem.exists(context.paths.aiderConfigFile)
            || context.fileSystem.directoryExists(context.paths.homeRelative(".aider"))
    }

    func managedFiles(_ context: InstallContext) -> [ManagedFile] {
        let file = context.paths.aiderConfigFile
        return [ManagedFile(url: file, kind: .spliced, splicer: AiderConfigSplicer(path: context.path(file), hook: context.hook))]
    }

    func notes(_ context: InstallContext) -> [String] {
        ["Aider rings the same bell for \"done\" and \"needs confirmation\"; a repo-level .aider.conf.yml or AIDER_NOTIFICATIONS_COMMAND overrides this."]
    }
}
