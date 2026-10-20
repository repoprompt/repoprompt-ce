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
    func beginComposerReprompt(target: AgentComposerSubmitTarget, text: String) -> Bool {
        if let operation = repromptOperation, operation.sourceTabID == target.tabID {
            guard operation.validate() else { return true }
            return operation.phase != .completed
        }
        guard repromptEnabled,
              Self.isRepromptEligible(text: text, hasStagedCommand: stagedSlashCommandProps(tabID: target.tabID) != nil),
              !isMCPControlled(tabID: target.tabID) else { return false }
        guard let session = sessions[target.tabID], currentTabID == target.tabID,
              makeComposerSubmitTarget(tabID: target.tabID, session: session) == target else { return true }
        repromptOperation?.invalidate(reason: "Another composer began preparation.")
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
            originalText: text,
            manifest: AgentRepromptModelPolicy.manifest(rootNames: roots.map { URL(fileURLWithPath: $0).lastPathComponent }, selectedPaths: relativePaths),
            guidance: AgentRepromptGuidance.effectiveText(profile.agentRepromptGuidance), recentChat: history
        )
        let model = resolvedRepromptModel(session: session)
        let disclosed = repromptAvailability != nil || !repromptPillProps().requiresDisclosure
        let operation = AgentRepromptOperation(
            id: id, sourceTabID: target.tabID, rawDraft: text, draftGeneration: session.draftMutationGeneration,
            request: request, model: model, service: repromptService, store: repromptUIStore,
            initialError: disclosed ? nil : .disclosureRequired,
            currentDraft: { [weak session] in session?.draftText ?? "" },
            applyDraft: { [weak self, weak session] value in
                guard let self, let session, repromptOperation?.id == id,
                      sessions[target.tabID] === session else { return nil }
                session.draftText = value
                return session.draftMutationGeneration
            },
            chooseEffort: { [weak self] model in
                await self?.chooseRepromptEffort(model: model, text: text, requestID: id) ?? model
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
                    && (profile.agentRepromptModelRaw != AgentRepromptModelPolicy.primaryOracle || live.planningModelRaw == profile.planningModelRaw)
                    && (workspaceManager?.activeWorkspace?.repoPaths ?? []) == roots
            }
        )
        repromptOperation = operation
        operation.onComplete = { [weak self, weak operation, weak session] brief in
            guard let self, let operation, let session else { return }
            startRepromptSpeculation(session: session, operationID: operation.id, text: brief, originalText: operation.rawDraft)
        }
        operation.onEdit = { [weak self] in self?.cancelRepromptSpeculation(claimID: id) }
        operation.onClose = { [weak self] in
            guard let self else { return }
            cancelRepromptSpeculation(claimID: id)
            if repromptOperation?.id == id { repromptOperation = nil }
            syncStatusPillsUIState()
        }
        let check: () -> Void = { [weak operation] in
            Task { @MainActor in await Task.yield()
                _ = operation?.validate()
            }
        }
        session.objectWillChange.sink { _ in check() }.store(in: &operation.observations)
        objectWillChange.sink { _ in check() }.store(in: &operation.observations)
        modelRouterSettingsStore.objectWillChange.sink { _ in check() }.store(in: &operation.observations)
        workspaceManager?.objectWillChange.sink { _ in check() }.store(in: &operation.observations)
        operation.start()
        syncStatusPillsUIState()
        return true
    }

    /// Synchronous transfer at the real, local composer claim boundary, before token publication.
    func adoptRepromptPreparation(into claim: AgentComposerSubmitClaim) {
        guard let operation = repromptOperation, operation.phase == .completed,
              operation.sourceTabID == claim.attempt.sourceTabID,
              sessions[operation.sourceTabID] === claim.sourceSession,
              operation.expectedDraft.utf8.elementsEqual(claim.attempt.rawDraftSnapshot.utf8) else { return }
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
        repromptOperation?.cancel()
    }

    /// "Send original" prepares the unchanged draft for the next Send; it never auto-dispatches.
    func useRepromptOriginal() {
        guard let operation = repromptOperation, operation.validate() else { return }
        operation.useOriginal()
    }
}
