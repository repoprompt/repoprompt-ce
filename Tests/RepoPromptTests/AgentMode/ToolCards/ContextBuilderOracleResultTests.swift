import Foundation
@testable import RepoPromptApp
import XCTest

final class ContextBuilderOracleResultTests: XCTestCase {
    func testDecodesPairedOracleResults() throws {
        let dto = try decode(#"""
        {
          "response_type": "plan",
          "plan": {
            "chat_id": "primary-chat",
            "status": "partial_failure",
            "oracle_results": {
              "primary": {
                "status": "completed",
                "chat_id": "primary-chat",
                "response": "Primary response",
                "model_display_name": "Primary Model"
              },
              "secondary": {
                "status": "failed",
                "chat_id": "secondary-chat",
                "partial_response": "Secondary partial",
                "error": "Secondary failed",
                "model_display_name": "Secondary Model"
              }
            }
          }
        }
        """#)

        XCTAssertEqual(dto.plan?.status, "partial_failure")
        XCTAssertEqual(dto.plan?.oracleResults?["primary"]?.response, "Primary response")
        XCTAssertEqual(dto.plan?.oracleResults?["secondary"]?.partialResponse, "Secondary partial")
        XCTAssertEqual(dto.plan?.oracleResults?["secondary"]?.error, "Secondary failed")
    }

    func testLaneProjectionIsStablePrimaryThenSecondary() throws {
        let dto = try decode(#"""
        {
          "response_type": "review",
          "review": {
            "oracle_results": {
              "secondary": {
                "status": "failed",
                "chat_id": " secondary-chat ",
                "error": " Secondary failed ",
                "model_display_name": "Secondary Model"
              },
              "primary": {
                "status": "completed",
                "chat_id": "primary-chat",
                "model_display_name": "Primary Model"
              }
            }
          }
        }
        """#)

        let lanes = contextBuilderOracleLaneSummaries(for: dto)
        XCTAssertEqual(lanes.map(\.lane), [.primary, .secondary])
        XCTAssertEqual(lanes.map(\.chatID), ["primary-chat", "secondary-chat"])
        XCTAssertEqual(lanes.map(\.status), ["completed", "failed"])
        XCTAssertEqual(lanes.map(\.cardStatus), [.success, .failure])
    }

    func testLanePopoverRoutesOnlyTheExactLaneChat() throws {
        let workspaceID = UUID()
        let tabID = UUID()
        let userInfo = try XCTUnwrap(contextBuilderOraclePopoverUserInfo(
            openContext: AgentOracleOpenContext(
                windowID: 7,
                workspaceID: workspaceID,
                tabID: tabID,
                chatID: "ambient-chat"
            ),
            chatID: " secondary-chat "
        ))
        let route = try XCTUnwrap(AgentOraclePopoverRoute(notificationUserInfo: userInfo))

        XCTAssertEqual(route.workspaceID, workspaceID)
        XCTAssertEqual(route.tabID, tabID)
        XCTAssertEqual(route.chatID, "secondary-chat")
        XCTAssertNil(contextBuilderOraclePopoverUserInfo(
            openContext: AgentOracleOpenContext(
                windowID: 7,
                workspaceID: workspaceID,
                tabID: tabID,
                chatID: "ambient-chat"
            ),
            chatID: "  "
        ))
    }

    func testFollowUpValuePreservesPairedEnvelopeAndLegacyPrimaryProjection() throws {
        let primaryID = UUID()
        let pairID = UUID()
        let result = OracleSendResult(
            payload: .paired(.init(
                pairID: pairID,
                mode: "plan",
                primaryChatID: "primary-chat",
                secondaryChatID: "secondary-chat",
                primaryModel: .gpt54Pro,
                secondaryModel: .claude4Sonnet,
                result: .init(
                    primary: .success(ChatSendReply(
                        chatId: primaryID,
                        shortId: "primary-chat",
                        mode: "plan",
                        response: "Primary response",
                        errors: nil
                    )),
                    secondary: .failure(.init(message: "Secondary failed", partialResponse: "Secondary partial"))
                ),
                historyDiverged: true,
                historyPersistenceError: nil
            )),
            route: .init(contextID: UUID(), agentSessionID: UUID(), agentRunID: UUID())
        )

        let followUp = MCPContextBuilderToolProvider.followUpValue(for: result)
        XCTAssertEqual(followUp.primary.chatId, primaryID)
        XCTAssertEqual(followUp.primary.errors, ["Secondary Oracle failed: Secondary failed"])
        let json = ToolOutputFormatter.rawJSONString(.object([
            "response_type": .string("plan"),
            "plan": followUp.value
        ]))
        let dto = try decode(json)
        XCTAssertEqual(dto.plan?.status, "partial_failure")
        XCTAssertEqual(dto.plan?.oraclePairID, pairID.uuidString)
        XCTAssertEqual(dto.plan?.oracleResults?["primary"]?.response, "Primary response")
        XCTAssertEqual(dto.plan?.oracleResults?["secondary"]?.partialResponse, "Secondary partial")
    }

    func testFollowUpValueLeavesSingleEnvelopeLegacyFlat() {
        let reply = ChatSendReply(
            chatId: UUID(),
            shortId: "single-chat",
            mode: "plan",
            response: "Single response",
            errors: nil
        )
        let result = OracleSendResult(
            payload: .single(reply),
            route: .init(contextID: UUID(), agentSessionID: UUID(), agentRunID: UUID())
        )

        let followUp = MCPContextBuilderToolProvider.followUpValue(for: result)
        XCTAssertEqual(followUp.primary.shortId, "single-chat")
        XCTAssertEqual(followUp.value.objectValue?["chat_id"]?.stringValue, "single-chat")
        XCTAssertNil(followUp.value.objectValue?["status"])
        XCTAssertNil(followUp.value.objectValue?["oracle_results"])
        XCTAssertNil(followUp.value.objectValue?["context_id"])
    }

    func testLegacySingleFollowUpRoutingIsUnchanged() throws {
        let plan = try decode(#"{"response_type":"plan","plan":{"chat_id":"plan-chat"}}"#)
        let question = try decode(#"{"response_type":"question","plan":{"chat_id":"question-chat"}}"#)
        let review = try decode(#"{"response_type":"review","review":{"chat_id":"review-chat"}}"#)

        XCTAssertTrue(contextBuilderOracleLaneSummaries(for: plan).isEmpty)
        XCTAssertEqual(contextBuilderFollowUpChatID(for: plan), "plan-chat")
        XCTAssertEqual(contextBuilderFollowUpChatID(for: question), "question-chat")
        XCTAssertEqual(contextBuilderFollowUpChatID(for: review), "review-chat")
    }

    private func decode(_ json: String) throws -> ToolResultDTOs.ContextBuilderDTO {
        try JSONDecoder().decode(ToolResultDTOs.ContextBuilderDTO.self, from: Data(json.utf8))
    }
}
