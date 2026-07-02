import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class AgentModeSourceItemIntegrityTests: XCTestCase {
    func testEphemeralPayloadMapKeepsFirstDuplicateRetainedToolResultPayload() throws {
        let duplicateID = UUID()
        let first = try retainedAgentRunToolResult(id: duplicateID, marker: "first", sequenceIndex: 0)
        let second = try retainedAgentRunToolResult(id: duplicateID, marker: "second", sequenceIndex: 1)
        let firstPayload = try XCTUnwrap(AgentToolResultPersistencePolicy.retainedEphemeralRawPayload(for: first))
        let secondPayload = try XCTUnwrap(AgentToolResultPersistencePolicy.retainedEphemeralRawPayload(for: second))
        XCTAssertNotEqual(firstPayload, secondPayload)

        let payloads = AgentModeViewModel.rebuildEphemeralToolResultPayloadMap(
            from: [first, second],
            diagnosticContext: "test_duplicate_retained_payload"
        )

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[duplicateID], firstPayload)
    }

    func testTabSessionSetItemsSilentlyRepairsDuplicateRetainedToolResultIDs() throws {
        let duplicateID = UUID()
        let first = try retainedAgentRunToolResult(id: duplicateID, marker: "first", sequenceIndex: 0)
        let second = try retainedAgentRunToolResult(id: duplicateID, marker: "second", sequenceIndex: 1)
        let firstPayload = try XCTUnwrap(AgentToolResultPersistencePolicy.retainedEphemeralRawPayload(for: first))
        let secondPayload = try XCTUnwrap(AgentToolResultPersistencePolicy.retainedEphemeralRawPayload(for: second))
        let session = AgentModeViewModel.TabSession(tabID: UUID())

        session.setItemsSilently([first, second], reason: .testOverride)

        XCTAssertEqual(session.items.count, 2)
        XCTAssertEqual(Set(session.items.map(\.id)).count, 2)
        XCTAssertEqual(session.items.count(where: { $0.id == duplicateID }), 1)
        let rekeyedItem = try XCTUnwrap(session.items.first { $0.id != duplicateID })
        XCTAssertEqual(rekeyedItem.text, second.text)
        XCTAssertEqual(session.ephemeralToolResultPayloadByItemID.count, 2)
        XCTAssertEqual(session.ephemeralToolResultPayloadByItemID[duplicateID], firstPayload)
        XCTAssertEqual(session.ephemeralToolResultPayloadByItemID[rekeyedItem.id], secondPayload)
    }

    func testTabSessionSetItemsSilentlyDropsExactDuplicateRows() throws {
        let duplicateID = UUID()
        let item = try retainedAgentRunToolResult(id: duplicateID, marker: "exact", sequenceIndex: 0)
        let payload = try XCTUnwrap(AgentToolResultPersistencePolicy.retainedEphemeralRawPayload(for: item))
        let session = AgentModeViewModel.TabSession(tabID: UUID())

        session.setItemsSilently([item, item], reason: .testOverride)

        XCTAssertEqual(session.items, [item])
        XCTAssertEqual(session.liveItemIDs, Set([duplicateID]))
        XCTAssertEqual(session.ephemeralToolResultPayloadByItemID, [duplicateID: payload])
    }

    func testWorkingSourceItemsRepairsDuplicateActivityIDsFromMalformedTranscript() {
        let duplicateID = UUID()
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        let first = AgentTranscriptActivity(
            id: duplicateID,
            timestamp: startedAt,
            sequenceIndex: 0,
            role: .assistant,
            itemKind: .assistant,
            text: "first assistant row"
        )
        let second = AgentTranscriptActivity(
            id: duplicateID,
            timestamp: startedAt.addingTimeInterval(1),
            sequenceIndex: 1,
            role: .assistant,
            itemKind: .assistant,
            text: "second assistant row"
        )
        let transcript = AgentTranscript(
            turns: [
                AgentTranscriptTurn(
                    responseSpans: [
                        AgentTranscriptProviderResponseSpan(
                            lifecycle: .completed,
                            startedAt: startedAt,
                            completedAt: startedAt.addingTimeInterval(2),
                            activities: [first, second]
                        )
                    ],
                    startedAt: startedAt,
                    completedAt: startedAt.addingTimeInterval(2)
                )
            ],
            nextSequenceIndex: 2
        )

        let rows = AgentTranscriptIO.workingSourceItems(from: transcript)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
        XCTAssertEqual(rows.map(\.text), ["first assistant row", "second assistant row"])
        XCTAssertEqual(rows[0].id, duplicateID)
        XCTAssertNotEqual(rows[1].id, duplicateID)
    }

    private func retainedAgentRunToolResult(
        id: UUID,
        marker: String,
        sequenceIndex: Int
    ) throws -> AgentChatItem {
        let raw = try jsonString([
            "status": "success",
            "session_id": "session-\(marker)",
            "transcript_item_count": sequenceIndex + 10,
            "response": String(repeating: "raw \(marker) response ", count: 80)
        ])
        return AgentChatItem(
            id: id,
            timestamp: Date(timeIntervalSinceReferenceDate: TimeInterval(sequenceIndex)),
            kind: .toolResult,
            text: raw,
            toolName: "agent_run",
            toolInvocationID: UUID(),
            toolResultJSON: raw,
            toolIsError: false,
            sequenceIndex: sequenceIndex
        )
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
