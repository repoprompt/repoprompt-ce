import Foundation
import RepoPromptDomainRuntime

/// One-shot, exact-object managed Stop. The authority fence precedes every target mutation;
/// cancellation then follows the same run-service path as the lane user's Stop.
extension AgentModeViewModel {
    func agentSessionLinkPerformStop(
        to candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkStopRequest,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        queueHasCommittedDrain: @escaping @MainActor () -> Bool,
        withdrawInbound: @escaping @MainActor () -> Bool,
        commitAuthorization: @MainActor () async -> AgentSessionLinkSendCommitOutcome,
        teardownDeadlineSeconds: TimeInterval = 30,
        auditDeadlineSeconds: TimeInterval = 5,
        deadlineSleep: @escaping @MainActor (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        beforeCleanupTask: @escaping @MainActor () -> Void = {}
    ) async -> AgentSessionLinkStopTransactionOutcome {
        guard let session = agentSessionLinkLiveSession(matching: candidate), liveness().permitsDelivery else {
            return .blocked(.endpointInvalidated)
        }
        guard (try? mcpSettledLiveSessionForStop(sessionID: candidate.sessionID)) === session else {
            return .blocked(.targetLoading)
        }
        let initial = Self.agentSessionLinkDeliveryReadinessSnapshot(
            session: session, endpointMatchesGrant: true, isClosing: false
        )
        if case let .blocked(failure) = AgentSessionLinkStopAdmission.classify(initial) {
            return .blocked(failure)
        }
        if queueHasCommittedDrain() { return .blocked(.targetBusy) }

        let commit = await commitAuthorization()
        guard commit == .committed else { return .blocked(commit.refusal) }

        // No suspension from this recheck through selection, queue withdrawal and gate claim.
        guard agentSessionLinkLiveSession(matching: candidate) === session,
              liveness().permitsDelivery,
              workspaceManager?.activeWorkspace?.id == candidate.workspaceID,
              (try? mcpSettledLiveSessionForStop(sessionID: candidate.sessionID)) === session
        else { return .blocked(.endpointInvalidated) }
        let snapshot = Self.agentSessionLinkDeliveryReadinessSnapshot(
            session: session, endpointMatchesGrant: true, isClosing: false
        )
        let selection = AgentSessionLinkStopAdmission.classify(snapshot)
        if case let .blocked(failure) = selection { return .blocked(failure) }
        if queueHasCommittedDrain() { return .blocked(.targetBusy) }
        guard let binding = session.persistentSessionBindingIdentity else { return .blocked(.targetBusy) }

        if selection == .notRunning {
            prepareAgentRunCancellation(session: session, intent: .userStop, origin: .explicitStop)
            return .settled(Self.agentSessionLinkStopReceipt(
                request: request, targetSessionID: candidate.sessionID,
                result: .notRunning, stopRequested: false, audit: .notRequired,
                runState: session.runState.rawValue
            ))
        }
        if selection == .activeRun, session.activeRunOwnership == nil || session.runID == nil {
            return .blocked(.targetBusy)
        }
        guard withdrawInbound() else { return .blocked(.targetBusy) }

        let admission = AgentRunCancellationAdmission(
            scope: selection == .activeRun ? .activeRun : .pendingStart,
            session: session,
            binding: binding,
            expectedOwnership: session.activeRunOwnership,
            expectedRunID: session.runID,
            cancellationGeneration: session.stopState.cancellationGeneration,
            pendingStartFence: nil,
            validateAndClaim: { [weak self, weak session] in
                guard let self, let session else { return false }
                return agentSessionLinkLiveSession(matching: candidate) === session
                    && workspaceManager?.activeWorkspace?.id == candidate.workspaceID
            }
        )

        if selection == .pendingStart {
            guard withdrawPendingStartForSessionLink(session: session, admission: admission) else {
                return .settled(Self.agentSessionLinkStopReceipt(
                    request: request, targetSessionID: candidate.sessionID,
                    result: .stopFailed, failure: .cancellationUnconfirmed,
                    stopRequested: true, audit: .notRequired
                ))
            }
            let itemID = agentSessionLinkAppendStopRow(
                request: request, candidate: candidate, session: session, binding: binding
            )
            let audit = await agentSessionLinkFlushStopAudit(
                candidate: candidate, session: session, binding: binding,
                itemID: itemID, deadlineSeconds: auditDeadlineSeconds,
                deadlineSleep: deadlineSleep
            )
            return .settled(Self.agentSessionLinkStopReceipt(
                request: request, targetSessionID: candidate.sessionID,
                result: .stopped, stopRequested: true, itemID: itemID,
                audit: audit, runState: "pending_start_withdrawn"
            ))
        }

        guard let ownership = session.activeRunOwnership, session.runID != nil else {
            return .blocked(.targetBusy)
        }
        // This is the synchronous claim: a deferred producer cannot enter while the cleanup task
        // is waiting for its first MainActor turn.
        guard session.stopState.claimManagedStop(id: request.requestID, binding: binding) else {
            return .blocked(.targetBusy)
        }
        // Claim-time withdrawal is independent of whether the run still exists when cleanup starts.
        prepareAgentRunCancellation(session: session, intent: .userStop, origin: .explicitStop)
        withdrawQueuedWorkForManagedStop(session: session)
        let claimedAdmission = AgentRunCancellationAdmission(
            scope: .activeRun, session: session, binding: binding,
            expectedOwnership: admission.expectedOwnership, expectedRunID: admission.expectedRunID,
            cancellationGeneration: session.stopState.cancellationGeneration,
            pendingStartFence: nil, validateAndClaim: admission.validateAndClaim
        )
        session.noteMonitorObservationInputsChanged()
        requestUIRefresh(tabID: candidate.tabID, urgent: true)
        let recorder = AgentRunCancellationOutcomeRecorder(
            expectedOwnership: ownership,
            expectedRunID: session.runID,
            expectedBinding: binding,
            onAcceptedPrimaryPublication: { [weak self, weak session] _ in
                guard let self, let session else { return }
                _ = agentSessionLinkAppendStopRow(
                    request: request, candidate: candidate, session: session, binding: binding
                )
            }
        )
        let teardown = AgentSessionLinkStopSignal<Bool>()
        let audit = AgentSessionLinkStopSignal<DomainAgentSessionLinkStopReceipt.AuditStatus>()
        Task { [weak self, weak session] in
            session?.stopState.markCleanupStarted(id: request.requestID, binding: binding)
            guard let self, let session else {
                if let session {
                    _ = session.stopState.releaseManagedStop(id: request.requestID, binding: binding)
                    session.noteMonitorObservationInputsChanged()
                }
                teardown.finish(false)
                audit.finish(.unknown)
                return
            }
            beforeCleanupTask()
            let routed = await cancelAgentRunForSessionLink(
                session: session, admission: claimedAdmission, outcomeRecorder: recorder
            )
            teardown.finish(routed && recorder.teardownCompleted)
            if session.stopState.releaseManagedStop(id: request.requestID, binding: binding) {
                session.noteMonitorObservationInputsChanged()
                requestUIRefresh(tabID: candidate.tabID, urgent: true)
            }
            let itemID = session.items.contains(where: { $0.id == request.requestID })
                ? request.requestID : nil
            await audit.finish(agentSessionLinkFlushStopAudit(
                candidate: candidate, session: session, binding: binding,
                itemID: itemID, deadlineSeconds: auditDeadlineSeconds,
                deadlineSleep: deadlineSleep
            ))
        }
        Task {
            await deadlineSleep(teardownDeadlineSeconds)
            teardown.finish(false)
            session.stopState.markCleanupUnclaimedIfNeverStarted(id: request.requestID, binding: binding)
        }
        let teardownCompleted = await teardown.value()
        /// A terminal state on this mutable session is not evidence that the captured run ended:
        /// the same object can be rebound or repurposed for a replacement attempt while cleanup waits.
        func matchedTerminalRunState() -> String? {
            guard session.persistentSessionBindingIdentity == binding,
                  session.runState.isTerminalForCommit else { return nil }
            if let revision = session.lastTerminalCommitRevision {
                guard revision.ownership == ownership,
                      revision.expectedRunID == admission.expectedRunID else { return nil }
                return revision.terminalState.rawValue
            }
            guard session.activeRunOwnership == ownership,
                  session.runID == admission.expectedRunID else { return nil }
            return session.runState.rawValue
        }
        let accepted = if case .accepted? = recorder.publicationResult { true } else { false }
        let itemID = session.items.contains(where: { $0.id == request.requestID })
            ? request.requestID : nil
        if !teardownCompleted {
            if !recorder.initiatedCancellation, let terminalState = matchedTerminalRunState() {
                return .settled(Self.agentSessionLinkStopReceipt(
                    request: request, targetSessionID: candidate.sessionID,
                    result: .notRunning, stopRequested: false,
                    audit: .notRequired, runState: terminalState
                ))
            }
            if recorder.initiatedCancellation, recorder.teardownCompleted,
               recorder.publicationResult == nil, let terminalState = matchedTerminalRunState()
            {
                return .settled(Self.agentSessionLinkStopReceipt(
                    request: request, targetSessionID: candidate.sessionID,
                    result: .notRunning, stopRequested: true,
                    teardownCompleted: true, audit: .notRequired,
                    runState: terminalState
                ))
            }
            // An accepted cancellation publication means the run was stopped; only local
            // teardown is unconfirmed, which `teardownCompleted: false` reports as a warning.
            let failure: DomainAgentSessionLinkStopReceipt.FailureReason? = switch recorder.publicationResult {
            case .accepted?: nil
            case .stale?: .terminalPublicationStale
            case .rejected?: .terminalPublicationRejected
            case nil: recorder.initiatedCancellation ? .cancellationUnconfirmed : .targetChanged
            }
            return .settled(Self.agentSessionLinkStopReceipt(
                request: request, targetSessionID: candidate.sessionID,
                result: accepted ? .stopped : .stopFailed, failure: failure,
                stopRequested: recorder.initiatedCancellation,
                teardownCompleted: recorder.teardownCompleted,
                itemID: itemID, audit: itemID == nil ? .notRequired : .unknown,
                runState: recorder.primaryRevision?.terminalState.rawValue
            ))
        }
        Task {
            await deadlineSleep(auditDeadlineSeconds)
            audit.finish(.unknown)
        }
        let auditStatus = await audit.value()
        if recorder.initiatedCancellation, recorder.teardownCompleted,
           recorder.publicationResult == nil, let terminalState = matchedTerminalRunState()
        {
            return .settled(Self.agentSessionLinkStopReceipt(
                request: request, targetSessionID: candidate.sessionID,
                result: .notRunning, stopRequested: true,
                teardownCompleted: true, audit: .notRequired,
                runState: terminalState
            ))
        }
        let failure: DomainAgentSessionLinkStopReceipt.FailureReason? = switch recorder.publicationResult {
        case .accepted?: nil
        case .stale?: .terminalPublicationStale
        case .rejected?: .terminalPublicationRejected
        case nil: recorder.initiatedCancellation ? .cancellationUnconfirmed : .targetChanged
        }
        return .settled(Self.agentSessionLinkStopReceipt(
            request: request, targetSessionID: candidate.sessionID,
            result: accepted ? .stopped : .stopFailed,
            failure: failure,
            stopRequested: recorder.initiatedCancellation,
            teardownCompleted: recorder.teardownCompleted,
            itemID: itemID, audit: auditStatus,
            runState: recorder.primaryRevision?.terminalState.rawValue
        ))
    }

    private func agentSessionLinkAppendStopRow(
        request: AgentSessionLinkStopRequest,
        candidate: AgentSessionLinkEndpointCandidate,
        session: TabSession,
        binding: AgentPersistentSessionBindingIdentity
    ) -> UUID? {
        guard agentSessionLinkLiveSession(matching: candidate) === session,
              session.persistentSessionBindingIdentity == binding
        else { return nil }
        if session.items.contains(where: { $0.id == request.requestID }) { return request.requestID }
        session.appendItem(.overseerRunStopped(
            stopID: request.requestID, stoppedAt: Date(),
            attribution: request.attribution, sequenceIndex: session.nextSequenceIndex
        ))
        updateBindingsFromSession(session)
        scheduleSave(for: candidate.tabID)
        requestUIRefresh(tabID: candidate.tabID, urgent: true)
        return request.requestID
    }

    private func agentSessionLinkFlushStopAudit(
        candidate: AgentSessionLinkEndpointCandidate,
        session: TabSession,
        binding: AgentPersistentSessionBindingIdentity,
        itemID: UUID?,
        deadlineSeconds: TimeInterval,
        deadlineSleep: @escaping @MainActor (TimeInterval) async -> Void
    ) async -> DomainAgentSessionLinkStopReceipt.AuditStatus {
        guard let itemID else { return .failed }
        guard agentSessionLinkLiveSession(matching: candidate) === session,
              session.persistentSessionBindingIdentity == binding
        else { return .failed }
        let signal = AgentSessionLinkStopSignal<DomainAgentSessionLinkStopReceipt.AuditStatus>()
        Task { [weak self, weak session] in
            guard let self, let session else { signal.finish(.unknown)
                return
            }
            guard agentSessionLinkLiveSession(matching: candidate) === session,
                  session.persistentSessionBindingIdentity == binding,
                  session.items.contains(where: { $0.id == itemID })
            else { signal.finish(.failed)
                return
            }
            let result = await flushSaveRequired(
                for: candidate.tabID, workspaceID: candidate.workspaceID
            )
            guard agentSessionLinkLiveSession(matching: candidate) === session,
                  session.persistentSessionBindingIdentity == binding,
                  session.items.contains(where: { $0.id == itemID })
            else { signal.finish(.failed)
                return
            }
            switch result {
            case .success: signal.finish(.persisted)
            case .failure: signal.finish(.failed)
            }
        }
        Task {
            await deadlineSleep(deadlineSeconds)
            signal.finish(.unknown)
        }
        return await signal.value()
    }

    private static func agentSessionLinkStopReceipt(
        request: AgentSessionLinkStopRequest,
        targetSessionID: UUID,
        result: DomainAgentSessionLinkStopReceipt.Result,
        failure: DomainAgentSessionLinkStopReceipt.FailureReason? = nil,
        stopRequested: Bool?,
        teardownCompleted: Bool? = nil,
        itemID: UUID? = nil,
        audit: DomainAgentSessionLinkStopReceipt.AuditStatus,
        runState: String? = nil
    ) -> DomainAgentSessionLinkStopReceipt {
        DomainAgentSessionLinkStopReceipt(
            requestID: request.requestID, targetSessionID: targetSessionID,
            result: result, failureReason: failure,
            stopRequested: stopRequested, teardownCompleted: teardownCompleted,
            targetItemID: itemID?.uuidString, auditStatus: audit,
            resultingRunState: runState, settledAt: Date()
        )
    }
}
