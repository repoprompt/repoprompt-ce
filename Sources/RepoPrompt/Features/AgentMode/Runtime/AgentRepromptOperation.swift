import Combine
import Foundation

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
    private var pendingBody: String?
    private var callRevision: UInt64 = 0
    private var publicationRevision: UInt64 = 0
    private(set) var expectedDraft: String
    private(set) var expectedDraftGeneration: UInt64
    private(set) var isPublishing = false
    private(set) var isClosed = false
    private(set) var lastGeneratedText = ""
    private(set) var usedOriginal = false
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
        initialError: AgentRepromptError? = nil,
        currentDraft: @escaping () -> String, applyDraft: @escaping (String) -> UInt64?,
        chooseEffort: @escaping (AIModel) async -> AIModel = { $0 }, isCurrent: @escaping () -> Bool
    ) {
        self.id = id
        self.sourceTabID = sourceTabID
        self.rawDraft = rawDraft
        expectedDraft = rawDraft
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
            modelName: model?.displayName ?? "Unavailable model",
            usesChatContext: !request.recentChat.isEmpty
        )
        retry()
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
        store.presentation?.phase = request.answers == nil ? .generating : .refining
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
                    firstResult = result
                    let interaction = AgentAskUserInteraction(title: "Before sending", questions: result.openQuestions.map {
                        .init(id: $0.id, question: $0.question, options: $0.options.map { .init(label: $0.label, description: $0.description) })
                    })
                    store.pendingQuestions = .init(interaction: interaction)
                    store.presentation?.phase = .clarifying
                } else { complete() }
            } catch {
                guard validate(), !Task.isCancelled, revision == callRevision else { return }
                publicationTask?.cancel()
                publicationTask = nil
                if let pendingBody { install(pendingBody) }
                pendingBody = nil
                task = nil
                store.presentation?.phase = .failed
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
        publicationRevision &+= 1
        store.draftUpdate = .init(operationID: id, tabID: sourceTabID, revision: publicationRevision, text: text)
    }

    func noteUserMutation(text: String, generation: UInt64) {
        guard !isClosed, !isPublishing else { return }
        if phase == .completed {
            expectedDraft = text
            expectedDraftGeneration = generation
            onEdit?()
        } else if text != expectedDraft || generation != expectedDraftGeneration {
            invalidate(reason: "The draft changed during preparation.")
        }
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

    private func complete() {
        guard validate() else { return }
        store.presentation?.phase = .completed
        onComplete?(expectedDraft)
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
        store.presentation?.phase = .completed
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
        if restoreOriginal, candidate == expectedDraft { install(rawDraft) }
        task = nil
        observations.removeAll()
        store.pendingQuestions = nil
        store.presentation = nil
        onClose?()
    }

    func invalidate(reason: String) {
        guard !isClosed else { return }
        store.recover(
            tabID: sourceTabID,
            text: phase == .completed ? expectedDraft : lastGeneratedText,
            originalDraft: rawDraft,
            reason: reason,
            currentDraft: currentDraft()
        )
        cancel(restoreOriginal: false, recover: false)
    }
}
