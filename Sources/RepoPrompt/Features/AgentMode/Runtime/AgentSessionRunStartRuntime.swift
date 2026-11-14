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
        let providerSwitchRefusal: (AgentTabSession) -> String
        let input: AgentSessionProviderInputRuntime
        let workspacePaths: () -> [String]
        let inputWorkspace: (AgentTabSession) async throws -> AgentSessionProviderInputRuntime.WorkspaceSource?
        let initialThreadInput: (AgentTabSession) async throws -> AgentSessionProviderInputRuntime.InitialThreadInput?
        let composition: () -> AgentModeRunComposition
        var hostResources: AgentSessionHostStartupResources?
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
              !owner.isRetiring, !owner.hasReleasedWriterClaims,
              let originalMembership = owner.membership(of: session) else { return nil }
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
            if let resources = environment.hostResources {
                guard resources.origin.writer.session === session, resources.isCurrent else { return false }
            }
            guard environment.currentWorkspaceID() == originalWorkspaceID else { return false }
            // An already-mismatched host is not a valid resource snapshot merely because it
            // stayed unchanged. Nil remains the explicit no-workspace resource composition.
            guard let originalWorkspaceID, let writer else { return true }
            return originalWorkspaceID == writer.identity.workspaceID
        }
        func isCurrent() -> Bool {
            guard owner.sessions[tabID] === session, !owner.isRetiring, !owner.hasReleasedWriterClaims,
                  resourcesAreCurrent() else { return false }
            if let writer { return writer.isCurrent }
            // A blank draft has no persistent Writer yet. Its slot still has exact provenance:
            // preparation must not adopt a remove/re-add of the same unbound object.
            return originalMembership.permitsBindingPreparation
                && session.currentRestorationBindingToken == originalBindingToken
        }
        if let writer, let originalWorkspaceID, originalWorkspaceID != writer.identity.workspaceID {
            startOutcome?.recordStartFailure(message: "Workspace resources do not belong to the session's runtime writer.")
            return nil
        }
        guard isCurrent() else { return nil }
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
        /// One async host-resource admission boundary. Resource currency does not authorize a
        /// writer or scheduled turn: recheck all originating facts after the authority hop.
        func admitHostResources(_ fence: AgentRunStartStopFence) async -> Bool {
            guard let resources = environment.hostResources else { return true }
            guard !Task.isCancelled, isCurrent(), periodicStartIsCurrent(), fence.permitsStart(of: session) else { return false }
            guard await resources.validate() else { return false }
            return !Task.isCancelled && isCurrent() && periodicStartIsCurrent() && fence.permitsStart(of: session)
        }
        guard await admitHostResources(originalStopFence) else { return nil }
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
            guard await admitHostResources(originalStopFence) else { return nil }
            // The resource authority hop can admit a new provider adoption. Do not reserve
            // events or steer through that operation's preparation ownership.
            guard claudeCoordinator.pendingProviderAdoption(for: session) == nil else {
                recordClaudeStartRefusal()
                return nil
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
                    taggedFiles: existingItem?.taggedFileAttachments ?? taggedFileAttachments,
                    draftText: directStartOptions.restorationDraftText ?? initialMessage, userItem: userItem,
                    localComposerCandidate: directStartOptions.localComposerCandidate,
                    skipsSlashExpansion: directStartOptions.skipsSlashExpansion,
                    providerTaggedFiles: taggedFileAttachments
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
        if let directCreation = bindingAdmission.creation {
            guard case .durablySaved = await owner.persistence.commitConfiguredCreation(directCreation, writer: writer) else {
                let message = "The new session could not save its initial configuration. Retry saving it before starting a run."
                startOutcome?.recordStartFailure(message: message)
                return .failed(message: message)
            }
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
        var inputSources = providerSwitchPreparation?.inputSources ?? []
        func inputIsCurrent() -> Bool {
            command.isCurrent && resourcesAreCurrent() && stopFence.permitsStart(of: session) && periodicStartIsCurrent()
                && inputSources.allSatisfy { $0.isCurrent() }
        }
        func runInputIsCurrent() -> Bool {
            periodicStartIsCurrent() && stopFence.permitsStart(of: session) && command.isCurrent && resourcesAreCurrent()
                && session.operationAdmissionFailureMessage == nil && inputSources.allSatisfy { $0.isCurrent() }
        }
        guard await owner.mcp.prepareWaitTrackingForRunStart(session: session, stopFence: stopFence) else { return nil }
        guard runInputIsCurrent() else { return nil }
        // A lane update has no user-authored base instruction, so every augmentation this applies —
        // skill context, tagged-file expansion, attachment rendering, staged handoff — is user-only
        // work with nothing to act on. Skipping it is what keeps the turn's only new provider input
        // the rendered lane claim the supplement path attaches.
        let switchMessages: (user: String, initial: String)?
        if session.pendingHandoff.providerSwitchDelivery != nil {
            switchMessages = await links.prepareProviderSwitchHandoverForSend(providerSwitchPreparation, session: session, stopFence: stopFence)
            guard inputIsCurrent() else { return nil }
            guard switchMessages != nil else {
                let message = environment.providerSwitchRefusal(session)
                startOutcome?.recordStartFailure(message: message)
                return .failed(message: message)
            }
        } else {
            switchMessages = nil
        }
        var taggedFileFailures = providerSwitchPreparation?.taggedFileFailures ?? []
        let augmentedInitialMessage: String
        let initialMessageForRun: String
        do {
            augmentedInitialMessage = if let switchMessages { switchMessages.user } else if directStartOptions.skipsUserAugmentation {
                initialMessage
            } else {
                try await environment.input.augmentUserMessage(
                    initialMessage, attachments: attachments, taggedFileAttachments: taggedFileAttachments,
                    agent: session.selectedAgent, workspacePaths: environment.workspacePaths(),
                    workspace: {
                        let source = try await environment.inputWorkspace(session)
                        if let source { inputSources.append(source) }
                        return source
                    }, workspaceCaptureOrder: environment.hostResources == nil ? .afterSkillExpansion : .beforeSkillExpansion,
                    session: session, handoff: owner.handoff,
                    ignoresPendingHandoff: directStartOptions.ignoresPendingHandoff,
                    skipsSlashExpansion: directStartOptions.skipsSlashExpansion, isCurrent: inputIsCurrent,
                    onTaggedFileFailures: { taggedFileFailures = $0 }
                )
            }
            guard inputIsCurrent() else { return nil }
            // A provider control command is exactly its fixed native text: prepending initial-thread
            // context would make it ordinary prose the provider no longer recognizes as a command.
            initialMessageForRun = if let switchMessages { switchMessages.initial } else { directStartOptions.providerControlCommand != nil
                || directStartOptions.selfCompactDispatchID?.stage == .note
                ? augmentedInitialMessage
                : try await environment.input.buildInitialThreadMessageIfNeeded(
                    session: session, initialMessage: augmentedInitialMessage,
                    input: {
                        let input = try await environment.initialThreadInput(session)
                        if let input { inputSources.append(input.workspace) }
                        return input
                    }, isCurrent: inputIsCurrent
                )
            }
        } catch {
            startOutcome?.recordStartFailure(message: "The originating workspace context is no longer available.")
            return nil
        }
        guard runInputIsCurrent() else { return nil }
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
                guard inputIsCurrent() else { return nil }
                AgentSessionProviderInputRuntime.recordTaggedFileFailures(taggedFileFailures, session: session, scope: owner)
                startOutcome?.recordAccepted()
                return nil
            }
        #endif
        guard runInputIsCurrent() else { return nil }
        let providerLaunchInput: AgentProviderLaunchInput?
        do {
            providerLaunchInput = try await environment.hostResources?.captureProviderLaunchInput(for: command).retainingInputSources(inputSources)
        } catch {
            startOutcome?.recordStartFailure(message: "The originating provider launch resources are no longer available.")
            return nil
        }
        guard await admitHostResources(stopFence), runInputIsCurrent() else { return nil }
        for source in inputSources {
            guard await source.validate(), runInputIsCurrent() else { return nil }
        }
        guard preparedClaudeEvents?.listener.isCurrent() != false else {
            recordClaudeStartRefusal()
            return nil
        }
        AgentSessionProviderInputRuntime.recordTaggedFileFailures(taggedFileFailures, session: session, scope: owner)
        candidateTransferred = true
        claudeEventsTransferred = true
        return await environment.composition().startRun(
            tabID: tabID,
            session: session,
            origin: command,
            providerLaunchInput: providerLaunchInput,
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
        skipsSlashExpansion: Bool, providerTaggedFiles: [AgentTaggedFileAttachment]? = nil,
        accepted: (() -> Void)? = nil,
        inputAdmission: AgentSessionProviderInputRuntime.Admission? = nil
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
            skipsSlashExpansion: skipsSlashExpansion,
            providerTaggedFileAttachments: providerTaggedFiles,
            runtimeInputAdmission: inputAdmission
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
