@testable import RepoPrompt
import XCTest

@MainActor
final class WorkspaceFilesAutoCodemapModeTests: XCTestCase {
    private var temporaryRoots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testExplicitCodemapRemovalDisablesAutoForPresentAndEmptySelections() {
        do {
            let fixture = makeFixture(fileName: "Present.swift")
            fixture.viewModel.setFileAsCodemap(fixture.file)
            fixture.viewModel.codemapAutoEnabled = true

            fixture.viewModel.removeCodemapFile(fixture.file)

            XCTAssertFalse(fixture.viewModel.codemapAutoEnabled)
            XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
            XCTAssertFalse(fixture.viewModel.isAutoCodemapFile(fixture.file))
        }

        do {
            let fixture = makeFixture(fileName: "Empty.swift")
            XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
            XCTAssertTrue(fixture.viewModel.codemapAutoEnabled)

            fixture.viewModel.clearAutoCodemapFiles()

            XCTAssertFalse(fixture.viewModel.codemapAutoEnabled)
            XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
        }

        do {
            let fixture = makeFixture(fileName: "Absent.swift")

            fixture.viewModel.removeCodemapFile(fixture.file)

            XCTAssertTrue(fixture.viewModel.codemapAutoEnabled)
            XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
        }
    }

    func testOrdinaryFileRemovalPreservesAutoAndFullClearRestoresIt() async {
        do {
            let fixture = makeFixture(fileName: "Selected.swift")
            fixture.viewModel.selectFileForTesting(fixture.file)
            XCTAssertTrue(fixture.viewModel.codemapAutoEnabled)

            fixture.viewModel.removeFileFromAllSelections(fixture.file)

            XCTAssertTrue(fixture.viewModel.selectedFiles.isEmpty)
            XCTAssertTrue(fixture.viewModel.codemapAutoEnabled)
        }

        do {
            let fixture = makeFixture(fileName: "Clear.swift")
            fixture.viewModel.setFileAsCodemap(fixture.file)
            XCTAssertFalse(fixture.viewModel.codemapAutoEnabled)
            XCTAssertEqual(fixture.viewModel.autoCodemapFiles.map(\.id), [fixture.file.id])

            await fixture.viewModel.clearSelection()

            XCTAssertTrue(fixture.viewModel.selectedFiles.isEmpty)
            XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
            XCTAssertTrue(fixture.viewModel.codemapAutoEnabled)
        }
    }

    func testVisibleAutoCodemapExcludesSessionRootsAndPreservesSlicesAndManualMode() async throws {
        #if DEBUG
            let visibleRootURL = try temporaryRoots.makeRoot(suiteName: "VisibleAutoCodemapRoot")
            let hiddenRootURL = try temporaryRoots.makeRoot(suiteName: "HiddenAutoCodemapWorktree")
            let selectedURL = visibleRootURL.appendingPathComponent("Selected.swift")
            let visibleDependencyURL = visibleRootURL.appendingPathComponent("VisibleDependency.swift")
            let hiddenDependencyURL = hiddenRootURL.appendingPathComponent("HiddenDependency.swift")
            try "let selected = true\n".write(to: selectedURL, atomically: true, encoding: .utf8)
            try "struct DependencyType {}\n".write(to: visibleDependencyURL, atomically: true, encoding: .utf8)
            try "struct DependencyType {}\n".write(to: hiddenDependencyURL, atomically: true, encoding: .utf8)

            let store = WorkspaceFileContextStore()
            let visibleRoot = try await store.loadRoot(path: visibleRootURL.path)
            let hiddenRoot = try await store.loadRoot(path: hiddenRootURL.path, kind: .sessionWorktree)
            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            await manager.setCodeScanEnabled(false)
            _ = try manager.attachRootShell(for: visibleRoot, workspaceID: UUID())
            _ = try manager.attachRootShell(for: hiddenRoot, workspaceID: UUID())

            let visibleRecords = await store.files(inRoot: visibleRoot.id)
            let hiddenRecords = await store.files(inRoot: hiddenRoot.id)
            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: visibleRoot.id,
                rootPath: visibleRoot.standardizedFullPath,
                generation: 1,
                upsertedFiles: visibleRecords
            ))
            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: hiddenRoot.id,
                rootPath: hiddenRoot.standardizedFullPath,
                generation: 1,
                upsertedFiles: hiddenRecords
            ))

            let selected = try XCTUnwrap(manager.findFileByFullPath(selectedURL.path))
            let visibleDependency = try XCTUnwrap(manager.findFileByFullPath(visibleDependencyURL.path))
            let hiddenDependency = try XCTUnwrap(manager.findFileByFullPath(hiddenDependencyURL.path))
            XCTAssertLessThan(hiddenDependency.standardizedFullPath, visibleDependency.standardizedFullPath)
            let selectedAPI = makeFileAPI(
                path: selectedURL.path,
                symbolName: "selectedSymbol",
                referencedTypes: ["DependencyType"]
            )
            let visibleAPI = makeFileAPI(
                path: visibleDependencyURL.path,
                symbolName: "visibleDependencySymbol",
                className: "DependencyType"
            )
            let hiddenAPI = makeFileAPI(
                path: hiddenDependencyURL.path,
                symbolName: "hiddenDependencySymbol",
                className: "DependencyType"
            )
            selected.setCodeMap(selectedAPI)
            visibleDependency.setCodeMap(visibleAPI)
            hiddenDependency.setCodeMap(hiddenAPI)
            await store.applyObservedCodemapResults([
                WorkspaceObservedCodemapResult(fullPath: selectedURL.path, modificationDate: Date(), fileAPI: selectedAPI),
                WorkspaceObservedCodemapResult(fullPath: visibleDependencyURL.path, modificationDate: Date(), fileAPI: visibleAPI),
                WorkspaceObservedCodemapResult(fullPath: hiddenDependencyURL.path, modificationDate: Date(), fileAPI: hiddenAPI)
            ])

            manager.selectFileForTesting(selected)
            let slice = LineRange(start: 1, end: 1)
            manager.seedSelectionSlicesForTesting([slice], for: selected)
            await manager.flushAutoCodemapSyncNowIfNeeded()

            let automatic = manager.snapshotSelection()
            XCTAssertEqual(automatic.autoCodemapPaths, [visibleDependency.standardizedFullPath])
            XCTAssertFalse(automatic.autoCodemapPaths.contains(hiddenDependency.standardizedFullPath))
            XCTAssertEqual(automatic.slices[selected.standardizedFullPath], [slice])
            XCTAssertTrue(automatic.codemapAutoEnabled)

            manager.setFileAsCodemap(visibleDependency)
            let manualBeforeFlush = manager.snapshotSelection()
            await manager.flushAutoCodemapSyncNowIfNeeded()
            let manualAfterFlush = manager.snapshotSelection()
            XCTAssertFalse(manualAfterFlush.codemapAutoEnabled)
            XCTAssertEqual(manualAfterFlush.autoCodemapPaths, manualBeforeFlush.autoCodemapPaths)
            XCTAssertEqual(manualAfterFlush.slices, manualBeforeFlush.slices)

            await manager.unloadAllRootFolders()
        #endif
    }

    private func makeFixture(fileName: String) -> (
        viewModel: WorkspaceFilesViewModel,
        file: FileViewModel
    ) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceFilesAutoCodemapModeTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootID = UUID()
        let file = FileViewModel(
            file: File(
                name: fileName,
                path: rootURL.appendingPathComponent(fileName).path,
                modificationDate: Date(timeIntervalSince1970: 1000)
            ),
            rootPath: rootURL.path,
            rootIdentifier: rootID,
            rootFolderPath: rootURL.path,
            fileSystemService: nil
        )
        return (WorkspaceFilesViewModel(), file)
    }

    private func makeFileAPI(
        path: String,
        symbolName: String,
        className: String? = nil,
        referencedTypes: [String] = []
    ) -> FileAPI {
        FileAPI(
            filePath: path,
            imports: [],
            classes: className.map { [ClassInfo(name: $0, methods: [], properties: [])] } ?? [],
            functions: [
                FunctionInfo(
                    name: symbolName,
                    parameters: [],
                    returnType: nil,
                    definitionLine: "func \(symbolName)()",
                    lineNumber: 1
                )
            ],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: referencedTypes
        )
    }
}
