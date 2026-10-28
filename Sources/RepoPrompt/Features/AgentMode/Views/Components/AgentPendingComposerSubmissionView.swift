import SwiftUI

/// An admitted send is visible immediately, while routing/worktree preparation runs.
/// This is deliberately not a transcript item: it has not reached the agent yet.
struct AgentPendingComposerSubmissionView: View {
    @ObservedObject var composerUI: AgentComposerUIStore
    let tabID: UUID?
    let onCancel: (UUID) -> Void

    private var pending: AgentComposerPendingSubmission? {
        composerUI.pendingSubmissions.values.first { $0.destinationTabID == tabID }
    }

    var body: some View {
        if let pending {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(composerUI.props.isRoutingFreshTask ? "Sending… Choosing model and effort" : "Sending… Preparing agent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel ⎋") { onCancel(pending.id) }
                        .keyboardShortcut(.escape, modifiers: [])
                        .buttonStyle(.borderless)
                }
                if !pending.text.isEmpty {
                    ScrollView {
                        Text(pending.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .accessibilityIdentifier("agentComposer.pendingSend")
        }
    }
}
