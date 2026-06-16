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
            XCTAssertEqual(try shardDiagnostics(rootID: rootA.id, diagnostics: diagnostics).pathIndexBuildCount, 2)
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
