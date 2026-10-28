import Foundation
import RepoPromptDomainRuntime

// The target-side execution of one overseer-requested context compaction.
//
// It is the send transaction's sibling, not a kind of send: the same readiness gate, composer claim,
// authorization commit fence, and durable-before-dispatch ordering, but it records an attributed
// `.system` request row instead of a user row and dispatches a RepoPrompt-constructed native command
// (`AgentProviderControlCommand.compact`) instead of an envelope. Nothing the observer writes reaches
// the provider. Invariant: a waiting target is never ready, so a compaction can neither answer nor
// route around an interaction, while a target whose last turn *failed* (for example on context
// length) is idle and therefore admissible — the case compaction exists for.

/// Whether a target's provider can take an overseer compaction right now.
enum AgentSessionLinkCompactSupport: String, Codable, Equatable {
    /// Codex: native `thread/compact/start` on the existing thread.
    case codex
    /// Claude Code: the bare native `/compact` command in the existing provider conversation.
    case claudeCode
    /// An ACP session whose live controller currently advertises `compact` in the existing provider
    /// session: the bare `/compact` as the whole `session/prompt`. Live-unverified.
    case acpAdvertisedCommand
    /// No verified native compaction path for this runtime. Never downgraded to a message.
    case notSupported
    /// No live provider session to compact: no recorded conversation, or a remembered one whose
    /// controller is absent, still opening, or has not reported its command surface yet.
    case noProviderSession
}

enum AgentNativeCompactDispatchResult: Equatable {
    case started
    case notStarted
    case startFailed
}

extension AgentModeViewModel {
    /// Pure support decision for one target, taken before anything is recorded.
    ///
    /// Claude-compatible variants share the Claude CLI but their backends are not verified to honor
    /// the native command, so they are `notSupported` rather than guessed at. An ACP session is
    /// supported only while its live controller advertises `compact` for the target's own provider
    /// session. A stored ACP conversation without a live provider session — after a relaunch,
    /// before the session's first turn, or while its controller is still opening — is
    /// `noProviderSession`, a retryable state: one ordinary turn brings the conversation and its
    /// command advertisement up. `notSupported` needs the live session's command list to have been
    /// observed and to provably lack `compact` (or to name another conversation); an unobserved
    /// list is retryable too. OpenCode and Cursor are never supported (see
    /// `AgentProviderControlCommand.acpRuntimeAdvertisesNativeCommands`).
    func agentSessionLinkCompactSupport(for session: TabSession) async -> AgentSessionLinkCompactSupport {
        switch session.selectedAgent {
        case .codexExec:
            let thread = session.codexConversationID?.trimmingCharacters(in: .whitespacesAndNewlines)
            return codexCoordinator.hasKnownCodexThread(session) && thread?.isEmpty == false
                ? .codex
                : .noProviderSession
        case .claudeCode:
            let conversation = session.providerSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
            return conversation?.isEmpty == false ? .claudeCode : .noProviderSession
        case .devin, .grokBuild, .antigravity:
            // Bind the exact stored conversation — it is what the controller's snapshot compares.
            guard let conversation = session.providerSessionID,
                  !conversation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return .noProviderSession
            }
            // No live provider session means its command surface cannot have been observed yet —
            // retryable, not incapable.
            guard let controller = session.acpController, await controller.hasLiveProviderSession else {
                return .noProviderSession
            }
            // Everything unobservable after the hop is retryable rather than unsupported. A single
            // snapshot read answers both questions at once — snapshot present (an unobserved list,
            // dropped while the session opens or never sent, is indistinguishable from "about to
            // advertise") and list contents — while the same-stretch re-checks bind the verdict to
            // the controller, conversation, and runtime proven before the hop. `notSupported` is
            // reserved for a snapshot that names another conversation or provably lacks `compact`.
            guard session.acpController === controller,
                  session.providerSessionID == conversation,
                  AgentProviderControlCommand.acpRuntimeAdvertisesNativeCommands(session.selectedAgent)
            else {
                return .noProviderSession
            }
            guard let advertised = controller.currentAdvertisedCommands() else {
                return .noProviderSession
            }
            guard advertised.sessionID == conversation else {
                return .notSupported
            }
            return advertised.names.contains(AgentProviderControlCommand.Kind.compact.rawValue)
                ? .acpAdvertisedCommand
                : .notSupported
        case .claudeCodeGLM, .kimiCode, .customClaudeCompatible, .openCode, .cursor:
            return .notSupported
        }
    }

    /// Runs the whole overseer compaction transaction for one exact live endpoint.
    ///
    /// The ordering is `agentSessionLinkPerformSend`'s and is not rearrangeable:
    ///
    /// 1. exact endpoint identity of both incarnations plus the target window's closing state,
    /// 2. pure readiness admission and provider support (no mutation on refusal),
    /// 3. local composer claim,
    /// 4. authorization commit fence before any row exists,
    /// 5. post-hop revalidation of identities, closing state, claim, readiness, and support,
    /// 6. attributed request row + durable persistence as the linearization point,
    /// 7. post-persistence revalidation — drift withholds dispatch and reports `persisted`,
    /// 8. the native command, dispatched exactly once.
    func agentSessionLinkPerformCompact(
        to candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkCompactRequest,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        commitAuthorization: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkSendTransactionOutcome {
        // 1. Exact endpoint incarnations.
        guard let session = agentSessionLinkLiveSession(matching: candidate) else {
            return .blocked(.endpointInvalidated)
        }
        let admissionLiveness = liveness()
        guard admissionLiveness.permitsDelivery else {
            return .blocked(.endpointInvalidated)
        }

        // 2. Pure readiness admission, then provider support. Readiness first, so a busy or waiting
        //    target reads `target_not_idle` regardless of its provider.
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
        if Self.agentSessionLinkCompactHasQueuedProviderWork(session) {
            return .blocked(.targetNotIdle)
        }
        let support = await agentSessionLinkCompactSupport(for: session)
        switch support {
        case .notSupported:
            return .blocked(.notSupported)
        case .noProviderSession:
            return .blocked(.noProviderSession)
        case .codex, .claudeCode, .acpAdvertisedCommand:
            break
        }

        // 3. Local composer claim. Losing it means a local user Send won the race.
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
            rawDraftSnapshot: ""
        )
        guard case let .claimed(claim) = claimComposerSubmitAttempt(
            attempt,
            requireActiveTabOwnership: false
        ) else {
            return .blocked(.targetNotIdle)
        }

        // 4. Authorization linearization fence, before any row exists.
        let commit = await commitAuthorization()
        guard commit == .committed else {
            releaseComposerSubmitClaim(claim)
            return .blocked(commit == .shuttingDown ? .shuttingDown : .linkRevoked)
        }

        // 5. Re-prove everything the commit await could have changed, including provider support: a
        //    provider switch during the hop must not dispatch a command the new runtime cannot honor.
        //    The support answer itself suspends on the controller actor, so it is fetched first;
        //    liveness, identity, claim, readiness, and workspace are then proved in one MainActor
        //    stretch with no suspension between them and the durable row.
        guard let liveSession = agentSessionLinkLiveSession(matching: candidate),
              liveSession === session
        else {
            releaseComposerSubmitClaim(claim)
            return .blocked(.endpointInvalidated)
        }
        let postCommitSupport = await agentSessionLinkCompactSupport(for: liveSession)
        let postCommitLiveness = liveness()
        guard agentSessionLinkLiveSession(matching: candidate) === liveSession,
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
        if Self.agentSessionLinkCompactHasQueuedProviderWork(liveSession) {
            releaseComposerSubmitClaim(claim)
            return .blocked(.targetNotIdle)
        }
        guard postCommitSupport == support else {
            releaseComposerSubmitClaim(claim)
            return .blocked(postCommitSupport == .noProviderSession ? .noProviderSession : .notSupported)
        }
        guard let workspaceID = workspaceManager?.activeWorkspace?.id,
              workspaceID == candidate.workspaceID
        else {
            releaseComposerSubmitClaim(claim)
            return .blocked(.endpointInvalidated)
        }

        // 6. Durable acceptance of the *request*. A `.system` row with fixed text plus typed
        //    attribution: no user row, no turn anchor, no draft, workflow, or handoff mutation.
        let requestItem = AgentChatItem.overseerCompactionRequest(
            attribution: request.attribution,
            sequenceIndex: liveSession.nextSequenceIndex
        )
        liveSession.appendItem(requestItem)
        updateBindingsFromSession(liveSession)
        requestUIRefresh(tabID: candidate.tabID, urgent: true)

        if case .failure = await flushSaveRequired(for: candidate.tabID, workspaceID: workspaceID) {
            agentSessionLinkRemoveStagedCompactRow(itemID: requestItem.id, tabID: candidate.tabID, session: liveSession)
            // As for a send: only a durably confirmed removal makes "nothing was requested" true.
            if case .failure = await flushSaveRequired(for: candidate.tabID, workspaceID: workspaceID) {
                releaseComposerSubmitClaim(claim)
                return .blocked(.persistenceIndeterminate)
            }
            releaseComposerSubmitClaim(claim)
            return .blocked(.persistenceFailed)
        }

        let acceptedAt = Date()
        let persistedOnly = AgentSessionLinkSendDelivery(
            targetItemID: requestItem.id,
            acceptedAt: acceptedAt,
            deliveryState: .persisted,
            resultingRunState: liveSession.runState.rawValue
        )
        if Task.isCancelled {
            releaseComposerSubmitClaim(claim)
            return .delivered(persistedOnly)
        }

        // 7. The flush awaited: re-prove every admission fact before anything reaches a provider.
        //    Drift keeps the durable request and withholds only the command. The support answer
        //    suspends on the controller actor, so it is fetched first; the liveness probe and
        //    every guard below then run after the last suspension.
        let dispatchSupport = await agentSessionLinkCompactSupport(for: liveSession)
        let dispatchLiveness = liveness()
        guard !Task.isCancelled,
              agentSessionLinkLiveSession(matching: candidate) === liveSession,
              dispatchLiveness.permitsDelivery,
              composerSubmitClaimIsCurrent(claim),
              workspaceManager?.activeWorkspace?.id == candidate.workspaceID,
              dispatchSupport == support
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
        if Self.agentSessionLinkCompactHasQueuedProviderWork(liveSession) {
            releaseComposerSubmitClaim(claim)
            return .delivered(persistedOnly)
        }

        // 8. The native command. Codex compacts its thread through the app-server control plane and
        //    never sends a message; Claude Code and an advertising ACP session receive exactly
        //    `/compact` through their ordinary run pipelines, so status, events, and (for Claude) the
        //    compaction boundary flow as for any turn.
        let dispatch = await agentSessionLinkDispatchNativeCompact(
            session: liveSession,
            tabID: candidate.tabID,
            support: support,
            isStillAdmissible: { [weak self] in
                guard let self else { return false }
                let current = liveness()
                guard !Task.isCancelled,
                      agentSessionLinkLiveSession(matching: candidate) === liveSession,
                      current.permitsDelivery,
                      composerSubmitClaimIsCurrent(claim),
                      workspaceManager?.activeWorkspace?.id == candidate.workspaceID
                else { return false }
                return AgentSessionLinkDeliveryReadiness.evaluate(
                    snapshot: Self.agentSessionLinkDeliveryReadinessSnapshot(
                        session: liveSession,
                        endpointMatchesGrant: current.targetEndpointIsLive,
                        isClosing: current.targetWindowIsClosing,
                        ignoresComposerSubmissionInFlight: true
                    )
                ) == .ready && !Self.agentSessionLinkCompactHasQueuedProviderWork(liveSession)
            }
        )
        if dispatch == .notStarted {
            releaseComposerSubmitClaim(claim)
            return .delivered(persistedOnly)
        }
        releaseComposerSubmitClaim(claim)

        let resultingRunState = sessions[candidate.tabID]?.runState ?? liveSession.runState
        return .delivered(AgentSessionLinkSendDelivery(
            targetItemID: requestItem.id,
            acceptedAt: acceptedAt,
            deliveryState: dispatch == .started ? .runStarted : .runStartFailed,
            resultingRunState: resultingRunState.rawValue,
            compactionRunsInBackground: postCommitSupport == .acpAdvertisedCommand && dispatch == .started
        ))
    }

    /// Shared native leaves only. The overseer authorization/persistence transaction above remains
    /// eight separate steps; self-compaction invokes this only after its own independent fences.
    func agentSessionLinkDispatchNativeCompact(
        session: TabSession,
        tabID: UUID,
        support: AgentSessionLinkCompactSupport,
        isStillAdmissible: @escaping @MainActor () -> Bool,
        selfCompactDispatchID: AgentSelfCompactionDispatchID? = nil
    ) async -> AgentNativeCompactDispatchResult {
        guard isStillAdmissible(), await agentSessionLinkCompactSupport(for: session) == support,
              isStillAdmissible()
        else { return .notStarted }
        switch support {
        case .codex:
            guard let expectedThreadID = session.codexConversationID else { return .notStarted }
            let start = await codexCoordinator.startOversightCompaction(
                session: session,
                expectedThreadID: expectedThreadID,
                selfCompactDispatchID: selfCompactDispatchID,
                isStillAdmissible: isStillAdmissible
            )
            switch start {
            case .started: return .started
            case .notStarted: return .notStarted
            case .startFailed: return .startFailed
            }
        case .claudeCode, .acpAdvertisedCommand:
            guard let conversation = session.providerSessionID,
                  let binding = session.persistentSessionBindingIdentity,
                  isStillAdmissible()
            else { return .notStarted }
            let command = AgentProviderControlCommand.compact(
                expectedBinding: binding,
                expectedProviderConversation: conversation,
                selfCompactDispatchID: selfCompactDispatchID
            )
            let recorder = AgentRunStartOutcomeRecorder()
            _ = await startAgentRun(
                tabID: tabID,
                initialMessage: command.providerText,
                directStartOptions: .providerControl(command),
                startOutcome: recorder
            )
            return recorder.outcome.didStart ? .started : .startFailed
        case .notSupported, .noProviderSession:
            return .notStarted
        }
    }

    /// Provider-side queued work a compaction must never race or discard.
    ///
    /// A Codex compaction that fails to start unwinds the same way the local `/compact` does, which
    /// abandons queued fallback follow-ups. Those belong to the target's own user, so an overseer
    /// compaction is refused while any exist rather than being allowed to discard them.
    static func agentSessionLinkCompactHasQueuedProviderWork(_ session: TabSession) -> Bool {
        !session.codexFallbackQueue.isEmpty || session.codexFallbackDispatchInFlight != nil
    }

    /// Removes a staged compaction request row whose durable write failed.
    private func agentSessionLinkRemoveStagedCompactRow(itemID: UUID, tabID: UUID, session: TabSession) {
        if let index = session.items.firstIndex(where: { $0.id == itemID }) {
            _ = session.removeItem(at: index)
        }
        updateBindingsFromSession(session)
        requestUIRefresh(tabID: tabID, urgent: true)
        scheduleSave(for: tabID)
    }
}
