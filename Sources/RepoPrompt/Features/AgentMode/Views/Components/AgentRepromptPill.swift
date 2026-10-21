import RepoPromptSettingsCore
import SwiftUI

struct AgentRepromptPill: View {
    let props: AgentRepromptPillProps
    @ObservedObject var store: AgentRepromptUIStore
    let viewModel: AgentModeViewModel
    let setEnabled: (Bool, String?) -> Void
    let openSettings: () -> Void
    @State private var showingDisclosure = false
    @State private var disclosedProviderID: String?
    @State private var oneShotRequestID: UUID?

    var body: some View {
        HStack(spacing: 4) {
            AgentIconTogglePill(systemImage: "wand.and.sparkles", isOn: props.isOn, isBusy: props.isPreparing) {
                if props.isOn { setEnabled(false, nil) }
                else if !props.isAvailable { openSettings() }
                else if props.requiresDisclosure {
                    disclosedProviderID = props.providerID
                    oneShotRequestID = nil
                    showingDisclosure = true
                } else { setEnabled(true, nil) }
            }
            if !props.isAvailable { Button("Choose a model", action: openSettings).buttonStyle(.plain).font(.caption) }
        }
        .hoverTooltip(props.unavailableReason ?? "Re-prompt · \(viewModel.repromptMode.displayName). Return prepares or sends; ⌘Return prepares again. Model: \(props.modelDisplayName ?? "unavailable").", .top)
        .accessibilityLabel("Re-prompt")
        .accessibilityValue(props.isOn ? "On" : "Off")
        .contextMenu {
            AgentRepromptModelPicker(
                selection: Binding(get: { viewModel.repromptModelSelectionRaw() }, set: { viewModel.setRepromptModelRaw($0) }),
                availableModels: viewModel.configuredRepromptModels(),
                resolvedModel: viewModel.resolvedRepromptModel()
            )
            Picker("Mode", selection: Binding(get: { viewModel.repromptMode }, set: { viewModel.setRepromptMode($0) })) {
                ForEach(AgentRepromptMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Toggle("Include recent chat context", isOn: Binding(get: { viewModel.repromptIncludesRecentChat }, set: { viewModel.setRepromptIncludesRecentChat($0) }))
            Text("Resolved: \(props.modelDisplayName ?? "unavailable")")
            Button("Agent Models Settings", action: openSettings)
        }
        .onReceive(store.$oneShotDisclosureRequest) { request in
            guard let request else { return }
            oneShotRequestID = request.id
            disclosedProviderID = viewModel.repromptPillProps().providerID
            showingDisclosure = true
        }
        .popover(isPresented: $showingDisclosure) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Enable Re-prompt?").font(.headline)
                Text("Each eligible local message, rewrite guidance and a bounded manifest of root names and selected file paths go to the resolved model (\(props.modelDisplayName ?? "unavailable")). If Include recent chat context is on, sessions with at least two completed turns also send bounded recent user messages and assistant final-reply excerpts. No tools, repository file contents, git context, composer attachments, tool output or thinking are sent. Clarification answers may be sent in one refinement. The current message always takes precedence over unverified history. This model may use a different provider or billing route from your agent; its retention terms apply. Avoid secrets. Review before sending is the default. Send automatically mode dispatches the completed rewrite unless clarification questions or slash-leading text require review. Cmd+Return always prepares for review, including when the pill is off. Enabled Router/Auto Effort services can judge the complete draft before you Send, even if you later undo it.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") {
                        if store.oneShotDisclosureRequest?.id == oneShotRequestID { store.oneShotDisclosureRequest = nil }
                        showingDisclosure = false
                    }
                    Button(oneShotRequestID == nil ? "Enable Re-prompt" : "Re-prompt once") {
                        if let oneShotRequestID, let disclosedProviderID {
                            viewModel.confirmOneShotReprompt(requestID: oneShotRequestID, providerID: disclosedProviderID)
                        } else { setEnabled(true, disclosedProviderID) }
                        showingDisclosure = false
                    }
                }
            }.padding().frame(width: 410)
        }
    }
}
