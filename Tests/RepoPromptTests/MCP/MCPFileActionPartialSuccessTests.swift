import MCP
@testable import RepoPromptApp
import XCTest

final class MCPFileActionPartialSuccessTests: XCTestCase {
    func testCreateSelectionPersistenceWarningPreservesSuccessfulFileAction() throws {
        let warning = "The file was created, but its selection was not confirmed. Retry manage_selection."
        let dto = ToolResultDTOs.FileActionReply(
            status: "ok",
            action: "create",
            path: "/tmp/Created.swift",
            newPath: nil,
            warning: warning
        )
        let value = try Self.value(dto)

        let decoded = try XCTUnwrap(value.decode(ToolResultDTOs.FileActionReply.self))
        XCTAssertEqual(decoded.status, "ok")
        XCTAssertEqual(decoded.warning, warning)

        let text = try Self.onlyText(ToolOutputFormatter.formatFileAction(value: value))
        XCTAssertTrue(text.contains("## File Action ✅"), text)
        XCTAssertTrue(text.contains("- Warning: \(warning)"), text)
    }

    func testFreshnessPendingAcknowledgementIsAppliedAndNotBlindlyRetryable() throws {
        let dto = ToolResultDTOs.FileActionReply(
            status: "ok",
            action: "move",
            path: "/tmp/Old.swift",
            newPath: "/tmp/New.swift",
            warning: "Mutation durable; inspect the filesystem before retry and use the operation ID only for correlation.",
            operationID: "operation-123",
            mutationState: "applied",
            freshness: "pending"
        )
        let value = try Self.value(dto)
        let decoded = try XCTUnwrap(value.decode(ToolResultDTOs.FileActionReply.self))

        XCTAssertEqual(decoded.operationID, "operation-123")
        XCTAssertEqual(decoded.mutationState, "applied")
        XCTAssertEqual(decoded.freshness, "pending")
        XCTAssertNil(decoded.retryable)

        let text = try Self.onlyText(ToolOutputFormatter.formatFileAction(value: value))
        XCTAssertTrue(text.contains("Operation ID: `operation-123`"), text)
        XCTAssertTrue(text.contains("Mutation: applied"), text)
        XCTAssertTrue(text.contains("Freshness: pending"), text)
        XCTAssertFalse(text.contains("Retryable: yes"), text)
    }

    func testApplyEditsFreshnessPendingAcknowledgementWarnsAgainstReplay() throws {
        let dto = ToolResultDTOs.EditSummary(
            status: "success",
            editsRequested: 1,
            editsApplied: 1,
            addedLines: 1,
            deletedLines: 0,
            totalLinesChanged: 1,
            totalChunks: 1,
            results: nil,
            unifiedDiff: nil,
            cardUnifiedDiff: nil,
            note: nil,
            fileCreated: nil,
            fileOverwritten: nil,
            reviewStatus: nil,
            rejectionReason: nil,
            requiresUserApproval: nil,
            operationID: "operation-456",
            mutationState: "applied",
            freshness: "pending"
        )
        let value = try Self.value(dto)
        let text = try Self.onlyText(ToolOutputFormatter.formatApplyEdits(value: value, emitResources: false))

        XCTAssertTrue(text.contains("Operation ID: `operation-456`"), text)
        XCTAssertTrue(text.contains("Mutation: applied"), text)
        XCTAssertTrue(text.contains("Freshness: pending"), text)
        XCTAssertTrue(text.contains("do not blindly replay"), text)
    }

    private static func value(_ value: some Encodable) throws -> Value {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private static func onlyText(_ blocks: [MCP.Tool.Content]) throws -> String {
        let first = try XCTUnwrap(blocks.first)
        guard case let .text(text, _, _) = first else {
            XCTFail("Expected text content")
            return ""
        }
        return text
    }
}
