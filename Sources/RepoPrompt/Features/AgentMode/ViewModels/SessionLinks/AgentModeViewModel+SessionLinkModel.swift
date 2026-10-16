import Foundation
import RepoPromptDomainRuntime
import RepoPromptSettingsCore

extension AgentModeViewModel {
    /// Workspace-qualified model routing never invokes the generic lifecycle discovery sweep.
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
        guard let identity = agentSessionLinkModelIdentity(
            workspaceID: endpoint.workspaceID, tabID: endpoint.tabID, sessionID: endpoint.sessionID
        ), identity.monitorEndpoint(windowID: windowID) == endpoint,
        let session = sessions[endpoint.tabID] else { return nil }
        return agentSessionLinkCandidate(
            session: session, identity: identity, tabName: "",
            // Compatible-provider displayName reads backend configuration; no label is needed here.
            providerDisplayName: session.selectedAgent.rawValue,
            isWindowClosing: false, includeLocation: false
        )
    }

    private func agentSessionLinkModelSession(matching candidate: AgentSessionLinkEndpointCandidate) -> TabSession? {
        guard let identity = agentSessionLinkModelIdentity(
            workspaceID: candidate.workspaceID, tabID: candidate.tabID, sessionID: candidate.sessionID
        ), identity.monitorEndpoint(windowID: windowID) == candidate.domainEndpoint else { return nil }
        return sessions[candidate.tabID]
    }

    /// The target owns the final suspension. No hydration, provider calls, composer claim, or
    /// discovery occurs here. A concurrent send winning during reauthorization must defeat us.
    func agentSessionLinkPerformSetModel(
        to candidate: AgentSessionLinkEndpointCandidate,
        modelID: String,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        availability: @MainActor () -> AgentModelCatalog.AvailabilityContext,
        reauthorize: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkModelOutcome {
        guard let session = agentSessionLinkModelSession(matching: candidate),
              liveness().permitsDelivery, !Task.isCancelled else { return .blocked(.endpointInvalidated) }
        if let failure = agentSessionLinkModelReadiness(session) { return .blocked(failure) }
        let admittedAvailability = availability()
        if let id = AgentModelSelectionID.parse(modelID), id.rawValue == modelID,
           let agent = AgentProviderKind(rawValue: id.agentRaw), agent != session.selectedAgent
        {
            return .invalid("set_model cannot change agent kind (current: \(session.selectedAgent.rawValue)). Use agent_manage.list_agents for a same-agent model_id.")
        }
        do {
            _ = try AgentAdvertisedModelCatalog.shared.selection(modelID, availability: admittedAvailability)
        } catch let error as AgentAdvertisedModelCatalog.AdmissionError { return .invalid(error.message) }
        catch { return .invalid("Model catalogue admission failed.") }

        let commit = await reauthorize()
        guard commit == .committed else { return .blocked(commit.refusal) }
        // Last suspension above. Exact object, both endpoints, workspace, readiness, and original
        // full-ID membership are re-read synchronously before any configuration assignment.
        guard !Task.isCancelled, liveness().permitsDelivery,
              agentSessionLinkModelSession(matching: candidate) === session,
              workspaceManager?.activeWorkspaceID == candidate.workspaceID
        else {
            return .blocked(.endpointInvalidated)
        }
        if let failure = agentSessionLinkModelReadiness(session) { return .blocked(failure) }
        guard availability() == admittedAvailability else {
            return .invalid("Destination model availability changed. Refresh agent_manage.list_agents and retry.")
        }
        if let id = AgentModelSelectionID.parse(modelID), id.rawValue == modelID,
           let agent = AgentProviderKind(rawValue: id.agentRaw), agent != session.selectedAgent
        {
            return .invalid("The target agent changed. Refresh agent_manage.list_agents and choose a same-agent model_id.")
        }
        do {
            let selection = try AgentAdvertisedModelCatalog.shared.selection(modelID, availability: admittedAvailability)
            return .accepted(agentSessionLinkCommitModel(selection, to: session))
        } catch let error as AgentAdvertisedModelCatalog.AdmissionError { return .invalid(error.message) }
        catch { return .invalid("Model catalogue admission failed.") }
    }

    private func agentSessionLinkModelReadiness(_ session: TabSession) -> AgentSessionLinkSendFailure? {
        AgentSessionLinkDeliveryReadiness.failure(snapshot: Self.agentSessionLinkDeliveryReadinessSnapshot(
            session: session, endpointMatchesGrant: true, isClosing: false
        ))
    }

    /// Synchronous commit seam: only per-session model/effort, narrow active UI, and scheduled save.
    private func agentSessionLinkCommitModel(
        _ selection: AgentAdvertisedModelCatalog.Selection,
        to session: TabSession
    ) -> AgentSessionLinkModelReceipt {
        let changed = session.selectedModelRaw != selection.storedModelRaw
            || session.selectedReasoningEffortRaw != selection.reasoningEffortRaw
        if changed {
            session.selectedModelRaw = selection.storedModelRaw
            session.selectedReasoningEffortRaw = selection.reasoningEffortRaw
            session.isDirty = true
            if session.tabID == currentTabID {
                let restoring = isRestoringState
                isRestoringState = true
                defer { isRestoringState = restoring }
                selectedModelRaw = session.selectedModelRaw
                selectedReasoningEffortRaw = session.selectedReasoningEffortRaw
                // Deliberately defer permission/tool chrome to the next normal binding refresh
                // (including local-turn acceptance): updatePermissionBindingState reads preferences.
                // Runtime permission/launch checks read the session's new model, not this UI snapshot.
                // Do not call makeComposerProps: it resolves parameter/worktree/catalogue state.
                // Publish only selection, dropping old model-qualified controls (not their pins).
                var props = ui.composer.props
                props.selectedModelRaw = session.selectedModelRaw
                props.selectedModelDisplayName = selection.option.displayName
                props.selectedReasoningEffortRaw = session.selectedReasoningEffortRaw
                props.selectedReasoningEffortDisplayName = selectedReasoningEffortDisplayName
                props.acpModelParameterControls = []
                ui.composer.update(props)
            }
            scheduleSave(for: session)
            let binding = session.persistentSessionBindingIdentity
            Task { @MainActor [weak self, weak session] in
                guard let self, let session, sessions[session.tabID] === session,
                      session.persistentSessionBindingIdentity == binding else { return }
                handleObservedMCPStateChange(for: session)
            }
        }
        return AgentSessionLinkModelReceipt(
            modelID: selection.id.rawValue, modelRaw: session.selectedModelRaw,
            reasoningEffortRaw: session.selectedReasoningEffortRaw, changed: changed
        )
    }
}
