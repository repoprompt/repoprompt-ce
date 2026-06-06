import Foundation
@testable import RepoPrompt
import XCTest

final class AgentConversationReplaySerializationTests: XCTestCase {
    func testEquivalentModeMatchesLegacyBytesAndCategoryMetrics() throws {
        let invocationID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"))
        let items: [AgentChatItem] = [
            .user("  hello 🌍\nnext  ", sequenceIndex: 0),
            .assistant("\n  working  \n", sequenceIndex: 1),
            .toolCall(
                name: "read_file",
                invocationID: invocationID,
                argsJSON: #"{"path":"Sources/Ünicode.swift"}"#,
                sequenceIndex: 2
            ),
            .toolResult(
                name: "read_file",
                invocationID: invocationID,
                resultJSON: #"{"content":"ignored by replay"}"#,
                isError: false,
                sequenceIndex: 3
            ),
            .system(" system context ", sequenceIndex: 4),
            .error(" error context ", sequenceIndex: 5),
            .thinking("hidden reasoning", sequenceIndex: 6),
            .assistant("\nfinal answer\n", sequenceIndex: 7)
        ]
        let transcript = AgentTranscriptIO.importLegacyItems(items)

        let serialization = AgentTranscriptIO.serializeConversationHistory(from: transcript)
        let expected = [
            "<user>  hello 🌍\nnext  </user>",
            "<assistant>working</assistant>",
            #"<tool_call name="read_file">{"path":"Sources/Ünicode.swift"}</tool_call>"#,
            #"<tool_result name="read_file"/>"#,
            "<system> system context </system>",
            "<error> error context </error>",
            "<assistant>final answer</assistant>"
        ].joined(separator: "\n")

        XCTAssertEqual(serialization.text, expected)
        XCTAssertEqual(Array(serialization.text.utf8), Array(expected.utf8))
        XCTAssertEqual(AgentTranscriptIO.buildConversationHistory(from: transcript), expected)
        XCTAssertEqual(serialization.metrics.mode, .equivalent)
        XCTAssertEqual(serialization.metrics.outputUTF8Bytes, expected.utf8.count)
        XCTAssertEqual(serialization.metrics.unboundedOutputUTF8Bytes, expected.utf8.count)
        XCTAssertEqual(serialization.metrics.userAuthoredUTF8Bytes, "  hello 🌍\nnext  ".utf8.count)
        XCTAssertEqual(serialization.metrics.categories[.user]?.examinedCount, 1)
        XCTAssertEqual(serialization.metrics.categories[.user]?.emittedCount, 1)
        XCTAssertEqual(serialization.metrics.categories[.assistant]?.emittedCount, 2)
        XCTAssertEqual(serialization.metrics.categories[.toolCall]?.emittedCount, 1)
        XCTAssertEqual(serialization.metrics.categories[.toolResult]?.emittedCount, 1)
        XCTAssertEqual(serialization.metrics.categories[.system]?.emittedCount, 1)
        XCTAssertEqual(serialization.metrics.categories[.error]?.emittedCount, 1)
        XCTAssertEqual(serialization.metrics.omittedRowCount, 0)
        XCTAssertEqual(serialization.metrics.truncatedToolCallCount, 0)
    }

    func testEquivalentModeHandlesEmptyAndSelfClosingToolCallBytes() {
        let empty = AgentTranscriptIO.serializeConversationHistory(
            from: AgentTranscriptIO.importLegacyItems([])
        )
        XCTAssertEqual(empty.text, "")
        XCTAssertEqual(empty.metrics.outputUTF8Bytes, 0)

        let transcript = AgentTranscriptIO.importLegacyItems([
            .user("inspect", sequenceIndex: 0),
            .toolCall(name: "read_file", argsJSON: nil, sequenceIndex: 1),
            .assistant("done", sequenceIndex: 2)
        ])
        let expected = "<user>inspect</user>\n<tool_call name=\"read_file\"/>\n<assistant>done</assistant>"

        let serialization = AgentTranscriptIO.serializeConversationHistory(from: transcript)

        XCTAssertEqual(Array(serialization.text.utf8), Array(expected.utf8))
        XCTAssertEqual(serialization.metrics.outputUTF8Bytes, expected.utf8.count)
    }

    func testEquivalentModePreservesCustomRenderedUserTextExactly() {
        let transcript = AgentTranscriptIO.importLegacyItems([
            .user("original", sequenceIndex: 0),
            .assistant("done", sequenceIndex: 1)
        ])
        let renderedUserText = "  rendered attachment block\n\n@file.swift  "

        let serialization = AgentTranscriptIO.serializeConversationHistory(
            from: transcript,
            renderUserMessage: { _ in renderedUserText }
        )

        XCTAssertEqual(
            serialization.text,
            "<user>\(renderedUserText)</user>\n<assistant>done</assistant>"
        )
        XCTAssertEqual(serialization.metrics.userAuthoredUTF8Bytes, renderedUserText.utf8.count)
    }

    func testEquivalentModeRetainsCompactedPrefixAuthority() {
        var items: [AgentChatItem] = []
        for turn in 0 ..< 30 {
            let base = turn * 3
            items.append(.user("user \(turn)", sequenceIndex: base))
            items.append(.assistant("progress \(turn)", sequenceIndex: base + 1))
            items.append(.assistant("final \(turn)", sequenceIndex: base + 2))
        }
        let compacted = AgentTranscriptCompactor.compact(
            AgentTranscriptIO.importLegacyItems(items)
        )

        let serialization = AgentTranscriptIO.serializeConversationHistory(from: compacted)

        XCTAssertTrue(serialization.text.contains("<user>user 0</user>"))
        XCTAssertTrue(serialization.text.contains("final 0"))
        XCTAssertTrue(serialization.text.contains("<user>user 29</user>"))
        XCTAssertTrue(serialization.text.contains("<assistant>final 29</assistant>"))
        XCTAssertEqual(serialization.metrics.turnCount, compacted.turns.count)
    }

    func testBoundedModeTruncatesToolArgumentsOnCharacterBoundaryWithMarker() {
        let args = "😀éabc"
        let transcript = AgentTranscriptIO.importLegacyItems([
            .user("keep user", sequenceIndex: 0),
            .toolCall(name: "read_file", argsJSON: args, sequenceIndex: 1),
            .assistant("done", sequenceIndex: 2)
        ])

        let serialization = AgentTranscriptIO.serializeConversationHistory(
            from: transcript,
            policy: .bounded(AgentConversationReplayBudget(
                maxOutputUTF8Bytes: 10000,
                maxToolArgumentCharacters: 2
            ))
        )

        XCTAssertTrue(serialization.text.contains("<user>keep user</user>"))
        XCTAssertTrue(serialization.text.contains("😀é[replay_tool_arguments_truncated omitted_characters=3]"))
        XCTAssertFalse(serialization.text.contains("😀éabc</tool_call>"))
        XCTAssertEqual(serialization.metrics.originalToolArgumentCharacters, 5)
        XCTAssertEqual(serialization.metrics.emittedToolArgumentCharacters, 2)
        XCTAssertEqual(serialization.metrics.truncatedToolCallCount, 1)
        XCTAssertEqual(serialization.metrics.omittedRowCount, 0)
        XCTAssertEqual(serialization.metrics.mode, .bounded)
    }

    func testBoundedModeDropsToolResultBeforeHigherPriorityRows() {
        let toolName = String(repeating: "long_tool_name_", count: 10)
        let userLine = "<user>keep-user</user>"
        let intermediateLine = "<assistant>intermediate</assistant>"
        let toolCallLine = "<tool_call name=\"\(toolName)\">{}</tool_call>"
        let conclusionLine = "<assistant>final</assistant>"
        let omissionLine = "<system>[replay_rows_omitted count=1]</system>"
        let targetOutput = [
            userLine,
            intermediateLine,
            toolCallLine,
            conclusionLine,
            omissionLine
        ].joined(separator: "\n")
        let transcript = AgentTranscriptIO.importLegacyItems([
            .user("keep-user", sequenceIndex: 0),
            .assistant("intermediate", sequenceIndex: 1),
            .toolCall(name: toolName, argsJSON: "{}", sequenceIndex: 2),
            .toolResult(name: toolName, resultJSON: "{}", sequenceIndex: 3),
            .assistant("final", sequenceIndex: 4)
        ])

        let serialization = AgentTranscriptIO.serializeConversationHistory(
            from: transcript,
            policy: .bounded(AgentConversationReplayBudget(
                maxOutputUTF8Bytes: targetOutput.utf8.count,
                maxToolArgumentCharacters: 100
            ))
        )

        XCTAssertEqual(serialization.text, targetOutput)
        XCTAssertFalse(serialization.text.contains("<tool_result"))
        XCTAssertTrue(serialization.text.contains(toolCallLine))
        XCTAssertTrue(serialization.text.contains(intermediateLine))
        XCTAssertTrue(serialization.text.contains(conclusionLine))
        XCTAssertEqual(serialization.metrics.omittedRowCount, 1)
        XCTAssertEqual(serialization.metrics.categories[.toolResult]?.omittedCount, 1)
        XCTAssertEqual(serialization.metrics.categories[.toolCall]?.omittedCount, 0)
        XCTAssertEqual(serialization.metrics.categories[.assistant]?.omittedCount, 0)
        XCTAssertLessThanOrEqual(serialization.metrics.outputUTF8Bytes, targetOutput.utf8.count)
    }

    func testBoundedModeDoesNotCountTruncationForAnOmittedToolCall() {
        let userLine = "<user>keep-user</user>"
        let omissionLine = "<system>[replay_rows_omitted count=1]</system>"
        let expected = [userLine, omissionLine].joined(separator: "\n")
        let transcript = AgentTranscriptIO.importLegacyItems([
            .user("keep-user", sequenceIndex: 0),
            .toolCall(
                name: "read_file",
                argsJSON: String(repeating: "argument", count: 50),
                sequenceIndex: 1
            )
        ])

        let serialization = AgentTranscriptIO.serializeConversationHistory(
            from: transcript,
            policy: .bounded(AgentConversationReplayBudget(
                maxOutputUTF8Bytes: expected.utf8.count,
                maxToolArgumentCharacters: 1
            ))
        )

        XCTAssertEqual(serialization.text, expected)
        XCTAssertEqual(serialization.metrics.categories[.toolCall]?.omittedCount, 1)
        XCTAssertEqual(serialization.metrics.truncatedToolCallCount, 0)
        XCTAssertEqual(serialization.metrics.emittedToolArgumentCharacters, 0)
    }

    func testBoundedModePreservesUserTextAndReportsEssentialOverflow() {
        let userText = "user-authored-" + String(repeating: "内容", count: 40)
        let userLine = "<user>\(userText)</user>"
        let transcript = AgentTranscriptIO.importLegacyItems([
            .user(userText, sequenceIndex: 0),
            .assistant("discardable conclusion", sequenceIndex: 1)
        ])
        let budget = max(1, userLine.utf8.count / 2)

        let serialization = AgentTranscriptIO.serializeConversationHistory(
            from: transcript,
            policy: .bounded(AgentConversationReplayBudget(
                maxOutputUTF8Bytes: budget,
                maxToolArgumentCharacters: 10
            ))
        )

        XCTAssertTrue(serialization.text.contains(userLine))
        XCTAssertFalse(serialization.text.contains("discardable conclusion"))
        XCTAssertTrue(serialization.text.contains("[replay_rows_omitted count=1]"))
        XCTAssertTrue(serialization.text.contains("[replay_budget_exceeded_by_user_text user_text_preserved=true]"))
        XCTAssertEqual(serialization.metrics.userAuthoredUTF8Bytes, userText.utf8.count)
        XCTAssertGreaterThan(serialization.metrics.essentialOverflowUTF8Bytes, 0)
        XCTAssertGreaterThan(serialization.metrics.finalOverBudgetUTF8Bytes, 0)
        XCTAssertEqual(serialization.metrics.categories[.user]?.omittedCount, 0)
        XCTAssertEqual(serialization.metrics.categories[.user]?.emittedCount, 1)
    }
}
