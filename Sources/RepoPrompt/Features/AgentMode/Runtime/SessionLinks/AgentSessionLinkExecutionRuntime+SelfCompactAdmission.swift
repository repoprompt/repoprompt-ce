import Foundation
import RepoPromptDomainRuntime

/// Owns self-only compaction admission and its required save, not the later native completion.
extension AgentSessionLinkExecutionRuntime {
    /// Synchronous admission captures the authoritative run attempt before a future MCP await.
    func agentSelfCompactSchedule(
        command: AgentSessionRuntimeStore.Command,
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        runID: UUID,
        runAttemptID: UUID,
        note: String,
        idempotencyKey: String,
        support: AgentSessionLinkCompactSupport
    ) -> AgentSelfCompactState.Reservation? {
        let session = command.writer.session
        guard command.writer.scope === scope, command.isCurrent,
              sessions[endpoint.tabID] === session,
              agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint,
              session.runID == runID,
              session.runState == .running,
              session.activeRunOwnership?.attemptID == runAttemptID,
              let bindingGeneration = endpoint.persistentBindingGeneration,
              !session.terminalCommitInProgress
        else { return nil }
        let owner = AgentSelfCompactOwner(
            windowID: endpoint.windowID,
            workspaceID: endpoint.workspaceID,
            tabID: endpoint.tabID,
            sessionID: endpoint.sessionID,
            persistentBindingGeneration: bindingGeneration,
            bindingTransitionGeneration: endpoint.bindingTransitionGeneration,
            runID: runID,
            runAttemptID: runAttemptID
        )
        var state = session.selfCompactState
        let reservation = state.reserve(
            note: note, idempotencyKey: idempotencyKey,
            maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.maximumNoteUTF8Bytes(
                windowTokens: AgentModeViewModel.observationContextLoad(for: session)?.windowTokens
            ),
            owner: owner
        )
        if case .scheduled = reservation {
            guard support == .codex || support == .claudeCode || support == .acpAdvertisedCommand else {
                return nil
            }
            state.active?.admittedSupport = support
            session.selfCompactState = state
            session.isDirty = true
            scheduleSave(for: session)
        }
        return reservation
    }

    /// MCP admission is synchronous until the reservation exists. The required save completes while
    /// this tool execution still owns the originating run's active-tool slot, so terminal dispatch
    /// cannot outrun durability. A failed/ambiguous save never leaves an executable request armed.
    func agentSelfCompactMCPAdmission(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        origin: AgentSelfMCPCallOrigin,
        note: String,
        idempotencyKey: String
    ) async -> AgentSelfMCPToolService.Admission {
        guard endpoint == origin.endpoint,
              let session = sessions[endpoint.tabID],
              agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint,
              session.runID == origin.runID,
              session.activeRunOwnership?.attemptID == origin.runAttemptID
        else { return .unavailable }

        var candidate = session.selfCompactState
        let reservation = candidate.reserve(
            note: note, idempotencyKey: idempotencyKey,
            maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.maximumNoteUTF8Bytes(
                windowTokens: AgentModeViewModel.observationContextLoad(for: session)?.windowTokens
            )
        )
        if let answer = agentSelfCompactUnscheduledAdmission(reservation, session: session, endpoint: endpoint) {
            return answer
        }

        guard let command = admit(endpoint: endpoint) else {
            return .blocked(reason: "session_not_exclusive")
        }
        let owner = command.writer.scope
        defer { withExtendedLifetime(owner) {} }
        guard !session.selfCompactPersistenceWarning,
              endpoint.persistentBindingGeneration != nil
        else { return .blocked(reason: "session_not_exclusive") }

        let support = await agentSessionLinkCompactSupport(for: session)
        #if DEBUG
            await test_selfCompactAfterSupport?()
        #endif
        guard sessions[endpoint.tabID] === session,
              agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint,
              session.runID == origin.runID,
              session.activeRunOwnership?.attemptID == origin.runAttemptID
        else { return .unavailable }
        guard command.isCurrent else { return .blocked(reason: "session_not_exclusive") }
        switch support {
        case .notSupported: return .blocked(reason: "not_supported")
        case .noProviderSession: return .blocked(reason: "no_provider_session")
        case .codex, .claudeCode, .acpAdvertisedCommand: break
        }
        var readiness = AgentModeViewModel.agentSessionLinkDeliveryReadinessSnapshot(
            session: session, endpointMatchesGrant: true, isClosing: false
        )
        readiness.runStateIsActive = false // The caller's own still-running turn is expected.
        readiness.pendingSelfCompact = false
        let hasInteraction = readiness.hasWaitingPrompt || readiness.hasPendingAskUser
            || readiness.hasPendingUserInputRequest || readiness.hasPendingApproval
            || readiness.hasPendingPermissionsRequest || readiness.hasPendingMCPElicitationRequest
            || readiness.hasPendingApplyEditsReview || readiness.hasPendingWorktreeMergeReview
        if hasInteraction { return .blocked(reason: "pending_interaction") }
        guard AgentSessionLinkDeliveryReadiness.evaluate(snapshot: readiness) == .ready,
              !AgentSessionLinkExecutionRuntime.agentSessionLinkCompactHasQueuedProviderWork(session)
        else { return .blocked(reason: "busy") }

        guard let accepted = agentSelfCompactSchedule(
            command: command, endpoint: endpoint, runID: origin.runID, runAttemptID: origin.runAttemptID,
            note: note, idempotencyKey: idempotencyKey, support: support
        ) else { return .blocked(reason: "busy") }
        // A concurrent same-key call may have reserved while this one awaited provider support.
        // Answer it exactly as the first check would have, not as a generic busy refusal.
        if let answer = agentSelfCompactUnscheduledAdmission(accepted, session: session, endpoint: endpoint) {
            return answer
        }
        guard case let .scheduled(attempt) = accepted else { return .blocked(reason: "busy") }
        session.selfCompactAdmissionPendingID = attempt.id
        defer {
            if session.selfCompactAdmissionPendingID == attempt.id {
                session.selfCompactAdmissionPendingID = nil
            }
        }
        guard case .success = await owner.persistence.flushSaveRequired(
            writer: command.writer
        ) else {
            settleSelfCompactAdmission(attempt: attempt, command: command, outcome: .recoveryRequired)
            return .blocked(reason: "persistence_indeterminate")
        }
        guard session.selfCompactState.active?.id == attempt.id else { return .blocked(reason: "busy") }
        guard sessions[endpoint.tabID] === session,
              agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint
        else {
            settleSelfCompactAdmission(attempt: attempt, command: command, outcome: .cancelled)
            return .blocked(reason: "busy")
        }
        guard command.isCurrent else {
            settleSelfCompactAdmission(attempt: attempt, command: command, outcome: .cancelled)
            return .blocked(reason: "session_not_exclusive")
        }
        guard session.runID == origin.runID, session.activeRunOwnership?.attemptID == origin.runAttemptID,
              let active = session.selfCompactState.active, active.phase == .scheduled
        else {
            settleSelfCompactAdmission(attempt: attempt, command: command, outcome: .cancelled)
            return .blocked(reason: "busy")
        }
        return .scheduled(active)
    }

    /// Disarm only the reservation created by this admission, including after uniqueness loss.
    /// A different object/record, or an attempt already handed to native completion, is not ours.
    private func settleSelfCompactAdmission(
        attempt: AgentSelfCompactAttempt, command: AgentSessionRuntimeStore.Command,
        outcome: AgentSelfCompactSettlement.Outcome
    ) {
        let session = command.writer.session
        guard session.persistentSessionBindingIdentity == command.writer.binding,
              session.selfCompactState.active?.id == attempt.id,
              session.selfCompactState.active?.phase == .scheduled else { return }
        var state = session.selfCompactState
        state.settle(outcome, noteDelivery: .notSent, completionVerified: false)
        session.selfCompactState = state
        session.isDirty = true
        // A retiring original writer can save its final state. A conflict or reacquisition cannot
        // turn this cleanup into an admission-issued compensating write through a successor.
        if let scope, scope.originatingWriter(identity: command.identity, session: session) != nil {
            scope.persistence.scheduleSave(for: session)
        }
    }

    /// The admission answer for every reservation that did not schedule a new request; nil only
    /// for `.scheduled`, which the caller continues to persist.
    private func agentSelfCompactUnscheduledAdmission(
        _ reservation: AgentSelfCompactState.Reservation,
        session: TabSession,
        endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentSelfMCPToolService.Admission? {
        switch reservation {
        case let .duplicate(requestID):
            guard session.selfCompactAdmissionPendingID != requestID else {
                return .blocked(reason: "persistence_pending")
            }
            if session.selfCompactState.active?.id == requestID,
               !agentSelfCompactHasExclusiveWriter(session, endpoint: endpoint, allowRetiringWriter: true)
            {
                return .blocked(reason: "session_not_exclusive")
            }
            return .duplicate(requestID: requestID, status: session.selfCompactState.status)
        case .conflict:
            return .blocked(reason: "idempotency_conflict")
        case .alreadyPending:
            return .blocked(reason: "compact_already_pending")
        case let .invalidNote(.tooLong(byteCount, maximum)):
            // Reservation and this projection are synchronous; report the same window basis.
            let limit = AgentSessionSelfCompactNotePolicy.noteLimit(
                windowTokens: AgentModeViewModel.observationContextLoad(for: session)?.windowTokens
            )
            return .noteTooLong(byteCount: byteCount, maximum: maximum, basis: limit.basis)
        case .invalidNote, .invalidIdempotencyKey:
            return .blocked(reason: "busy") // Service content/key validation rejects these before admission.
        case .scheduled:
            return nil
        }
    }

    func agentSelfCompactHasExclusiveWriter(_ session: TabSession, endpoint: DomainAgentSessionLinkEndpointIdentity, allowRetiringWriter: Bool = false) -> Bool {
        // A window census misses independent runtime scopes. Use the same exact writer
        // authority as persistence, before reserving a request or spending its key.
        guard let scope, case let .unique(writer) = scope.resolveWriter(
            workspaceID: endpoint.workspaceID, sessionID: endpoint.sessionID
        ) else { return false }
        return writer.scope === scope && writer.session === session && writer.binding.tabID == endpoint.tabID
            && writer.binding.generation == endpoint.persistentBindingGeneration
            && (allowRetiringWriter || !writer.scope.isRetiring)
    }
}
