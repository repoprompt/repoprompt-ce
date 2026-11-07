import Foundation
import RepoPromptAIContracts

@MainActor
enum AgentModeMCPPolicyInstaller {
    static let policyTTL: TimeInterval = 60
    static let policyReason = "agent-mode-run"

    static func additionalTools(for agent: AgentProviderKind) -> Set<String> {
        AgentModeMCPToolPolicy.grantedTools(forAgent: agent)
    }

    static func install(
        agent: AgentProviderKind,
        windowID: Int,
        tabID: UUID,
        runID: UUID,
        taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil,
        allowsAgentExternalControlTools: Bool = false,
        connectionPolicyInstaller: AgentModeViewModel.ConnectionPolicyInstaller
    ) async {
        guard let clientName = agent.mcpClientNameHint else { return }
        await connectionPolicyInstaller(
            clientName,
            windowID,
            AgentModeMCPToolPolicy.restrictedTools,
            true,
            policyReason,
            policyTTL,
            tabID,
            runID,
            additionalTools(for: agent),
            .agentModeRun,
            taskLabelKind,
            allowsAgentExternalControlTools,
            agent.requiresExpectedPIDOwnedAgentModeMCPRouting
        )
    }
}
