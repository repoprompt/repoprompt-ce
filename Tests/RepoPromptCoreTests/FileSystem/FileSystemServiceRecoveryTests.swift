@testable import RepoPromptCore
import XCTest

final class FileSystemServiceRecoveryTests: XCTestCase {
    private var temporaryRoots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testTempRootCreateEditReadExistsAndModificationDate() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "FileSystemServiceRecovery")
        let service = try await FileSystemService(
            path: root.path,
            respectGitignore: false,
            respectRepoIgnore: false,
            respectCursorignore: false,
            skipSymlinks: true
        )

        try await service.createFile(atRelativePath: "src/Note.txt", content: "first")
        let existsAfterCreate = await service.fileExistsOnDisk(relativePath: "src/../src/Note.txt")
        let contentAfterCreate = try await service.loadContent(ofRelativePath: "src/./Note.txt")
        XCTAssertTrue(existsAfterCreate)
        XCTAssertEqual(contentAfterCreate, "first")

        try await service.editFile(atRelativePath: "src/Note.txt", newContent: "second")
        let loaded = try await service.loadContentWithDate(ofRelativePath: "src/Note.txt")
        XCTAssertEqual(loaded.content, "second")
        XCTAssertGreaterThan(loaded.modificationDate.timeIntervalSince1970, 0)
    }
}
