@testable import RepoPromptApp
import XCTest

@MainActor
final class WorkspaceCodemapUIPresentationTests: XCTestCase {
    func testCurrentMarkerRequiresRenderablePresentationIdentity() throws {
        let file = makeFileViewModel(name: "Marker.swift")
        let entry = try makePresentationEntry(file: file)

        XCTAssertFalse(PromptFileEntry(file: file, codemap: nil, ranges: nil).isCodemap)
        XCTAssertTrue(PromptFileEntry(file: file, codemap: entry, ranges: nil).isCodemap)
        XCTAssertEqual(entry.fileID, file.id)
    }

    func testPreviewPayloadUsesImmutableLogicalPathAndText() throws {
        let file = makeFileViewModel(name: "Preview.swift")
        let entry = try makePresentationEntry(file: file)
        let originalText = entry.text
        let originalLogicalPath = entry.logicalPath.displayPath

        XCTAssertEqual(entry.text, originalText)
        XCTAssertEqual(entry.logicalPath.displayPath, originalLogicalPath)
        XCTAssertFalse(entry.logicalPath.displayPath.contains(file.rootFolderPath))
    }

    func testPreviewRevokesWhenRenderableFileIdentityIsGone() async {
        let manager = WorkspaceFilesViewModel()

        let disposition = await manager.codemapPreview(for: UUID())

        XCTAssertEqual(disposition, .revoked)
    }

    // The obsolete plain-folder "typed unavailable" preview contract was removed with non-Git
    // Code Map support. Positive preview coverage for a plain on-disk root now lives in
    // `CodemapAutomaticSelectionGraphNativeTests`
    // `.testFilesystemTSAndTSXCodeMapsUseCurrentBytesWithoutGitOrManifestAccess`, which asserts a
    // rendered entry containing the actual current symbols instead of an unavailability reason.

    private func makeFileViewModel(name: String) -> FileViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceCodemapUIPresentationTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return FileViewModel(
            file: File(
                name: name,
                path: root.appendingPathComponent(name).path,
                modificationDate: Date(timeIntervalSince1970: 1000)
            ),
            rootPath: root.path,
            rootIdentifier: UUID(),
            rootFolderPath: root.path,
            fileSystemService: nil
        )
    }

    private func makePresentationEntry(file: FileViewModel) throws -> WorkspaceCodemapUIPresentationEntry {
        let logicalPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "LogicalRoot",
            standardizedRelativePath: file.name
        ))
        return WorkspaceCodemapUIPresentationEntry(
            presentationID: UUID(),
            fileID: file.id,
            rootEpoch: WorkspaceCodemapRootEpoch(
                rootID: file.rootIdentifier,
                rootLifetimeID: UUID()
            ),
            logicalPath: logicalPath,
            text: SwiftFixtureSource.emptyStruct("RenderedPreview", trailingNewline: false),
            tokenCount: 7
        )
    }
}
