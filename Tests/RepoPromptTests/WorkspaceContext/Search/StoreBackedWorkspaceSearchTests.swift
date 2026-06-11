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
            logicalRootPaths: [logicalRoot.path],
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

    #if DEBUG
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
                logicalRootPaths: [logicalRoot.standardizedFileURL.path],
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
                logicalRootPaths: [logicalRoot.standardizedFileURL.path],
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
            "try await ensureSearchReady(store: store, workspaceManager: workspaceManager)",
            "let effectiveMode = mode == .auto ? FileSearchActor.inferredAutoMode(pattern) : mode",
            "return try await store.withStoreBackedSearchAccess(",
            "try await ensureRootScopeAvailable(rootScope, store: store)",
            "try await ensureSearchReady(store: store, workspaceManager: workspaceManager)",
            "_ = await store.awaitAppliedIngress(rootScope: rootScope)",
            "try Task.checkCancellation()",
            "try await performSearch("
        ], in: source)
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
            "await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(normalized, rootScope: rootScope)",
            "await store.lookupPath(WorkspacePathLookupRequest(userPath: normalized, profile: .mcpSearchScope, rootScope: rootScope))",
            "appendClause(.legacyPrefix(candidateLower: normalized.lowercased()))"
        ], in: source)
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
