import Foundation
@testable import RepoPromptApp
import XCTest

final class HistoryAnalyticsTests: XCTestCase {
    func testDurationUsesProviderCoverageButExcludesLongPauseInsideOneTurn() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let resumed = start.addingTimeInterval(86400)
        let turn = AgentTranscriptTurn(
            responseSpans: [
                AgentTranscriptProviderResponseSpan(
                    lifecycle: .completed,
                    startedAt: start,
                    lastActivityAt: start.addingTimeInterval(120),
                    completedAt: start.addingTimeInterval(120)
                ),
                AgentTranscriptProviderResponseSpan(
                    lifecycle: .completed,
                    startedAt: resumed,
                    lastActivityAt: resumed.addingTimeInterval(60),
                    completedAt: resumed.addingTimeInterval(60)
                )
            ],
            terminalState: .completed,
            startedAt: start,
            lastActivityAt: resumed.addingTimeInterval(60),
            completedAt: resumed.addingTimeInterval(60)
        )

        let primitives = AgentSessionMetadataRecord.computeDurationPrimitives(from: [turn])

        XCTAssertEqual(primitives.coveredSeconds, 180)
        XCTAssertEqual(primitives.gapSeconds, [86280])
        XCTAssertEqual(
            AgentSessionMetadataRecord.activeDurationSeconds(
                intervals: AgentSessionMetadataRecord.activityIntervals(from: turn),
                thresholdMinutes: 10
            ),
            180
        )
    }

    func testTranscriptTurnCountIsIndependentFromProjectedItemCount() {
        let record = makeRecord(id: UUID(), freshness: 1, itemCount: 275)
        let enriched = record.enrichingTranscriptDerivedFields(from: [
            AgentTranscriptTurn(startedAt: Date(timeIntervalSinceReferenceDate: 1)),
            AgentTranscriptTurn(startedAt: Date(timeIntervalSinceReferenceDate: 2))
        ])

        XCTAssertEqual(enriched.transcriptTurnCount, 2)
        XCTAssertEqual(enriched.itemCount, 275)
    }

    func testCrossWorkspaceFilteringDeduplicatesSessionIDUsingFreshestProjection() {
        let sessionID = UUID()
        let stale = makeRecord(id: sessionID, freshness: 1, itemCount: 10)
        let fresh = makeRecord(id: sessionID, freshness: 2, itemCount: 20)
        let scanner = HistorySessionScanner(applicationSupportRoot: URL(fileURLWithPath: "/tmp/history-tests"))

        let matches = scanner.sessionsMatchingFilters(
            [
                HistoryWorkspaceScanResult(
                    workspaceDir: URL(fileURLWithPath: "/tmp/workspace-a"),
                    workspaceName: "A",
                    workspaceID: UUID(),
                    records: [stale],
                    indexReadFailed: false,
                    indexSchemaVersion: nil
                ),
                HistoryWorkspaceScanResult(
                    workspaceDir: URL(fileURLWithPath: "/tmp/workspace-b"),
                    workspaceName: "B",
                    workspaceID: UUID(),
                    records: [fresh],
                    indexReadFailed: false,
                    indexSchemaVersion: nil
                )
            ],
            workspace: nil,
            agentKind: nil,
            model: nil,
            filePath: nil,
            from: nil,
            to: nil
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.workspaceName, "B")
        XCTAssertEqual(matches.first?.record.itemCount, 20)
    }

    func testTokenUsageAttributionIsBackwardCompatibleAndRoundTripsIDs() throws {
        let legacy = AgentTokenUsagePersist(promptTokens: 11, completionTokens: 7)
        let legacyDecoded = try JSONDecoder().decode(
            AgentTokenUsagePersist.self,
            from: JSONEncoder().encode(legacy)
        )
        XCTAssertNil(legacyDecoded.runID)
        XCTAssertNil(legacyDecoded.turnID)

        let runID = UUID()
        let turnID = UUID()
        let attributed = AgentTokenUsagePersist(
            runID: runID,
            turnID: turnID,
            promptTokens: 13,
            completionTokens: 5,
            estimatedToolInputTokens: 3,
            estimatedToolOutputTokens: 2
        )
        let decoded = try JSONDecoder().decode(
            AgentTokenUsagePersist.self,
            from: JSONEncoder().encode(attributed)
        )

        XCTAssertEqual(decoded.runID, runID)
        XCTAssertEqual(decoded.turnID, turnID)
        XCTAssertEqual(decoded.estimatedToolInputTokens, 3)
        XCTAssertEqual(decoded.estimatedToolOutputTokens, 2)
    }

    private func makeRecord(id: UUID, freshness: TimeInterval, itemCount: Int) -> AgentSessionMetadataRecord {
        let date = Date(timeIntervalSinceReferenceDate: freshness)
        return AgentSessionMetadataRecord(
            id: id,
            filename: "AgentSession-\(id.uuidString).json",
            workspaceID: nil,
            composeTabID: nil,
            name: "Session",
            savedAt: date,
            lastUserMessageAt: nil,
            itemCount: itemCount,
            transcriptProjectionCounts: nil,
            hasUnknownConversationContent: false,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            lastRunStateRaw: nil,
            autoEditEnabled: true,
            parentSessionID: nil,
            isMCPOriginated: true,
            serializationVersion: nil,
            observedFileSize: nil,
            observedFileModificationDate: date,
            lastIndexedAt: date
        )
    }
}
