import Foundation
@testable import RepoPrompt
import XCTest

final class AgentTranscriptGroupedHistoryBudgetTests: XCTestCase {
    func testProjectionCachesPreserveAnchorIndexesOnReuse() throws {
        var sequenceIndex = 0
        let items = makeTurnItems(label: "older", toolCount: 10, sequenceIndex: &sequenceIndex)
            + makeTurnItems(label: "newer", toolCount: 4, sequenceIndex: &sequenceIndex)
        let transcript = AgentTranscriptIO.buildTranscript(
            from: items,
            terminalState: .completed,
            nextSequenceIndex: sequenceIndex,
            compact: false
        )
        let refreshedTranscript = AgentTranscriptProjectionBuilder
            .refreshCompletedFullTurnGroupedHistoryCaches(in: transcript)

        let coldBuild = AgentTranscriptProjectionBuilder.buildWithCaches(
            from: refreshedTranscript,
            turnCaches: [:]
        )
        let cachedBuild = AgentTranscriptProjectionBuilder.buildWithCaches(
            from: refreshedTranscript,
            turnCaches: coldBuild.updatedTurnCaches
        )

        XCTAssertEqual(coldBuild.updatedTurnCaches.count, refreshedTranscript.turns.count)
        for turn in refreshedTranscript.turns {
            let cache = try XCTUnwrap(coldBuild.updatedTurnCaches[turn.id])
            XCTAssertTrue(cache.rowAnchorIndex.values.allSatisfy { anchorTurnID($0) == turn.id })
            XCTAssertTrue(cache.anchorBlockIndex.keys.allSatisfy { anchorTurnID($0) == turn.id })
        }
        XCTAssertFalse(coldBuild.projection.rowAnchorIndex.isEmpty)
        XCTAssertFalse(coldBuild.projection.anchorBlockIndex.isEmpty)
        XCTAssertEqual(cachedBuild.projection, coldBuild.projection)
        XCTAssertEqual(cachedBuild.updatedTurnCaches, coldBuild.updatedTurnCaches)
    }

    func testReusablePrefixCacheTightensWhenNewerTurnConsumesDetailedToolBudget() throws {
        var sequenceIndex = 0
        let olderItems = makeTurnItems(label: "older", toolCount: 10, sequenceIndex: &sequenceIndex)
        let initialNewerItems = makeTurnItems(label: "newer", toolCount: 1, sequenceIndex: &sequenceIndex)
        let initialItems = olderItems + initialNewerItems
        let initialTranscript = AgentTranscriptIO.buildTranscript(
            from: initialItems,
            terminalState: .completed,
            nextSequenceIndex: sequenceIndex,
            compact: false
        )
        let refreshedInitial = AgentTranscriptProjectionBuilder
            .refreshCompletedFullTurnGroupedHistoryCaches(in: initialTranscript)
        XCTAssertEqual(refreshedInitial.turns.count, 2)
        let initialOlderLimit = try XCTUnwrap(
            refreshedInitial.turns[0].responseSpans
                .compactMap(\.fullRenderGroupedHistoryCache?.detailedToolTailLimit)
                .first
        )
        XCTAssertEqual(initialOlderLimit, 7)

        var updatedSequenceIndex = olderItems.count
        let updatedNewerItems = makeTurnItems(
            label: "newer-updated",
            toolCount: 5,
            sequenceIndex: &updatedSequenceIndex,
            userItem: initialNewerItems[0]
        )
        let updatedNewerTranscript = AgentTranscriptIO.buildTranscript(
            from: updatedNewerItems,
            terminalState: .completed,
            nextSequenceIndex: updatedSequenceIndex,
            compact: false
        )
        var incrementallyUpdated = refreshedInitial
        incrementallyUpdated.turns[1] = try XCTUnwrap(updatedNewerTranscript.turns.first)
        incrementallyUpdated.nextSequenceIndex = updatedSequenceIndex

        let refreshedUpdated = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(
            in: incrementallyUpdated,
            reusablePrefixTurnCount: 1
        )
        let shiftedOlderLimit = try XCTUnwrap(
            refreshedUpdated.turns[0].responseSpans
                .compactMap(\.fullRenderGroupedHistoryCache?.detailedToolTailLimit)
                .first
        )

        XCTAssertEqual(shiftedOlderLimit, 3)
        XCTAssertEqual(refreshedUpdated.turns[0].frozenDetailedToolTailLimit, 3)
    }

    private func anchorTurnID(_ anchor: AgentTranscriptAnchor) -> UUID {
        switch anchor {
        case let .request(turnID),
             let .summary(turnID):
            turnID
        case let .activity(turnID, _, _),
             let .conclusion(turnID, _),
             let .groupedHistory(turnID, _):
            turnID
        }
    }

    private func makeTurnItems(
        label: String,
        toolCount: Int,
        sequenceIndex: inout Int,
        userItem: AgentChatItem? = nil
    ) -> [AgentChatItem] {
        var items: [AgentChatItem] = []
        let user = userItem ?? .user("\(label) request", sequenceIndex: sequenceIndex)
        items.append(user)
        sequenceIndex += 1
        for toolIndex in 0 ..< toolCount {
            let invocationID = UUID()
            items.append(.toolCall(
                name: "read_file",
                invocationID: invocationID,
                argsJSON: #"{"path":"/tmp/file.swift"}"#,
                sequenceIndex: sequenceIndex
            ))
            sequenceIndex += 1
            items.append(.toolResult(
                name: "read_file",
                invocationID: invocationID,
                resultJSON: #"{"content":"ok"}"#,
                sequenceIndex: sequenceIndex
            ))
            sequenceIndex += 1
        }
        items.append(.assistant("\(label) done", sequenceIndex: sequenceIndex))
        sequenceIndex += 1
        return items
    }
}
