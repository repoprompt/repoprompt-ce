@testable import RepoPromptApp
import XCTest

final class WorkspaceRootCatalogAdmissibilityTests: XCTestCase {
    func testCatalogAdmissionPrecedesSearchAdmissionOnlyAfterCatalogCompletion() {
        let workspaceID = UUID()
        let diagnostics = WorkspaceCatalogDiagnostics(
            generation: 1,
            rootScope: .visibleWorkspace,
            rootCount: 1,
            folderCount: 0,
            fileCount: 0
        )
        let cases: [(WorkspaceSearchReadinessState, Bool, Bool)] = [
            (.idle, false, false),
            (.activating(workspaceID: workspaceID, generation: 1), false, false),
            (.loadingCatalog(
                workspaceID: workspaceID,
                generation: 1,
                loadedRootCount: 0,
                expectedRootCount: 1,
                failures: []
            ), false, false),
            (.buildingIndexes(
                workspaceID: workspaceID,
                generation: 1,
                catalogGeneration: 1,
                failures: []
            ), true, false),
            (.ready(
                workspaceID: workspaceID,
                generation: 1,
                catalogGeneration: 1,
                indexedGeneration: 1,
                diagnostics: diagnostics
            ), true, true),
            (.degraded(
                workspaceID: workspaceID,
                generation: 1,
                catalogGeneration: 1,
                indexedGeneration: nil,
                failures: [],
                diagnostics: diagnostics
            ), true, true),
            (.degraded(
                workspaceID: workspaceID,
                generation: 1,
                catalogGeneration: nil,
                indexedGeneration: nil,
                failures: [],
                diagnostics: nil
            ), false, true)
        ]

        for (state, expectedCatalog, expectedSearch) in cases {
            XCTAssertEqual(state.isRootCatalogAdmissible, expectedCatalog, "state: \(state)")
            XCTAssertEqual(state.isSearchAdmissible, expectedSearch, "state: \(state)")
        }
    }
}
