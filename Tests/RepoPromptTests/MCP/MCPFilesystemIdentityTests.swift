import Foundation
@testable import RepoPrompt
import RepoPromptShared
import XCTest

final class MCPFilesystemIdentityTests: XCTestCase {
    func testExactCEV7DebugAndReleaseNames() {
        let debug = MCPFilesystemIdentity.repoPromptCE(.debug)
        let release = MCPFilesystemIdentity.repoPromptCE(.release)

        XCTAssertEqual(debug.protocolVersion, 7)
        XCTAssertEqual(release.protocolVersion, 7)
        XCTAssertEqual(debug.bootstrapSocketName, "repoprompt-ce-D-7.sock")
        XCTAssertEqual(release.bootstrapSocketName, "repoprompt-ce-7.sock")
        XCTAssertEqual(debug.externalEventsDirectoryName, "MCPEvents-CE-D-7")
        XCTAssertEqual(release.externalEventsDirectoryName, "MCPEvents-CE-7")
        XCTAssertEqual(debug.killSignalsDirectoryName, "MCPKillSignals-CE-D-7")
        XCTAssertEqual(release.killSignalsDirectoryName, "MCPKillSignals-CE-7")
        XCTAssertNotEqual(debug.bootstrapSocketName, release.bootstrapSocketName)
        XCTAssertNotEqual(debug.externalEventsDirectoryName, release.externalEventsDirectoryName)
    }

    func testCEConfigAndStableNamesShareOneAuthority() {
        let debug = MCPFilesystemIdentity.repoPromptCE(.debug)
        let release = MCPFilesystemIdentity.repoPromptCE(.release)

        XCTAssertEqual(debug.applicationSupportDirectoryName, "RepoPrompt CE")
        XCTAssertEqual(debug.stableWrapperConfigFileName, "discovery_debug.json")
        XCTAssertEqual(release.stableWrapperConfigFileName, "discovery.json")
        XCTAssertEqual(debug.networkConfigFileName, "mcp-config_debug.json")
        XCTAssertEqual(release.networkConfigFileName, "mcp-config.json")
        XCTAssertEqual(debug.routingStateFileName, "mcp-routing_debug.json")
        XCTAssertEqual(release.routingStateFileName, "mcp-routing.json")
        XCTAssertEqual(debug.userSpaceCLIFileName, "repoprompt_ce_cli_debug")
        XCTAssertEqual(release.userSpaceCLIFileName, "repoprompt_ce_cli")
        XCTAssertEqual(debug.pathCLICommandName, "rpce-cli-debug")
        XCTAssertEqual(release.pathCLICommandName, "rpce-cli")
        XCTAssertEqual(debug.claudeWrapperCommandName, "claude-rpce-debug")
        XCTAssertEqual(release.claudeWrapperCommandName, "claude-rpce")
    }

    func testCETemporaryRootUsesCanonicalProductDirectoryForBothBuildFlavors() {
        let fileManager = FileManager.default
        let expected = fileManager.temporaryDirectory
            .appendingPathComponent("RepoPrompt CE", isDirectory: true)

        XCTAssertEqual(
            MCPFilesystemIdentity.repoPromptCE(.debug).temporaryRootURL(fileManager: fileManager),
            expected
        )
        XCTAssertEqual(
            MCPFilesystemIdentity.repoPromptCE(.release).temporaryRootURL(fileManager: fileManager),
            expected
        )
    }

    func testAppConstantsDelegateToSharedIdentity() {
        #if DEBUG
            let expected = MCPFilesystemIdentity.repoPromptCE(.debug)
        #else
            let expected = MCPFilesystemIdentity.repoPromptCE(.release)
        #endif

        XCTAssertEqual(MCPFilesystemConstants.identity, expected)
        XCTAssertEqual(MCPFilesystemConstants.bootstrapSocketURL(), expected.bootstrapSocketURL())
        XCTAssertEqual(MCPFilesystemConstants.eventsDirectoryURL(), expected.externalEventsDirectoryURL())
    }

    func testAppAndHelperSourcesDelegateToSharedIdentity() throws {
        let root = try RepoRoot.url()
        let paths = [
            "Sources/RepoPrompt/Infrastructure/MCP/AppShared/MCPFilesystemConstants.swift",
            "Sources/RepoPromptMCP/Shared/MCPFilesystemConstants.swift"
        ]

        for path in paths {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(source.contains("MCPFilesystemIdentity.repoPromptCE"), path)
            XCTAssertFalse(source.contains("socketVersion = 6"), path)
        }
    }
}
