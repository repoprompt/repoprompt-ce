@testable import RepoPrompt
import XCTest

@MainActor
final class AgentModeSessionNamingPromptTests: XCTestCase {
    func testAgentModeInstructionsAndEveryRolePromptRequireVerifiedSetStatusRenames() {
        let agentModeInstructions = RepoPromptMCPInstructions.text(for: .agentModeRun)
        XCTAssertTrue(agentModeInstructions.contains("explicitly asks to name, rename, or retitle"))
        XCTAssertTrue(agentModeInstructions.contains("Do not claim that the title changed unless set_status returns success."))

        let discoverInstructions = RepoPromptMCPInstructions.text(for: .discoverRun)
        XCTAssertFalse(discoverInstructions.contains("SESSION NAMING"))
        XCTAssertFalse(discoverInstructions.contains("set_status"))

        let roles: [AgentModelCatalog.TaskLabelKind?] =
            [nil] + AgentModelCatalog.TaskLabelKind.allCases.map(Optional.some)
        for agent in [AgentProviderKind.codexExec, .claudeCode] {
            for role in roles {
                let prompt = SystemPromptService.agentModePrompt(
                    agentKind: agent,
                    taskLabelKind: role
                )
                XCTAssertTrue(
                    prompt.contains("explicitly asks to name, rename, or retitle"),
                    "agent=\(agent.rawValue), role=\(role?.rawValue ?? "nil")"
                )
                XCTAssertTrue(
                    prompt.lowercased().contains("do not claim success unless the tool succeeds"),
                    "agent=\(agent.rawValue), role=\(role?.rawValue ?? "nil")"
                )
            }
        }

        XCTAssertTrue(
            MCPAgentSessionControlToolProvider.setStatusDescription
                .contains("explicitly asks to name, rename, or retitle")
        )
        XCTAssertTrue(
            MCPAgentSessionControlToolProvider.setStatusDescription
                .contains("Do not tell the user the title changed unless this tool returns success.")
        )
    }
}
