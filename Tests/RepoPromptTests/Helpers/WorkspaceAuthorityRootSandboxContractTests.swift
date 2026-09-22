@testable import RepoPromptApp
import XCTest

#if DEBUG
    @MainActor
    final class WorkspaceAuthorityRootSandboxContractTests: XCTestCase {
        func testCanonicalCISandboxSatisfiesRootFixtureContract() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(rootNames: ["CanonicalRoot"]) { fixture in
                XCTAssertEqual(fixture.manager.activeWorkspaceID, fixture.workspace.id)
                let capture = try await fixture.capturePassive()
                XCTAssertEqual(capture.primaryRoots.map(\.standardizedFullPath), fixture.rootPaths)
                XCTAssertEqual(capture.canonical.document.metadata.repoPaths, fixture.rootPaths)
            }
        }
    }
#endif
