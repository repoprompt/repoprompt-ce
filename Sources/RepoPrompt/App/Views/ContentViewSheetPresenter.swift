import SwiftUI

// MARK: - Content View Sheet Presenter

struct ContentViewSheetPresenter: ViewModifier {
    @ObservedObject var viewModel: ContentViewModel
    @Binding var showWorkspaceSetup: Bool
    @Binding var showCreatePresetSheet: Bool
    @Binding var showMCPStatusSheet: Bool
    let recommendationWizardViewModel: RecommendationWizardViewModel?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showWorkspaceSetup) {
                WorkspaceSetupView(
                    onClose: { showWorkspaceSetup = false },
                    onWorkspaceCreated: { newWs in
                        Task {
                            await viewModel.workspaceManager.createAndActivateWorkspace(
                                name: newWs.name,
                                repoPaths: newWs.repoPaths
                            ) {
                                // Do any UI steps before switching
                                showWorkspaceSetup = false
                            }
                            // Auto-apply recommendations for the newly created workspace
                            // Use activeWorkspaceID since createAndActivateWorkspace generates a new UUID
                            if let wizardVM = recommendationWizardViewModel,
                               let actualWorkspaceID = viewModel.workspaceManager.activeWorkspaceID
                            {
                                wizardVM.autoApplyForNewWorkspace(workspaceID: actualWorkspaceID)
                            }
                        }
                    }
                )
                .environmentObject(viewModel.workspaceManager)
            }
            // Create-Preset naming sheet
            .sheet(isPresented: $showCreatePresetSheet) {
                if let ws = viewModel.workspaceManager.activeWorkspace {
                    PresetCreationSheet(workspace: ws)
                        .environmentObject(viewModel.workspaceManager)
                } else {
                    Text("No active workspace")
                        .padding()
                }
            }
            // MCP Status sheet
            .sheet(isPresented: $showMCPStatusSheet) {
                MCPStatusView(server: viewModel.state.mcpServer, windowID: viewModel.state.windowID)
            }
    }
}
