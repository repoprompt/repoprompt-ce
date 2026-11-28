import Foundation

extension AgentSessionComposerSubmitRuntime {
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
    func publishCanonicalInput(
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

    func captureCanonicalPublication(
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
    func rollbackCanonicalPublication(
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
    func submitCanonicalTurn(
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
}
