import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class AgentRunMCPToolServiceWaitAnyTests: XCTestCase {
    private enum TestFailure: Error {
        case missingEpoch
    }

    func testWaitAnySteeringWakeInterruptsAndFreshWaitCanResume() async throws {
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

        let firstWait = Task {
            await AgentRunMCPToolService.test_waitUntilActionableDisposition(
                sessionID: sessionID,
                timeoutSeconds: 1
            )
        }
        try await waitForAgentRunSessionStoreWaiter(registration: registration)

        await AgentRunSessionStore.wakeCurrentWaiters(
            makeRunningSnapshot(sessionID: sessionID),
            cursor: cursor,
            reason: .steeringRequested
        )

        let interrupted = await firstWait.value
        XCTAssertEqual(interrupted.sessionID, sessionID)
        XCTAssertEqual(interrupted.disposition, "steering_interrupted")
        XCTAssertEqual(interrupted.wakeReason, AgentRunSessionStore.WakeReason.steeringRequested.rawValue)
        XCTAssertEqual(interrupted.snapshotStatus, AgentRunMCPSnapshot.Status.running.rawValue)

        let secondWait = Task {
            await AgentRunMCPToolService.test_waitUntilActionableDisposition(
                sessionID: sessionID,
                timeoutSeconds: 1
            )
        }
        try await waitForAgentRunSessionStoreWaiter(registration: registration)
        let terminal = makeSnapshot(sessionID: sessionID, status: .completed)
        _ = await AgentRunSessionStore.publishTerminal(
            .init(epoch: epoch, snapshot: terminal),
            registration: registration,
            commitID: UUID(),
            successorKind: nil
        )

        let resumed = await secondWait.value
        XCTAssertEqual(resumed.disposition, "actionable")
        XCTAssertNil(resumed.wakeReason)
        XCTAssertEqual(resumed.snapshotStatus, AgentRunMCPSnapshot.Status.completed.rawValue)
        await AgentRunSessionStore.cleanup(registration: registration)
    }

    func testWaitAnyInstructionDeliveredContinuesToTerminalSnapshot() async throws {
        let sessionID = UUID()
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)
        let epoch = try await beginEpoch(
            registration: registration,
            activationID: UUID(),
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
        try await waitForAgentRunSessionStoreWaiter(registration: registration)

        await AgentRunSessionStore.wakeCurrentWaiters(
            makeRunningSnapshot(sessionID: sessionID),
            cursor: cursor,
            reason: .instructionDelivered
        )
        try await waitForAgentRunSessionStoreWaiter(registration: registration)
        let terminal = makeSnapshot(sessionID: sessionID, status: .completed)
        _ = await AgentRunSessionStore.publishTerminal(
            .init(epoch: epoch, snapshot: terminal),
            registration: registration,
            commitID: UUID(),
            successorKind: nil
        )

        let result = await waitTask.value
        XCTAssertEqual(result.disposition, "actionable")
        XCTAssertNil(result.wakeReason)
        XCTAssertEqual(result.snapshotStatus, AgentRunMCPSnapshot.Status.completed.rawValue)
        await AgentRunSessionStore.cleanup(registration: registration)
    }

    func testWaitAnyMultiEngineReturnsSteeringInterruption() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let firstRegistration = await AgentRunSessionStore.register(sessionID: firstID)
        let secondRegistration = await AgentRunSessionStore.register(sessionID: secondID)
        let firstEpoch = try await beginEpoch(
            registration: firstRegistration,
            activationID: UUID(),
            expected: nil,
            kind: .initial
        )
        let secondEpoch = try await beginEpoch(
            registration: secondRegistration,
            activationID: UUID(),
            expected: nil,
            kind: .initial
        )
        let waitTask = Task {
            await AgentRunMCPToolService.test_waitUntilFirstActionableDisposition(
                sessionIDs: [firstID, secondID],
                timeoutSeconds: 1
            )
        }
        try await waitForAgentRunSessionStoreWaiter(registration: firstRegistration)
        try await waitForAgentRunSessionStoreWaiter(registration: secondRegistration)

        await AgentRunSessionStore.wakeCurrentWaiters(
            makeRunningSnapshot(sessionID: secondID),
            cursor: .init(registration: secondRegistration, epoch: secondEpoch),
            reason: .steeringRequested
        )

        let result = await waitTask.value
        XCTAssertEqual(result.sessionID, secondID)
        XCTAssertEqual(result.disposition, "steering_interrupted")
        let retainedFirstEpoch = await AgentRunSessionStore.currentEpoch(for: firstRegistration)
        XCTAssertEqual(retainedFirstEpoch, firstEpoch)
        await AgentRunSessionStore.cleanup(registration: firstRegistration)
        await AgentRunSessionStore.cleanup(registration: secondRegistration)
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
        try await waitForAgentRunSessionStoreWaiter(registration: registration)

        let steering = try await beginEpoch(
            registration: registration,
            activationID: activationID,
            expected: first,
            kind: .steering
        )
        try await waitForAgentRunSessionStoreWaiter(registration: registration)
        let related = try await beginEpoch(
            registration: registration,
            activationID: activationID,
            expected: steering,
            kind: .relatedFollowUp
        )
        try await waitForAgentRunSessionStoreWaiter(registration: registration)
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
        try await waitForAgentRunSessionStoreWaiter(registration: registration)
        let second = try await beginEpoch(
            registration: registration,
            activationID: activationID,
            expected: first,
            kind: .steering
        )
        try await waitForAgentRunSessionStoreWaiter(registration: registration)
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

        let statusText = try XCTUnwrap(object["status_text"]?.stringValue)
        XCTAssertFalse(statusText.isEmpty)
        XCTAssertTrue(statusText.contains("run/control/wait handle has expired"))
        XCTAssertTrue(statusText.contains("`agent_run`"))
        XCTAssertTrue(statusText.contains("`op: \"steer\"`"))
        XCTAssertTrue(statusText.contains("`session_id`"))
        XCTAssertTrue(statusText.contains("`message`"))
        XCTAssertFalse(statusText.contains("Start a new run or use a more recent session ID"))
    }

    func testWaitAnyCutoffExcludesSteeringProducedAfterSiblingCancellation() async {
        let actionableSessionID = UUID()
        let steeringSessionID = UUID()

        let result = await AgentRunMCPToolService.test_waitAnyCutoffExcludesPostCancellationSteering(
            actionableSessionID: actionableSessionID,
            steeringSessionID: steeringSessionID
        )

        XCTAssertEqual(result.sessionID, actionableSessionID)
        XCTAssertEqual(result.disposition, "actionable")
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
            pendingSessionIDs: [firstID, secondID],
            interruptedSessionID: secondID
        )

        let object = try XCTUnwrap(value.objectValue)
        let meta = try XCTUnwrap(object["_meta"]?.objectValue)
        let wait = try XCTUnwrap(object["wait"]?.objectValue)
        XCTAssertEqual(meta["wake_reason"]?.stringValue, AgentRunSessionStore.WakeReason.steeringRequested.rawValue)
        XCTAssertEqual(object["session_id"]?.stringValue, secondID.uuidString)
        XCTAssertEqual(wait["mode"]?.stringValue, "any")
        XCTAssertEqual(wait["result"]?.stringValue, "interrupted_by_steering")
        XCTAssertNil(wait["winner_session_id"]?.stringValue)
        XCTAssertEqual(wait["interrupted_session_id"]?.stringValue, secondID.uuidString)
        XCTAssertEqual(
            wait["pending_session_ids"]?.arrayValue?.compactMap(\.stringValue),
            [firstID.uuidString, secondID.uuidString]
        )
        XCTAssertNil(object["assistant_text"])
        let snapshots = try XCTUnwrap(object["snapshots"]?.arrayValue)
        for snapshot in snapshots {
            XCTAssertNil(snapshot.objectValue?["assistant_text"])
        }
    }

    func testWaitAnySteeringInterruptKeepsRunningTriggerAsRepresentativeWhenFreshSnapshotIsTerminal() throws {
        let interruptedID = UUID()
        let siblingID = UUID()
        let triggeringSnapshot = makeRunningSnapshot(sessionID: interruptedID)
        let terminalSnapshot = makeSnapshot(sessionID: interruptedID, status: .completed)
        let value = AgentRunMCPToolService.test_decoratedMultiWaitInterruptValue(
            sessionIDs: [interruptedID, siblingID],
            representativeSnapshot: triggeringSnapshot,
            snapshots: [terminalSnapshot, makeRunningSnapshot(sessionID: siblingID)],
            pendingSessionIDs: [siblingID],
            interruptedSessionID: interruptedID
        )

        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["session_id"]?.stringValue, interruptedID.uuidString)
        XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
        XCTAssertEqual(
            object["status_text"]?.stringValue,
            "Wait interrupted by a new steering instruction; the agent run is still running."
        )
        let snapshots = try XCTUnwrap(object["snapshots"]?.arrayValue)
        let interruptedAggregate = try XCTUnwrap(snapshots.first { snapshot in
            snapshot.objectValue?["session_id"]?.stringValue == interruptedID.uuidString
        }?.objectValue)
        XCTAssertEqual(interruptedAggregate["status"]?.stringValue, AgentRunMCPSnapshot.Status.completed.rawValue)
    }

    func testWaitAnyArbitrationLetsSteeringDominateCrossSessionActionableResult() {
        let firstID = UUID()
        let secondID = UUID()
        let result = AgentRunMCPToolService.test_arbitrateWaitAnyDisposition(
            sessionIDs: [firstID, secondID],
            candidates: [
                (firstID, "actionable"),
                (secondID, "steering_interrupted")
            ]
        )

        XCTAssertEqual(result.sessionID, secondID)
        XCTAssertEqual(result.disposition, "steering_interrupted")
    }

    func testWaitAnyArbitrationPrioritizesPublicationRejectionAndIgnoresCancellationArtifacts() {
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let result = AgentRunMCPToolService.test_arbitrateWaitAnyDisposition(
            sessionIDs: [firstID, secondID, thirdID],
            candidates: [
                (firstID, "cancelled"),
                (secondID, "steering_interrupted"),
                (thirdID, "publication_rejected")
            ]
        )

        XCTAssertEqual(result.sessionID, thirdID)
        XCTAssertEqual(result.disposition, "publication_rejected")
    }

    func testWaitAnyArbitrationBreaksEqualPriorityTiesByInputOrder() {
        let firstID = UUID()
        let secondID = UUID()
        let result = AgentRunMCPToolService.test_arbitrateWaitAnyDisposition(
            sessionIDs: [firstID, secondID],
            candidates: [
                (secondID, "actionable"),
                (firstID, "actionable")
            ]
        )

        XCTAssertEqual(result.sessionID, firstID)
        XCTAssertEqual(result.disposition, "actionable")
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
