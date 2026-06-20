@testable import RepoPrompt
import XCTest

#if DEBUG
    final class WorkspacePerRootPathSearchIndexTests: XCTestCase {
        private var stores: [WorkspaceFileContextStore] = []
        private var temporaryRoots: [URL] = []

        override func tearDown() async throws {
            for store in stores {
                await store.unloadRoots(ids: store.roots().map(\.id))
            }
            stores.removeAll()
            for root in temporaryRoots {
                try? FileManager.default.removeItem(at: root)
            }
            temporaryRoots.removeAll()
            try await super.tearDown()
        }

        func testPerRootMergeMatchesAuthoritativeGlobalIndexAcrossScopes() async throws {
            let primaryAURL = try makeTemporaryRoot(name: "ParityPrimaryA")
            let primaryBURL = try makeTemporaryRoot(name: "ParityPrimaryB")
            let gitDataURL = try makeTemporaryRoot(name: "ParityGitData")
            let supplementalURL = try makeTemporaryRoot(name: "ParitySupplemental")
            let worktreeURL = try makeTemporaryRoot(name: "ParityWorktree")
            try write("a", to: primaryAURL.appendingPathComponent("Sources/SharedTarget.swift"))
            try write("b", to: primaryBURL.appendingPathComponent("Tests/SharedTargetTests.swift"))
            try write("unicode", to: primaryBURL.appendingPathComponent("Sources/ÅngströmTarget.swift"))
            try write("unicode", to: primaryBURL.appendingPathComponent("Sources/文件Target.swift"))
            try write("git", to: gitDataURL.appendingPathComponent("MAP-Target.txt"))
            try write("system", to: supplementalURL.appendingPathComponent("SystemTarget.swift"))
            try write("worktree", to: worktreeURL.appendingPathComponent("Sources/WorktreeTarget.swift"))

            let store = makeStore()
            _ = try await loadStoppedRoot(in: store, path: primaryAURL.path)
            _ = try await loadStoppedRoot(in: store, path: primaryBURL.path)
            _ = try await loadStoppedRoot(in: store, path: gitDataURL.path, kind: .workspaceGitData)
            _ = try await loadStoppedRoot(in: store, path: supplementalURL.path, kind: .supplementalSystem)
            _ = try await loadStoppedRoot(in: store, path: worktreeURL.path, kind: .sessionWorktree)

            let scopes: [WorkspaceLookupRootScope] = [
                .visibleWorkspace,
                .visibleWorkspacePlusGitData,
                .allLoaded,
                .sessionBoundWorkspace(
                    canonicalRootPaths: [primaryAURL.path],
                    physicalRootPaths: [worktreeURL.path]
                )
            ]
            let queries = ["", "Target", "Shared Target", "*.swift", worktreeURL.path]
            let service = WorkspaceSearchService()

            for scope in scopes {
                let snapshot = await store.searchCatalogSnapshot(rootScope: scope)
                XCTAssertEqual(snapshot.rootPathIndexes.count, snapshot.roots.count)
                await service.prepareIndex(from: snapshot)
                for query in queries {
                    for limit in [1, 3, 20] {
                        let expected = WorkspaceSearchService.authoritativeGlobalResultsForTesting(
                            from: snapshot,
                            query: query,
                            limit: limit
                        )
                        let actual = await service.search(query, limit: limit)
                        XCTAssertEqual(
                            actual.results,
                            expected,
                            "scope=\(scope) query=\(query) limit=\(limit)"
                        )
                    }
                }
            }
        }

        func testGlobalTopKAllowsLaterRootToDisplaceEarlierRootDeterministically() async throws {
            let loadedFirstURL = try makeTemporaryRoot(name: "ZZZLoadedFirst")
            let loadedLaterURL = try makeTemporaryRoot(name: "AAALoadedLater")
            try write("first", to: loadedFirstURL.appendingPathComponent("Target.swift"))
            try write("later", to: loadedLaterURL.appendingPathComponent("Target.swift"))

            let store = makeStore()
            let loadedFirst = try await loadStoppedRoot(in: store, path: loadedFirstURL.path)
            let loadedLater = try await loadStoppedRoot(in: store, path: loadedLaterURL.path)
            let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertEqual(snapshot.roots.map(\.id), [loadedFirst.id, loadedLater.id])

            let service = WorkspaceSearchService()
            await service.prepareIndex(from: snapshot)
            let result = await service.search("Target", limit: 1)
            let authoritative = WorkspaceSearchService.authoritativeGlobalResultsForTesting(
                from: snapshot,
                query: "Target",
                limit: 1
            )
            XCTAssertEqual(result.results, authoritative)
            XCTAssertEqual(result.results.map(\.rootID), [loadedLater.id])

            let precomposedRoot = try WorkspaceRootRecord(
                id: XCTUnwrap(UUID(uuidString: "30000000-0000-0000-0000-000000000001")),
                name: "Precomposed",
                fullPath: "/virtual/precomposed"
            )
            let decomposedRoot = try WorkspaceRootRecord(
                id: XCTUnwrap(UUID(uuidString: "30000000-0000-0000-0000-000000000002")),
                name: "Decomposed",
                fullPath: "/virtual/decomposed"
            )
            let precomposedID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
            let decomposedID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
            let sharedFullPath = "/virtual/shared/Target.swift"
            let precomposedFile = WorkspaceFileRecord(
                id: precomposedID,
                rootID: precomposedRoot.id,
                name: "Target.swift",
                relativePath: "Target.swift",
                fullPath: sharedFullPath,
                parentFolderID: nil
            )
            let decomposedFile = WorkspaceFileRecord(
                id: decomposedID,
                rootID: decomposedRoot.id,
                name: "Target.swift",
                relativePath: "Target.swift",
                fullPath: sharedFullPath,
                parentFolderID: nil
            )
            let precomposedEntry = WorkspaceSearchCatalogEntry(
                file: precomposedFile,
                root: precomposedRoot,
                displayPath: "ÉTarget.swift"
            )
            let decomposedEntry = WorkspaceSearchCatalogEntry(
                file: decomposedFile,
                root: decomposedRoot,
                displayPath: "E\u{301}Target.swift"
            )
            XCTAssertEqual(precomposedEntry.pathSearchIndexKey, decomposedEntry.pathSearchIndexKey)
            XCTAssertNotEqual(
                Array(precomposedEntry.pathSearchIndexKey.utf8),
                Array(decomposedEntry.pathSearchIndexKey.utf8)
            )

            let precomposedIndex = try WorkspaceSearchRootPathIndex(
                identity: WorkspaceSearchRootPathIndexIdentity(
                    rootID: precomposedRoot.id,
                    lifetimeID: XCTUnwrap(UUID(uuidString: "40000000-0000-0000-0000-000000000001")),
                    topologyGeneration: 1
                ),
                rootPath: precomposedRoot.standardizedFullPath,
                entries: [precomposedEntry]
            )
            let decomposedIndex = try WorkspaceSearchRootPathIndex(
                identity: WorkspaceSearchRootPathIndexIdentity(
                    rootID: decomposedRoot.id,
                    lifetimeID: XCTUnwrap(UUID(uuidString: "40000000-0000-0000-0000-000000000002")),
                    topologyGeneration: 1
                ),
                rootPath: decomposedRoot.standardizedFullPath,
                entries: [decomposedEntry]
            )
            let unicodeSnapshot = WorkspaceSearchCatalogSnapshot(
                generation: 1,
                rootScope: .visibleWorkspace,
                roots: [precomposedRoot, decomposedRoot],
                files: [precomposedFile, decomposedFile],
                entries: [precomposedEntry, decomposedEntry],
                rootPathIndexes: [precomposedIndex, decomposedIndex],
                diagnostics: WorkspaceCatalogDiagnostics(
                    generation: 1,
                    rootScope: .visibleWorkspace,
                    rootCount: 2,
                    folderCount: 0,
                    fileCount: 2
                )
            )
            let unicodeAuthoritative = WorkspaceSearchService.authoritativeGlobalResultsForTesting(
                from: unicodeSnapshot,
                query: "Target",
                limit: 1
            )
            XCTAssertEqual(unicodeAuthoritative.map(\.id), [decomposedID])
            await service.prepareIndex(from: unicodeSnapshot)
            let unicodeResult = await service.search("Target", limit: 1)
            XCTAssertEqual(unicodeResult.results, unicodeAuthoritative)
        }

        func testChangedRootOnlyRebuildsItsPathIndexAndUnloadReloadResetsLifetime() async throws {
            let rootAURL = try makeTemporaryRoot(name: "IndexReuseA")
            let rootBURL = try makeTemporaryRoot(name: "IndexReuseB")
            try write("a", to: rootAURL.appendingPathComponent("A.swift"))
            try write("b", to: rootBURL.appendingPathComponent("B.swift"))

            let store = makeStore()
            let rootA = try await loadStoppedRoot(in: store, path: rootAURL.path)
            let rootB = try await loadStoppedRoot(in: store, path: rootBURL.path)
            let firstSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            let firstAIndex = try rootPathIndex(rootID: rootA.id, snapshot: firstSnapshot)
            let firstBIndex = try rootPathIndex(rootID: rootB.id, snapshot: firstSnapshot)

            try write("new", to: rootAURL.appendingPathComponent("New.swift"))
            await store.replayObservedFileSystemDeltas(rootID: rootA.id, deltas: [.fileAdded("New.swift")])
            let secondSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            let secondAIndex = try rootPathIndex(rootID: rootA.id, snapshot: secondSnapshot)
            let secondBIndex = try rootPathIndex(rootID: rootB.id, snapshot: secondSnapshot)
            XCTAssertFalse(firstAIndex === secondAIndex)
            XCTAssertTrue(firstBIndex === secondBIndex)

            var diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            let rootADiagnostics = try shardDiagnostics(rootID: rootA.id, diagnostics: diagnostics)
            XCTAssertEqual(rootADiagnostics.pathIndexBuildCount, 1)
            XCTAssertEqual(rootADiagnostics.overlayPathIndexBuildCount, 1)
            XCTAssertEqual(try shardDiagnostics(rootID: rootB.id, diagnostics: diagnostics).pathIndexBuildCount, 1)

            await store.unloadRoot(id: rootA.id)
            let unloadedSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertEqual(unloadedSnapshot.rootPathIndexes.map(\.identity.rootID), [rootB.id])
            XCTAssertTrue(try rootPathIndex(rootID: rootB.id, snapshot: unloadedSnapshot) === firstBIndex)
            XCTAssertEqual(secondAIndex.search("New", limit: 10).map(\.entry.standardizedRelativePath), ["New.swift"])

            let replacementA = try await loadStoppedRoot(in: store, path: rootAURL.path)
            let reloadedSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            let replacementAIndex = try rootPathIndex(rootID: replacementA.id, snapshot: reloadedSnapshot)
            XCTAssertNotEqual(replacementA.id, rootA.id)
            XCTAssertNotEqual(replacementAIndex.identity.lifetimeID, firstAIndex.identity.lifetimeID)
            XCTAssertFalse(replacementAIndex === firstAIndex)
            XCTAssertTrue(try rootPathIndex(rootID: rootB.id, snapshot: reloadedSnapshot) === firstBIndex)

            diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            XCTAssertEqual(try shardDiagnostics(rootID: replacementA.id, diagnostics: diagnostics).pathIndexBuildCount, 1)
            XCTAssertEqual(try shardDiagnostics(rootID: rootB.id, diagnostics: diagnostics).pathIndexBuildCount, 1)
        }

        func testOverlayTransitionsPreserveSearchAndPerRootMergeParity() async throws {
            let rootAURL = try makeTemporaryRoot(name: "OverlayParityA")
            let rootBURL = try makeTemporaryRoot(name: "OverlayParityB")
            try write("a", to: rootAURL.appendingPathComponent("AAATarget.swift"))
            try write("b", to: rootAURL.appendingPathComponent("BBTarget.swift"))
            try write("space", to: rootAURL.appendingPathComponent("Sources/Space Target.swift"))
            try write("unicode", to: rootAURL.appendingPathComponent("Sources/ÅngströmTarget.swift"))
            try write("unicode", to: rootAURL.appendingPathComponent("Sources/文件Target.swift"))
            try write("other", to: rootBURL.appendingPathComponent("A0OtherTarget.swift"))

            let store = makeStore()
            let rootA = try await loadStoppedRoot(in: store, path: rootAURL.path)
            _ = try await loadStoppedRoot(in: store, path: rootBURL.path)
            let service = WorkspaceSearchService()
            let queries = ["", "Target", "Space Target", "*.swift", "Ångström", "文件"]

            try FileManager.default.removeItem(at: rootAURL.appendingPathComponent("AAATarget.swift"))
            await store.replayObservedFileSystemDeltas(rootID: rootA.id, deltas: [.fileRemoved("AAATarget.swift")])
            try await assertSearchParity(store: store, service: service, queries: queries)

            try write("added", to: rootAURL.appendingPathComponent("A0AddedTarget.swift"))
            await store.replayObservedFileSystemDeltas(rootID: rootA.id, deltas: [.fileAdded("A0AddedTarget.swift")])
            try await assertSearchParity(store: store, service: service, queries: queries)

            try FileManager.default.removeItem(at: rootAURL.appendingPathComponent("BBTarget.swift"))
            await store.replayObservedFileSystemDeltas(rootID: rootA.id, deltas: [.fileRemoved("BBTarget.swift")])
            try write("renamed", to: rootAURL.appendingPathComponent("RenamedTarget.swift"))
            await store.replayObservedFileSystemDeltas(rootID: rootA.id, deltas: [.fileAdded("RenamedTarget.swift")])
            try await assertSearchParity(store: store, service: service, queries: queries)

            let beforeFolderPatch = try await shardDiagnostics(
                rootID: rootA.id,
                diagnostics: store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            )
            let folderURL = rootAURL.appendingPathComponent("FolderOnly", isDirectory: true)
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            await store.replayObservedFileSystemDeltas(rootID: rootA.id, deltas: [.folderAdded("FolderOnly")])
            try await assertSearchParity(store: store, service: service, queries: queries)
            let afterFolderPatch = try await shardDiagnostics(
                rootID: rootA.id,
                diagnostics: store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            )
            XCTAssertEqual(afterFolderPatch.pathIndexBuildCount, beforeFolderPatch.pathIndexBuildCount)
            XCTAssertEqual(
                afterFolderPatch.overlayPathIndexBuildCount,
                beforeFolderPatch.overlayPathIndexBuildCount
            )

            let virtualRoot = try WorkspaceRootRecord(
                id: XCTUnwrap(UUID(uuidString: "10000000-0000-0000-0000-000000000000")),
                name: "Virtual",
                fullPath: "/virtual"
            )
            let precomposedID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
            let decomposedID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
            let sharedRelativePath = "Target.swift"
            let sharedFullPath = "/virtual/Target.swift"
            let precomposedFile = WorkspaceFileRecord(
                id: precomposedID,
                rootID: virtualRoot.id,
                name: sharedRelativePath,
                relativePath: sharedRelativePath,
                fullPath: sharedFullPath,
                parentFolderID: nil
            )
            let decomposedFile = WorkspaceFileRecord(
                id: decomposedID,
                rootID: virtualRoot.id,
                name: sharedRelativePath,
                relativePath: sharedRelativePath,
                fullPath: sharedFullPath,
                parentFolderID: nil
            )
            let precomposedEntry = WorkspaceSearchCatalogEntry(
                file: precomposedFile,
                root: virtualRoot,
                displayPath: "Virtual/ÉTarget.swift"
            )
            let decomposedEntry = WorkspaceSearchCatalogEntry(
                file: decomposedFile,
                root: virtualRoot,
                displayPath: "Virtual/E\u{301}Target.swift"
            )
            XCTAssertEqual(precomposedEntry.pathSearchIndexKey, decomposedEntry.pathSearchIndexKey)
            XCTAssertNotEqual(
                Array(precomposedEntry.pathSearchIndexKey.utf8),
                Array(decomposedEntry.pathSearchIndexKey.utf8)
            )
            let precomposedPath = "/virtual/ÉTarget.swift"
            let decomposedPath = "/virtual/E\u{301}Target.swift"
            XCTAssertTrue(FileSearchActor.pathSearchInputPrecedes(decomposedPath, precomposedPath))
            XCTAssertFalse(FileSearchActor.pathSearchInputPrecedes(precomposedPath, decomposedPath))

            let lifetimeID = try XCTUnwrap(UUID(uuidString: "20000000-0000-0000-0000-000000000000"))
            let baseIndex = WorkspaceSearchRootPathIndex(
                identity: WorkspaceSearchRootPathIndexIdentity(
                    rootID: virtualRoot.id,
                    lifetimeID: lifetimeID,
                    topologyGeneration: 1
                ),
                rootPath: virtualRoot.standardizedFullPath,
                entries: [precomposedEntry]
            )
            let overlayIndex = baseIndex.applyingPatch(
                identity: WorkspaceSearchRootPathIndexIdentity(
                    rootID: virtualRoot.id,
                    lifetimeID: lifetimeID,
                    topologyGeneration: 2
                ),
                entries: [precomposedEntry, decomposedEntry],
                changedFileIDs: [decomposedID]
            )
            XCTAssertEqual(
                overlayIndex.search("Target", limit: 1).map(\.entry.id),
                [decomposedID]
            )

            let unicodeSnapshot = WorkspaceSearchCatalogSnapshot(
                generation: 2,
                rootScope: .visibleWorkspace,
                roots: [virtualRoot],
                files: [precomposedFile, decomposedFile],
                entries: [precomposedEntry, decomposedEntry],
                rootPathIndexes: [overlayIndex],
                diagnostics: WorkspaceCatalogDiagnostics(
                    generation: 2,
                    rootScope: .visibleWorkspace,
                    rootCount: 1,
                    folderCount: 0,
                    fileCount: 2
                )
            )
            let authoritative = WorkspaceSearchService.authoritativeGlobalResultsForTesting(
                from: unicodeSnapshot,
                query: "Target",
                limit: 1
            )
            XCTAssertEqual(authoritative.map(\.id), [decomposedID])
            await service.prepareIndex(from: unicodeSnapshot)
            let indexed = await service.search("Target", limit: 1)
            XCTAssertEqual(indexed.results, authoritative)
        }

        func testOverlayCompactsAtBoundWhileRetainedReadersStayImmutable() async throws {
            let rootURL = try makeTemporaryRoot(name: "OverlayCompaction")
            try write("seed", to: rootURL.appendingPathComponent("Seed.swift"))

            let store = makeStore()
            let root = try await loadStoppedRoot(in: store, path: rootURL.path)
            let oldSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            let oldIndex = try rootPathIndex(rootID: root.id, snapshot: oldSnapshot)
            let overlayBound = await store.storeWorkDiagnosticsSnapshot()
                .rootCatalogShards.maxPathIndexOverlayChangedFileCount
            XCTAssertEqual(overlayBound, 32)

            var lastOverlaySnapshot: WorkspaceSearchCatalogSnapshot?
            for index in 0 ..< overlayBound {
                let relativePath = String(format: "Added-%02d-Target.swift", index)
                try write("added", to: rootURL.appendingPathComponent(relativePath))
                await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileAdded(relativePath)])
                if index == overlayBound - 2 {
                    lastOverlaySnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
                }
            }

            let compactedSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            let compactedIndex = try rootPathIndex(rootID: root.id, snapshot: compactedSnapshot)
            let overlayIndex = try rootPathIndex(
                rootID: root.id,
                snapshot: XCTUnwrap(lastOverlaySnapshot)
            )
            XCTAssertTrue(oldIndex.search("Added", limit: 100).isEmpty)
            XCTAssertEqual(overlayIndex.search("Added", limit: 100).count, overlayBound - 1)
            XCTAssertEqual(compactedIndex.search("Added", limit: 100).count, overlayBound)

            let diagnostics = try await shardDiagnostics(
                rootID: root.id,
                diagnostics: store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            )
            XCTAssertEqual(diagnostics.pathIndexBuildCount, 2)
            XCTAssertEqual(diagnostics.overlayPathIndexBuildCount, overlayBound - 1)
            XCTAssertEqual(diagnostics.patchCount, overlayBound)
            XCTAssertEqual(diagnostics.authoritativeRebuildCount, 1)
        }

        func testRootUnloadDropsOnlyItsReadyIndexWhileReplacementGenerationIsPending() async throws {
            let rootAURL = try makeTemporaryRoot(name: "DropIndexA")
            let rootBURL = try makeTemporaryRoot(name: "DropIndexB")
            try write("drop", to: rootAURL.appendingPathComponent("DropTarget.swift"))
            try write("keep", to: rootBURL.appendingPathComponent("KeepTarget.swift"))

            let store = makeStore()
            let rootA = try await loadStoppedRoot(in: store, path: rootAURL.path)
            let rootB = try await loadStoppedRoot(in: store, path: rootBURL.path)
            let service = WorkspaceSearchService(automaticIndexBuildDelayNanoseconds: 300_000_000)
            await service.prepareIndex(from: store.searchCatalogSnapshot(rootScope: .visibleWorkspace))
            await service.startKeepingFresh(with: store, debounceNanoseconds: 0)

            await store.unloadRoot(id: rootA.id)
            let targetGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
            try await waitForPendingGeneration(targetGeneration, service: service)

            let dropped = await service.search("DropTarget", limit: 10)
            let kept = await service.search("KeepTarget", limit: 10)
            XCTAssertTrue(dropped.results.isEmpty)
            XCTAssertEqual(kept.results.map(\.rootID), [rootB.id])
            XCTAssertTrue(kept.isIndexReady)
            XCTAssertTrue(kept.isStale)

            try await waitForIndexedGeneration(targetGeneration, service: service)
            let finalKept = await service.search("KeepTarget", limit: 10)
            XCTAssertEqual(finalKept.results.map(\.rootID), [rootB.id])
        }

        func testConcurrentOldReaderRetainsOldIndexWhileNewGenerationPublishes() async throws {
            let rootURL = try makeTemporaryRoot(name: "ConcurrentIndexGeneration")
            let oldURL = rootURL.appendingPathComponent("OldTarget.swift")
            try write("old", to: oldURL)

            let store = makeStore()
            let root = try await loadStoppedRoot(in: store, path: rootURL.path)
            let oldSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            let service = WorkspaceSearchService()
            await service.prepareIndex(from: oldSnapshot)

            let gate = AsyncGate()
            await service.setSearchDidCaptureGenerationHandler { generation in
                await gate.enter(generation: generation)
            }
            let oldSearch = Task { await service.search("OldTarget", limit: 10) }
            let capturedGeneration = await gate.waitUntilEntered()
            XCTAssertEqual(capturedGeneration, oldSnapshot.generation)

            try FileManager.default.removeItem(at: oldURL)
            await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileRemoved("OldTarget.swift")])
            let newSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            await service.rebuildIndex(from: newSnapshot)
            await service.setSearchDidCaptureGenerationHandler(nil)
            await gate.open()

            let oldResult = await oldSearch.value
            XCTAssertEqual(oldResult.indexedGeneration, oldSnapshot.generation)
            XCTAssertEqual(oldResult.results.map(\.standardizedRelativePath), ["OldTarget.swift"])
            let newResult = await service.search("OldTarget", limit: 10)
            XCTAssertEqual(newResult.indexedGeneration, newSnapshot.generation)
            XCTAssertTrue(newResult.results.isEmpty)

            let diagnostics = try await shardDiagnostics(
                rootID: root.id,
                diagnostics: store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            )
            XCTAssertEqual(diagnostics.pathIndexBuildCount, 1)
            XCTAssertEqual(diagnostics.overlayPathIndexBuildCount, 1)
        }

        private func makeStore() -> WorkspaceFileContextStore {
            let store = WorkspaceFileContextStore()
            stores.append(store)
            return store
        }

        private func loadStoppedRoot(
            in store: WorkspaceFileContextStore,
            path: String,
            kind: WorkspaceRootKind? = nil
        ) async throws -> WorkspaceRootRecord {
            let root = try await store.loadRoot(path: path, kind: kind)
            await store.stopWatchingRoot(id: root.id)
            return root
        }

        private func assertSearchParity(
            store: WorkspaceFileContextStore,
            service: WorkspaceSearchService,
            queries: [String],
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            await service.prepareIndex(from: snapshot)
            for query in queries {
                for limit in [1, 3, 20] {
                    let expected = WorkspaceSearchService.authoritativeGlobalResultsForTesting(
                        from: snapshot,
                        query: query,
                        limit: limit
                    )
                    let actual = await service.search(query, limit: limit)
                    XCTAssertEqual(actual.results, expected, "query=\(query) limit=\(limit)", file: file, line: line)
                }
            }
        }

        private func rootPathIndex(
            rootID: UUID,
            snapshot: WorkspaceSearchCatalogSnapshot
        ) throws -> WorkspaceSearchRootPathIndex {
            try XCTUnwrap(snapshot.rootPathIndexes.first { $0.identity.rootID == rootID })
        }

        private func shardDiagnostics(
            rootID: UUID,
            diagnostics: WorkspaceFileContextStore.RootCatalogShardDebugSnapshot
        ) throws -> WorkspaceFileContextStore.RootCatalogShardGenerationDebugSnapshot {
            try XCTUnwrap(diagnostics.roots.first { $0.rootID == rootID })
        }

        private func waitForIndexedGeneration(
            _ expected: UInt64,
            service: WorkspaceSearchService,
            timeout: TimeInterval = 2.0,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if await service.indexedGeneration == expected { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail("Timed out waiting for indexed generation \(expected)", file: file, line: line)
        }

        private func waitForPendingGeneration(
            _ expected: UInt64,
            service: WorkspaceSearchService,
            timeout: TimeInterval = 2.0,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if await service.pendingGeneration == expected { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail("Timed out waiting for pending generation \(expected)", file: file, line: line)
        }

        private func makeTemporaryRoot(name: String) throws -> URL {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("RepoPromptTests", isDirectory: true)
                .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            temporaryRoots.append(root)
            return root
        }

        private func write(_ content: String, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private actor AsyncGate {
        private var enteredGeneration: UInt64?
        private var enteredWaiters: [CheckedContinuation<UInt64?, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func enter(generation: UInt64?) async {
            enteredGeneration = generation
            let waiters = enteredWaiters
            enteredWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(returning: generation)
            }
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilEntered() async -> UInt64? {
            if enteredGeneration != nil { return enteredGeneration }
            return await withCheckedContinuation { continuation in
                enteredWaiters.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
#endif
