import Foundation
@testable import RepoPrompt
import XCTest

#if DEBUG
    final class WorkspaceFileSearchIndexTimeToReadyBenchmarkTests: XCTestCase {
        private struct BenchmarkInvariantError: Error {
            let message: String
        }

        func testFallbackReasonDeltaRenderingIsDeterministic() throws {
            let rootID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
            let lifetimeID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
            let counters = WorkspaceFileSearchIndexBenchmarkCounters(
                rootID: rootID,
                lifetimeID: lifetimeID,
                topologyGeneration: 42,
                crawl: 1,
                appliedGeneration: 1,
                shardBuild: 4,
                patch: 1,
                authoritative: 3,
                pathIndexBuild: 2,
                overlayPathIndexBuild: 1,
                fallback: 4,
                fallbackReasonDeltas: [
                    .shadowValidationMismatch: 1,
                    .fullResync: 0,
                    .patchApplicationBackstop: 1,
                    .generationGap: 2
                ],
                catalogRebuild: 3,
                catalogInvalidation: 2
            )

            XCTAssertEqual(
                WorkspaceFileContextStore.RootCatalogShardFallbackReason.allCases.map(\.rawValue),
                [
                    "missingReusableShard",
                    "generationGap",
                    "fullResync",
                    "unsafeOrAmbiguousBatch",
                    "retentionBoundary",
                    "patchThresholdExceeded",
                    "patchApplicationBackstop",
                    "shadowValidationMismatch"
                ]
            )
            XCTAssertTrue(counters.fallbackReasonDeltasAreNonnegative)
            XCTAssertEqual(counters.fallbackReasonDeltaSum, counters.fallback)
            XCTAssertEqual(
                counters.fallbackDiagnosticDescription(),
                "rootID=11111111-2222-3333-4444-555555555555, "
                    + "lifetimeID=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE, topology generation=42; "
                    + "fallback Δ=4; reasons=[generationGap=2, patchApplicationBackstop=1, shadowValidationMismatch=1]; "
                    + "crawl=1 shard=4 patch=1 authoritative=3 full=2 overlay=1"
            )
        }

        func testLargeRepositoryTimeToReadyBenchmark() async throws {
            let metricsEnabled = WorkspaceFileSearchIndexBenchmarkRuntimeConfiguration.isEnabled(
                environmentKey: "RP_RUN_FILE_SEARCH_INDEX_METRICS",
                configurationKey: "metricsEnabled"
            )
            let sortDiagnosticsEnabled = WorkspaceFileSearchIndexBenchmarkRuntimeConfiguration.isEnabled(
                environmentKey: "RP_RUN_FILE_SEARCH_INDEX_SORT_DIAGNOSTICS",
                configurationKey: "sortDiagnosticsEnabled"
            )
            try XCTSkipUnless(
                metricsEnabled
                    || WorkspaceFileSearchIndexBenchmarkRun.reportURLFromEnvironment != nil
                    || FileManager.default.fileExists(atPath: "/tmp/RepoPromptCE-file-search-index-opt-in"),
                "CE file-search index benchmark is opt-in. Set RP_RUN_FILE_SEARCH_INDEX_METRICS=1, RP_CE_FILE_SEARCH_INDEX_REPORT_PATH, or create /tmp/RepoPromptCE-file-search-index-opt-in."
            )

            let fixture = try WorkspaceFileSearchIndexBenchmarkFixture.make()
            defer { fixture.remove() }
            let environment = WorkspaceFileSearchIndexBenchmarkEnvironment.capture()
            let coldWorktree = try await runColdWorktreeScenario(fixture: fixture)
            let incrementalRebuild = try await runIncrementalRebuildScenario(fixture: fixture)
            let sortDiagnostic: WorkspaceFileSearchIndexSortDiagnostic? = if metricsEnabled, sortDiagnosticsEnabled {
                try await runSortAttributionProbe()
            } else {
                nil
            }
            let run = WorkspaceFileSearchIndexBenchmarkRun(
                environment: environment,
                coldWorktree: coldWorktree,
                incrementalRebuild: incrementalRebuild,
                sortDiagnostic: sortDiagnostic
            )
            try print(run.consoleReport())
            if let reportURL = WorkspaceFileSearchIndexBenchmarkRun.reportURLFromEnvironment {
                try run.appendMarkdown(to: reportURL)
            }
        }

        private func runColdWorktreeScenario(
            fixture: WorkspaceFileSearchIndexBenchmarkFixture
        ) async throws -> WorkspaceFileSearchIndexBenchmarkAggregate {
            let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
            addTeardownBlock { await self.unloadAllRoots(in: store) }
            let visibleRoot = try await store.loadRoot(path: fixture.visibleRootURL.path)
            await store.stopWatchingRoot(id: visibleRoot.id)
            let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)

            var warmup: WorkspaceFileSearchIndexBenchmarkSample?
            var measured: [WorkspaceFileSearchIndexBenchmarkSample] = []
            for sampleIndex in 0 ... 5 {
                let isWarmup = sampleIndex == 0
                let sample = try await runColdWorktreeSample(
                    ordinal: isWarmup ? 0 : sampleIndex,
                    phase: isWarmup ? "warmup-excluded" : "measured",
                    fixture: fixture,
                    visibleRoot: visibleRoot,
                    store: store,
                    materializer: materializer
                )
                if isWarmup {
                    warmup = sample
                } else {
                    measured.append(sample)
                }
            }
            await unloadAllRoots(in: store)
            return try WorkspaceFileSearchIndexBenchmarkAggregate(
                scenario: "cold-worktree-first-scoped-search",
                warmup: XCTUnwrap(warmup),
                measured: measured
            )
        }

        private func runColdWorktreeSample(
            ordinal: Int,
            phase: String,
            fixture: WorkspaceFileSearchIndexBenchmarkFixture,
            visibleRoot: WorkspaceRootRecord,
            store: WorkspaceFileContextStore,
            materializer: WorkspaceRootBindingProjectionMaterializer
        ) async throws -> WorkspaceFileSearchIndexBenchmarkSample {
            let worktreePath = fixture.worktreeRootURL.standardizedFileURL.path
            let rootsBefore = await store.roots()
            try require(!rootsBefore.contains { $0.standardizedFullPath == worktreePath }, "Worktree must be unloaded before a cold sample")
            let ownershipBefore = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()
            try require(ownershipBefore.installedOwnerCount == 0, "Cold sample must begin without installed ownership")
            try require(ownershipBefore.provisionalOwnerCount == 0, "Cold sample must begin without provisional ownership")
            try require(ownershipBefore.rootClaimCount == 0, "Cold sample must begin without worktree claims")

            let sessionID = UUID()
            let binding = AgentSessionWorktreeBinding(
                id: "file-search-benchmark-\(sessionID.uuidString)",
                repositoryID: "file-search-benchmark-repository",
                repoKey: "file-search-benchmark",
                logicalRootPath: visibleRoot.standardizedFullPath,
                logicalRootName: visibleRoot.name,
                worktreeID: "file-search-benchmark-\(ordinal)-\(sessionID.uuidString)",
                worktreeRootPath: worktreePath,
                worktreeName: fixture.worktreeRootURL.lastPathComponent,
                source: "file_search_index_benchmark"
            )
            let before = await WorkspaceFileSearchIndexBenchmarkCounterMark.capture(store: store)
            let started = DispatchTime.now()
            let preparation = try await materializer.prepare(sessionID: sessionID, bindings: [binding])

            do {
                let committedProjection = try await materializer.commit(preparation)
                let projection = try XCTUnwrap(committedProjection)
                let materialized = DispatchTime.now()
                let phaseCollector = WorkspaceFileSearchPhaseCollector()
                let result = try await WorkspaceFileSearchDebugContext.$collector.withValue(phaseCollector) {
                    try await StoreBackedWorkspaceSearch.search(
                        pattern: "FirstScopedNeedle",
                        mode: .path,
                        maxPaths: 1,
                        rootScope: projection.lookupRootScope,
                        store: store,
                        workspaceManager: nil
                    )
                }
                let finished = DispatchTime.now()
                let phases = phaseCollector.snapshot(
                    readySearchNanoseconds: finished.uptimeNanoseconds - materialized.uptimeNanoseconds
                )
                let physicalRootID = try XCTUnwrap(projection.physicalRootRefs.first?.id)
                let snapshot = await store.searchCatalogSnapshot(
                    rootScope: projection.lookupRootScope,
                    requirement: .recordsOnly
                )
                let after = await WorkspaceFileSearchIndexBenchmarkCounterMark.capture(
                    store: store,
                    rootID: physicalRootID
                )
                let counters = after.delta(from: before)

                try require(projection.isFullyMaterialized, "Cold projection must be fully materialized")
                try require(phases.status == .completed, "Cold phase collector must complete")
                try require(result.paths == [fixture.firstScopedNeedleURL.path], "Cold search must return the worktree needle")
                try require(!(result.paths?.contains { $0.hasPrefix(fixture.visibleRootURL.path) } ?? false), "Cold search must not substitute the visible root")
                try require(snapshot.diagnostics.fileCount == WorkspaceFileSearchIndexBenchmarkFixture.seedFileCount, "Cold snapshot file count must match the fixture")
                try require(snapshot.diagnostics.folderCount == WorkspaceFileSearchIndexBenchmarkFixture.folderCount, "Cold snapshot folder count must match the fixture")
                try require(counters.crawl == 1, "Cold sample must perform one crawl")
                try require(counters.shardBuild == 1, "Cold sample must build one shard")
                try require(counters.patch == 0, "Cold sample must not patch a shard")
                try require(counters.authoritative == 1, "Cold sample must perform one authoritative shard build")
                try require(counters.pathIndexBuild == 0, "Cold sample must not build a full path index")
                try require(counters.overlayPathIndexBuild == 0, "Cold sample must not build an overlay")
                try require(phases.catalog.pathIndexKeyMicroseconds == 0, "Cold path-index key phase must be zero")
                try require(
                    phases.catalog.pathIndexConstructionMicroseconds == 0,
                    "Cold path-index construction phase must be zero"
                )
                try require(
                    counterVector(counters) == [1, 0, 1, 0, 1, 0, 0, 0, 1, 1],
                    "Cold counter vector must match the records-only contract"
                )
                let fallbackDiagnostics = counters.fallbackDiagnosticDescription()
                try require(
                    counters.fallbackReasonDeltasAreNonnegative,
                    "Cold fallback reason deltas must not be negative; \(fallbackDiagnostics)"
                )
                try require(
                    counters.fallback == counters.fallbackReasonDeltaSum,
                    "Cold aggregate fallback delta must equal the reason delta sum; \(fallbackDiagnostics)"
                )
                try require(
                    counters.fallback == 0,
                    "Cold sample must not fall back",
                    diagnostics: fallbackDiagnostics
                )

                await materializer.release(sessionID: sessionID)
                let rootsAfter = await store.roots()
                try require(!rootsAfter.contains { $0.id == physicalRootID }, "Released worktree must unload before the next sample")
                let ownershipAfter = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()
                try require(ownershipAfter.installedOwnerCount == 0, "Released sample must clear installed ownership")
                try require(ownershipAfter.rootClaimCount == 0, "Released sample must clear worktree claims")

                return WorkspaceFileSearchIndexBenchmarkSample(
                    ordinal: ordinal,
                    phase: phase,
                    totalWallMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: started, to: finished),
                    preSearchMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: started, to: materialized),
                    searchMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: materialized, to: finished),
                    counters: counters,
                    phases: phases
                )
            } catch {
                await materializer.abort(preparation)
                await materializer.release(sessionID: sessionID)
                throw error
            }
        }

        private func runIncrementalRebuildScenario(
            fixture: WorkspaceFileSearchIndexBenchmarkFixture
        ) async throws -> WorkspaceFileSearchIndexBenchmarkAggregate {
            let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
            addTeardownBlock { await self.unloadAllRoots(in: store) }
            let visibleRoot = try await store.loadRoot(path: fixture.visibleRootURL.path)
            await store.stopWatchingRoot(id: visibleRoot.id)
            let worktreeRoot = try await store.loadRoot(path: fixture.worktreeRootURL.path, kind: .sessionWorktree)
            try await store.startWatchingRoot(id: worktreeRoot.id)
            let loadedService = await store.fileSystemServiceForTesting(rootID: worktreeRoot.id)
            let service = try XCTUnwrap(loadedService)
            await service.stopWatchingForChanges()
            _ = await store.awaitAppliedIngressForAllRoots()
            let watcherIsActive = try await store.rootWatcherIsActiveForTesting(rootID: worktreeRoot.id)
            try require(!watcherIsActive, "Incremental scenario must exclude live FSEvents")

            let scope = WorkspaceLookupRootScope.sessionBoundWorkspace(
                canonicalRootPaths: [],
                physicalRootPaths: [fixture.worktreeRootURL.standardizedFileURL.path]
            )
            _ = await store.searchCatalogSnapshot(rootScope: scope, requirement: .recordsOnly)
            let initialResult = try await StoreBackedWorkspaceSearch.search(
                pattern: "FirstScopedNeedle",
                mode: .path,
                maxPaths: 1,
                rootScope: scope,
                store: store,
                workspaceManager: nil
            )
            try require(initialResult.paths == [fixture.firstScopedNeedleURL.path], "Incremental scenario warm search must find the seed needle")

            var warmup: WorkspaceFileSearchIndexBenchmarkSample?
            var measured: [WorkspaceFileSearchIndexBenchmarkSample] = []
            for sampleIndex in 0 ... 5 {
                let isWarmup = sampleIndex == 0
                let relativePath = isWarmup
                    ? "IncrementalNeedle-Warmup.swift"
                    : String(format: "IncrementalNeedle-%02d.swift", sampleIndex - 1)
                let sample = try await runIncrementalRebuildSample(
                    ordinal: isWarmup ? 0 : sampleIndex,
                    phase: isWarmup ? "warmup-excluded" : "measured",
                    relativePath: relativePath,
                    fixture: fixture,
                    rootID: worktreeRoot.id,
                    scope: scope,
                    store: store
                )
                if isWarmup {
                    warmup = sample
                } else {
                    measured.append(sample)
                }
            }
            await unloadAllRoots(in: store)
            return try WorkspaceFileSearchIndexBenchmarkAggregate(
                scenario: "incremental-one-file-ready-search",
                warmup: XCTUnwrap(warmup),
                measured: measured
            )
        }

        private func runIncrementalRebuildSample(
            ordinal: Int,
            phase: String,
            relativePath: String,
            fixture: WorkspaceFileSearchIndexBenchmarkFixture,
            rootID: UUID,
            scope: WorkspaceLookupRootScope,
            store: WorkspaceFileContextStore
        ) async throws -> WorkspaceFileSearchIndexBenchmarkSample {
            let fileURL = try fixture.writeMutationFile(relativePath: relativePath)
            let before = await WorkspaceFileSearchIndexBenchmarkCounterMark.capture(store: store, rootID: rootID)
            let started = DispatchTime.now()
            try await store.publishSyntheticFileSystemDeltasForTesting(
                rootID: rootID,
                deltas: [.fileAdded(relativePath)]
            )
            let published = DispatchTime.now()
            let phaseCollector = WorkspaceFileSearchPhaseCollector()
            let result = try await WorkspaceFileSearchDebugContext.$collector.withValue(phaseCollector) {
                try await StoreBackedWorkspaceSearch.search(
                    pattern: relativePath,
                    mode: .path,
                    maxPaths: 1,
                    rootScope: scope,
                    store: store,
                    workspaceManager: nil
                )
            }
            let finished = DispatchTime.now()
            let phases = phaseCollector.snapshot(
                readySearchNanoseconds: finished.uptimeNanoseconds - published.uptimeNanoseconds
            )
            let after = await WorkspaceFileSearchIndexBenchmarkCounterMark.capture(store: store, rootID: rootID)
            let counters = after.delta(from: before)
            let snapshot = await store.searchCatalogSnapshot(rootScope: scope, requirement: .recordsOnly)
            let workDiagnostics = await store.storeWorkDiagnosticsSnapshot()
            let shardDiagnostics = try XCTUnwrap(
                workDiagnostics.rootCatalogShards.roots.first { $0.rootID == rootID }
            )

            try require(phases.status == .completed, "Incremental phase collector must complete")
            try require(result.paths == [fileURL.path], "Incremental search must return the added path")
            try require(snapshot.files.contains { $0.standardizedFullPath == fileURL.path }, "Fresh scoped snapshot must contain the added path")
            try require(counters.appliedGeneration == 1, "Incremental sample must advance one applied generation")
            try require(counters.crawl == 0, "Incremental sample must not crawl")
            try require(counters.shardBuild == 1, "Incremental sample must build one shard")
            try require(counters.patch == 1, "Incremental sample must apply one shard patch")
            try require(counters.authoritative == 0, "Incremental sample must not rebuild authoritatively")
            try require(counters.pathIndexBuild == 0, "Incremental sample must not build a full path index")
            try require(counters.overlayPathIndexBuild == 0, "Incremental sample must not build an overlay")
            try require(
                counterVector(counters) == [0, 1, 1, 1, 0, 0, 0, 0, 1, 1],
                "Incremental counter vector must match the records-only contract"
            )
            let fallbackDiagnostics = counters.fallbackDiagnosticDescription()
            try require(
                counters.fallbackReasonDeltasAreNonnegative,
                "Incremental fallback reason deltas must not be negative; \(fallbackDiagnostics)"
            )
            try require(
                counters.fallback == counters.fallbackReasonDeltaSum,
                "Incremental aggregate fallback delta must equal the reason delta sum; \(fallbackDiagnostics)"
            )
            try require(
                counters.fallback == 0,
                "Incremental sample must not fall back",
                diagnostics: fallbackDiagnostics
            )
            try require(shardDiagnostics.lastAppliedIndexGeneration == after.appliedGeneration, "Fresh shard generation must match the applied generation")
            try require(!shardDiagnostics.deltaStateDirty, "Fresh shard delta state must remain clean")
            let watcherIsStillActive = try await store.rootWatcherIsActiveForTesting(rootID: rootID)
            try require(!watcherIsStillActive, "Live FSEvents must remain stopped during incremental samples")

            return WorkspaceFileSearchIndexBenchmarkSample(
                ordinal: ordinal,
                phase: phase,
                totalWallMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: started, to: finished),
                preSearchMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: started, to: published),
                searchMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: published, to: finished),
                counters: counters,
                phases: phases
            )
        }

        private func runSortAttributionProbe() async throws -> WorkspaceFileSearchIndexSortDiagnostic {
            let fixture = try WorkspaceFileSearchIndexBenchmarkFixture.make()
            defer { fixture.remove() }

            let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
            let worktreeRoot = try await store.loadRoot(
                path: fixture.worktreeRootURL.path,
                kind: .sessionWorktree
            )
            let scope = WorkspaceLookupRootScope.sessionBoundWorkspace(
                canonicalRootPaths: [],
                physicalRootPaths: [fixture.worktreeRootURL.standardizedFileURL.path]
            )
            let before = await WorkspaceFileSearchIndexBenchmarkCounterMark.capture(
                store: store,
                rootID: worktreeRoot.id
            )
            let workBefore = await store.storeWorkDiagnosticsSnapshot()
            let catalogCacheBefore = await store.searchCatalogSnapshotCacheCountForTesting()
            let staticCacheBefore = await store.staticPathMatchSnapshotCacheCountForTesting()
            let sessionGenerationBefore = await store.sessionCatalogGenerationForTesting(scope: scope)
            let rootsBefore = await store.roots().map(\.id)

            let probe = await store.debugAuthoritativeCatalogSortProbe(rootScope: scope)

            let after = await WorkspaceFileSearchIndexBenchmarkCounterMark.capture(
                store: store,
                rootID: worktreeRoot.id
            )
            let workAfter = await store.storeWorkDiagnosticsSnapshot()
            let catalogCacheAfter = await store.searchCatalogSnapshotCacheCountForTesting()
            let staticCacheAfter = await store.staticPathMatchSnapshotCacheCountForTesting()
            let sessionGenerationAfter = await store.sessionCatalogGenerationForTesting(scope: scope)
            let rootsAfter = await store.roots().map(\.id)
            let counters = after.delta(from: before)
            let storeStateUnchanged = counterVector(counters).allSatisfy { $0 == 0 }
                && workAfter == workBefore
                && catalogCacheAfter == catalogCacheBefore
                && staticCacheAfter == staticCacheBefore
                && sessionGenerationAfter == sessionGenerationBefore
                && rootsAfter == rootsBefore

            try require(probe.status == .completed, "Sort attribution probe must complete")
            try require(
                probe.sourceFileCount == WorkspaceFileSearchIndexBenchmarkFixture.seedFileCount,
                "Sort attribution probe file count must match the fresh fixture"
            )
            try require(
                probe.sourceFolderCount == WorkspaceFileSearchIndexBenchmarkFixture.folderCount,
                "Sort attribution probe folder count must match the fresh fixture"
            )
            try require(probe.samples.count == 3, "Sort attribution probe must retain three samples")
            try require(
                probe.directAndProjectedOrdersMatch,
                "Sort attribution probe direct/projected ordering must match"
            )
            try require(storeStateUnchanged, "Sort attribution probe must not mutate store state")
            await unloadAllRoots(in: store)
            return WorkspaceFileSearchIndexSortDiagnostic(
                probe: probe,
                storeStateUnchanged: storeStateUnchanged
            )
        }

        private func counterVector(_ counters: WorkspaceFileSearchIndexBenchmarkCounters) -> [Int] {
            [
                counters.crawl,
                counters.appliedGeneration,
                counters.shardBuild,
                counters.patch,
                counters.authoritative,
                counters.pathIndexBuild,
                counters.overlayPathIndexBuild,
                counters.fallback,
                counters.catalogRebuild,
                counters.catalogInvalidation
            ]
        }

        private func require(
            _ condition: @autoclosure () -> Bool,
            _ message: String,
            diagnostics: String? = nil,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            guard condition() else {
                let failureMessage = diagnostics.map { "\(message); \($0)" } ?? message
                XCTFail(failureMessage, file: file, line: line)
                throw BenchmarkInvariantError(message: failureMessage)
            }
        }

        private func unloadAllRoots(in store: WorkspaceFileContextStore) async {
            let rootIDs = await store.roots().map(\.id)
            await store.unloadRoots(ids: rootIDs)
        }
    }
#endif
