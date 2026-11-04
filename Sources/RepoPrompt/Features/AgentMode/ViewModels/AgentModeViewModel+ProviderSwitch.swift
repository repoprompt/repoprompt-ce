import CryptoKit
import Foundation
import RepoPromptDomainRuntime
import RepoPromptSettingsCore

extension AgentModeViewModel {
    /// Request-local composition evidence, not a persisted preview or a second admission owner.
    struct ProviderSwitchSendPreparation {
        let binding: AgentSessionRestorationBindingToken?
        private(set) var handoff: PendingHandoffState
        let agent: AgentProviderKind
        let model: String
        let rawInput: String
        let augmentedInput: String
        let initialThreadInput: String
        let instructions: [String]
        let inputAlreadyIncludesSupplement: Bool
        let historyToolAllowed: Bool
        let computerUseArmed: Bool
        let catalogWindow: Int?
        let composerAttemptID: UUID?
        let autoWakeID: UUID?
        let stopFence: AgentRunStartStopFence
        var acceptedInputID: UUID?

        @MainActor
        func accepting(_ itemID: UUID, session: TabSession) -> Self {
            var copy = self
            copy.acceptedInputID = itemID
            if session.currentRestorationBindingToken == binding, session.pendingHandoff == handoff {
                copy.handoff.providerSwitchDispatch = copy.physicalDispatch
                session.pendingHandoff.providerSwitchDispatch = copy.handoff.providerSwitchDispatch
            }
            return copy
        }

        var physicalDispatch: ProviderSwitchPhysicalDispatch {
            .init(
                dispatchID: nil,
                binding: binding,
                admission: .init(self),
                acceptedInputID: acceptedInputID,
                composerAttemptID: composerAttemptID,
                autoWakeID: autoWakeID,
                stopFence: stopFence,
                runOwnership: nil,
                runID: nil
            )
        }
    }

    struct ProviderSwitchAdmissionEvidence: Equatable {
        let agent: AgentProviderKind
        let model: String
        let catalogWindow: Int?
        let computerUseArmed: Bool
        let historyToolAllowed: Bool
        let inputAlreadyIncludesSupplement: Bool
        let instructionsDigest: SHA256.Digest

        init(_ preparation: ProviderSwitchSendPreparation) {
            agent = preparation.agent
            model = preparation.model
            catalogWindow = preparation.catalogWindow
            computerUseArmed = preparation.computerUseArmed
            historyToolAllowed = preparation.historyToolAllowed
            inputAlreadyIncludesSupplement = preparation.inputAlreadyIncludesSupplement
            instructionsDigest = Self.digest(preparation.instructions)
        }

        static func digest(_ strings: [String]) -> SHA256.Digest {
            var hash = SHA256()
            for string in strings {
                hash.update(data: Data("\(string.utf8.count):".utf8))
                hash.update(data: Data(string.utf8))
            }
            return hash.finalize()
        }
    }

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

    /// Summary provenance excludes host-owned one-shot delivery content, not stable instructions
    /// or monitor authority. Full actual instructions still own every preview currency/fit check.
    private func providerSwitchInstructionProvenance(_ session: TabSession, destination: AgentProviderKind) -> [String] {
        providerSwitchInstructionStrings(session, destination: destination, includeOwedContent: false)
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

    /// Switch admission separates hard blockers (integrity or a real pending handover) from
    /// forceable causes (the source session's own live state, which a confirmed Stop may end).
    /// Derived from existing state only; nothing here is persisted.
    enum ProviderSwitchAdmission: Equatable {
        enum ForceableCause: Equatable {
            case running
            case waitingForInput
            case compaction
            case finishingTurn
            case sessionTransfer
            case stopping
            case workInFlight

            func message(provider: String) -> String {
                switch self {
                case .running: "\(provider) is still working on its last turn."
                case .waitingForInput: "\(provider) is waiting for your input."
                case .compaction: "\(provider) is still finishing a compaction."
                case .finishingTurn: "\(provider) is still finishing its last turn."
                case .sessionTransfer: "\(provider) is still finishing a session transfer."
                case .stopping: "\(provider) is stopping."
                case .workInFlight: "\(provider) still has work in flight."
                }
            }
        }

        case clear
        case hard(String)
        case forceable(ForceableCause)

        func message(provider: String) -> String? {
            switch self {
            case .clear: nil
            case let .hard(message): message
            case let .forceable(cause): cause.message(provider: provider)
            }
        }

        func isAdmissible(forcing: Bool) -> Bool {
            switch self {
            case .clear: true
            case .hard: false
            case .forceable: forcing
            }
        }
    }

    /// Item 3's transition admission reads existing owners, ignoring only its own exact
    /// claim/slot. Every integrity guard evaluates before any source live-state classification;
    /// `.forceable` means the local sheet may offer the confirmed stop-and-switch gesture.
    /// No saved idle bit, waiting worker, binding transition or provider action is introduced here.
    func providerSwitchTransitionAdmission(
        _ session: TabSession, ownsComposerClaim: Bool = false, resolvingHandoff: PendingHandoffState? = nil
    ) -> ProviderSwitchAdmission {
        // Every integrity guard is evaluated before any source-liveness classification, so a
        // force can never run its quiesce while a protected state holds.
        // A worktree relocation mutates bindings, not provider state; it stays uninterruptible.
        if session.pendingSelfWorktreeRelocation != nil {
            return .hard(SendBlocker.changingExecutionLocation.rawValue)
        }
        var snapshot = Self.agentSessionLinkDeliveryReadinessSnapshot(
            session: session, endpointMatchesGrant: sessions[session.tabID] === session, isClosing: false,
            ignoresComposerSubmissionInFlight: ownsComposerClaim
        )
        if let resolvingHandoff, session.pendingHandoff == resolvingHandoff {
            snapshot.providerSwitchUnconfirmed = false
            snapshot.providerHandoverNeedsReview = false
        }
        let evaluation = AgentSessionLinkDeliveryReadiness.evaluate(snapshot: snapshot)
        if case let .blocked(reason) = evaluation {
            switch reason {
            case .targetNotIdle:
                break
            case .providerSwitchUnconfirmed, .providerHandoverNeedsReview,
                 .endpointInvalidated, .targetLoading, .targetRestoreUnavailable,
                 .targetCreationIncomplete:
                return .hard(AgentSessionLinkSendFailure(reason).message)
            }
        }
        // An execution-location or initial-worktree mutation in flight stays hard like the
        // relocation gate above; it must precede every live-state classification.
        if snapshot.isChangingExecutionLocation || snapshot.isPreparingInitialWorktree {
            return .hard(AgentSessionLinkSendFailure.targetNotIdle.message)
        }
        if session.pendingHandoff.hasPayload, session.pendingHandoff.providerSwitchDelivery == nil,
           !providerSwitchCanReplaceResumeRecovery(session)
        {
            return .hard(AgentSessionLinkSendFailure.targetBusy.message)
        }
        // A latched compact failure is integrity state (a failed required save or an unconfirmed
        // delivery), not live work — it stays hard. Only a compact still in flight is forceable.
        if session.selfCompactState.latest?.outcome == .recoveryRequired
            || session.selfCompactState.latest?.outcome == .deliveryUnknown
            || session.selfCompactState.latest?.noteDelivery == .deliveryUnknown
        {
            return .hard(SendBlocker.pendingSelfCompact.rawValue)
        }
        if claudeCoordinator.hasPendingResumeTransfer(for: session) { return .forceable(.sessionTransfer) }
        if session.selfCompactState.active != nil { return .forceable(.compaction) }
        if case .blocked(.targetNotIdle) = evaluation {
            if snapshot.hasWaitingPrompt || snapshot.hasPendingAskUser || snapshot.hasPendingUserInputRequest
                || snapshot.hasPendingApproval || snapshot.hasPendingPermissionsRequest
                || snapshot.hasPendingMCPElicitationRequest || snapshot.hasPendingApplyEditsReview
                || snapshot.hasPendingWorktreeMergeReview
            {
                return .forceable(.waitingForInput)
            }
            if snapshot.stopInProgress { return .forceable(.stopping) }
            if snapshot.pendingSelfCompact || snapshot.backgroundCompactionSettling { return .forceable(.compaction) }
            if snapshot.terminalCommitInProgress { return .forceable(.finishingTurn) }
            if snapshot.runStateIsActive { return .forceable(.running) }
            return .forceable(.workInFlight)
        }
        if !providerSwitchTerminalIsSettled(session) { return .forceable(.finishingTurn) }
        return .clear
    }

    func providerSwitchTransitionBlocker(
        _ session: TabSession, ownsComposerClaim: Bool = false, resolvingHandoff: PendingHandoffState? = nil
    ) -> String? {
        switch providerSwitchTransitionAdmission(
            session, ownsComposerClaim: ownsComposerClaim, resolvingHandoff: resolvingHandoff
        ) {
        case .clear: nil
        case let .hard(message): message
        case let .forceable(cause): cause.message(provider: session.selectedAgent.displayName)
        }
    }

    /// Recognize only the existing app-authored recovery shape. Fork/unknown legacy slots remain
    /// protected. Item 3 may replace this slot through its ordinary claimed Review/apply transaction.
    func providerSwitchCanReplaceResumeRecovery(_ session: TabSession) -> Bool {
        guard session.pendingHandoff.providerSwitchDelivery == nil,
              !session.pendingHandoff.defersProviderLockUntilSend,
              let payload = session.pendingHandoff.payload else { return false }
        let lines = payload.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first.hasPrefix("<forked_session source=\""),
              first.contains("\" delivery_id=\""), first.hasSuffix("\">"), lines.count > 2,
              lines[1].hasPrefix("You are continuing a session that was restarted after a native resume failed for "),
              lines[1].hasSuffix(". Use the recovered transcript below, plus any preserved thread context, to continue seamlessly."),
              lines.last == "</forked_session>" else { return false }
        return true
    }

    /// Forced switch: decline pending interactions once, cancel an active self-compact, and stop
    /// the run through the ordinary local-Stop path. The wait is bounded by the managed-stop
    /// deadline; the stop itself keeps running in the background on timeout. Returns false when
    /// the source has not settled afterwards — a carrier rendered from it would repeat the stale
    /// in-flight-turn defect this path exists to prevent. A settled terminal state (.cancelled
    /// with publication finished, teardown still running detached) is safe to project.
    private func providerSwitchQuiesceSourceForForcedSwitch(_ session: TabSession) async -> Bool {
        providerSwitchDeclinePendingInteractions(for: session)
        agentSelfCompactCancelForAcceptedLocalInput(session)
        guard providerSwitchSourceRunIsLive(session) else {
            // Queued work with no live run gets the same claim-time withdrawal an explicit Stop
            // runs — without manufacturing a cancelled attempt the way cancelRun would on idle.
            prepareAgentRunCancellation(session: session, intent: .userStop, origin: .explicitStop)
            withdrawQueuedWorkForManagedStop(session: session)
            retireTimedOutManagedStopIfEligible(session)
            return providerSwitchSourceIsSettled(session)
        }
        // The switch destroys provider infrastructure next, so the stop awaits teardown.
        #if DEBUG
            let forceStopHook = test_providerSwitchForceStop
        #endif
        _ = await providerSwitchAwaitManagedStopDeadline {
            #if DEBUG
                if let hook = forceStopHook {
                    await hook(session)
                    return
                }
            #endif
            await self.cancelAgentRun(tabID: session.tabID, completion: .terminalTeardownCompleted)
        }
        return providerSwitchSourceIsSettled(session)
    }

    private func providerSwitchSourceRunIsLive(_ session: TabSession) -> Bool {
        session.runState.isActive || session.agentTask != nil || session.runState.isTerminalForCommit
    }

    /// Whether the source transcript is safe to project: no live run, no agent task, and no
    /// terminal commit still publishing. `isTerminalForCommit` alone is not unsettled — a fully
    /// committed .cancelled run must not count as live forever.
    private func providerSwitchSourceIsSettled(_ session: TabSession) -> Bool {
        !session.runState.isActive && session.agentTask == nil && !session.terminalCommitInProgress && session.activeRunOwnership == nil
    }

    enum ProviderSwitchDeadline: Hashable {
        case forcedStop, retirementTail, idleProbe, previewAugmentation
    }

    /// Returns the work's result, or nil when its bounded wait expires. The worker is not
    /// cancelled: captured-runtime cleanup can finish detached, while callers fence late writes.
    /// Only the cancellable stream read and deadline sleep belong to the racing task group.
    private func providerSwitchAwaitDeadline<Value: Sendable>(
        _ kind: ProviderSwitchDeadline, work: @escaping @MainActor () async -> Value
    ) async -> Value? {
        let (stream, continuation) = AsyncStream<Value>.makeStream()
        Task { @MainActor in
            await continuation.yield(work())
            continuation.finish()
        }
        var seconds = AgentRunStopState.managedStopDeadlineSeconds
        #if DEBUG
            if kind == .forcedStop || kind == .retirementTail {
                seconds = test_providerSwitchStopDeadlineSeconds
            }
            let gate = test_providerSwitchDeadlineGates[kind]
        #endif
        let deadlineSeconds = seconds
        let result = await withTaskGroup(of: Value?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                #if DEBUG
                    if let gate {
                        await gate()
                        return nil
                    }
                #endif
                try? await Task.sleep(nanoseconds: UInt64(deadlineSeconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        continuation.finish()
        return result
    }

    private func providerSwitchAwaitManagedStopDeadline(_ work: @escaping @MainActor () async -> Void) async -> Bool {
        await providerSwitchAwaitDeadline(.forcedStop) { await work()
            return true
        } ?? false
    }

    private func providerSwitchRequireIdle(_ session: TabSession) async -> String? {
        let result: String?? = await providerSwitchAwaitDeadline(.idleProbe) {
            do {
                #if DEBUG
                    if let hook = self.test_providerSwitchIdleProbe {
                        try await hook(session)
                        return nil as String?
                    }
                #endif
                try await self.requireIdleProviderForWorktreeBindingTransition(session)
                return nil as String?
            } catch { return error.localizedDescription }
        }
        switch result {
        case let .some(reason): return reason
        case .none: return AgentSessionLinkSendFailure.targetNotIdle.message
        }
    }

    private func providerSwitchHistoryToolAllowed(_ session: TabSession, destination: AgentProviderKind? = nil) -> Bool {
        guard AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(toolName: "history", taskLabelKind: session.mcpControlContext?.taskLabelKind) else { return false }
        if (destination ?? session.selectedAgent).usesClaudeNativeRuntime {
            return !MCPIntegrationHelper.claudeDisallowedTools(for: .agentRun).contains("mcp__\(MCPIntegrationHelper.repoPromptMCPServerName)__history")
        }
        return true
    }

    private func providerSwitchReadReferenceIsCurrent(_ descriptor: ProviderSwitchCarrierDescriptor, session: TabSession, destination: AgentProviderKind? = nil) -> Bool {
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
}

extension AgentModeViewModel {
    struct ProviderSwitchChoice {
        let mode: AgentProviderHandover.Mode
        var carrier: AgentProviderHandover.Carrier?
        var retainedPayload: String?
        var retainedOmissions: String?
        var unavailable: String?
        var hidden = false
        var bytes: Int {
            retainedPayload?.utf8.count ?? carrier?.utf8Bytes ?? 0
        }

        var label: String {
            switch mode { case .history: "Full history"
            case .newestTurns: "Recent turns"
            case .summary: "Summary" }
        }

        var omissions: String? {
            if retainedPayload != nil { return retainedOmissions }
            guard let carrier else { return nil }
            var parts: [String] = []
            if let range = carrier.omittedOlderTurns { parts.append("\(range.count) older turns") }
            if carrier.hasToolOutputOmission { parts.append("tool outputs") }
            if carrier.hasImageOmission { parts.append("images") }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
    }

    /// UI-only captured evidence. Neither its lifetime nor a completed projection authorizes a send.
    enum ProviderSwitchCursorParameterIntent {
        case select(ACPModelParameterSelection)
        case clear(ACPModelParameterIdentity)

        func applying(to selections: [ACPModelParameterSelection], model: String) -> [ACPModelParameterSelection]? {
            guard let parameters = ACPModelParameterResolver.parameterSet(providerID: .cursor, selectedModelRaw: model) else { return nil }
            switch self {
            case let .select(selection):
                guard selection.providerID == .cursor,
                      selection.identity.canonicalBaseModelRaw == ACPModelParameterIdentity.canonicalBaseModelRaw(model, providerID: .cursor),
                      let definition = parameters.definition(configID: selection.configID), definition.kind == selection.kind,
                      definition.choice(matching: selection.valueRaw) != nil else { return nil }
                return ACPModelParameterSelection.normalized(selections + [selection])
            case let .clear(identity):
                guard identity.providerID == .cursor,
                      identity.canonicalBaseModelRaw == ACPModelParameterIdentity.canonicalBaseModelRaw(model, providerID: .cursor),
                      parameters.definition(kind: identity.kind) != nil else { return nil }
                return selections.filter { $0.identity != identity }
            }
        }
    }

    struct ProviderSwitchComposition: Equatable {
        let draft: String
        let workflow: AgentWorkflowDefinition?
        let workflowRevision: UInt64
        let computerUseArmed: Bool
        let includesInterview: Bool
        let interviewPreference: Bool
        let includeCleanupGuidance: Bool
        let images: [AgentFileAttachment]
        let taggedFiles: [AgentTaggedFileAttachment]
    }

    private func providerSwitchComposition(_ session: TabSession, destination: AgentProviderKind) -> ProviderSwitchComposition {
        .init(
            draft: session.draftText.trimmingCharacters(in: .whitespacesAndNewlines),
            workflow: session.selectedWorkflow, workflowRevision: session.userWorkflowSelectionMutationGeneration,
            computerUseArmed: destination == .codexExec && session.isCodexComputerUseArmed,
            includesInterview: interviewFirst && (session.items.isEmpty || !session.items.contains(where: { $0.kind == .assistant })),
            interviewPreference: interviewFirst,
            includeCleanupGuidance: GlobalSettingsStore.shared.showBuiltInWorkflowCleanupGuidance(),
            images: session.pendingFileAttachments, taggedFiles: session.pendingTaggedFileAttachments
        )
    }

    struct ProviderSwitchGeneratedSummary {
        let text: String
        let sourceRevision: Int
        let cutoff: UUID?
        let sourceProvider: String
        let sourceModel: String
    }

    struct ProviderSwitchPreview: Identifiable {
        let id: UUID
        let session: TabSession
        let binding: AgentSessionRestorationBindingToken?
        let workspaceID: UUID?
        let stopFence: AgentRunStartStopFence
        let sourceAgent: AgentProviderKind
        let sourceModel: String
        let sourceReasoningEffort: String?
        let sourceClaudeEffort: String?
        let source: AgentProviderHandover.Source?
        let originalHandoff: PendingHandoffState
        fileprivate let originalDescriptor: ProviderSwitchCarrierDescriptor?
        let destination: AgentProviderKind
        let model: String
        let cursorParameterIntent: ProviderSwitchCursorParameterIntent?
        let sourceParameters: [ACPModelParameterSelection]
        let composition: ProviderSwitchComposition
        var sourceRevision: Int
        var draftRevision: UInt64
        var instructions: [String]
        let instructionProvenance: [String]
        var cutoff: UUID?
        var projection: AgentProviderHandover.Projection?
        var budget: AgentProviderHandover.Budget?
        var historyReference: AgentProviderHandover.HistoryReference?
        var generatedSummary: ProviderSwitchGeneratedSummary?
        var choices: [ProviderSwitchChoice] = []
        var selected: AgentProviderHandover.Mode?
        var explicitSelection: AgentProviderHandover.Mode?
        var wordLimit: Int?
        var building = true
        var updated = false
        var failure: String?
        var generationItemID: UUID?
        var generationFinished = false
        var isReview: Bool {
            originalHandoff.providerSwitchDelivery != nil
        }

        var chosen: ProviderSwitchChoice? {
            choices.first { $0.mode == selected }
        }
    }

    struct ProviderSwitchMutation {
        enum Phase { case preparing, detached, staged }
        let id: UUID
        let session: TabSession
        let preview: ProviderSwitchPreview
        let saveGenerationAtEntry: UInt64
        var phase: Phase = .preparing
        var allowsSave: Bool {
            phase == .staged
        }
    }

    struct ProviderSwitchBackgroundOutcome {
        let session: TabSession
        let binding: AgentSessionRestorationBindingToken?
    }

    func providerSwitchIsCompletingInBackground(_ session: TabSession) -> Bool {
        guard let mutation = providerSwitchMutation, mutation.session === session,
              mutation.phase != .preparing,
              session.currentRestorationBindingToken == mutation.preview.binding else { return false }
        return providerSwitchPreview?.id != mutation.preview.id
    }

    private func endProviderSwitchMutation(_ id: UUID) {
        guard let owned = providerSwitchMutation, owned.id == id else { return }
        providerSwitchMutation = nil
        if !owned.allowsSave, owned.session.saveRequestGeneration != owned.saveGenerationAtEntry,
           owned.session.isDirty, providerSwitchPreviewIdentityIsCurrent(owned.preview)
        {
            scheduleSave(for: owned.session)
        }
    }

    @MainActor
    struct ProviderSwitchRollback {
        let agent: AgentProviderKind
        let model: String
        let effort: String?
        let claudeEffort: String?
        let parameters: [ACPModelParameterSelection]
        let providerID: String?
        let cleanup: ProviderConversationCleanupHandle?
        let codexID: String?
        let rollout: String?
        let codexModel: String?
        let codexEffort: String?
        let computerUseActivation: CodexComputerUseActivation?
        let computerUseArming: UUID?
        let context: TabSession.ProviderSwitchContextSnapshot
        let handoff: PendingHandoffState

        init(_ session: TabSession) {
            agent = session.selectedAgent
            model = session.selectedModelRaw
            effort = session.selectedReasoningEffortRaw
            claudeEffort = session.selectedClaudeEffortRaw
            parameters = session.acpModelParameterSelections
            providerID = session.providerSessionID
            cleanup = session.providerCleanupHandle
            codexID = session.codexConversationID
            rollout = session.codexRolloutPath
            codexModel = session.codexModel
            codexEffort = session.codexReasoningEffort
            computerUseActivation = session.pendingCodexComputerUseActivation
            computerUseArming = session.codexComputerUseArmingRequestID
            context = session.captureProviderSwitchContext()
            handoff = session.pendingHandoff
        }

        func restore(_ session: TabSession) {
            session.selectedAgent = agent
            session.selectedModelRaw = model
            session.selectedReasoningEffortRaw = effort
            session.selectedClaudeEffortRaw = claudeEffort
            session.acpModelParameterSelections = parameters
            session.providerSessionID = providerID
            session.providerCleanupHandle = cleanup
            session.codexConversationID = codexID
            session.codexRolloutPath = rollout
            session.codexModel = codexModel
            session.codexReasoningEffort = codexEffort
            session.pendingCodexComputerUseActivation = computerUseActivation
            session.codexComputerUseArmingRequestID = computerUseArming
            session.restoreProviderSwitchContext(context)
            session.pendingHandoff = handoff
            session.isDirty = true
        }
    }

    /// UI-only interception. The shared picker/MCP selection predicate deliberately stays locked.
    func providerSwitchPickerRequiresPreview(_ agent: AgentProviderKind, session: TabSession) -> Bool {
        session.pendingHandoff.providerSwitchDelivery != nil || !canSelectAgentInCurrentChat(agent)
    }

    @discardableResult
    func requestProviderSwitchSelection(agent: AgentProviderKind, model: String, tabID: UUID?, cursorParameterIntent: ProviderSwitchCursorParameterIntent? = nil) -> Bool {
        guard let tabID, let session = sessions[tabID], currentTabID == tabID else { return false }
        guard providerSwitchPickerRequiresPreview(agent, session: session) else { return false }
        let binding = session.currentRestorationBindingToken
        let workspaceID = workspaceManager?.activeWorkspaceID
        Task { @MainActor [weak self] in
            guard let self, sessions[tabID] === session, session.currentRestorationBindingToken == binding,
                  workspaceManager?.activeWorkspaceID == workspaceID else { return }
            await openProviderSwitchPreview(agent: agent, model: model, tabID: tabID, cursorParameterIntent: cursorParameterIntent)
        }
        return true
    }

    /// Capture banner intent before its task hop; a later binding or slot is not the clicked chat.
    @discardableResult
    func requestProviderSwitchBannerAction(for session: TabSession, discard: Bool) -> Task<Bool, Never>? {
        guard sessions[session.tabID] === session, providerSwitchMutation == nil,
              session.pendingHandoff.providerSwitchDelivery != nil else { return nil }
        let binding = session.currentRestorationBindingToken
        let workspaceID = workspaceManager?.activeWorkspaceID
        let handoff = session.pendingHandoff
        let agent = session.selectedAgent
        let model = session.selectedModelRaw
        return Task { @MainActor [weak self] in
            guard let self, sessions[session.tabID] === session,
                  session.currentRestorationBindingToken == binding,
                  workspaceManager?.activeWorkspaceID == workspaceID,
                  session.pendingHandoff == handoff else { return false }
            if discard { return await discardProviderSwitchHandover(tabID: session.tabID) }
            return await openProviderSwitchPreview(agent: agent, model: model, tabID: session.tabID) != nil
        }
    }

    @discardableResult
    func openProviderSwitchPreview(agent: AgentProviderKind, model: String, tabID: UUID, updated: Bool = false, cursorParameterIntent: ProviderSwitchCursorParameterIntent? = nil, retainingSummary: ProviderSwitchGeneratedSummary? = nil, explicitSelection: AgentProviderHandover.Mode? = nil) async -> UUID? {
        guard providerSwitchMutation == nil, let session = sessions[tabID] else { return nil }
        providerSwitchBackgroundOutcome = nil
        let descriptor = session.pendingHandoff.providerSwitchDelivery != nil
            ? session.pendingHandoff.payload.flatMap(ProviderSwitchCarrierDescriptor.init) : nil
        // Corrupt retained source data must not acquire today's selected provider as its author.
        // A source-less Review remains available for the same claimed Discard mutation only.
        let source: AgentProviderHandover.Source? = if session.pendingHandoff.providerSwitchDelivery != nil {
            descriptor.flatMap { try? AgentProviderHandover.Source(provider: $0.sourceProvider, model: $0.sourceModel) }
        } else {
            try? AgentProviderHandover.Source(provider: session.selectedAgent.displayName, model: inputBarModelDisplayName(rawModel: session.selectedModelRaw, agentKind: session.selectedAgent))
        }
        var preview = captureProviderSwitchPreview(session, agent: agent, model: model, source: source, descriptor: descriptor, updated: updated, cursorParameterIntent: cursorParameterIntent, retainingSummary: retainingSummary)
        preview.explicitSelection = explicitSelection
        providerSwitchPreview = preview
        await buildProviderSwitchPreview(preview.id)
        // A caller may act only on the preview this request opened, never a later rebuild/owner.
        return preview.id
    }

    private func captureProviderSwitchPreview(_ session: TabSession, agent: AgentProviderKind, model: String, source: AgentProviderHandover.Source?, descriptor: ProviderSwitchCarrierDescriptor?, updated: Bool = false, cursorParameterIntent: ProviderSwitchCursorParameterIntent? = nil, retainingSummary: ProviderSwitchGeneratedSummary? = nil) -> ProviderSwitchPreview {
        let destinationModel = model.isEmpty ? defaultModelRaw(for: agent) : model
        return ProviderSwitchPreview(
            id: UUID(), session: session, binding: session.currentRestorationBindingToken,
            workspaceID: workspaceManager?.activeWorkspaceID,
            stopFence: AgentRunStartStopFence(session: session), sourceAgent: session.selectedAgent,
            sourceModel: session.selectedModelRaw, sourceReasoningEffort: session.selectedReasoningEffortRaw,
            sourceClaudeEffort: session.selectedClaudeEffortRaw, source: source, originalHandoff: session.pendingHandoff, originalDescriptor: descriptor,
            destination: agent, model: destinationModel, cursorParameterIntent: cursorParameterIntent,
            sourceParameters: session.acpModelParameterSelections,
            composition: providerSwitchComposition(session, destination: agent), sourceRevision: session.sourceItemsRevision,
            draftRevision: session.draftMutationGeneration,
            instructions: providerSwitchInstructionStrings(session, destination: agent),
            instructionProvenance: providerSwitchInstructionProvenance(session, destination: agent),
            generatedSummary: retainingSummary, updated: updated
        )
    }

    private func providerSwitchPreviewIdentityIsCurrent(_ preview: ProviderSwitchPreview) -> Bool {
        let session = preview.session
        return sessions[session.tabID] === session && session.currentRestorationBindingToken == preview.binding
            && workspaceManager?.activeWorkspaceID == preview.workspaceID
    }

    private func providerSwitchPreviewIsCurrent(_ preview: ProviderSwitchPreview, content: Bool = true) -> Bool {
        let session = preview.session
        return providerSwitchPreviewIdentityIsCurrent(preview)
            && session.selectedAgent == preview.sourceAgent && session.selectedModelRaw == preview.sourceModel
            && session.selectedReasoningEffortRaw == preview.sourceReasoningEffort
            && session.selectedClaudeEffortRaw == preview.sourceClaudeEffort
            && session.pendingHandoff == preview.originalHandoff
            // Fence identity, not permission: an in-progress managed stop is live state the
            // admission layer classifies, not preview drift. Run-start denial stays in the
            // start path (permitsStart), which admission still consults.
            && preview.stopFence.binding == session.persistentSessionBindingIdentity
            && preview.stopFence.cancellationGeneration == session.stopState.cancellationGeneration
            && session.acpModelParameterSelections == preview.sourceParameters
            && (!content || (
                session.sourceItemsRevision == preview.sourceRevision
                    && session.draftMutationGeneration == preview.draftRevision
                    && providerSwitchComposition(session, destination: preview.destination) == preview.composition
                    && providerSwitchInstructionStrings(session, destination: preview.destination) == preview.instructions
            ))
    }

    private func providerSwitchGenerationSourceIsCurrent(_ preview: ProviderSwitchPreview) -> Bool {
        guard providerSwitchPreviewIsCurrent(preview, content: false) else { return false }
        let composition = providerSwitchComposition(preview.session, destination: preview.destination)
        // Draft/workflow and owed one-shot content may refit the result. includesInterview is
        // derived from history: Generate's first assistant does not change the preference.
        return composition.computerUseArmed == preview.composition.computerUseArmed
            && composition.interviewPreference == preview.composition.interviewPreference
            && composition.includeCleanupGuidance == preview.composition.includeCleanupGuidance
            && composition.images == preview.composition.images
            && composition.taggedFiles == preview.composition.taggedFiles
            && providerSwitchInstructionProvenance(preview.session, destination: preview.destination) == preview.instructionProvenance
    }

    func providerSwitchDiscardBlocker(_ session: TabSession) -> String? {
        let preview = captureProviderSwitchPreview(session, agent: session.selectedAgent, model: session.selectedModelRaw, source: nil, descriptor: nil)
        return providerSwitchDiscardBlocker(preview)
    }

    /// Discard clears only the exact local slot. Content/budget drift is irrelevant, but
    /// binding, lifecycle, relocation and all live-work admission gates remain mandatory.
    func providerSwitchDiscardBlocker(_ preview: ProviderSwitchPreview, owningMutationID: UUID? = nil) -> String? {
        guard providerSwitchPreviewIsCurrent(preview, content: false),
              preview.isReview, providerSwitchHasExactOwner(preview.session)
        else { return AgentSessionLinkSendFailure.providerHandoverNeedsReview.message }
        if let mutation = providerSwitchMutation, mutation.id != owningMutationID {
            return AgentSessionLinkSendFailure.targetBusy.message
        }
        return providerSwitchTransitionBlocker(preview.session, ownsComposerClaim: owningMutationID != nil, resolvingHandoff: preview.originalHandoff)
    }

    func providerSwitchPreviewBlocker(_ preview: ProviderSwitchPreview) -> String? {
        providerSwitchPreviewAdmission(preview).message(provider: preview.sourceAgent.displayName)
    }

    /// The sheet's one admission read: identity/intent/failure are hard, live state classifies.
    func providerSwitchPreviewAdmission(_ preview: ProviderSwitchPreview) -> ProviderSwitchAdmission {
        let needsReview = ProviderSwitchAdmission.hard(AgentSessionLinkSendFailure.providerHandoverNeedsReview.message)
        guard providerSwitchPreviewIsCurrent(preview) else { return needsReview }
        if providerSwitchMutation != nil { return .hard(AgentSessionLinkSendFailure.targetBusy.message) }
        if let intent = preview.cursorParameterIntent,
           preview.destination != .cursor || intent.applying(to: preview.sourceParameters, model: preview.model) == nil
        {
            return needsReview
        }
        if preview.source == nil || (preview.isReview && preview.originalDescriptor == nil) {
            return needsReview
        }
        if let failure = preview.failure { return .hard(failure) }
        return providerSwitchTransitionAdmission(preview.session, resolvingHandoff: preview.originalHandoff)
    }

    /// UI preference only; never persisted and never used as delivery evidence.
    func selectProviderSwitchChoice(_ mode: AgentProviderHandover.Mode, previewID: UUID) {
        guard let preview = providerSwitchPreview, preview.id == previewID,
              preview.generationItemID == nil,
              Self.providerSwitchSelection(choices: preview.choices, explicit: mode, retained: nil) == mode
        else { return }
        providerSwitchPreview?.explicitSelection = mode
        providerSwitchPreview?.selected = mode
    }

    static func providerSwitchSelection(
        choices: [ProviderSwitchChoice], explicit: AgentProviderHandover.Mode?, retained: AgentProviderHandover.Mode?
    ) -> AgentProviderHandover.Mode? {
        [explicit, retained, .history, .newestTurns].compactMap(\.self).first { mode in
            choices.contains { $0.mode == mode && !$0.hidden && $0.unavailable == nil && $0.bytes > 0 }
        }
    }

    private func buildProviderSwitchPreview(_ id: UUID) async {
        guard var preview = providerSwitchPreview, preview.id == id else { return }
        let session = preview.session
        guard let source = preview.source else {
            providerSwitchPreview?.building = false
            providerSwitchPreview?.failure = AgentSessionLinkSendFailure.providerHandoverNeedsReview.message
            return
        }
        let transcript = session.transcript
        let items = session.items
        let nextSequence = session.nextSequenceIndex
        let state = session.runState
        let originalSlot = preview.originalHandoff
        let stale = Self.providerSwitchNeedsReview(session)
        let composition = preview.composition
        let wrapped = composeProviderSwitchPreviewDraft(composition, destination: preview.destination, session: session)
        let live: @MainActor () -> Bool = { [weak self] in
            self?.providerSwitchPreview?.id == id && self?.providerSwitchPreview?.building == true
                && self?.providerSwitchPreview?.failure == nil
        }
        let stage: String?? = await providerSwitchAwaitDeadline(.previewAugmentation) {
            let initial = await self.augmentUserMessageForProviderSend(
                wrapped, attachments: composition.images,
                taggedFileAttachments: composition.taggedFiles, agent: preview.destination,
                session: session, ignoresPendingHandoff: true, shouldPublishCatalog: live
            )
            guard live() else { return nil as String? }
            return await self.buildInitialThreadMessageIfNeeded(tabID: session.tabID, session: session, initialMessage: initial)
        }
        guard live() else { return }
        guard let composed = stage ?? nil else {
            providerSwitchPreview?.building = false
            providerSwitchPreview?.failure = AgentSessionLinkSendFailure.targetNotIdle.message
            return
        }
        guard providerSwitchPreviewIsCurrent(preview) else {
            refreshProviderSwitchPreviewAfterDrift(preview)
            return
        }
        let budget = AgentProviderHandover.Budget(
            catalogWindow: providerSwitchCatalogWindow(agent: preview.destination, model: preview.model),
            instructions: preview.instructions, composedInput: "\n\n" + composed, isPreview: true
        )
        let server = preview.destination == .grokBuild ? RepoPromptMCPServerConfiguration.grokBuildRuntimeServerName : MCPIntegrationHelper.repoPromptMCPServerName
        let reference = try? session.activeAgentSessionID.flatMap {
            try AgentProviderHandover.HistoryReference(
                server: server,
                sessionID: $0,
                historyAllowed: providerSwitchHistoryToolAllowed(session, destination: preview.destination),
                indicesMatch: true
            )
        }
        do {
            let result = try await providerSwitchProjectedCarriers(
                transcript: transcript, items: items, nextSequence: nextSequence, state: state,
                originalSlot: originalSlot, stale: stale, source: source, reference: reference,
                budget: budget
            )
            guard providerSwitchPreview?.id == id else { return }
            guard providerSwitchPreviewIsCurrent(preview) else {
                refreshProviderSwitchPreviewAfterDrift(preview)
                return
            }
            preview.projection = result.projection
            preview.budget = budget
            preview.historyReference = reference
            preview.cutoff = result.cutoff
            preview.wordLimit = preview.isReview ? nil : result.wordLimit
            // A newest-turns suffix that covers every projected turn carries the same body as full
            // history; two identical rows are noise, so drop it whenever full history also fits.
            let recentDuplicatesFull = result.recent.map {
                $0.turnIndices == result.full.turnIndices
                    && $0.omittedOlderTurns == nil
                    && $0.hasToolOutputOmission == result.full.hasToolOutputOmission
                    && $0.hasImageOmission == result.full.hasImageOmission
            } ?? false
            preview.choices = [
                .init(mode: .history, carrier: result.full, unavailable: budget.fits(result.full) ? nil : "Full history doesn't fit."),
                .init(mode: .newestTurns, carrier: result.recent, unavailable: result.recent == nil ? "the last turn alone doesn't fit" : nil, hidden: recentDuplicatesFull && budget.fits(result.full)),
                .init(mode: .summary, unavailable: preview.isReview ? AgentSessionLinkSendFailure.providerHandoverNeedsReview.message : (result.wordLimit == nil ? "no room for a summary" : nil))
            ]
            if !stale, let payload = originalSlot.payload, let descriptor = preview.originalDescriptor,
               providerSwitchReadReferenceIsCurrent(descriptor, session: session, destination: preview.destination),
               let mode = AgentProviderHandover.Mode(rawValue: descriptor.mode),
               AgentProviderHandover.estimate(payload) <= budget.remainingCarrierTokens,
               payload.utf8.count <= AgentProviderHandover.maximumBytes,
               mode != .summary || payload.utf8.count <= AgentProviderHandover.maximumSummaryBytes
            {
                var index = preview.choices.firstIndex(where: { $0.mode == mode && !$0.hidden })
                if index == nil, mode == .newestTurns,
                   let hiddenIndex = preview.choices.firstIndex(where: { $0.mode == .newestTurns })
                {
                    // The saved carrier may predate a budget that now fits full history; when it
                    // differs from the fresh suffix it is real approved content, so un-hide the
                    // row rather than retaining it under the Full history label.
                    if let carrier = preview.choices[hiddenIndex].carrier,
                       payload != AgentProviderHandover.render(carrier)
                    {
                        preview.choices[hiddenIndex].hidden = false
                        index = hiddenIndex
                    }
                }
                if index == nil, mode == .newestTurns {
                    index = preview.choices.firstIndex(where: { $0.mode == .history })
                }
                if let index {
                    preview.choices[index].retainedPayload = payload
                    preview.choices[index].retainedOmissions = descriptor.omissions.isEmpty ? nil : descriptor.omissions.joined(separator: ", ")
                    preview.choices[index].unavailable = nil
                    preview.selected = preview.choices[index].mode
                }
            }
            if let summary = preview.generatedSummary { fitProviderSwitchSummary(summary, into: &preview) }
            let retainedSelection = preview.selected
            // Read the live pick after the last suspension, not the build's stale value copy.
            preview.explicitSelection = providerSwitchPreview?.explicitSelection
            preview.selected = Self.providerSwitchSelection(
                choices: preview.choices, explicit: preview.explicitSelection, retained: retainedSelection
            )
            preview.building = false
            providerSwitchPreview = preview
        } catch {
            guard providerSwitchPreview?.id == id else { return }
            providerSwitchPreview?.building = false
            providerSwitchPreview?.failure = error.localizedDescription
        }
    }

    /// Canonical retained-turn projection into the switch carriers. Preview building and the
    /// forced-apply post-stop re-render share this so both measure identical cutoff and fit
    /// semantics; only the transcript snapshot differs.
    private func providerSwitchProjectedCarriers(
        transcript: AgentTranscript, items: [AgentChatItem], nextSequence: Int,
        state: AgentSessionRunState?, originalSlot: PendingHandoffState, stale: Bool,
        source: AgentProviderHandover.Source, reference: AgentProviderHandover.HistoryReference?,
        budget: AgentProviderHandover.Budget
    ) async throws -> (projection: AgentProviderHandover.Projection, full: AgentProviderHandover.Carrier, recent: AgentProviderHandover.Carrier?, wordLimit: Int?, cutoff: UUID?) {
        try await Task.detached(priority: .userInitiated) {
            var canonical = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                existingTranscript: transcript, workingItems: items, terminalState: state,
                nextSequenceIndex: nextSequence, policy: .canonical
            )
            // Only canonical retained anchors survive normalization/save/restore. A raw tail
            // can be one of import's three filtered meta tools and is not a durable cutoff.
            var anchors: [(id: UUID, sequence: Int, reason: String?)] = []
            var appliedNotices: [Int] = []
            for turn in canonical.turns {
                if let request = turn.request { anchors.append((request.id, request.sequenceIndex, nil)) }
                for activity in turn.allActivities {
                    anchors.append((activity.id, activity.sequenceIndex, activity.recoveryDiagnostic?.reason))
                    if activity.recoveryDiagnostic?.reason == "providerSwitch", activity.recoveryDiagnostic?.outcome == "applied" { appliedNotices.append(activity.sequenceIndex) }
                }
                for diagnostic in turn.summary?.recoveryDiagnostics ?? [] {
                    anchors.append((diagnostic.id, diagnostic.sequenceIndex, diagnostic.reason))
                    if diagnostic.reason == "providerSwitch", diagnostic.outcome == "applied" { appliedNotices.append(diagnostic.sequenceIndex) }
                }
            }
            let originalSequence = originalSlot.sourceItemID.flatMap { oldID in anchors.first(where: { $0.id == oldID })?.sequence }
            let ownAppliedSequence = appliedNotices.filter { sequence in originalSequence.map { sequence > $0 } ?? true }.max()
            func isOwnPendingNotice(_ sequence: Int, reason: String?) -> Bool {
                guard originalSlot.providerSwitchDelivery != nil, reason == "providerSwitch" else { return false }
                if let originalSequence { return sequence > originalSequence }
                // Nil/missing old cutoff must not erase older completed switches. The latest
                // applied notice identifies this still-pending transition without a new field.
                return ownAppliedSequence.map { sequence >= $0 } ?? false
            }
            let cutoff = (!stale && originalSlot.providerSwitchDelivery != nil) ? originalSlot.sourceItemID
                : anchors.filter { !isOwnPendingNotice($0.sequence, reason: $0.reason) }.max(by: { $0.sequence < $1.sequence })?.id
            let cutoffSequence = cutoff.flatMap { id in anchors.first(where: { $0.id == id })?.sequence }
            if let cutoffSequence {
                canonical.turns = canonical.turns.filter { turn in
                    (turn.request?.sequenceIndex ?? turn.allActivities.first?.sequenceIndex ?? turn.summary?.recoveryDiagnostics?.first?.sequenceIndex ?? 0) <= cutoffSequence
                }
            }
            // Keep original ordinals, including retained compacted diagnostic anchors. Strip
            // this pending transition's own notices even when its original history was empty.
            for t in canonical.turns.indices {
                for s in canonical.turns[t].responseSpans.indices {
                    canonical.turns[t].responseSpans[s].activities.removeAll { activity in
                        (cutoffSequence.map { activity.sequenceIndex > $0 } ?? false)
                            || isOwnPendingNotice(activity.sequenceIndex, reason: activity.recoveryDiagnostic?.reason)
                    }
                }
                canonical.turns[t].summary?.recoveryDiagnostics?.removeAll { diagnostic in
                    (cutoffSequence.map { diagnostic.sequenceIndex > $0 } ?? false)
                        || isOwnPendingNotice(diagnostic.sequenceIndex, reason: diagnostic.reason)
                }
            }
            let projection = try AgentProviderHandover.project(canonical)
            let full = AgentProviderHandover.history(projection, source: source, historyReference: reference)
            let recent = AgentProviderHandover.newestCompleteTurns(projection, source: source, historyReference: reference, budget: budget)
            let words = AgentProviderHandover.summaryWordLimit(for: projection, source: source, historyReference: reference, budget: budget)
            return (projection, full, recent, words, cutoff)
        }.value
    }

    private func refreshProviderSwitchPreviewAfterDrift(_ preview: ProviderSwitchPreview) {
        guard providerSwitchPreview?.id == preview.id else { return }
        providerSwitchPreview?.building = false
        providerSwitchPreview?.failure = AgentSessionLinkSendFailure.providerHandoverNeedsReview.message
        guard providerSwitchPreviewIdentityIsCurrent(preview) else { return }
        queueProviderSwitchPreviewRefresh(preview)
    }

    private func queueProviderSwitchPreviewRefresh(_ preview: ProviderSwitchPreview) {
        providerSwitchPreview?.building = true
        Task { @MainActor [weak self] in
            guard let self, providerSwitchPreview?.id == preview.id else { return }
            #if DEBUG
                await test_beforeProviderSwitchPreviewRefresh?(preview.session)
            #endif
            guard providerSwitchPreview?.id == preview.id else { return }
            guard providerSwitchPreviewIdentityIsCurrent(preview) else {
                providerSwitchPreview?.building = false
                providerSwitchPreview?.failure = AgentSessionLinkSendFailure.providerHandoverNeedsReview.message
                return
            }
            let composition = providerSwitchComposition(preview.session, destination: preview.destination)
            let canRetain = preview.session.sourceItemsRevision == preview.sourceRevision
                && preview.session.selectedAgent == preview.sourceAgent
                && preview.session.selectedModelRaw == preview.sourceModel
                && preview.session.selectedReasoningEffortRaw == preview.sourceReasoningEffort
                && preview.session.selectedClaudeEffortRaw == preview.sourceClaudeEffort
                && preview.session.acpModelParameterSelections == preview.sourceParameters
                && composition.computerUseArmed == preview.composition.computerUseArmed
                && composition.includesInterview == preview.composition.includesInterview
                && composition.interviewPreference == preview.composition.interviewPreference
                && composition.includeCleanupGuidance == preview.composition.includeCleanupGuidance
                && composition.images == preview.composition.images && composition.taggedFiles == preview.composition.taggedFiles
                && providerSwitchInstructionProvenance(preview.session, destination: preview.destination) == preview.instructionProvenance
            await openProviderSwitchPreview(agent: preview.destination, model: preview.model, tabID: preview.session.tabID, updated: true, cursorParameterIntent: preview.cursorParameterIntent, retainingSummary: canRetain ? preview.generatedSummary : nil, explicitSelection: providerSwitchPreview?.explicitSelection)
        }
    }

    func providerSwitchPreviewDidChange(_ session: TabSession) {
        guard let preview = providerSwitchPreview, preview.session === session,
              !preview.building, preview.generationItemID == nil, providerSwitchMutation == nil,
              !providerSwitchPreviewIsCurrent(preview) else { return }
        // Identity loss is not refreshable configuration drift. Keep the original intent blocked.
        guard providerSwitchPreviewIdentityIsCurrent(preview) else {
            providerSwitchPreview?.failure = AgentSessionLinkSendFailure.providerHandoverNeedsReview.message
            return
        }
        queueProviderSwitchPreviewRefresh(preview)
    }

    func cancelProviderSwitchPreview() {
        if let mutation = providerSwitchMutation, mutation.phase == .preparing {
            endProviderSwitchMutation(mutation.id)
        }
        providerSwitchPreview = nil
    }

    func providerSwitchPayload(_ id: UUID, mode: AgentProviderHandover.Mode) async -> String? {
        guard let preview = providerSwitchPreview, preview.id == id,
              let choice = preview.choices.first(where: { $0.mode == mode }) else { return nil }
        if let payload = choice.retainedPayload { return payload }
        guard let carrier = choice.carrier else { return nil }
        let payload = await Task.detached(priority: .userInitiated) { AgentProviderHandover.render(carrier) }.value
        guard providerSwitchPreview?.id == id, providerSwitchPreviewIsCurrent(preview) else { return nil }
        return payload
    }

    /// Forced apply only: project the post-stop source transcript and rebuild the selected
    /// carrier under the preview's budget. A generated summary refits onto the fresh projection;
    /// a retained payload is never consulted — trajectory modes rebuild fresh, and a summary
    /// selection without generated text refuses rather than staging pre-stop bytes. The returned
    /// revision is the `sourceItemsRevision` observed with the snapshot, so callers can detect
    /// rows that landed during the detached projection. Nil means do not proceed.
    private func providerSwitchForcedHandoverPayload(
        _ preview: ProviderSwitchPreview, session: TabSession
    ) async -> (payload: String, cutoff: UUID?, revision: Int)? {
        guard let source = preview.source, let budget = preview.budget else { return nil }
        let revision = session.sourceItemsRevision
        do {
            let result = try await providerSwitchProjectedCarriers(
                transcript: session.transcript, items: session.items,
                nextSequence: session.nextSequenceIndex, state: session.runState,
                originalSlot: preview.originalHandoff,
                stale: Self.providerSwitchNeedsReview(session), source: source,
                reference: preview.historyReference, budget: budget
            )
            let carrier: AgentProviderHandover.Carrier? = switch preview.selected ?? .history {
            case .history: result.full
            case .newestTurns: result.recent
            case .summary:
                try preview.generatedSummary.map {
                    try AgentProviderHandover.summary($0.text, of: result.projection, source: source, historyReference: preview.historyReference)
                }
            }
            guard let carrier, budget.fits(carrier) else { return nil }
            let rendered = await Task.detached(priority: .userInitiated) { AgentProviderHandover.render(carrier) }.value
            return (rendered, result.cutoff, revision)
        } catch {
            return nil
        }
    }

    private func providerSwitchHasExactOwner(_ session: TabSession) -> Bool {
        guard let id = session.activeAgentSessionID else { return false }
        let census = AgentSessionCarrierResolver.capture(
            windows: WindowStatesManager.shared.allWindows,
            sessionIDs: [id],
            includeRuntimeOwners: true
        )
        return census.isCurrent() && !census.ambiguousSessionIDs.contains(id)
            && !census.placementConflictSessionIDs.contains(id) && census.uniqueRuntimeOwners[id]?.session === session
    }

    private func providerSwitchClaim(_ preview: ProviderSwitchPreview, discard: Bool = false) -> AgentComposerSubmitClaim? {
        guard providerSwitchPreviewIsCurrent(preview, content: !discard), providerSwitchHasExactOwner(preview.session),
              let target = makeComposerSubmitTarget(tabID: preview.session.tabID, session: preview.session) else { return nil }
        let attempt = AgentComposerSubmitAttempt(
            id: UUID(),
            target: target,
            inputRevision: 0,
            noticeRevision: 0,
            rawDraftSnapshot: preview.session.draftText
        )
        guard case let .claimed(claim) = claimComposerSubmitAttempt(attempt, requireActiveTabOwnership: false) else { return nil }
        return claim
    }

    /// Explicit Generate is one ordinary source run. It never consumes the composer's workflow or
    /// attachments, never claims local authorship, and never applies or queues a provider switch.
    func generateProviderSwitchHandover(_ id: UUID) async {
        guard let preview = providerSwitchPreview, preview.id == id, !preview.isReview,
              let words = preview.wordLimit, let request = AgentProviderHandover.summaryRequest(wordLimit: words),
              providerSwitchPreviewBlocker(preview) == nil, let claim = providerSwitchClaim(preview) else { return }
        defer { releaseComposerSubmitClaim(claim) }
        let session = preview.session
        if let failure = await providerSwitchRequireIdle(session) {
            if providerSwitchPreview?.id == id {
                providerSwitchPreview?.failure = failure
            }
            return
        }
        guard providerSwitchPreview?.id == id, providerSwitchPreviewIsCurrent(preview), composerSubmitClaimIsCurrent(claim),
              providerSwitchTransitionBlocker(session, ownsComposerClaim: true) == nil,
              let workspaceID = workspaceManager?.activeWorkspaceID else { return }
        // Publish the exact row identity before dispatch, including synchronous fake completions.
        let row = AgentChatItem.user(request, sequenceIndex: session.nextSequenceIndex)
        session.appendItem(row)
        providerSwitchPreview?.generationItemID = row.id
        providerSwitchPreview?.selected = .summary
        session.isDirty = true
        guard case .success = await flushSaveRequired(for: session.tabID, workspaceID: workspaceID),
              providerSwitchPreview?.id == id, providerSwitchPreview?.generationItemID == row.id,
              composerSubmitClaimIsCurrent(claim), preview.stopFence.permitsStart(of: session),
              sessions[session.tabID] === session, session.currentRestorationBindingToken == preview.binding
        else {
            if providerSwitchPreview?.id == id {
                providerSwitchPreview?.generationItemID = nil
                if let index = providerSwitchPreview?.choices.firstIndex(where: { $0.mode == .summary }) {
                    providerSwitchPreview?.choices[index].unavailable = AgentSessionLinkSendFailure.persistenceIndeterminate.message
                }
            }
            return
        }
        #if DEBUG
            if let test_providerSwitchGeneration {
                await test_providerSwitchGeneration(session, row.id, request)
                providerSwitchGenerationSettled(session)
                return
            }
        #endif
        let outcome = AgentRunStartOutcomeRecorder()
        #if DEBUG
            if let test_providerSwitchGenerationStart {
                await test_providerSwitchGenerationStart(session, request, outcome)
            } else {
                _ = await startAgentRun(tabID: session.tabID, initialMessage: request, directStartOptions: .init(ignoresPendingHandoff: true, stopFence: preview.stopFence), startOutcome: outcome)
            }
        #else
            _ = await startAgentRun(tabID: session.tabID, initialMessage: request, directStartOptions: .init(ignoresPendingHandoff: true, stopFence: preview.stopFence), startOutcome: outcome)
        #endif
        if !outcome.outcome.didStart {
            guard providerSwitchPreview?.id == id, providerSwitchPreview?.generationItemID == row.id else { return }
            providerSwitchPreview?.generationItemID = nil
            if let index = providerSwitchPreview?.choices.firstIndex(where: { $0.mode == .summary }) {
                providerSwitchPreview?.choices[index].unavailable = AgentSessionLinkSendFailure.targetNotIdle.message
            }
        } else { agentSessionLinkClearWaitingOnAfterAcceptedTurn(session) }
    }

    func providerSwitchGenerationSettled(_ session: TabSession) {
        guard let preview = providerSwitchPreview, preview.session === session,
              sessions[session.tabID] === session, session.currentRestorationBindingToken == preview.binding,
              workspaceManager?.activeWorkspaceID == preview.workspaceID,
              session.pendingHandoff == preview.originalHandoff,
              let rowID = preview.generationItemID, !preview.generationFinished else { return }
        refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
        guard let turn = session.transcript.turns.first(where: { $0.request?.id == rowID }),
              turn.completedAt != nil, !(turn.terminalState?.isActive ?? false) else { return }
        providerSwitchPreview?.generationFinished = true
        guard providerSwitchGenerationSourceIsCurrent(preview) else {
            refreshProviderSwitchPreviewAfterDrift(preview)
            return
        }
        let usedTools = !AgentProviderHandover.isZeroEffectfulToolControlTurn(turn)
        let conclusion = turn.allActivities.first { $0.id == turn.conclusionActivityID }?.text
        let settledRevision = session.sourceItemsRevision
        Task { @MainActor [weak self] in
            #if DEBUG
                defer { self?.test_providerSwitchGenerationRebuildDidFinish?() }
            #endif
            guard let self, providerSwitchPreview?.id == preview.id,
                  sessions[session.tabID] === session, session.currentRestorationBindingToken == preview.binding,
                  workspaceManager?.activeWorkspaceID == preview.workspaceID,
                  session.pendingHandoff == preview.originalHandoff else { return }
            guard providerSwitchGenerationSourceIsCurrent(preview) else {
                refreshProviderSwitchPreviewAfterDrift(preview)
                return
            }
            let openedID = await openProviderSwitchPreview(agent: preview.destination, model: preview.model, tabID: session.tabID, updated: true, cursorParameterIntent: preview.cursorParameterIntent)
            guard let openedID, var current = providerSwitchPreview, current.id == openedID, current.session === session,
                  current.originalHandoff == preview.originalHandoff, !current.isReview,
                  session.sourceItemsRevision == settledRevision, current.binding == preview.binding,
                  current.projection != nil, current.budget != nil else { return }
            guard providerSwitchGenerationSourceIsCurrent(preview) else {
                refreshProviderSwitchPreviewAfterDrift(current)
                return
            }
            guard let index = current.choices.firstIndex(where: { $0.mode == .summary }) else { return }
            if usedTools {
                current.choices[index].unavailable = "the model used tools"
            } else if turn.terminalState == .completed, let conclusion, !conclusion.isEmpty, let source = current.source {
                let summary = ProviderSwitchGeneratedSummary(text: conclusion, sourceRevision: settledRevision, cutoff: current.cutoff, sourceProvider: source.provider, sourceModel: source.model)
                fitProviderSwitchSummary(summary, into: &current)
            } else { current.choices[index].unavailable = session.items.last(where: { $0.kind == .error })?.text ?? AgentSessionLinkSendFailure.targetNotIdle.message }
            providerSwitchPreview = current
        }
    }

    private func fitProviderSwitchSummary(_ summary: ProviderSwitchGeneratedSummary, into preview: inout ProviderSwitchPreview) {
        guard !preview.isReview, preview.sourceRevision == summary.sourceRevision, preview.cutoff == summary.cutoff,
              let source = preview.source, source.provider == summary.sourceProvider, source.model == summary.sourceModel,
              let projection = preview.projection, let budget = preview.budget,
              let index = preview.choices.firstIndex(where: { $0.mode == .summary }),
              let carrier = try? AgentProviderHandover.summary(summary.text, of: projection, source: source, historyReference: preview.historyReference)
        else {
            preview.generatedSummary = nil
            return
        }
        preview.generatedSummary = summary
        preview.choices[index].carrier = budget.fits(carrier) ? carrier : nil
        preview.choices[index].unavailable = budget.fits(carrier) ? nil : "the summary is too large"
        if budget.fits(carrier) { preview.selected = .summary }
    }

    /// One claimed, same-identity mutation for Switch/Replace and Discard. Native retirement is
    /// irreversible; rollback restores resumable references, never resurrects shutdown controllers.
    @discardableResult
    func applyProviderSwitch(_ id: UUID, discard: Bool = false, force: Bool = false) async -> Bool {
        guard let preview = providerSwitchPreview, preview.id == id else { return false }
        return await applyProviderSwitch(preview, discard: discard, force: force, requiresPresentedPreview: true)
    }

    @discardableResult
    func discardProviderSwitchHandover(tabID: UUID) async -> Bool {
        guard providerSwitchMutation == nil, let session = sessions[tabID], session.pendingHandoff.providerSwitchDelivery != nil else { return false }
        // Discard needs exact local ownership, not a valid source descriptor or a rendered sheet.
        var preview = captureProviderSwitchPreview(session, agent: session.selectedAgent, model: session.selectedModelRaw, source: nil, descriptor: nil)
        preview.building = false
        return await applyProviderSwitch(preview, discard: true, requiresPresentedPreview: false)
    }

    private func applyProviderSwitch(_ preview: ProviderSwitchPreview, discard: Bool, force: Bool = false, requiresPresentedPreview: Bool) async -> Bool {
        let id = preview.id
        // Force only bypasses the source's own liveness; every hard blocker still refuses.
        let forcing = force && !discard && !preview.isReview
        guard !preview.building,
              preview.generationItemID == nil,
              discard
              ? providerSwitchDiscardBlocker(preview) == nil
              : providerSwitchPreviewAdmission(preview).isAdmissible(forcing: forcing),
              discard ? preview.isReview : (preview.chosen != nil && preview.chosen?.unavailable == nil),
              let claim = providerSwitchClaim(preview, discard: discard), let workspaceID = workspaceManager?.activeWorkspaceID else { return false }
        defer { releaseComposerSubmitClaim(claim) }
        let session = preview.session
        var rollback = ProviderSwitchRollback(session)
        let mutation = ProviderSwitchMutation(id: UUID(), session: session, preview: preview, saveGenerationAtEntry: session.saveRequestGeneration)
        providerSwitchBackgroundOutcome = nil
        providerSwitchMutation = mutation
        defer { endProviderSwitchMutation(mutation.id) }
        func current() -> Bool {
            // Forcing deliberately mutates the source's live state (declines interactions, stops
            // the run); the content-revision currency check would abort on that intended drift.
            // Identity (session, binding, workspace) still has to hold in either mode.
            let previewCurrent = forcing
                ? providerSwitchPreviewIdentityIsCurrent(preview)
                : providerSwitchPreviewIsCurrent(preview, content: !discard)
            return composerSubmitClaimIsCurrent(claim) && providerSwitchMutation?.id == mutation.id
                && (!requiresPresentedPreview || providerSwitchPreview?.id == id) && previewCurrent
                && workspaceManager?.activeWorkspaceID == workspaceID && providerSwitchHasExactOwner(session)
                && (
                    discard ? providerSwitchDiscardBlocker(preview, owningMutationID: mutation.id) == nil
                        : providerSwitchTransitionAdmission(
                            session, ownsComposerClaim: true, resolvingHandoff: preview.originalHandoff
                        ).isAdmissible(forcing: forcing)
                )
        }
        func transactionCurrent() -> Bool {
            let sourceCurrent = forcing ? providerSwitchPreviewIdentityIsCurrent(preview)
                : (
                    providerSwitchPreviewIsCurrent(preview, content: false)
                        && session.sourceItemsRevision == preview.sourceRevision
                        && providerSwitchInstructionStrings(session, destination: preview.destination) == preview.instructions
                )
            return composerSubmitClaimIsCurrent(claim) && providerSwitchMutation?.id == mutation.id
                && sourceCurrent && workspaceManager?.activeWorkspaceID == workspaceID
                && providerSwitchHasExactOwner(session)
                && providerSwitchTransitionAdmission(session, ownsComposerClaim: true, resolvingHandoff: preview.originalHandoff).isAdmissible(forcing: forcing)
        }
        var noticeID: UUID?
        var phase: RequiredSavePhase = .beforeWrite
        func presentFailure(_ message: String, matching handoff: PendingHandoffState) {
            if requiresPresentedPreview {
                if providerSwitchPreview?.id == id {
                    providerSwitchPreview?.failure = message
                } else if providerSwitchMutation?.id == mutation.id, providerSwitchPreviewIdentityIsCurrent(preview) {
                    providerSwitchBackgroundOutcome = .init(session: session, binding: preview.binding)
                }
            } else if providerSwitchPreviewIdentityIsCurrent(preview),
                      composerSubmitClaimIsCurrent(claim), providerSwitchMutation?.id == mutation.id,
                      session.pendingHandoff == handoff
            {
                session.appendItem(.error(message, sequenceIndex: session.nextSequenceIndex))
            }
        }
        func surfaceReviewFailure() {
            presentFailure(AgentSessionLinkSendFailure.providerHandoverNeedsReview.message, matching: session.pendingHandoff)
        }
        do {
            guard current() else { return false }
            // A forced switch renders its carrier after the managed stop below: the preview's
            // carriers were projected before the quiesce and would stage a live in-flight turn
            // with no record of the stop.
            var payload = (discard || forcing) ? nil : await providerSwitchPayload(id, mode: preview.selected ?? .history)
            guard discard || payload != nil || forcing, current() else { return false }
            var cutoff = preview.cutoff
            if !discard {
                var stagedRevision: Int?
                if forcing {
                    guard await providerSwitchQuiesceSourceForForcedSwitch(session), current() else {
                        // The quiesce already ran; a late refusal must surface, not fail silently.
                        surfaceReviewFailure()
                        return false
                    }
                    // Build and fit the selected carrier here, before irreversible retirement:
                    // the predictable no-longer-fits refusal must not tear the provider down
                    // first, and the pre-stop bytes must never stage.
                    guard let refreshed = await providerSwitchForcedHandoverPayload(preview, session: session),
                          session.sourceItemsRevision == refreshed.revision,
                          providerSwitchSourceIsSettled(session), current()
                    else {
                        surfaceReviewFailure()
                        return false
                    }
                    payload = refreshed.payload
                    cutoff = refreshed.cutoff
                    stagedRevision = refreshed.revision
                } else {
                    if let failure = await providerSwitchRequireIdle(session) {
                        presentFailure(failure, matching: preview.originalHandoff)
                        return false
                    }
                    guard current() else { return false }
                }
                if forcing {
                    // The transcript now reflects the stop; any later refusal restores this
                    // stopped source, never the pre-stop snapshot.
                    rollback = ProviderSwitchRollback(session)
                }
                // Detached shutdown can hang on a wedged provider; bound the wait on the shared
                // managed-stop deadline, never the mutation. The work itself is never cancelled —
                // a slow provider still finishes retiring detached.
                let retire = detachProviderContextForProviderSwitch(session)
                providerSwitchMutation?.phase = .detached
                _ = await providerSwitchAwaitDeadline(.retirementTail) { await retire()
                    return true
                }
                guard transactionCurrent(), !forcing || providerSwitchSourceIsSettled(session) else {
                    surfaceReviewFailure()
                    return false
                }
                if forcing, session.sourceItemsRevision != stagedRevision {
                    // Retirement is not expected to write transcript rows, so drift came from
                    // the detached stop/provider tail: rebuild once against the now-final
                    // transcript and refuse like the late path on any residual staleness.
                    guard let refreshed = await providerSwitchForcedHandoverPayload(preview, session: session),
                          session.sourceItemsRevision == refreshed.revision,
                          providerSwitchSourceIsSettled(session), transactionCurrent()
                    else {
                        surfaceReviewFailure()
                        return false
                    }
                    payload = refreshed.payload
                    cutoff = refreshed.cutoff
                }
                // No suspension is permitted between clearing any native family and staging context.
                clearProviderContextForProviderSwitch(session)
                session.selectedAgent = preview.destination
                session.selectedModelRaw = preview.model
                if preview.destination.usesClaudeTooling, let effort = ClaudeModelSpecifier(raw: preview.model).explicitEffortLevel {
                    session.selectedClaudeEffortRaw = effort.rawValue
                }
                if preview.destination != rollback.agent || preview.model != rollback.model { session.selectedReasoningEffortRaw = nil }
                if let intent = preview.cursorParameterIntent,
                   let selections = intent.applying(to: preview.sourceParameters, model: preview.model)
                {
                    // The model-menu variant is intent until this synchronous Switch staging.
                    // Use existing parameter persistence; never mutate on open or Cancel.
                    let writes: [ACPModelParameterSelection] = switch intent {
                    case let .select(selection): [selection]
                    case let .clear(identity): preview.sourceParameters.filter { $0.identity == identity }
                    }
                    session.recordAcceptedACPModelParameterWrite(writes)
                    session.acpModelParameterSelections = selections
                }
                session.pendingHandoff = .init(
                    payload: payload,
                    createdAt: Date(),
                    sourceItemID: cutoff,
                    providerSwitchDelivery: .ready
                )
                agentSessionLinkReoweSupplementForRebuiltProviderContext(for: session)
            } else { session.pendingHandoff.clearAfterSend() }
            let text: String
            if discard { text = "Pending handover discarded; chat history unchanged." }
            else {
                guard let source = preview.source else { return false }
                text = "Provider changed from \(source.provider) / \(source.model) to \(preview.destination.displayName) / \(inputBarModelDisplayName(rawModel: preview.model, agentKind: preview.destination)); handover: \(preview.chosen?.label ?? "Full history")."
            }
            let notice = AgentChatItem.system(
                text,
                sequenceIndex: session.nextSequenceIndex,
                recoveryDiagnostic: .init(reason: "providerSwitch", outcome: discard ? "discarded" : "applied", text: text)
            )
            noticeID = notice.id
            session.appendItem(notice)
            session.isDirty = true
            providerSwitchMutation?.phase = .staged
            updateBindingsFromSession(session)
            let staged = session.pendingHandoff
            #if DEBUG
                test_providerSwitchBeforeSave?(session)
            #endif
            let result = await flushSaveRequired(for: session.tabID, workspaceID: workspaceID, observingSavePhase: { phase = $0 })
            guard case .success = result else {
                if phase == .beforeWrite, sessions[session.tabID] === session,
                   session.currentRestorationBindingToken == preview.binding, composerSubmitClaimIsCurrent(claim),
                   session.pendingHandoff == staged
                {
                    rollback.restore(session)
                    if let index = session.items.firstIndex(where: { $0.id == noticeID }) { _ = session.removeItem(at: index) }
                    for t in session.transcript.turns.indices {
                        for s in session.transcript.turns[t].responseSpans.indices {
                            session.transcript.turns[t].responseSpans[s].activities.removeAll { $0.id == noticeID }
                        }
                        session.transcript.turns[t].summary?.recoveryDiagnostics?.removeAll { $0.id == noticeID }
                    }
                    refreshDerivedTranscriptState(for: session)
                }
                if case let .failure(failure) = result {
                    presentFailure(failure.message, matching: phase == .beforeWrite ? rollback.handoff : staged)
                }
                updateBindingsFromSession(session)
                return false
            }
            guard sessions[session.tabID] === session, session.currentRestorationBindingToken == preview.binding,
                  composerSubmitClaimIsCurrent(claim), session.pendingHandoff == staged else { return false }
            if providerSwitchPreview?.session === session, providerSwitchPreview?.binding == preview.binding { providerSwitchPreview = nil }
            updateBindingsFromSession(session)
            return true
        }
    }
}

/// Parse persisted M1 as data, never instructions. No external entity/network resolution.
private final class ProviderSwitchCarrierDescriptor: NSObject, XMLParserDelegate {
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
