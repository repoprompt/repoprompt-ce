import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

final class OraclePairCoordinatorTests: XCTestCase {
    @MainActor
    func testReturnsBothSuccessfulLanesInStableOrder() async throws {
        let result = try await OraclePairCoordinator.run(
            primary: { "primary" },
            secondary: { "secondary" }
        )

        guard case let .success(primary) = result.primary,
              case let .success(secondary) = result.secondary
        else {
            return XCTFail("Expected both Oracle lanes to succeed")
        }
        XCTAssertEqual(primary, "primary")
        XCTAssertEqual(secondary, "secondary")
    }

    @MainActor
    func testPreservesOneLaneFailureWithoutInventingHistoryDivergence() async throws {
        let result = try await OraclePairCoordinator.run(
            primary: { ["response": Value.string("primary")] },
            secondary: { throw OracleLaneExecutionError(message: "secondary failed") }
        )
        let reply = OraclePairSendReply(
            pairID: UUID(),
            primaryChatID: "primary-chat",
            secondaryChatID: "secondary-chat",
            primaryModel: .gpt54Pro,
            secondaryModel: .claude4Sonnet,
            result: result,
            historyDiverged: false,
            historyPersistenceError: nil
        ).toMCPObject(mode: "chat")

        XCTAssertEqual(reply["status"]?.stringValue, "partial_failure")
        XCTAssertEqual(reply["oracle_history_diverged"]?.boolValue, false)
        XCTAssertEqual(
            reply["oracle_results"]?.objectValue?["secondary"]?.objectValue?["error"]?.stringValue,
            "secondary failed"
        )
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
            XCTFail("Expected pair cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testChatSessionPersistsPairLifecycleMetadataAndLegacyDefaults() throws {
        let pairID = UUID()
        let session = ChatSession(
            oraclePairID: pairID,
            oracleLane: .secondary,
            oracleHistoryDiverged: true,
            name: "Paired"
        )
        let decoded = try JSONDecoder().decode(ChatSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.oraclePairID, pairID)
        XCTAssertEqual(decoded.oracleLane, .secondary)
        XCTAssertTrue(decoded.oracleHistoryDiverged)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(ChatSession(name: "Legacy"))) as? [String: Any]
        )
        object.removeValue(forKey: "oraclePairID")
        object.removeValue(forKey: "oracleLane")
        object.removeValue(forKey: "oracleHistoryDiverged")
        let legacy = try JSONDecoder().decode(
            ChatSession.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(legacy.oraclePairID)
        XCTAssertNil(legacy.oracleLane)
        XCTAssertFalse(legacy.oracleHistoryDiverged)
    }
}
