import Foundation
import RepoPromptAIContracts

/// Owns startup orchestration and its exact-object lifetime. Composition supplies the existing
/// workspace/creation/input authorities for this request, not an implementation of `start`.
/// These inputs are still presentation-composed in the legacy host; they must be replaced with
/// canonical runtime composition before sharing writers or retiring the prepared-window path.
@MainActor
final class AgentSessionRunStartRuntime {
    typealias BindingAdmission = AgentSessionPersistenceRuntime.Admission

    struct Environment {
        let currentWorkspaceID: () -> UUID?
        let prepareSession: (AgentTabSession) async -> Void
        let availabilityFailure: (AgentProviderKind) -> String?
        let bindSession: (AgentTabSession) -> BindingAdmission?
        let commitCreation: (AgentSessionCreationHandle) async -> Bool
        let providerSwitchRefusal: (AgentTabSession) -> String
        let prepareProviderSwitch: (AgentProviderSwitchSendPreparation?, AgentTabSession, AgentRunStartStopFence) async -> (user: String, initial: String)?
        let augment: (String, AgentTabSession, [AgentFileAttachment], [AgentTaggedFileAttachment], Bool, Bool) async -> String
        let initialMessage: (AgentTabSession, String) async -> String
        let composition: () -> AgentModeRunComposition
        #if DEBUG
            var test_startOverride: ((AgentTabSession, String, String) async -> Bool)?
        #endif
    }

    private weak var scope: AgentSessionRuntimeStore.Scope?

    init(scope: AgentSessionRuntimeStore.Scope) {
        self.scope = scope
    }

    @discardableResult
    func start(
        session: AgentTabSession,
        initialMessage: String,
        attachments: [AgentFileAttachment] = [],
        taggedFileAttachments: [AgentTaggedFileAttachment] = [],
        codexFallbackContext: AgentTabSession.CodexFallbackSubmissionContext? = nil,
        autoEffortSelection: AutoEffortTurnSelection? = nil,
        directStartOptions: AgentDirectRunStartOptions = .default,
        startOutcome: AgentRunStartOutcomeRecorder? = nil,
        providerSwitchPreparation: AgentProviderSwitchSendPreparation? = nil,
        claudeCoordinator: ClaudeAgentModeCoordinator,
        links: AgentSessionLinkExecutionRuntime,
        environment: Environment
    ) async -> CodexAgentModeCoordinator.NativeSendOutcome? {
        var candidateTransferred = false
        defer {
            // Run preparation has no rollback for ordinary non-Codex rows. An explicit retained
            // startup refusal closes here; a launched runner owns acceptance/terminal settlement.
            if !candidateTransferred {
                session.settleLocalComposerOrigin(directStartOptions.localComposerCandidate, disposition: .retained)
            }
        }
        guard let owner = scope, owner.sessions[session.tabID] === session,
              !owner.isRetiring, !owner.hasReleasedWriterClaims else { return nil }
        defer { withExtendedLifetime(owner) {} }
        let tabID = session.tabID
        var writer: AgentSessionRuntimeStore.Writer?
        if let sessionID = session.activeAgentSessionID {
            guard case let .unique(existing) = owner.resolveWriter(sessionID: sessionID),
                  existing.scope === owner, existing.session === session
            else {
                let message = "The session no longer has an exclusive runtime writer."
                startOutcome?.recordStartFailure(message: message)
                return .failed(message: message)
            }
            writer = existing
        }
        // Writer currency is independent of presentation. Until the remaining host resource
        // adapters are replaced, their workspace must also stay pinned: a current writer is not
        // permission to consume another workspace's context or provider launch path.
        let originalBindingToken = session.currentRestorationBindingToken
        let originalWorkspaceID = environment.currentWorkspaceID()
        func resourcesAreCurrent() -> Bool {
            environment.currentWorkspaceID() == originalWorkspaceID
        }
        func isCurrent() -> Bool {
            guard owner.sessions[tabID] === session, !owner.isRetiring, !owner.hasReleasedWriterClaims,
                  resourcesAreCurrent() else { return false }
            if let writer { return writer.isCurrent }
            return session.currentRestorationBindingToken == originalBindingToken
        }
        if session.pendingHandoff.providerSwitchDelivery != nil, providerSwitchPreparation == nil {
            let message = environment.providerSwitchRefusal(session)
            startOutcome?.recordStartFailure(message: message)
            return .failed(message: message)
        }
        guard directStartOptions.stopFence?.permitsStart(of: session) ?? true else {
            startOutcome?.recordStartFailure(message: "This scheduled run was cancelled by Stop.")
            return nil
        }
        func periodicStartIsCurrent() -> Bool {
            guard let wakeID = directStartOptions.periodicWakeID else { return true }
            guard directStartOptions.laneUpdateWakeID == nil,
                  let attempt = session.oversight.pendingAutoWake,
                  attempt.isPeriodic, attempt.wakeID == wakeID, attempt.phase == .preparingDispatch,
                  let submissionID = attempt.periodicComposerAttemptID,
                  session.activeComposerSubmitAttempt?.id == submissionID,
                  links.agentSessionLinkPeriodicWakeIsEligible(session, endpoint: attempt.observerEndpoint),
                  links.agentSessionLinkPeriodicPreparationIsUnblocked(session) else { return false }
            return true
        }
        guard periodicStartIsCurrent() else { return nil }
        let originalStopFence = directStartOptions.stopFence ?? AgentRunStartStopFence(session: session)
        var preparedClaudeEvents: ClaudeAttemptEventReservation?
        var claudeEventsTransferred = false
        defer {
            if !claudeEventsTransferred, let preparedClaudeEvents {
                preparedClaudeEvents.listener.close(preparedClaudeEvents.subscription, returningTail: true)
                preparedClaudeEvents.listener.terminalPublished(for: preparedClaudeEvents.subscription)
            }
        }
        func recordClaudeStartRefusal() {
            let message = ClaudeAgentModeCoordinator.inputNotSentMessage
            startOutcome?.recordStartFailure(message: message)
            if directStartOptions.localComposerCandidate != nil {
                session.appendItem(.error(message, sequenceIndex: session.nextSequenceIndex))
                session.isDirty = true
                owner.persistence.scheduleSave(for: session)
                owner.presentation.requestUIRefresh(for: session, urgent: true)
            }
        }
        if session.selectedAgent.usesClaudeNativeRuntime, session.claudeController != nil {
            // Reserve before host preparation suspends. If adoption already won preparation,
            // only a plain local instruction can transfer to the existing steering owner.
            if let adoption = claudeCoordinator.pendingProviderAdoption(for: session) {
                await adoption.value
                guard originalStopFence.permitsStart(of: session), isCurrent()
                else {
                    startOutcome?.recordStartFailure(message: nil)
                    return nil
                }
            }
            if session.runState.isActive {
                guard let writer, case .success = writer.admitCommand(), let execution = owner.execution,
                      session.activeRunOwnership.map({ session.claudeTerminalAnchor?.0 == $0 }) == true,
                      directStartOptions.localComposerCandidate != nil,
                      directStartOptions.periodicWakeID == nil, directStartOptions.laneUpdateWakeID == nil,
                      directStartOptions.providerControlCommand == nil, directStartOptions.selfCompactDispatchID == nil,
                      !directStartOptions.skipsUserAugmentation, !directStartOptions.ignoresPendingHandoff,
                      codexFallbackContext == nil
                else {
                    recordClaudeStartRefusal()
                    return nil
                }
                let existingItem = directStartOptions.initialUserItemID.flatMap { id in session.items.first { $0.id == id } }
                let userItem = existingItem ?? AgentChatItem.user(initialMessage, sequenceIndex: session.nextSequenceIndex)
                if existingItem == nil { session.appendItem(userItem) }
                if let owner = session.activeRunOwnership { session.claudeTerminalAnchor = (owner, .exact(userItem.id)) }
                guard queueClaudeSteering(
                    session: session, service: execution,
                    wrappedText: initialMessage, attachments: attachments,
                    taggedFiles: taggedFileAttachments, draftText: initialMessage, userItem: userItem,
                    localComposerCandidate: directStartOptions.localComposerCandidate,
                    skipsSlashExpansion: directStartOptions.skipsSlashExpansion
                ) else {
                    recordClaudeStartRefusal()
                    return nil
                }
                candidateTransferred = true
                startOutcome?.recordAccepted()
                owner.presentation.bindingChanged(session)
                owner.persistence.scheduleSave(for: session)
                owner.presentation.requestUIRefresh(for: session, urgent: true)
                return nil
            }
            if session.claudeController != nil {
                guard let reservation = claudeCoordinator.reserveEventsForHostPreparation(for: session) else {
                    recordClaudeStartRefusal()
                    return nil
                }
                preparedClaudeEvents = reservation
            }
        }
        await environment.prepareSession(session)
        guard isCurrent(), originalStopFence.permitsStart(of: session) else { return nil }
        if let message = session.operationAdmissionFailureMessage {
            startOutcome?.recordStartFailure(message: message)
            return .failed(message: message)
        }
        if let message = environment.availabilityFailure(session.selectedAgent) {
            if session.mcpFollowUpRunPending, session.scheduledACPFollowUp == nil {
                session.mcpFollowUpRunPending = false
                owner.mcp.handleObservedMCPStateChange(for: session)
            }
            startOutcome?.recordStartFailure(message: message)
            return .failed(message: message)
        }
        defer {
            // A failed preparation cannot clear a successor's follow-up marker. The original
            // writer may still drain during retirement; admission is not required for cleanup.
            let ownsCleanup = writer.map {
                $0.isCurrent || (owner.sessions[tabID] !== session && session.currentRestorationBindingToken == $0.restoration)
            } ?? isCurrent()
            if ownsCleanup, session.mcpFollowUpRunPending, session.scheduledACPFollowUp == nil {
                session.mcpFollowUpRunPending = false
                owner.mcp.handleObservedMCPStateChange(for: session)
            }
        }
        guard let bindingAdmission = environment.bindSession(session) else {
            let message = "The tab could not be bound to an agent session."
            startOutcome?.recordStartFailure(message: message)
            return .failed(message: message)
        }
        if writer == nil {
            guard case let .unique(created) = owner.resolveWriter(sessionID: bindingAdmission.sessionID),
                  created.scope === owner, created.session === session else { return nil }
            writer = created
        }
        guard let writer, writer.identity.sessionID == bindingAdmission.sessionID, isCurrent() else { return nil }
        if let directCreation = bindingAdmission.creation, await !environment.commitCreation(directCreation) {
            let message = "The new session could not save its initial configuration. Retry saving it before starting a run."
            startOutcome?.recordStartFailure(message: message)
            return .failed(message: message)
        }
        guard isCurrent() else { return nil }
        let stopFence = directStartOptions.stopFence ?? AgentRunStartStopFence(session: session)
        guard stopFence.permitsStart(of: session) else {
            startOutcome?.recordStartFailure(message: "This scheduled run was cancelled by Stop.")
            return nil
        }
        await environment.prepareSession(session)
        guard periodicStartIsCurrent(), stopFence.permitsStart(of: session), isCurrent(),
              session.operationAdmissionFailureMessage == nil,
              case let .success(command) = writer.admitCommand() else { return nil }
        // The one provider-neutral fence for an automatic lane-update turn, placed here because this
        // is the last app-owned instant before *every* provider family (Codex start/fallback, Claude
        // native, ACP prompt, headless stream) is reached through `runComposition.startRun`.
        //
        // A lane update has no user-authored base instruction, so the rendered lane claim is its
        // entire justification and its entire new provider input. The claim store refuses an
        // auto-wake claim whose batch was revoked, already acknowledged, revision-mismatched, or
        // omitted by the shared 24 KiB budget — and without this guard that refusal would surface as
        // an empty, system-only turn rather than as no turn at all. Reserving here is idempotent: the
        // provider's own claim later resolves to this same pending claim through
        // `agentSessionLinkEffectiveDispatchID`, so nothing is rendered or acknowledged twice.
        //
        // Aborting quietly is the contract: no provider call, no error row, no provenance row, and
        // the lane content stays owed to a natural future dispatch.
        if let laneUpdateWakeID = directStartOptions.laneUpdateWakeID {
            guard links.agentSessionLinkPromptClaim(
                for: session,
                dispatchID: .autoWake(wakeID: laneUpdateWakeID)
            ) != nil else {
                startOutcome?.recordStartFailure(message: nil)
                return nil
            }
        }
        guard await owner.mcp.prepareWaitTrackingForRunStart(session: session, stopFence: stopFence) else { return nil }
        guard periodicStartIsCurrent(), stopFence.permitsStart(of: session), command.isCurrent, resourcesAreCurrent(),
              session.operationAdmissionFailureMessage == nil else { return nil }
        // A lane update has no user-authored base instruction, so every augmentation this applies —
        // skill context, tagged-file expansion, attachment rendering, staged handoff — is user-only
        // work with nothing to act on. Skipping it is what keeps the turn's only new provider input
        // the rendered lane claim the supplement path attaches.
        let switchMessages: (user: String, initial: String)?
        if session.pendingHandoff.providerSwitchDelivery != nil {
            switchMessages = await environment.prepareProviderSwitch(providerSwitchPreparation, session, stopFence)
            guard command.isCurrent, resourcesAreCurrent(), stopFence.permitsStart(of: session), periodicStartIsCurrent() else { return nil }
            guard switchMessages != nil else {
                let message = environment.providerSwitchRefusal(session)
                startOutcome?.recordStartFailure(message: message)
                return .failed(message: message)
            }
        } else {
            switchMessages = nil
        }
        let augmentedInitialMessage = if let switchMessages { switchMessages.user } else if directStartOptions.skipsUserAugmentation {
            initialMessage
        } else {
            await environment.augment(
                initialMessage, session, attachments, taggedFileAttachments,
                directStartOptions.ignoresPendingHandoff, directStartOptions.skipsSlashExpansion
            )
        }
        guard command.isCurrent, resourcesAreCurrent(), stopFence.permitsStart(of: session), periodicStartIsCurrent() else { return nil }
        // A provider control command is exactly its fixed native text: prepending initial-thread
        // context would make it ordinary prose the provider no longer recognizes as a command.
        let initialMessageForRun = if let switchMessages { switchMessages.initial } else { directStartOptions.providerControlCommand != nil
            || directStartOptions.selfCompactDispatchID?.stage == .note
            ? augmentedInitialMessage
            : await environment.initialMessage(session, augmentedInitialMessage)
        }
        guard periodicStartIsCurrent(), stopFence.permitsStart(of: session), command.isCurrent, resourcesAreCurrent(),
              session.operationAdmissionFailureMessage == nil else { return nil }
        let preparedCodexFallbackContext = codexFallbackContext.map { context in
            AgentTabSession.CodexFallbackSubmissionContext(
                queueID: context.queueID,
                providerText: initialMessageForRun,
                attachments: context.attachments,
                taggedFileAttachments: context.taggedFileAttachments,
                draftText: context.draftText,
                optimisticUserItemID: context.optimisticUserItemID,
                origin: context.origin,
                dispatchTicket: context.dispatchTicket,
                stopFence: context.stopFence ?? stopFence,
                isLocalUserInput: context.isLocalUserInput
            )
        }

        #if DEBUG
            if await environment.test_startOverride?(session, augmentedInitialMessage, initialMessageForRun) == true {
                guard command.isCurrent, resourcesAreCurrent(), stopFence.permitsStart(of: session), periodicStartIsCurrent() else { return nil }
                startOutcome?.recordAccepted()
                return nil
            }
        #endif
        guard command.isCurrent, resourcesAreCurrent(), stopFence.permitsStart(of: session), periodicStartIsCurrent() else { return nil }
        guard preparedClaudeEvents?.listener.isCurrent() != false else {
            recordClaudeStartRefusal()
            return nil
        }
        candidateTransferred = true
        claudeEventsTransferred = true
        return await environment.composition().startRun(
            tabID: tabID,
            session: session,
            initialUserMessage: augmentedInitialMessage,
            initialMessageForRun: initialMessageForRun,
            attachments: attachments,
            codexFallbackContext: preparedCodexFallbackContext,
            autoEffortSelection: autoEffortSelection,
            providerControlCommand: directStartOptions.providerControlCommand,
            selfCompactDispatchID: directStartOptions.selfCompactDispatchID,
            startOutcome: startOutcome,
            stopFence: stopFence,
            localComposerCandidate: directStartOptions.localComposerCandidate,
            initialUserItemID: directStartOptions.initialUserItemID,
            preparedClaudeEvents: preparedClaudeEvents
        )
    }

    /// Accepted steering has a runtime-owned producer even when its presentation detaches.
    /// The existing run service remains the serialized transport/drain authority.
    @discardableResult
    func queueClaudeSteering(
        session: AgentTabSession, service: AgentModeRunService, wrappedText: String,
        attachments: [AgentFileAttachment], taggedFiles: [AgentTaggedFileAttachment],
        draftText: String, userItem: AgentChatItem, localComposerCandidate: UUID?,
        skipsSlashExpansion: Bool, accepted: (() -> Void)? = nil
    ) -> Bool {
        guard let owner = scope, owner.sessions[session.tabID] === session,
              !owner.hasReleasedWriterClaims else { return false }
        // Claude Code preserves draft text and wakes current MCP waiters as soon
        // as the local steering request is accepted, then sends after MCP tools idle.
        let steering = AgentTabSession.ClaudeSteeringInstruction(
            id: UUID(),
            targetRunID: session.runID,
            targetRunAttemptID: session.activeRunAttemptID,
            providerText: wrappedText,
            attachments: attachments,
            taggedFileAttachments: taggedFiles,
            draftText: draftText,
            optimisticUserItemID: userItem.id,
            createdAt: Date(),
            supersedingProtectedTurnIDs: [],
            skipsSlashExpansion: skipsSlashExpansion
        )
        session.pendingClaudeSteeringInstructions.append(steering)
        session.settleLocalComposerOrigin(localComposerCandidate, disposition: .retained)
        accepted?()
        service.protectCurrentClaudeTurnForAcceptedSteeringIfNeeded(session: session, steeringID: steering.id)
        Self.steeringDebugLog("[AgentRunSteeringWake] Claude steering queued tab=\(session.tabID) runID=\(String(describing: session.runID)) attempt=\(String(describing: session.activeRunAttemptID)) queue=\(session.pendingClaudeSteeringInstructions.count) mcpDispatch=\(session.isMCPInstructionDispatchInProgress)")
        guard !session.isMCPInstructionDispatchInProgress else {
            Self.steeringDebugLog("[AgentRunSteeringWake] Claude steering flush owned by MCP dispatch tab=\(session.tabID) queue=\(session.pendingClaudeSteeringInstructions.count)")
            return true
        }
        Task { [owner, service] in
            defer { withExtendedLifetime(owner) {} }
            _ = await service.submitQueuedClaudeSteeringIfSupported(session: session)
        }
        return true
    }

    private static func steeringDebugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
            guard UserDefaults.standard.bool(forKey: "enableSteeringDebugLogging") else { return }
            print(message())
        #endif
    }
}
