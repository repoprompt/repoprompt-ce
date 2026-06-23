import Foundation
@testable import RepoPrompt
import RepoPromptShared
import XCTest

final class MCPFilesystemIdentityTests: XCTestCase {
    func testCEFilesystemIdentityPreservesVersionedFlavorAndStableConfigurationNames() {
        do {
            let caseLabel = "testExactCEV7DebugAndReleaseNames"
            let debug = MCPFilesystemIdentity.repoPromptCE(.debug)
            let release = MCPFilesystemIdentity.repoPromptCE(.release)

            XCTAssertEqual(debug.protocolVersion, 7, caseLabel)
            XCTAssertEqual(release.protocolVersion, 7, caseLabel)
            XCTAssertEqual(debug.bootstrapSocketName, "repoprompt-ce-D-7.sock", caseLabel)
            XCTAssertEqual(release.bootstrapSocketName, "repoprompt-ce-7.sock", caseLabel)
            XCTAssertEqual(debug.externalEventsDirectoryName, "MCPEvents-CE-D-7", caseLabel)
            XCTAssertEqual(release.externalEventsDirectoryName, "MCPEvents-CE-7", caseLabel)
            XCTAssertEqual(debug.killSignalsDirectoryName, "MCPKillSignals-CE-D-7", caseLabel)
            XCTAssertEqual(release.killSignalsDirectoryName, "MCPKillSignals-CE-7", caseLabel)
            XCTAssertNotEqual(debug.bootstrapSocketName, release.bootstrapSocketName, caseLabel)
            XCTAssertNotEqual(debug.externalEventsDirectoryName, release.externalEventsDirectoryName, caseLabel)
        }

        do {
            let caseLabel = "testCEConfigAndStableNamesShareOneAuthority"
            let debug = MCPFilesystemIdentity.repoPromptCE(.debug)
            let release = MCPFilesystemIdentity.repoPromptCE(.release)

            XCTAssertEqual(debug.applicationSupportDirectoryName, "RepoPrompt CE", caseLabel)
            XCTAssertEqual(debug.stableWrapperConfigFileName, "discovery_debug.json", caseLabel)
            XCTAssertEqual(release.stableWrapperConfigFileName, "discovery.json", caseLabel)
            XCTAssertEqual(debug.networkConfigFileName, "mcp-config_debug.json", caseLabel)
            XCTAssertEqual(release.networkConfigFileName, "mcp-config.json", caseLabel)
            XCTAssertEqual(debug.routingStateFileName, "mcp-routing_debug.json", caseLabel)
            XCTAssertEqual(release.routingStateFileName, "mcp-routing.json", caseLabel)
            XCTAssertEqual(debug.userSpaceCLIFileName, "repoprompt_ce_cli_debug", caseLabel)
            XCTAssertEqual(release.userSpaceCLIFileName, "repoprompt_ce_cli", caseLabel)
            XCTAssertEqual(debug.pathCLICommandName, "rpce-cli-debug", caseLabel)
            XCTAssertEqual(release.pathCLICommandName, "rpce-cli", caseLabel)
            XCTAssertEqual(debug.claudeWrapperCommandName, "claude-rpce-debug", caseLabel)
            XCTAssertEqual(release.claudeWrapperCommandName, "claude-rpce", caseLabel)
        }
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

    func testAppAndHelperFilesystemConstantsDelegateToSharedIdentity() throws {
        do {
            let caseLabel = "testAppConstantsDelegateToSharedIdentity"
            #if DEBUG
                let expected = MCPFilesystemIdentity.repoPromptCE(.debug)
            #else
                let expected = MCPFilesystemIdentity.repoPromptCE(.release)
            #endif

            XCTAssertEqual(MCPFilesystemConstants.identity, expected, caseLabel)
            XCTAssertEqual(MCPFilesystemConstants.bootstrapSocketURL(), expected.bootstrapSocketURL(), caseLabel)
            XCTAssertEqual(MCPFilesystemConstants.eventsDirectoryURL(), expected.externalEventsDirectoryURL(), caseLabel)
        }

        do {
            let caseLabel = "testAppAndHelperSourcesDelegateToSharedIdentity"
            let root = try RepoRoot.url()
            let paths = [
                "Sources/RepoPrompt/Infrastructure/MCP/AppShared/MCPFilesystemConstants.swift",
                "Sources/RepoPromptMCP/Shared/MCPFilesystemConstants.swift"
            ]

            for path in paths {
                let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
                XCTAssertTrue(source.contains("MCPFilesystemIdentity.repoPromptCE"), caseLabel + ": " + path)
                XCTAssertFalse(source.contains("socketVersion = 6"), caseLabel + ": " + path)
            }
        }
    }
}
