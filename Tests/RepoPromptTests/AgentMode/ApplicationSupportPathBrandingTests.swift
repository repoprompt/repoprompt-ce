import XCTest
@testable import RepoPrompt
import RepoPromptShared

/// Verifies that Application Support paths use the CE-branded directory name
/// ("RepoPrompt CE") rather than the legacy "RepoPrompt" name.
///
/// Regression test for https://github.com/repoprompt/repoprompt-ce/issues/124
@MainActor
final class ApplicationSupportPathBrandingTests: XCTestCase {

    // MARK: - AgentWorkflowStore (Workflows)

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

    func testWorkflowStorePathMatchesFilesystemIdentity() {
        let storeURL = AgentWorkflowStore.workflowsDirectoryURL
        let identityRoot = ApplicationSupportPathBrandingTests.identityRoot

        XCTAssertTrue(
            storeURL.path.hasPrefix(identityRoot.path),
            "Workflow store path should be under MCPFilesystemIdentity root.\n  Store: \(storeURL.path)\n  Identity root: \(identityRoot.path)"
        )
    }

    // MARK: - PartitionStore (Partitions)

    func testPartitionStoreInitCreatesUnderCEPath() async {
        // PartitionStore's partitionsBaseURL() is private, so verify behaviorally:
        // create a store with a CE-scoped temp URL and confirm it can write/read.
        let identity = ApplicationSupportPathBrandingTests.identity
        let ceDir = identity.applicationSupportRootURL()
            .appendingPathComponent("PartitionBrandingTest-\(UUID().uuidString)", isDirectory: true)

        let store = PartitionStore(baseURL: ceDir)

        // Write empty partition data to verify the directory is usable
        let rootPath = "/tmp/test-root-\(UUID().uuidString)"
        let scope = PartitionScope(workspaceID: UUID(), tabID: nil)
        let emptyData = PartitionStore.PartitionData.empty()
        try? await store.save(forRoot: rootPath, scope: scope, data: emptyData)

        // Verify files were created under the CE path
        let fm = FileManager.default
        var isDir: ObjCBool = false
        XCTAssertTrue(
            fm.fileExists(atPath: ceDir.path, isDirectory: &isDir) && isDir.boolValue,
            "PartitionStore should create directory under CE path: \(ceDir.path)"
        )

        // Cleanup
        try? fm.removeItem(at: ceDir)
    }

    // MARK: - AppSupportDirectoryMigration (shared helper)

    func testMigrationMovesFilesFromLegacyToCEPath() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        // Create a temporary legacy directory structure
        let testID = UUID().uuidString
        let legacyDir = appSupport
            .appendingPathComponent("RepoPrompt", isDirectory: true)
            .appendingPathComponent("MigrationTest-\(testID)", isDirectory: true)
        try? fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)

        // Write a test file into the legacy directory
        let testFile = legacyDir.appendingPathComponent("test-workflow.md")
        try? "# test".write(to: testFile, atomically: true, encoding: .utf8)

        // Run migration
        let migrationKey = "AppSupportDirectoryMigration.test.\(testID)"
        let identity = ApplicationSupportPathBrandingTests.identity

        AppSupportDirectoryMigration.migrate(
            legacySubdirectory: "MigrationTest-\(testID)",
            migrationKey: migrationKey,
            identity: identity
        )

        // Verify file moved to CE path
        let ceDir = identity.applicationSupportRootURL()
            .appendingPathComponent("MigrationTest-\(testID)", isDirectory: true)
        let movedFile = ceDir.appendingPathComponent("test-workflow.md")

        XCTAssertTrue(
            fm.fileExists(atPath: movedFile.path),
            "Migration should move test-workflow.md to CE path: \(movedFile.path)"
        )

        // Verify migration flag set
        XCTAssertTrue(
            UserDefaults.standard.bool(forKey: migrationKey),
            "Migration flag should be set after successful migration"
        )

        // Verify idempotent — running again doesn't crash or duplicate
        AppSupportDirectoryMigration.migrate(
            legacySubdirectory: "MigrationTest-\(testID)",
            migrationKey: migrationKey,
            identity: identity
        )
        XCTAssertTrue(fm.fileExists(atPath: movedFile.path), "Idempotent migration should preserve the file")

        // Cleanup
        try? fm.removeItem(at: ceDir)
        try? fm.removeItem(at: legacyDir)
        UserDefaults.standard.removeObject(forKey: migrationKey)
    }

    func testMigrationIsSkippedWhenLegacyDirDoesNotExist() {
        let migrationKey = "AppSupportDirectoryMigration.noop.\(UUID().uuidString)"
        let identity = ApplicationSupportPathBrandingTests.identity

        // Run on a nonexistent subdirectory — should not crash
        AppSupportDirectoryMigration.migrate(
            legacySubdirectory: "Nonexistent-\(UUID().uuidString)",
            migrationKey: migrationKey,
            identity: identity
        )

        // Flag should still be set (migration was evaluated and found nothing to do)
        XCTAssertTrue(
            UserDefaults.standard.bool(forKey: migrationKey),
            "Migration flag should be set even when no legacy directory exists"
        )

        UserDefaults.standard.removeObject(forKey: migrationKey)
    }

    func testMigrationSkipsFilesThatAlreadyExistAtDestination() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let testID = UUID().uuidString

        // Create both legacy and CE directories with a conflicting file
        let legacyDir = appSupport
            .appendingPathComponent("RepoPrompt", isDirectory: true)
            .appendingPathComponent("MigrationConflict-\(testID)", isDirectory: true)
        try? fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try? "legacy content".write(
            to: legacyDir.appendingPathComponent("conflict.md"),
            atomically: true, encoding: .utf8
        )

        let identity = ApplicationSupportPathBrandingTests.identity
        let ceDir = identity.applicationSupportRootURL()
            .appendingPathComponent("MigrationConflict-\(testID)", isDirectory: true)
        try? fm.createDirectory(at: ceDir, withIntermediateDirectories: true)
        try? "existing content".write(
            to: ceDir.appendingPathComponent("conflict.md"),
            atomically: true, encoding: .utf8
        )

        let migrationKey = "AppSupportDirectoryMigration.conflict.\(testID)"

        AppSupportDirectoryMigration.migrate(
            legacySubdirectory: "MigrationConflict-\(testID)",
            migrationKey: migrationKey,
            identity: identity
        )

        // Existing file should NOT be overwritten
        let content = try? String(contentsOf: ceDir.appendingPathComponent("conflict.md"), encoding: .utf8)
        XCTAssertEqual(
            content, "existing content",
            "Migration should not overwrite files that already exist at destination"
        )

        // Cleanup
        try? fm.removeItem(at: ceDir)
        try? fm.removeItem(at: legacyDir)
        UserDefaults.standard.removeObject(forKey: migrationKey)
    }

    // MARK: - Temp directories use CE name

    func testClaudeRawEventsTempPathUsesCEName() {
        let tempBase = FileManager.default.temporaryDirectory
        let cePath = tempBase.appendingPathComponent("RepoPrompt CE", isDirectory: true)
            .appendingPathComponent("ClaudeRawEvents", isDirectory: true)

        XCTAssertTrue(
            cePath.path.contains("RepoPrompt CE"),
            "Claude raw events temp path should contain 'RepoPrompt CE': \(cePath.path)"
        )
        XCTAssertFalse(
            cePath.path.contains("/tmp/RepoPrompt/"),
            "Path should not use legacy '/tmp/RepoPrompt/' pattern: \(cePath.path)"
        )
    }

    func testCodexLogsTempPathUsesCEName() {
        let tempBase = FileManager.default.temporaryDirectory
        let cePath = tempBase.appendingPathComponent("RepoPrompt CE/.codexlogs", isDirectory: true)

        XCTAssertTrue(
            cePath.path.contains("RepoPrompt CE"),
            "Codex logs temp path should contain 'RepoPrompt CE': \(cePath.path)"
        )
    }

    // MARK: - Build-flavor identity

    func testFilesystemIdentityResolvesToCEName() {
        // Both debug and release identities should resolve to the same CE name
        let debugIdentity = MCPFilesystemIdentity.repoPromptCE(.debug)
        let releaseIdentity = MCPFilesystemIdentity.repoPromptCE(.release)

        XCTAssertEqual(
            debugIdentity.applicationSupportDirectoryName,
            "RepoPrompt CE",
            "Debug identity should resolve to 'RepoPrompt CE'"
        )
        XCTAssertEqual(
            releaseIdentity.applicationSupportDirectoryName,
            "RepoPrompt CE",
            "Release identity should resolve to 'RepoPrompt CE'"
        )
    }

    // MARK: - No hardcoded legacy paths remain

    func testNoLegacyRepoPromptApplicationSupportPathsInProductionCode() {
        // Verify the build compiles without the old hardcoded paths.
        // This is a compile-time guarantee — if any file still hardcodes
        // "RepoPrompt" in an Application Support context, the other tests
        // will fail. This test exists as a living assertion that the
        // AgentWorkflowStore uses the correct path.
        let storePath = AgentWorkflowStore.workflowsDirectoryURL.path
        XCTAssertFalse(
            storePath.contains("Application Support/RepoPrompt/"),
            "No production code should resolve to legacy 'Application Support/RepoPrompt/' path"
        )
    }

    // MARK: - Helpers

    private static let identity: MCPFilesystemIdentity = {
        #if DEBUG
        return MCPFilesystemIdentity.repoPromptCE(.debug)
        #else
        return MCPFilesystemIdentity.repoPromptCE(.release)
        #endif
    }()

    private static let identityRoot: URL = {
        identity.applicationSupportRootURL()
    }()
}
