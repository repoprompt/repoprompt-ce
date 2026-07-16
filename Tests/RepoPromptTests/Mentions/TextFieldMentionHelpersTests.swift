import AppKit
@testable import RepoPromptApp
import XCTest

@MainActor
final class TextFieldMentionHelpersTests: XCTestCase {
    func testFileTagClickThenAcceptCommitsClickedSuggestion() {
        let first = MentionSuggestion(
            displayName: "First.swift",
            relativePath: "Sources/First.swift",
            kind: .file
        )
        let second = MentionSuggestion(
            displayName: "Second.swift",
            relativePath: "Sources/Second.swift",
            kind: .file
        )
        let textView = ImageAwareTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        textView.string = "@s"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        let helper = FileTagMentionHelper()
        helper.setSelectionStateForTesting(
            suggestions: [first, second],
            highlightedIndex: 0,
            triggerRange: NSRange(location: 0, length: 2)
        )
        var committed: MentionSuggestion?

        helper.clickSuggestionForTesting(at: 1)
        let handled = helper.handleCommandIfNeeded(
            textView: textView,
            commandSelector: #selector(NSResponder.insertTab(_:)),
            enabled: true,
            onCommit: { committed = $0 }
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(committed, second)
        XCTAssertEqual(textView.string, "@Sources/Second.swift ")
    }

    func testSlashSkillClickSurvivesDelayedRefreshCompletionBeforeAccept() async throws {
        let first = MentionSuggestion(
            displayName: "/first",
            relativePath: "first",
            kind: .skill
        )
        let clicked = MentionSuggestion(
            displayName: "/clicked",
            relativePath: "clicked",
            kind: .skill
        )
        let refreshed = MentionSuggestion(
            displayName: "/refreshed",
            relativePath: "refreshed",
            kind: .skill
        )
        let provider = DelayedSuggestionProvider(initial: [first, clicked], refreshed: [refreshed])
        let owner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        defer { owner.orderOut(nil) }
        let textView = ImageAwareTextView(frame: NSRect(x: 20, y: 20, width: 300, height: 80))
        textView.string = "/c"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        owner.contentView = textView
        let helper = SlashSkillMentionHelper()
        helper.configure(
            textView: textView,
            enabled: true,
            suggestionsProvider: { query in await provider.suggestions(for: query) }
        )
        try await waitUntil { helper.suggestionsForTesting == [first, clicked] }

        helper.scheduleRefresh(for: textView, immediate: true, enabled: true, isActive: true)
        try await waitUntil { provider.callCount == 2 }
        helper.clickSuggestionForTesting(at: 1)
        provider.completeRefresh()
        try await waitUntil { provider.completedRefreshCount == 1 }
        XCTAssertEqual(helper.suggestionsForTesting, [first, clicked])

        let handled = helper.handleCommandIfNeeded(
            textView: textView,
            commandSelector: #selector(NSResponder.insertNewline(_:)),
            enabled: true
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(textView.string, "/clicked ")
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        try await AsyncTestWait.waitUntil(
            "text-field mention condition"
        ) { await MainActor.run { condition() } }
    }
}

@MainActor
private final class DelayedSuggestionProvider {
    let initial: [MentionSuggestion]
    let refreshed: [MentionSuggestion]
    private var continuation: CheckedContinuation<[MentionSuggestion], Never>?
    private(set) var callCount = 0
    private(set) var completedRefreshCount = 0

    init(initial: [MentionSuggestion], refreshed: [MentionSuggestion]) {
        self.initial = initial
        self.refreshed = refreshed
    }

    func suggestions(for _: String) async -> [MentionSuggestion] {
        callCount += 1
        if callCount == 1 {
            return initial
        }
        let suggestions = await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        completedRefreshCount += 1
        return suggestions
    }

    func completeRefresh() {
        continuation?.resume(returning: refreshed)
        continuation = nil
    }
}
