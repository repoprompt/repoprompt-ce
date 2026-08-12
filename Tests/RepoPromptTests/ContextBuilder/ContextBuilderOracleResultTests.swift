import MCP
@testable import RepoPromptApp
import XCTest

final class ContextBuilderOracleResultTests: XCTestCase {
    func testGroupReplyAndToolCardPreserveOrderedUnsynthesizedLanes() throws {
        let groupID = UUID().uuidString
        let lanes: [Value] = [
            lane(index: 0, status: "completed", response: "primary answer"),
            lane(index: 1, status: "completed", response: "adviser answer"),
            lane(index: 2, status: "failed", error: "adviser failed")
        ]
        let value: [String: Value] = [
            "oracle_group_id": .string(groupID),
            "status": .string("partial_failure"),
            "oracle_count": .int(3),
            "oracle_results": .array(lanes)
        ]
        let reply = try ContextBuilderOracleGroupReply.decode(value)
        XCTAssertEqual(reply.orderedResults.map(\.laneIndex), [0, 1, 2])
        XCTAssertEqual(reply.result.primary.response, "primary answer")
        XCTAssertEqual(reply.toMCPFields()["oracle_count"]?.intValue, 3)

        let raw: Value = .object([
            "response_type": .string("review"),
            "review": .object(value)
        ])
        let dto = try XCTUnwrap(raw.decode(ToolResultDTOs.ContextBuilderDTO.self))
        let summaries = contextBuilderOracleLaneSummaries(for: dto)
        XCTAssertEqual(summaries.map(\.label), ["Primary Oracle", "Oracle 2", "Oracle 3"])
        XCTAssertEqual(summaries.map(\.chatID), ["chat-0", "chat-1", "chat-2"])
        XCTAssertEqual(contextBuilderFollowUpChatID(for: dto), "chat-0")

        let text = ToolOutputFormatter.formatDiscoverContext(value: raw).compactMap { block -> String? in
            guard case let .text(text, _, _) = block else { return nil }
            return text
        }.joined(separator: "\n")
        let primaryRange = try XCTUnwrap(text.range(of: "primary answer"))
        let adviserRange = try XCTUnwrap(text.range(of: "adviser answer"))
        let errorRange = try XCTUnwrap(text.range(of: "adviser failed"))
        XCTAssertLessThan(primaryRange.lowerBound, adviserRange.lowerBound)
        XCTAssertLessThan(adviserRange.lowerBound, errorRange.lowerBound)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("synthesis"))

        let askOracleText = ToolOutputFormatter.formatAskOracle(
            args: [:],
            value: .object(value),
            emitResources: false
        ).compactMap { block -> String? in
            guard case let .text(text, _, _) = block else { return nil }
            return text
        }.joined(separator: "\n")
        XCTAssertTrue(askOracleText.contains("Oracle group status: partial_failure"))
        XCTAssertTrue(askOracleText.contains("### Primary Oracle"))
        XCTAssertTrue(askOracleText.contains("### Oracle 2"))
        XCTAssertTrue(askOracleText.contains("### Oracle 3"))
    }

    func testDecodeRejectsRoleThatDoesNotMatchLaneIndex() {
        let value: [String: Value] = [
            "oracle_group_id": .string(UUID().uuidString),
            "status": .string("completed"),
            "oracle_count": .int(1),
            "oracle_results": .array([
                lane(index: 0, role: "additional", status: "completed", response: "answer")
            ])
        ]

        XCTAssertThrowsError(try ContextBuilderOracleGroupReply.decode(value))
    }

    private func lane(
        index: Int,
        role: String? = nil,
        status: String,
        response: String? = nil,
        error: String? = nil
    ) -> Value {
        var object: [String: Value] = [
            "lane_index": .int(index),
            "role": .string(role ?? (index == 0 ? "primary" : "additional")),
            "chat_id": .string("chat-\(index)"),
            "model_id": .string("model-\(index)"),
            "status": .string(status)
        ]
        if let response { object["response"] = .string(response) }
        if let error {
            object["error"] = .object([
                "code": .string("provider_failed"),
                "message": .string(error)
            ])
        }
        return .object(object)
    }
}
