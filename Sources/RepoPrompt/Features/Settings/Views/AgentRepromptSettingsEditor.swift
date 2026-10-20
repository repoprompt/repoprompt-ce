import RepoPromptSettingsCore
import SwiftUI

struct AgentRepromptSettingsEditor: View {
    @ObservedObject var viewModel: AgentModelsSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Re-prompt guidance").font(.callout.weight(.medium))
            Text("The primary Oracle turns each eligible local message into a balanced task brief. You review and approve every result. It may consult Oracle or Context Builder for repository context. These settings apply to the selected global/workspace scope; they do not enable Re-prompt.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Gather repository context", selection: $viewModel.repromptContextPolicyDraft) {
                Text("Automatic").tag(AgentRepromptContextPolicy.automatic)
                Text("Never").tag(AgentRepromptContextPolicy.never)
            }
            .pickerStyle(.segmented)
            TextEditor(text: $viewModel.repromptGuidanceDraft)
                .font(.body).frame(height: 180).padding(6)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Re-prompt rewrite guidance")
            HStack {
                Button("Save") { viewModel.saveRepromptDraft() }
                    .disabled(viewModel.repromptDraftHasConflict || !viewModel.isRepromptDraftDirty || !viewModel.repromptGuidanceIsWithinLimit)
                Button("Restore Default") { viewModel.restoreDefaultRepromptGuidance() }
                    .disabled(viewModel.repromptDraftHasConflict)
                if viewModel.repromptDraftHasConflict {
                    Button("Reload Current Text") { viewModel.reloadRepromptDraft() }
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
            if viewModel.repromptDraftHasConflict {
                Text("Settings or scope changed. Reload before saving; this discards your draft.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !viewModel.repromptGuidanceIsWithinLimit {
                Text("Guidance must be at most 16 KiB. Nothing is truncated or saved.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }
}
