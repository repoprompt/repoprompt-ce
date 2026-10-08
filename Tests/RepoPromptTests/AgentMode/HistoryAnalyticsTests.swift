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

    // MARK: - Stale index budget isolation (#1091)

    /// Hundreds of stale-schema indexes enumerated ahead of a few current ones must not
    /// consume the index-count or index-byte budgets, must not trigger workspace.json reads,
    /// and must leave a narrow date query answerable without truncation.
    func testStaleSchemaIndexesDoNotConsumeScanBudgetsAtScale() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("rp-history-1091-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let staleVersions = [2, 5, 6, 7]
        XCTAssertFalse(staleVersions.contains(AgentSessionMetadataIndex.currentSchemaVersion))
        let padding = String(repeating: "x", count: 1024)
        var workspaceDirs: [URL] = []

        // 400 head-sniffable stale indexes (~1 KB each), each with an oversized workspace.json.
        for index in 0 ..< 400 {
            let version = staleVersions[index % staleVersions.count]
            let json = "{\"schemaVersion\":\(version),\"generatedAt\":0,\"entries\":[],\"padding\":\"\(padding)\"}"
            try workspaceDirs.append(makeHistoryWorkspace(
                root: root,
                name: "Workspace-Stale\(index)-\(UUID().uuidString)",
                indexData: Data(json.utf8),
                workspaceJSON: "{\"name\":\"stale-\(index)\",\"padding\":\"\(padding)\"}"
            ))
        }
        // Two stale indexes whose schemaVersion sits beyond the head window exercise the
        // full-read fallback, which may charge bytes but never an index-count slot.
        for index in 0 ..< 2 {
            let longPadding = String(repeating: "y", count: 6000)
            let json = "{\"generatedAt\":0,\"entries\":[],\"padding\":\"\(longPadding)\",\"schemaVersion\":6}"
            try workspaceDirs.append(makeHistoryWorkspace(
                root: root,
                name: "Workspace-LateStale\(index)-\(UUID().uuidString)",
                indexData: Data(json.utf8),
                workspaceJSON: nil
            ))
        }

        let inRange = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var expectedIDs: Set<UUID> = []
        for index in 0 ..< 3 {
            let recent = makeRecord(id: UUID(), freshness: inRange.timeIntervalSinceReferenceDate, itemCount: 4)
            let old = makeRecord(id: UUID(), freshness: inRange.timeIntervalSinceReferenceDate - 90 * 86400, itemCount: 4)
            expectedIDs.insert(recent.id)
            let indexData = try JSONEncoder().encode(AgentSessionMetadataIndex(entries: [recent, old]))
            try workspaceDirs.append(makeHistoryWorkspace(
                root: root,
                name: "Workspace-Current\(index)-\(UUID().uuidString)",
                indexData: indexData,
                workspaceJSON: "{\"name\":\"current-\(index)\"}"
            ))
        }

        let dirs = workspaceDirs
        let scanner = HistorySessionScanner(
            applicationSupportRoot: root,
            inventoryBudget: HistoryInventoryBudget(
                maxWorkspaces: 1000,
                maxIndexDecodes: 3,
                maxIndexBytes: 64 * 1024,
                maxWorkspaceMetadataFileBytes: 256
            ),
            workspaceDirectoryProvider: { _ in dirs }
        )

        let scan = try await scanner.scanWorkspaces(matching: nil)

        XCTAssertFalse(scan.isTruncated, "diagnostics: \(scan.diagnostics)")
        let diagnosticKinds = Set(scan.diagnostics.map(\.kind))
        XCTAssertFalse(diagnosticKinds.contains(.indexCount))
        XCTAssertFalse(diagnosticKinds.contains(.indexBytes))
        XCTAssertFalse(diagnosticKinds.contains(.workspaceMetadataFileBytes))
        let decodeCount = await scanner.indexDecodeCountForTesting
        XCTAssertEqual(decodeCount, 3)

        let staleResults = scan.workspaces.filter { $0.indexSchemaVersion != nil }
        XCTAssertEqual(staleResults.count, 402)
        XCTAssertEqual(Set(staleResults.compactMap(\.indexSchemaVersion)), Set(staleVersions))
        XCTAssertTrue(staleResults.allSatisfy(\.records.isEmpty))
        let currentResults = scan.workspaces.filter { $0.indexSchemaVersion == nil && !$0.records.isEmpty }
        XCTAssertEqual(Set(currentResults.map(\.workspaceName)), ["current-0", "current-1", "current-2"])

        let matches = scanner.sessionsMatchingFilters(
            scan.workspaces,
            workspace: nil,
            agentKind: nil,
            model: nil,
            filePath: nil,
            from: inRange.addingTimeInterval(-3600),
            to: inRange.addingTimeInterval(3600)
        )
        XCTAssertEqual(Set(matches.map(\.sessionID)), expectedIDs)
    }

    private func makeHistoryWorkspace(
        root: URL,
        name: String,
        indexData: Data,
        workspaceJSON: String?
    ) throws -> URL {
        let workspaceDir = root.appendingPathComponent("Workspaces", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        let sessionsDir = workspaceDir.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try indexData.write(to: sessionsDir.appendingPathComponent("AgentSessionIndex.json"))
        if let workspaceJSON {
            try Data(workspaceJSON.utf8).write(to: workspaceDir.appendingPathComponent("workspace.json"))
        }
        return workspaceDir
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
