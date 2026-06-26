import Foundation
@testable import RepoPrompt
import XCTest

final class AgentTranscriptAssistantPreviewTests: XCTestCase {
    func testTerminalResponseJoinsTrailingFragmentsAndPreservesFullDetailRows() throws {
        let user = item(kind: .user, text: "question", sequenceIndex: 0)
        let answer = item(kind: .assistant, text: "answer", sequenceIndex: 1)
        let period = item(kind: .assistantInline, text: ".", sequenceIndex: 2)
        let items = [user, answer, period]
        let transcript = AgentTranscriptIO.buildTranscript(
            from: items,
            terminalState: .completed,
            compact: false
        )
        let turn = try XCTUnwrap(transcript.turns.last)

        XCTAssertEqual(AgentTranscriptIO.terminalAssistantResponseText(in: turn), "answer.")
        XCTAssertEqual(AgentTranscriptIO.terminalAssistantResponseText(from: items), "answer.")
        XCTAssertEqual(turn.allActivities.map(\.id), [answer.id, period.id])
        XCTAssertEqual(turn.conclusionActivityID, period.id)

        let assistantRows = AgentTranscriptProjectionBuilder.rows(for: turn, archived: false)
            .filter { $0.kind == .assistant || $0.kind == .assistantInline }
        XCTAssertEqual(assistantRows.map(\.id), [answer.id, period.id])
        XCTAssertEqual(assistantRows.map(\.text), ["answer", "."])
    }

    func testTerminalResponseStartsAfterLatestToolBoundary() throws {
        let items = [
            item(kind: .user, text: "question", sequenceIndex: 0),
            item(kind: .assistant, text: "I will inspect.", sequenceIndex: 1),
            item(kind: .toolCall, text: "read", sequenceIndex: 2, toolName: "read_file"),
            item(kind: .toolResult, text: "result", sequenceIndex: 3, toolName: "read_file"),
            item(kind: .assistant, text: "final", sequenceIndex: 4),
            item(kind: .assistantInline, text: ".", sequenceIndex: 5)
        ]
        let transcript = AgentTranscriptIO.buildTranscript(
            from: items,
            terminalState: .completed,
            compact: false
        )
        let turn = try XCTUnwrap(transcript.turns.last)

        XCTAssertEqual(AgentTranscriptIO.terminalAssistantResponseText(in: turn), "final.")
        XCTAssertEqual(AgentTranscriptIO.terminalAssistantResponseText(from: items), "final.")
    }

    func testTerminalResponseDoesNotCrossTrailingNonAssistantBoundary() throws {
        let items = [
            item(kind: .user, text: "question", sequenceIndex: 0),
            item(kind: .assistant, text: "answer", sequenceIndex: 1),
            item(kind: .assistantInline, text: ".", sequenceIndex: 2),
            item(kind: .system, text: "terminal note", sequenceIndex: 3)
        ]
        let transcript = AgentTranscriptIO.buildTranscript(
            from: items,
            terminalState: .completed,
            compact: false
        )
        let turn = try XCTUnwrap(transcript.turns.last)

        XCTAssertNil(AgentTranscriptIO.terminalAssistantResponseText(in: turn))
        XCTAssertNil(AgentTranscriptIO.terminalAssistantResponseText(from: items))
    }

    func testTerminalResponseLeavesSingleAssistantUnchanged() throws {
        let items = [
            item(kind: .user, text: "question", sequenceIndex: 0),
            item(kind: .assistant, text: "complete answer.", sequenceIndex: 1)
        ]
        let transcript = AgentTranscriptIO.buildTranscript(
            from: items,
            terminalState: .completed,
            compact: false
        )
        let turn = try XCTUnwrap(transcript.turns.last)

        XCTAssertEqual(
            AgentTranscriptIO.terminalAssistantResponseText(in: turn),
            "complete answer."
        )
        XCTAssertEqual(
            AgentTranscriptIO.terminalAssistantResponseText(from: items),
            "complete answer."
        )
    }

    func testTerminalResponseJoinsFragmentsAcrossResponseSpans() {
        let answer = item(kind: .assistant, text: "answer", sequenceIndex: 1)
        let period = item(kind: .assistantInline, text: ".", sequenceIndex: 2)
        let turn = AgentTranscriptTurn(
            responseSpans: [
                AgentTranscriptProviderResponseSpan(
                    lifecycle: .completed,
                    startedAt: answer.timestamp,
                    completedAt: answer.timestamp,
                    activities: [AgentTranscriptActivity(from: answer)]
                ),
                AgentTranscriptProviderResponseSpan(
                    lifecycle: .completed,
                    startedAt: period.timestamp,
                    completedAt: period.timestamp,
                    activities: [AgentTranscriptActivity(from: period)]
                )
            ],
            terminalState: .completed,
            startedAt: answer.timestamp,
            completedAt: period.timestamp
        )

        XCTAssertEqual(AgentTranscriptIO.terminalAssistantResponseText(in: turn), "answer.")
    }

    private func item(
        kind: AgentChatItemKind,
        text: String,
        sequenceIndex: Int,
        toolName: String? = nil
    ) -> AgentChatItem {
        AgentChatItem(
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequenceIndex)),
            kind: kind,
            text: text,
            toolName: toolName,
            sequenceIndex: sequenceIndex
        )
    }
}
