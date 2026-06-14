@testable import RepoPrompt
import XCTest

#if DEBUG
    final class WorkspaceCatalogShardTests: XCTestCase {
        private var stores: [WorkspaceFileContextStore] = []
        private var temporaryRoots: [URL] = []

        override func tearDown() async throws {
            for store in stores {
                let rootIDs = await store.roots().map(\.id)
                await store.unloadRoots(ids: rootIDs)
            }
            stores.removeAll()
            for url in temporaryRoots {
                try? FileManager.default.removeItem(at: url)
            }
            temporaryRoots.removeAll()
            try await super.tearDown()
        }

        func testTopologyChurnRebuildsOnlyAffectedRootShardsAndShadowMatchesAuthoritativeBytes() async throws {
            let visibleAURL = try makeTemporaryRoot(name: "ShardVisibleA")
            let visibleBURL = try makeTemporaryRoot(name: "ShardVisibleB")
            let gitDataURL = try makeTemporaryRoot(name: "ShardGitData")
            let supplementalURL = try makeTemporaryRoot(name: "ShardSupplemental")
            let worktreeURL = try makeTemporaryRoot(name: "ShardWorktree")
            try write("a", to: visibleAURL.appendingPathComponent("Z.swift"))
            try write("b", to: visibleBURL.appendingPathComponent("A.swift"))
            try write("git", to: gitDataURL.appendingPathComponent("MAP.txt"))
            try write("system", to: supplementalURL.appendingPathComponent("System.swift"))
            try write("worktree", to: worktreeURL.appendingPathComponent("Worktree.swift"))

            let store = makeStore()
            let visibleA = try await loadStoppedRoot(in: store, path: visibleAURL.path)
            let visibleB = try await loadStoppedRoot(in: store, path: visibleBURL.path)
            let gitData = try await loadStoppedRoot(in: store, path: gitDataURL.path, kind: .workspaceGitData)
            let supplemental = try await loadStoppedRoot(in: store, path: supplementalURL.path, kind: .supplementalSystem)
            let worktree = try await loadStoppedRoot(in: store, path: worktreeURL.path, kind: .sessionWorktree)
            let sessionScope = WorkspaceLookupRootScope.sessionBoundWorkspace(
                canonicalRootPaths: [visibleBURL.path],
                physicalRootPaths: [worktreeURL.path]
            )

            let visibleSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            let gitDataSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspacePlusGitData)
            let allLoadedSnapshot = await store.searchCatalogSnapshot(rootScope: .allLoaded)
            let sessionSnapshot = await store.searchCatalogSnapshot(rootScope: sessionScope)
            XCTAssertEqual(visibleSnapshot.roots.map(\.id), [visibleA.id, visibleB.id])
            XCTAssertEqual(gitDataSnapshot.roots.map(\.id), [visibleA.id, visibleB.id, gitData.id])
            XCTAssertEqual(allLoadedSnapshot.roots.map(\.id), [visibleA.id, visibleB.id, gitData.id, supplemental.id, worktree.id])
            XCTAssertEqual(sessionSnapshot.roots.map(\.id), [visibleB.id, worktree.id])
            for snapshot in [visibleSnapshot, gitDataSnapshot, allLoadedSnapshot, sessionSnapshot] {
                XCTAssertEqual(snapshot.files.map(\.standardizedFullPath), snapshot.files.map(\.standardizedFullPath).sorted())
            }

            var diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            XCTAssertEqual(diagnostics.shadowComparisonCount, 4)
            XCTAssertEqual(diagnostics.shadowMismatchCount, 0)
            XCTAssertGreaterThan(diagnostics.lastShadowByteCount, 0)
            XCTAssertEqual(diagnostics.publishedShardCount, 5)
            XCTAssertEqual(buildCount(rootID: visibleA.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: visibleB.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: gitData.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: supplemental.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: worktree.id, in: diagnostics), 1)

            try write("added", to: visibleAURL.appendingPathComponent("Middle.swift"))
            await store.replayObservedFileSystemDeltas(rootID: visibleA.id, deltas: [.fileAdded("Middle.swift")])
            let changedVisible = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            let changedAllLoaded = await store.searchCatalogSnapshot(rootScope: .allLoaded)
            XCTAssertTrue(changedVisible.files.contains { $0.standardizedRelativePath == "Middle.swift" })
            XCTAssertTrue(changedAllLoaded.files.contains { $0.standardizedRelativePath == "Middle.swift" })

            diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            XCTAssertEqual(buildCount(rootID: visibleA.id, in: diagnostics), 2)
            XCTAssertEqual(buildCount(rootID: visibleB.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: gitData.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: supplemental.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: worktree.id, in: diagnostics), 1)

            await store.unloadRoot(id: visibleB.id)
            let afterUnload = await store.searchCatalogSnapshot(rootScope: .allLoaded)
            XCTAssertFalse(afterUnload.roots.contains { $0.id == visibleB.id })
            diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            XCTAssertEqual(diagnostics.publishedShardCount, 4)
            XCTAssertEqual(buildCount(rootID: visibleA.id, in: diagnostics), 2)
            XCTAssertEqual(buildCount(rootID: gitData.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: supplemental.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: worktree.id, in: diagnostics), 1)

            let replacementB = try await loadStoppedRoot(in: store, path: visibleBURL.path)
            let afterReload = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertNotEqual(replacementB.id, visibleB.id)
            XCTAssertTrue(afterReload.roots.contains { $0.id == replacementB.id })
            diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            XCTAssertEqual(buildCount(rootID: replacementB.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: visibleA.id, in: diagnostics), 2)
            XCTAssertEqual(buildCount(rootID: gitData.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: supplemental.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: worktree.id, in: diagnostics), 1)
            XCTAssertEqual(diagnostics.shadowComparisonCount, 8)
            XCTAssertEqual(diagnostics.shadowMismatchCount, 0)
        }

        func testRetainedSnapshotsKeepOldGenerationsAliveAndBackstopRecoversAfterRelease() async throws {
            let rootURL = try makeTemporaryRoot(name: "ShardRetention")
            try write("seed", to: rootURL.appendingPathComponent("Seed.swift"))

            let store = makeStore()
            let root = try await loadStoppedRoot(in: store, path: rootURL.path)
            var retainedSnapshots = await [store.searchCatalogSnapshot(rootScope: .visibleWorkspace)]
            let cap = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards.liveGenerationCapPerRoot
            XCTAssertGreaterThan(cap, 1)

            for generation in 1 ..< cap {
                let relativePath = "Retained-\(generation).swift"
                try write("retained", to: rootURL.appendingPathComponent(relativePath))
                await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileAdded(relativePath)])
                await retainedSnapshots.append(store.searchCatalogSnapshot(rootScope: .visibleWorkspace))
            }

            var diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            var rootDiagnostics = try XCTUnwrap(diagnostics.roots.first { $0.rootID == root.id })
            XCTAssertEqual(rootDiagnostics.liveTopologyGenerations.count, cap)
            XCTAssertEqual(rootDiagnostics.retainedTopologyGenerations.count, cap - 1)
            XCTAssertEqual(rootDiagnostics.buildCount, cap)
            XCTAssertEqual(rootDiagnostics.backstopCount, 0)
            XCTAssertEqual(rootDiagnostics.maxLiveGenerationCount, cap)

            let backstopPath = "Backstop.swift"
            try write("backstop", to: rootURL.appendingPathComponent(backstopPath))
            await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileAdded(backstopPath)])
            let backstopSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertTrue(backstopSnapshot.files.contains { $0.standardizedRelativePath == backstopPath })

            diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            rootDiagnostics = try XCTUnwrap(diagnostics.roots.first { $0.rootID == root.id })
            XCTAssertNil(rootDiagnostics.publishedTopologyGeneration)
            XCTAssertEqual(rootDiagnostics.liveTopologyGenerations.count, cap)
            XCTAssertEqual(rootDiagnostics.retainedTopologyGenerations.count, cap)
            XCTAssertEqual(rootDiagnostics.buildCount, cap)
            XCTAssertEqual(rootDiagnostics.backstopCount, 1)
            XCTAssertEqual(diagnostics.totalBackstopCount, 1)
            XCTAssertEqual(diagnostics.shadowComparisonCount, cap)
            XCTAssertEqual(diagnostics.shadowMismatchCount, 0)

            retainedSnapshots.removeAll(keepingCapacity: false)
            let recoveredSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertEqual(recoveredSnapshot, backstopSnapshot)

            diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            rootDiagnostics = try XCTUnwrap(diagnostics.roots.first { $0.rootID == root.id })
            XCTAssertNotNil(rootDiagnostics.publishedTopologyGeneration)
            XCTAssertEqual(rootDiagnostics.liveTopologyGenerations.count, 1)
            XCTAssertTrue(rootDiagnostics.retainedTopologyGenerations.isEmpty)
            XCTAssertEqual(rootDiagnostics.buildCount, cap + 1)
            XCTAssertEqual(rootDiagnostics.backstopCount, 1)
            XCTAssertEqual(diagnostics.shadowComparisonCount, cap + 1)
            XCTAssertEqual(diagnostics.shadowMismatchCount, 0)
        }

        func testContiguousCanonicalBatchesPatchSingleFileAndFolderMutations() async throws {
            let rootURL = try makeTemporaryRoot(name: "ShardDeltaPatch")
            let seedURL = rootURL.appendingPathComponent("Seed.swift")
            try write("seed", to: seedURL)

            let store = makeStore()
            let root = try await loadStoppedRoot(in: store, path: rootURL.path)
            let initialSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            let initialFolderCount = initialSnapshot.diagnostics.folderCount

            let addedURL = rootURL.appendingPathComponent("Added.swift")
            try write("added", to: addedURL)
            await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileAdded("Added.swift")])
            var snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertTrue(snapshot.files.contains { $0.standardizedRelativePath == "Added.swift" })

            try write("modified", to: addedURL)
            await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileModified("Added.swift", nil)])

            try FileManager.default.removeItem(at: addedURL)
            await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileRemoved("Added.swift")])
            snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertFalse(snapshot.files.contains { $0.standardizedRelativePath == "Added.swift" })

            let folderURL = rootURL.appendingPathComponent("Empty", isDirectory: true)
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.folderAdded("Empty")])
            snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertEqual(snapshot.diagnostics.folderCount, initialFolderCount + 1)

            await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.folderModified("Empty")])
            try FileManager.default.removeItem(at: folderURL)
            await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.folderRemoved("Empty")])
            snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertEqual(snapshot.diagnostics.folderCount, initialFolderCount)

            let diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            let rootDiagnostics = try diagnosticsForRoot(rootID: root.id, in: diagnostics)
            XCTAssertEqual(diagnostics.maxPatchLogicalMutationCount, 1)
            XCTAssertEqual(rootDiagnostics.patchCount, 6)
            XCTAssertEqual(rootDiagnostics.authoritativeRebuildCount, 1)
            XCTAssertEqual(rootDiagnostics.buildCount, 7)
            XCTAssertEqual(rootDiagnostics.lastAppliedIndexGeneration, 6)
            XCTAssertFalse(rootDiagnostics.deltaStateDirty)
            XCTAssertTrue(rootDiagnostics.fallbackReasonCounts.isEmpty)
            XCTAssertEqual(diagnostics.shadowMismatchCount, 0)
        }

        func testCanonicalBatchFallbacksCoverFullResyncGapOverflowAndUnsafeAmbiguity() async throws {
            let rootURL = try makeTemporaryRoot(name: "ShardDeltaFallbacks")
            try write("seed", to: rootURL.appendingPathComponent("Seed.swift"))

            let store = makeStore()
            let root = try await loadStoppedRoot(in: store, path: rootURL.path)
            _ = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            let lifetimeID = try await store.rootLifetimeIDForTesting(rootID: root.id)

            await store.replayPublisherFileSystemPublicationForTesting(
                rootID: root.id,
                expectedLifetimeID: lifetimeID,
                deltas: [],
                requiresFullResync: true
            )
            await store.applyAppliedIndexEventToRootCatalogShardForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 3
            ))
            await store.applyAppliedIndexEventToRootCatalogShardForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: UInt64.max
            ))
            await store.applyAppliedIndexEventToRootCatalogShardForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 0
            ))
            await store.applyAppliedIndexEventToRootCatalogShardForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 1,
                modifiedFileIDs: [UUID()]
            ))

            let diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            let rootDiagnostics = try diagnosticsForRoot(rootID: root.id, in: diagnostics)
            XCTAssertEqual(rootDiagnostics.patchCount, 0)
            XCTAssertEqual(rootDiagnostics.authoritativeRebuildCount, 6)
            XCTAssertEqual(rootDiagnostics.fallbackReasonCounts["full_resync"], 1)
            XCTAssertEqual(rootDiagnostics.fallbackReasonCounts["generation_gap"], 2)
            XCTAssertEqual(rootDiagnostics.fallbackReasonCounts["generation_overflow"], 1)
            XCTAssertEqual(rootDiagnostics.fallbackReasonCounts["unsafe_ambiguity"], 1)
            XCTAssertEqual(rootDiagnostics.lastAppliedIndexGeneration, 1)
            XCTAssertFalse(rootDiagnostics.deltaStateDirty)
        }

        func testPatchThresholdRebuildsAffectedRootAndReusesUnaffectedRoot() async throws {
            let rootAURL = try makeTemporaryRoot(name: "ShardThresholdA")
            let rootBURL = try makeTemporaryRoot(name: "ShardThresholdB")
            try write("a", to: rootAURL.appendingPathComponent("SeedA.swift"))
            try write("b", to: rootBURL.appendingPathComponent("SeedB.swift"))

            let store = makeStore()
            let rootA = try await loadStoppedRoot(in: store, path: rootAURL.path)
            let rootB = try await loadStoppedRoot(in: store, path: rootBURL.path)
            _ = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)

            try write("one", to: rootAURL.appendingPathComponent("One.swift"))
            try write("two", to: rootAURL.appendingPathComponent("Two.swift"))
            await store.replayObservedFileSystemDeltas(
                rootID: rootA.id,
                deltas: [.fileAdded("One.swift"), .fileAdded("Two.swift")]
            )
            let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertTrue(snapshot.files.contains { $0.standardizedRelativePath == "One.swift" })
            XCTAssertTrue(snapshot.files.contains { $0.standardizedRelativePath == "Two.swift" })

            let diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            let rootADiagnostics = try diagnosticsForRoot(rootID: rootA.id, in: diagnostics)
            let rootBDiagnostics = try diagnosticsForRoot(rootID: rootB.id, in: diagnostics)
            XCTAssertEqual(rootADiagnostics.patchCount, 0)
            XCTAssertEqual(rootADiagnostics.authoritativeRebuildCount, 2)
            XCTAssertEqual(rootADiagnostics.fallbackReasonCounts["threshold_exceeded"], 1)
            XCTAssertEqual(rootBDiagnostics.buildCount, 1)
            XCTAssertEqual(rootBDiagnostics.authoritativeRebuildCount, 1)
            XCTAssertEqual(rootBDiagnostics.patchCount, 0)
            XCTAssertEqual(diagnostics.shadowMismatchCount, 0)
        }

        func testRetentionBackstopMarksDirtyAndNextCanonicalBatchRecoversAuthoritatively() async throws {
            let rootURL = try makeTemporaryRoot(name: "ShardDirtyRecovery")
            try write("seed", to: rootURL.appendingPathComponent("Seed.swift"))

            let store = makeStore()
            let root = try await loadStoppedRoot(in: store, path: rootURL.path)
            var retainedSnapshots = await [store.searchCatalogSnapshot(rootScope: .visibleWorkspace)]
            let cap = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards.liveGenerationCapPerRoot

            for generation in 1 ..< cap {
                let relativePath = "Retained-\(generation).swift"
                try write("retained", to: rootURL.appendingPathComponent(relativePath))
                await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileAdded(relativePath)])
                await retainedSnapshots.append(store.searchCatalogSnapshot(rootScope: .visibleWorkspace))
            }

            try write("backstop", to: rootURL.appendingPathComponent("Backstop.swift"))
            await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileAdded("Backstop.swift")])
            var diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            var rootDiagnostics = try diagnosticsForRoot(rootID: root.id, in: diagnostics)
            XCTAssertNil(rootDiagnostics.publishedTopologyGeneration)
            XCTAssertTrue(rootDiagnostics.deltaStateDirty)
            XCTAssertEqual(rootDiagnostics.fallbackReasonCounts["retention_backstop"], 1)
            XCTAssertEqual(rootDiagnostics.backstopCount, 1)

            retainedSnapshots.removeAll(keepingCapacity: false)
            try write("recovered", to: rootURL.appendingPathComponent("Recovered.swift"))
            await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileAdded("Recovered.swift")])
            let recoveredSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertTrue(recoveredSnapshot.files.contains { $0.standardizedRelativePath == "Backstop.swift" })
            XCTAssertTrue(recoveredSnapshot.files.contains { $0.standardizedRelativePath == "Recovered.swift" })

            diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            rootDiagnostics = try diagnosticsForRoot(rootID: root.id, in: diagnostics)
            XCTAssertFalse(rootDiagnostics.deltaStateDirty)
            XCTAssertEqual(rootDiagnostics.fallbackReasonCounts["dirty_recovery"], 1)
            XCTAssertEqual(rootDiagnostics.authoritativeRebuildCount, 2)
            XCTAssertEqual(rootDiagnostics.patchCount, cap - 1)
            XCTAssertEqual(rootDiagnostics.backstopCount, 1)
            XCTAssertEqual(diagnostics.shadowMismatchCount, 0)
        }

        func testUnloadClearsShardLifetimeAndReloadStartsIndependentGeneration() async throws {
            let rootURL = try makeTemporaryRoot(name: "ShardLifetimeReset")
            try write("seed", to: rootURL.appendingPathComponent("Seed.swift"))

            let store = makeStore()
            let originalRoot = try await loadStoppedRoot(in: store, path: rootURL.path)
            let retainedOriginalSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            let originalLifetimeID = try await store.rootLifetimeIDForTesting(rootID: originalRoot.id)

            await store.unloadRoot(id: originalRoot.id)
            var diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            let unloadedDiagnostics = try diagnosticsForRoot(rootID: originalRoot.id, in: diagnostics)
            XCTAssertNil(unloadedDiagnostics.publishedTopologyGeneration)
            XCTAssertEqual(unloadedDiagnostics.fallbackReasonCounts["unload"], 1)

            let replacementRoot = try await loadStoppedRoot(in: store, path: rootURL.path)
            let replacementLifetimeID = try await store.rootLifetimeIDForTesting(rootID: replacementRoot.id)
            XCTAssertNotEqual(replacementRoot.id, originalRoot.id)
            XCTAssertNotEqual(replacementLifetimeID, originalLifetimeID)
            _ = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)

            await store.applyAppliedIndexEventToRootCatalogShardForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: originalRoot.id,
                rootPath: originalRoot.standardizedFullPath,
                generation: 1,
                requiresFullResync: true
            ))
            try write("new", to: rootURL.appendingPathComponent("New.swift"))
            await store.replayObservedFileSystemDeltas(rootID: replacementRoot.id, deltas: [.fileAdded("New.swift")])
            let replacementSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertTrue(replacementSnapshot.files.contains { $0.standardizedRelativePath == "New.swift" })
            XCTAssertEqual(retainedOriginalSnapshot.files.map(\.standardizedRelativePath), ["Seed.swift"])

            diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            let replacementDiagnostics = try diagnosticsForRoot(rootID: replacementRoot.id, in: diagnostics)
            XCTAssertEqual(replacementDiagnostics.authoritativeRebuildCount, 1)
            XCTAssertEqual(replacementDiagnostics.patchCount, 1)
            XCTAssertEqual(replacementDiagnostics.lastAppliedIndexGeneration, 1)
            XCTAssertFalse(replacementDiagnostics.deltaStateDirty)
            XCTAssertEqual(diagnostics.shadowMismatchCount, 0)
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

        private func diagnosticsForRoot(
            rootID: UUID,
            in diagnostics: WorkspaceFileContextStore.RootCatalogShardDebugSnapshot
        ) throws -> WorkspaceFileContextStore.RootCatalogShardGenerationDebugSnapshot {
            try XCTUnwrap(diagnostics.roots.first { $0.rootID == rootID })
        }

        private func buildCount(
            rootID: UUID,
            in diagnostics: WorkspaceFileContextStore.RootCatalogShardDebugSnapshot
        ) -> Int {
            diagnostics.roots.first { $0.rootID == rootID }?.buildCount ?? 0
        }

        private func makeTemporaryRoot(name: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("RepoPrompt-\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            temporaryRoots.append(url)
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
#endif
