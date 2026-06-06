import Foundation
@testable import RepoPrompt
import XCTest

final class CECLINamingAndRoutingTests: XCTestCase {
    func testCanonicalCEPathCommandNames() {
        #if DEBUG
            XCTAssertEqual(CLIPathInstaller.cliCommandName, "rpce-cli-debug")
            XCTAssertEqual(CLIPathInstaller.claudeRPCommandName, "claude-rpce-debug")
        #else
            XCTAssertEqual(CLIPathInstaller.cliCommandName, "rpce-cli")
            XCTAssertEqual(CLIPathInstaller.claudeRPCommandName, "claude-rpce")
        #endif
    }

    func testConfigExporterUsesCEOwnedStablePath() {
        let path = MCPConfigExportService.stableWrapperConfigURL.path
        XCTAssertTrue(path.contains("Library/Application Support/RepoPrompt CE/MCP"), path)
        #if DEBUG
            XCTAssertTrue(CLIPathInstaller.test_claudeRPScriptContent().contains(path))
        #endif
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

    func testNamedSourcesDoNotAdvertiseStaleDebugCommandNames() throws {
        let root = try RepoRoot.url()
        let workflowPromptSourceRoot = root.appendingPathComponent("Sources/RepoPrompt/Infrastructure/AI/Prompts/Workflows")
        let workflowPromptSources = try FileManager.default.contentsOfDirectory(
            at: workflowPromptSourceRoot,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .map { RepoRoot.relativePath(for: $0, relativeTo: root) }
        .sorted()

        let relativePaths = [
            "Sources/RepoPrompt/Features/Settings/Views/MCPSettingsView.swift",
            "Sources/RepoPrompt/Features/AgentMode/Views/AgentOnboardingWizardView.swift",
            "Sources/RepoPrompt/Infrastructure/UI/Components/MCPServerToggleView.swift",
            "Sources/RepoPrompt/Infrastructure/MCP/MCPIntegrationHelper.swift",
            "Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnostics.swift",
            "Sources/RepoPromptMCP/CommandRunner/MCPCommandRunner.swift",
            "Sources/RepoPromptMCP/Interactive/InteractiveREPL.swift",
            "Sources/RepoPromptMCP/main.swift"
        ] + workflowPromptSources
        let forbidden = [
            "rp-cli",
            "rp-cli-ce-debug",
            "rp-ce-cli",
            "rp-ce-cli-debug",
            "claude-rp-ce-debug",
            "rp-cli-debug",
            "claude-rp-debug"
        ]

        for relativePath in relativePaths {
            let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            for staleName in forbidden {
                XCTAssertFalse(text.contains(staleName), "\(relativePath) still contains \(staleName)")
            }
        }
    }

    func testManageWorktreeIsExposedInCECLISurfaces() throws {
        let root = try RepoRoot.url()

        let parserText = try String(
            contentsOf: root.appendingPathComponent("Sources/RepoPromptMCP/CommandRunner/MCPCommandParser.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(parserText.contains("case \"manage_worktree\":"), "Parser should recognize manage_worktree as a direct raw MCP command")
        XCTAssertTrue(parserText.contains("aliasCall(toolName: \"manage_worktree\""), "Parser should route key=value args to manage_worktree")
        XCTAssertTrue(parserText.contains("call(toolName: \"manage_worktree\""), "Parser should route JSON args to manage_worktree")

        let groupsText = try String(
            contentsOf: root.appendingPathComponent("Sources/RepoPromptMCP/CommandRunner/ToolGroups.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(groupsText.contains("case git"), "CLI tool groups should expose a git group")
        XCTAssertTrue(groupsText.contains(".git: ["), "Git group should have an explicit mapping")
        XCTAssertTrue(groupsText.contains("\"manage_worktree\""), "Git group should include manage_worktree")

        let runnerHelpText = try String(
            contentsOf: root.appendingPathComponent("Sources/RepoPromptMCP/CommandRunner/MCPCommandRunner.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(runnerHelpText.contains("tools git --schema"), "Exec help should advertise git schema filtering")
        XCTAssertTrue(runnerHelpText.contains("manage_worktree op=list"), "Exec help should advertise direct manage_worktree usage")

        let mainHelpText = try String(
            contentsOf: root.appendingPathComponent("Sources/RepoPromptMCP/main.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(mainHelpText.contains("-d manage_worktree"), "Top-level help should advertise manage_worktree schema docs")
        XCTAssertTrue(mainHelpText.contains("--tools-schema=git"), "Top-level help should advertise git schema filtering")
        XCTAssertTrue(mainHelpText.contains("manage_worktree op=list"), "Top-level help should advertise direct manage_worktree usage")
    }

    func testProviderNeutralWorkflowPromptSourcesReplacedLegacyWorkflowPromptFile() throws {
        let root = try RepoRoot.url()
        let oldFile = root.appendingPathComponent("Sources/RepoPrompt/Infrastructure/Process/CLI/" + "Claude" + "CodeCommands.swift")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))

        let sourceRoot = root.appendingPathComponent("Sources/RepoPrompt")
        let enumerator = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertFalse(text.contains("Claude" + "CodeCommands"), "\(fileURL.path) still references legacy workflow prompt namespace")
        }
    }
}
