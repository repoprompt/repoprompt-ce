import Foundation
@testable import RepoPromptHeadlessLaunchBridge
import XCTest

final class DirectHeadlessCompositionTests: XCTestCase {
    func testMissingBundledHelperFailsBeforeLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let launcher = root
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("repoprompt-mcp")
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try RepoPromptHeadlessLaunchBridge.resolvedHelper(
                environment: [:],
                executableURL: launcher
            )
        ) { error in
            guard case RepoPromptHeadlessLaunchBridgeError.helperMissing = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testOverrideRequiresExplicitHarnessEnablement() throws {
        let launcher = URL(fileURLWithPath: "/tmp/no-bundled-repoprompt-mcp")
        XCTAssertThrowsError(
            try RepoPromptHeadlessLaunchBridge.resolvedHelper(
                environment: [
                    "REPOPROMPT_MCP_HEADLESS_RUNTIME_EXECUTABLE": "/usr/bin/printf"
                ],
                executableURL: launcher
            )
        ) { error in
            guard case RepoPromptHeadlessLaunchBridgeError.helperMissing = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testIncompatibleOverrideContractIsRejected() throws {
        XCTAssertThrowsError(
            try RepoPromptHeadlessLaunchBridge.resolvedHelper(
                environment: [
                    "REPOPROMPT_MCP_HEADLESS_RUNTIME_TEST_OVERRIDE_ALLOWED": "1",
                    "REPOPROMPT_MCP_HEADLESS_RUNTIME_EXECUTABLE": "/usr/bin/printf"
                ],
                executableURL: nil
            )
        ) { error in
            guard case RepoPromptHeadlessLaunchBridgeError.incompatibleContract = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testSymlinkOverrideIsRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("helper")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: URL(fileURLWithPath: "/usr/bin/printf")
        )

        XCTAssertThrowsError(
            try RepoPromptHeadlessLaunchBridge.resolvedHelper(
                environment: [
                    "REPOPROMPT_MCP_HEADLESS_RUNTIME_TEST_OVERRIDE_ALLOWED": "1",
                    "REPOPROMPT_MCP_HEADLESS_RUNTIME_EXECUTABLE": link.path
                ],
                executableURL: nil
            )
        ) { error in
            guard case RepoPromptHeadlessLaunchBridgeError.helperNotExecutable = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}
