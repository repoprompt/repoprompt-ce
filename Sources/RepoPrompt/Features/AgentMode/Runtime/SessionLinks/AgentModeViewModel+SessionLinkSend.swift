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
        guard let delivery = session.pendingHandoff.providerSwitchDelivery else { return .success(nil) }
        guard delivery == .ready else {
            guard Self.providerSwitchHasOwnedCarryingAttempt(session) else { return .failure(.providerSwitchUnconfirmed) }
            return .failure(Self.providerSwitchNeedsReview(session) ? .providerHandoverNeedsReview : .targetNotIdle)
        }
        guard !Self.providerSwitchNeedsReview(session) else { return .failure(.providerHandoverNeedsReview) }
        guard !session.runState.isActive, session.activeRunOwnership == nil else { return .failure(.targetNotIdle) }
        let handoff = session.pendingHandoff
        let binding = session.currentRestorationBindingToken
        let agent = session.selectedAgent
        let model = session.selectedModelRaw
        let computerUseArmed = session.isCodexComputerUseArmed
        let catalogWindow = providerSwitchCatalogWindow(agent: agent, model: model)
        let historyAllowed = providerSwitchHistoryToolAllowed(session)
        let instructions = providerSwitchInstructionStrings(session, includeSupplement: !inputAlreadyIncludesSupplement)
        let composerAttemptID = session.activeComposerSubmitAttempt?.id
        let stopFence = AgentRunStartStopFence(session: session)
        let augmented = skipsAugmentation ? input : await augmentUserMessageForProviderSend(
            input, attachments: attachments, taggedFileAttachments: taggedFiles,
            agent: agent, session: session, ignoresPendingHandoff: true,
            skipsSlashExpansion: skipsSlashExpansion
        )
        let initial = await buildInitialThreadMessageIfNeeded(
            tabID: session.tabID, session: session, initialMessage: augmented
        )
        guard isCurrent(), !Task.isCancelled else { return .failure(.targetStopped) }
        guard !session.runState.isActive, session.activeRunOwnership == nil else { return .failure(.targetNotIdle) }
        guard sessions[session.tabID] === session,
              session.currentRestorationBindingToken == binding,
              session.pendingHandoff == handoff,
              session.selectedAgent == agent, session.selectedModelRaw == model,
              session.isCodexComputerUseArmed == computerUseArmed,
              !Self.providerSwitchNeedsReview(session)
        else { return .failure(.providerHandoverNeedsReview) }
        guard providerSwitchCatalogWindow(agent: agent, model: model) == catalogWindow,
              providerSwitchHistoryToolAllowed(session) == historyAllowed,
              providerSwitchInstructionStrings(session, includeSupplement: !inputAlreadyIncludesSupplement) == instructions
        else { return .failure(.providerHandoverNeedsReview) }
        guard let payload = handoff.payload, !payload.isEmpty else { return .failure(.providerHandoverNeedsReview) }
        let bytes = payload.utf8.count
        guard bytes <= AgentProviderHandover.maximumBytes else { return .failure(.providerHandoverDoesNotFit) }
        guard let descriptor = ProviderSwitchCarrierDescriptor(payload),
              providerSwitchReadReferenceIsCurrent(descriptor, session: session)
        else { return .failure(.providerHandoverNeedsReview) }
        var budgetInstructions = instructions
        if let supplementalInput, let current = budgetInstructions.last,
           supplementalInput.utf8.count > current.utf8.count { budgetInstructions[budgetInstructions.count - 1] = supplementalInput }
        let budget = AgentProviderHandover.Budget(
            catalogWindow: catalogWindow,
            instructions: budgetInstructions, composedInput: "\n\n" + initial, isPreview: false
        )
        guard descriptor.mode != "summary" || bytes <= AgentProviderHandover.maximumSummaryBytes,
              AgentProviderHandover.estimate(payload) <= budget.remainingCarrierTokens
        else { return .failure(.providerHandoverDoesNotFit) }
        return .success(ProviderSwitchSendPreparation(
            binding: binding, handoff: handoff, agent: agent, model: model, rawInput: input,
            augmentedInput: augmented, initialThreadInput: initial, instructions: instructions,
            inputAlreadyIncludesSupplement: inputAlreadyIncludesSupplement,
            historyToolAllowed: historyAllowed, computerUseArmed: computerUseArmed,
            catalogWindow: catalogWindow, composerAttemptID: composerAttemptID, autoWakeID: autoWakeID, stopFence: stopFence
        ))
    }

    func providerSwitchCatalogWindow(agent: AgentProviderKind, model: String) -> Int? {
        if agent.usesClaudeNativeRuntime {
            return ClaudeCompatibleModelCatalogAdapter.contextWindowTokens(forRequestedModelRaw: model, agentKind: agent)
                ?? AgentModel.resolvedModel(forRaw: model, agentKind: agent)?.contextWindowTokens
        }
        return AgentModel.resolvedModel(forRaw: model, agentKind: agent)?.contextWindowTokens
    }

    /// Existing prompt owners author all these strings. Rendering current inventory in full is
    /// conservative for a pending fresh context and neither reserves nor acknowledges a claim.
    func providerSwitchInstructionStrings(_ session: TabSession, includeSupplement: Bool = true, destination: AgentProviderKind? = nil, includeOwedContent: Bool = true) -> [String] {
        let agent = destination ?? session.selectedAgent
        let prompt = SystemPromptService.agentModePrompt(
            agentKind: agent, taskLabelKind: session.mcpControlContext?.taskLabelKind,
            codeMapsDisabled: GlobalSettingsStore.shared.globalCodeMapsDisabled()
        )
        let packagedPrompt = agent.usesClaudeNativeRuntime
            ? ClaudeCompatiblePluginBridge.providerBoundUserMessage("", instructions: prompt, delivery: ClaudeAgentToolPreferences.agentModePromptDelivery()) : ""
        var strings = [packagedPrompt.isEmpty ? prompt : packagedPrompt]
        if includeOwedContent, let note = session.selfCompactState.parkedNote { strings.append(note.frame) }
        var supplement = ""
        if includeSupplement, let context = agentSessionLinkPromptContext(for: session), context.epoch.allowsSupplement {
            let baseline = AgentSessionLinkPrompts.rendered(.init(
                membershipKind: context.inventory.isEmpty ? nil : .inventory,
                inventory: context.inventory, passiveNotices: includeOwedContent ? context.passiveNotices : nil,
                toolReference: context.epoch.toolReference
            ))
            supplement = includeOwedContent ? (AgentSessionLinkRuntimeBridge.shared.localInputDecoration(
                observer: context.epoch.endpoint, inventory: context.inventory, baseline: baseline
            )?.fragment ?? baseline.fragment) : baseline.fragment
        }
        strings.append(supplement)
        return strings
    }

    static func providerSwitchStartRefusal(_ session: TabSession) -> AgentSessionLinkSendFailure {
        session.pendingHandoff.providerSwitchDelivery == .ready ? .providerHandoverNeedsReview : .providerSwitchUnconfirmed
    }

    static func providerSwitchHasOwnedCarryingAttempt(_ session: TabSession) -> Bool {
        guard let delivery = session.pendingHandoff.providerSwitchDelivery,
              let proof = session.pendingHandoff.providerSwitchDispatch,
              proof.binding == session.currentRestorationBindingToken,
              proof.stopFence.permitsStart(of: session),
              delivery == .ready || session.pendingHandoff.isStagedForSend else { return false }
        if let ownership = proof.runOwnership {
            return session.isCurrentRunAttempt(ownership, expectedRunID: proof.runID)
        }
        if let wakeID = proof.autoWakeID, let attempt = session.oversight.pendingAutoWake,
           attempt.wakeID == wakeID, !attempt.isPeriodic, attempt.phase == .preparingDispatch,
           attempt.physicalOutcome == .notAttempted
        { return true }
        if let claimID = proof.composerAttemptID, session.activeComposerSubmitAttempt?.id == claimID { return true }
        if let inputID = proof.acceptedInputID {
            if session.hasLocalComposerCandidate(itemID: inputID, fence: proof.stopFence) { return true }
            // Non-local producers (session-link send, MCP resident, auto/periodic wakes) leave no
            // composer candidate, and their claim can be released before the spawned run registers
            // ownership. The durably accepted row itself is the carrying attempt until then.
            return session.items.contains { $0.id == inputID }
        }
        return false
    }

    static func providerSwitchUnconfirmed(_ session: TabSession) -> Bool {
        session.pendingHandoff.providerSwitchDelivery == .sending && !providerSwitchHasOwnedCarryingAttempt(session)
    }

    /// Accepted input after the saved cutoff invalidates the ready seed. The exact input currently
    /// being started is excluded, never arbitrary equal text. Missing retained cutoff fails closed.
    static func providerSwitchNeedsReview(_ session: TabSession, excluding inputID: UUID? = nil) -> Bool {
        guard session.pendingHandoff.providerSwitchDelivery != nil else { return false }
        // Once the carrying dispatch is physically bound, the handover is already en route to the
        // destination; input accepted after it is ordinary traffic on that run, never staleness.
        if session.pendingHandoff.providerSwitchDispatch?.dispatchID != nil { return false }
        let ownedInputID = inputID ?? (providerSwitchHasOwnedCarryingAttempt(session) ? session.pendingHandoff.providerSwitchDispatch?.acceptedInputID : nil)
        var positions: [UUID: Int] = [:]
        var inputs: [UUID: Int] = [:]
        func record(_ id: UUID, _ sequence: Int, input: Bool) {
            positions[id] = sequence
            if input, id != ownedInputID { inputs[id] = sequence }
        }
        for turn in session.transcript.turns {
            if let request = turn.request { record(request.id, request.sequenceIndex, input: true) }
            for activity in turn.allActivities {
                record(
                    activity.id,
                    activity.sequenceIndex,
                    input: activity.itemKind == .user
                        || activity.text == AgentLaneUpdateDisplayAttribution.canonicalSystemText
                        || activity.text == AgentChatItem.overseerCompactionRequestText
                )
            }
            for diagnostic in turn.summary?.recoveryDiagnostics ?? [] {
                record(diagnostic.id, diagnostic.sequenceIndex, input: false)
            }
        }
        for item in session.items {
            record(
                item.id,
                item.sequenceIndex,
                input: item.kind == .user
                    || item.text == AgentLaneUpdateDisplayAttribution.canonicalSystemText
                    || item.text == AgentChatItem.overseerCompactionRequestText
            )
        }
        guard let cutoffID = session.pendingHandoff.sourceItemID else { return !inputs.isEmpty }
        guard let cutoff = positions[cutoffID] else { return true }
        return inputs.values.contains { $0 > cutoff }
    }

    /// Sole M1 insertion point. Required-save sending before invoking any runner. Currency failure
    /// after acceptance withholds start; it is not a second fit/admission decision.
    func prepareProviderSwitchHandoverForSend(
        _ preparation: ProviderSwitchSendPreparation?, session: TabSession,
        stopFence: AgentRunStartStopFence
    ) async -> (user: String, initial: String)? {
        guard let preparation else { return nil }
        guard providerSwitchPreparationIsCurrent(preparation, session: session),
              stopFence.permitsStart(of: session),
              let payload = preparation.handoff.payload,
              let workspaceID = workspaceManager?.activeWorkspaceID
        else { return nil }
        session.pendingHandoff.providerSwitchDelivery = .sending
        session.pendingHandoff.isStagedForSend = true
        session.pendingHandoff.providerSwitchDispatch = preparation.physicalDispatch
        let sending = session.pendingHandoff
        session.isDirty = true
        var sendingSaverReturned = false
        let sendingSave = await flushSaveRequired(for: session.tabID, workspaceID: workspaceID, observingSavePhase: {
            if case .writeReturned = $0 { sendingSaverReturned = true }
        })
        guard case .success = sendingSave else {
            if sendingSaverReturned, sessions[session.tabID] === session,
               session.currentRestorationBindingToken == preparation.binding, session.pendingHandoff == sending
            {
                // This VM has not released input to a runner. A known returned write may re-save
                // ready, but never authorizes dispatch or replay of the accepted input.
                await providerSwitchRestoreReadyBeforeDispatch(session: session, sending: sending, workspaceID: workspaceID)
            }
            // Unknown writes or loss of the exact no-runner proof remain inert sending.
            if sessions[session.tabID] === session, session.currentRestorationBindingToken == preparation.binding,
               session.pendingHandoff == sending
            {
                session.pendingHandoff.isStagedForSend = false
                session.pendingHandoff.providerSwitchDispatch = nil
            }
            return nil
        }
        guard sessions[session.tabID] === session, session.currentRestorationBindingToken == preparation.binding,
              session.pendingHandoff == sending else { return nil }
        guard !Task.isCancelled, stopFence.permitsStart(of: session),
              !session.runState.isActive, session.activeRunOwnership == nil,
              session.selectedAgent == preparation.agent, session.selectedModelRaw == preparation.model,
              session.isCodexComputerUseArmed == preparation.computerUseArmed,
              providerSwitchCatalogWindow(agent: preparation.agent, model: preparation.model) == preparation.catalogWindow,
              providerSwitchHistoryToolAllowed(session) == preparation.historyToolAllowed,
              providerSwitchInstructionStrings(session, includeSupplement: !preparation.inputAlreadyIncludesSupplement) == preparation.instructions
        else {
            // Only this VM path proves the runner has not been invoked. An unacknowledged ready
            // re-save restores sending; controller-specific failures never enter this path.
            await providerSwitchRestoreReadyBeforeDispatch(session: session, sending: sending, workspaceID: workspaceID)
            return nil
        }
        return (payload + "\n\n" + preparation.augmentedInput, payload + "\n\n" + preparation.initialThreadInput)
    }

    func providerSwitchPreparationIsCurrent(_ preparation: ProviderSwitchSendPreparation, session: TabSession) -> Bool {
        sessions[session.tabID] === session && session.currentRestorationBindingToken == preparation.binding
            && session.selectedAgent == preparation.agent && session.selectedModelRaw == preparation.model
            && !session.runState.isActive && session.activeRunOwnership == nil
            && session.pendingHandoff == preparation.handoff
            && providerSwitchCatalogWindow(agent: preparation.agent, model: preparation.model) == preparation.catalogWindow
            && providerSwitchHistoryToolAllowed(session) == preparation.historyToolAllowed
            && session.isCodexComputerUseArmed == preparation.computerUseArmed
            && !Self.providerSwitchNeedsReview(session, excluding: preparation.acceptedInputID)
            && providerSwitchInstructionStrings(session, includeSupplement: !preparation.inputAlreadyIncludesSupplement) == preparation.instructions
    }

    func providerSwitchRestoreReadyBeforeDispatch(
        session: TabSession, sending: PendingHandoffState, workspaceID: UUID
    ) async {
        guard sessions[session.tabID] === session, session.pendingHandoff == sending,
              let proof = sending.providerSwitchDispatch, proof.binding == session.currentRestorationBindingToken,
              proof.runOwnership == nil, proof.runID == nil, proof.dispatchID == nil,
              !session.runState.isActive, session.activeRunOwnership == nil else { return }
        let binding = session.currentRestorationBindingToken
        session.pendingHandoff.providerSwitchDelivery = .ready
        session.pendingHandoff.isStagedForSend = false
        session.pendingHandoff.providerSwitchDispatch = nil
        let ready = session.pendingHandoff
        session.isDirty = true
        var readySaverReturned = false
        let readySave = await flushSaveRequired(for: session.tabID, workspaceID: workspaceID, observingSavePhase: {
            if case .writeReturned = $0 { readySaverReturned = true }
        })
        if case .failure = readySave,
           !(readySaverReturned && !session.runState.isActive && session.activeRunOwnership == nil),
           sessions[session.tabID] === session, session.currentRestorationBindingToken == binding,
           session.pendingHandoff == ready
        {
            session.pendingHandoff = sending
            session.pendingHandoff.isStagedForSend = false
            session.pendingHandoff.providerSwitchDispatch = nil
            session.isDirty = true
        }
    }

    /// Called at the existing physical acquisition hook, not pipeline admission. Binding one exact
    /// logical dispatch is transient evidence; losing it on restart leaves durable sending inert.
    func providerSwitchAcquirePhysicalDispatch(session: TabSession, dispatchID: AgentSessionLinkPromptDispatchID) -> Bool {
        guard session.pendingHandoff.providerSwitchDelivery != nil else { return true }
        guard session.pendingHandoff.providerSwitchDelivery == .sending,
              session.pendingHandoff.isStagedForSend else { return false }
        let effectiveID = agentSessionLinkEffectiveDispatchID(for: session, dispatchID: dispatchID)
        guard let staged = session.pendingHandoff.providerSwitchDispatch,
              sessions[session.tabID] === session, staged.binding == session.currentRestorationBindingToken,
              staged.stopFence.permitsStart(of: session),
              let ownership = staged.runOwnership, let runID = session.runID,
              session.isCurrentRunAttempt(ownership, expectedRunID: staged.runID),
              !Self.providerSwitchNeedsReview(session, excluding: staged.acceptedInputID),
              staged.admission.agent == session.selectedAgent, staged.admission.model == session.selectedModelRaw,
              staged.admission.catalogWindow == providerSwitchCatalogWindow(agent: session.selectedAgent, model: session.selectedModelRaw),
              staged.admission.computerUseArmed == session.isCodexComputerUseArmed,
              staged.admission.historyToolAllowed == providerSwitchHistoryToolAllowed(session),
              staged.admission.instructionsDigest == ProviderSwitchAdmissionEvidence.digest(providerSwitchInstructionStrings(session, includeSupplement: !staged.admission.inputAlreadyIncludesSupplement))
        else { return false }
        if let boundID = staged.dispatchID { return boundID == effectiveID && staged.runID == runID }
        guard staged.runID == nil else { return false }
        session.pendingHandoff.providerSwitchDispatch = staged.bindingDispatch(effectiveID, runID: runID)
        return true
    }

    func providerSwitchRunSettled(_ session: TabSession, revision: AgentRunTerminalCommitRevision, publication: AgentRunTerminalPublicationResult) {
        guard publication.isResolved, sessions[session.tabID] === session,
              let proof = session.pendingHandoff.providerSwitchDispatch,
              proof.binding == session.currentRestorationBindingToken,
              proof.runOwnership == revision.ownership,
              proof.runID == nil || proof.runID == revision.expectedRunID
        else { return }
        session.pendingHandoff.providerSwitchDispatch = nil
    }

    /// Existing physical acceptance context is stronger than the legacy handoff Boolean (ACP's
    /// Boolean is earlier than its actual prompt return). Late/foreign contexts cannot clear M1.
    func providerSwitchRecordPhysicalAcceptance(session: TabSession, context: AgentSessionLinkDispatchContext?) {
        guard sessions[session.tabID] === session,
              let context, session.pendingHandoff.providerSwitchDelivery == .sending,
              session.pendingHandoff.isStagedForSend,
              let staged = session.pendingHandoff.providerSwitchDispatch,
              staged.dispatchID == context.dispatchID, staged.binding == session.currentRestorationBindingToken,
              let workspaceID = workspaceManager?.activeWorkspaceID else { return }
        let sending = session.pendingHandoff
        let binding = session.currentRestorationBindingToken
        session.pendingHandoff.clearAfterSend()
        let cleared = session.pendingHandoff
        let model = inputBarModelDisplayName(rawModel: session.selectedModelRaw, agentKind: session.selectedAgent)
        let text = "Handover sent to \(session.selectedAgent.displayName) / \(model)."
        session.appendItem(.system(text, sequenceIndex: session.nextSequenceIndex, recoveryDiagnostic: .init(
            reason: "providerSwitch", outcome: "sent", text: text
        )))
        session.isDirty = true
        Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            // A returned frozen clear must survive later save-token drift. The ordinary fresh-save
            // owner carries it forward; only an unacknowledged write restores uncertainty.
            var saverReturned = false
            let result = await flushSaveRequired(for: session.tabID, workspaceID: workspaceID, observingSavePhase: {
                if case .writeReturned = $0 { saverReturned = true }
            })
            if case .failure = result, !saverReturned,
               sessions[session.tabID] === session, session.currentRestorationBindingToken == binding,
               session.pendingHandoff == cleared
            {
                session.pendingHandoff = sending
                session.pendingHandoff.isStagedForSend = false
                session.pendingHandoff.providerSwitchDispatch = nil
                session.isDirty = true
                scheduleSave(for: session.tabID)
            }
        }
    }

    func providerSwitchHistoryToolAllowed(_ session: TabSession, destination: AgentProviderKind? = nil) -> Bool {
        guard AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(toolName: "history", taskLabelKind: session.mcpControlContext?.taskLabelKind) else { return false }
        if (destination ?? session.selectedAgent).usesClaudeNativeRuntime {
            return !MCPIntegrationHelper.claudeDisallowedTools(for: .agentRun).contains("mcp__\(MCPIntegrationHelper.repoPromptMCPServerName)__history")
        }
        return true
    }

    func providerSwitchReadReferenceIsCurrent(_ descriptor: ProviderSwitchCarrierDescriptor, session: TabSession, destination: AgentProviderKind? = nil) -> Bool {
        guard !descriptor.readableMarkers.isEmpty else { return true }
        guard let sessionID = session.activeAgentSessionID,
              providerSwitchHistoryToolAllowed(session, destination: destination)
        else { return false }
        let server = (destination ?? session.selectedAgent) == .grokBuild
            ? RepoPromptMCPServerConfiguration.grokBuildRuntimeServerName : MCPIntegrationHelper.repoPromptMCPServerName
        return descriptor.readableMarkers.allSatisfy { marker in
            guard let first = Int(marker.attributes["first"] ?? ""), let last = Int(marker.attributes["last"] ?? ""),
                  first >= 0, last >= first, last < session.transcript.turns.count else { return false }
            guard let reference = try? AgentProviderHandover.HistoryReference(server: server, sessionID: sessionID, historyAllowed: true, indicesMatch: true) else { return false }
            let expected = AgentProviderHandover.readableHistoryInstruction(first ... last, reference: reference)
            return marker.text.trimmingCharacters(in: .whitespacesAndNewlines) == expected
        }
    }

    static func providerSwitchIsInFlightOnActiveRun(_ session: TabSession) -> Bool {
        session.pendingHandoff.providerSwitchDelivery == .sending
            && session.runState.isActive && providerSwitchHasOwnedCarryingAttempt(session)
            && session.pendingHandoff.providerSwitchDispatch?.dispatchID != nil
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
        AgentSessionLinkDeliveryReadiness.Snapshot(
            hasLoadedPersistedState: session.hasLoadedPersistedState,
            restorationReadiness: session.qualifiedRestorationReadiness,
            bindingTransitionInProgress: session.bindingTransitionInProgress,
            isClosing: isClosing,
            endpointMatchesGrant: endpointMatchesGrant,
            runStateIsActive: session.runState.isActive
                || (!ignoresComposerSubmissionInFlight && providerSwitchHasOwnedCarryingAttempt(session)),
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
            pendingSelfCompact: session.selfCompactState.blocksOverseerDelivery
                && session.selfCompactState.active?.id != ignoresSelfCompactRequestID,
            selfCompactBlocksManagedStop: session.selfCompactState.blocksManagedStop
                && session.selfCompactState.active?.id != ignoresSelfCompactRequestID,
            stopInProgress: session.stopState.isStopping(binding: session.persistentSessionBindingIdentity),
            backgroundCompactionSettling: session.isSettlingACPBackgroundCompaction,
            providerSwitchUnconfirmed: providerSwitchUnconfirmed(session),
            providerHandoverNeedsReview: !ignoresProviderSwitchStalenessAfterAcceptance && providerSwitchNeedsReview(session),
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
            return .blocked(.endpointSession)
        }
        // A queued send is withdrawn only by an explicit Stop since it was queued; internal
        // lifecycle cancellations must not drop it. The transaction's own start fence is taken
        // now, so a cancellation during the drain still downgrades dispatch to persisted-only.
        if let queuedFence = request.startStopFence, !queuedFence.permitsQueuedDelivery(to: session) {
            return .blocked(.targetStopped)
        }
        let stopFence = AgentRunStartStopFence(session: session)
        guard stopFence.permitsStart(of: session) else { return .blocked(.targetStopped) }
        let admissionLiveness = liveness()
        guard admissionLiveness.permitsDelivery else {
            return .blocked(.invalidated(admissionLiveness))
        }

        // 2. Pure readiness admission.
        if let failure = AgentSessionLinkDeliveryReadiness.failure(
            snapshot: Self.agentSessionLinkDeliveryReadinessSnapshot(
                session: session,
                endpointMatchesGrant: admissionLiveness.targetEndpointIsLive,
                isClosing: admissionLiveness.targetWindowIsClosing
            )
        ) {
            return .blocked(failure == .endpointInvalidated ? .endpointReadiness : failure)
        }

        let envelope = AgentSessionLinkMessageEnvelope.render(
            sourceSessionID: request.observerSessionID, sourceName: request.observerDisplayName,
            linkID: request.linkID, linkGeneration: request.linkGeneration,
            message: request.message, framing: request.framing
        )
        let providerMessage = AgentSessionLinkMessageEnvelope.providerPayload(
            envelope: envelope, workflow: request.workflow,
            includeBuiltInSessionCleanupGuidance: GlobalSettingsStore.shared.showBuiltInWorkflowCleanupGuidance()
        )
        let computerUseArmedAtAdmission = session.isCodexComputerUseArmed
        let dispatchedMessage = computerUseArmedAtAdmission
            ? CodexComputerUseWorkflow.renderProviderPrompt(userInstructions: providerMessage) : providerMessage
        if case let .failure(failure) = await providerSwitchSendAdmission(session: session, input: dispatchedMessage, isCurrent: {
            stopFence.permitsStart(of: session) && liveness().permitsDelivery
        }) { return .blocked(failure) }

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
            return .blocked(commit.refusal)
        }

        // Only a switch carries admission evidence across authorization. Ordinary SEND keeps its
        // existing postauthorization composition behavior in persistAndStartNoncomposerTurn.
        if session.pendingHandoff.providerSwitchDelivery != nil,
           session.isCodexComputerUseArmed != computerUseArmedAtAdmission
        {
            releaseComposerSubmitClaim(claim)
            return .blocked(.endpointPostReadiness)
        }
        let switchPreparation: ProviderSwitchSendPreparation?
        switch await providerSwitchSendAdmission(session: session, input: dispatchedMessage, isCurrent: {
            stopFence.permitsStart(of: session) && liveness().permitsDelivery && self.composerSubmitClaimIsCurrent(claim)
        }) {
        case let .failure(failure):
            releaseComposerSubmitClaim(claim)
            return .blocked(failure)
        case let .success(preparation): switchPreparation = preparation
        }

        // 5. The commit awaited, so every identity and readiness fact must be re-proven — including
        //    the observer incarnation and the target window's closing state, which an observer
        //    rebind/close or a window teardown during that await would otherwise slip past.
        let postCommitLiveness = liveness()
        guard let liveSession = agentSessionLinkLiveSession(matching: candidate) else {
            releaseComposerSubmitClaim(claim)
            return .blocked(.endpointPostSession)
        }
        guard liveSession === session else {
            releaseComposerSubmitClaim(claim)
            return .blocked(.endpointPostSession)
        }
        guard postCommitLiveness.permitsDelivery else {
            releaseComposerSubmitClaim(claim)
            return .blocked(.invalidated(postCommitLiveness, postCommit: true))
        }
        guard composerSubmitClaimIsCurrent(claim) else {
            releaseComposerSubmitClaim(claim)
            return .blocked(.endpointClaim)
        }
        if let failure = AgentSessionLinkDeliveryReadiness.failure(
            snapshot: Self.agentSessionLinkDeliveryReadinessSnapshot(
                session: liveSession,
                endpointMatchesGrant: postCommitLiveness.targetEndpointIsLive,
                isClosing: postCommitLiveness.targetWindowIsClosing,
                ignoresComposerSubmissionInFlight: true
            )
        ) {
            releaseComposerSubmitClaim(claim)
            return .blocked(failure == .endpointInvalidated ? .endpointPostReadiness : failure)
        }
        guard let workspaceID = workspaceManager?.activeWorkspace?.id else {
            releaseComposerSubmitClaim(claim)
            return .blocked(.endpointMissingWorkspace)
        }
        guard workspaceID == candidate.workspaceID else {
            releaseComposerSubmitClaim(claim)
            return .blocked(.endpointWorkspace)
        }

        return await persistAndStartNoncomposerTurn(
            session: liveSession,
            tabID: candidate.tabID,
            workspaceID: workspaceID,
            claim: claim,
            displayText: request.message,
            providerMessage: providerMessage,
            workflow: request.workflow,
            attribution: request.attribution,
            stopFence: stopFence,
            providerSwitchPreparation: switchPreparation
        ) {
            let dispatchLiveness = liveness()
            guard self.agentSessionLinkLiveSession(matching: candidate) === liveSession,
                  dispatchLiveness.permitsDelivery,
                  self.composerSubmitClaimIsCurrent(claim),
                  stopFence.permitsStart(of: liveSession),
                  self.workspaceManager?.activeWorkspace?.id == candidate.workspaceID
            else { return false }
            return AgentSessionLinkDeliveryReadiness.failure(
                snapshot: Self.agentSessionLinkDeliveryReadinessSnapshot(
                    session: liveSession,
                    endpointMatchesGrant: dispatchLiveness.targetEndpointIsLive,
                    isClosing: dispatchLiveness.targetWindowIsClosing,
                    ignoresComposerSubmissionInFlight: true,
                    ignoresProviderSwitchStalenessAfterAcceptance: true
                )
            ) == nil
        }
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
        // Every noncomposer caller shares this pre-row fence. A completed but failed restoration
        // must never become a replacement transcript merely because it reached an idle runtime.
        guard liveSession.permitsBoundOperationAndSave else {
            releaseComposerSubmitClaim(claim)
            let reason = AgentSessionLinkDeliveryReadiness.restorationBlockReason(liveSession.qualifiedRestorationReadiness)
            return .blocked(AgentSessionLinkSendFailure(reason ?? .targetLoading))
        }
        var switchPreparation = providerSwitchPreparation
        if liveSession.pendingHandoff.providerSwitchDelivery != nil, switchPreparation == nil {
            let input = liveSession.isCodexComputerUseArmed
                ? CodexComputerUseWorkflow.renderProviderPrompt(userInstructions: providerMessage) : providerMessage
            switch await providerSwitchSendAdmission(session: liveSession, input: input, isCurrent: {
                stopFence.permitsStart(of: liveSession) && self.composerSubmitClaimIsCurrent(claim) && dispatchIsCurrent()
            }) {
            case let .failure(failure):
                releaseComposerSubmitClaim(claim)
                return .blocked(failure)
            case let .success(preparation): switchPreparation = preparation
            }
        }
        if let switchPreparation, !providerSwitchPreparationIsCurrent(switchPreparation, session: liveSession) {
            releaseComposerSubmitClaim(claim)
            return .blocked(.providerHandoverNeedsReview)
        }
        liveSession.noteAcceptedTaskInput()
        // 6. Durable acceptance. The bubble keeps raw words; the exact provider payload is metadata.
        let userItem = AgentChatItem.user(
            displayText,
            sequenceIndex: liveSession.nextSequenceIndex,
            // Badges the one-shot workflow the sender attached to *this* message through the row's
            // existing metadata, so the standard pill renders beside the attribution badge with no
            // new UI. It records what this turn ran under; it is not, and never becomes, the
            // target's composer selection.
            workflow: workflow,
            crossSessionAttribution: attribution
        )
        let anchorRollback = recordAgentTurnUserAnchor(for: liveSession, userItem: userItem)
        switchPreparation = switchPreparation?.accepting(userItem.id, session: liveSession)
        liveSession.appendItem(userItem)
        updateBindingsFromSession(liveSession)
        requestUIRefresh(tabID: tabID, urgent: true)

        if case .failure = await flushSaveRequired(for: tabID, workspaceID: workspaceID) {
            rollbackNoncomposerStagedRow(
                itemID: userItem.id,
                tabID: tabID,
                session: liveSession,
                anchorRollback: anchorRollback
            )
            // A failed flush may already have written the row, so "nothing was delivered" is only
            // true once the compensating removal is itself durable. Confirm it synchronously here
            // rather than leaving it to a scheduled save: releasing the idempotency key for a fresh
            // retry while a committed row might survive is exactly how one logical send becomes two
            // transcript rows.
            if case .failure = await flushSaveRequired(for: tabID, workspaceID: workspaceID) {
                releaseComposerSubmitClaim(claim)
                return .blocked(.persistenceIndeterminate)
            }
            releaseComposerSubmitClaim(claim)
            return .blocked(.persistenceFailed)
        }

        return await startPersistedNoncomposerTurn(
            session: liveSession, tabID: tabID, claim: claim, savedItemID: userItem.id,
            acceptedAt: Date(), providerMessage: providerMessage, stopFence: stopFence,
            providerSwitchPreparation: switchPreparation,
            dispatchIsCurrent: dispatchIsCurrent
        )
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
        let persistedOnly = AgentSessionLinkSendDelivery(
            targetItemID: savedItemID,
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
        guard liveSession.permitsBoundOperationAndSave,
              providerSwitchPreparation.map({ providerSwitchPreparationIsCurrent($0, session: liveSession) })
              ?? (liveSession.pendingHandoff.providerSwitchDelivery == nil),
              dispatchIsCurrent()
        else {
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
        //    `.crossSessionDelivery` leaves legacy staged handoffs for the next local input;
        //    an admitted provider-switch carrier instead accompanies this attributed input.
        //    Nothing focuses, activates, or switches the target window.
        // Local arming authorizes this tab's turns, including attributed remote input.
        let dispatchedProviderMessage = providerSwitchPreparation?.augmentedInput
            ?? (
                liveSession.isCodexComputerUseArmed
                    ? CodexComputerUseWorkflow.renderProviderPrompt(userInstructions: providerMessage)
                    : providerMessage
            )
        // The row was durable before dispatch. Mark the exact provider text only after the final
        // dispatch admission, so a persisted-only row cannot masquerade as an interrupted prompt.
        if let index = liveSession.items.firstIndex(where: { $0.id == savedItemID }) {
            var dispatchedRow = liveSession.items[index]
            dispatchedRow.dispatchedProviderText = dispatchedProviderMessage
            liveSession.replaceItem(at: index, with: dispatchedRow)
            scheduleSave(for: tabID)
        }
        // The run service's `nil` return is "not a Codex native send", not "started", so the
        // recorder is what distinguishes a Claude/ACP/headless pre-start failure from success.
        let startRecorder = AgentRunStartOutcomeRecorder()
        _ = await startAgentRun(
            tabID: tabID,
            initialMessage: dispatchedProviderMessage,
            directStartOptions: AgentDirectRunStartOptions(
                ignoresPendingHandoff: true, stopFence: stopFence
            ),
            startOutcome: startRecorder,
            providerSwitchPreparation: providerSwitchPreparation
        )
        releaseComposerSubmitClaim(claim)
        if startRecorder.outcome.didStart {
            agentSessionLinkClearWaitingOnAfterAcceptedTurn(liveSession)
        } else if let index = liveSession.items.firstIndex(where: { $0.id == savedItemID }) {
            var undispatchedRow = liveSession.items[index]
            undispatchedRow.dispatchedProviderText = nil
            liveSession.replaceItem(at: index, with: undispatchedRow)
            scheduleSave(for: tabID)
        }

        let resultingRunState = sessions[tabID]?.runState ?? liveSession.runState
        return .delivered(AgentSessionLinkSendDelivery(
            targetItemID: savedItemID,
            acceptedAt: acceptedAt,
            deliveryState: startRecorder.outcome.didStart ? .runStarted : .runStartFailed,
            resultingRunState: resultingRunState.rawValue
        ))
    }

    /// The live session for an endpoint, or `nil` unless every identity field still matches
    /// byte-for-byte and generation-for-generation.
    func agentSessionLinkLiveSession(
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
    private func rollbackNoncomposerStagedRow(
        itemID: UUID,
        tabID: UUID,
        session: TabSession,
        anchorRollback: AgentTurnUserAnchorRollbackState
    ) {
        if let index = session.items.firstIndex(where: { $0.id == itemID }) {
            _ = session.removeItem(at: index)
        }
        // The accepting() proof pointed at the removed row; a .ready handover must not keep it,
        // because the proof also participates in pendingHandoff equality and ownership checks.
        if session.pendingHandoff.providerSwitchDelivery == .ready {
            session.pendingHandoff.providerSwitchDispatch = nil
        }
        rollbackAgentTurnUserAnchor(anchorRollback, session: session)
        updateBindingsFromSession(session)
        requestUIRefresh(tabID: tabID, urgent: true)
        scheduleSave(for: tabID)
    }
}

/// Parse persisted M1 as data, never instructions. No external entity/network resolution.
final class ProviderSwitchCarrierDescriptor: NSObject, XMLParserDelegate {
    struct Marker {
        let attributes: [String: String]
        var text: String
    }

    private(set) var mode = ""
    private(set) var sourceProvider = ""
    private(set) var sourceModel = ""
    private(set) var readableMarkers: [Marker] = []
    private(set) var omissions: [String] = []
    private var depth = 0
    private var markerDepth: Int?
    private var validRoot = false

    init?(_ payload: String) {
        super.init()
        guard payload.utf8.count <= AgentProviderHandover.maximumBytes,
              !payload.contains("<!DOCTYPE"), !payload.contains("<!ENTITY") else { return nil }
        let parser = XMLParser(data: Data(payload.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse(), validRoot else { return nil }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        if depth == 1 {
            mode = attributes["mode"] ?? ""
            sourceProvider = attributes["source_provider"] ?? ""
            sourceModel = attributes["source_model"] ?? ""
            validRoot = elementName == "repoprompt_provider_handover" && attributes["version"] == "1"
                && ["history", "newest_turns", "summary"].contains(mode)
                && (try? AgentProviderHandover.Source(provider: sourceProvider, model: sourceModel)) != nil
        }
        if elementName == "omitted" {
            switch attributes["kind"] {
            case "older_turns":
                guard let first = Int(attributes["first"] ?? ""), let last = Int(attributes["last"] ?? ""), first >= 0, last >= first else {
                    parser.abortParsing()
                    return
                }
                let (difference, differenceOverflow) = last.subtractingReportingOverflow(first)
                let (count, countOverflow) = difference.addingReportingOverflow(1)
                guard !differenceOverflow, !countOverflow, count > 0 else {
                    parser.abortParsing()
                    return
                }
                omissions.append("\(count) older turns")
            case "tool_output": omissions.append("tool outputs")
            case "image": omissions.append("images")
            default: break
            }
        }
        if elementName == "omitted", attributes["availability"] == "readable" {
            readableMarkers.append(.init(attributes: attributes, text: ""))
            markerDepth = depth
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if markerDepth != nil, !readableMarkers.isEmpty { readableMarkers[readableMarkers.count - 1].text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if markerDepth == depth { markerDepth = nil }
        depth -= 1
    }
}
