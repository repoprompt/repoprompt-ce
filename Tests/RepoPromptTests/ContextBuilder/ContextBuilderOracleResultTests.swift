import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class ContextBuilderOracleResultTests: XCTestCase {
    func testGroupReplyAndToolCardPreserveOrderedUnsynthesizedLanes() throws {
        let result = try groupResult(
            status: .partialFailure,
            lanes: [
                lane(index: 0, status: .completed, response: "primary answer"),
                lane(index: 1, status: .completed, response: "adviser answer"),
                lane(index: 2, status: .failed, error: laneError(message: "adviser failed"))
            ]
        )
        let reply = ContextBuilderOracleGroupReply(result: result)
        XCTAssertEqual(reply.orderedResults.map(\.laneIndex), [0, 1, 2])
        XCTAssertEqual(reply.result.primary.response, "primary answer")
        XCTAssertEqual(try reply.requiredCompletedPrimaryResponse(), "primary answer")
        XCTAssertEqual(reply.toMCPFields()["oracle_count"]?.intValue, 3)

        let value = reply.toMCPFields()
        let raw: Value = .object([
            "response_type": .string("review"),
            "review": .object(value)
        ])
        let dto = try XCTUnwrap(raw.decode(ToolResultDTOs.ContextBuilderDTO.self))
        let summaries = contextBuilderOracleLaneSummaries(for: dto)
        XCTAssertEqual(summaries.map(\.label), ["Oracle", "Oracle 2", "Oracle 3"])
        XCTAssertEqual(summaries.map(\.chatID), ["chat-0", "chat-1", "chat-2"])
        XCTAssertEqual(contextBuilderFollowUpChatID(for: dto), "chat-0")
        XCTAssertEqual(
            contextBuilderFollowUpModelLine(dto: dto, fallback: "CLI-GPT"),
            "model-0 + model-1 + model-2"
        )
        XCTAssertEqual(
            contextBuilderJoinedFollowUpModelLine(
                primaryDisplayName: "CLI-GPT-5.6 Sol High",
                additionalModelRaws: ["second-raw", "  ", "third-raw"]
            ),
            "CLI-GPT-5.6 Sol High + second-raw + third-raw"
        )

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
        XCTAssertTrue(askOracleText.split(separator: "\n").contains("### Oracle"))
        XCTAssertTrue(askOracleText.contains("### Oracle 2"))
        XCTAssertTrue(askOracleText.contains("### Oracle 3"))
        XCTAssertFalse(askOracleText.contains("Primary Oracle"))
        XCTAssertFalse(askOracleText.contains("Secondary Oracle"))
    }

    func testFormattedGroupPreservesCancelledLaneStatus() throws {
        let result = try groupResult(
            status: .partialFailure,
            lanes: [
                lane(index: 0, status: .completed, response: "primary answer"),
                lane(
                    index: 1,
                    status: .cancelled,
                    error: laneError(
                        code: "cancelled",
                        message: "Oracle lane was cancelled."
                    )
                )
            ]
        )
        let fields = ContextBuilderOracleGroupReply(result: result).toMCPFields()
        let text = ToolOutputFormatter.formatAskOracle(
            args: [:],
            value: .object(fields),
            emitResources: false
        ).compactMap { block -> String? in
            guard case let .text(text, _, _) = block else { return nil }
            return text
        }.joined(separator: "\n")

        XCTAssertTrue(text.contains("- Status: Cancelled"), text)
        XCTAssertFalse(text.contains("- Status: Failed"), text)
    }

    func testFailedOrCancelledPrimaryIsNotPublishable() throws {
        for status in [OracleLaneResultStatus.failed, .cancelled] {
            let reply = try ContextBuilderOracleGroupReply(result: groupResult(
                status: .failed,
                lanes: [
                    lane(
                        index: 0,
                        status: status,
                        error: laneError(
                            code: "primary_stopped",
                            message: "primary stopped",
                            partialResponse: "primary partial"
                        )
                    ),
                    lane(index: 1, status: .completed, response: "auxiliary answer")
                ]
            ))

            XCTAssertThrowsError(try reply.requiredCompletedPrimaryResponse()) { error in
                XCTAssertEqual(
                    error as? ContextBuilderOraclePrimaryCompletionError,
                    .notCompleted(
                        status: status,
                        code: "primary_stopped",
                        message: "primary stopped"
                    )
                )
            }
        }
    }

    func testAuxiliaryFailureDoesNotBlockCompletedPrimaryPublication() throws {
        let reply = try ContextBuilderOracleGroupReply(result: groupResult(
            status: .partialFailure,
            lanes: [
                lane(index: 0, status: .completed, response: "primary answer"),
                lane(index: 1, status: .failed, error: laneError(message: "auxiliary failed"))
            ]
        ))

        XCTAssertEqual(try reply.requiredCompletedPrimaryResponse(), "primary answer")
        XCTAssertEqual(reply.result.status, .partialFailure)
    }

    func testReplyPreservesExecutionProfileAndWarnings() throws {
        let executionProfile = try OracleExecutionProfile(
            providerID: "provider",
            modelID: "resolved-model",
            effectiveReasoningEffort: "high"
        )
        let reply = try ContextBuilderOracleGroupReply(result: groupResult(
            status: .partialFailure,
            lanes: [
                lane(
                    index: 0,
                    status: .completed,
                    response: "primary",
                    executionProfile: executionProfile
                ),
                lane(index: 1, status: .failed, error: laneError(message: "failed"))
            ],
            warnings: [OracleGroupWarning(code: "lane_failures", message: "One lane did not complete")]
        ))

        XCTAssertEqual(reply.result.primary.executionProfile?.providerID, "provider")
        XCTAssertEqual(reply.result.primary.executionProfile?.modelID, "resolved-model")
        XCTAssertEqual(reply.result.primary.executionProfile?.effectiveReasoningEffort, "high")
        XCTAssertEqual(reply.result.warnings.map(\.code), ["lane_failures"])
        XCTAssertEqual(reply.result.warnings.map(\.message), ["One lane did not complete"])
        XCTAssertNotNil(
            reply.toMCPFields()["oracle_results"]?.arrayValue?[0]
                .objectValue?["execution_profile"]
        )
    }

    private func groupResult(
        groupID: UUID = UUID(),
        status: OracleGroupStatus = .completed,
        lanes: [OracleLaneResult],
        warnings: [OracleGroupWarning] = []
    ) throws -> OracleGroupResult {
        try OracleGroupResult(
            groupID: OracleGroupID(rawValue: groupID),
            status: status,
            oracleResults: lanes,
            warnings: warnings
        )
    }

    private func lane(
        index: Int,
        status: OracleLaneResultStatus,
        response: String? = nil,
        error: OracleLaneError? = nil,
        executionProfile: OracleExecutionProfile? = nil
    ) throws -> OracleLaneResult {
        try OracleLaneResult(
            laneIndex: index,
            chatID: "chat-\(index)",
            providerID: "provider-\(index)",
            modelID: "model-\(index)",
            status: status,
            executionProfile: executionProfile,
            response: response,
            error: error
        )
    }

    private func laneError(
        code: String = "provider_failed",
        message: String,
        partialResponse: String? = nil
    ) -> OracleLaneError {
        OracleLaneError(
            code: code,
            message: message,
            partialResponse: partialResponse
        )
    }
}
