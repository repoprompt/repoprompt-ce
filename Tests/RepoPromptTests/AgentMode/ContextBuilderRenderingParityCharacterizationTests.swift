import Foundation
@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

@MainActor
final class ContextBuilderRenderingParityCharacterizationTests: XCTestCase {
    private let firstPromptID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let secondPromptID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let laterPromptID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    func testCompleteUserMessageEnvelopeFreezesOrderAndBytes() throws {
        let customPromptText = try XCTUnwrap(try ContextBuilderPromptStorage.promptText(
            for: [secondPromptID, firstPromptID],
            in: [
                ContextBuilderPrompt(id: firstPromptID, title: "First", content: "FIRST CUSTOM"),
                ContextBuilderPrompt(
                    id: XCTUnwrap(UUID(uuidString: "44444444-4444-4444-4444-444444444444")),
                    title: "Unselected",
                    content: "UNSELECTED"
                ),
                ContextBuilderPrompt(id: secondPromptID, title: "Second", content: "SECOND CUSTOM")
            ]
        ))

        let message = ContextBuilderAgentViewModel.renderUserMessageEnvelope(
            fileTree: "Root\n├── A.swift\n└── B.swift",
            userPrompt: "Implement the parity checkpoint.",
            customPromptText: customPromptText,
            discoverInstructions: "Inspect before editing.",
            adjustedBudget: 8500
        )

        XCTAssertEqual(message, """
        <file_map>
        Root
        ├── A.swift
        └── B.swift
        </file_map>
        <current_prompt_content>
        Implement the parity checkpoint.
        </current_prompt_content>
        <meta prompt="First">
        FIRST CUSTOM
        </meta prompt>

        <meta prompt="Second">
        SECOND CUSTOM
        </meta prompt>
        <discover_instructions>
        Inspect before editing.
        </discover_instructions>
        <metadata>
        <token_budget>8500</token_budget>
        <token_budget_guidance>
        Make a best effort to ensure the complete prompt (including all selected files and context) fits within the prescribed token budget of 8500 tokens.

        Context Optimization Strategy:
        - For MCP modes (like the current context_builder mode), selected files are automatically compressed to show only their codemaps (API signatures) instead of full content, dramatically reducing token usage
        - Codemaps provide type definitions, function signatures, and structure without full implementation details
        - Additional codemaps may be automatically included for types referenced by selected files (in 'auto' mode)
        - Use the MCP tools to check current token counts and adjust selection as needed to stay within budget

        Prioritize including files most relevant to the user's task while staying within the token budget.
        For additional files that may not fit, but are important, mention them in the prompt, with a short description for what they contain that may be relevant to the task.
        </token_budget_guidance>
        <output_format>
        The final prompt should be written with clear formatting, isolating important concepts in xml tags, and making use of clean markdown where possible.
        Do not add any outer wrapping for the complete prompt, as it will already be wrapped in <user_instructions>.
        </output_format>
        </metadata>
        """)
        XCTAssertFalse(message.contains("UNSELECTED"))
    }

    func testEmptyAndWhitespaceOptionalSectionsProduceExactMetadataOnlyEnvelope() {
        let empty = ContextBuilderAgentViewModel.renderUserMessageEnvelope(
            fileTree: "",
            userPrompt: "",
            customPromptText: nil,
            discoverInstructions: "",
            adjustedBudget: 42
        )
        let whitespace = ContextBuilderAgentViewModel.renderUserMessageEnvelope(
            fileTree: "  \n\t",
            userPrompt: " \n",
            customPromptText: nil,
            discoverInstructions: "\t",
            adjustedBudget: 42
        )
        let expected = """
        <metadata>
        <token_budget>42</token_budget>
        <token_budget_guidance>
        Make a best effort to ensure the complete prompt (including all selected files and context) fits within the prescribed token budget of 42 tokens.

        Context Optimization Strategy:
        - For MCP modes (like the current context_builder mode), selected files are automatically compressed to show only their codemaps (API signatures) instead of full content, dramatically reducing token usage
        - Codemaps provide type definitions, function signatures, and structure without full implementation details
        - Additional codemaps may be automatically included for types referenced by selected files (in 'auto' mode)
        - Use the MCP tools to check current token counts and adjust selection as needed to stay within budget

        Prioritize including files most relevant to the user's task while staying within the token budget.
        For additional files that may not fit, but are important, mention them in the prompt, with a short description for what they contain that may be relevant to the task.
        </token_budget_guidance>
        <output_format>
        The final prompt should be written with clear formatting, isolating important concepts in xml tags, and making use of clean markdown where possible.
        Do not add any outer wrapping for the complete prompt, as it will already be wrapped in <user_instructions>.
        </output_format>
        </metadata>
        """

        XCTAssertEqual(empty, expected)
        XCTAssertEqual(whitespace, expected)
        XCTAssertFalse(empty.contains("<file_map>"))
        XCTAssertFalse(empty.contains("<current_prompt_content>"))
        XCTAssertFalse(empty.contains("<discover_instructions>"))
    }

    func testMCPInstructionsOverrideRemainsSeparateFromCapturedTabPrompt() throws {
        let session = ContextBuilderAgentViewModel.TabSession(tabID: UUID())
        session.contextBuilderInstructions = "MCP OVERRIDE INSTRUCTIONS"
        let tabSnapshot = ComposeTabState(
            id: session.tabID,
            selection: StoredSelection(selectedPaths: ["/workspace/TabPrompt.swift"]),
            promptText: "ORIGINAL TAB PROMPT"
        )
        ContextBuilderAgentViewModel.captureRunStartState(
            for: session,
            selectedContextBuilderPromptIDs: [],
            workspaceSnapshot: tabSnapshot,
            isCurrentTab: true,
            livePromptText: { "LIVE PROMPT MUST NOT WIN" }
        )

        let input = try capturedInput(
            ContextBuilderAgentViewModel.resolveUserMessageSource(
                for: session,
                workspaceSnapshot: { nil },
                isCurrentTab: true
            )
        )
        let message = ContextBuilderAgentViewModel.renderUserMessageEnvelope(
            fileTree: "",
            userPrompt: input.promptText,
            customPromptText: nil,
            discoverInstructions: session.contextBuilderInstructions,
            adjustedBudget: 100
        )

        XCTAssertTrue(message.contains("<current_prompt_content>\nORIGINAL TAB PROMPT\n</current_prompt_content>"))
        XCTAssertTrue(message.contains("<discover_instructions>\nMCP OVERRIDE INSTRUCTIONS\n</discover_instructions>"))
        XCTAssertFalse(message.contains("<current_prompt_content>\nMCP OVERRIDE INSTRUCTIONS"))
        XCTAssertFalse(message.contains("<discover_instructions>\nORIGINAL TAB PROMPT"))
        XCTAssertFalse(message.contains("LIVE PROMPT MUST NOT WIN"))
    }

    func testRunStartCaptureWinsAfterTabSwitchAndPostCaptureEdits() async throws {
        let tabID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        let session = ContextBuilderAgentViewModel.TabSession(tabID: tabID)
        let capturedSelection = StoredSelection(
            selectedPaths: ["/workspace/FrozenA.swift", "/workspace/FrozenB.swift"],
            autoCodemapPaths: ["/workspace/FrozenMap.swift"],
            slices: ["/workspace/FrozenB.swift": [LineRange(start: 2, end: 5, description: "frozen slice")]],
            codemapAutoEnabled: false
        )
        let capturedSnapshot = ComposeTabState(
            id: tabID,
            selection: capturedSelection,
            promptText: "FROZEN TAB PROMPT"
        )
        let capturedPromptIDs: Set<UUID> = [firstPromptID, secondPromptID]
        ContextBuilderAgentViewModel.captureRunStartState(
            for: session,
            selectedContextBuilderPromptIDs: capturedPromptIDs,
            workspaceSnapshot: capturedSnapshot,
            isCurrentTab: true,
            livePromptText: { "LIVE PROMPT MUST NOT WIN" }
        )

        session.selectedContextBuilderPromptIDs = [laterPromptID]
        let editedSnapshot = ComposeTabState(
            id: tabID,
            selection: StoredSelection(selectedPaths: ["/workspace/Later.swift"]),
            promptText: "POST-CAPTURE PROMPT EDIT"
        )
        var workspaceSnapshotWasRead = false
        let input = try capturedInput(
            ContextBuilderAgentViewModel.resolveUserMessageSource(
                for: session,
                workspaceSnapshot: {
                    workspaceSnapshotWasRead = true
                    return editedSnapshot
                },
                isCurrentTab: false
            )
        )

        XCTAssertFalse(workspaceSnapshotWasRead)
        XCTAssertEqual(input.promptText, "FROZEN TAB PROMPT")
        XCTAssertEqual(input.selection, capturedSelection)
        XCTAssertEqual(input.contextBuilderPromptIDs, capturedPromptIDs)

        let orderedPrompts = [
            ContextBuilderPrompt(id: firstPromptID, title: "Frozen First", content: "FROZEN CUSTOM ONE"),
            ContextBuilderPrompt(id: secondPromptID, title: "Frozen Second", content: "FROZEN CUSTOM TWO"),
            ContextBuilderPrompt(id: laterPromptID, title: "Later", content: "POST-CAPTURE CUSTOM EDIT")
        ]
        var renderedSelection: StoredSelection?
        var renderedPromptIDs: Set<UUID>?
        let message = await ContextBuilderAgentViewModel.renderUserMessage(
            input: input,
            adjustedBudget: 500,
            fileTreeRenderer: { selection in
                renderedSelection = selection
                return selection.selectedPaths.joined(separator: "\n")
            },
            discoverInstructions: { "FROZEN INSTRUCTIONS" },
            customPromptRenderer: { promptIDs in
                renderedPromptIDs = promptIDs
                return ContextBuilderPromptStorage.promptText(for: promptIDs, in: orderedPrompts)
            }
        )

        XCTAssertEqual(renderedSelection, capturedSelection)
        XCTAssertEqual(renderedPromptIDs, capturedPromptIDs)
        XCTAssertTrue(message.contains("/workspace/FrozenA.swift\n/workspace/FrozenB.swift"))
        XCTAssertTrue(message.contains("FROZEN TAB PROMPT"))
        XCTAssertTrue(message.contains("FROZEN CUSTOM ONE"))
        XCTAssertTrue(message.contains("FROZEN CUSTOM TWO"))
        XCTAssertFalse(message.contains("/workspace/Later.swift"))
        XCTAssertFalse(message.contains("POST-CAPTURE PROMPT EDIT"))
        XCTAssertFalse(message.contains("POST-CAPTURE CUSTOM EDIT"))
        XCTAssertFalse(message.contains("LIVE PROMPT MUST NOT WIN"))
    }

    private func capturedInput(
        _ source: ContextBuilderAgentViewModel.UserMessageSource
    ) throws -> ContextBuilderAgentViewModel.UserMessageInput {
        guard case let .captured(input) = source else {
            XCTFail("Expected captured run-start input, got \(source)")
            throw TestFailure.unexpectedSource
        }
        return input
    }

    private enum TestFailure: Error {
        case unexpectedSource
    }
}
