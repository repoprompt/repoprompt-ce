import SwiftUI

struct AgentRepromptPill: View {
    let props: AgentRepromptPillProps
    let setEnabled: (Bool, String?) -> Void
    let openSettings: () -> Void
    @State private var showingDisclosure = false
    @State private var disclosedProviderID: String?

    var body: some View {
        AgentIconTogglePill(systemImage: props.isOn && (!props.isAvailable || props.requiresDisclosure) ? "exclamationmark.bubble" : "text.badge.checkmark", isOn: props.isOn, isBusy: props.isPreparing) {
            if props.isOn {
                setEnabled(false, nil)
            } else if !props.isAvailable {
                openSettings()
            } else if props.requiresDisclosure {
                disclosedProviderID = props.providerID
                showingDisclosure = true
            } else {
                setEnabled(true, nil)
            }
        }
        .hoverTooltip(props.unavailableReason ?? "Re-prompt: review a balanced task brief before sending. Primary Oracle: \(props.modelDisplayName ?? "not selected").", .top)
        .accessibilityLabel("Re-prompt")
        .accessibilityValue(props.isOn ? "On" : "Off")
        .contextMenu { Button("Agent Models Settings", action: openSettings) }
        .alert("Enable Re-prompt?", isPresented: $showingDisclosure) {
            Button("Enable Re-prompt") { setEnabled(true, disclosedProviderID) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Re-prompt sends each eligible local message and your guidance to the primary Oracle (\(props.modelDisplayName ?? "not selected")) for a tool-less rewrite, without composer attachments or conversation history. Automatic context gathering also sends root names and selected file paths, and may consult the configured Oracle roster (primary plus additional Oracles) with selected file contents, tab prompt and git review context. Context Builder uses its own configured agent/provider and repository-reading tools. Consult chat/run history persists; results may be sent back to the primary Oracle to refine the brief. With Gather repository context: Never, no manifest or consult is sent. These providers may differ from your implementing agent and have their own retention terms: avoid secrets. You review and approve every result. Review edits are not sent back to the rewriter; enabled Router/Auto Effort services may judge the brief during review, even if you later cancel.")
        }
    }
}
