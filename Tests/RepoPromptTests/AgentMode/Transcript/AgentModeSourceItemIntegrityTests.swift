import Foundation
@testable import RepoPromptApp
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

    func testAppendAndReplaceRepairOnlyActualLiveIDCollisions() {
        let firstID = UUID()
        let secondID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.setItemsSilently([
            AgentChatItem(id: firstID, kind: .assistant, text: "first", sequenceIndex: 0),
            AgentChatItem(id: secondID, kind: .assistant, text: "second", sequenceIndex: 1)
        ], reason: .testOverride)
        #if DEBUG
            let initialRepairPassCount = session.test_sourceItemIDRepairPassCount
        #endif

        let replacementID = UUID()
        session.replaceItem(
            at: 1,
            with: AgentChatItem(id: replacementID, kind: .assistant, text: "ordinary replace", sequenceIndex: 1)
        )
        session.appendItem(.assistant("ordinary append"))

        XCTAssertEqual(session.items[1].id, replacementID)
        #if DEBUG
            XCTAssertEqual(session.test_sourceItemIDRepairPassCount, initialRepairPassCount)
        #endif

        session.appendItem(AgentChatItem(id: firstID, kind: .assistant, text: "append collision"))

        XCTAssertEqual(session.items.count, 4)
        XCTAssertEqual(session.items.count(where: { $0.id == firstID }), 1)
        XCTAssertEqual(Set(session.items.map(\.id)).count, 4)
        XCTAssertEqual(session.items.last?.text, "append collision")
        XCTAssertNotEqual(session.items.last?.id, firstID)
        #if DEBUG
            let postAppendRepairPassCount = session.test_sourceItemIDRepairPassCount
            XCTAssertGreaterThan(postAppendRepairPassCount, initialRepairPassCount)
        #endif

        let replacement = AgentChatItem(
            id: firstID,
            kind: .assistant,
            text: "replace collision",
            sequenceIndex: session.items[1].sequenceIndex
        )
        session.replaceItem(at: 1, with: replacement)

        XCTAssertEqual(session.items.count, 4)
        XCTAssertEqual(session.items.count(where: { $0.id == firstID }), 1)
        XCTAssertEqual(Set(session.items.map(\.id)).count, 4)
        XCTAssertEqual(session.items[1].text, "replace collision")
        XCTAssertNotEqual(session.items[1].id, firstID)
        #if DEBUG
            XCTAssertGreaterThan(session.test_sourceItemIDRepairPassCount, postAppendRepairPassCount)
            session.testAssertSourceItemDerivedStateIsConsistent()
        #endif
    }

    #if DEBUG
        func testStreamingTextMutationsDoNotRunFullIDRepairPasses() throws {
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            let activeInvocationID = UUID()
            var items: [AgentChatItem] = []
            items.reserveCapacity(2004)
            for index in 0 ..< 2000 {
                items.append(.assistant("historical \(index)", sequenceIndex: index))
            }
            items.append(.user("active", sequenceIndex: 2000))
            items.append(.toolCall(
                name: "read_file",
                invocationID: activeInvocationID,
                argsJSON: #"{"path":"Sources/Active.swift"}"#,
                sequenceIndex: 2001
            ))
            try items.append(retainedAgentRunToolResult(
                id: UUID(),
                marker: "streaming",
                sequenceIndex: 2002
            ))
            items.append(.assistant("streaming", sequenceIndex: 2003, isStreaming: true))
            session.setItemsSilently(items, reason: .testOverride)
            let initialIDs = session.liveItemIDs
            let initialNextSequenceIndex = session.nextSequenceIndex
            let initialRevision = session.sourceItemsRevision
            let initialRepairPassCount = session.test_sourceItemIDRepairPassCount
            let initialPayloads = session.ephemeralToolResultPayloadByItemID
            XCTAssertFalse(initialPayloads.isEmpty)
            var notifiedRevisions: [Int] = []
            session.onSourceItemsChanged = { changedSession, _ in
                notifiedRevisions.append(changedSession.sourceItemsRevision)
            }

            for _ in 0 ..< 100 {
                session.mutateItem(at: session.items.count - 1) { $0.text += " token" }
                session.updateLastItem { $0.text += " token" }
            }

            XCTAssertEqual(session.test_sourceItemIDRepairPassCount, initialRepairPassCount)
            XCTAssertEqual(session.liveItemIDs, initialIDs)
            XCTAssertEqual(session.nextSequenceIndex, initialNextSequenceIndex)
            XCTAssertEqual(session.sourceItemsRevision, initialRevision + 200)
            XCTAssertEqual(notifiedRevisions, Array((initialRevision + 1) ... (initialRevision + 200)))
            XCTAssertEqual(session.ephemeralToolResultPayloadByItemID, initialPayloads)
            XCTAssertEqual(session.indexedToolItemIndices(invocationID: activeInvocationID), [2001])
            XCTAssertTrue(session.isDirty)
            session.testAssertSourceItemDerivedStateIsConsistent()
        }
    #endif

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
