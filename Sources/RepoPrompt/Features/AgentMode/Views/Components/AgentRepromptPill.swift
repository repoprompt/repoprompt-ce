import SwiftUI

struct AgentRepromptPill: View {
    let props: AgentRepromptPillProps
    let viewModel: AgentModeViewModel
    let setEnabled: (Bool, String?) -> Void
    let openSettings: () -> Void
    @State private var showingDisclosure = false
    @State private var disclosedProviderID: String?

    var body: some View {
        AgentIconTogglePill(systemImage: "wand.and.sparkles", isOn: props.isOn, isBusy: props.isPreparing) {
            if props.isOn { setEnabled(false, nil) }
            else if !props.isAvailable { openSettings() }
            else if props.requiresDisclosure {
                disclosedProviderID = props.providerID
                showingDisclosure = true
            } else { setEnabled(true, nil) }
        }
        .hoverTooltip(props.unavailableReason ?? "Re-prompt: first Send prepares, next Send sends. Resolved model: \(props.modelDisplayName ?? "unavailable").", .top)
        .accessibilityLabel("Re-prompt")
        .accessibilityValue(props.isOn ? "On" : "Off")
        .contextMenu {
            AgentRepromptModelPicker(
                selection: Binding(get: { viewModel.repromptModelSelectionRaw() }, set: { viewModel.setRepromptModelRaw($0) }),
                availableModels: viewModel.configuredRepromptModels()
            )
            Toggle("Include recent chat context", isOn: Binding(get: { viewModel.repromptIncludesRecentChat }, set: { viewModel.setRepromptIncludesRecentChat($0) }))
            Text("Resolved: \(props.modelDisplayName ?? "unavailable")")
            Button("Agent Models Settings", action: openSettings)
        }
        .popover(isPresented: $showingDisclosure) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Enable Re-prompt?").font(.headline)
                Text("Each eligible local message, rewrite guidance and a bounded manifest of root names and selected file paths go to the resolved model (\(props.modelDisplayName ?? "unavailable")). If Include recent chat context is on, sessions with at least two completed turns also send bounded recent user messages and assistant final-reply excerpts. No tools, repository file contents, git context, composer attachments, tool output or thinking are sent. Clarification answers may be sent in one refinement. The current message always takes precedence over unverified history. This model may use a different provider or billing route from your agent; its retention terms apply. Avoid secrets. Nothing auto-sends: review/edit the composer, then press Send again. Enabled Router/Auto Effort services can judge the complete draft before you Send, even if you later undo it.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") { showingDisclosure = false }
                    Button("Enable Re-prompt") { setEnabled(true, disclosedProviderID)
                        showingDisclosure = false
                    }
                }
            }.padding().frame(width: 410)
        }
    }
}
