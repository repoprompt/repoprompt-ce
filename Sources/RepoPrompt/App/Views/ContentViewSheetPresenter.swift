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
                            showWorkspaceSetup = false
                            let result = await viewModel.workspaceManager.requestWorkspaceSwitch(to: newWs, saveState: false)

                            if result.didSwitch, let wizardVM = recommendationWizardViewModel {
                                wizardVM.autoApplyForNewWorkspace(workspaceID: newWs.id)
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
                MCPStatusView(server: viewModel.state.mcpServer)
            }
    }
}
