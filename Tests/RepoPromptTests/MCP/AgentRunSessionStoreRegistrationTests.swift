import Foundation
@testable import RepoPrompt
import XCTest

final class AgentRunSessionStoreRegistrationTests: XCTestCase {
    func testStalePublicationAndCleanupCannotAffectReplacementRegistration() async {
        let sessionID = UUID()
        let first = await AgentRunSessionStore.register(sessionID: sessionID)
        let replacement = await AgentRunSessionStore.register(sessionID: sessionID)

        await AgentRunSessionStore.signalSnapshot(makeSnapshot(sessionID: sessionID, status: .completed), registration: first)
        let replacementSnapshot = await AgentRunSessionStore.snapshot(for: replacement)
        XCTAssertNil(replacementSnapshot)

        await AgentRunSessionStore.cleanup(registration: first)
        let currentRegistration = await AgentRunSessionStore.currentRegistration(for: sessionID)
        XCTAssertEqual(currentRegistration, replacement)

        await AgentRunSessionStore.cleanup(registration: replacement)
    }

    func testTerminalCommitPublicationIsExactlyOncePerRegistration() async throws {
        let sessionID = UUID()
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)
        let waiter = Task {
            await AgentRunSessionStore.waitUntilInteresting(registration: registration, timeoutSeconds: 1)
        }
        try await waitForWaiter(registration: registration)

        let commitID = UUID()
        let completed = makeSnapshot(sessionID: sessionID, status: .completed)
        await AgentRunSessionStore.signalCommittedSnapshot(
            completed,
            registration: registration,
            commitID: commitID
        )
        await AgentRunSessionStore.signalCommittedSnapshot(
            completed,
            registration: registration,
            commitID: commitID
        )
        await AgentRunSessionStore.signalCommittedSnapshot(
            makeSnapshot(sessionID: sessionID, status: .failed),
            registration: registration,
            commitID: UUID()
        )

        let disposition = await waiter.value
        let storedSnapshot = await AgentRunSessionStore.snapshot(for: registration)
        XCTAssertEqual(disposition, .snapshotReady(completed))
        XCTAssertEqual(storedSnapshot, completed)
        await AgentRunSessionStore.cleanup(registration: registration)
    }

    func testReplacementRegistrationExpiresOldWaiter() async throws {
        let sessionID = UUID()
        let first = await AgentRunSessionStore.register(sessionID: sessionID)
        let waiter = Task {
            await AgentRunSessionStore.waitUntilInteresting(registration: first, timeoutSeconds: 1)
        }
        try await waitForWaiter(registration: first)

        let replacement = await AgentRunSessionStore.register(sessionID: sessionID)
        let disposition = await waiter.value
        let currentRegistration = await AgentRunSessionStore.currentRegistration(for: sessionID)
        XCTAssertEqual(disposition, .expired)
        XCTAssertEqual(currentRegistration, replacement)

        await AgentRunSessionStore.cleanup(registration: replacement)
    }

    func testNewTurnRotationPreservesWaiterButRejectsOldGenerationPublication() async throws {
        let sessionID = UUID()
        let first = await AgentRunSessionStore.register(sessionID: sessionID)
        let waiter = Task {
            await AgentRunSessionStore.waitUntilInteresting(registration: first, timeoutSeconds: 1)
        }
        try await waitForWaiter(registration: first)

        let rotatedRegistration = await AgentRunSessionStore.resetSnapshotForNewTurn(registration: first)
        let replacement = try XCTUnwrap(rotatedRegistration)
        await AgentRunSessionStore.signalSnapshot(makeSnapshot(sessionID: sessionID, status: .completed), registration: first)
        let replacementSnapshot = await AgentRunSessionStore.snapshot(for: replacement)
        XCTAssertNil(replacementSnapshot)

        let completed = makeSnapshot(sessionID: sessionID, status: .completed)
        await AgentRunSessionStore.signalSnapshot(completed, registration: replacement)
        let disposition = await waiter.value
        XCTAssertEqual(disposition, .snapshotReady(completed))

        await AgentRunSessionStore.cleanup(registration: replacement)
    }

    func testNewTurnRotationPreservesWaiterTimeoutDisposition() async throws {
        let sessionID = UUID()
        let first = await AgentRunSessionStore.register(sessionID: sessionID)
        let waiter = Task {
            await AgentRunSessionStore.waitUntilInteresting(registration: first, timeoutSeconds: 0.02)
        }
        try await waitForWaiter(registration: first)

        let rotatedRegistration = await AgentRunSessionStore.resetSnapshotForNewTurn(registration: first)
        let replacement = try XCTUnwrap(rotatedRegistration)
        let disposition = await waiter.value
        let currentRegistration = await AgentRunSessionStore.currentRegistration(for: sessionID)
        XCTAssertEqual(disposition, .timedOut)
        XCTAssertEqual(currentRegistration, replacement)

        await AgentRunSessionStore.cleanup(registration: replacement)
    }

    func testStaleExpiryCannotRemoveReplacementRegistration() async {
        let sessionID = UUID()
        let first = await AgentRunSessionStore.register(sessionID: sessionID)
        let replacement = await AgentRunSessionStore.register(sessionID: sessionID)

        await AgentRunSessionStore.shared.test_expire(registration: first)
        let currentRegistration = await AgentRunSessionStore.currentRegistration(for: sessionID)
        XCTAssertEqual(currentRegistration, replacement)

        await AgentRunSessionStore.cleanup(registration: replacement)
    }

    private func waitForWaiter(registration: AgentRunSessionStore.Registration) async throws {
        for _ in 0 ..< 100 {
            if await AgentRunSessionStore.shared.test_waiterCount(registration: registration) == 1 {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for waiter registration")
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
