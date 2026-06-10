import Foundation
@testable import RepoPrompt
import XCTest

final class AgentSessionMetadataRecordExtensionTests: XCTestCase {
    // MARK: - Codable Backward Compatibility

    func testDecodingMissingKeyPathsAndDurationFields() throws {
        // Simulates a schema version 2 record that lacks the new fields.
        let uuid = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
            "id": "\(uuid.uuidString.lowercased())",
            "filename": "AgentSession-test.json",
            "name": "Test Session",
            "savedAt": \(now.timeIntervalSince1970),
            "itemCount": 5,
            "hasUnknownConversationContent": false,
            "autoEditEnabled": true,
            "lastIndexedAt": \(now.timeIntervalSince1970)
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let record = try JSONDecoder().decode(AgentSessionMetadataRecord.self, from: data)

        XCTAssertEqual(record.keyPaths, [])
        XCTAssertEqual(record.activeDurationSeconds, 0)
    }

    func testDecodingPresentKeyPathsAndDurationFields() throws {
        let uuid = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
            "id": "\(uuid.uuidString.lowercased())",
            "filename": "AgentSession-test.json",
            "name": "Test Session",
            "savedAt": \(now.timeIntervalSince1970),
            "itemCount": 5,
            "hasUnknownConversationContent": false,
            "autoEditEnabled": true,
            "lastIndexedAt": \(now.timeIntervalSince1970),
            "keyPaths": ["src/foo.swift", "src/bar.swift"],
            "activeDurationSeconds": 42
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let record = try JSONDecoder().decode(AgentSessionMetadataRecord.self, from: data)

        XCTAssertEqual(record.keyPaths, Set(["src/foo.swift", "src/bar.swift"]))
        XCTAssertEqual(record.activeDurationSeconds, 42)
    }

    func testRoundTripEncodingDecoding() throws {
        let uuid = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let record = AgentSessionMetadataRecord(
            id: uuid,
            filename: "AgentSession-test.json",
            workspaceID: nil,
            composeTabID: nil,
            name: "Round Trip",
            savedAt: now,
            lastUserMessageAt: nil,
            itemCount: 3,
            transcriptProjectionCounts: nil,
            hasUnknownConversationContent: false,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            lastRunStateRaw: nil,
            autoEditEnabled: true,
            parentSessionID: nil,
            isMCPOriginated: false,
            serializationVersion: nil,
            observedFileSize: nil,
            observedFileModificationDate: nil,
            lastIndexedAt: now,
            keyPaths: ["a.swift", "b.swift"],
            activeDurationSeconds: 99
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(record)
        let decoded = try JSONDecoder().decode(AgentSessionMetadataRecord.self, from: data)

        XCTAssertEqual(decoded.keyPaths, Set(["a.swift", "b.swift"]))
        XCTAssertEqual(decoded.activeDurationSeconds, 99)
        XCTAssertEqual(decoded.id, uuid)
    }

    // MARK: - Factory: keyPaths Aggregation

    func testFactoryAggregatesKeyPathsFromTranscriptTurns() {
        let session = makeSession(turns: [
            makeTurn(
                summary: .init(
                    requestText: nil,
                    conclusionText: nil,
                    compactConclusionText: nil,
                    middleSummaryText: nil,
                    toolCount: 1,
                    notableToolNames: [],
                    keyPaths: ["src/foo.swift", "src/bar.swift"],
                    compactedActivityCount: 0,
                    hadWarning: false,
                    hadError: false
                ),
                startedAt: Date(timeIntervalSince1970: 0),
                completedAt: Date(timeIntervalSince1970: 10)
            ),
            makeTurn(
                summary: .init(
                    requestText: nil,
                    conclusionText: nil,
                    compactConclusionText: nil,
                    middleSummaryText: nil,
                    toolCount: 2,
                    notableToolNames: [],
                    keyPaths: ["src/baz.swift", "src/foo.swift"],
                    compactedActivityCount: 0,
                    hadWarning: false,
                    hadError: false
                ),
                startedAt: Date(timeIntervalSince1970: 15),
                completedAt: Date(timeIntervalSince1970: 25)
            )
        ])

        let fileURL = URL(fileURLWithPath: "/tmp/AgentSession-test.json")
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: nil,
            observedFileModificationDate: nil
        )

        XCTAssertEqual(record.keyPaths, Set(["src/foo.swift", "src/bar.swift", "src/baz.swift"]))
    }

    func testFactoryKeyPathsWithNilTranscript() {
        // Simulates stub load where transcript is nil.
        let session = AgentSession(
            name: "No Transcript",
            transcript: nil,
            itemCount: 0
        )

        let fileURL = URL(fileURLWithPath: "/tmp/AgentSession-test.json")
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: nil,
            observedFileModificationDate: nil
        )

        XCTAssertEqual(record.keyPaths, [])
        XCTAssertEqual(record.activeDurationSeconds, 0)
    }

    func testFactoryKeyPathsSkipsTurnsWithoutSummary() {
        let session = makeSession(turns: [
            makeTurn(
                summary: nil,
                startedAt: Date(timeIntervalSince1970: 0),
                completedAt: Date(timeIntervalSince1970: 5)
            ),
            makeTurn(
                summary: .init(
                    requestText: nil,
                    conclusionText: nil,
                    compactConclusionText: nil,
                    middleSummaryText: nil,
                    toolCount: 1,
                    notableToolNames: [],
                    keyPaths: ["only.swift"],
                    compactedActivityCount: 0,
                    hadWarning: false,
                    hadError: false
                ),
                startedAt: Date(timeIntervalSince1970: 10),
                completedAt: Date(timeIntervalSince1970: 15)
            )
        ])

        let fileURL = URL(fileURLWithPath: "/tmp/AgentSession-test.json")
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: nil,
            observedFileModificationDate: nil
        )

        XCTAssertEqual(record.keyPaths, Set(["only.swift"]))
    }

    func testFactoryKeyPathsFromToolExecutionsWhenNoSummary() {
        // Active (uncompacted) turns have summary=nil but toolExecution activities
        // carry keyPaths. The indexer should fall back to reading those.
        let toolActivity = AgentTranscriptActivity(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 5),
            sequenceIndex: 1,
            role: .toolExecution,
            itemKind: .assistant,
            text: "",
            toolExecution: AgentTranscriptToolExecution(
                stableExecutionID: "exec-1",
                toolName: "apply_edits",
                invocationID: nil,
                argsJSON: nil,
                resultJSON: nil,
                toolIsError: nil,
                status: .success,
                keyPaths: ["src/main.swift", "lib/helpers.swift"]
            )
        )
        let span = AgentTranscriptProviderResponseSpan(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 0),
            activities: [toolActivity]
        )
        let turn = AgentTranscriptTurn(
            responseSpans: [span],
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 10)
        )
        let session = makeSession(turns: [turn])

        let fileURL = URL(fileURLWithPath: "/tmp/AgentSession-test.json")
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: nil,
            observedFileModificationDate: nil
        )

        XCTAssertEqual(record.keyPaths, Set(["src/main.swift", "lib/helpers.swift"]))
    }

    func testFactoryKeyPathsPrefersSummaryOverToolExecutions() {
        // When a turn has both a summary and tool executions, summary wins.
        let toolActivity = AgentTranscriptActivity(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 5),
            sequenceIndex: 1,
            role: .toolExecution,
            itemKind: .assistant,
            text: "",
            toolExecution: AgentTranscriptToolExecution(
                stableExecutionID: "exec-1",
                toolName: "apply_edits",
                invocationID: nil,
                argsJSON: nil,
                resultJSON: nil,
                toolIsError: nil,
                status: .success,
                keyPaths: ["from_tool.swift"]
            )
        )
        let span = AgentTranscriptProviderResponseSpan(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 0),
            activities: [toolActivity]
        )
        let turn = AgentTranscriptTurn(
            responseSpans: [span],
            summary: .init(
                requestText: nil,
                conclusionText: nil,
                compactConclusionText: nil,
                middleSummaryText: nil,
                toolCount: 1,
                notableToolNames: [],
                keyPaths: ["from_summary.swift"],
                compactedActivityCount: 0,
                hadWarning: false,
                hadError: false
            ),
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 10)
        )
        let session = makeSession(turns: [turn])

        let fileURL = URL(fileURLWithPath: "/tmp/AgentSession-test.json")
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: nil,
            observedFileModificationDate: nil
        )

        // Summary keyPaths take priority — tool execution paths should NOT be included.
        XCTAssertEqual(record.keyPaths, Set(["from_summary.swift"]))
    }

    // MARK: - Factory: activeDurationSeconds Computation

    func testActiveDurationSingleTurn() {
        let session = makeSession(turns: [
            makeTurn(
                startedAt: Date(timeIntervalSince1970: 0),
                completedAt: Date(timeIntervalSince1970: 60)
            )
        ])

        let fileURL = URL(fileURLWithPath: "/tmp/AgentSession-test.json")
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: nil,
            observedFileModificationDate: nil
        )

        XCTAssertEqual(record.activeDurationSeconds, 60)
    }

    func testActiveDurationContinuousTurns() {
        // Two turns back-to-back with no idle gap.
        let session = makeSession(turns: [
            makeTurn(
                startedAt: Date(timeIntervalSince1970: 0),
                completedAt: Date(timeIntervalSince1970: 60)
            ),
            makeTurn(
                startedAt: Date(timeIntervalSince1970: 65),
                completedAt: Date(timeIntervalSince1970: 120)
            )
        ])

        let fileURL = URL(fileURLWithPath: "/tmp/AgentSession-test.json")
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: nil,
            observedFileModificationDate: nil
        )

        // Turn 1: 60s. Turn 2 continuous from prev end: 120-60 = 60s. Total: 120.
        XCTAssertEqual(record.activeDurationSeconds, 120)
    }

    func testActiveDurationExcludesIdleGapOverThirtyMinutes() {
        // Two turns separated by a 45-minute idle gap.
        let session = makeSession(turns: [
            makeTurn(
                startedAt: Date(timeIntervalSince1970: 0),
                completedAt: Date(timeIntervalSince1970: 60)
            ),
            makeTurn(
                startedAt: Date(timeIntervalSince1970: 60 + 45 * 60),
                completedAt: Date(timeIntervalSince1970: 60 + 45 * 60 + 30)
            )
        ])

        let fileURL = URL(fileURLWithPath: "/tmp/AgentSession-test.json")
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: nil,
            observedFileModificationDate: nil
        )

        // Turn 1: 60s. Turn 2 has idle gap > 30min so only counts its own duration: 30s. Total: 90.
        XCTAssertEqual(record.activeDurationSeconds, 90)
    }

    func testActiveDurationBoundaryGapExactlyThirtyMinutes() {
        // Gap is exactly 30 minutes — should be treated as continuous (not excluded).
        let thirtyMin: TimeInterval = 30 * 60
        let session = makeSession(turns: [
            makeTurn(
                startedAt: Date(timeIntervalSince1970: 0),
                completedAt: Date(timeIntervalSince1970: 60)
            ),
            makeTurn(
                startedAt: Date(timeIntervalSince1970: 60 + thirtyMin),
                completedAt: Date(timeIntervalSince1970: 60 + thirtyMin + 30)
            )
        ])

        let fileURL = URL(fileURLWithPath: "/tmp/AgentSession-test.json")
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: nil,
            observedFileModificationDate: nil
        )

        // Gap is exactly 30min → not excluded (only > 30min excluded). Continuous.
        // Turn 1: 60s. Turn 2 continuous from prev end: 1890 - 60 = 1830. Total: 1890.
        XCTAssertEqual(record.activeDurationSeconds, 1890)
    }

    func testActiveDurationSkipsTurnsWithoutCompletionTimestamp() {
        let session = makeSession(turns: [
            makeTurn(
                startedAt: Date(timeIntervalSince1970: 0),
                completedAt: nil,
                lastActivityAt: nil
            ),
            makeTurn(
                startedAt: Date(timeIntervalSince1970: 100),
                completedAt: Date(timeIntervalSince1970: 200)
            )
        ])

        let fileURL = URL(fileURLWithPath: "/tmp/AgentSession-test.json")
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: nil,
            observedFileModificationDate: nil
        )

        // First turn has no completion → skipped. Second turn is first valid: 200-100 = 100.
        XCTAssertEqual(record.activeDurationSeconds, 100)
    }

    func testActiveDurationUsesLastActivityAtFallback() {
        // Turn has no completedAt but has lastActivityAt.
        let session = makeSession(turns: [
            makeTurn(
                startedAt: Date(timeIntervalSince1970: 0),
                completedAt: nil,
                lastActivityAt: Date(timeIntervalSince1970: 45)
            )
        ])

        let fileURL = URL(fileURLWithPath: "/tmp/AgentSession-test.json")
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: nil,
            observedFileModificationDate: nil
        )

        XCTAssertEqual(record.activeDurationSeconds, 45)
    }

    func testActiveDurationEmptyTurns() {
        let session = makeSession(turns: [])

        let fileURL = URL(fileURLWithPath: "/tmp/AgentSession-test.json")
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: nil,
            observedFileModificationDate: nil
        )

        XCTAssertEqual(record.activeDurationSeconds, 0)
    }

    // MARK: - matchesIndexedSessionMetadata

    func testMatchesIndexedSessionMetadataComparNewFields() {
        let id = UUID()
        let base = makeMinimalRecord(id: id, keyPaths: ["a.swift"], activeDurationSeconds: 10)
        let same = makeMinimalRecord(id: id, keyPaths: ["a.swift"], activeDurationSeconds: 10)
        let differentKeyPaths = makeMinimalRecord(id: id, keyPaths: ["b.swift"], activeDurationSeconds: 10)
        let differentDuration = makeMinimalRecord(id: id, keyPaths: ["a.swift"], activeDurationSeconds: 20)

        XCTAssertTrue(base.matchesIndexedSessionMetadata(same))
        XCTAssertFalse(base.matchesIndexedSessionMetadata(differentKeyPaths))
        XCTAssertFalse(base.matchesIndexedSessionMetadata(differentDuration))
    }

    // MARK: - Helpers

    private func makeMinimalRecord(
        id: UUID = UUID(),
        keyPaths: Set<String>,
        activeDurationSeconds: Int
    ) -> AgentSessionMetadataRecord {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return AgentSessionMetadataRecord(
            id: id,
            filename: "AgentSession-test.json",
            workspaceID: nil,
            composeTabID: nil,
            name: "Test",
            savedAt: now,
            lastUserMessageAt: nil,
            itemCount: 0,
            transcriptProjectionCounts: nil,
            hasUnknownConversationContent: false,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            lastRunStateRaw: nil,
            autoEditEnabled: true,
            parentSessionID: nil,
            isMCPOriginated: false,
            serializationVersion: nil,
            observedFileSize: nil,
            observedFileModificationDate: nil,
            lastIndexedAt: now,
            keyPaths: keyPaths,
            activeDurationSeconds: activeDurationSeconds
        )
    }

    private func makeSession(turns: [AgentTranscriptTurn]) -> AgentSession {
        AgentSession(
            transcript: AgentTranscript(turns: turns),
            itemCount: turns.count
        )
    }

    private func makeTurn(
        summary: AgentTranscriptTurnSummary? = nil,
        startedAt: Date,
        completedAt: Date? = nil,
        lastActivityAt: Date? = nil
    ) -> AgentTranscriptTurn {
        AgentTranscriptTurn(
            summary: summary,
            startedAt: startedAt,
            lastActivityAt: lastActivityAt,
            completedAt: completedAt
        )
    }
}
