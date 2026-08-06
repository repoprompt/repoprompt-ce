import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class AgentRunWorkspaceAuthorityAdmissionTests: XCTestCase {
    func testExternalConflictBlocksAdmissionWithPreciseRecoveryMessage() throws {
        let reason = "saved_document_changed_while_working_state_dirty"
        let issue = DomainWorkspaceAuthorityIssue(
            workspaceID: UUID(),
            operation: "externalReload",
            kind: .externalConflict,
            reason: reason
        )

        XCTAssertThrowsError(try AgentRunMCPToolService.requireWritableWorkspaceAuthority(issue)) { error in
            XCTAssertEqual(
                String(describing: error),
                "[-32602] Invalid params: [workspace_external_conflict] agent_run.start blocked: \(reason). Resolve the workspace with Keep Local or Use External, then retry."
            )
        }
    }

    func testWritableWorkspaceAllowsAdmission() throws {
        XCTAssertNoThrow(try AgentRunMCPToolService.requireWritableWorkspaceAuthority(nil))
    }
}
