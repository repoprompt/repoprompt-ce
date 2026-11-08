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

    func providerSwitchCatalogWindow(agent: AgentProviderKind, model: String) -> Int? {
        linkExecutionRuntime.providerSwitchCatalogWindow(agent: agent, model: model)
    }

    /// Existing prompt owners author all these strings. Rendering current inventory in full is
    /// conservative for a pending fresh context and neither reserves nor acknowledges a claim.
    func providerSwitchInstructionStrings(_ session: TabSession, includeSupplement: Bool = true, destination: AgentProviderKind? = nil, includeOwedContent: Bool = true) -> [String] {
        linkExecutionRuntime.providerSwitchInstructionStrings(session, includeSupplement: includeSupplement, destination: destination, includeOwedContent: includeOwedContent)
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

    /// Accepted input after the saved cutoff invalidates the ready seed. The exact input currently
    /// being started is excluded, never arbitrary equal text. Missing retained cutoff fails closed.
    static func providerSwitchNeedsReview(_ session: TabSession, excluding inputID: UUID? = nil) -> Bool {
        AgentSessionLinkExecutionRuntime.providerSwitchNeedsReview(session, excluding: inputID)
    }

    /// Sole M1 insertion point. Required-save sending before invoking any runner. Currency failure
    /// after acceptance withholds start; it is not a second fit/admission decision.
    func prepareProviderSwitchHandoverForSend(
        _ preparation: ProviderSwitchSendPreparation?, session: TabSession,
        stopFence: AgentRunStartStopFence
    ) async -> (user: String, initial: String)? {
        await linkExecutionRuntime.prepareProviderSwitchHandoverForSend(preparation, session: session, stopFence: stopFence)
    }

    func providerSwitchPreparationIsCurrent(_ preparation: ProviderSwitchSendPreparation, session: TabSession) -> Bool {
        linkExecutionRuntime.providerSwitchPreparationIsCurrent(preparation, session: session)
    }

    /// Called at the existing physical acquisition hook, not pipeline admission. Binding one exact
    /// logical dispatch is transient evidence; losing it on restart leaves durable sending inert.
    func providerSwitchAcquirePhysicalDispatch(session: TabSession, dispatchID: AgentSessionLinkPromptDispatchID) -> Bool {
        linkExecutionRuntime.providerSwitchAcquirePhysicalDispatch(session: session, dispatchID: dispatchID)
    }

    func providerSwitchRunSettled(_ session: TabSession, revision: AgentRunTerminalCommitRevision, publication: AgentRunTerminalPublicationResult) {
        linkExecutionRuntime.providerSwitchRunSettled(session, revision: revision, publication: publication)
    }

    /// Existing physical acceptance context is stronger than the legacy handoff Boolean (ACP's
    /// Boolean is earlier than its actual prompt return). Late/foreign contexts cannot clear M1.
    func providerSwitchRecordPhysicalAcceptance(session: TabSession, context: AgentSessionLinkDispatchContext?) {
        linkExecutionRuntime.providerSwitchRecordPhysicalAcceptance(session: session, context: context)
    }

    func providerSwitchHistoryToolAllowed(_ session: TabSession, destination: AgentProviderKind? = nil) -> Bool {
        linkExecutionRuntime.providerSwitchHistoryToolAllowed(session, destination: destination)
    }

    func providerSwitchReadReferenceIsCurrent(_ descriptor: ProviderSwitchCarrierDescriptor, session: TabSession, destination: AgentProviderKind? = nil) -> Bool {
        linkExecutionRuntime.providerSwitchReadReferenceIsCurrent(descriptor, session: session, destination: destination)
    }

    static func providerSwitchIsInFlightOnActiveRun(_ session: TabSession) -> Bool {
        AgentSessionLinkExecutionRuntime.providerSwitchIsInFlightOnActiveRun(session)
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

    /// Runs the whole cross-session send transaction for one exact live endpoint.
    ///
    /// The ordering is the security contract and is not rearrangeable:
    ///
    /// 1. exact endpoint identity of **both** incarnations plus the target window's real closing
    ///    state,
    /// 2. pure readiness admission (no mutation on refusal),
    /// 3. local composer claim through the ordinary admission machinery,
    /// 4. authorization commit fence **before any row exists**,
    /// 5. post-hop revalidation of both identities, closing state, claim, and readiness,
    /// 6. attributed row + durable persistence as the delivery linearization point,
    /// 7. post-persistence revalidation of both identities, closing state, workspace, and claim,
    /// 8. provider-only envelope and a direct turn start.
    ///
    /// Steps 1–5 mutate nothing, so every refusal before step 6 leaves the target byte-identical.
    /// Step 6 awaits, so step 7 exists for the same reason step 5 does; unlike step 5 it can no
    /// longer refuse, because the row is already durably the target's. It withholds the provider
    /// start and reports `persisted` instead.
    ///
    /// - Parameter liveness: host-backed probe for the facts this view model cannot see — the
    ///   observer incarnation, which usually lives in another window, and the target window's own
    ///   teardown state. It is re-read at every fence and never consults link liveness, because
    ///   manual revocation is intentionally allowed to lose once the commit fence has been won.
    func agentSessionLinkPerformSend(
        to candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkSendRequest,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        commitAuthorization: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkSendTransactionOutcome {
        await linkExecutionRuntime.agentSessionLinkPerformSend(to: candidate, request: request, liveness: liveness, commitAuthorization: commitAuthorization)
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

    /// The live session for an endpoint, or `nil` unless every identity field still matches
    /// byte-for-byte and generation-for-generation.
    func agentSessionLinkLiveSession(
        matching candidate: AgentSessionLinkEndpointCandidate
    ) -> TabSession? {
        linkExecutionRuntime.agentSessionLinkLiveSession(matching: candidate)
    }
}
