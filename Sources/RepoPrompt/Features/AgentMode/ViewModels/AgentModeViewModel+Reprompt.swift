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

    /// Returns true when this Send is preparation (or is blocked by an unfinished preparation).
    /// No composer attempt, submission token, history row or runtime claim is acquired here.
    func beginComposerReprompt(target: AgentComposerSubmitTarget, text: String, forceReview: Bool = false, reprepare: Bool = false) -> Bool {
        var original = text
        var source = text
        if let operation = repromptOperation, operation.sourceTabID == target.tabID {
            guard operation.validate() else { return true }
            if !reprepare || operation.phase != .completed { return operation.phase != .completed }
            original = operation.rawDraft
            source = text == operation.lastGeneratedText ? original : text
            operation.cancel(restoreOriginal: false, recover: false)
        }
        if !reprepare, let recovery = repromptUIStore.recoveries[target.tabID] {
            if recovery.requiresDecision { return true }
            if recovery.bypassesPreparation, recovery.draftAtInvalidation == text { return false }
        }
        guard repromptEnabled || forceReview,
              Self.isRepromptEligible(text: original, hasStagedCommand: stagedSlashCommandProps(tabID: target.tabID) != nil),
              !isMCPControlled(tabID: target.tabID) else { return false }
        guard let session = sessions[target.tabID], currentTabID == target.tabID,
              makeComposerSubmitTarget(tabID: target.tabID, session: session) == target else { return true }
        repromptOperation?.invalidate(reason: "Another composer began preparation.")
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
        let roots = workspaceManager?.activeWorkspace?.repoPaths ?? []
        let selected = workspaceID.flatMap { workspaceManager?.composeTab(for: .init(workspaceID: $0, tabID: target.tabID))?.selection }
        let paths = (selected?.selectedPaths ?? []) + (selected?.manualCodemapPaths ?? []) + (selected.map { Array($0.slices.keys) } ?? [])
        let relativePaths = paths.map { path in
            guard let root = roots.first(where: { path.hasPrefix($0 + "/") }) else {
                return path.hasPrefix("/") ? URL(fileURLWithPath: path).lastPathComponent : path
            }
            return URL(fileURLWithPath: root).lastPathComponent + "/" + path.dropFirst(root.count + 1)
        }
        let history = repromptIncludesRecentChat ? AgentRepromptHistory.make(
            items: session.items, compactedAt: session.contextCompactedAt, hasActiveTurn: session.runState.isActive,
            completedUserItemIDs: Set(session.transcript.turns.filter { $0.terminalState == .completed }.compactMap { $0.request?.id })
        ) : []
        let request = AgentRepromptRequest(
            originalText: rewriteSource,
            manifest: AgentRepromptModelPolicy.manifest(rootNames: roots.map { URL(fileURLWithPath: $0).lastPathComponent }, selectedPaths: relativePaths),
            guidance: AgentRepromptGuidance.effectiveText(profile.agentRepromptGuidance), recentChat: history
        )
        let model = resolvedRepromptModel(session: session)
        let disclosed = model == nil || repromptAvailability != nil || !repromptPillProps().requiresDisclosure
        let operation = AgentRepromptOperation(
            id: id, sourceTabID: target.tabID, rawDraft: original, draftGeneration: session.draftMutationGeneration,
            request: request, model: model, service: repromptService, store: repromptUIStore,
            initialError: disclosed ? nil : .disclosureRequired,
            initialDraft: text, mode: forceReview ? .review : (profile.agentRepromptMode ?? .review),
            currentDraft: { [weak session] in session?.draftText ?? "" },
            applyDraft: { [weak self, weak session] value in
                guard let self, let session, repromptOperation?.id == id,
                      sessions[target.tabID] === session else { return nil }
                session.draftText = value
                return session.draftMutationGeneration
            },
            chooseEffort: { [weak self] model in
                await self?.chooseRepromptEffort(model: model, text: rewriteSource, requestID: id) ?? model
            },
            isCurrent: { [weak self, weak session] in
                guard let self, let session, let operation = repromptOperation, operation.id == id else { return false }
                let live = modelRouterSettingsStore.effectiveAgentModelsProfile(workspaceID: workspaceID)
                let liveMode = workspaceID.map { self.modelRouterSettingsStore.workspaceAgentModelsSettings(for: $0).inheritanceMode }
                return sessions[target.tabID] === session && currentTabID == target.tabID
                    && workspaceManager?.activeWorkspaceID == workspaceID
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
                    && (workspaceManager?.activeWorkspace?.repoPaths ?? []) == roots
            }
        )
        repromptOperation = operation
        operation.onComplete = { [weak self, weak operation, weak session] brief in
            guard let self, let operation, let session else { return }
            startRepromptSpeculation(session: session, operationID: operation.id, text: brief, originalText: operation.rawDraft)
        }
        operation.onStateChange = { [weak self] in self?.syncStatusPillsUIState() }
        operation.onEdit = { [weak self] in self?.cancelRepromptSpeculation(claimID: id) }
        operation.onClose = { [weak self] in
            guard let self else { return }
            cancelRepromptSpeculation(claimID: id)
            if repromptOperation?.id == id { repromptOperation = nil }
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
        let eligibilityText: String = if let owned = repromptOperation, owned.sourceTabID == target.tabID, owned.phase == .completed {
            owned.rawDraft // Generated/edited slash-like data is not a staged command.
        } else { text }
        guard let session = sessions[target.tabID], currentTabID == target.tabID,
              makeComposerSubmitTarget(tabID: target.tabID, session: session) == target,
              !isMCPControlled(tabID: target.tabID),
              !Self.repromptBlockingInteractions(session).contains(true),
              Self.isRepromptEligible(text: eligibilityText, hasStagedCommand: stagedSlashCommandProps(tabID: target.tabID) != nil),
              repromptOperation?.phase.isBusy != true else { return false }
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
        guard let operation = repromptOperation, operation.phase == .completed,
              operation.sourceTabID == claim.attempt.sourceTabID,
              sessions[operation.sourceTabID] === claim.sourceSession,
              operation.expectedDraft.utf8.elementsEqual(claim.attempt.rawDraftSnapshot.utf8)
        else {
            let tabID = claim.attempt.sourceTabID
            guard repromptOperation == nil, currentTabID == tabID, sessions[tabID] === claim.sourceSession,
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
        _ = repromptOperation?.validate()
    }

    func cancelReprompt() {
        repromptOperation?.cancel()
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
