import AppKit
import Foundation

@MainActor
final class FileTagMentionHelper {
    private let overlay: MentionOverlayController = {
        let overlay = MentionOverlayController()
        overlay.placement = .above
        return overlay
    }()

    private var suggestions: [MentionSuggestion] = []
    private var highlightedIndex = 0
    private var triggerRange: NSRange?
    private var service: AgentFileTagSuggestionService?
    private weak var fileTagStore: WorkspaceFileContextStore?
    private var fileTagSearchService: WorkspaceSearchService?
    private weak var fileTagSelectionCoordinator: WorkspaceSelectionCoordinator?
    private var fileTagLookupContextIdentity: AnyHashable?
    private var fileTagLookupContextProvider: (() async -> WorkspaceLookupContext)?
    private var configuration: FileMentionPickerConfiguration = .compact
    private var refreshTask: Task<Void, Never>?
    private var suggestionTask: Task<Void, Never>?
    private var commitFinalizationTask: Task<Void, Never>?
    private var suggestionRequestID: UInt64 = 0
    private var isFinalizingCommittedMention = false
    private static let typingDebounceNanoseconds: UInt64 = 45_000_000

    init() {
        overlay.onRowClicked = { [weak self] _, index in
            self?.selectSuggestion(at: index)
        }
    }

    func configure(
        textView: ImageAwareTextView,
        enabled: Bool,
        store: WorkspaceFileContextStore?,
        searchService: WorkspaceSearchService?,
        selectionCoordinator: WorkspaceSelectionCoordinator?,
        lookupContextIdentity: AnyHashable?,
        lookupContextProvider: (() async -> WorkspaceLookupContext)?,
        configuration: FileMentionPickerConfiguration
    ) {
        guard enabled else {
            let hadState = (service != nil || fileTagStore != nil || triggerRange != nil || refreshTask != nil || suggestionTask != nil)
            service = nil
            fileTagStore = nil
            fileTagSearchService = nil
            fileTagSelectionCoordinator = nil
            fileTagLookupContextIdentity = nil
            fileTagLookupContextProvider = nil
            self.configuration = .compact
            if hadState {
                dismiss()
            }
            return
        }

        var shouldRefreshNow = false
        let lookupContextChanged = lookupContextIdentity != fileTagLookupContextIdentity
        let configurationChanged = configuration != self.configuration
        if lookupContextChanged || configurationChanged {
            dismiss()
        }
        overlay.suggestedWidth = configuration.overlayWidth
        overlay.visibleRowLimit = configuration.visibleRows
        if service == nil || store !== fileTagStore || searchService !== fileTagSearchService || selectionCoordinator !== fileTagSelectionCoordinator || lookupContextChanged || configurationChanged {
            service = AgentFileTagSuggestionService(
                store: store,
                searchService: searchService,
                selectionCoordinator: selectionCoordinator,
                lookupContextProvider: lookupContextProvider,
                maxResults: configuration.maxResults,
                showsFileSubtitles: configuration.showsFileSubtitles
            )
            fileTagStore = store
            fileTagSearchService = searchService
            fileTagSelectionCoordinator = selectionCoordinator
            fileTagLookupContextIdentity = lookupContextIdentity
            fileTagLookupContextProvider = lookupContextProvider
            self.configuration = configuration
            shouldRefreshNow = true
        }
        if shouldRefreshNow {
            scheduleRefresh(for: textView, immediate: true, enabled: enabled, isActive: true)
        }
    }

    func scheduleRefresh(
        for textView: NSTextView,
        immediate: Bool,
        enabled: Bool,
        isActive: Bool
    ) {
        guard !isFinalizingCommittedMention else {
            refreshTask?.cancel()
            refreshTask = nil
            return
        }
        refreshTask?.cancel()
        let delay = immediate ? UInt64(0) : Self.typingDebounceNanoseconds
        refreshTask = Task { @MainActor [weak self, weak textView] in
            guard let self else { return }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled, isActive, let textView else { return }
            refreshSuggestions(for: textView, enabled: enabled)
        }
    }

    func handleCommandIfNeeded(
        textView: NSTextView,
        commandSelector: Selector,
        enabled: Bool,
        onCommit: ((MentionSuggestion) -> Void)?
    ) -> Bool {
        guard enabled, triggerRange != nil else { return false }

        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            guard !suggestions.isEmpty else { return false }
            highlightedIndex = (highlightedIndex - 1 + suggestions.count) % suggestions.count
            overlay.moveHighlight(by: -1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            guard !suggestions.isEmpty else { return false }
            highlightedIndex = (highlightedIndex + 1) % suggestions.count
            overlay.moveHighlight(by: 1)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss()
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) ||
            commandSelector == #selector(NSResponder.insertNewline(_:))
        {
            guard !suggestions.isEmpty else {
                dismiss()
                return false
            }
            commitHighlighted(in: textView, onCommit: onCommit)
            return true
        }
        return false
    }

    private func selectSuggestion(at index: Int) {
        guard suggestions.indices.contains(index) else { return }
        refreshTask?.cancel()
        refreshTask = nil
        suggestionTask?.cancel()
        suggestionTask = nil
        suggestionRequestID &+= 1
        highlightedIndex = index
    }

    #if DEBUG
        func setSelectionStateForTesting(
            suggestions: [MentionSuggestion],
            highlightedIndex: Int,
            triggerRange: NSRange
        ) {
            self.suggestions = suggestions
            self.highlightedIndex = highlightedIndex
            self.triggerRange = triggerRange
        }

        func clickSuggestionForTesting(at index: Int) {
            overlay.onRowClicked?(0, index)
        }
    #endif

    func dismiss() {
        refreshTask?.cancel()
        refreshTask = nil
        suggestionTask?.cancel()
        suggestionTask = nil
        commitFinalizationTask?.cancel()
        commitFinalizationTask = nil
        isFinalizingCommittedMention = false
        suggestionRequestID &+= 1
        overlay.hide()
        suggestions.removeAll()
        highlightedIndex = 0
        triggerRange = nil
    }

    private struct TriggerState {
        let range: NSRange
        let query: String
        let overlayWasVisible: Bool
    }

    private func refreshSuggestions(for textView: NSTextView, enabled: Bool) {
        guard enabled else {
            dismiss()
            return
        }
        guard !textView.hasMarkedText() else {
            dismiss()
            return
        }
        guard let trigger = detectTrigger(in: textView) else {
            dismiss()
            return
        }
        guard let service else {
            dismiss()
            return
        }

        let overlayWasVisible = trigger.overlayWasVisible
        let requestedQuery = trigger.query
        let expectedRange = trigger.range
        highlightedIndex = 0
        triggerRange = trigger.range

        suggestionTask?.cancel()
        suggestionRequestID &+= 1
        let requestID = suggestionRequestID
        suggestionTask = Task { @MainActor [weak self, weak textView] in
            guard let self else { return }
            let freshSuggestions = await service.suggestions(for: requestedQuery)
            guard !Task.isCancelled,
                  suggestionRequestID == requestID
            else { return }
            guard let textView else { return }
            guard enabled, !textView.hasMarkedText() else {
                dismiss()
                return
            }
            guard let latestTrigger = detectTrigger(in: textView),
                  latestTrigger.query == requestedQuery,
                  latestTrigger.range == expectedRange
            else { return }

            suggestions = freshSuggestions
            highlightedIndex = 0
            triggerRange = latestTrigger.range

            guard let ownerWindow = textView.window else {
                dismiss()
                return
            }
            let caretRect = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
            if overlayWasVisible {
                overlay.update(items: suggestions, highlighted: highlightedIndex)
                overlay.repositionRoot(to: caretRect)
            } else {
                overlay.show(at: caretRect, owner: ownerWindow, items: suggestions)
                overlay.update(items: suggestions, highlighted: highlightedIndex)
            }
        }
    }

    private func detectTrigger(in textView: NSTextView) -> TriggerState? {
        let selectedRange = textView.selectedRange()
        guard selectedRange.length == 0 else { return nil }

        let fullText = textView.string as NSString
        let cursor = selectedRange.location
        guard cursor != NSNotFound, cursor <= fullText.length else { return nil }
        guard cursor > 0 else { return nil }

        var cursorIndex = cursor - 1
        let whitespace = CharacterSet.whitespacesAndNewlines

        while cursorIndex >= 0 {
            let character = fullText.character(at: cursorIndex)
            if let scalar = UnicodeScalar(UInt32(character)), whitespace.contains(scalar) {
                return nil
            }
            if character == 64 { // "@"
                if cursorIndex > 0 {
                    let previous = fullText.character(at: cursorIndex - 1)
                    if let prevScalar = UnicodeScalar(UInt32(previous)),
                       !whitespace.contains(prevScalar)
                    {
                        return nil
                    }
                }
                let queryRange = NSRange(location: cursorIndex + 1, length: cursor - cursorIndex - 1)
                let query = fullText.substring(with: queryRange)
                let lowered = query.lowercased()
                if lowered.hasPrefix("/") || lowered.hasPrefix("~") || lowered.hasPrefix("file://") {
                    return nil
                }
                return TriggerState(
                    range: NSRange(location: cursorIndex, length: cursor - cursorIndex),
                    query: query,
                    overlayWasVisible: triggerRange != nil
                )
            }
            cursorIndex -= 1
        }

        return nil
    }

    private func commitHighlighted(in textView: NSTextView, onCommit: ((MentionSuggestion) -> Void)?) {
        guard !suggestions.isEmpty else {
            dismiss()
            return
        }
        guard suggestions.indices.contains(highlightedIndex) else {
            dismiss()
            return
        }
        guard let triggerRange else {
            dismiss()
            return
        }

        let suggestion = suggestions[highlightedIndex]
        let replacement = Self.committedReplacementText(for: suggestion)
        let insertionPoint = Self.committedInsertionPoint(
            triggerRange: triggerRange,
            replacement: replacement
        )
        let fullTextLength = (textView.string as NSString).length
        guard NSMaxRange(triggerRange) <= fullTextLength else {
            dismiss()
            return
        }

        // Clear stale trigger/menu state before mutating the text view, then suppress
        // refreshes caused by the replacement, binding write, onCommit state changes,
        // and final selection move. Without this suppression the old trigger range can
        // schedule a refresh before SwiftUI/AppKit settle the committed text selection.
        beginCommittedMentionFinalization()
        textView.textStorage?.replaceCharacters(in: triggerRange, with: replacement)
        textView.didChangeText()
        onCommit?(suggestion)
        positionCaretAfterCommittedReplacement(in: textView, insertionPoint: insertionPoint)
        deferCaretPlacementAfterCommit(in: textView, insertionPoint: insertionPoint)
    }

    static func committedReplacementText(for suggestion: MentionSuggestion) -> String {
        if let commitDisplayText = suggestion.commitDisplayText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !commitDisplayText.isEmpty
        {
            return "@\(escapePathForAtCommand(commitDisplayText)) "
        }
        return "@\(escapePathForAtCommand(suggestion.relativePath)) "
    }

    static func committedInsertionPoint(triggerRange: NSRange, replacement: String) -> Int {
        triggerRange.location + (replacement as NSString).length
    }

    private func beginCommittedMentionFinalization() {
        refreshTask?.cancel()
        refreshTask = nil
        suggestionTask?.cancel()
        suggestionTask = nil
        commitFinalizationTask?.cancel()
        commitFinalizationTask = nil
        isFinalizingCommittedMention = true
        suggestionRequestID &+= 1
        overlay.hide()
        suggestions.removeAll()
        highlightedIndex = 0
        triggerRange = nil
    }

    private func deferCaretPlacementAfterCommit(in textView: NSTextView, insertionPoint: Int) {
        commitFinalizationTask?.cancel()
        commitFinalizationTask = Task { @MainActor [weak self, weak textView] in
            await Self.waitForNextMainRunLoopTurn()
            guard let self, let textView, !Task.isCancelled else { return }
            positionCaretAfterCommittedReplacement(in: textView, insertionPoint: insertionPoint)
            await Self.waitForNextMainRunLoopTurn()
            guard !Task.isCancelled else { return }
            positionCaretAfterCommittedReplacement(in: textView, insertionPoint: insertionPoint)
            isFinalizingCommittedMention = false
            commitFinalizationTask = nil
        }
    }

    private static func waitForNextMainRunLoopTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func positionCaretAfterCommittedReplacement(in textView: NSTextView, insertionPoint: Int) {
        let fullTextLength = (textView.string as NSString).length
        let clampedInsertionPoint = min(max(insertionPoint, 0), fullTextLength)
        let range = NSRange(location: clampedInsertionPoint, length: 0)
        if textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    private static func escapePathForAtCommand(_ path: String) -> String {
        var escaped = ""
        for character in path {
            switch character {
            case "\\", " ", ",", ";", "!", "?", "(", ")", "[", "]", "{", "}":
                escaped.append("\\")
                escaped.append(character)
            default:
                escaped.append(character)
            }
        }
        return escaped
    }
}

@MainActor
final class SlashSkillMentionHelper {
    private let overlay: MentionOverlayController = {
        let overlay = MentionOverlayController()
        overlay.placement = .above
        overlay.suggestedWidth = 360
        return overlay
    }()

    private var suggestions: [MentionSuggestion] = []
    private var highlightedIndex = 0
    private var triggerRange: NSRange?
    private var suggestionsProvider: ((String) async -> [MentionSuggestion])?
    private var refreshTask: Task<Void, Never>?
    private var suggestionTask: Task<Void, Never>?
    private var suggestionRequestID: UInt64 = 0
    private var isProviderConfigured = false
    private static let typingDebounceNanoseconds: UInt64 = 45_000_000

    /// What a `configure` call should do, given the previous configuration state.
    enum ConfigurationOutcome: Equatable {
        /// Slash-skill support is off: drop the provider and tear down any live session.
        case deactivate
        /// Support is being turned on: adopt the provider and refresh immediately.
        case activate
        /// Support was already on: adopt the refreshed provider closure but leave any pending
        /// typing debounce and live session untouched.
        case adoptProvider
    }

    /// SwiftUI re-runs `updateNSView` (and therefore `configure`) on every keystroke, handing over a
    /// freshly allocated provider closure each time. Only an off/on transition may force a refresh;
    /// otherwise each keystroke would cancel the typing debounce and issue a redundant suggestions
    /// request on the main actor.
    static func configurationOutcome(
        enabled: Bool,
        hasSuggestionsProvider: Bool,
        isProviderConfigured: Bool
    ) -> ConfigurationOutcome {
        guard enabled, hasSuggestionsProvider else { return .deactivate }
        return isProviderConfigured ? .adoptProvider : .activate
    }

    init() {
        overlay.onRowClicked = { [weak self] _, index in
            self?.selectSuggestion(at: index)
        }
    }

    func configure(
        textView: ImageAwareTextView,
        enabled: Bool,
        suggestionsProvider: ((String) async -> [MentionSuggestion])?
    ) {
        switch Self.configurationOutcome(
            enabled: enabled,
            hasSuggestionsProvider: suggestionsProvider != nil,
            isProviderConfigured: isProviderConfigured
        ) {
        case .deactivate:
            let hadState = isProviderConfigured
                || self.suggestionsProvider != nil
                || triggerRange != nil
                || refreshTask != nil
                || suggestionTask != nil
            self.suggestionsProvider = nil
            isProviderConfigured = false
            if hadState {
                dismiss()
            }
        case .activate:
            self.suggestionsProvider = suggestionsProvider
            isProviderConfigured = true
            scheduleRefresh(for: textView, immediate: true, enabled: enabled, isActive: true)
        case .adoptProvider:
            self.suggestionsProvider = suggestionsProvider
        }
    }

    func scheduleRefresh(
        for textView: NSTextView,
        immediate: Bool,
        enabled: Bool,
        isActive: Bool
    ) {
        refreshTask?.cancel()
        let delay = immediate ? UInt64(0) : Self.typingDebounceNanoseconds
        refreshTask = Task { @MainActor [weak self, weak textView] in
            guard let self else { return }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled, isActive, let textView else { return }
            refreshSuggestions(for: textView, enabled: enabled)
        }
    }

    func handleCommandIfNeeded(
        textView: NSTextView,
        commandSelector: Selector,
        enabled: Bool
    ) -> Bool {
        guard enabled, triggerRange != nil else { return false }

        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            guard !suggestions.isEmpty else { return false }
            highlightedIndex = (highlightedIndex - 1 + suggestions.count) % suggestions.count
            overlay.moveHighlight(by: -1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            guard !suggestions.isEmpty else { return false }
            highlightedIndex = (highlightedIndex + 1) % suggestions.count
            overlay.moveHighlight(by: 1)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss()
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) ||
            commandSelector == #selector(NSResponder.insertNewline(_:))
        {
            guard !suggestions.isEmpty else {
                dismiss()
                return false
            }
            commitHighlighted(in: textView)
            return true
        }
        return false
    }

    private func selectSuggestion(at index: Int) {
        guard suggestions.indices.contains(index) else { return }
        refreshTask?.cancel()
        refreshTask = nil
        suggestionTask?.cancel()
        suggestionTask = nil
        suggestionRequestID &+= 1
        highlightedIndex = index
    }

    #if DEBUG
        var suggestionsForTesting: [MentionSuggestion] {
            suggestions
        }

        func clickSuggestionForTesting(at index: Int) {
            overlay.onRowClicked?(0, index)
        }
    #endif

    func dismiss() {
        refreshTask?.cancel()
        refreshTask = nil
        suggestionTask?.cancel()
        suggestionTask = nil
        suggestionRequestID &+= 1
        overlay.hide()
        suggestions.removeAll()
        highlightedIndex = 0
        triggerRange = nil
    }

    private struct TriggerState {
        let range: NSRange
        let query: String
        let overlayWasVisible: Bool
    }

    private func refreshSuggestions(for textView: NSTextView, enabled: Bool) {
        guard enabled else {
            dismiss()
            return
        }
        guard !textView.hasMarkedText() else {
            dismiss()
            return
        }
        guard let provider = suggestionsProvider else {
            dismiss()
            return
        }
        guard let trigger = detectTrigger(in: textView) else {
            dismiss()
            return
        }

        let overlayWasVisible = trigger.overlayWasVisible
        let requestedQuery = trigger.query
        let expectedRange = trigger.range
        highlightedIndex = 0
        triggerRange = trigger.range

        suggestionTask?.cancel()
        suggestionRequestID &+= 1
        let requestID = suggestionRequestID
        suggestionTask = Task { @MainActor [weak self, weak textView] in
            guard let self else { return }
            let freshSuggestions = await provider(requestedQuery)
            guard !Task.isCancelled,
                  suggestionRequestID == requestID
            else { return }
            guard let textView else { return }
            guard enabled, !textView.hasMarkedText() else {
                dismiss()
                return
            }
            guard let latestTrigger = detectTrigger(in: textView),
                  latestTrigger.query == requestedQuery,
                  latestTrigger.range == expectedRange
            else { return }

            suggestions = freshSuggestions
            highlightedIndex = 0
            triggerRange = latestTrigger.range

            guard let ownerWindow = textView.window else {
                dismiss()
                return
            }
            let caretRect = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
            if overlayWasVisible {
                overlay.update(items: suggestions, highlighted: highlightedIndex)
                overlay.repositionRoot(to: caretRect)
            } else {
                overlay.show(at: caretRect, owner: ownerWindow, items: suggestions)
                overlay.update(items: suggestions, highlighted: highlightedIndex)
            }
        }
    }

    /// Detect a `/` trigger only when it sits at the first non-whitespace position in the text.
    /// This allows literal slashes deeper in the input (file paths, URLs) without opening the overlay.
    private func detectTrigger(in textView: NSTextView) -> TriggerState? {
        let selectedRange = textView.selectedRange()
        guard selectedRange.length == 0 else { return nil }

        let fullText = textView.string as NSString
        let cursor = selectedRange.location
        guard cursor != NSNotFound, cursor <= fullText.length else { return nil }
        guard cursor > 0 else { return nil }

        // Find the first non-whitespace character in the input.
        let whitespace = CharacterSet.whitespacesAndNewlines
        var firstNonWS = 0
        while firstNonWS < fullText.length {
            let ch = fullText.character(at: firstNonWS)
            if let scalar = UnicodeScalar(ch), whitespace.contains(scalar) {
                firstNonWS += 1
                continue
            }
            break
        }

        // The first non-whitespace character must be `/` and the cursor must be past it.
        guard firstNonWS < fullText.length,
              fullText.character(at: firstNonWS) == 47, // "/"
              cursor > firstNonWS
        else { return nil }

        // Ensure the cursor is within or immediately after the skill token (no whitespace gap).
        var cursorIndex = cursor - 1
        while cursorIndex > firstNonWS {
            let character = fullText.character(at: cursorIndex)
            if let scalar = UnicodeScalar(UInt32(character)), whitespace.contains(scalar) {
                return nil
            }
            cursorIndex -= 1
        }

        let queryRange = NSRange(location: firstNonWS + 1, length: cursor - firstNonWS - 1)
        let query = fullText.substring(with: queryRange)
        if query.contains("/") {
            return nil
        }
        return TriggerState(
            range: NSRange(location: firstNonWS, length: cursor - firstNonWS),
            query: query,
            overlayWasVisible: triggerRange != nil
        )
    }

    private func commitHighlighted(in textView: NSTextView) {
        guard !suggestions.isEmpty else {
            dismiss()
            return
        }
        guard suggestions.indices.contains(highlightedIndex) else {
            dismiss()
            return
        }
        guard let triggerRange else {
            dismiss()
            return
        }

        let suggestion = suggestions[highlightedIndex]
        let commandName = suggestion.relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commandName.isEmpty else {
            dismiss()
            return
        }
        let replacement = "/\(commandName) "
        let fullTextLength = (textView.string as NSString).length
        guard NSMaxRange(triggerRange) <= fullTextLength else {
            dismiss()
            return
        }

        textView.textStorage?.replaceCharacters(in: triggerRange, with: replacement)
        let insertionPoint = triggerRange.location + (replacement as NSString).length
        textView.setSelectedRange(NSRange(location: insertionPoint, length: 0))
        textView.didChangeText()
        dismiss()
    }
}
