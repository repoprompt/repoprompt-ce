import Foundation
@testable import RepoPrompt
import XCTest

final class MCPResolvedToolDispatchSourceGuardTests: XCTestCase {
    func testOrdinaryCallToolHandlerInvokesResolvedToolDirectlyInBothDispatchBranches() throws {
        let source = try String(
            contentsOf: RepoRoot.url()
                .appendingPathComponent("Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift"),
            encoding: .utf8
        )
        let callToolHandler = try XCTUnwrap(source.slice(
            from: "        await server.withMethodHandler(CallTool.self) { [weak self] params in\n",
            to: "    /// Update the enabled state and notify clients\n"
        ))

        XCTAssertEqual(callToolHandler.occurrenceCount(of: "let serviceTools = await service.tools"), 1)
        XCTAssertEqual(callToolHandler.occurrenceCount(of: "guard let toolDef = serviceTools.first(where: { $0.name == toolName })"), 1)
        XCTAssertEqual(callToolHandler.occurrenceCount(of: "let selectedSchemaDeclaresWindowID ="), 1)
        XCTAssertEqual(callToolHandler.occurrenceCount(of: "routingWindowID != nil"), 1)
        XCTAssertEqual(callToolHandler.occurrenceCount(of: "capturedArguments[\"window_id\"] == nil"), 1)
        XCTAssertEqual(callToolHandler.occurrenceCount(of: "capturedArgsForFormatter[\"window_id\"] == nil"), 1)
        XCTAssertEqual(callToolHandler.occurrenceCount(of: "self.schemaDeclaresWindowID(schema: toolDef.inputSchema)"), 1)
        XCTAssertEqual(callToolHandler.occurrenceCount(of: "schemaDeclaresWindowID: selectedSchemaDeclaresWindowID"), 2)
        XCTAssertEqual(callToolHandler.occurrenceCount(of: "try await toolDef.callAsFunction(effectiveArgs)"), 2)
        XCTAssertFalse(callToolHandler.contains("service.call("))
        XCTAssertTrue(callToolHandler.contains("if let wsSvc, shouldTrackToolOwnership"))
        XCTAssertTrue(callToolHandler.contains("// Not window-scoped → no ownership tracking needed"))
    }
}

private extension String {
    func slice(from startMarker: String, to endMarker: String) -> String? {
        guard let startRange = range(of: startMarker),
              let endRange = range(of: endMarker, range: startRange.upperBound ..< endIndex)
        else {
            return nil
        }
        return String(self[startRange.lowerBound ..< endRange.lowerBound])
    }

    func occurrenceCount(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }
}
