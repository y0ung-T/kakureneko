// Agent integrations (onboarding step 3 and the Agents settings pane): only agents whose config dir exists,
// "last event seen" proof of life, Codex trust-step guidance, and a diff preview sheet before every install,
// removal or repair (`previewIntegration(agent, operation:)`; nothing is written until the user confirms).

import KakurenekoKit
import SwiftUI

/// What the sheet shows.
struct IntegrationSheetState: Identifiable {
    let id = UUID()
    var plan: InstallPlan
    var result: InstallResult?
}

struct IntegrationListView: View {
    enum Context {
        case onboarding
        case settings
    }

    let model: AppModel
    let context: Context
    @State private var sheet: IntegrationSheetState?

    var body: some View {
        let dismissed = context == .onboarding ? model.snapshot.settings.integrations.dismissedAgents : []
        let offered = IntegrationRowModel.offered(model.snapshot.integrations, dismissed: dismissed)
        let now = Date()
        VStack(alignment: .leading, spacing: 10) {
            if offered.isEmpty {
                Banner(symbolName: "puzzlepiece.extension", tone: .neutral, title: "No supported agent found on this Mac",
                       message: "Kakureneko only offers agents whose settings folder already exists. Agents without hooks are still detected from their activity.")
            }
            ForEach(offered) { status in
                IntegrationRow(model: model, row: IntegrationRowModel.make(status, now: now), context: context) { operation in
                    Task { await preview(status.agent, operation: operation) }
                }
            }
            if context == .settings {
                let missing = IntegrationRowModel.notDetected(model.snapshot.integrations)
                if !missing.isEmpty {
                    Text("Not found on this Mac: " + missing.map(\.agent.displayName).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .sheet(item: $sheet) { state in
            IntegrationPreviewSheet(model: model, state: state, onApply: { plan in
                Task { await apply(plan) }
            }, onClose: { sheet = nil })
        }
    }

    private func preview(_ agent: AgentID, operation: IntegrationRowModel.Operation) async {
        if let plan = await model.previewIntegration(agent, operation: operation.planOperation) {
            sheet = IntegrationSheetState(plan: plan)
        }
    }

    private func apply(_ plan: InstallPlan) async {
        if let result = await model.applyIntegration(plan) {
            sheet?.result = result
        } else {
            sheet = nil
        }
    }
}

private struct IntegrationRow: View {
    let model: AppModel
    let row: IntegrationRowModel
    let context: IntegrationListView.Context
    let onOperation: (IntegrationRowModel.Operation) -> Void

    var body: some View {
        let busy = model.isRunning(.integration(row.id))
        HStack(alignment: .top, spacing: 10) {
            StatusDot(tone: row.tone).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name).font(.body.weight(.medium))
                Text(row.statusText).font(.caption).foregroundStyle(row.tone == .muted ? Palette.ink2 : row.tone.color)
                ForEach(row.guidance, id: \.self) { line in
                    Label(line, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if busy {
                ProgressView().controlSize(.small)
            }
            ForEach(row.operations, id: \.self) { operation in
                Button(operation.title) { onOperation(operation) }
                    .buttonStyle(operation == .install ? .primary : .secondary)
                    .disabled(busy)
            }
            if context == .onboarding && row.operations == [.install] {
                Button("Not now") { Task { await model.dismissIntegration(row.id) } }
                    .buttonStyle(.accentLink)
                    .font(.callout)
                    .disabled(busy)
            }
        }
        .padding(10)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}

/// The diff preview: every file change with its unified diff, the CLI commands, warnings; then the result.
struct IntegrationPreviewSheet: View {
    let model: AppModel
    let state: IntegrationSheetState
    let onApply: (InstallPlan) -> Void
    let onClose: () -> Void

    var body: some View {
        let plan = state.plan
        let busy = model.isRunning(.integration(plan.agent))
        VStack(alignment: .leading, spacing: 12) {
            Text(InstallPlanText.title(plan)).font(.title3.weight(.semibold))
            if model.isDryRun {
                Badge(text: "Dry run · nothing will be written", tone: .attention)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if plan.isEmpty {
                        Text("Nothing needs to change.").foregroundStyle(Palette.ink2)
                    }
                    ForEach(Array(plan.changes.enumerated()), id: \.offset) { _, change in
                        FileChangeView(change: change)
                    }
                    if !plan.commands.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Commands").font(.headline)
                            ForEach(Array(plan.commands.enumerated()), id: \.offset) { _, command in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(command.displayString)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                    Text(command.purpose).font(.caption).foregroundStyle(Palette.ink2)
                                }
                            }
                        }
                    }
                    ForEach(plan.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Tone.attention.color)
                    }
                    if let note = plan.followUpNote {
                        Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(Palette.ink2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let result = state.result {
                Banner(symbolName: "checkmark.circle.fill", tone: .success, title: "Done",
                       message: InstallPlanText.resultSummary(result))
            }
            HStack {
                Text("Backups go to ~/.kakureneko/backups before anything is changed.")
                    .font(.caption)
                    .foregroundStyle(Palette.ink2)
                Spacer()
                if state.result == nil {
                    Button("Cancel", role: .cancel, action: onClose)
                        .keyboardShortcut(.cancelAction)
                    ProgressButton(title: InstallPlanText.confirmTitle(plan.operation), isRunning: busy, prominent: true) {
                        onApply(plan)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.isEmpty)
                } else {
                    Button("Close", action: onClose)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 380, idealHeight: 520)
    }
}

private struct FileChangeView: View {
    let change: FileChange

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Badge(text: InstallPlanText.changeKind(change.kind),
                      tone: change.kind == .delete ? .critical : (change.kind == .create ? .success : .working))
                Text(change.path)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(DiffLine.parse(change.unifiedDiff)) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(color(line.kind))
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(line.kind))
                    }
                }
                .textSelection(.enabled)
            }
            .padding(.vertical, 4)
            .background(Palette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func color(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: .green
        case .removed: .red
        case .hunk: .purple
        case .fileHeader: .secondary
        case .context: .primary
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: Tone.success.solid.opacity(0.12)
        case .removed: Tone.critical.solid.opacity(0.12)
        default: Color.clear
        }
    }
}
