import Foundation
import RepoPromptDomainRuntime

extension AgentModeViewModel {
    /// Workspace-qualified projection lookup; command admission uses the runtime writer instead.
    func agentSessionLinkModelIdentity(
        workspaceID: UUID, tabID: UUID, sessionID: UUID
    ) -> AgentSessionLifecycleAuthority.Identity? {
        guard let session = sessions[tabID], session.activeAgentSessionID == sessionID,
              let tab = workspaceManager?.modelRoutingTab(workspaceID: workspaceID, tabID: tabID),
              tab.activeAgentSessionID == sessionID else { return nil }
        return AgentSessionLifecycleAuthority.Identity(
            workspaceID: workspaceID, tabID: tabID, sessionID: sessionID,
            persistentBindingGeneration: session.persistentSessionBindingIdentity?.generation,
            bindingTransitionGeneration: session.bindingTransitionGeneration
        )
    }

    func agentSessionLinkModelCandidate(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentSessionLinkEndpointCandidate? {
        linkExecutionRuntime.agentSessionLinkModelCandidate(for: endpoint)
    }

    /// Optional projection only. The writer has already committed the session configuration.
    func publishSessionLinkModelConfiguration(_ session: TabSession, selection: AgentModelCatalogRuntime.Selection) {
        guard sessions[session.tabID] === session, session.tabID == currentTabID else { return }
        let restoring = isRestoringState
        isRestoringState = true
        defer { isRestoringState = restoring }
        selectedModelRaw = session.selectedModelRaw
        selectedReasoningEffortRaw = session.selectedReasoningEffortRaw
        // Permission/tool chrome refreshes through the normal binding path. Do not resolve
        // parameter/worktree/catalogue state here or mutate persisted parameter pins.
        var props = ui.composer.props
        props.selectedModelRaw = session.selectedModelRaw
        props.selectedModelDisplayName = selection.option.displayName
        props.selectedReasoningEffortRaw = session.selectedReasoningEffortRaw
        props.selectedReasoningEffortDisplayName = selectedReasoningEffortDisplayName
        props.acpModelParameterControls = []
        ui.composer.update(props)
    }
}
