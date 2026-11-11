import CryptoKit
import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptSettingsCore

// The target-side execution of one attributed cross-session `send`.
//
// Assembles the pure `AgentSessionLinkDeliveryReadiness.Snapshot` from live target state, claims
// composer submission atomically on the target's MainActor, re-evaluates the same snapshot after
// the authorization commit hop, and hands the framed envelope to the ordinary run start. It owns no
// authority (`DomainAgentSessionLinkAuthority` grants the lease before this runs) and no queueing
// (`AgentSessionLinkPendingSend` holds `when_sendable` entries until this path admits them).
// Invariant: readiness is decided entirely from facts about the target — never from what started
// the caller's turn — and a waiting target is never ready, because answering an interaction is a
// capability `send` does not have.

// MARK: - Atomic idle-only attributed send

extension AgentModeViewModel {
    typealias ProviderSwitchPhysicalDispatch = AgentProviderSwitchPhysicalDispatch
    typealias ProviderSwitchSendPreparation = AgentProviderSwitchSendPreparation
    typealias ProviderSwitchAdmissionEvidence = AgentProviderSwitchAdmissionEvidence

    /// ONE admission implementation for every input producer. Composition finishes before any
    /// input row/receipt is accepted. Start consumes this evidence; it never re-expands or re-fits.
    func providerSwitchSendAdmission(
        session: TabSession,
        input: String,
        attachments: [AgentFileAttachment] = [],
        taggedFiles: [AgentTaggedFileAttachment] = [],
        skipsAugmentation: Bool = false,
        skipsSlashExpansion: Bool = false,
        inputAlreadyIncludesSupplement: Bool = false,
        supplementalInput: String? = nil,
        autoWakeID: UUID? = nil,
        isCurrent: @MainActor () -> Bool = { !Task.isCancelled }
    ) async -> Result<ProviderSwitchSendPreparation?, AgentSessionLinkSendFailure> {
        await linkExecutionRuntime.providerSwitchSendAdmission(session: session, input: input, attachments: attachments, taggedFiles: taggedFiles, skipsAugmentation: skipsAugmentation, skipsSlashExpansion: skipsSlashExpansion, inputAlreadyIncludesSupplement: inputAlreadyIncludesSupplement, supplementalInput: supplementalInput, autoWakeID: autoWakeID, isCurrent: isCurrent)
    }

    static func providerSwitchStartRefusal(_ session: TabSession) -> AgentSessionLinkSendFailure {
        AgentSessionLinkExecutionRuntime.providerSwitchStartRefusal(session)
    }

    static func providerSwitchHasOwnedCarryingAttempt(_ session: TabSession) -> Bool {
        AgentSessionLinkExecutionRuntime.providerSwitchHasOwnedCarryingAttempt(session)
    }

    static func providerSwitchUnconfirmed(_ session: TabSession) -> Bool {
        AgentSessionLinkExecutionRuntime.providerSwitchUnconfirmed(session)
    }

    func providerSwitchPreparationIsCurrent(_ preparation: ProviderSwitchSendPreparation, session: TabSession) -> Bool {
        linkExecutionRuntime.providerSwitchPreparationIsCurrent(preparation, session: session)
    }

    /// Assembles the pure readiness snapshot from live target state.
    ///
    /// Every field is read directly off `TabSession`; nothing is derived or defaulted here, so a
    /// blocker added to the session later cannot be silently dropped by an intermediate projection.
    ///
    /// - Parameter ignoresComposerSubmissionInFlight: set only for the post-commit re-evaluation,
    ///   where *this* transaction is the in-flight submission. Passing `true` anywhere else would
    ///   defeat the local-send race guard.
    static func agentSessionLinkDeliveryReadinessSnapshot(
        session: TabSession,
        endpointMatchesGrant: Bool,
        isClosing: Bool,
        ignoresComposerSubmissionInFlight: Bool = false,
        ignoresSelfCompactRequestID: UUID? = nil,
        ignoresProviderSwitchStalenessAfterAcceptance: Bool = false
    ) -> AgentSessionLinkDeliveryReadiness.Snapshot {
        AgentSessionLinkExecutionRuntime.agentSessionLinkDeliveryReadinessSnapshot(session: session, endpointMatchesGrant: endpointMatchesGrant, isClosing: isClosing, ignoresComposerSubmissionInFlight: ignoresComposerSubmissionInFlight, ignoresSelfCompactRequestID: ignoresSelfCompactRequestID, ignoresProviderSwitchStalenessAfterAcceptance: ignoresProviderSwitchStalenessAfterAcceptance)
    }

    /// Persistence and direct start only. The caller owns authority, readiness and the empty
    /// composer claim, and re-proves them after the flush. No link or MCP authority is acquired here.
    func persistAndStartNoncomposerTurn(
        session liveSession: TabSession,
        tabID: UUID,
        workspaceID: UUID,
        claim: AgentComposerSubmitClaim,
        displayText: String,
        providerMessage: String,
        workflow: AgentWorkflowDefinition?,
        attribution: AgentCrossSessionAttribution?,
        stopFence: AgentRunStartStopFence,
        providerSwitchPreparation: ProviderSwitchSendPreparation? = nil,
        dispatchIsCurrent: @MainActor () -> Bool
    ) async -> AgentSessionLinkSendTransactionOutcome {
        await linkExecutionRuntime.persistAndStartNoncomposerTurn(session: liveSession, tabID: tabID, workspaceID: workspaceID, claim: claim, displayText: displayText, providerMessage: providerMessage, workflow: workflow, attribution: attribution, stopFence: stopFence, providerSwitchPreparation: providerSwitchPreparation, dispatchIsCurrent: dispatchIsCurrent)
    }

    /// Retry dispatch of an already accepted row without appending or saving the input again.
    /// The caller still owns an empty composer claim and the exact identity/Stop/readiness fence.
    func startPersistedNoncomposerTurn(
        session liveSession: TabSession, tabID: UUID, claim: AgentComposerSubmitClaim,
        savedItemID: UUID, acceptedAt: Date, providerMessage: String,
        stopFence: AgentRunStartStopFence,
        providerSwitchPreparation: ProviderSwitchSendPreparation? = nil,
        dispatchIsCurrent: @MainActor () -> Bool
    ) async -> AgentSessionLinkSendTransactionOutcome {
        await linkExecutionRuntime.startPersistedNoncomposerTurn(session: liveSession, tabID: tabID, claim: claim, savedItemID: savedItemID, acceptedAt: acceptedAt, providerMessage: providerMessage, stopFence: stopFence, providerSwitchPreparation: providerSwitchPreparation, dispatchIsCurrent: dispatchIsCurrent)
    }
}
