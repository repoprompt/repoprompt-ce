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

    func testSlashSkillConfigurationOutcomeOnlyActivatesOnAnOffToOnTransition() {
        XCTAssertEqual(
            SlashSkillMentionHelper.configurationOutcome(
                enabled: true,
                hasSuggestionsProvider: true,
                isProviderConfigured: false
            ),
            .activate
        )
        XCTAssertEqual(
            SlashSkillMentionHelper.configurationOutcome(
                enabled: true,
                hasSuggestionsProvider: true,
                isProviderConfigured: true
            ),
            .adoptProvider
        )
        XCTAssertEqual(
            SlashSkillMentionHelper.configurationOutcome(
                enabled: false,
                hasSuggestionsProvider: true,
                isProviderConfigured: true
            ),
            .deactivate
        )
        XCTAssertEqual(
            SlashSkillMentionHelper.configurationOutcome(
                enabled: true,
                hasSuggestionsProvider: false,
                isProviderConfigured: true
            ),
            .deactivate
        )
    }

    func testSlashSkillFirstConfigureRefreshesSuggestionsOnce() async {
        let textView = Self.makeSlashTriggerTextView()
        let provider = CountingSlashSkillProvider()
        let helper = SlashSkillMentionHelper()

        await provider.expectRequest(in: self, description: "first configure refresh") {
            helper.configure(textView: textView, enabled: true, suggestionsProvider: provider.suggestions)
        }

        XCTAssertEqual(provider.requestCount, 1)
    }

    func testSlashSkillRepeatedConfigureDoesNotRefreshPerRender() async {
        let textView = Self.makeSlashTriggerTextView()
        let provider = CountingSlashSkillProvider()
        let helper = SlashSkillMentionHelper()

        await provider.expectRequest(in: self, description: "first configure refresh") {
            helper.configure(textView: textView, enabled: true, suggestionsProvider: provider.suggestions)
        }

        // SwiftUI reruns updateNSView on every keystroke with a freshly allocated provider closure.
        await provider.expectNoRequest(in: self, description: "per-keystroke rerender refresh") {
            for _ in 0 ..< 8 {
                helper.configure(
                    textView: textView,
                    enabled: true,
                    suggestionsProvider: provider.suggestions
                )
            }
        }

        XCTAssertEqual(provider.requestCount, 1)
    }

    func testSlashSkillReenablingAfterDisableRefreshesAgain() async {
        let textView = Self.makeSlashTriggerTextView()
        let provider = CountingSlashSkillProvider()
        let helper = SlashSkillMentionHelper()

        await provider.expectRequest(in: self, description: "first configure refresh") {
            helper.configure(textView: textView, enabled: true, suggestionsProvider: provider.suggestions)
        }

        await provider.expectNoRequest(in: self, description: "disabled refresh") {
            helper.configure(textView: textView, enabled: false, suggestionsProvider: nil)
        }

        await provider.expectRequest(in: self, description: "re-enable refresh") {
            helper.configure(textView: textView, enabled: true, suggestionsProvider: provider.suggestions)
        }

        XCTAssertEqual(provider.requestCount, 2)
    }

    func testSlashSkillAdoptsReplacementProviderOnTheNextRefresh() async {
        let textView = Self.makeSlashTriggerTextView()
        let original = CountingSlashSkillProvider()
        let replacement = CountingSlashSkillProvider()
        let helper = SlashSkillMentionHelper()

        await original.expectRequest(in: self, description: "first configure refresh") {
            helper.configure(textView: textView, enabled: true, suggestionsProvider: original.suggestions)
        }

        helper.configure(textView: textView, enabled: true, suggestionsProvider: replacement.suggestions)
        await replacement.expectRequest(in: self, description: "replacement provider refresh") {
            helper.scheduleRefresh(for: textView, immediate: true, enabled: true, isActive: true)
        }

        XCTAssertEqual(original.requestCount, 1)
        XCTAssertEqual(replacement.requestCount, 1)
    }

    private static func makeSlashTriggerTextView() -> ImageAwareTextView {
        let textView = ImageAwareTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        textView.string = "/de"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        return textView
    }
}

@MainActor
private final class CountingSlashSkillProvider {
    private(set) var requestCount = 0
    private var onRequest: (() -> Void)?

    func suggestions(for _: String) async -> [MentionSuggestion] {
        requestCount += 1
        onRequest?()
        return []
    }

    /// Runs `operation` and waits for exactly one suggestions request to land.
    func expectRequest(
        in testCase: XCTestCase,
        description: String,
        operation: () -> Void
    ) async {
        let expectation = testCase.expectation(description: description)
        expectation.assertForOverFulfill = true
        onRequest = { expectation.fulfill() }
        defer { onRequest = nil }
        operation()
        await testCase.fulfillment(of: [expectation], timeout: 2)
    }

    /// Runs `operation` and asserts no suggestions request lands, waiting past the typing debounce.
    func expectNoRequest(
        in testCase: XCTestCase,
        description: String,
        operation: () -> Void
    ) async {
        let expectation = testCase.expectation(description: description)
        expectation.isInverted = true
        onRequest = { expectation.fulfill() }
        defer { onRequest = nil }
        operation()
        await testCase.fulfillment(of: [expectation], timeout: 0.3)
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
