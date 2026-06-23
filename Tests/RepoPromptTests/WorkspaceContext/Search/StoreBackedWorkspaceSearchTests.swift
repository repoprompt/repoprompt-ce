@testable import RepoPrompt
import XCTest

@MainActor
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

    #if DEBUG

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

    #endif

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
