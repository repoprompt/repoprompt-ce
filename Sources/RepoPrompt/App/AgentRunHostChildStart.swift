import Foundation
import MCP
import RepoPromptAIContracts

extension AgentRunHostChildCreation {
    /// Drive the shared external-start sequence from the exact provisional writer. The
    /// requesting connection stays on the parent route; the child installs its own MCP policy.
    func start(
        from source: AgentRunHostAdmission, message: String, selection: AgentRunMCPToolService.StartSelection,
        parameters: [ACPModelParameterSelection], workflow: AgentWorkflowDefinition?,
        reviewSource: AgentRunOracleReviewSource, expiry: AgentRunStartExpiry
    ) async throws -> AgentExternalMCPRunStarter.StartOutcome {
        let scope = host.scope
        let session = command.writer.session
        let sessionID = command.identity.sessionID
        let parentSessionID = source.source.identity.sessionID
        guard let activation = host.workspaceActivation, let availability = activation.modelAvailability,
              let interactions = scope.installedInteractions, let executor = scope.linkExecution
        else { throw MCPFileToolAuthorityFailure.unavailable }
        var configured: AgentSessionRuntimeStore.Command?
        func requireOrigin() throws {
            try Task.checkCancellation()
            try (configured ?? command).requireCurrent()
            guard source.sourceIsCurrent, activation.owns(scope: scope, route: host.route),
                  stopFence.permitsStart(of: session), session.parentSessionID == parentSessionID,
                  session.operationAdmissionFailureMessage == nil || configured == nil
            else { throw MCPFileToolAuthorityFailure.superseded }
        }
        func requireCarrier() async throws {
            let snapshot = try await source.canonicalSnapshot()
            try requireOrigin()
            guard activation.executionTab(in: snapshot, command: command) != nil else {
                throw MCPFileToolAuthorityFailure.superseded
            }
        }
        try expiry.throwIfExpired()
        try await requireCarrier()
        let context = try await scope.mcp.activateControlContext(
            command: command, activationID: UUID(), originatingConnectionID: source.connection.connectionID,
            taskLabelKind: selection.resolved.taskLabelKind, startPending: true, markSessionAsMCPOriginated: true,
            requireInactiveRunState: true, resources: .init(
                approvalStore: interactions.approvalStore, approvalScope: interactions.approvalScope(for: session),
                providerBindings: host.providerBindingService, perfRecorder: session.perfRecorder
            ), revalidateAdmission: { _ in try requireOrigin() }
        )
        do {
            return try await AgentExternalMCPRunStarter.finishPendingStart(
                sessionID: sessionID, tabID: session.tabID, session: session, ownedActivation: context,
                originalStopFence: stopFence, expiry: expiry, actions: .init(
                    ownerIsCurrent: { (try? requireOrigin()) != nil }, configure: {
                        try scope.mcp.stageAgentRunOracleReviewSource(
                            reviewSource, session: session, sessionID: sessionID,
                            workspaceID: self.command.identity.workspaceID, expectedParentSessionID: parentSessionID
                        )
                        let normalized = AgentModelCatalog.normalizeSelection(
                            agentRaw: selection.resolved.agentRaw ?? session.selectedAgent.rawValue,
                            modelRaw: selection.resolved.modelRaw ?? session.selectedModelRaw,
                            availability: availability, preserveUnavailableAgent: true
                        )
                        let effort = selection.routedTarget?.reasoningEffortRaw
                            ?? AgentExternalMCPRunStarter.extractReasoningEffort(from: selection.resolved.modelRaw).effort
                        try await self.host.configureMCPModel(
                            for: session, selection: normalized, reasoningEffortRaw: effort, parameters: parameters,
                            requireAdmission: requireOrigin
                        )
                    }, prepareRequestBinding: {
                        // Deliberately preserve the request's connection-to-parent binding.
                    }, commitConfiguration: {
                        try await requireCarrier()
                        configured = try await self.commitConfiguredCreation()
                    }, dispatch: { requirePendingStart in
                        try await requireCarrier()
                        try requirePendingStart()
                        guard let configured, configured.isCurrent,
                              let target = scope.submissions.programmaticTarget(configured),
                              let claim = executor.claimComposerSubmitAttempt(.init(
                                  id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: ""
                              )) else { throw MCPFileToolAuthorityFailure.superseded }
                        let providerText = workflow?.wrapUserText(
                            message, includeBuiltInSessionCleanupGuidance: self.host.modelRouterSettingsStore.showBuiltInWorkflowCleanupGuidance()
                        ) ?? message
                        let outcome = await executor.persistAndStartNoncomposerTurn(
                            session: session, tabID: session.tabID, workspaceID: configured.identity.workspaceID,
                            claim: claim, displayText: message, providerMessage: providerText, workflow: workflow,
                            attribution: nil, stopFence: self.stopFence, directStartOptions: .init(),
                            dispatchIsCurrent: { (try? requirePendingStart()) != nil }
                        )
                        switch outcome {
                        case let .blocked(failure): throw MCPError.invalidParams(failure.message)
                        case let .delivered(delivery):
                            guard delivery.deliveryState == .runStarted || session.runState == .failed else {
                                throw MCPError.invalidParams("The initial instruction was saved, but the originating run did not start.")
                            }
                            return .startedRun
                        }
                    }, snapshot: {
                        await AgentExternalMCPRunStarter.resolveInitialSnapshot(sessionID: sessionID, registration: context.registration) { registration in
                            guard scope.mcp.controlRead(sessionID: sessionID, registration: registration).session === session else { return nil }
                            return scope.mcp.mcpReadSnapshot(for: session)
                        }
                    }
                )
            )
        } catch {
            // An activation owns only its exact registration, never a successor epoch or a
            // running provider. The first-save owner independently decides compensation.
            if scope.sessions[session.tabID] === session, session.mcpControlContext == context {
                _ = await scope.mcp.deactivateControlContext(
                    session: session, expectedContext: context, approvalStore: interactions.approvalStore, cleanupRegistration: true
                )
            }
            throw error
        }
    }
}
