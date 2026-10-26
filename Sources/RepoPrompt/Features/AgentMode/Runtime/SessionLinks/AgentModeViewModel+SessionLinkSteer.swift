import Foundation
import RepoPromptDomainRuntime

// The target-side execution of one managed cross-session `steer`.
//
// An idle target goes through the ordinary attributed send transaction — durable row before the run
// starts — framed as managed direction. A running target, or one waiting for its next instruction,
// is steered through the same submission routing a local composer message takes
// (`submitAgentSessionLinkManagedSteer`), after the authority commit fence re-proved the user's
// management delegation. This file owns no authority and no idempotency: the bridge reserved the
// ledger entry and supplies the fence. Invariant: every refusal before submission leaves the target
// byte-identical, and nothing here reads, clears, or restores the target user's composer.

extension AgentModeViewModel {
    /// Bound on waiting for the provider-level outcome of an already-submitted managed steer. The
    /// Codex acknowledgement tracker settles far sooner; this only stops a route that never reports
    /// from parking the observer's tool call.
    static let agentSessionLinkManagedSteerOutcomeTimeoutSeconds: TimeInterval = 30

    /// Pre-mutation steer admission from this exact live target's facts.
    func agentSessionLinkSteerAdmission(
        for session: TabSession,
        liveness: AgentSessionLinkSendLiveness
    ) -> AgentSessionLinkSteerAdmission {
        // Any prompt other than an instruction wait blocks: the overseer answers it with `respond`,
        // or the target's own user does. Apply-edits reviews are not projected as interactions, so
        // they are checked directly.
        let pendingPromptExists = session.pendingApplyEditsReview != nil
            || mcpPendingInteraction(for: session).map { $0.kind != .instruction } == true
        return AgentSessionLinkSteerAdmission.evaluate(
            readiness: Self.agentSessionLinkDeliveryReadinessSnapshot(
                session: session,
                endpointMatchesGrant: liveness.targetEndpointIsLive,
                isClosing: liveness.targetWindowIsClosing
            ),
            runStateIsActive: session.runState.isActive,
            pendingPromptExists: pendingPromptExists,
            route: agentSessionLinkManagedSteerRoute(for: session)
        )
    }

    /// Runs one managed steer for one exact live endpoint.
    ///
    /// Ordering is the security contract:
    ///
    /// 1. exact endpoint identity of both incarnations plus the target window's closing state,
    /// 2. pure admission (no mutation on refusal); an idle target hands off to the send transaction,
    /// 3. the authority commit fence, which re-proves the exact grant *and* the management
    ///    delegation, as the last suspension before any row exists,
    /// 4. synchronous re-validation of identity, workspace, and admission,
    /// 5. synchronous submission of the attributed row through the target's own provider routing,
    /// 6. the provider-level outcome.
    func agentSessionLinkPerformSteer(
        to candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkSendRequest,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        commitAuthorization: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkSendTransactionOutcome {
        var managedRequest = request
        managedRequest.framing = .management

        // 1. Exact endpoint incarnations.
        guard let session = agentSessionLinkLiveSession(matching: candidate) else {
            return .blocked(.endpointSession)
        }
        let admissionLiveness = liveness()
        guard admissionLiveness.permitsDelivery else {
            return .blocked(.invalidated(admissionLiveness))
        }

        // 2. Pure admission. Nothing has suspended since step 1, so the send transaction's own
        //    admission re-reads the same state it was classified from.
        switch agentSessionLinkSteerAdmission(for: session, liveness: admissionLiveness) {
        case .idleTurn:
            return await agentSessionLinkPerformSend(
                to: candidate,
                request: managedRequest,
                liveness: liveness,
                commitAuthorization: commitAuthorization
            )
        case let .blocked(failure):
            return .blocked(failure == .endpointInvalidated ? .endpointReadiness : failure)
        case .steer:
            break
        }

        // 3. Authority fence. Losing it — revocation, withdrawn management, shutdown — leaves the
        //    target untouched.
        let commit = await commitAuthorization()
        guard commit == .committed else {
            return .blocked(commit.refusal)
        }

        // 4. The fence awaited, so every fact is re-proven. From here to submission nothing
        //    suspends. A workspace switch is an endpoint loss: a steer never follows a target into a
        //    workspace its grant was not given for.
        let postCommitLiveness = liveness()
        guard let liveSession = agentSessionLinkLiveSession(matching: candidate),
              liveSession === session
        else {
            return .blocked(.endpointPostSession)
        }
        guard postCommitLiveness.permitsDelivery else {
            return .blocked(.invalidated(postCommitLiveness, postCommit: true))
        }
        guard let workspaceID = workspaceManager?.activeWorkspace?.id else {
            return .blocked(.endpointMissingWorkspace)
        }
        guard workspaceID == candidate.workspaceID else {
            return .blocked(.endpointWorkspace)
        }
        let route: AgentSessionLinkManagedSteerRoute
        switch agentSessionLinkSteerAdmission(for: liveSession, liveness: postCommitLiveness) {
        case let .steer(current):
            route = current
        case .idleTurn:
            // The run settled while the fence was in flight. An idle target is delivered only through
            // the durable, exact-endpoint send transaction, and that path cannot be entered past this
            // fence. Nothing was staged, so the bridge releases the key and a retry takes the idle
            // path.
            return .blocked(.targetBusy)
        case let .blocked(failure):
            return .blocked(failure)
        }

        // 5. Submission. The provider sees RepoPrompt's management framing around the overseer's
        //    words; the transcript row keeps the raw text plus the same attribution badge a `send`
        //    row carries.
        let envelope = AgentSessionLinkMessageEnvelope.render(
            sourceSessionID: managedRequest.observerSessionID,
            sourceName: managedRequest.observerDisplayName,
            linkID: managedRequest.linkID,
            linkGeneration: managedRequest.linkGeneration,
            message: managedRequest.message,
            framing: .management
        )
        let sink = AgentSessionLinkManagedSteerSink()
        let turn = AgentSessionLinkManagedTurn(
            candidate: candidate,
            providerText: envelope,
            attribution: managedRequest.attribution,
            sink: sink
        )
        let acceptedAt = Date()
        guard submitAgentSessionLinkManagedSteer(
            tabID: candidate.tabID,
            session: liveSession,
            displayText: managedRequest.message,
            turn: turn,
            route: route
        ),
            let targetItemID = sink.appendedItemID
        else {
            return .blocked(.targetBusy)
        }
        requestUIRefresh(tabID: candidate.tabID, urgent: true)

        // 6. Provider-level outcome. Past submission nothing is rolled back here: the submission
        //    route itself withdraws a row it could not deliver, and reports that as `notAccepted`.
        let outcome = await sink.awaitOutcome(
            timeoutSeconds: Self.agentSessionLinkManagedSteerOutcomeTimeoutSeconds
        )
        let resultingRunState = sessions[candidate.tabID]?.runState ?? liveSession.runState
        switch outcome {
        case let .delivered(state):
            return .delivered(AgentSessionLinkSendDelivery(
                targetItemID: targetItemID,
                acceptedAt: acceptedAt,
                deliveryState: state,
                resultingRunState: resultingRunState.rawValue
            ))
        case .notAccepted:
            return .blocked(.steerNotAccepted)
        case .unconfirmed:
            return .blocked(.steerUnconfirmed)
        }
    }
}
