@testable import RepoPromptApp
import XCTest

@MainActor
final class MentionSuggestionServiceTests: XCTestCase {
    func testCompactSearchCapsResultsAndKeepsFileRowsUnsubtitled() {
        let fixture = makeFixture(fileCount: 8)
        let service = MentionSuggestionService(fileManager: fixture.fileManager)

        let rows = service.suggestions(for: "Match")

        XCTAssertEqual(rows.count, 5)
        XCTAssertTrue(rows.allSatisfy { $0.kind == .file })
        XCTAssertTrue(rows.allSatisfy { $0.subtitle == nil })
        XCTAssertTrue(rows.allSatisfy { $0.commitDisplayText == nil })
    }

    func testExpandedSearchUsesLargerResultCapAndParentPathSubtitles() {
        let fixture = makeFixture(fileCount: 12)
        let service = MentionSuggestionService(
            fileManager: fixture.fileManager,
            configuration: .expanded
        )

        let rows = service.suggestions(for: "Match")

        XCTAssertEqual(rows.count, 12)
        XCTAssertTrue(rows.allSatisfy { $0.kind == .file })
        XCTAssertEqual(Set(rows.compactMap(\.subtitle)), ["Sources"])
        XCTAssertTrue(rows.allSatisfy { $0.relativePath.hasPrefix("Sources/") })
        XCTAssertTrue(rows.allSatisfy { $0.commitDisplayText == nil })
    }

    func testUpdateFileManagerTracksIdentityAndDeallocation() {
        let first = WorkspaceFilesViewModel()
        let service = MentionSuggestionService(fileManager: first)

        XCTAssertFalse(service.updateFileManager(first))

        var second: WorkspaceFilesViewModel? = WorkspaceFilesViewModel()
        XCTAssertTrue(service.updateFileManager(second))
        XCTAssertFalse(service.updateFileManager(second))

        second = nil
        XCTAssertTrue(service.updateFileManager(nil))
        XCTAssertFalse(service.updateFileManager(nil))
    }

    func testSelectedFolderReturnsAllSelectedFilesWithoutCompactCap() throws {
        let fixture = makeFixture(fileCount: 7)
        for file in fixture.files {
            fixture.fileManager.selectFileForTesting(file)
        }
        let service = MentionSuggestionService(fileManager: fixture.fileManager)

        let rootRows = service.suggestions(for: "")
        let selectedFolder = try XCTUnwrap(rootRows.first(where: { $0.displayName == "Selected" }))
        let selectedRows = service.suggestions(for: "", under: selectedFolder)

        XCTAssertEqual(selectedRows.count, 7)
        XCTAssertTrue(selectedRows.allSatisfy { $0.kind == .file })
        XCTAssertTrue(selectedRows.allSatisfy { $0.subtitle == nil })
    }

    private func makeFixture(fileCount: Int) -> (
        fileManager: WorkspaceFilesViewModel,
        files: [FileViewModel]
    ) {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MentionSuggestionServiceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceURL = rootURL.appendingPathComponent("Sources", isDirectory: true)
        let date = Date(timeIntervalSince1970: 1000)
        let root = FolderViewModel(
            folder: Folder(name: "FixtureRoot", path: rootURL.path, modificationDate: date),
            rootPath: rootURL.path,
            isExpanded: true
        )
        let sources = FolderViewModel(
            folder: Folder(name: "Sources", path: sourceURL.path, modificationDate: date),
            rootPath: rootURL.path,
            hierarchyLevel: 1,
            isExpanded: true
        )

        let files = (0 ..< fileCount).map { index in
            let name = String(format: "Match%02d.swift", index)
            return FileViewModel(
                file: File(name: name, path: sourceURL.appendingPathComponent(name).path, modificationDate: date),
                rootPath: rootURL.path,
                hierarchyLevel: 2,
                rootIdentifier: root.id,
                rootFolderPath: rootURL.path,
                fileSystemService: nil,
                parentFolder: sources
            )
        }
        sources.addChildrenBatch(files.map(FileSystemItemType.file))
        root.addChildrenBatch([.folder(sources)])

        let fileManager = WorkspaceFilesViewModel()
        fileManager.addRootFolder(root)
        return (fileManager, files)
    }
}
