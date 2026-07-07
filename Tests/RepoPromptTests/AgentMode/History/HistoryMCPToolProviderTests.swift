import Foundation
import MCP
@testable import RepoPrompt
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

        let capture = ProviderRuntimeCapture()
        let runtime = MCPWindowToolRuntime(windowID: 42) { name, _, arguments, implementation in
            await capture.record(toolName: name, arguments: arguments)
            return try await implementation(MCPWindowToolContext(toolName: name, windowID: 42), arguments)
        }
        let provider = MCPHistoryToolProvider(runtime: runtime, scannerFactory: { scanner })
        let tool = try XCTUnwrap(provider.buildTools().first)

        XCTAssertEqual(tool.name, MCPWindowToolName.history)
        XCTAssertEqual(tool.annotations.readOnlyHint, true)
        XCTAssertEqual(tool.annotations.idempotentHint, true)

        let listValue = try await tool([
            "op": .string("list_sessions"),
            "limit": .int(10)
        ])
        let listObject = try XCTUnwrap(listValue.objectValue)
        var runtimeSnapshot = await capture.snapshot()
        XCTAssertEqual(runtimeSnapshot.toolName, MCPWindowToolName.history)
        XCTAssertEqual(runtimeSnapshot.arguments["op"]?.stringValue, "list_sessions")
        XCTAssertEqual(runtimeSnapshot.arguments["limit"]?.intValue, 10)
        XCTAssertEqual(listObject["total_sessions"]?.intValue, 1)

        let sessions = try XCTUnwrap(listObject["sessions"]?.arrayValue)
        let row = try XCTUnwrap(sessions.first?.objectValue)
        XCTAssertEqual(row["session_name"]?.stringValue, "Provider Session")
        XCTAssertEqual(row["workspace_name"]?.stringValue, "ProviderProject")
        XCTAssertEqual(row["active_duration_seconds"]?.intValue, 45)
        XCTAssertEqual(row["tool_call_count"]?.intValue, 2)
        XCTAssertEqual(row["files_touched"]?.arrayValue?.compactMap(\.stringValue), ["Sources/Provider.swift"])

        let searchValue = try await tool([
            "op": .string("search"),
            "query": .string("test"),
            "limit": .int(10),
            "date_from": .string("2026-01-15"),
            "source": .string("activities")
        ])
        let searchObject = try XCTUnwrap(searchValue.objectValue)
        runtimeSnapshot = await capture.snapshot()
        XCTAssertEqual(runtimeSnapshot.arguments["op"]?.stringValue, "search")
        XCTAssertEqual(runtimeSnapshot.arguments["query"]?.stringValue, "test")
        XCTAssertEqual(runtimeSnapshot.arguments["limit"]?.intValue, 10)
        XCTAssertEqual(runtimeSnapshot.arguments["date_from"]?.stringValue, "2026-01-15")
        XCTAssertEqual(runtimeSnapshot.arguments["source"]?.stringValue, "activities")
        XCTAssertNotNil(searchObject["total_matches"])
        XCTAssertNotNil(searchObject["results"])

        let timeValue = try await tool([
            "op": .string("time"),
            "group_by": .string("day"),
            "include_details": .bool(true),
            "workspace": .string("ProviderProject")
        ])
        let timeObject = try XCTUnwrap(timeValue.objectValue)
        runtimeSnapshot = await capture.snapshot()
        XCTAssertEqual(runtimeSnapshot.arguments["op"]?.stringValue, "time")
        XCTAssertEqual(runtimeSnapshot.arguments["group_by"]?.stringValue, "day")
        XCTAssertEqual(runtimeSnapshot.arguments["include_details"]?.boolValue, true)
        XCTAssertEqual(runtimeSnapshot.arguments["workspace"]?.stringValue, "ProviderProject")
        XCTAssertNotNil(timeObject["total_sessions"])
        XCTAssertNotNil(timeObject["groups"])
    }
}

private actor ProviderRuntimeCapture {
    private var toolName: String?
    private var arguments: [String: Value] = [:]

    func record(toolName: String, arguments: [String: Value]) {
        self.toolName = toolName
        self.arguments = arguments
    }

    func snapshot() -> (toolName: String?, arguments: [String: Value]) {
        (toolName, arguments)
    }
}
