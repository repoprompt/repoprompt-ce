import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentOraclePillLogicTests: XCTestCase {
    private func makeSession(
        id: UUID = UUID(),
        savedAt: Date = Date(),
        messageCount: Int? = nil,
        workspaceID: UUID? = nil,
        tabID: UUID? = nil,
        agentSessionID: UUID? = nil,
        runID: UUID? = nil,
        pairID: UUID? = nil,
        lane: OracleLane? = nil,
        shortID: String? = nil
    ) -> ChatSession {
        ChatSession(
            id: id,
            workspaceID: workspaceID,
            composeTabID: tabID,
            agentModeSessionID: agentSessionID,
            agentModeRunID: runID,
            oraclePairID: pairID,
            oracleLane: lane,
            name: "Oracle",
            savedAt: savedAt,
            messageCount: messageCount,
            shortID: shortID
        )
    }

    func testPresentationsPreserveLegacyWhenSecondaryIsDisabled() {
        XCTAssertEqual(AgentOraclePillLogic.presentations(secondaryConfigured: false), [.legacySingle])
        XCTAssertEqual(
            AgentOraclePillLogic.presentations(secondaryConfigured: true),
            [.pairedLane(.primary), .pairedLane(.secondary)]
        )
    }

    func testLaneResolutionRejectsMalformedPairedSession() {
        XCTAssertEqual(AgentOraclePillLogic.resolvedLane(for: makeSession()), .primary)
        XCTAssertEqual(AgentOraclePillLogic.resolvedLane(for: makeSession(pairID: UUID(), lane: .primary)), .primary)
        XCTAssertEqual(AgentOraclePillLogic.resolvedLane(for: makeSession(pairID: UUID(), lane: .secondary)), .secondary)
        XCTAssertNil(AgentOraclePillLogic.resolvedLane(for: makeSession(pairID: UUID())))
    }

    func testLaneFilteringKeepsPrimaryAndSecondaryIndependent() {
        let legacy = makeSession(messageCount: 1)
        let primary = makeSession(messageCount: 1, pairID: UUID(), lane: .primary)
        let secondary = makeSession(messageCount: 1, pairID: UUID(), lane: .secondary)
        let malformed = makeSession(messageCount: 1, pairID: UUID())

        let primarySessions = AgentOraclePillLogic.eligibleSessions(
            sessions: [secondary, malformed, primary, legacy],
            streamingSessionIDs: [],
            liveMessageCount: { _ in nil },
            lane: .primary
        )
        let secondarySessions = AgentOraclePillLogic.eligibleSessions(
            sessions: [legacy, primary, malformed, secondary],
            streamingSessionIDs: [],
            liveMessageCount: { _ in nil },
            lane: .secondary
        )

        XCTAssertEqual(Set(primarySessions.map(\.id)), Set([legacy.id, primary.id]))
        XCTAssertEqual(secondarySessions.map(\.id), [secondary.id])
    }

    func testTranscriptCandidatesIncludeBlankSessionWithoutCrossingLanes() {
        let primary = makeSession(pairID: UUID(), lane: .primary)
        let secondary = makeSession(pairID: UUID(), lane: .secondary)

        XCTAssertEqual(
            AgentOraclePillLogic.transcriptCandidates(sessions: [secondary, primary], lane: .primary).map(\.id),
            [primary.id]
        )
        XCTAssertEqual(
            AgentOraclePillLogic.transcriptCandidates(sessions: [primary, secondary], lane: .secondary).map(\.id),
            [secondary.id]
        )
        XCTAssertTrue(AgentOraclePillLogic.eligibleSessions(
            sessions: [primary],
            streamingSessionIDs: [],
            liveMessageCount: { _ in nil },
            lane: .primary
        ).isEmpty)
    }

    func testLaneProjectionDoesNotFallbackOutsideActiveOwnerRunCohort() {
        let ownerID = UUID()
        let runID = UUID()
        let exactPrimary = makeSession(
            agentSessionID: ownerID,
            runID: runID,
            pairID: UUID(),
            lane: .primary
        )
        let staleSecondary = makeSession(messageCount: 1, pairID: UUID(), lane: .secondary)

        XCTAssertTrue(AgentOraclePillLogic.transcriptCandidates(
            sessions: [staleSecondary, exactPrimary],
            activeAgentSessionID: ownerID,
            activeRunID: runID,
            lane: .secondary
        ).isEmpty)
        XCTAssertTrue(AgentOraclePillLogic.eligibleSessions(
            sessions: [staleSecondary, exactPrimary],
            streamingSessionIDs: [],
            liveMessageCount: { _ in nil },
            activeAgentSessionID: ownerID,
            activeRunID: runID,
            lane: .secondary
        ).isEmpty)

        let exactSecondary = makeSession(
            agentSessionID: ownerID,
            runID: runID,
            pairID: UUID(),
            lane: .secondary
        )
        let stalePrimary = makeSession(messageCount: 1)
        XCTAssertTrue(AgentOraclePillLogic.transcriptCandidates(
            sessions: [stalePrimary, exactSecondary],
            activeAgentSessionID: ownerID,
            activeRunID: runID,
            lane: .primary
        ).isEmpty)
    }

    func testExactOpenRequiresMatchingIdentityAndLane() throws {
        let workspaceID = UUID()
        let tabID = UUID()
        let secondary = makeSession(
            workspaceID: workspaceID,
            tabID: tabID,
            pairID: UUID(),
            lane: .secondary,
            shortID: "secondary-oracle"
        )
        let request = try XCTUnwrap(AgentOraclePillLogic.explicitOpenRequest(
            chatID: secondary.shortID,
            workspaceID: workspaceID,
            tabID: tabID,
            generation: 3,
            lane: .secondary
        ))

        XCTAssertTrue(AgentOraclePillLogic.shouldPresent(
            session: secondary,
            for: request,
            currentGeneration: 3,
            currentWorkspaceID: workspaceID,
            currentTabID: tabID,
            lane: .secondary
        ))
        XCTAssertFalse(AgentOraclePillLogic.shouldPresent(
            session: secondary,
            for: request,
            currentGeneration: 3,
            currentWorkspaceID: workspaceID,
            currentTabID: tabID,
            lane: .primary
        ))
        XCTAssertFalse(AgentOraclePillLogic.shouldPresent(
            session: secondary,
            for: request,
            currentGeneration: 4,
            currentWorkspaceID: workspaceID,
            currentTabID: tabID,
            lane: .secondary
        ))
        XCTAssertFalse(AgentOraclePillLogic.shouldPresent(
            session: secondary,
            for: request,
            currentGeneration: 3,
            currentWorkspaceID: UUID(),
            currentTabID: tabID,
            lane: .secondary
        ))
    }

    func testStatusKeepsTerminalOutcomeAndStreamingWins() {
        XCTAssertEqual(AgentOraclePillLogic.status(isStreaming: false, outcome: nil), .idle)
        XCTAssertEqual(AgentOraclePillLogic.status(isStreaming: false, outcome: .completed), .completed)
        XCTAssertEqual(
            AgentOraclePillLogic.status(isStreaming: false, outcome: .failed("provider unavailable")),
            .failed("provider unavailable")
        )
        XCTAssertEqual(
            AgentOraclePillLogic.status(isStreaming: true, outcome: .failed("stale failure")),
            .streaming
        )
    }

    func testOnlyLegacyOrPrimaryPresentationAcceptsLatestRoute() {
        XCTAssertTrue(AgentOraclePillLogic.acceptsLatestRoute(.legacySingle))
        XCTAssertTrue(AgentOraclePillLogic.acceptsLatestRoute(.pairedLane(.primary)))
        XCTAssertFalse(AgentOraclePillLogic.acceptsLatestRoute(.pairedLane(.secondary)))
    }

    func testStreamingFirstOrderingRemainsLaneLocal() {
        let now = Date()
        let olderPrimaryStreaming = makeSession(
            savedAt: now.addingTimeInterval(-20),
            pairID: UUID(),
            lane: .primary
        )
        let newerPrimary = makeSession(savedAt: now, pairID: UUID(), lane: .primary)
        let newestSecondaryStreaming = makeSession(
            savedAt: now.addingTimeInterval(20),
            pairID: UUID(),
            lane: .secondary
        )
        let streamingIDs: Set<UUID> = [olderPrimaryStreaming.id, newestSecondaryStreaming.id]

        XCTAssertEqual(
            AgentOraclePillLogic.latestSession(
                in: [newestSecondaryStreaming, newerPrimary, olderPrimaryStreaming],
                streamingSessionIDs: streamingIDs,
                lane: .primary
            )?.id,
            olderPrimaryStreaming.id
        )
        XCTAssertEqual(
            AgentOraclePillLogic.latestSession(
                in: [olderPrimaryStreaming, newerPrimary, newestSecondaryStreaming],
                streamingSessionIDs: streamingIDs,
                lane: .secondary
            )?.id,
            newestSecondaryStreaming.id
        )
    }
}
