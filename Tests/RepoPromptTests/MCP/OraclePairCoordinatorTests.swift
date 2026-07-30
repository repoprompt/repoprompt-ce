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

    @MainActor
    func testClaimRegistryRejectsConcurrentEntryAndReleasesAfterCancellation() async throws {
        let registry = OraclePairClaimRegistry()
        let key = OraclePairClaimKey.route(OraclePairRoute(
            workspaceID: UUID(),
            tabID: UUID(),
            agentModeSessionID: UUID(),
            agentModeRunID: UUID()
        ))
        let started = expectation(description: "claim acquired")
        let first = Task {
            try await registry.withClaim([key]) {
                started.fulfill()
                try await Task.sleep(nanoseconds: .max)
            }
        }
        await fulfillment(of: [started])

        do {
            _ = try await registry.withClaim([key]) { "unexpected" }
            XCTFail("Expected an in-flight route conflict")
        } catch let error as OraclePairClaimError {
            XCTAssertEqual(error, .conflict)
        }

        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let retry = try await registry.withClaim([key]) { "retry" }
        XCTAssertEqual(retry, "retry")
    }

    @MainActor
    func testWorkspaceClaimBlocksRouteEntryUntilRelease() async throws {
        let registry = OraclePairClaimRegistry()
        let workspaceID = UUID()
        let workspaceKey = OraclePairClaimKey.workspace(workspaceID)
        let routeKey = OraclePairClaimKey.route(OraclePairRoute(
            workspaceID: workspaceID,
            tabID: UUID(),
            agentModeSessionID: nil,
            agentModeRunID: nil
        ))
        let started = expectation(description: "workspace claim acquired")
        let first = Task {
            try await registry.withClaim([workspaceKey]) {
                started.fulfill()
                try await Task.sleep(nanoseconds: .max)
            }
        }
        await fulfillment(of: [started])

        do {
            _ = try await registry.withClaim([routeKey]) { "unexpected" }
            XCTFail("Expected workspace deletion to block route entry")
        } catch let error as OraclePairClaimError {
            XCTAssertEqual(error, .conflict)
        }

        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let retry = try await registry.withClaim([routeKey]) { "retry" }
        XCTAssertEqual(retry, "retry")
    }

    @MainActor
    func testCancelledLaneUsesStructuredFailureAndStableReplyOrder() async throws {
        let result = try await OraclePairCoordinator.run(
            primary: { ["response": Value.string("primary reply")] },
            secondary: {
                throw OracleLaneExecutionError(
                    message: "provider cancelled",
                    partialResponse: "secondary partial",
                    code: .cancelled
                )
            }
        )
        let reply = OraclePairSendReply(
            pairID: UUID(),
            primaryChatID: "primary-chat",
            secondaryChatID: "secondary-chat",
            primaryModel: .gpt54Pro,
            secondaryModel: .claude4Sonnet,
            result: result,
            historyDiverged: true,
            historyPersistenceError: nil
        ).toMCPObject(mode: "chat")

        let secondary = reply["oracle_results"]?.objectValue?["secondary"]?.objectValue
        XCTAssertEqual(secondary?["status"]?.stringValue, "failed")
        XCTAssertEqual(secondary?["error_code"]?.stringValue, "cancelled")
        XCTAssertEqual(secondary?["partial_response"]?.stringValue, "secondary partial")
        XCTAssertEqual(reply["status"]?.stringValue, "partial_failure")
        XCTAssertEqual(reply["oracle_history_diverged"]?.boolValue, true)
        let combined = try XCTUnwrap(reply["oracle_combined_response"]?.stringValue)
        XCTAssertLessThan(
            try XCTUnwrap(combined.range(of: "# Primary Oracle")?.lowerBound),
            try XCTUnwrap(combined.range(of: "# Secondary Oracle")?.lowerBound)
        )
    }

    func testHistoryPersistenceMergePreservesConcurrentSessionMetadata() {
        let stored = StoredMessage(isUser: false, rawText: "saved response", sequenceIndex: 0)
        var snapshot = ChatSession(name: "Before Await", messages: [stored])
        snapshot.savedAt = Date(timeIntervalSince1970: 10)
        var current = ChatSession(id: snapshot.id, name: "Renamed During Await")
        current.selectedFilePaths = ["Sources/Changed.swift"]
        let fileURL = URL(fileURLWithPath: "/tmp/session.json")

        let merged = OracleViewModel.mergingPersistedOracleHistory(
            snapshot: snapshot,
            fileURL: fileURL,
            into: current
        )

        XCTAssertEqual(merged.name, "Renamed During Await")
        XCTAssertEqual(merged.selectedFilePaths, ["Sources/Changed.swift"])
        XCTAssertEqual(merged.messages.map(\.rawText), ["saved response"])
        XCTAssertEqual(merged.savedAt, snapshot.savedAt)
        XCTAssertEqual(merged.fileURL, fileURL)
    }

    func testPersistedPairValidationRejectsIncompleteHydrationAsConflict() throws {
        let pairID = UUID()
        let workspaceID = UUID()
        let tabID = UUID()
        let primary = ChatSession(
            workspaceID: workspaceID,
            composeTabID: tabID,
            oraclePairID: pairID,
            oracleLane: .primary,
            name: "Primary"
        )

        XCTAssertThrowsError(try OracleViewModel.validatedPersistedOraclePairMembers(
            [primary],
            pairID: pairID,
            workspaceID: workspaceID,
            tabID: tabID,
            agentModeSessionID: nil,
            agentModeRunID: nil
        )) { error in
            guard let toolError = error as? ChatToolError else {
                return XCTFail("Expected ChatToolError, got \(error)")
            }
            XCTAssertEqual(toolError.code, .conflict)
            XCTAssertTrue(toolError.message.contains("incomplete"))
        }
    }

    func testHistoryDivergenceUsesExactUserTurnSequence() {
        XCTAssertFalse(OracleViewModel.oracleHistoriesDiverged(
            primary: ["first", "second"],
            secondary: ["first", "second"]
        ))
        XCTAssertTrue(OracleViewModel.oracleHistoriesDiverged(
            primary: ["first", "second"],
            secondary: ["first", "different"]
        ))
        XCTAssertTrue(OracleViewModel.oracleHistoriesDiverged(
            primary: ["first"],
            secondary: ["first", "second"]
        ))
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
