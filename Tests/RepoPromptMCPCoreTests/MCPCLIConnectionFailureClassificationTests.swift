import Darwin
import Foundation
@testable import RepoPromptMCPCore
import XCTest

/// Issue #294: launch/reconnect failures must be classified instead of collapsing into one
/// generic connection failure, and unsupported stdio framing must fail fast and clearly.
final class MCPCLIConnectionFailureClassificationTests: XCTestCase {
    // MARK: - Raw stdio framing (#294 item 3)

    func testContentLengthFramedClientFramesAreRejectedWithExplicitDetail() throws {
        for header in [
            "Content-Length: 123\r",
            "content-length: 7",
            "  CONTENT-LENGTH:42",
            "\rContent-Length: 1"
        ] {
            let detail = try XCTUnwrap(
                MCPStdioClientFraming.unsupportedFramingDetail(for: Data(header.utf8)),
                "'\(header)' must be classified as unsupported framing"
            )
            XCTAssertTrue(detail.contains("Content-Length"), detail)
            XCTAssertTrue(detail.contains("newline-delimited JSON-RPC"), detail)
        }
    }

    func testNewlineDelimitedFramesAndBlankLinesAreNotRejected() {
        for frame in [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            "",
            "\r",
            "   ",
            #"{"content-length": 3}"#,
            "Content-Type: application/json"
        ] {
            XCTAssertNil(MCPStdioClientFraming.unsupportedFramingDetail(for: Data(frame.utf8)), frame)
        }
    }

    func testUnsupportedClientFramingIsAPermanentNonRetryableProxyFailure() throws {
        let error = CLIRuntimeError.connectionFailed(
            underlying: SocketProxyError.unsupportedClientFraming(
                detail: MCPStdioClientFraming.unsupportedContentLengthDetail
            )
        )
        XCTAssertFalse(CLIProxyRuntimePolicy.shouldRetry(after: error))
        XCTAssertEqual(CLIProxyRuntimePolicy.failureReason(for: error), "unsupported_stdio_framing")
        let description = try XCTUnwrap(
            SocketProxyError.unsupportedClientFraming(detail: "x").errorDescription
        )
        XCTAssertTrue(description.hasPrefix("Unsupported stdio framing"), description)
        XCTAssertFalse(description.contains("unknown JSON-RPC response id"), description)
    }

    // MARK: - Transient reconnect window versus app not running (#294 item 2)

    func testBootstrapSocketUnavailableIsRetryableAndDistinctFromAppNotRunning() {
        XCTAssertFalse(InteractiveSessionError.appNotRunning.isRetryableConnectionFailure)
        XCTAssertFalse(InteractiveSessionError.approvalDenied.isRetryableConnectionFailure)
        XCTAssertTrue(InteractiveSessionError.bootstrapSocketUnavailable(errno: ECONNREFUSED).isRetryableConnectionFailure)
        XCTAssertTrue(InteractiveSessionError.bootstrapSocketUnavailable(errno: ENOENT).isRetryableConnectionFailure)
        XCTAssertTrue(InteractiveSessionError.bootstrapResponseTimeout.isRetryableConnectionFailure)

        let refused = InteractiveSessionError.bootstrapSocketUnavailable(errno: ECONNREFUSED).description
        XCTAssertTrue(refused.contains("refused the connection"), refused)
        XCTAssertTrue(refused.contains("retryable"), refused)
        XCTAssertTrue(refused.contains("--connect-wait"), refused)
        XCTAssertFalse(refused.contains("not running"), refused)

        let missing = InteractiveSessionError.bootstrapSocketUnavailable(errno: ENOENT).description
        XCTAssertTrue(missing.contains("socket is missing"), missing)

        let notRunning = InteractiveSessionError.appNotRunning.description
        XCTAssertTrue(notRunning.contains("not running or MCP is disabled"), notRunning)
        XCTAssertFalse(notRunning.contains("retryable"), notRunning)
    }
}
