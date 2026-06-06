import Foundation

extension AgentSessionRunState {
    var isTerminalForCommit: Bool {
        self == .completed || self == .cancelled || self == .failed
    }
}

struct AgentRunTerminalCommitRevision: Equatable {
    let commitID: UUID
    let ownership: AgentRunOwnership
    let terminalState: AgentSessionRunState
    let sourceItemsRevision: Int
    let assistantDeltaFlushGeneration: UInt64
    let providerDrainGeneration: UInt64
}

@MainActor
final class AgentRunTerminalCommitBarrier {
    struct Request {
        let session: AgentModeViewModel.TabSession
        let ownership: AgentRunOwnership
        let expectedRunID: UUID?
        let terminalState: AgentSessionRunState
        let source: String
        let errorText: String?
        let attachmentReservationID: UUID?
        let attachmentDisposition: AgentModeViewModel.AttachmentTurnDisposition
        let finalizeNonCodexUsage: Bool
        let supportsFollowUp: Bool
        let notifyTurnComplete: Bool
        let providerDrainGeneration: UInt64
        let providerBuffersAreDrained: () -> Bool
        let prepareProviderState: () -> (@MainActor () async -> Void)?
        let postCommit: () -> Void

        init(
            session: AgentModeViewModel.TabSession,
            ownership: AgentRunOwnership,
            expectedRunID: UUID?,
            terminalState: AgentSessionRunState,
            source: String,
            errorText: String? = nil,
            attachmentReservationID: UUID? = nil,
            attachmentDisposition: AgentModeViewModel.AttachmentTurnDisposition,
            finalizeNonCodexUsage: Bool,
            supportsFollowUp: Bool,
            notifyTurnComplete: Bool,
            providerDrainGeneration: UInt64 = 0,
            providerBuffersAreDrained: @escaping () -> Bool = { true },
            prepareProviderState: @escaping () -> (@MainActor () async -> Void)? = { nil },
            postCommit: @escaping () -> Void = {}
        ) {
            self.session = session
            self.ownership = ownership
            self.expectedRunID = expectedRunID
            self.terminalState = terminalState
            self.source = source
            self.errorText = errorText
            self.attachmentReservationID = attachmentReservationID
            self.attachmentDisposition = attachmentDisposition
            self.finalizeNonCodexUsage = finalizeNonCodexUsage
            self.supportsFollowUp = supportsFollowUp
            self.notifyTurnComplete = notifyTurnComplete
            self.providerDrainGeneration = providerDrainGeneration
            self.providerBuffersAreDrained = providerBuffersAreDrained
            self.prepareProviderState = prepareProviderState
            self.postCommit = postCommit
        }
    }

    private let hooks: AgentModeRunService.Hooks

    init(hooks: AgentModeRunService.Hooks) {
        self.hooks = hooks
    }

    @discardableResult
    func commit(_ request: Request) async -> AgentRunTerminalCommitRevision? {
        let session = request.session
        guard request.terminalState == .completed
            || request.terminalState == .cancelled
            || request.terminalState == .failed
        else {
            assertionFailure("Terminal commit requires a terminal run state")
            return nil
        }
        guard validatesOwnership(request) else {
            recordRejection("stale_ownership", request: request)
            return nil
        }
        guard !session.terminalCommitInProgress else {
            recordRejection("commit_in_progress", request: request)
            return nil
        }
        guard session.lastTerminalCommitRevision?.ownership != request.ownership else {
            recordRejection("duplicate_commit", request: request)
            return session.lastTerminalCommitRevision
        }
        guard session.providerTerminalDrainGeneration == request.providerDrainGeneration else {
            recordRejection("stale_provider_drain_generation", request: request)
            return nil
        }
        guard request.providerBuffersAreDrained() else {
            assertionFailure("Provider-local terminal buffers must be drained before terminal commit")
            recordRejection("provider_buffers_pending", request: request)
            return nil
        }

        session.terminalCommitInProgress = true
        hooks.flushPendingAssistantDelta(session)
        guard validatesOwnership(request) else {
            session.terminalCommitInProgress = false
            recordRejection("ownership_changed_during_drain", request: request)
            return nil
        }

        hooks.finalizeStreamingItems(session)
        hooks.finalizePendingToolCalls(session, request.terminalState)
        if request.finalizeNonCodexUsage {
            hooks.finalizeNonCodexTurnUsage(session, nil, nil, nil)
        }

        let queuedInstruction = request.terminalState == .completed && request.supportsFollowUp
            ? session.pendingInstructions.first
            : nil
        if queuedInstruction != nil {
            session.mcpFollowUpRunPending = true
            session.pendingInstructions.removeFirst()
        }

        hooks.cancelPendingQuestion(session)
        hooks.cancelPendingApproval(session)
        let reviewCancellationReason = switch request.terminalState {
        case .completed:
            "Run completed before review decision"
        case .cancelled:
            "Run cancelled"
        case .failed:
            "Run failed"
        default:
            "Run finished"
        }
        hooks.cancelPendingApplyEditsReview(session, reviewCancellationReason)
        hooks.cancelPendingWorktreeMergeReview(session, reviewCancellationReason)
        hooks.finalizeAttachmentsForTurn(
            session,
            request.attachmentReservationID,
            request.attachmentDisposition
        )

        if let errorText = request.errorText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !errorText.isEmpty
        {
            session.appendItem(AgentChatItem.error(errorText, sequenceIndex: session.nextSequenceIndex))
        }

        guard validatesOwnership(request),
              session.providerTerminalDrainGeneration == request.providerDrainGeneration,
              request.providerBuffersAreDrained()
        else {
            session.terminalCommitInProgress = false
            recordRejection("ownership_or_drain_changed_before_commit", request: request)
            return nil
        }

        let attemptTeardown = session.claimRunAttemptTerminalTeardown(
            ownership: request.ownership,
            terminalState: request.terminalState
        )
        let providerTeardown = request.prepareProviderState()
        let teardown: AgentRunAttemptTerminalResources.Teardown? = if attemptTeardown != nil || providerTeardown != nil {
            {
                await attemptTeardown?()
                await providerTeardown?()
            }
        } else {
            nil
        }
        session.agentTask = nil
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus(nil, source: nil)
        session.waitingPrompt = nil
        session.runState = request.terminalState
        _ = session.endRunAttempt(ifCurrent: request.ownership, source: request.source)
        hooks.setAgentRunActive(session.tabID, false)
        hooks.prepareTerminalPublication(session)

        let revision = AgentRunTerminalCommitRevision(
            commitID: UUID(),
            ownership: request.ownership,
            terminalState: request.terminalState,
            sourceItemsRevision: session.sourceItemsRevision,
            assistantDeltaFlushGeneration: session.assistantDeltaFlushGeneration,
            providerDrainGeneration: request.providerDrainGeneration
        )
        session.lastTerminalCommitRevision = revision

        hooks.updateBindings(session)
        if request.notifyTurnComplete {
            hooks.notifyAgentTurnComplete(session)
        }
        hooks.scheduleSave(session.tabID)
        await hooks.publishTerminalCommit(session, revision)
        session.terminalCommitInProgress = false
        request.postCommit()

        if let teardown {
            Task { @MainActor in
                #if DEBUG
                    AgentModePerfDiagnostics.increment("run.terminal.teardown.started", tabID: session.tabID)
                #endif
                await teardown()
                #if DEBUG
                    AgentModePerfDiagnostics.increment("run.terminal.teardown.completed", tabID: session.tabID)
                #endif
            }
        }
        if let queuedInstruction {
            hooks.startFollowUpRun(session.tabID, queuedInstruction)
        }

        #if DEBUG
            AgentModePerfDiagnostics.increment("run.terminal.commit.accepted", tabID: session.tabID)
            AgentModePerfDiagnostics.increment(
                "run.terminal.commit.accepted.\(request.terminalState.rawValue)",
                tabID: session.tabID
            )
        #endif
        return revision
    }

    private func validatesOwnership(_ request: Request) -> Bool {
        request.session.isCurrentRunAttemptForCurrentBinding(
            request.ownership,
            expectedRunID: request.expectedRunID
        )
    }

    private func recordRejection(_ reason: String, request: Request) {
        #if DEBUG
            AgentModePerfDiagnostics.increment("run.terminal.commit.rejected.\(reason)", tabID: request.session.tabID)
            AgentModePerfDiagnostics.event(
                "run.terminal.commitRejected",
                tabID: request.session.tabID,
                fields: [
                    "reason": reason,
                    "source": request.source,
                    "state": request.terminalState.rawValue
                ]
            )
        #endif
    }
}
