import Foundation
import MCP
@testable import RepoPrompt
import XCTest

final class BindContextRoutingRecoveryTests: XCTestCase {
    func testBindContextParsesWorkingDirsAndPrefersSelectedWindow() throws {
        let projectSourcePath = "/Users/repoprompt-test/project/Sources"
        let request = try WindowRoutingService.parseBindContextRequest([
            "op": .string("bind"),
            "working_dirs": .array([
                .string(" /Users/repoprompt-test/project/./Sources "),
                .string(projectSourcePath)
            ]),
            "create_if_missing": .bool(true),
            "tab_name": .string("Recovered")
        ])

        XCTAssertEqual(request.op, .bind)
        XCTAssertEqual(request.matchKind, .workingDirs)
        XCTAssertEqual(request.workingDirs, [projectSourcePath])
        XCTAssertTrue(request.createIfMissing)
        XCTAssertEqual(request.tabName, "Recovered")

        XCTAssertEqual(
            WindowRoutingService.test_preferredOpenWindowID(
                showingWindowIDs: [2, 6, 9],
                selectedWindowID: 6,
                focusedWindowID: 9
            ),
            6
        )
    }

    func testBindContextParsesReadOnlyOperationsWithoutSelectors() throws {
        let status = try WindowRoutingService.parseBindContextRequest(["op": .string("status")])
        XCTAssertEqual(status.op, .status)
        XCTAssertNil(status.matchKind)

        let list = try WindowRoutingService.parseBindContextRequest(["op": .string("list")])
        XCTAssertEqual(list.op, .list)
        XCTAssertNil(list.matchKind)
    }

    func testBindContextParsesCommaSeparatedWorkingDirs() throws {
        let request = try WindowRoutingService.parseBindContextRequest([
            "op": .string("bind"),
            "working_dirs": .string(" /tmp/repoprompt-a, /tmp/repoprompt-b , /tmp/repoprompt-a ")
        ])

        XCTAssertEqual(request.matchKind, .workingDirs)
        XCTAssertEqual(request.workingDirs, ["/tmp/repoprompt-a", "/tmp/repoprompt-b"])
    }

    func testBindContextRejectsInvalidPrimarySelectorCombinations() {
        do {
            let caseLabel = "testBindContextRejectsMultiplePrimarySelectors"
            XCTAssertThrowsError(try WindowRoutingService.parseBindContextRequest([
                "op": .string("bind"),
                "context_id": .string(UUID().uuidString),
                "working_dirs": .array([.string("/tmp/repoprompt-a")])
            ]), caseLabel)
        }

        do {
            let caseLabel = "testBindContextRejectsCreateIfMissingWithoutWorkingDirs"
            XCTAssertThrowsError(try WindowRoutingService.parseBindContextRequest([
                "op": .string("bind"),
                "window_id": .int(1),
                "create_if_missing": .bool(true)
            ]), caseLabel)
        }
    }

    func testMCPConnectionManagerHasNoIncompleteBindContextFastPathOrUnsafeRegisteredServicesSnapshot() throws {
        let source = try readMCPConnectionManagerSource()
        XCTAssertFalse(source.contains("fastBindContextReadOnlyResult"))
        XCTAssertFalse(source.contains("served read-only request via fast path"))
        XCTAssertFalse(source.contains("registeredServicesSnapshot"))
        XCTAssertFalse(source.contains("nonisolated(unsafe) private var registeredServicesSnapshot"))
    }

    func testStandardWorkspaceSwitchBindsConnectionOnlyWhenWindowIDIsExplicit() {
        XCTAssertTrue(WindowRoutingService.shouldBindConnectionAfterStandardWorkspaceSwitch(explicitWindowIDProvided: true))
        XCTAssertFalse(WindowRoutingService.shouldBindConnectionAfterStandardWorkspaceSwitch(explicitWindowIDProvided: false))
    }

    private func readMCPConnectionManagerSource() throws -> String {
        let root = try RepoRoot.url()
        let url = root.appendingPathComponent("Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
