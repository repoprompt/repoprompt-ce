import Foundation
@testable import RepoPromptApp
import XCTest

final class ContextBuilderOracleResultTests: XCTestCase {
    func testDecodesAndRoundTripsPairedOracleResultsAndAggregateStatus() throws {
        let dto = try decode(#"""
        {
          "status": "completed",
          "discovery_status": "completed",
          "discovery_error": "discovery warning",
          "oracle_status": "partial_failure",
          "overall_status": "partial_failure",
          "response_type": "plan",
          "plan": {
            "chat_id": "primary-chat",
            "status": "partial_failure",
            "oracle_results": {
              "secondary": {
                "status": "failed",
                "chat_id": "secondary-chat",
                "mode": "plan",
                "partial_response": "Secondary partial",
                "error": "Secondary failed",
                "errors": ["Secondary failed"],
                "model_raw_id": "secondary-raw",
                "model_display_name": "Secondary Model"
              },
              "primary": {
                "status": "completed",
                "chat_id": "primary-chat",
                "mode": "plan",
                "response": "Primary response",
                "model_raw_id": "primary-raw",
                "model_display_name": "Primary Model"
              }
            }
          }
        }
        """#)

        XCTAssertEqual(dto.discoveryStatus, "completed")
        XCTAssertEqual(dto.discoveryError, "discovery warning")
        XCTAssertEqual(dto.oracleStatus, "partial_failure")
        XCTAssertEqual(dto.overallStatus, "partial_failure")
        XCTAssertEqual(dto.plan?.status, "partial_failure")

        let primary = try XCTUnwrap(dto.plan?.oracleResults?["primary"])
        XCTAssertEqual(primary.status, "completed")
        XCTAssertEqual(primary.chatID, "primary-chat")
        XCTAssertEqual(primary.mode, "plan")
        XCTAssertEqual(primary.response, "Primary response")
        XCTAssertEqual(primary.modelRawID, "primary-raw")
        XCTAssertEqual(primary.modelDisplayName, "Primary Model")

        let secondary = try XCTUnwrap(dto.plan?.oracleResults?["secondary"])
        XCTAssertEqual(secondary.partialResponse, "Secondary partial")
        XCTAssertEqual(secondary.error, "Secondary failed")
        XCTAssertEqual(secondary.errors, ["Secondary failed"])
        XCTAssertEqual(secondary.modelRawID, "secondary-raw")
        XCTAssertEqual(secondary.modelDisplayName, "Secondary Model")

        let roundTripped = try JSONDecoder().decode(
            ToolResultDTOs.ContextBuilderDTO.self,
            from: JSONEncoder().encode(dto)
        )
        XCTAssertEqual(roundTripped, dto)
    }

    func testProjectionIsPrimaryThenSecondaryWithIndependentStatusModelsAndErrors() throws {
        let dto = try decode(#"""
        {
          "response_type": "plan",
          "plan": {
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

        let summaries = contextBuilderOracleLaneSummaries(for: dto)
        XCTAssertEqual(summaries.map(\.lane), [.primary, .secondary])
        XCTAssertEqual(summaries.map(\.status), ["completed", "failed"])
        XCTAssertEqual(summaries.map(\.cardStatus), [.success, .failure])
        XCTAssertEqual(summaries.map(\.chatID), ["primary-chat", "secondary-chat"])
        XCTAssertEqual(summaries.map(\.modelDisplayName), ["Primary Model", "Secondary Model"])
        XCTAssertEqual(summaries[1].error, "Secondary failed")
    }

    func testBranchSelectionUsesReviewThenPlanAndPlanForQuestion() throws {
        let reviewDTO = try decode(branchPayload(responseType: "review"))
        XCTAssertEqual(contextBuilderOracleLaneSummaries(for: reviewDTO).first?.chatID, "review-primary")
        XCTAssertEqual(contextBuilderFollowUpChatID(for: reviewDTO), "review-chat")

        let questionDTO = try decode(branchPayload(responseType: "question"))
        XCTAssertEqual(contextBuilderOracleLaneSummaries(for: questionDTO).first?.chatID, "plan-primary")
        XCTAssertEqual(contextBuilderFollowUpChatID(for: questionDTO), "plan-chat")
    }

    func testLegacyMissingResponseTypeUsesPlanFirstAndRetainsSingularFallback() throws {
        let planDTO = try decode(#"{"plan":{"chat_id":"legacy-plan"}}"#)
        XCTAssertTrue(contextBuilderOracleLaneSummaries(for: planDTO).isEmpty)
        XCTAssertEqual(contextBuilderFollowUpChatID(for: planDTO), "legacy-plan")

        let reviewDTO = try decode(#"{"review":{"chat_id":"legacy-review"}}"#)
        XCTAssertTrue(contextBuilderOracleLaneSummaries(for: reviewDTO).isEmpty)
        XCTAssertEqual(contextBuilderFollowUpChatID(for: reviewDTO), "legacy-review")
    }

    func testMissingSecondaryDoesNotCreateSyntheticSummaryAndMissingStatusIsUnknown() throws {
        let dto = try decode(#"""
        {
          "plan": {
            "oracle_results": {
              "primary": { "chat_id": "primary-only" }
            }
          }
        }
        """#)

        let summaries = contextBuilderOracleLaneSummaries(for: dto)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.lane, .primary)
        XCTAssertEqual(summaries.first?.status, "unknown")
        XCTAssertEqual(summaries.first?.cardStatus, .neutral)
    }

    func testResultStatusUsesAggregateThenOracleThenSelectedBranchThenLegacy() throws {
        XCTAssertEqual(
            try contextBuilderResultStatus(for: decode(
                #"{"status":"completed","oracle_status":"failed","overall_status":"warning","plan":{"status":"partial_failure"}}"#
            )),
            "warning"
        )
        XCTAssertEqual(
            try contextBuilderResultStatus(for: decode(
                #"{"status":"completed","oracle_status":"partial_failure","plan":{"status":"failed"}}"#
            )),
            "partial_failure"
        )
        XCTAssertEqual(
            try contextBuilderResultStatus(for: decode(
                #"{"status":"completed","response_type":"review","review":{"status":"failed"}}"#
            )),
            "failed"
        )
        XCTAssertEqual(try contextBuilderResultStatus(for: decode(#"{"status":"completed"}"#)), "completed")
    }

    func testAggregateStatusMapsPartialAndFailureWithoutFalseSuccess() {
        XCTAssertEqual(contextBuilderAggregateCardStatus("partial_failure"), .warning)
        XCTAssertEqual(contextBuilderAggregateCardStatus(" warning "), .warning)
        XCTAssertEqual(contextBuilderAggregateCardStatus("failed_oracle"), .failure)
        XCTAssertEqual(contextBuilderAggregateCardStatus("error"), .failure)
        XCTAssertEqual(contextBuilderAggregateCardStatus("completed"), .success)
        XCTAssertNil(contextBuilderAggregateCardStatus("future_status"))
    }

    func testLaneSpecificPopoverUsesExactChatIDAndRoundTripsRoute() throws {
        let workspaceID = UUID()
        let tabID = UUID()
        let openContext = AgentOracleOpenContext(
            windowID: 7,
            workspaceID: workspaceID,
            tabID: tabID,
            chatID: "legacy-chat"
        )
        let userInfo = try XCTUnwrap(contextBuilderOraclePopoverUserInfo(
            openContext: openContext,
            chatID: " secondary-chat "
        ))
        let route = try XCTUnwrap(AgentOraclePopoverRoute(notificationUserInfo: userInfo))

        XCTAssertEqual(route.windowID, 7)
        XCTAssertEqual(route.workspaceID, workspaceID)
        XCTAssertEqual(route.tabID, tabID)
        XCTAssertEqual(route.chatID, "secondary-chat")

        let fallback = try XCTUnwrap(contextBuilderOraclePopoverUserInfo(
            openContext: openContext,
            chatID: "  "
        ))
        XCTAssertEqual(AgentOraclePopoverRoute(notificationUserInfo: fallback)?.chatID, "legacy-chat")
        XCTAssertNil(contextBuilderOraclePopoverUserInfo(
            openContext: openContext,
            chatID: "  ",
            allowOpenContextFallback: false
        ))
    }

    func testActivePairedModelDetailIsStablePrimaryThenSecondary() {
        let secondary = AIModel.codexCustom(name: "secondary-model")
        XCTAssertEqual(
            contextBuilderFollowUpModelDetail(
                primaryDisplayName: "Primary Model",
                secondaryRawModel: secondary.rawValue,
                pairedGenerationActive: true
            ),
            "Primary: Primary Model • Secondary: \(secondary.displayName)"
        )
        XCTAssertEqual(
            contextBuilderFollowUpModelDetail(
                primaryDisplayName: "Primary Model",
                secondaryRawModel: secondary.rawValue,
                pairedGenerationActive: false
            ),
            "Primary Model"
        )
    }

    private func decode(_ json: String) throws -> ToolResultDTOs.ContextBuilderDTO {
        try JSONDecoder().decode(ToolResultDTOs.ContextBuilderDTO.self, from: Data(json.utf8))
    }

    private func branchPayload(responseType: String) -> String {
        #"{"response_type":"\#(responseType)","plan":{"chat_id":"plan-chat","oracle_results":{"primary":{"status":"completed","chat_id":"plan-primary"}}},"review":{"chat_id":"review-chat","oracle_results":{"primary":{"status":"completed","chat_id":"review-primary"}}}}"#
    }
}
