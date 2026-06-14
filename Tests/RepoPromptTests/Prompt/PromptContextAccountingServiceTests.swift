@testable import RepoPrompt
import XCTest

final class PromptContextAccountingServiceTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryRoots {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testExactSelectedFilesPreserveStoredSelectionOrderAfterBatchLookupAndConcurrentReads() async throws {
        let root = try makeTemporaryRoot(name: "AccountingOrder")
        let fileA = root.appendingPathComponent("A.swift")
        let fileB = root.appendingPathComponent("B.swift")
        let fileC = root.appendingPathComponent("C.swift")
        try write("alpha", to: fileA)
        try write("beta", to: fileB)
        try write("gamma", to: fileC)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let service = PromptContextAccountingService()
        let selection = StoredSelection(
            selectedPaths: [fileC.path, fileA.path, fileB.path],
            autoCodemapPaths: [],
            slices: [:],
            codemapAutoEnabled: false
        )

        let resolution = await service.resolveEntries(selection: selection, store: store, codeMapUsage: .none)

        XCTAssertEqual(resolution.entries.map(\.file.standardizedRelativePath), ["C.swift", "A.swift", "B.swift"])
        XCTAssertEqual(resolution.entries.map(\.loadedContent), ["gamma", "alpha", "beta"])
        XCTAssertEqual(resolution.missingPaths, [])
        XCTAssertEqual(resolution.invalidPaths, [])
    }

    func testPhysicalizedSelectionRefreshesSessionBoundBatchLookupAfterWorktreeLoad() async throws {
        let logicalRoot = try makeTemporaryRoot(name: "AccountingLogical")
        let worktreeRoot = try makeTemporaryRoot(name: "AccountingWorktree")
        let logicalFile = logicalRoot.appendingPathComponent("Sources/App.swift")
        let worktreeFile = worktreeRoot.appendingPathComponent("Sources/App.swift")
        try write("canonical", to: logicalFile)
        try write("worktree", to: worktreeFile)

        let store = WorkspaceFileContextStore()
        let logicalRootRecord = try await store.loadRoot(path: logicalRoot.path)
        let logicalRootRef = WorkspaceRootRef(
            id: logicalRootRecord.id,
            name: logicalRootRecord.name,
            fullPath: logicalRootRecord.standardizedFullPath
        )
        let physicalRootRef = WorkspaceRootRef(
            id: UUID(),
            name: logicalRootRecord.name,
            fullPath: worktreeRoot.path
        )
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: logicalRootRef,
                    physicalRoot: physicalRootRef,
                    binding: AgentSessionWorktreeBinding(
                        id: "accounting-binding",
                        repositoryID: "accounting-repository",
                        repoKey: "accounting-repo",
                        logicalRootPath: logicalRoot.path,
                        logicalRootName: logicalRootRecord.name,
                        worktreeID: "accounting-worktree",
                        worktreeRootPath: worktreeRoot.path,
                        source: "test"
                    )
                )
            ],
            visibleLogicalRoots: [logicalRootRef]
        )
        let lookupContext = WorkspaceLookupContext(
            rootScope: projection.lookupRootScope,
            bindingProjection: projection
        )
        let logicalSelection = StoredSelection(
            selectedPaths: [logicalFile.path],
            codemapAutoEnabled: false
        )
        let physicalSelection = lookupContext.physicalizeSelection(logicalSelection)
        XCTAssertEqual(physicalSelection.selectedPaths, [worktreeFile.path])

        let request = WorkspacePathLookupRequest(
            userPath: worktreeFile.path,
            profile: .uiAssisted,
            rootScope: lookupContext.rootScope
        )
        let generationBeforeWorktreeLoad = await store.catalogGeneration(rootScope: lookupContext.rootScope)
        let lookupBeforeWorktreeLoad = await store.lookupPaths([request])
        XCTAssertTrue(lookupBeforeWorktreeLoad.isEmpty)

        let worktreeRootRecord = try await store.loadRoot(path: worktreeRoot.path, kind: .sessionWorktree)
        let generationAfterWorktreeLoad = await store.catalogGeneration(rootScope: lookupContext.rootScope)
        XCTAssertNotEqual(generationAfterWorktreeLoad, generationBeforeWorktreeLoad)
        let resolution = await PromptContextAccountingService().resolveEntries(
            selection: physicalSelection,
            store: store,
            rootScope: lookupContext.rootScope,
            codeMapUsage: .none
        )

        let entry = try XCTUnwrap(resolution.entries.first)
        XCTAssertEqual(resolution.entries.count, 1)
        XCTAssertEqual(entry.file.rootID, worktreeRootRecord.id)
        XCTAssertEqual(entry.file.standardizedRelativePath, "Sources/App.swift")
        XCTAssertEqual(entry.loadedContent, "worktree")
        XCTAssertEqual(resolution.missingPaths, [])
        XCTAssertEqual(resolution.invalidPaths, [])
    }

    func testDuplicateSelectedPathsPreserveExistingEntryDedupOrder() async throws {
        let root = try makeTemporaryRoot(name: "AccountingDuplicates")
        let fileA = root.appendingPathComponent("A.swift")
        let fileB = root.appendingPathComponent("B.swift")
        try write("alpha", to: fileA)
        try write("beta", to: fileB)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let service = PromptContextAccountingService()
        let selection = StoredSelection(
            selectedPaths: [fileA.path, fileA.path, fileB.path],
            autoCodemapPaths: [],
            slices: [:],
            codemapAutoEnabled: false
        )

        let resolution = await service.resolveEntries(selection: selection, store: store, codeMapUsage: .none)

        XCTAssertEqual(resolution.entries.map(\.file.standardizedRelativePath), ["A.swift", "B.swift"])
        XCTAssertEqual(resolution.entries.map(\.loadedContent), ["alpha", "beta"])
        XCTAssertEqual(resolution.missingPaths, [])
        XCTAssertEqual(resolution.invalidPaths, [])
    }

    func testSelectedCodemapUsageDoesNotLoadContentWhenCodemapExists() async throws {
        let root = try makeTemporaryRoot(name: "AccountingSelectedCodemap")
        let fileURL = root.appendingPathComponent("A.swift")
        try write("struct A { func fullContent() {} }", to: fileURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(fullPath: fileURL.path, modificationDate: Date(), fileAPI: makeFileAPI(path: fileURL.path))
        ])
        let service = PromptContextAccountingService()
        let selection = StoredSelection(
            selectedPaths: [fileURL.path],
            autoCodemapPaths: [],
            slices: [:],
            codemapAutoEnabled: false
        )

        let resolution = await service.resolveEntries(selection: selection, store: store, codeMapUsage: .selected)

        let entry = try XCTUnwrap(resolution.entries.first)
        XCTAssertEqual(resolution.entries.count, 1)
        XCTAssertTrue(entry.isCodemap)
        XCTAssertEqual(entry.mode, .codemap)
        XCTAssertNil(entry.lineRanges)
        XCTAssertNil(entry.loadedContent)
        XCTAssertEqual(resolution.missingPaths, [])
        XCTAssertEqual(resolution.invalidPaths, [])
    }

    func testMissingSelectedPathsRemainMissingAndInvalidPathsRemainEmpty() async throws {
        let root = try makeTemporaryRoot(name: "AccountingMissing")
        try write("alpha", to: root.appendingPathComponent("A.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let service = PromptContextAccountingService()
        let missingPath = root.appendingPathComponent("Missing.swift").path
        let unresolvedRelativePath = "DefinitelyMissing.swift"
        let selection = StoredSelection(
            selectedPaths: [missingPath, unresolvedRelativePath],
            autoCodemapPaths: [],
            slices: [:],
            codemapAutoEnabled: false
        )

        let resolution = await service.resolveEntries(selection: selection, store: store, codeMapUsage: .none)

        XCTAssertEqual(resolution.entries, [])
        XCTAssertEqual(resolution.missingPaths, [unresolvedRelativePath, missingPath].sorted())
        XCTAssertEqual(resolution.invalidPaths, [])
    }

    func testExpandedSelectedFolderFilesRemainRelativePathOrderedWithContents() async throws {
        let root = try makeTemporaryRoot(name: "AccountingFolder")
        try write("b", to: root.appendingPathComponent("Sources/B.swift"))
        try write("a", to: root.appendingPathComponent("Sources/Nested/A.swift"))
        try write("notes", to: root.appendingPathComponent("Sources/notes.txt"))
        try write("outside", to: root.appendingPathComponent("Outside.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let expansion = await store.expandFolderInputToFiles("Sources", rootScope: .visibleWorkspace)
        XCTAssertTrue(expansion.handled)
        XCTAssertEqual(expansion.files.map(\.standardizedRelativePath), [
            "Sources/B.swift",
            "Sources/Nested/A.swift",
            "Sources/notes.txt"
        ])

        let service = PromptContextAccountingService()
        let selection = StoredSelection(
            selectedPaths: expansion.files.map(\.standardizedFullPath),
            autoCodemapPaths: [],
            slices: [:],
            codemapAutoEnabled: false
        )

        let resolution = await service.resolveEntries(selection: selection, store: store, codeMapUsage: .none)

        XCTAssertEqual(resolution.entries.map(\.file.standardizedRelativePath), [
            "Sources/B.swift",
            "Sources/Nested/A.swift",
            "Sources/notes.txt"
        ])
        XCTAssertEqual(resolution.entries.map(\.loadedContent), ["b", "a", "notes"])
        XCTAssertEqual(resolution.missingPaths, [])
        XCTAssertEqual(resolution.invalidPaths, [])
    }

    func testCompleteCodemapResolutionBuildsSingleStaticPathSnapshot() async throws {
        #if DEBUG
            let root = try makeTemporaryRoot(name: "AccountingCompleteCodemapBatch")
            let fileCount = 24
            var observed: [WorkspaceObservedCodemapResult] = []
            observed.reserveCapacity(fileCount)
            for index in 0 ..< fileCount {
                let fileURL = root.appendingPathComponent("File\(index).swift")
                try write("struct File\(index) {}", to: fileURL)
                observed.append(
                    WorkspaceObservedCodemapResult(
                        fullPath: fileURL.path,
                        modificationDate: Date(),
                        fileAPI: makeFileAPI(path: fileURL.path)
                    )
                )
            }

            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: root.path)
            await store.applyObservedCodemapResults(observed)
            let service = PromptContextAccountingService()
            let selection = StoredSelection(
                selectedPaths: [],
                autoCodemapPaths: [],
                slices: [:],
                codemapAutoEnabled: false
            )

            EditFlowPerf.resetDebugCaptureForTesting()
            defer { EditFlowPerf.resetDebugCaptureForTesting() }
            switch EditFlowPerf.beginDebugCapture(label: "complete-codemap-batch", maxSamples: 200) {
            case .started:
                break
            case .busy:
                XCTFail("Performance capture should start")
            }

            let resolution = await service.resolveEntries(
                selection: selection,
                store: store,
                codeMapUsage: .complete
            )
            let capture = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let snapshotBuildCount = capture.stages
                .filter { $0.stageName == String(describing: EditFlowPerf.Stage.ReadFile.pathLookupStaticSnapshotBuild) }
                .reduce(0) { $0 + $1.sampleCount }

            XCTAssertEqual(resolution.entries.count, fileCount)
            XCTAssertTrue(resolution.entries.allSatisfy { $0.mode == .codemap })
            XCTAssertEqual(snapshotBuildCount, 1)
            XCTAssertEqual(capture.droppedSampleCount, 0)
        #endif
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryRoots.append(url)
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeFileAPI(path: String) -> FileAPI {
        FileAPI(
            filePath: path,
            imports: [],
            classes: [],
            functions: [
                FunctionInfo(
                    name: "codemapOnlySymbol",
                    parameters: [],
                    returnType: nil,
                    definitionLine: "func codemapOnlySymbol()",
                    lineNumber: 1
                )
            ],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: []
        )
    }
}
