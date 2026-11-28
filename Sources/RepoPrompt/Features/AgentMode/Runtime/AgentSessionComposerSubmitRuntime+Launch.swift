import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime

extension AgentSessionComposerSubmitRuntime {
    nonisolated static let staleTargetMessage = "This composer changed before the message could be sent. Please try again."

    struct CanonicalInputRequest {
        let row: AgentChatItem
        let message: String
        let providerTaggedFiles: [AgentTaggedFileAttachment]
        let restorationDraftText: String
        let followUpDraftText: String
        let steeringDraftText: String
        let workflow: AgentWorkflowDefinition?
        let workflowMutationGeneration: UInt64?
        let autoEffortSelection: AutoEffortTurnSelection?
        let routerAudit: AgentAutomationTurnAudit.Feature?
        let autoEffortAudit: AgentAutomationTurnAudit.Feature?
        let repromptAudit: AgentAutomationTurnAudit.Reprompt?
        let steeringMessage: String?
        let skipsSlashExpansion: Bool
        let registersLocalComposerOrigin: Bool
        let consumesPreparedAttachments: Bool
        let stopFence: AgentRunStartStopFence?
        let providerSwitchPreparation: AgentProviderSwitchSendPreparation?
    }

    enum CanonicalInputAdmission {
        case queued
        case refused(String)
    }

    /// Admission, transcript publication and queue ownership transfer happen on the original
    /// runtime without suspension. The desktop supplies composed content and observes refusal.
    func acceptCanonicalInput(
        _ request: CanonicalInputRequest, claim: AgentSessionComposerSubmitClaim, host: AgentSessionRuntimeHost,
        rejectedPresentation: ((String) -> Void)? = nil,
        afterAttachmentRestartStop: (@MainActor () async -> Void)? = nil,
        attachmentRestartFinished: (@MainActor () -> Void)? = nil
    ) -> CanonicalInputAdmission {
        let owner = claim.scope
        let stale = Self.staleTargetMessage
        guard owner.submissions === self, host.scope === owner, owner.executableHost === host,
              host.workspaceActivation?.isCurrent == true,
              let session = claim.cancellation.runTarget,
              dispatchCommand(for: claim, on: session) != nil,
              let links = owner.linkExecution,
              let stop = request.stopFence ?? claim.cancellation.pendingStartFence(for: session),
              stop.permitsStart(of: session) else { return .refused(stale) }
        if let failure = session.operationAdmissionFailureMessage { return .refused(failure) }
        if let preparation = request.providerSwitchPreparation,
           !links.providerSwitchPreparationIsCurrent(preparation, session: session)
        {
            return .refused(AgentSessionLinkSendFailure.providerHandoverNeedsReview.message)
        }
        let provider = session.selectedAgent
        let model = session.selectedModelRaw
        if session.runState.isActive, session.runState != .waitingForUser {
            owner.stream.flushPendingAssistantDelta(session)
        }
        links.agentSelfCompactCancelForAcceptedLocalInput(session)
        session.noteAcceptedTaskInput()
        var row = request.row
        row.sequenceIndex = session.nextSequenceIndex
        let handover = request.providerSwitchPreparation?.accepting(row.id, session: session)
        guard let accepted = publishCanonicalInput(
            row, claim: claim, host: host, registersLocalComposerOrigin: request.registersLocalComposerOrigin
        ) else { return .refused(stale) }
        let publication = accepted.publication
        let options = AgentDirectRunStartOptions(
            skipsSlashExpansion: request.skipsSlashExpansion, stopFence: stop,
            localComposerCandidate: accepted.localComposerCandidate, initialUserItemID: row.id,
            restorationDraftText: request.restorationDraftText
        )
        let turn = PreparedTurn(
            publication: publication, message: request.message, attachments: row.attachments,
            taggedFiles: row.taggedFileAttachments, providerTaggedFiles: request.providerTaggedFiles,
            userItemID: row.id, draftText: request.restorationDraftText, workflow: request.workflow,
            workflowMutationGeneration: request.workflowMutationGeneration, anchorRollback: accepted.anchorRollback,
            autoEffortSelection: request.autoEffortSelection, options: options, providerSwitchPreparation: handover
        )
        func refuse(_ message: String) -> CanonicalInputAdmission {
            let recovered = settleCanonicalRefusal(turn, claim: claim, message: message)
            session.settleLocalComposerOrigin(accepted.localComposerCandidate, disposition: recovered ? .rolledBack : .retained)
            return .refused(message)
        }
        guard publication.acceptedInputIndex != nil, publication.command.isCurrent,
              session.selectedAgent == provider, session.selectedModelRaw == model,
              host.workspaceActivation?.isCurrent == true, isCurrent(claim)
        else { return refuse(stale) }
        if request.consumesPreparedAttachments {
            if session.userWorkflowSelectionMutationGeneration == request.workflowMutationGeneration {
                session.selectedWorkflow = nil
            }
            let imageIDs = Set(row.attachments.map(\.id))
            let fileIDs = Set(row.taggedFileAttachments.map(\.id))
            session.pendingFileAttachments.removeAll { imageIDs.contains($0.id) }
            session.pendingTaggedFileAttachments.removeAll { fileIDs.contains($0.id) }
        }

        recordCanonicalInputAcceptance(request, row: row, session: session, host: host, links: links)
        guard publication.acceptedInputIndex != nil, publication.command.isCurrent,
              session.selectedAgent == provider, session.selectedModelRaw == model,
              host.workspaceActivation?.isCurrent == true, isCurrent(claim), stop.permitsStart(of: session)
        else { return refuse(stale) }

        let route = links.inputRouting(for: session, hasImages: !row.attachments.isEmpty).composer
        if session.selectedAgent != .codexExec {
            let providerText = AgentSessionProviderInputRuntime.renderProviderMessage(
                text: request.message, attachments: row.attachments, agent: session.selectedAgent
            )
            _ = owner.usage.nonCodexContextUsageEstimator(for: session.selectedAgent)?
                .enqueueUserTurnEstimate(messageForProvider: providerText, session: session)
        }
        switch route {
        case .codex, .start:
            switch submitCanonicalTurn(turn, claim: claim, host: host, rejectedPresentation: rejectedPresentation) {
            case .queued: return .queued
            case let .refused(recovered):
                session.settleLocalComposerOrigin(accepted.localComposerCandidate, disposition: recovered ? .rolledBack : .retained)
                return .refused(stale)
            }
        case .waitingInstruction:
            if session.selectedAgent != .codexExec { _ = owner.usage.dequeuePendingNonCodexUserTokens(for: session) }
            links.dispatchLocalWaitingInstruction(
                session: session, text: request.message, row: row, providerTaggedFiles: request.providerTaggedFiles,
                rollback: accepted.anchorRollback, draftText: request.restorationDraftText,
                workflow: request.workflow, workflowGeneration: request.workflowMutationGeneration,
                localComposerCandidate: accepted.localComposerCandidate, skipsSlashExpansion: request.skipsSlashExpansion,
                managedTurn: nil, rejectedPresentation: rejectedPresentation
            )
        case let .steer(steering):
            guard links.submitActiveProviderSteering(
                steering, session: session, wrappedText: request.message, attachmentsToSend: row.attachments,
                taggedFilesToSend: row.taggedFileAttachments, trimmedText: request.steeringDraftText,
                userItem: row, localComposerCandidate: accepted.localComposerCandidate,
                skipsSlashExpansion: request.skipsSlashExpansion, providerTaggedFiles: request.providerTaggedFiles
            ) else { return refuse(stale) }
        case .followUp:
            session.pendingInstructions.append(.init(
                providerText: request.message, localDraftText: request.followUpDraftText,
                stopFence: stop, skipsSlashExpansion: request.skipsSlashExpansion
            ))
            session.settleLocalComposerOrigin(accepted.localComposerCandidate, disposition: .retained)
        case .restartClaudeForImages:
            guard let service = owner.execution else { return refuse(stale) }
            claim.cancellation.admitProducer()
            links.retainInputEffect(session: session, owner: owner) { [self, host] in
                defer { claim.cancellation.releaseProducer() }
                defer { session.settleLocalComposerOrigin(accepted.localComposerCandidate, disposition: .retained) }
                defer { attachmentRestartFinished?() }
                @MainActor func refused() {
                    let message = "This scheduled run was cancelled by Stop."
                    if settleCanonicalRefusal(turn, claim: claim, message: message) { rejectedPresentation?(message) }
                }
                guard publication.command.isCurrent, stop.permitsStart(of: session) else { refused()
                    return
                }
                await service.cancelRun(tabID: session.tabID, session: session)
                await afterAttachmentRestartStop?()
                guard publication.command.isCurrent, session.persistentSessionBindingIdentity == stop.binding,
                      session.stopState.cancellationCount == stop.cancellationCount + 1
                else { refused()
                    return
                }
                var resumedOptions = options
                resumedOptions.stopFence = AgentRunStartStopFence(session: session)
                let outcome = await host.startCanonicalRequest(
                    command: publication.command, message: turn.message, attachments: turn.attachments,
                    taggedFileAttachments: turn.providerTaggedFiles, autoEffortSelection: turn.autoEffortSelection,
                    options: resumedOptions, outcome: nil, providerSwitchPreparation: handover
                )
                if case let .preDispatchRejected(message) = outcome,
                   settleCanonicalRefusal(turn, claim: claim, message: message)
                {
                    rejectedPresentation?(message)
                }
            }
        }
        return .queued
    }

    private func recordCanonicalInputAcceptance(
        _ request: CanonicalInputRequest, row: AgentChatItem, session: AgentTabSession,
        host: AgentSessionRuntimeHost, links: AgentSessionLinkExecutionRuntime
    ) {
        let owner = host.scope
        if let endpoint = links.agentSessionLinkObserverEndpoint(tabID: session.tabID) {
            session.observerWaitRelease = (session.runID, session.activeRunAttemptID, AgentSessionLinkRuntimeBridge.shared.acceptLocalInput(for: endpoint))
            links.cancelAgentSessionLinkAutoWake(for: endpoint, reason: .localUserWon)
        }
        let settings = host.modelRouterSettingsStore
        func defaultAudit(_ enabled: Bool) -> AgentAutomationTurnAudit.Feature {
            .init(configured: enabled, eligible: false, judgmentRequested: false, decision: enabled ? .ineligible : .disabled)
        }
        session.appendAutomationAudit(.init(
            turnID: row.id, createdAt: row.timestamp,
            router: request.routerAudit ?? defaultAudit(settings.modelRouterConfiguration().enabled),
            autoEffort: request.autoEffortAudit ?? defaultAudit(settings.autoEffortEnabled()),
            acceptedProviderRaw: session.selectedAgent.rawValue, acceptedModelRaw: session.selectedModelRaw,
            acceptedEffortRaw: session.selectedReasoningEffortRaw, reprompt: request.repromptAudit
        ))
        session.clearAgentSessionLinkWaitingOnAfterAcceptedTurn()
        owner.presentation.bindingChanged(session)
        owner.persistence.scheduleSave(for: session)
        links.wakeInputWaiters(
            session: session, message: request.steeringMessage,
            environment: host.canonicalInputEnvironment(for: session), isManaged: false
        )
        if session.mcpControlContext != nil, session.runState == .running, !session.isMCPInstructionDispatchInProgress,
           session.selectedAgent != .codexExec, links.inputRouting(for: session, hasImages: false).activeSteering == nil
        {
            owner.mcp.signalMCPInstructionDeliveredFireAndForget(for: session)
        }
    }

    /// The exact command and user input admitted to this publication. The transcript revision
    /// qualifies rollback. Forward dispatch checks the submitted row and the writer directly.
    @MainActor
    struct CanonicalPublication {
        let attemptID: UUID
        let command: AgentSessionRuntimeStore.Command
        let membership: AgentSessionRuntimeStore.Membership
        let item: AgentChatItem
        let expectedSourceRevision: Int
        let draftGeneration: UInt64
        let workflowGeneration: UInt64

        var acceptedInputIndex: Int? {
            let items = command.writer.session.items
            guard let index = items.firstIndex(where: { $0.id == item.id }), items[index] == item else { return nil }
            return index
        }
    }

    struct PublishedInput {
        let publication: CanonicalPublication
        let anchorRollback: AgentTurnUserAnchorRollbackState
        let localComposerCandidate: UUID?
    }

    /// Publish through the already admitted writer. Presentation supplies text and attachments;
    /// the originating session records its own row, anchor and local-input occurrence.
    private func publishCanonicalInput(
        _ item: AgentChatItem, claim: AgentSessionComposerSubmitClaim, host: AgentSessionRuntimeHost,
        registersLocalComposerOrigin: Bool
    ) -> PublishedInput? {
        guard let session = claim.cancellation.runTarget,
              let publication = captureCanonicalPublication(claim: claim, host: host, session: session, item: item) else { return nil }
        let anchorRollback = claim.scope.turnTiming.recordAgentTurnUserAnchor(for: session, userItem: item)
        session.appendItem(item)
        claim.cancellation.recordOptimisticInput(item.id, on: session)
        let localComposerCandidate: UUID? = if registersLocalComposerOrigin, publication.membership.isCurrent,
                                               let index = publication.acceptedInputIndex
        {
            session.registerLocalComposerCandidate(itemID: item.id, at: index)
        } else { nil }
        return .init(publication: publication, anchorRollback: anchorRollback, localComposerCandidate: localComposerCandidate)
    }

    private func captureCanonicalPublication(
        claim: AgentSessionComposerSubmitClaim, host: AgentSessionRuntimeHost,
        session: AgentTabSession, item: AgentChatItem
    ) -> CanonicalPublication? {
        let owner = claim.scope
        guard owner.submissions === self, host.scope === owner, owner.executableHost === host,
              host.workspaceActivation?.isCurrent == true,
              let command = dispatchCommand(for: claim, on: session),
              let membership = owner.membership(of: session), !session.items.contains(where: { $0.id == item.id })
        else { return nil }
        return .init(
            attemptID: claim.attempt.id,
            command: command,
            membership: membership,
            item: item,
            expectedSourceRevision: session.sourceItemsRevision &+ 1,
            draftGeneration: session.draftMutationGeneration,
            workflowGeneration: session.userWorkflowSelectionMutationGeneration
        )
    }

    /// An immutable submitted payload, not an admission or a second submission ledger.
    struct PreparedTurn {
        let publication: CanonicalPublication
        let message: String
        let attachments: [AgentFileAttachment]
        let taggedFiles: [AgentTaggedFileAttachment]
        let providerTaggedFiles: [AgentTaggedFileAttachment]
        let userItemID: UUID
        let draftText: String
        let workflow: AgentWorkflowDefinition?
        let workflowMutationGeneration: UInt64?
        let anchorRollback: AgentTurnUserAnchorRollbackState
        let autoEffortSelection: AutoEffortTurnSelection?
        let options: AgentDirectRunStartOptions
        let providerSwitchPreparation: AgentProviderSwitchSendPreparation?
    }

    /// Refusal recovery consumes only the original publication evidence, not fresh admission.
    /// A changed transcript/composer is retained instead of guessing which successor bytes to undo.
    @discardableResult
    private func rollbackCanonicalPublication(
        _ turn: PreparedTurn, claim: AgentSessionComposerSubmitClaim, message: String
    ) -> Bool {
        let owner = claim.scope
        let receipt = turn.publication
        let session = receipt.command.writer.session
        guard owner.submissions === self, receipt.command.writer.scope === owner, receipt.command.writer.ownsPersistentClaim,
              claim.attempt.id == receipt.attemptID,
              owner.membership(of: session)?.identity == receipt.membership.identity,
              turn.userItemID == receipt.item.id,
              session.sourceItemsRevision == receipt.expectedSourceRevision,
              session.items.contains(receipt.item),
              session.draftMutationGeneration == receipt.draftGeneration
              || (
                  session === claim.sourceSession && session.draftText.isEmpty
                      && session.draftMutationGeneration == claim.cancellation.ownedDraftClearGeneration
              ),
              session.userWorkflowSelectionMutationGeneration == receipt.workflowGeneration
        else { return false }
        // Preserve owed user data before row removal can synchronously notify a presenter.
        let originalDraftIsStillPresent = session.draftMutationGeneration == receipt.draftGeneration
            && session.draftText == turn.draftText
        let draft = claim.cancellation.didRestoreDraft || originalDraftIsStillPresent
            ? "" : (claim.cancellation.takeOwedDraftForRecovery() ?? turn.draftText)
        guard owner.drafts.restoreRejectedSubmission(
            session: session, draftText: draft,
            attachments: turn.attachments, taggedFiles: turn.taggedFiles,
            workflow: turn.workflow, workflowMutationGeneration: turn.workflowMutationGeneration, message: message
        ), owner.membership(of: session)?.identity == receipt.membership.identity,
        session.sourceItemsRevision == receipt.expectedSourceRevision,
        let index = session.items.firstIndex(of: receipt.item)
        else { return false }
        owner.turnTiming.rollbackAgentTurnUserAnchor(turn.anchorRollback, session: session)
        guard owner.membership(of: session)?.identity == receipt.membership.identity,
              session.sourceItemsRevision == receipt.expectedSourceRevision,
              session.items.indices.contains(index), session.items[index] == receipt.item,
              session.removeItem(at: index) != nil else { return false }
        guard owner.membership(of: session)?.identity == receipt.membership.identity else { return true }
        owner.presentation.requestUIRefresh(for: session, urgent: true)
        if owner.membership(of: session)?.identity == receipt.membership.identity { owner.persistence.scheduleSave(for: session) }
        return true
    }

    enum CanonicalSubmission {
        case queued(Task<CodexAgentModeCoordinator.NativeSendOutcome?, Never>)
        case refused(recovered: Bool)
    }

    /// Pin the existing claim, host and writer in the scheduling turn. The producer does not
    /// consult a presenter after the serial gate, and its cleanup cannot target a recycled tab.
    private func submitCanonicalTurn(
        _ turn: PreparedTurn, claim: AgentSessionComposerSubmitClaim, host: AgentSessionRuntimeHost,
        rejectedPresentation: ((String) -> Void)? = nil
    ) -> CanonicalSubmission {
        let owner = claim.scope
        let publication = turn.publication
        let command = publication.command
        let session = command.writer.session
        guard owner.submissions === self, host.scope === owner, owner.executableHost === host,
              host.workspaceActivation?.isCurrent == true, isCurrent(claim),
              let links = owner.linkExecution, command.writer.scope === owner, command.isCurrent,
              session.composerStartCancellation === claim.cancellation, publication.membership.isCurrent,
              claim.attempt.id == publication.attemptID, publication.acceptedInputIndex != nil,
              let stop = turn.options.stopFence ?? claim.cancellation.pendingStartFence(for: session),
              stop.permitsStart(of: session)
        else {
            let message = "The originating submission changed before provider dispatch."
            return .refused(recovered: settleCanonicalRefusal(turn, claim: claim, message: message))
        }
        let agent = session.selectedAgent
        let ticket = agent == .codexExec ? session.codexDispatchSerialGate.issueTicket() : nil
        let fallback = ticket.map { ticket in
            AgentTabSession.CodexFallbackSubmissionContext(
                queueID: UUID(), providerText: turn.message, attachments: turn.attachments,
                taggedFileAttachments: turn.taggedFiles, draftText: turn.draftText,
                optimisticUserItemID: turn.userItemID, origin: .manual, dispatchTicket: ticket,
                stopFence: stop, isLocalUserInput: true
            )
        }
        claim.cancellation.admitProducer()
        let task = links.retainInputEffect(session: session, owner: owner) { [self, host] () -> CodexAgentModeCoordinator.NativeSendOutcome? in
            defer { claim.cancellation.releaseProducer() }
            defer { session.settleLocalComposerOrigin(turn.options.localComposerCandidate, disposition: .retained) }
            if let ticket, await !session.codexDispatchSerialGate.awaitTurn(ticket) {
                let message = "The input queue stopped before sending this message."
                if settleCanonicalRefusal(turn, claim: claim, message: message) { rejectedPresentation?(message) }
                return .preDispatchRejected(message: message)
            }
            defer { if let ticket { session.codexDispatchSerialGate.finish(ticket) } }
            var options = turn.options
            options.stopFence = stop
            // The transient composer claim may have been released or replaced. The admitted input
            // carries its own exact writer, row, and Stop fence through the serial gate.
            let result: CodexAgentModeCoordinator.NativeSendOutcome? = if command.isCurrent,
                                                                          publication.membership.isCurrent,
                                                                          !claim.cancellation.isWithdrawn,
                                                                          session.selectedAgent == agent,
                                                                          stop.permitsStart(of: session), !Task.isCancelled
            {
                await host.startCanonicalRequest(
                    command: command, message: turn.message, attachments: turn.attachments,
                    taggedFileAttachments: turn.providerTaggedFiles, codexFallbackContext: fallback,
                    autoEffortSelection: turn.autoEffortSelection, options: options, outcome: nil,
                    providerSwitchPreparation: turn.providerSwitchPreparation
                )
            } else {
                .preDispatchRejected(message: "The originating session changed before provider dispatch.")
            }
            switch result {
            case let .preDispatchRejected(message):
                if settleCanonicalRefusal(turn, claim: claim, message: message) { rejectedPresentation?(message) }
            case .failed, .cancelled, .stale:
                if agent == .codexExec {
                    recordInputDiagnostic(
                        publication,
                        outcome: "deliveryUncertain",
                        message: "The provider did not confirm delivery of this message. Review it before resending."
                    )
                }
            case .sent, .queuedFallback:
                if publication.membership.isCurrent { session.deferredActiveAgentRunTimerRollback = nil }
            case nil:
                break
            }
            return result
        }
        return .queued(task)
    }

    private func settleCanonicalRefusal(
        _ turn: PreparedTurn, claim: AgentSessionComposerSubmitClaim, message: String
    ) -> Bool {
        if rollbackCanonicalPublication(turn, claim: claim, message: message) { return true }
        recordInputDiagnostic(turn.publication, outcome: "notDispatched", message: message)
        return false
    }

    private func recordInputDiagnostic(_ publication: CanonicalPublication, outcome: String, message: String) {
        let writer = publication.command.writer
        let session = writer.session
        guard writer.ownsPersistentClaim, publication.membership.isCurrent,
              session.items.contains(where: { $0.id == publication.item.id }) else { return }
        let text = "Message \(publication.item.sequenceIndex + 1). \(message)"
        session.appendItem(.system(text, sequenceIndex: session.nextSequenceIndex, recoveryDiagnostic: .init(
            reason: "agentInput", outcome: outcome, text: text
        )))
        session.isDirty = true
        writer.scope.presentation.requestUIRefresh(for: session, urgent: true)
        writer.scope.persistence.scheduleSave(for: session)
    }

    #if DEBUG
        func test_captureCanonicalPublication(
            claim: AgentSessionComposerSubmitClaim, host: AgentSessionRuntimeHost,
            session: AgentTabSession, item: AgentChatItem
        ) -> CanonicalPublication? {
            captureCanonicalPublication(claim: claim, host: host, session: session, item: item)
        }

        func test_submitCanonicalTurn(
            _ turn: PreparedTurn, claim: AgentSessionComposerSubmitClaim, host: AgentSessionRuntimeHost
        ) -> CanonicalSubmission {
            submitCanonicalTurn(turn, claim: claim, host: host)
        }

        func test_rollbackCanonicalPublication(
            _ turn: PreparedTurn, claim: AgentSessionComposerSubmitClaim, message: String
        ) -> Bool {
            rollbackCanonicalPublication(turn, claim: claim, message: message)
        }
    #endif
}
