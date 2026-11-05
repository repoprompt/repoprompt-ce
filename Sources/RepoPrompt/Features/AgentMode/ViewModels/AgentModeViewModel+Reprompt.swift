import Combine
import Foundation
import RepoPromptSettingsCore

extension AgentModeViewModel {
    static func automationJudgingText(original: String, reprompted: String?) -> String {
        guard let reprompted, reprompted.count <= 4000 else { return original }
        return reprompted
    }

    private static func repromptBlockingInteractions(_ session: TabSession) -> [Bool] {
        [
            session.pendingAskUser != nil,
            session.pendingApproval != nil,
            session.pendingUserInputRequest != nil,
            session.pendingPermissionsRequest != nil,
            session.pendingMCPElicitationRequest != nil,
            session.pendingApplyEditsReview != nil,
            session.pendingWorktreeMergeReview != nil
        ]
    }

    static func isRepromptEligible(text: String, hasStagedCommand: Bool = false) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("/") && !hasStagedCommand
    }

    /// Called after UI publication commits. The operation owns the generated draft;
    /// the native editor may still show the preceding chunk, but any native edit/IME
    /// takeover fences automatic dispatch synchronously before changing that text.
    func consumeRepromptAutoSend(
        _ request: AgentRepromptUIStore.AutoSendRequest, tabID: UUID?, visibleDraft: String, hasMarkedText: Bool
    ) -> Bool {
        guard repromptEnabled, currentTabID == tabID, request.tabID == tabID,
              repromptUIStore.autoSendRequests[request.tabID] == request, visibleDraft == request.text, !hasMarkedText,
              let operation = repromptOperation, operation.id == request.operationID else { return false }
        return operation.consumeAutoSend(request)
    }

    /// Mouse Send and Return share this preparation boundary; dispatch still requires a fresh claim.
    /// A second explicit send accepts the visible draft in every phase, including failure and clarification.
    func prepareRepromptForComposerSend(target: AgentComposerSubmitTarget, text: String) -> Bool {
        guard let session = sessions[target.tabID], currentTabID == target.tabID,
              makeComposerSubmitTarget(tabID: target.tabID, session: session) == target,
              session.draftText == text else { return true }
        if let operation = repromptOperations[target.tabID] {
            operation.useCurrentDraft(text)
            return operation.isClosed || operation.phase != .completed
        }
        if let recovery = repromptUIStore.recoveries[target.tabID],
           recovery.draftAtInvalidation.utf8.elementsEqual(text.utf8)
        {
            keepRepromptRewrite(tabID: target.tabID)
            return false
        }
        return beginComposerReprompt(target: target, text: text)
    }

    /// Returns true when this Send is preparation (or is blocked by an unfinished preparation).
    /// No composer attempt, submission token, history row or runtime claim is acquired here.
    func beginComposerReprompt(target: AgentComposerSubmitTarget, text: String, forceReview: Bool = false, reprepare: Bool = false) -> Bool {
        var original = text
        var source = text
        if let operation = repromptOperations[target.tabID] {
            guard operation.validate() else { return true }
            if !reprepare || (operation.phase != .completed && operation.phase != .failed) { return operation.phase != .completed }
            original = operation.rawDraft
            source = text == operation.lastGeneratedText ? original : text
            operation.cancel(restoreOriginal: false, recover: false)
        }
        if !reprepare {
            if repromptUIStore.hasCancelledDraft(tabID: target.tabID, text: text) { return false }
            repromptUIStore.clearCancelledDraft(tabID: target.tabID)
        }
        if !reprepare, let recovery = repromptUIStore.recoveries[target.tabID] {
            if recovery.draftAtInvalidation != text {
                // Keep the recoverable alternative, but never lend its original/classification
                // authority to a different draft typed after restoration or invalidation.
                repromptUIStore.recoveries[target.tabID]?.requiresDecision = false
                repromptUIStore.recoveries[target.tabID]?.bypassesPreparation = false
            } else {
                if recovery.requiresDecision { return true }
                if recovery.bypassesPreparation { return false }
            }
        }
        guard repromptEnabled || forceReview,
              Self.isRepromptEligible(text: original, hasStagedCommand: stagedSlashCommandProps(tabID: target.tabID) != nil),
              !isMCPControlled(tabID: target.tabID) else { return false }
        guard let session = sessions[target.tabID], currentTabID == target.tabID,
              makeComposerSubmitTarget(tabID: target.tabID, session: session) == target else { return true }
        // Without a resolved model a preparation can only fail. Ordinary Return sends the draft
        // as typed (the pill already shows why Re-prompt is unavailable); explicit Cmd-Return still
        // reports the failure. No other model is substituted, so a saved choice is never overridden.
        if !forceReview, resolvedRepromptModel(session: session) == nil { return false }
        repromptUIStore.clearCancelledDraft(tabID: target.tabID)
        repromptOperations[target.tabID]?.invalidate(reason: "A newer preparation began.")
        // A new explicit preparation supersedes old decision/bypass authority, not its recoverable text.
        repromptUIStore.recoveries[target.tabID]?.requiresDecision = false
        repromptUIStore.recoveries[target.tabID]?.bypassesPreparation = false
        let rewriteSource = source
        let id = UUID()
        let workspaceID = workspaceManager?.activeWorkspaceID
        let profile = modelRouterSettingsStore.effectiveAgentModelsProfile(workspaceID: workspaceID)
        let mode = workspaceID.map { modelRouterSettingsStore.workspaceAgentModelsSettings(for: $0).inheritanceMode }
        let capturedPending = Self.pendingUserTurnState(from: session)
        let interactions = Self.repromptBlockingInteractions(session)
        let workflowGeneration = session.userWorkflowSelectionMutationGeneration
        let history = repromptIncludesRecentChat ? AgentRepromptHistory.make(
            items: session.items, compactedAt: session.contextCompactedAt, hasActiveTurn: session.runState.isActive,
            completedUserItemIDs: AgentRepromptHistory.closedRequestIDs(in: session.transcript)
        ) : []
        let sessionTitle = repromptIncludesRecentChat ? AgentRepromptHistory.sessionTitle(
            workspaceManager?.composeTabName(with: target.tabID)
        ) : nil
        // Attachment controls are locked during preparation, so this list stays true for the whole call.
        let request = AgentRepromptRequest(
            originalText: rewriteSource,
            guidance: AgentRepromptGuidance.effectiveText(profile.agentRepromptGuidance),
            recentChat: history,
            attachments: AgentRepromptAttachment.list(files: session.pendingFileAttachments, tagged: session.pendingTaggedFileAttachments),
            sessionTitle: sessionTitle
        )
        // Preparation is the point of use: pin the automatic route before any backend call.
        let model = repromptModelResolution(session: session, pinningDefault: true).model
        let disclosed = model == nil || repromptAvailability != nil || !repromptPillProps().requiresDisclosure
        let operation = AgentRepromptOperation(
            id: id, sourceTabID: target.tabID, rawDraft: original, draftGeneration: session.draftMutationGeneration,
            request: request, model: model, service: repromptService, store: repromptUIStore,
            initialError: disclosed ? nil : .disclosureRequired,
            initialDraft: text, mode: forceReview ? .review : (profile.agentRepromptMode ?? .review),
            currentDraft: { [weak session] in session?.draftText ?? "" },
            applyDraft: { [weak self, weak session] value in
                guard let self, let session, repromptOperations[target.tabID]?.id == id,
                      sessions[target.tabID] === session else { return nil }
                session.draftText = value
                return session.draftMutationGeneration
            },
            chooseEffort: { [weak self] model in
                await self?.chooseRepromptEffort(model: model, text: rewriteSource, requestID: id) ?? model
            },
            // Which session is visible is deliberately not part of this: a rewrite outlives a switch.
            isCurrent: { [weak self, weak session] in
                guard let self, let session, let operation = repromptOperations[target.tabID], operation.id == id else { return false }
                let live = modelRouterSettingsStore.effectiveAgentModelsProfile(workspaceID: workspaceID)
                let liveMode = workspaceID.map { self.modelRouterSettingsStore.workspaceAgentModelsSettings(for: $0).inheritanceMode }
                return sessions[target.tabID] === session
                    && workspaceManager?.activeWorkspaceID == workspaceID
                    && (operation.mode != .sendAutomatically || repromptEnabled)
                    && makeComposerSubmitTarget(tabID: target.tabID, session: session) == target
                    && (operation.isPublishing || (session.draftText == operation.expectedDraft && session.draftMutationGeneration == operation.expectedDraftGeneration))
                    && Self.pendingUserTurnState(from: session) == capturedPending
                    && Self.repromptBlockingInteractions(session) == interactions
                    && session.userWorkflowSelectionMutationGeneration == workflowGeneration
                    && session.operationAdmissionFailureMessage == nil
                    && liveMode == mode && live.agentRepromptModelRaw == profile.agentRepromptModelRaw
                    && live.agentRepromptGuidance == profile.agentRepromptGuidance
                    && live.agentRepromptMode == profile.agentRepromptMode
                    && live.agentRepromptIncludesRecentChat == profile.agentRepromptIncludesRecentChat
                    && resolvedRepromptModel(session: session) == model
            }
        )
        repromptOperations[target.tabID] = operation
        operation.onComplete = { [weak self, weak operation, weak session] brief in
            guard let self, let operation, let session else { return }
            startRepromptSpeculation(session: session, operationID: operation.id, text: brief, originalText: operation.rawDraft)
        }
        operation.onStateChange = { [weak self] in self?.syncStatusPillsUIState() }
        operation.onEdit = { [weak self] in self?.cancelRepromptSpeculation(claimID: id) }
        operation.onClose = { [weak self] in
            guard let self else { return }
            cancelRepromptSpeculation(claimID: id)
            if repromptOperations[target.tabID]?.id == id {
                repromptOperations[target.tabID] = nil
            }
            syncStatusPillsUIState()
        }
        let check: () -> Void = { [weak operation] in operation?.scheduleValidation() }
        session.objectWillChange.sink { _ in check() }.store(in: &operation.observations)
        objectWillChange.sink { _ in check() }.store(in: &operation.observations)
        modelRouterSettingsStore.objectWillChange.sink { _ in check() }.store(in: &operation.observations)
        workspaceManager?.objectWillChange.sink { _ in check() }.store(in: &operation.observations)
        promptManager?.objectWillChange.sink { _ in check() }.store(in: &operation.observations)
        operation.start()
        syncStatusPillsUIState()
        return true
    }

    /// Cmd-Return is local, explicit Review preparation even when the pill is off.
    /// Pending interactive reviews retain ownership of their existing keyboard shortcuts.
    @discardableResult
    func requestComposerRepromptAgain(target: AgentComposerSubmitTarget, text: String) -> Bool {
        let eligibilityText: String = if let owned = repromptOperations[target.tabID],
                                         owned.phase == .completed || owned.phase == .failed
        {
            owned.rawDraft // Generated/edited slash-like data is not a staged command.
        } else { text }
        guard let session = sessions[target.tabID], currentTabID == target.tabID,
              makeComposerSubmitTarget(tabID: target.tabID, session: session) == target,
              !isMCPControlled(tabID: target.tabID),
              !Self.repromptBlockingInteractions(session).contains(true),
              Self.isRepromptEligible(text: eligibilityText, hasStagedCommand: stagedSlashCommandProps(tabID: target.tabID) != nil),
              repromptOperations[target.tabID]?.phase.isBusy != true else { return false }
        if repromptAvailability == nil, repromptPillProps().isAvailable, repromptPillProps().requiresDisclosure {
            repromptUIStore.oneShotDisclosureRequest = .init(target: target, text: text, generation: session.draftMutationGeneration)
            return true
        }
        return beginComposerReprompt(target: target, text: text, forceReview: true, reprepare: true)
    }

    func confirmOneShotReprompt(requestID: UUID, providerID: String) {
        guard let request = repromptUIStore.oneShotDisclosureRequest, request.id == requestID else { return }
        repromptUIStore.oneShotDisclosureRequest = nil
        guard let session = sessions[request.target.tabID], currentTabID == request.target.tabID,
              session.draftText == request.text, session.draftMutationGeneration == request.generation,
              repromptPillProps().providerID == providerID else { return }
        AgentRepromptDisclosure.acknowledge(providerID: providerID, defaults: .standard)
        _ = requestComposerRepromptAgain(target: request.target, text: request.text)
    }

    /// Synchronous transfer at the real, local composer claim boundary, before token publication.
    func adoptRepromptPreparation(into claim: AgentComposerSubmitClaim) {
        guard let operation = repromptOperations[claim.attempt.sourceTabID], operation.phase == .completed,
              sessions[operation.sourceTabID] === claim.sourceSession,
              operation.expectedDraft.utf8.elementsEqual(claim.attempt.rawDraftSnapshot.utf8)
        else {
            let tabID = claim.attempt.sourceTabID
            guard repromptOperations[tabID] == nil, currentTabID == tabID, sessions[tabID] === claim.sourceSession,
                  let recovery = repromptUIStore.recoveries[tabID], recovery.bypassesPreparation, !recovery.requiresDecision,
                  recovery.draftAtInvalidation.utf8.elementsEqual(claim.attempt.rawDraftSnapshot.utf8),
                  stagedSlashCommandProps(tabID: tabID) == nil else { return }
            // Only the exact explicitly kept/restored draft may transfer original slash classification.
            repromptDispatchTexts[claim.attempt.id] = claim.attempt.rawDraftSnapshot.trimmingCharacters(in: .whitespacesAndNewlines)
            repromptDispatchOriginals[claim.attempt.id] = recovery.originalDraft
            repromptAudits[claim.attempt.id] = .init(outcome: .approved)
            repromptUIStore.recoveries[tabID]?.bypassesPreparation = false
            repromptUIStore.recoveries[tabID]?.requiresDecision = true
            return
        }
        repromptDispatchTexts[claim.attempt.id] = claim.attempt.rawDraftSnapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        repromptDispatchOriginals[claim.attempt.id] = operation.rawDraft
        repromptSpeculations[claim.attempt.id] = repromptSpeculations.removeValue(forKey: operation.id)
        repromptAudits[claim.attempt.id] = .init(outcome: operation.usedOriginal ? .sentOriginal : .approved)
        operation.cancel(restoreOriginal: false, recover: false)
    }

    func invalidateRepromptIfNeeded() {
        for operation in Array(repromptOperations.values) {
            _ = operation.validate()
        }
    }

    func cancelReprompt() {
        for operation in Array(repromptOperations.values) {
            operation.cancel()
        }
    }

    func undoReprompt() {
        guard let operation = repromptOperation, currentTabID == operation.sourceTabID else { return }
        operation.cancel()
    }

    /// "Send original" prepares the unchanged draft for the next Send; it never auto-dispatches.
    func useRepromptOriginal() {
        guard let operation = repromptOperation, operation.validate() else { return }
        operation.useOriginal()
    }
}
