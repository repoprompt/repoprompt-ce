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

    func testNonRetryableDTOFailurePreservesExactErrorWithoutSuccessContent() throws {
        let reply = ToolResultDTOs.ReadFileReply(
            content: "must not render",
            totalLines: 1,
            firstLine: 1,
            lastLine: 1,
            displayPath: "denied.swift",
            errorMessage: "Access denied.",
            errorCode: "access_denied",
            retryable: false
        )
        let text = try Self.onlyText(ToolOutputFormatter.formatReadFile(
            args: ["path": .string("requested.swift")], value: Value(reply)
        ))
        XCTAssertEqual(text, """
        ## File Read ❌
        - **Path**: `denied.swift`
        - **Status**: Unreadable tool result
        - **Code**: access_denied
        - **Retryable**: no
        - **Message**: Access denied.
        """)
    }

    func testErrorShapedObjectsNeverBecomeSuccess() throws {
        let cases: [[String: Value]] = [
            ["error": .string("denied"), "first_line": .int(0)],
            ["error": .string("denied"), "content": .string("not a result")],
            ["error_code": .string("denied"), "content": .string("not a result")],
            ["error": .object(["message": .string("denied")]), "content": .string("not a result")],
            ["retryable": .bool(true), "content": .string("not a result")]
        ]
        for object in cases {
            let text = try Self.onlyText(ToolOutputFormatter.formatReadFile(args: [:], value: .object(object)))
            XCTAssertTrue(text.contains("## File Read ❌"), text)
            XCTAssertFalse(text.contains("**Lines**"), text)
            XCTAssertFalse(text.contains("```"), text)
        }
    }

    func testMalformedStructuredRangesNeverBecomeSuccess() throws {
        let malformed: [[String: Value]] = [
            ["first_line": .int(0)],
            ["content": .bool(false), "first_line": .int(0), "last_line": .int(0), "total_lines": .int(0)],
            ["content": .string("x"), "first_line": .int(1)],
            ["content": .string("x"), "first_line": .double(1.5), "last_line": .int(1), "total_lines": .int(1)],
            ["content": .string("x"), "first_line": .int(1), "last_line": .int(1), "total_lines": .double(Double(Int.max))],
            ["content": .string("x"), "first_line": .int(-1), "last_line": .int(1), "total_lines": .int(1)],
            ["content": .string("x"), "first_line": .int(1), "last_line": .int(2), "total_lines": .int(1)],
            ["content": .string("x"), "first_line": .int(0), "last_line": .int(0), "total_lines": .int(0)]
        ]
        for object in malformed {
            let text = try Self.onlyText(ToolOutputFormatter.formatReadFile(args: [:], value: .object(object)))
            XCTAssertTrue(text.contains("## File Read ❌"), text)
            XCTAssertFalse(text.contains("**Lines**"), text)
            XCTAssertFalse(text.contains("```"), text)
        }
    }

    func testValidLegacyStringsAndNumericStringRangesRemainSuccess() throws {
        let cases: [(Value, String)] = [
            (.string(""), "0–0 of 0"),
            (.string("a\nb"), "1–2 of 2"),
            (.object([
                "content": .string("a"), "first_line": .string("1"),
                "last_line": .string("1"), "total_lines": .string("2")
            ]), "1–1 of 2")
        ]
        for (value, range) in cases {
            let text = try Self.onlyText(ToolOutputFormatter.formatReadFile(args: [:], value: value))
            XCTAssertTrue(text.contains("## File Read ✅"), text)
            XCTAssertTrue(text.contains("**Lines**: \(range)"), text)
        }
    }

    func testProviderEmptySlicesRemainSuccess() throws {
        for (first, last) in [(1, 0), (2, 1), (9, 3)] {
            let reply = ToolResultDTOs.ReadFileReply(content: "", totalLines: 3, firstLine: first, lastLine: last)
            let text = try Self.onlyText(ToolOutputFormatter.formatReadFile(args: [:], value: Value(reply)))
            XCTAssertTrue(text.contains("## File Read ✅"), text)
            XCTAssertTrue(text.contains("**Lines**: \(first)–\(last) of 3"), text)
        }
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
