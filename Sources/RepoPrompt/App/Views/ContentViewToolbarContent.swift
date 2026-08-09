import SwiftUI

// MARK: - Content View Toolbar Content

struct ContentViewToolbarContent: ToolbarContent {
    let windowState: WindowState
    let recommendationWizardViewModel: RecommendationWizardViewModel?
    let isAgentModeActive: Bool
    @Binding var showRecommendationsPopover: Bool
    @Binding var showMCPServerPopover: Bool

    var body: some ToolbarContent {
        // Agent Mode context drawer button
        ToolbarItem(placement: .automatic) {
            if isAgentModeActive {
                Button {
                    windowState.agentModeViewModel.ui.contextDrawer.toggle()
                } label: {
                    Label("Compose", systemImage: "pencil")
                        .labelStyle(.titleAndIcon)
                }
                .hoverTooltip("Generate prompts from selected files")
            }
        }

        if #available(macOS 26.0, *) {
            agentChatTitleItem
                .sharedBackgroundVisibility(.hidden)
        } else {
            agentChatTitleItem
        }

        // Recommendation wizard button
        ToolbarItem(placement: .automatic) {
            if let wizardVM = recommendationWizardViewModel {
                RecommendationToolbarButtonView(
                    viewModel: wizardVM,
                    showPopover: $showRecommendationsPopover
                )
            }
        }

        // TOOLBAR POPOVER FIX: Pass bindings to prevent state loss during toolbar re-evaluation
        ToolbarItem(placement: .automatic) {
            MCPServerToggleView(windowState: windowState, showPopover: $showMCPServerPopover)
        }

        // Update pill (user-initiated Sparkle UI)
        ToolbarItem(placement: .automatic) {
            UpdateAvailableToolbarPill(sparkleManager: SparkleUpdaterManager.shared)
        }
    }

    @ToolbarContentBuilder
    private var agentChatTitleItem: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            AgentChatTitleClusterView(
                model: windowState.agentChatTitleCluster,
                menuSnapshot: { [weak windowState] in
                    windowState?.agentChatTitleClusterMenuSnapshot()
                },
                menuActions: windowState.agentChatTitleClusterMenuActions()
            )
        }
    }
}
