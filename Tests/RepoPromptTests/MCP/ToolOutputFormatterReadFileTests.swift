import MCP
@testable import RepoPromptApp
import XCTest

final class ToolOutputFormatterReadFileTests: XCTestCase {
    func testEmptyObjectDoesNotInventOneLineSuccess() throws {
        let text = try Self.onlyText(
            ToolOutputFormatter.formatReadFile(
                args: ["path": .string("SKILL.md")],
                value: .object([:])
            )
        )

        XCTAssertTrue(text.contains("## File Read ❌"), text)
        XCTAssertTrue(text.contains("Unreadable tool result"), text)
        XCTAssertFalse(text.contains("## File Read ✅"), text)
        XCTAssertFalse(text.contains("0–1 of 1"), text)
    }

    func testEmptyContentWithoutLineMetadataDoesNotInventOneLineSuccess() throws {
        let text = try Self.onlyText(
            ToolOutputFormatter.formatReadFile(
                args: ["path": .string("SKILL.md")],
                value: .object(["content": .string("")])
            )
        )

        XCTAssertTrue(text.contains("## File Read ❌"), text)
        XCTAssertFalse(text.contains("## File Read ✅"), text)
        XCTAssertFalse(text.contains("0–1 of 1"), text)
        XCTAssertFalse(text.contains("```markdown"), text)
    }

    func testEmptyContentWithDoubleLineMetadataRendersEmptyFile() throws {
        let text = try Self.onlyText(
            ToolOutputFormatter.formatReadFile(
                args: ["path": .string("empty.txt")],
                value: .object([
                    "content": .string(""),
                    "first_line": .double(0),
                    "last_line": .double(0),
                    "total_lines": .double(0)
                ])
            )
        )

        XCTAssertTrue(text.contains("## File Read ✅"), text)
        XCTAssertTrue(text.contains("**Lines**: 0–0 of 0"), text)
        XCTAssertFalse(text.contains("0–1 of 1"), text)
    }

    func testDecodedEmptyFileReplyKeepsZeroRange() throws {
        let reply = ToolResultDTOs.ReadFileReply(
            content: "",
            totalLines: 0,
            firstLine: 0,
            lastLine: 0,
            displayPath: "empty.txt"
        )
        let text = try Self.onlyText(
            ToolOutputFormatter.formatReadFile(
                args: ["path": .string("empty.txt")],
                value: Value(reply)
            )
        )

        XCTAssertTrue(text.contains("## File Read ✅"), text)
        XCTAssertTrue(text.contains("**Lines**: 0–0 of 0"), text)
        XCTAssertTrue(text.contains("`empty.txt`"), text)
    }

    func testNonEmptyContentWithoutLineMetadataInfersRange() throws {
        let text = try Self.onlyText(
            ToolOutputFormatter.formatReadFile(
                args: ["path": .string("a.swift")],
                value: .object(["content": .string("print(1)")])
            )
        )

        XCTAssertTrue(text.contains("## File Read ✅"), text)
        XCTAssertTrue(text.contains("**Lines**: 1–1 of 1"), text)
        XCTAssertTrue(text.contains("print(1)"), text)
        XCTAssertTrue(text.contains("```swift"), text)
    }

    func testRetryableObjectWithoutDecodableDTOStillWarns() throws {
        let text = try Self.onlyText(
            ToolOutputFormatter.formatReadFile(
                args: ["path": .string("Sources/App.swift")],
                value: .object([
                    "content": .string(""),
                    "error": .string("Workspace freshness timed out before pending file-system ingress was applied."),
                    "error_code": .string("workspace_freshness_timeout"),
                    "retryable": .bool(true),
                    "retry_after_ms": .double(1000)
                ])
            )
        )

        XCTAssertTrue(text.contains("## File Read ⚠️"), text)
        XCTAssertTrue(text.contains("workspace_freshness_timeout"), text)
        XCTAssertTrue(text.contains("**Retry after**: 1000 ms"), text)
        XCTAssertFalse(text.contains("## File Read ✅"), text)
        XCTAssertFalse(text.contains("0–1 of 1"), text)
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
