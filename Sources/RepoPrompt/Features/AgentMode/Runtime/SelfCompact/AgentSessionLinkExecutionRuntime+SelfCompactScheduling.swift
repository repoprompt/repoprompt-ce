import Foundation
import RepoPromptDomainRuntime

/// Required terminal effects belong to the link executor, independently of presentation.
extension AgentSessionLinkExecutionRuntime {
    /// Register the actual producer before its first MainActor turn. Its receipt outlives phase,
    /// command admission and private coordinator handles, but never the producer's real exit.
    func trackSelfCompactProducer(_ task: Task<Void, Never>, for session: TabSession, requestID: UUID) {
        let effectID = UUID()
        pendingSelfCompactEffects[effectID] = .init(session: session, requestID: requestID, task: task)
        session.noteMonitorObservationInputsChanged()
        Task { @MainActor [weak self] in
            await task.value
            self?.finishSelfCompactEffect(effectID, session: session, requestID: requestID)
        }
    }

    func hasPendingSelfCompactEffects(for session: TabSession, requestID: UUID? = nil) -> Bool {
        pendingSelfCompactEffects.values.contains {
            $0.session === session && (requestID == nil || $0.requestID == requestID)
        }
    }

    /// Shared host resources outlive every owner-held effect, including removed/replaced objects.
    func hasPendingSelfCompactEffects() -> Bool {
        !pendingSelfCompactEffects.isEmpty
    }

    func drainPendingSelfCompactEffects() async {
        await drainSelfCompactEffects(session: nil, requestID: nil)
    }

    /// Cancellation of a waiter must neither cancel an original producer nor acknowledge its exit.
    /// No current-writer check: originating effects remain joinable during retirement/replacement.
    func drainPendingSelfCompactEffects(for session: TabSession, requestID: UUID? = nil) async {
        await drainSelfCompactEffects(session: session, requestID: requestID)
    }

    private func drainSelfCompactEffects(session: TabSession?, requestID: UUID?) async {
        while true {
            let effects = pendingSelfCompactEffects.filter { effect in
                (session.map { effect.value.session === $0 } ?? true)
                    && (requestID == nil || effect.value.requestID == requestID)
            }
            guard !effects.isEmpty else { return }
            for (effectID, effect) in effects {
                await effect.task.value
                finishSelfCompactEffect(effectID, session: effect.session, requestID: effect.requestID)
            }
        }
    }

    private func finishSelfCompactEffect(_ effectID: UUID, session: TabSession, requestID: UUID) {
        guard let effect = pendingSelfCompactEffects[effectID],
              effect.session === session, effect.requestID == requestID else { return }
        pendingSelfCompactEffects.removeValue(forKey: effectID)
        // Wake only after releasing the exact receipt; an earlier state event can see it pending.
        session.noteMonitorObservationInputsChanged()
    }

    /// Readiness for this request's dedicated continuation note. The generic ACP background-compaction
    /// hold exists so a new prompt cannot cancel a compaction that may still be running. A note is
    /// dispatched only after this request's own compaction was verified (a correlated native success
    /// or a vouched ACP context drop), so that hold no longer protects anything, and starting the
    /// note ends it. Every other holder, including an unverified attempt, still waits it out.
    static func agentSelfCompactNoteReadinessSnapshot(
        session: TabSession,
        requestID: UUID
    ) -> AgentSessionLinkDeliveryReadiness.Snapshot {
        var snapshot = AgentSessionLinkExecutionRuntime.agentSessionLinkDeliveryReadinessSnapshot(
            session: session,
            endpointMatchesGrant: true,
            isClosing: false,
            ignoresComposerSubmissionInFlight: true,
            ignoresSelfCompactRequestID: requestID
        )
        if let active = session.selfCompactState.active,
           active.id == requestID,
           active.compactTurnSucceeded == true,
           active.acpCompletionUnverified != true
        {
            snapshot.backgroundCompactionSettling = false
        }
        return snapshot
    }

    func agentSelfCompactTerminalSettled(
        session: TabSession,
        revision: AgentRunTerminalCommitRevision,
        publication: AgentRunTerminalPublicationResult,
        teardownSettled: @escaping @MainActor () -> Bool
    ) {
        if session.selfCompactState.active?.phase == .scheduled {
            let requestID = session.selfCompactState.active?.id
            let task = agentSelfCompactScheduler(for: session).terminalSettled(
                runID: revision.expectedRunID,
                runAttemptID: revision.ownership.attemptID,
                terminalState: revision.terminalState,
                publication: publication,
                successorClaimed: revision.successorKind != nil,
                teardownSettled: teardownSettled
            )
            if let task, let requestID {
                trackSelfCompactProducer(task, for: session, requestID: requestID)
            }
        } else if let completion = session.selfCompactNativeCompletion {
            let rowCount = completion.acceptsCompactTerminal(revision, publication: publication)
                ? agentSelfCompactACPNewAssistantOrToolRows(session) : nil
            completion.compactTurnSettled(
                revision: revision,
                publication: publication,
                teardownSettled: teardownSettled,
                assistantOrToolRowCount: rowCount,
                vouchedTokenCount: session.vouchedContextCount?.tokens
            )
        }
    }

    func agentSelfCompactCancelForAcceptedLocalInput(_ session: TabSession) {
        guard session.selfCompactState.active != nil else { return }
        agentSelfCompactScheduler(for: session).cancelForAcceptedLocalInput()
        session.selfCompactNativeCompletion?.supersedeForOrdinaryInput()
    }

    private static func publishSelfCompactStateChange(
        previous: AgentSelfCompactState, state: AgentSelfCompactState,
        session: TabSession, runtime: AgentSessionLinkExecutionRuntime?, includesCancellation: Bool
    ) {
        if previous.active != nil, state.active == nil {
            let row: AgentChatItem? = switch state.latest?.outcome {
            case .cancelled where includesCancellation:
                AgentChatItem.selfCompactionCancelled(sequenceIndex: session.nextSequenceIndex)
            case .failed:
                AgentChatItem.selfCompactionCouldNotStart(sequenceIndex: session.nextSequenceIndex)
            default:
                nil
            }
            if let row {
                session.appendItem(row)
                runtime?.updateBindingsFromSession(session)
            }
        }
        runtime?.scheduleSave(for: session)
        runtime?.requestUIRefresh(tabID: session.tabID, urgent: true)
    }

    private func agentSelfCompactScheduler(for session: TabSession) -> AgentSelfCompactTerminalScheduler {
        AgentSelfCompactTerminalScheduler(
            load: { session.selfCompactState },
            store: { [weak self] state in
                let previous = session.selfCompactState
                session.selfCompactState = state
                Self.publishSelfCompactStateChange(previous: previous, state: state, session: session, runtime: self, includesCancellation: true)
            },
            isCurrentOwner: { [weak self] owner in
                self?.agentSelfCompactOwnerIsCurrent(owner, session: session) ?? false
            },
            hasActiveTools: { [weak self] runID in
                // AgentSelfCompactTerminalScheduler:131,172 requires !hasActiveTools.
                // Unknown drain state must block both admission and physical start.
                self?.activeMCPToolProbe?(runID) ?? true
            },
            support: { [weak self] in
                await self?.agentSessionLinkCompactSupport(for: session) ?? .notSupported
            },
            dispatch: { [weak self] requestID, support, stillAdmissible, physicalStartIsSafe in
                guard let self else { return false }
                return await agentSelfCompactDispatchNative(
                    requestID: requestID,
                    session: session,
                    support: support,
                    stillAdmissible: stillAdmissible,
                    physicalStartIsSafe: physicalStartIsSafe
                )
            }
        )
    }

    private func agentSelfCompactOwnerIsCurrent(
        _ owner: AgentSelfCompactOwner,
        session: TabSession
    ) -> Bool {
        guard sessions[owner.tabID] === session,
              let endpoint = agentSessionLinkObserverEndpoint(tabID: owner.tabID)
        else { return false }
        return endpoint.windowID == owner.windowID
            && endpoint.workspaceID == owner.workspaceID
            && endpoint.tabID == owner.tabID
            && endpoint.sessionID == owner.sessionID
            && endpoint.persistentBindingGeneration == owner.persistentBindingGeneration
            && endpoint.bindingTransitionGeneration == owner.bindingTransitionGeneration
            && agentSelfCompactHasExclusiveWriter(session, endpoint: endpoint)
    }

    /// Evaluation can release a stale parked note without requiring a send that the note itself
    /// blocks. SelfCompact remains the lifecycle owner; an attempted note is never settled here.
    func agentSelfCompactSettleStaleParkedNote(_ session: TabSession) {
        guard let attempt = session.selfCompactState.active,
              attempt.phase == .parked, !attempt.noteDispatchStarted
        else { return }
        var state = session.selfCompactState
        if state.cancelStaleParkedNote(for: session) {
            session.selfCompactState = state
            scheduleSave(for: session)
            return
        }
        let completion = session.selfCompactNativeCompletion ?? agentSelfCompactNativeCompletion(for: session)
        completion.cancelUnattemptedNoteIfOwnerLost(.init(requestID: attempt.id, stage: .note))
    }

    /// The acquisition hold ends only after the correlated compact terminal has been verified.
    /// A Codex success event alone can set `compactTurnSucceeded` before that terminal arrives.
    func agentSelfCompactHoldsWakeAcquisition(_ session: TabSession) -> Bool {
        guard let attempt = session.selfCompactState.active else { return false }
        switch attempt.phase {
        case .awaitingNoteBoundary, .noteDispatchPending, .dispatchingNote, .parked:
            return session.selfCompactVerifiedWakeRequestID != attempt.id
        case .scheduled, .compactDispatchPending, .dispatchingCompact, .awaitingCompactTurn, .acpSettling:
            return true
        }
    }

    /// A wake that has not started preparation owns no provider boundary and may wait while this
    /// already-admitted self-compaction starts. Ordinary send and MCP admission remain unchanged.
    func agentSelfCompactCanIgnoreParkedWake(_ session: TabSession) -> Bool {
        guard let attempt = session.oversight.pendingAutoWake,
              !attempt.isManual, !attempt.isPeriodic,
              attempt.phase == .scheduled || attempt.phase == .awaitingSettlement,
              attempt.physicalOutcome == .notAttempted,
              attempt.periodicProducerDispatchID == nil, attempt.periodicProducerTask == nil,
              agentSessionLinkObserverEndpoint(tabID: session.tabID) == attempt.observerEndpoint,
              agentSessionLinkPromptClaimStore.pendingClaim(
                  dispatchID: .autoWake(wakeID: attempt.wakeID),
                  observerSessionID: attempt.observerEndpoint.sessionID
              ) == nil
        else { return false }
        return true
    }

    /// Only event-driven wakes can carry this note; periodic prompting remains excluded.
    func agentSelfCompactBlocksNotificationWake(_ session: TabSession) -> Bool {
        guard session.selfCompactState.blocksAutomaticWake else { return false }
        guard !agentSelfCompactHoldsWakeAcquisition(session),
              let owner = session.selfCompactState.verifiedParkedNoteOwner else { return true }
        return !agentSelfCompactOwnerIsCurrent(owner, session: session)
    }

    private func agentSelfCompactDispatchNative(
        requestID: UUID,
        session: TabSession,
        support: AgentSessionLinkCompactSupport,
        stillAdmissible: @escaping @MainActor () -> Bool,
        physicalStartIsSafe: @escaping @MainActor () -> Bool
    ) async -> Bool {
        guard let owner = session.selfCompactState.active?.owner,
              stillAdmissible(),
              let target = makeComposerSubmitTarget(tabID: owner.tabID, session: session),
              target.route == .existingAgentSession,
              target.expectedSourceAgentSessionID == owner.sessionID
        else { return false }
        let ownerIsCurrent: @MainActor () -> Bool = { [weak self, weak session] in
            guard let self, let session else { return false }
            return agentSelfCompactOwnerIsCurrent(owner, session: session)
        }
        session.selfCompactNoteOwnerIsCurrent = ownerIsCurrent
        session.selfCompactDispatchIsCurrent = { [weak session] in
            guard let session, ownerIsCurrent(), let active = session.selfCompactState.active,
                  active.id == requestID,
                  active.phase == .dispatchingCompact || active.phase == .awaitingCompactTurn
            else { return false }
            // Claude and ACP can return from run startup before their compact transport write.
            return physicalStartIsSafe()
        }
        let attempt = AgentComposerSubmitAttempt(
            id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: ""
        )
        guard let claim = claimComposerSubmitAttempt(attempt) else { return false }
        defer { releaseComposerSubmitClaim(claim) }
        guard let command = claim.command else { return false }

        let ready: @MainActor () -> Bool = { [weak self] in
            guard let self, selfCompactClaimIsReady(claim, session: session, stillAdmissible: stillAdmissible),
                  command.identity.workspaceID == owner.workspaceID
            else { return false }
            var snapshot = AgentSessionLinkExecutionRuntime.agentSessionLinkDeliveryReadinessSnapshot(
                session: session,
                endpointMatchesGrant: agentSelfCompactOwnerIsCurrent(owner, session: session),
                isClosing: false,
                ignoresComposerSubmissionInFlight: true,
                ignoresSelfCompactRequestID: requestID
            )
            if agentSelfCompactCanIgnoreParkedWake(session) {
                snapshot.pendingOversightAutoWake = false
            }
            return AgentSessionLinkDeliveryReadiness.evaluate(snapshot: snapshot) == .ready
        }
        guard ready() else { return false }

        // The fixed system row and attempt state are saved before any native command. The note
        // itself is never written to provider-replayed row text.
        let row = AgentChatItem.selfCompactionRequest(sequenceIndex: session.nextSequenceIndex)
        session.appendItem(row)
        updateBindingsFromSession(session)
        requestUIRefresh(tabID: owner.tabID, urgent: true)
        if case .failure = await flushSaveRequired(writer: command.writer) {
            if let index = session.items.firstIndex(where: { $0.id == row.id }) {
                _ = session.removeItem(at: index)
            }
            _ = await flushSaveRequired(writer: command.writer)
            return false
        }
        guard ready() else { return false }
        var state = session.selfCompactState
        state.active?.compactProviderConversation = support == .codex
            ? session.codexConversationID : session.providerSessionID
        state.active?.usedTokensBeforeCompact = session.vouchedContextCount?.tokens
        session.selfCompactState = state
        session.selfCompactNativeCompletion = agentSelfCompactNativeCompletion(for: session)
        let result = await agentSessionLinkDispatchNativeCompact(
            session: session,
            tabID: owner.tabID,
            support: support,
            isStillAdmissible: ready,
            selfCompactDispatchID: .init(requestID: requestID, stage: .compact)
        )
        return result == .started
    }

    private func agentSelfCompactNativeCompletion(
        for session: TabSession
    ) -> AgentSelfCompactNativeCompletionCoordinator {
        AgentSelfCompactNativeCompletionCoordinator(
            load: { session.selfCompactState },
            store: { [weak self] state in
                let previous = session.selfCompactState
                session.selfCompactState = state
                if previous.active?.acpCompletionUnverified != true,
                   state.active?.acpCompletionUnverified == true
                {
                    session.appendItem(
                        AgentChatItem.selfCompactionCompletionUnverified(sequenceIndex: session.nextSequenceIndex)
                    )
                    self?.updateBindingsFromSession(session)
                }
                Self.publishSelfCompactStateChange(previous: previous, state: state, session: session, runtime: self, includesCancellation: false)
            },
            isCurrentOwner: { [weak self] owner in
                self?.agentSelfCompactOwnerIsCurrent(owner, session: session) ?? false
            },
            dispatchNote: { [weak self] requestID, stillAdmissible in
                guard let self else { return false }
                return await agentSelfCompactDispatchNote(
                    requestID: requestID, session: session, stillAdmissible: stillAdmissible
                )
            },
            producerStarted: { [weak self, weak session] requestID, task in
                guard let session else { return }
                self?.trackSelfCompactProducer(task, for: session, requestID: requestID)
            }
        )
    }

    private func selfCompactClaimIsReady(
        _ claim: AgentComposerSubmitClaim, session: TabSession, stillAdmissible: @MainActor () -> Bool
    ) -> Bool {
        stillAdmissible() && composerSubmitClaimIsCurrent(claim)
            && !AgentSessionLinkExecutionRuntime.agentSessionLinkCompactHasQueuedProviderWork(session)
    }

    private func agentSelfCompactDispatchNote(
        requestID: UUID,
        session: TabSession,
        stillAdmissible: @escaping @MainActor () -> Bool
    ) async -> Bool {
        guard stillAdmissible(), let owner = session.selfCompactState.active?.owner,
              let target = makeComposerSubmitTarget(tabID: owner.tabID, session: session),
              target.route == .existingAgentSession,
              target.expectedSourceAgentSessionID == owner.sessionID
        else { return false }
        let submit = AgentComposerSubmitAttempt(
            id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: ""
        )
        guard let claim = claimComposerSubmitAttempt(submit) else { return false }
        defer { releaseComposerSubmitClaim(claim) }
        guard let command = claim.command else { return false }
        let ready: @MainActor () -> Bool = { [weak self] in
            guard let self, selfCompactClaimIsReady(claim, session: session, stillAdmissible: stillAdmissible),
                  agentSelfCompactOwnerIsCurrent(owner, session: session),
                  command.identity.workspaceID == owner.workspaceID
            else { return false }
            return AgentSessionLinkDeliveryReadiness.evaluate(
                snapshot: Self.agentSelfCompactNoteReadinessSnapshot(session: session, requestID: requestID)
            ) == .ready
        }
        guard ready(), let note = session.selfCompactState.active?.note else { return false }
        var state = session.selfCompactState
        state.active?.phase = .dispatchingNote
        session.selfCompactState = state
        guard case .success = await flushSaveRequired(writer: command.writer),
              ready()
        else { return false }
        let recorder = AgentRunStartOutcomeRecorder()
        _ = await startAgentRun(
            command: command,
            initialMessage: AgentSelfCompactNoteEnvelope.frame(note),
            directStartOptions: .selfCompactNote(requestID: requestID),
            startOutcome: recorder,
            providerSwitchPreparation: nil
        )
        return recorder.outcome.didStart
    }

    /// Assistant and tool rows appended after the ACP compact command was issued. Nil when this
    /// turn was not an ACP self-compact command, which the detector treats as an unknown shape.
    private func agentSelfCompactACPNewAssistantOrToolRows(_ session: TabSession) -> Int? {
        guard let baseline = session.selfCompactACPCommandItemIDs else { return nil }
        session.selfCompactACPCommandItemIDs = nil
        return session.items.reduce(into: 0) { count, item in
            guard !baseline.contains(item.id) else { return }
            switch item.kind {
            case .assistant, .assistantInline, .toolCall, .toolResult:
                count += 1
            case .user, .system, .error, .thinking:
                break
            }
        }
    }
}
