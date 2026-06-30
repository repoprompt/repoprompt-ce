@testable import RepoPrompt
import XCTest

final class WorkspaceSearchServiceTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryRoots {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testSearchCatalogGenerationChangesOnRootLoadDeltaAndUnload() async throws {
        let root = try makeTemporaryRoot(name: "CatalogGeneration")
        try write("alpha", to: root.appendingPathComponent("A.swift"))

        let store = WorkspaceFileContextStore()
        let initialGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)

        let record = try await store.loadRoot(path: root.path)
        let loadedSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertNotEqual(loadedSnapshot.generation, initialGeneration)
        XCTAssertEqual(loadedSnapshot.diagnostics.rootCount, 1)
        XCTAssertEqual(loadedSnapshot.diagnostics.fileCount, 1)
        XCTAssertEqual(loadedSnapshot.entries.map(\.standardizedRelativePath), ["A.swift"])

        let supplementalRoot = try makeTemporaryRoot(name: "SupplementalCatalogGeneration")
        try write("system", to: supplementalRoot.appendingPathComponent("SystemOnly.swift"))
        let allLoadedBeforeSupplemental = await store.catalogGeneration(rootScope: .allLoaded)
        _ = try await store.loadRoot(path: supplementalRoot.path, kind: .supplementalSystem)
        let visibleAfterSupplemental = await store.catalogGeneration(rootScope: .visibleWorkspace)
        let allLoadedAfterSupplemental = await store.catalogGeneration(rootScope: .allLoaded)
        XCTAssertEqual(visibleAfterSupplemental, loadedSnapshot.generation)
        XCTAssertNotEqual(allLoadedAfterSupplemental, allLoadedBeforeSupplemental)

        try write("beta", to: root.appendingPathComponent("Sources/B.swift"))
        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.fileAdded("Sources/B.swift")])
        let deltaSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertNotEqual(deltaSnapshot.generation, loadedSnapshot.generation)
        XCTAssertEqual(Set(deltaSnapshot.entries.map(\.standardizedRelativePath)), ["A.swift", "Sources/B.swift"])
        XCTAssertEqual(deltaSnapshot.diagnostics.fileCount, 2)

        await store.unloadRoot(id: record.id)
        let unloadedSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertNotEqual(unloadedSnapshot.generation, deltaSnapshot.generation)
        XCTAssertEqual(unloadedSnapshot.diagnostics.rootCount, 0)
        XCTAssertEqual(unloadedSnapshot.diagnostics.fileCount, 0)
        XCTAssertTrue(unloadedSnapshot.entries.isEmpty)
    }

    func testWorkspaceSearchServiceSearchesSingleRootCatalog() async throws {
        let root = try makeTemporaryRoot(name: "SingleRootSearch")
        try write("view model", to: root.appendingPathComponent("Sources/App/Search/SearchViewModel.swift"))
        try write("tests", to: root.appendingPathComponent("Tests/SearchViewModelTests.swift"))
        try write("readme", to: root.appendingPathComponent("README.md"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)

        let service = WorkspaceSearchService()
        let indexedGeneration = await service.rebuildIndex(from: snapshot)
        let serviceIndexedGeneration = await service.indexedGeneration
        let indexedPathCount = await service.indexedPathCount
        XCTAssertEqual(indexedGeneration, snapshot.generation)
        XCTAssertEqual(serviceIndexedGeneration, snapshot.generation)
        XCTAssertEqual(indexedPathCount, 3)

        let filenameResult = await service.search("SearchViewModel", limit: 10)
        XCTAssertTrue(filenameResult.isIndexReady)
        XCTAssertEqual(filenameResult.indexedGeneration, snapshot.generation)
        XCTAssertEqual(Set(filenameResult.results.map(\.standardizedRelativePath)), [
            "Sources/App/Search/SearchViewModel.swift",
            "Tests/SearchViewModelTests.swift"
        ])

        let subpathResult = await service.search("App SearchViewModel", limit: 10)
        XCTAssertEqual(subpathResult.results.map(\.standardizedRelativePath), ["Sources/App/Search/SearchViewModel.swift"])
    }

    func testWorkspaceSearchServiceSearchesMultiRootCatalog() async throws {
        let rootA = try makeTemporaryRoot(name: "AlphaRootSearch")
        let rootB = try makeTemporaryRoot(name: "BetaRootSearch")
        try write("alpha", to: rootA.appendingPathComponent("Sources/AlphaTarget.swift"))
        try write("shared alpha", to: rootA.appendingPathComponent("Shared/SharedTarget.swift"))
        try write("beta", to: rootB.appendingPathComponent("Sources/BetaTarget.swift"))
        try write("shared beta", to: rootB.appendingPathComponent("Shared/SharedTarget.swift"))

        let store = WorkspaceFileContextStore()
        let recordA = try await store.loadRoot(path: rootA.path)
        let recordB = try await store.loadRoot(path: rootB.path)
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertEqual(snapshot.diagnostics.rootCount, 2)
        XCTAssertEqual(snapshot.diagnostics.fileCount, 4)

        let service = WorkspaceSearchService()
        await service.prepareIndex(from: snapshot)

        let sharedResult = await service.search("SharedTarget", limit: 10)
        XCTAssertEqual(Set(sharedResult.results.map(\.rootID)), [recordA.id, recordB.id])
        XCTAssertEqual(sharedResult.results.count(where: { $0.standardizedRelativePath == "Shared/SharedTarget.swift" }), 2)

        let rootQualifiedResult = await service.search("\(rootB.lastPathComponent) BetaTarget", limit: 10)
        XCTAssertEqual(rootQualifiedResult.results.map(\.rootID), [recordB.id])
        XCTAssertEqual(rootQualifiedResult.results.map(\.standardizedRelativePath), ["Sources/BetaTarget.swift"])
    }

    func testWorkspaceSearchServiceRefreshesAfterFileAdd() async throws {
        let root = try makeTemporaryRoot(name: "LiveAddSearch")
        try write("alpha", to: root.appendingPathComponent("A.swift"))

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let service = WorkspaceSearchService()
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        await service.rebuildIndex(from: snapshot)
        await service.startKeepingFresh(with: store, debounceNanoseconds: 0)

        try write("beta", to: root.appendingPathComponent("Sources/BetaAdded.swift"))
        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.fileAdded("Sources/BetaAdded.swift")])
        let expectedGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        try await waitForIndexedGeneration(expectedGeneration, service: service)

        let result = await service.search("BetaAdded", limit: 10)
        XCTAssertFalse(result.isStale)
        XCTAssertEqual(result.indexedGeneration, expectedGeneration)
        XCTAssertEqual(result.results.map(\.standardizedRelativePath), ["Sources/BetaAdded.swift"])
    }

    func testWorkspaceSearchServiceRefreshesAfterFileRemove() async throws {
        let root = try makeTemporaryRoot(name: "LiveRemoveSearch")
        try write("alpha", to: root.appendingPathComponent("Keep.swift"))
        try write("remove", to: root.appendingPathComponent("RemoveMe.swift"))

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let service = WorkspaceSearchService()
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        await service.rebuildIndex(from: snapshot)
        await service.startKeepingFresh(with: store, debounceNanoseconds: 0)

        try FileManager.default.removeItem(at: root.appendingPathComponent("RemoveMe.swift"))
        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.fileRemoved("RemoveMe.swift")])
        let expectedGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        try await waitForIndexedGeneration(expectedGeneration, service: service)

        let removedResult = await service.search("RemoveMe", limit: 10)
        XCTAssertTrue(removedResult.results.isEmpty)
        let keepResult = await service.search("Keep", limit: 10)
        XCTAssertEqual(keepResult.results.map(\.standardizedRelativePath), ["Keep.swift"])
    }

    func testWorkspaceSearchServiceRefreshesAfterFolderRemove() async throws {
        let root = try makeTemporaryRoot(name: "LiveFolderRemoveSearch")
        try write("keep", to: root.appendingPathComponent("Keep.swift"))
        try write("gone", to: root.appendingPathComponent("Gone/NestedTarget.swift"))

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let service = WorkspaceSearchService()
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        await service.rebuildIndex(from: snapshot)
        await service.startKeepingFresh(with: store, debounceNanoseconds: 0)

        try FileManager.default.removeItem(at: root.appendingPathComponent("Gone"))
        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.folderRemoved("Gone")])
        let expectedGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        try await waitForIndexedGeneration(expectedGeneration, service: service)

        let removedResult = await service.search("NestedTarget", limit: 10)
        XCTAssertTrue(removedResult.results.isEmpty)
        let keepResult = await service.search("Keep", limit: 10)
        XCTAssertEqual(keepResult.results.map(\.standardizedRelativePath), ["Keep.swift"])
    }

    func testWorkspaceSearchServiceInvalidatesAfterRootUnload() async throws {
        let rootA = try makeTemporaryRoot(name: "LiveRootUnloadA")
        let rootB = try makeTemporaryRoot(name: "LiveRootUnloadB")
        try write("unload", to: rootA.appendingPathComponent("UnloadedTarget.swift"))
        try write("keep", to: rootB.appendingPathComponent("KeptTarget.swift"))

        let store = WorkspaceFileContextStore()
        let recordA = try await store.loadRoot(path: rootA.path)
        let recordB = try await store.loadRoot(path: rootB.path)
        let service = WorkspaceSearchService()
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        await service.rebuildIndex(from: snapshot)
        await service.startKeepingFresh(with: store, debounceNanoseconds: 0)

        await store.unloadRoot(id: recordA.id)
        let expectedGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        try await waitForIndexedGeneration(expectedGeneration, service: service)

        let unloadedResult = await service.search("UnloadedTarget", limit: 10)
        XCTAssertTrue(unloadedResult.results.isEmpty)
        let keptResult = await service.search("KeptTarget", limit: 10)
        XCTAssertEqual(keptResult.results.map(\.rootID), [recordB.id])
        XCTAssertEqual(keptResult.results.map(\.standardizedRelativePath), ["KeptTarget.swift"])
    }

    func testWorkspaceSearchServiceDeduplicatesDuplicateDeltas() async throws {
        let root = try makeTemporaryRoot(name: "LiveDuplicateDeltasSearch")
        try write("seed", to: root.appendingPathComponent("Seed.swift"))

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let service = WorkspaceSearchService()
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        await service.rebuildIndex(from: snapshot)
        await service.startKeepingFresh(with: store, debounceNanoseconds: 0)

        try write("duplicate", to: root.appendingPathComponent("DuplicateTarget.swift"))
        await store.replayObservedFileSystemDeltas(
            rootID: record.id,
            deltas: [.fileAdded("DuplicateTarget.swift"), .fileAdded("DuplicateTarget.swift")]
        )
        let expectedGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        try await waitForIndexedGeneration(expectedGeneration, service: service)

        let result = await service.search("DuplicateTarget", limit: 10)
        XCTAssertEqual(result.results.map(\.standardizedRelativePath), ["DuplicateTarget.swift"])
        XCTAssertEqual(Set(result.results.map(\.id)).count, 1)
    }

    func testWorkspaceSearchServiceCatchesUpWhenEventPrecedesSubscription() async throws {
        let root = try makeTemporaryRoot(name: "LiveCatchUpBeforeSubscription")
        try write("alpha", to: root.appendingPathComponent("Alpha.swift"))

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let staleSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)

        try write("missed", to: root.appendingPathComponent("MissedBeforeSubscribe.swift"))
        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.fileAdded("MissedBeforeSubscribe.swift")])
        let expectedGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)

        let service = WorkspaceSearchService()
        await service.rebuildIndex(from: staleSnapshot)
        await service.startKeepingFresh(with: store, debounceNanoseconds: 0)
        try await waitForIndexedGeneration(expectedGeneration, service: service)

        let result = await service.search("MissedBeforeSubscribe", limit: 10)
        XCTAssertFalse(result.isStale)
        XCTAssertEqual(result.results.map(\.standardizedRelativePath), ["MissedBeforeSubscribe.swift"])
    }

    func testWorkspaceSearchServiceDoesNotCancelActiveRebuildForSameGenerationEvent() async throws {
        let root = try makeTemporaryRoot(name: "LiveSameGenerationEvent")
        try write("alpha", to: root.appendingPathComponent("Alpha.swift"))

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let service = WorkspaceSearchService(automaticIndexBuildDelayNanoseconds: 200_000_000)
        let initialSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        await service.rebuildIndex(from: initialSnapshot)
        await service.startKeepingFresh(with: store, debounceNanoseconds: 0)

        try write("beta", to: root.appendingPathComponent("BetaAdded.swift"))
        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.fileAdded("BetaAdded.swift")])
        let targetGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        try await waitForPendingGeneration(targetGeneration, service: service)

        try write("alpha modified", to: root.appendingPathComponent("Alpha.swift"))
        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.fileModified("Alpha.swift", Date())])
        let generationAfterModify = await store.catalogGeneration(rootScope: .visibleWorkspace)
        XCTAssertEqual(generationAfterModify, targetGeneration)

        try await waitForIndexedGeneration(targetGeneration, service: service, timeout: 3.0)
        let result = await service.search("BetaAdded", limit: 10)
        XCTAssertFalse(result.isStale)
        XCTAssertEqual(result.results.map(\.standardizedRelativePath), ["BetaAdded.swift"])
    }

    func testWorkspaceSearchServiceDiscardsStaleRebuildCompletion() async throws {
        let root = try makeTemporaryRoot(name: "LiveStaleRebuildSearch")
        try write("alpha", to: root.appendingPathComponent("Alpha.swift"))

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let service = WorkspaceSearchService(automaticIndexBuildDelayNanoseconds: 200_000_000)
        let initialSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        await service.rebuildIndex(from: initialSnapshot)
        await service.startKeepingFresh(with: store, debounceNanoseconds: 0)

        try write("beta", to: root.appendingPathComponent("BetaFirst.swift"))
        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.fileAdded("BetaFirst.swift")])
        let firstGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        try await waitForPendingGeneration(firstGeneration, service: service)

        let staleResult = await service.search("Alpha", limit: 10)
        XCTAssertTrue(staleResult.isStale)
        XCTAssertEqual(staleResult.indexedGeneration, initialSnapshot.generation)
        XCTAssertEqual(staleResult.pendingGeneration, firstGeneration)
        XCTAssertEqual(staleResult.results.map(\.standardizedRelativePath), ["Alpha.swift"])

        try write("gamma", to: root.appendingPathComponent("GammaSecond.swift"))
        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.fileAdded("GammaSecond.swift")])
        let finalGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        try await waitForIndexedGeneration(finalGeneration, service: service, timeout: 3.0)

        let discardedCount = await service.discardedStaleRebuildCount
        XCTAssertGreaterThanOrEqual(discardedCount, 1)
        let finalResult = await service.search("Second", limit: 10)
        XCTAssertFalse(finalResult.isStale)
        XCTAssertEqual(finalResult.indexedGeneration, finalGeneration)
        XCTAssertEqual(finalResult.results.map(\.standardizedRelativePath), ["GammaSecond.swift"])
    }

    func testPathMatchWarmupPreservesLookupBehavior() async throws {
        let root = try makeTemporaryRoot(name: "PathMatchWarmup")
        try write("alpha", to: root.appendingPathComponent("Sources/Nested/A.swift"))
        try write("beta", to: root.appendingPathComponent("Sources/B.swift"))

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)

        let before = await store.lookupPath(
            WorkspacePathLookupRequest(userPath: "Sources/Nested/A.swift", profile: .mcpRead, rootScope: .visibleWorkspace)
        )
        XCTAssertEqual(before?.file?.rootID, record.id)
        XCTAssertEqual(before?.file?.standardizedRelativePath, "Sources/Nested/A.swift")

        let warmedGeneration = await store.warmPathLookupIndexes(rootScope: .visibleWorkspace)
        let catalogGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        XCTAssertEqual(warmedGeneration, catalogGeneration)

        let after = await store.lookupPath(
            WorkspacePathLookupRequest(userPath: "Sources/Nested/A.swift", profile: .mcpRead, rootScope: .visibleWorkspace)
        )
        XCTAssertEqual(after?.file, before?.file)
        XCTAssertEqual(after?.location, before?.location)

        let directChildren = await store.directFolderChildren(rootID: record.id, relativePath: "Sources")
        XCTAssertEqual(directChildren?.childFolders.map(\.standardizedRelativePath), ["Sources/Nested"])
        XCTAssertEqual(directChildren?.childFiles.map(\.standardizedRelativePath), ["Sources/B.swift"])
    }

    private func waitForIndexedGeneration(
        _ expectedGeneration: UInt64,
        service: WorkspaceSearchService,
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await service.indexedGeneration == expectedGeneration {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let actual = await service.indexedGeneration
        XCTFail("Timed out waiting for indexed generation \(expectedGeneration); actual=\(String(describing: actual))", file: file, line: line)
    }

    private func waitForPendingGeneration(
        _ expectedGeneration: UInt64,
        service: WorkspaceSearchService,
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await service.pendingGeneration == expectedGeneration {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let actual = await service.pendingGeneration
        XCTFail("Timed out waiting for pending generation \(expectedGeneration); actual=\(String(describing: actual))", file: file, line: line)
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
