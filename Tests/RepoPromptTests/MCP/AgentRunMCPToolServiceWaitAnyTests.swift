import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class AgentRunMCPToolServiceWaitAnyTests: XCTestCase {
    private enum TestFailure: Error {
        case missingEpoch
    }

    func testWaitAnyConsumesSteeringWakeAndContinuesToTerminalSnapshot() async throws {
        let sessionID = UUID()
        let activationID = UUID()
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)
        let epoch = try await beginEpoch(
            registration: registration,
            activationID: activationID,
            expected: nil,
            kind: .initial
        )
        let cursor = AgentRunSessionStore.WaitCursor(registration: registration, epoch: epoch)

        let waitTask = Task {
            await AgentRunMCPToolService.test_waitUntilActionableDisposition(
                sessionID: sessionID,
                timeoutSeconds: 1
            )
        }
        try await waitForWaiter(registration: registration)

        await AgentRunSessionStore.wakeCurrentWaiters(
            makeRunningSnapshot(sessionID: sessionID),
            cursor: cursor,
            reason: .steeringRequested
        )
        try await waitForWaiter(registration: registration)
        let terminal = makeSnapshot(sessionID: sessionID, status: .completed)
        _ = await AgentRunSessionStore.publishTerminal(
            .init(epoch: epoch, snapshot: terminal),
            registration: registration,
            commitID: UUID(),
            successorKind: nil
        )

        let result = await waitTask.value
        XCTAssertEqual(result.sessionID, sessionID)
        XCTAssertEqual(result.disposition, "actionable")
        XCTAssertNil(result.wakeReason)
        XCTAssertEqual(result.snapshotStatus, AgentRunMCPSnapshot.Status.completed.rawValue)
        await AgentRunSessionStore.cleanup(registration: registration)
    }

    func testWaitAnyRebindsRelatedEpochAndSurfacesUnrelatedSupersession() async throws {
        let sessionID = UUID()
        let activationID = UUID()
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)
        let first = try await beginEpoch(
            registration: registration,
            activationID: activationID,
            expected: nil,
            kind: .initial
        )
        let waitTask = Task {
            await AgentRunMCPToolService.test_waitUntilActionableDisposition(
                sessionID: sessionID,
                timeoutSeconds: 1
            )
        }
        try await waitForWaiter(registration: registration)

        let related = try await beginEpoch(
            registration: registration,
            activationID: activationID,
            expected: first,
            kind: .relatedFollowUp
        )
        try await waitForWaiter(registration: registration)
        _ = await AgentRunSessionStore.beginEpoch(
            registration: registration,
            activationID: activationID,
            expectedCurrentEpoch: related,
            transitionKind: .unrelated
        )

        let result = await waitTask.value
        XCTAssertEqual(result.disposition, "superseded")
        XCTAssertEqual(result.wakeReason, "superseded_turn")
        await AgentRunSessionStore.cleanup(registration: registration)
    }

    func testSingleSessionWaitPreservesOriginalTimeoutAcrossMultipleRelatedEpochs() async throws {
        let sessionID = UUID()
        let activationID = UUID()
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)
        let first = try await beginEpoch(
            registration: registration,
            activationID: activationID,
            expected: nil,
            kind: .initial
        )
        let waitTask = Task {
            await AgentRunMCPToolService.test_waitUntilActionableDisposition(
                sessionID: sessionID,
                timeoutSeconds: 0.1
            )
        }
        try await waitForWaiter(registration: registration)
        let second = try await beginEpoch(
            registration: registration,
            activationID: activationID,
            expected: first,
            kind: .relatedFollowUp
        )
        try await waitForWaiter(registration: registration)
        _ = try await beginEpoch(
            registration: registration,
            activationID: activationID,
            expected: second,
            kind: .relatedFollowUp
        )

        let result = await waitTask.value
        XCTAssertEqual(result.disposition, "timed_out")
        XCTAssertNil(result.wakeReason)
        await AgentRunSessionStore.cleanup(registration: registration)
    }

    func testExpiredWaitMetadataDoesNotClaimTurnSupersession() throws {
        let value = AgentRunMCPToolService.test_expiredWaitValue(sessionID: UUID())
        let object = try XCTUnwrap(value.objectValue)
        let meta = try XCTUnwrap(object["_meta"]?.objectValue)
        XCTAssertEqual(meta["wait_result"]?.stringValue, "expired")
        XCTAssertNil(meta["wake_reason"])
    }

    func testWaitAnySteeringInterruptValueShapeOmitsNonTerminalAssistantText() throws {
        let firstID = UUID()
        let secondID = UUID()
        let value = AgentRunMCPToolService.test_decoratedMultiWaitInterruptValue(
            sessionIDs: [firstID, secondID],
            snapshots: [
                makeRunningSnapshot(sessionID: firstID),
                makeRunningSnapshot(sessionID: secondID)
            ],
            pendingSessionIDs: [firstID, secondID]
        )

        let object = try XCTUnwrap(value.objectValue)
        let meta = try XCTUnwrap(object["_meta"]?.objectValue)
        let wait = try XCTUnwrap(object["wait"]?.objectValue)
        XCTAssertEqual(meta["wake_reason"]?.stringValue, AgentRunSessionStore.WakeReason.steeringRequested.rawValue)
        XCTAssertEqual(wait["mode"]?.stringValue, "any")
        XCTAssertEqual(wait["result"]?.stringValue, "interrupted_by_steering")
        XCTAssertNil(wait["winner_session_id"]?.stringValue)
        XCTAssertEqual(
            Set(wait["pending_session_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []),
            Set([firstID.uuidString, secondID.uuidString])
        )
        XCTAssertNil(object["assistant_text"])
        let snapshots = try XCTUnwrap(object["snapshots"]?.arrayValue)
        for snapshot in snapshots {
            XCTAssertNil(snapshot.objectValue?["assistant_text"])
        }
    }

    private func beginEpoch(
        registration: AgentRunSessionStore.Registration,
        activationID: UUID,
        expected: AgentRunTurnEpoch?,
        kind: AgentRunEpochTransitionKind
    ) async throws -> AgentRunTurnEpoch {
        let result = await AgentRunSessionStore.beginEpoch(
            registration: registration,
            activationID: activationID,
            expectedCurrentEpoch: expected,
            transitionKind: kind
        )
        guard case let .accepted(epoch) = result else {
            XCTFail("Expected accepted epoch, got \(result)")
            throw TestFailure.missingEpoch
        }
        return epoch
    }

    private func waitForWaiter(registration: AgentRunSessionStore.Registration) async throws {
        for _ in 0 ..< 200 {
            if await AgentRunSessionStore.shared.test_waiterCount(registration: registration) == 1 {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for waiter")
    }

    private func makeRunningSnapshot(sessionID: UUID) -> AgentRunMCPSnapshot {
        makeSnapshot(sessionID: sessionID, status: .running)
    }

    private func makeSnapshot(
        sessionID: UUID,
        status: AgentRunMCPSnapshot.Status
    ) -> AgentRunMCPSnapshot {
        AgentRunMCPSnapshot(
            sessionID: sessionID,
            tabID: nil,
            sessionName: "Child Agent",
            agentRaw: AgentProviderKind.codexExec.rawValue,
            agentDisplayName: AgentProviderKind.codexExec.displayName,
            modelRaw: "codex",
            reasoningEffortRaw: nil,
            status: status,
            statusText: status.rawValue,
            latestAssistantPreview: status == .running ? "still working" : nil,
            interaction: nil,
            transcriptItemCount: 1,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: nil,
            worktreeBindings: [],
            activeWorktreeMerges: []
        )
    }
}
