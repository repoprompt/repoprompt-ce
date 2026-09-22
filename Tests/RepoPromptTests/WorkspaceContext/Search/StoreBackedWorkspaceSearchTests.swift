import CoreServices
@testable import RepoPromptApp
import XCTest

final class StoreBackedWorkspaceSearchTests: XCTestCase {
    func testExactAbsoluteScopeHelperQualifiesTrimmedAndTildePathsButRejectsRelativeAliasAndNULInputs() async throws {
        let root = try makeTemporaryRoot(name: "ExactAbsoluteQualification")
        let fileURL = root.appendingPathComponent("Sources/Visible.swift")
        try write("visible", to: fileURL)

        let homeRoot = try makeHomeTemporaryRoot(name: "TildeQualification")
        let homeFileURL = homeRoot.appendingPathComponent("Sources/HomeVisible.swift")
        try write("home", to: homeFileURL)

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        _ = try await store.loadRoot(path: homeRoot.path)

        let trimmed = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(
            "  \(fileURL.path)\n",
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(trimmed?.file?.standardizedFullPath, fileURL.path)

        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let tildePath = "~/" + String(homeFileURL.path.dropFirst(homePath.count + 1))
        let tilde = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(
            tildePath,
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(tilde?.file?.standardizedFullPath, homeFileURL.path)

        let relative = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(
            "Sources/Visible.swift",
            rootScope: .visibleWorkspace
        )
        let alias = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(
            "\(record.name)/Sources/Visible.swift",
            rootScope: .visibleWorkspace
        )
        let nul = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(
            "/tmp/blocked\0.swift",
            rootScope: .visibleWorkspace
        )
        XCTAssertNil(relative)
        XCTAssertNil(alias)
        XCTAssertNil(nul)
    }

    func testExactAbsoluteScopeHelperReturnsDeepestDiscoverableFileFolderAndRootFolder() async throws {
        let parent = try makeTemporaryRoot(name: "NestedParent")
        let nested = parent.appendingPathComponent("NestedRoot", isDirectory: true)
        let folderURL = nested.appendingPathComponent("Sources/Nested", isDirectory: true)
        let fileURL = folderURL.appendingPathComponent("Visible.swift")
        try write("visible", to: fileURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: parent.path)
        let nestedRecord = try await store.loadRoot(path: nested.path)

        let file = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(
            fileURL.path,
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(file?.file?.rootID, nestedRecord.id)
        XCTAssertEqual(file?.file?.standardizedFullPath, fileURL.path)

        let folder = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(
            folderURL.path,
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(folder?.folder?.rootID, nestedRecord.id)
        XCTAssertEqual(folder?.folder?.standardizedRelativePath, "Sources/Nested")

        let rootFolder = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(
            nested.path,
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(rootFolder?.folder?.rootID, nestedRecord.id)
        XCTAssertEqual(rootFolder?.folder?.standardizedRelativePath, "")
    }

    func testExactAbsoluteScopeHelperExcludesManagedOnlyIgnoredFiles() async throws {
        let root = try makeTemporaryRoot(name: "IgnoredDiscoverability")
        try write("*.ignored\n", to: root.appendingPathComponent(".gitignore"))
        let ignoredURL = root.appendingPathComponent("Hidden.ignored")
        try write("hidden", to: ignoredURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let readableService = WorkspaceReadableFileService(store: store)
        let readable = try await readableService.resolveReadableFile(
            ignoredURL.path,
            rootScope: .visibleWorkspace
        )
        guard case .workspace = readable else {
            return XCTFail("Expected ignored absolute read fallback to materialize a managed-only record")
        }

        let searchHit = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(
            ignoredURL.path,
            rootScope: .visibleWorkspace
        )
        XCTAssertNil(searchHit)
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertFalse(snapshot.files.contains { $0.standardizedFullPath == ignoredURL.path })
    }

    func testExactAbsoluteScopeHelperHonorsVisibleGitDataAndSessionBoundScopes() async throws {
        let logicalRoot = try makeTemporaryRoot(name: "LogicalRoot")
        let gitDataRoot = try makeTemporaryRoot(name: "GitDataRoot")
        let worktreeRoot = try makeTemporaryRoot(name: "WorktreeRoot")
        let logicalFile = logicalRoot.appendingPathComponent("Logical.swift")
        let gitDataFile = gitDataRoot.appendingPathComponent("GitData.swift")
        let worktreeFile = worktreeRoot.appendingPathComponent("Worktree.swift")
        try write("logical", to: logicalFile)
        try write("git data", to: gitDataFile)
        try write("worktree", to: worktreeFile)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: logicalRoot.path)
        let gitDataRecord = try await store.loadRoot(path: gitDataRoot.path, kind: .workspaceGitData)
        let worktreeRecord = try await store.loadRoot(path: worktreeRoot.path, kind: .sessionWorktree)

        let visibleGitDataHit = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(
            gitDataFile.path,
            rootScope: .visibleWorkspace
        )
        XCTAssertNil(visibleGitDataHit)
        let gitDataHit = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(
            gitDataFile.path,
            rootScope: .visibleWorkspacePlusGitData
        )
        XCTAssertEqual(gitDataHit?.file?.rootID, gitDataRecord.id)

        let visibleWorktreeHit = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(
            worktreeFile.path,
            rootScope: .visibleWorkspace
        )
        XCTAssertNil(visibleWorktreeHit)
        let sessionScope = WorkspaceLookupRootScope.sessionBoundWorkspace(
            canonicalRootPaths: [],
            physicalRootPaths: [worktreeRoot.path]
        )
        let worktreeHit = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(
            worktreeFile.path,
            rootScope: sessionScope
        )
        XCTAssertEqual(worktreeHit?.file?.rootID, worktreeRecord.id)
        let sessionLogicalHit = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(
            logicalFile.path,
            rootScope: sessionScope
        )
        XCTAssertNil(sessionLogicalHit)
    }

    func testStoreBackedSearchAbsoluteFolderAndFileScopesReportScopedCounts() async throws {
        let root = try makeTemporaryRoot(name: "FacadeExactScopes")
        let nestedFolder = root.appendingPathComponent("Sources/Nested", isDirectory: true)
        let nestedA = nestedFolder.appendingPathComponent("A.swift")
        let nestedB = nestedFolder.appendingPathComponent("B.swift")
        let outside = root.appendingPathComponent("Sources/Outside.swift")
        try write("a", to: nestedA)
        try write("b", to: nestedB)
        try write("outside", to: outside)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)

        let folderResult = try await searchSwiftFiles(paths: [nestedFolder.path], store: store)
        XCTAssertEqual(folderResult.scopedFileCount, 2)
        XCTAssertEqual(Set(folderResult.paths ?? []), Set([nestedA.path, nestedB.path]))

        let fileResult = try await searchSwiftFiles(paths: [nestedA.path], store: store)
        XCTAssertEqual(fileResult.scopedFileCount, 1)
        XCTAssertEqual(fileResult.paths, [nestedA.path])
    }

    func testStoreBackedSearchPreservesRelativeAliasAbsoluteMissAndWildcardFallbacks() async throws {
        let rootA = try makeTemporaryRoot(name: "FallbackAlpha")
        let rootB = try makeTemporaryRoot(name: "FallbackBeta")
        let relativeFile = rootA.appendingPathComponent("Sources/RelativeOnly.swift")
        let absoluteMissingPath = rootA.appendingPathComponent("Sources/Missing").path
        let wildcardFile = rootB.appendingPathComponent("Sources/WildcardOnly.swift")
        try write("relative", to: relativeFile)
        try write("wildcard", to: wildcardFile)

        let store = WorkspaceFileContextStore()
        let recordA = try await store.loadRoot(path: rootA.path)
        _ = try await store.loadRoot(path: rootB.path)

        let relative = try await searchSwiftFiles(paths: ["Sources/RelativeOnly.swift"], store: store)
        XCTAssertEqual(relative.paths, [relativeFile.path])

        let alias = try await searchSwiftFiles(
            paths: ["\(recordA.name)/Sources/RelativeOnly.swift"],
            store: store
        )
        XCTAssertEqual(alias.paths, [relativeFile.path])

        let shortcutMiss = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(
            absoluteMissingPath,
            rootScope: .visibleWorkspace
        )
        XCTAssertNil(shortcutMiss)
        let absoluteMiss = try await searchSwiftFiles(paths: [absoluteMissingPath], store: store)
        XCTAssertEqual(absoluteMiss.scopedFileCount, 0)
        XCTAssertNil(absoluteMiss.paths)

        let wildcard = try await searchSwiftFiles(paths: ["*/Sources/WildcardOnly.swift"], store: store)
        XCTAssertEqual(wildcard.paths, [wildcardFile.path])
    }

    func testBroadSearchAdmissionClassifierGatesOnlyUnscopedContentCapableModes() {
        XCTAssertEqual(
            StoreBackedWorkspaceSearch.broadSearchAdmissionClass(
                pattern: "needle",
                mode: .content,
                paths: nil
            ),
            .unscopedContent
        )
        XCTAssertEqual(
            StoreBackedWorkspaceSearch.broadSearchAdmissionClass(
                pattern: "needle",
                mode: .both,
                paths: []
            ),
            .unscopedBoth
        )
        XCTAssertEqual(
            StoreBackedWorkspaceSearch.broadSearchAdmissionClass(
                pattern: "needle",
                mode: .auto,
                paths: ["  ", "\n"]
            ),
            .unscopedBoth
        )
        XCTAssertTrue(
            StoreBackedWorkspaceSearch.requiresBroadSearchAdmission(
                pattern: "needle",
                mode: .content,
                paths: nil
            )
        )
        XCTAssertFalse(
            StoreBackedWorkspaceSearch.requiresBroadSearchAdmission(
                pattern: "*.swift",
                mode: .path,
                paths: nil
            )
        )
        XCTAssertFalse(
            StoreBackedWorkspaceSearch.requiresBroadSearchAdmission(
                pattern: "*.swift",
                mode: .auto,
                paths: nil
            )
        )
        XCTAssertFalse(
            StoreBackedWorkspaceSearch.requiresBroadSearchAdmission(
                pattern: "needle",
                mode: .content,
                paths: ["Sources/A.swift"]
            )
        )
    }

    private func searchSwiftFiles(
        paths: [String],
        store: WorkspaceFileContextStore
    ) async throws -> SearchResults {
        try await StoreBackedWorkspaceSearch.search(
            pattern: "*.swift",
            mode: .path,
            isRegex: false,
            caseInsensitive: true,
            maxPaths: 100,
            paths: paths,
            rootScope: .visibleWorkspace,
            store: store,
            workspaceManager: nil
        )
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        try makeTestDirectory(name: name)
    }

    private func makeHomeTemporaryRoot(name: String) throws -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".RepoPromptTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
