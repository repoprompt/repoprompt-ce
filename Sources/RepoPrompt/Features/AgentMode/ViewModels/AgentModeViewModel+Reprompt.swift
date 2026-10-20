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

    func prepareComposerReprompt(text: String, claim: AgentComposerSubmitClaim) async -> AgentRepromptOperation.Outcome {
        let tabID = claim.attempt.sourceTabID
        repromptUIStore.recoveries[tabID] = nil
        guard repromptEnabled else { return .original }
        guard Self.isRepromptEligible(text: text, hasStagedCommand: stagedSlashCommandProps(tabID: tabID) != nil) else {
            repromptAudits[claim.attempt.id] = .init(outcome: .bypassed)
            return .original
        }
        guard repromptOperation == nil, composerSubmitClaimIsCurrent(claim) else { return .cancelled }
        let session = claim.sourceSession
        let workspaceID = workspaceManager?.activeWorkspaceID
        let profile = modelRouterSettingsStore.effectiveAgentModelsProfile(workspaceID: workspaceID)
        let mode = workspaceID.map { modelRouterSettingsStore.workspaceAgentModelsSettings(for: $0).inheritanceMode }
        let pending = Self.pendingUserTurnState(from: session)
        let workflowGeneration = session.userWorkflowSelectionMutationGeneration
        let binding = session.persistentSessionBindingIdentity
        let bindingGeneration = session.bindingTransitionGeneration
        let runID = session.runID
        let attemptID = session.activeRunAttemptID
        let runState = session.runState
        let draftGeneration = session.draftMutationGeneration
        let capturedDraft = session.draftText
        let interactions = Self.repromptBlockingInteractions(session)
        let lookupIdentity = agentWorkspaceLookupContextIdentity(tabID: tabID, session: session)
        let workspaceRoots = workspaceManager?.activeWorkspace?.repoPaths ?? []
        let initialSelection = workspaceID.flatMap { workspaceManager?.composeTab(for: .init(workspaceID: $0, tabID: tabID))?.selection }
        let lookup = await agentWorkspaceLookupContext(tabID: tabID, session: session)
        guard composerSubmitClaimIsCurrent(claim), currentTabID == tabID else { return .cancelled }
        let tab = workspaceID.flatMap { workspaceManager?.composeTab(for: .init(workspaceID: $0, tabID: tabID)) }
        var consultant: AgentRepromptContextConsultant?
        if profile.agentRepromptContextPolicy != .never,
           let workspaceID, let tab, let workspace = workspaceManager,
           let prompt = promptManager, let oracle = oracleViewModel, let builder = repromptContextBuilder
        {
            let reviewContext = await prompt.freezePromptGitReviewContext(workspaceID: workspaceID, tabID: tabID, sessionID: session.activeAgentSessionID, bindings: session.worktreeBindings)
            var nested = MCPTabContextSnapshot(
                tabID: tabID, windowID: windowID, workspaceID: workspaceID, promptText: tab.promptText,
                selection: tab.selection, selectedMetaPromptIDs: tab.selectedMetaPromptIDs,
                selectedContextBuilderPromptIDs: tab.contextBuilder.selectedContextBuilderPromptIDs,
                tabName: tab.name, runID: nil, activeAgentSessionID: session.activeAgentSessionID,
                worktreeBindings: session.worktreeBindings, explicitlyBound: true
            )
            nested.frozenLookupContext = lookup
            let oracleContext = OracleViewModel.OracleSendTabContext(
                tabID: tabID, workspaceID: workspaceID, activationPolicy: .background,
                packaging: .init(
                    sourceTabID: tabID, sourceWorkspaceID: workspaceID,
                    sourceSelectionRevision: workspace.selectionRevisionForMCP(workspaceID: workspaceID, tabID: tabID),
                    sourceAgentSessionID: session.activeAgentSessionID, sourceAgentRunID: runID,
                    promptText: tab.promptText, selection: tab.selection,
                    lookupContext: lookup, reviewGitContext: reviewContext, provenance: .direct
                )
            )
            consultant = .live(identity: .init(workspaceID: workspaceID, tabID: tabID), nested: nested, oracleContext: oracleContext, profile: profile, prompt: prompt, workspace: workspace, oracle: oracle, builder: builder)
        }
        let roots = workspaceRoots
        let selectedPaths = (tab?.selection.selectedPaths ?? []) + (tab?.selection.manualCodemapPaths ?? []) + (tab.map { Array($0.selection.slices.keys) } ?? [])
        let relativePaths = selectedPaths.map { path in
            guard let root = roots.first(where: { path.hasPrefix($0 + "/") }) else {
                return path.hasPrefix("/") ? URL(fileURLWithPath: path).lastPathComponent : path
            }
            return URL(fileURLWithPath: root).lastPathComponent + "/" + path.dropFirst(root.count + 1)
        }
        let request = AgentRepromptRequest(
            originalText: text,
            manifest: AgentRepromptContextConsultant.manifest(rootNames: roots.map { URL(fileURLWithPath: $0).lastPathComponent }, selectedPaths: relativePaths),
            guidance: AgentRepromptGuidance.effectiveText(profile.agentRepromptGuidance),
            contextPolicy: profile.agentRepromptContextPolicy ?? .automatic
        )
        let model = profile.planningModelRaw.flatMap(AIModel.fromModelName)
        let available = model.map { repromptAvailability?($0) ?? (promptManager?.mcpOracleIsProviderConfigured(for: $0) == true) } ?? false
        let operation = AgentRepromptOperation(
            sourceTabID: tabID, rawDraft: claim.attempt.rawDraftSnapshot, request: request,
            model: model, service: available ? repromptService : nil, store: repromptUIStore, consultant: consultant,
            initialError: profile.planningModelRaw != nil && model == nil ? .unknownPrimaryModel :
                (repromptAvailability == nil && available && repromptPillProps().requiresDisclosure ? .disclosureRequired : nil),
            currentDraft: { [weak self] in self?.retrieveDraftText(for: tabID) },
            isCurrent: { [weak self, weak consultant] in
                guard let self else { return false }
                let live = modelRouterSettingsStore.effectiveAgentModelsProfile(workspaceID: workspaceID)
                let liveMode = workspaceID.map { self.modelRouterSettingsStore.workspaceAgentModelsSettings(for: $0).inheritanceMode }
                let selection = workspaceID.flatMap { self.workspaceManager?.composeTab(for: .init(workspaceID: $0, tabID: tabID))?.selection }
                return composerSubmitClaimIsCurrent(claim) && currentTabID == tabID
                    && workspaceManager?.activeWorkspaceID == workspaceID
                    && session.persistentSessionBindingIdentity == binding && session.bindingTransitionGeneration == bindingGeneration
                    && session.draftMutationGeneration == draftGeneration && session.draftText == capturedDraft
                    && Self.repromptBlockingInteractions(session) == interactions
                    && agentWorkspaceLookupContextIdentity(tabID: tabID, session: session) == lookupIdentity
                    && (workspaceManager?.activeWorkspace?.repoPaths ?? []) == workspaceRoots
                    && Self.pendingUserTurnState(from: session) == pending
                    && session.userWorkflowSelectionMutationGeneration == workflowGeneration
                    && session.runID == runID && session.activeRunAttemptID == attemptID && session.runState == runState
                    && session.operationAdmissionFailureMessage == nil
                    && liveMode == mode && live.planningModelRaw == profile.planningModelRaw
                    && live.agentRepromptGuidance == profile.agentRepromptGuidance && live.agentRepromptContextPolicy == profile.agentRepromptContextPolicy
                    && (selection == initialSelection || consultant?.committedSelection.map { selection == $0 } == true)
            }
        )
        repromptOperation = operation
        operation.onReview = { [weak self, weak operation] text in
            guard let self, let operation else { return }
            startRepromptSpeculation(claim: claim, operationID: operation.id, text: text)
        }
        operation.onExit = { [weak self, weak operation] outcome in
            guard let self, let operation else { return }
            recordRepromptOutcome(claim: claim, operation: operation, outcome: outcome)
        }
        let check: () -> Void = { [weak operation] in
            Task { @MainActor in await Task.yield()
                _ = operation?.validate()
            }
        }
        objectWillChange.sink { _ in check() }.store(in: &operation.observations)
        session.objectWillChange.sink { _ in check() }.store(in: &operation.observations)
        modelRouterSettingsStore.objectWillChange.sink { _ in check() }.store(in: &operation.observations)
        workspaceManager?.objectWillChange.sink { _ in check() }.store(in: &operation.observations)
        promptManager?.objectWillChange.sink { _ in check() }.store(in: &operation.observations)
        syncStatusPillsUIState()
        let outcome = await operation.prepare()
        if repromptOperation === operation {
            repromptOperation = nil
        }
        syncStatusPillsUIState()
        return outcome
    }

    func invalidateRepromptIfNeeded() {
        _ = repromptOperation?.validate()
    }

    func cancelReprompt() {
        guard let operation = repromptOperation, operation.validate() else { return }
        operation.finish(.cancelled)
    }
}

/// Main-actor lifecycle authority, separate from runtime ask_user and implementing sessions.
@MainActor
final class AgentRepromptOperation {
    enum Outcome { case original, approved(String), cancelled }
    let id = UUID()
    let sourceTabID: UUID
    let rawDraft: String
    private let store: AgentRepromptUIStore
    private let model: AIModel?
    private let service: AgentRepromptService?
    private let isCurrent: () -> Bool
    private let initialError: AgentRepromptError?
    private let currentDraft: () -> String?
    let consultant: AgentRepromptContextConsultant?
    private var request: AgentRepromptRequest
    private var firstResult: AgentRepromptResult?
    private var task: Task<Void, Never>?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private(set) var terminal: Outcome?
    var observations = Set<AnyCancellable>()
    var onReview: ((String) -> Void)?
    var onExit: ((Outcome) -> Void)?

    init(
        sourceTabID: UUID, rawDraft: String, request: AgentRepromptRequest,
        model: AIModel?, service: AgentRepromptService?, store: AgentRepromptUIStore,
        consultant: AgentRepromptContextConsultant?, initialError: AgentRepromptError? = nil,
        currentDraft: @escaping () -> String? = { nil }, isCurrent: @escaping () -> Bool
    ) {
        self.sourceTabID = sourceTabID
        self.rawDraft = rawDraft
        self.request = request
        self.model = model
        self.service = service
        self.store = store
        self.consultant = consultant
        self.isCurrent = isCurrent
        self.initialError = initialError
        self.currentDraft = currentDraft
    }

    func prepare() async -> Outcome {
        await withTaskCancellationHandler {
            if Task.isCancelled {
                finish(.cancelled)
                return .cancelled
            }
            if let terminal {
                return terminal
            }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                store.presentation = .init(id: id, sourceTabID: sourceTabID, original: request.originalText, modelName: model?.displayName ?? "Primary Oracle")
                retry()
            }
        } onCancel: { Task { @MainActor in self.finish(.cancelled) } }
    }

    @discardableResult
    func validate() -> Bool {
        guard terminal == nil else { return false }
        guard isCurrent() else {
            invalidate(reason: "The source composer or preparation context changed.")
            return false
        }
        return true
    }

    func retry() {
        guard validate(), task == nil else { return }
        let refinement = request.answers != nil
        store.presentation?.phase = refinement ? .refining : .generating
        store.presentation?.error = nil
        task = Task { [self] in
            do {
                if let initialError {
                    throw initialError
                }
                guard let model else { throw AgentRepromptError.missingPrimaryModel }
                guard let service else { throw AgentRepromptError.unconfiguredPrimaryModel }
                let result = try await service.generate(request: request, model: model)
                guard validate(), !Task.isCancelled else { return }
                task = nil
                if refinement {
                    review(result)
                    return
                }
                firstResult = result
                consultant?.start(result.contextRequests)
                store.presentation?.consultKinds = result.contextRequests.map(\.kind)
                store.presentation?.contextStartedAt = Date()
                store.presentation?.isGatheringContext = !result.contextRequests.isEmpty
                if result.openQuestions.isEmpty {
                    completeQuestions(skipAll: true)
                } else {
                    let interaction = AgentAskUserInteraction(title: "Clarify your brief", questions: result.openQuestions.map {
                        AgentAskUserQuestion(id: $0.id, question: $0.question, options: $0.options.map { .init(label: $0.label, description: $0.description) })
                    })
                    try interaction.validate()
                    store.pendingQuestions = .init(interaction: interaction)
                    store.presentation?.phase = .clarifying
                }
            } catch {
                guard validate(), !Task.isCancelled else { return }
                task = nil
                store.presentation?.phase = .failed
                store.presentation?.error = (error as? AgentRepromptError)?.errorDescription ?? AgentRepromptError.provider.errorDescription
            }
        }
    }

    func updateDraft(questionID: String, draft: AgentAskUserDraft) {
        guard validate(), store.presentation?.phase == .clarifying else { return }
        store.pendingQuestions?.draftsByQuestionID[questionID] = draft
    }

    func setQuestionIndex(_ index: Int) {
        guard validate(), let pending = store.pendingQuestions,
              pending.interaction.questions.indices.contains(index) else { return }
        store.pendingQuestions?.currentQuestionIndex = index
    }

    func completeQuestions(skipAll: Bool = false) {
        guard validate(), task == nil, let firstResult else { return }
        var answers: [AgentRepromptRequest.Answer] = []
        if let pending = store.pendingQuestions {
            let response = skipAll ? pending.interaction.buildSkippedResponse(elapsedSeconds: 0)
                : try? pending.interaction.buildSubmittedResponse(drafts: pending.draftsByQuestionID, elapsedSeconds: 0)
            guard let response else { return }
            answers = pending.interaction.questions.map { question in
                let answer = response.answersByQuestionID[question.id]
                return .init(question: question.question, selectedOption: answer?.selectedOptions.first, customText: answer?.customResponse, skipped: answer?.skipped ?? true)
            }
        }
        store.pendingQuestions = nil
        store.presentation?.phase = .gatheringContext
        task = Task { [self, answers] in
            let results = await consultant?.results() ?? []
            guard validate(), !Task.isCancelled else { return }
            task = nil
            store.presentation?.consults = results
            store.presentation?.isGatheringContext = false
            let hasAnswer = answers.contains { !$0.skipped && ($0.selectedOption != nil || $0.customText?.isEmpty == false) }
            if hasAnswer || results.contains(where: { $0.status == "success" }) {
                request.answers = answers
                request.consultResults = results
                retry()
            } else {
                review(firstResult)
            }
        }
    }

    func skipContext() {
        guard validate() else { return }
        consultant?.cancel()
        store.presentation?.isGatheringContext = false
    }

    private func review(_ result: AgentRepromptResult) {
        guard validate() else { return }
        store.reviewText = result.renderedBrief
        store.presentation?.hasUnresolvedQuestions = !result.openQuestions.isEmpty
        store.presentation?.phase = .reviewing
        onReview?(result.renderedBrief)
    }

    func approve() {
        guard validate(), store.canApprove else { return }
        finish(.approved(store.reviewText.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func sendOriginal() {
        guard validate() else { return }
        finish(.original)
    }

    func invalidate(reason: String) {
        store.recover(tabID: sourceTabID, originalDraft: rawDraft, reason: reason, currentDraft: currentDraft())
        finish(.cancelled)
    }

    func finish(_ outcome: Outcome) {
        guard terminal == nil else { return }
        terminal = outcome
        task?.cancel()
        task = nil
        if case .approved = outcome {
            consultant?.cancel(keepSelection: true)
        } else {
            consultant?.cancel()
        }
        observations.removeAll()
        store.presentation = nil
        store.pendingQuestions = nil
        onExit?(outcome)
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: outcome)
    }
}
