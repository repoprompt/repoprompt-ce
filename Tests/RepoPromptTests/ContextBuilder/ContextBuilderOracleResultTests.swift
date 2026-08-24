import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class ContextBuilderOracleResultTests: XCTestCase {
    func testGroupReplyAndToolCardPreserveOrderedUnsynthesizedLanes() throws {
        let groupID = UUID().uuidString
        let lanes: [Value] = [
            lane(index: 0, status: "completed", response: "primary answer"),
            lane(index: 1, status: "completed", response: "adviser answer"),
            lane(index: 2, status: "failed", error: "adviser failed")
        ]
        let value = groupValue(groupID: groupID, status: "partial_failure", lanes: lanes)
        let reply = try ContextBuilderOracleGroupReply.decode(value)
        XCTAssertEqual(reply.orderedResults.map(\.laneIndex), [0, 1, 2])
        XCTAssertEqual(reply.result.primary.response, "primary answer")
        XCTAssertEqual(try reply.requiredCompletedPrimaryResponse(), "primary answer")
        XCTAssertEqual(reply.toMCPFields()["oracle_count"]?.intValue, 3)

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

    func testFailedOrCancelledPrimaryIsNotPublishable() throws {
        for status in [OracleLaneResultStatus.failed, .cancelled] {
            var primary = laneObject(index: 0, status: status.rawValue, error: "primary stopped")
            primary["error"] = .object([
                "code": .string("primary_stopped"),
                "message": .string("primary stopped"),
                "partial_response": .string("primary partial")
            ])
            let reply = try ContextBuilderOracleGroupReply.decode(groupValue(
                status: "failed",
                lanes: [
                    .object(primary),
                    lane(index: 1, status: "completed", response: "auxiliary answer")
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
        let reply = try ContextBuilderOracleGroupReply.decode(groupValue(
            status: "partial_failure",
            lanes: [
                lane(index: 0, status: "completed", response: "primary answer"),
                lane(index: 1, status: "failed", error: "auxiliary failed")
            ]
        ))

        XCTAssertEqual(try reply.requiredCompletedPrimaryResponse(), "primary answer")
        XCTAssertEqual(reply.result.status, .partialFailure)
    }

    func testDecodeRejectsCompletedPrimaryWithWhitespaceOnlyResponse() {
        XCTAssertThrowsError(try ContextBuilderOracleGroupReply.decode(groupValue(
            lanes: [
                lane(index: 0, status: "completed", response: "  \n"),
                lane(index: 1, status: "completed", response: "auxiliary answer")
            ]
        )))
    }

    func testDecodePreservesExecutionProfileAndWarnings() throws {
        var primary = laneObject(index: 0, status: "completed", response: "primary")
        primary["execution_profile"] = .object([
            "provider_id": .string("provider"),
            "model_id": .string("resolved-model"),
            "effective_reasoning_effort": .string("high")
        ])
        let warnings: Value = .array([
            .object([
                "code": .string("lane_failures"),
                "message": .string("One lane did not complete")
            ])
        ])
        let reply = try ContextBuilderOracleGroupReply.decode(groupValue(
            status: "partial_failure",
            lanes: [
                .object(primary),
                lane(index: 1, status: "failed", error: "failed")
            ],
            warnings: warnings
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

    func testDecodeRejectsWrongTypedPresentOptionalLaneFields() {
        let malformedFields: [(String, Value)] = [
            ("provider_id", .int(7)),
            ("execution_profile", .string("profile")),
            ("error", .string("failed"))
        ]
        for (field, malformedValue) in malformedFields {
            var primary = laneObject(index: 0, status: "completed", response: "primary")
            primary[field] = malformedValue
            XCTAssertThrowsError(
                try ContextBuilderOracleGroupReply.decode(groupValue(
                    lanes: [.object(primary), lane(index: 1, status: "completed", response: "additional")]
                )),
                "Expected malformed \(field) to fail"
            )
        }

        var failedAdditional = laneObject(index: 1, status: "failed", error: "failed")
        failedAdditional["response"] = .bool(true)
        XCTAssertThrowsError(try ContextBuilderOracleGroupReply.decode(groupValue(
            status: "partial_failure",
            lanes: [
                lane(index: 0, status: "completed", response: "primary"),
                .object(failedAdditional)
            ]
        )))
    }

    func testDecodeRejectsWrongTypedNestedOptionalFields() {
        for field in ["provider_id", "model_id"] {
            var wrongRequiredProfileField = laneObject(
                index: 0,
                status: "completed",
                response: "primary"
            )
            var profile: [String: Value] = [
                "provider_id": .string("provider"),
                "model_id": .string("resolved-model")
            ]
            profile[field] = .int(7)
            wrongRequiredProfileField["execution_profile"] = .object(profile)
            XCTAssertThrowsError(try ContextBuilderOracleGroupReply.decode(groupValue(
                lanes: [
                    .object(wrongRequiredProfileField),
                    lane(index: 1, status: "completed", response: "additional")
                ]
            )))
        }

        var wrongEffort = laneObject(index: 0, status: "completed", response: "primary")
        wrongEffort["execution_profile"] = .object([
            "provider_id": .string("provider"),
            "model_id": .string("resolved-model"),
            "effective_reasoning_effort": .bool(true)
        ])
        XCTAssertThrowsError(try ContextBuilderOracleGroupReply.decode(groupValue(
            lanes: [.object(wrongEffort), lane(index: 1, status: "completed", response: "additional")]
        )))

        var wrongPartial = laneObject(index: 1, status: "failed", error: "failed")
        wrongPartial["error"] = .object([
            "code": .string("provider_failed"),
            "message": .string("failed"),
            "partial_response": .int(7)
        ])
        XCTAssertThrowsError(try ContextBuilderOracleGroupReply.decode(groupValue(
            status: "partial_failure",
            lanes: [lane(index: 0, status: "completed", response: "primary"), .object(wrongPartial)]
        )))

        var missingErrorMessage = laneObject(index: 1, status: "failed")
        missingErrorMessage["error"] = .object(["code": .string("provider_failed")])
        XCTAssertThrowsError(try ContextBuilderOracleGroupReply.decode(groupValue(
            status: "partial_failure",
            lanes: [lane(index: 0, status: "completed", response: "primary"), .object(missingErrorMessage)]
        )))
    }

    func testDecodeRejectsWrongTypedWarningsWhenPresent() {
        XCTAssertThrowsError(try ContextBuilderOracleGroupReply.decode(groupValue(
            lanes: [
                lane(index: 0, status: "completed", response: "primary"),
                lane(index: 1, status: "completed", response: "additional")
            ],
            warnings: .string("warning")
        )))
    }

    func testDecodeRejectsRoleThatDoesNotMatchLaneIndex() {
        let value = groupValue(
            lanes: [
                lane(index: 0, role: "additional", status: "completed", response: "answer"),
                lane(index: 1, status: "completed", response: "additional")
            ]
        )

        XCTAssertThrowsError(try ContextBuilderOracleGroupReply.decode(value))
    }

    private func groupValue(
        groupID: String = UUID().uuidString,
        status: String = "completed",
        lanes: [Value],
        warnings: Value? = nil
    ) -> [String: Value] {
        var value: [String: Value] = [
            "oracle_group_id": .string(groupID),
            "status": .string(status),
            "oracle_count": .int(lanes.count),
            "oracle_results": .array(lanes)
        ]
        if let warnings {
            value["warnings"] = warnings
        }
        return value
    }

    private func lane(
        index: Int,
        role: String? = nil,
        status: String,
        response: String? = nil,
        error: String? = nil
    ) -> Value {
        .object(laneObject(
            index: index,
            role: role,
            status: status,
            response: response,
            error: error
        ))
    }

    private func laneObject(
        index: Int,
        role: String? = nil,
        status: String,
        response: String? = nil,
        error: String? = nil
    ) -> [String: Value] {
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
        return object
    }
}
