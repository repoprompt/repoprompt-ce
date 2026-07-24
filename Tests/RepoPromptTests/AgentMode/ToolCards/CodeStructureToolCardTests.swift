import Foundation
@testable import RepoPromptApp
import XCTest

final class CodeStructureToolCardTests: XCTestCase {
    func testGraphNativeResultBuildsFourStatusSummary() throws {
        let summary = try XCTUnwrap(AgentToolCardRenderSummaryBuilder.build(
            normalizedToolName: "get_code_structure",
            statusWord: "completed",
            rawObject: [
                "status": "partial",
                "roots": [["root": "A"], ["root": "B"]],
                "summary": ["seeds": 2, "nodes": 4, "edges": 3, "files": 2, "tokens": 120]
            ],
            argsObject: ["expand": "both", "depth": 2]
        ))

        XCTAssertEqual(summary.title, "Code Structure")
        XCTAssertEqual(summary.subtitle, "4 nodes • 2 roots • partial")
        XCTAssertEqual(summary.detailText, "2 rendered signatures")
        XCTAssertEqual(summary.status, .warning)
    }

    func testFlatArgumentsDecodeAndOmittedPathsMeanSelection() throws {
        let json = #"{"expand":"used_by","depth":3,"signatures":false,"max_tokens":12000}"#
        let args = try XCTUnwrap(ToolJSON.decodeArgs(ToolArgsDTOs.CodeStructureArgs.self, from: json))
        XCTAssertNil(args.paths)
        XCTAssertEqual(args.expand, "used_by")
        XCTAssertEqual(args.depth, 3)
        XCTAssertEqual(args.signatures, false)
        XCTAssertEqual(args.maxTokens, 12000)

        let summary = try XCTUnwrap(AgentToolCardRenderSummaryBuilder.build(
            normalizedToolName: "get_code_structure",
            statusWord: "completed",
            rawObject: nil,
            argsObject: [:]
        ))
        XCTAssertEqual(summary.subtitle, "selection")
    }
}
