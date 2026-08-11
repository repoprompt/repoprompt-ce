import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

final class OraclePairCoordinatorTests: XCTestCase {
    private func reply(_ lane: String) -> ChatSendReply {
        ChatSendReply(
            chatId: UUID(),
            shortId: "\(lane)-chat",
            mode: "chat",
            response: "\(lane) response",
            errors: nil
        )
    }

    func testLaneMetadataUsesOneValidatedOrderedPrefix() throws {
        let lanes = try OracleLane.orderedPrefix(count: 5)
        XCTAssertEqual(lanes.map(\.rawValue), ["primary", "secondary", "oracle_3", "oracle_4", "oracle_5"])
        XCTAssertEqual(lanes.map(\.ordinal), [1, 2, 3, 4, 5])
        XCTAssertEqual(
            lanes.map(\.displayLabel),
            ["Primary Oracle", "Secondary Oracle", "Oracle 3", "Oracle 4", "Oracle 5"]
        )
        XCTAssertNoThrow(try OracleLane.validateOrderedPrefix(lanes))
        XCTAssertThrowsError(try OracleLane.validateOrderedPrefix([.primary, .oracle3]))
        XCTAssertThrowsError(try OracleLane.orderedPrefix(count: 0))
        XCTAssertThrowsError(try OracleLane.orderedPrefix(count: 6))
    }

    @MainActor
    func testFiveLaneCoordinatorReturnsConfiguredOrderWhenCompletionOrderDiffers() async throws {
        let lanes = try OracleLane.orderedPrefix(count: 5)
        var operations: [OracleLane: OraclePairCoordinator.Operation<String>] = [:]
        for lane in lanes {
            operations[lane] = {
                try await Task.sleep(nanoseconds: UInt64(6 - lane.ordinal) * 1_000_000)
                return lane.rawValue
            }
        }

        let result = try await OraclePairCoordinator.run(operationsByLane: operations)

        XCTAssertEqual(result.orderedLanes, lanes)
        XCTAssertEqual(result.orderedResults.compactMap { laneResult in
            guard case let .success(value) = laneResult.execution else { return nil }
            return value
        }, lanes.map(\.rawValue))
        XCTAssertThrowsError(try OraclePairCoordinator.Result<String>(executionsByLane: [
            .primary: .success("primary"),
            .oracle3: .success("oracle_3")
        ]))
    }

    func testChatSessionInfersLegacyPairSizeAndRoundTripsExplicitGroupSize() throws {
        let pairID = UUID()
        let legacy = ChatSession(
            oraclePairID: pairID,
            oracleLane: .secondary,
            name: "Legacy pair"
        )
        XCTAssertEqual(legacy.oracleGroupSize, 2)
        XCTAssertEqual(legacy.oracleGroupID, pairID)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "oracleGroupSize")
        let decodedLegacy = try JSONDecoder().decode(
            ChatSession.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        XCTAssertEqual(decodedLegacy.oracleGroupSize, 2)

        let grouped = ChatSession(
            oraclePairID: UUID(),
            oracleLane: .oracle5,
            oracleGroupSize: 5,
            name: "Five Oracles"
        )
        let decodedGroup = try JSONDecoder().decode(ChatSession.self, from: JSONEncoder().encode(grouped))
        XCTAssertEqual(decodedGroup.oracleLane, .oracle5)
        XCTAssertEqual(decodedGroup.oracleGroupSize, 5)
    }

    func testFiveLaneTransportIsOrderedAndPreservesPairAliases() throws {
        let groupID = UUID()
        let lanes = try OracleLane.orderedPrefix(count: 5)
        let sessionIDsByLane = Dictionary(uniqueKeysWithValues: lanes.map { ($0, UUID()) })
        let chatIDsByLane = Dictionary(uniqueKeysWithValues: lanes.map { ($0, "\($0.rawValue)-chat") })
        let modelsByLane = Dictionary(uniqueKeysWithValues: lanes.map { ($0, AIModel.gpt54Pro) })
        var executions: [OracleLane: OraclePairCoordinator.LaneExecution<ChatSendReply>] = [:]
        for lane in lanes {
            executions[lane] = .success(ChatSendReply(
                chatId: try XCTUnwrap(sessionIDsByLane[lane]),
                shortId: try XCTUnwrap(chatIDsByLane[lane]),
                mode: "chat",
                response: "\(lane.rawValue) response",
                errors: nil
            ))
        }
        let result = try OraclePairCoordinator.Result(executionsByLane: executions)
        var incompleteChatIDs = chatIDsByLane
        incompleteChatIDs.removeValue(forKey: .oracle5)
        XCTAssertThrowsError(
            try OracleGroupSendReply(
                groupID: groupID,
                mode: "chat",
                sessionIDsByLane: sessionIDsByLane,
                chatIDsByLane: incompleteChatIDs,
                modelsByLane: modelsByLane,
                result: result,
                historyDiverged: false,
                historyPersistenceError: nil
            )
        )
        let reply = try OracleGroupSendReply(
            groupID: groupID,
            mode: "chat",
            sessionIDsByLane: sessionIDsByLane,
            chatIDsByLane: chatIDsByLane,
            modelsByLane: modelsByLane,
            result: result,
            historyDiverged: false,
            historyPersistenceError: nil
        )

        let object = reply.toMCPObject()
        XCTAssertEqual(object["chat_id"]?.stringValue, "primary-chat")
        XCTAssertEqual(object["oracle_group_id"]?.stringValue, groupID.uuidString)
        XCTAssertEqual(object["oracle_pair_id"]?.stringValue, groupID.uuidString)
        XCTAssertEqual(object["oracle_count"]?.intValue, 5)
        XCTAssertEqual(object["primary_chat_id"]?.stringValue, "primary-chat")
        XCTAssertEqual(object["secondary_chat_id"]?.stringValue, "secondary-chat")
        XCTAssertEqual(
            object["oracle_result_order"]?.arrayValue?.compactMap(\.stringValue),
            lanes.map(\.rawValue)
        )
        XCTAssertEqual(
            object["oracle_chat_ids"]?.objectValue?.compactMapValues(\.stringValue),
            Dictionary(uniqueKeysWithValues: lanes.compactMap { lane in
                chatIDsByLane[lane].map { (lane.rawValue, $0) }
            })
        )
        XCTAssertEqual(object["oracle_group_results"]?.arrayValue?.count, 5)
        XCTAssertEqual(
            object["oracle_results"]?.objectValue?["oracle_5"]?.objectValue?["oracle_ordinal"]?.intValue,
            5
        )

        let payload = ToolOutputFormatter.rawJSONString(.object(object))
        let decoded = try JSONDecoder().decode(ToolResultDTOs.ChatSendDTO.self, from: Data(payload.utf8))
        XCTAssertEqual(decoded.oracleGroupID, groupID.uuidString)
        XCTAssertEqual(decoded.oraclePairID, groupID.uuidString)
        XCTAssertEqual(decoded.oracleCount, 5)
        XCTAssertEqual(decoded.oracleResultOrder, lanes.map(\.rawValue))
        XCTAssertEqual(decoded.oracleChatIDs, chatIDsByLane.reduce(into: [:]) { result, entry in
            result[entry.key.rawValue] = entry.value
        })
        XCTAssertEqual(decoded.oracleGroupResults?.map(\.oracleLane), lanes.map(\.rawValue))
        XCTAssertEqual(decoded.oracleResults?["oracle_5"]?.oracleLabel, "Oracle 5")
    }

    func testSingleReplyTransportRemainsFlat() {
        let object = reply("single").toMCPObject()
        XCTAssertEqual(Set(object.keys), ["chat_id", "mode", "response"])
        XCTAssertNil(object["oracle_group_id"])
        XCTAssertNil(object["oracle_pair_id"])
        XCTAssertNil(object["oracle_results"])
    }

    @MainActor
    func testReturnsBothSuccessfulLanesInStableOrder() async throws {
        let result = try await OraclePairCoordinator.run(
            primary: { "primary" },
            secondary: { "secondary" }
        )
        guard case let .success(primary) = result.primary,
              case let .success(secondary) = result.secondary
        else { return XCTFail("Expected both lanes to succeed") }
        XCTAssertEqual(primary, "primary")
        XCTAssertEqual(secondary, "secondary")
    }

    @MainActor
    func testPartialFailureKeepsMinimalLanePayload() async throws {
        let result = try await OraclePairCoordinator.run(
            primary: { self.reply("primary") },
            secondary: { throw OracleLaneFailure(message: "secondary failed", partialResponse: "partial") }
        )
        let object = OraclePairSendReply(
            pairID: UUID(),
            mode: "chat",
            primarySessionID: UUID(),
            primaryChatID: "primary-chat",
            secondaryChatID: "secondary-chat",
            primaryModel: .gpt54Pro,
            secondaryModel: .claude4Sonnet,
            result: result,
            historyDiverged: false,
            historyPersistenceError: nil
        ).toMCPObject()

        XCTAssertEqual(object["status"]?.stringValue, "partial_failure")
        XCTAssertEqual(object["response"]?.stringValue, "primary response")
        XCTAssertEqual(
            object["errors"]?.arrayValue?.compactMap(\.stringValue),
            ["Secondary Oracle failed: secondary failed"]
        )
        XCTAssertEqual(
            object["oracle_results"]?.objectValue?["secondary"]?.objectValue?["partial_response"]?.stringValue,
            "partial"
        )
        XCTAssertNil(object["oracle_decision_policy"])
        XCTAssertNil(object["oracle_combined_response"])
    }

    func testHistoryPersistenceFailureDowngradesTypedAndSerializedStatus() {
        let pair = OraclePairSendReply(
            pairID: UUID(),
            mode: "chat",
            primarySessionID: UUID(),
            primaryChatID: "primary-chat",
            secondaryChatID: "secondary-chat",
            primaryModel: .gpt54Pro,
            secondaryModel: .claude4Sonnet,
            result: .init(
                primary: .success(reply("primary")),
                secondary: .success(reply("secondary"))
            ),
            historyDiverged: false,
            historyPersistenceError: "disk unavailable"
        )

        XCTAssertEqual(pair.status, .partialFailure)
        XCTAssertEqual(pair.toMCPObject()["status"]?.stringValue, "partial_failure")
    }

    func testPrimaryReplyProjectsSuccessAndPairWarnings() {
        let primary = reply("primary")
        let pair = OraclePairSendReply(
            pairID: UUID(),
            mode: "chat",
            primarySessionID: UUID(),
            primaryChatID: "primary-chat",
            secondaryChatID: "secondary-chat",
            primaryModel: .gpt54Pro,
            secondaryModel: .claude4Sonnet,
            result: .init(
                primary: .success(primary),
                secondary: .failure(.init(message: "secondary failed"))
            ),
            historyDiverged: false,
            historyPersistenceError: "disk unavailable"
        )

        let projected = pair.primaryReply()
        XCTAssertEqual(projected.chatId, primary.chatId)
        XCTAssertEqual(projected.shortId, "primary-chat")
        XCTAssertEqual(projected.response, "primary response")
        XCTAssertEqual(
            projected.errors,
            ["Secondary Oracle failed: secondary failed\nOracle pair history persistence failed: disk unavailable"]
        )
    }

    func testPrimaryReplyUsesResolvedSessionForFailedPrimary() {
        let primarySessionID = UUID()
        let pair = OraclePairSendReply(
            pairID: UUID(),
            mode: "plan",
            primarySessionID: primarySessionID,
            primaryChatID: "primary-chat",
            secondaryChatID: "secondary-chat",
            primaryModel: .gpt54Pro,
            secondaryModel: .claude4Sonnet,
            result: .init(
                primary: .failure(.init(message: "primary failed", partialResponse: "partial")),
                secondary: .success(reply("secondary"))
            ),
            historyDiverged: false,
            historyPersistenceError: nil
        )

        let projected = pair.primaryReply()
        XCTAssertEqual(projected.chatId, primarySessionID)
        XCTAssertEqual(projected.shortId, "primary-chat")
        XCTAssertEqual(projected.mode, "plan")
        XCTAssertEqual(projected.response, "partial")
        XCTAssertEqual(projected.errors, ["Primary Oracle failed: primary failed"])
    }

    @MainActor
    func testCancellationCancelsThePairInsteadOfReturningLaneFailures() async throws {
        let started = expectation(description: "both lanes started")
        started.expectedFulfillmentCount = 2
        let task = Task {
            try await OraclePairCoordinator.run(
                primary: {
                    started.fulfill()
                    try await Task.sleep(nanoseconds: .max)
                    return "primary"
                },
                secondary: {
                    started.fulfill()
                    try await Task.sleep(nanoseconds: .max)
                    return "secondary"
                }
            )
        }

        await fulfillment(of: [started])
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    @MainActor
    func testRouteAndWorkspaceClaimsConflictAndRelease() async throws {
        let registry = OracleSendClaimRegistry()
        let workspaceID = UUID()
        let route = OracleSendClaimKey.route(OraclePairRoute(
            workspaceID: workspaceID,
            tabID: UUID(),
            agentModeSessionID: UUID(),
            agentModeRunID: UUID()
        ))
        let started = expectation(description: "workspace claim acquired")
        let first = Task {
            try await registry.withClaim([.workspace(workspaceID)]) {
                started.fulfill()
                try await Task.sleep(nanoseconds: .max)
            }
        }
        await fulfillment(of: [started])

        do {
            _ = try await registry.withClaim([route]) { "unexpected" }
            XCTFail("Expected a conflict")
        } catch let error as OracleSendClaimError {
            XCTAssertEqual(error, .conflict)
        }

        first.cancel()
        do { _ = try await first.value } catch is CancellationError {}
        let retry = try await registry.withClaim([route]) { "retry" }
        XCTAssertEqual(retry, "retry")
    }

    @MainActor
    func testAllLaneFailureSurvivesStructuredMCPEnvelope() throws {
        let pairID = UUID()
        let contextID = UUID()
        let pairReply = OraclePairSendReply(
            pairID: pairID,
            mode: "chat",
            primarySessionID: UUID(),
            primaryChatID: "primary-chat",
            secondaryChatID: "secondary-chat",
            primaryModel: .gpt54Pro,
            secondaryModel: .claude4Sonnet,
            result: .init(
                primary: .failure(.init(message: "primary failed", partialResponse: "primary partial")),
                secondary: .failure(.init(message: "secondary failed"))
            ),
            historyDiverged: true,
            historyPersistenceError: nil
        )
        let sendResult = OracleSendResult(
            payload: .paired(pairReply),
            route: OracleSendRoute(contextID: contextID, agentSessionID: nil, agentRunID: nil)
        )
        let payload = ToolOutputFormatter.rawJSONString(.object(sendResult.toMCPObject()))
        let error = try ChatToolError(
            code: .internalError,
            message: XCTUnwrap(pairReply.failureSummary),
            details: ["oracle_pair_payload": payload]
        )
        guard case let .serverError(_, message) = try XCTUnwrap(MCPOracleToolService.structuredOracleSendMCPError(error)) else {
            return XCTFail("Expected structured server error")
        }

        let data = try JSONSerialization.data(withJSONObject: ["error": message])
        let decoded = try JSONDecoder().decode(ToolResultDTOs.ChatSendDTO.self, from: data)
        XCTAssertEqual(decoded.status, "failed")
        XCTAssertEqual(decoded.oraclePairID, pairID.uuidString)
        XCTAssertEqual(decoded.contextID, contextID.uuidString)
        XCTAssertEqual(decoded.oracleResults?["primary"]?.partialResponse, "primary partial")
        XCTAssertEqual(decoded.oracleResults?["secondary"]?.error, "secondary failed")
    }

    func testDuplicateMessageIdentityIsRejectedWithoutTrapping() {
        let duplicateID = UUID()
        let messages = [
            AIChatMessage(id: duplicateID, content: "first", isUser: true),
            AIChatMessage(id: duplicateID, content: "second", isUser: false)
        ]
        XCTAssertThrowsError(try OracleViewModel.storedOracleMessages(messages, preserving: [])) { error in
            XCTAssertEqual((error as? ChatToolError)?.code, .conflict)
            XCTAssertEqual((error as? ChatToolError)?.details?["duplicate_id"], duplicateID.uuidString)
        }
    }

    func testHistoryDivergenceUsesExactUserTurnSequence() {
        XCTAssertFalse(OracleViewModel.oracleHistoriesDiverged(
            primary: ["first", "second"],
            secondary: ["first", "second"]
        ))
        XCTAssertTrue(OracleViewModel.oracleHistoriesDiverged(
            primary: ["first", "second"],
            secondary: ["first", "changed"]
        ))
    }
}
