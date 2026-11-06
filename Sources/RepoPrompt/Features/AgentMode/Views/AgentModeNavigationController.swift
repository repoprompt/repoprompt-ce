import SwiftUI

@MainActor
final class AgentModeNavigationController: ObservableObject {
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    @Published var preferredColumn: NavigationSplitViewColumn = .sidebar

    init(isSystemWorkspaceMode: Bool) {
        _ = isSystemWorkspaceMode
    }

    func onAppear(
        isSystem: Bool,
        windowState: WindowState,
        agentModeVM: AgentModeViewModel
    ) {
        agentModeVM.setAgentModeActive(true)
        applyWorkspaceMode(isSystem: isSystem, windowState: windowState, agentModeVM: agentModeVM)
    }

    func onDisappear(windowState: WindowState, agentModeVM: AgentModeViewModel) {
        agentModeVM.setAgentModeActive(false)
        windowState.setAgentTitlebarAccessoryVisible(false)
    }

    func onWorkspaceModeChanged(
        isSystem: Bool,
        windowState: WindowState,
        agentModeVM: AgentModeViewModel
    ) {
        applyWorkspaceMode(isSystem: isSystem, windowState: windowState, agentModeVM: agentModeVM)
    }

    private func applyWorkspaceMode(
        isSystem: Bool,
        windowState: WindowState,
        agentModeVM: AgentModeViewModel
    ) {
        // Keep sidebar visibility stable across onboarding / no-workspace transitions.
        // Those screens are full-screen, so we avoid mutating split-view state here.
        if isSystem {
            windowState.setAgentTitlebarAccessoryVisible(false)
            return
        }

        windowState.setAgentTitlebarAccessoryVisible(true) { [weak self, weak agentModeVM] in
            guard let agentModeVM else { return }
            self?.requestNewSession(agentModeVM: agentModeVM)
        }
    }

    /// Shared by the compose buttons in the sidebar's titlebar cluster and the titlebar accessory.
    func requestNewSession(agentModeVM: AgentModeViewModel) {
        Task { [weak agentModeVM] in
            guard let agentModeVM else { return }
            let activeTabID = await MainActor.run { agentModeVM.currentTabID }
            if await MainActor.run(body: { agentModeVM.shouldSwallowNewSessionClick(for: activeTabID) }) {
                return
            }
            await agentModeVM.createAndActivateSessionTab()
        }
    }
}
