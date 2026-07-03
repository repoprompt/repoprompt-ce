import SwiftUI

// MARK: - Content Root Shell

struct ContentRootShellView: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var workspaceApprovalManager: WorkspaceApprovalManager
    @Binding var showWorkspaceSwitchOverlay: Bool
    @StateObject private var agentNavigationHUD = AgentNavigationHUDViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastAgentNavigationHUDCommand: (mode: AgentNavigationHUDMode, at: Date)?

    private var isBlockingOverlayVisible: Bool {
        showWorkspaceSwitchOverlay
            || (viewModel.state.mcpServer.pendingClientID != nil && viewModel.state.mcpServer.isApprovalOverlayVisible)
            || (workspaceApprovalManager.pendingRequest != nil && workspaceApprovalManager.isApprovalOverlayVisible)
    }

    var body: some View {
        ZStack {
            routedContent
                .blur(radius: showWorkspaceSwitchOverlay ? 6 : 0, opaque: false)
                .animation(.easeInOut(duration: 0.12), value: showWorkspaceSwitchOverlay)

            if agentNavigationHUD.isPresented {
                AgentNavigationHUDView(
                    viewModel: agentNavigationHUD,
                    windowState: viewModel.state
                )
                .transition(hudTransition)
                .zIndex(998)
            }

            if showWorkspaceSwitchOverlay {
                WorkspaceSwitchLoadingOverlay {
                    await viewModel.workspaceManager.cancelCurrentWorkspaceSwitchAndReturnToSystem()
                }
                .zIndex(999)
            }

            // MCP Client Approval Overlay
            if let clientID = viewModel.state.mcpServer.pendingClientID,
               viewModel.state.mcpServer.isApprovalOverlayVisible
            {
                MCPApprovalOverlayView(clientID: clientID)
                    .environmentObject(viewModel.state.mcpServer)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .zIndex(1000)
            }

            // Workspace Operation Approval Overlay
            if let request = workspaceApprovalManager.pendingRequest,
               workspaceApprovalManager.isApprovalOverlayVisible
            {
                WorkspaceApprovalOverlayView(
                    approvalManager: workspaceApprovalManager,
                    request: request
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(1001)
            }
        }
        .animation(hudAnimation, value: agentNavigationHUD.isPresented)
        .onReceive(NotificationCenter.default.publisher(for: .showAgentNavigationHUD)) { note in
            guard noteTargetsCurrentWindow(note) else { return }
            guard !isBlockingOverlayVisible else {
                animateHUD { agentNavigationHUD.dismiss() }
                return
            }
            let rawMode = note.userInfo?[AgentNavigationHUDNotificationUserInfoKey.mode] as? String
            let mode = rawMode.flatMap(AgentNavigationHUDMode.init(rawValue:)) ?? .currentWindow
            guard !isDuplicateAgentNavigationHUDCommand(mode) else { return }
            guard viewModel.rootRoute != .workspaceEntry || mode == .allAgents else {
                animateHUD { agentNavigationHUD.dismiss() }
                return
            }
            animateHUD {
                agentNavigationHUD.present(mode: mode, currentWindow: viewModel.state)
            }
        }
        .onChange(of: isBlockingOverlayVisible) { _, isVisible in
            if isVisible {
                animateHUD { agentNavigationHUD.dismiss() }
            }
        }
        .onChange(of: viewModel.state.promptManager.activeComposeTabID) { _, _ in
            if agentNavigationHUD.isPresented, !agentNavigationHUD.isRouting {
                animateHUD { agentNavigationHUD.dismiss() }
            }
        }
    }

    private var hudTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98))
    }

    private var hudAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.10) : .snappy(duration: 0.18, extraBounce: 0)
    }

    private func animateHUD(_ action: () -> Void) {
        withAnimation(hudAnimation) {
            action()
        }
    }

    /// SwiftUI menu commands and the app-focus-gated KeyboardShortcuts handler
    /// can both see the same physical ⌘K event. Coalesce same-mode repeats from
    /// a single keypress so the VM's deliberate toggle semantics don't open and
    /// immediately close the switcher.
    private func isDuplicateAgentNavigationHUDCommand(_ mode: AgentNavigationHUDMode) -> Bool {
        let now = Date()
        defer { lastAgentNavigationHUDCommand = (mode, now) }
        guard let lastAgentNavigationHUDCommand,
              lastAgentNavigationHUDCommand.mode == mode
        else { return false }
        return now.timeIntervalSince(lastAgentNavigationHUDCommand.at) < 0.20
    }

    private func noteTargetsCurrentWindow(_ note: Notification) -> Bool {
        if let id = note.userInfo?[AgentNavigationHUDNotificationUserInfoKey.windowID] as? Int {
            return id == viewModel.state.windowID
        }
        return true
    }

    @ViewBuilder
    private var routedContent: some View {
        if viewModel.rootRoute == .workspaceEntry {
            WorkspaceEntryRootView(
                workspaceManager: viewModel.workspaceManager,
                windowState: viewModel.state,
                tab: $viewModel.workspaceEntryTab,
                onboardingViewModel: viewModel.onboardingViewModel,
                onCreateOnboardingViewModelIfNeeded: { viewModel.ensureOnboardingViewModel() },
                onContinueToMain: {
                    viewModel.continueFromOnboarding()
                }
            )
        } else {
            AgentModeView(
                windowState: viewModel.state,
                agentModeVM: viewModel.state.agentModeViewModel,
                promptManager: viewModel.promptManager
            )
        }
    }
}
