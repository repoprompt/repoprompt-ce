@testable import RepoPrompt
import XCTest

final class WorkspaceGitDiffSelectionResolverTests: XCTestCase {
    private var temporaryRoots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testCandidatesIncludeSelectedPathsAndNonEmptySlicesOnce() {
        let selection = StoredSelection(
            selectedPaths: ["Sources/App.swift", "Sources/App.swift", "Sources/Other.swift"],
            autoCodemapPaths: ["Sources/CodemapOnly.swift"],
            slices: [
                "Sources/App.swift": [LineRange(start: 1, end: 2)],
                "Sources/Sliced.swift": [LineRange(start: 3, end: 4)],
                "Sources/EmptySlice.swift": []
            ],
            codemapAutoEnabled: false
        )

        let candidates = WorkspaceGitDiffSelectionResolver.candidates(from: selection)

        XCTAssertEqual(candidates, ["Sources/App.swift", "Sources/Other.swift", "Sources/Sliced.swift"])
    }

    func testFilesOnlyPolicyPreservesAgentAndMCPFolderBehavior() async throws {
        let root = try makeTemporaryRoot(name: "GitDiffFilesOnly")
        try FileSystemTestSupport.write("let one = true\n", to: root.appendingPathComponent("Sources/One.swift"))
        try FileSystemTestSupport.write("let two = true\n", to: root.appendingPathComponent("Sources/Two.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let selection = StoredSelection(selectedPaths: ["Sources"], codemapAutoEnabled: false)

        let paths = await WorkspaceGitDiffSelectionResolver.selectedGitDiffPaths(
            for: selection,
            store: store,
            rootScope: .allLoaded,
            folderPolicy: .filesOnly,
            profile: .mcpSelection,
            allowFilesystemFallback: WorkspaceLookupRootScope.allLoaded.allowsSelectedGitDiffFilesystemFallback
        )

        XCTAssertEqual(paths, [])
    }

    func testExpandFoldersPolicyPreservesPromptAndHeadlessFolderBehavior() async throws {
        let root = try makeTemporaryRoot(name: "GitDiffExpandFolders")
        try FileSystemTestSupport.write("let one = true\n", to: root.appendingPathComponent("Sources/One.swift"))
        try FileSystemTestSupport.write("let two = true\n", to: root.appendingPathComponent("Sources/Nested/Two.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let selection = StoredSelection(selectedPaths: [root.appendingPathComponent("Sources").path], codemapAutoEnabled: false)

        let paths = await WorkspaceGitDiffSelectionResolver.selectedGitDiffPaths(
            for: selection,
            store: store,
            rootScope: .allLoaded,
            folderPolicy: .expandFolders,
            profile: .uiAssisted,
            allowFilesystemFallback: WorkspaceLookupRootScope.allLoaded.allowsSelectedGitDiffFilesystemFallback
        )

        let expected = Set([
            root.appendingPathComponent("Sources/One.swift").standardizedFileURL.path,
            root.appendingPathComponent("Sources/Nested/Two.swift").standardizedFileURL.path
        ])
        XCTAssertEqual(Set(paths), expected)
        XCTAssertEqual(paths.count, expected.count)
    }

    func testFilesOnlyPolicyKeepsExistingAbsoluteFallback() async throws {
        let root = try makeTemporaryRoot(name: "GitDiffAbsoluteFallback")
        let outsideFile = try makeTemporaryRoot(name: "GitDiffOutside")
            .appendingPathComponent("Outside.swift")
        try FileSystemTestSupport.write("let outside = true\n", to: outsideFile)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let selection = StoredSelection(selectedPaths: [outsideFile.path], codemapAutoEnabled: false)

        let paths = await WorkspaceGitDiffSelectionResolver.selectedGitDiffPaths(
            for: selection,
            store: store,
            rootScope: .allLoaded,
            folderPolicy: .filesOnly,
            profile: .mcpSelection,
            allowFilesystemFallback: WorkspaceLookupRootScope.allLoaded.allowsSelectedGitDiffFilesystemFallback
        )

        XCTAssertEqual(paths, [outsideFile.standardizedFileURL.path])
    }

    func testFilesOnlyPolicyDoesNotFilesystemFallbackForFailClosedSessionBoundScope() async throws {
        let logicalRoot = try makeTemporaryRoot(name: "GitDiffFailClosedLogical")
        try FileSystemTestSupport.write("let origin = \"base\"\n", to: logicalRoot.appendingPathComponent("Sources/App.swift"))

        let store = WorkspaceFileContextStore()
        let loadedLogicalRoot = try await store.loadRoot(path: logicalRoot.path)
        let logicalRef = WorkspaceRootRef(
            id: loadedLogicalRoot.id,
            name: loadedLogicalRoot.name,
            fullPath: loadedLogicalRoot.standardizedFullPath
        )
        // Reusing the already-loaded logical root as the physical worktree path makes
        // materialization fail closed: the file exists on disk, but it is not a loaded
        // `.sessionWorktree` root and must not be admitted by raw filesystem fallback.
        let physicalRef = WorkspaceRootRef(id: UUID(), name: logicalRef.name, fullPath: logicalRoot.path)
        let binding = AgentSessionWorktreeBinding(
            id: "binding-fail-closed",
            repositoryID: "repo-fail-closed",
            repoKey: "repo-key",
            logicalRootPath: logicalRef.fullPath,
            logicalRootName: logicalRef.name,
            worktreeID: "worktree-fail-closed",
            worktreeRootPath: physicalRef.fullPath,
            worktreeName: physicalRef.name,
            source: "test"
        )
        let materializedProjection = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
            sessionID: UUID(),
            bindings: [binding]
        )
        let projection = try XCTUnwrap(materializedProjection)
        let lookupContext = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        let physicalSelection = lookupContext.physicalizeSelection(StoredSelection(
            selectedPaths: ["Sources/App.swift"],
            codemapAutoEnabled: false
        ))
        let physicalPath = try XCTUnwrap(physicalSelection.selectedPaths.first)

        let paths = await WorkspaceGitDiffSelectionResolver.selectedGitDiffPaths(
            for: physicalSelection,
            store: store,
            rootScope: lookupContext.rootScope,
            folderPolicy: .filesOnly,
            profile: .mcpSelection,
            allowFilesystemFallback: lookupContext.rootScope.allowsSelectedGitDiffFilesystemFallback
        )

        XCTAssertEqual(physicalPath, logicalRoot.appendingPathComponent("Sources/App.swift").standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: physicalPath))
        XCTAssertEqual(paths, [])
    }

    func testPrimaryGitArtifactsAutoSelectFromGitDataRoot() async throws {
        let visibleRoot = try makeTemporaryRoot(name: "GitArtifactSelectionVisible")
        let gitDataRoot = try makeTemporaryRoot(name: "GitArtifactSelectionData")
        let visibleFile = visibleRoot.appendingPathComponent("Visible.swift")
        let mapFile = gitDataRoot.appendingPathComponent("repos/repo/snapshot/MAP.txt")
        let patchFile = gitDataRoot.appendingPathComponent("repos/repo/snapshot/diff/all.patch")
        try FileSystemTestSupport.write("visible\n", to: visibleFile)
        try FileSystemTestSupport.write("map\n", to: mapFile)
        try FileSystemTestSupport.write("patch\n", to: patchFile)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: visibleRoot.path)
        _ = try await store.loadRoot(path: gitDataRoot.path, kind: .workspaceGitData)
        let existing = StoredSelection(selectedPaths: [visibleFile.path], codemapAutoEnabled: false)

        let result = await WorkspaceGitDiffArtifactSelectionService(store: store).addPrimaryArtifacts(
            existing: existing,
            paths: [mapFile.path, patchFile.path]
        )

        XCTAssertEqual(
            Set(result.selection.selectedPaths),
            Set([visibleFile.standardizedFileURL.path, mapFile.standardizedFileURL.path, patchFile.standardizedFileURL.path])
        )
        XCTAssertEqual(result.autoSelectedPaths, [mapFile.path, patchFile.path])
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        try temporaryRoots.makeRoot(suiteName: name)
    }
}
