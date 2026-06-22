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
            let productionEquivalent = try await runProductionEquivalentScenario()
            let incrementalRebuild = try await runIncrementalRebuildScenario(fixture: fixture)
            let sortDiagnostic: WorkspaceFileSearchIndexSortDiagnostic? = if metricsEnabled, sortDiagnosticsEnabled {
                try await runSortAttributionProbe()
            } else {
                nil
            }
            let run = WorkspaceFileSearchIndexBenchmarkRun(
                environment: environment,
                coldWorktree: coldWorktree,
                productionEquivalent: productionEquivalent,
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
                    coldCounterVectorIsValid(counters, pathIndexBuild: 0),
                    "Cold counter vector must match the records-only contract with at most one watcher-applied generation",
                    diagnostics: "actual=\(counterVector(counters))"
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
                    cumulativeSearchMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: started, to: finished),
                    readMilliseconds: 0,
                    counters: counters,
                    phases: phases,
                    coldStart: nil
                )
            } catch {
                await materializer.abort(preparation)
                await materializer.release(sessionID: sessionID)
                throw error
            }
        }

        private func runProductionEquivalentScenario() async throws -> WorkspaceFileSearchIndexBenchmarkAggregate {
            var warmup: WorkspaceFileSearchIndexBenchmarkSample?
            var measured: [WorkspaceFileSearchIndexBenchmarkSample] = []
            for sampleIndex in 0 ... 5 {
                let isWarmup = sampleIndex == 0
                let sample = try await runProductionEquivalentSample(
                    ordinal: isWarmup ? 0 : sampleIndex,
                    phase: isWarmup ? "warmup-excluded" : "measured"
                )
                if isWarmup {
                    warmup = sample
                } else {
                    measured.append(sample)
                }
            }
            return try WorkspaceFileSearchIndexBenchmarkAggregate(
                scenario: "materialize-first-scoped-content-search-first-read",
                warmup: XCTUnwrap(warmup),
                measured: measured
            )
        }

        private func runProductionEquivalentSample(
            ordinal: Int,
            phase: String
        ) async throws -> WorkspaceFileSearchIndexBenchmarkSample {
            let fixture = try WorkspaceFileSearchIndexBenchmarkFixture.make()
            defer { fixture.remove() }
            let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
            addTeardownBlock { await self.unloadAllRoots(in: store) }
            let visibleRoot = try await store.loadRoot(path: fixture.visibleRootURL.path)
            await store.stopWatchingRoot(id: visibleRoot.id)
            let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
            let worktreePath = fixture.worktreeRootURL.standardizedFileURL.path
            let rootsBefore = await store.roots()
            try require(
                !rootsBefore.contains { $0.standardizedFullPath == worktreePath },
                "Production-equivalent sample must start with the worktree unloaded"
            )
            let ownershipBefore = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()
            try require(ownershipBefore.installedOwnerCount == 0, "Sample must begin without installed ownership")
            try require(ownershipBefore.provisionalOwnerCount == 0, "Sample must begin without provisional ownership")
            try require(ownershipBefore.rootClaimCount == 0, "Sample must begin without worktree claims")

            let sessionID = UUID()
            let binding = AgentSessionWorktreeBinding(
                id: "file-tools-benchmark-\(sessionID.uuidString)",
                repositoryID: "file-tools-benchmark-repository",
                repoKey: "file-tools-benchmark",
                logicalRootPath: visibleRoot.standardizedFullPath,
                logicalRootName: visibleRoot.name,
                worktreeID: "file-tools-benchmark-\(ordinal)-\(sessionID.uuidString)",
                worktreeRootPath: worktreePath,
                worktreeName: fixture.worktreeRootURL.lastPathComponent,
                source: "file_tools_benchmark"
            )
            let before = await WorkspaceFileSearchIndexBenchmarkCounterMark.capture(store: store)
            let limiterBefore = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
            let coldStartCollector = WorkspaceFileSearchColdStartCollector()
            let searchPhaseCollector = WorkspaceFileSearchPhaseCollector()
            let started = DispatchTime.now()

            do {
                let workload = try await WorkspaceFileSearchDebugContext.$coldStartCollector.withValue(coldStartCollector) {
                    let maybeProjection = await materializer.materialize(sessionID: sessionID, bindings: [binding])
                    let projection = try XCTUnwrap(maybeProjection)
                    let materialized = DispatchTime.now()
                    let searchResult = try await WorkspaceFileSearchDebugContext.$collector.withValue(searchPhaseCollector) {
                        try await StoreBackedWorkspaceSearch.search(
                            pattern: WorkspaceFileSearchIndexBenchmarkFixture.firstScopedContentNeedle,
                            mode: .content,
                            maxPaths: 1,
                            rootScope: projection.lookupRootScope,
                            store: store,
                            workspaceManager: nil
                        )
                    }
                    let searchFinished = DispatchTime.now()

                    let logicalNeedlePath = fixture.visibleRootURL
                        .appendingPathComponent(WorkspaceFileSearchIndexBenchmarkFixture.firstScopedNeedleRelativePath)
                        .path
                    let physicalReadPath = projection.translateInputPath(logicalNeedlePath)
                    let readableService = WorkspaceReadableFileService(store: store)
                    let roots = await store.rootRefs(scope: projection.lookupRootScope)
                    try await readableService.awaitFreshnessForExplicitRequest(physicalReadPath, rootRefs: roots)
                    let resolution = await readableService.resolveReadFileRequest(
                        physicalReadPath,
                        profile: .mcpRead,
                        rootScope: projection.lookupRootScope,
                        rootRefs: roots
                    )
                    guard case let .readable(.workspace(file)) = resolution else {
                        throw BenchmarkInvariantError(message: "Production-equivalent read must resolve the scoped worktree file")
                    }
                    guard let readSnapshot = try await store.interactiveReadSnapshot(for: file) else {
                        throw BenchmarkInvariantError(message: "Production-equivalent read content must be available")
                    }
                    let readFinished = DispatchTime.now()
                    let coldStartAtReadCompletion = coldStartCollector.snapshot()
                    return (
                        projection: projection,
                        materialized: materialized,
                        searchResult: searchResult,
                        searchFinished: searchFinished,
                        readFile: file,
                        readContent: readSnapshot.preparedContent.linesWithEndings.joined(),
                        readFinished: readFinished,
                        coldStart: coldStartAtReadCompletion
                    )
                }

                let searchPhases = searchPhaseCollector.snapshot(
                    readySearchNanoseconds: workload.searchFinished.uptimeNanoseconds - workload.materialized.uptimeNanoseconds
                )
                let physicalRootID = try XCTUnwrap(workload.projection.physicalRootRefs.first?.id)
                let after = await WorkspaceFileSearchIndexBenchmarkCounterMark.capture(
                    store: store,
                    rootID: physicalRootID
                )
                let counters = after.delta(from: before)
                let limiterAfter = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
                let catalogSnapshot = await store.searchCatalogSnapshot(
                    rootScope: workload.projection.lookupRootScope,
                    requirement: .recordsOnly
                )

                try require(workload.projection.isFullyMaterialized, "Production materializer must produce a fully materialized projection")
                try require(
                    limiterAfter.codemapGrantWhileForegroundCount == limiterBefore.codemapGrantWhileForegroundCount,
                    "Production-equivalent foreground boundaries must not grant codemap permits"
                )
                try require(limiterAfter.foregroundActivityCount == 0, "Foreground activity tokens must be balanced at first-read completion")
                try require(searchPhases.status == .completed, "Content-search phase collector must complete")
                try require(
                    workload.searchResult.matches?.map(\.filePath) == [fixture.firstScopedNeedleURL.path],
                    "Scoped content search must return only the physical worktree needle"
                )
                try require(
                    !(workload.searchResult.matches?.contains { $0.filePath.hasPrefix(fixture.visibleRootURL.path) } ?? false),
                    "Scoped content search must not fall back to the canonical visible root"
                )
                try require(
                    workload.projection.logicalDisplayPath(forPhysicalPath: workload.readFile.standardizedFullPath, display: .full)
                        == fixture.visibleRootURL
                        .appendingPathComponent(WorkspaceFileSearchIndexBenchmarkFixture.firstScopedNeedleRelativePath)
                        .path,
                    "Physical worktree reads must retain the logical display projection"
                )
                try require(
                    workload.readContent == WorkspaceFileSearchIndexBenchmarkFixture.firstScopedNeedleContents,
                    "First read must return the exact worktree-only content"
                )
                try require(catalogSnapshot.diagnostics.fileCount == WorkspaceFileSearchIndexBenchmarkFixture.seedFileCount, "Scoped catalog file count must match the fixture")
                try require(counters.crawl == 1, "Production-equivalent sample must perform one crawl")
                try require(counters.shardBuild == 1, "Production-equivalent sample must build one shard")
                try require(counters.patch == 0, "Production-equivalent sample must not patch a shard")
                try require(counters.authoritative == 1, "Production-equivalent sample must perform one authoritative shard build")
                try require(counters.pathIndexBuild == 1, "Current content search must build one full path index")
                try require(counters.overlayPathIndexBuild == 0, "Cold content search must not build an overlay")
                try require(
                    coldCounterVectorIsValid(counters, pathIndexBuild: 1),
                    "Production-equivalent counter vector must match current content-search behavior with at most one watcher-applied generation"
                )
                try require(counters.fallback == 0, "Production-equivalent sample must not fall back", diagnostics: counters.fallbackDiagnosticDescription())

                await materializer.release(sessionID: sessionID)
                let rootsAfter = await store.roots()
                try require(!rootsAfter.contains { $0.id == physicalRootID }, "Released production-equivalent worktree must unload")
                let ownershipAfter = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()
                try require(ownershipAfter.installedOwnerCount == 0, "Released sample must clear installed ownership")
                try require(ownershipAfter.provisionalOwnerCount == 0, "Released sample must clear provisional ownership")
                try require(ownershipAfter.rootClaimCount == 0, "Released sample must clear worktree claims")
                await unloadAllRoots(in: store)

                let coldStart = workload.coldStart
                try require(coldStart.rootCrawl.count == 1, "Cold-start attribution must contain exactly one root crawl")
                try require(
                    coldStart.rootCrawl.filesDiscovered == WorkspaceFileSearchIndexBenchmarkFixture.seedFileCount,
                    "Cold-start crawl attribution must count every fixture file"
                )
                for workloadName in [ContentReadWorkloadClass.contentSearch.rawValue, ContentReadWorkloadClass.interactiveRead.rawValue] {
                    let scheduler = try XCTUnwrap(coldStart.schedulerByWorkload[workloadName])
                    try require(scheduler.requestCount > 0, "Foreground scheduler attribution must include \(workloadName)")
                    try require(scheduler.requestCount == scheduler.grantCount, "Foreground scheduler grants must match requests for \(workloadName)")
                    try require(scheduler.requestCount == scheduler.completionCount, "Foreground scheduler completions must match requests for \(workloadName)")
                    try require(scheduler.cancellationCount == 0, "Foreground scheduler work must not be cancelled for \(workloadName)")
                    try require(scheduler.failureCount == 0, "Foreground scheduler work must not fail for \(workloadName)")
                }

                return WorkspaceFileSearchIndexBenchmarkSample(
                    ordinal: ordinal,
                    phase: phase,
                    totalWallMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: started, to: workload.readFinished),
                    preSearchMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: started, to: workload.materialized),
                    searchMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: workload.materialized, to: workload.searchFinished),
                    cumulativeSearchMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: started, to: workload.searchFinished),
                    readMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: workload.searchFinished, to: workload.readFinished),
                    counters: counters,
                    phases: searchPhases,
                    coldStart: coldStart
                )
            } catch {
                await materializer.release(sessionID: sessionID)
                await unloadAllRoots(in: store)
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
                cumulativeSearchMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: started, to: finished),
                readMilliseconds: 0,
                counters: counters,
                phases: phases,
                coldStart: nil
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

        private func coldCounterVectorIsValid(
            _ counters: WorkspaceFileSearchIndexBenchmarkCounters,
            pathIndexBuild: Int
        ) -> Bool {
            let vector = counterVector(counters)
            return vector == [1, 0, 1, 0, 1, pathIndexBuild, 0, 0, 1, 1]
                || vector == [1, 1, 1, 0, 1, pathIndexBuild, 0, 0, 1, 1]
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
