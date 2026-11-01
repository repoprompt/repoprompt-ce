import AppKit
import SwiftUI

/// Computer Use prerequisites shown under the Codex Computer Use toggle: what RepoPrompt can
/// verify (companion and runtime) with a re-check action, and links to the macOS privacy panes
/// whose grants belong to Codex Computer Use.
struct CodexComputerUseSetupStatusView: View {
    @State private var status: CodexComputerUseSetupStatus?
    @State private var isRechecking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status {
                checkRow(status.companion)
                checkRow(status.runtime)
            }

            Text(CodexComputerUseSetupStatus.permissionGuidance)
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                ForEach(CodexComputerUsePrivacyPane.allCases) { pane in
                    Button(pane.buttonTitle) { open(pane) }
                        .controlSize(.small)
                }
                Button(isRechecking ? "Checking…" : "Re-check") {
                    Task { await recheck() }
                }
                .controlSize(.small)
                .disabled(isRechecking)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(6)
        .task { await recheck() }
    }

    private func checkRow(_ check: CodexComputerUseSetupStatus.Check) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: iconName(for: check.state))
                .foregroundColor(color(for: check.state))
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(.footnote.weight(.medium))
                Text(check.detail)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func iconName(for state: CodexComputerUseSetupStatus.CheckState) -> String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .checking: "clock"
        case .needsAction: "exclamationmark.triangle.fill"
        }
    }

    private func color(for state: CodexComputerUseSetupStatus.CheckState) -> Color {
        switch state {
        case .ready: .green
        case .checking: .secondary
        case .needsAction: .orange
        }
    }

    @MainActor
    private func recheck() async {
        isRechecking = true
        defer { isRechecking = false }
        status = .evaluate(
            companionPath: CodexNativeSessionController.computerUseClientPath(),
            runtimeMessage: CodexComputerUseWorkflow.checkingRuntimeMessage
        )
        let runtimeMessage = await CodexComputerUseWorkflow.checkConfiguredRuntimeRequirement()
        status = .evaluate(
            companionPath: CodexNativeSessionController.computerUseClientPath(),
            runtimeMessage: runtimeMessage
        )
    }

    private func open(_ pane: CodexComputerUsePrivacyPane) {
        for url in pane.settingsURLs where NSWorkspace.shared.open(url) {
            return
        }
    }
}
