import MCP
@testable import RepoPromptApp
import XCTest

final class DebugSelectionFixtureParserTests: XCTestCase {
    func testDebugWorkspaceSelectionFixtureSlicesAcceptsEmptyArrayAndEmptyObject() throws {
        #if DEBUG
            let missing = ServerNetworkManager.debugParseSelectionFixtureSlicesForTesting(nil)
            XCTAssertNil(missing.error)
            XCTAssertTrue(try XCTUnwrap(missing.slices).isEmpty)

            let emptyArray = ServerNetworkManager.debugParseSelectionFixtureSlicesForTesting(.array([]))
            XCTAssertNil(emptyArray.error)
            XCTAssertTrue(try XCTUnwrap(emptyArray.slices).isEmpty)

            let emptyObject = ServerNetworkManager.debugParseSelectionFixtureSlicesForTesting(.object([:]))
            XCTAssertNil(emptyObject.error)
            XCTAssertTrue(try XCTUnwrap(emptyObject.slices).isEmpty)
        #endif
    }

    func testDebugWorkspaceSelectionFixtureSlicesAcceptsObjectMapping() throws {
        #if DEBUG
            let parsed = ServerNetworkManager.debugParseSelectionFixtureSlicesForTesting(.object([
                "/tmp/A.swift": .array([
                    .object([
                        "start_line": .int(1),
                        "end_line": .int(3),
                        "description": .string("focused")
                    ])
                ])
            ]))

            XCTAssertNil(parsed.error)
            let slices = try XCTUnwrap(parsed.slices)
            XCTAssertEqual(slices["/tmp/A.swift"], [LineRange(start: 1, end: 3, description: "focused")])
        #endif
    }
}
