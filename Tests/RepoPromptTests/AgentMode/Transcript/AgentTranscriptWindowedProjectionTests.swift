import Foundation
@testable import RepoPrompt
import XCTest

final class AgentTranscriptWindowedProjectionTests: XCTestCase {
    func testLargeTranscriptProjectionEmitsCollapsedRangeAndFullTail() {
        let transcript = makeTranscript(turnCount: 45)
        let projection = AgentTranscriptProjectionBuilder.build(from: transcript)

        let windowed = AgentTranscriptProjectionBuilder.tailWindowedProjection(
            from: AgentTranscriptProjectionBuilder.workingProjection(from: projection),
            transcript: transcript,
            isExpanded: false
        )

        XCTAssertEqual(windowed.workingBlocks.first?.kind, .collapsedHistoryRange)
        XCTAssertEqual(windowed.workingBlocks.first?.collapsedHistoryRange?.hiddenTurnCount, 5)
        XCTAssertEqual(windowed.workingBlocks.first?.id, "collapsed-range:\(transcript.turns[0].id.uuidString)")
        XCTAssertEqual(windowed.workingBlocks.count(where: { $0.kind != .collapsedHistoryRange }), 80)
        XCTAssertEqual(windowed.workingRows.count, 80)
        XCTAssertEqual(orderedUniqueTurnIDs(windowed.workingBlocks.filter { $0.kind != .collapsedHistoryRange }.map(\.turnID)), transcript.turns.suffix(40).map(\.id))
    }

    func testOpenTurnRemainsVisibleEvenWhenOlderThanTail() {
        var transcript = makeTranscript(turnCount: 45)
        transcript.turns[0] = makeTurn(index: 0, completed: false)
        let projection = AgentTranscriptProjectionBuilder.build(from: transcript)

        let windowed = AgentTranscriptProjectionBuilder.tailWindowedProjection(
            from: AgentTranscriptProjectionBuilder.workingProjection(from: projection),
            transcript: transcript,
            isExpanded: false
        )

        XCTAssertTrue(windowed.workingBlocks.contains { $0.turnID == transcript.turns[0].id && $0.kind != .collapsedHistoryRange })
        XCTAssertEqual(windowed.workingBlocks.first(where: { $0.kind == .collapsedHistoryRange })?.collapsedHistoryRange?.hiddenTurnCount, 4)
    }

    func testExpandedFlagRestoresExactProjectionRowsAndBlocks() {
        let transcript = makeTranscript(turnCount: 45)
        let projection = AgentTranscriptProjectionBuilder.workingProjection(
            from: AgentTranscriptProjectionBuilder.build(from: transcript)
        )

        let expanded = AgentTranscriptProjectionBuilder.tailWindowedProjection(
            from: projection,
            transcript: transcript,
            isExpanded: true
        )

        XCTAssertEqual(expanded, projection)
    }

    func testAppendingNewMessagesPreservesStableCollapsedRangeIDAndFullTail() {
        let initialTranscript = makeTranscript(turnCount: 45)
        let updatedTranscript = makeTranscript(turnCount: 46, turnIDs: initialTranscript.turns.map(\.id) + [UUID()])
        let initialProjection = AgentTranscriptProjectionBuilder.workingProjection(
            from: AgentTranscriptProjectionBuilder.build(from: initialTranscript)
        )
        let updatedProjection = AgentTranscriptProjectionBuilder.workingProjection(
            from: AgentTranscriptProjectionBuilder.build(from: updatedTranscript)
        )

        let initialWindowed = AgentTranscriptProjectionBuilder.tailWindowedProjection(
            from: initialProjection,
            transcript: initialTranscript,
            isExpanded: false
        )
        let updatedWindowed = AgentTranscriptProjectionBuilder.tailWindowedProjection(
            from: updatedProjection,
            transcript: updatedTranscript,
            isExpanded: false
        )

        XCTAssertEqual(initialWindowed.workingBlocks.first?.id, updatedWindowed.workingBlocks.first?.id)
        XCTAssertEqual(updatedWindowed.workingBlocks.count(where: { $0.kind != .collapsedHistoryRange }), 80)
        XCTAssertEqual(updatedWindowed.workingBlocks.last?.turnID, updatedTranscript.turns.last?.id)
    }

    func testHiddenAnchorRemapsToCollapsedRangeAndVisibleAnchorsRemainUnchanged() throws {
        let transcript = makeTranscript(turnCount: 45)
        let projection = AgentTranscriptProjectionBuilder.workingProjection(
            from: AgentTranscriptProjectionBuilder.build(from: transcript)
        )
        let hiddenAnchor = AgentTranscriptAnchor.request(turnID: transcript.turns[0].id)
        let visibleAnchor = AgentTranscriptAnchor.request(turnID: transcript.turns[44].id)
        let originalVisibleBlockID = try XCTUnwrap(projection.anchorBlockIndex[visibleAnchor])

        let windowed = AgentTranscriptProjectionBuilder.tailWindowedProjection(
            from: projection,
            transcript: transcript,
            isExpanded: false
        )

        XCTAssertEqual(windowed.anchorBlockIndex[hiddenAnchor], "collapsed-range:\(transcript.turns[0].id.uuidString)")
        XCTAssertEqual(windowed.anchorBlockIndex[visibleAnchor], originalVisibleBlockID)
    }

    private func orderedUniqueTurnIDs(_ ids: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        var ordered: [UUID] = []
        for id in ids where seen.insert(id).inserted {
            ordered.append(id)
        }
        return ordered
    }

    private func makeTranscript(turnCount: Int, turnIDs: [UUID]? = nil) -> AgentTranscript {
        AgentTranscript(
            turns: (0 ..< turnCount).map { index in
                makeTurn(index: index, id: turnIDs?[index] ?? UUID())
            },
            nextSequenceIndex: turnCount * 2
        )
    }

    private func makeTurn(index: Int, id: UUID = UUID(), completed: Bool = true) -> AgentTranscriptTurn {
        let startedAt = Date(timeIntervalSinceReferenceDate: TimeInterval(index))
        let user = AgentChatItem.user("request \(index)", sequenceIndex: index * 2)
        let assistant = AgentChatItem.assistant("response \(index)", sequenceIndex: index * 2 + 1)
        let activity = AgentTranscriptActivity(from: assistant)
        let completedAt = completed ? startedAt.addingTimeInterval(1) : nil
        return AgentTranscriptTurn(
            id: id,
            request: AgentTranscriptRequestAnchor(from: user),
            responseSpans: [
                AgentTranscriptProviderResponseSpan(
                    lifecycle: completed ? .completed : .open,
                    startedAt: startedAt,
                    lastActivityAt: completedAt,
                    completedAt: completedAt,
                    activities: [activity]
                )
            ],
            retentionTier: .full,
            terminalState: completed ? .completed : .running,
            startedAt: startedAt,
            lastActivityAt: completedAt,
            completedAt: completedAt
        )
    }
}
