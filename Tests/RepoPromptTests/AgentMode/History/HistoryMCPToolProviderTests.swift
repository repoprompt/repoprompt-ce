import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class HistoryMCPToolProviderTests: XCTestCase {
    func testProviderExecutesHistoryOpsThroughMCPValueBoundary() async throws {
        let fixture = try HistoryTestFixture()
        let workspace = try fixture.createWorkspace(name: "ProviderProject")
        let spec = HistoryTestFixture.toolExecutionSession(
            name: "Provider Session",
            files: ["Sources/Provider.swift"],
            toolCount: 2,
            durationSeconds: 45
        )
        try fixture.install([spec], in: workspace)
        let scanner = fixture.makeScanner()

        let runtime = MCPAppToolBinder(windowID: 42) { _, _, arguments, implementation in
            try await implementation(MCPAppToolInvocation(toolName: MCPWindowToolName.history, windowID: 42), arguments)
        }
        let provider = MCPHistoryToolProvider(runtime: runtime, scannerFactory: { scanner })
        let context = Self.makeDomainContext()

        let listValue = try await provider.executeDomainRead(context: context, args: [
            "op": .string("list_sessions"),
            "limit": .int(10)
        ])
        let listObject = try XCTUnwrap(listValue.objectValue)
        XCTAssertEqual(listObject["total_sessions"]?.intValue, 1)

        let sessions = try XCTUnwrap(listObject["sessions"]?.arrayValue)
        let row = try XCTUnwrap(sessions.first?.objectValue)
        XCTAssertEqual(row["session_name"]?.stringValue, "Provider Session")
        XCTAssertEqual(row["workspace_name"]?.stringValue, "ProviderProject")
        XCTAssertEqual(row["active_duration_seconds"]?.intValue, 45)
        XCTAssertEqual(row["tool_call_count"]?.intValue, 2)
        XCTAssertEqual(row["files_touched"]?.arrayValue?.compactMap(\.stringValue), ["Sources/Provider.swift"])

        let searchValue = try await provider.executeDomainRead(context: context, args: [
            "op": .string("search"),
            "query": .string("test"),
            "limit": .int(10),
            "date_from": .string("2026-01-15"),
            "source": .string("activities")
        ])
        let searchObject = try XCTUnwrap(searchValue.objectValue)
        XCTAssertNotNil(searchObject["total_matches"])
        XCTAssertNotNil(searchObject["results"])

        let timeValue = try await provider.executeDomainRead(context: context, args: [
            "op": .string("time"),
            "group_by": .string("day"),
            "include_details": .bool(true),
            "workspace": .string("ProviderProject")
        ])
        let timeObject = try XCTUnwrap(timeValue.objectValue)
        XCTAssertNotNil(timeObject["total_sessions"])
        XCTAssertNotNil(timeObject["groups"])
    }

    private static func makeDomainContext() -> DomainReadInvocationContext {
        DomainReadInvocationContext(handle: nil, connectionID: nil)
    }
}
