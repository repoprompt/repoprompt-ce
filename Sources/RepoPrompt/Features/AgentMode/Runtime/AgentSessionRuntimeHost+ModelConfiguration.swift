import Foundation
import MCP
import RepoPromptAIContracts
import RepoPromptSettingsCore

extension AgentSessionRuntimeHost {
    /// Configure the exact admitted session without a presenter. The caller supplies its
    /// original authority fence so it is checked again after the provider transition.
    func configureMCPModel(
        for session: AgentTabSession,
        selection: AgentModelCatalog.NormalizedAgentSelection,
        reasoningEffortRaw: String?,
        parameters: [ACPModelParameterSelection],
        beforeCommit: (() async -> Void)? = nil,
        requireAdmission: () throws -> Void
    ) async throws {
        func requireProviderSwitchPermission() throws {
            let differs = selection.agent != session.selectedAgent || selection.modelRaw != session.selectedModelRaw
            if session.pendingHandoff.providerSwitchDelivery != nil, differs {
                throw MCPError.invalidParams(AgentSessionLinkSendFailure.providerHandoverNeedsReview.message)
            }
        }

        try requireAdmission()
        let previousAgent = session.selectedAgent
        if session.activeAgentSessionID != nil,
           selection.agent != previousAgent,
           !session.permitsMCPProviderSelection(selection.agent)
        {
            throw MCPError.invalidParams("This session is locked to \(previousAgent.displayName). Start a new session to change agents.")
        }
        try requireProviderSwitchPermission()
        try Self.validateMCPModelParameters(selectedAgent: selection.agent, selectedModelRaw: selection.modelRaw, parameters: parameters)
        if previousAgent != selection.agent {
            codexCoordinator.handleProviderSwitch(from: previousAgent, to: selection.agent, session: session)
            await claudeCoordinator.handleProviderIdentityTransition(session: session, from: previousAgent, to: selection.agent)
        }
        await beforeCommit?()
        try requireAdmission()
        try requireProviderSwitchPermission()
        session.selectedAgent = selection.agent
        session.selectedModelRaw = selection.modelRaw
        if selection.agent.usesClaudeNativeRuntime {
            // For native providers, an absent pin explicitly clears an inherited pin.
            session.selectedReasoningEffortRaw = reasoningEffortRaw
            session.selectedClaudeEffortRaw = reasoningEffortRaw
        } else if let reasoningEffortRaw {
            session.selectedReasoningEffortRaw = reasoningEffortRaw
        }
        if !parameters.isEmpty {
            session.storeMCPModelParameters(parameters)
        }
        if session.mcpControlContext != nil {
            session.permissionProfile = providerBindingService.permissionProfileForMCPActivation(
                isSubagent: true, provider: selection.agent.providerBindingID
            )
        }
        if !selection.agent.usesClaudeNativeRuntime {
            codexCoordinator.normalizeCodexSelectionForSession(session, preservingExplicitEffort: reasoningEffortRaw != nil)
        }
        // Remember only an explicit Codex effort that survived normalization.
        if let reasoningEffortRaw, session.selectedAgent == .codexExec,
           let requested = CodexReasoningEffort.parse(reasoningEffortRaw),
           let accepted = CodexReasoningEffort.parse(session.selectedReasoningEffortRaw), requested == accepted
        {
            CodexAgentToolPreferences.setLastUsedReasoningEffort(accepted, forModelRaw: session.selectedModelRaw)
            codexCoordinator.recordLastUsedReasoningEffort(accepted, forModelRaw: session.selectedModelRaw)
        }
    }

    static func validateMCPModelParameters(
        selectedAgent: AgentProviderKind, selectedModelRaw: String, parameters: [ACPModelParameterSelection]
    ) throws {
        guard !parameters.isEmpty else { return }
        guard let providerID = selectedAgent.acpProviderID else {
            throw MCPError.invalidParams("Model parameters are supported only for ACP providers; cannot apply them to \(selectedAgent.displayName).")
        }
        let selectedModel = ACPModelParameterIdentity.canonicalBaseModelRaw(selectedModelRaw, providerID: providerID)
        guard parameters.allSatisfy({
            $0.providerID == providerID
                && ACPModelParameterIdentity.canonicalBaseModelRaw($0.baseModelRaw, providerID: providerID) == selectedModel
        }) else {
            throw MCPError.invalidParams("Model parameters do not match the configured \(selectedAgent.displayName) base model.")
        }
    }
}

extension AgentTabSession {
    func permitsMCPProviderSelection(_ candidate: AgentProviderKind) -> Bool {
        if pendingHandoff.providerSwitchDelivery != nil { return candidate == selectedAgent }
        return !isProviderSelectionLocked || candidate == selectedAgent
            || (selectedAgent.usesClaudeNativeRuntime && candidate.usesClaudeNativeRuntime)
    }

    /// Only call after model parameter identity and inactivity were validated.
    @discardableResult
    func storeMCPModelParameters(_ selections: [ACPModelParameterSelection]) -> Bool {
        recordAcceptedACPModelParameterWrite(selections)
        let updated = ACPModelParameterSelection.normalized(acpModelParameterSelections + selections)
        guard updated != acpModelParameterSelections else { return false }
        acpModelParameterSelections = updated
        isDirty = true
        return true
    }
}
