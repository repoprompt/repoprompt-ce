import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class AgentTranscriptReplyClassifierTests: XCTestCase {
    private func activity(_ kind: AgentChatItemKind, _ index: Int) -> AgentTranscriptActivity {
        AgentTranscriptActivity(
            id: UUID(), timestamp: Date(timeIntervalSince1970: Double(index)), sequenceIndex: index,
            role: .assistant, itemKind: kind, text: "text"
        )
    }

    private func assertReplies(_ kinds: [AgentChatItemKind], _ expected: [Int], file: StaticString = #filePath, line: UInt = #line) {
        let activities = kinds.enumerated().map { activity($0.element, $0.offset) }
        XCTAssertEqual(
            AgentTranscriptReplyClassifier.replyActivityIDs(in: activities),
            Set(expected.map { activities[$0].id }), file: file, line: line
        )
    }

    func testImmediateReply() {
        assertReplies([.user, .assistant, .toolCall], [1])
    }

    func testToolBeforeReply() {
        assertReplies([.user, .toolCall, .assistant, .toolCall], [2])
    }

    func testLateTextAndAnswerAreBothReplies() {
        assertReplies([.user, .assistant, .assistant, .toolCall], [1, 2])
    }

    func testThinkingDoesNotEndReply() {
        assertReplies([.user, .assistant, .thinking, .assistantInline, .toolCall], [1, 3])
    }

    func testNarrationAfterToolIsNotReply() {
        assertReplies([.user, .assistant, .toolCall, .assistant, .toolResult], [1])
    }

    func testEachUserStartsNewReply() {
        assertReplies([.user, .assistant, .toolCall, .user, .toolCall, .assistant], [1, 5])
    }

    func testNoUserHasNoReply() {
        assertReplies([.assistant, .toolCall, .assistant], [])
    }
}
