import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptSettingsCore

/// The existing attributed-send transaction and provider-switch acceptance, owned by the runtime.
@MainActor
extension AgentSessionLinkExecutionRuntime {
    typealias PendingHandoffState = AgentPendingHandoffState
    typealias ProviderSwitchAdmissionEvidence = AgentProviderSwitchAdmissionEvidence

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
        guard let owner = scope, !owner.hasReleasedWriterClaims else { return .failure(.targetStopped) }
        defer { withExtendedLifetime(owner) {} }
        guard commands.isAvailable(), owner.sessions[session.tabID] === session else { return .failure(.targetStopped) }
        guard let delivery = session.pendingHandoff.providerSwitchDelivery else { return .success(nil) }
        guard delivery == .ready else {
            guard Self.providerSwitchHasOwnedCarryingAttempt(session) else { return .failure(.providerSwitchUnconfirmed) }
            return .failure(Self.providerSwitchNeedsReview(session) ? .providerHandoverNeedsReview : .targetNotIdle)
        }
        guard !Self.providerSwitchNeedsReview(session) else { return .failure(.providerHandoverNeedsReview) }
        guard !session.runState.isActive, session.activeRunOwnership == nil else { return .failure(.targetNotIdle) }
        guard let command = try? owner.admit(session: session) else { return .failure(.targetStopped) }
        let resourceWorkspaceID = commands.workspaceID(session)
        guard resourceWorkspaceID == nil || resourceWorkspaceID == command.identity.workspaceID else { return .failure(.targetStopped) }
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
        var inputSources: [AgentSessionProviderInputRuntime.WorkspaceSource] = []
        func inputIsCurrent() -> Bool {
            command.isCurrent && commands.isAvailable() && isCurrent() && !Task.isCancelled
                && commands.workspaceID(session) == resourceWorkspaceID && stopFence.permitsStart(of: session)
                && inputSources.allSatisfy { $0.isCurrent() }
        }
        guard inputIsCurrent() else { return .failure(.targetStopped) }
        var taggedFileFailures: [AgentSessionProviderInputRuntime.ExplicitFileFailure] = []
        let augmented: String
        let initial: String
        do {
            augmented = skipsAugmentation ? input : try await commands.input.augmentUserMessage(
                input, attachments: attachments, taggedFileAttachments: taggedFiles, agent: agent,
                workspacePaths: commands.workspacePaths(), workspace: {
                    let source = try await commands.inputWorkspace(session, command)
                    if let source { inputSources.append(source) }
                    return source
                },
                session: session, handoff: owner.handoff, ignoresPendingHandoff: true,
                skipsSlashExpansion: skipsSlashExpansion, isCurrent: inputIsCurrent,
                onTaggedFileFailures: { taggedFileFailures = $0 }
            )
            guard inputIsCurrent() else { return .failure(.targetStopped) }
            initial = try await commands.input.buildInitialThreadMessageIfNeeded(
                session: session, initialMessage: augmented,
                input: {
                    let input = try await commands.initialThreadInput(session, command)
                    if let input { inputSources.append(input.workspace) }
                    return input
                }, isCurrent: inputIsCurrent
            )
        } catch { return .failure(.targetStopped) }
        for source in inputSources {
            guard inputIsCurrent(), await source.validate(), inputIsCurrent() else { return .failure(.targetStopped) }
        }
        guard inputIsCurrent() else { return .failure(.targetStopped) }
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
            command: command, binding: binding, handoff: handoff, agent: agent, model: model, rawInput: input,
            augmentedInput: augmented, initialThreadInput: initial, instructions: instructions,
            inputAlreadyIncludesSupplement: inputAlreadyIncludesSupplement,
            historyToolAllowed: historyAllowed, computerUseArmed: computerUseArmed,
            catalogWindow: catalogWindow, composerAttemptID: composerAttemptID, autoWakeID: autoWakeID, stopFence: stopFence,
            taggedFileFailures: taggedFileFailures, inputSources: inputSources
        ))
    }

    func providerSwitchCatalogWindow(agent: AgentProviderKind, model: String) -> Int? {
        if agent.usesClaudeNativeRuntime {
            return ClaudeCompatibleModelCatalogAdapter.contextWindowTokens(forRequestedModelRaw: model, agentKind: agent)
                ?? AgentModel.resolvedModel(forRaw: model, agentKind: agent)?.contextWindowTokens
        }
        return AgentModel.resolvedModel(forRaw: model, agentKind: agent)?.contextWindowTokens
    }

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

    func prepareProviderSwitchHandoverForSend(
        _ preparation: ProviderSwitchSendPreparation?, session: TabSession,
        stopFence: AgentRunStartStopFence
    ) async -> (user: String, initial: String)? {
        guard let owner = scope, !owner.hasReleasedWriterClaims else { return nil }
        defer { withExtendedLifetime(owner) {} }
        guard let preparation else { return nil }
        guard providerSwitchPreparationIsCurrent(preparation, session: session),
              await preparation.validateInputSources(), providerSwitchPreparationIsCurrent(preparation, session: session),
              stopFence.permitsStart(of: session),
              let payload = preparation.handoff.payload
        else { return nil }
        let writer = preparation.command.writer
        session.pendingHandoff.providerSwitchDelivery = .sending
        session.pendingHandoff.isStagedForSend = true
        session.pendingHandoff.providerSwitchDispatch = preparation.physicalDispatch
        let sending = session.pendingHandoff
        session.isDirty = true
        var sendingSaverReturned = false
        let sendingSave = await flushSaveRequired(writer: writer, observingSavePhase: {
            if case .writeReturned = $0 { sendingSaverReturned = true }
        })
        guard case .success = sendingSave else {
            if sendingSaverReturned, writer.isCurrent, sessions[session.tabID] === session,
               session.currentRestorationBindingToken == preparation.binding, session.pendingHandoff == sending
            {
                // This runtime has not released input to a runner. A known returned write may re-save
                // ready, but never authorizes dispatch or replay of the accepted input.
                await providerSwitchRestoreReadyBeforeDispatch(writer: writer, sending: sending)
            }
            // Unknown writes or loss of writer currency remain inert sending. Equality includes
            // the originating writer incarnation, so this only releases our transient proof.
            if sessions[session.tabID] === session, session.currentRestorationBindingToken == preparation.binding,
               session.pendingHandoff == sending
            {
                session.pendingHandoff.isStagedForSend = false
                session.pendingHandoff.providerSwitchDispatch = nil
            }
            return nil
        }
        guard writer.isCurrent, session.pendingHandoff == sending else {
            // The transient proof belongs to this exact request, including its writer incarnation.
            // Release only that proof, never a successor's proof or the durable sending uncertainty.
            if sessions[session.tabID] === session, session.currentRestorationBindingToken == preparation.binding,
               session.pendingHandoff == sending
            {
                session.pendingHandoff.isStagedForSend = false
                session.pendingHandoff.providerSwitchDispatch = nil
            }
            return nil
        }
        guard preparation.command.isCurrent, await preparation.validateInputSources(),
              preparation.command.isCurrent, session.pendingHandoff == sending,
              !Task.isCancelled, stopFence.permitsStart(of: session),
              !session.runState.isActive, session.activeRunOwnership == nil,
              session.selectedAgent == preparation.agent, session.selectedModelRaw == preparation.model,
              session.isCodexComputerUseArmed == preparation.computerUseArmed,
              providerSwitchCatalogWindow(agent: preparation.agent, model: preparation.model) == preparation.catalogWindow,
              providerSwitchHistoryToolAllowed(session) == preparation.historyToolAllowed,
              providerSwitchInstructionStrings(session, includeSupplement: !preparation.inputAlreadyIncludesSupplement) == preparation.instructions
        else {
            // Only this runtime path proves the runner has not been invoked. An unacknowledged ready
            // re-save restores sending; controller-specific failures never enter this path.
            await providerSwitchRestoreReadyBeforeDispatch(writer: writer, sending: sending)
            return nil
        }
        return (payload + "\n\n" + preparation.augmentedInput, payload + "\n\n" + preparation.initialThreadInput)
    }

    func providerSwitchPreparationIsCurrent(_ preparation: ProviderSwitchSendPreparation, session: TabSession) -> Bool {
        preparation.command.isCurrent && preparation.command.writer.scope === scope
            && preparation.inputSources.allSatisfy { $0.isCurrent() }
            && preparation.command.writer.session === session
            && commands.isAvailable() && sessions[session.tabID] === session && session.currentRestorationBindingToken == preparation.binding
            && session.selectedAgent == preparation.agent && session.selectedModelRaw == preparation.model
            && !session.runState.isActive && session.activeRunOwnership == nil
            && session.pendingHandoff == preparation.handoff
            && providerSwitchCatalogWindow(agent: preparation.agent, model: preparation.model) == preparation.catalogWindow
            && providerSwitchHistoryToolAllowed(session) == preparation.historyToolAllowed
            && session.isCodexComputerUseArmed == preparation.computerUseArmed
            && !Self.providerSwitchNeedsReview(session, excluding: preparation.acceptedInputID)
            && providerSwitchInstructionStrings(session, includeSupplement: !preparation.inputAlreadyIncludesSupplement) == preparation.instructions
    }

    private func providerSwitchRestoreReadyBeforeDispatch(
        writer: AgentSessionRuntimeStore.Writer, sending: PendingHandoffState
    ) async {
        guard writer.scope === scope, writer.isCurrent else { return }
        let session = writer.session
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
        let readySave = await flushSaveRequired(writer: writer, observingSavePhase: {
            if case .writeReturned = $0 { readySaverReturned = true }
        })
        if case .failure = readySave, writer.isCurrent,
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

    /// The physical proof carries an incarnation, not just a binding token. Resolving it may
    /// recover the originating writer during retirement, but may never adopt a replacement claim.
    private func providerSwitchWriter(
        for session: TabSession, proof: AgentProviderSwitchPhysicalDispatch
    ) -> AgentSessionRuntimeStore.Writer? {
        guard let scope, let sessionID = session.activeAgentSessionID,
              case let .unique(writer) = scope.resolveWriter(
                  sessionID: sessionID, expectedWorkspaceID: proof.admission.writerIdentity.workspaceID
              ),
              writer.scope === scope, writer.session === session,
              writer.identity == proof.admission.writerIdentity, writer.isCurrent else { return nil }
        return writer
    }

    func providerSwitchAcquirePhysicalDispatch(session: TabSession, dispatchID: AgentSessionLinkPromptDispatchID) -> Bool {
        guard session.pendingHandoff.providerSwitchDelivery != nil else { return true }
        guard session.pendingHandoff.providerSwitchDelivery == .sending,
              session.pendingHandoff.isStagedForSend else { return false }
        let effectiveID = agentSessionLinkEffectiveDispatchID(for: session, dispatchID: dispatchID)
        guard let staged = session.pendingHandoff.providerSwitchDispatch,
              let writer = providerSwitchWriter(for: session, proof: staged),
              case .success = writer.admitCommand(),
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

    func providerSwitchRecordPhysicalAcceptance(session: TabSession, context: AgentSessionLinkDispatchContext?) {
        guard let owner = scope, owner.sessions[session.tabID] === session,
              let context, session.pendingHandoff.providerSwitchDelivery == .sending,
              session.pendingHandoff.isStagedForSend,
              let staged = session.pendingHandoff.providerSwitchDispatch,
              staged.dispatchID == context.dispatchID, staged.binding == session.currentRestorationBindingToken,
              let writer = providerSwitchWriter(for: session, proof: staged) else { return }
        // Physical acceptance acknowledges an already-dispatched effect. Retirement blocks a new
        // dispatch, not this originating acknowledgement or its final durable clear.
        let sending = session.pendingHandoff
        let binding = session.currentRestorationBindingToken
        session.pendingHandoff.clearAfterSend()
        let cleared = session.pendingHandoff
        let model = commands.modelDisplayName(session)
        let text = "Handover sent to \(session.selectedAgent.displayName) / \(model)."
        session.appendItem(.system(text, sequenceIndex: session.nextSequenceIndex, recoveryDiagnostic: .init(
            reason: "providerSwitch", outcome: "sent", text: text
        )))
        session.isDirty = true
        let effectID = UUID()
        let task = Task { @MainActor [self, session, writer] in
            defer {
                pendingSendEffects.removeValue(forKey: effectID)
                writer.scope.noteSettlementChanged()
            }
            // Admission and the scheduled write are separate actor turns. Do not let a replaced
            // claim persist this acknowledgement through the successor's tab slot.
            guard writer.isCurrent else { return }
            // A returned frozen clear must survive later save-token drift. The ordinary fresh-save
            // owner carries it forward; only an unacknowledged write restores uncertainty.
            var saverReturned = false
            let result = await flushSaveRequired(writer: writer, observingSavePhase: {
                if case .writeReturned = $0 { saverReturned = true }
            })
            if case .failure = result, !saverReturned, writer.isCurrent,
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
        pendingSendEffects[effectID] = PendingSendEffect(sessionIdentity: ObjectIdentifier(session), task: task)
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

    func agentSessionLinkPerformSend(
        to candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkSendRequest,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        commitAuthorization: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkSendTransactionOutcome {
        guard let owner = scope, !owner.hasReleasedWriterClaims, !owner.isRetiring else { return .blocked(.endpointSession) }
        defer { withExtendedLifetime(owner) {} }
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

        guard let command = admit(candidate) else { return .blocked(.endpointSession) }
        defer { withExtendedLifetime(command) {} }
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
            command.isCurrent && stopFence.permitsStart(of: session) && liveness().permitsDelivery
        }) { return .blocked(failure) }

        // 3. Local composer claim. Losing it means a local user Send won the race, which is exactly
        //    `target_not_idle` — the observer polls and retries rather than queueing behind the user.
        guard let claim = claimEmptyComposer(for: candidate, session: session) else {
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
            command.isCurrent && stopFence.permitsStart(of: session) && liveness().permitsDelivery && self.composerSubmitClaimIsCurrent(claim)
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
        guard command.isCurrent, let liveSession = agentSessionLinkLiveSession(matching: candidate) else {
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
        let workspaceID = command.identity.workspaceID

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
                  self.commands.workspaceID(liveSession) == candidate.workspaceID
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
        guard let owner = scope, !owner.hasReleasedWriterClaims, !owner.isRetiring else {
            releaseComposerSubmitClaim(claim)
            return .blocked(.endpointSession)
        }
        defer { withExtendedLifetime(owner) {} }
        guard commands.isAvailable(), owner.sessions[tabID] === liveSession,
              liveSession.tabID == tabID
        else {
            releaseComposerSubmitClaim(claim)
            return .blocked(.endpointSession)
        }
        // Every noncomposer caller shares this pre-row fence. A completed but failed restoration
        // must never become a replacement transcript merely because it reached an idle runtime.
        guard liveSession.permitsBoundOperationAndSave else {
            releaseComposerSubmitClaim(claim)
            let reason = AgentSessionLinkDeliveryReadiness.restorationBlockReason(liveSession.qualifiedRestorationReadiness)
            return .blocked(AgentSessionLinkSendFailure(reason ?? .targetLoading))
        }
        guard let command = try? owner.admit(session: liveSession, expectedWorkspaceID: workspaceID) else {
            releaseComposerSubmitClaim(claim)
            return .blocked(.endpointSession)
        }
        defer { withExtendedLifetime(command) {} }
        let writer = command.writer
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
        guard command.isCurrent else {
            releaseComposerSubmitClaim(claim)
            return .blocked(.endpointPostSession)
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
        let anchorRollback = owner.turnTiming.recordAgentTurnUserAnchor(for: liveSession, userItem: userItem)
        switchPreparation = switchPreparation?.accepting(userItem.id, session: liveSession)
        liveSession.appendItem(userItem)
        updateBindingsFromSession(liveSession)
        requestUIRefresh(tabID: tabID, urgent: true)

        if case .failure = await flushSaveRequired(writer: writer) {
            // The saver may have returned for the originating payload after this object was rebound.
            // A stale writer may neither acknowledge that write nor compensate against its successor.
            guard writer.isCurrent else {
                releaseComposerSubmitClaim(claim)
                return .blocked(.persistenceIndeterminate)
            }
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
            if case .failure = await flushSaveRequired(writer: writer) {
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
        guard let owner = scope, !owner.hasReleasedWriterClaims, !owner.isRetiring,
              owner.sessions[tabID] === liveSession, commands.isAvailable()
        else {
            releaseComposerSubmitClaim(claim)
            return .delivered(persistedOnly)
        }
        defer { withExtendedLifetime(owner) {} }
        if Task.isCancelled {
            releaseComposerSubmitClaim(claim)
            return .delivered(persistedOnly)
        }

        // The flush awaited, so every admission fact must be re-proven before a provider is started.
        // A window teardown, an observer rebind/close, an in-place rebind that keeps the same session
        // UUID, a workspace switch, a lost composer claim, or a locally started run during that await
        // would otherwise let a tab-resolved start dispatch this turn against whatever now occupies
        // the tab — possibly a replacement binding the grant never covered.
        //
        // The probe is deliberately endpoint/window liveness only and never link liveness: manual
        // revocation is *intended* to lose once the commit fence has been won.
        //
        // Drift retains the durable delivery and withholds only the provider start: the row is
        // already the target's, so rolling it back here would contradict the linearization point and
        // make the same key deliverable twice.
        guard let command = claim.command,
              command.writer.session === liveSession,
              command.isCurrent,
              composerSubmitClaimIsCurrent(claim),
              liveSession.permitsBoundOperationAndSave,
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
            command: command,
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

    func agentSessionLinkLiveSession(
        matching candidate: AgentSessionLinkEndpointCandidate
    ) -> TabSession? {
        guard let scope,
              case let .unique(writer) = scope.resolveWriter(sessionID: candidate.sessionID, expectedWorkspaceID: candidate.workspaceID),
              writer.scope === scope, writer.session.tabID == candidate.tabID,
              let session = sessions[candidate.tabID], writer.session === session,
              let identity = agentSessionLinkObserverEndpoint(tabID: candidate.tabID),
              identity == candidate.domainEndpoint
        else {
            return nil
        }
        return session
    }

    static func providerSwitchStartRefusal(_ session: TabSession) -> AgentSessionLinkSendFailure {
        session.pendingHandoff.providerSwitchDelivery == .ready ? .providerHandoverNeedsReview : .providerSwitchUnconfirmed
    }

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
        scope?.turnTiming.rollbackAgentTurnUserAnchor(anchorRollback, session: session)
        updateBindingsFromSession(session)
        requestUIRefresh(tabID: tabID, urgent: true)
        scheduleSave(for: tabID)
    }

    func updateBindingsFromSession(_ session: AgentTabSession) {
        scope?.presentation.bindingChanged(session)
    }

    func flushSaveRequired(writer: AgentSessionRuntimeStore.Writer, observingSavePhase: ((AgentSessionRequiredSavePhase) -> Void)? = nil) async -> Result<Void, AgentSessionPersistenceFailure> {
        let tabID = writer.binding.tabID
        guard let owner = scope, writer.scope === owner else {
            return .failure(.init(operation: .save, tabID: tabID, message: "The originating runtime owner is unavailable."))
        }
        return await owner.persistence.flushSaveRequired(
            writer: writer,
            observingSavePhase: observingSavePhase
        )
    }

    func drainPendingSendEffects(for session: AgentTabSession? = nil) async {
        let identity = session.map(ObjectIdentifier.init)
        while true {
            let pending = pendingSendEffects.values.filter { identity == nil || $0.sessionIdentity == identity }
            guard !pending.isEmpty else { return }
            for effect in pending {
                await effect.task.value
            }
        }
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
