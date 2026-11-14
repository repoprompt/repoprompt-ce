import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptSettingsCore

extension AgentSessionLinkExecutionRuntime {
    /// Configuration-only snapshot from the unique runtime writer. Labels never warm provider
    /// configuration, and agreeing sidebar replicas do not become additional command owners.
    func agentSessionLinkModelCandidate(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentSessionLinkEndpointCandidate? {
        guard agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint,
              let session = sessions[endpoint.tabID] else { return nil }
        return AgentSessionLinkEndpointCandidate(
            windowID: routeID, workspaceID: endpoint.workspaceID, tabID: endpoint.tabID,
            sessionID: endpoint.sessionID, persistentBindingGeneration: endpoint.persistentBindingGeneration,
            bindingTransitionGeneration: endpoint.bindingTransitionGeneration,
            isTopLevel: session.parentSessionID == nil,
            hasLoadedPersistedState: session.hasLoadedPersistedState,
            bindingTransitionInProgress: session.bindingTransitionInProgress,
            isClosing: AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: endpoint.sessionID),
            isMCPControlled: session.mcpControlContext != nil, isMCPOriginated: session.isMCPOriginated,
            roleAllowsOutboundMonitoring: AgentSessionLinkToolPolicy.allowsOutboundMonitoring(
                taskLabelKind: session.mcpControlContext?.taskLabelKind
            ),
            displayName: "", providerDisplayName: session.selectedAgent.rawValue, locationLabel: nil,
            restorationReadiness: session.qualifiedRestorationReadiness,
            isDeletionInProgress: AgentSessionDeletionRegistry.shared.isDeletionInProgress(sessionID: endpoint.sessionID),
            parentSessionID: session.parentSessionID, createdByOverseerSessionID: session.createdByOverseerSessionID
        )
    }

    /// The exact writer owns the final suspension and synchronous configuration commit. Catalog
    /// availability is a host resource input; neither a presenter nor a window index elects the writer.
    func agentSessionLinkPerformSetModel(
        to candidate: AgentSessionLinkEndpointCandidate,
        modelID: String,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        availability: @MainActor () -> AgentModelCatalog.AvailabilityContext?,
        roleSelectionProvider: AgentMCPSelectionResolver.RoleSelectionProvider? = nil,
        reauthorize: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkModelOutcome {
        guard let command = admit(candidate),
              liveness().permitsDelivery, !Task.isCancelled else { return .blocked(.endpointInvalidated) }
        let session = command.writer.session
        if let failure = agentSessionLinkModelReadiness(session) { return .blocked(failure) }
        guard let admittedAvailability = availability() else { return .blocked(.endpointHost) }
        let admittedModelID: String
        func invalid(_ detail: String, code: String = "model_catalog_admission_failed") -> AgentSessionLinkModelOutcome {
            let alternatives = AgentModelCatalogRuntime.shared.modelIDs(
                for: session.selectedAgent, availability: availability() ?? admittedAvailability
            )
            return .refused(
                code: code,
                detail: detail + " Usable same-agent model_ids: [" + alternatives.joined(separator: ", ")
                    + "]. Next: agent_manage {op: list_agents, roles_only: false} in the destination workspace.",
                alternatives: alternatives
            )
        }
        if AgentModelCatalog.TaskLabelKind(rawValue: modelID.lowercased()) != nil {
            do {
                // Resolve a role once, before the final lease hop, just like agent_run.
                let resolved = try AgentMCPSelectionResolver.resolve(
                    modelID: modelID, availability: admittedAvailability, workspaceID: command.identity.workspaceID,
                    roleSelectionProvider: roleSelectionProvider
                )
                guard let agent = resolved.agentRaw, let raw = resolved.modelRaw else {
                    return invalid("No available model for the requested role.", code: "model_role_unavailable")
                }
                admittedModelID = AgentModelSelectionID(agentRaw: agent, modelRaw: raw).rawValue
            } catch { return invalid("Role resolution failed: " + error.localizedDescription, code: "model_role_unavailable") }
        } else { admittedModelID = modelID }
        if let id = AgentModelSelectionID.parse(admittedModelID), id.rawValue == admittedModelID,
           let agent = AgentProviderKind(rawValue: id.agentRaw), agent != session.selectedAgent
        {
            return invalid("set_model cannot change agent kind (current: \(session.selectedAgent.rawValue)). Use agent_manage.list_agents for a same-agent model_id.", code: "model_agent_mismatch")
        }
        do {
            _ = try AgentModelCatalogRuntime.shared.selection(admittedModelID, availability: admittedAvailability)
        } catch let error as AgentModelCatalogRuntime.AdmissionError { return invalid(error.message, code: error.diagnosticCode) }
        catch { return invalid("Model catalogue admission failed.") }

        let commit = await reauthorize()
        guard commit == .committed else { return .blocked(commit.refusal) }
        // Last suspension above. Recheck the originating incarnation and exact endpoint, not a
        // newly resolved writer, before any configuration assignment.
        guard !Task.isCancelled, liveness().permitsDelivery, command.isCurrent,
              agentSessionLinkObserverEndpoint(tabID: candidate.tabID) == candidate.domainEndpoint
        else { return .blocked(.endpointInvalidated) }
        if let failure = agentSessionLinkModelReadiness(session) { return .blocked(failure) }
        guard availability() == admittedAvailability else {
            return invalid("Destination model availability changed. Refresh agent_manage.list_agents and retry.", code: "model_availability_changed")
        }
        if let id = AgentModelSelectionID.parse(admittedModelID), id.rawValue == admittedModelID,
           let agent = AgentProviderKind(rawValue: id.agentRaw), agent != session.selectedAgent
        {
            return invalid("The target agent changed. Refresh agent_manage.list_agents and choose a same-agent model_id.", code: "model_agent_changed")
        }
        do {
            let selection = try AgentModelCatalogRuntime.shared.selection(admittedModelID, availability: admittedAvailability)
            return .accepted(agentSessionLinkCommitModel(selection, command: command))
        } catch let error as AgentModelCatalogRuntime.AdmissionError { return invalid(error.message, code: error.diagnosticCode) }
        catch { return invalid("Model catalogue admission failed.") }
    }

    /// Delegation effort changes use the same exact writer as link model changes. The scope lease
    /// remains separate authority and is rechecked immediately before the synchronous commit.
    func delegationSetReasoningEffort(
        command: AgentSessionRuntimeStore.Command,
        effort: String,
        isStillAuthorized: @MainActor () -> Bool
    ) -> SessionAdminLifecycleOutcome {
        guard command.writer.scope === scope, command.isCurrent else {
            return .blocked("The target session has no current runtime writer.")
        }
        let session = command.writer.session
        guard agentSessionLinkModelReadiness(session) == nil else {
            return .blocked("The target is running; change effort when it is idle.")
        }
        let allowed: [String] = if session.selectedAgent.usesClaudeTooling {
            AgentModelCatalog.supportedClaudeEfforts(
                forSelectedModelRaw: session.selectedModelRaw, agentKind: session.selectedAgent
            ).map(\.rawValue)
        } else if session.selectedAgent == .codexExec {
            codexCoordinator?.reasoningEffortOptions(
                forModelRaw: session.selectedModelRaw, agentKind: session.selectedAgent
            ).map(\.rawValue) ?? []
        } else {
            []
        }
        guard !allowed.isEmpty else {
            return .invalid("The target's provider/model has no selectable effort.")
        }
        guard allowed.contains(effort) else {
            return .invalid("Unsupported effort '\(effort)' for the target's model. Supported: \(allowed.joined(separator: ", ")).")
        }
        guard isStillAuthorized(), command.isCurrent else {
            return .blocked("Delegated authority or the runtime writer ended before the change.")
        }
        let usesClaude = session.selectedAgent.usesClaudeTooling
        let changed = usesClaude ? session.selectedClaudeEffortRaw != effort : session.selectedReasoningEffortRaw != effort
        if changed {
            session.selectedReasoningEffortRaw = effort
            if usesClaude { session.selectedClaudeEffortRaw = effort }
            session.isDirty = true
            command.writer.scope.persistence.scheduleSave(for: session)
            command.writer.scope.presentation.reasoningEffortChanged(session)
            if command.writer.isCurrent { command.writer.scope.mcp.handleObservedMCPStateChange(for: session) }
        }
        return .applied(changed: changed, fields: ["effort": effort, "model": session.selectedModelRaw])
    }

    private func agentSessionLinkModelReadiness(_ session: TabSession) -> AgentSessionLinkSendFailure? {
        AgentSessionLinkDeliveryReadiness.failure(snapshot: AgentSessionLinkExecutionRuntime.agentSessionLinkDeliveryReadinessSnapshot(
            session: session, endpointMatchesGrant: true, isClosing: false
        ))
    }

    private func agentSessionLinkCommitModel(
        _ selection: AgentModelCatalogRuntime.Selection,
        command: AgentSessionRuntimeStore.Command
    ) -> AgentSessionLinkModelReceipt {
        let writer = command.writer
        let session = writer.session
        let changed = session.selectedModelRaw != selection.storedModelRaw
            || session.selectedReasoningEffortRaw != selection.reasoningEffortRaw
        if changed {
            session.selectedModelRaw = selection.storedModelRaw
            session.selectedReasoningEffortRaw = selection.reasoningEffortRaw
            session.isDirty = true
            writer.scope.persistence.scheduleSave(for: session)
            writer.scope.presentation.modelConfigurationChanged(session, selection: selection)
            Task { @MainActor in
                guard writer.isCurrent else { return }
                writer.scope.mcp.handleObservedMCPStateChange(for: session)
            }
        }
        return AgentSessionLinkModelReceipt(
            modelID: selection.id.rawValue, modelRaw: session.selectedModelRaw,
            reasoningEffortRaw: session.selectedReasoningEffortRaw, changed: changed
        )
    }
}
