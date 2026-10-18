@testable import KakurenekoApp
import KakurenekoKit
import Foundation
import Testing

@Suite("Integration formatting (pure)", .timeLimit(.minutes(1)))
struct IntegrationFormattingTests {
    @Test func installedWithEventsIsProvenWorking() {
        let status = IntegrationStatus(agent: .claude, supported: true, configDirExists: true, installed: true,
                                       lastEventSeen: fixedNow.addingTimeInterval(-20))
        let row = IntegrationRowModel.make(status, now: fixedNow)
        #expect(row.name == "Claude Code")
        #expect(row.statusText == "Working · last event 20s ago")
        #expect(row.tone == .success)
        #expect(row.operations == [.uninstall])
        #expect(row.guidance.isEmpty)
    }

    @Test func installedWithoutEventsWaits() {
        let row = IntegrationRowModel.make(IntegrationStatus(agent: .gemini, supported: true, configDirExists: true, installed: true),
                                           now: fixedNow)
        #expect(row.statusText == "Installed · waiting for the first event")
        #expect(row.tone == .attention)
    }

    @Test func codexShowsTheTrustStepOnlyOnceInstalled() {
        let installed = IntegrationRowModel.make(
            IntegrationStatus(agent: .codex, supported: true, configDirExists: true, installed: true, needsTrustStep: true,
                              notes: ["Restart Codex to load the hooks."]),
            now: fixedNow)
        #expect(installed.guidance == [IntegrationRowModel.codexTrustGuidance, "Restart Codex to load the hooks."])
        #expect(installed.guidance[0].contains("/hooks"))
        let notInstalled = IntegrationRowModel.make(
            IntegrationStatus(agent: .codex, supported: true, configDirExists: true, needsTrustStep: true), now: fixedNow)
        #expect(notInstalled.guidance.isEmpty)
        #expect(notInstalled.operations == [.install])
        #expect(notInstalled.statusText == "Not installed")
    }

    @Test func needsRepairOffersRepairFirst() {
        let row = IntegrationRowModel.make(
            IntegrationStatus(agent: .cursor, supported: true, configDirExists: true, installed: true, needsRepair: true),
            now: fixedNow)
        #expect(row.operations == [.repair, .uninstall])
        #expect(row.tone == .critical)
        #expect(row.statusText.hasPrefix("Needs repair"))
    }

    @Test func unsupportedOffersNothing() {
        let row = IntegrationRowModel.make(IntegrationStatus(agent: .zed, supported: false, configDirExists: true), now: fixedNow)
        #expect(row.operations.isEmpty)
    }

    @Test func operationsMapToPlanOperations() {
        #expect(IntegrationRowModel.Operation.allCases.map(\.planOperation) == [.install, .uninstall, .repair])
        #expect(IntegrationRowModel.Operation.allCases.map(\.title) == ["Install…", "Remove…", "Repair…"])
    }

    /// Phantom-install rule: only supported agents whose config dir exists, in installer order, minus dismissed ones.
    @Test func offeredFiltersAndOrders() {
        let statuses = [
            IntegrationStatus(agent: .aider, supported: true, configDirExists: true),
            IntegrationStatus(agent: .gemini, supported: true, configDirExists: false),
            IntegrationStatus(agent: .codex, supported: true, configDirExists: true),
            IntegrationStatus(agent: .zed, supported: false, configDirExists: true),
            IntegrationStatus(agent: .claude, supported: true, configDirExists: true),
            IntegrationStatus(agent: .opencode, supported: true, configDirExists: true),
        ]
        #expect(IntegrationRowModel.offered(statuses).map(\.agent) == [.claude, .codex, .opencode, .aider])
        #expect(IntegrationRowModel.offered(statuses, dismissed: [.codex, .aider]).map(\.agent) == [.claude, .opencode])
        #expect(IntegrationRowModel.notDetected(statuses).map(\.agent) == [.gemini])
    }

    @Test func diffLinesAreClassified() {
        let diff = "--- a/settings.json\n+++ b/settings.json\n@@ -1,2 +1,3 @@\n {\n+  \"hooks\": {},\n-  \"x\": 1\n}\n"
        let lines = DiffLine.parse(diff)
        #expect(lines.map(\.kind) == [.fileHeader, .fileHeader, .hunk, .context, .added, .removed, .context])
        #expect(lines.map(\.id) == Array(0..<7))
        #expect(lines[4].text == "+  \"hooks\": {},")
        #expect(DiffLine.parse("").isEmpty)
    }

    @Test func planTexts() {
        #expect(InstallPlanText.title(InstallPlan(agent: .codex, operation: .uninstall)) == "Remove the Kakureneko hook from Codex")
        #expect(InstallPlanText.title(InstallPlan(agent: .claude, operation: .install)) == "Install the Kakureneko hook for Claude Code")
        #expect(InstallPlanText.title(InstallPlan(agent: .claude, operation: .repair)) == "Repair the Kakureneko hook for Claude Code")
        #expect(InstallPlanText.confirmTitle(.install) == "Install")
        #expect(InstallPlanText.confirmTitle(.uninstall) == "Remove")
        #expect(InstallPlanText.confirmTitle(.repair) == "Repair")
        #expect(InstallPlanText.changeKind(.create) == "New file")
        #expect(InstallPlanText.changeKind(.modify) == "Modified")
        #expect(InstallPlanText.changeKind(.delete) == "Deleted")
    }

    @Test func resultSummaries() {
        let status = IntegrationStatus(agent: .codex, supported: true, configDirExists: true, installed: true)
        let plan = InstallPlan(agent: .codex, operation: .install, followUpNote: "Approve the hooks with /hooks in Codex.")
        let real = InstallResult(plan: plan, backups: ["a.bak", "b.bak"], messages: ["Hooks enabled."], status: status)
        #expect(InstallPlanText.resultSummary(real)
            == "Installed for Codex. 2 backups saved. Hooks enabled. Approve the hooks with /hooks in Codex.")
        let dry = InstallResult(plan: InstallPlan(agent: .codex, operation: .uninstall), backups: ["a.bak"], dryRun: true, status: status)
        #expect(InstallPlanText.resultSummary(dry) == "Dry run · nothing was written. 1 backup saved.")
        let repaired = InstallResult(plan: InstallPlan(agent: .gemini, operation: .repair), status: status)
        #expect(InstallPlanText.resultSummary(repaired) == "Repaired for Gemini CLI.")
    }
}
