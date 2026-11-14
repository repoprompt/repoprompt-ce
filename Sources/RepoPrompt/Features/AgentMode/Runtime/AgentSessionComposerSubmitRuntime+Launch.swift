import Foundation

extension AgentSessionComposerSubmitRuntime {
    /// Original publication evidence only. It cannot admit a command after revocation.
    struct PublicationCleanup {
        let attemptID: UUID
        let membership: AgentSessionRuntimeStore.Membership
        let item: AgentChatItem
        let expectedSourceRevision: Int
        let draftGeneration: UInt64
        let workflowGeneration: UInt64
    }

    func captureCanonicalPublication(
        claim: AgentSessionComposerSubmitClaim, host: AgentSessionRuntimeHost, item: AgentChatItem
    ) -> PublicationCleanup? {
        let owner = claim.scope
        let session = claim.sourceSession
        guard owner.submissions === self, host.scope === owner, owner.executableHost === host,
              host.workspaceActivation?.isCurrent == true, isCurrent(claim),
              let command = claim.command, command.writer.scope === owner,
              command.writer.session === session, command.isCurrent,
              let membership = owner.membership(of: session), !session.items.contains(where: { $0.id == item.id })
        else { return nil }
        return .init(
            attemptID: claim.attempt.id,
            membership: membership,
            item: item,
            expectedSourceRevision: session.sourceItemsRevision &+ 1,
            draftGeneration: session.draftMutationGeneration,
            workflowGeneration: session.userWorkflowSelectionMutationGeneration
        )
    }

    /// An immutable submitted payload, not an admission or a second submission ledger.
    struct PreparedTurn {
        let publication: PublicationCleanup
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
        let session = claim.sourceSession
        let receipt = turn.publication
        guard owner.submissions === self, claim.attempt.id == receipt.attemptID,
              owner.membership(of: session)?.identity == receipt.membership.identity,
              turn.userItemID == receipt.item.id,
              session.sourceItemsRevision == receipt.expectedSourceRevision,
              session.items.contains(receipt.item),
              session.draftMutationGeneration == receipt.draftGeneration
              || (session.draftText.isEmpty && session.draftMutationGeneration == claim.cancellation.ownedDraftClearGeneration),
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
        let session = claim.sourceSession
        guard owner.submissions === self, host.scope === owner, owner.executableHost === host,
              host.workspaceActivation?.isCurrent == true, isCurrent(claim),
              let command = claim.command, command.writer.session === session,
              command.writer.scope === owner, command.isCurrent,
              let membership = owner.membership(of: session), membership.identity == turn.publication.membership.identity,
              claim.attempt.id == turn.publication.attemptID,
              session.sourceItemsRevision == turn.publication.expectedSourceRevision,
              session.items.contains(turn.publication.item)
        else {
            return .refused(recovered: rollbackCanonicalPublication(
                turn, claim: claim, message: "The originating submission changed before provider dispatch."
            ))
        }
        let agent = session.selectedAgent
        let stop = turn.options.stopFence ?? claim.cancellation.pendingStartFence(for: session)
            ?? AgentRunStartStopFence(session: session)
        let ticket = agent == .codexExec ? session.codexDispatchSerialGate.issueTicket() : nil
        let fallback = ticket.map { ticket in
            AgentTabSession.CodexFallbackSubmissionContext(
                queueID: UUID(), providerText: turn.message, attachments: turn.attachments,
                taggedFileAttachments: turn.taggedFiles, draftText: turn.draftText,
                optimisticUserItemID: turn.userItemID, origin: .manual, dispatchTicket: ticket,
                stopFence: stop, isLocalUserInput: true
            )
        }
        claim.cancellation.retainProducer()
        return .queued(Task { [self, host] in
            defer { claim.cancellation.releaseProducer() }
            defer { session.settleLocalComposerOrigin(turn.options.localComposerCandidate, disposition: .retained) }
            if let ticket {
                guard await session.codexDispatchSerialGate.awaitTurn(ticket) else { return .cancelled }
            }
            defer { if let ticket { session.codexDispatchSerialGate.finish(ticket) } }
            var options = turn.options
            options.stopFence = stop
            let result: CodexAgentModeCoordinator.NativeSendOutcome? = if command.isCurrent, isCurrent(claim), session.selectedAgent == agent,
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
            // Ordinary non-Codex startup keeps its existing retained-row settlement. Codex
            // refusal owns rollback while still holding the original serial dispatch ticket.
            if agent == .codexExec {
                let message: String? = switch result {
                case let .preDispatchRejected(message)?: message
                case .cancelled?: "Codex send was cancelled before provider dispatch."
                default: nil
                }
                if let message, owner.membership(of: session)?.identity == membership.identity {
                    if rollbackCanonicalPublication(turn, claim: claim, message: message) {
                        rejectedPresentation?(message)
                    }
                } else if message == nil, owner.membership(of: session)?.identity == membership.identity {
                    session.deferredActiveAgentRunTimerRollback = nil
                }
            }
            return result
        })
    }
}
