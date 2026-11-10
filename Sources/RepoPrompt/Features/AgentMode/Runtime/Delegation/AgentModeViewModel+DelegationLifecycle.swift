import Foundation

extension AgentModeViewModel {
    /// Delegation-scope `fork`: the ordinary Handoff/Fork transcript migration into a background tab,
    /// with no focus change and no oversight-link inheritance (a scope may not mint links to
    /// sessions outside it). Returns the new session ID.
    func delegationFork(
        sessionID: UUID, upToItemID: UUID?, isStillAuthorized: @escaping @MainActor () -> Bool
    ) async throws -> UUID {
        guard let source = try authoritativeLiveSession(for: sessionID) else {
            throw SessionAdminHostError.sessionUnavailable
        }
        guard let cutoff = upToItemID ?? source.items.last?.id else {
            throw SessionAdminHostError.invalid("The target session has no transcript to fork.")
        }
        let workspaceID = workspaceManager?.activeWorkspaceID
        let binding = source.currentRestorationBindingToken
        let destinationTabID = try await prepareHandoffToNewTab(
            upToItemID: cutoff,
            destinationAgent: source.selectedAgent,
            destinationModelRaw: source.selectedModelRaw,
            destinationReasoningEffortRaw: source.persistedReasoningEffortRaw,
            sourceTabID: source.tabID,
            activateDestination: false,
            inheritOversightLinks: false,
            missingImagePolicy: .strict,
            isStillAuthorized: { [weak self] in
                guard let self else { return false }
                return isStillAuthorized()
                    && workspaceManager?.activeWorkspaceID == workspaceID
                    && sessions[source.tabID] === source
                    && source.activeAgentSessionID == sessionID
                    && source.currentRestorationBindingToken == binding
            }
        )
        guard let forkedSessionID = sessions[destinationTabID]?.activeAgentSessionID else {
            throw SessionAdminHostError.invalid("The fork was created but its session did not bind.")
        }
        return forkedSessionID
    }
}
