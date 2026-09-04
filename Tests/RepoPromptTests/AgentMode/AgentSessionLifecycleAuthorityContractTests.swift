import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentSessionLifecycleAuthorityContractTests: XCTestCase {
    func testAlreadySavedWorkspaceIsAdmittedWhenBindingIsCurrent() {
        let authority = AgentSessionLifecycleAuthority()
        let workspaceID = UUID()

        XCTAssertEqual(
            authority.decideAdmission(
                persistence: .notRequired(workspaceID: workspaceID),
                targetWorkspaceID: workspaceID,
                bindingStillCurrent: true
            ),
            .commit
        )
    }

    func testPersistedTargetWorkspaceIsAdmittedWhenBindingIsCurrent() {
        let authority = AgentSessionLifecycleAuthority()
        let workspaceID = UUID()

        XCTAssertEqual(
            authority.decideAdmission(
                persistence: .persisted(
                    workspaceID: workspaceID,
                    stateVersion: 7
                ),
                targetWorkspaceID: workspaceID,
                bindingStillCurrent: true
            ),
            .commit
        )
    }

    func testRejectedPersistenceRollsBack() {
        let authority = AgentSessionLifecycleAuthority()

        XCTAssertEqual(
            authority.decideAdmission(
                persistence: .rejected(reason: "save rejected"),
                targetWorkspaceID: UUID(),
                bindingStillCurrent: true
            ),
            .rollback(.workspacePersistenceRejected)
        )
    }

    func testStaleBindingRollsBackAfterAcceptedPersistence() {
        let authority = AgentSessionLifecycleAuthority()
        let workspaceID = UUID()

        XCTAssertEqual(
            authority.decideAdmission(
                persistence: .notRequired(workspaceID: workspaceID),
                targetWorkspaceID: workspaceID,
                bindingStillCurrent: false
            ),
            .rollback(.sessionIdentityChanged)
        )
    }

    func testPersistedDifferentWorkspaceRollsBack() {
        let authority = AgentSessionLifecycleAuthority()
        let workspaceID = UUID()

        XCTAssertEqual(
            authority.decideAdmission(
                persistence: .persisted(
                    workspaceID: UUID(),
                    stateVersion: 7
                ),
                targetWorkspaceID: workspaceID,
                bindingStillCurrent: true
            ),
            .rollback(.workspaceChanged)
        )
    }
}
