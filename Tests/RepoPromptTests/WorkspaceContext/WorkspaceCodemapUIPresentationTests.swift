@testable import RepoPrompt
import XCTest

@MainActor
final class WorkspaceCodemapUIPresentationTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

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

    func testNonGitPreviewIsTypedUnavailableWithoutCodemapArtifactWork() async throws {
        let rootURL = try makeTemporaryRoot(name: "NonGitPreview")
        let sourceURL = rootURL.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "struct NonGitPreviewType {}\n".write(to: sourceURL, atomically: true, encoding: .utf8)

        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        _ = try manager.attachRootShell(for: root, workspaceID: UUID())
        let materializedFile = await manager.materializeFileForUserInput(sourceURL.path)
        let file = try XCTUnwrap(materializedFile)

        let disposition = await manager.codemapPreview(for: file.id)
        guard case let .unavailable(coverage, issues) = disposition else {
            return XCTFail("Expected typed unavailable preview, got \(disposition)")
        }
        XCTAssertFalse(issues.isEmpty)
        if case .complete = coverage {
            XCTFail("Unavailable preview cannot report complete coverage")
        }
        await store.unloadRoot(id: root.id)
    }

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
            text: "struct RenderedPreview {}",
            tokenCount: 7
        )
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryRoots.append(root)
        return root
    }
}
