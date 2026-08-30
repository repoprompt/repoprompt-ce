import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

final class AgentRunLifecycleContractsTests: XCTestCase {
    func testOwnershipCapturesImmutableTurnEpoch() {
        let sessionID = UUID()
        let epoch = AgentRunTurnEpoch(
            sessionID: sessionID,
            activationID: UUID(),
            registrationGeneration: 7,
            id: UUID(),
            ordinal: 3,
            continuityGeneration: 1,
            transitionKind: .relatedFollowUp
        )
        var tracker = AgentRunLifecycleTracker()
        let ownership = tracker.begin(
            tabID: UUID(),
            persistentSessionID: sessionID,
            turnEpoch: epoch
        )
        XCTAssertEqual(ownership.turnEpoch, epoch)
        XCTAssertEqual(tracker.activeOwnership?.turnEpoch, epoch)
    }

    func testHeartbeatAdvancesSignalTimeWithoutManufacturingRealProgress() {
        var tracker = AgentRunLifecycleTracker()
        let ownership = tracker.begin(
            tabID: UUID(),
            persistentSessionID: nil,
            timestampUptimeNanoseconds: 100
        )

        guard case let .accepted(providerSnapshot) = tracker.record(
            ownership: ownership,
            kind: .providerEvent,
            stage: .running,
            timestampUptimeNanoseconds: 200
        ) else {
            return XCTFail("Expected provider progress")
        }
        guard case let .accepted(heartbeatSnapshot) = tracker.record(
            ownership: ownership,
            kind: .heartbeat,
            stage: .running,
            timestampUptimeNanoseconds: 300
        ) else {
            return XCTFail("Expected heartbeat")
        }

        XCTAssertEqual(providerSnapshot.lastRealProgressUptimeNanoseconds, 200)
        XCTAssertEqual(heartbeatSnapshot.lastSignalUptimeNanoseconds, 300)
        XCTAssertEqual(heartbeatSnapshot.lastHeartbeatUptimeNanoseconds, 300)
        XCTAssertEqual(heartbeatSnapshot.lastRealProgressUptimeNanoseconds, 200)
    }

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
