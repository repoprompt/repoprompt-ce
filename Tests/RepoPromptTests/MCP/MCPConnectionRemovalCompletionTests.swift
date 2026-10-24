import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

#if DEBUG
    @MainActor
    final class MCPConnectionRemovalCompletionTests: XCTestCase {
        func testDebugCleanupJoinsInFlightRemovalBeforeReadingAdmissionState() async {
            let manager = ServerNetworkManager(domainHost: AppDomainRuntimeComposition.shared.runtime.domainHost)
            let id = UUID()
            let clientID = "cleanup-owner-test"
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: id,
                connection: RemovalTestConnection(),
                clientID: clientID,
                totalToolCalls: 1,
                createdAt: Date(timeIntervalSince1970: 1234)
            )
            let gate = RemovalGate()
            let ownerPaused = expectation(description: "removal owner paused before registry cleanup")
            await manager.debugSetBeforeActiveToolCancellationScanForTesting { connectionID, _ in
                guard connectionID == id else { return }
                ownerPaused.fulfill()
                await gate.wait()
            }
            let owner = Task { await manager.removeConnection(id) }
            await fulfillment(of: [ownerPaused], timeout: 5)

            // Reproduce the original harness mistake deterministically: requesting a
            // duplicate removal is not a completion barrier for the existing owner.
            await manager.removeConnection(id)
            let before = await manager.debugDirectAdmissionStateForTesting(connectionID: id)
            XCTAssertEqual(before.indexedClientID, clientID)
            XCTAssertEqual(before.activeClientIDs, [clientID])
            XCTAssertTrue(before.hasStats)
            XCTAssertNotNil(before.connectionLifecycleGeneration)

            let joined = expectation(description: "debug cleanup joined the exact removal owner")
            var duplicateFinished = false
            let duplicate = Task {
                await manager.debugRemoveConnection(id, onJoiningRemoval: { joined.fulfill() })
                duplicateFinished = true
            }
            await fulfillment(of: [joined], timeout: 5)
            let waiting = await manager.debugConnectionRemovalWaiterCount(for: id)
            XCTAssertEqual(waiting, 1)
            XCTAssertFalse(duplicateFinished)

            gate.release()
            await owner.value
            await duplicate.value
            await manager.debugSetBeforeActiveToolCancellationScanForTesting(nil)
            let after = await manager.debugDirectAdmissionStateForTesting(connectionID: id)
            XCTAssertTrue(duplicateFinished)
            XCTAssertNil(after.pendingClientID)
            XCTAssertNil(after.indexedClientID)
            XCTAssertTrue(after.activeClientIDs.isEmpty)
            XCTAssertFalse(after.hasStats)
            XCTAssertNil(after.connectionLifecycleGeneration)
            let remainingWaiters = await manager.debugConnectionRemovalWaiterCount(for: id)
            XCTAssertEqual(remainingWaiters, 0)
            let hasOperation = await manager.debugHasConnectionRemovalOperation(for: id)
            XCTAssertFalse(hasOperation)
            let history = await manager.debugConnectionHistoryPayload(
                limit: 200, clientName: nil, sessionFingerprint: nil, connectionID: id
            )
            let events = history["events"] as? [[String: Any]] ?? []
            XCTAssertEqual(events.count(where: { $0["event"] as? String == "removed" }), 1)
            // Already-finished cleanup remains idempotent and does not install a waiter.
            await manager.debugRemoveConnection(id)
            let finalWaiters = await manager.debugConnectionRemovalWaiterCount(for: id)
            XCTAssertEqual(finalWaiters, 0)
        }

        func testDebugCleanupFinishesWhenStopInvalidatesCommittedRemoval() async {
            let manager = ServerNetworkManager(domainHost: AppDomainRuntimeComposition.shared.runtime.domainHost)
            let id = UUID()
            let clientID = "invalidated-cleanup-owner-test"
            await manager.debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: id,
                connection: RemovalTestConnection(),
                clientID: clientID,
                totalToolCalls: 1,
                createdAt: Date(timeIntervalSince1970: 1234)
            )
            let gate = RemovalGate()
            let committed = expectation(description: "eviction committed before removal body entry")
            await manager.debugSetAfterAdmissionEvictionRemovalCommittedForTesting { connectionID in
                guard connectionID == id else { return }
                committed.fulfill()
                await gate.wait()
            }
            let eviction = Task { await manager.debugEvictLeastValuableForTesting(clientID: clientID) }
            await fulfillment(of: [committed], timeout: 5)
            let joined = expectation(description: "debug cleanup joined the committed operation")
            var cleanupFinished = false
            let cleanup = Task {
                await manager.debugRemoveConnection(id, onJoiningRemoval: { joined.fulfill() })
                cleanupFinished = true
            }
            await fulfillment(of: [joined], timeout: 5)
            let waiting = await manager.debugConnectionRemovalWaiterCount(for: id)
            XCTAssertEqual(waiting, 1)
            XCTAssertFalse(cleanupFinished)

            await manager.stop()
            // Stop invalidates the committed identity, but completion belongs to the
            // exact parked operation. It must finish when that owner rejects its commit.
            XCTAssertFalse(cleanupFinished)
            gate.release()
            _ = await eviction.value
            await cleanup.value
            await manager.debugSetAfterAdmissionEvictionRemovalCommittedForTesting(nil)
            XCTAssertTrue(cleanupFinished)
            let after = await manager.debugDirectAdmissionStateForTesting(connectionID: id)
            XCTAssertNil(after.pendingClientID)
            XCTAssertNil(after.indexedClientID)
            XCTAssertTrue(after.activeClientIDs.isEmpty)
            XCTAssertFalse(after.hasStats)
            XCTAssertNil(after.connectionLifecycleGeneration)
            let remainingWaiters = await manager.debugConnectionRemovalWaiterCount(for: id)
            let hasOperation = await manager.debugHasConnectionRemovalOperation(for: id)
            XCTAssertEqual(remainingWaiters, 0)
            XCTAssertFalse(hasOperation)
            await manager.debugRemoveConnection(id)
        }

        @MainActor
        private final class RemovalGate {
            private var released = false
            private var waiters: [CheckedContinuation<Void, Never>] = []

            func wait() async {
                guard !released else { return }
                await withCheckedContinuation { waiters.append($0) }
            }

            func release() {
                released = true
                let pending = waiters
                waiters.removeAll()
                pending.forEach { $0.resume() }
            }
        }
    }

    private actor RemovalTestConnection: MCPServerConnection {
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
        func stop() async {}
        func abortForExecutionWatchdog(context _: MCPExecutionWatchdogTerminalContext) async {}
        func notifyToolListChanged() async {}
        func connectionState() -> ConnectionStateSnapshot {
            .ready
        }

        func isViableForRetention() -> Bool {
            true
        }

        func secondsSinceLastActivity() async -> TimeInterval {
            0
        }

        func transportIngressSnapshot() async -> MCPTransportIngressSnapshot? {
            nil
        }

        func terminate(reason _: TerminationReason, message _: String?) async {}
        func sendProgress(tool _: String, kind _: RepoPromptProgressKind, stage _: String, message _: String) async {}
    }
#endif
