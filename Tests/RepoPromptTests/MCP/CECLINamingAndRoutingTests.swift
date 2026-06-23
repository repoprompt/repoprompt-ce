import Foundation
@testable import RepoPrompt
import XCTest

final class CECLINamingAndRoutingTests: XCTestCase {
    func testCanonicalCECLICommandsAndStableConfigUseCEIdentity() {
        do {
            let caseLabel = "testCanonicalCEPathCommandNames"
            #if DEBUG
                XCTAssertEqual(CLIPathInstaller.cliCommandName, "rpce-cli-debug", caseLabel)
                XCTAssertEqual(CLIPathInstaller.claudeRPCommandName, "claude-rpce-debug", caseLabel)
            #else
                XCTAssertEqual(CLIPathInstaller.cliCommandName, "rpce-cli", caseLabel)
                XCTAssertEqual(CLIPathInstaller.claudeRPCommandName, "claude-rpce", caseLabel)
            #endif
        }

        do {
            let caseLabel = "testConfigExporterUsesCEOwnedStablePath"
            let path = MCPConfigExportService.stableWrapperConfigURL.path
            XCTAssertTrue(path.contains("Library/Application Support/RepoPrompt CE/MCP"), caseLabel + ": " + path)
            #if DEBUG
                XCTAssertTrue(CLIPathInstaller.test_claudeRPScriptContent().contains(path), caseLabel)
            #endif
        }
    }

    func testUserSpaceSymlinkPathUsesApplicationSupport() {
        let path = CLISymlinkManagerUserSpace.userSymlinkPath
        XCTAssertTrue(path.contains("Library/Application Support/RepoPrompt CE"), path)
        #if DEBUG
            XCTAssertTrue(path.hasSuffix("repoprompt_ce_cli_debug"), path)
        #else
            XCTAssertTrue(path.hasSuffix("repoprompt_ce_cli"), path)
        #endif
    }

    #if DEBUG
        func testClaudeRPCEWrapperMarkerDetection() {
            let generated = CLIPathInstaller.test_claudeRPScriptContent()
            XCTAssertTrue(generated.contains("# claude-rpce: Claude Code wrapper configured for RepoPrompt CE"))
            XCTAssertTrue(CLIPathInstaller.test_isManagedClaudeRPScript(generated))
            XCTAssertTrue(CLIPathInstaller.test_isManagedClaudeRPScript("# claude-rp-ce: Claude Code wrapper configured for RepoPrompt CE\n"))
            XCTAssertFalse(CLIPathInstaller.test_isManagedClaudeRPScript("#!/bin/bash\necho '# claude-rpce: Claude Code wrapper configured for RepoPrompt CE'\n"))
            XCTAssertFalse(CLIPathInstaller.test_isManagedClaudeRPScript("#!/bin/bash\necho unrelated\n"))
        }
    #endif
}
