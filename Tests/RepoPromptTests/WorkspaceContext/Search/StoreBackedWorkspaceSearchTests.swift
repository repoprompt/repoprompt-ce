import CoreServices
@testable import RepoPrompt
import XCTest

final class StoreBackedWorkspaceSearchTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        #if DEBUG
            EditFlowPerf.resetDebugCaptureForTesting()
        #endif
        for url in temporaryRoots {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

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

        let trimmed = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope("  \(fileURL.path)\n", rootScope: .visibleWorkspace)
        XCTAssertEqual(trimmed?.file?.standardizedFullPath, fileURL.path)

        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let tildePath = "~/" + String(homeFileURL.path.dropFirst(homePath.count + 1))
        let tilde = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(tildePath, rootScope: .visibleWorkspace)
        XCTAssertEqual(tilde?.file?.standardizedFullPath, homeFileURL.path)

        let relative = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope("Sources/Visible.swift", rootScope: .visibleWorkspace)
        let alias = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope("\(record.name)/Sources/Visible.swift", rootScope: .visibleWorkspace)
        let nul = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope("/tmp/blocked\0.swift", rootScope: .visibleWorkspace)
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

        let file = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(fileURL.path, rootScope: .visibleWorkspace)
        XCTAssertEqual(file?.file?.rootID, nestedRecord.id)
        XCTAssertEqual(file?.file?.standardizedFullPath, fileURL.path)

        let folder = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(folderURL.path, rootScope: .visibleWorkspace)
        XCTAssertEqual(folder?.folder?.rootID, nestedRecord.id)
        XCTAssertEqual(folder?.folder?.standardizedRelativePath, "Sources/Nested")

        let rootFolder = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(nested.path, rootScope: .visibleWorkspace)
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
        let readable = await readableService.resolveReadableFile(ignoredURL.path, profile: .mcpRead, rootScope: .visibleWorkspace)
        guard case .workspace = readable else {
            return XCTFail("Expected ignored absolute read fallback to materialize a managed-only record")
        }

        let searchHit = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(ignoredURL.path, rootScope: .visibleWorkspace)
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

        let visibleGitDataHit = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(gitDataFile.path, rootScope: .visibleWorkspace)
        XCTAssertNil(visibleGitDataHit)
        let gitDataHit = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(gitDataFile.path, rootScope: .visibleWorkspacePlusGitData)
        XCTAssertEqual(gitDataHit?.file?.rootID, gitDataRecord.id)

        let visibleWorktreeHit = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(worktreeFile.path, rootScope: .visibleWorkspace)
        XCTAssertNil(visibleWorktreeHit)
        let sessionScope = WorkspaceLookupRootScope.sessionBoundWorkspace(
            canonicalRootPaths: [],
            physicalRootPaths: [worktreeRoot.path]
        )
        let worktreeHit = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(worktreeFile.path, rootScope: sessionScope)
        XCTAssertEqual(worktreeHit?.file?.rootID, worktreeRecord.id)
        let sessionLogicalHit = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(logicalFile.path, rootScope: sessionScope)
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

        let alias = try await searchSwiftFiles(paths: ["\(recordA.name)/Sources/RelativeOnly.swift"], store: store)
        XCTAssertEqual(alias.paths, [relativeFile.path])

        let shortcutMiss = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(absoluteMissingPath, rootScope: .visibleWorkspace)
        XCTAssertNil(shortcutMiss)
        let absoluteMiss = try await searchSwiftFiles(paths: [absoluteMissingPath], store: store)
        XCTAssertEqual(absoluteMiss.scopedFileCount, 0)
        XCTAssertNil(absoluteMiss.paths)

        let wildcard = try await searchSwiftFiles(paths: ["*/Sources/WildcardOnly.swift"], store: store)
        XCTAssertEqual(wildcard.paths, [wildcardFile.path])
    }

    func testBroadSearchAdmissionClassifierGatesOnlyUnscopedContentCapableModes() {
        XCTAssertEqual(StoreBackedWorkspaceSearch.broadSearchAdmissionClass(pattern: "needle", mode: .content, paths: nil), .unscopedContent)
        XCTAssertEqual(StoreBackedWorkspaceSearch.broadSearchAdmissionClass(pattern: "needle", mode: .both, paths: []), .unscopedBoth)
        XCTAssertEqual(StoreBackedWorkspaceSearch.broadSearchAdmissionClass(pattern: "needle", mode: .auto, paths: ["  ", "\n"]), .unscopedBoth)
        XCTAssertTrue(StoreBackedWorkspaceSearch.requiresBroadSearchAdmission(pattern: "needle", mode: .content, paths: nil))
        XCTAssertFalse(StoreBackedWorkspaceSearch.requiresBroadSearchAdmission(pattern: "*.swift", mode: .path, paths: nil))
        XCTAssertFalse(StoreBackedWorkspaceSearch.requiresBroadSearchAdmission(pattern: "*.swift", mode: .auto, paths: nil))
        XCTAssertFalse(StoreBackedWorkspaceSearch.requiresBroadSearchAdmission(pattern: "needle", mode: .content, paths: ["Sources/A.swift"]))
    }

    func testMutationAfterCatalogCrawlBeforeWatcherStartIsVisibleToFreshSearch() async throws {
        let root = try makeTemporaryRoot(name: "WatcherStartupReplay")
        try write("let seed = true\n", to: root.appendingPathComponent("Seed.swift"))
        let lateFileURL = root.appendingPathComponent("Late.swift")
        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)

        try write("let startupGapNeedle = true\n", to: lateFileURL)
        try await store.startWatchingRoot(id: record.id)

        let result = try await searchContent(pattern: "startupGapNeedle", store: store)
        XCTAssertEqual(result.matches?.map(\.filePath), [lateFileURL.path])
        await store.stopWatchingRoot(id: record.id)
    }

    #if DEBUG
        func testDebugColdScopedPathSearchPhaseAccounting() async throws {
            let visibleRoot = try makeTemporaryRoot(name: "DebugPhaseVisible")
            try write("visible", to: visibleRoot.appendingPathComponent("Visible.swift"))
            let worktreeRoot = try makeTemporaryRoot(name: "DebugPhaseWorktree")
            let expectedRelativePath = "Sources/00-FirstPhaseNeedle.swift"
            let expected = worktreeRoot.appendingPathComponent(expectedRelativePath)
            for index in 1 ... 4 {
                try write(
                    "other \(index)",
                    to: worktreeRoot.appendingPathComponent(String(format: "Sources/%02d-Other.swift", index))
                )
            }

            let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
            _ = try await store.loadRoot(path: visibleRoot.path)
            let worktreeRecord = try await store.loadRoot(path: worktreeRoot.path, kind: .sessionWorktree)
            let scope = WorkspaceLookupRootScope.sessionBoundWorkspace(
                canonicalRootPaths: [],
                physicalRootPaths: [worktreeRoot.standardizedFileURL.path]
            )

            try write("needle", to: expected)
            await store.replayObservedFileSystemDeltas(
                rootID: worktreeRecord.id,
                deltas: [.fileAdded(expectedRelativePath)]
            )
            let beforeFirstPathDiagnostics = await store.storeWorkDiagnosticsSnapshot()
            XCTAssertEqual(beforeFirstPathDiagnostics.catalogRebuild.rebuildCount, 0)
            let beforeFirstPathShard = try XCTUnwrap(
                beforeFirstPathDiagnostics.rootCatalogShards.roots.first { $0.rootID == worktreeRecord.id }
            )
            XCTAssertNil(beforeFirstPathShard.publishedTopologyGeneration)
            XCTAssertEqual(beforeFirstPathShard.buildCount, 0)
            XCTAssertEqual(beforeFirstPathShard.authoritativeRebuildCount, 0)
            XCTAssertEqual(beforeFirstPathShard.pathIndexBuildCount, 0)
            XCTAssertEqual(beforeFirstPathShard.overlayPathIndexBuildCount, 0)

            let collector = WorkspaceFileSearchPhaseCollector()
            let started = DispatchTime.now()
            let result = try await WorkspaceFileSearchDebugContext.$collector.withValue(collector) {
                try await StoreBackedWorkspaceSearch.search(
                    pattern: "FirstPhaseNeedle",
                    mode: .path,
                    maxPaths: 1,
                    rootScope: scope,
                    store: store,
                    workspaceManager: nil
                )
            }
            let finished = DispatchTime.now()
            let phases = collector.snapshot(
                readySearchNanoseconds: finished.uptimeNanoseconds - started.uptimeNanoseconds
            )

            XCTAssertEqual(result.paths, [expected.path])
            XCTAssertEqual(phases.status, .completed)
            XCTAssertGreaterThanOrEqual(phases.topLevel.residualOrchestrationMicroseconds, 0)
            XCTAssertGreaterThanOrEqual(phases.fileActor.residualMicroseconds, 0)

            XCTAssertEqual(phases.catalog.sortInvocationCount, 1)
            XCTAssertEqual(phases.catalog.sortFileInputCount, 5)
            XCTAssertEqual(phases.catalog.sortFolderInputCount, 2)
            XCTAssertGreaterThanOrEqual(phases.catalog.fileSortMicroseconds, 0)
            XCTAssertGreaterThanOrEqual(phases.catalog.folderSortMicroseconds, 0)
            XCTAssertGreaterThanOrEqual(phases.catalog.sortResidualMicroseconds, 0)
            let nestedSortChildren = phases.catalog.fileSortMicroseconds
                + phases.catalog.folderSortMicroseconds
                + phases.catalog.sortResidualMicroseconds
            XCTAssertLessThanOrEqual(nestedSortChildren, phases.catalog.sortMicroseconds + 1000)
            XCTAssertLessThanOrEqual(abs(phases.catalog.sortReconciliationDeltaMicroseconds), 1000)

            let catalogChildren = phases.catalog.filterMicroseconds
                + phases.catalog.sortMicroseconds
                + phases.catalog.materializationMicroseconds
                + phases.catalog.pathIndexKeyMicroseconds
                + phases.catalog.pathIndexConstructionMicroseconds
                + phases.catalog.compositionCacheResidualMicroseconds
            XCTAssertLessThanOrEqual(catalogChildren, phases.catalog.totalMicroseconds + 1000)

            let actorChildren = phases.fileActor.descriptorMicroseconds
                + phases.fileActor.filterMicroseconds
                + phases.fileActor.sortAndInputMicroseconds
                + phases.fileActor.batchConstructionAndInitialEnqueueMicroseconds
                + phases.fileActor.deterministicDrainToHitMicroseconds
                + phases.fileActor.postHitResidualMicroseconds
            XCTAssertLessThanOrEqual(
                actorChildren,
                phases.topLevel.fileSearchActorMicroseconds + 1000
            )

            let reconciledReadyMicroseconds = Int64(phases.topLevel.readinessFreshnessPreambleMicroseconds)
                + Int64(phases.topLevel.firstCatalogAccessMicroseconds)
                + Int64(phases.topLevel.fileSearchActorMicroseconds)
                + phases.topLevel.residualOrchestrationMicroseconds
            XCTAssertLessThanOrEqual(
                abs(reconciledReadyMicroseconds - Int64(phases.topLevel.readySearchMicroseconds)),
                1000
            )
            XCTAssertLessThanOrEqual(abs(phases.topLevel.reconciliationDeltaMicroseconds), 1000)

            XCTAssertEqual(phases.counts.sourceFileCount, 5)
            XCTAssertEqual(phases.counts.descriptorsBuilt, 5)
            XCTAssertEqual(phases.counts.admittedFileCount, 5)
            XCTAssertEqual(phases.counts.sortInputCount, 5)
            XCTAssertEqual(phases.counts.totalBatchCount, 1)
            XCTAssertEqual(phases.counts.initiallyEnqueuedBatchCount, 1)
            XCTAssertEqual(phases.counts.deterministicallyDrainedBatchCount, 1)
            XCTAssertEqual(phases.counts.entriesExaminedByDrainedBatches, 5)
            XCTAssertEqual(phases.counts.returnedHitPrefixLength, 1)

            XCTAssertEqual(phases.catalog.rebuildCount, 1)
            XCTAssertEqual(phases.catalog.rootCount, 1)
            XCTAssertEqual(phases.catalog.fileCount, 5)
            XCTAssertEqual(phases.catalog.pathIndexKeyMicroseconds, 0)
            XCTAssertEqual(phases.catalog.pathIndexConstructionMicroseconds, 0)
            let recordsOnlySnapshot = await store.searchCatalogSnapshot(
                rootScope: scope,
                requirement: .recordsOnly
            )
            XCTAssertTrue(recordsOnlySnapshot.rootPathIndexes.isEmpty)
            let coldDiagnostics = await store.storeWorkDiagnosticsSnapshot()
            XCTAssertEqual(coldDiagnostics.catalogRebuild.rebuildCount, 1)
            let worktreeShard = try XCTUnwrap(
                coldDiagnostics.rootCatalogShards.roots.first { $0.rootID == worktreeRecord.id }
            )
            XCTAssertEqual(worktreeShard.authoritativeRebuildCount, 1)
            XCTAssertEqual(worktreeShard.pathIndexBuildCount, 0)
            XCTAssertEqual(worktreeShard.overlayPathIndexBuildCount, 0)

            let warm = try await StoreBackedWorkspaceSearch.search(
                pattern: "FirstPhaseNeedle",
                mode: .path,
                maxPaths: 1,
                rootScope: scope,
                store: store,
                workspaceManager: nil
            )
            XCTAssertEqual(warm.paths, [expected.path])
            var warmDiagnostics = await store.storeWorkDiagnosticsSnapshot()
            XCTAssertEqual(warmDiagnostics.catalogRebuild.rebuildCount, 1)
            XCTAssertEqual(warmDiagnostics.catalogRebuild.sortInvocationCount, 1)
            XCTAssertEqual(warmDiagnostics.catalogRebuild.sortFileInputCount, 5)
            XCTAssertEqual(warmDiagnostics.catalogRebuild.sortFolderInputCount, 2)
            XCTAssertLessThanOrEqual(
                abs(warmDiagnostics.catalogRebuild.sortReconciliationDeltaMicroseconds),
                1000
            )
            var warmShard = try XCTUnwrap(
                warmDiagnostics.rootCatalogShards.roots.first { $0.rootID == worktreeRecord.id }
            )
            XCTAssertEqual(warmShard.buildCount, worktreeShard.buildCount)
            XCTAssertEqual(warmShard.pathIndexBuildCount, 0)

            let auto = try await StoreBackedWorkspaceSearch.search(
                pattern: "FirstPhaseNeedle",
                mode: .auto,
                maxPaths: 1,
                rootScope: scope,
                store: store,
                workspaceManager: nil
            )
            XCTAssertEqual(auto.paths, [expected.path])
            warmDiagnostics = await store.storeWorkDiagnosticsSnapshot()
            warmShard = try XCTUnwrap(
                warmDiagnostics.rootCatalogShards.roots.first { $0.rootID == worktreeRecord.id }
            )
            XCTAssertEqual(warmShard.authoritativeRebuildCount, 1)
            XCTAssertEqual(warmShard.buildCount, worktreeShard.buildCount + 1)
            XCTAssertEqual(warmShard.pathIndexBuildCount, 1)
            XCTAssertEqual(warmShard.overlayPathIndexBuildCount, 0)

            _ = try await StoreBackedWorkspaceSearch.search(
                pattern: "FirstPhaseNeedle",
                mode: .both,
                maxPaths: 1,
                maxMatches: 1,
                rootScope: scope,
                store: store,
                workspaceManager: nil
            )
            let bothDiagnostics = await store.storeWorkDiagnosticsSnapshot()
            let bothShard = try XCTUnwrap(
                bothDiagnostics.rootCatalogShards.roots.first { $0.rootID == worktreeRecord.id }
            )
            XCTAssertEqual(bothShard.buildCount, warmShard.buildCount)
            XCTAssertEqual(bothShard.pathIndexBuildCount, 1)
            XCTAssertEqual(bothShard.overlayPathIndexBuildCount, 0)

            let probeContainer = try makeTemporaryRoot(name: "DebugCatalogSortProbe")
            let nestedRoot = probeContainer.appendingPathComponent("Nested")
            let probePaths = [
                "a.swift",
                "É-Precomposed.swift",
                "Prefix-long",
                "File-2.swift",
                "E\u{301}-Decomposed.swift",
                "A.swift",
                "Prefix",
                "中.swift",
                "File-10.swift",
                "Ω.swift",
                "relative/Child.swift"
            ]
            for relativePath in probePaths {
                try write(
                    relativePath,
                    to: nestedRoot.appendingPathComponent(relativePath)
                )
            }
            try write("absolute", to: probeContainer.appendingPathComponent("Absolute.swift"))

            let probeStore = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
            let parentRecord = try await probeStore.loadRoot(path: probeContainer.path)
            let nestedRecord = try await probeStore.loadRoot(path: nestedRoot.path, kind: .sessionWorktree)
            let probeScope = WorkspaceLookupRootScope.sessionBoundWorkspace(
                canonicalRootPaths: [probeContainer.standardizedFileURL.path],
                physicalRootPaths: [nestedRoot.standardizedFileURL.path]
            )
            let expectedFiles = await probeStore.files(inRoot: parentRecord.id)
                + probeStore.files(inRoot: nestedRecord.id)
            let nestedPrefix = nestedRoot.standardizedFileURL.path + "/"
            let expectedNestedPathOrder = [
                "E\u{301}-Decomposed.swift",
                "E\u{301}-Precomposed.swift",
                "File-10.swift",
                "File-2.swift",
                "Prefix",
                "Prefix-long",
                "a.swift",
                "relative/Child.swift",
                "Ω.swift",
                "中.swift"
            ]
            let absolutePath = probeContainer
                .appendingPathComponent("Absolute.swift")
                .standardizedFileURL.path
            let expectedUniquePaths = [absolutePath]
                + expectedNestedPathOrder.map { nestedPrefix + $0 }
            let expectedOrderedPaths = [absolutePath]
                + expectedNestedPathOrder.flatMap { relativePath in
                    Array(repeating: nestedPrefix + relativePath, count: 2)
                }
            let expectedOrder = expectedUniquePaths.flatMap { expectedPath in
                expectedFiles
                    .filter {
                        $0.standardizedFullPath.utf8.elementsEqual(expectedPath.utf8)
                    }
                    .sorted {
                        $0.id.uuidString.utf8.lexicographicallyPrecedes($1.id.uuidString.utf8)
                    }
            }
            XCTAssertEqual(expectedOrder.map(\.standardizedFullPath), expectedOrderedPaths)
            let expectedFolderCount = await probeStore.folders(inRoot: parentRecord.id).count
                + probeStore.folders(inRoot: nestedRecord.id).count
            let singleRootScope = WorkspaceLookupRootScope.sessionBoundWorkspace(
                canonicalRootPaths: [],
                physicalRootPaths: [nestedRoot.standardizedFileURL.path]
            )
            let expectedSingleRootFiles = await probeStore.files(inRoot: nestedRecord.id)
            let expectedSingleRootOrder = expectedSingleRootFiles.sorted { lhs, rhs in
                if lhs.standardizedRelativePath.utf8.elementsEqual(rhs.standardizedRelativePath.utf8) {
                    return lhs.id.uuidString.utf8.lexicographicallyPrecedes(rhs.id.uuidString.utf8)
                }
                return lhs.standardizedRelativePath.utf8.lexicographicallyPrecedes(
                    rhs.standardizedRelativePath.utf8
                )
            }
            XCTAssertEqual(
                expectedSingleRootOrder.map(\.standardizedRelativePath),
                expectedNestedPathOrder
            )
            let expectedSingleRootFolderCount = await probeStore.folders(inRoot: nestedRecord.id).count
            let workBeforeProbe = await probeStore.storeWorkDiagnosticsSnapshot()
            let catalogCacheCountBeforeProbe = await probeStore.searchCatalogSnapshotCacheCountForTesting()
            let staticCacheCountBeforeProbe = await probeStore.staticPathMatchSnapshotCacheCountForTesting()
            let sessionGenerationBeforeProbe = await probeStore.sessionCatalogGenerationForTesting(scope: probeScope)
            let singleRootGenerationBeforeProbe = await probeStore
                .sessionCatalogGenerationForTesting(scope: singleRootScope)

            let singleRootProbe = await probeStore.debugAuthoritativeCatalogSortProbe(
                rootScope: singleRootScope
            )
            XCTAssertEqual(singleRootProbe.status, .completed)
            XCTAssertEqual(singleRootProbe.sourceFileCount, expectedSingleRootFiles.count)
            XCTAssertEqual(singleRootProbe.sourceFolderCount, expectedSingleRootFolderCount)
            XCTAssertEqual(singleRootProbe.samples.count, 3)
            XCTAssertTrue(singleRootProbe.directAndProjectedOrdersMatch)
            XCTAssertNil(singleRootProbe.firstMismatchIndex)
            XCTAssertEqual(singleRootProbe.orderedFileIDs, expectedSingleRootOrder.map(\.id))
            XCTAssertTrue(singleRootProbe.samples.allSatisfy(\.directAndProjectedOrdersMatch))
            XCTAssertTrue(singleRootProbe.samples.allSatisfy { $0.firstMismatchIndex == nil })
            XCTAssertTrue(singleRootProbe.samples.allSatisfy { $0.directFileComparatorCalls > 0 })
            XCTAssertTrue(singleRootProbe.samples.allSatisfy { $0.projectedFileComparatorCalls > 0 })
            XCTAssertTrue(singleRootProbe.samples.allSatisfy { $0.folderComparatorCalls > 0 })
            XCTAssertEqual(Set(singleRootProbe.samples.map(\.directFileComparatorCalls)).count, 1)
            XCTAssertEqual(Set(singleRootProbe.samples.map(\.projectedFileComparatorCalls)).count, 1)
            XCTAssertEqual(Set(singleRootProbe.samples.map(\.folderComparatorCalls)).count, 1)

            let probe = await probeStore.debugAuthoritativeCatalogSortProbe(rootScope: probeScope)
            XCTAssertEqual(probe.status, .completed)
            XCTAssertEqual(probe.sourceFileCount, expectedFiles.count)
            XCTAssertEqual(probe.sourceFolderCount, expectedFolderCount)
            XCTAssertEqual(probe.samples.count, 3)
            XCTAssertTrue(probe.directAndProjectedOrdersMatch)
            XCTAssertNil(probe.firstMismatchIndex)
            XCTAssertEqual(probe.orderedFileIDs, expectedOrder.map(\.id))
            XCTAssertTrue(probe.samples.allSatisfy(\.directAndProjectedOrdersMatch))
            XCTAssertTrue(probe.samples.allSatisfy { $0.firstMismatchIndex == nil })
            XCTAssertTrue(probe.samples.allSatisfy { $0.directFileComparatorCalls > 0 })
            XCTAssertTrue(probe.samples.allSatisfy { $0.projectedFileComparatorCalls > 0 })
            XCTAssertTrue(probe.samples.allSatisfy { $0.folderComparatorCalls > 0 })
            XCTAssertEqual(Set(probe.samples.map(\.directFileComparatorCalls)).count, 1)
            XCTAssertEqual(Set(probe.samples.map(\.projectedFileComparatorCalls)).count, 1)
            XCTAssertEqual(Set(probe.samples.map(\.folderComparatorCalls)).count, 1)

            let duplicateGroups = Dictionary(
                grouping: expectedFiles,
                by: { Array($0.standardizedFullPath.utf8) }
            )
            .values
            .filter { $0.count > 1 }
            XCTAssertFalse(duplicateGroups.isEmpty)
            for group in duplicateGroups {
                let orderedIDs = probe.orderedFileIDs.filter { id in group.contains { $0.id == id } }
                XCTAssertEqual(
                    orderedIDs,
                    group.map(\.id).sorted {
                        $0.uuidString.utf8.lexicographicallyPrecedes($1.uuidString.utf8)
                    }
                )
            }

            let unavailableScope = WorkspaceLookupRootScope.sessionBoundWorkspace(
                canonicalRootPaths: [],
                physicalRootPaths: [probeContainer.appendingPathComponent("Missing").path]
            )
            let unavailable = await probeStore.debugAuthoritativeCatalogSortProbe(rootScope: unavailableScope)
            XCTAssertEqual(unavailable.status, .unavailable)
            XCTAssertTrue(unavailable.samples.isEmpty)

            let workAfterProbe = await probeStore.storeWorkDiagnosticsSnapshot()
            let catalogCacheCountAfterProbe = await probeStore.searchCatalogSnapshotCacheCountForTesting()
            let staticCacheCountAfterProbe = await probeStore.staticPathMatchSnapshotCacheCountForTesting()
            let sessionGenerationAfterProbe = await probeStore.sessionCatalogGenerationForTesting(scope: probeScope)
            let singleRootGenerationAfterProbe = await probeStore
                .sessionCatalogGenerationForTesting(scope: singleRootScope)
            XCTAssertEqual(workAfterProbe, workBeforeProbe)
            XCTAssertEqual(catalogCacheCountAfterProbe, catalogCacheCountBeforeProbe)
            XCTAssertEqual(staticCacheCountAfterProbe, staticCacheCountBeforeProbe)
            XCTAssertEqual(sessionGenerationAfterProbe, sessionGenerationBeforeProbe)
            XCTAssertEqual(singleRootGenerationAfterProbe, singleRootGenerationBeforeProbe)
        }

        func testWatcherQualifiedWarmSearchSkipsPerFileMetadataValidation() async throws {
            let root = try makeTemporaryRoot(name: "WatcherQualifiedWarmSearch")
            let fileCount = 48
            for index in 0 ..< fileCount {
                try write(
                    "let watcherQualifiedNeedle\(index) = true\n",
                    to: root.appendingPathComponent(String(format: "Sources/File-%03d.swift", index))
                )
            }
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            let attachedPublisherIngress = try await store
                .attachPublisherIngressWithoutStartingWatcherForTesting(rootID: record.id)
            XCTAssertTrue(attachedPublisherIngress)
            try await store.setCachedSearchContentWatcherActiveOverrideForTesting(rootID: record.id, true)
            addTeardownBlock {
                try? await store.setCachedSearchContentWatcherActiveOverrideForTesting(rootID: record.id, nil)
                await store.stopWatchingRoot(id: record.id)
            }

            let cold = try await searchContent(pattern: "watcherQualifiedNeedle", store: store)
            let cacheAfterCold = await store.searchDecodedContentCacheSnapshotForTesting()
            try await store.resetSearchContentFingerprintRequestCountForTesting(rootID: record.id)
            _ = startedCapture(label: "watcher-qualified-warm-search", maxSamples: 2000)

            let warm = try await searchContent(pattern: "watcherQualifiedNeedle", store: store)
            let capture = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let fingerprintRequestCount = try await store.searchContentFingerprintRequestCountForTesting(rootID: record.id)
            let cacheAfterWarm = await store.searchDecodedContentCacheSnapshotForTesting()
            let freshnessRows = capture.stages.filter {
                $0.stageName == String(describing: EditFlowPerf.Stage.Search.contentFreshnessValidation)
            }

            XCTAssertEqual(cold.matches?.count, fileCount)
            XCTAssertEqual(warm.matches, cold.matches)
            XCTAssertEqual(fingerprintRequestCount, 0)
            XCTAssertEqual(cacheAfterWarm.loadCount, cacheAfterCold.loadCount)
            XCTAssertEqual(cacheAfterWarm.acceptedLoadCount, cacheAfterCold.acceptedLoadCount)
            XCTAssertFalse(freshnessRows.isEmpty)
            XCTAssertTrue(freshnessRows.allSatisfy {
                $0.sanitizedDimensions.contains("freshnessPolicy=cachedMetadata")
            })
            XCTAssertEqual(
                capture.stages
                    .filter { $0.stageName == String(describing: EditFlowPerf.Stage.FileSystem.contentReadWorkerBody) }
                    .reduce(0) { $0 + $1.sampleCount },
                0
            )
        }

        func testAbsoluteScopedWarmSearchIgnoresUnrelatedUnqualifiedRoot() async throws {
            let qualifiedRoot = try makeTemporaryRoot(name: "ScopedWarmQualified")
            let unqualifiedRoot = try makeTemporaryRoot(name: "ScopedWarmUnqualified")
            let qualifiedFile = qualifiedRoot.appendingPathComponent("Qualified.swift")
            try write("let scopedWarmNeedle = true\n", to: qualifiedFile)
            try write("let unrelatedNeedle = true\n", to: unqualifiedRoot.appendingPathComponent("Unqualified.swift"))

            let store = WorkspaceFileContextStore()
            let qualifiedRecord = try await store.loadRoot(path: qualifiedRoot.path)
            let unqualifiedRecord = try await store.loadRoot(path: unqualifiedRoot.path)
            let attachedPublisherIngress = try await store
                .attachPublisherIngressWithoutStartingWatcherForTesting(rootID: qualifiedRecord.id)
            XCTAssertTrue(attachedPublisherIngress)
            try await store.setCachedSearchContentWatcherActiveOverrideForTesting(
                rootID: qualifiedRecord.id,
                true
            )
            addTeardownBlock {
                try? await store.setCachedSearchContentWatcherActiveOverrideForTesting(
                    rootID: qualifiedRecord.id,
                    nil
                )
                await store.stopWatchingRoot(id: qualifiedRecord.id)
            }

            let cold = try await searchContent(
                pattern: "scopedWarmNeedle",
                paths: [qualifiedFile.path],
                store: store
            )
            try await store.resetSearchContentFingerprintRequestCountForTesting(rootID: qualifiedRecord.id)
            try await store.resetSearchContentFingerprintRequestCountForTesting(rootID: unqualifiedRecord.id)

            let warm = try await searchContent(
                pattern: "scopedWarmNeedle",
                paths: [qualifiedFile.path],
                store: store
            )
            let qualifiedFingerprintRequests = try await store
                .searchContentFingerprintRequestCountForTesting(rootID: qualifiedRecord.id)
            let unqualifiedFingerprintRequests = try await store
                .searchContentFingerprintRequestCountForTesting(rootID: unqualifiedRecord.id)

            XCTAssertEqual(cold.matches?.map(\.filePath), [qualifiedFile.path])
            XCTAssertEqual(warm.matches, cold.matches)
            XCTAssertEqual(qualifiedFingerprintRequests, 0)
            XCTAssertEqual(unqualifiedFingerprintRequests, 0)
        }

        func testWatcherQualifiedWarmSearchReloadsAppliedModificationBeforeMatching() async throws {
            let root = try makeTemporaryRoot(name: "WatcherQualifiedModification")
            let fileURL = root.appendingPathComponent("A.swift")
            try write("let oldWatcherNeedle = true\n", to: fileURL)
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            let attachedPublisherIngress = try await store
                .attachPublisherIngressWithoutStartingWatcherForTesting(rootID: record.id)
            XCTAssertTrue(attachedPublisherIngress)
            try await store.setCachedSearchContentWatcherActiveOverrideForTesting(rootID: record.id, true)
            addTeardownBlock {
                try? await store.setCachedSearchContentWatcherActiveOverrideForTesting(rootID: record.id, nil)
                await store.stopWatchingRoot(id: record.id)
            }

            let cold = try await searchContent(pattern: "oldWatcherNeedle", store: store)
            XCTAssertEqual(cold.matches?.map(\.filePath), [fileURL.path])
            try await store.resetSearchContentFingerprintRequestCountForTesting(rootID: record.id)

            try write("let newWatcherNeedle = true\n", to: fileURL)
            try await store.publishSyntheticFileSystemDeltasForTesting(
                rootID: record.id,
                deltas: [.fileModified("A.swift", Date())]
            )
            let refreshed = try await searchContent(pattern: "newWatcherNeedle", store: store)
            let old = try await searchContent(pattern: "oldWatcherNeedle", store: store)
            let fingerprintRequestCount = try await store.searchContentFingerprintRequestCountForTesting(rootID: record.id)

            XCTAssertEqual(refreshed.matches?.map(\.filePath), [fileURL.path])
            XCTAssertTrue((old.matches ?? []).isEmpty)
            XCTAssertEqual(fingerprintRequestCount, 1)
        }

        func testOverflowCompletionInvalidatesRetainedWarmContentBeforeWatermarkReuse() async throws {
            let root = try makeTemporaryRoot(name: "OverflowRetainedContent")
            let fileURL = root.appendingPathComponent("A.swift")
            try write("let oldOverflowNeedle = true\n", to: fileURL)
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            let attachedPublisherIngress = try await store
                .attachPublisherIngressWithoutStartingWatcherForTesting(rootID: record.id)
            XCTAssertTrue(attachedPublisherIngress)
            try await store.setCachedSearchContentWatcherActiveOverrideForTesting(rootID: record.id, true)
            addTeardownBlock {
                try? await store.setCachedSearchContentWatcherActiveOverrideForTesting(rootID: record.id, nil)
                await store.stopWatchingRoot(id: record.id)
            }

            let cold = try await searchContent(pattern: "oldOverflowNeedle", store: store)
            XCTAssertEqual(cold.matches?.map(\.filePath), [fileURL.path])
            try await store.resetSearchContentFingerprintRequestCountForTesting(rootID: record.id)
            let warm = try await searchContent(pattern: "oldOverflowNeedle", store: store)
            let warmFingerprintRequestCount = try await store
                .searchContentFingerprintRequestCountForTesting(rootID: record.id)
            XCTAssertEqual(warm.matches?.map(\.filePath), [fileURL.path])
            XCTAssertEqual(warmFingerprintRequestCount, 0)

            try write("let newOverflowNeedle = true\n", to: fileURL)
            let optionalService = await store.fileSystemServiceForTesting(rootID: record.id)
            let service = try XCTUnwrap(optionalService)
            let eventID: FSEventStreamEventId = 1
            let optionalAccepted = await service.acceptWatcherPayloadForTesting(
                [(
                    absolutePath: fileURL.path,
                    flags: FSEventStreamEventFlags(
                        kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile
                    ),
                    eventId: eventID
                )],
                scheduleDrain: false
            )
            let accepted = try XCTUnwrap(optionalAccepted)
            await service.collapsePendingEventsToRootRescan(
                upTo: eventID,
                acceptedHighWatermark: accepted
            )
            _ = await store.awaitAppliedIngress(rootScope: .visibleWorkspace)

            try await store.resetSearchContentFingerprintRequestCountForTesting(rootID: record.id)
            let refreshed = try await searchContent(pattern: "newOverflowNeedle", store: store)
            let stale = try await searchContent(pattern: "oldOverflowNeedle", store: store)
            let refreshedFingerprintRequestCount = try await store
                .searchContentFingerprintRequestCountForTesting(rootID: record.id)
            XCTAssertEqual(refreshed.matches?.map(\.filePath), [fileURL.path])
            XCTAssertTrue((stale.matches ?? []).isEmpty)
            XCTAssertEqual(refreshedFingerprintRequestCount, 1)

            try await store.resetSearchContentFingerprintRequestCountForTesting(rootID: record.id)
            let rewarmed = try await searchContent(pattern: "newOverflowNeedle", store: store)
            let rewarmedFingerprintRequestCount = try await store
                .searchContentFingerprintRequestCountForTesting(rootID: record.id)
            XCTAssertEqual(rewarmed.matches?.map(\.filePath), [fileURL.path])
            XCTAssertEqual(rewarmedFingerprintRequestCount, 0)
        }

        func testWatcherAcceptedAfterBarrierForcesStrictMetadataFallback() async throws {
            let root = try makeTemporaryRoot(name: "WatcherFreshnessGap")
            let fileURL = root.appendingPathComponent("A.swift")
            try write("let watcherGapNeedle = true\n", to: fileURL)
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            let attachedPublisherIngress = try await store
                .attachPublisherIngressWithoutStartingWatcherForTesting(rootID: record.id)
            XCTAssertTrue(attachedPublisherIngress)
            try await store.setCachedSearchContentWatcherActiveOverrideForTesting(rootID: record.id, true)
            addTeardownBlock {
                _ = await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
                try? await store.setCachedSearchContentWatcherActiveOverrideForTesting(rootID: record.id, nil)
                await store.stopWatchingRoot(id: record.id)
            }

            let samples = await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
            let accepted = try await store.acceptWatcherPayloadForTesting(
                rootID: record.id,
                events: [(
                    absolutePath: fileURL.path,
                    flags: FSEventStreamEventFlags(
                        kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile
                    ),
                    eventId: 1
                )],
                scheduleDrain: false
            )
            XCTAssertNotNil(accepted)

            let policy = await store.contentSearchFreshnessPolicy(
                rootScope: .visibleWorkspace,
                appliedIngressSamples: samples
            )
            guard case .validateDiskMetadata = policy else {
                return XCTFail("Accepted watcher ingress beyond the applied barrier must retain strict metadata validation")
            }
        }

        func testPublisherIngressAcceptedAfterBarrierForcesStrictMetadataFallback() async throws {
            let root = try makeTemporaryRoot(name: "PublisherFreshnessGap")
            let fileURL = root.appendingPathComponent("A.swift")
            try write("let publisherGapNeedle = true\n", to: fileURL)
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            let attachedPublisherIngress = try await store
                .attachPublisherIngressWithoutStartingWatcherForTesting(rootID: record.id)
            XCTAssertTrue(attachedPublisherIngress)
            try await store.setCachedSearchContentWatcherActiveOverrideForTesting(rootID: record.id, true)

            let sinkGate = AsyncGate()
            await store.setWatcherSinkWillApplyHandler { observedRootID in
                guard observedRootID == record.id else { return }
                await sinkGate.markStartedAndWaitForRelease()
            }
            addTeardownBlock {
                await sinkGate.release()
                await store.setWatcherSinkWillApplyHandler(nil)
                try? await store.setCachedSearchContentWatcherActiveOverrideForTesting(rootID: record.id, nil)
                await store.stopWatchingRoot(id: record.id)
            }

            let samples = await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
            try await store.publishSyntheticFileSystemDeltasForTesting(
                rootID: record.id,
                deltas: [.fileModified("A.swift", Date())]
            )
            await sinkGate.waitUntilStarted()

            let policy = await store.contentSearchFreshnessPolicy(
                rootScope: .visibleWorkspace,
                appliedIngressSamples: samples
            )
            guard case .validateDiskMetadata = policy else {
                return XCTFail("Publisher ingress beyond the applied barrier must retain strict metadata validation")
            }
        }

        func testSameStoreBroadLaneRunsOneQueuesOneAndRejectsThirdWhilePreservingResults() async throws {
            let root = try makeTemporaryRoot(name: "BroadLaneOneActiveOneQueued")
            let alphaURL = root.appendingPathComponent("A.swift")
            let betaURL = root.appendingPathComponent("B.swift")
            let gammaURL = root.appendingPathComponent("C.swift")
            try write("let alphaNeedle = true\n", to: alphaURL)
            try write("let betaNeedle = true\n", to: betaURL)
            try write("let gammaNeedle = true\n", to: gammaURL)
            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: root.path)
            await configureSingleLeaseSearchLane(store)
            let gate = AsyncGate()
            let freshnessCaptureCount = AsyncCounter()
            await store.setAppliedIngressDidCaptureWatermarksHandler { _ in
                _ = await freshnessCaptureCount.incrementAndValue()
            }
            await store.setSearchLanePermitAcquiredHandlerForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            addTeardownBlock {
                await gate.release()
                await store.setAppliedIngressDidCaptureWatermarksHandler(nil)
                await store.setSearchLanePermitAcquiredHandlerForTesting(nil)
            }

            let first = Task { try await self.searchContent(pattern: "alphaNeedle", store: store) }
            await assertAsyncTrue(gate.waitUntilStartedCount(1))
            let second = Task { try await self.searchContent(pattern: "betaNeedle", store: store) }
            await assertAsyncTrue(waitForAdmissionWaiterCount(1, store: store))
            let thirdCompleted = AsyncSignal()
            let third = Task { () -> Result<SearchResults, Error> in
                do {
                    let result = try await self.searchContent(pattern: "gammaNeedle", store: store)
                    await thirdCompleted.mark()
                    return .success(result)
                } catch {
                    await thirdCompleted.mark()
                    return .failure(error)
                }
            }
            let thirdDidComplete = await thirdCompleted.waitUntilMarked()
            if !thirdDidComplete {
                third.cancel()
                second.cancel()
                first.cancel()
                await gate.release()
                _ = await third.value
                _ = try? await second.value
                _ = try? await first.value
                XCTFail("Timed out waiting for third broad search overflow rejection")
                return
            }
            switch await third.value {
            case .success:
                XCTFail("Expected third broad search to be rejected")
            case let .failure(error):
                guard let admissionError = error as? StoreBackedWorkspaceSearchAdmissionError else {
                    return XCTFail("Expected broad-search admission error, got \(error)")
                }
                XCTAssertEqual(admissionError, .queueFull(scope: .perStore, retryAfterMilliseconds: 1000))
            }
            let heldFreshnessCaptureCount = await freshnessCaptureCount.currentValue()
            XCTAssertEqual(
                heldFreshnessCaptureCount,
                0,
                "No broad search may enter freshness while the active permit hook is held; the waiter and rejected overflow must remain bounded at admission"
            )

            let heldSnapshot = await store.searchLaneSnapshotForTesting()
            XCTAssertEqual(heldSnapshot.activePermitCount, 1)
            XCTAssertEqual(heldSnapshot.waiterCount, 1)
            await gate.release()

            let firstPaths = try await first.value.matches?.map(\.filePath)
            let secondPaths = try await second.value.matches?.map(\.filePath)
            XCTAssertEqual(firstPaths, [alphaURL.path])
            XCTAssertEqual(secondPaths, [betaURL.path])
            let finalSnapshot = await store.searchLaneSnapshotForTesting()
            XCTAssertTrue(finalSnapshot.isIdle)
            XCTAssertEqual(finalSnapshot.maximumActivePermitCount, 1)
            XCTAssertEqual(finalSnapshot.maximumWaiterCount, 1)
            await store.setAppliedIngressDidCaptureWatermarksHandler(nil)
        }

        func testConcurrentBroadSearchBurstSharesOneIngressFreshnessFlight() async throws {
            let configuration = StoreBackedWorkspaceSearchLane.Configuration.production
            let burstSize = configuration.maxActiveLeases
            let root = try makeTemporaryRoot(name: "BroadLaneBurstFreshness")
            for index in 0 ..< burstSize {
                try write("let burstNeedle\(index) = true\n", to: root.appendingPathComponent("Burst\(index).swift"))
            }
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)
            let sinkGate = AsyncGate()
            let freshnessCaptureCount = AsyncCounter()
            await store.setWatcherSinkWillApplyHandler { observedRootID in
                guard observedRootID == record.id else { return }
                await sinkGate.markStartedAndWaitForRelease()
            }
            await store.setAppliedIngressDidCaptureWatermarksHandler { _ in
                _ = await freshnessCaptureCount.incrementAndValue()
            }
            addTeardownBlock {
                await sinkGate.release()
                await store.setWatcherSinkWillApplyHandler(nil)
                await store.setAppliedIngressDidCaptureWatermarksHandler(nil)
                await store.stopWatchingRoot(id: record.id)
            }

            try write("let burstHoldNeedle = true\n", to: root.appendingPathComponent("Hold.swift"))
            try await store.publishSyntheticFileSystemDeltasForTesting(
                rootID: record.id,
                deltas: [.fileAdded("Hold.swift")]
            )
            await sinkGate.waitUntilStarted()
            let statsBeforeBurst = await store.scopedIngressBarrierStatsForTesting(rootID: record.id)

            // The production lane admits the entire burst concurrently, so every member
            // captures the same watermark cut and shares the single blocked barrier flight.
            let burst = (0 ..< burstSize).map { index in
                Task { try await self.searchContent(pattern: "burstNeedle\(index)", store: store) }
            }
            await assertAsyncTrue(freshnessCaptureCount.waitUntilValue(atLeast: burstSize))
            let heldStats = await store.scopedIngressBarrierStatsForTesting(rootID: record.id)
            XCTAssertEqual(heldStats.launchCount - statsBeforeBurst.launchCount, 1)
            XCTAssertEqual(heldStats.joinCount - statsBeforeBurst.joinCount, burstSize - 1)
            let heldLane = await store.searchLaneSnapshotForTesting()
            XCTAssertEqual(heldLane.activePermitCount, burstSize)
            XCTAssertEqual(heldLane.waiterCount, 0)
            XCTAssertEqual(heldLane.overloadCount, 0)

            await sinkGate.release()
            for (index, task) in burst.enumerated() {
                let result = try await task.value
                XCTAssertEqual(result.matches?.map(\.filePath), [root.appendingPathComponent("Burst\(index).swift").path])
            }
            let settledLane = await store.searchLaneSnapshotForTesting()
            XCTAssertTrue(settledLane.isIdle)
            XCTAssertEqual(settledLane.maximumActivePermitCount, burstSize)
        }

        func testQueuedBroadContentSearchCancellationRemovesWaiterWithoutEnteringFreshness() async throws {
            let root = try makeTemporaryRoot(name: "BroadLaneCancellation")
            try write("let holdNeedle = true\nlet laterNeedle = true\n", to: root.appendingPathComponent("A.swift"))
            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: root.path)
            await configureSingleLeaseSearchLane(store)
            let gate = AsyncGate()
            let freshnessCaptureCount = AsyncCounter()
            await store.setAppliedIngressDidCaptureWatermarksHandler { _ in
                _ = await freshnessCaptureCount.incrementAndValue()
            }
            await store.setSearchLanePermitAcquiredHandlerForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            addTeardownBlock {
                await gate.release()
                await store.setAppliedIngressDidCaptureWatermarksHandler(nil)
                await store.setSearchLanePermitAcquiredHandlerForTesting(nil)
            }

            let first = Task { try await self.searchContent(pattern: "holdNeedle", store: store) }
            await assertAsyncTrue(gate.waitUntilStartedCount(1))
            let cancellationCompleted = AsyncSignal()
            let cancelled = Task { () -> Result<SearchResults, Error> in
                do {
                    let result = try await self.searchContent(pattern: "cancelledNeedle", store: store)
                    await cancellationCompleted.mark()
                    return .success(result)
                } catch {
                    await cancellationCompleted.mark()
                    return .failure(error)
                }
            }
            await assertAsyncTrue(waitForAdmissionWaiterCount(1, store: store))
            let queuedFreshnessCaptureCount = await freshnessCaptureCount.currentValue()
            XCTAssertEqual(
                queuedFreshnessCaptureCount,
                0,
                "A queued broad search must not capture an applied-ingress target before admission"
            )
            cancelled.cancel()
            let cancellationDidComplete = await cancellationCompleted.waitUntilMarked()
            if !cancellationDidComplete {
                first.cancel()
                await gate.release()
                _ = await cancelled.value
                _ = try? await first.value
                XCTFail("Timed out waiting for queued broad search cancellation")
                return
            }
            switch await cancelled.value {
            case .success:
                XCTFail("Expected queued broad search cancellation")
            case let .failure(error):
                XCTAssertTrue(error is CancellationError)
            }
            await assertAsyncTrue(waitForAdmissionWaiterCount(0, store: store))
            let cancelledFreshnessCaptureCount = await freshnessCaptureCount.currentValue()
            XCTAssertEqual(
                cancelledFreshnessCaptureCount,
                0,
                "Cancelling the queued search must not start freshness work"
            )
            let later = Task { try await self.searchContent(pattern: "laterNeedle", store: store) }
            await assertAsyncTrue(waitForAdmissionWaiterCount(1, store: store))

            await gate.release()
            _ = try await first.value
            let laterMatchCount = try await later.value.matches?.count
            XCTAssertEqual(laterMatchCount, 1)
            let finalSnapshot = await store.searchLaneSnapshotForTesting()
            XCTAssertTrue(finalSnapshot.isIdle)
            XCTAssertEqual(finalSnapshot.queuedCancellationCount, 1)
            let finalFreshnessCaptureCount = await freshnessCaptureCount.currentValue()
            XCTAssertEqual(finalFreshnessCaptureCount, 2)
            await store.setAppliedIngressDidCaptureWatermarksHandler(nil)
        }

        func testPathScopedContentAndDifferentStoreSearchesBypassHeldBroadLane() async throws {
            let rootA = try makeTemporaryRoot(name: "BroadLaneBypassA")
            let rootB = try makeTemporaryRoot(name: "BroadLaneBypassB")
            let fileA = rootA.appendingPathComponent("A.swift")
            let fileB = rootB.appendingPathComponent("B.swift")
            try write("let holdNeedle = true\nlet scopedNeedle = true\n", to: fileA)
            try write("let peerNeedle = true\n", to: fileB)
            let storeA = WorkspaceFileContextStore()
            let storeB = WorkspaceFileContextStore()
            _ = try await storeA.loadRoot(path: rootA.path)
            _ = try await storeB.loadRoot(path: rootB.path)
            let gate = AsyncGate()
            await storeA.setSearchLanePermitAcquiredHandlerForTesting {
                await gate.markStartedAndWaitForRelease()
            }

            let held = Task { try await self.searchContent(pattern: "holdNeedle", store: storeA) }
            await assertAsyncTrue(gate.waitUntilStartedWithinTimeout())

            async let pathResult = searchPaths(pattern: "*.swift", store: storeA)
            async let scopedResult = searchContent(pattern: "scopedNeedle", paths: [fileA.path], store: storeA)
            async let peerResult = searchContent(pattern: "peerNeedle", store: storeB)
            let bypassResults = try await (pathResult, scopedResult, peerResult)
            XCTAssertEqual(bypassResults.0.paths, [fileA.path])
            XCTAssertEqual(bypassResults.1.matches?.map(\.filePath), [fileA.path])
            XCTAssertEqual(bypassResults.2.matches?.map(\.filePath), [fileB.path])

            await gate.release()
            _ = try await held.value
            let storeASnapshot = await storeA.searchLaneSnapshotForTesting()
            let storeBSnapshot = await storeB.searchLaneSnapshotForTesting()
            XCTAssertTrue(storeASnapshot.isIdle)
            XCTAssertTrue(storeBSnapshot.isIdle)
        }

        func testOrderedBatchWindowAdvancesOnlyWithTheDrainFrontier() {
            var window = OrderedSearchBatchWindow(batchCount: 8, maxEnqueueLead: 3)

            XCTAssertEqual(window.takeNextBatchToEnqueue(), 0)
            XCTAssertEqual(window.takeNextBatchToEnqueue(), 1)
            XCTAssertEqual(window.takeNextBatchToEnqueue(), 2)
            XCTAssertNil(window.takeNextBatchToEnqueue())
            XCTAssertEqual(window.enqueueLead, 3)

            window.advanceDrainFrontier()
            XCTAssertEqual(window.takeNextBatchToEnqueue(), 3)
            XCTAssertNil(window.takeNextBatchToEnqueue())
            XCTAssertEqual(window.enqueueLead, 3)

            window.advanceDrainFrontier()
            window.advanceDrainFrontier()
            XCTAssertEqual(window.takeNextBatchToEnqueue(), 4)
            XCTAssertEqual(window.takeNextBatchToEnqueue(), 5)
            XCTAssertNil(window.takeNextBatchToEnqueue())
            XCTAssertEqual(window.enqueueLead, 3)
        }

        func testContentScanBatchSizingUsesStableWorkerPolicy() {
            let cases: [(workerCount: Int, fileCount: Int, expectedBatchSize: Int)] = [
                (1, 0, 0),
                (1, 1, 1),
                (1, 24, 2),
                (1, 96, 3),
                (1, 384, 4),
                (1, 632, 4),
                (1, Int.max, 4),
                (8, 24, 2),
                (8, 96, 2),
                (8, 384, 4),
                (8, 632, 4),
                (14, 96, 2),
                (14, 384, 4),
                (14, 632, 4),
                (64, 384, 2),
                (64, 632, 2),
                (64, 4096, 4),
                (Int.max, Int.max, 2)
            ]

            for testCase in cases {
                XCTAssertEqual(
                    FileSearchActor.contentScanBatchSize(
                        fileCount: testCase.fileCount,
                        workerCount: testCase.workerCount
                    ),
                    testCase.expectedBatchSize,
                    "workers=\(testCase.workerCount), files=\(testCase.fileCount)"
                )
            }
        }

        #if DEBUG
            func testAdaptiveContentBatchingBoundsCappedScanWindow() async throws {
                let workerCount = max(4, ProcessInfo.processInfo.activeProcessorCount)
                let (scaledFileCount, overflowed) = workerCount.multipliedReportingOverflow(by: 8)
                XCTAssertFalse(overflowed)
                let fileCount = scaledFileCount + 1
                let root = try makeTemporaryRoot(name: "AdaptiveContentBatches")
                for index in (0 ..< fileCount).reversed() {
                    try write(
                        "needle\nneedle\n",
                        to: root.appendingPathComponent(String(format: "File-%06d.swift", index))
                    )
                }
                let store = WorkspaceFileContextStore()
                _ = try await store.loadRoot(path: root.path)
                _ = startedCapture(label: "adaptive-content-batch-window", maxSamples: 10000)

                let result = try await searchContent(
                    pattern: "needle",
                    maxMatches: 1,
                    store: store
                )
                let capture = EditFlowPerf.debugCaptureSnapshot(finish: true)
                let resolvedBatchSize = FileSearchActor.contentScanBatchSize(
                    fileCount: fileCount,
                    workerCount: workerCount
                )
                let adaptiveScannedWindow = min(fileCount, workerCount * resolvedBatchSize)
                let formerFixedScannedWindow = min(fileCount, workerCount * 16)
                XCTAssertLessThan(adaptiveScannedWindow, formerFixedScannedWindow)
                XCTAssertEqual(
                    result.matches?.map(\.filePath),
                    [root.appendingPathComponent("File-000000.swift").path]
                )
                XCTAssertEqual(result.matches?.map(\.lineNumber), [0])

                let totalRows = capture.stages.filter {
                    $0.stageName == String(describing: EditFlowPerf.Stage.Search.contentScanTotal)
                        && $0.sanitizedDimensions.contains("outcome=capped")
                }
                XCTAssertEqual(totalRows.count, 1)
                let totalRow = try XCTUnwrap(totalRows.first)
                XCTAssertEqual(dimensionInt("batchSize", in: totalRow.sanitizedDimensions), resolvedBatchSize)
                XCTAssertEqual(dimensionInt("workerCount", in: totalRow.sanitizedDimensions), workerCount)

                let batchRows = capture.stages.filter {
                    $0.stageName == String(describing: EditFlowPerf.Stage.Search.contentBatch)
                }
                let enqueuedBatchCount = batchRows.reduce(0) { $0 + $1.sampleCount }
                let scannedFileCount = try batchRows.reduce(into: 0) { count, row in
                    let batchScannedFileCount = try XCTUnwrap(
                        dimensionInt("scannedFileCount", in: row.sanitizedDimensions)
                    )
                    count += batchScannedFileCount * row.sampleCount
                }
                XCTAssertLessThanOrEqual(enqueuedBatchCount, workerCount)
                XCTAssertLessThanOrEqual(scannedFileCount, adaptiveScannedWindow)
                XCTAssertTrue(batchRows.allSatisfy {
                    dimensionInt("batchSize", in: $0.sanitizedDimensions) == resolvedBatchSize
                        && dimensionInt("workerCount", in: $0.sanitizedDimensions) == workerCount
                })
            }
        #endif

        func testMultiBatchPathSearchReturnsDeterministicCappedPrefix() async throws {
            let root = try makeTemporaryRoot(name: "OrderedPathBatches")
            let fileCount = 300
            for index in (0 ..< fileCount).reversed() {
                try write("path", to: root.appendingPathComponent(String(format: "File-%03d.swift", index)))
            }
            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: root.path)

            let result = try await StoreBackedWorkspaceSearch.search(
                pattern: "*.swift",
                mode: .path,
                isRegex: false,
                caseInsensitive: true,
                maxPaths: 25,
                maxMatches: 25,
                rootScope: .visibleWorkspace,
                store: store,
                workspaceManager: nil
            )
            let expected = (0 ..< 25).map {
                root.appendingPathComponent(String(format: "File-%03d.swift", $0)).path
            }
            XCTAssertEqual(result.paths, expected)
        }

        func testMultiBatchContentSearchPreservesCappedOrderAndExhaustiveCountOnly() async throws {
            let root = try makeTemporaryRoot(name: "OrderedContentBatches")
            let fileCount = 80
            for index in (0 ..< fileCount).reversed() {
                try write("needle\nneedle\n", to: root.appendingPathComponent(String(format: "File-%03d.swift", index)))
            }
            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: root.path)
            let capped = try await searchContent(
                pattern: "needle",
                maxMatches: 5,
                store: store
            )
            let repeatedCapped = try await searchContent(
                pattern: "needle",
                maxMatches: 5,
                store: store
            )
            let countOnly = try await searchContent(
                pattern: "needle",
                countOnly: true,
                store: store
            )

            let expectedPaths = [0, 0, 1, 1, 2].map {
                root.appendingPathComponent(String(format: "File-%03d.swift", $0)).path
            }
            XCTAssertEqual(capped.matches?.map(\.filePath), expectedPaths)
            XCTAssertEqual(capped.matches?.map(\.lineNumber), [0, 1, 0, 1, 0])
            XCTAssertEqual(repeatedCapped.matches, capped.matches)
            XCTAssertEqual(countOnly.totalCount, fileCount * 2)
            XCTAssertEqual(countOnly.contentFileCount, fileCount)
            XCTAssertEqual(countOnly.searchedFileCount, fileCount)
            XCTAssertTrue((countOnly.matches ?? []).isEmpty)
        }

        func testCancelledScopedContentSearchDrainsCacheFlight() async throws {
            let root = try makeTemporaryRoot(name: "CancelledContentSearch")
            let fileURL = root.appendingPathComponent("A.swift")
            try write("needle\n", to: fileURL)
            let store = WorkspaceFileContextStore()
            let rootRecord = try await store.loadRoot(path: root.path)
            let gate = AsyncGate()
            try await store.setSearchContentReadChunkHandlerForTesting(rootID: rootRecord.id) { path in
                guard path == "A.swift" else { return }
                await gate.markStartedAndWaitForRelease()
            }

            let task = Task {
                try await self.searchContent(
                    pattern: "needle",
                    paths: [fileURL.path],
                    store: store
                )
            }
            let started = await gate.waitUntilStartedWithinTimeout()
            XCTAssertTrue(started)
            task.cancel()
            await gate.release()
            do {
                _ = try await task.value
                XCTFail("Expected search cancellation")
            } catch is CancellationError {
                // Expected.
            }

            let cache = await waitForCacheIdle(store: store)
            XCTAssertEqual(cache.entryCount, 0)
            XCTAssertEqual(cache.activeFlightCount, 0)
            XCTAssertEqual(cache.waiterCount, 0)
            try await store.setSearchContentReadChunkHandlerForTesting(rootID: rootRecord.id, nil)
        }

        func testQueuedBroadContentSearchPreservesExhaustiveCountOnlyCompleteness() async throws {
            let root = try makeTemporaryRoot(name: "BroadLaneCorrectness")
            try write("needle\nneedle\n", to: root.appendingPathComponent("A.swift"))
            try write("needle\nneedle\n", to: root.appendingPathComponent("B.swift"))
            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: root.path)
            let baseline = try await searchContent(pattern: "needle", countOnly: true, store: store)
            await configureSingleLeaseSearchLane(store)

            let gate = AsyncGate()
            await store.setSearchLanePermitAcquiredHandlerForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            let held = Task { try await self.searchContent(pattern: "holdNeedle", store: store) }
            await assertAsyncTrue(gate.waitUntilStartedCount(1))
            let queued = Task { try await self.searchContent(pattern: "needle", countOnly: true, store: store) }
            await assertAsyncTrue(waitForAdmissionWaiterCount(1, store: store))
            await gate.release()

            _ = try await held.value
            let result = try await queued.value
            XCTAssertEqual(result.totalCount, baseline.totalCount)
            XCTAssertEqual(result.contentFileCount, baseline.contentFileCount)
            XCTAssertEqual(result.searchedFileCount, baseline.searchedFileCount)
            let laneSnapshot = await store.searchLaneSnapshotForTesting()
            XCTAssertTrue(laneSnapshot.isIdle)
        }

        func testStoreBackedSearchContentWorkerPermitTelemetryInheritsOriginatingCorrelation() async throws {
            let holdingRoot = try makeTemporaryRoot(name: "SearchWorkerCorrelationHolding")
            let searchRoot = try makeTemporaryRoot(name: "SearchWorkerCorrelationTarget")
            try write("let inheritedCorrelationNeedle = true\n", to: searchRoot.appendingPathComponent("Target.swift"))
            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: searchRoot.path)
            let holdingService = try await FileSystemService(
                path: holdingRoot.path,
                respectGitignore: false,
                respectRepoIgnore: false,
                respectCursorignore: false,
                skipSymlinks: true
            )
            let workerLimit = FileSystemService.contentReadWorkerLimitForTesting
            let enteredCount = AsyncCounter()
            let gate = AsyncGate()
            for index in 0 ..< workerLimit {
                try write("held-\(index)", to: holdingRoot.appendingPathComponent("Held-\(index).txt"))
            }
            await holdingService.setContentReadChunkHandlerForTesting { path in
                guard path.hasPrefix("Held-") else { return }
                _ = await enteredCount.incrementAndValue()
                await gate.markStartedAndWaitForRelease()
            }
            let heldReads = (0 ..< workerLimit).map { index in
                Task {
                    try await holdingService.loadContent(
                        ofRelativePath: "Held-\(index).txt",
                        workloadClass: .contentSearch
                    )
                }
            }
            let saturated = await enteredCount.waitUntilValue(atLeast: workerLimit)
            XCTAssertTrue(saturated)
            _ = startedCapture(label: "store-backed-search-worker-correlation", maxSamples: 100)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive())
            let searchTask = Task {
                try await EditFlowPerf.$currentLifecycleCorrelation.withValue(correlation) {
                    try await self.searchContent(
                        pattern: "inheritedCorrelationNeedle",
                        store: store
                    )
                }
            }
            let waitBegan = await waitForLifecycleEvent(
                "FileSystem.ContentReadWorkerPermitWaitBegan",
                correlationID: correlation.id
            )
            XCTAssertTrue(waitBegan)

            await gate.release()
            for task in heldReads {
                _ = try await task.value
            }
            let results = try await searchTask.value
            XCTAssertEqual(results.matches?.count, 1)
            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let workerEvents = snapshot.lifecycleEvents.filter {
                $0.correlationID == correlation.id.uuidString &&
                    $0.eventName.hasPrefix("FileSystem.ContentReadWorker")
            }
            XCTAssertEqual(workerEvents.map(\.eventName), [
                "FileSystem.ContentReadWorkerPermitWaitBegan",
                "FileSystem.ContentReadWorkerPermitAcquired",
                "FileSystem.ContentReadWorkerReturned"
            ])
            XCTAssertTrue(workerEvents.allSatisfy { $0.sanitizedDimensions.contains("workloadClass=contentSearch") })
            await holdingService.setContentReadChunkHandlerForTesting(nil)
        }

        func testStoreBackedSearchUsesRevisionLineIndexIdentityAndWarmContentSnapshot() async throws {
            let root = try makeTemporaryRoot(name: "StoreBackedRevisionIdentity")
            try write("let revisionIdentityToken = true\n", to: root.appendingPathComponent("A.swift"))
            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: root.path)
            _ = startedCapture(label: "store-backed-revision-identity", maxSamples: 200)
            let cold = try await searchContent(
                pattern: "revisionIdentityToken",
                store: store
            )
            let warm = try await searchContent(
                pattern: "revisionIdentityToken",
                store: store
            )
            let capture = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let lineIndexRows = capture.stages.filter {
                $0.stageName == String(describing: EditFlowPerf.Stage.Search.lineIndexLookup)
            }
            let cache = await store.searchDecodedContentCacheSnapshotForTesting()

            XCTAssertEqual(cold.matches?.count, 1)
            XCTAssertEqual(warm.matches, cold.matches)
            XCTAssertFalse(lineIndexRows.isEmpty)
            XCTAssertTrue(lineIndexRows.allSatisfy { $0.sanitizedDimensions.contains("scanKind=revision") })
            XCTAssertTrue(lineIndexRows.allSatisfy { !$0.sanitizedDimensions.contains("hash-fallback") })
            XCTAssertEqual(
                capture.stages
                    .filter { $0.stageName == String(describing: EditFlowPerf.Stage.FileSystem.contentReadWorkerPermitWait) }
                    .reduce(0) { $0 + $1.sampleCount },
                1,
                "The warm decoded-content hit must not enter filesystem read admission"
            )
            XCTAssertEqual(
                capture.stages
                    .filter { $0.stageName == String(describing: EditFlowPerf.Stage.FileSystem.contentReadWorkerBody) }
                    .reduce(0) { $0 + $1.sampleCount },
                1,
                "Only the cold miss should execute a disk-read worker body"
            )
            XCTAssertEqual(cache.loadCount, 1)
            XCTAssertGreaterThanOrEqual(cache.hitCount, 1)
            XCTAssertEqual(cache.latestRevision, 1)
        }

        func testExactPathKindIsResolvedAgainAfterFreshnessApplies() async throws {
            let root = try makeTemporaryRoot(name: "ExactPathKindTransition")
            let targetURL = root.appendingPathComponent("Target")
            try write("let oldFileValue = true\n", to: targetURL)

            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)
            let sinkGate = AsyncGate()
            let barrierCaptured = AsyncSignal()
            await store.setWatcherSinkWillApplyHandler { observedRootID in
                guard observedRootID == record.id else { return }
                await sinkGate.markStartedAndWaitForRelease()
            }
            await store.setAppliedIngressDidCaptureWatermarksHandler { _ in
                await barrierCaptured.mark()
            }
            addTeardownBlock {
                await sinkGate.release()
                await store.setWatcherSinkWillApplyHandler(nil)
                await store.setAppliedIngressDidCaptureWatermarksHandler(nil)
                await store.stopWatchingRoot(id: record.id)
            }

            try FileManager.default.removeItem(at: targetURL)
            let nestedURL = targetURL.appendingPathComponent("Nested.swift")
            try write("let refreshedKindNeedle = true\n", to: nestedURL)
            try await store.publishSyntheticFileSystemDeltasForTesting(
                rootID: record.id,
                deltas: [
                    .fileRemoved("Target"),
                    .folderAdded("Target"),
                    .fileAdded("Target/Nested.swift")
                ]
            )
            await sinkGate.waitUntilStarted()

            let searchTask = Task {
                try await self.searchContent(
                    pattern: "refreshedKindNeedle",
                    paths: [targetURL.path],
                    store: store
                )
            }
            await assertAsyncTrue(barrierCaptured.waitUntilMarked())
            await sinkGate.release()

            let result = try await searchTask.value
            XCTAssertEqual(result.matches?.map(\.filePath), [nestedURL.path])

            await store.setWatcherSinkWillApplyHandler(nil)
            await store.setAppliedIngressDidCaptureWatermarksHandler(nil)
            await store.stopWatchingRoot(id: record.id)
        }

        func testExactFolderBecomingFileIsResolvedAfterFreshnessApplies() async throws {
            let root = try makeTemporaryRoot(name: "ExactFolderToFileTransition")
            let targetURL = root.appendingPathComponent("Target")
            try write("let oldNestedValue = true\n", to: targetURL.appendingPathComponent("Old.swift"))

            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)
            let sinkGate = AsyncGate()
            let barrierCaptured = AsyncSignal()
            await store.setWatcherSinkWillApplyHandler { observedRootID in
                guard observedRootID == record.id else { return }
                await sinkGate.markStartedAndWaitForRelease()
            }
            await store.setAppliedIngressDidCaptureWatermarksHandler { _ in
                await barrierCaptured.mark()
            }
            addTeardownBlock {
                await sinkGate.release()
                await store.setWatcherSinkWillApplyHandler(nil)
                await store.setAppliedIngressDidCaptureWatermarksHandler(nil)
                await store.stopWatchingRoot(id: record.id)
            }

            try FileManager.default.removeItem(at: targetURL)
            try write("let refreshedFileKindNeedle = true\n", to: targetURL)
            try await store.publishSyntheticFileSystemDeltasForTesting(
                rootID: record.id,
                deltas: [
                    .folderRemoved("Target"),
                    .fileAdded("Target")
                ]
            )
            await sinkGate.waitUntilStarted()

            let searchTask = Task {
                try await self.searchContent(
                    pattern: "refreshedFileKindNeedle",
                    paths: [targetURL.path],
                    store: store
                )
            }
            await assertAsyncTrue(barrierCaptured.waitUntilMarked())
            await sinkGate.release()

            let result = try await searchTask.value
            XCTAssertEqual(result.matches?.map(\.filePath), [targetURL.path])

            await store.setWatcherSinkWillApplyHandler(nil)
            await store.setAppliedIngressDidCaptureWatermarksHandler(nil)
            await store.stopWatchingRoot(id: record.id)
        }

        func testExactPathDisappearanceRetainsMissingPathFallbackSemantics() async throws {
            let root = try makeTemporaryRoot(name: "ExactPathDisappearance")
            let targetURL = root.appendingPathComponent("Target.swift")
            try write("let disappearingNeedle = true\n", to: targetURL)

            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)
            let sinkGate = AsyncGate()
            let barrierCaptured = AsyncSignal()
            await store.setWatcherSinkWillApplyHandler { observedRootID in
                guard observedRootID == record.id else { return }
                await sinkGate.markStartedAndWaitForRelease()
            }
            await store.setAppliedIngressDidCaptureWatermarksHandler { _ in
                await barrierCaptured.mark()
            }
            addTeardownBlock {
                await sinkGate.release()
                await store.setWatcherSinkWillApplyHandler(nil)
                await store.setAppliedIngressDidCaptureWatermarksHandler(nil)
                await store.stopWatchingRoot(id: record.id)
            }

            try FileManager.default.removeItem(at: targetURL)
            try await store.publishSyntheticFileSystemDeltasForTesting(
                rootID: record.id,
                deltas: [.fileRemoved("Target.swift")]
            )
            await sinkGate.waitUntilStarted()

            let searchTask = Task {
                try await self.searchContent(
                    pattern: "disappearingNeedle",
                    paths: [targetURL.path, "/tmp/invalid\0.swift"],
                    store: store
                )
            }
            await assertAsyncTrue(barrierCaptured.waitUntilMarked())
            await sinkGate.release()

            let result = try await searchTask.value
            XCTAssertTrue(result.matches?.isEmpty ?? true)
            XCTAssertEqual(result.scopedFileCount, 0)

            await store.setWatcherSinkWillApplyHandler(nil)
            await store.setAppliedIngressDidCaptureWatermarksHandler(nil)
            await store.stopWatchingRoot(id: record.id)
        }

        func testDeduplicatedExactPathRetainsEveryDisappearanceFallback() async throws {
            let targetRoot = try makeTemporaryRoot(name: "DeduplicatedExactTarget")
            let fallbackRoot = try makeTemporaryRoot(name: "DeduplicatedExactFallback")
            let targetURL = targetRoot.appendingPathComponent("Foo.swift")
            let fallbackURL = fallbackRoot.appendingPathComponent("Foo.swift")
            try write("let oldTargetValue = true\n", to: targetURL)

            let store = WorkspaceFileContextStore()
            let targetRecord = try await store.loadRoot(path: targetRoot.path)
            let fallbackRecord = try await store.loadRoot(path: fallbackRoot.path)
            try await store.startWatchingRoot(id: targetRecord.id)
            try await store.startWatchingRoot(id: fallbackRecord.id)
            let sinkGate = AsyncGate()
            let barrierCaptured = AsyncSignal()
            await store.setWatcherSinkWillApplyHandler { observedRootID in
                guard observedRootID == targetRecord.id else { return }
                await sinkGate.markStartedAndWaitForRelease()
            }
            await store.setAppliedIngressDidCaptureWatermarksHandler { _ in
                await barrierCaptured.mark()
            }
            addTeardownBlock {
                await sinkGate.release()
                await store.setWatcherSinkWillApplyHandler(nil)
                await store.setAppliedIngressDidCaptureWatermarksHandler(nil)
                await store.stopWatchingRoot(id: targetRecord.id)
                await store.stopWatchingRoot(id: fallbackRecord.id)
            }

            try FileManager.default.removeItem(at: targetURL)
            try await store.publishSyntheticFileSystemDeltasForTesting(
                rootID: targetRecord.id,
                deltas: [.fileRemoved("Foo.swift")]
            )
            await sinkGate.waitUntilStarted()

            let searchTask = Task {
                try await self.searchContent(
                    pattern: "deduplicatedFallbackNeedle",
                    paths: [
                        targetURL.path,
                        "\(targetRecord.name)/Foo.swift",
                        "Foo.swift"
                    ],
                    store: store
                )
            }
            await assertAsyncTrue(barrierCaptured.waitUntilMarked())

            try write("let deduplicatedFallbackNeedle = true\n", to: fallbackURL)
            try await store.publishSyntheticFileSystemDeltasForTesting(
                rootID: fallbackRecord.id,
                deltas: [.fileAdded("Foo.swift")]
            )
            _ = await store.awaitAppliedIngress(rootRefs: [
                WorkspaceRootRef(
                    id: fallbackRecord.id,
                    name: fallbackRecord.name,
                    fullPath: fallbackRecord.standardizedFullPath
                )
            ])
            await sinkGate.release()

            let result = try await searchTask.value
            XCTAssertEqual(result.matches?.map(\.filePath), [fallbackURL.path])

            await store.setWatcherSinkWillApplyHandler(nil)
            await store.setAppliedIngressDidCaptureWatermarksHandler(nil)
            await store.stopWatchingRoot(id: targetRecord.id)
            await store.stopWatchingRoot(id: fallbackRecord.id)
        }

        func testMultipleRelativeAndAliasExactSearchPathsBuildOneStaticLookupSnapshot() async throws {
            let root = try makeTemporaryRoot(name: "BatchedExactSearchScopes")
            let firstURL = root.appendingPathComponent("First.swift")
            let secondURL = root.appendingPathComponent("Second.swift")
            try write("let batchedExactNeedle = 1\n", to: firstURL)
            try write("let batchedExactNeedle = 2\n", to: secondURL)

            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            _ = startedCapture(label: "batched-exact-search-scopes", maxSamples: 200)

            let result = try await searchContent(
                pattern: "batchedExactNeedle",
                paths: [
                    "\(record.name)/First.swift",
                    "Second.swift"
                ],
                store: store
            )
            let capture = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let snapshotBuildCount = capture.stages
                .filter {
                    $0.stageName == String(describing: EditFlowPerf.Stage.ReadFile.pathLookupStaticSnapshotBuild)
                }
                .reduce(0) { $0 + $1.sampleCount }

            XCTAssertEqual(Set(result.matches?.map(\.filePath) ?? []), Set([firstURL.path, secondURL.path]))
            XCTAssertEqual(snapshotBuildCount, 1)
        }

        func testRootRestrictedSearchPathsDoNotWaitForUnrelatedRepresentedRoot() async throws {
            let targetRoot = try makeTemporaryRoot(name: "ScopedFreshnessTarget")
            let blockedRoot = try makeTemporaryRoot(name: "ScopedFreshnessBlocked")
            let targetFile = targetRoot.appendingPathComponent("Target.swift")
            let blockedFile = blockedRoot.appendingPathComponent("Blocked.swift")
            try write("let scopedFreshnessNeedle = true\n", to: targetFile)

            let store = WorkspaceFileContextStore()
            let targetRecord = try await store.loadRoot(path: targetRoot.path)
            let blockedRecord = try await store.loadRoot(path: blockedRoot.path)
            try await store.startWatchingRoot(id: blockedRecord.id)
            let sinkGate = AsyncGate()
            await store.setWatcherSinkWillApplyHandler { observedRootID in
                guard observedRootID == blockedRecord.id else { return }
                await sinkGate.markStartedAndWaitForRelease()
            }
            addTeardownBlock {
                await sinkGate.release()
                await store.setWatcherSinkWillApplyHandler(nil)
                await store.stopWatchingRoot(id: blockedRecord.id)
            }

            try write("let unrelatedBlockedNeedle = true\n", to: blockedFile)
            try await store.publishSyntheticFileSystemDeltasForTesting(
                rootID: blockedRecord.id,
                deltas: [.fileAdded("Blocked.swift")]
            )
            await sinkGate.waitUntilStarted()

            let scopedPaths: [([String], [String])] = [
                ([targetFile.path], [targetFile.path]),
                (["\(targetRecord.name)/Target.swift"], [targetFile.path]),
                (["\(targetRecord.name)/*.swift"], [targetFile.path]),
                ([targetRoot.appendingPathComponent("*.swift").path], [targetFile.path]),
                (["/tmp/RepoPromptOutside-\(UUID().uuidString).swift"], [])
            ]
            for (paths, expectedPaths) in scopedPaths {
                let completionSignal = AsyncSignal()
                let searchTask = Task { () -> Result<SearchResults, Error> in
                    do {
                        let result = try await self.searchContent(
                            pattern: "scopedFreshnessNeedle",
                            paths: paths,
                            store: store
                        )
                        await completionSignal.mark()
                        return .success(result)
                    } catch {
                        await completionSignal.mark()
                        return .failure(error)
                    }
                }

                let completedWhileUnrelatedRootBlocked = await completionSignal.waitUntilMarked()
                XCTAssertTrue(
                    completedWhileUnrelatedRootBlocked,
                    "Root-restricted paths \(paths) must not wait for another represented root"
                )
                switch await searchTask.value {
                case let .success(result):
                    XCTAssertEqual(result.matches?.map(\.filePath) ?? [], expectedPaths)
                case let .failure(error):
                    XCTFail("Expected targeted search success for \(paths), got \(error)")
                }
            }

            let targetStats = await store.scopedIngressBarrierStatsForTesting(rootID: targetRecord.id)
            let blockedStats = await store.scopedIngressBarrierStatsForTesting(rootID: blockedRecord.id)
            XCTAssertGreaterThanOrEqual(targetStats.launchCount, 1)
            XCTAssertEqual(blockedStats.launchCount, 0)

            await sinkGate.release()
            await store.setWatcherSinkWillApplyHandler(nil)
            await store.stopWatchingRoot(id: blockedRecord.id)
        }

        func testAmbiguousAndUnrestrictedSearchPathsWaitForFullFreshnessScope() async throws {
            let containerA = try makeTemporaryRoot(name: "AmbiguousFreshnessA")
            let containerB = try makeTemporaryRoot(name: "AmbiguousFreshnessB")
            let rootA = containerA.appendingPathComponent("SharedRoot", isDirectory: true)
            let rootB = containerB.appendingPathComponent("SharedRoot", isDirectory: true)
            try write("let ambiguousNeedle = true\n", to: rootA.appendingPathComponent("A.swift"))
            try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)

            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: rootA.path)
            let blockedRecord = try await store.loadRoot(path: rootB.path)
            try await store.startWatchingRoot(id: blockedRecord.id)
            let sinkGate = AsyncGate()
            await store.setWatcherSinkWillApplyHandler { observedRootID in
                guard observedRootID == blockedRecord.id else { return }
                await sinkGate.markStartedAndWaitForRelease()
            }
            addTeardownBlock {
                await sinkGate.release()
                await store.setWatcherSinkWillApplyHandler(nil)
                await store.stopWatchingRoot(id: blockedRecord.id)
            }

            try write("let blockedNeedle = true\n", to: rootB.appendingPathComponent("Blocked.swift"))
            try await store.publishSyntheticFileSystemDeltasForTesting(
                rootID: blockedRecord.id,
                deltas: [.fileAdded("Blocked.swift")]
            )
            await sinkGate.waitUntilStarted()

            for paths in [
                ["SharedRoot/*.swift"],
                ["*.swift"],
                ["Missing/Relative.swift"],
                ["SharedRoot/[broken"],
                ["Missing/[broken"],
                ["/tmp/invalid\0.swift"]
            ] {
                let completionSignal = AsyncSignal()
                let searchTask = Task { () -> Result<SearchResults, Error> in
                    do {
                        let result = try await self.searchContent(
                            pattern: "ambiguousNeedle",
                            paths: paths,
                            store: store
                        )
                        await completionSignal.mark()
                        return .success(result)
                    } catch {
                        await completionSignal.mark()
                        return .failure(error)
                    }
                }

                let completedWhileBlocked = await completionSignal.waitUntilMarked(timeoutNanoseconds: 100_000_000)
                XCTAssertFalse(completedWhileBlocked, "Conservative path \(paths) must await all represented roots")
                searchTask.cancel()
                if case let .success(result) = await searchTask.value {
                    XCTFail("Expected cancellation while full freshness was blocked, got \(result)")
                }
            }

            let blockedStats = await store.scopedIngressBarrierStatsForTesting(rootID: blockedRecord.id)
            XCTAssertGreaterThan(blockedStats.launchCount + blockedStats.joinCount, 0)
            await sinkGate.release()
            await store.setWatcherSinkWillApplyHandler(nil)
            await store.stopWatchingRoot(id: blockedRecord.id)
        }

        func testInitializingSessionWorktreeIsNarrowedOrTimesOutWithoutSearchingIncompleteCatalog() async throws {
            let canonicalRoot = try makeTemporaryRoot(name: "InitializingCanonical")
            let worktreeContainer = try makeTemporaryRoot(name: "InitializingWorktreeContainer")
            let worktreeRoot = worktreeContainer.appendingPathComponent("InitiallyAbsent", isDirectory: true)
            let canonicalFile = canonicalRoot.appendingPathComponent("Canonical.swift")
            let initializingFile = worktreeRoot.appendingPathComponent("Initializing.swift")
            try write("let canonicalNeedle = true\n", to: canonicalFile)

            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: canonicalRoot.path)
            let scope = WorkspaceLookupRootScope.sessionBoundWorkspace(
                canonicalRootPaths: [canonicalRoot.path],
                physicalRootPaths: [worktreeRoot.path]
            )
            do {
                _ = try await StoreBackedWorkspaceSearch.search(
                    pattern: "initializingNeedle",
                    mode: .content,
                    paths: [initializingFile.path],
                    rootScope: scope,
                    store: store,
                    workspaceManager: nil
                )
                XCTFail("Expected the absent physical worktree to be unavailable")
            } catch let error as StoreBackedWorkspaceSearchError {
                XCTAssertEqual(
                    error,
                    .worktreeScopeUnavailable(missingPhysicalRootPaths: [worktreeRoot.standardizedFileURL.path])
                )
            }

            // loadRoot performs its initial crawl and catalog commit atomically before exposing
            // the root, so there is no searchable incomplete pre-commit state to pause. Blocking
            // the first accepted ingress immediately after the real load is the closest explicit
            // initial-publication seam and exercises the Search freshness boundary.
            try write("let initialCatalogNeedle = true\n", to: worktreeRoot.appendingPathComponent("Initial.swift"))
            let worktreeRecord = try await store.loadRoot(path: worktreeRoot.path, kind: .sessionWorktree)
            try await store.startWatchingRoot(id: worktreeRecord.id)
            let sinkGate = AsyncGate()
            await store.setWatcherSinkWillApplyHandler { observedRootID in
                guard observedRootID == worktreeRecord.id else { return }
                await sinkGate.markStartedAndWaitForRelease()
            }
            addTeardownBlock {
                await sinkGate.release()
                await store.setWatcherSinkWillApplyHandler(nil)
                await store.stopWatchingRoot(id: worktreeRecord.id)
            }

            try write("let initializingNeedle = true\n", to: initializingFile)
            try await store.publishSyntheticFileSystemDeltasForTesting(
                rootID: worktreeRecord.id,
                deltas: [.fileAdded("Initializing.swift")]
            )
            await sinkGate.waitUntilStarted()

            let canonicalResult = try await StoreBackedWorkspaceSearch.search(
                pattern: "canonicalNeedle",
                mode: .content,
                paths: [canonicalFile.path],
                rootScope: scope,
                store: store,
                workspaceManager: nil
            )
            XCTAssertEqual(canonicalResult.matches?.map(\.filePath), [canonicalFile.path])

            do {
                _ = try await StoreBackedWorkspaceSearch.$freshnessWaitTimeoutOverrideForTesting.withValue(.milliseconds(50)) {
                    try await StoreBackedWorkspaceSearch.search(
                        pattern: "initializingNeedle",
                        mode: .content,
                        paths: [initializingFile.path],
                        rootScope: scope,
                        store: store,
                        workspaceManager: nil
                    )
                }
                XCTFail("Expected the requested initializing worktree to report freshness timeout")
            } catch let error as StoreBackedWorkspaceSearchError {
                XCTAssertEqual(error, .workspaceFreshnessTimedOut)
            }

            await sinkGate.release()
            let readyResult = try await StoreBackedWorkspaceSearch.search(
                pattern: "initializingNeedle",
                mode: .content,
                paths: [initializingFile.path],
                rootScope: scope,
                store: store,
                workspaceManager: nil
            )
            XCTAssertEqual(readyResult.matches?.map(\.filePath), [initializingFile.path])

            await store.setWatcherSinkWillApplyHandler(nil)
            await store.stopWatchingRoot(id: worktreeRecord.id)
        }

        func testFreshnessTimeoutDoesNotAwaitCancellationInsensitiveLoser() async throws {
            let root = try makeTemporaryRoot(name: "FreshnessRaceTimeout")
            try write("let raceTimeoutNeedle = true\n", to: root.appendingPathComponent("A.swift"))
            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: root.path)
            let freshnessGate = AsyncGate()
            let freshnessCompleted = AsyncSignal()

            let clock = ContinuousClock()
            let started = clock.now
            do {
                _ = try await StoreBackedWorkspaceSearch.$freshnessWaitOperationOverrideForTesting.withValue({ _, _ in
                    await freshnessGate.markStartedAndWaitForRelease()
                    await freshnessCompleted.mark()
                    return []
                }) {
                    try await StoreBackedWorkspaceSearch.$freshnessWaitTimeoutOverrideForTesting.withValue(.milliseconds(50)) {
                        try await searchContent(
                            pattern: "raceTimeoutNeedle",
                            store: store
                        )
                    }
                }
                XCTFail("Expected workspace freshness timeout")
            } catch let error as StoreBackedWorkspaceSearchError {
                XCTAssertEqual(error, .workspaceFreshnessTimedOut)
            }
            let freshnessStarted = await freshnessGate.waitUntilStartedWithinTimeout()
            XCTAssertTrue(freshnessStarted)
            XCTAssertLessThan(started.duration(to: clock.now), .milliseconds(500))
            let completedBeforeRelease = await freshnessCompleted.waitUntilMarked(timeoutNanoseconds: 20_000_000)
            XCTAssertFalse(completedBeforeRelease)

            await freshnessGate.release()
            let completedAfterRelease = await freshnessCompleted.waitUntilMarked()
            XCTAssertTrue(completedAfterRelease)
        }

        func testBlockedFreshnessWaitReturnsDedicatedTimeout() async throws {
            let root = try makeTemporaryRoot(name: "FreshnessTimeout")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)
            let sinkGate = AsyncGate()
            await store.setWatcherSinkWillApplyHandler { observedRootID in
                guard observedRootID == record.id else { return }
                await sinkGate.markStartedAndWaitForRelease()
            }
            addTeardownBlock {
                await sinkGate.release()
                await store.setWatcherSinkWillApplyHandler(nil)
                await store.stopWatchingRoot(id: record.id)
            }

            try write("let timeoutNeedle = true\n", to: root.appendingPathComponent("Added.swift"))
            try await store.publishSyntheticFileSystemDeltasForTesting(
                rootID: record.id,
                deltas: [.fileAdded("Added.swift")]
            )
            await sinkGate.waitUntilStarted()

            let clock = ContinuousClock()
            let started = clock.now
            do {
                _ = try await StoreBackedWorkspaceSearch.$freshnessWaitTimeoutOverrideForTesting.withValue(.milliseconds(50)) {
                    try await searchContent(
                        pattern: "timeoutNeedle",
                        store: store
                    )
                }
                XCTFail("Expected workspace freshness timeout")
            } catch let error as StoreBackedWorkspaceSearchError {
                XCTAssertEqual(error, .workspaceFreshnessTimedOut)
                XCTAssertTrue(error.localizedDescription.contains("Workspace freshness timed out"))
            }
            XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))

            await sinkGate.release()
            await store.setWatcherSinkWillApplyHandler(nil)
            await store.stopWatchingRoot(id: record.id)
        }

        func testStoreBackedSearchAcquiresBroadPermitBeforeAwaitingScopedFreshnessAndCatalogSnapshot() async throws {
            let root = try makeTemporaryRoot(name: "ScopedSearchFreshness")
            let addedURL = root.appendingPathComponent("Added.swift")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)
            let sinkGate = AsyncGate()
            let permitSignal = AsyncSignal()
            await store.setWatcherSinkWillApplyHandler { observedRootID in
                guard observedRootID == record.id else { return }
                await sinkGate.markStartedAndWaitForRelease()
            }
            await store.setSearchLanePermitAcquiredHandlerForTesting {
                await permitSignal.mark()
            }
            addTeardownBlock {
                await sinkGate.release()
                await store.setWatcherSinkWillApplyHandler(nil)
                await store.setSearchLanePermitAcquiredHandlerForTesting(nil)
                await store.stopWatchingRoot(id: record.id)
            }

            try write("freshNeedle", to: addedURL)
            try await store.publishSyntheticFileSystemDeltasForTesting(rootID: record.id, deltas: [.fileAdded("Added.swift")])
            await sinkGate.waitUntilStarted()
            let searchTask = Task {
                try await self.searchContent(pattern: "freshNeedle", store: store)
            }
            await assertAsyncTrue(permitSignal.waitUntilMarked())
            let freshnessLaneSnapshot = await store.searchLaneSnapshotForTesting()
            XCTAssertEqual(freshnessLaneSnapshot.activePermitCount, 1)
            XCTAssertEqual(freshnessLaneSnapshot.waiterCount, 0)

            await sinkGate.release()
            let result = try await searchTask.value
            XCTAssertEqual(result.matches?.map(\.filePath), [addedURL.path])
            let laneSnapshot = await store.searchLaneSnapshotForTesting()
            XCTAssertTrue(laneSnapshot.isIdle)
            await store.setWatcherSinkWillApplyHandler(nil)
            await store.setSearchLanePermitAcquiredHandlerForTesting(nil)
            await store.stopWatchingRoot(id: record.id)
        }

        func testCancelledBroadSearchBlockedInFreshnessReleasesAdmissionPermit() async throws {
            let root = try makeTemporaryRoot(name: "CancelledBroadSearchFreshness")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)
            let sinkGate = AsyncGate()
            let permitSignal = AsyncSignal()
            let completionSignal = AsyncSignal()
            await store.setWatcherSinkWillApplyHandler { observedRootID in
                guard observedRootID == record.id else { return }
                await sinkGate.markStartedAndWaitForRelease()
            }
            await store.setSearchLanePermitAcquiredHandlerForTesting {
                await permitSignal.mark()
            }
            addTeardownBlock {
                await sinkGate.release()
                await store.setWatcherSinkWillApplyHandler(nil)
                await store.setSearchLanePermitAcquiredHandlerForTesting(nil)
                await store.stopWatchingRoot(id: record.id)
            }

            try write("cancelNeedle", to: root.appendingPathComponent("Added.swift"))
            try await store.publishSyntheticFileSystemDeltasForTesting(
                rootID: record.id,
                deltas: [.fileAdded("Added.swift")]
            )
            await sinkGate.waitUntilStarted()
            let searchTask = Task { () -> Result<SearchResults, Error> in
                do {
                    let result = try await self.searchContent(pattern: "cancelNeedle", store: store)
                    await completionSignal.mark()
                    return .success(result)
                } catch {
                    await completionSignal.mark()
                    return .failure(error)
                }
            }
            await assertAsyncTrue(permitSignal.waitUntilMarked())
            let heldSnapshot = await store.searchLaneSnapshotForTesting()
            XCTAssertEqual(heldSnapshot.activePermitCount, 1)

            searchTask.cancel()
            let completedWhileIngressBlocked = await completionSignal.waitUntilMarked()
            XCTAssertTrue(
                completedWhileIngressBlocked,
                "Cancellation after admission must detach from freshness without waiting for ingress application"
            )
            let releasedBeforeIngress = await waitForSearchLaneIdle(store: store)
            XCTAssertTrue(
                releasedBeforeIngress,
                "Cancellation during freshness must release the broad-search permit before ingress unblocks"
            )

            await sinkGate.release()
            switch await searchTask.value {
            case .success:
                XCTFail("Expected cancelled broad search to fail")
            case let .failure(error):
                XCTAssertTrue(error is CancellationError)
            }
            await store.setWatcherSinkWillApplyHandler(nil)
            await store.setSearchLanePermitAcquiredHandlerForTesting(nil)
            await store.stopWatchingRoot(id: record.id)
        }

        @MainActor
        func testReadinessWaitMapsTimeoutCancellationAndIdleUnavailable() async throws {
            let root = try makeTemporaryRoot(name: "SearchReadinessWait")
            let fileURL = root.appendingPathComponent("OldWorkspace.swift")
            try write("let oldWorkspaceNeedle = true\n", to: fileURL)
            let store = WorkspaceFileContextStore()
            let composition = makeComposition(store: store)
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let source = manager.createWorkspace(
                name: "Search Readiness Source \(UUID().uuidString.prefix(8))",
                repoPaths: [root.path],
                ephemeral: true
            )
            let sourceSwitchResult = await manager.switchWorkspace(to: source, saveState: false)
            XCTAssertTrue(sourceSwitchResult.didSwitch)

            let readinessGate = AsyncGate()
            manager.setWorkspaceSwitchReadinessDidInvalidateHandlerForTesting {
                await readinessGate.markStartedAndWaitForRelease()
            }
            let target = manager.createWorkspace(
                name: "Search Readiness Target \(UUID().uuidString.prefix(8))",
                repoPaths: [],
                ephemeral: true
            )
            let switchTask = Task { @MainActor in
                await manager.switchWorkspace(to: target, saveState: false, reason: "searchReadinessErrors")
            }
            addTeardownBlock {
                switchTask.cancel()
                await MainActor.run {
                    manager.setWorkspaceSwitchReadinessDidInvalidateHandlerForTesting(nil)
                }
                await readinessGate.release()
                _ = await switchTask.value
            }
            let switchReachedReadinessGate = await readinessGate.waitUntilStartedWithinTimeout()
            XCTAssertTrue(switchReachedReadinessGate)

            do {
                _ = try await StoreBackedWorkspaceSearch.$readinessWaitTimeoutOverrideForTesting.withValue(.milliseconds(20)) {
                    try await StoreBackedWorkspaceSearch.search(
                        pattern: "oldWorkspaceNeedle",
                        mode: .content,
                        paths: [fileURL.path],
                        rootScope: .visibleWorkspace,
                        store: store,
                        workspaceManager: manager
                    )
                }
                XCTFail("Expected workspace readiness timeout")
            } catch let error as StoreBackedWorkspaceSearchError {
                XCTAssertEqual(error, .workspaceReadinessTimedOut)
                XCTAssertTrue(error.localizedDescription.contains("readiness timed out"))
            }
            XCTAssertEqual(manager.workspaceSearchReadinessWaiterCountForTesting, 0)

            let cancelledSearch = Task { @MainActor in
                try await StoreBackedWorkspaceSearch.$readinessWaitTimeoutOverrideForTesting.withValue(.seconds(2)) {
                    try await StoreBackedWorkspaceSearch.search(
                        pattern: "oldWorkspaceNeedle",
                        mode: .content,
                        paths: [fileURL.path],
                        rootScope: .visibleWorkspace,
                        store: store,
                        workspaceManager: manager
                    )
                }
            }
            try await waitForReadinessWaiterCount(1, manager: manager)
            cancelledSearch.cancel()
            do {
                _ = try await cancelledSearch.value
                XCTFail("Expected readiness cancellation")
            } catch is CancellationError {
                // Expected: search must preserve manager cancellation rather than remapping it.
            }
            try await waitForReadinessWaiterCount(0, manager: manager)

            await manager.cancelCurrentWorkspaceSwitchAndReturnToSystem()
            XCTAssertEqual(manager.workspaceSearchReadinessState, .idle)
            do {
                _ = try await StoreBackedWorkspaceSearch.search(
                    pattern: "oldWorkspaceNeedle",
                    mode: .content,
                    paths: [fileURL.path],
                    rootScope: .visibleWorkspace,
                    store: store,
                    workspaceManager: manager
                )
                XCTFail("Expected idle readiness to be unavailable")
            } catch let error as StoreBackedWorkspaceSearchError {
                XCTAssertEqual(error, .workspaceReadinessUnavailable)
            }

            manager.setWorkspaceSwitchReadinessDidInvalidateHandlerForTesting(nil)
            await readinessGate.release()
            _ = await switchTask.value
        }

        @MainActor
        func testWorkspaceSearchReadinessSnapshotFenceMatchesMainActorAuthorityAcrossGenerationChange() async throws {
            let sourceRoot = try makeTemporaryRoot(name: "ReadinessFenceSource")
            let targetRoot = try makeTemporaryRoot(name: "ReadinessFenceTarget")
            try write("let sourceNeedle = true\n", to: sourceRoot.appendingPathComponent("Source.swift"))
            try write("let targetNeedle = true\n", to: targetRoot.appendingPathComponent("Target.swift"))

            let store = WorkspaceFileContextStore()
            let composition = makeComposition(store: store)
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let source = manager.createWorkspace(
                name: "Readiness Fence Source \(UUID().uuidString.prefix(8))",
                repoPaths: [sourceRoot.path],
                ephemeral: true
            )
            let sourceSwitchResult = await manager.switchWorkspace(to: source, saveState: false)
            XCTAssertTrue(sourceSwitchResult.didSwitch)

            let sourceTicket = try await manager.awaitWorkspaceSearchReadiness(timeout: .seconds(2))
            XCTAssertNoThrow(try manager.validateWorkspaceSearchReadiness(sourceTicket))
            let sourceAcceptedOffMain = await Task.detached {
                do {
                    try manager.validateWorkspaceSearchReadinessSnapshot(sourceTicket)
                    return true
                } catch {
                    return false
                }
            }.value
            XCTAssertTrue(sourceAcceptedOffMain)

            var generationAdvanceProbeCount = 0
            manager.setWorkspaceHydrationGenerationDidAdvanceHandlerForTesting {
                generationAdvanceProbeCount += 1
                do {
                    try manager.validateWorkspaceSearchReadiness(sourceTicket)
                    XCTFail("Expected main-actor readiness authority to reject the old ticket")
                } catch {
                    XCTAssertEqual(error as? WorkspaceSearchReadinessWaitError, .superseded)
                }
                do {
                    try manager.validateWorkspaceSearchReadinessSnapshot(sourceTicket)
                    XCTFail("Expected the readiness snapshot fence to reject the old ticket")
                } catch {
                    XCTAssertEqual(error as? WorkspaceSearchReadinessWaitError, .superseded)
                }
            }
            let invalidationGate = AsyncGate()
            manager.setWorkspaceSwitchReadinessDidInvalidateHandlerForTesting {
                await invalidationGate.markStartedAndWaitForRelease()
            }
            let target = manager.createWorkspace(
                name: "Readiness Fence Target \(UUID().uuidString.prefix(8))",
                repoPaths: [targetRoot.path],
                ephemeral: true
            )
            let switchTask = Task { @MainActor in
                await manager.switchWorkspace(to: target, saveState: false, reason: "readinessFenceEquivalence")
            }
            addTeardownBlock {
                switchTask.cancel()
                await MainActor.run {
                    manager.setWorkspaceHydrationGenerationDidAdvanceHandlerForTesting(nil)
                    manager.setWorkspaceSwitchReadinessDidInvalidateHandlerForTesting(nil)
                }
                await invalidationGate.release()
                _ = await switchTask.value
            }
            let switchReachedInvalidationGate = await invalidationGate.waitUntilStartedWithinTimeout()
            XCTAssertTrue(switchReachedInvalidationGate)
            XCTAssertEqual(generationAdvanceProbeCount, 1)

            XCTAssertThrowsError(try manager.validateWorkspaceSearchReadiness(sourceTicket)) { error in
                XCTAssertEqual(error as? WorkspaceSearchReadinessWaitError, .superseded)
            }
            let invalidatedTicketRejectedOffMain = await Task.detached {
                do {
                    try manager.validateWorkspaceSearchReadinessSnapshot(sourceTicket)
                    return false
                } catch let error as WorkspaceSearchReadinessWaitError {
                    return error == .superseded
                } catch {
                    return false
                }
            }.value
            XCTAssertTrue(invalidatedTicketRejectedOffMain)

            manager.setWorkspaceHydrationGenerationDidAdvanceHandlerForTesting(nil)
            manager.setWorkspaceSwitchReadinessDidInvalidateHandlerForTesting(nil)
            await invalidationGate.release()
            let targetSwitchResult = await switchTask.value
            XCTAssertTrue(targetSwitchResult.didSwitch)
            let targetTicket = try await manager.awaitWorkspaceSearchReadiness(timeout: .seconds(2))
            XCTAssertEqual(targetTicket.workspaceID, target.id)
            XCTAssertNotEqual(targetTicket, sourceTicket)
            XCTAssertNoThrow(try manager.validateWorkspaceSearchReadiness(targetTicket))

            let generationValidation = await Task.detached {
                let targetAccepted: Bool
                do {
                    try manager.validateWorkspaceSearchReadinessSnapshot(targetTicket)
                    targetAccepted = true
                } catch {
                    targetAccepted = false
                }
                let oldRejected: Bool
                do {
                    try manager.validateWorkspaceSearchReadinessSnapshot(sourceTicket)
                    oldRejected = false
                } catch let error as WorkspaceSearchReadinessWaitError {
                    oldRejected = error == .superseded
                } catch {
                    oldRejected = false
                }
                return (targetAccepted, oldRejected)
            }.value
            XCTAssertTrue(generationValidation.0)
            XCTAssertTrue(generationValidation.1)
        }

        @MainActor
        func testQueuedBroadSearchRejectsSupersededReadinessTicketAfterAdmission() async throws {
            let root = try makeTemporaryRoot(name: "QueuedReadinessSupersession")
            try write("let queuedReadinessNeedle = true\n", to: root.appendingPathComponent("Old.swift"))
            let store = WorkspaceFileContextStore()
            let composition = makeComposition(store: store)
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let source = manager.createWorkspace(
                name: "Queued Search Source \(UUID().uuidString.prefix(8))",
                repoPaths: [root.path],
                ephemeral: true
            )
            let sourceSwitchResult = await manager.switchWorkspace(to: source, saveState: false)
            XCTAssertTrue(sourceSwitchResult.didSwitch)

            await configureSingleLeaseSearchLane(store)
            let admissionGate = AsyncGate()
            await store.setSearchLanePermitAcquiredHandlerForTesting {
                await admissionGate.markStartedAndWaitForRelease()
            }
            let held = Task { @MainActor in
                try await StoreBackedWorkspaceSearch.search(
                    pattern: "queuedReadinessNeedle",
                    mode: .content,
                    rootScope: .visibleWorkspace,
                    store: store,
                    workspaceManager: manager
                )
            }
            addTeardownBlock {
                held.cancel()
                await admissionGate.release()
                await store.setSearchLanePermitAcquiredHandlerForTesting(nil)
                _ = try? await held.value
            }
            let heldSearchReachedAdmission = await admissionGate.waitUntilStartedWithinTimeout()
            XCTAssertTrue(heldSearchReachedAdmission)
            let queued = Task { @MainActor in
                try await StoreBackedWorkspaceSearch.search(
                    pattern: "queuedReadinessNeedle",
                    mode: .content,
                    rootScope: .visibleWorkspace,
                    store: store,
                    workspaceManager: manager
                )
            }
            addTeardownBlock {
                queued.cancel()
                await admissionGate.release()
                _ = try? await queued.value
            }
            await assertAsyncTrue(waitForAdmissionWaiterCount(1, store: store))

            let readinessGate = AsyncGate()
            manager.setWorkspaceSwitchReadinessDidInvalidateHandlerForTesting {
                await readinessGate.markStartedAndWaitForRelease()
            }
            let target = manager.createWorkspace(
                name: "Queued Search Target \(UUID().uuidString.prefix(8))",
                repoPaths: [],
                ephemeral: true
            )
            let switchTask = Task { @MainActor in
                await manager.switchWorkspace(to: target, saveState: false, reason: "queuedSearchSupersession")
            }
            addTeardownBlock {
                switchTask.cancel()
                await MainActor.run {
                    manager.setWorkspaceSwitchReadinessDidInvalidateHandlerForTesting(nil)
                }
                await admissionGate.release()
                await readinessGate.release()
                await store.setSearchLanePermitAcquiredHandlerForTesting(nil)
                _ = await switchTask.value
            }
            let switchReachedReadinessGate = await readinessGate.waitUntilStartedWithinTimeout()
            XCTAssertTrue(switchReachedReadinessGate)
            await admissionGate.release()

            for searchTask in [held, queued] {
                do {
                    _ = try await searchTask.value
                    XCTFail("Expected the old readiness ticket to be rejected")
                } catch let error as StoreBackedWorkspaceSearchError {
                    XCTAssertEqual(error, .workspaceReadinessSuperseded)
                }
            }
            let searchLaneBecameIdle = await waitForSearchLaneIdle(store: store)
            XCTAssertTrue(searchLaneBecameIdle)

            manager.setWorkspaceSwitchReadinessDidInvalidateHandlerForTesting(nil)
            await readinessGate.release()
            _ = await switchTask.value
            await store.setSearchLanePermitAcquiredHandlerForTesting(nil)
        }

        @MainActor
        func testSearchRejectsSupersededReadinessAfterAppliedIngressWait() async throws {
            let root = try makeTemporaryRoot(name: "IngressReadinessSupersession")
            let fileURL = root.appendingPathComponent("Old.swift")
            try write("let ingressReadinessNeedle = true\n", to: fileURL)
            let store = WorkspaceFileContextStore()
            let composition = makeComposition(store: store)
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let source = manager.createWorkspace(
                name: "Ingress Search Source \(UUID().uuidString.prefix(8))",
                repoPaths: [root.path],
                ephemeral: true
            )
            let sourceSwitchResult = await manager.switchWorkspace(to: source, saveState: false)
            XCTAssertTrue(sourceSwitchResult.didSwitch)

            let ingressGate = AsyncGate()
            let searchTask = Task { @MainActor in
                try await StoreBackedWorkspaceSearch.$freshnessWaitOperationOverrideForTesting.withValue({ _, _ in
                    await ingressGate.markStartedAndWaitForRelease()
                    return []
                }) {
                    try await StoreBackedWorkspaceSearch.search(
                        pattern: "ingressReadinessNeedle",
                        mode: .content,
                        paths: [fileURL.path],
                        rootScope: .visibleWorkspace,
                        store: store,
                        workspaceManager: manager
                    )
                }
            }
            addTeardownBlock {
                searchTask.cancel()
                await ingressGate.release()
                _ = try? await searchTask.value
            }
            let searchReachedIngressGate = await ingressGate.waitUntilStartedWithinTimeout()
            XCTAssertTrue(searchReachedIngressGate)

            let readinessGate = AsyncGate()
            manager.setWorkspaceSwitchReadinessDidInvalidateHandlerForTesting {
                await readinessGate.markStartedAndWaitForRelease()
            }
            let target = manager.createWorkspace(
                name: "Ingress Search Target \(UUID().uuidString.prefix(8))",
                repoPaths: [],
                ephemeral: true
            )
            let switchTask = Task { @MainActor in
                await manager.switchWorkspace(to: target, saveState: false, reason: "ingressSearchSupersession")
            }
            addTeardownBlock {
                switchTask.cancel()
                await MainActor.run {
                    manager.setWorkspaceSwitchReadinessDidInvalidateHandlerForTesting(nil)
                }
                await ingressGate.release()
                await readinessGate.release()
                _ = await switchTask.value
            }
            let switchReachedReadinessGate = await readinessGate.waitUntilStartedWithinTimeout()
            XCTAssertTrue(switchReachedReadinessGate)
            let rootsBeforeUnload = await store.roots()
            XCTAssertTrue(rootsBeforeUnload.contains { $0.standardizedFullPath == root.path })
            await ingressGate.release()

            do {
                _ = try await searchTask.value
                XCTFail("Expected post-ingress readiness validation to reject old-root results")
            } catch let error as StoreBackedWorkspaceSearchError {
                XCTAssertEqual(error, .workspaceReadinessSuperseded)
            }

            manager.setWorkspaceSwitchReadinessDidInvalidateHandlerForTesting(nil)
            await readinessGate.release()
            _ = await switchTask.value
        }

        func testMissingSessionWorktreeScopeThrowsTypedUnavailableErrorBeforeAdmission() async throws {
            let logicalRoot = try makeTemporaryRoot(name: "UnavailableWorktreeLogical")
            try write("let baseNeedle = true\n", to: logicalRoot.appendingPathComponent("A.swift"))
            let missingPhysicalRoot = logicalRoot
                .deletingLastPathComponent()
                .appendingPathComponent("Missing-\(UUID().uuidString)")
            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: logicalRoot.path)
            let permitSignal = AsyncSignal()
            await store.setSearchLanePermitAcquiredHandlerForTesting {
                await permitSignal.mark()
            }
            let scope = WorkspaceLookupRootScope.sessionBoundWorkspace(
                canonicalRootPaths: [],
                physicalRootPaths: [missingPhysicalRoot.standardizedFileURL.path]
            )

            do {
                _ = try await StoreBackedWorkspaceSearch.search(
                    pattern: "baseNeedle",
                    mode: .content,
                    rootScope: scope,
                    store: store,
                    workspaceManager: nil
                )
                XCTFail("Expected unavailable session worktree error")
            } catch let error as StoreBackedWorkspaceSearchError {
                XCTAssertEqual(
                    error,
                    .worktreeScopeUnavailable(missingPhysicalRootPaths: [missingPhysicalRoot.standardizedFileURL.path])
                )
            }

            let permitMarkedEarly = await permitSignal.waitUntilMarked(timeoutNanoseconds: 50_000_000)
            XCTAssertFalse(permitMarkedEarly)
            let laneSnapshot = await store.searchLaneSnapshotForTesting()
            XCTAssertTrue(laneSnapshot.isIdle)
        }

        func testQueuedSessionWorktreeSearchRechecksAvailabilityAfterAdmission() async throws {
            let logicalRoot = try makeTemporaryRoot(name: "QueuedUnavailableWorktreeLogical")
            let physicalRoot = try makeTemporaryRoot(name: "QueuedUnavailableWorktreePhysical")
            try write("let baseNeedle = true\n", to: logicalRoot.appendingPathComponent("Base.swift"))
            try write("let worktreeNeedle = true\n", to: physicalRoot.appendingPathComponent("Worktree.swift"))
            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: logicalRoot.path)
            let physicalRecord = try await store.loadRoot(path: physicalRoot.path, kind: .sessionWorktree)
            await configureSingleLeaseSearchLane(store)
            let gate = AsyncGate()
            await store.setSearchLanePermitAcquiredHandlerForTesting {
                await gate.markStartedAndWaitForRelease()
            }

            let held = Task { try await self.searchContent(pattern: "baseNeedle", store: store) }
            await assertAsyncTrue(gate.waitUntilStartedCount(1))
            let scope = WorkspaceLookupRootScope.sessionBoundWorkspace(
                canonicalRootPaths: [],
                physicalRootPaths: [physicalRoot.standardizedFileURL.path]
            )
            let queued = Task {
                try await StoreBackedWorkspaceSearch.search(
                    pattern: "worktreeNeedle",
                    mode: .content,
                    rootScope: scope,
                    store: store,
                    workspaceManager: nil
                )
            }
            await assertAsyncTrue(waitForAdmissionWaiterCount(1, store: store))

            await store.unloadRoot(id: physicalRecord.id)
            await gate.release()
            _ = try await held.value
            do {
                _ = try await queued.value
                XCTFail("Expected queued search to observe the unloaded session worktree")
            } catch let error as StoreBackedWorkspaceSearchError {
                XCTAssertEqual(
                    error,
                    .worktreeScopeUnavailable(missingPhysicalRootPaths: [physicalRoot.standardizedFileURL.path])
                )
            }

            await store.setSearchLanePermitAcquiredHandlerForTesting(nil)
            let laneSnapshot = await store.searchLaneSnapshotForTesting()
            XCTAssertTrue(laneSnapshot.isIdle)
        }
    #endif

    func testBroadSearchOrchestrationChecksScopeAndReadinessBeforeAndAfterAdmission() throws {
        let source = try String(
            contentsOf: RepoRoot.url().appendingPathComponent("Sources/RepoPrompt/Features/Search/StoreBackedWorkspaceSearch.swift"),
            encoding: .utf8
        )
        try assertOrdered([
            "try await ensureRootScopeAvailable(rootScope, store: store)",
            "let readinessTicket = try await acquireSearchReadiness(",
            "readinessTicket: readinessTicket,",
            "try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)",
            "let effectiveMode = mode == .auto ? FileSearchActor.inferredAutoMode(pattern) : mode",
            "return try await store.withStoreBackedSearchAccess(",
            "if admissionClass != nil {",
            "try await ensureRootScopeAvailable(",
            "readinessTicket: readinessTicket,",
            "try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)",
            "var parsedSearchScope:",
            "try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)",
            "let freshnessRootRefs:",
            "try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)",
            "appliedIngressSamples = try await awaitAppliedIngress(",
            "try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)",
            "let contentFreshnessPolicy = await store.contentSearchFreshnessPolicy(",
            "try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)",
            "parsedSearchScope = await refreshExactSearchScopeClauses(",
            "try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)",
            "return try await performSearch("
        ], in: source)
        let performSearchStart = try XCTUnwrap(source.range(of: "private static func performSearch("))
        try assertOrdered([
            "try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)",
            "let catalogRequirement: WorkspaceSearchCatalogAccessRequirement = switch mode",
            "let catalogAccess = await store.searchCatalogAccess(",
            "requirement: catalogRequirement",
            "try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)",
            "let visibleRootRefs = await store.rootRefs(scope: .visibleWorkspace)",
            "try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)",
            "let filterResult = await withTaskCancellationHandler",
            "try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)",
            "results = try await EditFlowPerf.measure(",
            "try await fileSearchActor.searchUnified(",
            "try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)",
            "results.scopedFileCount = filesToSearch.count"
        ], in: String(source[performSearchStart.lowerBound...]))
    }

    func testSearchScopeParserKeepsRequiredResolutionOrder() throws {
        let source = try String(
            contentsOf: RepoRoot.url().appendingPathComponent("Sources/RepoPrompt/Features/Search/StoreBackedWorkspaceSearch.swift"),
            encoding: .utf8
        )
        try assertOrdered([
            "let hasWildcard = normalized.contains(\"*\")",
            "if hasWildcard {",
            "await store.exactPathResolutionIssue(for: normalized, kind: .either, rootScope: rootScope)",
            "await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(",
            "let lookupResults = await store.lookupPaths(lookupRequests)",
            "appendClause(.legacyPrefix(candidateLower: normalizedPath.lowercased()))",
            "await store.lookupDiscoverablePath("
        ], in: source)
        XCTAssertEqual(
            source.components(separatedBy: "parseSearchScopePaths(").count - 1,
            2,
            "Explicit search paths must be parsed once, then exact clauses refreshed by root-local lookup"
        )
    }

    private func searchSwiftFiles(paths: [String], store: WorkspaceFileContextStore) async throws -> SearchResults {
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

    private func searchPaths(
        pattern: String,
        store: WorkspaceFileContextStore
    ) async throws -> SearchResults {
        try await StoreBackedWorkspaceSearch.search(
            pattern: pattern,
            mode: .path,
            isRegex: false,
            caseInsensitive: true,
            maxPaths: 100,
            rootScope: .visibleWorkspace,
            store: store,
            workspaceManager: nil
        )
    }

    private func searchContent(
        pattern: String,
        paths: [String]? = nil,
        maxMatches: Int = 100,
        countOnly: Bool = false,
        store: WorkspaceFileContextStore
    ) async throws -> SearchResults {
        try await StoreBackedWorkspaceSearch.search(
            pattern: pattern,
            mode: .content,
            isRegex: false,
            caseInsensitive: false,
            maxPaths: maxMatches,
            maxMatches: maxMatches,
            paths: paths,
            countOnly: countOnly,
            rootScope: .visibleWorkspace,
            store: store,
            workspaceManager: nil
        )
    }

    #if DEBUG
        @MainActor
        private func makeComposition(
            store: WorkspaceFileContextStore
        ) -> WindowStateComposition {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            defer {
                GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            }
            return WindowStateCompositionFactory.make(
                windowID: -700 - Int.random(in: 1 ... 99),
                deferredInitialAgentSystemWorkspaceRefresh: true,
                sharedMCPService: MCPService(),
                workspaceFileContextStore: store
            )
        }

        @MainActor
        private func waitForReadinessWaiterCount(
            _ expectedCount: Int,
            manager: WorkspaceManagerViewModel,
            timeoutNanoseconds: UInt64 = 1_000_000_000,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let interval: UInt64 = 10_000_000
            var waited: UInt64 = 0
            while manager.workspaceSearchReadinessWaiterCountForTesting != expectedCount,
                  waited < timeoutNanoseconds
            {
                try await Task.sleep(nanoseconds: interval)
                waited += interval
            }
            XCTAssertEqual(
                manager.workspaceSearchReadinessWaiterCountForTesting,
                expectedCount,
                file: file,
                line: line
            )
        }

        private func assertAsyncTrue(
            _ value: Bool,
            _ message: @autoclosure () -> String = "",
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertTrue(value, message(), file: file, line: line)
        }

        /// Pins the store's broad-search lane to one active lease and one waiter so the
        /// queue/overflow choreography stays deterministic under the burst-capacity production policy.
        private func configureSingleLeaseSearchLane(
            _ store: WorkspaceFileContextStore,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            let configuration = StoreBackedWorkspaceSearchLane.Configuration(
                maxQueueWait: .milliseconds(1500)
            )
            guard case .applied = await store.configureSearchLaneForTesting(configuration) else {
                return XCTFail(
                    "Expected the idle store lane to accept the single-lease test configuration",
                    file: file,
                    line: line
                )
            }
        }

        private func waitForAdmissionWaiterCount(
            _ expectedCount: Int,
            store: WorkspaceFileContextStore,
            timeoutNanoseconds: UInt64 = 1_000_000_000
        ) async -> Bool {
            let interval: UInt64 = 10_000_000
            var waited: UInt64 = 0
            while await store.searchLaneSnapshotForTesting().waiterCount != expectedCount, waited < timeoutNanoseconds {
                try? await Task.sleep(nanoseconds: interval)
                waited += interval
            }
            return await store.searchLaneSnapshotForTesting().waiterCount == expectedCount
        }

        private func waitForSearchLaneIdle(
            store: WorkspaceFileContextStore,
            timeoutNanoseconds: UInt64 = 1_000_000_000
        ) async -> Bool {
            let interval: UInt64 = 10_000_000
            var waited: UInt64 = 0
            while await !store.searchLaneSnapshotForTesting().isIdle, waited < timeoutNanoseconds {
                try? await Task.sleep(nanoseconds: interval)
                waited += interval
            }
            return await store.searchLaneSnapshotForTesting().isIdle
        }

        private func waitForCacheIdle(
            store: WorkspaceFileContextStore,
            timeoutNanoseconds: UInt64 = 1_000_000_000
        ) async -> WorkspaceSearchDecodedContentCache.Snapshot {
            let interval: UInt64 = 10_000_000
            var waited: UInt64 = 0
            while waited < timeoutNanoseconds {
                let snapshot = await store.searchDecodedContentCacheSnapshotForTesting()
                if snapshot.activeFlightCount == 0, snapshot.waiterCount == 0 {
                    return snapshot
                }
                try? await Task.sleep(nanoseconds: interval)
                waited += interval
            }
            return await store.searchDecodedContentCacheSnapshotForTesting()
        }

        private func waitForLifecycleEvent(
            _ eventName: String,
            correlationID: UUID,
            timeoutNanoseconds: UInt64 = 1_000_000_000
        ) async -> Bool {
            let interval: UInt64 = 10_000_000
            var waited: UInt64 = 0
            while waited < timeoutNanoseconds {
                let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: false)
                if snapshot.lifecycleEvents.contains(where: {
                    $0.eventName == eventName && $0.correlationID == correlationID.uuidString
                }) {
                    return true
                }
                try? await Task.sleep(nanoseconds: interval)
                waited += interval
            }
            return false
        }

        private func dimensionInt(_ key: String, in dimensions: String) -> Int? {
            let prefix = "\(key)="
            guard let component = dimensions.split(separator: " ").first(where: { $0.hasPrefix(prefix) }) else {
                return nil
            }
            return Int(component.dropFirst(prefix.count))
        }

        private func startedCapture(label: String, maxSamples: Int) -> EditFlowPerf.DebugCaptureSnapshot {
            switch EditFlowPerf.beginDebugCapture(label: label, maxSamples: maxSamples) {
            case let .started(snapshot):
                return snapshot
            case .busy:
                XCTFail("Capture should start.")
                fatalError("Capture should start.")
            }
        }
    #endif

    private func assertOrdered(_ needles: [String], in source: String) throws {
        var lowerBound = source.startIndex
        for needle in needles {
            let range = try XCTUnwrap(source.range(of: needle, range: lowerBound ..< source.endIndex), "Missing ordered source fragment: \(needle)")
            lowerBound = range.upperBound
        }
    }

    #if DEBUG
        private actor AsyncCounter {
            private var count = 0

            func incrementAndValue() -> Int {
                count += 1
                return count
            }

            func currentValue() -> Int {
                count
            }

            func waitUntilValue(atLeast target: Int, timeoutNanoseconds: UInt64 = 1_000_000_000) async -> Bool {
                let interval: UInt64 = 10_000_000
                var waited: UInt64 = 0
                while count < target, waited < timeoutNanoseconds {
                    try? await Task.sleep(nanoseconds: interval)
                    waited += interval
                }
                return count >= target
            }
        }

        private actor AsyncSignal {
            private var marked = false

            func mark() {
                marked = true
            }

            func waitUntilMarked(timeoutNanoseconds: UInt64 = 1_000_000_000) async -> Bool {
                let interval: UInt64 = 10_000_000
                var waited: UInt64 = 0
                while !marked, waited < timeoutNanoseconds {
                    try? await Task.sleep(nanoseconds: interval)
                    waited += interval
                }
                return marked
            }
        }

        private actor AsyncGate {
            private var startedCount = 0
            private var released = false
            private var startWaiters: [CheckedContinuation<Void, Never>] = []
            private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

            func markStartedAndWaitForRelease() async {
                startedCount += 1
                let waiters = startWaiters
                startWaiters.removeAll()
                waiters.forEach { $0.resume() }
                guard !released else { return }
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }

            func waitUntilStarted() async {
                guard startedCount == 0 else { return }
                await withCheckedContinuation { continuation in
                    startWaiters.append(continuation)
                }
            }

            func waitUntilStartedWithinTimeout(timeoutNanoseconds: UInt64 = 1_000_000_000) async -> Bool {
                await waitUntilStartedCount(1, timeoutNanoseconds: timeoutNanoseconds)
            }

            func waitUntilStartedCount(_ expectedCount: Int, timeoutNanoseconds: UInt64 = 1_000_000_000) async -> Bool {
                let interval: UInt64 = 10_000_000
                var waited: UInt64 = 0
                while startedCount < expectedCount, waited < timeoutNanoseconds {
                    try? await Task.sleep(nanoseconds: interval)
                    waited += interval
                }
                return startedCount >= expectedCount
            }

            func release() {
                released = true
                let waiters = releaseWaiters
                releaseWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
    #endif

    private func makeTemporaryRoot(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryRoots.append(url)
        return url
    }

    private func makeHomeTemporaryRoot(name: String) throws -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".RepoPromptTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryRoots.append(url)
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
