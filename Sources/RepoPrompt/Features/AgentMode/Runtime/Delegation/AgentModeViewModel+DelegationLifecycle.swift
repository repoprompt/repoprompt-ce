import Foundation

extension AgentModeViewModel {
    /// Delegation-scope `set_effort`: the same narrow per-session commit `set_model` uses (session
    /// selection, active-tab composer mirror, scheduled save), validated against the provider's own
    /// advertised efforts for the session's current model. Never changes effort mid-turn.
    func delegationSetReasoningEffort(
        sessionID: UUID,
        effort: String,
        isStillAuthorized: @MainActor () -> Bool
    ) -> SessionAdminLifecycleOutcome {
        guard let session = try? authoritativeLiveSession(for: sessionID) else {
            return .blocked("The target session is not live in this window.")
        }
        guard !session.runState.isActive, !session.isComposerSubmissionInFlight else {
            return .blocked("The target is running; change effort when it is idle.")
        }
        let allowed: [String] = if session.selectedAgent.usesClaudeTooling {
            AgentModelCatalog.supportedClaudeEfforts(
                forSelectedModelRaw: session.selectedModelRaw, agentKind: session.selectedAgent
            ).map(\.rawValue)
        } else if session.selectedAgent == .codexExec {
            codexCoordinator.reasoningEffortOptions(
                forModelRaw: session.selectedModelRaw, agentKind: session.selectedAgent
            ).map(\.rawValue)
        } else {
            []
        }
        guard !allowed.isEmpty else {
            return .invalid("The target's provider/model has no selectable effort.")
        }
        guard allowed.contains(effort) else {
            return .invalid("Unsupported effort '\(effort)' for the target's model. Supported: \(allowed.joined(separator: ", ")).")
        }
        guard isStillAuthorized() else { return .blocked("Delegated authority ended before the change.") }
        let usesClaude = session.selectedAgent.usesClaudeTooling
        let changed = usesClaude ? session.selectedClaudeEffortRaw != effort : session.selectedReasoningEffortRaw != effort
        if changed {
            session.selectedReasoningEffortRaw = effort
            if usesClaude { session.selectedClaudeEffortRaw = effort }
            session.isDirty = true
            if session.tabID == currentTabID {
                let restoring = isRestoringState
                isRestoringState = true
                defer { isRestoringState = restoring }
                selectedReasoningEffortRaw = session.selectedReasoningEffortRaw
            }
            scheduleSave(for: session)
            handleObservedMCPStateChange(for: session)
        }
        return .applied(changed: changed, fields: ["effort": effort, "model": session.selectedModelRaw])
    }

    /// Delegation-scope `fork`: the ordinary Handoff/Fork transcript migration into a background tab,
    /// with no focus change and no oversight-link inheritance (a scope may not mint links to
    /// sessions outside it). Returns the new session ID.
    func delegationFork(sessionID: UUID, upToItemID: UUID?) async throws -> UUID {
        guard let source = try authoritativeLiveSession(for: sessionID) else {
            throw SessionAdminHostError.sessionUnavailable
        }
        guard let cutoff = upToItemID ?? source.items.last?.id else {
            throw SessionAdminHostError.invalid("The target session has no transcript to fork.")
        }
        let destinationTabID = try await prepareHandoffToNewTab(
            upToItemID: cutoff,
            destinationAgent: source.selectedAgent,
            destinationModelRaw: source.selectedModelRaw,
            destinationReasoningEffortRaw: source.persistedReasoningEffortRaw,
            sourceTabID: source.tabID,
            activateDestination: false,
            inheritOversightLinks: false
        )
        guard let forkedSessionID = sessions[destinationTabID]?.activeAgentSessionID else {
            throw SessionAdminHostError.invalid("The fork was created but its session did not bind.")
        }
        return forkedSessionID
    }
}
