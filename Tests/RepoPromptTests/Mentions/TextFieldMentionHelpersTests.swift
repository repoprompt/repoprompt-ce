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
}

@MainActor
private final class DelayedSuggestionProvider {
    let initial: [MentionSuggestion]
    let refreshed: [MentionSuggestion]
    private var continuation: CheckedContinuation<[MentionSuggestion], Never>?
    private(set) var callCount = 0

    init(initial: [MentionSuggestion], refreshed: [MentionSuggestion]) {
        self.initial = initial
        self.refreshed = refreshed
    }

    func suggestions(for _: String) async -> [MentionSuggestion] {
        callCount += 1
        if callCount == 1 {
            return initial
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func completeRefresh() {
        continuation?.resume(returning: refreshed)
        continuation = nil
    }
}
