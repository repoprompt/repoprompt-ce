import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

@MainActor
final class OracleImageContractTests: XCTestCase {
    func testParserAcceptsOnlyBoundedPathAndOptionalTitleObjects() throws {
        XCTAssertEqual(try MCPOracleToolService.parseOracleImageRequests(nil), [])
        XCTAssertEqual(try MCPOracleToolService.parseOracleImageRequests(.array([])), [])

        let parsed = try MCPOracleToolService.parseOracleImageRequests(.array([
            .object([
                "path": .string("  /workspace/diagram.png  "),
                "title": .string("  Architecture  "),
                "_meta": .string("ignored")
            ]),
            .object(["path": .string("/workspace/photo.jpg")])
        ]))

        XCTAssertEqual(parsed, [
            .init(index: 0, path: "  /workspace/diagram.png  ", title: "Architecture"),
            .init(index: 1, path: "/workspace/photo.jpg", title: nil)
        ])
    }

    func testParserRejectsOversizedAndExpandedAttachmentShapes() {
        XCTAssertThrowsError(try MCPOracleToolService.parseOracleImageRequests(.array(
            (0 ... 10).map { .object(["path": .string("/workspace/\($0).png")]) }
        )))
        XCTAssertThrowsError(try MCPOracleToolService.parseOracleImageRequests(.array([
            .object([
                "path": .string("/workspace/image.png"),
                "url": .string("https://example.com/image.png")
            ])
        ])))
        XCTAssertThrowsError(try MCPOracleToolService.parseOracleImageRequests(.array([
            .object([
                "path": .string("/workspace/image.png"),
                "title": .string(String(repeating: "x", count: 201))
            ])
        ])))
    }

    func testRawImagesAtOracleDispatchAreAnInternalInvariantFailure() {
        XCTAssertNoThrow(try OracleViewModel.validateRawImageDispatchInvariant([
            "message": .string("inspect")
        ]))
        XCTAssertThrowsError(try OracleViewModel.validateRawImageDispatchInvariant([
            "images": .array([.object(["path": .string("/workspace/image.png")])])
        ])) { error in
            guard let toolError = error as? ChatToolError else {
                return XCTFail("Expected ChatToolError, got \(error)")
            }
            XCTAssertEqual(toolError.code, .internalError)
            XCTAssertTrue(toolError.message.contains("must be consumed before Oracle dispatch"))
        }
    }

    func testAskOracleToolArgumentsAreRedactedBeforePersistence() throws {
        let raw = #"{"message":"inspect","images":[{"path":"/Users/secret.png","title":"Secret"}]}"#
        let item = AgentChatItem.toolCall(
            name: "mcp__RepoPromptCE__ask_oracle",
            argsJSON: raw
        )

        let sanitized = try XCTUnwrap(item.toolArgsJSON)
        XCTAssertTrue(sanitized.contains("inspect"))
        XCTAssertFalse(sanitized.contains("images"))
        XCTAssertFalse(sanitized.contains("/Users/secret.png"))
        XCTAssertFalse(try String(decoding: JSONEncoder().encode(item), as: UTF8.self).contains("secret.png"))

        let unrelated = AgentChatItem.toolCall(name: "read_file", argsJSON: raw)
        XCTAssertEqual(unrelated.toolArgsJSON, raw)
    }

    func testLateAndPartialToolArgumentsPreserveTextButRedactImages() throws {
        let raw = #"{"message":"inspect","images":[{"path":"/Users/late-secret.png"}]}"#
        var item = AgentChatItem.toolCall(name: "read_file", argsJSON: nil)
        item.toolName = "ask_oracle"
        item.toolArgsJSON = raw

        let sanitized = try XCTUnwrap(item.toolArgsJSON)
        XCTAssertFalse(sanitized.contains("images"))
        XCTAssertFalse(sanitized.contains("late-secret"))

        item.toolArgsJSON = #"{"message":"partial"#
        XCTAssertEqual(item.toolArgsJSON, #"{"message":"partial"#)
        item.toolArgsJSON = #"{"images":[{"path":"/Users/partial-secret.png"#
        XCTAssertNil(item.toolArgsJSON)
    }
}
