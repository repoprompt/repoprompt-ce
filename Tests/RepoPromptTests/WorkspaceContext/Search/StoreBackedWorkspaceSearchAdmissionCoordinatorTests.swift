import Foundation
@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

#if DEBUG
    final class StoreBackedWorkspaceSearchAdmissionCoordinatorTests: XCTestCase {
        override func tearDown() {
            EditFlowPerf.resetDebugCaptureForTesting()
            super.tearDown()
        }

        func testProductionPolicyUsesPerStorePrimaryProtectionAndSupportsTwelveWindows() {
            let configuration = StoreBackedWorkspaceSearchAdmissionCoordinator.Configuration.production
            XCTAssertEqual(configuration.perStoreCapacity, 2)
            XCTAssertEqual(configuration.globalCapacity, max(12, min(32, ProcessInfo.processInfo.activeProcessorCount * 2)))
            XCTAssertGreaterThanOrEqual(configuration.globalCapacity, 12)
            XCTAssertEqual(configuration.maxQueuedPerStore, 2)
            XCTAssertEqual(configuration.maxQueuedGlobally, 4)
            XCTAssertEqual(configuration.maxQueueWait, .seconds(8))
        }

        func testSameStoreCapacityTwoAdmitsTwoAndQueuesThird() async throws {
            let coordinator = makeCoordinator()
            let store = WorkspaceFileContextStore()
            let gate = PermitGate()
            await installGate(gate, on: coordinator)

            let first = permitTask(coordinator: coordinator, store: store, value: 1)
            let second = permitTask(coordinator: coordinator, store: store, value: 2)
            await assertTrue(gate.waitUntilStartedCount(2))
            let third = permitTask(coordinator: coordinator, store: store, value: 3)
            await assertTrue(waitForSnapshot(store: store, coordinator: coordinator) { $0.waiterCount == 1 })

            let held = await coordinator.snapshot(for: store)
            XCTAssertEqual(held.activePermitCount, 2)
            XCTAssertEqual(held.waiterCount, 1)
            let globalHeld = await coordinator.snapshot()
            XCTAssertEqual(globalHeld.activePermitCount, 2)
            XCTAssertEqual(globalHeld.waiterCount, 1)

            await gate.releaseAll()
            try await assertEqual(first.value, 1)
            try await assertEqual(second.value, 2)
            try await assertEqual(third.value, 3)
            await assertEqual(coordinator.snapshot(), .init(activePermitCount: 0, waiterCount: 0, laneCount: 0))
        }

        func testGlobalCapAllowsIdleBorrowingAndHandsOffToNewStore() async throws {
            let coordinator = makeCoordinator(
                configuration: .init(
                    perStoreCapacity: 2,
                    globalCapacity: 2,
                    maxQueuedPerStore: 2,
                    maxQueuedGlobally: 4,
                    maxQueueWait: .seconds(8)
                )
            )
            let storeA = WorkspaceFileContextStore()
            let storeB = WorkspaceFileContextStore()
            let gate = PermitGate()
            await installGate(gate, on: coordinator)

            let firstA = permitTask(coordinator: coordinator, store: storeA, value: 1)
            let secondA = permitTask(coordinator: coordinator, store: storeA, value: 2)
            await assertTrue(gate.waitUntilStartedCount(2))
            await assertEqual(coordinator.snapshot(for: storeA).activePermitCount, 2, "One store should borrow all idle global capacity.")

            let firstB = permitTask(coordinator: coordinator, store: storeB, value: 3)
            await assertTrue(waitForSnapshot(store: storeB, coordinator: coordinator) { $0.waiterCount == 1 })
            await assertEqual(coordinator.snapshot().activePermitCount, 2)

            await gate.releaseFirst()
            await assertTrue(gate.waitUntilStartedCount(3))
            let startedStores = await gate.startedStores()
            XCTAssertEqual(startedStores, [ObjectIdentifier(storeA), ObjectIdentifier(storeA), ObjectIdentifier(storeB)])

            await gate.releaseAll()
            try await assertEqual(firstA.value, 1)
            try await assertEqual(secondA.value, 2)
            try await assertEqual(firstB.value, 3)
            await assertEqual(coordinator.snapshot().laneCount, 0)
        }

        func testIdleGlobalCapacityRemainsBorrowableWhenHotStoreQueueIsIneligible() async throws {
            let coordinator = makeCoordinator(
                configuration: .init(
                    perStoreCapacity: 1,
                    globalCapacity: 2,
                    maxQueuedPerStore: 1,
                    maxQueuedGlobally: 1,
                    maxQueueWait: .seconds(8)
                )
            )
            let storeA = WorkspaceFileContextStore()
            let storeB = WorkspaceFileContextStore()
            let gate = PermitGate()
            await installGate(gate, on: coordinator)

            let heldA = permitTask(coordinator: coordinator, store: storeA, value: 1)
            await assertTrue(gate.waitUntilStartedCount(1))
            let queuedA = permitTask(coordinator: coordinator, store: storeA, value: 2)
            await assertTrue(waitForSnapshot(store: storeA, coordinator: coordinator) { $0.waiterCount == 1 })
            let borrowedB = permitTask(coordinator: coordinator, store: storeB, value: 3)
            await assertTrue(gate.waitUntilStartedCount(2))
            await assertEqual(coordinator.snapshot(for: storeB).activePermitCount, 1)
            await assertEqual(coordinator.snapshot().activePermitCount, 2)
            await assertEqual(coordinator.snapshot().waiterCount, 1)

            await gate.releaseAll()
            try await assertEqual(heldA.value, 1)
            try await assertEqual(queuedA.value, 2)
            try await assertEqual(borrowedB.value, 3)
            await assertEqual(coordinator.snapshot().laneCount, 0)
        }

        func testCrossStoreHandoffUsesLeastRecentlyGrantedEligibleLane() async throws {
            let coordinator = makeCoordinator(
                configuration: .init(
                    perStoreCapacity: 2,
                    globalCapacity: 2,
                    maxQueuedPerStore: 2,
                    maxQueuedGlobally: 4,
                    maxQueueWait: .seconds(8)
                )
            )
            let storeA = WorkspaceFileContextStore()
            let storeB = WorkspaceFileContextStore()
            let gate = PermitGate()
            await installGate(gate, on: coordinator)

            let firstA = permitTask(coordinator: coordinator, store: storeA, value: 1)
            await assertTrue(gate.waitUntilStartedCount(1))
            let firstB = permitTask(coordinator: coordinator, store: storeB, value: 2)
            await assertTrue(gate.waitUntilStartedCount(2))
            let secondA = permitTask(coordinator: coordinator, store: storeA, value: 3)
            let secondB = permitTask(coordinator: coordinator, store: storeB, value: 4)
            await assertTrue(waitForGlobalSnapshot(coordinator: coordinator) { $0.waiterCount == 2 })

            await gate.releaseFirst()
            await assertTrue(gate.waitUntilStartedCount(3))
            await gate.releaseFirst()
            await assertTrue(gate.waitUntilStartedCount(4))
            await assertEqual(
                gate.startedStores(),
                [ObjectIdentifier(storeA), ObjectIdentifier(storeB), ObjectIdentifier(storeA), ObjectIdentifier(storeB)]
            )

            await gate.releaseAll()
            try await assertEqual(firstA.value, 1)
            try await assertEqual(firstB.value, 2)
            try await assertEqual(secondA.value, 3)
            try await assertEqual(secondB.value, 4)
            await assertEqual(coordinator.snapshot().laneCount, 0)
        }

        func testPerStoreQueueBoundRejectsPromptlyAndCleansUp() async throws {
            let coordinator = makeCoordinator(
                configuration: .init(
                    perStoreCapacity: 1,
                    globalCapacity: 1,
                    maxQueuedPerStore: 1,
                    maxQueuedGlobally: 4,
                    maxQueueWait: .seconds(8)
                )
            )
            let store = WorkspaceFileContextStore()
            let gate = PermitGate()
            await installGate(gate, on: coordinator)

            let held = permitTask(coordinator: coordinator, store: store, value: 1)
            await assertTrue(gate.waitUntilStartedCount(1))
            let queued = permitTask(coordinator: coordinator, store: store, value: 2)
            await assertTrue(waitForSnapshot(store: store, coordinator: coordinator) { $0.waiterCount == 1 })
            let rejected = permitTask(coordinator: coordinator, store: store, value: 3)
            await assertQueueFull(rejected, scope: .perStore)
            await assertEqual(coordinator.snapshot(for: store).waiterCount, 1)

            await gate.releaseAll()
            try await assertEqual(held.value, 1)
            try await assertEqual(queued.value, 2)
            await assertEqual(coordinator.snapshot().laneCount, 0)
        }

        func testGlobalQueueBoundRejectsPromptlyAndCleansUp() async throws {
            let coordinator = makeCoordinator(
                configuration: .init(
                    perStoreCapacity: 1,
                    globalCapacity: 1,
                    maxQueuedPerStore: 2,
                    maxQueuedGlobally: 1,
                    maxQueueWait: .seconds(8)
                )
            )
            let storeA = WorkspaceFileContextStore()
            let storeB = WorkspaceFileContextStore()
            let storeC = WorkspaceFileContextStore()
            let gate = PermitGate()
            await installGate(gate, on: coordinator)

            let held = permitTask(coordinator: coordinator, store: storeA, value: 1)
            await assertTrue(gate.waitUntilStartedCount(1))
            let queued = permitTask(coordinator: coordinator, store: storeB, value: 2)
            await assertTrue(waitForGlobalSnapshot(coordinator: coordinator) { $0.waiterCount == 1 })
            let rejected = permitTask(coordinator: coordinator, store: storeC, value: 3)
            await assertQueueFull(rejected, scope: .global)
            await assertEqual(coordinator.snapshot().waiterCount, 1)

            await gate.releaseAll()
            try await assertEqual(held.value, 1)
            try await assertEqual(queued.value, 2)
            await assertEqual(coordinator.snapshot().laneCount, 0)
        }

        func testQueuedWaiterExpiresAtInjectedDeadlineAndReclaimsCapacity() async throws {
            let manualClock = ManualAdmissionClock()
            let coordinator = makeCoordinator(
                configuration: .init(
                    perStoreCapacity: 1,
                    globalCapacity: 1,
                    maxQueuedPerStore: 1,
                    maxQueuedGlobally: 1,
                    maxQueueWait: .seconds(8)
                ),
                clock: manualClock.makeClock()
            )
            let store = WorkspaceFileContextStore()
            let gate = PermitGate()
            await installGate(gate, on: coordinator)

            let held = permitTask(coordinator: coordinator, store: store, value: 1)
            await assertTrue(gate.waitUntilStartedCount(1))
            let expired = permitTask(coordinator: coordinator, store: store, value: 2)
            await assertTrue(waitForSnapshot(store: store, coordinator: coordinator) { $0.waiterCount == 1 })
            manualClock.advance(by: .seconds(7))
            await assertEqual(coordinator.snapshot(for: store).waiterCount, 1)
            manualClock.advance(by: .seconds(1))
            await assertWaitExpired(expired)
            await assertEqual(coordinator.snapshot(for: store).waiterCount, 0)

            let replacement = permitTask(coordinator: coordinator, store: store, value: 3)
            await assertTrue(waitForSnapshot(store: store, coordinator: coordinator) { $0.waiterCount == 1 })
            await gate.releaseAll()
            try await assertEqual(held.value, 1)
            try await assertEqual(replacement.value, 3)
            await assertEqual(coordinator.snapshot().laneCount, 0)
        }

        func testQueuedCancellationVersusExpiryRaceDoesNotLeakWaiterOrLane() async throws {
            let manualClock = ManualAdmissionClock()
            let coordinator = makeCoordinator(
                configuration: .init(
                    perStoreCapacity: 1,
                    globalCapacity: 1,
                    maxQueuedPerStore: 1,
                    maxQueuedGlobally: 1,
                    maxQueueWait: .seconds(8)
                ),
                clock: manualClock.makeClock()
            )
            let store = WorkspaceFileContextStore()
            let gate = PermitGate()
            await installGate(gate, on: coordinator)

            let held = permitTask(coordinator: coordinator, store: store, value: 1)
            await assertTrue(gate.waitUntilStartedCount(1))
            let raced = permitTask(coordinator: coordinator, store: store, value: 2)
            await assertTrue(waitForSnapshot(store: store, coordinator: coordinator) { $0.waiterCount == 1 })

            raced.cancel()
            manualClock.advance(by: .seconds(8))
            do {
                _ = try await raced.value
                XCTFail("Expected cancellation or expiry")
            } catch is CancellationError {
                // Cancellation won the actor race.
            } catch let error as StoreBackedWorkspaceSearchAdmissionError {
                XCTAssertEqual(error, .waitExpired(retryAfterMilliseconds: 1000))
            }
            await assertEqual(coordinator.snapshot(for: store).waiterCount, 0)

            await gate.releaseAll()
            try await assertEqual(held.value, 1)
            await assertEqual(coordinator.snapshot().laneCount, 0)
        }

        func testAcquisitionVersusExpiryRaceDoesNotLeakPermitOrLane() async throws {
            let manualClock = ManualAdmissionClock()
            let coordinator = makeCoordinator(
                configuration: .init(
                    perStoreCapacity: 1,
                    globalCapacity: 1,
                    maxQueuedPerStore: 1,
                    maxQueuedGlobally: 1,
                    maxQueueWait: .seconds(8)
                ),
                clock: manualClock.makeClock()
            )
            let store = WorkspaceFileContextStore()
            let gate = PermitGate()
            await installGate(gate, on: coordinator)

            let held = permitTask(coordinator: coordinator, store: store, value: 1)
            await assertTrue(gate.waitUntilStartedCount(1))
            let raced = permitTask(coordinator: coordinator, store: store, value: 2)
            await assertTrue(waitForSnapshot(store: store, coordinator: coordinator) { $0.waiterCount == 1 })

            async let release: Void = gate.releaseFirst()
            manualClock.advance(by: .seconds(8))
            _ = await release
            await gate.releaseAll()
            try await assertEqual(held.value, 1)
            do {
                try await assertEqual(raced.value, 2)
            } catch let error as StoreBackedWorkspaceSearchAdmissionError {
                XCTAssertEqual(error, .waitExpired(retryAfterMilliseconds: 1000))
            }
            await assertEqual(coordinator.snapshot(), .init(activePermitCount: 0, waiterCount: 0, laneCount: 0))
        }

        func testBroadAdmissionTelemetryRecordsLeaseHoldOverloadWaitExpiryAndBoundedDimensions() async throws {
            _ = startedCapture(label: "broad-admission-telemetry", maxSamples: 200)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive())
            let manualClock = ManualAdmissionClock()
            let coordinator = makeCoordinator(
                configuration: .init(
                    perStoreCapacity: 1,
                    globalCapacity: 1,
                    maxQueuedPerStore: 1,
                    maxQueuedGlobally: 1,
                    maxQueueWait: .seconds(8)
                ),
                clock: manualClock.makeClock()
            )
            let store = WorkspaceFileContextStore()
            let gate = PermitGate()
            await installGate(gate, on: coordinator)

            let held = correlatedPermitTask(coordinator: coordinator, store: store, correlation: correlation, value: 1)
            await assertTrue(gate.waitUntilStartedCount(1))
            let expired = correlatedPermitTask(coordinator: coordinator, store: store, correlation: correlation, value: 2)
            await assertTrue(waitForSnapshot(store: store, coordinator: coordinator) { $0.waiterCount == 1 })
            let overloaded = correlatedPermitTask(coordinator: coordinator, store: store, correlation: correlation, value: 3)
            await assertQueueFull(overloaded, scope: .perStore)
            manualClock.advance(by: .seconds(8))
            await assertWaitExpired(expired)
            await gate.releaseAll()
            try await assertEqual(held.value, 1)

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertTrue(snapshot.stages.contains {
                $0.stageName == "EditFlow.Search.BroadAdmissionLeaseHold" &&
                    $0.sanitizedDimensions.contains("outcome=completed") &&
                    $0.sanitizedDimensions.contains("storeCapacity=1") &&
                    $0.sanitizedDimensions.contains("globalCapacity=1")
            })
            let eventNames = Set(snapshot.lifecycleEvents.map(\.eventName))
            XCTAssertTrue(eventNames.contains("Search.BroadAdmissionPermitAcquired"))
            XCTAssertTrue(eventNames.contains("Search.BroadAdmissionWaitBegan"))
            XCTAssertTrue(eventNames.contains("Search.BroadAdmissionOverloaded"))
            XCTAssertTrue(eventNames.contains("Search.BroadAdmissionWaitExpired"))
            XCTAssertTrue(eventNames.contains("Search.BroadAdmissionPermitReleased"))
            XCTAssertTrue(snapshot.lifecycleEvents.allSatisfy {
                !$0.sanitizedDimensions.contains("/") &&
                    !$0.sanitizedDimensions.contains("workspace") &&
                    !$0.sanitizedDimensions.contains("ObjectIdentifier")
            })
        }

        func testDebugReconfigurationSupportsStressRangesOnlyWhileIdle() async {
            let coordinator = makeCoordinator()
            let stressConfiguration = StoreBackedWorkspaceSearchAdmissionCoordinator.Configuration(
                perStoreCapacity: 4,
                globalCapacity: 128,
                maxQueuedPerStore: 256,
                maxQueuedGlobally: 1024,
                maxQueueWait: .milliseconds(60000)
            )

            switch await coordinator.configureForDebug(stressConfiguration) {
            case let .applied(snapshot):
                XCTAssertEqual(snapshot.configuration, stressConfiguration)
                XCTAssertTrue(snapshot.isIdle)
            case .busy:
                XCTFail("Idle coordinator should accept DEBUG stress configuration")
            }
            let snapshot = await coordinator.snapshotForDebug()
            XCTAssertEqual(snapshot.configuration, stressConfiguration)
            XCTAssertEqual(snapshot.configuration.maxQueueWaitMilliseconds, 60000)

            switch await coordinator.resetDebugConfiguration() {
            case let .applied(restored):
                XCTAssertEqual(restored.configuration, .production)
            case .busy:
                XCTFail("Idle coordinator should restore production DEBUG configuration")
            }
        }

        func testDebugReconfigurationRejectsActiveAndQueuedCoordinatorWithoutMutation() async throws {
            let original = StoreBackedWorkspaceSearchAdmissionCoordinator.Configuration(
                perStoreCapacity: 1,
                globalCapacity: 1,
                maxQueuedPerStore: 1,
                maxQueuedGlobally: 1,
                maxQueueWait: .seconds(8)
            )
            let coordinator = makeCoordinator(configuration: original)
            let store = WorkspaceFileContextStore()
            let gate = PermitGate()
            await installGate(gate, on: coordinator)
            let held = permitTask(coordinator: coordinator, store: store, value: 1)
            await assertTrue(gate.waitUntilStartedCount(1))
            let queued = permitTask(coordinator: coordinator, store: store, value: 2)
            await assertTrue(waitForSnapshot(store: store, coordinator: coordinator) { $0.waiterCount == 1 })

            let replacement = StoreBackedWorkspaceSearchAdmissionCoordinator.Configuration(
                perStoreCapacity: 4,
                globalCapacity: 64,
                maxQueuedPerStore: 32,
                maxQueuedGlobally: 256,
                maxQueueWait: .seconds(30)
            )
            switch await coordinator.configureForDebug(replacement) {
            case .applied:
                XCTFail("Busy coordinator must reject DEBUG reconfiguration")
            case let .busy(snapshot):
                XCTAssertEqual(snapshot.configuration, original)
                XCTAssertFalse(snapshot.isIdle)
                XCTAssertEqual(snapshot.globalActiveCount, 1)
                XCTAssertEqual(snapshot.globalQueuedCount, 1)
                XCTAssertEqual(snapshot.laneLoads, [.init(activeCount: 1, queuedCount: 1)])
            }

            await gate.releaseAll()
            try await assertEqual(held.value, 1)
            try await assertEqual(queued.value, 2)
            switch await coordinator.configureForDebug(replacement) {
            case let .applied(snapshot):
                XCTAssertEqual(snapshot.configuration, replacement)
                XCTAssertTrue(snapshot.isIdle)
            case .busy:
                XCTFail("Coordinator should accept DEBUG reconfiguration after cleanup")
            }
        }

        func testHundredsOfCallersRemainBoundedRejectPromptlyRetryablyAndCleanUp() async throws {
            let coordinator = makeCoordinator(
                configuration: .init(
                    perStoreCapacity: 2,
                    globalCapacity: 2,
                    maxQueuedPerStore: 4,
                    maxQueuedGlobally: 4,
                    maxQueueWait: .seconds(8)
                )
            )
            let store = WorkspaceFileContextStore()
            let gate = PermitGate()
            await installGate(gate, on: coordinator)
            let callerCount = 300
            let tasks = (0 ..< callerCount).map { value in
                permitTask(coordinator: coordinator, store: store, value: value)
            }

            await assertTrue(gate.waitUntilStartedCount(2))
            await assertTrue(waitForGlobalSnapshot(coordinator: coordinator) { snapshot in
                snapshot.activePermitCount == 2 && snapshot.waiterCount == 4
            })
            await assertTrue(waitForDebugSnapshot(coordinator: coordinator) { snapshot in
                snapshot.overloadCount == callerCount - 6
            })
            let pressured = await coordinator.snapshotForDebug()
            XCTAssertEqual(pressured.globalActiveCount, 2)
            XCTAssertEqual(pressured.globalQueuedCount, 4)
            XCTAssertEqual(pressured.laneCount, 1)
            XCTAssertEqual(pressured.laneLoads, [.init(activeCount: 2, queuedCount: 4)])
            XCTAssertEqual(pressured.overloadCount, callerCount - 6)

            await gate.releaseAll()
            var admittedCount = 0
            var overloadedCount = 0
            for task in tasks {
                do {
                    _ = try await task.value
                    admittedCount += 1
                } catch let error as StoreBackedWorkspaceSearchAdmissionError {
                    guard case let .queueFull(scope, retryAfterMilliseconds) = error else {
                        XCTFail("Expected prompt retryable queue overload, got \(error)")
                        continue
                    }
                    XCTAssertTrue(scope == .perStore || scope == .global)
                    XCTAssertEqual(retryAfterMilliseconds, 1000)
                    overloadedCount += 1
                }
            }
            XCTAssertEqual(admittedCount, 6)
            XCTAssertEqual(overloadedCount, callerCount - 6)
            let cleaned = await coordinator.snapshotForDebug()
            XCTAssertTrue(cleaned.isIdle)
            XCTAssertEqual(cleaned.globalActiveCount, 0)
            XCTAssertEqual(cleaned.globalQueuedCount, 0)
            XCTAssertEqual(cleaned.laneCount, 0)
            XCTAssertEqual(cleaned.laneLoads, [])
            XCTAssertEqual(cleaned.overloadCount, callerCount - 6)
        }

        private func assertTrue(
            _ value: Bool,
            _ message: @autoclosure () -> String = "",
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertTrue(value, message(), file: file, line: line)
        }

        private func assertEqual<T: Equatable>(
            _ actual: T,
            _ expected: T,
            _ message: @autoclosure () -> String = "",
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertEqual(actual, expected, message(), file: file, line: line)
        }

        private func makeCoordinator(
            configuration: StoreBackedWorkspaceSearchAdmissionCoordinator.Configuration = .production,
            clock: StoreBackedWorkspaceSearchAdmissionCoordinator.AdmissionClock = .continuous()
        ) -> StoreBackedWorkspaceSearchAdmissionCoordinator {
            StoreBackedWorkspaceSearchAdmissionCoordinator(configuration: configuration, clock: clock)
        }

        private func installGate(
            _ gate: PermitGate,
            on coordinator: StoreBackedWorkspaceSearchAdmissionCoordinator
        ) async {
            await coordinator.setPermitAcquiredHandlerForTesting { store in
                await gate.hold(store: store)
            }
        }

        private func permitTask(
            coordinator: StoreBackedWorkspaceSearchAdmissionCoordinator,
            store: WorkspaceFileContextStore,
            value: Int
        ) -> Task<Int, Error> {
            Task {
                try await coordinator.withBroadSearchPermit(
                    for: store,
                    searchMode: .content,
                    admissionClass: .unscopedContent
                ) {
                    value
                }
            }
        }

        private func correlatedPermitTask(
            coordinator: StoreBackedWorkspaceSearchAdmissionCoordinator,
            store: WorkspaceFileContextStore,
            correlation: EditFlowPerf.LifecycleCorrelation,
            value: Int
        ) -> Task<Int, Error> {
            Task {
                try await EditFlowPerf.$currentLifecycleCorrelation.withValue(correlation) {
                    try await WorkspaceRuntimePerf.withLifecycleCorrelation(id: correlation.id) {
                        try await coordinator.withBroadSearchPermit(
                            for: store,
                            searchMode: .content,
                            admissionClass: .unscopedContent
                        ) {
                            value
                        }
                    }
                }
            }
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

        private func assertQueueFull(
            _ task: Task<Int, Error>,
            scope: StoreBackedWorkspaceSearchAdmissionError.QueueScope,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                _ = try await task.value
                XCTFail("Expected bounded queue rejection", file: file, line: line)
            } catch let error as StoreBackedWorkspaceSearchAdmissionError {
                XCTAssertEqual(error, .queueFull(scope: scope, retryAfterMilliseconds: 1000), file: file, line: line)
            } catch {
                XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        }

        private func assertWaitExpired(
            _ task: Task<Int, Error>,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                _ = try await task.value
                XCTFail("Expected bounded wait expiry", file: file, line: line)
            } catch let error as StoreBackedWorkspaceSearchAdmissionError {
                XCTAssertEqual(error, .waitExpired(retryAfterMilliseconds: 1000), file: file, line: line)
            } catch {
                XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        }

        private func waitForSnapshot(
            store: WorkspaceFileContextStore,
            coordinator: StoreBackedWorkspaceSearchAdmissionCoordinator,
            predicate: (StoreBackedWorkspaceSearchAdmissionCoordinator.Snapshot) -> Bool
        ) async -> Bool {
            for _ in 0 ..< 10000 {
                if await predicate(coordinator.snapshot(for: store)) { return true }
                await Task.yield()
            }
            return await predicate(coordinator.snapshot(for: store))
        }

        private func waitForGlobalSnapshot(
            coordinator: StoreBackedWorkspaceSearchAdmissionCoordinator,
            predicate: (StoreBackedWorkspaceSearchAdmissionCoordinator.GlobalSnapshot) -> Bool
        ) async -> Bool {
            for _ in 0 ..< 10000 {
                if await predicate(coordinator.snapshot()) { return true }
                await Task.yield()
            }
            return await predicate(coordinator.snapshot())
        }

        private func waitForDebugSnapshot(
            coordinator: StoreBackedWorkspaceSearchAdmissionCoordinator,
            predicate: (StoreBackedWorkspaceSearchAdmissionCoordinator.DebugSnapshot) -> Bool
        ) async -> Bool {
            for _ in 0 ..< 10000 {
                if await predicate(coordinator.snapshotForDebug()) { return true }
                await Task.yield()
            }
            return await predicate(coordinator.snapshotForDebug())
        }

        private actor PermitGate {
            private var startedStoreKeys: [ObjectIdentifier] = []
            private var waiters: [CheckedContinuation<Void, Never>] = []
            private var isOpen = false

            func hold(store: WorkspaceFileContextStore) async {
                startedStoreKeys.append(ObjectIdentifier(store))
                guard !isOpen else { return }
                await withCheckedContinuation { continuation in
                    waiters.append(continuation)
                }
            }

            func waitUntilStartedCount(_ expectedCount: Int) async -> Bool {
                for _ in 0 ..< 10000 {
                    if startedStoreKeys.count >= expectedCount { return true }
                    await Task.yield()
                }
                return startedStoreKeys.count >= expectedCount
            }

            func startedStores() -> [ObjectIdentifier] {
                startedStoreKeys
            }

            func releaseFirst() {
                guard !waiters.isEmpty else { return }
                waiters.removeFirst().resume()
            }

            func releaseAll() {
                isOpen = true
                let activeWaiters = waiters
                waiters.removeAll()
                activeWaiters.forEach { $0.resume() }
            }
        }

        private final class ManualAdmissionClock: @unchecked Sendable {
            private enum SleepRegistration {
                case suspend
                case resume
                case cancel
            }

            private struct Sleeper {
                let deadline: Duration
                let continuation: CheckedContinuation<Void, Error>
            }

            private let lock = NSLock()
            private var current: Duration = .zero
            private var sleepers: [UUID: Sleeper] = [:]

            func makeClock() -> StoreBackedWorkspaceSearchAdmissionCoordinator.AdmissionClock {
                StoreBackedWorkspaceSearchAdmissionCoordinator.AdmissionClock(
                    now: { self.now() },
                    sleepUntil: { deadline in try await self.sleep(until: deadline) }
                )
            }

            func now() -> Duration {
                lock.withLock { current }
            }

            func advance(by duration: Duration) {
                let ready: [Sleeper] = lock.withLock {
                    current += duration
                    let readyIDs = sleepers.compactMap { id, sleeper in
                        sleeper.deadline <= current ? id : nil
                    }
                    return readyIDs.compactMap { sleepers.removeValue(forKey: $0) }
                }
                ready.forEach { $0.continuation.resume() }
            }

            func sleep(until deadline: Duration) async throws {
                try Task.checkCancellation()
                let id = UUID()
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        let registration: SleepRegistration = lock.withLock {
                            if Task.isCancelled { return .cancel }
                            if deadline <= current { return .resume }
                            sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                            return .suspend
                        }
                        switch registration {
                        case .suspend:
                            break
                        case .resume:
                            continuation.resume()
                        case .cancel:
                            continuation.resume(throwing: CancellationError())
                        }
                    }
                } onCancel: {
                    self.cancelSleep(id: id)
                }
            }

            private func cancelSleep(id: UUID) {
                let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
                sleeper?.continuation.resume(throwing: CancellationError())
            }
        }
    }
#endif
