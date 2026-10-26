import Foundation

@MainActor
final class ChatWorkspaceSwitchSessionProvider: WorkspaceSwitchSessionProvider {
    private weak var workspaceManager: WorkspaceManagerViewModel?
    private weak var oracleViewModel: OracleViewModel?

    init(workspaceManager: WorkspaceManagerViewModel, oracleViewModel: OracleViewModel) {
        self.workspaceManager = workspaceManager
        self.oracleViewModel = oracleViewModel
    }

    func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
        let count = activeChatCount()
        guard count > 0 else { return [] }
        return [WorkspaceSwitchSessionItem(
            id: "chat",
            count: count,
            singularLabel: "active chat session",
            pluralLabel: "active chat sessions"
        )]
    }

    func cancelSwitchSessions() async {
        await cancelSwitchSessions(for: nil)
    }

    func cancelSwitchSessions(for deletionToken: WorkspaceDeletionCancellationToken?) async {
        guard let workspaceManager, let oracleViewModel else { return }
        guard activeChatCount() > 0 else { return }
        let expectedWorkspaceID = workspaceManager.activeWorkspaceID

        await oracleViewModel.cancelAllActiveSessionStreams()
        guard deletionToken?.isActive ?? true,
              workspaceManager.activeWorkspaceID == expectedWorkspaceID
        else { return }
        workspaceManager.setActiveChatTabs([])
        workspaceManager.isChatBusy = false
    }

    private func activeChatCount() -> Int {
        guard let workspaceManager else { return 0 }
        return max(workspaceManager.tabsWithActiveChat.count, workspaceManager.isChatBusy ? 1 : 0)
    }
}

@MainActor
final class ContextBuilderWorkspaceSwitchSessionProvider: WorkspaceSwitchSessionProvider {
    private weak var contextBuilderAgentViewModel: ContextBuilderAgentViewModel?

    init(contextBuilderAgentViewModel: ContextBuilderAgentViewModel) {
        self.contextBuilderAgentViewModel = contextBuilderAgentViewModel
    }

    func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
        let count = activeContextBuilderCount()
        guard count > 0 else { return [] }
        return [WorkspaceSwitchSessionItem(
            id: "context-builder",
            count: count,
            singularLabel: "active context builder session",
            pluralLabel: "active context builder sessions"
        )]
    }

    func cancelSwitchSessions() async {
        await contextBuilderAgentViewModel?.cancelAllActiveRuns()
    }

    private func activeContextBuilderCount() -> Int {
        let contextBuilderTabs = contextBuilderAgentViewModel?.tabsWithActiveContextBuilderRun ?? []
        let planTabs = contextBuilderAgentViewModel?.tabsWithActivePlanGeneration ?? []
        return contextBuilderTabs.union(planTabs).count
    }
}

@MainActor
final class AgentModeWorkspaceSwitchSessionProvider: WorkspaceSwitchSessionProvider {
    private weak var agentModeViewModel: AgentModeViewModel?

    init(agentModeViewModel: AgentModeViewModel) {
        self.agentModeViewModel = agentModeViewModel
    }

    func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
        let count = activeAgentCount()
        guard count > 0 else { return [] }
        return [WorkspaceSwitchSessionItem(
            id: "agent-mode",
            count: count,
            singularLabel: "active agent session",
            pluralLabel: "active agent sessions"
        )]
    }

    func cancelSwitchSessions() async {
        await cancelSwitchSessions(for: nil)
    }

    func cancelSwitchSessions(for deletionToken: WorkspaceDeletionCancellationToken?) async {
        guard let agentModeViewModel else { return }
        let expectedWorkspaceID = agentModeViewModel.workspaceManager?.activeWorkspaceID
        let activeTabs = agentModeViewModel.tabsWithActiveAgentRun
        for tabID in activeTabs {
            await agentModeViewModel.cancelAgentRun(tabID: tabID, completion: .terminalPublished)
            guard deletionToken?.isActive ?? true,
                  agentModeViewModel.workspaceManager?.activeWorkspaceID == expectedWorkspaceID
            else { return }
        }
    }

    private func activeAgentCount() -> Int {
        agentModeViewModel?.tabsWithActiveAgentRun.count ?? 0
    }
}
