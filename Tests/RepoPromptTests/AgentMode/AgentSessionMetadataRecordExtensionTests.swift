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
        XCTAssertEqual(record.coveredTurnDurationSeconds, 0)
        XCTAssertEqual(record.interActiveIntervalGapSeconds, [])
        XCTAssertEqual(record.toolCallCount, 0)
        XCTAssertNil(record.firstActivityAt)
        XCTAssertNil(record.lastActivityAt)
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
            "firstActivityAt": \(now.addingTimeInterval(-60).timeIntervalSinceReferenceDate),
            "lastActivityAt": \(now.addingTimeInterval(-5).timeIntervalSinceReferenceDate),
            "keyPaths": ["src/foo.swift", "src/bar.swift"],
            "coveredTurnDurationSeconds": 42,
            "interActiveIntervalGapSeconds": [30, 90],
            "toolCallCount": 7
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let record = try JSONDecoder().decode(AgentSessionMetadataRecord.self, from: data)

        XCTAssertEqual(record.keyPaths, Set(["src/foo.swift", "src/bar.swift"]))
        XCTAssertEqual(record.coveredTurnDurationSeconds, 42)
        XCTAssertEqual(record.interActiveIntervalGapSeconds, [30, 90])
        // Default 30-min threshold merges both gaps in: 42 + 30 + 90.
        XCTAssertEqual(record.activeDurationSeconds, 162)
        XCTAssertEqual(record.toolCallCount, 7)
        XCTAssertEqual(record.firstActivityAt, now.addingTimeInterval(-60))
        XCTAssertEqual(record.lastActivityAt, now.addingTimeInterval(-5))
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
            firstActivityAt: now.addingTimeInterval(-120),
            lastActivityAt: now.addingTimeInterval(-10),
            keyPaths: ["a.swift", "b.swift"],
            coveredTurnDurationSeconds: 99,
            toolCallCount: 4
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(record)
        let decoded = try JSONDecoder().decode(AgentSessionMetadataRecord.self, from: data)

        XCTAssertEqual(decoded.keyPaths, Set(["a.swift", "b.swift"]))
        XCTAssertEqual(decoded.activeDurationSeconds, 99)
        XCTAssertEqual(decoded.toolCallCount, 4)
        XCTAssertEqual(decoded.firstActivityAt, now.addingTimeInterval(-120))
        XCTAssertEqual(decoded.lastActivityAt, now.addingTimeInterval(-10))
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

        // First turn has no completion/activity timestamps → falls back to startedAt (0 duration).
        // previousEnd advances to t=0. Second turn continuous from prev end: 200-0 = 200.
        XCTAssertEqual(record.activeDurationSeconds, 200)
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

    // MARK: - Activity Bounds

    func testFactoryComputesActivityBoundsFromTranscriptTurns() {
        let session = makeSession(turns: [
            makeTurn(
                startedAt: Date(timeIntervalSince1970: 100),
                completedAt: Date(timeIntervalSince1970: 160)
            ),
            makeTurn(
                startedAt: Date(timeIntervalSince1970: 200),
                completedAt: nil,
                lastActivityAt: Date(timeIntervalSince1970: 245)
            )
        ])

        let fileURL = URL(fileURLWithPath: "/tmp/AgentSession-test.json")
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: nil,
            observedFileModificationDate: nil
        )

        XCTAssertEqual(record.firstActivityAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(record.lastActivityAt, Date(timeIntervalSince1970: 245))
    }

    // MARK: - toolCallCount

    func testToolCallCount_withToolExecutions() {
        let toolActivity = AgentTranscriptActivity(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 5),
            sequenceIndex: 0,
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
                keyPaths: ["src/main.swift"]
            )
        )
        let assistantActivity = AgentTranscriptActivity(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 3),
            sequenceIndex: 0,
            role: .assistant,
            itemKind: .assistant,
            text: "Hello"
        )
        let span = AgentTranscriptProviderResponseSpan(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 0),
            activities: [assistantActivity, toolActivity]
        )
        // Two turns, each with one tool execution.
        let turn1 = AgentTranscriptTurn(
            responseSpans: [span],
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 30)
        )
        let turn2 = AgentTranscriptTurn(
            responseSpans: [span],
            startedAt: Date(timeIntervalSince1970: 40),
            completedAt: Date(timeIntervalSince1970: 70)
        )
        let session = makeSession(turns: [turn1, turn2])

        let fileURL = URL(fileURLWithPath: "/tmp/AgentSession-test.json")
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: nil,
            observedFileModificationDate: nil
        )

        // 2 turns × 1 tool execution per turn = 2 total.
        XCTAssertEqual(record.toolCallCount, 2)
    }

    func testToolCallCount_noToolExecutions() {
        let session = makeSession(turns: [
            makeTurn(
                startedAt: Date(timeIntervalSince1970: 0),
                completedAt: Date(timeIntervalSince1970: 10)
            )
        ])

        let fileURL = URL(fileURLWithPath: "/tmp/AgentSession-test.json")
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: nil,
            observedFileModificationDate: nil
        )

        XCTAssertEqual(record.toolCallCount, 0)
    }

    func testToolCallCount_usesSummaryToolCountForCompactedTurns() {
        let session = makeSession(turns: [
            makeTurn(
                summary: .init(
                    requestText: nil,
                    conclusionText: nil,
                    compactConclusionText: nil,
                    middleSummaryText: nil,
                    toolCount: 4,
                    notableToolNames: ["apply_edits"],
                    keyPaths: ["Sources/App.swift"],
                    compactedActivityCount: 7,
                    hadWarning: false,
                    hadError: false
                ),
                startedAt: Date(timeIntervalSince1970: 0),
                completedAt: Date(timeIntervalSince1970: 10)
            )
        ])

        let fileURL = URL(fileURLWithPath: "/tmp/AgentSession-test.json")
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: nil,
            observedFileModificationDate: nil
        )

        XCTAssertEqual(record.toolCallCount, 4)
    }

    // MARK: - Duration with startedAt-only turns

    func testActiveDuration_continuousTurnsWithOnlyStartedAt() {
        // Turns with no completedAt or lastActivityAt — only startedAt.
        // Each contributes 0 duration but advances previousEnd for gap tracking.
        let session = makeSession(turns: [
            makeTurn(startedAt: Date(timeIntervalSince1970: 0)),
            makeTurn(startedAt: Date(timeIntervalSince1970: 60)),
            makeTurn(startedAt: Date(timeIntervalSince1970: 120))
        ])

        let fileURL = URL(fileURLWithPath: "/tmp/AgentSession-test.json")
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: nil,
            observedFileModificationDate: nil
        )

        // All turns have end == start (startedAt fallback).
        // Turn 1: 0s. Turn 2: continuous from prev end (0), 60-0=60s. Turn 3: continuous from prev end (60), 120-60=60s.
        // Total: 0+60+60 = 120.
        XCTAssertEqual(record.activeDurationSeconds, 120)
    }

    func testActiveDuration_mixedTurnsSomeWithCompletionSomeWithout() {
        // Turn 1: has completion (0-60 = 60s).
        // Turn 2: no completion, only startedAt at t=70 → 0 duration, advances previousEnd to 70.
        // Turn 3: has completion (80-140 = 60s). Continuous from prev end (70): 140-70 = 70s.
        let session = makeSession(turns: [
            makeTurn(
                startedAt: Date(timeIntervalSince1970: 0),
                completedAt: Date(timeIntervalSince1970: 60)
            ),
            makeTurn(startedAt: Date(timeIntervalSince1970: 70)),
            makeTurn(
                startedAt: Date(timeIntervalSince1970: 80),
                completedAt: Date(timeIntervalSince1970: 140)
            )
        ])

        let fileURL = URL(fileURLWithPath: "/tmp/AgentSession-test.json")
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: nil,
            observedFileModificationDate: nil
        )

        // Turn 1: 60s. Turn 2: startedAt fallback, continuous 70-60=10s. Turn 3: continuous 140-70=70s. Total=140.
        XCTAssertEqual(record.activeDurationSeconds, 140)
    }

    // MARK: - v5 Duration Primitives (interval merge + threshold derivation)

    func testDurationPrimitives_storeCoveredAndGaps() {
        // Two non-overlapping turns: [0,200] and [320,520] -> covered 400, gap 120.
        let session = makeSession(turns: [
            makeTurn(startedAt: Date(timeIntervalSince1970: 0), completedAt: Date(timeIntervalSince1970: 200)),
            makeTurn(startedAt: Date(timeIntervalSince1970: 320), completedAt: Date(timeIntervalSince1970: 520))
        ])
        let record = AgentSessionMetadataRecord.record(from: session, fileURL: URL(fileURLWithPath: "/tmp/test.json"), observedFileSize: nil, observedFileModificationDate: nil)

        XCTAssertEqual(record.coveredTurnDurationSeconds, 400)
        XCTAssertEqual(record.interActiveIntervalGapSeconds, [120])
    }

    func testDurationPrimitives_mergesOverlappingNestedAndContiguousIntervals() {
        // Overlapping, nested, and touching turns collapse to their union without double-counting
        // or emitting a zero gap. Defect: naive sum-of-durations would double-count overlaps;
        // the old previousEnd-chaining under-counted nested turns.
        let cases: [(name: String, first: (TimeInterval, TimeInterval), second: (TimeInterval, TimeInterval), covered: Int, gaps: [Int])] = [
            ("nested", (0, 100), (20, 30), 100, []),
            ("partial overlap", (0, 100), (50, 150), 150, []),
            ("contiguous (touch)", (0, 100), (100, 200), 200, [])
        ]
        for c in cases {
            let session = makeSession(turns: [
                makeTurn(startedAt: Date(timeIntervalSince1970: c.first.0), completedAt: Date(timeIntervalSince1970: c.first.1)),
                makeTurn(startedAt: Date(timeIntervalSince1970: c.second.0), completedAt: Date(timeIntervalSince1970: c.second.1))
            ])
            let record = AgentSessionMetadataRecord.record(from: session, fileURL: URL(fileURLWithPath: "/tmp/test.json"), observedFileSize: nil, observedFileModificationDate: nil)

            XCTAssertEqual(record.coveredTurnDurationSeconds, c.covered, c.name)
            XCTAssertEqual(record.interActiveIntervalGapSeconds, c.gaps, c.name)
        }
    }

    func testDurationPrimitives_dropsNegativeDurationTurns() {
        // end < start is dropped, not counted as negative covered time. Only the valid turn remains.
        let session = makeSession(turns: [
            makeTurn(startedAt: Date(timeIntervalSince1970: 100), completedAt: Date(timeIntervalSince1970: 50)),
            makeTurn(startedAt: Date(timeIntervalSince1970: 200), completedAt: Date(timeIntervalSince1970: 300))
        ])
        let record = AgentSessionMetadataRecord.record(from: session, fileURL: URL(fileURLWithPath: "/tmp/test.json"), observedFileSize: nil, observedFileModificationDate: nil)

        XCTAssertEqual(record.coveredTurnDurationSeconds, 100)
        XCTAssertEqual(record.interActiveIntervalGapSeconds, [])
    }

    func testDurationPrimitives_zeroTurns() {
        let session = makeSession(turns: [])
        let record = AgentSessionMetadataRecord.record(from: session, fileURL: URL(fileURLWithPath: "/tmp/test.json"), observedFileSize: nil, observedFileModificationDate: nil)

        XCTAssertEqual(record.coveredTurnDurationSeconds, 0)
        XCTAssertEqual(record.interActiveIntervalGapSeconds, [])
        XCTAssertEqual(record.activeDurationSeconds, 0)
    }

    func testDurationPrimitives_sortsOutOfOrderTurns() {
        // Turns arrive non-chronologically; the merge must sort by startedAt before measuring.
        // Defect: dropping the sort would mis-merge and emit a spurious gap / wrong covered time.
        let session = makeSession(turns: [
            makeTurn(startedAt: Date(timeIntervalSince1970: 320), completedAt: Date(timeIntervalSince1970: 520)),
            makeTurn(startedAt: Date(timeIntervalSince1970: 0), completedAt: Date(timeIntervalSince1970: 200))
        ])
        let record = AgentSessionMetadataRecord.record(from: session, fileURL: URL(fileURLWithPath: "/tmp/test.json"), observedFileSize: nil, observedFileModificationDate: nil)

        // Same as the in-order case: covered 400, one 120s gap.
        XCTAssertEqual(record.coveredTurnDurationSeconds, 400)
        XCTAssertEqual(record.interActiveIntervalGapSeconds, [120])
    }

    func testActiveDurationThreshold_variesByThreshold() {
        // covered 400, gap 120s between merged intervals.
        let session = makeSession(turns: [
            makeTurn(startedAt: Date(timeIntervalSince1970: 0), completedAt: Date(timeIntervalSince1970: 200)),
            makeTurn(startedAt: Date(timeIntervalSince1970: 320), completedAt: Date(timeIntervalSince1970: 520))
        ])
        let record = AgentSessionMetadataRecord.record(from: session, fileURL: URL(fileURLWithPath: "/tmp/test.json"), observedFileSize: nil, observedFileModificationDate: nil)

        // Threshold 0 min: every positive gap is idle -> covered only.
        XCTAssertEqual(record.activeDurationSeconds(thresholdMinutes: 0), 400)
        // Threshold 1 min (60s): 120s gap > 60s -> idle -> covered only.
        XCTAssertEqual(record.activeDurationSeconds(thresholdMinutes: 1), 400)
        // Equality boundary: threshold 2 min (120s) == gap -> counts as active -> covered + gap.
        XCTAssertEqual(record.activeDurationSeconds(thresholdMinutes: 2), 520)
        // Default threshold (30 min) -> gap active.
        XCTAssertEqual(record.activeDurationSeconds, 520)
    }

    // MARK: - matchesIndexedSessionMetadata

    func testMatchesIndexedSessionMetadataComparesHistoryIndexFields() {
        let id = UUID()
        let firstActivity = Date(timeIntervalSince1970: 10)
        let lastActivity = Date(timeIntervalSince1970: 20)
        let base = makeMinimalRecord(
            id: id,
            keyPaths: ["a.swift"],
            activeDurationSeconds: 10,
            toolCallCount: 2,
            firstActivityAt: firstActivity,
            lastActivityAt: lastActivity
        )
        let same = makeMinimalRecord(
            id: id,
            keyPaths: ["a.swift"],
            activeDurationSeconds: 10,
            toolCallCount: 2,
            firstActivityAt: firstActivity,
            lastActivityAt: lastActivity
        )
        let differentKeyPaths = makeMinimalRecord(
            id: id,
            keyPaths: ["b.swift"],
            activeDurationSeconds: 10,
            toolCallCount: 2,
            firstActivityAt: firstActivity,
            lastActivityAt: lastActivity
        )
        let differentDuration = makeMinimalRecord(
            id: id,
            keyPaths: ["a.swift"],
            activeDurationSeconds: 20,
            toolCallCount: 2,
            firstActivityAt: firstActivity,
            lastActivityAt: lastActivity
        )
        let differentToolCount = makeMinimalRecord(
            id: id,
            keyPaths: ["a.swift"],
            activeDurationSeconds: 10,
            toolCallCount: 3,
            firstActivityAt: firstActivity,
            lastActivityAt: lastActivity
        )
        let differentActivityBounds = makeMinimalRecord(
            id: id,
            keyPaths: ["a.swift"],
            activeDurationSeconds: 10,
            toolCallCount: 2,
            firstActivityAt: firstActivity,
            lastActivityAt: lastActivity.addingTimeInterval(1)
        )

        XCTAssertTrue(base.matchesIndexedSessionMetadata(same))
        XCTAssertFalse(base.matchesIndexedSessionMetadata(differentKeyPaths))
        XCTAssertFalse(base.matchesIndexedSessionMetadata(differentDuration))
        XCTAssertFalse(base.matchesIndexedSessionMetadata(differentToolCount))
        XCTAssertFalse(base.matchesIndexedSessionMetadata(differentActivityBounds))
    }

    // MARK: - Stub vs Full Session (Rebuild Regression Guard)

    func testRecordFromStubSessionProducesZeroV5Fields() {
        // By design: loadAgentSessionStub returns transcript=nil, so stub-built records carry
        // zero v5 fields. rebuildMetadataIndex uses stubs (cheap); the history tool enriches these
        // on demand (see lacksTranscriptDerivedFields / enrichingTranscriptDerivedFields).
        let stubSession = AgentSession(name: "Stub", transcript: nil, itemCount: 10)
        let record = AgentSessionMetadataRecord.record(
            from: stubSession,
            fileURL: URL(fileURLWithPath: "/tmp/stub.json"),
            observedFileSize: nil,
            observedFileModificationDate: nil
        )
        XCTAssertEqual(record.coveredTurnDurationSeconds, 0)
        XCTAssertEqual(record.interActiveIntervalGapSeconds, [])
        XCTAssertNil(record.firstActivityAt)
        XCTAssertNil(record.lastActivityAt)
        XCTAssertEqual(record.toolCallCount, 0)
        XCTAssertEqual(record.keyPaths, [])
    }

    func testRecordFromFullSessionProducesNonZeroV5Fields() {
        // A full session with transcript turns (timestamps) produces non-zero v5 fields.
        // This is what the save/load path and on-demand enrichment compute from real turns.
        let session = makeSession(turns: [
            makeTurn(startedAt: Date(timeIntervalSince1970: 0), completedAt: Date(timeIntervalSince1970: 100)),
            makeTurn(startedAt: Date(timeIntervalSince1970: 200), completedAt: Date(timeIntervalSince1970: 300))
        ])
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: URL(fileURLWithPath: "/tmp/full.json"),
            observedFileSize: nil,
            observedFileModificationDate: nil
        )
        XCTAssertEqual(record.coveredTurnDurationSeconds, 200)
        XCTAssertEqual(record.interActiveIntervalGapSeconds, [100])
        XCTAssertNotNil(record.firstActivityAt)
        XCTAssertNotNil(record.lastActivityAt)
    }

    func testLacksTranscriptDerivedFieldsAndOnDemandEnrichmentEquivalence() {
        // Pins the on-demand contract the history tool depends on:
        //  - a stub-built record (transcript=nil) lacks all v5 fields and needs enrichment;
        //  - a fully-indexed record does not;
        //  - any single populated v5 field is enough to treat a record as indexed;
        //  - enriching a stub with the session's turns reproduces the factory's v5 exactly.
        let stubSession = AgentSession(name: "Stub", transcript: nil, itemCount: 1)
        let stubRecord = AgentSessionMetadataRecord.record(
            from: stubSession,
            fileURL: URL(fileURLWithPath: "/tmp/stub.json"),
            observedFileSize: nil,
            observedFileModificationDate: nil
        )
        XCTAssertTrue(stubRecord.lacksTranscriptDerivedFields, "stub-built record should need enrichment")

        let fullSession = makeSession(turns: [
            makeTurn(startedAt: Date(timeIntervalSince1970: 0), completedAt: Date(timeIntervalSince1970: 100)),
            makeTurn(startedAt: Date(timeIntervalSince1970: 200), completedAt: Date(timeIntervalSince1970: 300))
        ])
        let fullRecord = AgentSessionMetadataRecord.record(
            from: fullSession,
            fileURL: URL(fileURLWithPath: "/tmp/full.json"),
            observedFileSize: nil,
            observedFileModificationDate: nil
        )
        XCTAssertFalse(fullRecord.lacksTranscriptDerivedFields, "indexed record should not trigger enrichment")

        var partial = stubRecord
        partial.keyPaths = ["a.swift"]
        XCTAssertFalse(partial.lacksTranscriptDerivedFields, "any v5 field set ⇒ treated as indexed")

        let enriched = stubRecord.enrichingTranscriptDerivedFields(from: fullSession.transcript?.turns ?? [])
        XCTAssertEqual(enriched.coveredTurnDurationSeconds, fullRecord.coveredTurnDurationSeconds)
        XCTAssertEqual(enriched.interActiveIntervalGapSeconds, fullRecord.interActiveIntervalGapSeconds)
        XCTAssertEqual(enriched.firstActivityAt, fullRecord.firstActivityAt)
        XCTAssertEqual(enriched.lastActivityAt, fullRecord.lastActivityAt)
        XCTAssertEqual(enriched.keyPaths, fullRecord.keyPaths)
        XCTAssertEqual(enriched.toolCallCount, fullRecord.toolCallCount)
        XCTAssertFalse(enriched.lacksTranscriptDerivedFields, "enriched record is now indexed")
    }

    // MARK: - Helpers

    private func makeMinimalRecord(
        id: UUID = UUID(),
        keyPaths: Set<String>,
        activeDurationSeconds: Int,
        toolCallCount: Int = 0,
        firstActivityAt: Date? = nil,
        lastActivityAt: Date? = nil
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
            firstActivityAt: firstActivityAt,
            lastActivityAt: lastActivityAt,
            keyPaths: keyPaths,
            coveredTurnDurationSeconds: activeDurationSeconds,
            toolCallCount: toolCallCount
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
