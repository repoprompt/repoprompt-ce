import Combine
import RepoPromptAIContracts
import RepoPromptSettingsCore
import SwiftUI

struct AgentRepromptPill: View {
    let props: AgentRepromptPillProps
    let viewModel: AgentModeViewModel
    let canRepromptDraft: Bool
    let setEnabled: (Bool) -> Void
    let openSettings: () -> Void
    @Environment(\.windowIsPresentationVisible) private var windowIsPresentationVisible
    @ObservedObject private var shortcutDisplay = GlobalKeyboardShortcutsCoordinator.shared.bindingDisplay

    private var rewriteKey: String {
        shortcutDisplay.localLabel(for: .repromptDraft)
    }

    /// Model availability loads asynchronously after the pill snapshot is first built.
    /// Rebuild the snapshot when it changes so first use does not stay on "Choose a model".
    private var availableModelChanges: AnyPublisher<[AIModel], Never> {
        viewModel.promptManager?.$availableModels.dropFirst().eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()
    }

    var body: some View {
        HStack(spacing: 4) {
            AgentIconTogglePill(systemImage: "wand.and.sparkles", isOn: props.isOn, isBusy: props.isPreparing) {
                if props.isOn { setEnabled(false) }
                else if props.isAvailable { setEnabled(true) }
                else { openSettings() }
            }
            if !props.isAvailable { modelChooser }
        }
        .hoverTooltip(props.unavailableReason ?? helpText, .top)
        .accessibilityLabel("Re-prompt")
        .accessibilityValue(props.isOn ? "On" : "Off")
        .contextMenu {
            if windowIsPresentationVisible {
                let models = viewModel.repromptMenuModels()
                Button("Re-prompt This Draft", action: repromptCurrentDraft)
                    .disabled(!canRepromptDraft || models.resolved == nil || props.isPreparing)
                ForEach(props.dataDisclosure, id: \.self) { Text($0) }
                Divider()
                AgentRepromptModelPicker(
                    selection: Binding(get: { viewModel.repromptModelSelectionRaw() }, set: { viewModel.setRepromptModelRaw($0) }),
                    availableModels: models.configured,
                    resolvedModel: models.resolved
                )
                if !viewModel.repromptModelSelectionRaw().isEmpty {
                    Button("Use automatic default") { viewModel.useAutomaticRepromptModel() }
                }
                Picker("Mode", selection: Binding(get: { viewModel.repromptMode }, set: { viewModel.setRepromptMode($0) })) {
                    ForEach(AgentRepromptMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Include recent chat context", isOn: Binding(get: { viewModel.repromptIncludesRecentChat }, set: { viewModel.setRepromptIncludesRecentChat($0) }))
                Button("Agent Models Settings", action: openSettings)
            }
        }
        .onAppear { viewModel.ui.statusPills.update(viewModel.makeStatusPillsSnapshot()) }
        .onReceive(availableModelChanges) { _ in
            // @Published emits in willSet. Resolve after the new model list is stored.
            Task { @MainActor in
                await Task.yield()
                viewModel.ui.statusPills.update(viewModel.makeStatusPillsSnapshot())
            }
        }
    }

    /// One click to a concrete model. Explicit choices are never replaced automatically.
    private var modelChooser: some View {
        Menu {
            if windowIsPresentationVisible {
                let models = viewModel.configuredRepromptModels()
                if models.isEmpty { Text("No supported model is connected") }
                ForEach(models, id: \.rawValue) { model in
                    Button(model.displayName) { viewModel.setRepromptModelRaw(model.rawValue) }
                }
                if !viewModel.repromptModelSelectionRaw().isEmpty {
                    Divider()
                    Button("Use automatic default") { viewModel.useAutomaticRepromptModel() }
                }
                Divider()
                Button("Agent Models Settings…", action: openSettings)
            }
        } label: {
            Text("Choose model").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Choose Re-prompt model")
    }

    private var helpText: String {
        let toggle = props.isOn ? "Turn off Re-prompt on Send." : "Turn on Re-prompt on Send."
        let manual = rewriteKey.isEmpty ? "Use Re-prompt This Draft from the menu." : "\(rewriteKey) rewrites this draft once."
        let details = props.dataDisclosure.joined(separator: " ")
        return "\(toggle) \(manual) \(details)"
    }

    private func repromptCurrentDraft() {
        guard canRepromptDraft, let tabID = viewModel.currentTabID, let session = viewModel.sessions[tabID],
              let target = viewModel.makeComposerSubmitTarget(tabID: tabID, session: session) else { return }
        _ = viewModel.requestComposerRepromptAgain(target: target, text: session.draftText)
    }
}
