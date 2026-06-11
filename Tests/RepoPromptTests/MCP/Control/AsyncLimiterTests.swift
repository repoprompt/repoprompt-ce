import Foundation
import MCP
@testable import RepoPrompt
import RepoPromptShared
import XCTest

#if DEBUG
    final class AsyncLimiterTests: XCTestCase {
        func testCancelledMiddleWaiterDetachesPromptlyAndLiveWaitersRemainFIFO() async throws {
            let limiter = AsyncLimiter(limit: 1)
            let holderGate = LimiterTestGate()
            let recorder = LimiterOrderRecorder()
            let snapshots = LimiterSnapshotSignal()
            await limiter.setDebugStateObserver { snapshot in
                Task { await snapshots.record(snapshot) }
            }

            let holder = Task {
                try await limiter.withPermit {
                    await holderGate.markStartedAndWaitForRelease()
                }
            }
            await holderGate.waitUntilStarted()

            let first = Task {
                try await limiter.withPermit {
                    await recorder.append(1)
                }
            }
            _ = await snapshots.waitUntil { $0.waiterCount == 1 }

            let cancelled = Task {
                try await limiter.withPermit {
                    await recorder.append(2)
                }
            }
            _ = await snapshots.waitUntil { $0.waiterCount == 2 }

            let third = Task {
                try await limiter.withPermit {
                    await recorder.append(3)
                }
            }
            _ = await snapshots.waitUntil { $0.waiterCount == 3 }

            cancelled.cancel()
            let afterCancellation = await snapshots.waitUntil {
                $0.waiterCount == 2 && $0.inFlight == 3 && $0.cancelledWaiterCount == 1
            }
            XCTAssertEqual(afterCancellation.activePermitCount, 1)
            await assertCancellation(cancelled)

            await holderGate.release()
            try await holder.value
            try await first.value
            try await third.value

            let values = await recorder.values()
            XCTAssertEqual(values, [1, 3])
            let settled = await snapshots.waitUntil { $0.isIdle }
            assertIdle(settled, cancelledWaiterCount: 1, isClosed: false)
        }

        func testCloseDuringQueuedPermitHandoffRejectsResumedBodyAndRestoresPermit() async throws {
            let limiter = AsyncLimiter(limit: 1)
            let holderGate = LimiterTestGate()
            let handoffGate = LimiterTestGate()
            let waiterBodyRan = LimiterTestFlag()
            await limiter.setDebugQueuedPermitHandoffHandler {
                await handoffGate.markStartedAndWaitForRelease()
            }

            let holder = Task {
                try await limiter.withPermit {
                    await holderGate.markStartedAndWaitForRelease()
                }
            }
            await holderGate.waitUntilStarted()

            let waiter = Task {
                try await limiter.withPermit {
                    await waiterBodyRan.mark()
                }
            }
            let snapshots = LimiterSnapshotSignal()
            await limiter.setDebugStateObserver { snapshot in
                Task { await snapshots.record(snapshot) }
            }
            _ = await snapshots.waitUntil { $0.waiterCount == 1 }

            await holderGate.release()
            try await holder.value
            await handoffGate.waitUntilStarted()

            let close = Task {
                await limiter.cancelAll()
                return await limiter.waitUntilIdle()
            }
            _ = await snapshots.waitUntil { $0.isClosed && $0.activePermitCount == 1 }
            await handoffGate.release()

            await assertCancellation(waiter)
            let closeDrained = await close.value
            XCTAssertTrue(closeDrained)
            let didRunWaiterBody = await waiterBodyRan.isMarked()
            XCTAssertFalse(didRunWaiterBody)
            let settled = await limiter.debugSnapshot()
            assertIdle(settled, cancelledWaiterCount: 0, isClosed: true)
            await limiter.setDebugQueuedPermitHandoffHandler(nil)
        }

        func testConnectionRemovalBoundsCancellationInsensitiveOwnerAndDropsLimiter() async throws {
            let manager = ServerNetworkManager.shared
            let connectionID = UUID()
            let cleanupDeadlineGate = LimiterTestGate()
            let limiter = await manager.debugInstallConnectionLimiterForTesting(
                connectionID: connectionID,
                idleWaitSleep: { _ in
                    await cleanupDeadlineGate.markStartedAndWaitForRelease()
                }
            )
            let holderGate = LimiterTestGate()
            let queuedBodyRan = LimiterTestFlag()
            let removalCompleted = LimiterTestFlag()
            let snapshots = LimiterSnapshotSignal()
            await limiter.setDebugStateObserver { snapshot in
                Task { await snapshots.record(snapshot) }
            }

            let holder = Task {
                try await limiter.withPermit {
                    await holderGate.markStartedAndWaitForRelease()
                }
            }
            await holderGate.waitUntilStarted()

            let queued = Task {
                try await limiter.withPermit {
                    await queuedBodyRan.mark()
                }
            }
            _ = await snapshots.waitUntil { $0.waiterCount == 1 }

            let removal = Task {
                await manager.debugRemoveConnection(connectionID)
                await removalCompleted.mark()
            }

            let closed = await snapshots.waitUntil {
                $0.isClosed && $0.waiterCount == 0 && $0.cancelledWaiterCount == 1
            }
            XCTAssertEqual(closed.activePermitCount, 1)
            await assertCancellation(queued)
            let didRunQueuedBody = await queuedBodyRan.isMarked()
            XCTAssertFalse(didRunQueuedBody)
            await cleanupDeadlineGate.waitUntilStarted()
            let didFinishRemovalBeforeDeadline = await removalCompleted.isMarked()
            XCTAssertFalse(didFinishRemovalBeforeDeadline)
            let registeredSnapshot = await manager.connectionLimiterSnapshotForTesting(connectionID: connectionID)
            XCTAssertNil(registeredSnapshot)

            await cleanupDeadlineGate.release()
            await removal.value
            let didFinishRemoval = await removalCompleted.isMarked()
            XCTAssertTrue(didFinishRemoval)
            let detached = await limiter.debugSnapshot()
            XCTAssertTrue(detached.isClosed)
            XCTAssertEqual(detached.activePermitCount, 1)
            XCTAssertEqual(detached.inFlight, 1)
            XCTAssertFalse(detached.isIdle)

            await holderGate.release()
            try await holder.value
            let eventuallyDrained = await limiter.waitUntilIdle()
            XCTAssertTrue(eventuallyDrained)
            let settled = await limiter.debugSnapshot()
            assertIdle(settled, cancelledWaiterCount: 1, isClosed: true)
        }

        func testConnectionRemovalClosesBothCallLanesAndSearchPreventsEviction() async throws {
            let manager = ServerNetworkManager.shared
            let connectionID = UUID()
            let ordinary = await manager.debugInstallConnectionLimiterForTesting(connectionID: connectionID)
            let installedFileSearch = await manager.limiter(for: connectionID, lane: .fileSearch)
            let fileSearch = try XCTUnwrap(installedFileSearch)
            let ordinaryGate = LimiterTestGate()
            let fileSearchGate = LimiterTestGate()

            let fileSearchHolder = Task {
                try await manager.withConnectionCallPermitForTesting(
                    connectionID: connectionID,
                    lane: .fileSearch
                ) {
                    await fileSearchGate.markStartedAndWaitForRelease()
                }
            }
            await assertStarted(fileSearchGate, description: "file-search holder")
            let searchIsInFlight = await manager.hasInFlightCalls(for: connectionID)
            let searchConnectionIsEvictable = await manager.connectionIsEvictableForTesting(connectionID)
            XCTAssertTrue(searchIsInFlight)
            XCTAssertFalse(searchConnectionIsEvictable)

            let ordinaryHolder = Task {
                try await manager.withConnectionCallPermitForTesting(
                    connectionID: connectionID,
                    lane: .ordinary
                ) {
                    await ordinaryGate.markStartedAndWaitForRelease()
                }
            }
            await assertStarted(ordinaryGate, description: "ordinary holder")

            let removal = Task {
                await manager.debugRemoveConnection(connectionID)
            }
            async let ordinaryClosedObservation = waitForSnapshot(of: ordinary) { $0.isClosed }
            async let fileSearchClosedObservation = waitForSnapshot(of: fileSearch) { $0.isClosed }
            let (ordinaryClosed, fileSearchClosed) = await (
                ordinaryClosedObservation,
                fileSearchClosedObservation
            )

            XCTAssertNotNil(ordinaryClosed, "Timed out waiting for the ordinary lane to close")
            XCTAssertNotNil(fileSearchClosed, "Timed out waiting for the file-search lane to close")
            XCTAssertEqual(ordinaryClosed?.activePermitCount, 1)
            XCTAssertEqual(fileSearchClosed?.activePermitCount, 1)
            let registeredOrdinary = await manager.connectionLimiterSnapshotForTesting(
                connectionID: connectionID,
                lane: .ordinary
            )
            let registeredFileSearch = await manager.connectionLimiterSnapshotForTesting(
                connectionID: connectionID,
                lane: .fileSearch
            )
            XCTAssertNil(registeredOrdinary)
            XCTAssertNil(registeredFileSearch)

            await ordinaryGate.release()
            await fileSearchGate.release()
            await assertSuccess(ordinaryHolder)
            await assertSuccess(fileSearchHolder)
            await assertCompletion(removal, description: "connection removal")

            let ordinarySettled = await ordinary.debugSnapshot()
            let fileSearchSettled = await fileSearch.debugSnapshot()
            assertIdle(ordinarySettled, cancelledWaiterCount: 0, isClosed: true)
            assertIdle(fileSearchSettled, cancelledWaiterCount: 0, isClosed: true)
        }

        @MainActor
        func testServerShutdownCancelsConnectionOwnedToolsBeforeConcurrentLaneDrain() async {
            let manager = ServerNetworkManager()
            let connectionID = UUID()
            let runID = UUID()
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

            let drainStarts = LimiterTestCounter()
            let ordinary = await manager.debugInstallConnectionLimiterForTesting(
                connectionID: connectionID,
                idleWaitSleep: { duration in
                    await drainStarts.increment()
                    try await Task.sleep(for: duration)
                }
            )
            guard let fileSearch = await manager.limiter(for: connectionID, lane: .fileSearch) else {
                XCTFail("Expected file-search limiter")
                window.beginClose()
                await window.tearDown()
                WindowStatesManager.shared.unregisterWindowState(window)
                return
            }

            let ordinaryGate = LimiterTestGate()
            let fileSearchGate = LimiterTestGate()
            let queuedSearchBodyRan = LimiterTestFlag()
            let ordinaryCancelled = LimiterLockedFlag()
            let fileSearchCancelled = LimiterLockedFlag()

            let ordinaryHolder = Task {
                try await manager.withConnectionCallPermitForTesting(
                    connectionID: connectionID,
                    lane: .ordinary
                ) {
                    await ordinaryGate.markStartedAndWaitForRelease()
                }
            }
            // Saturate the burst-capacity file-search lane so the next call queues.
            let fileSearchHolders = (0 ..< ServerNetworkManager.fileSearchCallLaneLimit).map { _ in
                Task {
                    try await manager.withConnectionCallPermitForTesting(
                        connectionID: connectionID,
                        lane: .fileSearch
                    ) {
                        await fileSearchGate.markStartedAndWaitForRelease()
                    }
                }
            }
            await assertStarted(ordinaryGate, description: "ordinary holder")
            await assertStarted(fileSearchGate, description: "file-search holder")
            let saturatedSearchSnapshot = await waitForSnapshot(of: fileSearch) {
                $0.activePermitCount == ServerNetworkManager.fileSearchCallLaneLimit
            }

            let queuedSearch = Task {
                try await manager.withConnectionCallPermitForTesting(
                    connectionID: connectionID,
                    lane: .fileSearch
                ) {
                    await queuedSearchBodyRan.mark()
                }
            }
            let queuedSearchSnapshot = await waitForSnapshot(of: fileSearch) {
                $0.waiterCount == 1
            }
            guard saturatedSearchSnapshot != nil, queuedSearchSnapshot != nil else {
                XCTFail("Timed out waiting for the saturated lane and queued file-search call")
                queuedSearch.cancel()
                await ordinaryGate.release()
                await fileSearchGate.release()
                await assertSuccess(ordinaryHolder)
                for holder in fileSearchHolders {
                    await assertSuccess(holder)
                }
                await assertCancellation(queuedSearch)
                window.beginClose()
                await window.tearDown()
                WindowStatesManager.shared.unregisterWindowState(window)
                return
            }

            XCTAssertTrue(
                window.mcpServer.registerRunIDMapping(
                    connectionID: connectionID,
                    runID: runID,
                    windowID: window.windowID
                )
            )
            let metadata = MCPServerViewModel.RequestMetadata(
                connectionID: connectionID,
                clientName: "server-shutdown-cancellation-test",
                windowID: window.windowID
            )
            let ordinaryExecution = await window.mcpServer.test_beginResolvedToolExecution(
                metadata: metadata,
                resolvedContext: nil,
                toolName: MCPWindowToolName.readFile
            ) {
                ordinaryCancelled.mark()
            }
            let fileSearchExecution = await window.mcpServer.test_beginResolvedToolExecution(
                metadata: metadata,
                resolvedContext: nil,
                toolName: MCPWindowToolName.search
            ) {
                fileSearchCancelled.mark()
            }
            XCTAssertNotNil(ordinaryExecution)
            XCTAssertNotNil(fileSearchExecution)
            XCTAssertTrue(window.mcpServer.hasActiveToolExecutions(runID: runID))

            let stopTask = Task {
                await manager.stop()
            }
            guard let drainStartCount = await drainStarts.waitUntil(2, timeout: .seconds(2)) else {
                XCTFail("Timed out waiting for both limiter lanes to begin shutdown drain")
                await ordinaryGate.release()
                await fileSearchGate.release()
                await assertSuccess(ordinaryHolder)
                for holder in fileSearchHolders {
                    await assertSuccess(holder)
                }
                await assertCompletion(stopTask, description: "server stop")
                await assertCancellation(queuedSearch)
                window.beginClose()
                await window.tearDown()
                WindowStatesManager.shared.unregisterWindowState(window)
                return
            }
            XCTAssertGreaterThanOrEqual(drainStartCount, 2)

            XCTAssertTrue(ordinaryCancelled.isMarked())
            XCTAssertTrue(fileSearchCancelled.isMarked())
            let ordinaryClosed = await ordinary.debugSnapshot()
            let fileSearchClosed = await fileSearch.debugSnapshot()
            XCTAssertTrue(ordinaryClosed.isClosed)
            XCTAssertTrue(fileSearchClosed.isClosed)
            XCTAssertEqual(ordinaryClosed.activePermitCount, 1)
            XCTAssertEqual(fileSearchClosed.activePermitCount, ServerNetworkManager.fileSearchCallLaneLimit)
            XCTAssertEqual(fileSearchClosed.waiterCount, 0)
            XCTAssertEqual(fileSearchClosed.cancelledWaiterCount, 1)
            await assertCancellation(queuedSearch)
            let didRunQueuedSearchBody = await queuedSearchBodyRan.isMarked()
            XCTAssertFalse(didRunQueuedSearchBody)

            await ordinaryGate.release()
            await fileSearchGate.release()
            await assertSuccess(ordinaryHolder)
            for holder in fileSearchHolders {
                await assertSuccess(holder)
            }
            await assertCompletion(stopTask, description: "server stop")

            let registeredOrdinary = await manager.connectionLimiterSnapshotForTesting(
                connectionID: connectionID,
                lane: .ordinary
            )
            let registeredFileSearch = await manager.connectionLimiterSnapshotForTesting(
                connectionID: connectionID,
                lane: .fileSearch
            )
            XCTAssertNil(registeredOrdinary)
            XCTAssertNil(registeredFileSearch)
            await assertIdle(ordinary.debugSnapshot(), cancelledWaiterCount: 0, isClosed: true)
            await assertIdle(fileSearch.debugSnapshot(), cancelledWaiterCount: 1, isClosed: true)
            XCTAssertFalse(window.mcpServer.hasActiveToolExecutions(runID: runID))

            _ = window.mcpServer.cancelActiveToolsForConnection(
                connectionID: connectionID,
                reason: "testCleanup"
            )
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
        }

        func testAdmittedPermitRejectsRemovalCommittedBeforeBodyStarts() async {
            let manager = ServerNetworkManager()
            let connectionID = UUID()
            let permitGate = LimiterTestGate()
            let stopGate = LimiterTestGate()
            let bodyRan = LimiterTestFlag()

            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: connectionID,
                connection: AdmissionEvictionTestConnection(
                    idleSeconds: 0,
                    stopGate: stopGate
                ),
                clientID: "post-permit-removal-\(UUID().uuidString)",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugSetAfterConnectionCallPermitAcquiredForTesting { acquiredConnectionID in
                guard acquiredConnectionID == connectionID else { return }
                await permitGate.markStartedAndWaitForRelease()
            }

            let admittedCall = Task {
                try await manager.withConnectionCallPermitForTesting(
                    connectionID: connectionID,
                    lane: .ordinary
                ) {
                    await bodyRan.mark()
                }
            }
            await assertStarted(permitGate, description: "post-permit dispatch gate")

            let removal = Task {
                await manager.debugRemoveConnection(connectionID)
            }
            await assertStarted(stopGate, description: "post-permit connection removal")
            await manager.debugSetAfterConnectionCallPermitAcquiredForTesting(nil)
            await permitGate.release()

            let callSucceeded: Bool
            do {
                try await admittedCall.value
                callSucceeded = true
            } catch {
                callSucceeded = false
            }
            let didRunBody = await bodyRan.isMarked()
            XCTAssertFalse(callSucceeded)
            XCTAssertFalse(didRunBody)

            await stopGate.release()
            await assertCompletion(removal, description: "post-permit connection removal")
        }

        func testAdmittedPermitRejectsShutdownCommittedBeforeBodyStarts() async {
            let manager = ServerNetworkManager()
            let connectionID = UUID()
            let permitGate = LimiterTestGate()
            let bodyRan = LimiterTestFlag()

            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: connectionID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 0),
                clientID: "post-permit-shutdown-\(UUID().uuidString)",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            guard let limiter = await manager.limiter(for: connectionID, lane: .ordinary) else {
                XCTFail("Expected ordinary limiter")
                return
            }
            await manager.debugSetAfterConnectionCallPermitAcquiredForTesting { acquiredConnectionID in
                guard acquiredConnectionID == connectionID else { return }
                await permitGate.markStartedAndWaitForRelease()
            }

            let admittedCall = Task {
                try await manager.withConnectionCallPermitForTesting(
                    connectionID: connectionID,
                    lane: .ordinary
                ) {
                    await bodyRan.mark()
                }
            }
            await assertStarted(permitGate, description: "post-permit shutdown dispatch gate")

            let shutdown = Task {
                await manager.stop()
            }
            let closed = await waitForSnapshot(of: limiter) { $0.isClosed }
            XCTAssertNotNil(closed, "Timed out waiting for shutdown to close the admitted call limiter")
            await manager.debugSetAfterConnectionCallPermitAcquiredForTesting(nil)
            await permitGate.release()

            let callSucceeded: Bool
            do {
                try await admittedCall.value
                callSucceeded = true
            } catch {
                callSucceeded = false
            }
            let didRunBody = await bodyRan.isMarked()
            XCTAssertFalse(callSucceeded)
            XCTAssertFalse(didRunBody)
            await assertCompletion(shutdown, description: "post-permit server shutdown")
        }

        @MainActor
        func testClosingWindowRejectsCapturedDispatchIdentityBeforeOwnershipOperation() async {
            let manager = ServerNetworkManager()
            let connectionID = UUID()
            let bodyRan = LimiterTestFlag()
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: connectionID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 0),
                clientID: "closing-window-dispatch-\(UUID().uuidString)",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            let identity = ServerNetworkManager.WindowToolDispatchIdentity(
                windowID: window.windowID,
                windowStateIdentity: ObjectIdentifier(window),
                serverViewModelIdentity: ObjectIdentifier(window.mcpServer),
                catalogServiceIdentity: ObjectIdentifier(window.mcpServer.windowMCPToolCatalogService)
            )
            window.beginClose()

            do {
                try await manager.withWindowToolOwnership(
                    windowID: window.windowID,
                    connectionID: connectionID,
                    toolName: MCPWindowToolName.search,
                    windowIdentity: identity
                ) {
                    await bodyRan.mark()
                }
                XCTFail("A captured dispatch target must become terminal when its window begins closing")
            } catch {
                // Expected.
            }
            let didRunBody = await bodyRan.isMarked()
            XCTAssertFalse(didRunBody)

            await manager.debugRemoveConnection(connectionID)
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
        }

        @MainActor
        func testUnboundExecutionsRemainTokenAndConnectionOwnedWhenTheyOverlap() async {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            let firstConnectionID = UUID()
            let secondConnectionID = UUID()
            let firstCancelled = LimiterLockedFlag()
            let secondCancelled = LimiterLockedFlag()

            let first = await window.mcpServer.test_beginResolvedToolExecution(
                metadata: MCPServerViewModel.RequestMetadata(
                    connectionID: firstConnectionID,
                    clientName: "unbound-first",
                    windowID: window.windowID
                ),
                resolvedContext: nil,
                toolName: MCPWindowToolName.readFile
            ) {
                firstCancelled.mark()
            }
            let second = await window.mcpServer.test_beginResolvedToolExecution(
                metadata: MCPServerViewModel.RequestMetadata(
                    connectionID: secondConnectionID,
                    clientName: "unbound-second",
                    windowID: window.windowID
                ),
                resolvedContext: nil,
                toolName: MCPWindowToolName.readFile
            ) {
                secondCancelled.mark()
            }

            XCTAssertNotNil(first)
            XCTAssertNotNil(second)
            XCTAssertEqual(window.mcpServer.test_activeToolExecutionCount(), 2)
            XCTAssertEqual(window.mcpServer.test_activeToolExecutionCount(connectionID: firstConnectionID), 1)
            XCTAssertEqual(window.mcpServer.test_activeToolExecutionCount(connectionID: secondConnectionID), 1)
            XCTAssertEqual(
                window.mcpServer.cancelActiveToolsForConnection(
                    connectionID: firstConnectionID,
                    reason: "unbound-overlap-first"
                ),
                1
            )
            XCTAssertTrue(firstCancelled.isMarked())
            XCTAssertFalse(secondCancelled.isMarked())
            XCTAssertEqual(window.mcpServer.test_activeToolExecutionCount(), 1)
            XCTAssertEqual(window.mcpServer.test_activeToolExecutionCount(connectionID: firstConnectionID), 0)
            XCTAssertEqual(
                window.mcpServer.cancelActiveToolsForConnection(
                    connectionID: secondConnectionID,
                    reason: "unbound-overlap-second"
                ),
                1
            )
            XCTAssertTrue(secondCancelled.isMarked())
            XCTAssertEqual(window.mcpServer.test_activeToolExecutionCount(), 0)

            if let first {
                window.mcpServer.test_endToolExecution(executionID: first.executionID)
            }
            if let second {
                window.mcpServer.test_endToolExecution(executionID: second.executionID)
            }
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
        }

        func testDiagnosticsExposeSelectedActiveScopeWindowInsteadOfAssignedWindow() async throws {
            let manager = ServerNetworkManager()
            let connectionID = UUID()
            let assignedWindowID = 73013
            let activeWindowID = 73014
            let secondaryActiveWindowID = 73015
            let scopeID = UUID()

            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: connectionID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 0),
                clientID: "active-tool-diagnostics-\(UUID().uuidString)",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugSetConnectionWindowForTesting(
                connectionID: connectionID,
                windowID: assignedWindowID
            )
            _ = await manager.debugBeginActiveToolScopeForTesting(
                windowID: secondaryActiveWindowID,
                connectionID: connectionID,
                toolName: "secondary-cross-window-active",
                scopeID: UUID()
            )
            _ = await manager.debugBeginActiveToolScopeForTesting(
                windowID: activeWindowID,
                connectionID: connectionID,
                toolName: "cross-window-active",
                scopeID: scopeID
            )

            let result = await manager.debugConnectionsPayload(op: "connections", arguments: [:])
            let payload = try diagnosticsPayload(result)
            let connections = try XCTUnwrap(payload["connections"] as? [[String: Any]])
            let connection = try XCTUnwrap(connections.first(where: { $0["id"] as? String == connectionID.uuidString }))
            XCTAssertEqual(connection["window_id"] as? Int, assignedWindowID)
            XCTAssertEqual(connection["active_tool_name"] as? String, "cross-window-active")
            XCTAssertEqual(connection["active_tool_window_id"] as? Int, activeWindowID)
            XCTAssertEqual(connection["active_tool_scope_count"] as? Int, 2)
            let scopes = try XCTUnwrap(connection["active_tool_scopes"] as? [[String: Any]])
            XCTAssertEqual(Set(scopes.compactMap { $0["window_id"] as? Int }), [activeWindowID, secondaryActiveWindowID])

            await manager.debugRemoveConnection(connectionID)
        }

        func testOverlappingSameConnectionWindowOwnershipPersistsUntilFinalCallCompletes() async {
            let manager = ServerNetworkManager.shared
            let connectionID = UUID()
            let windowID = 73001
            let firstGate = LimiterTestGate()
            let secondGate = LimiterTestGate()

            let first = Task {
                try! await manager.withWindowToolOwnership(
                    windowID: windowID,
                    connectionID: connectionID,
                    toolName: MCPWindowToolName.search
                ) {
                    await firstGate.markStartedAndWaitForRelease()
                }
            }
            await assertStarted(firstGate, description: "first owner")

            let second = Task {
                try! await manager.withWindowToolOwnership(
                    windowID: windowID,
                    connectionID: connectionID,
                    toolName: MCPWindowToolName.readFile
                ) {
                    await secondGate.markStartedAndWaitForRelease()
                }
            }
            await assertStarted(secondGate, description: "second owner")

            let evictableWhileBothActive = await manager.connectionIsEvictableForTesting(connectionID)
            XCTAssertFalse(evictableWhileBothActive)

            await firstGate.release()
            await assertCompletion(first, description: "first ownership task")

            let evictableWhileSecondRemainsActive = await manager.connectionIsEvictableForTesting(connectionID)
            XCTAssertFalse(
                evictableWhileSecondRemainsActive,
                "Completing one overlapping call must not clear ownership while another remains active"
            )

            await secondGate.release()
            await assertCompletion(second, description: "second ownership task")
            let evictableAfterBothComplete = await manager.connectionIsEvictableForTesting(connectionID)
            XCTAssertTrue(evictableAfterBothComplete)
        }

        func testOverlappingDifferentConnectionWindowOwnershipProtectsBothUntilEachCompletes() async {
            let manager = ServerNetworkManager()
            let firstConnectionID = UUID()
            let secondConnectionID = UUID()
            let windowID = 73002
            let firstGate = LimiterTestGate()
            let secondGate = LimiterTestGate()

            let first = Task {
                try! await manager.withWindowToolOwnership(
                    windowID: windowID,
                    connectionID: firstConnectionID,
                    toolName: MCPWindowToolName.search
                ) {
                    await firstGate.markStartedAndWaitForRelease()
                }
            }
            await assertStarted(firstGate, description: "first cross-connection owner")

            let second = Task {
                try! await manager.withWindowToolOwnership(
                    windowID: windowID,
                    connectionID: secondConnectionID,
                    toolName: MCPWindowToolName.readFile
                ) {
                    await secondGate.markStartedAndWaitForRelease()
                }
            }
            await assertStarted(secondGate, description: "second cross-connection owner")

            let firstEvictableWhileBothActive = await manager.connectionIsEvictableForTesting(firstConnectionID)
            let secondEvictableWhileBothActive = await manager.connectionIsEvictableForTesting(secondConnectionID)
            XCTAssertFalse(firstEvictableWhileBothActive)
            XCTAssertFalse(secondEvictableWhileBothActive)

            await secondGate.release()
            await assertCompletion(second, description: "second cross-connection ownership task")

            let firstEvictableAfterSecondCompletion = await manager.connectionIsEvictableForTesting(firstConnectionID)
            let secondEvictableAfterCompletion = await manager.connectionIsEvictableForTesting(secondConnectionID)
            XCTAssertFalse(
                firstEvictableAfterSecondCompletion,
                "Completing the newer connection must preserve the older exact ownership scope"
            )
            XCTAssertTrue(secondEvictableAfterCompletion)

            await firstGate.release()
            await assertCompletion(first, description: "first cross-connection ownership task")
            let firstEvictableAfterCompletion = await manager.connectionIsEvictableForTesting(firstConnectionID)
            XCTAssertTrue(firstEvictableAfterCompletion)
        }

        func testConnectionCancellationRemovesOnlyScopesCapturedBeforeMainActorScan() async {
            let manager = ServerNetworkManager()
            let targetConnectionID = UUID()
            let otherConnectionID = UUID()
            let windowID = 73003
            let capturedScopeID = UUID()
            let newerTargetScopeID = UUID()
            let otherScopeID = UUID()
            let cancellationGate = LimiterTestGate()

            let beganCapturedScope = await manager.debugBeginActiveToolScopeForTesting(
                windowID: windowID,
                connectionID: targetConnectionID,
                toolName: MCPWindowToolName.search,
                scopeID: capturedScopeID
            )
            XCTAssertEqual(beganCapturedScope, capturedScopeID)
            await manager.debugSetBeforeActiveToolCancellationScanForTesting { connectionID, scopeIDs in
                guard connectionID == targetConnectionID,
                      scopeIDs == [capturedScopeID]
                else { return }
                await cancellationGate.markStartedAndWaitForRelease()
            }

            let cancellation = Task {
                await manager.debugCancelActiveToolsOwnedByConnection(
                    targetConnectionID,
                    reason: "exactScopeCancellationRace"
                )
            }
            await assertStarted(cancellationGate, description: "active-tool cancellation snapshot")

            let beganNewerTargetScope = await manager.debugBeginActiveToolScopeForTesting(
                windowID: windowID,
                connectionID: targetConnectionID,
                toolName: MCPWindowToolName.readFile,
                scopeID: newerTargetScopeID
            )
            let beganOtherScope = await manager.debugBeginActiveToolScopeForTesting(
                windowID: windowID,
                connectionID: otherConnectionID,
                toolName: MCPWindowToolName.applyEdits,
                scopeID: otherScopeID
            )
            XCTAssertEqual(beganNewerTargetScope, newerTargetScopeID)
            XCTAssertEqual(beganOtherScope, otherScopeID)

            await cancellationGate.release()
            await assertCompletion(cancellation, description: "exact-scope connection cancellation")
            await manager.debugSetBeforeActiveToolCancellationScanForTesting(nil)

            let remainingScopes = await manager.debugActiveToolScopesForTesting()
            XCTAssertEqual(Set(remainingScopes.map(\.scopeID)), Set([newerTargetScopeID, otherScopeID]))
            let removedCapturedScopeAgain = await manager.debugEndActiveToolScopeForTesting(
                windowID: windowID,
                scopeID: capturedScopeID
            )
            XCTAssertFalse(
                removedCapturedScopeAgain,
                "A deferred completion for an already-cleaned exact scope must be harmless"
            )
            let scopesAfterDeferredCompletion = await manager.debugActiveToolScopesForTesting()
            XCTAssertEqual(Set(scopesAfterDeferredCompletion.map(\.scopeID)), Set([newerTargetScopeID, otherScopeID]))
        }

        func testConnectionRemovalRejectsScopeThatStartsAfterCancellationSnapshot() async {
            let manager = ServerNetworkManager()
            let connectionID = UUID()
            let capturedScopeID = UUID()
            let rejectedScopeID = UUID()
            let windowID = 73011
            let cancellationGate = LimiterTestGate()

            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: connectionID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 0),
                clientID: "active-tool-removal-race-\(UUID().uuidString)",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            _ = await manager.debugBeginActiveToolScopeForTesting(
                windowID: windowID,
                connectionID: connectionID,
                toolName: MCPWindowToolName.search,
                scopeID: capturedScopeID
            )
            await manager.debugSetBeforeActiveToolCancellationScanForTesting { cancelledConnectionID, _ in
                guard cancelledConnectionID == connectionID else { return }
                await cancellationGate.markStartedAndWaitForRelease()
            }

            let removal = Task {
                await manager.debugRemoveConnection(connectionID)
            }
            await assertStarted(cancellationGate, description: "connection-removal cancellation snapshot")
            let rejectedScope = await manager.debugBeginActiveToolScopeForTesting(
                windowID: windowID,
                connectionID: connectionID,
                toolName: MCPWindowToolName.readFile,
                scopeID: rejectedScopeID
            )
            XCTAssertNil(rejectedScope)

            await cancellationGate.release()
            await assertCompletion(removal, description: "connection removal after ownership race")
            await manager.debugSetBeforeActiveToolCancellationScanForTesting(nil)
            let remainingScopes = await manager.debugActiveToolScopesForTesting()
            XCTAssertFalse(remainingScopes.contains { $0.connectionID == connectionID })
        }

        func testDebugScopeIDCannotBeReusedAfterExactCompletion() async {
            let manager = ServerNetworkManager()
            let connectionID = UUID()
            let windowID = 73012
            let scopeID = UUID()

            let firstBegin = await manager.debugBeginActiveToolScopeForTesting(
                windowID: windowID,
                connectionID: connectionID,
                toolName: MCPWindowToolName.search,
                scopeID: scopeID
            )
            XCTAssertEqual(firstBegin, scopeID)
            let firstEnd = await manager.debugEndActiveToolScopeForTesting(
                windowID: windowID,
                scopeID: scopeID
            )
            XCTAssertTrue(firstEnd)

            let reusedBegin = await manager.debugBeginActiveToolScopeForTesting(
                windowID: windowID,
                connectionID: connectionID,
                toolName: MCPWindowToolName.readFile,
                scopeID: scopeID
            )
            XCTAssertNil(reusedBegin)
            let remainingScopes = await manager.debugActiveToolScopesForTesting()
            XCTAssertTrue(remainingScopes.isEmpty)
        }

        func testDashboardSelectsNewestAssignedWindowScopeThenFallsBackBySequence() async {
            let manager = ServerNetworkManager()
            let connectionID = UUID()
            let assignedWindowID = 73004
            let otherWindowID = 73005
            let assignedOlderScopeID = UUID()
            let otherNewerScopeID = UUID()
            let assignedNewestScopeID = UUID()

            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: connectionID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 0),
                clientID: "active-tool-dashboard-\(UUID().uuidString)",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugSetConnectionWindowForTesting(
                connectionID: connectionID,
                windowID: assignedWindowID
            )
            _ = await manager.debugBeginActiveToolScopeForTesting(
                windowID: assignedWindowID,
                connectionID: connectionID,
                toolName: "assigned-older",
                scopeID: assignedOlderScopeID
            )
            _ = await manager.debugBeginActiveToolScopeForTesting(
                windowID: otherWindowID,
                connectionID: connectionID,
                toolName: "other-newer",
                scopeID: otherNewerScopeID
            )

            let preferredAssignedSnapshot = await manager.dashboardSnapshot()
            XCTAssertEqual(
                preferredAssignedSnapshot.connections.first(where: { $0.id == connectionID })?.activeToolName,
                "assigned-older"
            )

            _ = await manager.debugBeginActiveToolScopeForTesting(
                windowID: assignedWindowID,
                connectionID: connectionID,
                toolName: "assigned-newest",
                scopeID: assignedNewestScopeID
            )
            let newestAssignedSnapshot = await manager.dashboardSnapshot()
            XCTAssertEqual(
                newestAssignedSnapshot.connections.first(where: { $0.id == connectionID })?.activeToolName,
                "assigned-newest"
            )

            _ = await manager.debugEndActiveToolScopeForTesting(
                windowID: assignedWindowID,
                scopeID: assignedNewestScopeID
            )
            let olderAssignedFallbackSnapshot = await manager.dashboardSnapshot()
            XCTAssertEqual(
                olderAssignedFallbackSnapshot.connections.first(where: { $0.id == connectionID })?.activeToolName,
                "assigned-older"
            )

            _ = await manager.debugEndActiveToolScopeForTesting(
                windowID: assignedWindowID,
                scopeID: assignedOlderScopeID
            )
            let crossWindowFallbackSnapshot = await manager.dashboardSnapshot()
            XCTAssertEqual(
                crossWindowFallbackSnapshot.connections.first(where: { $0.id == connectionID })?.activeToolName,
                "other-newer"
            )

            _ = await manager.debugEndActiveToolScopeForTesting(
                windowID: otherWindowID,
                scopeID: otherNewerScopeID
            )
            let idleSnapshot = await manager.dashboardSnapshot()
            XCTAssertNil(idleSnapshot.connections.first(where: { $0.id == connectionID })?.activeToolName)
            await manager.debugRemoveConnection(connectionID)
        }

        func testWindowCloseRemovesOnlyItsScopeBucketAndStaleCompletionIsHarmless() async {
            let manager = ServerNetworkManager()
            let connectionID = UUID()
            let closedWindowID = 73006
            let retainedWindowID = 73007
            let closedScopeID = UUID()
            let retainedScopeID = UUID()

            _ = await manager.debugBeginActiveToolScopeForTesting(
                windowID: closedWindowID,
                connectionID: connectionID,
                toolName: MCPWindowToolName.search,
                scopeID: closedScopeID
            )
            _ = await manager.debugBeginActiveToolScopeForTesting(
                windowID: retainedWindowID,
                connectionID: connectionID,
                toolName: MCPWindowToolName.readFile,
                scopeID: retainedScopeID
            )

            await manager.clearWindowSelectionIfClosed(closedWindowID)
            let remainingAfterClose = await manager.debugActiveToolScopesForTesting()
            XCTAssertEqual(remainingAfterClose.map(\.scopeID), [retainedScopeID])
            let removedStaleScope = await manager.debugEndActiveToolScopeForTesting(
                windowID: closedWindowID,
                scopeID: closedScopeID
            )
            XCTAssertFalse(removedStaleScope)
            let remainingAfterStaleCompletion = await manager.debugActiveToolScopesForTesting()
            XCTAssertEqual(remainingAfterStaleCompletion.map(\.scopeID), [retainedScopeID])
        }

        func testLifecycleResetClearsAllScopesWithoutReusingSequenceOrOldIDs() async {
            let manager = ServerNetworkManager()
            let connectionID = UUID()
            let windowID = 73008
            let oldScopeID = UUID()
            let newScopeID = UUID()

            _ = await manager.debugBeginActiveToolScopeForTesting(
                windowID: windowID,
                connectionID: connectionID,
                toolName: "old-lifecycle",
                scopeID: oldScopeID
            )
            let oldScope = await manager.debugActiveToolScopesForTesting().first
            await manager.stop()
            let scopesAfterReset = await manager.debugActiveToolScopesForTesting()
            XCTAssertTrue(scopesAfterReset.isEmpty)

            _ = await manager.debugBeginActiveToolScopeForTesting(
                windowID: windowID,
                connectionID: connectionID,
                toolName: "new-lifecycle",
                scopeID: newScopeID
            )
            let newScope = await manager.debugActiveToolScopesForTesting().first
            XCTAssertNotNil(oldScope)
            XCTAssertNotNil(newScope)
            if let oldScope, let newScope {
                XCTAssertGreaterThan(newScope.sequence, oldScope.sequence)
            }
            let removedOldScope = await manager.debugEndActiveToolScopeForTesting(
                windowID: windowID,
                scopeID: oldScopeID
            )
            XCTAssertFalse(removedOldScope)
            let remainingScopes = await manager.debugActiveToolScopesForTesting()
            XCTAssertEqual(remainingScopes.map(\.scopeID), [newScopeID])
        }

        func testConnectionRemovalClearsOwnedScopesAcrossWindowsWithoutTouchingPeerScopes() async {
            let manager = ServerNetworkManager()
            let targetConnectionID = UUID()
            let peerConnectionID = UUID()
            let firstWindowID = 73009
            let secondWindowID = 73010
            let targetFirstScopeID = UUID()
            let targetSecondScopeID = UUID()
            let peerScopeID = UUID()

            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: targetConnectionID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 0),
                clientID: "active-tool-removal-target-\(UUID().uuidString)",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: peerConnectionID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 0),
                clientID: "active-tool-removal-peer-\(UUID().uuidString)",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            _ = await manager.debugBeginActiveToolScopeForTesting(
                windowID: firstWindowID,
                connectionID: targetConnectionID,
                toolName: MCPWindowToolName.search,
                scopeID: targetFirstScopeID
            )
            _ = await manager.debugBeginActiveToolScopeForTesting(
                windowID: secondWindowID,
                connectionID: targetConnectionID,
                toolName: MCPWindowToolName.readFile,
                scopeID: targetSecondScopeID
            )
            _ = await manager.debugBeginActiveToolScopeForTesting(
                windowID: firstWindowID,
                connectionID: peerConnectionID,
                toolName: MCPWindowToolName.applyEdits,
                scopeID: peerScopeID
            )

            await manager.debugRemoveConnection(targetConnectionID)
            let remainingScopes = await manager.debugActiveToolScopesForTesting()
            XCTAssertEqual(remainingScopes.map(\.scopeID), [peerScopeID])
            let peerEvictable = await manager.connectionIsEvictableForTesting(peerConnectionID)
            XCTAssertFalse(peerEvictable)
            await manager.debugRemoveConnection(peerConnectionID)
        }

        func testConnectionCancellationClearsAllOverlappingOwnershipReferences() async {
            let manager = ServerNetworkManager()
            let connectionID = UUID()
            let windowID = 73002
            let firstGate = LimiterTestGate()
            let secondGate = LimiterTestGate()
            let first = Task {
                try! await manager.withWindowToolOwnership(
                    windowID: windowID,
                    connectionID: connectionID,
                    toolName: MCPWindowToolName.search
                ) {
                    await firstGate.markStartedAndWaitForRelease()
                }
            }
            let second = Task {
                try! await manager.withWindowToolOwnership(
                    windowID: windowID,
                    connectionID: connectionID,
                    toolName: MCPWindowToolName.readFile
                ) {
                    await secondGate.markStartedAndWaitForRelease()
                }
            }
            await assertStarted(firstGate, description: "first owner")
            await assertStarted(secondGate, description: "second owner")

            let evictableBeforeCancellation = await manager.connectionIsEvictableForTesting(connectionID)
            XCTAssertFalse(evictableBeforeCancellation)

            _ = await manager.debugCancelActiveToolsOwnedByConnection(
                connectionID,
                reason: "ownershipRefcountTest"
            )

            let evictableAfterCancellation = await manager.connectionIsEvictableForTesting(connectionID)
            XCTAssertTrue(evictableAfterCancellation)

            await firstGate.release()
            await secondGate.release()
            await assertCompletion(first, description: "first ownership task")
            await assertCompletion(second, description: "second ownership task")
            let evictableAfterDeferredClears = await manager.connectionIsEvictableForTesting(connectionID)
            XCTAssertTrue(evictableAfterDeferredClears)
        }

        func testPerClientAdmissionEvictionSkipsCandidateThatBecomesBusyBeforeAtomicClose() async {
            await assertAdmissionEvictionFallsBackToNextCandidate(scope: .perClient)
        }

        func testGlobalAdmissionEvictionSkipsCandidateThatBecomesBusyBeforeAtomicClose() async {
            await assertAdmissionEvictionFallsBackToNextCandidate(scope: .global)
        }

        func testGlobalAdmissionEvictionIgnoresRemovingSiblingBeforeClosingProtectedVictim() async {
            let manager = ServerNetworkManager()
            let firstClientID = "admission-eviction-first-\(UUID().uuidString)"
            let protectedClientID = "admission-eviction-protected-\(UUID().uuidString)"
            let firstCandidateID = UUID()
            let firstSiblingID = UUID()
            let protectedCandidateID = UUID()
            let protectedSiblingID = UUID()

            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: firstCandidateID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 120),
                clientID: firstClientID,
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: firstSiblingID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 10),
                clientID: firstClientID,
                totalToolCalls: 2,
                createdAt: Date()
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: protectedCandidateID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 60),
                clientID: protectedClientID,
                totalToolCalls: 1,
                createdAt: Date()
            )
            let protectedSiblingStopGate = LimiterTestGate()
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: protectedSiblingID,
                connection: AdmissionEvictionTestConnection(
                    idleSeconds: 10,
                    stopGate: protectedSiblingStopGate
                ),
                clientID: protectedClientID,
                totalToolCalls: 2,
                createdAt: Date()
            )

            let firstSiblingGate = LimiterTestGate()
            let protectedSiblingGate = LimiterTestGate()
            let firstSiblingHolder = Task {
                try await manager.withConnectionCallPermitForTesting(
                    connectionID: firstSiblingID,
                    lane: .ordinary
                ) {
                    await firstSiblingGate.markStartedAndWaitForRelease()
                }
            }
            let protectedSiblingHolder = Task {
                try await manager.withConnectionCallPermitForTesting(
                    connectionID: protectedSiblingID,
                    lane: .ordinary
                ) {
                    await protectedSiblingGate.markStartedAndWaitForRelease()
                }
            }
            await assertStarted(firstSiblingGate, description: "first sibling holder")
            await assertStarted(protectedSiblingGate, description: "protected sibling holder")

            let firstCandidateBusyGate = LimiterTestGate()
            let firstCandidateBusyTask = LimiterTestTaskStore()
            let protectedSiblingRemovalTask = LimiterTestTaskStore()
            await manager.debugSetBeforeAdmissionEvictionCloseForTesting { candidateID in
                guard candidateID == firstCandidateID else { return }
                await firstCandidateBusyTask.start {
                    try? await manager.withConnectionCallPermitForTesting(
                        connectionID: firstCandidateID,
                        lane: .ordinary
                    ) {
                        await firstCandidateBusyGate.markStartedAndWaitForRelease()
                    }
                }
                guard await firstCandidateBusyGate.waitUntilStarted(timeout: .seconds(2)) else { return }
                await protectedSiblingRemovalTask.start {
                    await manager.debugRemoveConnection(protectedSiblingID)
                }
                guard await protectedSiblingStopGate.waitUntilStarted(timeout: .seconds(2)) else { return }
            }

            let didEvict = await manager.debugEvictLeastValuableGlobalForAdmissionForTesting(
                preserveOnePerClient: true
            )
            let retainedFirstCandidate = await manager.debugContainsConnection(firstCandidateID)
            let retainedProtectedCandidate = await manager.debugContainsConnection(protectedCandidateID)
            let retainedRemovingSibling = await manager.debugContainsConnection(protectedSiblingID)
            let protectedSiblingRemovalStarted = await protectedSiblingStopGate.hasStarted()
            XCTAssertFalse(didEvict)
            XCTAssertTrue(
                protectedSiblingRemovalStarted,
                "Timed out waiting for protected sibling removal to reach stop()"
            )
            XCTAssertTrue(retainedFirstCandidate)
            XCTAssertTrue(
                retainedRemovingSibling,
                "The fixture must observe removal after it starts but before indexed membership cleanup"
            )
            XCTAssertTrue(
                retainedProtectedCandidate,
                "A candidate that became its client's sole member must not be evicted"
            )

            await manager.debugSetBeforeAdmissionEvictionCloseForTesting(nil)
            await firstCandidateBusyGate.release()
            await assertCompletion(firstCandidateBusyTask, description: "first candidate task")
            await firstSiblingGate.release()
            await protectedSiblingGate.release()
            await assertSuccess(firstSiblingHolder)
            await assertSuccess(protectedSiblingHolder)
            await protectedSiblingStopGate.release()
            await assertCompletion(protectedSiblingRemovalTask, description: "protected sibling removal")
            await manager.debugRemoveConnection(firstCandidateID)
            await manager.debugRemoveConnection(firstSiblingID)
            await manager.debugRemoveConnection(protectedCandidateID)
        }

        func testGlobalAdmissionEvictionRestoresIdleLanesWhenSiblingRemovalStartsDuringClose() async throws {
            let manager = ServerNetworkManager()
            let clientID = "admission-eviction-during-close-\(UUID().uuidString)"
            let victimID = UUID()
            let siblingID = UUID()

            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: victimID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 120),
                clientID: clientID,
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            let siblingStopGate = LimiterTestGate()
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: siblingID,
                connection: AdmissionEvictionTestConnection(
                    idleSeconds: 10,
                    stopGate: siblingStopGate
                ),
                clientID: clientID,
                totalToolCalls: 1,
                createdAt: Date()
            )
            let installedOrdinary = await manager.limiter(for: victimID, lane: .ordinary)
            let installedFileSearch = await manager.limiter(for: victimID, lane: .fileSearch)
            let originalOrdinary = try XCTUnwrap(installedOrdinary)
            let originalFileSearch = try XCTUnwrap(installedFileSearch)

            let siblingRemovalTask = LimiterTestTaskStore()
            await manager.debugSetDuringAdmissionEvictionCloseForTesting { candidateID in
                guard candidateID == victimID else { return }
                await siblingRemovalTask.start {
                    await manager.debugRemoveConnection(siblingID)
                }
                guard await siblingStopGate.waitUntilStarted(timeout: .seconds(2)) else { return }
            }

            let didEvict = await manager.debugEvictLeastValuableGlobalForAdmissionForTesting(
                preserveOnePerClient: true
            )
            await manager.debugSetDuringAdmissionEvictionCloseForTesting(nil)

            let retainedVictim = await manager.debugContainsConnection(victimID)
            let retainedSibling = await manager.debugContainsConnection(siblingID)
            let siblingRemovalStarted = await siblingStopGate.hasStarted()
            let originalOrdinarySnapshot = await originalOrdinary.debugSnapshot()
            let originalFileSearchSnapshot = await originalFileSearch.debugSnapshot()
            XCTAssertFalse(didEvict)
            XCTAssertTrue(
                siblingRemovalStarted,
                "Timed out waiting for sibling removal to reach stop() during lane closure"
            )
            XCTAssertTrue(retainedVictim, "The sole remaining usable connection must stay registered")
            XCTAssertTrue(
                retainedSibling,
                "The fixture must observe removal after it starts but before indexed membership cleanup"
            )
            XCTAssertTrue(originalOrdinarySnapshot.isClosed)
            XCTAssertTrue(originalFileSearchSnapshot.isClosed)

            let registeredOrdinary = await manager.connectionLimiterSnapshotForTesting(
                connectionID: victimID,
                lane: .ordinary
            )
            let registeredFileSearch = await manager.connectionLimiterSnapshotForTesting(
                connectionID: victimID,
                lane: .fileSearch
            )
            XCTAssertNotNil(registeredOrdinary)
            XCTAssertNotNil(registeredFileSearch)
            XCTAssertFalse(registeredOrdinary?.isClosed ?? true)
            XCTAssertFalse(registeredFileSearch?.isClosed ?? true)

            if registeredOrdinary != nil, registeredFileSearch != nil {
                let ordinaryRan = LimiterTestFlag()
                let fileSearchRan = LimiterTestFlag()
                try await manager.withConnectionCallPermitForTesting(
                    connectionID: victimID,
                    lane: .ordinary
                ) {
                    await ordinaryRan.mark()
                }
                try await manager.withConnectionCallPermitForTesting(
                    connectionID: victimID,
                    lane: .fileSearch
                ) {
                    await fileSearchRan.mark()
                }
                let didRunOrdinary = await ordinaryRan.isMarked()
                let didRunFileSearch = await fileSearchRan.isMarked()
                XCTAssertTrue(didRunOrdinary)
                XCTAssertTrue(didRunFileSearch)
            }

            await siblingStopGate.release()
            await assertCompletion(siblingRemovalTask, description: "sibling removal")
            await manager.debugRemoveConnection(victimID)
        }

        func testDirectAdmissionRejectsActorIdentityReplacementAfterSuspension() async {
            await assertDirectAdmissionRejectsStaleResume(
                advanceLifecycleGeneration: false,
                replaceConnectionActor: true
            )
        }

        func testDirectAdmissionRejectsLifecycleGenerationReplacementAfterSuspension() async {
            await assertDirectAdmissionRejectsStaleResume(
                advanceLifecycleGeneration: true,
                replaceConnectionActor: false
            )
        }

        func testDirectAdmissionRejectsRemovalCommittedWhileSuspended() async {
            let manager = ServerNetworkManager()
            let connectionID = UUID()
            let stopGate = LimiterTestGate()
            let removalTask = LimiterTestTaskStore()

            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: connectionID,
                connection: AdmissionEvictionTestConnection(
                    idleSeconds: 0,
                    stopGate: stopGate
                )
            )
            await manager.debugSetAfterDirectAdmissionPendingPublishedForTesting { suspendedConnectionID in
                guard suspendedConnectionID == connectionID else { return }
                await removalTask.start {
                    await manager.debugRemoveConnection(connectionID)
                }
                _ = await stopGate.waitUntilStarted(timeout: .seconds(2))
            }

            let admitted = await manager.tryReserveConnectionSlot(
                connectionID: connectionID,
                clientID: "direct-removal-fence-\(UUID().uuidString)"
            )
            await manager.debugSetAfterDirectAdmissionPendingPublishedForTesting(nil)
            XCTAssertFalse(
                admitted,
                "A direct admission must not resume after exact removal ownership is committed"
            )

            await stopGate.release()
            await assertCompletion(removalTask, description: "direct admission removal")
        }

        func testDirectAdmissionLifecycleChangeDuringAtomicCloseStillRemovesClosedVictim() async {
            let manager = ServerNetworkManager()
            let incomingConnectionID = UUID()
            let victimID = UUID()
            let originalClientID = "close-lifecycle-original-\(UUID().uuidString)"
            let replacementClientID = "close-lifecycle-replacement-\(UUID().uuidString)"
            let incomingConnection = AdmissionEvictionTestConnection(idleSeconds: 0)

            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: 2,
                preserveOnePerClient: false
            )
            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: incomingConnectionID,
                connection: incomingConnection
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: victimID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 180),
                clientID: "close-lifecycle-victim-\(UUID().uuidString)",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugSetDuringAdmissionEvictionCloseForTesting { candidateID in
                guard candidateID == victimID else { return }
                await manager.debugInstallDirectAdmissionConnectionForTesting(
                    connectionID: incomingConnectionID,
                    connection: incomingConnection,
                    pendingClientID: replacementClientID,
                    advanceLifecycleGeneration: true
                )
            }

            let admitted = await manager.tryReserveConnectionSlot(
                connectionID: incomingConnectionID,
                clientID: originalClientID
            )
            await manager.debugSetDuringAdmissionEvictionCloseForTesting(nil)

            XCTAssertFalse(admitted)
            let victimRetained = await manager.debugContainsConnection(victimID)
            XCTAssertFalse(
                victimRetained,
                "A successfully closed victim must be removed before stale admission is reported"
            )
            let incomingState = await manager.debugDirectAdmissionStateForTesting(
                connectionID: incomingConnectionID
            )
            XCTAssertEqual(incomingState.pendingClientID, replacementClientID)
            XCTAssertNil(incomingState.indexedClientID)
            XCTAssertFalse(incomingState.hasStats)

            await manager.debugRemoveConnection(incomingConnectionID)
            await manager.debugRemoveConnection(victimID)
            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: nil,
                preserveOnePerClient: nil
            )
        }

        func testBootstrapAdmissionUsesReboundSessionReplacementAfterPolicyReadiness() async {
            let manager = ServerNetworkManager()
            let clientID = "bootstrap-rebind-\(UUID().uuidString)"
            let sessionToken = "bootstrap-rebind-token-\(UUID().uuidString)"
            let staleReplacementID = UUID()
            let currentReplacementID = UUID()
            let retainedID = UUID()

            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: 2,
                preserveOnePerClient: true
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: currentReplacementID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 180),
                clientID: clientID,
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: staleReplacementID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 120),
                clientID: clientID,
                totalToolCalls: 1,
                createdAt: Date(timeIntervalSince1970: 1)
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: retainedID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 60),
                clientID: clientID,
                totalToolCalls: 2,
                createdAt: Date()
            )
            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: staleReplacementID)
            await manager.debugSetAfterBootstrapPolicyReadinessForTesting { observedToken in
                guard observedToken == sessionToken else { return }
                await manager.debugBindSessionTokenForAdmissionTesting(
                    sessionToken,
                    to: currentReplacementID
                )
            }

            let admitted = await manager.debugBootstrapAdmissionHasCapacityForTesting(
                sessionToken: sessionToken
            )
            await manager.debugSetAfterBootstrapPolicyReadinessForTesting(nil)

            XCTAssertTrue(admitted)
            let retainedCurrentReplacement = await manager.debugContainsConnection(currentReplacementID)
            let retainedStaleReplacement = await manager.debugContainsConnection(staleReplacementID)
            let retainedOther = await manager.debugContainsConnection(retainedID)
            XCTAssertTrue(
                retainedCurrentReplacement,
                "Capacity eviction must protect the replacement currently bound to the durable session token"
            )
            XCTAssertFalse(
                retainedStaleReplacement,
                "Capacity eviction should remove the least valuable non-current replacement"
            )
            XCTAssertTrue(retainedOther)

            await manager.debugRemoveConnection(staleReplacementID)
            await manager.debugRemoveConnection(currentReplacementID)
            await manager.debugRemoveConnection(retainedID)
            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: nil,
                preserveOnePerClient: nil
            )
        }

        func testBootstrapAdmissionDoesNotResurrectFormerReplacementAfterReboundReplacementDisappears() async {
            let manager = ServerNetworkManager()
            let sessionToken = "bootstrap-rebound-disappeared-token-\(UUID().uuidString)"
            let formerReplacementID = UUID()
            let reboundReplacementID = UUID()
            let retainedID = UUID()

            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: 2,
                preserveOnePerClient: false
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: formerReplacementID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 180),
                clientID: "bootstrap-former-replacement-\(UUID().uuidString)",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: reboundReplacementID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 60),
                clientID: "bootstrap-rebound-replacement-\(UUID().uuidString)",
                totalToolCalls: 1,
                createdAt: Date()
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: retainedID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 30),
                clientID: "bootstrap-rebound-retained-\(UUID().uuidString)",
                totalToolCalls: 2,
                createdAt: Date()
            )
            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: formerReplacementID)
            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: reboundReplacementID)
            await manager.debugSetAfterBootstrapPolicyReadinessForTesting { observedToken in
                guard observedToken == sessionToken else { return }
                await manager.debugRemoveConnection(reboundReplacementID)
            }

            let admitted = await manager.debugBootstrapAdmissionHasCapacityForTesting(
                sessionToken: sessionToken
            )
            await manager.debugSetAfterBootstrapPolicyReadinessForTesting(nil)

            XCTAssertTrue(admitted)
            let retainedFormerReplacement = await manager.debugContainsConnection(formerReplacementID)
            let retainedReboundReplacement = await manager.debugContainsConnection(reboundReplacementID)
            let retainedOther = await manager.debugContainsConnection(retainedID)
            XCTAssertFalse(
                retainedFormerReplacement,
                "A former token owner must not be resurrected after the rebound replacement disappears"
            )
            XCTAssertFalse(retainedReboundReplacement)
            XCTAssertTrue(retainedOther)

            await manager.debugRemoveConnection(formerReplacementID)
            await manager.debugRemoveConnection(reboundReplacementID)
            await manager.debugRemoveConnection(retainedID)
            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: nil,
                preserveOnePerClient: nil
            )
        }

        func testBootstrapAdmissionStopsDiscountingDisappearedSessionReplacementAfterPolicyReadiness() async {
            let manager = ServerNetworkManager()
            let sessionToken = "bootstrap-disappeared-token-\(UUID().uuidString)"
            let disappearedReplacementID = UUID()
            let retainedID = UUID()

            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: 2,
                preserveOnePerClient: false
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: disappearedReplacementID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 180),
                clientID: "bootstrap-disappeared-\(UUID().uuidString)",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: retainedID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 60),
                clientID: "bootstrap-retained-\(UUID().uuidString)",
                totalToolCalls: 1,
                createdAt: Date()
            )
            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: disappearedReplacementID)
            await manager.debugSetAfterBootstrapPolicyReadinessForTesting { observedToken in
                guard observedToken == sessionToken else { return }
                await manager.debugUnbindSessionTokenForAdmissionTesting(
                    sessionToken,
                    from: disappearedReplacementID
                )
            }

            let admitted = await manager.debugBootstrapAdmissionHasCapacityForTesting(
                sessionToken: sessionToken
            )
            await manager.debugSetAfterBootstrapPolicyReadinessForTesting(nil)

            XCTAssertTrue(admitted)
            let retainedDisappearedReplacement = await manager.debugContainsConnection(disappearedReplacementID)
            let retainedOther = await manager.debugContainsConnection(retainedID)
            XCTAssertFalse(
                retainedDisappearedReplacement,
                "A connection no longer bound to the durable token must not receive replacement capacity credit"
            )
            XCTAssertTrue(retainedOther)

            await manager.debugRemoveConnection(disappearedReplacementID)
            await manager.debugRemoveConnection(retainedID)
            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: nil,
                preserveOnePerClient: nil
            )
        }

        func testDirectGlobalAdmissionPreservesCandidateWhenRemovalCreatesHeadroomBeforeClose() async throws {
            try await assertGlobalAdmissionPreservesCandidateWhenRemovalCreatesHeadroomBeforeClose(path: .direct)
        }

        func testBootstrapGlobalAdmissionPreservesCandidateWhenRemovalCreatesHeadroomBeforeClose() async throws {
            try await assertGlobalAdmissionPreservesCandidateWhenRemovalCreatesHeadroomBeforeClose(path: .bootstrap)
        }

        func testDirectGlobalAdmissionRestoresClosedCandidateWhenRemovalCreatesHeadroomDuringClose() async throws {
            try await assertGlobalAdmissionRestoresClosedCandidateWhenRemovalCreatesHeadroomDuringClose(path: .direct)
        }

        func testBootstrapGlobalAdmissionRestoresClosedCandidateWhenRemovalCreatesHeadroomDuringClose() async throws {
            try await assertGlobalAdmissionRestoresClosedCandidateWhenRemovalCreatesHeadroomDuringClose(path: .bootstrap)
        }

        func testPerClientAdmissionAcceptsWhenConcurrentRemovalCreatesCapacityWithoutClosingCandidate() async {
            let manager = ServerNetworkManager()
            let clientID = "per-client-capacity-progress-\(UUID().uuidString)"
            let victimID = UUID()
            let siblingID = UUID()
            let incomingConnectionID = UUID()
            let incomingConnection = AdmissionEvictionTestConnection(idleSeconds: 0)
            let siblingStopGate = LimiterTestGate()
            let victimBusyGate = LimiterTestGate()
            let victimBusyTask = LimiterTestTaskStore()
            let siblingRemovalTask = LimiterTestTaskStore()

            await manager.debugConfigurePerClientAdmissionForTesting(maxConnectionsPerClient: 2)
            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: incomingConnectionID,
                connection: incomingConnection
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: victimID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 180),
                clientID: clientID,
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: siblingID,
                connection: AdmissionEvictionTestConnection(
                    idleSeconds: 60,
                    stopGate: siblingStopGate
                ),
                clientID: clientID,
                totalToolCalls: 1,
                createdAt: Date()
            )
            await manager.debugSetBeforeAdmissionEvictionCloseForTesting { candidateID in
                guard candidateID == victimID else { return }
                await victimBusyTask.start {
                    try? await manager.withConnectionCallPermitForTesting(
                        connectionID: victimID,
                        lane: .ordinary
                    ) {
                        await victimBusyGate.markStartedAndWaitForRelease()
                    }
                }
                guard await victimBusyGate.waitUntilStarted(timeout: .seconds(2)) else { return }
                await siblingRemovalTask.start {
                    await manager.debugRemoveConnection(siblingID)
                }
                _ = await siblingStopGate.waitUntilStarted(timeout: .seconds(2))
            }

            let admitted = await manager.tryReserveConnectionSlot(
                connectionID: incomingConnectionID,
                clientID: clientID
            )
            await manager.debugSetBeforeAdmissionEvictionCloseForTesting(nil)

            XCTAssertTrue(
                admitted,
                "Per-client admission must recheck effective membership when another removal creates capacity"
            )
            let victimRetained = await manager.debugContainsConnection(victimID)
            let removingSiblingRetained = await manager.debugContainsConnection(siblingID)
            XCTAssertTrue(victimRetained)
            XCTAssertTrue(
                removingSiblingRetained,
                "The fixture must observe removal after effective membership changes but before indexed cleanup"
            )

            await victimBusyGate.release()
            await assertCompletion(victimBusyTask, description: "per-client victim busy task")
            await siblingStopGate.release()
            await assertCompletion(siblingRemovalTask, description: "per-client sibling removal")
            await manager.debugRemoveConnection(incomingConnectionID)
            await manager.debugRemoveConnection(victimID)
            await manager.debugConfigurePerClientAdmissionForTesting(maxConnectionsPerClient: nil)
        }

        func testPerClientAdmissionRestoresClosedCandidateWhenRemovalCreatesCapacityDuringClose() async throws {
            let manager = ServerNetworkManager()
            let clientID = "per-client-capacity-during-close-\(UUID().uuidString)"
            let victimID = UUID()
            let siblingID = UUID()
            let incomingConnectionID = UUID()
            let siblingStopGate = LimiterTestGate()
            let siblingRemovalTask = LimiterTestTaskStore()

            await manager.debugConfigurePerClientAdmissionForTesting(maxConnectionsPerClient: 2)
            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: incomingConnectionID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 0)
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: victimID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 180),
                clientID: clientID,
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: siblingID,
                connection: AdmissionEvictionTestConnection(
                    idleSeconds: 60,
                    stopGate: siblingStopGate
                ),
                clientID: clientID,
                totalToolCalls: 1,
                createdAt: Date()
            )
            let installedOrdinary = await manager.limiter(for: victimID, lane: .ordinary)
            let installedFileSearch = await manager.limiter(for: victimID, lane: .fileSearch)
            let originalOrdinary = try XCTUnwrap(installedOrdinary)
            let originalFileSearch = try XCTUnwrap(installedFileSearch)

            await manager.debugSetDuringAdmissionEvictionCloseForTesting { candidateID in
                guard candidateID == victimID else { return }
                await siblingRemovalTask.start {
                    await manager.debugRemoveConnection(siblingID)
                }
                _ = await siblingStopGate.waitUntilStarted(timeout: .seconds(2))
            }

            let admitted = await manager.tryReserveConnectionSlot(
                connectionID: incomingConnectionID,
                clientID: clientID
            )
            await manager.debugSetDuringAdmissionEvictionCloseForTesting(nil)

            let siblingRemovalStarted = await siblingStopGate.hasStarted()
            let victimRetained = await manager.debugContainsConnection(victimID)
            let removingSiblingRetained = await manager.debugContainsConnection(siblingID)
            let originalOrdinarySnapshot = await originalOrdinary.debugSnapshot()
            let originalFileSearchSnapshot = await originalFileSearch.debugSnapshot()
            XCTAssertTrue(admitted)
            XCTAssertTrue(siblingRemovalStarted)
            XCTAssertTrue(victimRetained)
            XCTAssertTrue(
                removingSiblingRetained,
                "The fixture must observe effective removal before indexed cleanup completes"
            )
            XCTAssertTrue(originalOrdinarySnapshot.isClosed)
            XCTAssertTrue(originalFileSearchSnapshot.isClosed)

            let registeredOrdinary = await manager.connectionLimiterSnapshotForTesting(
                connectionID: victimID,
                lane: .ordinary
            )
            let registeredFileSearch = await manager.connectionLimiterSnapshotForTesting(
                connectionID: victimID,
                lane: .fileSearch
            )
            XCTAssertFalse(registeredOrdinary?.isClosed ?? true)
            XCTAssertFalse(registeredFileSearch?.isClosed ?? true)

            let ordinaryRan = LimiterTestFlag()
            let fileSearchRan = LimiterTestFlag()
            try await manager.withConnectionCallPermitForTesting(
                connectionID: victimID,
                lane: .ordinary
            ) {
                await ordinaryRan.mark()
            }
            try await manager.withConnectionCallPermitForTesting(
                connectionID: victimID,
                lane: .fileSearch
            ) {
                await fileSearchRan.mark()
            }
            let didRunOrdinary = await ordinaryRan.isMarked()
            let didRunFileSearch = await fileSearchRan.isMarked()
            XCTAssertTrue(didRunOrdinary)
            XCTAssertTrue(didRunFileSearch)

            await siblingStopGate.release()
            await assertCompletion(siblingRemovalTask, description: "per-client during-close sibling removal")
            await manager.debugRemoveConnection(incomingConnectionID)
            await manager.debugRemoveConnection(victimID)
            await manager.debugConfigurePerClientAdmissionForTesting(maxConnectionsPerClient: nil)
        }

        func testDirectAdmissionCountsLiveBootstrapReservationsInGlobalEffectiveLoad() async {
            let manager = ServerNetworkManager()
            let incomingConnectionID = UUID()
            let existingConnectionID = UUID()
            let firstReservationID = UUID()
            let secondReservationID = UUID()
            let busyGate = LimiterTestGate()

            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: 3,
                preserveOnePerClient: false
            )
            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: incomingConnectionID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 0)
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: existingConnectionID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 120),
                clientID: "reservation-aware-existing-\(UUID().uuidString)",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            let firstReserved = await manager.debugReserveBootstrapSlotForTesting(
                connectionID: firstReservationID,
                sessionToken: "reservation-aware-first-\(UUID().uuidString)"
            )
            let secondReserved = await manager.debugReserveBootstrapSlotForTesting(
                connectionID: secondReservationID,
                sessionToken: "reservation-aware-second-\(UUID().uuidString)"
            )
            XCTAssertTrue(firstReserved)
            XCTAssertTrue(secondReserved)

            let busyTask = Task {
                try? await manager.withConnectionCallPermitForTesting(
                    connectionID: existingConnectionID,
                    lane: .ordinary
                ) {
                    await busyGate.markStartedAndWaitForRelease()
                }
            }
            await assertStarted(busyGate, description: "reservation-aware existing connection")

            let admitted = await manager.tryReserveConnectionSlot(
                connectionID: incomingConnectionID,
                clientID: "reservation-aware-incoming-\(UUID().uuidString)"
            )
            let state = await manager.debugDirectAdmissionStateForTesting(
                connectionID: incomingConnectionID
            )

            XCTAssertFalse(
                admitted,
                "Direct admission must reserve room for all live bootstrap reservations"
            )
            XCTAssertNil(state.indexedClientID)
            XCTAssertFalse(state.hasStats)

            await busyGate.release()
            await assertCompletion(busyTask, description: "reservation-aware busy connection")
            await manager.debugRollbackBootstrapReservationForTesting(connectionID: firstReservationID)
            await manager.debugRollbackBootstrapReservationForTesting(connectionID: secondReservationID)
            await manager.debugRemoveConnection(incomingConnectionID)
            await manager.debugRemoveConnection(existingConnectionID)
            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: nil,
                preserveOnePerClient: nil
            )
        }

        func testDirectAdmissionUsesReplacementCreditForLiveBootstrapReservations() async {
            let manager = ServerNetworkManager()
            let incomingConnectionID = UUID()
            let predecessorID = UUID()
            let replacementReservationID = UUID()
            let ordinaryReservationID = UUID()
            let sessionToken = "direct-replacement-credit-\(UUID().uuidString)"
            let predecessorBusyGate = LimiterTestGate()

            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: 4,
                preserveOnePerClient: false
            )
            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: incomingConnectionID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 0)
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: predecessorID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 120),
                clientID: "direct-replacement-credit-predecessor",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: predecessorID)
            let replacementReserved = await manager.debugReserveBootstrapSlotForTesting(
                connectionID: replacementReservationID,
                sessionToken: sessionToken
            )
            let ordinaryReserved = await manager.debugReserveBootstrapSlotForTesting(
                connectionID: ordinaryReservationID,
                sessionToken: "direct-ordinary-reservation-\(UUID().uuidString)"
            )
            XCTAssertTrue(replacementReserved)
            XCTAssertTrue(ordinaryReserved)

            let predecessorBusyTask = Task {
                try? await manager.withConnectionCallPermitForTesting(
                    connectionID: predecessorID,
                    lane: .ordinary
                ) {
                    await predecessorBusyGate.markStartedAndWaitForRelease()
                }
            }
            await assertStarted(predecessorBusyGate, description: "direct credited predecessor")

            let admitted = await manager.tryReserveConnectionSlot(
                connectionID: incomingConnectionID,
                clientID: "direct-replacement-credit-incoming"
            )
            XCTAssertTrue(
                admitted,
                "Direct admission must use the reservation's valid predecessor credit"
            )

            await predecessorBusyGate.release()
            await assertCompletion(predecessorBusyTask, description: "direct credited predecessor")
            await manager.debugRollbackBootstrapReservationForTesting(
                connectionID: replacementReservationID
            )
            await manager.debugRollbackBootstrapReservationForTesting(
                connectionID: ordinaryReservationID
            )
            await manager.debugRemoveConnection(incomingConnectionID)
            await manager.debugRemoveConnection(predecessorID)
            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: nil,
                preserveOnePerClient: nil
            )
        }

        func testDirectAdmissionRechecksReservationLoadAfterPerClientSuspension() async {
            let manager = ServerNetworkManager()
            let clientID = "direct-reservation-recheck-\(UUID().uuidString)"
            let incomingConnectionID = UUID()
            let victimID = UUID()
            let busySiblingID = UUID()
            let reservationIDs = [UUID(), UUID(), UUID()]
            let busySiblingGate = LimiterTestGate()

            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: 5,
                preserveOnePerClient: false
            )
            await manager.debugConfigurePerClientAdmissionForTesting(maxConnectionsPerClient: 2)
            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: incomingConnectionID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 0)
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: victimID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 180),
                clientID: clientID,
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: busySiblingID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 60),
                clientID: clientID,
                totalToolCalls: 1,
                createdAt: Date()
            )
            let busySiblingTask = Task {
                try? await manager.withConnectionCallPermitForTesting(
                    connectionID: busySiblingID,
                    lane: .ordinary
                ) {
                    await busySiblingGate.markStartedAndWaitForRelease()
                }
            }
            await assertStarted(busySiblingGate, description: "direct reservation recheck sibling")

            await manager.debugSetBeforeAdmissionEvictionCloseForTesting { candidateID in
                guard candidateID == victimID else { return }
                for (index, reservationID) in reservationIDs.enumerated() {
                    _ = await manager.debugReserveBootstrapSlotForTesting(
                        connectionID: reservationID,
                        sessionToken: "direct-recheck-reservation-\(index)-\(UUID().uuidString)"
                    )
                }
            }

            let admitted = await manager.tryReserveConnectionSlot(
                connectionID: incomingConnectionID,
                clientID: clientID
            )
            await manager.debugSetBeforeAdmissionEvictionCloseForTesting(nil)
            XCTAssertFalse(
                admitted,
                "Direct admission must recheck global reservation load after per-client awaits"
            )

            await busySiblingGate.release()
            await assertCompletion(busySiblingTask, description: "direct reservation recheck sibling")
            for reservationID in reservationIDs {
                await manager.debugRollbackBootstrapReservationForTesting(
                    connectionID: reservationID
                )
            }
            await manager.debugRemoveConnection(incomingConnectionID)
            await manager.debugRemoveConnection(victimID)
            await manager.debugRemoveConnection(busySiblingID)
            await manager.debugConfigurePerClientAdmissionForTesting(maxConnectionsPerClient: nil)
            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: nil,
                preserveOnePerClient: nil
            )
        }

        func testProspectiveBootstrapClaimProtectsPredecessorFromPerClientEviction() async {
            let manager = ServerNetworkManager()
            let clientID = "claim-per-client-\(UUID().uuidString)"
            let sessionToken = "claim-per-client-\(UUID().uuidString)"
            let predecessorID = UUID()
            let siblingID = UUID()
            let claimID = UUID()

            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: predecessorID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 180),
                clientID: clientID,
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: siblingID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 60),
                clientID: clientID,
                totalToolCalls: 1,
                createdAt: Date()
            )
            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: predecessorID)
            let claimed = await manager.debugClaimBootstrapAdmissionForTesting(
                connectionID: claimID,
                sessionToken: sessionToken
            )
            XCTAssertTrue(claimed)

            let protectedBeforeEviction = await manager.debugProtectedBootstrapPredecessorConnectionIDsForTesting()
            let didEvict = await manager.debugEvictLeastValuableForTesting(clientID: clientID)
            let predecessorRetained = await manager.debugContainsConnection(predecessorID)
            let siblingRetained = await manager.debugContainsConnection(siblingID)
            XCTAssertTrue(protectedBeforeEviction.contains(predecessorID))
            XCTAssertTrue(didEvict)
            XCTAssertTrue(predecessorRetained)
            XCTAssertFalse(siblingRetained)

            await manager.debugReleaseBootstrapAdmissionClaimForTesting(
                connectionID: claimID,
                sessionToken: sessionToken
            )
            await manager.debugRemoveConnection(predecessorID)
            await manager.debugRemoveConnection(siblingID)
        }

        func testProspectiveBootstrapClaimProtectsPredecessorFromPressureEviction() async {
            let manager = ServerNetworkManager()
            let sessionToken = "claim-pressure-\(UUID().uuidString)"
            let predecessorID = UUID()
            let siblingID = UUID()
            let claimID = UUID()

            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: 2,
                preserveOnePerClient: false
            )
            await manager.debugConfigurePressureEvictionForTesting(idleSeconds: 1)
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: predecessorID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 180),
                clientID: "claim-pressure-predecessor",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: siblingID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 60),
                clientID: "claim-pressure-sibling",
                totalToolCalls: 1,
                createdAt: Date()
            )
            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: predecessorID)
            let claimed = await manager.debugClaimBootstrapAdmissionForTesting(
                connectionID: claimID,
                sessionToken: sessionToken
            )
            XCTAssertTrue(claimed)

            await manager.debugPressureEvictIdleConnectionsForTesting()
            let predecessorRetained = await manager.debugContainsConnection(predecessorID)
            let siblingRetained = await manager.debugContainsConnection(siblingID)
            XCTAssertTrue(predecessorRetained)
            XCTAssertFalse(siblingRetained)

            await manager.debugReleaseBootstrapAdmissionClaimForTesting(
                connectionID: claimID,
                sessionToken: sessionToken
            )
            await manager.debugRemoveConnection(predecessorID)
            await manager.debugRemoveConnection(siblingID)
            await manager.debugConfigurePressureEvictionForTesting(idleSeconds: nil)
            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: nil,
                preserveOnePerClient: nil
            )
        }

        func testProspectiveBootstrapClaimProtectsPredecessorFromGlobalEvictionWithoutDiscountingLoad() async {
            let manager = ServerNetworkManager()
            let sessionToken = "claim-global-\(UUID().uuidString)"
            let predecessorID = UUID()
            let siblingID = UUID()
            let claimID = UUID()

            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: predecessorID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 180),
                clientID: "claim-global-predecessor",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: siblingID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 60),
                clientID: "claim-global-sibling",
                totalToolCalls: 1,
                createdAt: Date()
            )
            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: predecessorID)
            let claimed = await manager.debugClaimBootstrapAdmissionForTesting(
                connectionID: claimID,
                sessionToken: sessionToken
            )
            XCTAssertTrue(claimed)

            let loadBeforeEviction = await manager.debugGlobalAdmissionLoadComponentsForTesting()
            let didEvict = await manager.debugEvictLeastValuableGlobalForAdmissionForTesting(
                preserveOnePerClient: false
            )
            XCTAssertEqual(loadBeforeEviction.registeredConnections, 2)
            XCTAssertEqual(loadBeforeEviction.reservations, 0)
            XCTAssertEqual(loadBeforeEviction.replacementCredits, 0)
            XCTAssertEqual(loadBeforeEviction.effectiveLoad, 2)
            let predecessorRetained = await manager.debugContainsConnection(predecessorID)
            let siblingRetained = await manager.debugContainsConnection(siblingID)
            XCTAssertTrue(didEvict)
            XCTAssertTrue(predecessorRetained)
            XCTAssertFalse(siblingRetained)

            await manager.debugReleaseBootstrapAdmissionClaimForTesting(
                connectionID: claimID,
                sessionToken: sessionToken
            )
            await manager.debugRemoveConnection(predecessorID)
            await manager.debugRemoveConnection(siblingID)
        }

        func testProspectiveBootstrapClaimCreditInvalidatesOnRebindAndReleaseWithoutResurrection() async {
            let manager = ServerNetworkManager()
            let sessionToken = "claim-invalidation-\(UUID().uuidString)"
            let predecessorID = UUID()
            let reboundID = UUID()
            let claimID = UUID()

            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: predecessorID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 120)
            )
            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: reboundID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 60)
            )
            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: predecessorID)
            let claimed = await manager.debugClaimBootstrapAdmissionForTesting(
                connectionID: claimID,
                sessionToken: sessionToken
            )
            XCTAssertTrue(claimed)
            let initiallyProtected = await manager.debugProtectedBootstrapPredecessorConnectionIDsForTesting()
            XCTAssertTrue(initiallyProtected.contains(predecessorID))

            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: reboundID)
            let protectedAfterRebind = await manager.debugProtectedBootstrapPredecessorConnectionIDsForTesting()
            XCTAssertFalse(protectedAfterRebind.contains(predecessorID))
            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: predecessorID)
            let protectedAfterRebindBack = await manager.debugProtectedBootstrapPredecessorConnectionIDsForTesting()
            XCTAssertFalse(
                protectedAfterRebindBack.contains(predecessorID),
                "Invalidated claim credit must not resurrect when the token points back"
            )

            await manager.debugReleaseBootstrapAdmissionClaimForTesting(
                connectionID: claimID,
                sessionToken: sessionToken
            )
            let protectedAfterRelease = await manager.debugProtectedBootstrapPredecessorConnectionIDsForTesting()
            XCTAssertTrue(protectedAfterRelease.isEmpty)
            await manager.debugRemoveConnection(predecessorID)
            await manager.debugRemoveConnection(reboundID)
        }

        func testReplacementBootstrapReservationCreditsItsExactStillBoundPredecessor() async {
            let manager = ServerNetworkManager()
            let predecessorID = UUID()
            let reservationID = UUID()
            let sessionToken = "replacement-credit-\(UUID().uuidString)"

            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: predecessorID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 120)
            )
            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: predecessorID)
            let reserved = await manager.debugReserveBootstrapSlotForTesting(
                connectionID: reservationID,
                sessionToken: sessionToken
            )
            XCTAssertTrue(reserved)

            let effectiveLoad = await manager.debugEffectiveGlobalAdmissionLoadForTesting()
            XCTAssertEqual(
                effectiveLoad,
                1,
                "A replacement reservation and its exact predecessor must count as one transition"
            )

            await manager.debugRollbackBootstrapReservationForTesting(connectionID: reservationID)
            await manager.debugRemoveConnection(predecessorID)
        }

        func testReplacementReservationCreditDoesNotResurrectAfterTokenRebind() async {
            let manager = ServerNetworkManager()
            let predecessorID = UUID()
            let reboundID = UUID()
            let reservationID = UUID()
            let sessionToken = "replacement-credit-rebind-\(UUID().uuidString)"

            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: predecessorID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 120)
            )
            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: reboundID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 60)
            )
            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: predecessorID)
            let reserved = await manager.debugReserveBootstrapSlotForTesting(
                connectionID: reservationID,
                sessionToken: sessionToken
            )
            let initialLoad = await manager.debugEffectiveGlobalAdmissionLoadForTesting()
            XCTAssertTrue(reserved)
            XCTAssertEqual(initialLoad, 2)

            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: reboundID)
            let reboundLoad = await manager.debugEffectiveGlobalAdmissionLoadForTesting()
            XCTAssertEqual(
                reboundLoad,
                3,
                "Rebinding the token must invalidate the captured predecessor credit"
            )
            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: predecessorID)
            let reboundBackLoad = await manager.debugEffectiveGlobalAdmissionLoadForTesting()
            XCTAssertEqual(
                reboundBackLoad,
                3,
                "An invalidated reservation credit must not resurrect when the token later points back"
            )

            await manager.debugRollbackBootstrapReservationForTesting(connectionID: reservationID)
            await manager.debugRemoveConnection(predecessorID)
            await manager.debugRemoveConnection(reboundID)
        }

        func testReplacementReservationCreditDisappearsWhenClaimIsReleased() async {
            let manager = ServerNetworkManager()
            let predecessorID = UUID()
            let reservationID = UUID()
            let sessionToken = "replacement-credit-claim-\(UUID().uuidString)"

            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: predecessorID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 120)
            )
            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: predecessorID)
            let reserved = await manager.debugReserveBootstrapSlotForTesting(
                connectionID: reservationID,
                sessionToken: sessionToken
            )
            let credited = await manager.debugGlobalAdmissionLoadComponentsForTesting()
            XCTAssertTrue(reserved)
            XCTAssertEqual(credited.replacementCredits, 1)
            XCTAssertEqual(credited.effectiveLoad, 1)

            await manager.debugReleaseBootstrapAdmissionClaimForTesting(
                connectionID: reservationID,
                sessionToken: sessionToken
            )
            let released = await manager.debugGlobalAdmissionLoadComponentsForTesting()
            XCTAssertEqual(released.registeredConnections, 1)
            XCTAssertEqual(released.reservations, 1)
            XCTAssertEqual(released.replacementCredits, 0)
            XCTAssertEqual(released.effectiveLoad, 2)

            await manager.debugRollbackBootstrapReservationForTesting(connectionID: reservationID)
            await manager.debugRemoveConnection(predecessorID)
        }

        func testReplacementReservationCreditDisappearsWhenPredecessorRemovalStarts() async {
            let manager = ServerNetworkManager()
            let predecessorID = UUID()
            let reservationID = UUID()
            let sessionToken = "replacement-credit-removal-\(UUID().uuidString)"
            let stopGate = LimiterTestGate()

            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: predecessorID,
                connection: AdmissionEvictionTestConnection(
                    idleSeconds: 120,
                    stopGate: stopGate
                ),
                clientID: "replacement-credit-removal-client",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: predecessorID)
            let reserved = await manager.debugReserveBootstrapSlotForTesting(
                connectionID: reservationID,
                sessionToken: sessionToken
            )
            XCTAssertTrue(reserved)

            let removal = Task {
                await manager.debugRemoveConnection(predecessorID)
            }
            await assertStarted(stopGate, description: "credited predecessor removal")
            let duringRemoval = await manager.debugGlobalAdmissionLoadComponentsForTesting()
            XCTAssertEqual(duringRemoval.registeredConnections, 0)
            XCTAssertEqual(duringRemoval.reservations, 1)
            XCTAssertEqual(duringRemoval.replacementCredits, 0)
            XCTAssertEqual(duringRemoval.effectiveLoad, 1)

            await stopGate.release()
            await assertCompletion(removal, description: "credited predecessor removal")
            await manager.debugRollbackBootstrapReservationForTesting(connectionID: reservationID)
        }

        func testReplacementReservationCleanupRemovesCreditOnExpiryRollbackAndCommit() async {
            let manager = ServerNetworkManager()
            let predecessorID = UUID()
            let sessionToken = "replacement-credit-cleanup-\(UUID().uuidString)"

            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: predecessorID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 120)
            )
            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: predecessorID)

            let expiredReservationID = UUID()
            let expiredReserved = await manager.debugReserveBootstrapSlotForTesting(
                connectionID: expiredReservationID,
                sessionToken: sessionToken
            )
            XCTAssertTrue(expiredReserved)
            await manager.debugExpireBootstrapReservationForTesting(connectionID: expiredReservationID)
            let expired = await manager.debugGlobalAdmissionLoadComponentsForTesting()
            XCTAssertEqual(expired.reservations, 0)
            XCTAssertEqual(expired.replacementCredits, 0)
            XCTAssertEqual(expired.effectiveLoad, 1)

            let rolledBackReservationID = UUID()
            let rollbackReserved = await manager.debugReserveBootstrapSlotForTesting(
                connectionID: rolledBackReservationID,
                sessionToken: sessionToken
            )
            XCTAssertTrue(rollbackReserved)
            await manager.debugRollbackBootstrapReservationForTesting(
                connectionID: rolledBackReservationID
            )
            let rolledBack = await manager.debugGlobalAdmissionLoadComponentsForTesting()
            XCTAssertEqual(rolledBack.reservations, 0)
            XCTAssertEqual(rolledBack.replacementCredits, 0)

            let committedReservationID = UUID()
            let commitReserved = await manager.debugReserveBootstrapSlotForTesting(
                connectionID: committedReservationID,
                sessionToken: sessionToken
            )
            XCTAssertTrue(commitReserved)
            let committed = await manager.debugCommitBootstrapReservationAccountingForTesting(
                connectionID: committedReservationID
            )
            let afterCommit = await manager.debugGlobalAdmissionLoadComponentsForTesting()
            XCTAssertTrue(committed)
            XCTAssertEqual(afterCommit.reservations, 0)
            XCTAssertEqual(afterCommit.replacementCredits, 0)

            await manager.debugRemoveConnection(predecessorID)
        }

        func testExpiredReplacementReservationStaysCountedAndCannotCommit() async {
            let manager = ServerNetworkManager()
            let predecessorID = UUID()
            let reservationID = UUID()
            let sessionToken = "replacement-credit-expired-commit-\(UUID().uuidString)"

            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: predecessorID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 120)
            )
            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: predecessorID)
            let reserved = await manager.debugReserveBootstrapSlotForTesting(
                connectionID: reservationID,
                sessionToken: sessionToken
            )
            XCTAssertTrue(reserved)

            await manager.debugAgeBootstrapReservationPastExpiryForTesting(
                connectionID: reservationID
            )
            let expiredPending = await manager.debugGlobalAdmissionLoadComponentsForTesting()
            XCTAssertEqual(expiredPending.registeredConnections, 1)
            XCTAssertEqual(expiredPending.reservations, 1)
            XCTAssertEqual(expiredPending.replacementCredits, 0)
            XCTAssertEqual(expiredPending.effectiveLoad, 2)

            let committed = await manager.debugCommitBootstrapReservationAccountingForTesting(
                connectionID: reservationID
            )
            let afterRejectedCommit = await manager.debugGlobalAdmissionLoadComponentsForTesting()
            XCTAssertFalse(committed)
            XCTAssertEqual(afterRejectedCommit.reservations, 0)
            XCTAssertEqual(afterRejectedCommit.replacementCredits, 0)
            XCTAssertEqual(afterRejectedCommit.effectiveLoad, 1)

            await manager.debugRemoveConnection(predecessorID)
        }

        func testReplacementReservationCreditIsIdentityAndLifecycleFenced() async {
            let identityManager = ServerNetworkManager()
            let identityPredecessorID = UUID()
            let identityReservationID = UUID()
            let identityToken = "replacement-credit-identity-\(UUID().uuidString)"

            await identityManager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: identityPredecessorID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 120)
            )
            await identityManager.debugBindSessionTokenForAdmissionTesting(
                identityToken,
                to: identityPredecessorID
            )
            let identityReserved = await identityManager.debugReserveBootstrapSlotForTesting(
                connectionID: identityReservationID,
                sessionToken: identityToken
            )
            XCTAssertTrue(identityReserved)
            await identityManager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: identityPredecessorID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 60)
            )
            let identityReplaced = await identityManager.debugGlobalAdmissionLoadComponentsForTesting()
            XCTAssertEqual(identityReplaced.reservations, 1)
            XCTAssertEqual(identityReplaced.replacementCredits, 0)
            XCTAssertEqual(identityReplaced.effectiveLoad, 2)
            await identityManager.debugRollbackBootstrapReservationForTesting(
                connectionID: identityReservationID
            )
            await identityManager.debugRemoveConnection(identityPredecessorID)

            let lifecycleManager = ServerNetworkManager()
            let lifecyclePredecessorID = UUID()
            let lifecycleReservationID = UUID()
            let lifecycleToken = "replacement-credit-lifecycle-\(UUID().uuidString)"
            let lifecycleConnection = AdmissionEvictionTestConnection(idleSeconds: 120)

            await lifecycleManager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: lifecyclePredecessorID,
                connection: lifecycleConnection
            )
            await lifecycleManager.debugBindSessionTokenForAdmissionTesting(
                lifecycleToken,
                to: lifecyclePredecessorID
            )
            let lifecycleReserved = await lifecycleManager.debugReserveBootstrapSlotForTesting(
                connectionID: lifecycleReservationID,
                sessionToken: lifecycleToken
            )
            XCTAssertTrue(lifecycleReserved)
            await lifecycleManager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: lifecyclePredecessorID,
                connection: lifecycleConnection,
                advanceLifecycleGeneration: true
            )
            let lifecycleReplaced = await lifecycleManager.debugGlobalAdmissionLoadComponentsForTesting()
            XCTAssertEqual(lifecycleReplaced.reservations, 0)
            XCTAssertEqual(lifecycleReplaced.replacementCredits, 0)
            XCTAssertEqual(lifecycleReplaced.effectiveLoad, 1)
            await lifecycleManager.stop()
        }

        func testCallEnteringDuringTentativeCloseWaitsForRestoration() async {
            let manager = ServerNetworkManager()
            let clientID = "during-close-restoration-\(UUID().uuidString)"
            let incomingConnectionID = UUID()
            let victimID = UUID()
            let siblingID = UUID()
            let resolutionGate = LimiterTestGate()
            let rejectionGate = LimiterTestGate()
            let siblingStopGate = LimiterTestGate()
            let siblingRemovalTask = LimiterTestTaskStore()
            let lateCallTask = LimiterTestTaskStore()
            let operationRan = LimiterTestFlag()

            await manager.debugConfigurePerClientAdmissionForTesting(maxConnectionsPerClient: 2)
            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: incomingConnectionID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 0)
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: victimID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 180),
                clientID: clientID,
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: siblingID,
                connection: AdmissionEvictionTestConnection(
                    idleSeconds: 60,
                    stopGate: siblingStopGate
                ),
                clientID: clientID,
                totalToolCalls: 1,
                createdAt: Date()
            )
            await manager.debugSetAfterConnectionCallLimiterResolutionForTesting { resolvedID in
                guard resolvedID == victimID else { return }
                await resolutionGate.markStartedAndWaitForRelease()
            }
            await manager.debugSetAfterConnectionCallLimiterRejectionForTesting { rejectedID in
                guard rejectedID == victimID else { return }
                await rejectionGate.markStartedAndWaitForRelease()
            }
            await manager.debugSetDuringAdmissionEvictionCloseForTesting { candidateID in
                guard candidateID == victimID else { return }
                await lateCallTask.start {
                    try? await manager.withConnectionCallPermitForTesting(
                        connectionID: victimID,
                        lane: .ordinary
                    ) {
                        await operationRan.mark()
                    }
                }
                guard await resolutionGate.waitUntilStarted(timeout: .seconds(2)) else { return }
                await resolutionGate.release()
                guard await rejectionGate.waitUntilStarted(timeout: .seconds(2)) else { return }
                await rejectionGate.release()
                let waiterRegistered = await self.waitForAdmissionRetryWaiterCount(
                    manager: manager,
                    connectionID: victimID,
                    expectedCount: 1
                )
                guard waiterRegistered else { return }
                // Cross the former fixed one-second retry deadline while the exact
                // tentative transition remains unresolved. The call must keep waiting.
                try? await Task.sleep(for: .milliseconds(1250))
                await siblingRemovalTask.start {
                    await manager.debugRemoveConnection(siblingID)
                }
                _ = await siblingStopGate.waitUntilStarted(timeout: .seconds(2))
            }

            let admitted = await manager.tryReserveConnectionSlot(
                connectionID: incomingConnectionID,
                clientID: clientID
            )
            await manager.debugSetDuringAdmissionEvictionCloseForTesting(nil)
            await manager.debugSetAfterConnectionCallLimiterResolutionForTesting(nil)
            await manager.debugSetAfterConnectionCallLimiterRejectionForTesting(nil)

            let lateCallCompleted = await lateCallTask.wait()
            let didRunOperation = await operationRan.isMarked()
            XCTAssertTrue(admitted)
            XCTAssertTrue(lateCallCompleted)
            XCTAssertTrue(
                didRunOperation,
                "A call that encounters the tentatively closed current bundle must await restoration and retry"
            )

            await siblingStopGate.release()
            await assertCompletion(siblingRemovalTask, description: "during-close sibling removal")
            await manager.debugRemoveConnection(incomingConnectionID)
            await manager.debugRemoveConnection(victimID)
            await manager.debugConfigurePerClientAdmissionForTesting(maxConnectionsPerClient: nil)
        }

        func testPerClientEvictionSkipsCreditedBootstrapPredecessor() async {
            let manager = ServerNetworkManager()
            let clientID = "per-client-credited-predecessor-\(UUID().uuidString)"
            let sessionToken = "per-client-credited-predecessor-\(UUID().uuidString)"
            let predecessorID = UUID()
            let siblingID = UUID()
            let reservationID = UUID()

            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: predecessorID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 180),
                clientID: clientID,
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: siblingID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 60),
                clientID: clientID,
                totalToolCalls: 1,
                createdAt: Date()
            )
            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: predecessorID)
            let reserved = await manager.debugReserveBootstrapSlotForTesting(
                connectionID: reservationID,
                sessionToken: sessionToken
            )
            XCTAssertTrue(reserved)

            let didEvict = await manager.debugEvictLeastValuableForTesting(clientID: clientID)
            let predecessorRetained = await manager.debugContainsConnection(predecessorID)
            let siblingRetained = await manager.debugContainsConnection(siblingID)
            XCTAssertTrue(didEvict)
            XCTAssertTrue(
                predecessorRetained,
                "Per-client eviction must not remove a predecessor carrying live bootstrap credit"
            )
            XCTAssertFalse(siblingRetained)

            await manager.debugRollbackBootstrapReservationForTesting(connectionID: reservationID)
            await manager.debugRemoveConnection(predecessorID)
            await manager.debugRemoveConnection(siblingID)
        }

        func testPerClientEvictionRestoresCandidateThatBecomesCreditedDuringClose() async throws {
            let manager = ServerNetworkManager()
            let clientID = "per-client-credit-during-close-\(UUID().uuidString)"
            let sessionToken = "per-client-credit-during-close-\(UUID().uuidString)"
            let predecessorID = UUID()
            let reservationID = UUID()

            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: predecessorID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 180),
                clientID: clientID,
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: predecessorID)
            let installedOriginalLimiter = await manager.limiter(
                for: predecessorID,
                lane: .ordinary
            )
            let originalLimiter = try XCTUnwrap(installedOriginalLimiter)
            await manager.debugSetDuringAdmissionEvictionCloseForTesting { candidateID in
                guard candidateID == predecessorID else { return }
                _ = await manager.debugReserveBootstrapSlotForTesting(
                    connectionID: reservationID,
                    sessionToken: sessionToken
                )
            }

            let didEvict = await manager.debugEvictLeastValuableForTesting(clientID: clientID)
            await manager.debugSetDuringAdmissionEvictionCloseForTesting(nil)

            let predecessorRetained = await manager.debugContainsConnection(predecessorID)
            let originalSnapshot = await originalLimiter.debugSnapshot()
            let restoredSnapshot = await manager.connectionLimiterSnapshotForTesting(
                connectionID: predecessorID,
                lane: .ordinary
            )
            XCTAssertFalse(didEvict)
            XCTAssertTrue(predecessorRetained)
            XCTAssertTrue(originalSnapshot.isClosed)
            XCTAssertFalse(restoredSnapshot?.isClosed ?? true)

            await manager.debugRollbackBootstrapReservationForTesting(connectionID: reservationID)
            await manager.debugRemoveConnection(predecessorID)
        }

        func testPerClientRemovalCommitPreventsLateCreditFromStrandingClosedPredecessor() async {
            let manager = ServerNetworkManager()
            let clientID = "per-client-removal-commit-\(UUID().uuidString)"
            let sessionToken = "per-client-removal-commit-\(UUID().uuidString)"
            let predecessorID = UUID()
            let reservationID = UUID()

            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: predecessorID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 180),
                clientID: clientID,
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: predecessorID)
            await manager.debugSetAfterAdmissionEvictionRemovalCommittedForTesting { candidateID in
                guard candidateID == predecessorID else { return }
                _ = await manager.debugReserveBootstrapSlotForTesting(
                    connectionID: reservationID,
                    sessionToken: sessionToken
                )
            }

            let didEvict = await manager.debugEvictLeastValuableForTesting(clientID: clientID)
            await manager.debugSetAfterAdmissionEvictionRemovalCommittedForTesting(nil)

            let predecessorRetained = await manager.debugContainsConnection(predecessorID)
            let load = await manager.debugGlobalAdmissionLoadComponentsForTesting()
            XCTAssertTrue(didEvict)
            XCTAssertFalse(predecessorRetained)
            XCTAssertEqual(load.reservations, 1)
            XCTAssertEqual(
                load.replacementCredits,
                0,
                "Once exact removal is committed, a late reservation must not credit the closing predecessor"
            )

            await manager.debugRollbackBootstrapReservationForTesting(connectionID: reservationID)
            await manager.debugRemoveConnection(predecessorID)
        }

        func testPressureEvictionSkipsCreditedBootstrapPredecessor() async {
            let manager = ServerNetworkManager()
            let sessionToken = "pressure-credited-predecessor-\(UUID().uuidString)"
            let predecessorID = UUID()
            let siblingID = UUID()
            let reservationID = UUID()

            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: 2,
                preserveOnePerClient: false
            )
            await manager.debugConfigurePressureEvictionForTesting(idleSeconds: 1)
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: predecessorID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 180),
                clientID: "pressure-credited-predecessor",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: siblingID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 60),
                clientID: "pressure-ordinary-sibling",
                totalToolCalls: 1,
                createdAt: Date()
            )
            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: predecessorID)
            let reserved = await manager.debugReserveBootstrapSlotForTesting(
                connectionID: reservationID,
                sessionToken: sessionToken
            )
            XCTAssertTrue(reserved)

            await manager.debugPressureEvictIdleConnectionsForTesting()
            let predecessorRetained = await manager.debugContainsConnection(predecessorID)
            let siblingRetained = await manager.debugContainsConnection(siblingID)
            XCTAssertTrue(
                predecessorRetained,
                "Pressure eviction must not remove a predecessor carrying live bootstrap credit"
            )
            XCTAssertFalse(siblingRetained)

            await manager.debugRollbackBootstrapReservationForTesting(connectionID: reservationID)
            await manager.debugRemoveConnection(predecessorID)
            await manager.debugRemoveConnection(siblingID)
            await manager.debugConfigurePressureEvictionForTesting(idleSeconds: nil)
            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: nil,
                preserveOnePerClient: nil
            )
        }

        func testPressureEvictionRestoresCandidateThatBecomesCreditedDuringClose() async throws {
            let manager = ServerNetworkManager()
            let sessionToken = "pressure-credit-during-close-\(UUID().uuidString)"
            let predecessorID = UUID()
            let reservationID = UUID()

            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: 1,
                preserveOnePerClient: false
            )
            await manager.debugConfigurePressureEvictionForTesting(idleSeconds: 1)
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: predecessorID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 180),
                clientID: "pressure-credit-during-close",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: predecessorID)
            let installedOriginalLimiter = await manager.limiter(
                for: predecessorID,
                lane: .ordinary
            )
            let originalLimiter = try XCTUnwrap(installedOriginalLimiter)
            await manager.debugSetDuringAdmissionEvictionCloseForTesting { candidateID in
                guard candidateID == predecessorID else { return }
                _ = await manager.debugReserveBootstrapSlotForTesting(
                    connectionID: reservationID,
                    sessionToken: sessionToken
                )
            }

            await manager.debugPressureEvictIdleConnectionsForTesting()
            await manager.debugSetDuringAdmissionEvictionCloseForTesting(nil)

            let predecessorRetained = await manager.debugContainsConnection(predecessorID)
            let originalSnapshot = await originalLimiter.debugSnapshot()
            let restoredSnapshot = await manager.connectionLimiterSnapshotForTesting(
                connectionID: predecessorID,
                lane: .ordinary
            )
            XCTAssertTrue(predecessorRetained)
            XCTAssertTrue(originalSnapshot.isClosed)
            XCTAssertFalse(restoredSnapshot?.isClosed ?? true)

            await manager.debugRollbackBootstrapReservationForTesting(connectionID: reservationID)
            await manager.debugRemoveConnection(predecessorID)
            await manager.debugConfigurePressureEvictionForTesting(idleSeconds: nil)
            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: nil,
                preserveOnePerClient: nil
            )
        }

        func testPreResolvedCallRetriesRestoredLimiterBundleForSameConnectionLifecycle() async throws {
            let manager = ServerNetworkManager()
            let clientID = "pre-resolved-restoration-\(UUID().uuidString)"
            let incomingConnectionID = UUID()
            let victimID = UUID()
            let siblingID = UUID()
            let resolutionGate = LimiterTestGate()
            let siblingStopGate = LimiterTestGate()
            let siblingRemovalTask = LimiterTestTaskStore()
            let operationRan = LimiterTestFlag()

            await manager.debugConfigurePerClientAdmissionForTesting(maxConnectionsPerClient: 2)
            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: incomingConnectionID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 0)
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: victimID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 180),
                clientID: clientID,
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: siblingID,
                connection: AdmissionEvictionTestConnection(
                    idleSeconds: 60,
                    stopGate: siblingStopGate
                ),
                clientID: clientID,
                totalToolCalls: 1,
                createdAt: Date()
            )
            let installedOriginalLimiter = await manager.limiter(for: victimID, lane: .ordinary)
            let originalLimiter = try XCTUnwrap(installedOriginalLimiter)
            await manager.debugSetAfterConnectionCallLimiterResolutionForTesting { connectionID in
                guard connectionID == victimID else { return }
                await resolutionGate.markStartedAndWaitForRelease()
            }

            let preResolvedCall = Task {
                try await manager.withConnectionCallPermitForTesting(
                    connectionID: victimID,
                    lane: .ordinary
                ) {
                    await operationRan.mark()
                }
            }
            await assertStarted(resolutionGate, description: "pre-resolved limiter call")

            await manager.debugSetDuringAdmissionEvictionCloseForTesting { candidateID in
                guard candidateID == victimID else { return }
                await siblingRemovalTask.start {
                    await manager.debugRemoveConnection(siblingID)
                }
                _ = await siblingStopGate.waitUntilStarted(timeout: .seconds(2))
            }
            let admitted = await manager.tryReserveConnectionSlot(
                connectionID: incomingConnectionID,
                clientID: clientID
            )
            await manager.debugSetDuringAdmissionEvictionCloseForTesting(nil)
            await manager.debugSetAfterConnectionCallLimiterResolutionForTesting(nil)
            await resolutionGate.release()

            let callSucceeded: Bool
            do {
                try await preResolvedCall.value
                callSucceeded = true
            } catch {
                callSucceeded = false
            }
            let originalSnapshot = await originalLimiter.debugSnapshot()
            let restoredSnapshot = await manager.connectionLimiterSnapshotForTesting(
                connectionID: victimID,
                lane: .ordinary
            )
            let didRunOperation = await operationRan.isMarked()

            XCTAssertTrue(admitted)
            XCTAssertTrue(originalSnapshot.isClosed)
            XCTAssertFalse(restoredSnapshot?.isClosed ?? true)
            XCTAssertTrue(
                callSucceeded,
                "A call rejected only by an exact bundle restoration must retry the registered bundle"
            )
            XCTAssertTrue(didRunOperation)

            await siblingStopGate.release()
            await assertCompletion(siblingRemovalTask, description: "pre-resolved sibling removal")
            await manager.debugRemoveConnection(incomingConnectionID)
            await manager.debugRemoveConnection(victimID)
            await manager.debugConfigurePerClientAdmissionForTesting(maxConnectionsPerClient: nil)
        }

        func testPreResolvedCallRetriesThroughSuccessiveRestoredLimiterBundles() async throws {
            let manager = ServerNetworkManager()
            let connectionID = UUID()
            let resolutionGate = LimiterTestGate()
            let secondRestorationTriggered = LimiterTestFlag()
            let operationRan = LimiterTestFlag()

            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: connectionID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 120),
                clientID: "successive-restoration-\(UUID().uuidString)",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            let installedOriginalLimiter = await manager.limiter(for: connectionID, lane: .ordinary)
            let originalLimiter = try XCTUnwrap(installedOriginalLimiter)
            await manager.debugSetAfterConnectionCallLimiterResolutionForTesting { resolvedID in
                guard resolvedID == connectionID else { return }
                await resolutionGate.markStartedAndWaitForRelease()
            }

            let preResolvedCall = Task {
                try await manager.withConnectionCallPermitForTesting(
                    connectionID: connectionID,
                    lane: .ordinary
                ) {
                    await operationRan.mark()
                }
            }
            await assertStarted(resolutionGate, description: "successive restoration call")

            let firstRestored = await manager.closeAndRestoreConnectionCallLanesForTesting(connectionID)
            let installedFirstReplacement = await manager.limiter(for: connectionID, lane: .ordinary)
            let firstReplacement = try XCTUnwrap(installedFirstReplacement)
            XCTAssertTrue(firstRestored)

            await manager.debugSetAfterConnectionCallLimiterRejectionForTesting { rejectedID in
                guard rejectedID == connectionID,
                      await secondRestorationTriggered.markIfUnmarked()
                else { return }
                _ = await manager.closeAndRestoreConnectionCallLanesForTesting(connectionID)
            }
            await manager.debugSetAfterConnectionCallLimiterResolutionForTesting(nil)
            await resolutionGate.release()

            _ = try await boundedValue(
                of: preResolvedCall,
                description: "call through successive restored limiter bundles"
            )
            await manager.debugSetAfterConnectionCallLimiterRejectionForTesting(nil)

            let installedCurrentLimiter = await manager.limiter(for: connectionID, lane: .ordinary)
            let currentLimiter = try XCTUnwrap(installedCurrentLimiter)
            let originalSnapshot = await originalLimiter.debugSnapshot()
            let firstReplacementSnapshot = await firstReplacement.debugSnapshot()
            let currentSnapshot = await currentLimiter.debugSnapshot()
            XCTAssertTrue(originalSnapshot.isClosed)
            XCTAssertTrue(firstReplacementSnapshot.isClosed)
            XCTAssertFalse(currentSnapshot.isClosed)
            let didRunOperation = await operationRan.isMarked()
            XCTAssertFalse(firstReplacement === currentLimiter)
            XCTAssertTrue(didRunOperation)

            await manager.debugRemoveConnection(connectionID)
        }

        func testSuccessiveRestorationDoesNotResurrectConnectionAfterTerminalRemoval() async {
            let manager = ServerNetworkManager()
            let connectionID = UUID()
            let resolutionGate = LimiterTestGate()
            let terminalTransitionTriggered = LimiterTestFlag()
            let operationRan = LimiterTestFlag()

            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: connectionID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 120),
                clientID: "successive-restoration-removal-\(UUID().uuidString)",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugSetAfterConnectionCallLimiterResolutionForTesting { resolvedID in
                guard resolvedID == connectionID else { return }
                await resolutionGate.markStartedAndWaitForRelease()
            }

            let preResolvedCall = Task {
                try await manager.withConnectionCallPermitForTesting(
                    connectionID: connectionID,
                    lane: .ordinary
                ) {
                    await operationRan.mark()
                }
            }
            await assertStarted(resolutionGate, description: "successive restoration removal call")
            let firstRestored = await manager.closeAndRestoreConnectionCallLanesForTesting(connectionID)
            XCTAssertTrue(firstRestored)

            await manager.debugSetAfterConnectionCallLimiterRejectionForTesting { rejectedID in
                guard rejectedID == connectionID,
                      await terminalTransitionTriggered.markIfUnmarked()
                else { return }
                _ = await manager.closeAndRestoreConnectionCallLanesForTesting(connectionID)
                await manager.debugRemoveConnection(connectionID)
            }
            await manager.debugSetAfterConnectionCallLimiterResolutionForTesting(nil)
            await resolutionGate.release()

            await assertCancellation(preResolvedCall)
            await manager.debugSetAfterConnectionCallLimiterRejectionForTesting(nil)
            let didRunOperation = await operationRan.isMarked()
            let registeredLimiter = await manager.connectionLimiterSnapshotForTesting(connectionID: connectionID)
            XCTAssertFalse(didRunOperation)
            XCTAssertNil(registeredLimiter)
        }

        func testPreResolvedCallDoesNotRetryAfterGenuineConnectionRemoval() async {
            let manager = ServerNetworkManager()
            let connectionID = UUID()
            let resolutionGate = LimiterTestGate()
            let stopGate = LimiterTestGate()
            let operationRan = LimiterTestFlag()

            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: connectionID,
                connection: AdmissionEvictionTestConnection(
                    idleSeconds: 120,
                    stopGate: stopGate
                ),
                clientID: "pre-resolved-removal-\(UUID().uuidString)",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugSetAfterConnectionCallLimiterResolutionForTesting { resolvedID in
                guard resolvedID == connectionID else { return }
                await resolutionGate.markStartedAndWaitForRelease()
            }

            let preResolvedCall = Task {
                try await manager.withConnectionCallPermitForTesting(
                    connectionID: connectionID,
                    lane: .ordinary
                ) {
                    await operationRan.mark()
                }
            }
            await assertStarted(resolutionGate, description: "pre-resolved removal call")

            let removal = Task {
                await manager.debugRemoveConnection(connectionID)
            }
            await assertStarted(stopGate, description: "genuine connection removal")
            await manager.debugSetAfterConnectionCallLimiterResolutionForTesting(nil)
            await resolutionGate.release()

            let callSucceeded: Bool
            do {
                try await preResolvedCall.value
                callSucceeded = true
            } catch {
                callSucceeded = false
            }
            let didRunOperation = await operationRan.isMarked()
            XCTAssertFalse(callSucceeded)
            XCTAssertFalse(didRunOperation)

            await stopGate.release()
            await assertCompletion(removal, description: "genuine connection removal")
        }

        func testDirectAdmissionRechecksEffectiveCapacityAfterPreservationRollback() async throws {
            try await assertAdmissionRechecksEffectiveCapacityAfterPreservationRollback(path: .direct)
        }

        func testBootstrapAdmissionRechecksEffectiveCapacityAfterPreservationRollback() async throws {
            try await assertAdmissionRechecksEffectiveCapacityAfterPreservationRollback(path: .bootstrap)
        }

        func testDirectAdmissionRejectsWhenEffectiveLiveCapacityRemainsFull() async {
            await assertAdmissionRejectsWhenEffectiveLiveCapacityRemainsFull(path: .direct)
        }

        func testBootstrapAdmissionRejectsWhenEffectiveLiveCapacityRemainsFull() async {
            await assertAdmissionRejectsWhenEffectiveLiveCapacityRemainsFull(path: .bootstrap)
        }

        func testPreResolvedCallDoesNotRetryRestoredBundleAfterTaskCancellation() async {
            let manager = ServerNetworkManager()
            let connectionID = UUID()
            let resolutionGate = LimiterTestGate()
            let operationRan = LimiterTestFlag()

            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: connectionID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 120),
                clientID: "pre-resolved-cancelled-\(UUID().uuidString)",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugSetAfterConnectionCallLimiterResolutionForTesting { resolvedID in
                guard resolvedID == connectionID else { return }
                await resolutionGate.markStartedAndWaitForRelease()
            }

            let preResolvedCall = Task {
                try await manager.withConnectionCallPermitForTesting(
                    connectionID: connectionID,
                    lane: .ordinary
                ) {
                    await operationRan.mark()
                }
            }
            await assertStarted(resolutionGate, description: "pre-resolved cancelled call")
            preResolvedCall.cancel()
            let restored = await manager.closeAndRestoreConnectionCallLanesForTesting(connectionID)
            await manager.debugSetAfterConnectionCallLimiterResolutionForTesting(nil)
            await resolutionGate.release()

            let callSucceeded: Bool
            do {
                try await preResolvedCall.value
                callSucceeded = true
            } catch {
                callSucceeded = false
            }
            let didRunOperation = await operationRan.isMarked()
            XCTAssertTrue(restored)
            XCTAssertFalse(callSucceeded)
            XCTAssertFalse(didRunOperation)

            await manager.debugRemoveConnection(connectionID)
        }

        func testEvictionCloseAtomicallyRejectsNewCallsOnBothLanes() async throws {
            let manager = ServerNetworkManager()
            let connectionID = UUID()
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: connectionID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 120),
                clientID: "closed-without-replacement-\(UUID().uuidString)",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            let didClose = await manager.closeConnectionCallLanesIfIdleForEvictionForTesting(connectionID)
            XCTAssertTrue(didClose)

            for lane in MCPConnectionCallLane.allCases {
                let bodyRan = LimiterTestFlag()
                do {
                    try await manager.withConnectionCallPermitForTesting(
                        connectionID: connectionID,
                        lane: lane
                    ) {
                        await bodyRan.mark()
                    }
                    XCTFail("Closed connection call lanes should reject \(lane.rawValue)")
                } catch is CancellationError {
                    // Expected.
                } catch {
                    XCTFail("Expected CancellationError for \(lane.rawValue), got \(error)")
                }
                let didRunBody = await bodyRan.isMarked()
                XCTAssertFalse(didRunBody)
            }

            await manager.debugRemoveConnection(connectionID)
        }

        private enum GlobalAdmissionPath: Equatable {
            case direct
            case bootstrap
        }

        private func assertDirectAdmissionRejectsStaleResume(
            advanceLifecycleGeneration: Bool,
            replaceConnectionActor: Bool,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            let manager = ServerNetworkManager()
            let connectionID = UUID()
            let originalClientID = "stale-direct-original-\(UUID().uuidString)"
            let replacementClientID = "stale-direct-replacement-\(UUID().uuidString)"
            let originalConnection = AdmissionEvictionTestConnection(idleSeconds: 0)
            let replacementConnection = replaceConnectionActor
                ? AdmissionEvictionTestConnection(idleSeconds: 0)
                : originalConnection

            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: connectionID,
                connection: originalConnection
            )
            await manager.debugSetAfterDirectAdmissionPendingPublishedForTesting { suspendedConnectionID in
                guard suspendedConnectionID == connectionID else { return }
                await manager.debugInstallDirectAdmissionConnectionForTesting(
                    connectionID: connectionID,
                    connection: replacementConnection,
                    pendingClientID: replacementClientID,
                    advanceLifecycleGeneration: advanceLifecycleGeneration
                )
            }

            let admitted = await manager.tryReserveConnectionSlot(
                connectionID: connectionID,
                clientID: originalClientID
            )
            await manager.debugSetAfterDirectAdmissionPendingPublishedForTesting(nil)
            let state = await manager.debugDirectAdmissionStateForTesting(connectionID: connectionID)

            XCTAssertFalse(admitted, "A stale direct admission must reject after suspension", file: file, line: line)
            XCTAssertEqual(state.pendingClientID, replacementClientID, file: file, line: line)
            XCTAssertNil(state.indexedClientID, file: file, line: line)
            XCTAssertTrue(state.activeClientIDs.isEmpty, file: file, line: line)
            XCTAssertFalse(state.hasStats, file: file, line: line)
            XCTAssertEqual(
                state.connectionLifecycleGeneration,
                state.lifecycleGeneration,
                "The replacement lifecycle metadata must remain intact",
                file: file,
                line: line
            )

            await manager.debugRemoveConnection(connectionID)
        }

        private func assertGlobalAdmissionPreservesCandidateWhenRemovalCreatesHeadroomBeforeClose(
            path: GlobalAdmissionPath,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let manager = ServerNetworkManager()
            let victimID = UUID()
            let capacityReliefID = UUID()
            let incomingConnectionID = UUID()
            let capacityReliefStopGate = LimiterTestGate()
            let capacityReliefRemovalTask = LimiterTestTaskStore()

            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: path == .direct ? 3 : 2,
                preserveOnePerClient: false
            )
            if path == .direct {
                await manager.debugInstallDirectAdmissionConnectionForTesting(
                    connectionID: incomingConnectionID,
                    connection: AdmissionEvictionTestConnection(idleSeconds: 0)
                )
            }
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: victimID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 180),
                clientID: "global-preclose-victim-\(UUID().uuidString)",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: capacityReliefID,
                connection: AdmissionEvictionTestConnection(
                    idleSeconds: 10,
                    stopGate: capacityReliefStopGate
                ),
                clientID: "global-preclose-relief-\(UUID().uuidString)",
                totalToolCalls: 1,
                createdAt: Date()
            )
            let installedOrdinary = await manager.limiter(for: victimID, lane: .ordinary)
            let installedFileSearch = await manager.limiter(for: victimID, lane: .fileSearch)
            let originalOrdinary = try XCTUnwrap(installedOrdinary, file: file, line: line)
            let originalFileSearch = try XCTUnwrap(installedFileSearch, file: file, line: line)

            await manager.debugSetBeforeAdmissionEvictionCloseForTesting { candidateID in
                guard candidateID == victimID else { return }
                await capacityReliefRemovalTask.start {
                    await manager.debugRemoveConnection(capacityReliefID)
                }
                _ = await capacityReliefStopGate.waitUntilStarted(timeout: .seconds(2))
            }

            let admitted: Bool = switch path {
            case .direct:
                await manager.tryReserveConnectionSlot(
                    connectionID: incomingConnectionID,
                    clientID: "global-preclose-incoming-\(UUID().uuidString)"
                )
            case .bootstrap:
                await manager.debugBootstrapAdmissionHasCapacityForTesting()
            }
            await manager.debugSetBeforeAdmissionEvictionCloseForTesting(nil)

            let capacityReliefRemovalStarted = await capacityReliefStopGate.hasStarted()
            let victimRetained = await manager.debugContainsConnection(victimID)
            let originalOrdinarySnapshot = await originalOrdinary.debugSnapshot()
            let originalFileSearchSnapshot = await originalFileSearch.debugSnapshot()
            XCTAssertTrue(admitted, file: file, line: line)
            XCTAssertTrue(capacityReliefRemovalStarted, file: file, line: line)
            XCTAssertTrue(
                victimRetained,
                "Capacity progress before atomic closure must preserve the unrelated candidate",
                file: file,
                line: line
            )
            XCTAssertFalse(originalOrdinarySnapshot.isClosed, file: file, line: line)
            XCTAssertFalse(originalFileSearchSnapshot.isClosed, file: file, line: line)

            if path == .direct {
                await manager.debugRemoveConnection(incomingConnectionID)
            }
            await capacityReliefStopGate.release()
            await assertCompletion(capacityReliefRemovalTask, description: "global pre-close capacity relief")
            await manager.debugRemoveConnection(victimID)
            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: nil,
                preserveOnePerClient: nil
            )
        }

        private func assertGlobalAdmissionRestoresClosedCandidateWhenRemovalCreatesHeadroomDuringClose(
            path: GlobalAdmissionPath,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let manager = ServerNetworkManager()
            let victimID = UUID()
            let capacityReliefID = UUID()
            let incomingConnectionID = UUID()
            let capacityReliefStopGate = LimiterTestGate()
            let capacityReliefRemovalTask = LimiterTestTaskStore()

            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: path == .direct ? 3 : 2,
                preserveOnePerClient: false
            )
            if path == .direct {
                await manager.debugInstallDirectAdmissionConnectionForTesting(
                    connectionID: incomingConnectionID,
                    connection: AdmissionEvictionTestConnection(idleSeconds: 0)
                )
            }
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: victimID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 180),
                clientID: "global-during-close-victim-\(UUID().uuidString)",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: capacityReliefID,
                connection: AdmissionEvictionTestConnection(
                    idleSeconds: 10,
                    stopGate: capacityReliefStopGate
                ),
                clientID: "global-during-close-relief-\(UUID().uuidString)",
                totalToolCalls: 1,
                createdAt: Date()
            )
            let installedOrdinary = await manager.limiter(for: victimID, lane: .ordinary)
            let installedFileSearch = await manager.limiter(for: victimID, lane: .fileSearch)
            let originalOrdinary = try XCTUnwrap(installedOrdinary, file: file, line: line)
            let originalFileSearch = try XCTUnwrap(installedFileSearch, file: file, line: line)

            await manager.debugSetDuringAdmissionEvictionCloseForTesting { candidateID in
                guard candidateID == victimID else { return }
                await capacityReliefRemovalTask.start {
                    await manager.debugRemoveConnection(capacityReliefID)
                }
                _ = await capacityReliefStopGate.waitUntilStarted(timeout: .seconds(2))
            }

            let admitted: Bool = switch path {
            case .direct:
                await manager.tryReserveConnectionSlot(
                    connectionID: incomingConnectionID,
                    clientID: "global-during-close-incoming-\(UUID().uuidString)"
                )
            case .bootstrap:
                await manager.debugBootstrapAdmissionHasCapacityForTesting()
            }
            await manager.debugSetDuringAdmissionEvictionCloseForTesting(nil)

            let capacityReliefRemovalStarted = await capacityReliefStopGate.hasStarted()
            let victimRetained = await manager.debugContainsConnection(victimID)
            let originalOrdinarySnapshot = await originalOrdinary.debugSnapshot()
            let originalFileSearchSnapshot = await originalFileSearch.debugSnapshot()
            let registeredOrdinary = await manager.connectionLimiterSnapshotForTesting(
                connectionID: victimID,
                lane: .ordinary
            )
            let registeredFileSearch = await manager.connectionLimiterSnapshotForTesting(
                connectionID: victimID,
                lane: .fileSearch
            )
            XCTAssertTrue(admitted, file: file, line: line)
            XCTAssertTrue(capacityReliefRemovalStarted, file: file, line: line)
            XCTAssertTrue(
                victimRetained,
                "Capacity progress during atomic closure must preserve the unrelated candidate",
                file: file,
                line: line
            )
            XCTAssertTrue(originalOrdinarySnapshot.isClosed, file: file, line: line)
            XCTAssertTrue(originalFileSearchSnapshot.isClosed, file: file, line: line)
            XCTAssertFalse(registeredOrdinary?.isClosed ?? true, file: file, line: line)
            XCTAssertFalse(registeredFileSearch?.isClosed ?? true, file: file, line: line)

            if path == .direct {
                await manager.debugRemoveConnection(incomingConnectionID)
            }
            await capacityReliefStopGate.release()
            await assertCompletion(capacityReliefRemovalTask, description: "global during-close capacity relief")
            await manager.debugRemoveConnection(victimID)
            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: nil,
                preserveOnePerClient: nil
            )
        }

        private func assertAdmissionRechecksEffectiveCapacityAfterPreservationRollback(
            path: GlobalAdmissionPath,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let manager = ServerNetworkManager()
            let clientID = "admission-capacity-race-\(UUID().uuidString)"
            let victimID = UUID()
            let siblingID = UUID()
            let incomingConnectionID = UUID()
            let siblingStopGate = LimiterTestGate()
            let siblingRemovalTask = LimiterTestTaskStore()

            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: path == .direct ? 3 : 2,
                preserveOnePerClient: true
            )
            if path == .direct {
                await manager.debugInstallDirectAdmissionConnectionForTesting(
                    connectionID: incomingConnectionID,
                    connection: AdmissionEvictionTestConnection(idleSeconds: 0)
                )
            }
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: victimID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 120),
                clientID: clientID,
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: siblingID,
                connection: AdmissionEvictionTestConnection(
                    idleSeconds: 10,
                    stopGate: siblingStopGate
                ),
                clientID: clientID,
                totalToolCalls: 1,
                createdAt: Date()
            )
            let installedOrdinary = await manager.limiter(for: victimID, lane: .ordinary)
            let installedFileSearch = await manager.limiter(for: victimID, lane: .fileSearch)
            let originalOrdinary = try XCTUnwrap(installedOrdinary, file: file, line: line)
            let originalFileSearch = try XCTUnwrap(installedFileSearch, file: file, line: line)

            await manager.debugSetDuringAdmissionEvictionCloseForTesting { candidateID in
                guard candidateID == victimID else { return }
                await siblingRemovalTask.start {
                    await manager.debugRemoveConnection(siblingID)
                }
                guard await siblingStopGate.waitUntilStarted(timeout: .seconds(2)) else { return }
            }

            let admitted: Bool = switch path {
            case .direct:
                await manager.tryReserveConnectionSlot(
                    connectionID: incomingConnectionID,
                    clientID: "incoming-direct-\(UUID().uuidString)"
                )
            case .bootstrap:
                await manager.debugBootstrapAdmissionHasCapacityForTesting()
            }
            await manager.debugSetDuringAdmissionEvictionCloseForTesting(nil)

            XCTAssertTrue(
                admitted,
                "Admission must recheck capacity after rollback instead of rejecting on no victim eviction",
                file: file,
                line: line
            )
            let effectiveCount = await manager.debugEffectiveRegisteredConnectionCountForTesting()
            let siblingRemovalStarted = await siblingStopGate.hasStarted()
            XCTAssertTrue(
                siblingRemovalStarted,
                "Timed out waiting for sibling removal to reach stop() during admission",
                file: file,
                line: line
            )
            XCTAssertEqual(effectiveCount, path == .direct ? 2 : 1, file: file, line: line)
            let retainedVictim = await manager.debugContainsConnection(victimID)
            let retainedRemovingSibling = await manager.debugContainsConnection(siblingID)
            XCTAssertTrue(retainedVictim, file: file, line: line)
            XCTAssertTrue(retainedRemovingSibling, file: file, line: line)
            let originalOrdinarySnapshot = await originalOrdinary.debugSnapshot()
            let originalFileSearchSnapshot = await originalFileSearch.debugSnapshot()
            XCTAssertTrue(originalOrdinarySnapshot.isClosed, file: file, line: line)
            XCTAssertTrue(originalFileSearchSnapshot.isClosed, file: file, line: line)
            let restoredOrdinary = await manager.connectionLimiterSnapshotForTesting(
                connectionID: victimID,
                lane: .ordinary
            )
            let restoredFileSearch = await manager.connectionLimiterSnapshotForTesting(
                connectionID: victimID,
                lane: .fileSearch
            )
            XCTAssertFalse(restoredOrdinary?.isClosed ?? true, file: file, line: line)
            XCTAssertFalse(restoredFileSearch?.isClosed ?? true, file: file, line: line)

            if path == .direct {
                await manager.debugRemoveConnection(incomingConnectionID)
            }
            await siblingStopGate.release()
            await assertCompletion(siblingRemovalTask, description: "sibling removal")
            await manager.debugRemoveConnection(victimID)
            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: nil,
                preserveOnePerClient: nil
            )
        }

        private func assertAdmissionRejectsWhenEffectiveLiveCapacityRemainsFull(
            path: GlobalAdmissionPath,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            let manager = ServerNetworkManager()
            let existingConnectionID = UUID()
            let incomingConnectionID = UUID()
            let busyGate = LimiterTestGate()

            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: path == .direct ? 2 : 1,
                preserveOnePerClient: true
            )
            if path == .direct {
                await manager.debugInstallDirectAdmissionConnectionForTesting(
                    connectionID: incomingConnectionID,
                    connection: AdmissionEvictionTestConnection(idleSeconds: 0)
                )
            }
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: existingConnectionID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 120),
                clientID: "admission-full-\(UUID().uuidString)",
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            let busyTask = Task {
                try? await manager.withConnectionCallPermitForTesting(
                    connectionID: existingConnectionID,
                    lane: .ordinary
                ) {
                    await busyGate.markStartedAndWaitForRelease()
                }
            }
            await assertStarted(busyGate, description: "busy connection")

            let admitted: Bool = switch path {
            case .direct:
                await manager.tryReserveConnectionSlot(
                    connectionID: incomingConnectionID,
                    clientID: "incoming-full-\(UUID().uuidString)"
                )
            case .bootstrap:
                await manager.debugBootstrapAdmissionHasCapacityForTesting()
            }

            XCTAssertFalse(
                admitted,
                "Admission must reject while effective live capacity remains full",
                file: file,
                line: line
            )
            let effectiveCount = await manager.debugEffectiveRegisteredConnectionCountForTesting()
            XCTAssertEqual(effectiveCount, path == .direct ? 2 : 1, file: file, line: line)
            let retainedExisting = await manager.debugContainsConnection(existingConnectionID)
            XCTAssertTrue(retainedExisting, file: file, line: line)

            await busyGate.release()
            await assertCompletion(busyTask, description: "busy connection task")
            if path == .direct {
                await manager.debugRemoveConnection(incomingConnectionID)
            }
            await manager.debugRemoveConnection(existingConnectionID)
            await manager.debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: nil,
                preserveOnePerClient: nil
            )
        }

        private enum AdmissionEvictionScope {
            case perClient
            case global
        }

        private func assertAdmissionEvictionFallsBackToNextCandidate(
            scope: AdmissionEvictionScope,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            let manager = ServerNetworkManager()
            let clientID = "admission-eviction-fallback-\(UUID().uuidString)"
            let firstCandidateID = UUID()
            let secondCandidateID = UUID()
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: firstCandidateID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 120),
                clientID: clientID,
                totalToolCalls: 0,
                createdAt: .distantPast
            )
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: secondCandidateID,
                connection: AdmissionEvictionTestConnection(idleSeconds: 60),
                clientID: clientID,
                totalToolCalls: 1,
                createdAt: Date()
            )

            let busyGate = LimiterTestGate()
            await manager.debugSetBeforeAdmissionEvictionCloseForTesting { candidateID in
                guard candidateID == firstCandidateID else { return }
                Task {
                    try? await manager.withConnectionCallPermitForTesting(
                        connectionID: firstCandidateID,
                        lane: .ordinary
                    ) {
                        await busyGate.markStartedAndWaitForRelease()
                    }
                }
                guard await busyGate.waitUntilStarted(timeout: .seconds(2)) else { return }
            }

            let didEvict: Bool = switch scope {
            case .perClient:
                await manager.debugEvictLeastValuableForTesting(clientID: clientID)
            case .global:
                await manager.debugEvictLeastValuableGlobalForAdmissionForTesting(
                    preserveOnePerClient: false
                )
            }

            let retainedBusyCandidate = await manager.debugContainsConnection(firstCandidateID)
            let removedFallbackCandidate = await manager.debugContainsConnection(secondCandidateID)
            XCTAssertTrue(didEvict, file: file, line: line)
            XCTAssertTrue(retainedBusyCandidate, file: file, line: line)
            XCTAssertFalse(
                removedFallbackCandidate,
                "Eviction should continue to the next sorted candidate when the first became busy",
                file: file,
                line: line
            )

            await manager.debugSetBeforeAdmissionEvictionCloseForTesting(nil)
            await busyGate.release()
            await manager.debugRemoveConnection(firstCandidateID)
            await manager.debugRemoveConnection(secondCandidateID)
        }

        private func waitForAdmissionRetryWaiterCount(
            manager: ServerNetworkManager,
            connectionID: UUID,
            expectedCount: Int,
            timeout: Duration = .seconds(2)
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if await manager.connectionCallAdmissionRetryWaiterCountForTesting(connectionID) == expectedCount {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return await manager.connectionCallAdmissionRetryWaiterCountForTesting(connectionID) == expectedCount
        }

        private func waitForSnapshot(
            of limiter: AsyncLimiter,
            timeout: Duration = .seconds(2),
            matching predicate: @escaping @Sendable (AsyncLimiter.DebugSnapshot) -> Bool
        ) async -> AsyncLimiter.DebugSnapshot? {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                let snapshot = await limiter.debugSnapshot()
                if predicate(snapshot) { return snapshot }
                try? await Task.sleep(for: .milliseconds(5))
            }
            let snapshot = await limiter.debugSnapshot()
            return predicate(snapshot) ? snapshot : nil
        }

        private func boundedValue<Success>(
            of task: Task<Success, some Error>,
            timeout: Duration = .seconds(2),
            description: String
        ) async throws -> Success {
            let result = LimiterTaskResultBox<Success>()
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
            throw LimiterTestTimeoutError(description: description)
        }

        private func diagnosticsPayload(_ result: CallTool.Result) throws -> [String: Any] {
            let text = result.content.compactMap { content -> String? in
                if case let .text(text, _, _) = content { return text }
                return nil
            }.joined()
            let data = try XCTUnwrap(text.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        private func assertStarted(
            _ gate: LimiterTestGate,
            description: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            let started = await gate.waitUntilStarted(timeout: .seconds(2))
            XCTAssertTrue(started, "Timed out waiting for \(description)", file: file, line: line)
        }

        private func assertCompletion(
            _ taskStore: LimiterTestTaskStore,
            description: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            let completed = await taskStore.wait()
            XCTAssertTrue(completed, "Timed out waiting for \(description)", file: file, line: line)
        }

        private func assertSuccess(
            _ task: Task<Void, Error>,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                _ = try await boundedValue(of: task, description: "successful task")
            } catch {
                XCTFail("Expected task success, got \(error)", file: file, line: line)
            }
        }

        private func assertCompletion(
            _ task: Task<some Any, Never>,
            description: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                _ = try await boundedValue(of: task, description: description)
            } catch {
                XCTFail("Timed out waiting for \(description): \(error)", file: file, line: line)
            }
        }

        private func assertCancellation(
            _ task: Task<Void, Error>,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                _ = try await boundedValue(of: task, description: "task cancellation")
                XCTFail("Expected CancellationError", file: file, line: line)
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("Expected CancellationError, got \(error)", file: file, line: line)
            }
        }

        private func assertIdle(
            _ snapshot: AsyncLimiter.DebugSnapshot,
            cancelledWaiterCount: Int,
            isClosed: Bool,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertEqual(snapshot.permits, snapshot.limit, file: file, line: line)
            XCTAssertEqual(snapshot.activePermitCount, 0, file: file, line: line)
            XCTAssertEqual(snapshot.waiterCount, 0, file: file, line: line)
            XCTAssertEqual(snapshot.inFlight, 0, file: file, line: line)
            XCTAssertEqual(snapshot.cancelledWaiterCount, cancelledWaiterCount, file: file, line: line)
            XCTAssertEqual(snapshot.isClosed, isClosed, file: file, line: line)
            XCTAssertTrue(snapshot.isIdle, file: file, line: line)
        }
    }

    private struct LimiterTestTimeoutError: Error, CustomStringConvertible {
        let description: String
    }

    private final class LimiterTaskResultBox<Success>: @unchecked Sendable {
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

    private actor AdmissionEvictionTestConnection: MCPServerConnection {
        private let idleSeconds: TimeInterval
        private let stopGate: LimiterTestGate?

        init(idleSeconds: TimeInterval, stopGate: LimiterTestGate? = nil) {
            self.idleSeconds = idleSeconds
            self.stopGate = stopGate
        }

        nonisolated var isFilesystemBacked: Bool {
            false
        }

        nonisolated var connectionFolderURL: URL? {
            nil
        }

        nonisolated var capabilityToken: String? {
            nil
        }

        func start(approvalHandler _: @escaping (MCP.Client.Info) async -> Bool) async throws {}
        func stop() async {
            await stopGate?.markStartedAndWaitForRelease()
        }

        func abortForExecutionWatchdog() async {}
        func notifyToolListChanged() async {}
        func connectionState() -> ConnectionStateSnapshot {
            .ready
        }

        func isViableForRetention() -> Bool {
            true
        }

        func secondsSinceLastActivity() async -> TimeInterval {
            idleSeconds
        }

        func transportIngressSnapshot() async -> MCPTransportIngressSnapshot? {
            nil
        }

        func terminate(reason _: TerminationReason, message _: String?) async {}
        func sendProgress(
            tool _: String,
            kind _: RepoPromptProgressKind,
            stage _: String,
            message _: String
        ) async {}
    }

    private actor LimiterTestGate {
        private var started = false
        private var released = false
        private var startedWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markStartedAndWaitForRelease() async {
            started = true
            let startedWaiters = startedWaiters.values
            self.startedWaiters.removeAll()
            for waiter in startedWaiters {
                waiter.resume(returning: true)
            }
            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        @discardableResult
        func waitUntilStarted(timeout: Duration? = nil) async -> Bool {
            guard !started else { return true }
            let waiterID = UUID()
            return await withCheckedContinuation { continuation in
                startedWaiters[waiterID] = continuation
                if let timeout {
                    Task {
                        try? await Task.sleep(for: timeout)
                        await self.timeoutStartedWaiter(waiterID)
                    }
                }
            }
        }

        func hasStarted() -> Bool {
            started
        }

        private func timeoutStartedWaiter(_ waiterID: UUID) {
            startedWaiters.removeValue(forKey: waiterID)?.resume(returning: false)
        }

        func release() {
            guard !released else { return }
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    private actor LimiterTestCounter {
        private struct Waiter {
            let target: Int
            let continuation: CheckedContinuation<Int?, Never>
        }

        private var value = 0
        private var waiters: [UUID: Waiter] = [:]

        func increment() {
            value += 1
            let readyIDs = waiters.compactMap { waiterID, waiter in
                value >= waiter.target ? waiterID : nil
            }
            for waiterID in readyIDs {
                waiters.removeValue(forKey: waiterID)?.continuation.resume(returning: value)
            }
        }

        func waitUntil(_ target: Int, timeout: Duration) async -> Int? {
            if value >= target { return value }
            let waiterID = UUID()
            return await withCheckedContinuation { continuation in
                waiters[waiterID] = Waiter(target: target, continuation: continuation)
                Task {
                    try? await Task.sleep(for: timeout)
                    await self.timeoutWaiter(waiterID)
                }
            }
        }

        private func timeoutWaiter(_ waiterID: UUID) {
            waiters.removeValue(forKey: waiterID)?.continuation.resume(returning: nil)
        }
    }

    private actor LimiterTestTaskStore {
        private var task: Task<Void, Never>?

        func start(_ operation: @escaping @Sendable () async -> Void) {
            guard task == nil else { return }
            task = Task {
                await operation()
            }
        }

        func wait(timeout: Duration = .seconds(2)) async -> Bool {
            guard let task else { return true }
            let completed = LimiterLockedFlag()
            let observer = Task {
                await task.value
                completed.mark()
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while !completed.isMarked(), clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            guard completed.isMarked() else {
                task.cancel()
                observer.cancel()
                return false
            }
            observer.cancel()
            return true
        }
    }

    private final class LimiterLockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var marked = false

        func mark() {
            lock.lock()
            marked = true
            lock.unlock()
        }

        func isMarked() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return marked
        }
    }

    private actor LimiterOrderRecorder {
        private var recordedValues: [Int] = []

        func append(_ value: Int) {
            recordedValues.append(value)
        }

        func values() -> [Int] {
            recordedValues
        }
    }

    private actor LimiterTestFlag {
        private var marked = false

        func mark() {
            marked = true
        }

        func markIfUnmarked() -> Bool {
            guard !marked else { return false }
            marked = true
            return true
        }

        func isMarked() -> Bool {
            marked
        }
    }

    private actor LimiterSnapshotSignal {
        typealias Snapshot = AsyncLimiter.DebugSnapshot

        private var latest: Snapshot?
        private var waiter: (
            predicate: @Sendable (Snapshot) -> Bool,
            continuation: CheckedContinuation<Snapshot, Never>
        )?

        func record(_ snapshot: Snapshot) {
            latest = snapshot
            guard let waiter, waiter.predicate(snapshot) else { return }
            self.waiter = nil
            waiter.continuation.resume(returning: snapshot)
        }

        func waitUntil(
            _ predicate: @escaping @Sendable (Snapshot) -> Bool
        ) async -> Snapshot {
            if let latest, predicate(latest) {
                return latest
            }
            return await withCheckedContinuation { continuation in
                waiter = (predicate, continuation)
            }
        }
    }
#endif
