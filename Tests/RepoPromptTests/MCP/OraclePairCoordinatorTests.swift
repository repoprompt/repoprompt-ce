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

    func testPrimaryReplyUsesFallbackForFailedPrimary() {
        let fallback = UUID()
        let pair = OraclePairSendReply(
            pairID: UUID(),
            mode: "plan",
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

        let projected = pair.primaryReply(fallbackSessionID: fallback)
        XCTAssertEqual(projected.chatId, fallback)
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
