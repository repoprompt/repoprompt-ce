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

        func testDefaultColdCompositionReusesSingleShardAndSkipsShadowValidation() async throws {
            let rootAURL = try makeTemporaryRoot(name: "ColdCompositionA")
            let rootBURL = try makeTemporaryRoot(name: "ColdCompositionB")
            try write("a", to: rootAURL.appendingPathComponent("A.swift"))
            try write("b", to: rootBURL.appendingPathComponent("B.swift"))

            let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
            stores.append(store)
            let rootA = try await loadStoppedRoot(in: store, path: rootAURL.path)
            let singleRootSnapshot = await store.searchCatalogSnapshot(
                rootScope: .visibleWorkspace,
                requirement: .recordsOnly
            )

            XCTAssertEqual(singleRootSnapshot.roots.map(\.id), [rootA.id])
            XCTAssertEqual(singleRootSnapshot.files.map(\.standardizedRelativePath), ["A.swift"])
            XCTAssertEqual(singleRootSnapshot.files.map(\.id), singleRootSnapshot.entries.map(\.id))
            XCTAssertTrue(singleRootSnapshot.rootPathIndexes.isEmpty)
            var diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            var rootADiagnostics = try diagnosticsForRoot(rootID: rootA.id, in: diagnostics)
            XCTAssertEqual(rootADiagnostics.authoritativeRebuildCount, 1)
            XCTAssertEqual(rootADiagnostics.pathIndexBuildCount, 0)
            XCTAssertEqual(rootADiagnostics.overlayPathIndexBuildCount, 0)
            XCTAssertEqual(diagnostics.singleShardCompositionReuseCount, 1)
            XCTAssertEqual(diagnostics.genericMergeElementVisitCount, 0)
            XCTAssertEqual(diagnostics.shadowComparisonCount, 0)
            XCTAssertEqual(diagnostics.lastShadowByteCount, 0)

            let rootB = try await loadStoppedRoot(in: store, path: rootBURL.path)
            let multiRootSnapshot = await store.searchCatalogSnapshot(
                rootScope: .visibleWorkspace,
                requirement: .recordsOnly
            )

            XCTAssertEqual(multiRootSnapshot.roots.map(\.id), [rootA.id, rootB.id])
            XCTAssertEqual(multiRootSnapshot.files.map(\.standardizedRelativePath), ["A.swift", "B.swift"])
            XCTAssertEqual(multiRootSnapshot.files.map(\.id), multiRootSnapshot.entries.map(\.id))
            XCTAssertTrue(multiRootSnapshot.rootPathIndexes.isEmpty)
            diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            let recordsOnlyDiagnostics = diagnostics
            rootADiagnostics = try diagnosticsForRoot(rootID: rootA.id, in: diagnostics)
            let rootBRecordsOnlyDiagnostics = try diagnosticsForRoot(rootID: rootB.id, in: diagnostics)
            XCTAssertEqual(rootADiagnostics.authoritativeRebuildCount, 1)
            XCTAssertEqual(rootADiagnostics.pathIndexBuildCount, 0)
            XCTAssertEqual(rootBRecordsOnlyDiagnostics.authoritativeRebuildCount, 1)
            XCTAssertEqual(rootBRecordsOnlyDiagnostics.pathIndexBuildCount, 0)
            XCTAssertEqual(diagnostics.singleShardCompositionReuseCount, 1)
            XCTAssertEqual(diagnostics.genericMergeElementVisitCount, 2)
            let retainedRecordsOnlyFileIDs = multiRootSnapshot.files.map(\.id)

            let rootAOnlyScope = WorkspaceLookupRootScope.sessionBoundWorkspace(
                canonicalRootPaths: [rootAURL.standardizedFileURL.path],
                physicalRootPaths: []
            )
            let indexedRootA = await store.searchCatalogSnapshot(rootScope: rootAOnlyScope)
            XCTAssertEqual(indexedRootA.roots.map(\.id), [rootA.id])
            XCTAssertEqual(indexedRootA.rootPathIndexes.count, 1)
            let rootAOnlyDiagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            let promotedRootADiagnostics = try diagnosticsForRoot(rootID: rootA.id, in: rootAOnlyDiagnostics)
            let unpromotedRootBDiagnostics = try diagnosticsForRoot(rootID: rootB.id, in: rootAOnlyDiagnostics)
            XCTAssertEqual(promotedRootADiagnostics.buildCount, 2)
            XCTAssertEqual(promotedRootADiagnostics.pathIndexBuildCount, 1)
            XCTAssertEqual(unpromotedRootBDiagnostics.buildCount, 1)
            XCTAssertEqual(unpromotedRootBDiagnostics.pathIndexBuildCount, 0)
            let projectedRootA = await store.searchCatalogSnapshot(
                rootScope: rootAOnlyScope,
                requirement: .recordsOnly
            )
            XCTAssertTrue(projectedRootA.rootPathIndexes.isEmpty)
            XCTAssertEqual(projectedRootA.generation, indexedRootA.generation)

            let indexed = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertEqual(indexed.rootPathIndexes.count, 2)
            XCTAssertTrue(indexed.rootPathIndexes[0] === indexedRootA.rootPathIndexes[0])
            XCTAssertTrue(multiRootSnapshot.rootPathIndexes.isEmpty)
            XCTAssertEqual(multiRootSnapshot.files.map(\.id), retainedRecordsOnlyFileIDs)
            diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            rootADiagnostics = try diagnosticsForRoot(rootID: rootA.id, in: diagnostics)
            let rootBIndexedDiagnostics = try diagnosticsForRoot(rootID: rootB.id, in: diagnostics)
            XCTAssertEqual(rootADiagnostics.authoritativeRebuildCount, 1)
            XCTAssertEqual(rootADiagnostics.pathIndexBuildCount, 1)
            XCTAssertEqual(rootADiagnostics.buildCount, 2)
            XCTAssertEqual(rootBIndexedDiagnostics.authoritativeRebuildCount, 1)
            XCTAssertEqual(rootBIndexedDiagnostics.pathIndexBuildCount, 1)
            XCTAssertEqual(rootBIndexedDiagnostics.buildCount, 2)
            XCTAssertEqual(rootADiagnostics.patchCount, 0)
            XCTAssertEqual(rootBIndexedDiagnostics.patchCount, 0)

            let repeatedIndexed = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertTrue(indexed.rootPathIndexes[0] === repeatedIndexed.rootPathIndexes[0])
            XCTAssertTrue(indexed.rootPathIndexes[1] === repeatedIndexed.rootPathIndexes[1])
            let repeatedDiagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            XCTAssertEqual(repeatedDiagnostics.roots, diagnostics.roots)

            let projectedRecordsOnly = await store.searchCatalogSnapshot(
                rootScope: .visibleWorkspace,
                requirement: .recordsOnly
            )
            XCTAssertTrue(projectedRecordsOnly.rootPathIndexes.isEmpty)
            XCTAssertEqual(projectedRecordsOnly.generation, indexed.generation)
            XCTAssertEqual(projectedRecordsOnly.files.map(\.id), indexed.files.map(\.id))
            let projectedDiagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            XCTAssertEqual(projectedDiagnostics.roots, diagnostics.roots)

            let indexedAllLoaded = await store.searchCatalogSnapshot(rootScope: .allLoaded)
            let projectedAllLoaded = await store.searchCatalogSnapshot(
                rootScope: .allLoaded,
                requirement: .recordsOnly
            )
            XCTAssertEqual(indexedAllLoaded.rootPathIndexes.count, 2)
            XCTAssertTrue(projectedAllLoaded.rootPathIndexes.isEmpty)
            XCTAssertEqual(projectedAllLoaded.generation, indexedAllLoaded.generation)
            let finalDiagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            XCTAssertEqual(finalDiagnostics.roots, diagnostics.roots)
            XCTAssertEqual(recordsOnlyDiagnostics.shadowComparisonCount, 0)
            XCTAssertEqual(finalDiagnostics.shadowComparisonCount, 0)
            XCTAssertEqual(finalDiagnostics.shadowMismatchCount, 0)
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
            let recoveredSnapshot = await store.searchCatalogSnapshot(
                rootScope: .visibleWorkspace,
                requirement: .recordsOnly
            )
            XCTAssertEqual(recoveredSnapshot, backstopSnapshot)
            XCTAssertTrue(recoveredSnapshot.rootPathIndexes.isEmpty)

            diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            rootDiagnostics = try XCTUnwrap(diagnostics.roots.first { $0.rootID == root.id })
            XCTAssertNotNil(rootDiagnostics.publishedTopologyGeneration)
            XCTAssertEqual(rootDiagnostics.liveTopologyGenerations.count, 1)
            XCTAssertTrue(rootDiagnostics.retainedTopologyGenerations.isEmpty)
            XCTAssertEqual(rootDiagnostics.buildCount, cap + 1)
            XCTAssertEqual(rootDiagnostics.pathIndexBuildCount, 2)
            XCTAssertEqual(rootDiagnostics.backstopCount, 1)
            XCTAssertEqual(diagnostics.shadowComparisonCount, cap + 1)
            XCTAssertEqual(diagnostics.shadowMismatchCount, 0)

            let indexedRecovery = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertEqual(indexedRecovery.rootPathIndexes.count, 1)
            let indexedDiagnostics = try await diagnosticsForRoot(
                rootID: root.id,
                in: store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            )
            XCTAssertEqual(indexedDiagnostics.buildCount, rootDiagnostics.buildCount)
            XCTAssertEqual(indexedDiagnostics.pathIndexBuildCount, rootDiagnostics.pathIndexBuildCount)
        }

        func testContiguousCanonicalBatchesPatchSingleFileAndFolderMutations() async throws {
            assertExplicitBinaryFileOrderContract()

            let containerURL = try makeTemporaryRoot(name: "ShardDeltaPatch")
            let rootURL = containerURL.appendingPathComponent("Nested", isDirectory: true)
            let initialRelativePaths = [
                "A.swift",
                "E\u{301}-Decomposed.swift",
                "File-10.swift",
                "File-2.swift",
                "Prefix",
                "Prefix-long",
                "Seed.swift",
                "a.swift",
                "É-Precomposed.swift",
                "Ω.swift",
                "中.swift"
            ]
            try write("absolute", to: containerURL.appendingPathComponent("Absolute.swift"))
            for relativePath in initialRelativePaths {
                try write(relativePath, to: rootURL.appendingPathComponent(relativePath))
            }

            let store = makeStore()
            let parentRoot = try await loadStoppedRoot(in: store, path: containerURL.path)
            let root = try await loadStoppedRoot(in: store, path: rootURL.path)
            let initialSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            let initialFolderCount = initialSnapshot.diagnostics.folderCount
            let expectedDiskRelativePaths = [
                "A.swift",
                "E\u{301}-Decomposed.swift",
                "E\u{301}-Precomposed.swift",
                "File-10.swift",
                "File-2.swift",
                "Prefix",
                "Prefix-long",
                "Seed.swift",
                "Ω.swift",
                "中.swift"
            ]
            let nestedPrefix = rootURL.standardizedFileURL.path + "/"
            let absolutePath = containerURL
                .appendingPathComponent("Absolute.swift")
                .standardizedFileURL.path
            let expectedInitialFullPaths = [absolutePath]
                + expectedDiskRelativePaths.flatMap { relativePath in
                    Array(repeating: nestedPrefix + relativePath, count: 2)
                }
            assertCatalogFileOrderAndAlignment(initialSnapshot, expectedFullPaths: expectedInitialFullPaths)
            XCTAssertEqual(
                initialSnapshot.files
                    .filter { $0.rootID == root.id }
                    .map(\.standardizedRelativePath),
                expectedDiskRelativePaths
            )
            XCTAssertEqual(initialSnapshot.roots.map(\.id), [parentRoot.id, root.id])

            let initialPrefixService = WorkspaceSearchService()
            await initialPrefixService.prepareIndex(from: initialSnapshot)
            let initialBlankPrefix = await initialPrefixService.search("", limit: 5)
            let expectedBlankPrefixPaths = Array(expectedInitialFullPaths.prefix(5))
            XCTAssertEqual(
                initialBlankPrefix.results.map(\.standardizedFullPath),
                expectedBlankPrefixPaths
            )

            let initialDiagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            let initialRootDiagnostics = try diagnosticsForRoot(rootID: root.id, in: initialDiagnostics)
            let initialParentDiagnostics = try diagnosticsForRoot(rootID: parentRoot.id, in: initialDiagnostics)
            let initialShadowComparisonCount = initialDiagnostics.shadowComparisonCount
            let lifetimeID = try await store.rootLifetimeIDForTesting(rootID: root.id)
            XCTAssertEqual(initialRootDiagnostics.lifetimeID, lifetimeID)
            XCTAssertEqual(initialRootDiagnostics.authoritativeRebuildCount, 1)
            XCTAssertEqual(initialRootDiagnostics.pathIndexBuildCount, 1)
            XCTAssertEqual(initialParentDiagnostics.authoritativeRebuildCount, 1)
            XCTAssertEqual(initialParentDiagnostics.pathIndexBuildCount, 1)
            assertFallbackInvariant(initialRootDiagnostics, expected: [:])

            let insertionPaths = [
                "0-Before.swift",
                "G-Middle.swift",
                "🧭-After.swift"
            ]
            let expectedNestedRelativeOrdersAfterPatch = [
                [
                    "0-Before.swift",
                    "A.swift",
                    "E\u{301}-Decomposed.swift",
                    "E\u{301}-Precomposed.swift",
                    "File-10.swift",
                    "File-2.swift",
                    "Prefix",
                    "Prefix-long",
                    "Seed.swift",
                    "Ω.swift",
                    "中.swift"
                ],
                [
                    "0-Before.swift",
                    "A.swift",
                    "E\u{301}-Decomposed.swift",
                    "E\u{301}-Precomposed.swift",
                    "File-10.swift",
                    "File-2.swift",
                    "G-Middle.swift",
                    "Prefix",
                    "Prefix-long",
                    "Seed.swift",
                    "Ω.swift",
                    "中.swift"
                ],
                [
                    "0-Before.swift",
                    "A.swift",
                    "E\u{301}-Decomposed.swift",
                    "E\u{301}-Precomposed.swift",
                    "File-10.swift",
                    "File-2.swift",
                    "G-Middle.swift",
                    "Prefix",
                    "Prefix-long",
                    "Seed.swift",
                    "Ω.swift",
                    "中.swift",
                    "🧭-After.swift"
                ]
            ]
            var snapshot = initialSnapshot
            for (index, relativePath) in insertionPaths.enumerated() {
                try write(relativePath, to: rootURL.appendingPathComponent(relativePath))
                await store.replayObservedFileSystemDeltas(
                    rootID: root.id,
                    deltas: [.fileAdded(relativePath)]
                )
                snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
                XCTAssertTrue(snapshot.files.contains {
                    $0.rootID == root.id && $0.standardizedRelativePath == relativePath
                })
                XCTAssertEqual(
                    snapshot.files
                        .filter { $0.rootID == root.id }
                        .map(\.standardizedRelativePath),
                    expectedNestedRelativeOrdersAfterPatch[index]
                )

                if index == 0 {
                    let afterFirstPatch = try await diagnosticsForRoot(
                        rootID: root.id,
                        in: store.storeWorkDiagnosticsSnapshot().rootCatalogShards
                    )
                    XCTAssertEqual(afterFirstPatch.patchCount, initialRootDiagnostics.patchCount + 1)
                    XCTAssertEqual(
                        afterFirstPatch.overlayPathIndexBuildCount,
                        initialRootDiagnostics.overlayPathIndexBuildCount + 1
                    )
                    XCTAssertEqual(
                        afterFirstPatch.authoritativeRebuildCount,
                        initialRootDiagnostics.authoritativeRebuildCount
                    )
                }
            }
            let expectedPatchedFullPaths = (
                [absolutePath]
                    + expectedDiskRelativePaths.flatMap { relativePath in
                        Array(repeating: nestedPrefix + relativePath, count: 2)
                    }
                    + insertionPaths.map { nestedPrefix + $0 }
            ).sorted {
                $0.utf8.lexicographicallyPrecedes($1.utf8)
            }
            assertCatalogFileOrderAndAlignment(snapshot, expectedFullPaths: expectedPatchedFullPaths)

            let patchedPrefixService = WorkspaceSearchService()
            await patchedPrefixService.prepareIndex(from: snapshot)
            let patchedBlankPrefix = await patchedPrefixService.search("", limit: 5)
            XCTAssertEqual(
                patchedBlankPrefix.results.map(\.standardizedFullPath),
                Array(snapshot.files.prefix(5).map(\.standardizedFullPath))
            )

            let addedURL = rootURL.appendingPathComponent("0-Before.swift")
            try write("modified", to: addedURL)
            await store.replayObservedFileSystemDeltas(
                rootID: root.id,
                deltas: [.fileModified("0-Before.swift", nil)]
            )

            try FileManager.default.removeItem(at: addedURL)
            await store.replayObservedFileSystemDeltas(
                rootID: root.id,
                deltas: [.fileRemoved("0-Before.swift")]
            )
            snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertFalse(snapshot.files.contains {
                $0.rootID == root.id && $0.standardizedRelativePath == "0-Before.swift"
            })

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
            assertCatalogFileOrderAndAlignment(
                initialSnapshot,
                expectedFullPaths: expectedInitialFullPaths
            )
            let retainedBlankPrefix = await initialPrefixService.search("", limit: 5)
            XCTAssertEqual(
                retainedBlankPrefix.results.map(\.standardizedFullPath),
                expectedBlankPrefixPaths
            )

            let diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            let rootDiagnostics = try diagnosticsForRoot(rootID: root.id, in: diagnostics)
            XCTAssertEqual(diagnostics.maxPatchLogicalMutationCount, 1)
            XCTAssertEqual(rootDiagnostics.patchCount, 8)
            XCTAssertEqual(rootDiagnostics.authoritativeRebuildCount, 1)
            XCTAssertEqual(rootDiagnostics.buildCount, 9)
            XCTAssertEqual(rootDiagnostics.pathIndexBuildCount, 1)
            XCTAssertEqual(rootDiagnostics.overlayPathIndexBuildCount, 5)
            XCTAssertEqual(rootDiagnostics.lastAppliedIndexGeneration, 8)
            XCTAssertFalse(rootDiagnostics.deltaStateDirty)
            assertFallbackInvariant(rootDiagnostics, expected: [:])
            XCTAssertNil(rootDiagnostics.fallbackReasonCounts[.shadowValidationMismatch])
            XCTAssertGreaterThan(diagnostics.shadowComparisonCount, initialShadowComparisonCount)
            XCTAssertEqual(diagnostics.shadowMismatchCount, 0)

            let recordsOnlyRootURL = try makeTemporaryRoot(name: "RecordsOnlyPatch")
            try write("seed", to: recordsOnlyRootURL.appendingPathComponent("Seed.swift"))
            let recordsOnlyStore = makeStore()
            let recordsOnlyRoot = try await loadStoppedRoot(in: recordsOnlyStore, path: recordsOnlyRootURL.path)
            let retainedRecordsOnly = await recordsOnlyStore.searchCatalogSnapshot(
                rootScope: .visibleWorkspace,
                requirement: .recordsOnly
            )
            XCTAssertTrue(retainedRecordsOnly.rootPathIndexes.isEmpty)
            let recordsOnlyBeforePatch = try await diagnosticsForRoot(
                rootID: recordsOnlyRoot.id,
                in: recordsOnlyStore.storeWorkDiagnosticsSnapshot().rootCatalogShards
            )
            XCTAssertEqual(recordsOnlyBeforePatch.authoritativeRebuildCount, 1)
            XCTAssertEqual(recordsOnlyBeforePatch.pathIndexBuildCount, 0)
            XCTAssertEqual(recordsOnlyBeforePatch.overlayPathIndexBuildCount, 0)

            let addedRelativePath = "RecordsOnlyAdded.swift"
            try write("added", to: recordsOnlyRootURL.appendingPathComponent(addedRelativePath))
            await recordsOnlyStore.replayObservedFileSystemDeltas(
                rootID: recordsOnlyRoot.id,
                deltas: [.fileAdded(addedRelativePath)]
            )
            let patchedRecordsOnly = await recordsOnlyStore.searchCatalogSnapshot(
                rootScope: .visibleWorkspace,
                requirement: .recordsOnly
            )
            XCTAssertTrue(patchedRecordsOnly.rootPathIndexes.isEmpty)
            XCTAssertFalse(retainedRecordsOnly.files.contains { $0.standardizedRelativePath == addedRelativePath })
            XCTAssertTrue(patchedRecordsOnly.files.contains { $0.standardizedRelativePath == addedRelativePath })
            XCTAssertEqual(patchedRecordsOnly.files.map(\.id), patchedRecordsOnly.entries.map(\.id))
            let recordsOnlyAfterPatch = try await diagnosticsForRoot(
                rootID: recordsOnlyRoot.id,
                in: recordsOnlyStore.storeWorkDiagnosticsSnapshot().rootCatalogShards
            )
            XCTAssertEqual(recordsOnlyAfterPatch.patchCount, recordsOnlyBeforePatch.patchCount + 1)
            XCTAssertEqual(recordsOnlyAfterPatch.authoritativeRebuildCount, 1)
            XCTAssertEqual(recordsOnlyAfterPatch.pathIndexBuildCount, 0)
            XCTAssertEqual(recordsOnlyAfterPatch.overlayPathIndexBuildCount, 0)

            let promoted = await recordsOnlyStore.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertEqual(promoted.rootPathIndexes.count, 1)
            let promotionDiagnostics = try await diagnosticsForRoot(
                rootID: recordsOnlyRoot.id,
                in: recordsOnlyStore.storeWorkDiagnosticsSnapshot().rootCatalogShards
            )
            XCTAssertEqual(promotionDiagnostics.patchCount, recordsOnlyAfterPatch.patchCount)
            XCTAssertEqual(promotionDiagnostics.authoritativeRebuildCount, 1)
            XCTAssertEqual(promotionDiagnostics.pathIndexBuildCount, 1)
            XCTAssertEqual(promotionDiagnostics.overlayPathIndexBuildCount, 0)
            let promotedService = WorkspaceSearchService()
            await promotedService.prepareIndex(from: promoted)
            let promotedResult = await promotedService.search("RecordsOnlyAdded", limit: 5)
            XCTAssertEqual(promotedResult.results.map(\.standardizedRelativePath), [addedRelativePath])

            let repeatedPromotion = await recordsOnlyStore.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertTrue(promoted.rootPathIndexes[0] === repeatedPromotion.rootPathIndexes[0])
            let repeatedPromotionDiagnostics = try await diagnosticsForRoot(
                rootID: recordsOnlyRoot.id,
                in: recordsOnlyStore.storeWorkDiagnosticsSnapshot().rootCatalogShards
            )
            XCTAssertEqual(repeatedPromotionDiagnostics, promotionDiagnostics)
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
            await store.advanceRootCatalogTopologyGenerationForTesting(rootID: root.id)
            await store.applyAppliedIndexEventToRootCatalogShardForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 2
            ))

            let diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            let rootDiagnostics = try diagnosticsForRoot(rootID: root.id, in: diagnostics)
            XCTAssertEqual(rootDiagnostics.patchCount, 0)
            XCTAssertEqual(rootDiagnostics.authoritativeRebuildCount, 7)
            XCTAssertEqual(rootDiagnostics.pathIndexBuildCount, 7)
            XCTAssertEqual(rootDiagnostics.overlayPathIndexBuildCount, 0)
            assertFallbackInvariant(rootDiagnostics, expected: [
                .generationGap: 3,
                .fullResync: 1,
                .unsafeOrAmbiguousBatch: 1,
                .patchApplicationBackstop: 1
            ])
            XCTAssertEqual(rootDiagnostics.lastAppliedIndexGeneration, 2)
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
            XCTAssertEqual(rootADiagnostics.pathIndexBuildCount, 2)
            XCTAssertEqual(rootADiagnostics.overlayPathIndexBuildCount, 0)
            assertFallbackInvariant(rootADiagnostics, expected: [.patchThresholdExceeded: 1])
            XCTAssertEqual(rootBDiagnostics.buildCount, 1)
            XCTAssertEqual(rootBDiagnostics.authoritativeRebuildCount, 1)
            XCTAssertEqual(rootBDiagnostics.patchCount, 0)
            assertFallbackInvariant(rootBDiagnostics, expected: [:])
            XCTAssertEqual(diagnostics.shadowMismatchCount, 0)
        }

        func testRetentionBackstopMarksDirtyAndNextCanonicalBatchRecoversAuthoritatively() async throws {
            let rootURL = try makeTemporaryRoot(name: "ShardDirtyRecovery")
            try write("seed", to: rootURL.appendingPathComponent("Seed.swift"))

            let store = makeStore()
            let root = try await loadStoppedRoot(in: store, path: rootURL.path)
            let initialSnapshot = await store.searchCatalogSnapshot(
                rootScope: .visibleWorkspace,
                requirement: .recordsOnly
            )
            XCTAssertTrue(initialSnapshot.rootPathIndexes.isEmpty)
            var retainedSnapshots = [initialSnapshot]
            let cap = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards.liveGenerationCapPerRoot

            for generation in 1 ..< cap {
                let relativePath = "Retained-\(generation).swift"
                try write("retained", to: rootURL.appendingPathComponent(relativePath))
                await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileAdded(relativePath)])
                await retainedSnapshots.append(store.searchCatalogSnapshot(
                    rootScope: .visibleWorkspace,
                    requirement: .recordsOnly
                ))
            }

            try write("backstop", to: rootURL.appendingPathComponent("Backstop.swift"))
            await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileAdded("Backstop.swift")])
            var diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            var rootDiagnostics = try diagnosticsForRoot(rootID: root.id, in: diagnostics)
            XCTAssertNil(rootDiagnostics.publishedTopologyGeneration)
            XCTAssertTrue(rootDiagnostics.deltaStateDirty)
            assertFallbackInvariant(rootDiagnostics, expected: [.retentionBoundary: 1])
            XCTAssertEqual(rootDiagnostics.backstopCount, 1)

            retainedSnapshots.removeAll(keepingCapacity: false)
            try write("recovered", to: rootURL.appendingPathComponent("Recovered.swift"))
            await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileAdded("Recovered.swift")])
            let recoveredSnapshot = await store.searchCatalogSnapshot(
                rootScope: .visibleWorkspace,
                requirement: .recordsOnly
            )
            XCTAssertTrue(recoveredSnapshot.rootPathIndexes.isEmpty)
            XCTAssertTrue(recoveredSnapshot.files.contains { $0.standardizedRelativePath == "Backstop.swift" })
            XCTAssertTrue(recoveredSnapshot.files.contains { $0.standardizedRelativePath == "Recovered.swift" })

            diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            rootDiagnostics = try diagnosticsForRoot(rootID: root.id, in: diagnostics)
            XCTAssertFalse(rootDiagnostics.deltaStateDirty)
            assertFallbackInvariant(rootDiagnostics, expected: [.retentionBoundary: 2])
            XCTAssertEqual(rootDiagnostics.authoritativeRebuildCount, 2)
            XCTAssertEqual(rootDiagnostics.pathIndexBuildCount, 0)
            XCTAssertEqual(rootDiagnostics.overlayPathIndexBuildCount, 0)
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

            await store.recordRootCatalogShardFallbackForTesting(
                rootID: originalRoot.id,
                lifetimeID: originalLifetimeID,
                reason: .fullResync
            )
            var diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            let originalDiagnostics = try diagnosticsForRoot(rootID: originalRoot.id, in: diagnostics)
            assertFallbackInvariant(originalDiagnostics, expected: [.fullResync: 1])

            await store.unloadRoot(id: originalRoot.id)
            diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            let unloadedDiagnostics = try diagnosticsForRoot(rootID: originalRoot.id, in: diagnostics)
            XCTAssertEqual(unloadedDiagnostics.lifetimeID, originalLifetimeID)
            XCTAssertNil(unloadedDiagnostics.publishedTopologyGeneration)
            assertFallbackInvariant(unloadedDiagnostics, expected: [.fullResync: 1])

            let reusedLifetimeID = UUID()
            await store.recordRootCatalogShardFallbackForTesting(
                rootID: originalRoot.id,
                lifetimeID: reusedLifetimeID,
                reason: .generationGap
            )
            await store.recordRootCatalogShardFallbackForTesting(
                rootID: originalRoot.id,
                lifetimeID: reusedLifetimeID,
                reason: .patchApplicationBackstop
            )
            diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            let reusedLifetimeDiagnostics = try diagnosticsForRoot(rootID: originalRoot.id, in: diagnostics)
            XCTAssertEqual(reusedLifetimeDiagnostics.lifetimeID, reusedLifetimeID)
            assertFallbackInvariant(reusedLifetimeDiagnostics, expected: [
                .generationGap: 1,
                .patchApplicationBackstop: 1
            ])
            XCTAssertNil(reusedLifetimeDiagnostics.fallbackReasonCounts[.fullResync])

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

        private func assertExplicitBinaryFileOrderContract(
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let pathByID: [UUID: String] = [
                UUID(uuidString: "00000000-0000-0000-0000-000000000010")!: "/root/Prefix-long",
                UUID(uuidString: "00000000-0000-0000-0000-000000000009")!: "/root/Prefix",
                UUID(uuidString: "00000000-0000-0000-0000-000000000008")!: "/root/É.swift",
                UUID(uuidString: "00000000-0000-0000-0000-000000000007")!: "/root/E\u{301}.swift",
                UUID(uuidString: "00000000-0000-0000-0000-000000000006")!: "/root/a.swift",
                UUID(uuidString: "00000000-0000-0000-0000-000000000005")!: "/root/A.swift",
                UUID(uuidString: "00000000-0000-0000-0000-000000000004")!: "/root/Ω.swift",
                UUID(uuidString: "00000000-0000-0000-0000-000000000003")!: "/root/中.swift",
                UUID(uuidString: "00000000-0000-0000-0000-000000000002")!: "/root/É.swift"
            ]
            let expectedIDs = [
                UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000007")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000009")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000008")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
            ]
            XCTAssertEqual(Set(pathByID.keys), Set(expectedIDs), file: file, line: line)
            for (lhsID, rhsID) in zip(expectedIDs, expectedIDs.dropFirst()) {
                let lhsPath = pathByID[lhsID]!
                let rhsPath = pathByID[rhsID]!
                let ordered = lhsPath.utf8.elementsEqual(rhsPath.utf8)
                    ? lhsID.uuidString.utf8.lexicographicallyPrecedes(rhsID.uuidString.utf8)
                    : lhsPath.utf8.lexicographicallyPrecedes(rhsPath.utf8)
                XCTAssertTrue(ordered, "\(lhsID) should precede \(rhsID)", file: file, line: line)
            }
            XCTAssertEqual("/root/É.swift", "/root/E\u{301}.swift")
            XCTAssertNotEqual(
                Array("/root/É.swift".utf8),
                Array("/root/E\u{301}.swift".utf8)
            )
        }

        private func assertCatalogFileOrderAndAlignment(
            _ snapshot: WorkspaceSearchCatalogSnapshot,
            expectedFullPaths: [String],
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertEqual(
                snapshot.files.map(\.standardizedFullPath),
                expectedFullPaths,
                file: file,
                line: line
            )
            XCTAssertEqual(snapshot.files.count, snapshot.entries.count, file: file, line: line)
            for (record, entry) in zip(snapshot.files, snapshot.entries) {
                XCTAssertEqual(record.id, entry.id, file: file, line: line)
                XCTAssertEqual(
                    record.standardizedFullPath,
                    entry.standardizedFullPath,
                    file: file,
                    line: line
                )
            }
            for (lhs, rhs) in zip(snapshot.files, snapshot.files.dropFirst()) {
                let ordered = lhs.standardizedFullPath.utf8.elementsEqual(
                    rhs.standardizedFullPath.utf8
                )
                    ? lhs.id.uuidString.utf8.lexicographicallyPrecedes(rhs.id.uuidString.utf8)
                    : lhs.standardizedFullPath.utf8.lexicographicallyPrecedes(
                        rhs.standardizedFullPath.utf8
                    )
                XCTAssertTrue(ordered, file: file, line: line)
            }
        }

        private func makeStore() -> WorkspaceFileContextStore {
            let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: true)
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

        private func assertFallbackInvariant(
            _ diagnostics: WorkspaceFileContextStore.RootCatalogShardGenerationDebugSnapshot,
            expected: [WorkspaceFileContextStore.RootCatalogShardFallbackReason: Int],
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertEqual(diagnostics.fallbackReasonCounts, expected, file: file, line: line)
            XCTAssertEqual(
                diagnostics.fallbackCount,
                diagnostics.fallbackReasonCounts.values.reduce(0, +),
                file: file,
                line: line
            )
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
