import Foundation
import RepoPromptDomainRuntime

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
        ignoresComposerSubmissionInFlight: Bool = false
    ) -> AgentSessionLinkDeliveryReadiness.Snapshot {
        AgentSessionLinkDeliveryReadiness.Snapshot(
            hasLoadedPersistedState: session.hasLoadedPersistedState,
            bindingTransitionInProgress: session.bindingTransitionInProgress,
            isClosing: isClosing,
            endpointMatchesGrant: endpointMatchesGrant,
            runStateIsActive: session.runState.isActive,
            terminalCommitInProgress: session.terminalCommitInProgress,
            mcpFollowUpRunPending: session.mcpFollowUpRunPending,
            isComposerSubmissionInFlight: ignoresComposerSubmissionInFlight
                ? false
                : session.isComposerSubmissionInFlight,
            isPreparingInitialWorktree: session.isPreparingInitialWorktree,
            isChangingExecutionLocation: session.isChangingExecutionLocation,
            pendingInstructionCount: session.pendingInstructions.count,
            pendingACPSteeringCount: session.pendingACPSteeringInstructions.count,
            pendingClaudeSteeringCount: session.pendingClaudeSteeringInstructions.count,
            pendingOversightAutoWake: session.oversight.pendingAutoWake != nil,
            hasWaitingPrompt: session.waitingPrompt != nil,
            hasPendingAskUser: session.pendingAskUser != nil,
            hasPendingUserInputRequest: session.pendingUserInputRequest != nil,
            hasPendingApproval: session.pendingApproval != nil,
            hasPendingPermissionsRequest: session.pendingPermissionsRequest != nil,
            hasPendingMCPElicitationRequest: session.pendingMCPElicitationRequest != nil,
            hasPendingApplyEditsReview: session.pendingApplyEditsReview != nil,
            hasPendingWorktreeMergeReview: session.pendingWorktreeMergeReview != nil
        )
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
        // 1. Exact endpoint incarnations. The local lookup proves the target tab; the host probe
        //    proves the observer incarnation and the target window's real closing state.
        guard let session = agentSessionLinkLiveSession(matching: candidate) else {
            return .blocked(.endpointInvalidated)
        }
        let admissionLiveness = liveness()
        guard admissionLiveness.permitsDelivery else {
            return .blocked(.endpointInvalidated)
        }

        // 2. Pure readiness admission.
        let admission = AgentSessionLinkDeliveryReadiness.evaluate(
            snapshot: Self.agentSessionLinkDeliveryReadinessSnapshot(
                session: session,
                endpointMatchesGrant: admissionLiveness.targetEndpointIsLive,
                isClosing: admissionLiveness.targetWindowIsClosing
            )
        )
        if case let .blocked(reason) = admission {
            return .blocked(AgentSessionLinkSendFailure(reason))
        }

        // 3. Local composer claim. Losing it means a local user Send won the race, which is exactly
        //    `target_not_idle` — the observer polls and retries rather than queueing behind the user.
        guard let target = makeComposerSubmitTarget(tabID: candidate.tabID, session: session),
              target.route == .existingAgentSession,
              target.expectedSourceAgentSessionID == candidate.sessionID
        else {
            return .blocked(.targetNotIdle)
        }
        let attempt = AgentComposerSubmitAttempt(
            id: UUID(),
            target: target,
            inputRevision: 0,
            noticeRevision: 0,
            // A cross-session send carries no composer draft, so it must never look like one: an
            // empty snapshot cannot match a real draft and therefore cannot clear the user's text.
            rawDraftSnapshot: ""
        )
        guard case let .claimed(claim) = claimComposerSubmitAttempt(
            attempt,
            requireActiveTabOwnership: false
        ) else {
            return .blocked(.targetNotIdle)
        }

        // 4. Authorization linearization fence, still holding the claim and before any row exists.
        //    A manual Stop that wins here cancels with zero transcript mutation; a commit that wins
        //    is allowed to settle even if Stop follows.
        let commit = await commitAuthorization()
        guard commit == .committed else {
            releaseComposerSubmitClaim(claim)
            return .blocked(commit == .shuttingDown ? .shuttingDown : .linkRevoked)
        }

        // 5. The commit awaited, so every identity and readiness fact must be re-proven — including
        //    the observer incarnation and the target window's closing state, which an observer
        //    rebind/close or a window teardown during that await would otherwise slip past.
        let postCommitLiveness = liveness()
        guard let liveSession = agentSessionLinkLiveSession(matching: candidate),
              liveSession === session,
              postCommitLiveness.permitsDelivery,
              composerSubmitClaimIsCurrent(claim)
        else {
            releaseComposerSubmitClaim(claim)
            return .blocked(.endpointInvalidated)
        }
        let postCommitAdmission = AgentSessionLinkDeliveryReadiness.evaluate(
            snapshot: Self.agentSessionLinkDeliveryReadinessSnapshot(
                session: liveSession,
                endpointMatchesGrant: postCommitLiveness.targetEndpointIsLive,
                isClosing: postCommitLiveness.targetWindowIsClosing,
                ignoresComposerSubmissionInFlight: true
            )
        )
        if case let .blocked(reason) = postCommitAdmission {
            releaseComposerSubmitClaim(claim)
            return .blocked(AgentSessionLinkSendFailure(reason))
        }
        guard let workspaceID = workspaceManager?.activeWorkspace?.id,
              workspaceID == candidate.workspaceID
        else {
            releaseComposerSubmitClaim(claim)
            return .blocked(.endpointInvalidated)
        }

        // 6. Durable acceptance. The row carries the observer's raw text plus attribution; the
        //    envelope is built for the provider only, so the transcript is not a rendering of XML.
        let userItem = AgentChatItem.user(
            request.message,
            sequenceIndex: liveSession.nextSequenceIndex,
            // Badges the one-shot workflow the sender attached to *this* message through the row's
            // existing metadata, so the standard pill renders beside the attribution badge with no
            // new UI. It records what this turn ran under; it is not, and never becomes, the
            // target's composer selection.
            workflow: request.workflow,
            crossSessionAttribution: request.attribution
        )
        let anchorRollback = recordAgentTurnUserAnchor(for: liveSession, userItem: userItem)
        liveSession.appendItem(userItem)
        updateBindingsFromSession(liveSession)
        requestUIRefresh(tabID: candidate.tabID, urgent: true)

        if case .failure = await flushSaveRequired(for: candidate.tabID, workspaceID: workspaceID) {
            agentSessionLinkRollbackStagedRow(
                itemID: userItem.id,
                tabID: candidate.tabID,
                session: liveSession,
                anchorRollback: anchorRollback
            )
            // A failed flush may already have written the row, so "nothing was delivered" is only
            // true once the compensating removal is itself durable. Confirm it synchronously here
            // rather than leaving it to a scheduled save: releasing the idempotency key for a fresh
            // retry while a committed row might survive is exactly how one logical send becomes two
            // transcript rows.
            if case .failure = await flushSaveRequired(for: candidate.tabID, workspaceID: workspaceID) {
                releaseComposerSubmitClaim(claim)
                return .blocked(.persistenceIndeterminate)
            }
            releaseComposerSubmitClaim(claim)
            return .blocked(.persistenceFailed)
        }

        // Past this point the message is durably the target's. Every later failure reports a
        // delivery state rather than rolling back, so a retry with the same key can never deliver
        // the row twice.
        let acceptedAt = Date()
        let persistedOnly = AgentSessionLinkSendDelivery(
            targetItemID: userItem.id,
            acceptedAt: acceptedAt,
            deliveryState: .persisted,
            resultingRunState: liveSession.runState.rawValue
        )
        if Task.isCancelled {
            releaseComposerSubmitClaim(claim)
            return .delivered(persistedOnly)
        }

        // The flush awaited, so every admission fact must be re-proven before a provider is started.
        // A window teardown, an observer rebind/close, an in-place rebind that keeps the same session
        // UUID, a workspace switch, a lost composer claim, or a locally started run during that await
        // would otherwise let `startAgentRun(tabID:)` dispatch this turn against whatever now occupies
        // the tab — possibly a replacement binding the grant never covered.
        //
        // The probe is deliberately endpoint/window liveness only and never link liveness: manual
        // revocation is *intended* to lose once the commit fence has been won.
        //
        // Drift retains the durable delivery and withholds only the provider start: the row is
        // already the target's, so rolling it back here would contradict the linearization point and
        // make the same key deliverable twice.
        let dispatchLiveness = liveness()
        guard agentSessionLinkLiveSession(matching: candidate) === liveSession,
              dispatchLiveness.permitsDelivery,
              composerSubmitClaimIsCurrent(claim),
              workspaceManager?.activeWorkspace?.id == candidate.workspaceID
        else {
            releaseComposerSubmitClaim(claim)
            return .delivered(persistedOnly)
        }
        let dispatchAdmission = AgentSessionLinkDeliveryReadiness.evaluate(
            snapshot: Self.agentSessionLinkDeliveryReadinessSnapshot(
                session: liveSession,
                endpointMatchesGrant: dispatchLiveness.targetEndpointIsLive,
                isClosing: dispatchLiveness.targetWindowIsClosing,
                ignoresComposerSubmissionInFlight: true
            )
        )
        if case .blocked = dispatchAdmission {
            releaseComposerSubmitClaim(claim)
            return .delivered(persistedOnly)
        }

        // 8. Provider dispatch. `startAgentRun` is used directly rather than `submitUserTurn` so the
        //    target's *own* Workflow, Interview, and native/skill slash-command handling are neither
        //    applied nor consumed: those all live in `submitUserTurn`/`submitPreparedUserTurn`, and
        //    provider-send slash expansion only triggers when `/` is the first non-whitespace
        //    character, which a bare envelope never is. A one-shot workflow does put its own
        //    template in front, so that guarantee narrows to exactly the one a local workflow turn
        //    already has — `submitUserTurn` wraps before `startAgentRun` too — and never weakens to
        //    a sender-controlled string, because the sender's words stay inside `<message>`.
        //    `.crossSessionDelivery`
        //    additionally leaves any staged handoff untouched, so the target's next *local* send
        //    still receives the continuity it was staged for. Nothing focuses, activates, or
        //    switches the target window.
        let envelope = AgentSessionLinkMessageEnvelope.render(
            sourceSessionID: request.observerSessionID,
            sourceName: request.observerDisplayName,
            linkID: request.linkID,
            linkGeneration: request.linkGeneration,
            message: request.message
        )
        // A per-message workflow is applied to the provider payload only. `session.selectedWorkflow`
        // is never read, written, or restored here, which is what makes preserving the target's own
        // selection structural rather than a cleanup step some failure path could skip.
        let providerMessage = AgentSessionLinkMessageEnvelope.providerPayload(
            envelope: envelope,
            workflow: request.workflow,
            includeBuiltInSessionCleanupGuidance: GlobalSettingsStore.shared
                .showBuiltInWorkflowCleanupGuidance()
        )
        // The run service's `nil` return is "not a Codex native send", not "started", so the
        // recorder is what distinguishes a Claude/ACP/headless pre-start failure from success.
        let startRecorder = AgentRunStartOutcomeRecorder()
        _ = await startAgentRun(
            tabID: candidate.tabID,
            initialMessage: providerMessage,
            directStartOptions: .crossSessionDelivery,
            startOutcome: startRecorder
        )
        releaseComposerSubmitClaim(claim)
        if startRecorder.outcome.didStart {
            agentSessionLinkClearWaitingOnAfterAcceptedTurn(liveSession)
        }

        let resultingRunState = sessions[candidate.tabID]?.runState ?? liveSession.runState
        return .delivered(AgentSessionLinkSendDelivery(
            targetItemID: userItem.id,
            acceptedAt: acceptedAt,
            deliveryState: startRecorder.outcome.didStart ? .runStarted : .runStartFailed,
            resultingRunState: resultingRunState.rawValue
        ))
    }

    /// The live session for an endpoint, or `nil` unless every identity field still matches
    /// byte-for-byte and generation-for-generation.
    private func agentSessionLinkLiveSession(
        matching candidate: AgentSessionLinkEndpointCandidate
    ) -> TabSession? {
        guard let session = sessions[candidate.tabID],
              session.activeAgentSessionID == candidate.sessionID,
              let identity = agentSessionLifecycleIdentity(
                  tabID: candidate.tabID,
                  expectedSessionID: candidate.sessionID
              ),
              identity.monitorEndpoint(windowID: windowID) == candidate.domainEndpoint
        else {
            return nil
        }
        return session
    }

    /// Removes a staged attributed row whose durable persistence failed and restores the turn-runtime
    /// bookkeeping it changed.
    ///
    /// A save is scheduled afterwards so the on-disk copy converges even if the failed flush had
    /// already written the row. The caller must additionally *confirm* that removal durably before it
    /// treats the send as undelivered; a scheduled save alone cannot prove a committed row is gone.
    private func agentSessionLinkRollbackStagedRow(
        itemID: UUID,
        tabID: UUID,
        session: TabSession,
        anchorRollback: AgentTurnUserAnchorRollbackState
    ) {
        if let index = session.items.firstIndex(where: { $0.id == itemID }) {
            _ = session.removeItem(at: index)
        }
        rollbackAgentTurnUserAnchor(anchorRollback, session: session)
        updateBindingsFromSession(session)
        requestUIRefresh(tabID: tabID, urgent: true)
        scheduleSave(for: tabID)
    }
}
