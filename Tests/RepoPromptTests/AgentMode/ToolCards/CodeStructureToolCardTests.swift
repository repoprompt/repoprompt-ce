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
                "size": "medium",
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

    func testUnavailablePathEchoPreservesMachineSummaryContract() throws {
        let summary = try XCTUnwrap(AgentToolCardRenderSummaryBuilder.build(
            normalizedToolName: "get_code_structure",
            statusWord: "completed",
            rawObject: [
                "status": "unavailable",
                "size": "medium",
                "roots": [],
                "summary": ["seeds": 0, "nodes": 0, "edges": 0, "files": 0, "tokens": 0],
                "issues": [["code": "path_not_found", "path": "Sources/Missing.swift"]]
            ],
            argsObject: ["paths": ["Sources/Missing.swift"]]
        ))

        XCTAssertEqual(summary.subtitle, "0 nodes • 0 roots • unavailable")
        XCTAssertNil(summary.detailText)
        XCTAssertEqual(summary.status, .failure)
    }

    func testFlatArgumentsDecodeAndOmittedPathsMeanSelection() throws {
        let json = #"{"expand":"used_by","depth":3,"signatures":false,"size":"large"}"#
        let args = try XCTUnwrap(ToolJSON.decodeArgs(ToolArgsDTOs.CodeStructureArgs.self, from: json))
        XCTAssertNil(args.paths)
        XCTAssertEqual(args.expand, "used_by")
        XCTAssertEqual(args.depth, 3)
        XCTAssertEqual(args.signatures, false)
        XCTAssertEqual(args.size, "large")

        let summary = try XCTUnwrap(AgentToolCardRenderSummaryBuilder.build(
            normalizedToolName: "get_code_structure",
            statusWord: "completed",
            rawObject: nil,
            argsObject: [:]
        ))
        XCTAssertEqual(summary.subtitle, "selection")
    }
}
