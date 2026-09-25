import Foundation
@testable import RepoPromptApp
import XCTest

/// `updatedTurnCaches(for:projection:...)` must produce the same per-turn slices as the
/// historical per-turn `filter` implementation: blocks and rows scoped to the turn in
/// projection order, anchor maps keyed by the anchor's owning turn, and the loop's
/// retention rules (incomplete turns evict, protected turns keep their existing cache,
/// foreign turns are dropped) unchanged.
final class AgentTranscriptTurnCacheGroupingTests: XCTestCase {
    // MARK: - Fixtures

    private func makeFullTurn(
        index: Int,
        id: UUID = UUID(),
        retentionTier: AgentTranscriptRetentionTier = .full
    ) -> AgentTranscriptTurn {
        let startedAt = Date(timeIntervalSince1970: TimeInterval(index * 10))
        let user = AgentChatItem.user("request \(index)", sequenceIndex: index * 3)
        let thinking = AgentChatItem.thinking("thinking \(index)", sequenceIndex: index * 3 + 1)
        let assistant = AgentChatItem.assistant("response \(index)", sequenceIndex: index * 3 + 2)
        return AgentTranscriptTurn(
            id: id,
            request: AgentTranscriptRequestAnchor(from: user),
            responseSpans: [
                AgentTranscriptProviderResponseSpan(
                    lifecycle: .completed,
                    startedAt: startedAt,
                    lastActivityAt: startedAt.addingTimeInterval(1),
                    completedAt: startedAt.addingTimeInterval(1),
                    activities: [
                        AgentTranscriptActivity(from: thinking),
                        AgentTranscriptActivity(from: assistant)
                    ]
                )
            ],
            retentionTier: retentionTier,
            terminalState: .completed,
            startedAt: startedAt,
            lastActivityAt: startedAt.addingTimeInterval(1),
            completedAt: startedAt.addingTimeInterval(1)
        )
    }

    private func makeActiveTurn(index: Int) -> AgentTranscriptTurn {
        let startedAt = Date(timeIntervalSince1970: TimeInterval(index * 10))
        let user = AgentChatItem.user("active request \(index)", sequenceIndex: index * 3)
        let assistant = AgentChatItem.assistant("partial \(index)", sequenceIndex: index * 3 + 1)
        return AgentTranscriptTurn(
            id: UUID(),
            request: AgentTranscriptRequestAnchor(from: user),
            responseSpans: [
                AgentTranscriptProviderResponseSpan(
                    lifecycle: .open,
                    startedAt: startedAt,
                    lastActivityAt: startedAt,
                    activities: [AgentTranscriptActivity(from: assistant)]
                )
            ],
            retentionTier: .full,
            terminalState: .running,
            startedAt: startedAt,
            lastActivityAt: startedAt
        )
    }

    private func makeEmptyCompletedTurn(index: Int) -> AgentTranscriptTurn {
        let startedAt = Date(timeIntervalSince1970: TimeInterval(index * 10))
        return AgentTranscriptTurn(
            id: UUID(),
            request: nil,
            responseSpans: [],
            retentionTier: .full,
            terminalState: .completed,
            startedAt: startedAt,
            lastActivityAt: startedAt,
            completedAt: startedAt
        )
    }

    private func makeCache(turnID: UUID) -> AgentTranscriptTurnProjectionCache {
        AgentTranscriptTurnProjectionCache(
            token: .init(
                turnID: turnID,
                retentionTier: .full,
                isCompleted: true,
                responseSpanCount: 0,
                activityCount: 0,
                conclusionActivityID: nil,
                frozenDetailedToolTailLimit: nil
            ),
            workingBlocks: [],
            archivedBlocks: [],
            workingRows: [],
            archivedRows: [],
            rowAnchorIndex: [:],
            anchorBlockIndex: [:]
        )
    }

    private func anchorTurnID(_ anchor: AgentTranscriptAnchor) -> UUID {
        switch anchor {
        case let .request(turnID), let .summary(turnID), let .groupedHistory(turnID, _):
            turnID
        case let .activity(turnID, _, _), let .conclusion(turnID, _):
            turnID
        }
    }

    // MARK: - Per-turn slicing

    func testCachesSliceBlocksRowsAndAnchorsPerTurn() throws {
        let turn0 = makeFullTurn(index: 0)
        let turn1 = makeFullTurn(index: 1)
        let archivedTurn = makeFullTurn(index: 2, retentionTier: .archived)
        let transcript = AgentTranscript(turns: [turn0, turn1, archivedTurn], nextSequenceIndex: 9)
        let projection = AgentTranscriptProjectionBuilder.build(from: transcript)

        let caches = AgentTranscriptProjectionBuilder.updatedTurnCaches(
            for: transcript,
            projection: projection
        )

        XCTAssertEqual(Set(caches.keys), [turn0.id, turn1.id, archivedTurn.id])
        for turn in [turn0, turn1, archivedTurn] {
            let cache = try XCTUnwrap(caches[turn.id])
            XCTAssertEqual(
                cache.workingBlocks,
                projection.workingBlocks.filter { $0.turnID == turn.id }
            )
            XCTAssertEqual(
                cache.archivedBlocks,
                projection.archivedBlocks.filter { $0.turnID == turn.id }
            )
            // Rows are reconstructed from the turn's blocks in block order; grouped and
            // collapsed blocks contribute no rows.
            let expectedRows = cache.workingBlocks
                .filter { $0.kind != .groupedHistory && $0.kind != .collapsedHistoryRange }
                .flatMap(\.rows)
            XCTAssertEqual(cache.workingRows, expectedRows)
            let expectedArchivedRows = cache.archivedBlocks
                .filter { $0.kind != .groupedHistory && $0.kind != .collapsedHistoryRange }
                .flatMap(\.rows)
            XCTAssertEqual(cache.archivedRows, expectedArchivedRows)
            // Anchor maps equal the projection maps filtered by owning turn, in full.
            XCTAssertEqual(
                cache.rowAnchorIndex,
                projection.rowAnchorIndex.filter { anchorTurnID($0.value) == turn.id }
            )
            XCTAssertEqual(
                cache.anchorBlockIndex,
                projection.anchorBlockIndex.filter { anchorTurnID($0.key) == turn.id }
            )
            XCTAssertEqual(cache.token.turnID, turn.id)
        }
        // The archived-tier turn produced real archived blocks, so the archived slicing
        // assertions above are not vacuous.
        XCTAssertFalse(caches[archivedTurn.id]?.archivedBlocks.isEmpty ?? true)
    }

    func testCompletedTurnWithNoBlocksStillGetsAnEmptyCache() throws {
        let emptyTurn = makeEmptyCompletedTurn(index: 0)
        let transcript = AgentTranscript(turns: [emptyTurn], nextSequenceIndex: 0)
        let projection = AgentTranscriptProjectionBuilder.build(from: transcript)

        let caches = AgentTranscriptProjectionBuilder.updatedTurnCaches(
            for: transcript,
            projection: projection
        )

        let cache = try XCTUnwrap(caches[emptyTurn.id])
        XCTAssertTrue(cache.workingBlocks.isEmpty)
        XCTAssertTrue(cache.archivedBlocks.isEmpty)
        XCTAssertTrue(cache.workingRows.isEmpty)
        XCTAssertTrue(cache.archivedRows.isEmpty)
        XCTAssertTrue(cache.rowAnchorIndex.isEmpty)
        XCTAssertTrue(cache.anchorBlockIndex.isEmpty)
    }

    // MARK: - Retention rules

    func testIncompleteTurnDropsItsExistingCache() {
        let activeTurn = makeActiveTurn(index: 0)
        let transcript = AgentTranscript(turns: [activeTurn], nextSequenceIndex: 3)
        let projection = AgentTranscriptProjectionBuilder.build(from: transcript)

        let caches = AgentTranscriptProjectionBuilder.updatedTurnCaches(
            for: transcript,
            projection: projection,
            existingTurnCaches: [activeTurn.id: makeCache(turnID: activeTurn.id)]
        )

        XCTAssertNil(caches[activeTurn.id])
    }

    func testProtectedTurnKeepsItsExistingCacheVerbatim() {
        let protected = makeFullTurn(index: 0)
        let other = makeFullTurn(index: 1)
        let transcript = AgentTranscript(turns: [protected, other], nextSequenceIndex: 6)
        let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
        let existing = makeCache(turnID: protected.id)

        let caches = AgentTranscriptProjectionBuilder.updatedTurnCaches(
            for: transcript,
            projection: projection,
            protection: .protectedTurn(protected.id),
            existingTurnCaches: [protected.id: existing]
        )

        XCTAssertEqual(caches[protected.id], existing)
        XCTAssertNotNil(caches[other.id])
    }

    func testCachesForTurnsAbsentFromTranscriptAreDropped() {
        let turn = makeFullTurn(index: 0)
        let transcript = AgentTranscript(turns: [turn], nextSequenceIndex: 3)
        let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
        let foreignID = UUID()

        let caches = AgentTranscriptProjectionBuilder.updatedTurnCaches(
            for: transcript,
            projection: projection,
            existingTurnCaches: [
                turn.id: makeCache(turnID: turn.id),
                foreignID: makeCache(turnID: foreignID)
            ]
        )

        XCTAssertNil(caches[foreignID])
        XCTAssertNotNil(caches[turn.id])
        // The kept turn's cache is rebuilt from the projection, not retained verbatim.
        XCTAssertEqual(
            caches[turn.id]?.token,
            AgentTranscriptProjectionBuilder.validationToken(for: turn)
        )
    }

    func testDuplicateTurnIDsProduceOneCacheWithAllMatchingBlocks() throws {
        let sharedID = UUID()
        let first = makeFullTurn(index: 0, id: sharedID)
        let second = makeFullTurn(index: 1, id: sharedID)
        let transcript = AgentTranscript(turns: [first, second], nextSequenceIndex: 6)
        let projection = AgentTranscriptProjectionBuilder.build(from: transcript)

        let caches = AgentTranscriptProjectionBuilder.updatedTurnCaches(
            for: transcript,
            projection: projection
        )

        let cache = try XCTUnwrap(caches[sharedID])
        // Both occurrences slice the same projection, so the surviving cache contains
        // every block bearing the shared turn ID — identical to the old filter behavior.
        XCTAssertEqual(
            cache.workingBlocks,
            projection.workingBlocks.filter { $0.turnID == sharedID }
        )
    }
}
