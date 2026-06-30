@testable import RepoPrompt
import XCTest

final class FileSystemServiceIgnoreRecoveryTests: XCTestCase {
    private var temporaryRoots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testRepoAndCursorIgnoreLayersUseCursorPrecedence() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "FileSystemServiceIgnoreRecovery")
        try FileSystemTestSupport.write("repo", to: root.appendingPathComponent("repo-blocked.txt"))
        try FileSystemTestSupport.write("repo-only", to: root.appendingPathComponent("repo-only-blocked.txt"))
        try FileSystemTestSupport.write("cursor", to: root.appendingPathComponent("cursor-blocked.txt"))
        try FileSystemTestSupport.write("keep", to: root.appendingPathComponent("keep.txt"))
        try FileSystemTestSupport.write("repo-blocked.txt\nrepo-only-blocked.txt\n", to: root.appendingPathComponent(".repo_ignore"))
        try FileSystemTestSupport.write("cursor-blocked.txt\n!repo-blocked.txt\n", to: root.appendingPathComponent(".cursorignore"))

        let service = try await FileSystemService(
            path: root.path,
            respectRepoIgnore: true,
            respectCursorignore: true,
            skipSymlinks: true
        )

        let paths = try await FileSystemTestSupport.collectRelativePaths(from: service, root: root)

        XCTAssertTrue(paths.contains("keep.txt"))
        XCTAssertTrue(paths.contains("repo-blocked.txt"), "The higher-priority .cursorignore negation should allow this file.")
        XCTAssertFalse(paths.contains("repo-only-blocked.txt"), ".repo_ignore should hide files not re-allowed by .cursorignore.")
        XCTAssertFalse(paths.contains("cursor-blocked.txt"), ".cursorignore should hide its positive match.")
    }

    func testLoadContentsSkipsDirectorySymlinksWhenConfigured() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "FileSystemServiceIgnoreRecovery")
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileSystemTestSupport.write("visible", to: real.appendingPathComponent("visible.txt"))
        try FileSystemTestSupport.createDirectorySymlinkOrSkip(
            at: root.appendingPathComponent("linked-real"),
            destination: real
        )

        let service = try await FileSystemService(
            path: root.path,
            respectRepoIgnore: false,
            respectCursorignore: false,
            skipSymlinks: true
        )

        let paths = try await FileSystemTestSupport.collectRelativePaths(from: service, root: root)

        XCTAssertTrue(paths.contains("real"))
        XCTAssertTrue(paths.contains("real/visible.txt"))
        XCTAssertFalse(paths.contains("linked-real"))
        XCTAssertFalse(paths.contains("linked-real/visible.txt"))
    }
}
