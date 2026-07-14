import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var viewModel: ContentViewModel
    @StateObject private var workspaceApprovalManager = WorkspaceApprovalManager.shared

    @State private var showWorkspaceSetup = false

    /// Sheet for naming a brand-new preset
    @State private var showCreatePresetSheet = false

    // Stable state for toolbar popovers so they survive toolbar re-evaluation
    @State private var showMCPServerPopover = false
    @State private var showMCPStatusSheet = false
    @State private var showRecommendationsPopover = false
    @State private var showWorkspaceSwitchOverlay = false

    /// Recommendation wizard view model (lazy initialized)
    @State private var recommendationWizardViewModel: RecommendationWizardViewModel?

    /// Initialize with a single WindowState,
    /// then build a ContentViewModel from it.
    init(windowState: WindowState) {
        _viewModel = StateObject(wrappedValue: ContentViewModel(state: windowState))
    }

    var body: some View {
        ContentRootShellView(
            viewModel: viewModel,
            workspaceApprovalManager: workspaceApprovalManager,
            showWorkspaceSwitchOverlay: $showWorkspaceSwitchOverlay
        )
        .toolbar {
            ContentViewToolbarContent(
                windowState: viewModel.state,
                recommendationWizardViewModel: recommendationWizardViewModel,
                isAgentModeActive: viewModel.rootRoute == .main,
                showRecommendationsPopover: $showRecommendationsPopover,
                showMCPServerPopover: $showMCPServerPopover
            )
        }
        .onAppear {
            showWorkspaceSwitchOverlay = viewModel.workspaceManager.isWorkspaceSwitchOverlayVisible

            // Evaluate initial route (workspace entry vs main) and auto-onboarding
            viewModel.evaluateInitialRouteIfNeeded()

            // Initialize recommendation wizard view model
            if recommendationWizardViewModel == nil {
                let engine = AutoRecommendationEngine(
                    settingsStore: GlobalSettingsStore.shared,
                    profileSettingsManager: GlobalSettingsStore.shared,
                    apiSettingsViewModel: viewModel.apiSettingsViewModel
                )
                recommendationWizardViewModel = RecommendationWizardViewModel(
                    engine: engine,
                    settingsStore: GlobalSettingsStore.shared,
                    workspaceManager: viewModel.workspaceManager,
                    windowID: viewModel.state.windowID
                )
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .workspaceSwitchOverlayDidChange,
                object: viewModel.workspaceManager
            )
        ) { notification in
            if let isVisible = notification.userInfo?["isVisible"] as? Bool {
                showWorkspaceSwitchOverlay = isVisible
            }
        }
        .workspaceSwitchConfirmation(manager: viewModel.workspaceManager)
        .modifier(ContentViewSheetPresenter(
            viewModel: viewModel,
            showWorkspaceSetup: $showWorkspaceSetup,
            showCreatePresetSheet: $showCreatePresetSheet,
            showMCPStatusSheet: $showMCPStatusSheet,
            recommendationWizardViewModel: recommendationWizardViewModel
        ))
        .modifier(ContentViewNotificationHandler(
            windowState: viewModel.state,
            onShowWizard: { viewModel.presentSetupGuide() },
            onShowMCPPopover: { showMCPServerPopover = true },
            onShowCreatePresetSheet: { showCreatePresetSheet = true },
            onShowMCPStatusSheet: { showMCPStatusSheet = true },
            onShowRecommendationWizard: {
                recommendationWizardViewModel?.refresh(navigation: .resetToIntro)
                showRecommendationsPopover = true
            },
            onAppWillRestartForUpdate: { closeAllSheets() }
        ))
        // Close all sheets when a connection approval request comes in
        .onChange(of: viewModel.state.mcpServer.isApprovalOverlayVisible) { _, isVisible in
            if isVisible {
                closeAllSheets()
            }
        }
        // Close all sheets when a workspace approval request comes in
        .onChange(of: workspaceApprovalManager.isApprovalOverlayVisible) { _, isVisible in
            if isVisible {
                closeAllSheets()
            }
        }
        .environmentObject(viewModel.workspaceManager)
    }

    private func closeAllSheets() {
        withAnimation {
            showWorkspaceSetup = false
            showCreatePresetSheet = false
            showMCPStatusSheet = false
        }
    }
}
