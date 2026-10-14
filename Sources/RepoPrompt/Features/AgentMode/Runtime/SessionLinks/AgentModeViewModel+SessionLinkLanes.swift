import Foundation
import MCP
import RepoPromptDomainRuntime

/// A fresh lane has already published its durable tab binding. The idempotency key must be spent
/// even if subsequent hydration or lifecycle validation cannot complete.
struct AgentSessionLanePublishedFailure: Error {
    let sessionID: UUID
    let tabID: UUID
}

extension AgentModeViewModel {
    func agentSessionLinkWasCreatedBy(sessionID: UUID, creatorSessionID: UUID) -> Bool {
        ownerValidatedSessionIndex[sessionID]?.createdByOverseerSessionID == creatorSessionID
            || sessions.values.contains {
                $0.activeAgentSessionID == sessionID
                    && $0.createdByOverseerSessionID == creatorSessionID
            }
    }

    func agentSessionLinkChildRetirementRecords() -> [AgentSessionLaneChildRetirementRecord] {
        let loadedSessionIDs = Set(sessions.values.filter(\.hasLoadedPersistedState).compactMap(\.activeAgentSessionID))
        var records = ownerValidatedSessionIndex.values.filter { !loadedSessionIDs.contains($0.id) }.map { entry in
            AgentSessionLaneChildRetirementRecord(
                sessionID: entry.id, parentSessionID: entry.parentSessionID,
                blocksRetirement: entry.lastRunStateRaw.flatMap(AgentSessionRunState.init(rawValue:))?.isActive ?? true,
                source: .sessionIndex
            )
        }
        for session in sessions.values {
            guard let sessionID = session.activeAgentSessionID else { continue }
            let indexed = ownerValidatedSessionIndex[sessionID]
            records.append(.init(
                sessionID: sessionID,
                parentSessionID: session.hasLoadedPersistedState
                    ? session.parentSessionID : session.parentSessionID ?? indexed?.parentSessionID,
                blocksRetirement: !agentSessionLinkLaneSessionIsQuiescent(session),
                source: session.hasLoadedPersistedState ? .hydratedSession : .unhydratedSession
            ))
        }
        return records
    }

    private func agentSessionLinkLaneSessionIsQuiescent(_ session: TabSession) -> Bool {
        !session.runState.isActive
            && session.waitingPrompt == nil
            && Self.pendingInteractionKind(for: session) == nil
            && !session.isComposerSubmissionInFlight
            && !session.mcpFollowUpRunPending
            && !session.terminalCommitInProgress
            && session.pendingInstructions.isEmpty
            && session.pendingACPSteeringInstructions.isEmpty
            && session.pendingClaudeSteeringInstructions.isEmpty
            && session.oversight.pendingAutoWake == nil
    }

    enum MCPOversightLaneCreationOutcome: Equatable {
        case created(sessionID: UUID, tabID: UUID, bindingToken: AgentSessionRestorationBindingToken)
        case creationIncomplete(sessionID: UUID, tabID: UUID)
    }

    /// Creates a user-visible, top-level session without MCP ownership or a provider turn. The
    /// caller may establish an oversight link only after `.created` proves the first payload save.
    func mcpCreateOversightLane(
        creatorSessionID: UUID,
        sessionName: String?,
        selection: AgentSessionLanePolicy.RoleSelection,
        expectedWorkspaceID: UUID
    ) async throws -> MCPOversightLaneCreationOutcome {
        guard workspaceManager?.activeWorkspaceID == expectedWorkspaceID,
              workspaceManager?.activeWorkspace?.id == expectedWorkspaceID
        else {
            throw MCPError.invalidParams("The destination workspace is not active.")
        }
        // Scope-only: guardrails of every scope the creator belongs to, and auto-join stamping.
        let spawnAdmission: DelegationSpawnAdmission.Admission?
        do {
            spawnAdmission = try DelegationSpawnAdmission.admitOrThrow(creatorSessionID: creatorSessionID)
        } catch let MCPError.invalidParams(detail) {
            throw AgentSessionLaneSpawnAdmissionFailure(detail: detail ?? "Scoped spawn admission was refused. Call session_admin scope_status to inspect authority and placement.")
        }
        defer { DelegationSpawnAdmission.finish(spawnAdmission) }
        let target: MCPSessionTarget
        do {
            target = try await mcpResolveOrCreateSessionTarget(
                tabID: nil,
                sessionID: nil,
                createIfNeeded: true,
                sessionName: sessionName,
                parentSessionID: nil,
                inheritWorktreeBindings: false,
                expectedWorkspaceID: expectedWorkspaceID,
                creationKind: .oversightLane(creatorSessionID: creatorSessionID)
            )
        } catch let published as AgentSessionLanePublishedFailure {
            return .creationIncomplete(sessionID: published.sessionID, tabID: published.tabID)
        }
        guard let sessionID = target.sessionID ?? target.recoveryClaim?.identity.sessionID else {
            throw MCPError.internalError("The new lane has no session ID.")
        }
        // A published lane keeps its visible identity even if configuration or persistence fails.
        // Accept the provisional admission rather than invoking MCP's discard/delete recovery path.
        mcpAcceptSessionTarget(target)
        // Acceptance settles the recovery claim. Subsequent configuration checks must use the
        // claimless exact lifecycle identity, not ask a settled claim to still be provisional.
        let settledTarget = MCPSessionTarget(
            tabID: target.tabID, sessionID: target.sessionID,
            origin: .existingSession, lifecycleIdentity: target.lifecycleIdentity,
            creationHandle: target.creationHandle
        )
        let incomplete: MCPOversightLaneCreationOutcome = .creationIncomplete(
            sessionID: sessionID,
            tabID: target.tabID
        )
        guard let session = session(for: target.tabID, createIfNeeded: false),
              session.activeAgentSessionID == sessionID,
              session.createdByOverseerSessionID == creatorSessionID,
              session.parentSessionID == nil,
              !session.isMCPOriginated,
              session.mcpControlContext == nil
        else {
            failSessionCreation(target.creationHandle, message: "This lane changed before its initial configuration completed.")
            return incomplete
        }

        do {
            try requireCurrentMCPWorkspaceTarget(settledTarget, expectedWorkspaceID: expectedWorkspaceID)
            try requireSessionConfigurationAdmission(session, creationHandle: target.creationHandle)
        } catch {
            failSessionCreation(target.creationHandle, message: "This lane changed before its initial configuration completed.")
            return incomplete
        }
        if let scopeID = spawnAdmission?.stampScopeID, let lease = spawnAdmission?.stampLease,
           AgentSessionLinkRuntimeBridge.shared.delegationScopes.isCurrent(lease),
           DelegationSpawnTargetPlacement(
               organizationalParentID: session.organizationalParentID,
               parentSessionID: session.parentSessionID,
               createdByOverseerSessionID: session.createdByOverseerSessionID,
               delegationScopeID: session.delegationScopeID
           ).admitsStamp(by: creatorSessionID)
        {
            // Auto-join before the first save so the lane's placement is durable with it. Like every
            // stamp, it never overwrites an existing placement or scope.
            session.organizationalParentID = creatorSessionID
            session.delegationScopeID = scopeID
        }
        // Provenance was installed by the fresh-session seam before this first dirty marking.
        session.isDirty = true
        #if DEBUG
            await test_afterOversightLaneProvision?(target.tabID)
        #endif
        do {
            try requireCurrentMCPWorkspaceTarget(settledTarget, expectedWorkspaceID: expectedWorkspaceID)
            try await mcpConfigureSession(
                tabID: target.tabID,
                agentRaw: selection.agentRaw,
                modelRaw: selection.modelRaw,
                reasoningEffortRaw: selection.reasoningEffortRaw,
                requireInactiveRunState: true,
                workspaceAuthority: .init(
                    target: settledTarget,
                    expectedWorkspaceID: expectedWorkspaceID,
                    allowMatchingControlledSession: false
                ),
                creationHandle: target.creationHandle
            )
            try requireCurrentMCPWorkspaceTarget(settledTarget, expectedWorkspaceID: expectedWorkspaceID)
            try mcpApplyModelParameterSelections(
                tabID: target.tabID,
                selections: selection.modelParameterSelections,
                creationHandle: target.creationHandle
            )
            guard mcpOversightLaneSelectionMatches(selection, session: session)
            else {
                failSessionCreation(target.creationHandle, message: "This lane's initial model selection could not be configured.")
                return incomplete
            }
            try Task.checkCancellation()
        } catch {
            failSessionCreation(target.creationHandle, message: "This lane did not finish its initial configuration. Create a new lane.")
            return incomplete
        }

        guard await mcpCommitOversightLaneFirstSave(
            session: session,
            sessionID: sessionID,
            workspaceID: expectedWorkspaceID,
            creationHandle: target.creationHandle
        ) else {
            // A configured write failure retains the same owner's ready-to-persist snapshot.
            // Only a still-preparing creation can be failed here; ordinary autosave stays blocked.
            failSessionCreation(target.creationHandle, message: "This lane did not finish its initial configuration. Create a new lane.")
            return incomplete
        }
        guard !Task.isCancelled else { return incomplete }
        guard session.activeAgentSessionID == sessionID,
              session.createdByOverseerSessionID == creatorSessionID,
              session.parentSessionID == nil,
              session.mcpControlContext == nil,
              !session.isMCPOriginated
        else { return incomplete }
        guard case let .authoritative(bindingToken, .freshBindingDurablyCreated) = session.restorationReadiness
        else { return incomplete }
        return .created(sessionID: sessionID, tabID: target.tabID, bindingToken: bindingToken)
    }

    private func mcpOversightLaneSelectionMatches(
        _ selection: AgentSessionLanePolicy.RoleSelection,
        session: TabSession
    ) -> Bool {
        guard session.selectedAgent.rawValue == selection.agentRaw,
              selection.reasoningEffortRaw.map({ session.selectedReasoningEffortRaw == $0 }) ?? true
        else { return false }
        if session.selectedAgent == .codexExec {
            let requested = CodexModelSpecifier(raw: selection.modelRaw)
            let installed = CodexModelSpecifier(raw: session.selectedModelRaw)
            return requested.baseModel == installed.baseModel
                && requested.serviceTier == installed.serviceTier
        }
        if session.selectedAgent.usesClaudeNativeRuntime {
            return ClaudeModelSpecifier(raw: selection.modelRaw).baseModel
                == ClaudeModelSpecifier(raw: session.selectedModelRaw).baseModel
        }
        return session.selectedModelRaw == selection.modelRaw
    }

    /// Exact-incarnation read for cap and retirement checks; a stale endpoint never inherits a
    /// replacement's provenance merely because the session UUID is the same.
    func agentSessionLinkLaneProvenance(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> UUID? {
        guard agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint,
              let session = session(for: endpoint.tabID, createIfNeeded: false),
              session.activeAgentSessionID == endpoint.sessionID
        else { return nil }
        if session.hasLoadedPersistedState {
            return session.createdByOverseerSessionID
        }
        return ownerValidatedSessionIndex[endpoint.sessionID]?.createdByOverseerSessionID
    }

    func agentSessionLinkLaneCreatorLabel(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> String? {
        guard let creatorID = agentSessionLinkLaneProvenance(for: endpoint) else { return nil }
        return agentSessionLinkLocalCreatorLabel(creatorID: creatorID)
    }

    /// Known row identity: never search unrelated live sessions. A matching hydrated nil is
    /// authoritative; an unhydrated freshly provisioned creator still wins before index publication.
    func agentSessionLinkLaneCreatorSessionID(tabID: UUID, expectedSessionID: UUID) -> UUID? {
        if let live = sessions[tabID], live.activeAgentSessionID == expectedSessionID {
            return live.createdByOverseerSessionID
                ?? (live.hasLoadedPersistedState ? nil : ownerValidatedSessionIndex[expectedSessionID]?.createdByOverseerSessionID)
        }
        return ownerValidatedSessionIndex[expectedSessionID]?.createdByOverseerSessionID
    }

    func agentSidebarLaneCreator(
        tabID: UUID,
        expectedSessionID: UUID,
        names: [UUID: String]? = nil,
        archived: Bool = false
    ) -> (sessionID: UUID, label: String)? {
        if !archived, let live = sessions[tabID], live.activeAgentSessionID != expectedSessionID {
            return nil
        }
        guard let creatorID = agentSessionLinkLaneCreatorSessionID(tabID: tabID, expectedSessionID: expectedSessionID) else { return nil }
        let label = (names ?? sidebarCreatorDisplayNames)[creatorID]
            ?? agentSessionLinkLocalCreatorLabel(creatorID: creatorID)
        return (creatorID, label)
    }

    func agentSessionLinkLocalCreatorLabel(creatorID: UUID) -> String {
        let name = ownerValidatedSessionIndex[creatorID]?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.flatMap { $0.isEmpty ? nil : $0 }
            ?? AgentMonitorSessionIDFormatter.short(creatorID)
    }

    /// Preflight or stash one exact inactive lane. The commit:false phase runs the same required
    /// flush, cascade, and post-preflight CAS checks as the stash, plus a non-mutating save-admission
    /// probe — it only skips the projection mutation. The flush is deliberately effectful: real
    /// save I/O is what freshens the stale child headers the post-preflight rescan relies on.
    /// Commit re-runs every check with fresh claims.
    func agentSessionLinkRetireLane(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        commit: Bool,
        isStillRetirable: @escaping @MainActor () -> Bool,
        descendantSessionIDs: Set<UUID> = [],
        didStash: @MainActor (Set<UUID>) -> Void = { _ in }
    ) async -> Bool {
        let canRetire: @MainActor () -> Bool = { [weak self] in
            guard let self,
                  isStillRetirable(),
                  agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint,
                  let session = session(for: endpoint.tabID, createIfNeeded: false),
                  session.activeAgentSessionID == endpoint.sessionID,
                  agentSessionLinkLaneSessionIsQuiescent(session),
                  !AgentSessionLaneChildRetirementRecord.hasBlockingDescendant(
                      of: endpoint.sessionID, in: agentSessionLinkChildRetirementRecords()
                  )
            else { return false }
            return true
        }
        guard canRetire(), let promptManager, let workspaceManager else { return false }
        let subtreeTabIDs = Set(promptManager.currentComposeTabs.compactMap { tab in
            tab.activeAgentSessionID.map { descendantSessionIDs.contains($0) } == true ? tab.id : nil
        }).union([endpoint.tabID])
        let report = await promptManager.stashComposeTabs(
            withIDs: subtreeTabIDs,
            isMutationContextCurrent: canRetire,
            postPreflightValidation: canRetire,
            expandCascade: true,
            validateOnly: !commit
        )
        guard report.rejections.isEmpty else { return false }
        guard commit else {
            return workspaceManager.canAdmitLifecycleWorkspaceSave(workspaceID: endpoint.workspaceID)
        }
        guard report.removedComposeTabIDs.contains(endpoint.tabID),
              workspaceManager.activeWorkspace?.stashedTabs.contains(where: {
                  $0.tab.id == endpoint.tabID
              }) == true
        else { return false }
        didStash(report.removedComposeTabIDs)
        // The stash has committed in memory, so the lane is retired even when this canonical save
        // is not admitted: the normal save cadence persists it later, and the accepted worst case
        // is the tab returning unlinked after a crash. The save still runs — the retirement
        // activation claim stays held by the bridge until it settles, so another window cannot
        // reload the pre-stash binding in the meantime — but its admission no longer gates the
        // outcome; only an uncommitted stash may report `unlinked_not_stashed`.
        _ = await workspaceManager.pollAndSaveStateWithOutcomeAsync(
            workspaceID: endpoint.workspaceID,
            source: WorkspaceSaveSource("oversightLaneRetirement")
        )
        return true
    }

    /// The synchronous slice of the retire CAS run immediately before unlinking: endpoint
    /// currentness, target quiescence, live subtree settlement, and the save-admission probe.
    func agentSessionLinkRetirementReadiness(endpoint: DomainAgentSessionLinkEndpointIdentity) -> Bool {
        guard agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint,
              let session = session(for: endpoint.tabID, createIfNeeded: false),
              session.activeAgentSessionID == endpoint.sessionID,
              agentSessionLinkLaneSessionIsQuiescent(session),
              !AgentSessionLaneChildRetirementRecord.hasBlockingDescendant(
                  of: endpoint.sessionID, in: agentSessionLinkChildRetirementRecords()
              ),
              let workspaceManager
        else { return false }
        return workspaceManager.canAdmitLifecycleWorkspaceSave(workspaceID: endpoint.workspaceID)
    }
}
