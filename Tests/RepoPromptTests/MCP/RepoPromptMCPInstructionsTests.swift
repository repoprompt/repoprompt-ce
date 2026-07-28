//
//  RepoPromptMCPInstructionsTests.swift
//  RepoPrompt
//
//  Regression tests for the MCP server instructions returned by RepoPromptMCPInstructions.
//

@testable import RepoPromptApp
import XCTest

final class RepoPromptMCPInstructionsTests: XCTestCase {
    /// All three run purposes must warn clients that `read_mcp_resource` is only for exact
    /// advertised URIs (e.g. `repoprompt://instructions`) and that workspace/root-prefixed
    /// paths must be read with `read_file`.
    func testResourceReadGuidanceIsPresentForEveryRunPurpose() {
        let purposes: [MCPRunPurpose] = [.agentModeRun, .discoverRun, .unknown]
        let requiredPhrases = [
            "read_mcp_resource",
            "read_file",
            "list_mcp_resources",
            "repoprompt://instructions",
            "workspace files",
            "agno/AGENTS.md"
        ]

        for purpose in purposes {
            let instructions = RepoPromptMCPInstructions.text(for: purpose)

            for phrase in requiredPhrases {
                XCTAssert(
                    instructions.contains(phrase),
                    "Instructions for MCPRunPurpose.\(purpose) are missing required phrase \"\(phrase)\"."
                )
            }
        }
    }
}
