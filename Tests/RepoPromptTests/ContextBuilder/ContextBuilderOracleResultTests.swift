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

    func testStrictPrimaryResponseAccessorStillRejectsFailedOrCancelledPrimary() throws {
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

    @MainActor
    func testSettledReplyBoundaryDeliversFailedPrimaryAndKeepsErrorNavigation() throws {
        for mode in [HeadlessMode.plan, .review] {
            for primaryStatus in [OracleLaneResultStatus.failed, .cancelled] {
                let result = try groupResult(status: .failed, lanes: [
                    lane(index: 0, status: primaryStatus, error: laneError(
                        code: "primary_stopped", message: "primary stopped", partialResponse: "primary partial"
                    )),
                    lane(index: 1, status: .completed, response: "Error: is legitimate answer text"),
                    lane(index: 2, status: .completed, response: "third answer")
                ])
                let (session, generation, members) = try preparedSession(for: result)
                let workspaceID = UUID()
                let reply = try session.completeOracleGroupReply(
                    ContextBuilderOracleGroupReply(result: result),
                    generation: generation,
                    originWorkspaceID: workspaceID,
                    mode: mode
                )
                XCTAssertEqual(reply.chatId, members[0].sessionID)
                XCTAssertEqual(reply.shortId, "chat-0")
                XCTAssertNil(reply.response, "A secondary answer must never become the primary response")
                XCTAssertEqual(reply.oracleGroup?.result, result)
                XCTAssertEqual(reply.errors, ["Oracle \(primaryStatus.rawValue): primary stopped"])
                XCTAssertFalse(session.isBackgroundPlanGenerating)
                XCTAssertEqual(session.backgroundPlanResponseText, "primary partial")
                guard case let .error(message) = session.planStatus else {
                    return XCTFail("Primary failure must remain visible")
                }
                XCTAssertTrue(message.contains("primary stopped"))
                XCTAssertEqual(session.failedAnswerRoute, ContextBuilderGeneratedAnswerRoute(
                    workspaceID: workspaceID, tabID: session.tabID, chatID: "chat-0"
                ))
                XCTAssertTrue(session.followUpOracleGroupState.members.isEmpty)

                let branch = mode == .review ? "review" : "plan"
                let raw: Value = .object([
                    "response_type": .string(branch),
                    branch: reply.toMCPValue()
                ])
                let dto = try XCTUnwrap(raw.decode(ToolResultDTOs.ContextBuilderDTO.self))
                let summaries = contextBuilderOracleLaneSummaries(for: dto)
                XCTAssertEqual(summaries.map(\.chatID), ["chat-0", "chat-1", "chat-2"])
                XCTAssertEqual(summaries.map(\.status), [primaryStatus.rawValue, "done", "done"])
                XCTAssertEqual(contextBuilderFollowUpChatID(for: dto), "chat-0")
                let text = ToolOutputFormatter.formatDiscoverContext(value: raw).compactMap { block -> String? in
                    guard case let .text(text, _, _) = block else { return nil }
                    return text
                }.joined(separator: "\n")
                XCTAssertTrue(text.contains("primary stopped"), text)
                XCTAssertTrue(text.contains("Error: is legitimate answer text"), text)
                XCTAssertTrue(text.contains("third answer"), text)
            }
        }
    }

    @MainActor
    func testSettledReplyBoundaryPreservesSuccessAndPartialFailure() throws {
        for additionalStatus in [OracleLaneResultStatus.completed, .failed] {
            let result = try groupResult(
                status: additionalStatus == .completed ? .completed : .partialFailure,
                lanes: [
                    lane(index: 0, status: .completed, response: "primary answer"),
                    lane(index: 1, status: additionalStatus,
                         response: additionalStatus == .completed ? "second answer" : nil,
                         error: additionalStatus == .failed ? laneError(message: "second failed") : nil)
                ]
            )
            let (session, generation, _) = try preparedSession(for: result)
            let reply = try session.completeOracleGroupReply(
                ContextBuilderOracleGroupReply(result: result), generation: generation,
                originWorkspaceID: UUID(), mode: .plan
            )
            XCTAssertEqual(reply.response, "primary answer")
            XCTAssertEqual(reply.oracleGroup?.result, result)
            XCTAssertNil(session.backgroundPlanError)
            XCTAssertNil(session.failedAnswerRoute)
            guard case .ready = session.planStatus else { return XCTFail("Expected ready") }
        }
    }

    @MainActor
    func testSettledReplyBoundaryRejectsStaleGenerationAndMismatchedMembershipBeforeMutation() throws {
        let result = try groupResult(lanes: [
            lane(index: 0, status: .completed, response: "primary"),
            lane(index: 1, status: .completed, response: "secondary")
        ])
        let (session, generation, members) = try preparedSession(for: result)
        let differentGroup = try groupResult(lanes: result.oracleResults)
        XCTAssertThrowsError(try session.completeOracleGroupReply(
            ContextBuilderOracleGroupReply(result: differentGroup), generation: generation,
            originWorkspaceID: UUID(), mode: .review
        ))
        XCTAssertEqual(session.followUpOracleGroupState.members, members)
        XCTAssertTrue(session.isBackgroundPlanGenerating)
        XCTAssertNil(session.generatedAnswerRoute)

        let wrongMember = try OracleLaneResult(
            laneIndex: 1, chatID: "different-chat", providerID: "provider-1", modelID: "model-1",
            status: .completed, response: "unrelated answer"
        )
        let mismatchedMembers = try groupResult(
            groupID: result.groupID.rawValue, lanes: [result.primary, wrongMember]
        )
        XCTAssertThrowsError(try session.completeOracleGroupReply(
            ContextBuilderOracleGroupReply(result: mismatchedMembers), generation: generation,
            originWorkspaceID: UUID(), mode: .review
        ))
        XCTAssertEqual(session.followUpOracleGroupState.members, members)
        XCTAssertNil(session.generatedAnswerRoute)

        _ = session.followUpOracleGroupState.beginRun()
        XCTAssertThrowsError(try session.completeOracleGroupReply(
            ContextBuilderOracleGroupReply(result: result), generation: generation,
            originWorkspaceID: UUID(), mode: .review
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(session.isBackgroundPlanGenerating)
        XCTAssertNil(session.generatedAnswerRoute)
    }

    @MainActor
    func testSettledReplyBoundaryHonorsTaskCancellation() async throws {
        let result = try groupResult(lanes: [
            lane(index: 0, status: .completed, response: "primary"),
            lane(index: 1, status: .completed, response: "secondary")
        ])
        let (session, generation, members) = try preparedSession(for: result)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try session.completeOracleGroupReply(
                ContextBuilderOracleGroupReply(result: result), generation: generation,
                originWorkspaceID: UUID(), mode: .review
            )
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled work must not publish a reply")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(session.followUpOracleGroupState.members, members)
        XCTAssertTrue(session.isBackgroundPlanGenerating)
        XCTAssertNil(session.generatedAnswerRoute)
    }

    @MainActor
    private func preparedSession(for result: OracleGroupResult) throws -> (
        ContextBuilderAgentViewModel.TabSession, UInt64, [ContextBuilderOracleMemberHandle]
    ) {
        let session = ContextBuilderAgentViewModel.TabSession(tabID: UUID())
        session.isBackgroundPlanGenerating = true
        let generation = session.followUpOracleGroupState.beginRun()
        let members = try result.oracleResults.map {
            ContextBuilderOracleMemberHandle(
                laneID: try OracleLaneID(index: $0.laneIndex), sessionID: UUID(), chatID: $0.chatID
            )
        }
        XCTAssertTrue(session.followUpOracleGroupState.bind(
            groupID: result.groupID, turnID: OracleTurnID(), members: members, generation: generation
        ))
        return (session, generation, members)
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
