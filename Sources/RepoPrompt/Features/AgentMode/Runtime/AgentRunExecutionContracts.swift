import Foundation
import RepoPromptACPProviders
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts

/// Host-injected provider and routing capabilities. The runtime owns their vocabulary;
/// presentation composition supplies implementations without becoming their type owner.
/// These are in-process closures, not persisted type identities or a second provider registry.
enum AgentRunExecutionContracts {
    typealias HeadlessProviderFactory = (_ agent: AgentProviderKind, _ modelString: String?) -> HeadlessAgentProvider
    typealias ACPProviderFactory = (_ agent: AgentProviderKind, _ modelString: String?) async throws -> (any ACPAgentProvider)?
    typealias ACPControllerFactory = (_ provider: any ACPAgentProvider, _ runRequest: ACPRunRequest) throws -> ACPAgentSessionController
    typealias ConnectionPolicyInstaller = (
        _ clientName: String,
        _ windowID: Int,
        _ restrictedTools: Set<String>,
        _ oneShot: Bool,
        _ reason: String?,
        _ ttl: TimeInterval,
        _ tabID: UUID?,
        _ runID: UUID?,
        _ additionalTools: Set<String>?,
        _ purpose: MCPRunPurpose,
        _ taskLabelKind: AgentTaskLabelKind?,
        _ allowsAgentExternalControlTools: Bool,
        _ requiresExpectedAgentPID: Bool
    ) async -> Void
    typealias MCPServerEnabler = () async -> Bool
}

/// Value input captured by the session host for one ACP dispatch. Request assembly cannot
/// read a different tab or a later mutation of the session while provider work suspends.
/// This is not admission authority: binding, attempt and cancellation fences remain with
/// the existing run service/runners. Steering captures a fresh value for each dispatch.
struct AgentACPRunInput {
    let agent: AgentProviderKind
    let selectedModelRaw: String
    let providerSessionID: String?
    let taskLabelKind: AgentTaskLabelKind?
    let modelParameterSelections: [ACPModelParameterSelection]

    @MainActor
    func makeRequest(
        workspacePath: String?,
        attachments: [AgentFileAttachment],
        runtimePermission: AgentProviderRuntimePermissionBinding
    ) -> ACPRunRequest? {
        guard let providerID = agent.acpProviderID else { return nil }
        return ACPRunRequest(
            agentKind: agent,
            modelString: selectedModelRaw == AgentModel.defaultModel.rawValue ? nil : selectedModelRaw,
            workspacePath: workspacePath,
            resumeSessionID: providerSessionID,
            attachments: attachments,
            taskLabelKind: taskLabelKind,
            sessionModeID: runtimePermission.acpSessionModeID,
            autoApproveAllToolPermissions: runtimePermission.autoApproveAllACPToolPermissions,
            launchPermissionMode: runtimePermission.acpLaunchPermissionMode,
            modelParameterSelections: ACPModelParameterResolver.effectiveSelections(
                providerID: providerID,
                selectedModelRaw: selectedModelRaw,
                persistedSelections: modelParameterSelections
            )
        )
    }
}
