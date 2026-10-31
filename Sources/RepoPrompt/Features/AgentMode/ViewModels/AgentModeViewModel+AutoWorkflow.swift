import Foundation

extension AgentModeViewModel {
    /// Submission-local advice. Never installed as the user's manual picker selection.
    struct AutoWorkflowTurnSelection {
        let workflow: AgentWorkflowDefinition
        let sessionIdentity: ObjectIdentifier
        let workflowMutationGeneration: UInt64
        let configuration: AutoWorkflowConfiguration
        let catalog: [AgentWorkflowDefinition]
    }

    func autoWorkflowIsEligible(session: TabSession, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("/") && autoWorkflowSessionIsInitial(session)
    }

    private func autoWorkflowSessionIsInitial(_ session: TabSession) -> Bool {
        // Empty/unhydrated saved transcripts are not evidence of a new session. Require
        // current fresh-creation provenance as well as the actual provider/turn state.
        guard let record = transcriptPresentationRecordsByTabID[session.tabID],
              record.origin == .fresh,
              record.scope.sessionIdentity == ObjectIdentifier(session),
              record.scope.binding == session.persistentSessionBindingIdentity,
              record.scope.bindingTransitionGeneration == session.bindingTransitionGeneration,
              session.hasLoadedPersistedState,
              session.providerSessionID == nil,
              session.codexConversationID == nil,
              session.mcpControlContext == nil,
              !session.isMCPOriginated,
              session.parentSessionID == nil,
              !session.pendingHandoff.hasPayload,
              !session.runState.isActive,
              !session.hasSentFirstMessage,
              session.runID == nil,
              session.activeRunAttemptID == nil,
              session.items.isEmpty,
              session.transcript.turns.isEmpty
        else { return false }
        return true
    }

    func autoWorkflowCatalog() -> [AgentWorkflowDefinition] {
        #if DEBUG
            if let catalog = test_autoWorkflowCatalog { return catalog }
        #endif
        let store = AgentWorkflowStore.shared
        return store.visibleBuiltInWorkflows + store.customWorkflows.sorted {
            $0.displayName == $1.displayName ? $0.id < $1.id : $0.displayName < $1.displayName
        }
    }

    /// Manual choices (including edits made while a judgment was pending) always win.
    func effectiveWorkflow(session: TabSession, autoWorkflow: AutoWorkflowTurnSelection?) -> AgentWorkflowDefinition? {
        if let manual = session.selectedWorkflow { return manual }
        guard let selection = autoWorkflow,
              selection.sessionIdentity == ObjectIdentifier(session),
              selection.workflowMutationGeneration == session.userWorkflowSelectionMutationGeneration,
              selection.configuration == modelRouterSettingsStore.autoWorkflowConfiguration(),
              selection.configuration.enabled,
              selection.catalog == autoWorkflowCatalog(),
              autoWorkflowSessionIsInitial(session)
        else { return nil }
        return selection.workflow
    }

    func chooseAutoWorkflow(
        text: String,
        claim: AgentComposerSubmitClaim,
        session: TabSession
    ) async -> AutoWorkflowTurnSelection? {
        let configuration = modelRouterSettingsStore.autoWorkflowConfiguration()
        guard !Task.isCancelled, configuration.enabled,
              composerSubmitClaimIsCurrent(claim),
              session.selectedWorkflow == nil,
              autoWorkflowIsEligible(session: session, text: text),
              let excerpt = AutoEffortTaskSummary.make(from: AgentTaskRoutingTaskExcerpt.make(from: text)),
              let runtime = modelRouterRuntime,
              let backendID = configuration.selectedBackendID,
              runtime.isBackendReady(backendID)
        else { return nil }
        let catalog = autoWorkflowCatalog()
        guard !catalog.isEmpty else { return nil }
        let generation = session.userWorkflowSelectionMutationGeneration
        guard let registration = await runtime.registry.registration(for: backendID),
              !Task.isCancelled, composerSubmitClaimIsCurrent(claim),
              sessions[session.tabID] === session,
              session.selectedWorkflow == nil,
              session.userWorkflowSelectionMutationGeneration == generation,
              configuration == modelRouterSettingsStore.autoWorkflowConfiguration(),
              let prepared = try? AutoWorkflowDecisionPolicy().build(
                  requestID: UUID(), maskedTaskExcerpt: excerpt, workflows: catalog,
                  capabilities: registration.capabilities
              )
        else { return nil }
        // Own a cancellable task before suspending. A fresh UUID keeps this reservation
        // independent from Model Router and its reprompt speculation/retry IDs.
        let task = Task {
            await runtime.coordinator.decide(
                serviceID: backendID, request: prepared.request, consumerRevision: configuration.revision
            )
        }
        autoWorkflowJudgments[claim.attempt.id] = task
        ui.composer.pendingSubmissions[claim.attempt.id]?.isChoosingWorkflow = true
        defer {
            autoWorkflowJudgments[claim.attempt.id] = nil
            ui.composer.pendingSubmissions[claim.attempt.id]?.isChoosingWorkflow = false
        }
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled,
              composerSubmitClaimIsCurrent(claim),
              sessions[session.tabID] === session,
              autoWorkflowIsEligible(session: session, text: text),
              case let .workflow(workflow)? = prepared.selection(for: outcome)
        else { return nil }
        let selection = AutoWorkflowTurnSelection(
            workflow: workflow, sessionIdentity: ObjectIdentifier(session),
            workflowMutationGeneration: generation, configuration: configuration, catalog: catalog
        )
        return effectiveWorkflow(session: session, autoWorkflow: selection) == workflow ? selection : nil
    }
}
