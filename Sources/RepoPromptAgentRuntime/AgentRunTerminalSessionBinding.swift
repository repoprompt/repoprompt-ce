import Foundation
import RepoPromptDomainRuntime

/// Exact-object-bound capabilities used by the terminal settlement spine.
///
/// This value carries no concrete app session class and performs no lookup by
/// `tabID`. The app host partially applies its exact session at the
/// run/settlement edge, while the terminal barrier operates only on this
/// capability surface and `AgentRunAttemptLifecycle`. Attachment finalization
/// is expressed in provider-neutral domain command vocabulary; the bound app
/// hook remains the attachment persistence authority that applies it.
@MainActor
package struct AgentRunTerminalSessionBinding {
    package struct Hooks {
        package var flushQuietToolObservations: (@MainActor () async -> Bool)?
        package var quietToolObservationsAreComplete: @MainActor () -> Bool = { true }
        var sealQuietCheckIn: @MainActor (AgentRunOwnership, AgentSessionRunState, Bool, Bool) -> Void = { _, _, _, _ in }
        let flushPendingAssistantDelta: @MainActor () -> Void
        let finalizeStreamingItems: @MainActor () -> Void
        let finalizePendingToolCalls: @MainActor (AgentSessionRunState) -> Void
        let finalizeNonCodexTurnUsage: @MainActor () -> Void
        let cancelPendingInteractions: @MainActor (_ reviewReason: String) -> Void
        let finalizeAttachments: @MainActor (UUID?, DomainAgentRunAttachmentTurnDisposition) -> Void
        let setAgentRunInactive: @MainActor () -> Void
        let prepareTerminalPublication: @MainActor () -> Void
        let makeTerminalPublicationEnvelope: @MainActor (
            AgentRunOwnership,
            AgentSessionRunState,
            UUID?,
            DomainAgentRunSnapshot.FailureReason?
        ) -> AgentRunTerminalPublicationEnvelope?
        let updateBindings: @MainActor () -> Void
        let notifyAgentTurnComplete: @MainActor () -> Void
        /// Defaulted so bindings built by test doubles that predate failure notifications compile.
        var notifyAgentTurnFailed: @MainActor (_ errorText: String?) -> Void = { _ in }
        let scheduleSave: @MainActor () -> Void
        let publishTerminalCommit: @MainActor (
            AgentRunTerminalCommitRevision,
            AgentRunEpochTransitionKind?
        ) async -> AgentRunTerminalPublicationResult
        /// Domain publication can finish after a local rebind. Its committed result is not
        /// permission to consume or dispatch work on that different incarnation.
        var permitsTerminalSuccessor: @MainActor (AgentRunTerminalCommitRevision, AgentRunTerminalPublicationResult) -> Bool = { _, _ in true }
        let startFollowUpRun: @MainActor (AgentRunPendingInstruction) -> Void
        /// Post-publication, post-successor terminal observation; provider work must be deferred.
        var onSelfCompactTerminalSettled: @MainActor (
            AgentRunTerminalCommitRevision,
            AgentRunTerminalPublicationResult,
            @escaping @MainActor () -> Bool
        ) -> Void = { _, _, _ in }

        package init(
            flushQuietToolObservations: (@MainActor () async -> Bool)? = nil,
            quietToolObservationsAreComplete: @escaping @MainActor () -> Bool = { true },
            sealQuietCheckIn: @escaping @MainActor (AgentRunOwnership, AgentSessionRunState, Bool, Bool) -> Void = { _, _, _, _ in },
            flushPendingAssistantDelta: @escaping @MainActor () -> Void,
            finalizeStreamingItems: @escaping @MainActor () -> Void,
            finalizePendingToolCalls: @escaping @MainActor (AgentSessionRunState) -> Void,
            finalizeNonCodexTurnUsage: @escaping @MainActor () -> Void,
            cancelPendingInteractions: @escaping @MainActor (_ reviewReason: String) -> Void,
            finalizeAttachments: @escaping @MainActor (UUID?, DomainAgentRunAttachmentTurnDisposition) -> Void,
            setAgentRunInactive: @escaping @MainActor () -> Void,
            prepareTerminalPublication: @escaping @MainActor () -> Void,
            makeTerminalPublicationEnvelope: @escaping @MainActor (
                AgentRunOwnership,
                AgentSessionRunState,
                UUID?,
                DomainAgentRunSnapshot.FailureReason?
            ) -> AgentRunTerminalPublicationEnvelope?,
            updateBindings: @escaping @MainActor () -> Void,
            notifyAgentTurnComplete: @escaping @MainActor () -> Void,
            notifyAgentTurnFailed: @escaping @MainActor (_ errorText: String?) -> Void = { _ in },
            scheduleSave: @escaping @MainActor () -> Void,
            publishTerminalCommit: @escaping @MainActor (
                AgentRunTerminalCommitRevision,
                AgentRunEpochTransitionKind?
            ) async -> AgentRunTerminalPublicationResult,
            permitsTerminalSuccessor: @escaping @MainActor (AgentRunTerminalCommitRevision, AgentRunTerminalPublicationResult) -> Bool = { _, _ in true },
            startFollowUpRun: @escaping @MainActor (AgentRunPendingInstruction) -> Void,
            onSelfCompactTerminalSettled: @escaping @MainActor (
                AgentRunTerminalCommitRevision,
                AgentRunTerminalPublicationResult,
                @escaping @MainActor () -> Bool
            ) -> Void = { _, _, _ in }
        ) {
            self.flushQuietToolObservations = flushQuietToolObservations
            self.quietToolObservationsAreComplete = quietToolObservationsAreComplete
            self.sealQuietCheckIn = sealQuietCheckIn
            self.flushPendingAssistantDelta = flushPendingAssistantDelta
            self.finalizeStreamingItems = finalizeStreamingItems
            self.finalizePendingToolCalls = finalizePendingToolCalls
            self.finalizeNonCodexTurnUsage = finalizeNonCodexTurnUsage
            self.cancelPendingInteractions = cancelPendingInteractions
            self.finalizeAttachments = finalizeAttachments
            self.setAgentRunInactive = setAgentRunInactive
            self.prepareTerminalPublication = prepareTerminalPublication
            self.makeTerminalPublicationEnvelope = makeTerminalPublicationEnvelope
            self.updateBindings = updateBindings
            self.notifyAgentTurnComplete = notifyAgentTurnComplete
            self.notifyAgentTurnFailed = notifyAgentTurnFailed
            self.scheduleSave = scheduleSave
            self.publishTerminalCommit = publishTerminalCommit
            self.permitsTerminalSuccessor = permitsTerminalSuccessor
            self.startFollowUpRun = startFollowUpRun
            self.onSelfCompactTerminalSettled = onSelfCompactTerminalSettled
        }
    }

    let tabID: UUID
    let lifecycle: AgentRunAttemptLifecycle
    package var hooks: Hooks

    private let ownershipValidator: @MainActor (AgentRunOwnership, UUID?) -> Bool
    private let providerDrainGenerationProvider: @MainActor () -> UInt64
    private let terminalTurnIDProvider: @MainActor () -> UUID?
    private let queuedFollowUpProvider: @MainActor () -> String?
    private let followUpPendingSetter: @MainActor (Bool) -> Void
    private let firstQueuedFollowUpRemover: @MainActor () -> AgentRunPendingInstruction?
    private let errorAppender: @MainActor (String) -> Void
    private let activeStateFinisher: @MainActor (AgentRunOwnership, AgentSessionRunState, String) -> Void
    private let processRunIdentityRetainer: @MainActor (UUID, UUID) -> Void
    private let sourceItemsRevisionProvider: @MainActor () -> Int
    private let assistantDeltaFlushGenerationProvider: @MainActor () -> UInt64
    private let latestFailureTextProvider: @MainActor () -> String?

    package init(
        tabID: UUID,
        lifecycle: AgentRunAttemptLifecycle,
        hooks: Hooks,
        validatesOwnership: @escaping @MainActor (AgentRunOwnership, UUID?) -> Bool,
        providerDrainGeneration: @escaping @MainActor () -> UInt64,
        terminalTurnID: @escaping @MainActor () -> UUID?,
        queuedFollowUp: @escaping @MainActor () -> String?,
        setFollowUpPending: @escaping @MainActor (Bool) -> Void,
        removeFirstQueuedFollowUp: @escaping @MainActor () -> AgentRunPendingInstruction?,
        appendError: @escaping @MainActor (String) -> Void,
        finishActiveState: @escaping @MainActor (AgentRunOwnership, AgentSessionRunState, String) -> Void,
        retainProcessRunIdentity: @escaping @MainActor (UUID, UUID) -> Void,
        sourceItemsRevision: @escaping @MainActor () -> Int,
        assistantDeltaFlushGeneration: @escaping @MainActor () -> UInt64,
        latestFailureText: @escaping @MainActor () -> String?
    ) {
        self.tabID = tabID
        self.lifecycle = lifecycle
        self.hooks = hooks
        ownershipValidator = validatesOwnership
        providerDrainGenerationProvider = providerDrainGeneration
        terminalTurnIDProvider = terminalTurnID
        queuedFollowUpProvider = queuedFollowUp
        followUpPendingSetter = setFollowUpPending
        firstQueuedFollowUpRemover = removeFirstQueuedFollowUp
        errorAppender = appendError
        activeStateFinisher = finishActiveState
        processRunIdentityRetainer = retainProcessRunIdentity
        sourceItemsRevisionProvider = sourceItemsRevision
        assistantDeltaFlushGenerationProvider = assistantDeltaFlushGeneration
        latestFailureTextProvider = latestFailureText
    }

    func validatesOwnership(_ ownership: AgentRunOwnership, expectedRunID: UUID?) -> Bool {
        ownershipValidator(ownership, expectedRunID)
    }

    var providerDrainGeneration: UInt64 {
        providerDrainGenerationProvider()
    }

    var terminalTurnID: UUID? {
        terminalTurnIDProvider()
    }

    var queuedFollowUp: String? {
        queuedFollowUpProvider()
    }

    func setFollowUpPending(_ pending: Bool) {
        followUpPendingSetter(pending)
    }

    @discardableResult
    func removeFirstQueuedFollowUp() -> AgentRunPendingInstruction? {
        firstQueuedFollowUpRemover()
    }

    func appendError(_ text: String) {
        errorAppender(text)
    }

    func finishActiveState(
        ownership: AgentRunOwnership,
        terminalState: AgentSessionRunState,
        source: String
    ) {
        activeStateFinisher(ownership, terminalState, source)
    }

    func retainProcessRunIdentity(_ runID: UUID, terminalTurnID: UUID) {
        processRunIdentityRetainer(runID, terminalTurnID)
    }

    var sourceItemsRevision: Int {
        sourceItemsRevisionProvider()
    }

    var assistantDeltaFlushGeneration: UInt64 {
        assistantDeltaFlushGenerationProvider()
    }

    var latestFailureText: String? {
        latestFailureTextProvider()
    }
}
