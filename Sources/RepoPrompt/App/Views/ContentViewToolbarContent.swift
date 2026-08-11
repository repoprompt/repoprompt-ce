import SwiftUI

// MARK: - Content View Toolbar Content

struct ContentViewToolbarContent: ToolbarContent {
    let windowState: WindowState
    let recommendationWizardViewModel: RecommendationWizardViewModel?
    let onCreateWorkspace: () -> Void
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

    private var presentation: ActiveWorkspaceToolbarPresentation {
        ActiveWorkspaceToolbarPresentation(
            activeWorkspace: workspaceManager.activeWorkspace,
            workspaceCount: workspaceManager.workspacesForMenu().count,
            instanceNumber: windowState.workspaceInstanceNumber,
            chatTitle: title
        )
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

                Text(presentation.workspaceTitle)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: fontPreset.scaledClamped(280, max: 340), alignment: .leading)
                    .accessibilityIdentifier("ActiveWorkspaceTitle")

                if presentation.showsDistinctChatTitle {
                    Divider()
                        .frame(height: fontPreset.scaledClamped(14, max: 18))

                    Text(presentation.chatTitle)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: fontPreset.scaledClamped(280, max: 340), alignment: .leading)
                        .accessibilityIdentifier("AgentChatTitle")
                }

                Image(systemName: "chevron.down")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityIdentifier("ActiveWorkspacePicker")
        }
        .buttonStyle(CustomButtonStyle(verticalPadding: 0, horizontalPadding: 10, height: 28))
        .hoverTooltip(presentation.workspaceTooltip, .bottom)
    }

    private func openManageWorkspaces() {
        NotificationCenter.default.post(
            name: .showManageWorkspacesTab,
            object: windowState,
            userInfo: ["windowID": windowState.windowID]
        )
    }
}

struct ActiveWorkspaceToolbarPresentation: Equatable {
    let workspaceTitle: String
    let chatTitle: String
    let workspaceTooltip: String

    var showsDistinctChatTitle: Bool {
        chatTitle != workspaceTitle
    }

    var accessibilityLabel: String {
        if showsDistinctChatTitle {
            return "Active workspace: \(workspaceTitle). Chat: \(chatTitle)"
        }
        return "Active workspace: \(workspaceTitle)"
    }

    init(
        activeWorkspace: WorkspaceModel?,
        workspaceCount: Int,
        instanceNumber: Int?,
        chatTitle: String
    ) {
        if let activeWorkspace, !activeWorkspace.isSystemWorkspace {
            if let instanceNumber, instanceNumber >= 2 {
                workspaceTitle = "\(activeWorkspace.name) (\(instanceNumber))"
            } else {
                workspaceTitle = activeWorkspace.name
            }
        } else {
            workspaceTitle = "No Workspace"
        }

        self.chatTitle = chatTitle
        workspaceTooltip = workspaceCount == 0 ? "No saved workspaces" : "Switch workspace"
    }
}
