import Foundation
@testable import RepoPromptHeadless
import XCTest

final class HeadlessRootAccessPolicyTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testPersistedRelativeRootIsRejectedAsAbsolutePathViolation() {
        let root = HeadlessAllowedRoot(
            id: UUID(),
            name: "Relative",
            path: "relative-root",
            resolvedPath: "/tmp/relative-root",
            addedAt: Date()
        )

        XCTAssertEqual(
            HeadlessRootAccessPolicy.validationFailures(for: [root]),
            ["Root 'Relative' is invalid: Allowed roots must be absolute paths. Received: relative-root"]
        )
    }

    func testPersistedFilesystemRootFailsClosedWithoutRewritingConfiguration() async throws {
        let directory = try makeTemporaryDirectory()
        let paths = HeadlessStatePaths(rootDirectory: directory.appendingPathComponent("State", isDirectory: true))
        let store = HeadlessConfigurationStore(paths: paths)
        _ = try store.update { configuration in
            configuration.allowedRoots = [filesystemRoot()]
        }
        let before = try Data(contentsOf: paths.configFile)

        do {
            _ = try await HeadlessHost(configurationStore: store).snapshot(requireWorkspace: true)
            XCTFail("Expected persisted filesystem root to fail validation")
        } catch let error as HeadlessCommandError {
            XCTAssertTrue(error.message.contains("Refusing to use '/' as a headless allowed root."))
        }

        XCTAssertEqual(try Data(contentsOf: paths.configFile), before)
        let workspaceFiles = try FileManager.default.contentsOfDirectory(
            at: paths.workspacesDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(workspaceFiles.contains { $0.pathExtension == "json" })
    }

    func testPersistedFilesystemRootCannotBeSelectedWithoutRewritingConfiguration() async throws {
        let directory = try makeTemporaryDirectory()
        let paths = HeadlessStatePaths(rootDirectory: directory.appendingPathComponent("State", isDirectory: true))
        let root = filesystemRoot()
        let workspace = HeadlessWorkspaceDocument(name: "Existing", rootIDs: [root.id])
        try HeadlessWorkspaceStore(paths: paths).save(workspace)
        let store = HeadlessConfigurationStore(paths: paths)
        _ = try store.update { configuration in
            configuration.allowedRoots = [root]
            configuration.activeWorkspaceID = nil
        }
        let before = try Data(contentsOf: paths.configFile)

        do {
            _ = try await HeadlessHost(configurationStore: store).selectWorkspace(token: workspace.id.uuidString)
            XCTFail("Expected workspace selection to reject persisted filesystem root")
        } catch let error as HeadlessCommandError {
            XCTAssertTrue(error.message.contains("Refusing to use '/' as a headless allowed root."))
        }

        XCTAssertEqual(try Data(contentsOf: paths.configFile), before)
    }

    private func filesystemRoot() -> HeadlessAllowedRoot {
        HeadlessAllowedRoot(
            id: UUID(),
            name: "FilesystemRoot",
            path: "/",
            resolvedPath: "/",
            addedAt: Date()
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = HeadlessTestTemporaryDirectory.baseURL
            .appendingPathComponent("RepoPromptHeadlessRootPolicy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
