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

    func testStructuredResolutionReportsUnresolvedAndOmitsExcludedCandidates() async throws {
        let root = try makeTemporaryRoot(name: "GitDiffStructuredResolution")
        let selectedFile = root.appendingPathComponent("Sources/Selected.swift")
        let excludedFile = root.appendingPathComponent("_git_data/repos/repo/snapshot/diff/all.patch")
        try FileSystemTestSupport.write("let selected = true\n", to: selectedFile)
        try FileSystemTestSupport.write("diff\n", to: excludedFile)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let selection = StoredSelection(
            selectedPaths: [
                "Sources/Selected.swift",
                "Sources/Missing.swift",
                "_git_data/repos/repo/snapshot/diff/all.patch"
            ],
            codemapAutoEnabled: false
        )

        let resolution = await WorkspaceGitDiffSelectionResolver.resolveSelectedGitDiffPaths(
            for: selection,
            store: store,
            rootScope: .allLoaded,
            folderPolicy: .filesOnly,
            profile: .mcpSelection,
            allowFilesystemFallback: false,
            excluding: [excludedFile.path + "/../all.patch"]
        )

        XCTAssertEqual(resolution.paths, [selectedFile.standardizedFileURL.path])
        XCTAssertEqual(resolution.unresolvedCandidates, ["Sources/Missing.swift"])
    }

    func testStructuredFolderResolutionReportsOnlyUnhandledCandidates() async throws {
        let root = try makeTemporaryRoot(name: "GitDiffStructuredFolders")
        let excludedNestedFile = root.appendingPathComponent("Sources/Nested/One.swift")
        let includedNestedFile = root.appendingPathComponent("Sources/Nested/Two.swift")
        try FileSystemTestSupport.write("let one = true\n", to: excludedNestedFile)
        try FileSystemTestSupport.write("let two = true\n", to: includedNestedFile)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let selection = StoredSelection(
            selectedPaths: ["Sources", "MissingFolder"],
            codemapAutoEnabled: false
        )

        let resolution = await WorkspaceGitDiffSelectionResolver.resolveSelectedGitDiffPaths(
            for: selection,
            store: store,
            rootScope: .allLoaded,
            folderPolicy: .expandFolders,
            profile: .uiAssisted,
            allowFilesystemFallback: true,
            excluding: [excludedNestedFile.path]
        )

        XCTAssertEqual(resolution.paths, [includedNestedFile.standardizedFileURL.path])
        XCTAssertEqual(resolution.unresolvedCandidates, ["MissingFolder"])
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

    func testPrimaryGitArtifactsAutoSelectFromGitDataRoot() throws {
        let visibleRoot = try makeTemporaryRoot(name: "GitArtifactSelectionVisible")
        let gitDataRoot = try makeTemporaryRoot(name: "GitArtifactSelectionData")
        let visibleFile = visibleRoot.appendingPathComponent("Visible.swift")
        let mapFile = gitDataRoot.appendingPathComponent("repos/repo/snapshot/MAP.txt")
        let patchFile = gitDataRoot.appendingPathComponent("repos/repo/snapshot/diff/all.patch")
        try FileSystemTestSupport.write("visible\n", to: visibleFile)
        try FileSystemTestSupport.write("map\n", to: mapFile)
        try FileSystemTestSupport.write("patch\n", to: patchFile)

        let visiblePath = visibleFile.standardizedFileURL.path
        let mapPath = mapFile.standardizedFileURL.path
        let patchPath = patchFile.standardizedFileURL.path
        let existing = StoredSelection(
            selectedPaths: [visiblePath],

            slices: [visiblePath: [LineRange(start: 2, end: 4)]],
            codemapAutoEnabled: false
        )
        let candidates = [
            GitDiffPublishedArtifact(
                kind: .map,
                absolutePath: mapPath,
                gitDataRelativePath: "repos/repo/snapshot/MAP.txt",
                clientAlias: "_git_data/repos/repo/snapshot/MAP.txt",
                selectionDisposition: .primaryAutoSelect
            ),
            GitDiffPublishedArtifact(
                kind: .allPatch,
                absolutePath: patchPath,
                gitDataRelativePath: "repos/repo/snapshot/diff/all.patch",
                clientAlias: "_git_data/repos/repo/snapshot/diff/all.patch",
                selectionDisposition: .primaryAutoSelect
            )
        ]

        let result = WorkspaceGitDiffArtifactSelectionService().mergePrimaryArtifacts(
            existing: existing,
            candidates: candidates + [candidates[0]]
        )

        XCTAssertEqual(result.selection.selectedPaths, [visiblePath, mapPath, patchPath])
        XCTAssertEqual(result.selection.slices, existing.slices)
        XCTAssertFalse(result.selection.codemapAutoEnabled)
        XCTAssertEqual(result.newlyAddedArtifacts, candidates)
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        try temporaryRoots.makeRoot(suiteName: name)
    }
}
