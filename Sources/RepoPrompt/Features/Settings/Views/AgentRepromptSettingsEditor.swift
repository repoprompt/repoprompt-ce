import RepoPromptSettingsCore
import SwiftUI

struct AgentRepromptSettingsEditor: View {
    @ObservedObject var viewModel: AgentModelsSettingsViewModel
    @State private var showsGuidance = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Re-prompt").font(.callout.weight(.medium))
            Text("Re-prompt rewrites your message into a clearer brief before it's sent; press Return to send, ⌘Return to re-prompt again.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Model")
                AgentRepromptModelPicker(
                    selection: $viewModel.repromptModelDraft,
                    availableModels: viewModel.apiSettingsVM.availableModels.filter { AgentRepromptModelPolicy.supportsSideCall($0) && $0.canStream },
                    resolvedModel: viewModel.resolvedRepromptDraftModel
                )
            }
            Text("Defaults to a fast model from your connected Claude or ChatGPT subscription.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Effort: Low (Auto Effort decides when on)").font(.caption).foregroundStyle(.secondary)
            Picker("Mode", selection: $viewModel.repromptModeDraft) {
                ForEach(AgentRepromptMode.allCases, id: \.self) { mode in Text(mode.displayName).tag(mode) }
            }
            Toggle("Include recent chat context", isOn: $viewModel.repromptRecentChatDraft)
            DisclosureGroup("Rewrite guidance (advanced)", isExpanded: $showsGuidance) {
                TextEditor(text: $viewModel.repromptGuidanceDraft)
                    .font(.body).frame(height: 180).padding(6)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Re-prompt rewrite guidance")
                Button("Restore Default") { viewModel.restoreDefaultRepromptGuidance() }
                    .disabled(viewModel.repromptDraftHasConflict)
            }
            HStack {
                Button("Save") { viewModel.saveRepromptDraft() }
                    .disabled(viewModel.repromptDraftHasConflict || !viewModel.isRepromptDraftDirty || !viewModel.repromptGuidanceIsWithinLimit)
                if viewModel.repromptDraftHasConflict { Button("Reload Current Settings") { viewModel.reloadRepromptDraft() } }
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
