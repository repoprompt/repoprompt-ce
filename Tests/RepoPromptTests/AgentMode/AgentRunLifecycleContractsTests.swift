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

    @MainActor
    func testTerminalCommitRejectsStaleDrainAndDoesNotRepublishResolvedRevision() async throws {
        let tabID = UUID()
        let lifecycle = AgentRunAttemptLifecycle()
        let ownership = lifecycle.beginAttempt(
            context: .init(tabID: tabID, persistentSessionID: nil)
        )
        let providerDrainGeneration: UInt64 = 7
        var publicationCount = 0
        let hooks = AgentRunTerminalSessionBinding.Hooks(
            flushPendingAssistantDelta: {},
            finalizeStreamingItems: {},
            finalizePendingToolCalls: { _ in },
            finalizeNonCodexTurnUsage: {},
            cancelPendingInteractions: { _ in },
            finalizeAttachments: { _, _ in },
            setAgentRunInactive: {},
            prepareTerminalPublication: {},
            makeTerminalPublicationEnvelope: { _, _, _, _ in nil },
            updateBindings: {},
            notifyAgentTurnComplete: {},
            scheduleSave: {},
            publishTerminalCommit: { _, _ in
                publicationCount += 1
                return .accepted(successorEpoch: nil)
            },
            startFollowUpRun: { _ in }
        )
        let binding = AgentRunTerminalSessionBinding(
            tabID: tabID,
            lifecycle: lifecycle,
            hooks: hooks,
            validatesOwnership: { candidate, expectedRunID in
                lifecycle.isCurrentAttempt(candidate, expectedRunID: expectedRunID)
            },
            providerDrainGeneration: { providerDrainGeneration },
            terminalTurnID: { nil },
            queuedFollowUp: { nil },
            setFollowUpPending: { _ in },
            removeFirstQueuedFollowUp: { nil },
            appendError: { _ in },
            finishActiveState: { candidate, _, _ in
                _ = lifecycle.endAttempt(ifCurrent: candidate)
            },
            retainProcessRunIdentity: { _, _ in },
            sourceItemsRevision: { 3 },
            assistantDeltaFlushGeneration: { 5 },
            latestFailureText: { nil }
        )
        let barrier = AgentRunTerminalCommitBarrier()

        func request(drainGeneration: UInt64) -> AgentRunTerminalCommitBarrier.Request {
            AgentRunTerminalCommitBarrier.Request(
                binding: binding,
                ownership: ownership,
                expectedRunID: nil,
                terminalState: .completed,
                source: "test.terminalCommit",
                attachmentDisposition: .deleteFiles,
                finalizeNonCodexUsage: false,
                supportsFollowUp: false,
                notifyTurnComplete: false,
                providerDrainGeneration: drainGeneration
            )
        }

        let staleRevision = await barrier.commit(request(drainGeneration: providerDrainGeneration - 1))
        XCTAssertNil(staleRevision)
        XCTAssertEqual(publicationCount, 0)
        XCTAssertNil(lifecycle.lastTerminalCommitRevision)

        let firstCandidate = await barrier.commit(request(drainGeneration: providerDrainGeneration))
        let firstRevision = try XCTUnwrap(firstCandidate)
        XCTAssertEqual(publicationCount, 1)
        XCTAssertEqual(lifecycle.lastTerminalPublicationResult, .accepted(successorEpoch: nil))

        let repeatedCandidate = await barrier.commit(request(drainGeneration: providerDrainGeneration))
        let repeatedRevision = try XCTUnwrap(repeatedCandidate)
        XCTAssertEqual(repeatedRevision, firstRevision)
        XCTAssertEqual(publicationCount, 1)
    }
}
