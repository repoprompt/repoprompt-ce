import SwiftUI

// MARK: - Content View Toolbar Content

struct ContentViewToolbarContent: ToolbarContent {
    let windowState: WindowState
    let recommendationWizardViewModel: RecommendationWizardViewModel?
    let onCreateWorkspace: () -> Void
    @Binding var showRecommendationsPopover: Bool
    @Binding var showMCPServerPopover: Bool

    var body: some ToolbarContent {
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
            ) { title in
                ActiveWorkspaceToolbarPicker(
                    title: title,
                    windowState: windowState,
                    onCreateWorkspace: onCreateWorkspace
                )
            }
        }
    }
}

private struct ActiveWorkspaceToolbarPicker: View {
    let title: String
    @ObservedObject var windowState: WindowState
    @ObservedObject private var workspaceManager: WorkspaceManagerViewModel
    @ObservedObject private var fontScale = FontScaleManager.shared
    let onCreateWorkspace: () -> Void

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var workspaceTitle: String {
        guard let workspace = workspaceManager.activeWorkspace,
              !workspace.isSystemWorkspace
        else {
            return "No Workspace"
        }

        if let instanceNumber = windowState.workspaceInstanceNumber,
           instanceNumber >= 2
        {
            return "\(workspace.name) (\(instanceNumber))"
        }

        return workspace.name
    }

    private var workspaceTooltip: String {
        let workspaceCount = workspaceManager.workspacesForMenu().count
        if workspaceCount == 0 {
            return "No saved workspaces"
        }
        return "Switch workspace"
    }

    init(title: String, windowState: WindowState, onCreateWorkspace: @escaping () -> Void) {
        self.title = title
        self.windowState = windowState
        self.onCreateWorkspace = onCreateWorkspace
        _workspaceManager = ObservedObject(wrappedValue: windowState.workspaceManager)
    }

    var body: some View {
        WorkspacePickerMenu(
            workspaceManager: workspaceManager,
            onCreateWorkspace: onCreateWorkspace,
            onManageWorkspaces: openManageWorkspaces
        ) {
            HStack(spacing: fontPreset.scaledClamped(6, max: 8)) {
                Image(systemName: "folder")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))

                Text(title)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: fontPreset.scaledClamped(520, max: 620), alignment: .leading)
                    .accessibilityIdentifier("AgentChatTitle")

                Image(systemName: "chevron.down")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Active workspace: \(workspaceTitle)")
        }
        .buttonStyle(CustomButtonStyle(verticalPadding: 0, horizontalPadding: 10, height: 28))
        .hoverTooltip(workspaceTooltip, .bottom)
    }

    private func openManageWorkspaces() {
        NotificationCenter.default.post(
            name: .showManageWorkspacesTab,
            object: windowState,
            userInfo: ["windowID": windowState.windowID]
        )
    }
}
