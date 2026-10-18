@testable import KakurenekoInstall
import KakurenekoKit
import Foundation
import Testing

@Suite("JSON hook splicing", .timeLimit(.minutes(1)))
struct JSONSpliceTests {
    private func gemini(_ home: TestHome) -> any ConfigSplicer {
        GeminiInstaller().managedFiles(makeContext(home))[0].splicer
    }

    @Test func installKeepsCommentsKeyOrderAndUserHookThenUninstallRestoresBytes() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let splicer = gemini(home)
        let installed = try splicer.install(into: Fixtures.geminiSettings, previous: nil).text

        // Comments and every user key survive, in their original order.
        for fragment in ["// Gemini CLI settings", "/* MCP servers */", "\"theme\": \"GitHub\"", "~/bin/log-turn.sh"] {
            #expect(installed.contains(fragment))
        }
        let order = ["\"theme\"", "\"selectedAuthType\"", "\"mcpServers\"", "\"hooks\""].map { installed.range(of: $0)!.lowerBound }
        #expect(order == order.sorted())
        // The user's AfterAgent group is kept, ours appended after it.
        let commands = try handlerCommands(installed, containerKeys: ["hooks"])
        #expect(commands.first == "~/bin/log-turn.sh")
        #expect(commands.filter { $0.contains(KakurenekoID.ownershipMarker) }.count == 5)
        #expect(commands.contains("\(home.hookPath) gemini AfterAgent 2>/dev/null; exit 0"))
        #expect(installed.contains("\"timeout\": 5000"))
        #expect(installed.contains("\"name\": \"kakureneko-turn-done\""))

        let restored = try splicer.uninstall(from: installed, previous: nil)
        #expect(restored == Fixtures.geminiSettings)
    }

    @Test func installIsIdempotentAndReplacesStaleEntries() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let splicer = gemini(home)
        let once = try splicer.install(into: Fixtures.geminiSettings, previous: nil).text
        #expect(try splicer.install(into: once, previous: nil).text == once)

        // An older install pointed at another helper path: it is replaced, never duplicated.
        let stale = once.replacingOccurrences(of: home.hookPath, with: "/Users/old/.kakureneko/bin/kakureneko-hook")
        let repaired = try splicer.install(into: stale, previous: nil).text
        let commands = try handlerCommands(repaired, containerKeys: ["hooks"])
        #expect(commands.filter { $0.contains(KakurenekoID.ownershipMarker) }.count == 5)
        #expect(!repaired.contains("/Users/old/"))
        #expect(commands.contains("~/bin/log-turn.sh"))
    }

    @Test func uninstallInsideMixedGroupRemovesOnlyOurHandler() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let mixed = """
        {
          "hooks": {
            "AfterAgent": [
              { "hooks": [
                { "type": "command", "command": "~/bin/mine.sh" },
                { "type": "command", "command": "\(home.hookPath) gemini AfterAgent 2>/dev/null; exit 0" }
              ] }
            ]
          }
        }
        """
        let result = try #require(try gemini(home).uninstall(from: mixed, previous: nil))
        #expect(!result.contains(KakurenekoID.ownershipMarker))
        #expect(result.contains("~/bin/mine.sh"))
        _ = try JSONSyntax.parse(result, dialect: .strict)
    }

    @Test func roundTripsOddFormattingByteForByte() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let context = makeContext(home)
        let cases: [(any ConfigSplicer, String)] = [
            (CursorInstaller().managedFiles(context)[0].splicer, Fixtures.cursorHooks),
            (CodexInstaller().managedFiles(context)[1].splicer, Fixtures.codexHooks),
            (AgyInstaller().managedFiles(context)[0].splicer, Fixtures.agyHooks),
            (ClaudeFamilyInstaller(spec: ClaudeFamilyInstaller.qwen).managedFiles(context)[0].splicer, Fixtures.qwenSettings),
            (ClaudeFamilyInstaller(spec: ClaudeFamilyInstaller.auggie).managedFiles(context)[0].splicer, Fixtures.auggieSettings),
            (ClaudeFamilyInstaller(spec: ClaudeFamilyInstaller.devin).managedFiles(context)[0].splicer, Fixtures.devinConfig),
            (WindsurfInstaller().managedFiles(context)[0].splicer, Fixtures.windsurfHooks),
            (gemini(home), Fixtures.bomEmpty),
            (gemini(home), "{\n  \"a\": 1,\n  \"b\": [1, 2],\n}\n"), // JSONC trailing comma
        ]
        for (splicer, original) in cases {
            let installed = try splicer.install(into: original, previous: nil).text
            #expect(installed != original)
            #expect(splicer.containsOurs(installed))
            try splicer.validate(installed)
            let restored = try splicer.uninstall(from: installed, previous: nil)
            #expect(restored == original, "round trip changed \(original.debugDescription)")
        }
    }

    @Test func crlfAndTabsAreFollowedWhenSplicing() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let context = makeContext(home)
        let qwen = ClaudeFamilyInstaller(spec: ClaudeFamilyInstaller.qwen).managedFiles(context)[0].splicer
        let installed = try qwen.install(into: Fixtures.qwenSettings, previous: nil).text
        // Every line break stays CRLF.
        let bytes = Array(installed.utf8)
        for (i, byte) in bytes.enumerated() where byte == 0x0A { #expect(i > 0 && bytes[i - 1] == 0x0D) }
        #expect(installed.contains("\"matcher\": \"*\""))
        #expect(installed.contains("\"name\": \"kakureneko\""))

        let cursor = CursorInstaller().managedFiles(context)[0].splicer
        let tabbed = try cursor.install(into: Fixtures.cursorHooks, previous: nil).text
        #expect(tabbed.contains("\n\t\t\"sessionStart\": ["))
    }

    @Test func refusesFilesItCannotEditSafely() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let context = makeContext(home)
        let cursor = CursorInstaller().managedFiles(context)[0].splicer
        // Cursor's file is strict JSON: a comment makes it unparseable for us, so nothing is written.
        #expect(throws: InstallError.self) { try cursor.install(into: "{ // hi\n}", previous: nil) }
        #expect(throws: InstallError.self) { try gemini(home).install(into: "[1, 2]", previous: nil) }
        #expect(throws: InstallError.self) { try gemini(home).install(into: "{\"hooks\": null}", previous: nil) }
        #expect(throws: InstallError.self) { try gemini(home).install(into: "{\"hooks\": {\"AfterAgent\": {}}}", previous: nil) }
    }

    @Test func newFilesMatchTheSnippets() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let context = makeContext(home)
        let cursor = try CursorInstaller().managedFiles(context)[0].splicer.install(into: nil, previous: nil).text
        let editor = try JSONEditor(text: cursor, dialect: .strict, path: "hooks.json")
        #expect(editor.node(at: ["version"])?.value == .number(1))
        #expect(editor.node(at: ["hooks"])?.members?.map(\.key) == CursorInstaller.events)
        #expect(try handlerCommands(cursor, containerKeys: ["hooks"], dialect: .strict).allSatisfy { $0.hasSuffix(" 2>/dev/null; exit 0") })

        let codex = try CodexInstaller().managedFiles(context)[1].splicer.install(into: nil, previous: nil).text
        let codexEditor = try JSONEditor(text: codex, dialect: .strict, path: "hooks.json")
        #expect(codexEditor.root.members?.map(\.key) == ["description", "hooks"])
        #expect(codexEditor.node(at: ["hooks", "PermissionRequest"])?.elements?.first?.member("matcher")?.value.stringValue == "*")
        let interruptGroup = try #require(codexEditor.node(at: ["hooks", "Interrupt"])?.elements?.first)
        let interruptHandler = try #require(interruptGroup.member("hooks")?.value.elements?.first)
        let interruptTimeout: JSONValue? = interruptHandler.member("timeout")?.value.value
        #expect(interruptTimeout == JSONValue.number(1))

        // Droid's hooks.json is keyed directly by event name.
        let droid = try ClaudeFamilyInstaller(spec: ClaudeFamilyInstaller.droid).managedFiles(context)[0].splicer
            .install(into: nil, previous: nil).text
        let droidEditor = try JSONEditor(text: droid, dialect: .strict, path: "hooks.json")
        #expect(droidEditor.root.members?.map(\.key) == ["SessionStart", "UserPromptSubmit", "Notification", "Stop", "SessionEnd"])
    }

    @Test func uninstallDeletesAFileWeCreatedOnlyWhenNothingElseIsLeft() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let splicer = CursorInstaller().managedFiles(makeContext(home))[0].splicer
        let created = try splicer.install(into: nil, previous: nil).text
        let ours = InstallManifestEntry(agent: .cursor, file: "x", kind: .spliced, sha256Before: nil, sha256After: "", installedAt: Date())
        #expect(try splicer.uninstall(from: created, previous: ours) == nil)

        // The user added a hook of their own afterwards: the file stays, without our entries.
        var editor = try JSONEditor(text: created, dialect: .strict, path: "x")
        try editor.appendHookEntries([HookEventEntries(event: "afterFileEdit", entries: [.compact(.fields(["command": .string("fmt")]))])],
                                     containerKeys: ["hooks"])
        let kept = try #require(try splicer.uninstall(from: editor.text, previous: ours))
        #expect(kept.contains("fmt"))
        #expect(!kept.contains(KakurenekoID.ownershipMarker))
    }
}

@Suite("Codex notify (TOML)", .timeLimit(.minutes(1)))
struct CodexNotifyTests {
    private func splicer(_ home: TestHome) -> CodexNotifySplicer {
        CodexNotifySplicer(path: "config.toml", hookPath: home.hookPath)
    }

    @Test func chainsAnExistingNotifyWithTheExactStringsOfTheBrief() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let original = "notify = [\"X\", \"a\"]\n"
        let outcome = try splicer(home).install(into: original, previous: nil)
        #expect(outcome.text == "notify = [\"\(home.hookPath)\", \"codex\", \"notify\", \"--chain\", \"--\", \"X\", \"a\"]\n")
        #expect(outcome.chainedOriginal == "notify = [\"X\", \"a\"]")

        let entry = InstallManifestEntry(agent: .codex, file: "config.toml", kind: .spliced, sha256Before: "x", sha256After: "y",
                                         chainedOriginal: outcome.chainedOriginal, installedAt: Date())
        #expect(try splicer(home).uninstall(from: outcome.text, previous: entry) == original)
    }

    @Test func plainNotifyGoesBeforeTheFirstTable() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let outcome = try splicer(home).install(into: Fixtures.codexConfigNoNotify, previous: nil)
        #expect(outcome.text == "model = \"o4\"\nnotify = [\"\(home.hookPath)\", \"codex\", \"notify\"]\n\n[tui]\nnotifications = false")
        #expect(outcome.chainedOriginal == nil)
        #expect(try splicer(home).uninstall(from: outcome.text, previous: nil) == Fixtures.codexConfigNoNotify)

        // Only tables: the key goes to the very top (still the root table).
        let tablesOnly = "# settings\n[tui]\nx = 1\n"
        let top = try splicer(home).install(into: tablesOnly, previous: nil).text
        #expect(top.hasPrefix("notify = ["))
        #expect(try splicer(home).uninstall(from: top, previous: nil) == tablesOnly)

        // Root key-values ending the file without a newline.
        let noNewline = "model = \"o4\""
        let appended = try splicer(home).install(into: noNewline, previous: nil).text
        #expect(appended == "model = \"o4\"\nnotify = [\"\(home.hookPath)\", \"codex\", \"notify\"]")
        #expect(try splicer(home).uninstall(from: appended, previous: nil) == noNewline)
    }

    @Test func realisticConfigRoundTripsWithCommentsAndTables() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let outcome = try splicer(home).install(into: Fixtures.codexConfig, previous: nil)
        #expect(outcome.chainedOriginal == "notify = [\"terminal-notifier\", \"-title\", \"Codex\"]   # desktop ping")
        #expect(outcome.text.contains("notify = [\"\(home.hookPath)\", \"codex\", \"notify\", \"--chain\", \"--\", \"terminal-notifier\", \"-title\", \"Codex\"]\n"))
        for fragment in ["# Codex configuration", "[mcp_servers.docs]", "# comment inside an array with [brackets]", "[profiles.fast]"] {
            #expect(outcome.text.contains(fragment))
        }
        try splicer(home).validate(outcome.text)
        let entry = InstallManifestEntry(agent: .codex, file: "c", kind: .spliced, sha256Before: "x", sha256After: "y",
                                         chainedOriginal: outcome.chainedOriginal, installedAt: Date())
        #expect(try splicer(home).uninstall(from: outcome.text, previous: entry) == Fixtures.codexConfig)
        // Idempotent re-install keeps the chain and the saved original.
        let again = try splicer(home).install(into: outcome.text, previous: entry)
        #expect(again == outcome)
    }

    @Test func multiLineNotifyIsRestoredByteForByte() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let original = "model = \"o3\"\nnotify = [\n  \"python3\",  # interpreter\n  '/Users/me/notify.py',\n]\n[tui]\n"
        let outcome = try splicer(home).install(into: original, previous: nil)
        #expect(outcome.text.contains("\"--chain\", \"--\", \"python3\", \"/Users/me/notify.py\"]"))
        let entry = InstallManifestEntry(agent: .codex, file: "c", kind: .spliced, sha256Before: "x", sha256After: "y",
                                         chainedOriginal: outcome.chainedOriginal, installedAt: Date())
        #expect(try splicer(home).uninstall(from: outcome.text, previous: entry) == original)
    }

    @Test func withoutTheManifestUnchainingRebuildsTheOriginalArgv() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let installed = try splicer(home).install(into: "notify = ['X', 'a b']\n", previous: nil).text
        #expect(try splicer(home).uninstall(from: installed, previous: nil) == "notify = [\"X\", \"a b\"]\n")
    }

    @Test func rejectsANotifyThatIsNotAnArgv() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        #expect(throws: InstallError.self) { try splicer(home).install(into: "notify = \"say done\"\n", previous: nil) }
        #expect(throws: InstallError.self) { try splicer(home).install(into: "notify = [\n", previous: nil) }
    }

    @Test func aUserNotifyIsNeverTouchedByUninstall() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let text = "notify = [\"mine\"]\n"
        #expect(try splicer(home).uninstall(from: text, previous: nil) == text)
        #expect(!splicer(home).containsOurs(text))
    }
}

@Suite("Codex trust detection", .timeLimit(.minutes(1)))
struct CodexTrustTests {
    @Test func detectsTheTrustStepReadOnly() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.mkdir(".codex")
        let context = makeContext(home)
        let installer = CodexInstaller()
        let hooks = try installer.managedFiles(context)[1].splicer.install(into: Fixtures.codexHooks, previous: nil).text
        try home.write(".codex/hooks.json", hooks)
        try home.write(".codex/config.toml", "model = \"o4\"\n")
        #expect(installer.needsTrustStep(context))

        let ours = CodexTrust.ourHandlers(inHooksJSON: hooks)
        #expect(ours.count == 6)
        #expect(ours.first { $0.event == "Stop" } == CodexTrust.Handler(event: "Stop", group: 1, handler: 0))
        // Approvals as Codex writes them: one table per handler (the user's Stop group is index 0).
        var config = "model = \"o4\"\n"
        for handler in ours {
            config += "\n[hooks.state.\"\(home.paths.codexHome.path(percentEncoded: false))hooks.json:\(handler.event):\(handler.group):\(handler.handler)\"]\ntrusted_hash = \"sha256:abc\"\n"
        }
        try home.write(".codex/config.toml", config)
        #expect(!installer.needsTrustStep(context))

        // An approval of another group (e.g. the user's own Stop hook) does not count for ours.
        let partial = config.replacingOccurrences(of: ":Stop:1:0", with: ":Stop:0:0")
        try home.write(".codex/config.toml", partial)
        #expect(installer.needsTrustStep(context))
    }

    @Test func inlineStateTablesAndSnakeCaseEventsAreRecognized() {
        let handlers = [CodexTrust.Handler(event: "UserPromptSubmit", group: 0, handler: 0)]
        let config = "[hooks.state]\n\"user:user_prompt_submit:0:0\" = { trusted_hash = \"h\" }\n"
        #expect(CodexTrust.isTrusted(handlers, stateKeys: CodexTrust.trustedStateKeys(inConfig: config)))
        #expect(!CodexTrust.isTrusted(handlers, stateKeys: CodexTrust.trustedStateKeys(inConfig: "[hooks.state.\"user:Stop:0:0\"]\ntrusted_hash = \"h\"\n")))
        // A header without trusted_hash is not an approval.
        #expect(!CodexTrust.isTrusted(handlers, stateKeys: CodexTrust.trustedStateKeys(inConfig: "[hooks.state.\"user:UserPromptSubmit:0:0\"]\n")))
    }
}

@Suite("Aider (YAML)", .timeLimit(.minutes(1)))
struct AiderSpliceTests {
    private func splicer(_ home: TestHome) -> AiderConfigSplicer {
        AiderConfigSplicer(path: ".aider.conf.yml", hook: HookCommand(hookPath: home.hookPath))
    }

    private func command(in text: String) throws -> String? {
        let document = try YAMLDocument(text)
        guard let entry = document.entries(named: AiderConfigSplicer.commandKey).first,
              case .string(let value) = try document.scalar(of: entry) else { return nil }
        return value
    }

    @Test func chainsTheUserCommandAndRestoresItByteForByte() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let outcome = try splicer(home).install(into: Fixtures.aiderConfig, previous: nil)
        #expect(try command(in: outcome.text) == "\(home.hookPath) aider waiting --chain -- /bin/sh -c 'say '\\''Aider is ready'\\''' 2>/dev/null; exit 0")
        for fragment in ["# Aider config", "# Notifications", "auto-commits: false   # keep commits manual"] {
            #expect(outcome.text.contains(fragment))
        }
        let originals = try #require(AiderConfigSplicer.Originals.decode(outcome.chainedOriginal))
        #expect(originals.command == "notifications-command: \"say 'Aider is ready'\"")
        #expect(originals.notifications == "notifications: true")

        let entry = InstallManifestEntry(agent: .aider, file: "a", kind: .spliced, sha256Before: "x", sha256After: "y",
                                         chainedOriginal: outcome.chainedOriginal, installedAt: Date())
        #expect(try splicer(home).uninstall(from: outcome.text, previous: entry) == Fixtures.aiderConfig)
        #expect(try splicer(home).install(into: outcome.text, previous: entry) == outcome)
        // The chained command can be recovered from our own argv (manifest lost).
        #expect(AiderConfigSplicer.userCommand(chainedIn: try #require(try command(in: outcome.text))) == "say 'Aider is ready'")
    }

    @Test func notificationsWithoutACommandChainAidersOwnAlert() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let original = "notifications: yes\n"
        let outcome = try splicer(home).install(into: original, previous: nil)
        #expect(outcome.text == "notifications: yes\nnotifications-command: " + YAMLDocument.doubleQuoted(
            "\(home.hookPath) aider waiting --chain -- \(AiderConfigSplicer.defaultNotificationChain) 2>/dev/null; exit 0") + "\n")
        let entry = InstallManifestEntry(agent: .aider, file: "a", kind: .spliced, sha256Before: "x", sha256After: "y",
                                         chainedOriginal: outcome.chainedOriginal, installedAt: Date())
        #expect(try splicer(home).uninstall(from: outcome.text, previous: entry) == original)
    }

    @Test func turnsNotificationsOnAndBackOff() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let original = "model: gpt-5\nnotifications: false # quiet\n"
        let outcome = try splicer(home).install(into: original, previous: nil)
        #expect(outcome.text == "model: gpt-5\nnotifications: true\nnotifications-command: \"\(home.hookPath) aider waiting 2>/dev/null; exit 0\"\n")
        let entry = InstallManifestEntry(agent: .aider, file: "a", kind: .spliced, sha256Before: "x", sha256After: "y",
                                         chainedOriginal: outcome.chainedOriginal, installedAt: Date())
        #expect(try splicer(home).uninstall(from: outcome.text, previous: entry) == original)
    }

    @Test func createsTheFileAndHandlesAMissingTrailingNewline() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let created = try splicer(home).install(into: nil, previous: nil)
        #expect(created.text == "notifications: true\nnotifications-command: \"\(home.hookPath) aider waiting 2>/dev/null; exit 0\"\n")
        let ours = InstallManifestEntry(agent: .aider, file: "a", kind: .spliced, sha256Before: nil, sha256After: "y",
                                        chainedOriginal: created.chainedOriginal, installedAt: Date())
        #expect(try splicer(home).uninstall(from: created.text, previous: ours) == nil)

        let noNewline = "model: sonnet"
        let installed = try splicer(home).install(into: noNewline, previous: nil)
        let entry = InstallManifestEntry(agent: .aider, file: "a", kind: .spliced, sha256Before: "x", sha256After: "y",
                                         chainedOriginal: installed.chainedOriginal, installedAt: Date())
        #expect(try splicer(home).uninstall(from: installed.text, previous: entry) == noNewline)
    }

    @Test func blockScalarCommandsAreChainedAndRestored() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let original = "notifications: true\nnotifications-command: >-\n  terminal-notifier\n  -message done\nmodel: x\n"
        let outcome = try splicer(home).install(into: original, previous: nil)
        #expect(try command(in: outcome.text)?.contains("--chain -- /bin/sh -c 'terminal-notifier -message done'") == true)
        #expect(outcome.text.hasSuffix("model: x\n"))
        let entry = InstallManifestEntry(agent: .aider, file: "a", kind: .spliced, sha256Before: "x", sha256After: "y",
                                         chainedOriginal: outcome.chainedOriginal, installedAt: Date())
        #expect(try splicer(home).uninstall(from: outcome.text, previous: entry) == original)
    }

    @Test func refusesYAMLItDoesNotUnderstand() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        #expect(throws: InstallError.self) { try splicer(home).install(into: "- a\n- b\n", previous: nil) }
        #expect(throws: InstallError.self) { try splicer(home).install(into: "a: 1\n---\nb: 2\n", previous: nil) }
        #expect(throws: InstallError.self) { try splicer(home).install(into: "notifications-command:\n  - x\n", previous: nil) }
        #expect(throws: InstallError.self) { try splicer(home).install(into: "notifications: true\nnotifications: false\n", previous: nil) }
    }

    @Test func decodesYAMLScalars() throws {
        let doc = try YAMLDocument("a: \"x\\ty \\u00e9\"\nb: 'it''s'\nc: plain # c\nd: ~\ne: |\n  one\n  two\n\"quoted key\": 1\n")
        func value(_ key: String) throws -> YAMLDocument.Scalar { try doc.scalar(of: doc.entries(named: key)[0]) }
        #expect(try value("a") == .string("x\ty é"))
        #expect(try value("b") == .string("it's"))
        #expect(try value("c") == .string("plain"))
        #expect(try value("d") == .null)
        #expect(try value("e") == .string("one\ntwo\n"))
        #expect(doc.entries(named: "quoted key").count == 1)
    }
}

@Suite("Unified diff", .timeLimit(.minutes(1)))
struct UnifiedDiffTests {
    @Test func insertionHunkWithContext() {
        let old = (1...10).map { "line \($0)\n" }.joined()
        let new = old.replacingOccurrences(of: "line 5\n", with: "line 5\nadded\n")
        let diff = UnifiedDiff.make(old: old, new: new, label: "~/x.json")
        #expect(diff == "--- ~/x.json\n+++ ~/x.json\n@@ -3,6 +3,7 @@\n line 3\n line 4\n line 5\n+added\n line 6\n line 7\n line 8\n")
    }

    @Test func createDeleteAndMissingNewline() {
        #expect(UnifiedDiff.make(old: nil, new: "a\nb\n", label: "f") == "--- /dev/null\n+++ f\n@@ -0,0 +1,2 @@\n+a\n+b\n")
        #expect(UnifiedDiff.make(old: "a\n", new: nil, label: "f") == "--- f\n+++ /dev/null\n@@ -1 +0,0 @@\n-a\n")
        #expect(UnifiedDiff.make(old: "a", new: "a\n", label: "f") == "--- f\n+++ f\n@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+a\n")
        #expect(UnifiedDiff.make(old: "same", new: "same", label: "f") == "")
    }

    @Test func separateHunksAndMinimalScript() {
        let old = (1...30).map { "l\($0)\n" }.joined()
        let new = old.replacingOccurrences(of: "l3\n", with: "L3\n").replacingOccurrences(of: "l25\n", with: "")
        let diff = UnifiedDiff.make(old: old, new: new, label: "f")
        #expect(diff.components(separatedBy: "\n@@").count == 3)
        #expect(diff.contains("-l3\n+L3\n"))
        #expect(diff.contains("-l25\n"))
        let a = UnifiedDiff.lines("a\nb\nc\nd\n")
        let b = UnifiedDiff.lines("a\nx\nc\nd\ny\n")
        let ops = UnifiedDiff.editScript(a, b)
        #expect(ops.filter { if case .equal = $0 { false } else { true } }.count == 3)
    }
}

@Suite("Splice edge cases", .timeLimit(.minutes(1)))
struct SpliceEdgeCaseTests {
    private func gemini(_ home: TestHome) -> any ConfigSplicer {
        GeminiInstaller().managedFiles(makeContext(home))[0].splicer
    }

    @Test(arguments: [
        "{\"hooks\": {}}",
        "{\n  \"hooks\": {}\n}\n",
        "{\n  \"hooks\": {\n  }\n}\n",
        "{\"theme\":\"x\",\"hooks\":{\"AfterAgent\":[]}}",
        "{\n  \"ui\": { \"title\": \"Zürich ✓ \\u00e9 \\\"q\\\" \\/ 😀\" },\n  /* keep */ \"hooks\": { // inline\n    \"SessionStart\": [ ]\n  }\n}",
        "{\n    \"a\": [1, 2, 3],\n    \"b\": { \"c\": null, \"d\": -1.5e3, \"e\": true }\n}",
    ])
    func roundTripsUnusualContainers(_ original: String) async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let splicer = gemini(home)
        let installed = try splicer.install(into: original, previous: nil).text
        try splicer.validate(installed)
        #expect(splicer.containsOurs(installed))
        #expect(try handlerCommands(installed, containerKeys: ["hooks"]).filter { $0.contains(KakurenekoID.ownershipMarker) }.count == 5)
        #expect(try splicer.install(into: installed, previous: nil).text == installed)

        // Text-only removal (no manifest): nothing of ours is left and every user value survives; hook containers
        // that end up empty are dropped (brief §3.7.4), even when the user had them empty before.
        let surgical = try #require(try splicer.uninstall(from: installed, previous: nil))
        #expect(!surgical.contains(KakurenekoID.ownershipMarker))
        try splicer.validate(surgical)
        #expect(Self.withoutEmptyHookContainers(try JSONSyntax.parse(surgical, dialect: .jsonc).value)
            == Self.withoutEmptyHookContainers(try JSONSyntax.parse(original, dialect: .jsonc).value))

        // Through the manager (backup + manifest) an untouched file comes back byte for byte.
        try home.deployFakeHelper()
        try home.write(".gemini/settings.json", original)
        let manager = home.manager()
        _ = try await manager.install(.gemini)
        _ = try await manager.uninstall(.gemini)
        #expect(home.read(".gemini/settings.json") == original)
    }

    /// `value` without empty `hooks` objects and empty event arrays inside them.
    static func withoutEmptyHookContainers(_ value: JSONValue) -> JSONValue {
        guard case .object(var root) = value, case .object(var hooks)? = root["hooks"] else { return value }
        hooks = hooks.filter { $0.value != .array([]) }
        root["hooks"] = hooks.isEmpty ? nil : .object(hooks)
        return .object(root)
    }

    @Test func unicodeAndEscapesSurviveByteForByte() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let original = "{\n  \"name\": \"Café \\u00e9 \\ud83d\\ude00 😀\",\n  \"path\": \"C:\\\\x\\/y\"\n}\n"
        let splicer = gemini(home)
        let installed = try splicer.install(into: original, previous: nil).text
        #expect(installed.hasPrefix("{\n  \"name\": \"Café \\u00e9 \\ud83d\\ude00 😀\",\n  \"path\": \"C:\\\\x\\/y\",\n"))
        let restored = try #require(try splicer.uninstall(from: installed, previous: nil))
        #expect(Array(restored.utf8) == Array(original.utf8))
    }

    @Test func aHookPathWithSpacesIsQuotedButKeepsTheMarker() throws {
        let command = HookCommand(hookPath: "/Users/John O'Hara/.kakureneko/bin/kakureneko-hook")
        let shell = command.shell(.gemini, "Stop")
        #expect(shell == "'/Users/John O'\\''Hara/.kakureneko/bin/kakureneko-hook' gemini Stop 2>/dev/null; exit 0")
        #expect(shell.contains(KakurenekoID.ownershipMarker))
        #expect(HookCommand(hookPath: "/Users/me/.kakureneko/bin/kakureneko-hook").shell(.cursor, "stop")
            == "/Users/me/.kakureneko/bin/kakureneko-hook cursor stop 2>/dev/null; exit 0")
        #expect(ShellQuote.quoteIfNeeded("") == "''")
    }

    @Test func reinstallKeepsAMixedGroupsUserHandlers() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        // The user moved their own handler into our group (or another tool merged groups).
        let mixed = """
        {
          "hooks": {
            "AfterAgent": [
              { "hooks": [
                { "type": "command", "command": "~/bin/mine.sh" },
                { "type": "command", "command": "/Users/old/.kakureneko/bin/kakureneko-hook gemini AfterAgent 2>/dev/null; exit 0" }
              ] }
            ]
          }
        }
        """
        let installed = try gemini(home).install(into: mixed, previous: nil).text
        let commands = try handlerCommands(installed, containerKeys: ["hooks"])
        #expect(commands.contains("~/bin/mine.sh"))
        #expect(!installed.contains("/Users/old/"))
        #expect(commands.filter { $0.contains(KakurenekoID.ownershipMarker) }.count == 5)
    }

    @Test func codexNotifyNeverTouchesHooksStateOrOtherTables() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let splicer = CodexNotifySplicer(path: "config.toml", hookPath: home.hookPath)
        let original = """
        model = "o4"
        hooks.state."user:Stop:0:0".trusted_hash = "sha256:aa"   # dotted at the root

        [tui]
        notify = ["not", "the", "root", "key"]

        [hooks.state."user:SessionStart:0:0"]
        trusted_hash = "sha256:bb"

        """
        let outcome = try splicer.install(into: original, previous: nil)
        #expect(outcome.chainedOriginal == nil)
        let document = try TOMLDocument(outcome.text)
        let state = document.resolvedKeyValues.filter { $0.path.starts(with: ["hooks", "state"]) }
        #expect(state.count == 2)
        #expect(outcome.text.contains("[tui]\nnotify = [\"not\", \"the\", \"root\", \"key\"]\n"))
        #expect(outcome.text.contains("\n[hooks.state.\"user:SessionStart:0:0\"]\ntrusted_hash = \"sha256:bb\"\n"))
        #expect(outcome.text.hasPrefix("model = \"o4\"\nhooks.state.\"user:Stop:0:0\".trusted_hash = \"sha256:aa\"   # dotted at the root\nnotify = ["))
        #expect(try splicer.uninstall(from: outcome.text, previous: nil) == original)
    }

    @Test func crlfTOMLAndYAMLKeepTheirLineEndings() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let toml = "model = \"o4\"\r\nnotify = [\"say\", \"hi\"]\r\n\r\n[tui]\r\nx = 1\r\n"
        let codex = CodexNotifySplicer(path: "config.toml", hookPath: home.hookPath)
        let chained = try codex.install(into: toml, previous: nil)
        #expect(chained.text == "model = \"o4\"\r\nnotify = [\"\(home.hookPath)\", \"codex\", \"notify\", \"--chain\", \"--\", \"say\", \"hi\"]\r\n\r\n[tui]\r\nx = 1\r\n")
        let entry = InstallManifestEntry(agent: .codex, file: "c", kind: .spliced, sha256Before: "x", sha256After: "y",
                                         chainedOriginal: chained.chainedOriginal, installedAt: Date())
        #expect(try codex.uninstall(from: chained.text, previous: entry) == toml)
        let plain = "model = \"o4\"\r\n[tui]\r\n"
        let inserted = try codex.install(into: plain, previous: nil).text
        #expect(inserted == "model = \"o4\"\r\nnotify = [\"\(home.hookPath)\", \"codex\", \"notify\"]\r\n[tui]\r\n")

        let yaml = "# aider\r\nmodel: sonnet\r\n"
        let aider = AiderConfigSplicer(path: ".aider.conf.yml", hook: HookCommand(hookPath: home.hookPath))
        let installed = try aider.install(into: yaml, previous: nil)
        #expect(installed.text == "# aider\r\nmodel: sonnet\r\nnotifications: true\r\nnotifications-command: \"\(home.hookPath) aider waiting 2>/dev/null; exit 0\"\r\n")
        let aiderEntry = InstallManifestEntry(agent: .aider, file: "a", kind: .spliced, sha256Before: "x", sha256After: "y",
                                              chainedOriginal: installed.chainedOriginal, installedAt: Date())
        #expect(try aider.uninstall(from: installed.text, previous: aiderEntry) == yaml)
    }

    @Test func yamlWithADocumentStartMarkerAndQuotedKeys() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let aider = AiderConfigSplicer(path: ".aider.conf.yml", hook: HookCommand(hookPath: home.hookPath))
        let original = "---\n\"notifications\": on\nnotifications-command: 'terminal-notifier -message ''done'''\nmap:\n  key: value\n"
        let installed = try aider.install(into: original, previous: nil)
        #expect(installed.text.hasPrefix("---\n\"notifications\": on\nnotifications-command: \"\(home.hookPath) aider waiting --chain -- /bin/sh -c "))
        #expect(installed.text.hasSuffix("map:\n  key: value\n"))
        let document = try YAMLDocument(installed.text)
        let entry = try #require(document.entries(named: AiderConfigSplicer.commandKey).first)
        guard case .string(let command) = try document.scalar(of: entry) else {
            Issue.record("not a string")
            return
        }
        #expect(AiderConfigSplicer.userCommand(chainedIn: command) == "terminal-notifier -message 'done'")
        let manifest = InstallManifestEntry(agent: .aider, file: "a", kind: .spliced, sha256Before: "x", sha256After: "y",
                                            chainedOriginal: installed.chainedOriginal, installedAt: Date())
        #expect(try aider.uninstall(from: installed.text, previous: manifest) == original)
    }

    @Test func agyReplacesAStaleKeyOfOursAndKeepsOtherHookNames() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let splicer = AgyInstaller().managedFiles(makeContext(home))[0].splicer
        let stale = "{\n  \"my-guard\": { \"PreToolUse\": [] },\n  \"kakureneko\": { \"Stop\": [ { \"type\": \"command\", \"command\": \"/old/.kakureneko/bin/kakureneko-hook agy Stop\", \"timeout\": 9 } ] }\n}\n"
        let installed = try splicer.install(into: stale, previous: nil).text
        let editor = try JSONEditor(text: installed, dialect: .jsonc, path: "hooks.json")
        #expect(editor.root.members?.map(\.key) == ["my-guard", "kakureneko"])
        let stop = try #require(editor.node(at: ["kakureneko", "Stop"])?.elements)
        #expect(stop.count == 1)
        #expect(stop.first?.member("command")?.value.stringValue == "\(home.hookPath) agy Stop 2>/dev/null; exit 0")
        #expect(stop.first?.member("timeout")?.value.value == .number(5))
        let removed = try #require(try splicer.uninstall(from: installed, previous: nil))
        #expect(removed == "{\n  \"my-guard\": { \"PreToolUse\": [] }\n}\n")
    }

    @Test func diffsApplyBackToTheNewText() throws {
        let old = (0..<3000).map { "line \($0)\n" }.joined()
        // Scattered edits: a minimal script.
        let few = old.replacingOccurrences(of: "line 10\n", with: "LINE 10\n")
            .replacingOccurrences(of: "line 2000\n", with: "")
            .replacingOccurrences(of: "line 2999\n", with: "line 2999\nappended")
        let fewDiff = UnifiedDiff.make(old: old, new: few, label: "big")
        #expect(fewDiff.split(separator: "\n").filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count == 2)
        #expect(try Self.apply(fewDiff, to: old) == few)
        // Every other line changed: past the trace budget the middle is replaced as one block (still correct).
        let many = (0..<3000).map { $0 % 2 == 0 ? "LINE \($0)\n" : "line \($0)\n" }.joined()
        #expect(try Self.apply(UnifiedDiff.make(old: old, new: many, label: "big"), to: old) == many)
        // Create and delete.
        #expect(try Self.apply(UnifiedDiff.make(old: nil, new: "a\nb", label: "f"), to: "") == "a\nb")
        #expect(try Self.apply(UnifiedDiff.make(old: "a\nb\n", new: nil, label: "f"), to: "a\nb\n") == "")
        // An installer edit.
        let home = try TestHome()
        defer { home.cleanup() }
        let installed = try gemini(home).install(into: Fixtures.geminiSettings, previous: nil).text
        #expect(try Self.apply(UnifiedDiff.make(old: Fixtures.geminiSettings, new: installed, label: "s"), to: Fixtures.geminiSettings) == installed)
    }

    struct PatchError: Error {}

    /// Applies a unified diff made by `UnifiedDiff` (LF line endings) to `old`.
    static func apply(_ diff: String, to old: String) throws -> String {
        let oldLines = UnifiedDiff.lines(old).map(String.init)
        var out: [String] = []
        var index = 0
        var lines = diff.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var i = 2
        while i < lines.count {
            let header = lines[i].split(separator: " ")
            guard header.count >= 3, header[0] == "@@" else { throw PatchError() }
            let spec = header[1].dropFirst().split(separator: ",").compactMap { Int($0) }
            let start = spec[0]
            let count = spec.count > 1 ? spec[1] : 1
            let copyUpTo = count == 0 ? start : start - 1
            while index < copyUpTo { out.append(oldLines[index]); index += 1 }
            i += 1
            var last: Character?
            while i < lines.count, !lines[i].hasPrefix("@@ ") {
                let line = lines[i]
                i += 1
                if line.hasPrefix("\\") {
                    if last == "+" || last == " " { out[out.count - 1].removeLast() }
                    continue
                }
                guard let kind = line.first else { throw PatchError() }
                switch kind {
                case " ":
                    guard oldLines[index].hasPrefix(String(line.dropFirst())) else { throw PatchError() }
                    out.append(oldLines[index])
                    index += 1
                case "-":
                    guard oldLines[index].hasPrefix(String(line.dropFirst())) else { throw PatchError() }
                    index += 1
                case "+":
                    out.append(String(line.dropFirst()) + "\n")
                default:
                    throw PatchError()
                }
                last = kind
            }
        }
        while index < oldLines.count { out.append(oldLines[index]); index += 1 }
        return out.joined()
    }
}
