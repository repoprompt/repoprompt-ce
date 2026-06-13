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
    let mcpPublicationEnvelope: AgentRunTerminalPublicationEnvelope?
    let successorKind: AgentRunEpochTransitionKind?
    let providerSuccessorID: UUID?
}

@MainActor
final class AgentRunTerminalCommitBarrier {
    struct ProviderSuccessor {
        let id: UUID
        let transitionKind: AgentRunEpochTransitionKind
        let consumeAfterPublication: (
            AgentRunTerminalCommitRevision,
            AgentRunTerminalPublicationResult
        ) -> Bool
    }

    struct Request {
        let session: AgentModeViewModel.TabSession
        let ownership: AgentRunOwnership
        let expectedRunID: UUID?
        let terminalState: AgentSessionRunState
        let source: String
        let completion: AgentModeRunService.CancellationCompletion
        let errorText: String?
        let attachmentReservationID: UUID?
        let attachmentDisposition: AgentModeViewModel.AttachmentTurnDisposition
        let finalizeNonCodexUsage: Bool
        let supportsFollowUp: Bool
        let providerSuccessor: ProviderSuccessor?
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
            completion: AgentModeRunService.CancellationCompletion = .terminalPublished,
            errorText: String? = nil,
            attachmentReservationID: UUID? = nil,
            attachmentDisposition: AgentModeViewModel.AttachmentTurnDisposition,
            finalizeNonCodexUsage: Bool,
            supportsFollowUp: Bool,
            providerSuccessor: ProviderSuccessor? = nil,
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
            self.completion = completion
            self.errorText = errorText
            self.attachmentReservationID = attachmentReservationID
            self.attachmentDisposition = attachmentDisposition
            self.finalizeNonCodexUsage = finalizeNonCodexUsage
            self.supportsFollowUp = supportsFollowUp
            self.providerSuccessor = providerSuccessor
            self.notifyTurnComplete = notifyTurnComplete
            self.providerDrainGeneration = providerDrainGeneration
            self.providerBuffersAreDrained = providerBuffersAreDrained
            self.prepareProviderState = prepareProviderState
            self.postCommit = postCommit
        }
    }

    private func recordTerminalBarrierState(_ active: Bool, request: Request) {
        #if DEBUG
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.publicationOwnershipState,
                EditFlowPerf.Dimensions(
                    status: "terminal_barrier",
                    outcome: request.terminalState.rawValue,
                    runID: request.expectedRunID?.uuidString,
                    providerActive: false,
                    networkScopeActive: false,
                    permitActive: false,
                    publicationPending: active,
                    terminalBarrier: active
                )
            )
        #endif
    }

    private let hooks: AgentModeRunService.Hooks
    private var terminalTeardownTasks: [AgentRunOwnership: Task<Void, Never>] = [:]
    private var consumedProviderSuccessorIDs: Set<UUID> = []
    private var consumedProviderSuccessorOrder: [UUID] = []
    private let maxConsumedProviderSuccessorTombstones = 512

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
        guard !session.terminalCommitInProgress else {
            recordRejection("commit_in_progress", request: request)
            return nil
        }
        if let existingRevision = session.lastTerminalCommitRevision,
           existingRevision.ownership == request.ownership
        {
            recordRejection("duplicate_commit", request: request)
            if session.lastTerminalPublicationResult?.isResolved != true {
                session.lastTerminalPublicationResult = await hooks.publishTerminalCommit(
                    session,
                    existingRevision,
                    existingRevision.successorKind
                )
            }
            if let followUpInstruction = takeQueuedFollowUpIfReady(
                session: session,
                revision: existingRevision,
                publicationResult: session.lastTerminalPublicationResult
            ) {
                hooks.startFollowUpRun(session.tabID, followUpInstruction)
            }
            if let providerSuccessor = request.providerSuccessor,
               providerSuccessor.id == existingRevision.providerSuccessorID,
               let publicationResult = session.lastTerminalPublicationResult
            {
                notifyProviderSuccessor(
                    providerSuccessor,
                    revision: existingRevision,
                    publicationResult: publicationResult
                )
            }
            return existingRevision
        }
        guard validatesOwnership(request) else {
            recordRejection("stale_ownership", request: request)
            return nil
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
        recordTerminalBarrierState(true, request: request)
        hooks.flushPendingAssistantDelta(session)
        guard validatesOwnership(request) else {
            session.terminalCommitInProgress = false
            recordTerminalBarrierState(false, request: request)
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
        let providerSuccessor = request.terminalState == .completed
            ? request.providerSuccessor
            : nil
        assert(
            queuedInstruction == nil || providerSuccessor == nil,
            "Generic and provider-specific successors must not drain from the same terminal commit"
        )
        if queuedInstruction != nil || providerSuccessor != nil {
            session.mcpFollowUpRunPending = true
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
            recordTerminalBarrierState(false, request: request)
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

        let successorKind: AgentRunEpochTransitionKind? = if queuedInstruction != nil {
            .relatedFollowUp
        } else {
            providerSuccessor?.transitionKind
        }
        let revision = AgentRunTerminalCommitRevision(
            commitID: UUID(),
            ownership: request.ownership,
            terminalState: request.terminalState,
            sourceItemsRevision: session.sourceItemsRevision,
            assistantDeltaFlushGeneration: session.assistantDeltaFlushGeneration,
            providerDrainGeneration: request.providerDrainGeneration,
            mcpPublicationEnvelope: hooks.makeTerminalPublicationEnvelope(
                session,
                request.ownership,
                request.terminalState
            ),
            successorKind: successorKind,
            providerSuccessorID: providerSuccessor?.id
        )
        session.lastTerminalCommitRevision = revision
        session.lastTerminalPublicationResult = nil

        hooks.updateBindings(session)
        if request.notifyTurnComplete {
            hooks.notifyAgentTurnComplete(session)
        }
        hooks.scheduleSave(session.tabID)
        session.lastTerminalPublicationResult = await hooks.publishTerminalCommit(
            session,
            revision,
            successorKind
        )
        let followUpInstruction = takeQueuedFollowUpIfReady(
            session: session,
            revision: revision,
            publicationResult: session.lastTerminalPublicationResult
        )
        if let providerSuccessor,
           let publicationResult = session.lastTerminalPublicationResult
        {
            notifyProviderSuccessor(
                providerSuccessor,
                revision: revision,
                publicationResult: publicationResult
            )
        }
        let teardownTask = registerTerminalTeardown(
            teardown,
            ownership: request.ownership,
            tabID: session.tabID
        )
        session.terminalCommitInProgress = false
        recordTerminalBarrierState(false, request: request)
        request.postCommit()

        if let followUpInstruction {
            hooks.startFollowUpRun(session.tabID, followUpInstruction)
        }
        if request.completion == .terminalTeardownCompleted {
            await teardownTask?.value
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

    private func notifyProviderSuccessor(
        _ providerSuccessor: ProviderSuccessor,
        revision: AgentRunTerminalCommitRevision,
        publicationResult: AgentRunTerminalPublicationResult
    ) {
        if case .accepted = publicationResult {
            guard !consumedProviderSuccessorIDs.contains(providerSuccessor.id) else {
                return
            }
            guard providerSuccessor.consumeAfterPublication(revision, publicationResult) else {
                return
            }
            consumedProviderSuccessorIDs.insert(providerSuccessor.id)
            consumedProviderSuccessorOrder.append(providerSuccessor.id)
            while consumedProviderSuccessorOrder.count > maxConsumedProviderSuccessorTombstones {
                let expiredID = consumedProviderSuccessorOrder.removeFirst()
                consumedProviderSuccessorIDs.remove(expiredID)
            }
            return
        }
        _ = providerSuccessor.consumeAfterPublication(revision, publicationResult)
    }

    private func takeQueuedFollowUpIfReady(
        session: AgentModeViewModel.TabSession,
        revision: AgentRunTerminalCommitRevision,
        publicationResult: AgentRunTerminalPublicationResult?
    ) -> String? {
        guard revision.successorKind != nil,
              revision.providerSuccessorID == nil,
              let publicationResult
        else { return nil }
        switch publicationResult {
        case let .accepted(successorEpoch):
            if revision.mcpPublicationEnvelope != nil, successorEpoch == nil {
                return nil
            }
        case .rejected:
            return nil
        case .stale:
            if !session.pendingInstructions.isEmpty {
                session.pendingInstructions.removeFirst()
            }
            session.mcpFollowUpRunPending = false
            return nil
        }
        guard !session.pendingInstructions.isEmpty else {
            session.mcpFollowUpRunPending = false
            return nil
        }
        return session.pendingInstructions.removeFirst()
    }

    func awaitTerminalPublication(
        for ownership: AgentRunOwnership,
        session: AgentModeViewModel.TabSession
    ) async {
        while session.terminalCommitInProgress {
            if let revision = session.lastTerminalCommitRevision,
               revision.ownership != ownership
            {
                return
            }
            await Task.yield()
        }
    }

    func awaitTerminalTeardown(
        for ownership: AgentRunOwnership,
        session: AgentModeViewModel.TabSession
    ) async {
        await awaitTerminalPublication(for: ownership, session: session)
        guard session.lastTerminalCommitRevision?.ownership == ownership else { return }
        await terminalTeardownTasks[ownership]?.value
    }

    private func registerTerminalTeardown(
        _ teardown: AgentRunAttemptTerminalResources.Teardown?,
        ownership: AgentRunOwnership,
        tabID: UUID
    ) -> Task<Void, Never>? {
        guard let teardown else { return nil }
        let task = Task { @MainActor [weak self] in
            #if DEBUG
                AgentModePerfDiagnostics.increment("run.terminal.teardown.started", tabID: tabID)
            #endif
            await teardown()
            #if DEBUG
                AgentModePerfDiagnostics.increment("run.terminal.teardown.completed", tabID: tabID)
            #endif
            self?.terminalTeardownTasks[ownership] = nil
        }
        terminalTeardownTasks[ownership] = task
        return task
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
