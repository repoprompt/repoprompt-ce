import Combine
import Foundation
import RepoPromptDomainRuntime

/// Independent scheduling; the existing Auto-wake slot owns provider execution.
@MainActor
extension AgentModeViewModel {
    static let periodicWakeMessage = "[Periodic wake-up. Perform only checks or follow-ups previously requested by the user. If none are due, take no action and return to idle.]"

    static func agentSessionLinkPeriodicWakeSessionIsIdle(_ session: TabSession) -> Bool {
        AgentSessionLinkDeliveryReadiness.evaluate(snapshot: agentSessionLinkDeliveryReadinessSnapshot(
            session: session, endpointMatchesGrant: true, isClosing: false
        )).isReady
            && session.runState != .waitingForUser
            && session.instructionContinuation == nil
            && !session.hasActiveCodexHookGateOperation
            && session.codexFallbackQueue.isEmpty
            && session.codexFallbackDispatchInFlight == nil
            && session.codexFallbackHookGateOwnerBlocker == nil
    }

    func agentSessionLinkPeriodicWakeIsEligible(
        _ session: TabSession, endpoint: DomainAgentSessionLinkEndpointIdentity, requiresReadyCatalog: Bool = true
    ) -> Bool {
        guard sessions[endpoint.tabID] === session,
              agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint,
              session.oversight.periodicIdleWakeEnabled,
              session.hasLoadedPersistedState, !session.bindingTransitionInProgress,
              agentSessionLinkPeriodicObserverIsLive(endpoint),
              let published = agentSessionLinkPromptInventoryBySessionID[endpoint.sessionID],
              published.endpoint == endpoint, !published.inventory.isEmpty
        else { return false }
        guard requiresReadyCatalog else { return true }
        guard let context = agentSessionLinkPromptContext(for: session),
              context.epoch.endpoint == endpoint, context.epoch.allowsSupplement,
              !context.inventory.isEmpty else { return false }
        return true
    }

    /// Excludes this producer's own active run and composer claim.
    func agentSessionLinkPeriodicPreparationIsUnblocked(_ session: TabSession) -> Bool {
        !session.terminalCommitInProgress && !session.bindingTransitionInProgress
            && !session.isChangingExecutionLocation && !session.isPreparingInitialWorktree
            && session.pendingInstructions.isEmpty && session.pendingACPSteeringInstructions.isEmpty
            && session.pendingClaudeSteeringInstructions.isEmpty
            && session.pendingAskUser == nil && session.pendingUserInputRequest == nil
            && session.pendingApproval == nil && session.pendingPermissionsRequest == nil
            && session.pendingMCPElicitationRequest == nil && session.pendingApplyEditsReview == nil
            && session.pendingWorktreeMergeReview == nil && !session.hasPendingCodexHookReviewWait
            && session.instructionContinuation == nil
    }

    func agentSessionLinkReconcilePeriodicWake(for endpoint: DomainAgentSessionLinkEndpointIdentity) {
        guard let session = sessions[endpoint.tabID] else { return }
        guard agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint else {
            if session.oversight.periodicEndpoint == endpoint { session.oversight.retirePeriodicScheduling() }
            return
        }
        agentSessionLinkReleasePeriodicACPContinuationSlot(for: session)
        if session.oversight.periodicEndpoint != endpoint {
            session.oversight.retirePeriodicScheduling()
            session.oversight.periodicEndpoint = endpoint
        }
        if session.oversight.periodicObservation == nil,
           session.oversight.periodicIdleWakeEnabled || session.oversight.pendingAutoWake?.isPeriodic == true
        {
            session.oversight.periodicObservation = session.monitorReadinessChangePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak session] _ in
                    MainActor.assumeIsolated {
                        guard let self, let session, self.sessions[endpoint.tabID] === session else { return }
                        self.agentSessionLinkReconcilePeriodicWake(for: endpoint)
                    }
                }
        }
        // A busy observer cannot start an idle span, but an owned periodic producer still needs
        // eligibility-loss settlement and the continuation handling above.
        if session.oversight.pendingAutoWake?.isPeriodic != true,
           !Self.agentSessionLinkPeriodicWakeSessionIsIdle(session)
        {
            session.oversight.invalidatePeriodicIdleSpan()
            if !session.oversight.periodicIdleWakeEnabled {
                session.oversight.periodicObservation = nil
            }
            return
        }
        let preparing = session.oversight.pendingAutoWake?.isPeriodic == true
            && session.oversight.pendingAutoWake?.phase.ownsTransportBoundary == true
        guard agentSessionLinkPeriodicWakeIsEligible(session, endpoint: endpoint, requiresReadyCatalog: !preparing) else {
            session.oversight.invalidatePeriodicIdleSpan()
            if let attempt = session.oversight.pendingAutoWake,
               attempt.isPeriodic, attempt.phase != .cancelledBeforeDispatch
            { cancelAgentSessionLinkAutoWake(for: endpoint, reason: .eligibilityLost) }
            if !session.oversight.periodicIdleWakeEnabled, session.oversight.pendingAutoWake?.isPeriodic != true {
                session.oversight.periodicObservation = nil
            }
            return
        }
        guard Self.agentSessionLinkPeriodicWakeSessionIsIdle(session) else {
            session.oversight.invalidatePeriodicIdleSpan()
            return
        }
        let clock = session.oversight.snoozeClock
        let baseline = session.oversight.periodicIdleSince ?? clock.now()
        session.oversight.periodicIdleSince = baseline
        let deadline = baseline.advanced(by: .seconds(
            AgentSessionLinkPeriodicWakeInterval.normalized(session.oversight.periodicIdleWakeIntervalSeconds)
        ))
        guard session.oversight.periodicDeadline != deadline else { return }
        session.oversight.periodicDeadlineTask?.cancel()
        let token = UUID()
        session.oversight.periodicDeadline = deadline
        session.oversight.periodicDeadlineToken = token
        session.oversight.periodicDeadlineTask = Task { @MainActor [weak self] in
            do { try await clock.sleepUntil(deadline) } catch { return }
            guard !Task.isCancelled else { return }
            self?.agentSessionLinkPeriodicWakeDeadline(endpoint: endpoint, token: token, deadline: deadline)
        }
    }

    func agentSessionLinkPeriodicWakeDeadline(
        endpoint: DomainAgentSessionLinkEndpointIdentity, token: UUID, deadline: ContinuousClock.Instant
    ) {
        guard let session = sessions[endpoint.tabID],
              agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint,
              session.oversight.periodicDeadlineToken == token,
              session.oversight.periodicDeadline == deadline else { return }
        guard session.oversight.snoozeClock.now() >= deadline else {
            session.oversight.periodicDeadline = nil
            agentSessionLinkReconcilePeriodicWake(for: endpoint)
            return
        }
        session.oversight.invalidatePeriodicIdleSpan()
        guard agentSessionLinkPeriodicWakeIsEligible(session, endpoint: endpoint),
              Self.agentSessionLinkPeriodicWakeSessionIsIdle(session) else { return }
        let attempt = AgentSessionLinkAutoWakeAttempt(
            wakeID: UUID(), observerEndpoint: endpoint,
            queueEpoch: nil, queueRevision: 0, wakeFingerprint: nil,
            admissionBasis: .periodic, attemptedFingerprint: nil,
            physicalOutcome: .notAttempted, phase: .scheduled, task: nil
        )
        session.oversight.pendingAutoWake = attempt
        agentSessionLinkScheduleAutoWakeReevaluation(wakeID: attempt.wakeID, endpoint: endpoint)
    }

    func agentSessionLinkPeriodicProducerHasSettled(_ session: TabSession) -> Bool {
        guard let attempt = session.oversight.pendingAutoWake, attempt.isPeriodic,
              attempt.periodicStartReturned else { return false }
        // A startup refusal can have no producer, but missing capture never proves an active run
        // harmless. Late ACP startup installs its task even when the reservation was cancelled.
        if attempt.periodicProducerTask == nil, attempt.periodicProducerDispatchID == nil {
            return !session.runState.isActive && !session.terminalCommitInProgress
        }
        guard !session.runState.isActive,
              !session.terminalCommitInProgress,
              session.codexFallbackQueue.isEmpty, session.codexFallbackDispatchInFlight == nil,
              session.codexFallbackPumpTask == nil else { return false }
        return true
    }

    /// Uses the shared reservation, physical hooks and finalizer, but never a waiting continuation.
    func agentSessionLinkRunPeriodicAttempt(_ attempt: AgentSessionLinkAutoWakeAttempt, session: TabSession) async {
        let endpoint = attempt.observerEndpoint
        guard !session.runState.isActive, session.runState != .waitingForUser,
              !session.mcpFollowUpRunPending, !session.hasActiveCodexHookGateOperation,
              agentSessionLinkPeriodicPreparationIsUnblocked(session),
              session.codexFallbackQueue.isEmpty, session.codexFallbackDispatchInFlight == nil,
              let target = makeComposerSubmitTarget(tabID: endpoint.tabID, session: session),
              target.route == .existingAgentSession,
              target.expectedSourceAgentSessionID == endpoint.sessionID
        else {
            cancelAgentSessionLinkAutoWake(for: endpoint, reason: .eligibilityLost)
            return
        }
        let submission = AgentComposerSubmitAttempt(
            id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: ""
        )
        guard case let .claimed(claim) = claimComposerSubmitAttempt(submission, requireActiveTabOwnership: false) else {
            cancelAgentSessionLinkAutoWake(for: endpoint, reason: .eligibilityLost)
            return
        }
        guard var current = session.oversight.pendingAutoWake,
              current.wakeID == attempt.wakeID, current.phase == .scheduled,
              agentSessionLinkPeriodicWakeIsEligible(session, endpoint: endpoint)
        else {
            releaseComposerSubmitClaim(claim)
            if session.oversight.pendingAutoWake?.wakeID == attempt.wakeID {
                cancelAgentSessionLinkAutoWake(for: endpoint, reason: .eligibilityLost)
            }
            return
        }
        current.phase = .preparingDispatch
        current.periodicComposerAttemptID = submission.id
        session.oversight.pendingAutoWake = current
        _ = await startAgentRun(
            tabID: endpoint.tabID,
            initialMessage: Self.periodicWakeMessage,
            directStartOptions: .periodicWake(wakeID: attempt.wakeID)
        )
        if var current = session.oversight.pendingAutoWake, current.wakeID == attempt.wakeID {
            current.periodicStartReturned = true
            session.oversight.pendingAutoWake = current
        }
        releaseComposerSubmitClaim(claim)
        await agentSessionLinkAwaitPhysicalDispatchSettlement(wakeID: attempt.wakeID, endpoint: endpoint)
    }
}
