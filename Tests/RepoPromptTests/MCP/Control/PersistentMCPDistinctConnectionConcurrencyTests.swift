import Darwin
import Foundation
import MCP
@testable import RepoPrompt
import XCTest

@MainActor
final class PersistentMCPDistinctConnectionConcurrencyTests: XCTestCase {
    func testDistinctConnectionsOverlapWithoutCrossRoutingReadOrSearchResults() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                do {
                    try await runCheckpoint(fixture: fixture)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        #else
            throw XCTSkip("Distinct MCP connection socketpair integration requires DEBUG diagnostics helpers.")
        #endif
    }

    func testK12WarmBroadAndScopedSearchesShareOneWindowStoreAndReuseConnections() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    contextASearchFileCount: 12
                )
                do {
                    try await runK12SharedWindowSearchCheckpoint(fixture: fixture)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        #else
            throw XCTSkip("Distinct MCP connection socketpair integration requires DEBUG diagnostics helpers.")
        #endif
    }

    func testInteractivePartialReadSelectionPersistsAcrossConnectionTeardownAndFreshRebind() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                do {
                    try await runReadSelectionPersistenceCheckpoint(fixture: fixture, shape: .partial)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        #else
            throw XCTSkip("Read-file selection persistence socketpair integration requires DEBUG diagnostics helpers.")
        #endif
    }

    func testInteractiveFullReadSelectionPersistsAcrossConnectionTeardownAndFreshRebind() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                do {
                    try await runReadSelectionPersistenceCheckpoint(fixture: fixture, shape: .full)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        #else
            throw XCTSkip("Read-file selection persistence socketpair integration requires DEBUG diagnostics helpers.")
        #endif
    }

    func testClearPersistedRoutingSessionHiddenDispatchIsExactAndRestoresState() async throws {
        #if DEBUG
            let networkManager = ServerNetworkManager.shared
            let baseline = await networkManager.debugExactRoutingSessionFixtureState()
            let fixture = await networkManager.debugSeedExactRoutingSessionFixture()
            do {
                try await runExactRoutingSessionCleanupCheckpoint(networkManager: networkManager, fixture: fixture)
                await assertExactRoutingSessionFixtureRestored(networkManager: networkManager, fixture: fixture, baseline: baseline)
            } catch {
                await assertExactRoutingSessionFixtureRestored(networkManager: networkManager, fixture: fixture, baseline: baseline)
                throw error
            }
        #else
            throw XCTSkip("Exact persisted routing session cleanup diagnostics require DEBUG helpers.")
        #endif
    }
}

#if DEBUG
    private extension PersistentMCPDistinctConnectionConcurrencyTests {
        enum ReadSelectionShape {
            case partial
            case full
        }

        func runReadSelectionPersistenceCheckpoint(
            fixture: PersistentMCPTestFixture,
            shape: ReadSelectionShape
        ) async throws {
            let readEndpoint = try fixture.endpointA()
            let freshEndpoint = try fixture.endpointARead()
            let context = fixture.contextA
            let workspace = try XCTUnwrap(
                context.window.workspaceManager.workspaces.first(where: { $0.id == context.workspaceID })
            )
            await context.window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "readSelectionPersistenceCheckpoint"
            )
            context.window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
            try await Self.bind(readEndpoint, to: context.tabID)
            _ = try await readEndpoint.callTool(
                name: MCPWindowToolName.manageSelection,
                arguments: ["op": "clear"]
            )

            let gate = SearchAdmissionGate {}
            context.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            defer {
                context.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                Task { await gate.release() }
            }

            var readArguments: [String: Any] = ["path": context.fileURL.path]
            if shape == .partial {
                readArguments["start_line"] = 1
                readArguments["limit"] = 1
            }
            let readCompletion = PersistentMCPTaskResultBox<PersistentMCPTestRPCResponse>()
            let readTask = Task {
                do {
                    let response = try await readEndpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: readArguments
                    )
                    readCompletion.store(.success(response))
                    return response
                } catch {
                    readCompletion.store(.failure(error))
                    throw error
                }
            }
            let autoSelectionStarted = await gate.waitUntilStarted()
            XCTAssertTrue(autoSelectionStarted)
            XCTAssertNil(
                readCompletion.load(),
                "Interactive read_file returned before its auto-selection reached the provider durability barrier."
            )
            await gate.release()
            let readResponse = try await Self.boundedTaskValue(
                readTask,
                description: "interactive read_file selection durability"
            )
            try Self.assertReadResult(
                readResponse,
                contains: context.sentinel,
                excludes: fixture.contextB.sentinel
            )

            readEndpoint.client.close()
            await fixture.networkManager.debugRemoveConnection(readEndpoint.connectionID)
            context.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)

            try await Self.bind(freshEndpoint, to: context.tabID)
            let freshSelectionResponse = try await freshEndpoint.callTool(
                name: MCPWindowToolName.manageSelection,
                arguments: [
                    "op": "get",
                    "view": "files",
                    "path_display": "full"
                ]
            )
            let freshSelectionText = try Self.toolText(from: freshSelectionResponse)
            XCTAssertTrue(freshSelectionText.contains(context.fileURL.lastPathComponent), freshSelectionText)

            let expectedSlices: [String: [LineRange]] = switch shape {
            case .partial:
                [context.fileURL.path: [LineRange(start: 1, end: 1)]]
            case .full:
                [:]
            }
            let storedSelection = try XCTUnwrap(
                context.window.workspaceManager.composeTab(with: context.tabID)?.selection
            )
            XCTAssertEqual(storedSelection.selectedPaths, [context.fileURL.path])
            XCTAssertEqual(storedSelection.slices, expectedSlices)
            XCTAssertEqual(
                context.window.promptManager.currentComposeTabs
                    .first(where: { $0.id == context.tabID })?
                    .selection,
                storedSelection
            )
            switch shape {
            case .partial:
                XCTAssertTrue(freshSelectionText.contains("lines 1"), freshSelectionText)
            case .full:
                XCTAssertFalse(freshSelectionText.contains("lines 1"), freshSelectionText)
            }
        }

        func runK12SharedWindowSearchCheckpoint(fixture: PersistentMCPTestFixture) async throws {
            let primary = try fixture.endpointA()
            var endpoints = [primary]
            for index in 1 ..< 12 {
                try await endpoints.append(fixture.makeAdditionalEndpoint(label: "shared-search-\(index)"))
            }
            for endpoint in endpoints {
                try await Self.bind(endpoint, to: fixture.contextA.tabID)
            }

            let searchFiles = fixture.contextA.searchFileURLs
            XCTAssertEqual(searchFiles.count, 12)
            let store = fixture.contextA.window.workspaceFileContextStore
            let warmResponse = try await primary.callTool(
                name: MCPWindowToolName.search,
                arguments: Self.sharedWindowBroadSearchArguments(countOnly: true)
            )
            let warmText = try Self.toolText(from: warmResponse)
            Self.assertHealthySearchText(warmText)
            let cacheAfterWarm = await store.searchDecodedContentCacheSnapshotForTesting()
            XCTAssertEqual(cacheAfterWarm.loadCount, searchFiles.count)
            XCTAssertEqual(cacheAfterWarm.acceptedLoadCount, searchFiles.count)
            XCTAssertEqual(cacheAfterWarm.activeFlightCount, 0)
            XCTAssertEqual(cacheAfterWarm.waiterCount, 0)

            var baselineSnapshots: [UUID: PersistentMCPTestEndpointSnapshot] = [:]
            for endpoint in endpoints {
                let snapshot = await fixture.snapshot(endpoint, context: fixture.contextA)
                Self.assertStableSnapshot(snapshot, endpoint: endpoint, context: fixture.contextA)
                baselineSnapshots[endpoint.connectionID] = snapshot
            }
            let gate = SearchAdmissionGate {}
            await store.setSearchLanePermitAcquiredHandlerForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            let broadTask = Task {
                try await primary.callTool(
                    name: MCPWindowToolName.search,
                    arguments: Self.sharedWindowBroadSearchArguments(countOnly: false)
                )
            }
            var scopedTasks: [Task<(URL, PersistentMCPTestRPCResponse), Error>] = []
            do {
                let broadStarted = await gate.waitUntilStarted()
                XCTAssertTrue(broadStarted)
                scopedTasks = zip(endpoints.dropFirst(), searchFiles.dropFirst()).map { endpoint, fileURL in
                    Task {
                        let response = try await endpoint.callTool(
                            name: MCPWindowToolName.search,
                            arguments: Self.sharedWindowScopedSearchArguments(path: fileURL.path)
                        )
                        return (fileURL, response)
                    }
                }
                for task in scopedTasks {
                    let (fileURL, response) = try await task.value
                    let text = try Self.toolText(from: response)
                    Self.assertHealthySearchText(text)
                    XCTAssertTrue(text.contains(fileURL.lastPathComponent), text)
                    for otherFileURL in searchFiles where otherFileURL != fileURL {
                        XCTAssertFalse(text.contains(otherFileURL.lastPathComponent), text)
                    }
                    XCTAssertFalse(text.contains(fixture.contextB.fileURL.lastPathComponent), text)
                }

                await gate.release()
                let broadResponse = try await broadTask.value
                let broadText = try Self.toolText(from: broadResponse)
                Self.assertHealthySearchText(broadText)
                for fileURL in searchFiles {
                    XCTAssertTrue(broadText.contains(fileURL.lastPathComponent), broadText)
                }
            } catch {
                broadTask.cancel()
                scopedTasks.forEach { $0.cancel() }
                await gate.release()
                _ = try? await broadTask.value
                for task in scopedTasks {
                    _ = try? await task.value
                }
                await store.setSearchLanePermitAcquiredHandlerForTesting(nil)
                throw error
            }
            await store.setSearchLanePermitAcquiredHandlerForTesting(nil)

            try await runK12UnscopedBroadBurstCheckpoint(
                endpoints: endpoints,
                searchFiles: searchFiles,
                store: store
            )

            for endpoint in endpoints {
                _ = try await endpoint.client.request(method: "tools/list", params: [:])
            }
            let primaryRead = try await primary.callTool(
                name: MCPWindowToolName.readFile,
                arguments: ["path": searchFiles[0].path]
            )
            try Self.assertReadResult(
                primaryRead,
                contains: PersistentMCPTestFixture.sharedSearchToken,
                excludes: fixture.contextB.sentinel
            )
            let peerRead = try await endpoints[1].callTool(
                name: MCPWindowToolName.readFile,
                arguments: ["path": searchFiles[1].path]
            )
            try Self.assertReadResult(
                peerRead,
                contains: PersistentMCPTestFixture.sharedSearchToken,
                excludes: fixture.contextB.sentinel
            )

            let finalCache = await store.searchDecodedContentCacheSnapshotForTesting()
            let finalLane = await store.searchLaneSnapshotForTesting()
            let finalReadLimiter = await Self.waitForContentReadLimiterIdle()
            XCTAssertEqual(finalCache.loadCount, cacheAfterWarm.loadCount)
            XCTAssertEqual(finalCache.acceptedLoadCount, cacheAfterWarm.acceptedLoadCount)
            XCTAssertGreaterThan(finalCache.hitCount, cacheAfterWarm.hitCount)
            XCTAssertEqual(finalCache.activeFlightCount, 0)
            XCTAssertEqual(finalCache.waiterCount, 0)
            XCTAssertTrue(finalLane.isIdle)
            XCTAssertTrue(finalReadLimiter.isIdle)

            for endpoint in endpoints {
                let finalSnapshot = await fixture.snapshot(endpoint, context: fixture.contextA)
                let baselineSnapshot = try XCTUnwrap(baselineSnapshots[endpoint.connectionID])
                XCTAssertEqual(finalSnapshot, baselineSnapshot)
                let hasInFlightCalls = await fixture.networkManager.hasInFlightCalls(for: endpoint.connectionID)
                let limiter = await fixture.networkManager.connectionLimiterSnapshotForTesting(
                    connectionID: endpoint.connectionID
                )
                XCTAssertFalse(hasInFlightCalls)
                XCTAssertEqual(limiter?.permits, 1)
                XCTAssertEqual(limiter?.waiterCount, 0)
                XCTAssertEqual(limiter?.inFlight, 0)
            }
        }

        func runK12UnscopedBroadBurstCheckpoint(
            endpoints: [PersistentMCPTestEndpoint],
            searchFiles: [URL],
            store: WorkspaceFileContextStore
        ) async throws {
            XCTAssertEqual(endpoints.count, 12)
            let baselineConfiguration = await store.searchLaneSnapshotForTesting().configuration
            let burstConfiguration = StoreBackedWorkspaceSearchLane.Configuration(
                maxQueueWait: .seconds(8),
                retryAfterMilliseconds: 1000
            )
            guard case .applied = await store.configureSearchLaneForTesting(burstConfiguration) else {
                XCTFail("Shared-window broad-search lane must be idle before the K12 burst")
                return
            }

            let gate = SearchAdmissionGate {}
            await store.setSearchLanePermitAcquiredHandlerForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            let active = Task {
                try await endpoints[0].callTool(
                    name: MCPWindowToolName.search,
                    arguments: Self.sharedWindowBroadSearchArguments(countOnly: false)
                )
            }
            var queued: Task<PersistentMCPTestRPCResponse, Error>?
            var excess: [Task<PersistentMCPTestRPCResponse, Error>] = []
            do {
                guard await gate.waitUntilStarted() else {
                    XCTFail("The first K12 broad search did not acquire the shared lane")
                    throw ClientFixtureError.broadSearchDidNotStart
                }
                queued = Task {
                    try await endpoints[1].callTool(
                        name: MCPWindowToolName.search,
                        arguments: Self.sharedWindowBroadSearchArguments(countOnly: false)
                    )
                }
                await Self.waitForSearchLaneWaiter(store: store, expectedCount: 1)
                let saturated = await store.searchLaneSnapshotForTesting()
                XCTAssertEqual(saturated.activePermitCount, 1)
                XCTAssertEqual(saturated.waiterCount, 1)
                XCTAssertEqual(saturated.maximumActivePermitCount, 1)
                XCTAssertEqual(saturated.maximumWaiterCount, 1)

                excess = endpoints.dropFirst(2).map { endpoint in
                    Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.search,
                            arguments: Self.sharedWindowBroadSearchArguments(countOnly: false)
                        )
                    }
                }
                for task in excess {
                    try await Self.assertSearchBackpressureResult(task.value)
                }
                let overloaded = await store.searchLaneSnapshotForTesting()
                XCTAssertEqual(overloaded.activePermitCount, 1)
                XCTAssertEqual(overloaded.waiterCount, 1)
                XCTAssertEqual(overloaded.overloadCount, endpoints.count - 2)

                await gate.release()
                let activeResponse = try await active.value
                let queuedResponse = try await XCTUnwrap(queued).value
                try Self.assertSharedWindowBroadSearchResult(activeResponse, searchFiles: searchFiles)
                try Self.assertSharedWindowBroadSearchResult(queuedResponse, searchFiles: searchFiles)
                await store.setSearchLanePermitAcquiredHandlerForTesting(nil)

                for endpoint in endpoints.dropFirst(2) {
                    let retry = try await endpoint.callTool(
                        name: MCPWindowToolName.search,
                        arguments: Self.sharedWindowBroadSearchArguments(countOnly: false)
                    )
                    try Self.assertSharedWindowBroadSearchResult(retry, searchFiles: searchFiles)
                }
                let settled = await store.searchLaneSnapshotForTesting()
                XCTAssertTrue(settled.isIdle)
                XCTAssertEqual(settled.maximumActivePermitCount, 1)
                XCTAssertEqual(settled.maximumWaiterCount, 1)
                XCTAssertEqual(settled.overloadCount, endpoints.count - 2)
                XCTAssertEqual(settled.grantCount, endpoints.count)
                await restoreBroadSearchAdmissionConfiguration(baselineConfiguration, store: store)
            } catch {
                active.cancel()
                queued?.cancel()
                excess.forEach { $0.cancel() }
                await gate.release()
                _ = try? await active.value
                if let queued {
                    _ = try? await queued.value
                }
                for task in excess {
                    _ = try? await task.value
                }
                await restoreBroadSearchAdmissionConfiguration(baselineConfiguration, store: store)
                throw error
            }
        }

        func runCheckpoint(fixture: PersistentMCPTestFixture) async throws {
            let endpointA = try fixture.endpointA()
            let endpointB = try fixture.endpointB()

            let directCanonical = try await endpointA.callTool(
                name: MCPWindowToolName.readFile,
                arguments: [
                    "path": fixture.contextA.fileURL.path,
                    "context_id": fixture.contextA.tabID.uuidString
                ]
            )
            try Self.assertReadResult(
                directCanonical,
                contains: fixture.contextA.sentinel,
                excludes: fixture.contextB.sentinel
            )

            let directLegacy = try await endpointB.callTool(
                name: MCPWindowToolName.readFile,
                arguments: [
                    "path": fixture.contextB.fileURL.path,
                    "_tabID": fixture.contextB.tabID.uuidString
                ]
            )
            try Self.assertReadResult(
                directLegacy,
                contains: fixture.contextB.sentinel,
                excludes: fixture.contextA.sentinel
            )

            try await Self.bind(endpointA, to: fixture.contextA.tabID)
            try await Self.bind(endpointB, to: fixture.contextB.tabID)
            fixture.assertStableBindings()

            let baselineA = await fixture.snapshot(endpointA, context: fixture.contextA)
            let baselineB = await fixture.snapshot(endpointB, context: fixture.contextB)
            Self.assertStableSnapshot(baselineA, endpoint: endpointA, context: fixture.contextA)
            Self.assertStableSnapshot(baselineB, endpoint: endpointB, context: fixture.contextB)
            XCTAssertNotEqual(baselineA.connectionID, baselineB.connectionID)

            try await Self.assertPing(endpointA, tag: "before-a")
            try await Self.assertPing(endpointB, tag: "before-b")
            try await Self.assertRoutingSnapshot(endpointA, context: fixture.contextA)
            try await Self.assertRoutingSnapshot(endpointB, context: fixture.contextB)

            var sameConnectionMillis: [Double] = []
            var distinctConnectionMillis: [Double] = []
            for trial in 0 ..< 3 {
                try await sameConnectionMillis.append(Self.measureMilliseconds {
                    async let first = Self.sleep(endpointA, tag: "same-\(trial)-first")
                    async let second = Self.sleep(endpointA, tag: "same-\(trial)-second")
                    let responses = try await (first, second)
                    XCTAssertNotEqual(responses.0, responses.1)
                })
                try await distinctConnectionMillis.append(Self.measureMilliseconds {
                    async let first = Self.sleep(endpointA, tag: "distinct-\(trial)-a")
                    async let second = Self.sleep(endpointB, tag: "distinct-\(trial)-b")
                    _ = try await (first, second)
                })
            }
            let sameMedian = Self.median(sameConnectionMillis)
            let distinctMedian = Self.median(distinctConnectionMillis)
            XCTAssertGreaterThanOrEqual(sameMedian, 700, "same-connection sleeps must serialize: \(sameConnectionMillis)")
            XCTAssertLessThanOrEqual(distinctMedian, 650, "distinct-connection sleeps must overlap: \(distinctConnectionMillis)")
            XCTAssertLessThanOrEqual(distinctMedian, sameMedian * 0.85, "distinct connections must overlap materially")

            async let readA = endpointA.callTool(name: MCPWindowToolName.readFile, arguments: ["path": fixture.contextA.fileURL.path])
            async let readB = endpointB.callTool(name: MCPWindowToolName.readFile, arguments: ["path": fixture.contextB.fileURL.path])
            let parallelReads = try await (readA, readB)
            try Self.assertReadResult(parallelReads.0, contains: fixture.contextA.sentinel, excludes: fixture.contextB.sentinel)
            try Self.assertReadResult(parallelReads.1, contains: fixture.contextB.sentinel, excludes: fixture.contextA.sentinel)

            async let searchA = endpointA.callTool(name: MCPWindowToolName.search, arguments: Self.searchArguments)
            async let searchB = endpointB.callTool(name: MCPWindowToolName.search, arguments: Self.searchArguments)
            let parallelSearches = try await (searchA, searchB)
            try Self.assertSearchResult(parallelSearches.0, contains: fixture.contextA.fileURL.lastPathComponent, excludes: fixture.contextB.fileURL.lastPathComponent)
            try Self.assertSearchResult(parallelSearches.1, contains: fixture.contextB.fileURL.lastPathComponent, excludes: fixture.contextA.fileURL.lastPathComponent)

            async let mixedReadA = endpointA.callTool(name: MCPWindowToolName.readFile, arguments: ["path": fixture.contextA.fileURL.path])
            async let mixedSearchB = endpointB.callTool(name: MCPWindowToolName.search, arguments: Self.searchArguments)
            let firstMixed = try await (mixedReadA, mixedSearchB)
            try Self.assertReadResult(firstMixed.0, contains: fixture.contextA.sentinel, excludes: fixture.contextB.sentinel)
            try Self.assertSearchResult(firstMixed.1, contains: fixture.contextB.fileURL.lastPathComponent, excludes: fixture.contextA.fileURL.lastPathComponent)

            async let mixedSearchA = endpointA.callTool(name: MCPWindowToolName.search, arguments: Self.searchArguments)
            async let mixedReadB = endpointB.callTool(name: MCPWindowToolName.readFile, arguments: ["path": fixture.contextB.fileURL.path])
            let secondMixed = try await (mixedSearchA, mixedReadB)
            try Self.assertSearchResult(secondMixed.0, contains: fixture.contextA.fileURL.lastPathComponent, excludes: fixture.contextB.fileURL.lastPathComponent)
            try Self.assertReadResult(secondMixed.1, contains: fixture.contextB.sentinel, excludes: fixture.contextA.sentinel)

            try await Self.assertRetainedReadSpellings(endpointA, context: fixture.contextA)
            try await runBroadSearchAdmissionCheckpoint(fixture: fixture)

            try await Self.assertPing(endpointA, tag: "after-a")
            try await Self.assertPing(endpointB, tag: "after-b")
            try await Self.assertRoutingSnapshot(endpointA, context: fixture.contextA)
            try await Self.assertRoutingSnapshot(endpointB, context: fixture.contextB)

            let finalA = await fixture.snapshot(endpointA, context: fixture.contextA)
            let finalB = await fixture.snapshot(endpointB, context: fixture.contextB)
            XCTAssertEqual(finalA, baselineA)
            XCTAssertEqual(finalB, baselineB)
            for endpoint in try fixture.endpoints() {
                let hasInFlightCalls = await fixture.networkManager.hasInFlightCalls(for: endpoint.connectionID)
                XCTAssertFalse(hasInFlightCalls)
            }
        }

        func runBroadSearchAdmissionCheckpoint(fixture: PersistentMCPTestFixture) async throws {
            let endpointA = try fixture.endpointA()
            let endpointAQueued = try fixture.endpointAQueuedSearch()
            let endpointAOverflow = try fixture.endpointAOverflowSearch()
            let endpointARead = try fixture.endpointARead()
            let endpointB = try fixture.endpointB()
            try await Self.bind(endpointAQueued, to: fixture.contextA.tabID)
            try await Self.bind(endpointAOverflow, to: fixture.contextA.tabID)
            try await Self.bind(endpointARead, to: fixture.contextA.tabID)
            fixture.assertStableBindings(includeAdditionalContextAEndpoints: true)

            let heldStore = fixture.contextA.window.workspaceFileContextStore
            let baselineConfiguration = await heldStore.searchLaneSnapshotForTesting().configuration
            // One active lease and two waiter slots: the same-connection burst member and the
            // separate-connection search both wait in the store queue while the third rejects.
            let liveSweepConfiguration = StoreBackedWorkspaceSearchLane.Configuration(
                maxActiveLeases: 1,
                maxQueuedWaiters: 2,
                maxQueueWait: .seconds(8),
                retryAfterMilliseconds: 1000
            )
            guard case .applied = await heldStore.configureSearchLaneForTesting(liveSweepConfiguration) else {
                XCTFail("Per-workspace search lane should be idle before retained MCP checkpoint")
                return
            }
            let heldSearchStarted = expectation(description: "first broad search acquired per-workspace admission")
            let gate = SearchAdmissionGate {
                heldSearchStarted.fulfill()
            }
            await heldStore.setSearchLanePermitAcquiredHandlerForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            var outstandingSearchTasks: [Task<PersistentMCPTestRPCResponse, Error>] = []
            do {
                let firstHeldSearch = Task {
                    try await endpointA.callTool(name: MCPWindowToolName.search, arguments: Self.searchArguments)
                }
                outstandingSearchTasks.append(firstHeldSearch)
                await fulfillment(of: [heldSearchStarted], timeout: 1)
                let sameConnectionSearchAdmitted = expectation(
                    description: "second same-connection search admitted concurrently by the file-search lane"
                )
                let observerInstalled = await fixture.networkManager.setConnectionLimiterStateObserverForTesting(
                    connectionID: endpointA.connectionID,
                    lane: .fileSearch
                ) { snapshot in
                    if snapshot.activePermitCount == 2,
                       snapshot.waiterCount == 0,
                       snapshot.inFlight == 2
                    {
                        sameConnectionSearchAdmitted.fulfill()
                    }
                }
                XCTAssertTrue(observerInstalled)
                let secondHeldSearch = Task {
                    try await endpointA.callTool(name: MCPWindowToolName.search, arguments: Self.searchArguments)
                }
                outstandingSearchTasks.append(secondHeldSearch)
                await fulfillment(of: [sameConnectionSearchAdmitted], timeout: 1)
                _ = await fixture.networkManager.setConnectionLimiterStateObserverForTesting(
                    connectionID: endpointA.connectionID,
                    lane: .fileSearch,
                    observer: nil
                )
                // The burst member proceeds past the connection lane and waits in the store queue.
                await Self.waitForSearchLaneWaiter(store: heldStore, expectedCount: 1)
                let burstLimiterState = await fixture.networkManager.connectionLimiterSnapshotForTesting(
                    connectionID: endpointA.connectionID,
                    lane: .fileSearch
                )
                XCTAssertEqual(burstLimiterState?.activePermitCount, 2)
                XCTAssertEqual(burstLimiterState?.waiterCount, 0)
                XCTAssertEqual(burstLimiterState?.inFlight, 2)
                let hasHeldSearchInFlight = await fixture.networkManager.hasInFlightCalls(for: endpointA.connectionID)
                XCTAssertTrue(hasHeldSearchInFlight)

                let storeQueuedSearch = Task {
                    try await endpointAQueued.callTool(name: MCPWindowToolName.search, arguments: Self.searchArguments)
                }
                outstandingSearchTasks.append(storeQueuedSearch)
                await Self.waitForSearchLaneWaiter(store: heldStore, expectedCount: 2)
                let heldSearchStartedCount = await gate.startedCountSnapshot()
                XCTAssertEqual(heldSearchStartedCount, 1)
                let heldSnapshot = await heldStore.searchLaneSnapshotForTesting()
                XCTAssertEqual(heldSnapshot.activePermitCount, 1)
                XCTAssertEqual(heldSnapshot.waiterCount, 2)

                let overflow = try await endpointAOverflow.callTool(name: MCPWindowToolName.search, arguments: Self.searchArguments)
                try Self.assertSearchBackpressureResult(overflow)

                let sameConnectionRead = try await endpointA.callTool(
                    name: MCPWindowToolName.readFile,
                    arguments: ["path": fixture.contextA.fileURL.path],
                    timeoutSeconds: 1
                )
                try Self.assertReadResult(
                    sameConnectionRead,
                    contains: fixture.contextA.sentinel,
                    excludes: fixture.contextB.sentinel
                )
                let ordinaryLimiterState = await fixture.networkManager.connectionLimiterSnapshotForTesting(
                    connectionID: endpointA.connectionID,
                    lane: .ordinary
                )
                XCTAssertEqual(ordinaryLimiterState?.permits, 1)
                XCTAssertEqual(ordinaryLimiterState?.waiterCount, 0)
                XCTAssertEqual(ordinaryLimiterState?.inFlight, 0)

                let runtimeResponse = try await endpointA.callTool(
                    name: ServerNetworkManager.debugDiagnosticsToolName,
                    arguments: [
                        "op": "mcp_read_search_runtime_snapshot",
                        "connection_id": endpointA.connectionID.uuidString,
                        "recent_publication_limit": 0,
                        "root_limit": 1
                    ]
                )
                let runtimePayload = try Self.debugPayload(from: runtimeResponse)
                let runtime = try XCTUnwrap(runtimePayload["runtime"] as? [String: Any])
                let aggregateLimiter = try XCTUnwrap(runtime["limiter"] as? [String: Any])
                XCTAssertEqual((aggregateLimiter["active_permit_count"] as? NSNumber)?.intValue, 3)
                XCTAssertEqual((aggregateLimiter["waiter_count"] as? NSNumber)?.intValue, 0)
                XCTAssertEqual((aggregateLimiter["in_flight_count"] as? NSNumber)?.intValue, 3)
                XCTAssertEqual(aggregateLimiter["is_idle"] as? Bool, false)
                let limiterLanes = try XCTUnwrap(aggregateLimiter["lanes"] as? [String: Any])
                let diagnosticOrdinaryLane = try XCTUnwrap(limiterLanes["ordinary"] as? [String: Any])
                XCTAssertEqual((diagnosticOrdinaryLane["active_permit_count"] as? NSNumber)?.intValue, 1)
                XCTAssertEqual((diagnosticOrdinaryLane["waiter_count"] as? NSNumber)?.intValue, 0)
                XCTAssertEqual((diagnosticOrdinaryLane["in_flight_count"] as? NSNumber)?.intValue, 1)
                let diagnosticSearchLane = try XCTUnwrap(limiterLanes["file_search"] as? [String: Any])
                XCTAssertEqual((diagnosticSearchLane["active_permit_count"] as? NSNumber)?.intValue, 2)
                XCTAssertEqual((diagnosticSearchLane["waiter_count"] as? NSNumber)?.intValue, 0)
                XCTAssertEqual((diagnosticSearchLane["in_flight_count"] as? NSNumber)?.intValue, 2)

                let exactRead = try await endpointARead.callTool(
                    name: MCPWindowToolName.readFile,
                    arguments: ["path": fixture.contextA.fileURL.path]
                )
                try Self.assertReadResult(exactRead, contains: fixture.contextA.sentinel, excludes: fixture.contextB.sentinel)
                try await Self.assertRetainedReadSpellings(endpointARead, context: fixture.contextA)
                let sameStorePathControl = try await endpointARead.callTool(
                    name: MCPWindowToolName.search,
                    arguments: Self.pathSearchArguments
                )
                try Self.assertSearchResult(sameStorePathControl, contains: fixture.contextA.fileURL.lastPathComponent, excludes: fixture.contextB.fileURL.lastPathComponent)
                let sameStoreScopedContentControl = try await endpointARead.callTool(
                    name: MCPWindowToolName.search,
                    arguments: Self.scopedSearchArguments(path: fixture.contextA.fileURL.path)
                )
                try Self.assertSearchResult(sameStoreScopedContentControl, contains: fixture.contextA.fileURL.lastPathComponent, excludes: fixture.contextB.fileURL.lastPathComponent)

                let peerRead = try await endpointB.callTool(
                    name: MCPWindowToolName.readFile,
                    arguments: ["path": fixture.contextB.fileURL.path]
                )
                try Self.assertReadResult(peerRead, contains: fixture.contextB.sentinel, excludes: fixture.contextA.sentinel)
                let peerPathControl = try await endpointB.callTool(
                    name: MCPWindowToolName.search,
                    arguments: Self.pathSearchArguments
                )
                try Self.assertSearchResult(peerPathControl, contains: fixture.contextB.fileURL.lastPathComponent, excludes: fixture.contextA.fileURL.lastPathComponent)
                let peerSearch = try await endpointB.callTool(name: MCPWindowToolName.search, arguments: Self.searchArguments)
                try Self.assertSearchResult(peerSearch, contains: fixture.contextB.fileURL.lastPathComponent, excludes: fixture.contextA.fileURL.lastPathComponent)

                let limiterStateAfterPeerCalls = await fixture.networkManager.connectionLimiterSnapshotForTesting(
                    connectionID: endpointA.connectionID,
                    lane: .fileSearch
                )
                XCTAssertEqual(limiterStateAfterPeerCalls?.activePermitCount, 2)
                XCTAssertEqual(limiterStateAfterPeerCalls?.waiterCount, 0)
                XCTAssertEqual(limiterStateAfterPeerCalls?.inFlight, 2)

                await gate.release()
                let firstHeld = try await firstHeldSearch.value
                let secondHeld = try await secondHeldSearch.value
                let storeQueued = try await Self.boundedTaskValue(
                    storeQueuedSearch,
                    description: "queued retained search"
                )
                try Self.assertSearchResult(firstHeld, contains: fixture.contextA.fileURL.lastPathComponent, excludes: fixture.contextB.fileURL.lastPathComponent)
                try Self.assertSearchResult(secondHeld, contains: fixture.contextA.fileURL.lastPathComponent, excludes: fixture.contextB.fileURL.lastPathComponent)
                try Self.assertSearchResult(storeQueued, contains: fixture.contextA.fileURL.lastPathComponent, excludes: fixture.contextB.fileURL.lastPathComponent)
                let settledSearchLimiterState = await fixture.networkManager.connectionLimiterSnapshotForTesting(
                    connectionID: endpointA.connectionID,
                    lane: .fileSearch
                )
                XCTAssertEqual(settledSearchLimiterState?.permits, ServerNetworkManager.fileSearchCallLaneLimit)
                XCTAssertEqual(settledSearchLimiterState?.activePermitCount, 0)
                XCTAssertEqual(settledSearchLimiterState?.waiterCount, 0)
                XCTAssertEqual(settledSearchLimiterState?.inFlight, 0)
                let settledOrdinaryLimiterState = await fixture.networkManager.connectionLimiterSnapshotForTesting(
                    connectionID: endpointA.connectionID,
                    lane: .ordinary
                )
                XCTAssertEqual(settledOrdinaryLimiterState?.permits, 1)
                XCTAssertEqual(settledOrdinaryLimiterState?.waiterCount, 0)
                XCTAssertEqual(settledOrdinaryLimiterState?.inFlight, 0)
                let hasSettledInFlightCalls = await fixture.networkManager.hasInFlightCalls(for: endpointA.connectionID)
                XCTAssertFalse(hasSettledInFlightCalls)

                let settledRetry = try await endpointAOverflow.callTool(name: MCPWindowToolName.search, arguments: Self.searchArguments)
                try Self.assertSearchResult(settledRetry, contains: fixture.contextA.fileURL.lastPathComponent, excludes: fixture.contextB.fileURL.lastPathComponent)
                let snapshot = await heldStore.searchLaneSnapshotForTesting()
                XCTAssertTrue(snapshot.isIdle)
                await restoreBroadSearchAdmissionConfiguration(baselineConfiguration, store: heldStore)
            } catch {
                await gate.release()
                for task in outstandingSearchTasks {
                    _ = try? await Self.boundedTaskValue(
                        task,
                        description: "retained search cleanup"
                    )
                }
                _ = await fixture.networkManager.setConnectionLimiterStateObserverForTesting(
                    connectionID: endpointA.connectionID,
                    lane: .fileSearch,
                    observer: nil
                )
                await restoreBroadSearchAdmissionConfiguration(baselineConfiguration, store: heldStore)
                throw error
            }
        }

        func restoreBroadSearchAdmissionConfiguration(
            _ configuration: StoreBackedWorkspaceSearchLane.Configuration,
            store: WorkspaceFileContextStore
        ) async {
            await store.setSearchLanePermitAcquiredHandlerForTesting(nil)
            for _ in 0 ..< 10000 {
                switch await store.configureSearchLaneForTesting(configuration) {
                case .applied:
                    return
                case .busy:
                    await Task.yield()
                }
            }
            XCTFail("Per-workspace search lane should restore its DEBUG baseline after retained MCP checkpoint")
        }

        func runExactRoutingSessionCleanupCheckpoint(
            networkManager: ServerNetworkManager,
            fixture: ServerNetworkManager.DebugExactRoutingSessionFixture
        ) async throws {
            let callerID = UUID(uuidString: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")!
            let rawSessionTokens = [fixture.sessionA.rawSessionToken, fixture.sessionB.rawSessionToken]
            let seededState = await networkManager.debugExactRoutingSessionFixtureState()
            Self.assertFixtureCounts(seededState, session: fixture.sessionA, expected: 1)
            Self.assertFixtureCounts(seededState, session: fixture.sessionB, expected: 1)

            let missing = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: ["op": .string("clear_persisted_routing_session")],
                rawSessionTokens: rawSessionTokens
            )
            Self.assertCleanupError(missing, code: "invalid_params")
            var currentState = await networkManager.debugExactRoutingSessionFixtureState()
            XCTAssertEqual(currentState, seededState)

            var malformedArguments = Self.exactRoutingSessionClearArguments(for: fixture.sessionA)
            malformedArguments["session_fingerprint"] = .string("sha256:ABCDEF0123456789")
            let malformed = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: malformedArguments,
                rawSessionTokens: rawSessionTokens
            )
            Self.assertCleanupError(malformed, code: "invalid_params")
            currentState = await networkManager.debugExactRoutingSessionFixtureState()
            XCTAssertEqual(currentState, seededState)

            var trailingNewlineArguments = Self.exactRoutingSessionClearArguments(for: fixture.sessionA)
            trailingNewlineArguments["session_fingerprint"] = .string(fixture.sessionA.sessionFingerprint + "\n")
            let trailingNewline = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: trailingNewlineArguments,
                rawSessionTokens: rawSessionTokens
            )
            Self.assertCleanupError(trailingNewline, code: "invalid_params")
            currentState = await networkManager.debugExactRoutingSessionFixtureState()
            XCTAssertEqual(currentState, seededState)

            var trailingWhitespaceArguments = Self.exactRoutingSessionClearArguments(for: fixture.sessionA)
            trailingWhitespaceArguments["session_fingerprint"] = .string(fixture.sessionA.sessionFingerprint + " ")
            let trailingWhitespace = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: trailingWhitespaceArguments,
                rawSessionTokens: rawSessionTokens
            )
            Self.assertCleanupError(trailingWhitespace, code: "invalid_params")
            currentState = await networkManager.debugExactRoutingSessionFixtureState()
            XCTAssertEqual(currentState, seededState)

            var alternateSelectorArguments = Self.exactRoutingSessionClearArguments(for: fixture.sessionA)
            alternateSelectorArguments["client_name"] = .string(AgentProviderKind.codexMCPClientID)
            let alternateSelector = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: alternateSelectorArguments,
                rawSessionTokens: rawSessionTokens
            )
            Self.assertCleanupError(alternateSelector, code: "invalid_params")
            currentState = await networkManager.debugExactRoutingSessionFixtureState()
            XCTAssertEqual(currentState, seededState)

            let mismatch = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: Self.exactRoutingSessionClearArguments(
                    for: fixture.sessionA,
                    expectedLastConnectionID: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
                ),
                rawSessionTokens: rawSessionTokens
            )
            Self.assertCleanupError(mismatch, code: "last_connection_id_mismatch")
            currentState = await networkManager.debugExactRoutingSessionFixtureState()
            XCTAssertEqual(currentState, seededState)

            await networkManager.debugSetExactRoutingSessionFixtureTargetActive(fixture.sessionA, active: true)
            let activeTarget = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: Self.exactRoutingSessionClearArguments(for: fixture.sessionA),
                rawSessionTokens: rawSessionTokens
            )
            await networkManager.debugSetExactRoutingSessionFixtureTargetActive(fixture.sessionA, active: false)
            Self.assertCleanupError(activeTarget, code: "target_connection_active_or_pending")
            currentState = await networkManager.debugExactRoutingSessionFixtureState()
            XCTAssertEqual(currentState, seededState)

            await networkManager.debugSetExactRoutingSessionFixtureTargetPending(fixture.sessionA, pending: true)
            let pendingTarget = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: Self.exactRoutingSessionClearArguments(for: fixture.sessionA),
                rawSessionTokens: rawSessionTokens
            )
            await networkManager.debugSetExactRoutingSessionFixtureTargetPending(fixture.sessionA, pending: false)
            Self.assertCleanupError(pendingTarget, code: "target_connection_active_or_pending")
            currentState = await networkManager.debugExactRoutingSessionFixtureState()
            XCTAssertEqual(currentState, seededState)

            await networkManager.debugSetExactRoutingSessionFixtureReboundActive(fixture, active: true)
            let rebound = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: Self.exactRoutingSessionClearArguments(for: fixture.sessionA),
                rawSessionTokens: rawSessionTokens
            )
            await networkManager.debugSetExactRoutingSessionFixtureReboundActive(fixture, active: false)
            Self.assertCleanupError(rebound, code: "session_rebound_active")
            currentState = await networkManager.debugExactRoutingSessionFixtureState()
            XCTAssertEqual(currentState, seededState)

            let clearedA = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: Self.exactRoutingSessionClearArguments(for: fixture.sessionA),
                rawSessionTokens: rawSessionTokens
            )
            Self.assertCleanupSuccess(clearedA, session: fixture.sessionA, alreadyAbsent: false, changed: true, expectedCount: 1)
            currentState = await networkManager.debugExactRoutingSessionFixtureState()
            Self.assertFixtureCounts(currentState, session: fixture.sessionA, expected: 0)
            Self.assertFixtureCounts(currentState, session: fixture.sessionB, expected: 1)

            let clearedAAgain = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: Self.exactRoutingSessionClearArguments(for: fixture.sessionA),
                rawSessionTokens: rawSessionTokens
            )
            Self.assertCleanupSuccess(clearedAAgain, session: fixture.sessionA, alreadyAbsent: true, changed: false, expectedCount: 0)
            currentState = await networkManager.debugExactRoutingSessionFixtureState()
            Self.assertFixtureCounts(currentState, session: fixture.sessionA, expected: 0)
            Self.assertFixtureCounts(currentState, session: fixture.sessionB, expected: 1)

            let clearedB = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: Self.exactRoutingSessionClearArguments(for: fixture.sessionB),
                rawSessionTokens: rawSessionTokens
            )
            Self.assertCleanupSuccess(clearedB, session: fixture.sessionB, alreadyAbsent: false, changed: true, expectedCount: 1)
            currentState = await networkManager.debugExactRoutingSessionFixtureState()
            Self.assertFixtureCounts(currentState, session: fixture.sessionA, expected: 0)
            Self.assertFixtureCounts(currentState, session: fixture.sessionB, expected: 0)
        }

        func assertExactRoutingSessionFixtureRestored(
            networkManager: ServerNetworkManager,
            fixture: ServerNetworkManager.DebugExactRoutingSessionFixture,
            baseline: ServerNetworkManager.DebugExactRoutingSessionFixtureState
        ) async {
            let restoredExactly = await networkManager.debugRestoreExactRoutingSessionFixture(fixture)
            XCTAssertTrue(restoredExactly)
            let restoredState = await networkManager.debugExactRoutingSessionFixtureState()
            XCTAssertEqual(restoredState, baseline)
        }

        static func exactRoutingSessionClearArguments(
            for session: ServerNetworkManager.DebugExactRoutingSessionFixtureSession,
            expectedLastConnectionID: UUID? = nil
        ) -> [String: Value] {
            [
                "op": .string("clear_persisted_routing_session"),
                "allow_destructive": .bool(true),
                "session_fingerprint": .string(session.sessionFingerprint),
                "expected_last_connection_id": .string((expectedLastConnectionID ?? session.expectedLastConnectionID).uuidString)
            ]
        }

        static func invokeExactRoutingSessionClear(
            networkManager: ServerNetworkManager,
            callerID: UUID,
            arguments: [String: Value],
            rawSessionTokens: [String]
        ) async throws -> DebugToolInvocation {
            let result = await networkManager.handleDebugDiagnosticsTool(connectionID: callerID, arguments: arguments)
            let serializedText = result.content.compactMap { content -> String? in
                if case let .text(text, _, _) = content { return text }
                return nil
            }.joined()
            for rawSessionToken in rawSessionTokens {
                XCTAssertFalse(serializedText.contains(rawSessionToken), serializedText)
            }
            let data = try XCTUnwrap(serializedText.data(using: .utf8))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return DebugToolInvocation(payload: payload, serializedText: serializedText)
        }

        static func assertCleanupError(_ invocation: DebugToolInvocation, code: String) {
            XCTAssertEqual(invocation.payload["ok"] as? Bool, false, invocation.serializedText)
            XCTAssertEqual(invocation.payload["code"] as? String, code, invocation.serializedText)
        }

        static func assertCleanupSuccess(
            _ invocation: DebugToolInvocation,
            session: ServerNetworkManager.DebugExactRoutingSessionFixtureSession,
            alreadyAbsent: Bool,
            changed: Bool,
            expectedCount: Int
        ) {
            XCTAssertEqual(invocation.payload["ok"] as? Bool, true, invocation.serializedText)
            XCTAssertEqual(invocation.payload["op"] as? String, "clear_persisted_routing_session", invocation.serializedText)
            XCTAssertEqual(invocation.payload["session_fingerprint"] as? String, session.sessionFingerprint, invocation.serializedText)
            XCTAssertEqual(invocation.payload["expected_last_connection_id"] as? String, session.expectedLastConnectionID.uuidString, invocation.serializedText)
            XCTAssertEqual(invocation.payload["already_absent"] as? Bool, alreadyAbsent, invocation.serializedText)
            XCTAssertEqual(invocation.payload["changed"] as? Bool, changed, invocation.serializedText)
            XCTAssertEqual((invocation.payload["removed_persisted_record_count"] as? NSNumber)?.intValue, expectedCount, invocation.serializedText)
            XCTAssertEqual((invocation.payload["removed_last_window_entry_count"] as? NSNumber)?.intValue, expectedCount, invocation.serializedText)
            XCTAssertEqual((invocation.payload["removed_live_run_affinity_entry_count"] as? NSNumber)?.intValue, expectedCount, invocation.serializedText)
            XCTAssertEqual((invocation.payload["removed_total_count"] as? NSNumber)?.intValue, expectedCount * 3, invocation.serializedText)
        }

        static func assertFixtureCounts(
            _ state: ServerNetworkManager.DebugExactRoutingSessionFixtureState,
            session: ServerNetworkManager.DebugExactRoutingSessionFixtureSession,
            expected: Int
        ) {
            XCTAssertEqual(state.persistedRecordCountByFingerprint[session.sessionFingerprint] ?? 0, expected)
            XCTAssertEqual(state.lastWindowEntryCountByFingerprint[session.sessionFingerprint] ?? 0, expected)
            XCTAssertEqual(state.liveRunAffinityEntryCountByFingerprint[session.sessionFingerprint] ?? 0, expected)
        }

        struct DebugToolInvocation {
            let payload: [String: Any]
            let serializedText: String
        }

        static func sharedWindowBroadSearchArguments(countOnly: Bool) -> [String: Any] {
            [
                "pattern": PersistentMCPTestFixture.sharedSearchToken,
                "mode": "content",
                "regex": false,
                "max_results": 100,
                "count_only": countOnly,
                "context_lines": 0
            ]
        }

        static func sharedWindowScopedSearchArguments(path: String) -> [String: Any] {
            [
                "pattern": PersistentMCPTestFixture.sharedSearchToken,
                "mode": "content",
                "regex": false,
                "filter": ["paths": [path]],
                "max_results": 10,
                "count_only": false,
                "context_lines": 0
            ]
        }

        static let searchArguments: [String: Any] = [
            "pattern": PersistentMCPTestFixture.sharedSearchToken,
            "mode": "content",
            "regex": false,
            "max_results": 10,
            "count_only": false,
            "context_lines": 0
        ]

        static let pathSearchArguments: [String: Any] = [
            "pattern": "*.swift",
            "mode": "path",
            "regex": false,
            "max_results": 10,
            "count_only": false,
            "context_lines": 0
        ]

        static func scopedSearchArguments(path: String) -> [String: Any] {
            [
                "pattern": PersistentMCPTestFixture.sharedSearchToken,
                "mode": "content",
                "regex": false,
                "filter": ["paths": [path]],
                "max_results": 10,
                "count_only": false,
                "context_lines": 0
            ]
        }

        static func assertRetainedReadSpellings(_ endpoint: PersistentMCPTestEndpoint, context: PersistentMCPTestContext) async throws {
            let aliasPath = "\(context.rootURL.lastPathComponent)/Sources/\(context.fileURL.lastPathComponent)"
            for path in [
                context.fileURL.path,
                "Sources/\(context.fileURL.lastPathComponent)",
                aliasPath
            ] {
                let response = try await endpoint.callTool(
                    name: MCPWindowToolName.readFile,
                    arguments: ["path": path]
                )
                try assertReadResult(response, contains: context.sentinel, excludes: "sentinel-peer-not-present")
            }
        }

        static func bind(_ endpoint: PersistentMCPTestEndpoint, to tabID: UUID) async throws {
            let response = try await endpoint.callTool(
                name: "bind_context",
                arguments: [
                    "op": "bind",
                    "context_id": tabID.uuidString
                ]
            )
            _ = try toolText(from: response)
        }

        static func sleep(_ endpoint: PersistentMCPTestEndpoint, tag: String) async throws -> Int {
            let response = try await endpoint.callTool(
                name: ServerNetworkManager.debugDiagnosticsToolName,
                arguments: [
                    "op": "sleep",
                    "milliseconds": 400,
                    "tag": tag
                ]
            )
            let payload = try debugPayload(from: response)
            XCTAssertEqual(payload["op"] as? String, "sleep")
            XCTAssertEqual((payload["slept_milliseconds"] as? NSNumber)?.intValue, 400)
            XCTAssertEqual(payload["tag"] as? String, tag)
            return response.id
        }

        static func assertPing(_ endpoint: PersistentMCPTestEndpoint, tag: String) async throws {
            let response = try await endpoint.callTool(
                name: ServerNetworkManager.debugDiagnosticsToolName,
                arguments: ["op": "ping", "tag": tag]
            )
            let payload = try debugPayload(from: response)
            XCTAssertEqual(payload["op"] as? String, "ping")
            XCTAssertEqual(payload["connection_id"] as? String, endpoint.connectionID.uuidString)
            XCTAssertEqual(payload["tag"] as? String, tag)
        }

        static func assertRoutingSnapshot(_ endpoint: PersistentMCPTestEndpoint, context: PersistentMCPTestContext) async throws {
            let response = try await endpoint.callTool(
                name: ServerNetworkManager.debugDiagnosticsToolName,
                arguments: ["op": "routing_snapshot"]
            )
            let payload = try debugPayload(from: response)
            XCTAssertEqual(payload["op"] as? String, "routing_snapshot")
            XCTAssertEqual(payload["current_connection_id"] as? String, endpoint.connectionID.uuidString)
            let binding = try XCTUnwrap(payload["binding"] as? [String: Any])
            XCTAssertEqual(binding["binding_kind"] as? String, "tab_context")
            XCTAssertEqual(binding["window_id"] as? Int, context.window.windowID)
            XCTAssertEqual(binding["context_id"] as? String, context.tabID.uuidString)
            XCTAssertEqual(binding["workspace_id"] as? String, context.workspaceID.uuidString)
            XCTAssertEqual(binding["explicit"] as? Bool, true)
            XCTAssertEqual(binding["run_scoped"] as? Bool, false)
        }

        static func assertStableSnapshot(_ snapshot: PersistentMCPTestEndpointSnapshot, endpoint: PersistentMCPTestEndpoint, context: PersistentMCPTestContext) {
            XCTAssertEqual(snapshot.connectionID, endpoint.connectionID)
            XCTAssertEqual(snapshot.capabilityToken, endpoint.sessionToken)
            XCTAssertTrue(snapshot.ready)
            XCTAssertTrue(snapshot.viable)
            XCTAssertEqual(snapshot.peerPID, Int(getpid()))
            XCTAssertEqual(snapshot.selectedWindowID, context.window.windowID)
            XCTAssertEqual(snapshot.policyPurpose, .unknown)
            XCTAssertTrue(snapshot.restrictedTools.isEmpty)
            XCTAssertTrue(snapshot.additionalTools.isEmpty)
            XCTAssertEqual(snapshot.binding.bindingKind, .tabContext)
            XCTAssertEqual(snapshot.binding.windowID, context.window.windowID)
            XCTAssertEqual(snapshot.binding.tabID, context.tabID)
            XCTAssertEqual(snapshot.binding.workspaceID, context.workspaceID)
            XCTAssertEqual(snapshot.binding.repoPaths, [context.rootURL.path])
            XCTAssertTrue(snapshot.binding.explicitlyBound)
            XCTAssertNil(snapshot.binding.runID)
        }

        static func assertReadResult(_ response: PersistentMCPTestRPCResponse, contains expected: String, excludes peer: String) throws {
            let text = try toolText(from: response)
            XCTAssertTrue(text.contains(expected), text)
            XCTAssertFalse(text.contains(peer), text)
        }

        static func assertSearchResult(_ response: PersistentMCPTestRPCResponse, contains expected: String, excludes peer: String) throws {
            let text = try toolText(from: response)
            assertHealthySearchText(text)
            XCTAssertTrue(text.contains(expected), text)
            XCTAssertFalse(text.contains(peer), text)
        }

        static func assertHealthySearchText(_ text: String) {
            XCTAssertFalse(text.contains("tool_execution_timeout"), text)
            XCTAssertFalse(text.contains("tool_execution_cleanup_unresponsive"), text)
            XCTAssertFalse(text.contains("Temporarily busy"), text)
        }

        static func assertSharedWindowBroadSearchResult(
            _ response: PersistentMCPTestRPCResponse,
            searchFiles: [URL]
        ) throws {
            let text = try toolText(from: response)
            assertHealthySearchText(text)
            for fileURL in searchFiles {
                XCTAssertTrue(text.contains(fileURL.lastPathComponent), text)
            }
        }

        static func boundedTaskValue<Success>(
            _ task: Task<Success, some Error>,
            timeout: Duration = .seconds(12),
            description: String
        ) async throws -> Success {
            let result = PersistentMCPTaskResultBox<Success>()
            let observer = Task {
                do {
                    try await result.store(.success(task.value))
                } catch {
                    result.store(.failure(error))
                }
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if let completed = result.load() {
                    observer.cancel()
                    return try completed.get()
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            task.cancel()
            observer.cancel()
            throw PersistentMCPTaskTimeoutError(description: description)
        }

        static func waitForContentReadLimiterIdle(
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

        static func waitForSearchLaneWaiter(
            store: WorkspaceFileContextStore,
            expectedCount: Int,
            timeoutNanoseconds: UInt64 = 1_000_000_000
        ) async {
            let interval: UInt64 = 5_000_000
            var waited: UInt64 = 0
            while waited < timeoutNanoseconds {
                if await store.searchLaneSnapshotForTesting().waiterCount == expectedCount {
                    return
                }
                try? await Task.sleep(nanoseconds: interval)
                waited += interval
            }
            let finalCount = await store.searchLaneSnapshotForTesting().waiterCount
            XCTAssertEqual(finalCount, expectedCount)
        }

        static func assertSearchBackpressureResult(_ response: PersistentMCPTestRPCResponse) throws {
            let text = try toolText(from: response)
            XCTAssertTrue(text.contains("Temporarily busy"), text)
            XCTAssertTrue(text.contains("**Code**: search_backpressure"), text)
            XCTAssertTrue(text.contains("Retryable**: yes"), text)
            XCTAssertTrue(text.contains("filter.paths"), text)
            XCTAssertFalse(text.contains("tool_execution_timeout"), text)
            XCTAssertFalse(text.contains("tool_execution_cleanup_unresponsive"), text)
            XCTAssertFalse(text.contains("Complete (limit not reached)"), text)
        }

        static func debugPayload(from response: PersistentMCPTestRPCResponse) throws -> [String: Any] {
            let text = try toolText(from: response)
            let data = try XCTUnwrap(text.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        static func toolText(from response: PersistentMCPTestRPCResponse) throws -> String {
            let object = try responseObject(from: response)
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            let text = content.compactMap { $0["text"] as? String }.joined()
            guard result["isError"] as? Bool != true else {
                throw ClientFixtureError.toolReturnedError(text)
            }
            return text
        }

        nonisolated static func responseObject(from response: PersistentMCPTestRPCResponse) throws -> [String: Any] {
            let data = try XCTUnwrap(response.rawJSON.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual((object["id"] as? NSNumber)?.intValue, response.id)
            XCTAssertNil(object["error"])
            return object
        }

        static func measureMilliseconds(_ operation: () async throws -> Void) async rethrows -> Double {
            let clock = ContinuousClock()
            let start = clock.now
            try await operation()
            let components = start.duration(to: clock.now).components
            return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1_000_000_000_000_000
        }

        static func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            let midpoint = sorted.count / 2
            if sorted.count.isMultiple(of: 2) {
                return (sorted[midpoint - 1] + sorted[midpoint]) / 2
            }
            return sorted[midpoint]
        }
    }

    @MainActor
    final class PersistentMCPTestFixture {
        static let sharedSearchToken = "distinct_mcp_connection_shared_search_token"

        let networkManager = ServerNetworkManager.shared
        let rootURL: URL
        let contextA: PersistentMCPTestContext
        let contextB: PersistentMCPTestContext
        let ownedRoutingService: WindowRoutingService?
        private var firstPersistentMCPTestEndpoint: PersistentMCPTestEndpoint?
        private var secondPersistentMCPTestEndpoint: PersistentMCPTestEndpoint?
        private var queuedSearchPersistentMCPTestEndpoint: PersistentMCPTestEndpoint?
        private var overflowSearchPersistentMCPTestEndpoint: PersistentMCPTestEndpoint?
        private var exactReadPersistentMCPTestEndpoint: PersistentMCPTestEndpoint?
        private var additionalPersistentMCPTestEndpoints: [PersistentMCPTestEndpoint] = []
        private var cleanedUp = false

        private init(
            rootURL: URL,
            contextA: PersistentMCPTestContext,
            contextB: PersistentMCPTestContext,
            ownedRoutingService: WindowRoutingService?
        ) {
            self.rootURL = rootURL
            self.contextA = contextA
            self.contextB = contextB
            self.ownedRoutingService = ownedRoutingService
        }

        static func make(
            lease: MCPSharedServerTestLease.Ownership,
            contextBuilderProviderFactory: ContextBuilderAgentViewModel.ProviderFactory? = nil,
            contextASearchFileCount: Int = 1
        ) async throws -> PersistentMCPTestFixture {
            _ = lease
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("PersistentMCPDistinctConnectionConcurrencyTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let windowA = if let contextBuilderProviderFactory {
                WindowState(contextBuilderProviderFactory: contextBuilderProviderFactory)
            } else {
                WindowState()
            }
            let windowB = WindowState()
            WindowStatesManager.shared.registerWindowState(windowA)
            WindowStatesManager.shared.registerWindowState(windowB)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            await windowA.workspaceManager.awaitInitialized()
            await windowB.workspaceManager.awaitInitialized()

            var contextA: PersistentMCPTestContext?
            var contextB: PersistentMCPTestContext?
            var ownedRoutingService: WindowRoutingService?
            var constructedFixture: PersistentMCPTestFixture?
            do {
                contextA = try await makeContext(
                    rootURL: rootURL.appendingPathComponent("context-a", isDirectory: true),
                    fileName: "DistinctConnectionA.swift",
                    sentinel: "let distinctMCPConnectionSentinelA = \"sentinel-a\"",
                    tabID: UUID(),
                    window: windowA,
                    label: "A",
                    searchFileCount: contextASearchFileCount
                )
                contextB = try await makeContext(
                    rootURL: rootURL.appendingPathComponent("context-b", isDirectory: true),
                    fileName: "DistinctConnectionB.swift",
                    sentinel: "let distinctMCPConnectionSentinelB = \"sentinel-b\"",
                    tabID: UUID(),
                    window: windowB,
                    label: "B",
                    searchFileCount: 1
                )
                let routing = try await ensureRoutingService()
                ownedRoutingService = routing.owned ? routing.service : nil
                let fixture = try PersistentMCPTestFixture(
                    rootURL: rootURL,
                    contextA: XCTUnwrap(contextA),
                    contextB: XCTUnwrap(contextB),
                    ownedRoutingService: ownedRoutingService
                )
                constructedFixture = fixture
                fixture.firstPersistentMCPTestEndpoint = try await PersistentMCPTestEndpoint.make(label: "a", networkManager: fixture.networkManager)
                fixture.secondPersistentMCPTestEndpoint = try await PersistentMCPTestEndpoint.make(label: "b", networkManager: fixture.networkManager)
                fixture.queuedSearchPersistentMCPTestEndpoint = try await PersistentMCPTestEndpoint.make(label: "a-queued-search", networkManager: fixture.networkManager)
                fixture.overflowSearchPersistentMCPTestEndpoint = try await PersistentMCPTestEndpoint.make(label: "a-overflow-search", networkManager: fixture.networkManager)
                fixture.exactReadPersistentMCPTestEndpoint = try await PersistentMCPTestEndpoint.make(label: "a-exact-read", networkManager: fixture.networkManager)
                return fixture
            } catch {
                if let constructedFixture {
                    await constructedFixture.cleanup()
                } else {
                    if let contextB { await cleanupContext(contextB) }
                    if let contextA { await cleanupContext(contextA) }
                    if let ownedRoutingService { ServiceRegistry.unregister(ownedRoutingService) }
                    WindowStatesManager.shared.unregisterWindowState(windowB)
                    WindowStatesManager.shared.unregisterWindowState(windowA)
                    try? FileManager.default.removeItem(at: rootURL)
                }
                throw error
            }
        }

        func endpointA() throws -> PersistentMCPTestEndpoint {
            try XCTUnwrap(firstPersistentMCPTestEndpoint)
        }

        func endpointB() throws -> PersistentMCPTestEndpoint {
            try XCTUnwrap(secondPersistentMCPTestEndpoint)
        }

        func endpointAQueuedSearch() throws -> PersistentMCPTestEndpoint {
            try XCTUnwrap(queuedSearchPersistentMCPTestEndpoint)
        }

        func endpointAOverflowSearch() throws -> PersistentMCPTestEndpoint {
            try XCTUnwrap(overflowSearchPersistentMCPTestEndpoint)
        }

        func endpointARead() throws -> PersistentMCPTestEndpoint {
            try XCTUnwrap(exactReadPersistentMCPTestEndpoint)
        }

        func makeAdditionalEndpoint(label: String) async throws -> PersistentMCPTestEndpoint {
            let endpoint = try await PersistentMCPTestEndpoint.make(
                label: label,
                networkManager: networkManager
            )
            additionalPersistentMCPTestEndpoints.append(endpoint)
            return endpoint
        }

        func endpoints() throws -> [PersistentMCPTestEndpoint] {
            try [endpointA(), endpointB(), endpointAQueuedSearch(), endpointAOverflowSearch(), endpointARead()]
                + additionalPersistentMCPTestEndpoints
        }

        func snapshot(_ endpoint: PersistentMCPTestEndpoint, context: PersistentMCPTestContext) async -> PersistentMCPTestEndpointSnapshot {
            let policy = await networkManager.debugConnectionPolicyState(for: endpoint.connectionID)
            return await PersistentMCPTestEndpointSnapshot(
                connectionID: endpoint.connectionID,
                capabilityToken: endpoint.connectionManager.capabilityToken,
                ready: endpoint.connectionManager.connectionState() == .ready,
                viable: endpoint.connectionManager.isViableForRetention(),
                peerPID: endpoint.connectionManager.peerPID(),
                selectedWindowID: networkManager.selectedWindow(for: endpoint.connectionID),
                restrictedTools: policy.restrictedTools,
                additionalTools: policy.additionalTools,
                policyPurpose: policy.purpose,
                binding: context.window.mcpServer.connectionBindingSnapshot(forConnection: endpoint.connectionID)
            )
        }

        func assertStableBindings(includeAdditionalContextAEndpoints: Bool = false) {
            let first = try? endpointA()
            let second = try? endpointB()
            XCTAssertEqual(first.map { contextA.window.mcpServer.connectionBindingSnapshot(forConnection: $0.connectionID).tabID }, contextA.tabID)
            XCTAssertEqual(second.map { contextB.window.mcpServer.connectionBindingSnapshot(forConnection: $0.connectionID).tabID }, contextB.tabID)
            XCTAssertNil(first.flatMap { contextB.window.mcpServer.connectionBindingSnapshot(forConnection: $0.connectionID).tabID })
            XCTAssertNil(second.flatMap { contextA.window.mcpServer.connectionBindingSnapshot(forConnection: $0.connectionID).tabID })
            guard includeAdditionalContextAEndpoints else { return }
            let queued = try? endpointAQueuedSearch()
            let overflow = try? endpointAOverflowSearch()
            let exactRead = try? endpointARead()
            XCTAssertEqual(queued.map { contextA.window.mcpServer.connectionBindingSnapshot(forConnection: $0.connectionID).tabID }, contextA.tabID)
            XCTAssertEqual(overflow.map { contextA.window.mcpServer.connectionBindingSnapshot(forConnection: $0.connectionID).tabID }, contextA.tabID)
            XCTAssertEqual(exactRead.map { contextA.window.mcpServer.connectionBindingSnapshot(forConnection: $0.connectionID).tabID }, contextA.tabID)
            XCTAssertNil(queued.flatMap { contextB.window.mcpServer.connectionBindingSnapshot(forConnection: $0.connectionID).tabID })
            XCTAssertNil(overflow.flatMap { contextB.window.mcpServer.connectionBindingSnapshot(forConnection: $0.connectionID).tabID })
            XCTAssertNil(exactRead.flatMap { contextB.window.mcpServer.connectionBindingSnapshot(forConnection: $0.connectionID).tabID })
        }

        func cleanup() async {
            guard !cleanedUp else { return }
            cleanedUp = true
            let fixedEndpoints = [
                firstPersistentMCPTestEndpoint,
                secondPersistentMCPTestEndpoint,
                queuedSearchPersistentMCPTestEndpoint,
                overflowSearchPersistentMCPTestEndpoint,
                exactReadPersistentMCPTestEndpoint
            ].compactMap(\.self)
            for endpoint in fixedEndpoints + additionalPersistentMCPTestEndpoints {
                endpoint.client.close()
                await endpoint.connectionManager.stop()
                await networkManager.debugRemoveConnection(endpoint.connectionID)
                await networkManager.clearClientConnectionPolicy(for: endpoint.clientName)
                await networkManager.debugClearPersistedRoutingState(for: endpoint.clientName)
                contextA.window.mcpServer.removeTabContext(
                    forConnectionID: endpoint.connectionID,
                    clientName: endpoint.clientName,
                    windowID: nil,
                    runID: nil
                )
                contextB.window.mcpServer.removeTabContext(
                    forConnectionID: endpoint.connectionID,
                    clientName: endpoint.clientName,
                    windowID: nil,
                    runID: nil
                )
            }
            await contextA.window.mcpServer.shutdownListener()
            ServiceRegistry.unregister(contextB.catalogService)
            ServiceRegistry.unregister(contextA.catalogService)
            await contextB.window.workspaceFilesViewModel.cancelAllScans()
            await contextA.window.workspaceFilesViewModel.cancelAllScans()
            await contextB.window.workspaceFileContextStore.unloadRoot(id: contextB.rootID)
            await contextA.window.workspaceFileContextStore.unloadRoot(id: contextA.rootID)
            contextB.window.workspaceManager.workspaces.removeAll { $0.id == contextB.workspaceID }
            contextA.window.workspaceManager.workspaces.removeAll { $0.id == contextA.workspaceID }
            WindowStatesManager.shared.unregisterWindowState(contextB.window)
            WindowStatesManager.shared.unregisterWindowState(contextA.window)
            if let ownedRoutingService { ServiceRegistry.unregister(ownedRoutingService) }
            try? FileManager.default.removeItem(at: rootURL)
        }

        func assertCleanedUp() async throws {
            for endpoint in try endpoints() {
                let hasInFlightCalls = await networkManager.hasInFlightCalls(for: endpoint.connectionID)
                let selectedWindow = await networkManager.selectedWindow(for: endpoint.connectionID)
                XCTAssertFalse(hasInFlightCalls)
                XCTAssertNil(selectedWindow)
                let policy = await networkManager.debugConnectionPolicyState(for: endpoint.connectionID)
                XCTAssertTrue(policy.restrictedTools.isEmpty)
                XCTAssertTrue(policy.additionalTools.isEmpty)
                XCTAssertEqual(policy.purpose, .unknown)
                XCTAssertNil(policy.windowID)
                let pendingPolicies = await networkManager.debugPendingPolicySnapshot(for: endpoint.clientName)
                XCTAssertTrue(pendingPolicies.isEmpty)
                XCTAssertEqual(contextA.window.mcpServer.connectionBindingSnapshot(forConnection: endpoint.connectionID).bindingKind, .unbound)
                XCTAssertEqual(contextB.window.mcpServer.connectionBindingSnapshot(forConnection: endpoint.connectionID).bindingKind, .unbound)
                do {
                    _ = try await endpoint.client.request(method: "tools/list", params: [:])
                    XCTFail("closed socket unexpectedly accepted a request")
                } catch PersistentMCPTestSocketClient.ClientError.closed {
                    // Expected.
                } catch {
                    XCTFail("closed socket failed with unexpected error: \(error)")
                }
            }
        }

        private static func makeContext(
            rootURL: URL,
            fileName: String,
            sentinel: String,
            tabID: UUID,
            window: WindowState,
            label: String,
            searchFileCount: Int
        ) async throws -> PersistentMCPTestContext {
            precondition(searchFileCount > 0)
            let sourceDirectory = rootURL.appendingPathComponent("Sources", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            let fileURL = sourceDirectory.appendingPathComponent(fileName)
            var searchFileURLs = [fileURL]
            try "\(sentinel)\n// \(sharedSearchToken)\n".write(to: fileURL, atomically: true, encoding: .utf8)
            for index in 1 ..< searchFileCount {
                let additionalURL = sourceDirectory.appendingPathComponent(
                    String(format: "DistinctConnection%@-%02d.swift", label, index)
                )
                try "let distinctMCPScopedFileIndex = \(index)\n// \(sharedSearchToken)\n".write(
                    to: additionalURL,
                    atomically: true,
                    encoding: .utf8
                )
                searchFileURLs.append(additionalURL)
            }
            searchFileURLs.sort { $0.path < $1.path }
            var configuredWorkspace = WorkspaceModel(
                name: "Distinct MCP Connection \(label)",
                repoPaths: [rootURL.path]
            )
            configuredWorkspace.isEphemeral = true
            configuredWorkspace.composeTabs = [
                ComposeTabState(id: tabID, name: "Distinct MCP Connection \(label)")
            ]
            configuredWorkspace.activeComposeTabID = tabID
            window.workspaceManager.workspaces.append(configuredWorkspace)
            let rootRecord = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
                in: window,
                path: rootURL.path
            )
            let exactHit = await WorkspaceReadableFileService(store: window.workspaceFileContextStore)
                .resolveExactAbsoluteWorkspaceCatalogHit(fileURL.path, rootScope: .visibleWorkspace)
            guard exactHit?.standardizedFullPath == fileURL.path else {
                throw ClientFixtureError.exactAbsoluteCatalogMiss
            }
            let catalogService = window.mcpServer.windowMCPToolCatalogService
            ServiceRegistry.register(catalogService)
            return PersistentMCPTestContext(
                rootURL: rootURL,
                fileURL: fileURL,
                searchFileURLs: searchFileURLs,
                rootID: rootRecord.id,
                window: window,
                workspaceID: configuredWorkspace.id,
                tabID: tabID,
                sentinel: sentinel,
                catalogService: catalogService
            )
        }

        private static func ensureRoutingService() async throws -> (service: WindowRoutingService, owned: Bool) {
            if let existing = ServiceRegistry.services.first(where: { $0 is WindowRoutingService }) as? WindowRoutingService {
                return (existing, false)
            }
            let service = WindowRoutingService(windowStates: .shared, networkMgr: .shared)
            for _ in 0 ..< 100 {
                let registered = ServiceRegistry.services.contains { $0 as AnyObject === service as AnyObject }
                let names = await service.tools.map(\.name)
                if registered, names.contains("bind_context") {
                    return (service, true)
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            ServiceRegistry.unregister(service)
            throw ClientFixtureError.routingServiceUnavailable
        }

        private static func cleanupContext(_ context: PersistentMCPTestContext) async {
            ServiceRegistry.unregister(context.catalogService)
            await context.window.workspaceFileContextStore.unloadRoot(id: context.rootID)
            context.window.workspaceManager.workspaces.removeAll { $0.id == context.workspaceID }
            try? FileManager.default.removeItem(at: context.rootURL)
        }
    }

    @MainActor
    final class PersistentMCPTestContext {
        let rootURL: URL
        let fileURL: URL
        let searchFileURLs: [URL]
        let rootID: UUID
        let window: WindowState
        let workspaceID: UUID
        let tabID: UUID
        let sentinel: String
        let catalogService: MCPWindowToolCatalogService

        init(
            rootURL: URL,
            fileURL: URL,
            searchFileURLs: [URL],
            rootID: UUID,
            window: WindowState,
            workspaceID: UUID,
            tabID: UUID,
            sentinel: String,
            catalogService: MCPWindowToolCatalogService
        ) {
            self.rootURL = rootURL
            self.fileURL = fileURL
            self.searchFileURLs = searchFileURLs
            self.rootID = rootID
            self.window = window
            self.workspaceID = workspaceID
            self.tabID = tabID
            self.sentinel = sentinel
            self.catalogService = catalogService
        }
    }

    struct PersistentMCPTestEndpointSnapshot: Equatable {
        let connectionID: UUID
        let capabilityToken: String?
        let ready: Bool
        let viable: Bool
        let peerPID: Int
        let selectedWindowID: Int?
        let restrictedTools: Set<String>
        let additionalTools: Set<String>
        let policyPurpose: MCPRunPurpose
        let binding: MCPServerViewModel.ConnectionBindingSnapshot
    }

    final class PersistentMCPTestEndpoint: @unchecked Sendable {
        let connectionID: UUID
        let sessionToken: String
        let clientName: String
        let client: PersistentMCPTestSocketClient
        let connectionManager: BootstrapSocketConnectionManager

        private init(
            connectionID: UUID,
            sessionToken: String,
            clientName: String,
            client: PersistentMCPTestSocketClient,
            connectionManager: BootstrapSocketConnectionManager
        ) {
            self.connectionID = connectionID
            self.sessionToken = sessionToken
            self.clientName = clientName
            self.client = client
            self.connectionManager = connectionManager
        }

        static func make(
            label: String,
            networkManager: ServerNetworkManager,
            clientName overrideClientName: String? = nil,
            requiredToolNames: Set<String> = [
                MCPWindowToolName.readFile,
                MCPWindowToolName.search,
                "bind_context"
            ]
        ) async throws -> PersistentMCPTestEndpoint {
            let connectionID = UUID()
            let sessionToken = "persistent-mcp-distinct-\(label)-\(UUID().uuidString)"
            let clientName = overrideClientName ?? "persistent-mcp-distinct-\(label)-\(UUID().uuidString)"
            await networkManager.debugClearPersistedRoutingState(for: clientName)
            var socketFDs = [Int32](repeating: -1, count: 2)
            guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &socketFDs) == 0 else {
                throw PersistentMCPTestSocketClient.ClientError.posix(operation: "socketpair", code: errno)
            }
            var noSigPipe: Int32 = 1
            guard Darwin.setsockopt(
                socketFDs[0],
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout.size(ofValue: noSigPipe))
            ) == 0 else {
                let code = errno
                Darwin.close(socketFDs[0])
                Darwin.close(socketFDs[1])
                throw PersistentMCPTestSocketClient.ClientError.posix(operation: "setsockopt(SO_NOSIGPIPE)", code: code)
            }
            let client = PersistentMCPTestSocketClient(fd: socketFDs[0])
            let manager = try BootstrapSocketConnectionManager(
                connectionID: connectionID,
                sessionToken: sessionToken,
                clientPid: Int(getpid()),
                clientName: clientName,
                purpose: .unknown,
                codeMapsDisabled: false,
                connectedFD: socketFDs[1],
                parentManager: networkManager
            )
            let endpoint = PersistentMCPTestEndpoint(
                connectionID: connectionID,
                sessionToken: sessionToken,
                clientName: clientName,
                client: client,
                connectionManager: manager
            )
            await networkManager.debugRegisterConnectionForSocketFixture(
                connectionID: connectionID,
                connection: manager,
                clientName: clientName,
                sessionToken: sessionToken
            )
            let startTask = Task {
                try await manager.start { clientInfo in
                    guard clientInfo.name == clientName else { return false }
                    _ = await networkManager.debugApplyPendingPolicy(
                        clientName: clientName,
                        connectionID: connectionID,
                        clientPid: Int(getpid()),
                        bootstrapClientName: clientInfo.name
                    )
                    return true
                }
            }
            do {
                let initialize = try await client.request(
                    method: "initialize",
                    params: [
                        "protocolVersion": "2025-11-25",
                        "capabilities": [:],
                        "clientInfo": [
                            "name": clientName,
                            "version": "persistent-mcp-distinct-connection-concurrency-test"
                        ]
                    ]
                )
                _ = try PersistentMCPDistinctConnectionConcurrencyTests.responseObject(from: initialize)
                try await startTask.value
                try client.sendNotification(method: "notifications/initialized", params: [:])
                let tools = try await client.request(method: "tools/list", params: [:])
                let names = try Self.toolNames(from: tools)
                for requiredToolName in requiredToolNames {
                    XCTAssertTrue(names.contains(requiredToolName), "Missing required tool \(requiredToolName): \(names)")
                }
                return endpoint
            } catch {
                startTask.cancel()
                client.close()
                await manager.stop()
                await networkManager.debugRemoveConnection(connectionID)
                await networkManager.debugClearPersistedRoutingState(for: clientName)
                _ = try? await startTask.value
                throw error
            }
        }

        func callTool(
            name: String,
            arguments: [String: Any],
            timeoutSeconds: Int = 10
        ) async throws -> PersistentMCPTestRPCResponse {
            try await client.request(
                method: "tools/call",
                params: [
                    "name": name,
                    "arguments": arguments
                ],
                timeoutSeconds: timeoutSeconds
            )
        }

        private static func toolNames(from response: PersistentMCPTestRPCResponse) throws -> [String] {
            let object = try PersistentMCPDistinctConnectionConcurrencyTests.responseObject(from: response)
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
            return tools.compactMap { $0["name"] as? String }
        }
    }

    struct PersistentMCPTestRPCResponse {
        let id: Int
        let rawJSON: String
    }

    final class PersistentMCPTestSocketClient: @unchecked Sendable {
        enum ClientError: Error {
            case closed
            case duplicateRequestID(Int)
            case invalidResponse
            case posix(operation: String, code: Int32)
            case timedOut(Int)
            case unexpectedResponseID(Int)
        }

        private let writeQueue = DispatchQueue(label: "PersistentMCPDistinctConnectionConcurrencyTests.write")
        private let readQueue = DispatchQueue(label: "PersistentMCPDistinctConnectionConcurrencyTests.read")
        private let stateLock = NSLock()
        private var fd: Int32
        private var nextRequestID = 1
        private var pending: [Int: CheckedContinuation<String, Error>] = [:]
        private var responseInterceptors: [Int: @Sendable (String) async throws -> String] = [:]
        private var notifications: [String] = []
        private var isClosed = false

        init(fd: Int32) {
            self.fd = fd
            readQueue.async { [weak self] in
                self?.readerLoop()
            }
        }

        deinit {
            close()
        }

        func close() {
            close(with: ClientError.closed)
        }

        func nextRequestIDForTesting() -> Int {
            withStateLock { nextRequestID }
        }

        func installResponseInterceptor(
            for requestID: Int,
            interceptor: @escaping @Sendable (String) async throws -> String
        ) {
            withStateLock {
                responseInterceptors[requestID] = interceptor
            }
        }

        func sendNotification(method: String, params: [String: Any]) throws {
            try sendJSON([
                "jsonrpc": "2.0",
                "method": method,
                "params": params
            ])
        }

        func request(method: String, params: [String: Any], timeoutSeconds: Int = 10) async throws -> PersistentMCPTestRPCResponse {
            let id = allocateRequestID()
            let rawJSON = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    var registered = false
                    do {
                        try register(continuation, for: id)
                        registered = true
                        try sendJSON([
                            "jsonrpc": "2.0",
                            "id": id,
                            "method": method,
                            "params": params
                        ])
                        Task { [weak self] in
                            try? await Task.sleep(for: .seconds(timeoutSeconds))
                            self?.failPending(id: id, error: ClientError.timedOut(id))
                        }
                    } catch {
                        if registered {
                            // Once registered, only the pending map owns the resume; if
                            // failPending finds nothing, close() already resumed it.
                            failPending(id: id, error: error)
                        } else {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                self.failPending(id: id, error: CancellationError())
            }
            return PersistentMCPTestRPCResponse(id: id, rawJSON: rawJSON)
        }

        private func allocateRequestID() -> Int {
            withStateLock {
                defer { nextRequestID += 1 }
                return nextRequestID
            }
        }

        private func register(_ continuation: CheckedContinuation<String, Error>, for id: Int) throws {
            try withStateLock {
                guard !isClosed, fd >= 0 else { throw ClientError.closed }
                guard pending[id] == nil else { throw ClientError.duplicateRequestID(id) }
                pending[id] = continuation
            }
        }

        private func sendJSON(_ object: [String: Any]) throws {
            var line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            line.append(0x0A)
            try writeQueue.sync {
                var written = 0
                while written < line.count {
                    let activeFD = withStateLock { isClosed ? -1 : fd }
                    guard activeFD >= 0 else { throw ClientError.closed }
                    let result = line.withUnsafeBytes { bytes in
                        Darwin.write(activeFD, bytes.baseAddress?.advanced(by: written), line.count - written)
                    }
                    if result > 0 {
                        written += result
                        continue
                    }
                    if result < 0, errno == EINTR { continue }
                    throw ClientError.posix(operation: "write", code: errno)
                }
            }
        }

        private func readerLoop() {
            var buffer = Data()
            while true {
                let activeFD = withStateLock { isClosed ? -1 : fd }
                guard activeFD >= 0 else { return }
                var descriptor = pollfd(fd: activeFD, events: Int16(POLLIN), revents: 0)
                let pollResult = Darwin.poll(&descriptor, 1, 100)
                if pollResult == 0 { continue }
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    if withStateLock({ isClosed }) { return }
                    close(with: ClientError.posix(operation: "poll", code: errno))
                    return
                }
                if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0,
                   descriptor.revents & Int16(POLLIN) == 0
                {
                    close(with: ClientError.closed)
                    return
                }
                var bytes = [UInt8](repeating: 0, count: 4096)
                let readCount = bytes.withUnsafeMutableBytes { storage in
                    Darwin.read(activeFD, storage.baseAddress, storage.count)
                }
                if readCount > 0 {
                    buffer.append(contentsOf: bytes.prefix(readCount))
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = Data(buffer[..<newline])
                        buffer.removeSubrange(buffer.startIndex ... newline)
                        guard handle(line) else { return }
                    }
                    continue
                }
                if readCount == 0 {
                    close(with: ClientError.closed)
                    return
                }
                if errno == EINTR { continue }
                if withStateLock({ isClosed }) { return }
                close(with: ClientError.posix(operation: "read", code: errno))
                return
            }
        }

        private func handle(_ line: Data) -> Bool {
            do {
                let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                guard let object else { throw ClientError.invalidResponse }
                if let rawID = object["id"] {
                    guard let id = (rawID as? NSNumber)?.intValue else { throw ClientError.invalidResponse }
                    let pendingResponse = takePendingResponse(id: id)
                    guard let continuation = pendingResponse.continuation else {
                        throw ClientError.unexpectedResponseID(id)
                    }
                    guard let rawJSON = String(data: line, encoding: .utf8) else { throw ClientError.invalidResponse }
                    guard let interceptor = pendingResponse.interceptor else {
                        continuation.resume(returning: rawJSON)
                        return true
                    }
                    Task { [weak self] in
                        do {
                            try await continuation.resume(returning: interceptor(rawJSON))
                        } catch {
                            continuation.resume(throwing: error)
                            self?.close(with: error)
                        }
                    }
                    return true
                }
                guard object["method"] as? String != nil,
                      let rawJSON = String(data: line, encoding: .utf8)
                else {
                    throw ClientError.invalidResponse
                }
                withStateLock { notifications.append(rawJSON) }
                return true
            } catch {
                close(with: error)
                return false
            }
        }

        private func takePending(id: Int) -> CheckedContinuation<String, Error>? {
            withStateLock {
                responseInterceptors.removeValue(forKey: id)
                return pending.removeValue(forKey: id)
            }
        }

        private func takePendingResponse(
            id: Int
        ) -> (
            continuation: CheckedContinuation<String, Error>?,
            interceptor: (@Sendable (String) async throws -> String)?
        ) {
            withStateLock {
                (pending.removeValue(forKey: id), responseInterceptors.removeValue(forKey: id))
            }
        }

        @discardableResult
        private func failPending(id: Int, error: Error) -> Bool {
            guard let continuation = takePending(id: id) else { return false }
            continuation.resume(throwing: error)
            return true
        }

        private func close(with error: Error) {
            let snapshot: (Int32, [CheckedContinuation<String, Error>]) = withStateLock {
                guard !isClosed else { return (-1, []) }
                isClosed = true
                let activeFD = fd
                fd = -1
                let continuations = Array(pending.values)
                pending.removeAll()
                responseInterceptors.removeAll()
                return (activeFD, continuations)
            }
            if snapshot.0 >= 0 { Darwin.close(snapshot.0) }
            for continuation in snapshot.1 {
                continuation.resume(throwing: error)
            }
        }

        private func withStateLock<T>(_ operation: () throws -> T) rethrows -> T {
            stateLock.lock()
            defer { stateLock.unlock() }
            return try operation()
        }
    }

    private struct PersistentMCPTaskTimeoutError: Error, CustomStringConvertible {
        let description: String
    }

    private final class PersistentMCPTaskResultBox<Success>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Success, Error>?

        func store(_ result: Result<Success, Error>) {
            lock.lock()
            self.result = result
            lock.unlock()
        }

        func load() -> Result<Success, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    private actor SearchAdmissionGate {
        private let onStarted: @Sendable () -> Void
        private var startedCount = 0
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        init(onStarted: @escaping @Sendable () -> Void) {
            self.onStarted = onStarted
        }

        func markStartedAndWaitForRelease() async {
            startedCount += 1
            if startedCount == 1 {
                onStarted()
            }
            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func startedCountSnapshot() -> Int {
            startedCount
        }

        func waitUntilStarted(timeout: Duration = .seconds(2)) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while startedCount == 0, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return startedCount > 0
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }
    }

    private enum ClientFixtureError: Error {
        case broadSearchDidNotStart
        case exactAbsoluteCatalogMiss
        case routingServiceUnavailable
        case toolReturnedError(String)
    }
#endif
