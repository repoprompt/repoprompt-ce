import Combine
import Foundation
import RepoPromptSettingsCore

/// Preparation owns draft revisions, never a submit claim or provider-history row.
@MainActor
final class AgentRepromptOperation {
    let id: UUID
    let sourceTabID: UUID
    let rawDraft: String
    let model: AIModel?
    private let store: AgentRepromptUIStore
    private let service: AgentRepromptService?
    private let initialError: AgentRepromptError?
    private let isCurrent: () -> Bool
    private let applyDraft: (String) -> UInt64?
    private let currentDraft: () -> String
    private let chooseEffort: (AIModel) async -> AIModel
    private var request: AgentRepromptRequest
    private var firstResult: AgentRepromptResult?
    private var task: Task<Void, Never>?
    private var publicationTask: Task<Void, Never>?
    private var validationTask: Task<Void, Never>?
    private(set) var hasUserEdits = false
    private var pendingBody: String?
    private var callRevision: UInt64 = 0
    private var publicationRevision: UInt64 = 0
    private(set) var expectedDraft: String
    private(set) var expectedDraftGeneration: UInt64
    private(set) var isPublishing = false
    private(set) var isClosed = false
    private(set) var lastGeneratedText = ""
    private(set) var usedOriginal = false
    private(set) var hadQuestions = false
    private(set) var autoSendConsumed = false
    let mode: AgentRepromptMode
    var onStateChange: (() -> Void)?
    var observations = Set<AnyCancellable>()
    var onComplete: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onEdit: (() -> Void)?
    var phase: AgentRepromptUIStore.Phase {
        store.presentation?.phase ?? .failed
    }

    init(
        id: UUID = UUID(), sourceTabID: UUID, rawDraft: String, draftGeneration: UInt64,
        request: AgentRepromptRequest, model: AIModel?, service: AgentRepromptService?, store: AgentRepromptUIStore,
        initialError: AgentRepromptError? = nil, initialDraft: String? = nil, mode: AgentRepromptMode = .review,
        currentDraft: @escaping () -> String, applyDraft: @escaping (String) -> UInt64?,
        chooseEffort: @escaping (AIModel) async -> AIModel = { $0 }, isCurrent: @escaping () -> Bool
    ) {
        self.id = id
        self.sourceTabID = sourceTabID
        self.rawDraft = rawDraft
        expectedDraft = initialDraft ?? rawDraft
        self.mode = mode
        expectedDraftGeneration = draftGeneration
        self.request = request
        self.model = model
        self.service = service
        self.initialError = initialError
        self.store = store
        self.currentDraft = currentDraft
        self.applyDraft = applyDraft
        self.chooseEffort = chooseEffort
        self.isCurrent = isCurrent
    }

    func start() {
        guard !isClosed, store.presentation == nil else { return }
        store.presentation = .init(
            id: id,
            sourceTabID: sourceTabID,
            original: rawDraft,
            modelName: model?.displayName ?? "Choose a model",
            usesChatContext: !request.recentChat.isEmpty
        )
        retry()
    }

    /// objectWillChange fires before mutation; one next-turn check covers a burst of publications.
    func scheduleValidation() {
        guard !isClosed, validationTask == nil else { return }
        validationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            validationTask = nil
            _ = validate()
        }
    }

    @discardableResult
    func validate() -> Bool {
        guard !isClosed else { return false }
        guard isCurrent() else {
            invalidate(reason: "The source composer or preparation context changed.")
            return false
        }
        return true
    }

    func retry() {
        guard validate(), task == nil, phase != .completed else { return }
        let revision = callRevision &+ 1
        callRevision = revision
        setPhase(request.answers == nil ? .generating : .refining)
        store.presentation?.error = nil
        task = Task { [self] in
            do {
                if let initialError { throw initialError }
                guard let model, let service else { throw AgentRepromptError.missingModel }
                // The same ceiling includes the optional effort judgment, not just provider time.
                let race = AgentRepromptCallRace<AgentRepromptResult>()
                let result = try await withTaskCancellationHandler {
                    try await race.run(seconds: service.timeoutOverride ?? AgentRepromptService.timeout(for: model.providerType)) { @MainActor [self] in
                        let effectiveModel = await chooseEffort(model)
                        guard validate(), !Task.isCancelled, revision == callRevision else { throw CancellationError() }
                        store.presentation?.modelName = effectiveModel.displayName
                        return try await service.generate(request: request, model: effectiveModel) { [weak self] body in
                            try await self?.receive(body, callRevision: revision)
                        }
                    }
                } onCancel: { Task { await race.finish(.failure(CancellationError())) } }
                guard validate(), !Task.isCancelled, revision == callRevision else { return }
                publicationTask?.cancel()
                publicationTask = nil
                pendingBody = nil
                install(result.body)
                lastGeneratedText = result.body
                task = nil
                if request.answers == nil, !result.openQuestions.isEmpty {
                    hadQuestions = true
                    firstResult = result
                    let interaction = AgentAskUserInteraction(title: "Before sending", questions: result.openQuestions.map {
                        .init(id: $0.id, question: $0.question, options: $0.options.map { .init(label: $0.label, description: $0.description) })
                    })
                    store.pendingQuestions = .init(interaction: interaction)
                    setPhase(.clarifying)
                } else { complete() }
            } catch {
                guard validate(), !Task.isCancelled, revision == callRevision else { return }
                publicationTask?.cancel()
                publicationTask = nil
                if let pendingBody { install(pendingBody) }
                pendingBody = nil
                task = nil
                setPhase(.failed)
                store.presentation?.error = (error as? AgentRepromptError)?.errorDescription ?? AgentRepromptError.provider.errorDescription
                store.recover(
                    tabID: sourceTabID,
                    text: lastGeneratedText,
                    originalDraft: rawDraft,
                    reason: "Incomplete rewrite",
                    currentDraft: currentDraft()
                )
            }
        }
    }

    private func receive(_ body: String, callRevision: UInt64) throws {
        guard !Task.isCancelled, !isClosed, self.callRevision == callRevision,
              phase == .generating || phase == .refining, validate() else { throw CancellationError() }
        guard !body.isEmpty, body != lastGeneratedText else { return }
        pendingBody = body
        lastGeneratedText = body
        guard publicationTask == nil else { return }
        publicationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            guard let self, !Task.isCancelled, !isClosed, self.callRevision == callRevision, validate() else { return }
            publicationTask = nil
            if let pendingBody { install(pendingBody) }
            pendingBody = nil
        }
    }

    private func install(_ text: String) {
        isPublishing = true
        defer { isPublishing = false }
        guard let generation = applyDraft(text) else { return }
        expectedDraft = text
        expectedDraftGeneration = generation
        store.presentation?.startsWithProviderCommand = Self.startsWithProviderCommand(text)
        publicationRevision &+= 1
        store.draftUpdate = .init(operationID: id, tabID: sourceTabID, revision: publicationRevision, text: text)
    }

    /// Native editing takes ownership before a keystroke or marked text can race another chunk.
    /// Keep the visible draft in place; its synchronous editor echo records the new generation.
    @discardableResult
    func beginUserEditing() -> Bool {
        guard !isClosed else { return false }
        hasUserEdits = true
        guard validate() else { return false }
        callRevision &+= 1
        task?.cancel()
        task = nil
        publicationTask?.cancel()
        publicationTask = nil
        pendingBody = nil
        autoSendConsumed = true
        if store.pendingQuestions != nil { store.pendingQuestions = nil }
        if store.autoSendRequest != nil { store.autoSendRequest = nil }
        if store.presentation?.error != nil { store.presentation?.error = nil }
        if phase != .completed { setPhase(.completed) }
        onEdit?()
        return true
    }

    func noteUserMutation(text: String, generation: UInt64) {
        guard !isClosed, !isPublishing,
              text != expectedDraft || generation != expectedDraftGeneration else { return }
        expectedDraft = text
        expectedDraftGeneration = generation
        store.presentation?.startsWithProviderCommand = Self.startsWithProviderCommand(text)
        _ = beginUserEditing()
    }

    func updateDraft(questionID: String, draft: AgentAskUserDraft) {
        guard validate(), phase == .clarifying else { return }
        store.pendingQuestions?.draftsByQuestionID[questionID] = draft
    }

    func setQuestionIndex(_ index: Int) {
        guard validate(), let pending = store.pendingQuestions, pending.interaction.questions.indices.contains(index) else { return }
        store.pendingQuestions?.currentQuestionIndex = index
    }

    func completeQuestions(skipAll: Bool = false) {
        guard validate(), task == nil, let firstResult, let pending = store.pendingQuestions else { return }
        let response = skipAll ? pending.interaction.buildSkippedResponse(elapsedSeconds: 0)
            : try? pending.interaction.buildSubmittedResponse(drafts: pending.draftsByQuestionID, elapsedSeconds: 0)
        guard let response else { return }
        let answers: [AgentRepromptRequest.Answer] = pending.interaction.questions.map { question in
            let answer = response.answersByQuestionID[question.id]
            return .init(
                question: question.question,
                selectedOption: answer?.selectedOptions.first,
                customText: answer?.customResponse,
                skipped: answer?.skipped ?? true
            )
        }
        store.pendingQuestions = nil
        if answers.contains(where: { !$0.skipped && ($0.selectedOption != nil || $0.customText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) }) {
            request.answers = answers
            retry()
        } else {
            install(firstResult.body)
            complete()
        }
    }

    private func setPhase(_ phase: AgentRepromptUIStore.Phase) {
        store.presentation?.phase = phase
        onStateChange?()
    }

    /// One terminal auto-send intent. Any clarification, edit, cancellation or stale generation fences it.
    func consumeAutoSend(_ request: AgentRepromptUIStore.AutoSendRequest) -> Bool {
        guard request.operationID == id, request.tabID == sourceTabID, !autoSendConsumed else { return false }
        autoSendConsumed = true
        return mode == .sendAutomatically && !hadQuestions && !usedOriginal && !hasUserEdits && !Self.startsWithProviderCommand(expectedDraft) && phase == .completed
            && request.operationID == id && request.tabID == sourceTabID
            && request.text == expectedDraft && request.text == lastGeneratedText
            && request.generation == expectedDraftGeneration && validate()
    }

    static func startsWithProviderCommand(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
    }

    private func complete() {
        guard validate() else { return }
        setPhase(.completed)
        onComplete?(expectedDraft)
        if mode == .sendAutomatically, !hadQuestions, !Self.startsWithProviderCommand(expectedDraft), !isClosed {
            store.autoSendRequest = .init(operationID: id, tabID: sourceTabID, text: expectedDraft, generation: expectedDraftGeneration)
        }
    }

    /// Explicit keyboard override: freeze exactly what is visible, without another model call.
    /// Cancel and revision-fence streaming before the fresh composer claim can be acquired.
    func useCurrentDraft(_ text: String) {
        // A reviewed draft already owns its exact generation and speculative routing work.
        // Sending it is not an edit, nor an explicit choice to send the original.
        guard validate(), phase != .completed else { return }
        callRevision &+= 1
        task?.cancel()
        task = nil
        publicationTask?.cancel()
        publicationTask = nil
        pendingBody = nil
        store.pendingQuestions = nil
        store.autoSendRequest = nil
        usedOriginal = text == rawDraft
        install(text)
        setPhase(.completed)
        onEdit?()
    }

    func useOriginal() {
        guard validate() else { return }
        store.recover(
            tabID: sourceTabID,
            text: currentDraft(),
            originalDraft: rawDraft,
            reason: "Original selected",
            currentDraft: rawDraft
        )
        callRevision &+= 1
        task?.cancel()
        task = nil
        publicationTask?.cancel()
        publicationTask = nil
        pendingBody = nil
        store.pendingQuestions = nil
        usedOriginal = true
        install(rawDraft)
        setPhase(.completed)
        onEdit?()
    }

    func cancel(restoreOriginal: Bool = true, recover: Bool = true) {
        guard !isClosed else { return }
        let candidate = currentDraft()
        if recover {
            store.recover(
                tabID: sourceTabID,
                text: candidate,
                originalDraft: rawDraft,
                reason: "Original restored",
                currentDraft: restoreOriginal ? rawDraft : candidate
            )
        }
        // Fence callbacks before any restoration; an ignoring transport cannot regain authority.
        isClosed = true
        callRevision &+= 1
        task?.cancel()
        publicationTask?.cancel()
        validationTask?.cancel()
        validationTask = nil
        if restoreOriginal, candidate == expectedDraft { install(rawDraft) }
        if recover { store.rememberCancelledDraft(tabID: sourceTabID, text: currentDraft()) }
        task = nil
        observations.removeAll()
        store.pendingQuestions = nil
        store.autoSendRequest = nil
        store.presentation = nil
        onClose?()
    }

    func invalidate(reason: String) {
        guard !isClosed else { return }
        let live = currentDraft()
        let keepEdits = hasUserEdits || live != expectedDraft
        let alternative = (phase == .completed && hasUserEdits) || lastGeneratedText.isEmpty ? live : lastGeneratedText
        cancel(restoreOriginal: !keepEdits, recover: false)
        store.recover(
            tabID: sourceTabID, text: alternative, originalDraft: rawDraft,
            reason: reason, currentDraft: currentDraft(), requiresDecision: keepEdits
        )
    }
}
