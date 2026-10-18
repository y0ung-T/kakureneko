import Foundation

/// Agent integrations (brief §3.6–3.7). Implemented by `KakurenekoInstall.IntegrationManager`.
///
/// Isolation: actor or `final class … : Sendable`; one operation at a time per agent.
/// Rules (binding): per-agent opt-in with a diff preview; only agents whose config dir exists (never
/// create `~/.<tool>`); backup before the first edit to `~/.kakureneko/backups/<agent>/<basename>.<ISO-ts>`;
/// temp file + fsync + rename (follow symlinks); format-preserving splices; re-parse after writing and roll
/// back on failure; ownership marker `/.kakureneko/bin/kakureneko-hook` in every entry; manifest
/// `~/.kakureneko/install-manifest.json`; uninstall restores byte for byte. When `DryRunGate.isOn`, nothing
/// is written and no mutating CLI runs (the result has `dryRun == true` and the ledger says "would write …").
/// Every agent-CLI subprocess sets `extraEnvironment: paths.agentSubprocessEnvironment` + `DISABLE_AUTOUPDATER=1`
/// (a `KAKURENEKO_HOME` run must never touch the real `~/.claude`).
public protocol AgentIntegrating: Sendable {
    /// Status of every agent in `AgentID.installableInV1` (config dir exists, installed, needs repair,
    /// needs trust step). `lastEventSeen` is left nil (the coordinator fills it).
    func statuses() async -> [IntegrationStatus]
    /// Builds the plan (diffs + commands) for `operation` without writing anything (the UI shows the diff before
    /// install, uninstall AND repair — brief §3.7.1).
    func preview(_ agent: AgentID, operation: InstallPlan.Operation) async throws -> InstallPlan
    /// Throws `SideEffectError.unavailable("hook helper not deployed")` when `paths.hookBinary` is not an
    /// executable file (skipped in dry-run) — never write hooks pointing at a missing helper.
    func install(_ agent: AgentID) async throws -> InstallResult
    func uninstall(_ agent: AgentID) async throws -> InstallResult
    /// Re-applies our entries after an agent rewrote its config (same helper check as `install`).
    func repair(_ agent: AgentID) async throws -> InstallResult
    /// Copies the bundled helper (`Kakureneko.app/Contents/Helpers/kakureneko-hook`) to `~/.kakureneko/bin/kakureneko-hook`
    /// (0755) when its SHA-256 differs; ensures `DirectoryLayout`. A copy, never a symlink.
    func deployHelper(from bundledHelper: URL) async throws -> HelperDeployment
}

extension AgentIntegrating {
    /// Install preview (the common case).
    public func preview(_ agent: AgentID) async throws -> InstallPlan { try await preview(agent, operation: .install) }
}
