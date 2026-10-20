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
            Text("Re-prompt sends each eligible local message and your guidance to the primary Oracle (\(props.modelDisplayName ?? "not selected"), \(disclosedProviderID ?? "unknown provider")). With automatic context gathering it also sends root names and selected file paths, and may consult Oracle or run Context Builder. With Never, it sends only text and guidance. This provider may differ from your agent and has its own retention terms: avoid secrets. Attachments and conversation history are excluded. You review and approve every result. Review edits are not sent back to the rewriter; enabled Router/Auto Effort services judge the approved brief and may begin judging during review, even if you later cancel.")
        }
    }
}
