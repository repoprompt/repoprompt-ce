import Foundation
import RepoPromptShared
import XCTest

final class MCPResponseSendDeadlineConfigurationTests: XCTestCase {
    func testCEPinsReviewedSwiftSDKResponseDeliveryCommit() throws {
        let root = try RepoRoot.url()
        let manifest = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(manifest.contains(
            #"revision: "85dec2fc7a27252bc33dc7728be6af6b3bd398c0""#
        ))

        let resolvedData = try Data(contentsOf: root.appendingPathComponent("Package.resolved"))
        let resolved = try XCTUnwrap(JSONSerialization.jsonObject(with: resolvedData) as? [String: Any])
        let pins = try XCTUnwrap(resolved["pins"] as? [[String: Any]])
        let sdk = try XCTUnwrap(pins.first { $0["identity"] as? String == "swift-sdk" })
        let state = try XCTUnwrap(sdk["state"] as? [String: Any])
        XCTAssertEqual(
            state["revision"] as? String,
            "85dec2fc7a27252bc33dc7728be6af6b3bd398c0"
        )
        XCTAssertNil(state["branch"])
    }

    func testBootstrapServerAndTransportsUseCentralResponseDeliveryPolicy() throws {
        XCTAssertEqual(
            MCPTimeoutPolicy.responseSendDeadlineSeconds,
            MCPTimeoutPolicy.boundedToolExecutionDeadlineSeconds
        )
        XCTAssertEqual(
            MCPTimeoutPolicy.transportWriteStallTimeoutSeconds,
            TimeInterval(MCPTimeoutPolicy.responseSendDeadlineSeconds)
        )

        let root = try RepoRoot.url()
        let server = try source(
            root: root,
            path: "Sources/RepoPrompt/Infrastructure/MCP/BootstrapSocketConnectionManager.swift"
        )
        XCTAssertTrue(server.contains("responseSendTimeout: MCPTimeoutPolicy.responseSendDeadline"))

        let appTransport = try source(
            root: root,
            path: "Sources/RepoPrompt/Infrastructure/MCP/UnixSocketMCPTransport.swift"
        )
        XCTAssertTrue(appTransport.contains(
            "writeStallTimeout: TimeInterval = MCPTimeoutPolicy.transportWriteStallTimeoutSeconds"
        ))

        let cliTransport = try source(
            root: root,
            path: "Sources/RepoPromptMCP/Transports/BootstrapSocketMCPTransport.swift"
        )
        XCTAssertTrue(cliTransport.contains(
            "writeStallTimeout: TimeInterval = MCPTimeoutPolicy.transportWriteStallTimeoutSeconds"
        ))

        let cliWriter = try source(
            root: root,
            path: "Sources/RepoPromptMCP/Transports/NonBlockingFDWriter.swift"
        )
        XCTAssertTrue(cliWriter.contains(
            "stallTimeout: TimeInterval = MCPTimeoutPolicy.transportWriteStallTimeoutSeconds"
        ))
    }

    private func source(root: URL, path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
