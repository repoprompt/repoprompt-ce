import AppKit
import Combine
import Foundation

@MainActor
final class MentionCoordinator: MentionTextViewDelegate {
    private struct LevelState {
        let parent: MentionSuggestion?
        var suggestions: [MentionSuggestion]
        var highlightedIndex: Int
    }

    private struct QueryRequest {
        let query: String
        let parent: MentionSuggestion?
        let preserveIndex: Bool
        let epoch: UInt64
    }

    // MARK: - Init & stored refs

    private unowned let textView: MentionTextView
    private let suggestionService: MentionSuggestionService
    private let overlay = MentionOverlayController()
    private var configuration: FileMentionPickerConfiguration
    private let commitHandler: (MentionSuggestion) -> Void
    private let tokenRemovedHandler: (MentionTokenPayload) -> Void

    init(
        textView: MentionTextView,
        suggestionService: MentionSuggestionService,
        configuration: FileMentionPickerConfiguration = .compact,
        commitHandler: @escaping (MentionSuggestion) -> Void,
        tokenRemovedHandler: @escaping (MentionTokenPayload) -> Void
    ) {
        self.textView = textView
        self.suggestionService = suggestionService
        self.configuration = configuration
        self.commitHandler = commitHandler
        self.tokenRemovedHandler = tokenRemovedHandler
        applyConfiguration(configuration)

        querySubject
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in
                self?.runQuery(request)
            }
            .store(in: &cancellables)

        overlay.onRowClicked = { [weak self] level, index in
            self?.selectSuggestion(at: index, inLevel: level)
        }
    }

    func updateFileManager(_ manager: WorkspaceFilesViewModel?) {
        guard suggestionService.updateFileManager(manager) else { return }
        resetMentionSession(endTextViewSession: true)
    }

    func updateConfiguration(_ configuration: FileMentionPickerConfiguration) {
        guard self.configuration != configuration else { return }
        self.configuration = configuration
        resetMentionSession(endTextViewSession: true)
        applyConfiguration(configuration)
    }

    private func applyConfiguration(_ configuration: FileMentionPickerConfiguration) {
        suggestionService.updateConfiguration(configuration)
        overlay.suggestedWidth = configuration.overlayWidth
        overlay.visibleRowLimit = configuration.visibleRows
    }

    // MARK: - Internal state

    private var levels = [LevelState(parent: nil, suggestions: [], highlightedIndex: 0)]

    private var currentParent: MentionSuggestion? {
        guard let level = levels.last else { return nil }
        return level.parent
    }

    private var currentSuggestions: [MentionSuggestion] {
        levels.last?.suggestions ?? []
    }

    private var currentHighlightedIndex: Int {
        levels.last?.highlightedIndex ?? 0
    }

    private let querySubject = PassthroughSubject<QueryRequest, Never>()
    private var cancellables = Set<AnyCancellable>()
    private var queryEpoch: UInt64 = 0
    #if DEBUG
        private var testPendingDebouncedQuery: QueryRequest?
    #endif
    private var pendingReanchorTask: Task<Void, Never>?
    private var reanchorGeneration: UInt64 = 0

    // MARK: - MentionTextViewDelegate

    func mentionStarted(at caret: NSRect) {
        invalidatePendingQueries()

        let initialSuggestions = suggestionService.suggestions(for: "", under: nil)
        levels = [LevelState(parent: nil, suggestions: initialSuggestions, highlightedIndex: 0)]

        guard !textView.hasMarkedText(), let host = textView.window else {
            overlay.hide()
            return
        }
        overlay.show(at: caret, owner: host, items: initialSuggestions)
        scheduleOverlayReanchor()
    }

    func mentionQueryChanged(_ query: String, parent: MentionSuggestion?) {
        mentionQueryChanged(query, parent: parent, preserveIndex: false)
    }

    func mentionQueryChanged(
        _ query: String,
        parent: MentionSuggestion?,
        preserveIndex: Bool = false
    ) {
        let request = QueryRequest(
            query: query,
            parent: parent,
            preserveIndex: preserveIndex,
            epoch: queryEpoch
        )
        #if DEBUG
            testPendingDebouncedQuery = request
        #endif
        querySubject.send(request)
    }

    func mentionNavigate(_ command: MentionNavigationCommand) {
        guard let currentLevelIndex = levels.indices.last else { return }

        switch command {
        case .up:
            let count = levels[currentLevelIndex].suggestions.count
            levels[currentLevelIndex].highlightedIndex =
                (levels[currentLevelIndex].highlightedIndex - 1 + count) % max(count, 1)
            overlay.moveHighlight(by: -1)
        case .down:
            let count = levels[currentLevelIndex].suggestions.count
            levels[currentLevelIndex].highlightedIndex =
                (levels[currentLevelIndex].highlightedIndex + 1) % max(count, 1)
            overlay.moveHighlight(by: 1)
        case .left:
            guard levels.count > 1 else { return }
            levels.removeLast()
            overlay.popLevel()
            mentionQueryChanged("", parent: currentParent, preserveIndex: true)
        case .right:
            guard currentSuggestions.indices.contains(currentHighlightedIndex) else { return }
            let selectedSuggestion = currentSuggestions[currentHighlightedIndex]
            guard selectedSuggestion.kind == .folder else { return }

            levels.append(LevelState(
                parent: selectedSuggestion,
                suggestions: [],
                highlightedIndex: 0
            ))
            overlay.pushLevel()
            mentionQueryChanged("", parent: selectedSuggestion)
        }
    }

    func mentionAccept() {
        guard currentSuggestions.indices.contains(currentHighlightedIndex) else { return }
        let suggestion = currentSuggestions[currentHighlightedIndex]
        overlay.hide()
        textView.insertMentionToken(suggestion)
        commitHandler(suggestion)
    }

    func mentionAbort() {
        invalidatePendingQueries()
        pendingReanchorTask?.cancel()
        overlay.hide()
    }

    func tokenRemoved(_ payload: MentionTokenPayload) {
        tokenRemovedHandler(payload)
    }

    deinit {
        pendingReanchorTask?.cancel()
        let overlay = self.overlay
        Task { @MainActor in
            overlay.hide()
        }
    }

    // MARK: - Private helpers

    private func runQuery(_ request: QueryRequest) {
        guard request.epoch == queryEpoch else { return }
        guard !textView.hasMarkedText() else {
            overlay.hide()
            return
        }

        let parent = request.parent ?? currentParent
        let suggestions = suggestionService.suggestions(for: request.query, under: parent)
        let desiredIndex = request.preserveIndex ? currentHighlightedIndex : 0
        let highlightedIndex = suggestions.isEmpty
            ? 0
            : min(max(desiredIndex, 0), suggestions.count - 1)

        if let currentLevelIndex = levels.indices.last {
            levels[currentLevelIndex].suggestions = suggestions
            levels[currentLevelIndex].highlightedIndex = highlightedIndex
        } else {
            levels = [LevelState(
                parent: parent,
                suggestions: suggestions,
                highlightedIndex: highlightedIndex
            )]
        }

        overlay.update(items: suggestions, highlighted: highlightedIndex)
        guard textView.window != nil else {
            overlay.hide()
            return
        }
        scheduleOverlayReanchor()
    }

    private func selectSuggestion(at index: Int, inLevel level: Int) {
        guard levels.indices.contains(level),
              levels[level].suggestions.indices.contains(index)
        else { return }

        invalidatePendingQueries()
        levels = Array(levels.prefix(level + 1))
        levels[level].highlightedIndex = index
    }

    private func invalidatePendingQueries() {
        queryEpoch &+= 1
    }

    private func resetMentionSession(endTextViewSession: Bool) {
        invalidatePendingQueries()
        pendingReanchorTask?.cancel()
        levels = [LevelState(parent: nil, suggestions: [], highlightedIndex: 0)]
        overlay.hide()
        if endTextViewSession {
            textView.endMentionSession()
        }
    }

    private func scheduleOverlayReanchor() {
        pendingReanchorTask?.cancel()
        reanchorGeneration &+= 1
        let generation = reanchorGeneration

        pendingReanchorTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            guard !Task.isCancelled else { return }
            guard generation == reanchorGeneration else { return }
            guard !textView.hasMarkedText() else {
                overlay.hide()
                return
            }
            guard textView.window != nil else {
                overlay.hide()
                return
            }
            let displaySelectionRange = textView.clampSelectionToCurrentString()
            let caretRect = textView.firstRect(
                forCharacterRange: displaySelectionRange,
                actualRange: nil
            )
            overlay.repositionRoot(to: caretRect)
        }
    }

    #if DEBUG
        var testSuggestions: [MentionSuggestion] {
            currentSuggestions
        }

        var testOverlayWindowCount: Int {
            overlay.testWindowCount
        }

        func testSuggestions(atLevel level: Int) -> [MentionSuggestion] {
            guard levels.indices.contains(level) else { return [] }
            return levels[level].suggestions
        }

        func testHighlightedIndex(atLevel level: Int) -> Int? {
            guard levels.indices.contains(level) else { return nil }
            return levels[level].highlightedIndex
        }

        @discardableResult
        func testFlushPendingDebouncedQuery(cancelScheduledEmission: Bool = true) -> Bool {
            guard let request = testPendingDebouncedQuery else { return false }
            testPendingDebouncedQuery = nil
            runQuery(request)
            if cancelScheduledEmission {
                invalidatePendingQueries()
            }
            return true
        }

        func testClickOverlayRow(level: Int, index: Int) {
            overlay.clickRowForTesting(level: level, index: index)
        }
    #endif
}
