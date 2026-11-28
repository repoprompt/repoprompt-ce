import Foundation
import MCP
import RepoPromptAIContracts
import RepoPromptDomainRuntime

extension AgentRunHostChildCreation {
    /// Drive the shared external-start sequence from the exact provisional writer. The
    /// requesting connection stays on the parent route; the child installs its own MCP policy.
    func start(
        from source: AgentRunHostAdmission, message: String, selection: AgentRunMCPToolService.StartSelection,
        parameters: [ACPModelParameterSelection], workflow: AgentWorkflowDefinition?,
        reviewSource: AgentRunOracleReviewSource, expiry: AgentRunStartExpiry,
        didActivate: @escaping @MainActor (AgentMCPControlContext) -> Void
    ) async throws -> AgentExternalMCPRunStarter.StartOutcome {
        try await AgentRunHostStartTransaction.start(
            host: host, command: command, stopFence: stopFence, expectedParent: { source.source.identity.sessionID },
            from: source, message: message, selection: selection, parameters: parameters, workflow: workflow,
            reviewSource: reviewSource, expiry: expiry, requireTarget: {}, didActivate: didActivate,
            commitConfiguration: { try await self.commitConfiguredCreation() }
        )
    }
}

@MainActor
enum AgentRunHostStartTransaction {
    /// Creation and existing targets use the same pending-start owner. The carrier predicate
    /// retains a stricter raw-tab fence for explicitly selected already-bound sessions.
    static func start(
        host: AgentSessionRuntimeHost, command: AgentSessionRuntimeStore.Command,
        stopFence: AgentRunStartStopFence, expectedParent: @escaping @MainActor () -> UUID?,
        from source: AgentRunHostAdmission, message: String, selection: AgentRunMCPToolService.StartSelection,
        parameters: [ACPModelParameterSelection], workflow: AgentWorkflowDefinition?,
        reviewSource: AgentRunOracleReviewSource, expiry: AgentRunStartExpiry,
        validateCarrier: @escaping @MainActor (DomainWorkspaceSnapshot) -> Bool = { _ in true },
        requireTarget: @escaping @MainActor () throws -> Void,
        didActivate: @escaping @MainActor (AgentMCPControlContext) -> Void,
        acceptDurableInput: (@MainActor () async throws -> Void)? = nil,
        commitConfiguration: @escaping @MainActor () async throws -> AgentSessionRuntimeStore.Command
    ) async throws -> AgentExternalMCPRunStarter.StartOutcome {
        let scope = host.scope
        let session = command.writer.session
        let sessionID = command.identity.sessionID
        guard let activation = host.workspaceActivation, let availability = activation.modelAvailability,
              let interactions = scope.installedInteractions, let executor = scope.linkExecution
        else { throw MCPFileToolAuthorityFailure.unavailable }
        var configured: AgentSessionRuntimeStore.Command?
        func requireOrigin() throws {
            try Task.checkCancellation()
            try (configured ?? command).requireCurrent()
            try requireTarget()
            guard source.sourceIsCurrent, activation.owns(scope: scope, route: host.route),
                  stopFence.permitsStart(of: session), session.parentSessionID == expectedParent(),
                  session.operationAdmissionFailureMessage == nil || configured == nil
            else { throw MCPFileToolAuthorityFailure.superseded }
        }
        func requireCarrier() async throws {
            let snapshot = try await source.canonicalSnapshot()
            try requireOrigin()
            guard activation.executionTab(in: snapshot, command: command) != nil, validateCarrier(snapshot) else {
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
        didActivate(context)
        do {
            return try await AgentExternalMCPRunStarter.finishPendingStart(
                sessionID: sessionID, tabID: session.tabID, session: session, ownedActivation: context,
                originalStopFence: stopFence, expiry: expiry, actions: .init(
                    ownerIsCurrent: { (try? requireOrigin()) != nil }, configure: {
                        let normalized = AgentModelCatalog.normalizeSelection(
                            agentRaw: selection.resolved.agentRaw ?? session.selectedAgent.rawValue,
                            modelRaw: selection.resolved.modelRaw ?? session.selectedModelRaw,
                            availability: availability, preserveUnavailableAgent: true
                        )
                        let effort = selection.routedTarget?.reasoningEffortRaw
                            ?? AgentExternalMCPRunStarter.extractReasoningEffort(from: selection.resolved.modelRaw).effort
                        try await host.configureMCPModel(
                            for: session, selection: normalized, reasoningEffortRaw: effort, parameters: parameters,
                            requireAdmission: requireOrigin
                        )
                    }, prepareRequestBinding: {
                        // Deliberately preserve the request's connection-to-parent binding.
                    }, commitConfiguration: {
                        try await requireCarrier()
                        let committed = try await commitConfiguration()
                        configured = committed
                        WindowStatesManager.shared.retainChildControl(committed, host: host)
                    }, dispatch: { requirePendingStart in
                        try await requireCarrier()
                        try requirePendingStart()
                        guard let configured, session.autoEffortJudgmentID == nil else {
                            throw MCPFileToolAuthorityFailure.superseded
                        }
                        let policy = source.autoEffortPolicy(for: host, command: configured)
                        let judgesEffort = AutoEffortModelPolicy.shouldJudgeMCPUserTurn(
                            isEnabled: host.modelRouterSettingsStore.autoEffortEnabled(),
                            startsNewRun: !session.runState.isActive, hasPriorUserTurn: session.hasSentFirstMessage,
                            isNativePreparedTurn: false, preserveRoutedInitialEffort: selection.routedTarget != nil
                        )
                        let effort = judgesEffort ? await policy.chooseAutoEffortForUserTurn(
                            text: message, session: session, workflow: workflow,
                            isCurrent: { (try? requirePendingStart()) != nil }
                        ) : nil
                        try await requireCarrier()
                        try requirePendingStart()
                        guard !session.runState.isActive, configured.isCurrent,
                              let target = scope.submissions.programmaticTarget(configured),
                              let claim = executor.claimComposerSubmitAttempt(.init(
                                  id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: ""
                              )) else { throw MCPFileToolAuthorityFailure.superseded }
                        let providerText = workflow?.wrapUserText(
                            message, includeBuiltInSessionCleanupGuidance: host.modelRouterSettingsStore.showBuiltInWorkflowCleanupGuidance()
                        ) ?? message
                        let outcome = await executor.persistAndStartNoncomposerTurn(
                            session: session, tabID: session.tabID, workspaceID: configured.identity.workspaceID,
                            claim: claim, displayText: message, providerMessage: providerText, workflow: workflow,
                            attribution: nil, stopFence: stopFence, directStartOptions: .init(autoEffortSelection: effort?.selection),
                            audit: effort.map { choice in { policy.auditForSubmittedTurn($0, session: session, autoEffort: choice.audit) } },
                            revalidateBeforeDispatch: {
                                try await requireCarrier()
                                try requirePendingStart()
                                if let acceptDurableInput {
                                    try await acceptDurableInput()
                                    try await requireCarrier()
                                    try requirePendingStart()
                                }
                                try scope.mcp.stageAgentRunOracleReviewSource(
                                    reviewSource, session: session, sessionID: sessionID,
                                    workspaceID: command.identity.workspaceID, expectedParentSessionID: source.source.identity.sessionID
                                )
                            }, dispatchIsCurrent: { (try? requirePendingStart()) != nil }
                        )
                        if case let .delivered(delivery) = outcome, delivery.deliveryState == .runStarted, let selection = effort?.selection {
                            policy.recordSubmittedAutoEffort(selection, for: session)
                        }
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
