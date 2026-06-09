import XCTest
@testable import RepoPrompt
import RepoPromptShared

/// Verifies that Application Support paths use the CE-branded directory name
/// ("RepoPrompt CE") rather than the legacy "RepoPrompt" name.
///
/// Regression test for https://github.com/repoprompt/repoprompt-ce/issues/124
@MainActor
final class ApplicationSupportPathBrandingTests: XCTestCase {

    // MARK: - AgentWorkflowStore

    func testWorkflowStoreUsesCEApplicationSupportPath() {
        let url = AgentWorkflowStore.workflowsDirectoryURL

        // Must contain "RepoPrompt CE" not bare "RepoPrompt"
        let path = url.path
        XCTAssertTrue(
            path.contains("RepoPrompt CE"),
            "AgentWorkflowStore.workflowsDirectoryURL should use 'RepoPrompt CE' but got: \(path)"
        )
        XCTAssertFalse(
            path.contains("Application Support/RepoPrompt/"),
            "Path should not use legacy 'Application Support/RepoPrompt/' but got: \(path)"
        )
        XCTAssertTrue(
            path.hasSuffix("Workflows"),
            "Path should end with 'Workflows' but got: \(path)"
        )
    }

    // MARK: - MCPFilesystemIdentity consistency

    func testWorkflowStorePathMatchesFilesystemIdentity() {
        let storeURL = AgentWorkflowStore.workflowsDirectoryURL
        let identityRoot = MCPFilesystemIdentity.repoPromptCE(.debug).applicationSupportRootURL()

        XCTAssertTrue(
            storeURL.path.hasPrefix(identityRoot.path),
            "Workflow store path should be under MCPFilesystemIdentity root.\n  Store: \(storeURL.path)\n  Identity root: \(identityRoot.path)"
        )
    }
}
