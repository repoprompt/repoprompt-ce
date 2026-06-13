import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

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

    func testOwnershipRejectsStaleSignalsAndDuplicateOrOutOfOrderSequences() {
        let tabID = UUID()
        let sessionID = UUID()
        var tracker = AgentRunLifecycleTracker()
        let ownership = tracker.begin(
            tabID: tabID,
            persistentSessionID: sessionID,
            timestampUptimeNanoseconds: 100
        )
        let staleOwnership = AgentRunOwnership(
            binding: AgentRunBindingIdentity(tabID: tabID, persistentSessionID: sessionID)
        )

        XCTAssertEqual(
            tracker.accept(.init(
                ownership: staleOwnership,
                sequence: 1,
                timestampUptimeNanoseconds: 110,
                kind: .providerEvent,
                stage: .running,
                retryIntent: .none
            )),
            .rejected(.staleOwnership)
        )

        let accepted = AgentRunProgressSignal(
            ownership: ownership,
            sequence: 1,
            timestampUptimeNanoseconds: 120,
            kind: .providerEvent,
            stage: .running,
            retryIntent: .none
        )
        guard case let .accepted(snapshot) = tracker.accept(accepted) else {
            return XCTFail("Expected first current-ownership signal to be accepted")
        }
        XCTAssertEqual(snapshot.lastAcceptedSequence, 1)
        XCTAssertEqual(tracker.accept(accepted), .rejected(.duplicateSequence))
        XCTAssertEqual(
            tracker.accept(.init(
                ownership: ownership,
                sequence: 0,
                timestampUptimeNanoseconds: 130,
                kind: .providerEvent,
                stage: .running,
                retryIntent: .none
            )),
            .rejected(.outOfOrderSequence)
        )
        XCTAssertEqual(
            tracker.accept(.init(
                ownership: ownership,
                sequence: 2,
                timestampUptimeNanoseconds: 119,
                kind: .providerEvent,
                stage: .running,
                retryIntent: .none
            )),
            .rejected(.nonMonotonicTimestamp)
        )
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

    func testRetryIntentAndStageAreNonRenderingLifecycleState() {
        var tracker = AgentRunLifecycleTracker()
        let ownership = tracker.begin(tabID: UUID(), persistentSessionID: nil, timestampUptimeNanoseconds: 10)

        guard case let .accepted(snapshot) = tracker.record(
            ownership: ownership,
            kind: .stageTransition,
            stage: .retrying,
            retryIntent: .providerManaged,
            timestampUptimeNanoseconds: 20
        ) else {
            return XCTFail("Expected retry transition")
        }

        XCTAssertEqual(snapshot.stage, .retrying)
        XCTAssertEqual(snapshot.retryIntent, .providerManaged)
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
