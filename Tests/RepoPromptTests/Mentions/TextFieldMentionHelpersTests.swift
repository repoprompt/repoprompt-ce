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

    func testSlashEnterPreservesExactCommandEvenWhenAnotherRowIsHighlighted() {
        let textView = Self.makeSlashTriggerTextView()
        textView.string = "/compact"
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        let helper = SlashSkillMentionHelper()
        helper.setSelectionStateForTesting(suggestions: [
            MentionSuggestion(displayName: "/compact-review", relativePath: "compact-review", kind: .skill),
            MentionSuggestion(displayName: "/compact", relativePath: "compact", kind: .skill, submitsOnExactEnter: true)
        ], triggerRange: NSRange(location: 0, length: 8), query: "compact")

        XCTAssertFalse(helper.handleCommandIfNeeded(textView: textView, commandSelector: #selector(NSResponder.insertNewline(_:)), enabled: true))
        XCTAssertEqual(textView.string, "/compact")
        XCTAssertTrue(helper.suggestionsForTesting.isEmpty)
    }

    func testSlashEnterDoesNotAcceptStaleSuggestionsAfterTypingExactCommand() {
        let textView = Self.makeSlashTriggerTextView()
        textView.string = "/compact"
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        let helper = SlashSkillMentionHelper()
        helper.setSelectionStateForTesting(suggestions: [
            MentionSuggestion(displayName: "/code-review", relativePath: "code-review", kind: .skill)
        ], triggerRange: NSRange(location: 0, length: 3), query: "co")

        XCTAssertFalse(helper.handleCommandIfNeeded(textView: textView, commandSelector: #selector(NSResponder.insertNewline(_:)), enabled: true))
        XCTAssertEqual(textView.string, "/compact")
    }

    func testSlashEnterRejectsStaleQueryEvenWhenTokenLengthIsUnchanged() {
        let textView = Self.makeSlashTriggerTextView()
        textView.string = "/compact"
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        let helper = SlashSkillMentionHelper()
        helper.setSelectionStateForTesting(suggestions: [
            MentionSuggestion(displayName: "/collect", relativePath: "collect", kind: .skill)
        ], triggerRange: NSRange(location: 0, length: 8), query: "collect")

        XCTAssertFalse(helper.handleCommandIfNeeded(textView: textView, commandSelector: #selector(NSResponder.insertNewline(_:)), enabled: true))
        XCTAssertEqual(textView.string, "/compact")
    }

    func testSlashPartialEnterAndExactTabStillCompleteSuggestion() {
        for (input, selector) in [("/com", #selector(NSResponder.insertNewline(_:))), ("/compact", #selector(NSResponder.insertTab(_:)))] {
            let textView = Self.makeSlashTriggerTextView()
            textView.string = input
            textView.setSelectedRange(NSRange(location: input.utf16.count, length: 0))
            let helper = SlashSkillMentionHelper()
            helper.setSelectionStateForTesting(suggestions: [
                MentionSuggestion(displayName: "/compact", relativePath: "compact", kind: .skill, submitsOnExactEnter: true)
            ], triggerRange: NSRange(location: 0, length: input.utf16.count), query: String(input.dropFirst()))

            XCTAssertTrue(helper.handleCommandIfNeeded(textView: textView, commandSelector: selector, enabled: true))
            XCTAssertEqual(textView.string, "/compact ")
        }
    }

    func testSlashEnterHonorsArrowSelectedLongerCommand() {
        let textView = Self.makeSlashTriggerTextView()
        textView.string = "/review"
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        let helper = SlashSkillMentionHelper()
        helper.setSelectionStateForTesting(suggestions: [
            MentionSuggestion(displayName: "/review", relativePath: "review", kind: .skill, submitsOnExactEnter: true),
            MentionSuggestion(displayName: "/review-pr", relativePath: "review-pr", kind: .skill, submitsOnExactEnter: true)
        ], triggerRange: NSRange(location: 0, length: 7), query: "review")
        XCTAssertTrue(helper.handleCommandIfNeeded(textView: textView, commandSelector: #selector(NSResponder.moveDown(_:)), enabled: true))
        XCTAssertTrue(helper.handleCommandIfNeeded(textView: textView, commandSelector: #selector(NSResponder.insertNewline(_:)), enabled: true))
        XCTAssertEqual(textView.string, "/review-pr ")
    }

    func testPendingRefreshCannotOverwriteArrowSelection() async throws {
        let textView = Self.makeSlashTriggerTextView()
        textView.string = "/review"
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        let helper = SlashSkillMentionHelper()
        let requested = expectation(description: "pending suggestions request")
        var continuation: CheckedContinuation<[MentionSuggestion], Never>?
        defer {
            continuation?.resume(returning: [])
            helper.dismiss()
        }
        helper.configure(textView: textView, enabled: true, suggestionsProvider: { _ in
            await withCheckedContinuation {
                continuation = $0
                requested.fulfill()
            }
        })
        await fulfillment(of: [requested], timeout: 2)
        let pendingTask = try XCTUnwrap(helper.suggestionTaskForTesting)
        let rows = [
            MentionSuggestion(displayName: "/review", relativePath: "review", kind: .skill, submitsOnExactEnter: true),
            MentionSuggestion(displayName: "/review-pr", relativePath: "review-pr", kind: .skill, submitsOnExactEnter: true)
        ]
        helper.setSelectionStateForTesting(suggestions: rows, triggerRange: NSRange(location: 0, length: 4), query: "rev")
        XCTAssertTrue(helper.handleCommandIfNeeded(textView: textView, commandSelector: #selector(NSResponder.moveDown(_:)), enabled: true))
        continuation?.resume(returning: rows)
        continuation = nil
        await pendingTask.value
        XCTAssertTrue(helper.handleCommandIfNeeded(textView: textView, commandSelector: #selector(NSResponder.insertNewline(_:)), enabled: true))
        XCTAssertEqual(textView.string, "/review-pr ")
    }

    func testStalePartialEnterAndTabStillCompleteMatchingRow() {
        for path in ["review", "skill:review", "code-review"] {
            for selector in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:))] {
                let textView = Self.makeSlashTriggerTextView()
                textView.string = "/rev"
                textView.setSelectedRange(NSRange(location: 4, length: 0))
                let helper = SlashSkillMentionHelper()
                helper.setSelectionStateForTesting(suggestions: [
                    MentionSuggestion(displayName: "/\(path)", relativePath: path, kind: .skill)
                ], triggerRange: NSRange(location: 0, length: 3), query: "re")
                XCTAssertTrue(helper.handleCommandIfNeeded(textView: textView, commandSelector: selector, enabled: true))
                XCTAssertEqual(textView.string, "/\(path) ")
            }
        }
    }

    func testCodexComputerUseExactEnterStillCompletesInsteadOfSending() {
        let textView = Self.makeSlashTriggerTextView()
        textView.string = "/computer-use"
        textView.setSelectedRange(NSRange(location: 13, length: 0))
        let helper = SlashSkillMentionHelper()
        helper.setSelectionStateForTesting(suggestions: [
            MentionSuggestion(displayName: "/computer-use", relativePath: "computer-use", kind: .skill)
        ], triggerRange: NSRange(location: 0, length: 13), query: "computer-use")
        XCTAssertTrue(helper.handleCommandIfNeeded(textView: textView, commandSelector: #selector(NSResponder.insertNewline(_:)), enabled: true))
        XCTAssertEqual(textView.string, "/computer-use ")
    }

    func testClaudeArgumentHintAndRuntimeSkillKeepExactEnterInCompletion() {
        let rows = AgentModeViewModel.claudeSlashCommandSuggestions(for: "", runtimeCommands: [
            .init(name: "review", description: "Review file", argumentHint: "<file>", builtin: true),
            .init(name: "review-skill", description: "Skill", argumentHint: "")
        ], canCompact: false)
        for row in rows {
            let textView = Self.makeSlashTriggerTextView()
            let input = "/\(row.relativePath)"
            textView.string = input
            textView.setSelectedRange(NSRange(location: input.utf16.count, length: 0))
            let helper = SlashSkillMentionHelper()
            helper.setSelectionStateForTesting(suggestions: [row], triggerRange: NSRange(location: 0, length: input.utf16.count), query: row.relativePath)
            XCTAssertTrue(helper.handleCommandIfNeeded(textView: textView, commandSelector: #selector(NSResponder.insertNewline(_:)), enabled: true))
            XCTAssertEqual(textView.string, input + " ")
        }
        XCTAssertEqual(rows.count, 2)
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
