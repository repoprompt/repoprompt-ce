import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class AgentRunWorkspaceAuthorityAdmissionTests: XCTestCase {
    func testDegradedWorkspaceBlocksAdmissionWithPreciseRecoveryMessage() throws {
        let reason = "future_working_journal"
        let issue = DomainWorkspaceAuthorityIssue(
            workspaceID: UUID(),
            operation: "externalReload",
            kind: .degradedReadOnly,
            reason: reason
        )

        XCTAssertThrowsError(try AgentRunMCPToolService.requireWritableWorkspaceAuthority(issue)) { error in
            XCTAssertEqual(
                String(describing: error),
                "[-32602] Invalid params: [workspace_read_only_degraded] agent_run.start blocked: \(reason). Retry the workspace authority refresh after correcting the persistence problem."
            )
        }
    }

    func testWritableWorkspaceAllowsAdmission() throws {
        XCTAssertNoThrow(try AgentRunMCPToolService.requireWritableWorkspaceAuthority(nil))
    }
}
