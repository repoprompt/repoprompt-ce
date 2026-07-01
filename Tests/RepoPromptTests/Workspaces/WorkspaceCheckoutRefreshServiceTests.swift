@testable import RepoPrompt
import XCTest

final class WorkspaceCheckoutRefreshServiceTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryRoots {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testRefreshAfterCheckoutMutationFencesCodemapAuthorityWithoutRescan() async throws {
        let root = try makeTemporaryRoot(name: "CheckoutRefreshCodemap")
        let file = root.appendingPathComponent("Sources/App.swift")
        try write("func branchBSymbol() {}\n", to: file)

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let service = WorkspaceCheckoutRefreshService(store: store, searchService: WorkspaceSearchService())
        let result = await service.refreshAfterCheckoutMutation(rootPath: root.path)
        await Task.yield()

        let operations = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertTrue(result.didRefreshLoadedRoot)
        XCTAssertEqual(result.refreshedRootIDs, [record.id])
        XCTAssertEqual(operations.artifactDemandRequests, 0)
        XCTAssertEqual(operations.presentationFreezeRequests, 0)
    }

    func testRefreshAfterCheckoutMutationRebuildsVisibleSearchIndexFromFreshCatalogSnapshot() async throws {
        let root = try makeTemporaryRoot(name: "CheckoutRefreshSearch")
        try write("let seed = true\n", to: root.appendingPathComponent("Seed.swift"))

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let searchService = WorkspaceSearchService()
        let initialSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        await searchService.rebuildIndex(from: initialSnapshot)

        try write("let branchOnly = true\n", to: root.appendingPathComponent("Sources/BranchOnly.swift"))
        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.fileAdded("Sources/BranchOnly.swift")])

        let service = WorkspaceCheckoutRefreshService(store: store, searchService: searchService)
        let result = await service.refreshAfterCheckoutMutation(rootPath: root.path)
        let expectedGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        let searchResult = await searchService.search("BranchOnly", limit: 10)

        XCTAssertEqual(result.searchIndexedGeneration, expectedGeneration)
        XCTAssertEqual(result.searchIndexRefreshBehavior, .rebuiltSharedVisibleWorkspace)
        XCTAssertNotNil(result.pathLookupGeneration)
        XCTAssertFalse(searchResult.isStale)
        XCTAssertEqual(searchResult.indexedGeneration, expectedGeneration)
        XCTAssertEqual(searchResult.results.map(\.standardizedRelativePath), ["Sources/BranchOnly.swift"])
    }

    func testRefreshAfterCheckoutMutationReconcilesDiskChangesBeforeWarmingIndexes() async throws {
        let root = try makeTemporaryRoot(name: "CheckoutRefreshDiskReconcile")
        let seed = root.appendingPathComponent("Sources/Seed.swift")
        let branchOnly = root.appendingPathComponent("Sources/BranchOnly.swift")
        try write("let seed = true\n", to: seed)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let searchService = WorkspaceSearchService()
        let initialSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        await searchService.rebuildIndex(from: initialSnapshot)

        try FileManager.default.removeItem(at: seed)
        try write("let branchOnly = true\n", to: branchOnly)

        let service = WorkspaceCheckoutRefreshService(store: store, searchService: searchService)
        let result = await service.refreshAfterCheckoutMutation(rootPath: root.path)
        let expectedGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        let branchLookup = await store.lookupPath("Sources/BranchOnly.swift", profile: .uiAssisted, rootScope: .visibleWorkspace)
        let seedLookup = await store.lookupPath("Sources/Seed.swift", profile: .uiAssisted, rootScope: .visibleWorkspace)
        let searchResult = await searchService.search("BranchOnly", limit: 10)

        XCTAssertEqual(result.searchIndexRefreshBehavior, .rebuiltSharedVisibleWorkspace)
        XCTAssertEqual(result.searchIndexedGeneration, expectedGeneration)
        XCTAssertNotNil(result.pathLookupGeneration)
        XCTAssertNotNil(branchLookup?.file)
        XCTAssertNil(seedLookup?.file)
        XCTAssertFalse(searchResult.isStale)
        XCTAssertEqual(searchResult.indexedGeneration, expectedGeneration)
        XCTAssertEqual(searchResult.results.map(\.standardizedRelativePath), ["Sources/BranchOnly.swift"])
    }

    func testRefreshAfterCheckoutMutationDoesNotOverwriteVisibleSearchIndexForSessionWorktreeRoot() async throws {
        let visibleRoot = try makeTemporaryRoot(name: "CheckoutRefreshVisibleRoot")
        let worktreeRoot = try makeTemporaryRoot(name: "CheckoutRefreshSessionWorktree")
        try write("let baseOnly = true\n", to: visibleRoot.appendingPathComponent("Sources/BaseOnly.swift"))
        try write("let branchOnly = true\n", to: worktreeRoot.appendingPathComponent("Sources/BranchOnly.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: visibleRoot.path)
        _ = try await store.loadRoot(path: worktreeRoot.path, kind: .sessionWorktree)
        let searchService = WorkspaceSearchService()
        let initialVisibleSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let initialVisibleGeneration = await searchService.rebuildIndex(from: initialVisibleSnapshot)

        let service = WorkspaceCheckoutRefreshService(store: store, searchService: searchService)
        let result = await service.refreshAfterCheckoutMutation(rootPath: worktreeRoot.path)
        let baseSearch = await searchService.search("BaseOnly", limit: 10)
        let branchSearch = await searchService.search("BranchOnly", limit: 10)

        XCTAssertEqual(result.searchIndexRefreshBehavior, .skippedSharedVisibleWorkspaceForSessionWorktree)
        XCTAssertNil(result.searchIndexedGeneration)
        XCTAssertEqual(baseSearch.indexedGeneration, initialVisibleGeneration)
        XCTAssertEqual(baseSearch.results.map(\.standardizedRelativePath), ["Sources/BaseOnly.swift"])
        XCTAssertEqual(branchSearch.indexedGeneration, initialVisibleGeneration)
        XCTAssertTrue(branchSearch.results.isEmpty)
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
}
