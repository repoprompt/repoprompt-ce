import Foundation
import MCP
import RepoPromptDomainRuntime

extension AgentRunHostAdmission {
    @MainActor
    private final class BoundStart {
        var admitted: (command: AgentSessionRuntimeStore.Command, host: AgentSessionRuntimeHost)?
        var control: AgentMCPControlContext?
    }

    /// Resolve the explicit target under the existing setup budget, never via a presenter.
    func executeCanonicalStart(_ args: [String: Value]) async throws -> Value {
        let tools = makeHostToolService()
        let request = try tools.parseStartRequest(args)
        let preparation = BoundStart()
        return try await tools.executeResolvedStart(request, operation: { expiry in
            #if DEBUG
                if let rawToken = AgentMCPToolHelpers.normalizedString(args["_worktree_startup_benchmark_token"]) {
                    guard UUID(uuidString: rawToken) != nil else {
                        throw MCPError.invalidParams("Invalid worktree startup benchmark token.")
                    }
                    // This private diagnostic token is scoped to an admitted presentation route.
                    throw MCPError.invalidParams("Worktree startup benchmark token rejected (\(DebugWorktreeStartupBenchmarkError.invalidScope.code)).")
                }
            #endif
            let workspace = try await canonicalWorkspace()
            let requestedTab = try MCPServerViewModel.resolveExplicitTabIDForAgentMode(
                rawTabID: AgentMCPToolHelpers.normalizedString(args["_tabID"]),
                availableTabIDs: Set(workspace.composeTabs.map(\.id))
            )
            if let requestedTab {
                let matches = workspace.composeTabs.filter { $0.id == requestedTab }
                guard matches.count == 1, !workspace.stashedTabs.contains(where: { $0.tab.id == requestedTab }) else {
                    throw MCPError.invalidParams("The explicit Agent tab has conflicting bindings.")
                }
                if let sessionID = matches[0].activeAgentSessionID {
                    return try await performCanonicalBoundStart(
                        args, request: request, tabID: requestedTab, sessionID: sessionID, expiry: expiry,
                        didAdmit: { command, host in preparation.admitted = (command, host) },
                        didActivate: { preparation.control = $0 }
                    )
                }
            }
            return try await performCanonicalNewChild(
                args, request: request, bindingEmptyTabID: requestedTab, expiry: expiry,
                didPublish: { child in preparation.admitted = (child.command, child.host) },
                didActivate: { preparation.control = $0 }
            )
        }, expiredResult: { sessionID in
            let child = preparation.admitted
            let session = child?.command.writer.session
            let live: AgentRunMCPSnapshot? = if let child, let session,
                                                child.command.identity.sessionID == sessionID, sourceIsCurrent,
                                                child.command.writer.ownsPersistentClaim,
                                                let control = preparation.control,
                                                session.mcpControlContext?.activationID == control.activationID,
                                                session.mcpControlContext?.registration == control.registration,
                                                child.host.scope.mcp.controlRead(sessionID: sessionID, registration: control.registration).session === session
            {
                child.host.scope.mcp.mcpReadSnapshot(for: session)
            } else {
                nil
            }
            let snapshot = AgentRunMCPToolService.startExpirySnapshot(sessionID: sessionID, live: live, ownerSession: session)
            return .init(
                value: AgentRunMCPToolService.startExpiryValue(snapshot), sessionID: sessionID,
                metadata: invocation.metadata, delivery: .startedRun, running: false
            )
        }, awaitStartedRun: { result in
            let targets = try await captureReadTargets([result.sessionID], operation: .runWait)
            let read = readAccess(for: targets, operation: .runWait)
            let value = try await makeHostToolService(waitTargets: targets).waitForStartedRun(request, result: result, read: read)
            try await requireReadTargets(targets, operation: .runWait)
            return value
        })
    }

    private func performCanonicalNewChild(
        _ args: [String: Value], request: AgentRunMCPToolService.StartRequest,
        bindingEmptyTabID: UUID?, expiry: AgentRunStartExpiry, didPublish: (AgentRunHostChildCreation) -> Void,
        didActivate: @escaping @MainActor (AgentMCPControlContext) -> Void
    ) async throws -> AgentRunMCPToolService.StartResult {
        try expiry.throwIfExpired()
        try requireSpawnSource()
        _ = try await canonicalSnapshot()
        // Freeze the exact caller before resolving models or allocating a carrier.
        let review = await captureOracleReviewSource()
        let selection = try await resolveStartSelection(
            arguments: args, resolvedTabID: bindingEmptyTabID, message: request.message
        )
        try expiry.throwIfExpired()
        _ = try await canonicalSnapshot()
        try requireSpawnSource()
        let admission = try DelegationSpawnAdmission.admitOrThrow(creatorSessionID: source.identity.sessionID)
        defer { DelegationSpawnAdmission.finish(admission) }
        let child = try await AgentRunHostChildCreation.publish(
            from: self, name: AgentMCPToolHelpers.normalizedString(args["session_name"]),
            bindingEmptyTabID: bindingEmptyTabID
        )
        didPublish(child)
        do {
            let workspacePath = try await child.prepareWorktree(request.worktree, from: self, expiry: expiry)
            let parameters = try await selection.resolveParameters(args["model_parameters"], workspacePath: workspacePath)
            try expiry.throwIfExpired()
            try await requireCurrent()
            try DelegationSpawnAdmission.stageOnCanonicalCreation(admission, command: child.command, creation: child.creation)
            let outcome = try await child.start(
                from: self, message: request.message, selection: selection, parameters: parameters,
                workflow: request.workflow, reviewSource: review, expiry: expiry, didActivate: didActivate
            )
            return .init(
                value: makeHostToolService().decoratedRunValue(snapshot: outcome.snapshot, workflow: request.workflow, delivery: outcome.delivery),
                sessionID: outcome.snapshot.sessionID, metadata: invocation.metadata, delivery: outcome.delivery,
                running: outcome.snapshot.status == .running
            )
        } catch {
            await child.discardIfProvisional()
            throw error
        }
    }

    private func performCanonicalBoundStart(
        _ args: [String: Value], request: AgentRunMCPToolService.StartRequest, tabID: UUID, sessionID: UUID,
        expiry: AgentRunStartExpiry, didAdmit: (AgentSessionRuntimeStore.Command, AgentSessionRuntimeHost) -> Void,
        didActivate: @escaping @MainActor (AgentMCPControlContext) -> Void
    ) async throws -> AgentRunMCPToolService.StartResult {
        try expiry.throwIfExpired()
        try requireSpawnSource()
        let creator = source.identity.sessionID
        guard sessionID != creator, host.route.domainRuntimeIdentity == AppDomainRuntimeComposition.shared.runtime.identity else {
            throw MCPError.invalidParams("The explicit Agent tab is not a valid child destination.")
        }
        let review = await captureOracleReviewSource()
        let selection = try await resolveStartSelection(arguments: args, resolvedTabID: tabID, message: request.message)
        try expiry.throwIfExpired()

        func matchesCarrier(_ snapshot: DomainWorkspaceSnapshot) -> Bool {
            guard let workspace = try? JSONDecoder().decode(WorkspaceModel.self, from: snapshot.document.documentBytes),
                  workspace.id == workspaceID else { return false }
            let tabs = workspace.composeTabs.filter { $0.id == tabID }
            return tabs.count == 1 && tabs[0].activeAgentSessionID == sessionID
                && !workspace.stashedTabs.contains { $0.tab.id == tabID }
        }
        guard try await matchesCarrier(canonicalSnapshot()) else {
            throw MCPError.invalidParams("The explicit Agent tab no longer carries the requested session.")
        }
        let reservation = UUID()
        let admissions = WorkspaceAgentAdmissionCoordinator.shared
        guard admissions.reserveProvisionalSession(workspaceID: workspaceID, sessionID: sessionID, ownerID: reservation)
        else { throw MCPError.internalError("The Agent session target is still provisional. Retry after it settles.") }
        defer { admissions.releaseProvisionalSession(workspaceID: workspaceID, sessionID: sessionID, ownerID: reservation) }
        let manager = WindowStatesManager.shared
        manager.beginPreparedOversightPreparation(sessionID)
        defer { manager.endPreparedOversightPreparation(sessionID) }
        let environment = try captureContinuationProviderEnvironment()
        let prepared = await manager.prepareSavedOversightTarget(
            sessionID, providerEnvironment: environment, isStillAuthorized: { sourceIsCurrent }
        )
        let writer = try prepared.get()
        let target = try writer.admitCommand().get()
        let session = writer.session
        guard writer.identity.workspaceID == workspaceID, session.tabID == tabID, !session.runState.isActive,
              !session.mcpFollowUpRunPending, let targetHost = writer.scope.executableHost,
              targetHost.route.domainRuntimeIdentity == host.route.domainRuntimeIdentity,
              let expectedActivation = targetHost.workspaceActivation, let executor = writer.scope.linkExecution,
              let endpoint = executor.agentSessionLinkObserverEndpoint(tabID: tabID), endpoint.sessionID == sessionID
        else { throw MCPError.invalidParams(AgentModeViewModel.mcpResidentTargetError) }

        let stopFence = AgentRunStartStopFence(session: session)
        var expectedParent = session.parentSessionID
        let wasResident = AgentModeViewModel.isMCPResidentAppOwned(session)
        func requireOwner() throws {
            try target.requireCurrent()
            guard sourceIsCurrent, stopFence.permitsStart(of: session),
                  targetHost.workspaceActivation === expectedActivation,
                  expectedActivation.owns(scope: writer.scope, route: targetHost.route),
                  session.parentSessionID == expectedParent,
                  executor.agentSessionLinkObserverEndpoint(tabID: tabID) == endpoint
            else { throw MCPFileToolAuthorityFailure.superseded }
            if wasResident { try executor.mcpRequireResidentLinkFence(endpoint) }
        }
        let hasLinks = wasResident ? await executor.agentSessionLinkHasActiveOutboundLink(endpoint) : false
        let snapshot = try await canonicalSnapshot()
        try requireOwner()
        try expiry.throwIfExpired()
        guard !session.runState.isActive, !session.mcpFollowUpRunPending, matchesCarrier(snapshot)
        else { throw MCPError.invalidParams(AgentModeViewModel.mcpResidentTargetError) }
        if wasResident { try executor.mcpRequireResidentLinkFence(endpoint, authoritativeHasLinks: hasLinks) }

        let placement = DelegationSpawnTargetPlacement(
            organizationalParentID: session.organizationalParentID, parentSessionID: session.parentSessionID,
            createdByOverseerSessionID: session.createdByOverseerSessionID, delegationScopeID: session.delegationScopeID
        )
        let admission = try DelegationSpawnAdmission.admitOrThrow(
            creatorSessionID: creator,
            target: DelegationSpawnTarget.classify(sessionID: sessionID, placement: placement, creatorSessionID: creator)
        )
        defer { DelegationSpawnAdmission.finish(admission) }
        let parent = session.parentSessionID ?? creator
        /// Preparation may use the proposed lineage, but it may not publish child-control
        /// provenance before the exact existing session accepts a durable user row.
        func acceptInput() async throws {
            try requireOwner()
            let adoptedParent = expectedParent == nil
            if adoptedParent {
                session.parentSessionID = parent
                expectedParent = parent
                session.isDirty = true
            }
            if placement.admitsStamp(by: creator), let scopeID = admission?.stampScopeID,
               let lease = admission?.stampLease, AgentSessionLinkRuntimeBridge.shared.delegationScopes.isCurrent(lease)
            {
                let commit = try target.commitDelegationPlacement(organizationalParentID: creator, delegationScopeID: scopeID) { writer in
                    manager.projectDelegationPlacement(writer)
                }
                try await commit.persisted()
            } else if adoptedParent, case let .failure(failure) = await writer.scope.persistence.flushSaveRequired(writer: writer) {
                throw MCPError.internalError(failure.message)
            }
            try requireOwner()
            DelegationSpawnAdmission.finish(admission)
        }

        didAdmit(target, targetHost)
        let workspacePath = try await AgentRunHostStartTransaction.prepareWorktree(
            request.worktree, from: self, host: targetHost, command: target, stopFence: stopFence,
            expiry: expiry, validatesCarrier: matchesCarrier, proposedParentID: parent, requireTarget: requireOwner
        )
        let parameters = try await selection.resolveParameters(args["model_parameters"], workspacePath: workspacePath)
        try expiry.throwIfExpired()
        let outcome = try await AgentRunHostStartTransaction.start(
            host: targetHost, command: target, stopFence: stopFence, expectedParent: { expectedParent },
            from: self, message: request.message, selection: selection, parameters: parameters,
            workflow: request.workflow, reviewSource: review, expiry: expiry,
            validateCarrier: matchesCarrier, requireTarget: requireOwner, didActivate: didActivate,
            acceptDurableInput: acceptInput, commitConfiguration: {
                try requireOwner()
                return target
            }
        )
        return .init(
            value: makeHostToolService().decoratedRunValue(snapshot: outcome.snapshot, workflow: request.workflow, delivery: outcome.delivery),
            sessionID: sessionID, metadata: invocation.metadata, delivery: outcome.delivery, running: outcome.snapshot.status == .running
        )
    }
}
