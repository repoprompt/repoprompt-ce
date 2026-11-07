import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCPServer
import RepoPromptShared
import XCTest

final class MCPServerInvocationContextTests: XCTestCase {
    func testMissingCapturedContextFailsClosed() {
        XCTAssertThrowsError(try MCPInvocationContextBridge.require(toolName: "read_file", diagnosticSink: { _ in })) {
            XCTAssertEqual($0 as? MCPInvocationContextFailure, .missingExpectedContext)
        }
    }

    func testCapturedInvocationIsScopedAndWrongToolFailsClosed() async throws {
        let connectionID = UUID()
        let invocationID = UUID()
        let context = ToolInvocationContext(
            origin: .network,
            invocationID: invocationID,
            requestID: nil,
            toolName: "read_file",
            metadata: MCPRequestMetadata(connectionID: connectionID, clientName: nil, windowID: nil, invocationID: invocationID),
            dispatchAuthorization: nil
        )
        try await MCPInvocationContextBridge.withInvocation(context) {
            XCTAssertEqual(try MCPInvocationContextBridge.require(toolName: "read_file", diagnosticSink: { _ in }).invocationID, invocationID)
            XCTAssertThrowsError(try MCPInvocationContextBridge.require(toolName: "file_actions", diagnosticSink: { _ in })) {
                XCTAssertEqual($0 as? MCPInvocationContextFailure, .toolMismatch)
            }
        }
        XCTAssertNil(MCPInvocationContextBridge.current)
    }
}
