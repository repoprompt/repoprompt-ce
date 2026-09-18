import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class ContextBuilderOracleFailedPrimaryResultTests: XCTestCase {
    func testSettledFailedPrimaryPreservesAuxiliaryResultAndNavigation() throws {
        let primaryError = OracleLaneError(
            code: "primary_stopped",
            message: "primary stopped",
            partialResponse: "primary partial"
        )
        let primary = try OracleLaneResult(
            laneIndex: 0,
            chatID: "chat-0",
            providerID: "provider-0",
            modelID: "model-0",
            status: .failed,
            response: nil,
            error: primaryError
        )
        let auxiliary = try OracleLaneResult(
            laneIndex: 1,
            chatID: "chat-1",
            providerID: "provider-1",
            modelID: "model-1",
            status: .completed,
            response: "auxiliary answer",
            error: nil
        )
        let groupResult = try OracleGroupResult(
            groupID: OracleGroupID(rawValue: UUID()),
            status: .failed,
            oracleResults: [primary, auxiliary]
        )
        let group = ContextBuilderOracleGroupReply(result: groupResult)

        XCTAssertNil(try group.requiredCompletedPrimaryResponse())

        let reply = try ChatSendReply(
            chatId: UUID(),
            shortId: primary.chatID,
            mode: "review",
            response: group.requiredCompletedPrimaryResponse(),
            errors: ["Oracle failed: primary stopped"],
            oracleGroup: group
        )
        XCTAssertNil(reply.response)
        XCTAssertEqual(reply.oracleGroup?.orderedResults, [primary, auxiliary])

        let fields = try XCTUnwrap(reply.toMCPValue().objectValue)
        XCTAssertNil(fields["response"])
        XCTAssertEqual(fields["chat_id"]?.stringValue, "chat-0")
        XCTAssertEqual(fields["oracle_count"]?.intValue, 2)
        let lanes = try XCTUnwrap(fields["oracle_results"]?.arrayValue)
        XCTAssertEqual(lanes.map { $0.objectValue?["chat_id"]?.stringValue }, ["chat-0", "chat-1"])
        XCTAssertEqual(lanes.map { $0.objectValue?["status"]?.stringValue }, ["failed", "completed"])
        XCTAssertNil(lanes[0].objectValue?["response"])
        XCTAssertEqual(lanes[0].objectValue?["error"]?.objectValue?["message"]?.stringValue, "primary stopped")
        XCTAssertEqual(lanes[1].objectValue?["response"]?.stringValue, "auxiliary answer")

        let raw: Value = .object([
            "response_type": .string("review"),
            "review": reply.toMCPValue()
        ])
        let dto = try XCTUnwrap(raw.decode(ToolResultDTOs.ContextBuilderDTO.self))
        XCTAssertEqual(contextBuilderFollowUpChatID(for: dto), "chat-0")
        XCTAssertEqual(contextBuilderOracleLaneSummaries(for: dto).map(\.chatID), ["chat-0", "chat-1"])
    }
}
