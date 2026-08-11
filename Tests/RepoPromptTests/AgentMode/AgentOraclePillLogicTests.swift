import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentOraclePillLogicTests: XCTestCase {
    private func makeSession(
        savedAt: Date = Date(),
        messageCount: Int? = nil,
        workspaceID: UUID? = nil,
        tabID: UUID? = nil,
        pairID: UUID? = nil,
        lane: OracleLane? = nil,
        shortID: String? = nil
    ) -> ChatSession {
        ChatSession(
            workspaceID: workspaceID,
            composeTabID: tabID,
            oraclePairID: pairID,
            oracleLane: lane,
            name: "Oracle",
            savedAt: savedAt,
            messageCount: messageCount,
            shortID: shortID
        )
    }

    func testPresentationsUseConfigurationOrExistingSecondaryLane() {
        for raw in [String?.none, "", " \n\t "] {
            XCTAssertEqual(AgentOraclePillLogic.presentations(secondaryModelRaw: raw), [.legacySingle])
        }
        XCTAssertEqual(
            AgentOraclePillLogic.presentations(secondaryModelRaw: "not-a-model"),
            [.legacySingle]
        )
        let paired: [AgentOraclePillPresentation] = [.pairedLane(.primary), .pairedLane(.secondary)]
        XCTAssertEqual(
            AgentOraclePillLogic.presentations(secondaryModelRaw: AIModel.claude4Sonnet.rawValue),
            paired
        )
        XCTAssertEqual(
            AgentOraclePillLogic.presentations(secondaryModelRaw: nil, hasSecondarySession: true),
            paired
        )
    }

    func testPresentationsScaleToFiveConfiguredOraclesInStableOrder() {
        let model = AIModel.claude4Sonnet.rawValue
        XCTAssertEqual(
            AgentOraclePillLogic.presentations(
                additionalModelRaws: Array(repeating: model, count: 4)
            ),
            OracleLane.allCases.map { .pairedLane($0) }
        )
        XCTAssertEqual(AgentOraclePillPresentation.pairedLane(.primary).label, "Primary Oracle")
        XCTAssertEqual(AgentOraclePillPresentation.pairedLane(.oracle5).label, "Oracle 5")
    }

    func testHistoricalGroupLanesRemainVisibleAfterConfigurationRemoval() {
        XCTAssertEqual(
            AgentOraclePillLogic.presentations(
                additionalModelRaws: [],
                groupSessionLanes: Set(OracleLane.allCases)
            ),
            OracleLane.allCases.map { .pairedLane($0) }
        )
    }

    func testLaneResolutionPreservesLegacyPrimaryAndRejectsMalformedMetadata() {
        XCTAssertEqual(AgentOraclePillLogic.resolvedLane(for: makeSession()), .primary)
        XCTAssertEqual(AgentOraclePillLogic.resolvedLane(for: makeSession(pairID: UUID(), lane: .primary)), .primary)
        XCTAssertEqual(AgentOraclePillLogic.resolvedLane(for: makeSession(pairID: UUID(), lane: .secondary)), .secondary)
        XCTAssertNil(AgentOraclePillLogic.resolvedLane(for: makeSession(pairID: UUID())))
        XCTAssertNil(AgentOraclePillLogic.resolvedLane(for: makeSession(lane: .primary)))
        XCTAssertNil(AgentOraclePillLogic.resolvedLane(for: makeSession(lane: .secondary)))
    }

    func testLaneFilteringKeepsPrimaryAndSecondaryIndependent() {
        let legacy = makeSession(messageCount: 1)
        let primary = makeSession(messageCount: 1, pairID: UUID(), lane: .primary)
        let secondary = makeSession(messageCount: 1, pairID: UUID(), lane: .secondary)

        let primarySessions = AgentOraclePillLogic.sessions(
            [secondary, primary, legacy],
            resolvedTo: .primary
        )
        let secondarySessions = AgentOraclePillLogic.sessions(
            [legacy, primary, secondary],
            resolvedTo: .secondary
        )

        XCTAssertEqual(Set(primarySessions.map(\.id)), Set([legacy.id, primary.id]))
        XCTAssertEqual(secondarySessions.map(\.id), [secondary.id])
    }

    func testLaneWithoutEligibleSessionHasNoPillTarget() {
        let legacy = makeSession(messageCount: 1)
        let secondarySessions = AgentOraclePillLogic.sessions([legacy], resolvedTo: .secondary)

        XCTAssertTrue(secondarySessions.isEmpty)
        XCTAssertNil(AgentOraclePillLogic.latestSession(
            in: secondarySessions,
            streamingSessionIDs: []
        ))
    }

    func testExactOpenRequiresMatchingLaneAndRoute() throws {
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
            generation: 3
        ))

        XCTAssertTrue(AgentOraclePillLogic.shouldPresent(
            session: secondary,
            for: request,
            currentGeneration: 3,
            currentWorkspaceID: workspaceID,
            currentTabID: tabID,
            expectedLane: .secondary
        ))
        XCTAssertFalse(AgentOraclePillLogic.shouldPresent(
            session: secondary,
            for: request,
            currentGeneration: 3,
            currentWorkspaceID: workspaceID,
            currentTabID: tabID,
            expectedLane: .primary
        ))
    }

    func testStreamingFirstSelectionRemainsLaneLocal() {
        let now = Date()
        let primaryStreaming = makeSession(savedAt: now.addingTimeInterval(-10), pairID: UUID(), lane: .primary)
        let primaryNewer = makeSession(savedAt: now, pairID: UUID(), lane: .primary)
        let secondaryStreaming = makeSession(savedAt: now.addingTimeInterval(10), pairID: UUID(), lane: .secondary)
        let streaming: Set<UUID> = [primaryStreaming.id, secondaryStreaming.id]

        let primarySessions = AgentOraclePillLogic.sessions(
            [secondaryStreaming, primaryNewer, primaryStreaming],
            resolvedTo: .primary
        )
        let secondarySessions = AgentOraclePillLogic.sessions(
            [primaryStreaming, primaryNewer, secondaryStreaming],
            resolvedTo: .secondary
        )
        XCTAssertEqual(
            AgentOraclePillLogic.latestSession(
                in: primarySessions,
                streamingSessionIDs: streaming
            )?.id,
            primaryStreaming.id
        )
        XCTAssertEqual(
            AgentOraclePillLogic.latestSession(
                in: secondarySessions,
                streamingSessionIDs: streaming
            )?.id,
            secondaryStreaming.id
        )
    }
}
