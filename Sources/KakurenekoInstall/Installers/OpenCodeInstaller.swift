import KakurenekoKit
import Foundation

/// opencode v1 (≥ 1.18.29) and v2 (brief §3.6 G; R03 §7): our own plugin file
/// `<XDG_CONFIG_HOME>/opencode/plugins/kakureneko.js`. It spawns the hook detached and swallows every error, so
/// it can never throw inside opencode's process. (fix) An installed opencode older than 1.18.29 (read with
/// `opencode --version`) gets the legacy function-export form instead (brief §3.6 G: older v1 loaders reject the
/// object form); an unknown version gets the object form.
struct OpenCodeInstaller: IntegrationInstaller {
    let agent = AgentID.opencode

    /// The first v1 that loads the object form.
    static let objectFormMinimum = OpenCodeVersion(major: 1, minor: 18, patch: 29)

    /// Where the opencode binary usually is (curl installer, bun, npm, Homebrew).
    static func binaryCandidates(_ paths: Paths) -> [String] {
        [".opencode/bin/opencode", ".bun/bin/opencode", ".npm-global/bin/opencode", ".local/bin/opencode"]
            .map { paths.homeRelative($0).path(percentEncoded: false) }
            + ["/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"]
    }

    /// The legacy function-export form for opencode v1 < 1.18.29.
    func usesLegacyForm(_ context: InstallContext) -> Bool {
        guard let version = context.opencodeVersion else { return false }
        return version < Self.objectFormMinimum
    }

    func pluginFile(_ context: InstallContext) -> URL {
        context.paths.opencodeConfigDirectory.appending(path: "plugins/\(KakurenekoID.claudePluginName).js", directoryHint: .notDirectory)
    }

    func configDirectories(_ context: InstallContext) -> [URL] { [context.paths.opencodeConfigDirectory] }

    func source(_ context: InstallContext) -> String {
        """
        // Kakureneko activity reporter for opencode (v1 >= 1.18.29 and v2). Written by the Kakureneko menu-bar app;
        // removing the integration in Kakureneko deletes this file. It never blocks or throws.
        import { spawn } from "node:child_process"
        const HOOK = \(JSONRenderer.quote(context.hookPath))
        const KEEP = new Set(["session.status","session.idle","session.created","session.deleted","session.error",
                              "permission.asked","permission.replied","question.asked","form.created","form.replied"])
        function emit(type, payload) {
          try {
            const p = spawn(HOOK, ["opencode", type], { stdio: ["pipe", "ignore", "ignore"], detached: true })
            p.on("error", () => {}); p.stdin.on("error", () => {})
            p.stdin.end(JSON.stringify({ ...payload, pid: process.pid })); p.unref()
          } catch {}
        }
        function handle(event, ctx) {
          const t = event?.type
          if (KEEP.has(t)) emit(t, { type: t, properties: event?.properties ?? event?.data ?? null, directory: ctx?.directory ?? null })
        }
        \(usesLegacyForm(context) ? Self.legacyExport : Self.objectExport)
        """
    }

    /// v1 (≥ 1.18.29) and v2.
    static let objectExport = """
        export default {
          id: "\(KakurenekoID.claudePluginName)",
          server: async (input) => ({ event: async ({ event }) => handle(event, input) }),          // v1 (>= 1.18.29)
          setup: async (ctx) => {                                                                   // v2
            const ac = new AbortController()
            ;(async () => { for await (const ev of ctx.event.subscribe({ signal: ac.signal })) handle(ev, ctx) })().catch(() => {})
            return () => ac.abort()
          },
        }

        """

    /// opencode v1 before 1.18.29 (function export only; brief §3.6 G).
    static let legacyExport = """
        export const KakurenekoPlugin = async (input) => ({ event: async ({ event }) => handle(event, input) })   // v1 (< 1.18.29)

        """

    func managedFiles(_ context: InstallContext) -> [ManagedFile] {
        let file = pluginFile(context)
        return [ManagedFile(url: file, kind: .ownedFile, splicer: OwnedFileSplicer(
            path: context.path(file), content: source(context), validation: .text, locationIsOwned: false))]
    }

    func notes(_ context: InstallContext) -> [String] {
        if usesLegacyForm(context), let version = context.opencodeVersion {
            return ["opencode \(version) is older than \(Self.objectFormMinimum): Kakureneko uses the older plugin form. "
                + "Reinstall the integration after updating opencode; open sessions pick the plugin up after a restart."]
        }
        return ["Needs opencode 1.18.29 or later (or v2); open sessions pick the plugin up after a restart."]
    }
}

/// `major.minor.patch` from `opencode --version` (the first such token; `v` prefixes and suffixes ignored).
struct OpenCodeVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    var major: Int
    var minor: Int
    var patch: Int

    static func parse(_ text: String) -> OpenCodeVersion? {
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            var word = Substring(token)
            if word.first == "v" || word.first == "V" { word = word.dropFirst() }
            let parts = word.split(separator: ".", maxSplits: 2).map { $0.prefix { $0.isNumber } }
            guard parts.count == 3, let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else {
                continue
            }
            return OpenCodeVersion(major: major, minor: minor, patch: patch)
        }
        return nil
    }

    static func < (lhs: OpenCodeVersion, rhs: OpenCodeVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}
