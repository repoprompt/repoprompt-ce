import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class AgentRunMCPToolServiceWaitAnyTests: XCTestCase {
    func testWaitAnyPerSessionSteeringWakeSurfacesAsNonActionableWake() async throws {
        let sessionID = UUID()
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)

        let waitTask = Task {
            await AgentRunMCPToolService.test_waitUntilActionableDisposition(
                sessionID: sessionID,
                timeoutSeconds: 1
            )
        }
        try await Task.sleep(nanoseconds: 25_000_000)

        await AgentRunSessionStore.wakeCurrentWaiters(
            makeRunningSnapshot(sessionID: sessionID),
            registration: registration,
            reason: .steeringRequested
        )

        let result = await waitTask.value
        XCTAssertEqual(result.sessionID, sessionID)
        XCTAssertEqual(result.disposition, "non_actionable_wake")
        XCTAssertEqual(result.wakeReason, AgentRunSessionStore.WakeReason.steeringRequested.rawValue)
        XCTAssertEqual(result.snapshotStatus, AgentRunMCPSnapshot.Status.running.rawValue)
        await AgentRunSessionStore.cleanup(registration: registration)
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

    private func makeRunningSnapshot(sessionID: UUID) -> AgentRunMCPSnapshot {
        AgentRunMCPSnapshot(
            sessionID: sessionID,
            tabID: nil,
            sessionName: "Child Agent",
            agentRaw: AgentProviderKind.codexExec.rawValue,
            agentDisplayName: AgentProviderKind.codexExec.displayName,
            modelRaw: "codex",
            reasoningEffortRaw: nil,
            status: .running,
            statusText: "Running",
            latestAssistantPreview: "still working",
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
