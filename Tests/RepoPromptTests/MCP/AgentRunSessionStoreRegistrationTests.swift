import Foundation
@testable import RepoPrompt
import XCTest

final class AgentRunSessionStoreRegistrationTests: XCTestCase {
    private enum TestFailure: Error {
        case missingEpoch
    }

    func testActivationReplacementExpiresOldWaiterAndRejectsOldPublication() async throws {
        let sessionID = UUID()
        let first = await AgentRunSessionStore.register(sessionID: sessionID)
        let firstCursor = AgentRunSessionStore.WaitCursor(registration: first, epoch: nil)
        let waiter = Task {
            await AgentRunSessionStore.waitUntilInteresting(cursor: firstCursor, timeoutSeconds: 1)
        }
        try await waitForWaiter(registration: first)

        let replacement = await AgentRunSessionStore.register(sessionID: sessionID)
        let disposition = await waiter.value
        XCTAssertEqual(disposition, .expired)
        await AgentRunSessionStore.signalSnapshot(
            makeSnapshot(sessionID: sessionID, status: .completed),
            cursor: firstCursor
        )
        let replacementSnapshot = await AgentRunSessionStore.snapshot(for: replacement)
        let currentRegistration = await AgentRunSessionStore.currentRegistration(for: sessionID)
        XCTAssertNil(replacementSnapshot)
        XCTAssertEqual(currentRegistration, replacement)
        await AgentRunSessionStore.cleanup(registration: replacement)
    }

    func testRegisterIfMissingDoesNotReplaceExistingRegistration() async {
        let sessionID = UUID()
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)

        let recovered = await AgentRunSessionStore.registerIfMissing(sessionID: sessionID)
        let current = await AgentRunSessionStore.currentRegistration(for: sessionID)

        XCTAssertNil(recovered)
        XCTAssertEqual(current, registration)
        await AgentRunSessionStore.cleanup(registration: registration)
    }

    func testPreEpochWaiterAdvancesWithoutRotatingActivationRegistration() async throws {
        let sessionID = UUID()
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)
        let cursor = AgentRunSessionStore.WaitCursor(registration: registration, epoch: nil)
        let waiter = Task {
            await AgentRunSessionStore.waitUntilInteresting(cursor: cursor, timeoutSeconds: 1)
        }
        try await waitForWaiter(registration: registration)

        let epoch = try await beginEpoch(
            registration: registration,
            activationID: UUID(),
            expected: nil,
            kind: .initial
        )
        let disposition = await waiter.value
        let currentRegistration = await AgentRunSessionStore.currentRegistration(for: sessionID)
        let currentEpoch = await AgentRunSessionStore.currentEpoch(for: registration)
        XCTAssertEqual(disposition, .epochAdvanced(epoch, .initial))
        XCTAssertEqual(currentRegistration, registration)
        XCTAssertEqual(currentEpoch, epoch)
        await AgentRunSessionStore.cleanup(registration: registration)
    }

    func testTerminalPublicationAndRelatedSuccessorAreAtomicAndIdempotent() async throws {
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
        let waiter = Task {
            await AgentRunSessionStore.waitUntilInteresting(cursor: cursor, timeoutSeconds: 1)
        }
        try await waitForWaiter(registration: registration)

        let terminal = makeSnapshot(sessionID: sessionID, status: .completed)
        let commitID = UUID()
        let firstResult = await AgentRunSessionStore.publishTerminal(
            .init(epoch: epoch, snapshot: terminal),
            registration: registration,
            commitID: commitID,
            successorKind: .relatedFollowUp
        )
        let successor = try XCTUnwrap(firstResult.successorEpoch)
        let disposition = await waiter.value
        let oldSnapshot = await AgentRunSessionStore.snapshot(for: cursor)
        let successorSnapshot = await AgentRunSessionStore.snapshot(
            for: .init(registration: registration, epoch: successor)
        )
        XCTAssertEqual(disposition, .epochAdvanced(successor, .relatedFollowUp))
        XCTAssertEqual(oldSnapshot, terminal)
        XCTAssertNil(successorSnapshot)

        let duplicate = await AgentRunSessionStore.publishTerminal(
            .init(epoch: epoch, snapshot: terminal),
            registration: registration,
            commitID: commitID,
            successorKind: .relatedFollowUp
        )
        let currentEpoch = await AgentRunSessionStore.currentEpoch(for: registration)
        XCTAssertEqual(duplicate, .accepted(successorEpoch: successor))
        XCTAssertEqual(currentEpoch, successor)
        await AgentRunSessionStore.cleanup(registration: registration)
    }

    func testOldEpochTerminalAfterNewEpochBeginsIsCanonicalButDoesNotWakeCurrentWaiter() async throws {
        let sessionID = UUID()
        let activationID = UUID()
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)
        let firstEpoch = try await beginEpoch(
            registration: registration,
            activationID: activationID,
            expected: nil,
            kind: .initial
        )
        let secondEpoch = try await beginEpoch(
            registration: registration,
            activationID: activationID,
            expected: firstEpoch,
            kind: .relatedFollowUp
        )
        let secondCursor = AgentRunSessionStore.WaitCursor(registration: registration, epoch: secondEpoch)
        let waiter = Task {
            await AgentRunSessionStore.waitUntilInteresting(cursor: secondCursor, timeoutSeconds: 1)
        }
        try await waitForWaiter(registration: registration)

        let oldTerminal = makeSnapshot(sessionID: sessionID, status: .completed)
        let staleResult = await AgentRunSessionStore.publishTerminal(
            .init(epoch: firstEpoch, snapshot: oldTerminal),
            registration: registration,
            commitID: UUID(),
            successorKind: nil
        )
        let waiterCount = await AgentRunSessionStore.shared.test_waiterCount(registration: registration)
        let storedOldTerminal = await AgentRunSessionStore.snapshot(
            for: .init(registration: registration, epoch: firstEpoch)
        )
        XCTAssertEqual(staleResult, .stale)
        XCTAssertEqual(waiterCount, 1)
        XCTAssertEqual(storedOldTerminal, oldTerminal)

        let currentTerminal = makeSnapshot(sessionID: sessionID, status: .failed)
        let accepted = await AgentRunSessionStore.publishTerminal(
            .init(epoch: secondEpoch, snapshot: currentTerminal),
            registration: registration,
            commitID: UUID(),
            successorKind: nil
        )
        let disposition = await waiter.value
        XCTAssertEqual(accepted, .accepted(successorEpoch: nil))
        XCTAssertEqual(disposition, .snapshotReady(currentTerminal))
        await AgentRunSessionStore.cleanup(registration: registration)
    }

    func testSkippedUnrelatedEpochStillSupersedesAcrossLaterRelatedEpoch() async throws {
        let sessionID = UUID()
        let activationID = UUID()
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)
        let first = try await beginEpoch(
            registration: registration,
            activationID: activationID,
            expected: nil,
            kind: .initial
        )
        let unrelated = try await beginEpoch(
            registration: registration,
            activationID: activationID,
            expected: first,
            kind: .unrelated
        )
        let related = try await beginEpoch(
            registration: registration,
            activationID: activationID,
            expected: unrelated,
            kind: .relatedFollowUp
        )

        let disposition = await AgentRunSessionStore.waitUntilInteresting(
            cursor: .init(registration: registration, epoch: first),
            timeoutSeconds: 0
        )
        XCTAssertEqual(disposition, .epochAdvanced(related, .unrelated))
        await AgentRunSessionStore.cleanup(registration: registration)
    }

    func testDelayedSteeringWakeCannotRegressCanonicalTerminalSnapshot() async throws {
        let sessionID = UUID()
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)
        let epoch = try await beginEpoch(
            registration: registration,
            activationID: UUID(),
            expected: nil,
            kind: .initial
        )
        let cursor = AgentRunSessionStore.WaitCursor(registration: registration, epoch: epoch)
        let terminal = makeSnapshot(sessionID: sessionID, status: .completed)
        let result = await AgentRunSessionStore.publishTerminal(
            .init(epoch: epoch, snapshot: terminal),
            registration: registration,
            commitID: UUID(),
            successorKind: nil
        )
        XCTAssertEqual(result, .accepted(successorEpoch: nil))

        await AgentRunSessionStore.wakeCurrentWaiters(
            makeSnapshot(sessionID: sessionID, status: .running),
            cursor: cursor,
            reason: .steeringRequested
        )
        let stored = await AgentRunSessionStore.snapshot(for: cursor)
        let disposition = await AgentRunSessionStore.waitUntilInteresting(cursor: cursor, timeoutSeconds: 0)
        XCTAssertEqual(stored, terminal)
        XCTAssertEqual(disposition, .snapshotReady(terminal))
        await AgentRunSessionStore.cleanup(registration: registration)
    }

    func testDirectNoWaiterSteeringWakeIsEdgeTriggered() async throws {
        let sessionID = UUID()
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)
        let epoch = try await beginEpoch(
            registration: registration,
            activationID: UUID(),
            expected: nil,
            kind: .initial
        )
        let cursor = AgentRunSessionStore.WaitCursor(registration: registration, epoch: epoch)
        let running = makeSnapshot(sessionID: sessionID, status: .running)
        await AgentRunSessionStore.signalSnapshot(running, cursor: cursor)

        await AgentRunSessionStore.wakeCurrentWaiters(
            running,
            cursor: cursor,
            reason: .steeringRequested
        )

        let disposition = await AgentRunSessionStore.waitUntilInteresting(cursor: cursor, timeoutSeconds: 0)
        XCTAssertEqual(disposition, .timedOut)
        await AgentRunSessionStore.cleanup(registration: registration)
    }

    func testDuplicateDirectWakeCannotPoisonFreshWait() async throws {
        let sessionID = UUID()
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)
        let epoch = try await beginEpoch(
            registration: registration,
            activationID: UUID(),
            expected: nil,
            kind: .initial
        )
        let cursor = AgentRunSessionStore.WaitCursor(registration: registration, epoch: epoch)
        let running = makeSnapshot(sessionID: sessionID, status: .running)
        await AgentRunSessionStore.signalSnapshot(running, cursor: cursor)
        let firstWait = Task {
            await AgentRunSessionStore.waitUntilInteresting(cursor: cursor, timeoutSeconds: 1)
        }
        try await waitForWaiter(registration: registration)

        await AgentRunSessionStore.wakeCurrentWaiters(
            running,
            cursor: cursor,
            reason: .steeringRequested
        )
        let firstDisposition = await firstWait.value
        XCTAssertEqual(firstDisposition, .noteworthySnapshot(running, .steeringRequested))

        await AgentRunSessionStore.wakeCurrentWaiters(
            running,
            cursor: cursor,
            reason: .steeringRequested
        )
        await AgentRunSessionStore.wakeCurrentWaiters(
            running,
            cursor: cursor,
            reason: .steeringRequested
        )

        let freshDisposition = await AgentRunSessionStore.waitUntilInteresting(
            cursor: cursor,
            timeoutSeconds: 0
        )
        XCTAssertEqual(freshDisposition, .timedOut)
        await AgentRunSessionStore.cleanup(registration: registration)
    }

    func testSignaledNoteworthySnapshotRemainsStickyForNextWaitOnly() async throws {
        let sessionID = UUID()
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)
        let epoch = try await beginEpoch(
            registration: registration,
            activationID: UUID(),
            expected: nil,
            kind: .initial
        )
        let cursor = AgentRunSessionStore.WaitCursor(registration: registration, epoch: epoch)
        let running = makeSnapshot(sessionID: sessionID, status: .running)

        await AgentRunSessionStore.signalSnapshotAndWakeWaiters(
            running,
            cursor: cursor,
            reason: .instructionDelivered
        )

        let firstDisposition = await AgentRunSessionStore.waitUntilInteresting(
            cursor: cursor,
            timeoutSeconds: 0
        )
        let secondDisposition = await AgentRunSessionStore.waitUntilInteresting(
            cursor: cursor,
            timeoutSeconds: 0
        )
        XCTAssertEqual(firstDisposition, .noteworthySnapshot(running, .instructionDelivered))
        XCTAssertEqual(secondDisposition, .timedOut)
        await AgentRunSessionStore.cleanup(registration: registration)
    }

    func testActionablePublicationDominatesPendingSteeringWake() async throws {
        let sessionID = UUID()
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)
        let epoch = try await beginEpoch(
            registration: registration,
            activationID: UUID(),
            expected: nil,
            kind: .initial
        )
        let cursor = AgentRunSessionStore.WaitCursor(registration: registration, epoch: epoch)
        let running = makeSnapshot(sessionID: sessionID, status: .running)
        let actionable = makeSnapshot(sessionID: sessionID, status: .waitingForInput)

        await AgentRunSessionStore.signalSnapshotAndWakeWaiters(
            running,
            cursor: cursor,
            reason: .steeringRequested
        )
        await AgentRunSessionStore.signalSnapshot(actionable, cursor: cursor)

        let disposition = await AgentRunSessionStore.waitUntilInteresting(cursor: cursor, timeoutSeconds: 0)
        XCTAssertEqual(disposition, .snapshotReady(actionable))
        await AgentRunSessionStore.cleanup(registration: registration)
    }

    func testInteractionSnapshotWakesImmediatelyAndIsNotHiddenByEpochState() async throws {
        let sessionID = UUID()
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)
        let epoch = try await beginEpoch(
            registration: registration,
            activationID: UUID(),
            expected: nil,
            kind: .initial
        )
        let cursor = AgentRunSessionStore.WaitCursor(registration: registration, epoch: epoch)
        let waiter = Task {
            await AgentRunSessionStore.waitUntilInteresting(cursor: cursor, timeoutSeconds: 1)
        }
        try await waitForWaiter(registration: registration)

        var interactionSnapshot = makeSnapshot(sessionID: sessionID, status: .waitingForInput)
        interactionSnapshot = AgentRunMCPSnapshot(
            sessionID: interactionSnapshot.sessionID,
            tabID: interactionSnapshot.tabID,
            sessionName: interactionSnapshot.sessionName,
            agentRaw: interactionSnapshot.agentRaw,
            agentDisplayName: interactionSnapshot.agentDisplayName,
            modelRaw: interactionSnapshot.modelRaw,
            reasoningEffortRaw: interactionSnapshot.reasoningEffortRaw,
            status: .waitingForInput,
            statusText: "Question",
            latestAssistantPreview: nil,
            interaction: .init(
                id: UUID(),
                kind: .question,
                responseType: .text,
                title: "Question",
                prompt: "Continue?",
                context: nil,
                allowsMultiple: nil,
                options: [],
                fields: [],
                details: []
            ),
            transcriptItemCount: 0,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: nil,
            worktreeBindings: [],
            activeWorktreeMerges: []
        )
        await AgentRunSessionStore.signalSnapshot(interactionSnapshot, cursor: cursor)
        let disposition = await waiter.value
        XCTAssertEqual(disposition, .snapshotReady(interactionSnapshot))
        await AgentRunSessionStore.cleanup(registration: registration)
    }

    func testUnexpectedCurrentEpochTerminalRejectionWakesMatchingWaiter() async throws {
        let sessionID = UUID()
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)
        let epoch = try await beginEpoch(
            registration: registration,
            activationID: UUID(),
            expected: nil,
            kind: .initial
        )
        let cursor = AgentRunSessionStore.WaitCursor(registration: registration, epoch: epoch)
        await AgentRunSessionStore.shared.test_setTerminalCommitID(UUID(), cursor: cursor)
        let waiter = Task {
            await AgentRunSessionStore.waitUntilInteresting(cursor: cursor, timeoutSeconds: 1)
        }
        try await waitForWaiter(registration: registration)

        let result = await AgentRunSessionStore.publishTerminal(
            .init(epoch: epoch, snapshot: makeSnapshot(sessionID: sessionID, status: .completed)),
            registration: registration,
            commitID: UUID(),
            successorKind: nil
        )
        guard case let .rejected(reason) = result else {
            return XCTFail("Expected rejected terminal publication")
        }
        let disposition = await waiter.value
        XCTAssertEqual(disposition, .terminalPublicationRejected(epoch: epoch, reason: reason))
        await AgentRunSessionStore.cleanup(registration: registration)
    }

    func testOriginalTimeoutBudgetSurvivesMultipleRelatedEpochAdvances() async throws {
        let sessionID = UUID()
        let activationID = UUID()
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(80))
        let waiter = Task { () -> AgentRunSessionStore.WaitDisposition in
            var cursor = AgentRunSessionStore.WaitCursor(registration: registration, epoch: nil)
            while true {
                let remaining = durationSeconds(clock.now.duration(to: deadline))
                guard remaining > 0 else { return .timedOut }
                let disposition = await AgentRunSessionStore.waitUntilInteresting(
                    cursor: cursor,
                    timeoutSeconds: remaining
                )
                if case let .epochAdvanced(epoch, _) = disposition {
                    cursor = .init(registration: registration, epoch: epoch)
                    continue
                }
                return disposition
            }
        }
        try await waitForWaiter(registration: registration)
        let first = try await beginEpoch(
            registration: registration,
            activationID: activationID,
            expected: nil,
            kind: .initial
        )
        try await waitForWaiter(registration: registration)
        _ = try await beginEpoch(
            registration: registration,
            activationID: activationID,
            expected: first,
            kind: .relatedFollowUp
        )
        let disposition = await waiter.value
        XCTAssertEqual(disposition, .timedOut)
        await AgentRunSessionStore.cleanup(registration: registration)
    }

    func testStaleTerminalExpiryCannotRemoveNewerEpoch() async throws {
        let sessionID = UUID()
        let activationID = UUID()
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)
        let first = try await beginEpoch(
            registration: registration,
            activationID: activationID,
            expected: nil,
            kind: .initial
        )
        let second = try await beginEpoch(
            registration: registration,
            activationID: activationID,
            expected: first,
            kind: .relatedFollowUp
        )
        await AgentRunSessionStore.shared.test_expire(
            cursor: .init(registration: registration, epoch: first)
        )
        let currentEpoch = await AgentRunSessionStore.currentEpoch(for: registration)
        let currentRegistration = await AgentRunSessionStore.currentRegistration(for: sessionID)
        XCTAssertEqual(currentEpoch, second)
        XCTAssertEqual(currentRegistration, registration)
        await AgentRunSessionStore.cleanup(registration: registration)
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
        XCTFail("Timed out waiting for waiter registration")
    }

    private func durationSeconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func makeSnapshot(
        sessionID: UUID,
        status: AgentRunMCPSnapshot.Status
    ) -> AgentRunMCPSnapshot {
        AgentRunMCPSnapshot(
            sessionID: sessionID,
            tabID: nil,
            sessionName: "Agent",
            agentRaw: AgentProviderKind.codexExec.rawValue,
            agentDisplayName: AgentProviderKind.codexExec.displayName,
            modelRaw: "codex",
            reasoningEffortRaw: nil,
            status: status,
            statusText: status.rawValue,
            latestAssistantPreview: nil,
            interaction: nil,
            transcriptItemCount: 0,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: nil,
            worktreeBindings: [],
            activeWorktreeMerges: []
        )
    }
}
