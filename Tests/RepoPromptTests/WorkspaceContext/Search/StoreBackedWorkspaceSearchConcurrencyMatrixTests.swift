import Foundation
@testable import RepoPrompt
import XCTest

#if DEBUG
    final class StoreBackedWorkspaceSearchConcurrencyMatrixTests: XCTestCase {
        private static let corpusFileCount = 24
        private static let matchesPerFile = 2
        private static let cappedMatchCount = 5
        private static let kValues = [1, 6, 12]

        private var temporaryRoots: [URL] = []

        override func tearDownWithError() throws {
            for root in temporaryRoots {
                try? FileManager.default.removeItem(at: root)
            }
            temporaryRoots.removeAll()
            try super.tearDownWithError()
        }

        func testConcurrentSameStoreAndSeparateStoreMatrixPreservesOrderingIsolationAndCleanup() async throws {
            for topology in SearchTopology.allCases {
                for k in Self.kValues {
                    try await runScenario(topology: topology, k: k)
                }
            }
        }

        private enum SearchTopology: String, CaseIterable {
            case sameStore = "same_store"
            case separateStores = "separate_stores"
        }

        private struct Fixture {
            let store: WorkspaceFileContextStore
            let orderedFilePaths: [String]
        }

        private func runScenario(topology: SearchTopology, k: Int) async throws {
            guard Self.kValues.contains(k) else {
                throw ConcurrencyMatrixError.invalidScenario(k: k)
            }
            let fixtures = try await makeFixtures(
                storeCount: topology == .sameStore ? 1 : k,
                label: "\(topology.rawValue)-k\(k)"
            )
            let limiterBefore = await waitForContentReadLimiterIdle()
            assertBoundedIdleReadLimiter(limiterBefore)

            let coldCount = try await runConcurrentSearches(
                fixtures: fixtures,
                topology: topology,
                k: k,
                countOnly: true
            )
            assertCountResults(coldCount, expectedResultCount: k)
            let cacheAfterCold = await cacheSnapshots(fixtures)
            if topology == .sameStore, k > 1 {
                let snapshot = try XCTUnwrap(cacheAfterCold.first)
                XCTAssertEqual(snapshot.loadCount, Self.corpusFileCount)
                XCTAssertEqual(snapshot.acceptedLoadCount, Self.corpusFileCount)
            }
            let limiterAfterCold = await waitForContentReadLimiterIdle()
            assertBoundedIdleReadLimiter(limiterAfterCold)
            XCTAssertEqual(limiterAfterCold.overloadCount, limiterBefore.overloadCount)

            let warmCapped = try await runConcurrentSearches(
                fixtures: fixtures,
                topology: topology,
                k: k,
                countOnly: false
            )
            let warmCount = try await runConcurrentSearches(
                fixtures: fixtures,
                topology: topology,
                k: k,
                countOnly: true
            )
            assertOrderedCappedResults(
                warmCapped,
                fixtures: fixtures,
                topology: topology,
                expectedResultCount: k
            )
            assertCountResults(warmCount, expectedResultCount: k)
            let cacheAfterWarm = await cacheSnapshots(fixtures)
            if topology == .sameStore, k > 1 {
                XCTAssertEqual(cacheAfterWarm.map(\.loadCount), cacheAfterCold.map(\.loadCount))
                XCTAssertEqual(cacheAfterWarm.map(\.acceptedLoadCount), cacheAfterCold.map(\.acceptedLoadCount))
            }

            switch topology {
            case .sameStore:
                try await verifyScopedBypassWhileBroadSearchHeld(fixture: fixtures[0], k: k)
            case .separateStores:
                try await verifySeparateStoreBroadLaneIsolation(fixtures)
            }

            let laneSnapshots = await searchLaneSnapshots(fixtures)
            XCTAssertTrue(laneSnapshots.allSatisfy(\.isIdle))
            XCTAssertTrue(laneSnapshots.allSatisfy { $0.maximumActivePermitCount <= 1 })
            XCTAssertTrue(laneSnapshots.allSatisfy { $0.maximumWaiterCount == 0 })

            let cacheSnapshots = await cacheSnapshots(fixtures)
            XCTAssertTrue(cacheSnapshots.allSatisfy { $0.activeFlightCount == 0 })
            XCTAssertTrue(cacheSnapshots.allSatisfy { $0.waiterCount == 0 })

            let limiterAfterScenario = await waitForContentReadLimiterIdle()
            assertBoundedIdleReadLimiter(limiterAfterScenario)
            XCTAssertEqual(limiterAfterScenario.overloadCount, limiterBefore.overloadCount)
        }

        private func makeFixtures(storeCount: Int, label: String) async throws -> [Fixture] {
            var fixtures: [Fixture] = []
            fixtures.reserveCapacity(storeCount)
            for storeIndex in 0 ..< storeCount {
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("RepoPromptTests", isDirectory: true)
                    .appendingPathComponent("SearchMatrix-\(label)-s\(storeIndex)-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                temporaryRoots.append(root)

                var orderedFilePaths: [String] = []
                for fileIndex in (0 ..< Self.corpusFileCount).reversed() {
                    let relativePath = String(format: "Sources/Group-%02d/File-%03d.swift", fileIndex % 4, fileIndex)
                    let file = root.appendingPathComponent(relativePath)
                    try FileManager.default.createDirectory(
                        at: file.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let content = "let sharedNeedle = \(fileIndex)\n// sharedNeedle store \(storeIndex)\n"
                    try content.write(to: file, atomically: true, encoding: .utf8)
                    orderedFilePaths.append(file.path)
                }
                let store = WorkspaceFileContextStore()
                _ = try await store.loadRoot(path: root.path)
                fixtures.append(Fixture(
                    store: store,
                    orderedFilePaths: orderedFilePaths.sorted()
                ))
            }
            return fixtures
        }

        private func runConcurrentSearches(
            fixtures: [Fixture],
            topology: SearchTopology,
            k: Int,
            countOnly: Bool
        ) async throws -> [SearchResults] {
            let tasks: [Task<SearchResults, Error>] = (0 ..< k).map { requestIndex in
                let fixture = topology == .sameStore ? fixtures[0] : fixtures[requestIndex]
                return Task {
                    try await self.search(
                        fixture: fixture,
                        countOnly: countOnly,
                        scoped: topology == .sameStore && requestIndex > 0
                    )
                }
            }
            return try await collect(tasks)
        }

        private func verifyScopedBypassWhileBroadSearchHeld(
            fixture: Fixture,
            k: Int
        ) async throws {
            guard k > 1 else { return }

            let gate = SearchPermitGate()
            await fixture.store.setSearchLanePermitAcquiredHandlerForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            let broadTask = Task {
                try await self.search(fixture: fixture, countOnly: false, scoped: false)
            }
            var scopedTasks: [Task<SearchResults, Error>] = []
            do {
                guard await gate.waitUntilStartedCount(1) else {
                    throw ConcurrencyMatrixError.sameStoreBroadSearchDidNotStart
                }
                scopedTasks = (1 ..< k).map { _ in
                    Task {
                        try await self.search(fixture: fixture, countOnly: false, scoped: true)
                    }
                }
                let scopedResults = try await collect(scopedTasks)
                let heldSnapshot = await fixture.store.searchLaneSnapshotForTesting()
                XCTAssertEqual(heldSnapshot.activePermitCount, 1)
                XCTAssertEqual(heldSnapshot.waiterCount, 0)

                await gate.release()
                let broadResult = try await broadTask.value
                await fixture.store.setSearchLanePermitAcquiredHandlerForTesting(nil)
                assertOrderedCappedResults(
                    [broadResult] + scopedResults,
                    fixtures: [fixture],
                    topology: .sameStore,
                    expectedResultCount: k
                )
            } catch {
                broadTask.cancel()
                scopedTasks.forEach { $0.cancel() }
                await gate.release()
                await drain([broadTask] + scopedTasks)
                await fixture.store.setSearchLanePermitAcquiredHandlerForTesting(nil)
                throw error
            }
        }

        private func verifySeparateStoreBroadLaneIsolation(_ fixtures: [Fixture]) async throws {
            guard fixtures.count > 1 else { return }

            let barrier = KWayIsolationBarrier(expectedCount: fixtures.count)
            for fixture in fixtures {
                await fixture.store.setSearchLanePermitAcquiredHandlerForTesting {
                    await barrier.arriveAndWaitForRelease()
                }
            }
            let tasks = fixtures.map { fixture in
                Task {
                    try await self.search(fixture: fixture, countOnly: false, scoped: false)
                }
            }
            let allLanesAcquired = await barrier.waitUntilAllArrived()
            XCTAssertTrue(allLanesAcquired)
            await barrier.release()
            do {
                let results = try await collect(tasks)
                await clearSearchLaneHooks(fixtures)
                assertOrderedCappedResults(
                    results,
                    fixtures: fixtures,
                    topology: .separateStores,
                    expectedResultCount: fixtures.count
                )
            } catch {
                tasks.forEach { $0.cancel() }
                await barrier.release()
                await drain(tasks)
                await clearSearchLaneHooks(fixtures)
                throw error
            }
        }

        private func search(fixture: Fixture, countOnly: Bool, scoped: Bool) async throws -> SearchResults {
            try await StoreBackedWorkspaceSearch.search(
                pattern: "sharedNeedle",
                mode: .content,
                isRegex: false,
                caseInsensitive: false,
                maxPaths: Self.cappedMatchCount,
                maxMatches: Self.cappedMatchCount,
                paths: scoped ? fixture.orderedFilePaths : nil,
                countOnly: countOnly,
                rootScope: .visibleWorkspace,
                store: fixture.store,
                workspaceManager: nil
            )
        }

        private func collect(_ tasks: [Task<SearchResults, Error>]) async throws -> [SearchResults] {
            do {
                var results: [SearchResults] = []
                results.reserveCapacity(tasks.count)
                for task in tasks {
                    try await results.append(task.value)
                }
                return results
            } catch {
                tasks.forEach { $0.cancel() }
                await drain(tasks)
                throw error
            }
        }

        private func drain(_ tasks: [Task<SearchResults, Error>]) async {
            for task in tasks {
                _ = try? await task.value
            }
        }

        private func assertOrderedCappedResults(
            _ results: [SearchResults],
            fixtures: [Fixture],
            topology: SearchTopology,
            expectedResultCount: Int
        ) {
            XCTAssertEqual(results.count, expectedResultCount)
            for (index, result) in results.enumerated() {
                let fixture = topology == .sameStore ? fixtures[0] : fixtures[index]
                let expectedPaths = [0, 0, 1, 1, 2].map { fixture.orderedFilePaths[$0] }
                XCTAssertEqual(result.matches?.map(\.filePath), expectedPaths)
                XCTAssertEqual(result.matches?.map(\.lineNumber), [0, 1, 0, 1, 0])
                XCTAssertEqual(result.matches?.count, Self.cappedMatchCount)
            }
        }

        private func assertCountResults(_ results: [SearchResults], expectedResultCount: Int) {
            XCTAssertEqual(results.count, expectedResultCount)
            for result in results {
                XCTAssertEqual(result.totalCount, Self.corpusFileCount * Self.matchesPerFile)
                XCTAssertEqual(result.contentFileCount, Self.corpusFileCount)
                XCTAssertEqual(result.searchedFileCount, Self.corpusFileCount)
                XCTAssertTrue((result.matches ?? []).isEmpty)
            }
        }

        private func clearSearchLaneHooks(_ fixtures: [Fixture]) async {
            for fixture in fixtures {
                await fixture.store.setSearchLanePermitAcquiredHandlerForTesting(nil)
            }
        }

        private func cacheSnapshots(
            _ fixtures: [Fixture]
        ) async -> [WorkspaceSearchDecodedContentCache.Snapshot] {
            var snapshots: [WorkspaceSearchDecodedContentCache.Snapshot] = []
            snapshots.reserveCapacity(fixtures.count)
            for fixture in fixtures {
                await snapshots.append(fixture.store.searchDecodedContentCacheSnapshotForTesting())
            }
            return snapshots
        }

        private func searchLaneSnapshots(
            _ fixtures: [Fixture]
        ) async -> [StoreBackedWorkspaceSearchLane.Snapshot] {
            var snapshots: [StoreBackedWorkspaceSearchLane.Snapshot] = []
            snapshots.reserveCapacity(fixtures.count)
            for fixture in fixtures {
                await snapshots.append(fixture.store.searchLaneSnapshotForTesting())
            }
            return snapshots
        }

        private func waitForContentReadLimiterIdle(
            timeout: Duration = .seconds(5)
        ) async -> ContentReadAsyncLimiter.Snapshot {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                let snapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
                if snapshot.isIdle { return snapshot }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
        }

        private func assertBoundedIdleReadLimiter(_ snapshot: ContentReadAsyncLimiter.Snapshot) {
            XCTAssertTrue(snapshot.isIdle)
            XCTAssertLessThanOrEqual(snapshot.activePermitCount, snapshot.capacity)
            XCTAssertLessThanOrEqual(snapshot.queuedWaiterCount, snapshot.maxQueuedWaiterCount)
            XCTAssertEqual(snapshot.ownerLaneCount, 0)
        }
    }

    private enum ConcurrencyMatrixError: Error {
        case invalidScenario(k: Int)
        case sameStoreBroadSearchDidNotStart
    }

    private actor SearchPermitGate {
        private var startedCount = 0
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markStartedAndWaitForRelease() async {
            startedCount += 1
            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilStartedCount(
            _ expectedCount: Int,
            timeout: Duration = .seconds(2)
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while startedCount < expectedCount, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return startedCount >= expectedCount
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }
    }

    private actor KWayIsolationBarrier {
        private let expectedCount: Int
        private var arrivedCount = 0
        private var released = false

        init(expectedCount: Int) {
            self.expectedCount = expectedCount
        }

        func arriveAndWaitForRelease() async {
            arrivedCount += 1
            while !released {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }

        func waitUntilAllArrived(timeout: Duration = .seconds(2)) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while arrivedCount < expectedCount, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
            return arrivedCount == expectedCount
        }

        func release() {
            released = true
        }
    }
#endif
