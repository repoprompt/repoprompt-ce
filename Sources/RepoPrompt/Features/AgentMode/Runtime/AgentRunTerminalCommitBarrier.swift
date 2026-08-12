import Foundation
import RepoPromptDomainRuntime

extension AgentSessionRunState {
    var isTerminalForCommit: Bool {
        self == .completed || self == .cancelled || self == .failed
    }

    /// MCP snapshot status equivalent of a committed terminal run state.
    var mcpTerminalSnapshotStatus: DomainAgentRunSnapshot.Status? {
        switch self {
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        case .idle, .running, .waitingForUser, .waitingForQuestion, .waitingForApproval: nil
        }
    }
}

struct AgentRunTerminalCommitRevision: Equatable {
    let commitID: UUID
    let ownership: AgentRunOwnership
    let terminalState: AgentSessionRunState
    let failureReason: DomainAgentRunSnapshot.FailureReason?
    let expectedRunID: UUID?
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
        // This request carries no concrete app session class. Its domain command values
        // carry no settlement authority; the exact-object binding applies them
        // through host-owned capabilities.
        let binding: AgentRunTerminalSessionBinding
        let ownership: AgentRunOwnership
        let expectedRunID: UUID?
        let terminalState: AgentSessionRunState
        let source: String
        let completion: DomainAgentRunCancellationCompletion
        let errorText: String?
        let failureReason: DomainAgentRunSnapshot.FailureReason?
        let attachmentReservationID: UUID?
        let attachmentDisposition: DomainAgentRunAttachmentTurnDisposition
        let finalizeNonCodexUsage: Bool
        let supportsFollowUp: Bool
        let providerSuccessor: ProviderSuccessor?
        let notifyTurnComplete: Bool
        let providerDrainGeneration: UInt64
        let providerBuffersAreDrained: () -> Bool
        let prepareProviderState: () -> (@MainActor () async -> Void)?
        let postCommit: () -> Void

        init(
            binding: AgentRunTerminalSessionBinding,
            ownership: AgentRunOwnership,
            expectedRunID: UUID?,
            terminalState: AgentSessionRunState,
            source: String,
            completion: DomainAgentRunCancellationCompletion = .terminalPublished,
            errorText: String? = nil,
            failureReason: DomainAgentRunSnapshot.FailureReason? = nil,
            attachmentReservationID: UUID? = nil,
            attachmentDisposition: DomainAgentRunAttachmentTurnDisposition,
            finalizeNonCodexUsage: Bool,
            supportsFollowUp: Bool,
            providerSuccessor: ProviderSuccessor? = nil,
            notifyTurnComplete: Bool,
            providerDrainGeneration: UInt64 = 0,
            providerBuffersAreDrained: @escaping () -> Bool = { true },
            prepareProviderState: @escaping () -> (@MainActor () async -> Void)? = { nil },
            postCommit: @escaping () -> Void = {}
        ) {
            self.binding = binding
            self.ownership = ownership
            self.expectedRunID = expectedRunID
            self.terminalState = terminalState
            self.source = source
            self.completion = completion
            self.errorText = errorText
            self.failureReason = failureReason
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

    private var terminalTeardownTasks: [AgentRunOwnership: Task<Void, Never>] = [:]
    private var consumedProviderSuccessorIDs: Set<UUID> = []
    private var consumedProviderSuccessorOrder: [UUID] = []
    private let maxConsumedProviderSuccessorTombstones = 512

    init() {}

    @discardableResult
    func commit(_ request: Request) async -> AgentRunTerminalCommitRevision? {
        let binding = request.binding
        let lifecycle = binding.lifecycle
        guard request.terminalState == .completed
            || request.terminalState == .cancelled
            || request.terminalState == .failed
        else {
            assertionFailure("Terminal commit requires a terminal run state")
            return nil
        }
        guard !lifecycle.terminalCommitInProgress else {
            recordRejection("commit_in_progress", request: request)
            return nil
        }
        if let existingRevision = lifecycle.lastTerminalCommitRevision,
           existingRevision.ownership == request.ownership
        {
            recordRejection("duplicate_commit", request: request)
            if lifecycle.lastTerminalPublicationResult?.isResolved != true {
                // Duplicate retry: records a result while no terminal commit is
                // in progress; the facade operation is intentionally unguarded.
                let retriedResult = await binding.hooks.publishTerminalCommit(
                    existingRevision,
                    existingRevision.successorKind
                )
                lifecycle.recordTerminalPublicationResult(retriedResult)
            }
            if let followUpInstruction = takeQueuedFollowUpIfReady(
                binding: binding,
                revision: existingRevision,
                publicationResult: lifecycle.lastTerminalPublicationResult
            ) {
                binding.hooks.startFollowUpRun(followUpInstruction)
            }
            if let providerSuccessor = request.providerSuccessor,
               providerSuccessor.id == existingRevision.providerSuccessorID,
               let publicationResult = lifecycle.lastTerminalPublicationResult
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
        guard binding.providerDrainGeneration == request.providerDrainGeneration else {
            recordRejection("stale_provider_drain_generation", request: request)
            return nil
        }
        guard request.providerBuffersAreDrained() else {
            assertionFailure("Provider-local terminal buffers must be drained before terminal commit")
            recordRejection("provider_buffers_pending", request: request)
            return nil
        }
        let terminalTurnID = binding.terminalTurnID

        let acquiredTerminalCommitPhase = lifecycle.beginTerminalCommit()
        assert(acquiredTerminalCommitPhase, "Terminal commit phase acquisition must succeed after the in-progress guard")
        recordTerminalBarrierState(true, request: request)
        binding.hooks.flushPendingAssistantDelta()
        guard validatesOwnership(request) else {
            lifecycle.abortTerminalCommit()
            recordTerminalBarrierState(false, request: request)
            recordRejection("ownership_changed_during_drain", request: request)
            return nil
        }

        binding.hooks.finalizeStreamingItems()
        binding.hooks.finalizePendingToolCalls(request.terminalState)
        if request.finalizeNonCodexUsage {
            binding.hooks.finalizeNonCodexTurnUsage()
        }

        let queuedInstruction = request.terminalState == .completed && request.supportsFollowUp
            ? binding.queuedFollowUp
            : nil
        let providerSuccessor = request.terminalState == .completed
            ? request.providerSuccessor
            : nil
        assert(
            queuedInstruction == nil || providerSuccessor == nil,
            "Generic and provider-specific successors must not drain from the same terminal commit"
        )
        if queuedInstruction != nil || providerSuccessor != nil {
            binding.setFollowUpPending(true)
        }

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
        binding.hooks.cancelPendingInteractions(reviewCancellationReason)
        binding.hooks.finalizeAttachments(
            request.attachmentReservationID,
            request.attachmentDisposition
        )

        if let errorText = request.errorText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !errorText.isEmpty
        {
            binding.appendError(errorText)
        }

        guard validatesOwnership(request),
              binding.providerDrainGeneration == request.providerDrainGeneration,
              request.providerBuffersAreDrained()
        else {
            lifecycle.abortTerminalCommit()
            recordTerminalBarrierState(false, request: request)
            recordRejection("ownership_or_drain_changed_before_commit", request: request)
            return nil
        }

        let attemptTeardown = lifecycle.claimTerminalTeardown(
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
        binding.finishActiveState(
            ownership: request.ownership,
            terminalState: request.terminalState,
            source: request.source
        )
        binding.hooks.setAgentRunInactive()
        binding.hooks.prepareTerminalPublication()
        if let runID = request.expectedRunID, let terminalTurnID {
            binding.retainProcessRunIdentity(runID, terminalTurnID: terminalTurnID)
        }

        let successorKind: AgentRunEpochTransitionKind? = if queuedInstruction != nil {
            .relatedFollowUp
        } else {
            providerSuccessor?.transitionKind
        }
        // Resolved exactly once at settlement; the publication envelope is built
        // before the revision is stored, so the reason is threaded explicitly.
        let failureReason = resolveTerminalFailureReason(request: request, binding: binding)
        let revision = AgentRunTerminalCommitRevision(
            commitID: UUID(),
            ownership: request.ownership,
            terminalState: request.terminalState,
            failureReason: failureReason,
            expectedRunID: request.expectedRunID,
            sourceItemsRevision: binding.sourceItemsRevision,
            assistantDeltaFlushGeneration: binding.assistantDeltaFlushGeneration,
            providerDrainGeneration: request.providerDrainGeneration,
            mcpPublicationEnvelope: binding.hooks.makeTerminalPublicationEnvelope(
                request.ownership,
                request.terminalState,
                request.expectedRunID,
                failureReason
            ),
            successorKind: successorKind,
            providerSuccessorID: providerSuccessor?.id
        )
        lifecycle.stageTerminalRevision(revision)

        binding.hooks.updateBindings()
        if request.notifyTurnComplete {
            binding.hooks.notifyAgentTurnComplete()
        }
        binding.hooks.scheduleSave()
        let publicationResult = await binding.hooks.publishTerminalCommit(
            revision,
            successorKind
        )
        lifecycle.recordTerminalPublicationResult(publicationResult)
        let followUpInstruction = takeQueuedFollowUpIfReady(
            binding: binding,
            revision: revision,
            publicationResult: lifecycle.lastTerminalPublicationResult
        )
        if let providerSuccessor,
           let publicationResult = lifecycle.lastTerminalPublicationResult
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
            tabID: binding.tabID
        )
        lifecycle.completeTerminalCommit()
        recordTerminalBarrierState(false, request: request)
        request.postCommit()

        if let followUpInstruction {
            binding.hooks.startFollowUpRun(followUpInstruction)
        }
        if request.completion == .terminalTeardownCompleted {
            await teardownTask?.value
        }

        #if DEBUG
            AgentModePerfDiagnostics.increment("run.terminal.commit.accepted", tabID: binding.tabID)
            AgentModePerfDiagnostics.increment(
                "run.terminal.commit.accepted.\(request.terminalState.rawValue)",
                tabID: binding.tabID
            )
        #endif
        return revision
    }

    /// Settles the terminal failure classification for a commit. Runs after the
    /// transcript flush/finalization and after any request error item has been
    /// appended, so the failed-state text classification sees the same latest
    /// settled error text the publication snapshot projects today.
    private func resolveTerminalFailureReason(
        request: Request,
        binding: AgentRunTerminalSessionBinding
    ) -> DomainAgentRunSnapshot.FailureReason? {
        switch request.terminalState {
        case .cancelled:
            return .cancelled
        case .failed:
            if let failureReason = request.failureReason {
                return failureReason
            }
            let settledFailureText = binding.latestFailureText
            return DomainAgentRunSnapshot.FailureReason.classify(status: .failed, statusText: settledFailureText)
        default:
            return nil
        }
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
        binding: AgentRunTerminalSessionBinding,
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
            _ = binding.removeFirstQueuedFollowUp()
            binding.setFollowUpPending(false)
            return nil
        }
        guard binding.queuedFollowUp != nil else {
            binding.setFollowUpPending(false)
            return nil
        }
        return binding.removeFirstQueuedFollowUp()
    }

    func awaitTerminalPublication(
        for ownership: AgentRunOwnership,
        lifecycle: AgentRunAttemptLifecycle
    ) async {
        while lifecycle.terminalCommitInProgress {
            if let revision = lifecycle.lastTerminalCommitRevision,
               revision.ownership != ownership
            {
                return
            }
            await Task.yield()
        }
    }

    func awaitTerminalTeardown(
        for ownership: AgentRunOwnership,
        lifecycle: AgentRunAttemptLifecycle
    ) async {
        await awaitTerminalPublication(for: ownership, lifecycle: lifecycle)
        guard lifecycle.lastTerminalCommitRevision?.ownership == ownership else { return }
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
        request.binding.validatesOwnership(
            request.ownership,
            expectedRunID: request.expectedRunID
        )
    }

    private func recordRejection(_ reason: String, request: Request) {
        #if DEBUG
            AgentModePerfDiagnostics.increment("run.terminal.commit.rejected.\(reason)", tabID: request.binding.tabID)
            AgentModePerfDiagnostics.event(
                "run.terminal.commitRejected",
                tabID: request.binding.tabID,
                fields: [
                    "reason": reason,
                    "source": request.source,
                    "state": request.terminalState.rawValue
                ]
            )
        #endif
    }
}
