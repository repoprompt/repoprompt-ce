import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

final class AgentRunLifecycleIntegrationTests: XCTestCase {
    @MainActor
    func testSessionLivenessDoesNotCreateTranscriptOrContextBuilderLogRows() {
        let agentSession = AgentModeViewModel.TabSession(tabID: UUID())
        let agentOwnership = agentSession.beginRunAttempt(source: "test")
        agentSession.recordRunProgress(
            ownership: agentOwnership,
            kind: .heartbeat,
            stage: .running
        )
        XCTAssertTrue(agentSession.items.isEmpty)

        let contextBuilderSession = ContextBuilderAgentViewModel.TabSession(tabID: UUID())
        let contextOwnership = contextBuilderSession.beginRunAttempt(source: "test")
        contextBuilderSession.recordRunProgress(
            ownership: contextOwnership,
            kind: .providerEvent,
            stage: .running
        )
        let replacementOwnership = contextBuilderSession.beginRunAttempt(source: "test.replacement")
        XCTAssertFalse(contextBuilderSession.endRunAttempt(ifCurrent: contextOwnership, source: "test.staleCleanup"))
        XCTAssertEqual(contextBuilderSession.activeRunOwnership, replacementOwnership)
        XCTAssertTrue(contextBuilderSession.endRunAttempt(ifCurrent: replacementOwnership, source: "test.cleanup"))
        XCTAssertNil(contextBuilderSession.activeRunOwnership)
        XCTAssertTrue(contextBuilderSession.agentLog.isEmpty)
    }
}

final class HeadlessAgentConnectionGateDeadlineTests: XCTestCase {
    func testLeaseAcquireTimeoutFinalizesAsVisibleFailureNotCancel() {
        let timeout = MCPBootstrapLeaseAcquireFailureOutcome(timedOut: true)
        XCTAssertEqual(timeout.terminalState, .failed)
        XCTAssertEqual(timeout.errorText, HeadlessAgentConnectionAcquireTimeoutError().localizedDescription)

        let cancel = MCPBootstrapLeaseAcquireFailureOutcome(timedOut: false)
        XCTAssertEqual(cancel.terminalState, .cancelled)
        XCTAssertNil(cancel.errorText)
    }

    func testExpiredWaitRemovesOnlyWaiterAndPreservesOwner() async {
        let gate = HeadlessAgentConnectionGate()
        let owner = UUID()
        let acquired = await gate.acquire(owner)
        XCTAssertTrue(acquired)
        let result = await gate.acquireWithDiagnostics(UUID(), deadline: .zero)
        XCTAssertFalse(result.acquired)
        XCTAssertTrue(result.timedOut)
        let snapshot = await gate.snapshot()
        XCTAssertEqual(snapshot.activeConnectionID, owner)
        XCTAssertEqual(snapshot.queueDepth, 0)
        await gate.completeConnection(owner)
        let successor = await gate.acquire(UUID())
        XCTAssertTrue(successor)
        await gate.cancelAll()
    }

    func testCancellationDoesNotBecomeTimeoutOrReleaseOwner() async throws {
        let gate = HeadlessAgentConnectionGate()
        let owner = UUID()
        _ = await gate.acquire(owner)
        let waiter = Task { await gate.acquireWithDiagnostics(UUID(), deadline: .seconds(60)) }
        try await AsyncTestWait.waitUntil("gate waiter enqueued") {
            await gate.snapshot().queueDepth == 1
        }
        waiter.cancel()
        let result = await waiter.value
        XCTAssertFalse(result.acquired)
        XCTAssertFalse(result.timedOut)
        let snapshot = await gate.snapshot()
        XCTAssertEqual(snapshot.activeConnectionID, owner)
        XCTAssertEqual(snapshot.queueDepth, 0)
        await gate.cancelAll()
    }

    func testReleaseHandsOffBeforeDeadlineAndClearsWaiter() async throws {
        let gate = HeadlessAgentConnectionGate()
        let owner = UUID()
        let successor = UUID()
        _ = await gate.acquire(owner)
        let waiter = Task { await gate.acquireWithDiagnostics(successor, deadline: .seconds(60)) }
        try await AsyncTestWait.waitUntil("gate waiter enqueued") {
            await gate.snapshot().queueDepth == 1
        }
        await gate.completeConnection(owner)
        let result = await waiter.value
        XCTAssertTrue(result.acquired)
        XCTAssertFalse(result.timedOut)
        let snapshot = await gate.snapshot()
        XCTAssertEqual(snapshot.activeConnectionID, successor)
        XCTAssertEqual(snapshot.queueDepth, 0)
        await gate.cancelAll()
    }

    func testCancelledHandoffWakesNextWaiterWithoutWaitingForDeadline() async throws {
        let gate = HeadlessAgentConnectionGate()
        let owner = UUID()
        let successor = UUID()
        _ = await gate.acquire(owner)
        let first = Task { await gate.acquireWithDiagnostics(UUID(), deadline: .seconds(60)) }
        try await AsyncTestWait.waitUntil("first gate waiter enqueued") {
            await gate.snapshot().queueDepth == 1
        }
        let second = Task { await gate.acquireWithDiagnostics(successor, deadline: .seconds(60)) }
        try await AsyncTestWait.waitUntil("second gate waiter enqueued") {
            await gate.snapshot().queueDepth == 2
        }
        // Both operations run in one actor turn, before the first waiter can reclaim it.
        await gate.debugCompleteConnectionAndCancelWaiter(owner, waiter: first)
        let cancelled = await first.value
        let acquired = await second.value
        XCTAssertFalse(cancelled.acquired)
        XCTAssertFalse(cancelled.timedOut)
        XCTAssertTrue(acquired.acquired)
        XCTAssertFalse(acquired.timedOut)
        let snapshot = await gate.snapshot()
        XCTAssertEqual(snapshot.activeConnectionID, successor)
        XCTAssertEqual(snapshot.queueDepth, 0)
        await gate.cancelAll()
    }
}
