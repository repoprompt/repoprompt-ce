@testable import RepoPrompt
import XCTest

final class WorkspaceGitignorePolicyIdentityTests: XCTestCase {
    func testCurrentIdentityUsesGitIgnoreFloorV3() {
        XCTAssertEqual(WorkspaceGitignorePolicyIdentity.current, .gitIgnoreFloorV3)
        XCTAssertEqual(
            WorkspaceGitignorePolicyIdentity.current.rawValue,
            "mandatory-gitignore-floor-reachable-controls-v3"
        )
    }

    func testLoadedRootUsesMandatoryIdentityAndExcludesIgnoredFiles() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceGitignorePolicyIdentityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data("ignored.txt\n".utf8).write(to: rootURL.appendingPathComponent(".gitignore"))
        try Data("ignored".utf8).write(to: rootURL.appendingPathComponent("ignored.txt"))
        try Data("kept".utf8).write(to: rootURL.appendingPathComponent("kept.txt"))

        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)

        let identity = await store.gitignorePolicyIdentityForTesting(rootID: root.id)
        let paths = await store.files(inRoot: root.id).map(\.standardizedRelativePath)
        XCTAssertEqual(identity, .gitIgnoreFloorV3)
        XCTAssertTrue(paths.contains("kept.txt"))
        XCTAssertFalse(paths.contains("ignored.txt"))
        await store.unloadRoot(id: root.id)
    }
}
