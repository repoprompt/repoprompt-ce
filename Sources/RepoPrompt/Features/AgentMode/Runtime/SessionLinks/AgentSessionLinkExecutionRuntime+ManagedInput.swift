import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptSettingsCore

extension AgentSessionLinkExecutionRuntime {
    /// Managed input deliberately has no draft, attachment, interview or local workflow access.
    func agentSessionLinkManagedSteerRoute(for session: TabSession) -> AgentSessionLinkManagedSteerRoute? {
        if session.runState == .waitingForUser, session.instructionContinuation != nil { return .waitingInstruction }
        guard session.runState.isActive else { return nil }
        if session.selectedAgent == .codexExec { return .codex }
        guard session.runState == .running, session.pendingApproval == nil else { return nil }
        if session.selectedAgent.acpProviderID != nil,
           session.pendingAskUser == nil, session.pendingUserInputRequest == nil,
           session.pendingPermissionsRequest == nil, session.runID != nil,
           session.activeRunAttemptID != nil, session.acpController != nil { return .acpQueued }
        return session.selectedAgent.usesClaudeNativeRuntime ? .claudeInterrupt : nil
    }

    @discardableResult
    func submitAgentSessionLinkManagedSteer(
        tabID: UUID, session: TabSession, displayText: String,
        turn: AgentSessionLinkManagedTurn, route: AgentSessionLinkManagedSteerRoute,
        environment: ManagedInputEnvironment
    ) -> Bool {
        submitNoncomposerSteer(
            tabID: tabID, session: session, displayText: displayText,
            turn: AgentNoncomposerTurn(managed: turn), route: route, environment: environment
        )
    }

    @discardableResult
    func submitNoncomposerSteer(
        tabID: UUID, session: TabSession, displayText: String, turn: AgentNoncomposerTurn,
        route: AgentSessionLinkManagedSteerRoute, workflow: AgentWorkflowDefinition? = nil,
        environment: ManagedInputEnvironment
    ) -> Bool {
        guard let owner = scope, let command = admit(endpoint: turn.endpoint), command.isCurrent,
              owner.sessions[tabID] === session, command.writer.session === session,
              environment.workspaceID == command.identity.workspaceID,
              environment.resourcesAreCurrent(), commands.workspaceID(session) == environment.workspaceID,
              session.operationAdmissionFailureMessage == nil,
              agentSessionLinkManagedSteerRoute(for: session) == route,
              (route != .claudeInterrupt && route != .acpQueued) || owner.execution != nil else { return false }
        guard let receipt = AgentSessionRuntimeStore.WriterReceipt(command) else { return false }
        let resourcesAreCurrent = environment.resourcesAreCurrent
        let inputAdmission = AgentSessionProviderInputRuntime.Admission(isCurrent: { [weak session] in
            guard let session else { return false }
            return receipt.disposition(for: session) == .current && resourcesAreCurrent()
        }, ownsCleanup: { [weak session] in
            guard let session else { return false }
            return receipt.disposition(for: session) != .claimLost
        })
        let wrapped = workflow?.wrapUserText(
            session.isCodexComputerUseArmed
                ? CodexComputerUseWorkflow.renderProviderPrompt(userInstructions: turn.providerText) : turn.providerText,
            includeBuiltInSessionCleanupGuidance: environment.settings.showBuiltInWorkflowCleanupGuidance()
        ) ?? (
            session.isCodexComputerUseArmed
                ? CodexComputerUseWorkflow.renderProviderPrompt(userInstructions: turn.providerText) : turn.providerText
        )
        if session.runState != .waitingForUser { owner.stream.flushPendingAssistantDelta(session) }
        cancelSelfCompactForAcceptedInput(session)
        session.noteAcceptedTaskInput()
        let row = AgentChatItem.user(
            displayText, sequenceIndex: session.nextSequenceIndex, workflow: workflow,
            crossSessionAttribution: turn.attribution, dispatchedProviderText: wrapped
        )
        let rollback = owner.turnTiming.recordAgentTurnUserAnchor(for: session, userItem: row)
        session.appendItem(row)
        turn.sink.noteAppended(itemID: row.id)
        let router = environment.settings.modelRouterConfiguration().enabled
        let effort = environment.settings.autoEffortEnabled()
        session.appendAutomationAudit(.init(
            turnID: row.id, createdAt: row.timestamp,
            router: .init(configured: router, eligible: false, judgmentRequested: false, decision: router ? .ineligible : .disabled),
            autoEffort: .init(configured: effort, eligible: false, judgmentRequested: false, decision: effort ? .ineligible : .disabled),
            acceptedProviderRaw: session.selectedAgent.rawValue, acceptedModelRaw: session.selectedModelRaw,
            acceptedEffortRaw: session.selectedReasoningEffortRaw
        ))
        session.clearAgentSessionLinkWaitingOnAfterAcceptedTurn()
        cancelAgentSessionLinkAutoWake(for: turn.endpoint, reason: .localUserWon)
        owner.presentation.bindingChanged(session)
        owner.persistence.scheduleSave(for: session)
        wakeManagedInputWaiters(session: session, message: displayText, environment: environment)

        if session.selectedAgent != .codexExec {
            let preview = AgentSessionProviderInputRuntime.renderProviderMessage(text: wrapped, attachments: [], agent: session.selectedAgent)
            _ = owner.usage.nonCodexContextUsageEstimator(for: session.selectedAgent)?
                .enqueueUserTurnEstimate(messageForProvider: preview, session: session)
            if route == .waitingInstruction { _ = owner.usage.dequeuePendingNonCodexUserTokens(for: session) }
        }
        switch route {
        case .waitingInstruction:
            dispatchManagedWaitingInstruction(
                command: command,
                session: session,
                text: wrapped,
                row: row,
                rollback: rollback,
                turn: turn,
                environment: environment
            )
        case .codex:
            dispatchManagedCodex(
                command: command,
                session: session,
                text: wrapped,
                row: row,
                rollback: rollback,
                turn: turn,
                environment: environment
            )
        case .claudeInterrupt:
            guard let service = owner.execution else { preconditionFailure("Admission requires an execution service") }
            if !owner.startup.queueClaudeSteering(
                session: session, service: service, wrappedText: wrapped, attachments: [], taggedFiles: [],
                draftText: "", userItem: row, localComposerCandidate: nil, skipsSlashExpansion: false,
                accepted: { turn.sink.resolve(.delivered(.queuedInterrupt)) },
                inputAdmission: inputAdmission
            ) { withdrawManagedInput(command: command, session: session, row: row, rollback: rollback, turn: turn) }
        case .acpQueued:
            guard let service = owner.execution else { preconditionFailure("Admission requires an execution service") }
            let steering = TabSession.ACPSteeringInstruction(
                id: UUID(), targetRunID: session.runID, targetRunAttemptID: session.activeRunAttemptID,
                providerText: wrapped, interruptedPromptProviderText: Self.interruptedACPProviderText(for: session, before: row),
                attachments: [], taggedFileAttachments: [], draftText: "", optimisticUserItemID: row.id,
                createdAt: Date(), managed: .init(
                    sink: turn.sink,
                    attributedItemID: row.id,
                    endpoint: turn.endpoint,
                    attribution: turn.attribution
                ),
                runtimeInputAdmission: inputAdmission
            )
            session.pendingACPSteeringInstructions.append(steering)
            if !session.isMCPInstructionDispatchInProgress {
                let stopFence = AgentRunStartStopFence(session: session)
                retainManagedInputEffect(session: session, owner: owner) {
                    guard command.isCurrent, environment.resourcesAreCurrent(), stopFence.permitsStart(of: session) else {
                        service.withdrawQueuedManagedACPSteering(id: steering.id, session: session, stopFence: stopFence)
                        return
                    }
                    let accepted = await service.submitQueuedACPSteeringIfSupported(session: session)
                    guard stopFence.permitsStart(of: session), !accepted else { return }
                    service.settleRejectedACPSteeringSubmission(id: steering.id, session: session, stopFence: stopFence)
                }
            }
        }
        return true
    }

    private func cancelSelfCompactForAcceptedInput(_ session: TabSession) {
        guard session.selfCompactState.active != nil else { return }
        if let phase = session.selfCompactState.active?.phase,
           phase == .scheduled || phase == .compactDispatchPending
        {
            session.selfCompactState.settle(.cancelled, noteDelivery: .notSent, completionVerified: false)
            session.appendItem(.selfCompactionCancelled(sequenceIndex: session.nextSequenceIndex))
        }
        session.selfCompactNativeCompletion?.supersedeForOrdinaryInput()
    }

    static func interruptedACPProviderText(for session: TabSession, before row: AgentChatItem) -> String? {
        guard let prior = session.items.last(where: { $0.kind == .user && $0.sequenceIndex < row.sequenceIndex }) else { return nil }
        if let dispatched = prior.dispatchedProviderText { return dispatched }
        guard prior.crossSessionAttribution == nil else { return nil }
        let text = AgentSessionProviderInputRuntime.renderProviderMessage(text: prior.text, attachments: prior.attachments, agent: session.selectedAgent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func retainManagedInputEffect(
        session: TabSession, owner: AgentSessionRuntimeStore.Scope, operation: @escaping @MainActor () async -> Void
    ) {
        let id = UUID()
        let task = Task { @MainActor [self, owner] in
            defer { pendingManagedInputEffects.removeValue(forKey: id)
                withExtendedLifetime(owner) {}
            }
            await operation()
        }
        pendingManagedInputEffects[id] = PendingSendEffect(sessionIdentity: ObjectIdentifier(session), task: task)
    }

    /// Separate from terminal-save effects: provider submission can itself await terminal work.
    func drainPendingManagedInputEffects(for session: TabSession? = nil) async {
        let identity = session.map(ObjectIdentifier.init)
        while let effect = pendingManagedInputEffects.values.first(where: { identity == nil || $0.sessionIdentity == identity }) {
            await effect.task.value
        }
    }

    private func withdrawManagedInput(
        command: AgentSessionRuntimeStore.Command, session: TabSession, row: AgentChatItem,
        rollback: AgentTurnUserAnchorRollbackState, turn: AgentNoncomposerTurn
    ) {
        // Originating cleanup may proceed under suspension, but never on a successor binding.
        guard command.writer.ownsPersistentClaim else {
            turn.sink.resolve(.unconfirmed(message: "The originating writer changed before input settlement."))
            return
        }
        if let index = session.items.firstIndex(where: { $0.id == row.id }) { _ = session.removeItem(at: index) }
        command.writer.scope.turnTiming.rollbackAgentTurnUserAnchor(rollback, session: session)
        command.writer.scope.presentation.bindingChanged(session)
        command.writer.scope.persistence.scheduleSave(for: session)
        requestUIRefresh(tabID: session.tabID, urgent: true)
        turn.sink.resolve(.notAccepted(message: "The session changed before the steer reached the provider."))
    }

    private func dispatchManagedCodex(
        command: AgentSessionRuntimeStore.Command, session: TabSession, text: String, row: AgentChatItem,
        rollback: AgentTurnUserAnchorRollbackState, turn: AgentNoncomposerTurn, environment: ManagedInputEnvironment
    ) {
        let owner = command.writer.scope
        let attemptID = session.codexSteerAckTracker.beginAttempt()
        let ticket = session.codexDispatchSerialGate.issueTicket()
        let stopFence = AgentRunStartStopFence(session: session)
        let ownership = session.activeRunOwnership
        let controllerID = session.codexController.map(ObjectIdentifier.init)
        let receipt = AgentSessionRuntimeStore.WriterReceipt(command)
        session.codexSteerAckTracker.authorizeDispatch(attemptID: attemptID)
        retainManagedInputEffect(session: session, owner: owner) { [self] in
            guard await session.codexSteerAckTracker.awaitDispatchAuthorization(attemptID: attemptID) else {
                session.codexDispatchSerialGate.cancel(ticket)
                withdrawManagedInput(command: command, session: session, row: row, rollback: rollback, turn: turn)
                return
            }
            guard await session.codexDispatchSerialGate.awaitTurn(ticket) else {
                session.codexSteerAckTracker.resolve(attemptID: attemptID, state: .cancelled)
                withdrawManagedInput(command: command, session: session, row: row, rollback: rollback, turn: turn)
                return
            }
            defer { session.codexDispatchSerialGate.finish(ticket) }
            @MainActor func isCurrent() -> Bool {
                command.isCurrent && environment.resourcesAreCurrent() && stopFence.permitsStart(of: session)
                    && agentSessionLinkObserverEndpoint(tabID: session.tabID) == turn.endpoint
                    && session.runState.isActive && session.activeRunOwnership == ownership
                    && session.codexController.map(ObjectIdentifier.init) == controllerID
            }
            var failures: [AgentSessionProviderInputRuntime.ExplicitFileFailure] = []
            let augmented = await commands.input.augmentUserMessage(
                text, attachments: [], taggedFileAttachments: [], agent: session.selectedAgent,
                workspacePaths: commands.workspacePaths(), workspace: { self.commands.inputWorkspace(session) },
                session: session, handoff: owner.handoff, ignoresPendingHandoff: false,
                skipsSlashExpansion: false, isCurrent: isCurrent, onTaggedFileFailures: { failures = $0 }
            )
            let fallback = TabSession.CodexFallbackSubmissionContext(
                queueID: UUID(), providerText: augmented, attachments: [], taggedFileAttachments: [], draftText: "",
                optimisticUserItemID: row.id, origin: .mcp(attemptID: attemptID), dispatchTicket: ticket,
                stopFence: stopFence, isLocalUserInput: false
            )
            var inputWasAttempted = false
            let outcome: CodexAgentModeCoordinator.NativeSendOutcome
            if isCurrent(), let receipt, let ownership, let coordinator = codexCoordinator {
                AgentSessionProviderInputRuntime.recordTaggedFileFailures(failures, session: session, scope: owner)
                outcome = await coordinator.sendCodexNativeMessage(
                    session: session, writerReceipt: receipt, ownership: ownership, text: augmented,
                    attachments: [], fallbackContext: fallback, stopFence: stopFence, terminalizeRejectedSend: false,
                    // Carry the admitted command through native route/read-proof awaits. Resource
                    // currency alone can survive same-object writer claim reacquisition.
                    inputResourcesAreCurrent: isCurrent,
                    inputAttemptChanged: { inputWasAttempted = $0 }
                )
            } else { outcome = .preDispatchRejected(message: "The originating Codex writer or attempt changed before dispatch.") }
            if !outcome.didSend, !inputWasAttempted {
                withdrawManagedInput(command: command, session: session, row: row, rollback: rollback, turn: turn)
            } else { session.deferredActiveAgentRunTimerRollback = nil }
            let state: CodexSteerAckTracker.TerminalState = switch outcome {
            case .sent: .steerAccepted
            case let .queuedFallback(id, _): .durablyQueued(queueID: id)
            case let .preDispatchRejected(message), let .failed(message): .failed(message: message)
            case let .stale(reason): .stale(reason: reason)
            case .cancelled: .cancelled
            }
            session.codexSteerAckTracker.resolve(attemptID: attemptID, state: state)
            let terminal = await session.codexSteerAckTracker.awaitTerminalState(attemptID: attemptID)
            if inputWasAttempted, !outcome.didSend {
                turn.sink.resolve(.unconfirmed(message: "The Codex input was attempted, but its acceptance is unconfirmed. Read the session before retrying."))
            } else { turn.sink.resolve(Self.agentSessionLinkManagedSteerOutcome(for: terminal)) }
        }
    }

    static func agentSessionLinkManagedSteerOutcome(for state: CodexSteerAckTracker.TerminalState) -> AgentSessionLinkManagedSteerOutcome {
        switch state {
        case .steerAccepted, .controlAccepted: .delivered(.steered)
        case .startAccepted: .delivered(.runStarted)
        case .durablyQueued: .delivered(.queuedFollowUp)
        case let .failed(message): .notAccepted(message: message)
        case .cancelled: .notAccepted(message: "Codex cancelled the steer before it reached the session.")
        case let .stale(reason): .notAccepted(message: reason)
        case .timedOut: .unconfirmed(message: "Codex did not confirm the steer in time.")
        }
    }

    private func dispatchManagedWaitingInstruction(
        command: AgentSessionRuntimeStore.Command, session: TabSession, text: String, row: AgentChatItem,
        rollback: AgentTurnUserAnchorRollbackState, turn: AgentNoncomposerTurn, environment: ManagedInputEnvironment
    ) {
        let owner = command.writer.scope
        let ownership = session.activeRunOwnership
        let waitID = session.instructionWaitID
        let instruction = instructionCommand(for: session)
        let controllerID = session.codexController.map(ObjectIdentifier.init)
        let dispatchID = AgentSessionLinkPromptDispatchID.waitingContinuation(waitID: waitID ?? session.tabID)
        let ticket = session.codexDispatchSerialGate.issueTicket()
        retainManagedInputEffect(session: session, owner: owner) { [self] in
            guard await session.codexDispatchSerialGate.awaitTurn(ticket) else {
                turn.sink.resolve(.unconfirmed(message: "The waiting instruction stopped dispatching."))
                return
            }
            defer { session.codexDispatchSerialGate.finish(ticket) }
            @MainActor func isCurrent() -> Bool {
                guard let instruction, let waitID else { return false }
                return command.isCurrent && environment.resourcesAreCurrent()
                    && ownsInstructionWait(command: instruction, waitID: waitID)
                    && (
                        ownership.map { session.isCurrentRunAttemptForCurrentBinding($0) && session.quietLedger.isOpen(owner: $0) }
                            ?? (session.activeRunOwnership == nil)
                    )
                    && session.instructionContinuation != nil && session.instructionWaitID == waitID
                    && session.codexController.map(ObjectIdentifier.init) == controllerID
            }
            var ownsDispatchClaim = false
            @MainActor func reject() {
                if ownsDispatchClaim { agentSessionLinkRecordPhysicalDispatchNotAttempted(for: session, dispatchID: dispatchID) }
                withdrawManagedInput(command: command, session: session, row: row, rollback: rollback, turn: turn)
            }
            guard isCurrent() else { reject()
                return
            }
            var failures: [AgentSessionProviderInputRuntime.ExplicitFileFailure] = []
            let augmented = await commands.input.augmentUserMessage(
                text, attachments: [], taggedFileAttachments: [], agent: session.selectedAgent,
                workspacePaths: commands.workspacePaths(), workspace: { self.commands.inputWorkspace(session) },
                session: session, handoff: owner.handoff, ignoresPendingHandoff: false,
                skipsSlashExpansion: false, isCurrent: isCurrent, onTaggedFileFailures: { failures = $0 }
            )
            guard isCurrent() else { reject()
                return
            }
            let readiness = await qualifyProviderInputRoute(for: session)
            guard readiness.allowsDispatch, isCurrent(),
                  agentSessionLinkHasCurrentProviderInputRoute(for: session, qualification: readiness)
            else { reject()
                return
            }
            let monitoring = agentSessionLinkDecoratedProviderText(augmented, session: session, dispatchID: dispatchID)
            ownsDispatchClaim = monitoring.claim != nil
            guard !monitoring.mustAbortDispatch else { reject()
                return
            }
            let proof = await agentSessionLinkProveProviderInput(for: session, claim: monitoring.claim)
            guard isCurrent(), !Task.isCancelled,
                  agentSessionLinkHasCurrentProviderInputRoute(for: session, qualification: readiness),
                  let instruction, let waitID,
                  resumeWaitingInstructionContinuation(
                      command: instruction,
                      waitID: waitID,
                      providerText: monitoring.text,
                      claim: monitoring.claim,
                      origin: .user,
                      inputProof: proof,
                      undecoratedProviderText: augmented
                  )
            else { reject()
                return
            }
            AgentSessionProviderInputRuntime.recordTaggedFileFailures(failures, session: session, scope: owner)
            session.deferredActiveAgentRunTimerRollback = nil
            turn.sink.resolve(.delivered(.deliveredToWaitingInstruction))
        }
    }

    private func wakeManagedInputWaiters(session: TabSession, message: String, environment: ManagedInputEnvironment) {
        guard session.runState == .running, !session.isMCPInstructionDispatchInProgress, let owner = scope else { return }
        let runID = session.runID
        let attemptID = session.activeRunAttemptID
        let currentOrigin: @MainActor () -> UUID? = { [weak session, weak owner] in
            guard let session, owner?.sessions[session.tabID] === session,
                  session.runState.isActive, session.runID == runID, session.activeRunAttemptID == attemptID else { return nil }
            return runID
        }
        if let runID, let server = environment.server,
           session.selectedAgent != .codexExec || codexCoordinator?.isCodexCompactionInFlight(session: session) == true
        {
            retainManagedInputEffect(session: session, owner: owner) {
                await server.wakeAgentRunWaitersOwnedByActiveRun(
                    runID: runID, source: "managed-active-submit-parent-run", steeringMessage: message,
                    steeringOriginRunID: currentOrigin,
                    publicationForSessionID: { id in
                        guard let cursor = owner.mcp.waitCursor(sessionID: id),
                              let target = owner.mcp.controlRead(sessionID: id).session,
                              let snapshot = owner.mcp.mcpReadSnapshot(for: target) else { return nil }
                        return (snapshot, cursor)
                    }
                )
            }
        }
        if let (snapshot, context) = owner.mcp.currentSteeringSnapshot(for: session, operation: "managed steer") {
            retainManagedInputEffect(session: session, owner: owner) {
                guard owner.mcp.mcpControlContextMatches(
                    tabID: session.tabID,
                    sessionID: snapshot.sessionID,
                    activationID: context.activationID,
                    registration: context.registration
                ) else { return }
                await AgentRunSessionStore.wakeCurrentWaiters(
                    snapshot, cursor: .init(registration: context.registration, epoch: context.currentEpoch),
                    reason: .steeringRequested, steeringMessage: message, steeringOriginRunID: currentOrigin()
                )
            }
        }
    }
}
