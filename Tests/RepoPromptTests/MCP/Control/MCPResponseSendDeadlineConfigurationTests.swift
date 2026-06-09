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
        let appSourceRoot = root.appendingPathComponent("Sources/RepoPrompt")
        let cliSourceRoot = root.appendingPathComponent("Sources/RepoPromptMCP")

        let server = try source(
            declaring: "BootstrapSocketConnectionManager",
            under: appSourceRoot
        )
        XCTAssertTrue(server.contains("responseSendTimeout: MCPTimeoutPolicy.responseSendDeadline"))

        let appTransport = try source(
            declaring: "UnixSocketMCPTransport",
            under: appSourceRoot
        )
        XCTAssertTrue(appTransport.contains(
            "writeStallTimeout: TimeInterval = MCPTimeoutPolicy.transportWriteStallTimeoutSeconds"
        ))

        let cliTransport = try source(
            declaring: "BootstrapSocketMCPTransport",
            under: cliSourceRoot
        )
        XCTAssertTrue(cliTransport.contains(
            "writeStallTimeout: TimeInterval = MCPTimeoutPolicy.transportWriteStallTimeoutSeconds"
        ))

        let cliWriter = try source(
            declaring: "NonBlockingFDWriter",
            under: cliSourceRoot
        )
        XCTAssertTrue(cliWriter.contains(
            "stallTimeout: TimeInterval = MCPTimeoutPolicy.transportWriteStallTimeoutSeconds"
        ))
    }

    private func source(declaring declarationName: String, under sourceRoot: URL) throws -> String {
        let escapedName = NSRegularExpression.escapedPattern(for: declarationName)
        let declaration = try NSRegularExpression(
            pattern: #"(?m)^\s*(?:(?:public|package|internal|private|fileprivate|open|final|indirect|nonisolated)\s+)*(?:actor|class|struct|enum|protocol)\s+"#
                + escapedName
                + #"\b"#
        )
        let swiftFiles = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )

        var owners: [(url: URL, source: String)] = []
        for case let fileURL as URL in swiftFiles where fileURL.pathExtension == "swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            if declaration.firstMatch(in: source, range: range) != nil {
                owners.append((fileURL, source))
            }
        }

        XCTAssertEqual(
            owners.count,
            1,
            "Expected exactly one Swift declaration owner for \(declarationName) under \(sourceRoot.path); found \(owners.map(\.url.path))"
        )
        return try XCTUnwrap(owners.first?.source)
    }
}
