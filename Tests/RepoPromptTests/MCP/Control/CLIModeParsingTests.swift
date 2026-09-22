@testable import RepoPromptMCP
import XCTest

#if DEBUG
    final class CLIModeParsingTests: XCTestCase {
        func testSingleShotRetainsLastSharedSelectorValues() {
            let mode = parseCLIMode(arguments: [
                "rpce-cli",
                "--tab", "first-tab",
                "-t", "last-tab",
                "--context-id", "first-context",
                "--context-id", "last-context",
                "-c", "workspace_context"
            ])

            guard case let .interactive(options) = mode else {
                return XCTFail("Expected interactive mode for a single-shot tool call")
            }

            XCTAssertEqual(options.callTool, "workspace_context")
            XCTAssertEqual(options.tabID, "last-tab")
            XCTAssertEqual(options.contextID, "last-context")
        }

        func testPlainREPLRetainsBothSharedSelectors() {
            let mode = parseCLIMode(arguments: [
                "rpce-cli",
                "-i",
                "-t", "review-tab",
                "--context-id", "compose-context"
            ])

            guard case let .interactive(options) = mode else {
                return XCTFail("Expected interactive mode for the plain REPL")
            }

            XCTAssertNil(options.callTool)
            XCTAssertEqual(options.tabID, "review-tab")
            XCTAssertEqual(options.contextID, "compose-context")
        }

        func testExecModePrecedenceAndSelectorStateRemainUnchanged() {
            let mode = parseCLIMode(arguments: [
                "rpce-cli",
                "-c", "workspace_context",
                "-t", "review-tab",
                "--context-id", "compose-context",
                "-e", "tree"
            ])

            guard case let .exec(options) = mode else {
                return XCTFail("Expected exec mode to retain precedence over interactive flags")
            }

            XCTAssertEqual(options.commands, ["tree"])
            XCTAssertEqual(options.tabID, "review-tab")
            XCTAssertEqual(options.contextID, "compose-context")
        }
    }
#endif
