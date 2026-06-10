import Foundation
@testable import RepoPrompt
import XCTest

/// Integration tests that exercise the full `history` MCP tool flow end-to-end
/// through `HistoryMCPToolService.execute(args:scanner:)` using a real
/// `HistorySessionScanner` backed by temporary directory fixtures.
///
/// Each test creates realistic workspace/session directory structures on disk,
/// points a scanner at them, and calls the service — testing the complete
/// path from filesystem scan through args dispatch to response formatting.
final class HistoryIntegrationTests: XCTestCase {
    // MARK: - Test Infrastructure

    private var tempDir: URL!
    private var workspacesRoot: URL!
    private var scanner: HistorySessionScanner!
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        workspacesRoot = tempDir.appendingPathComponent("Workspaces", isDirectory: true)
        scanner = HistorySessionScanner(applicationSupportRoot: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - 1. Cross-workspace list_sessions

    func testListSessions_crossWorkspace_includesBothWorkspaces() async throws {
        let ws1ID = UUID()
        let ws2ID = UUID()
        let session1ID = UUID()
        let session2ID = UUID()

        let ws1 = try createWorkspaceDir(name: "ProjectAlpha", uuid: ws1ID)
        try writeWorkspaceJSON(in: ws1, name: "ProjectAlpha", id: ws1ID)
        try createAgentSessionsIndex(in: ws1, records: [
            makeRecord(id: session1ID, name: "Alpha Session", savedAt: Date(timeIntervalSince1970: 1_700_000_100))
        ])

        let ws2 = try createWorkspaceDir(name: "ProjectBeta", uuid: ws2ID)
        try writeWorkspaceJSON(in: ws2, name: "ProjectBeta", id: ws2ID)
        try createAgentSessionsIndex(in: ws2, records: [
            makeRecord(id: session2ID, name: "Beta Session", savedAt: Date(timeIntervalSince1970: 1_700_000_200))
        ])

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions"],
            scanner: scanner
        )

        XCTAssertEqual(result["total_sessions"] as? Int, 2)
        XCTAssertEqual(result["truncated"] as? Bool, false)

        let sessions = result["sessions"] as? [[String: Any]]
        XCTAssertNotNil(sessions)
        XCTAssertEqual(sessions?.count, 2)

        let workspaceNames = sessions?.compactMap { $0["workspace_name"] as? String }.sorted()
        XCTAssertEqual(workspaceNames, ["ProjectAlpha", "ProjectBeta"])

        // Verify each session carries the correct workspace_name
        let alphaSession = sessions?.first { $0["workspace_name"] as? String == "ProjectAlpha" }
        XCTAssertEqual(alphaSession?["session_name"] as? String, "Alpha Session")
        XCTAssertEqual(alphaSession?["session_id"] as? String, session1ID.uuidString)

        let betaSession = sessions?.first { $0["workspace_name"] as? String == "ProjectBeta" }
        XCTAssertEqual(betaSession?["session_name"] as? String, "Beta Session")
        XCTAssertEqual(betaSession?["session_id"] as? String, session2ID.uuidString)
    }

    // MARK: - 2. list_sessions filter by touched_file

    func testListSessions_filterByTouchedFile_returnsMatchingOnly() async throws {
        let wsID = UUID()
        let ws = try createWorkspaceDir(name: "MyProject", uuid: wsID)
        try writeWorkspaceJSON(in: ws, name: "MyProject", id: wsID)

        let matchID = UUID()
        let noMatchID = UUID()

        try createAgentSessionsIndex(in: ws, records: [
            makeRecord(
                id: matchID,
                name: "Touched File Session",
                keyPaths: ["src/main.swift", "lib/utils.swift"],
                savedAt: Date(timeIntervalSince1970: 1_700_000_100)
            ),
            makeRecord(
                id: noMatchID,
                name: "No Match Session",
                keyPaths: ["docs/README.md"],
                savedAt: Date(timeIntervalSince1970: 1_700_000_200)
            )
        ])

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "touched_file": "main.swift"],
            scanner: scanner
        )

        XCTAssertEqual(result["total_sessions"] as? Int, 1)
        let sessions = result["sessions"] as? [[String: Any]]
        XCTAssertEqual(sessions?.count, 1)
        XCTAssertEqual(sessions?.first?["session_id"] as? String, matchID.uuidString)

        // Verify files_touched is populated
        let filesTouched = sessions?.first?["files_touched"] as? [String]
        XCTAssertEqual(filesTouched, ["lib/utils.swift", "src/main.swift"])
    }

    // MARK: - 3. list_sessions truncation

    func testListSessions_truncation_whenMoreThanLimit() async throws {
        let wsID = UUID()
        let ws = try createWorkspaceDir(name: "BigProject", uuid: wsID)
        try writeWorkspaceJSON(in: ws, name: "BigProject", id: wsID)

        // Create 5 sessions, limit to 3
        var records: [AgentSessionMetadataRecord] = []
        for i in 0 ..< 5 {
            records.append(makeRecord(
                id: UUID(),
                name: "Session \(i)",
                savedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i * 100))
            ))
        }
        try createAgentSessionsIndex(in: ws, records: records)

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "limit": 3],
            scanner: scanner
        )

        XCTAssertEqual(result["total_sessions"] as? Int, 5)
        XCTAssertEqual(result["truncated"] as? Bool, true)

        let sessions = result["sessions"] as? [[String: Any]]
        XCTAssertEqual(sessions?.count, 3)
    }

    // MARK: - 4. search across compacted and live turns

    func testSearch_matchesCompactedAndLiveTurns() async throws {
        let wsID = UUID()
        let sessionID = UUID()
        let ws = try createWorkspaceDir(name: "SearchProject", uuid: wsID)
        try writeWorkspaceJSON(in: ws, name: "SearchProject", id: wsID)
        try createAgentSessionsIndex(in: ws, records: [
            makeRecord(id: sessionID, name: "Search Session", savedAt: Date(timeIntervalSince1970: 1_700_000_100))
        ])

        // Build a transcript with a compacted turn (summary only) and a live turn (activities)
        let compactedTurn = AgentTranscriptTurn(
            id: UUID(),
            retentionTier: .summary,
            summary: AgentTranscriptTurnSummary(
                requestText: "Fix the database connection pool",
                conclusionText: nil,
                compactConclusionText: "Fixed the database connection pool by adjusting timeout settings",
                middleSummaryText: nil,
                toolCount: 3,
                notableToolNames: ["apply_edits"],
                keyPaths: ["src/db/pool.swift"],
                compactedActivityCount: 5,
                hadWarning: false,
                hadError: false
            ),
            startedAt: Date(timeIntervalSince1970: 1_700_000_050),
            completedAt: Date(timeIntervalSince1970: 1_700_000_080)
        )

        let liveActivity = AgentTranscriptActivity(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_110),
            sequenceIndex: 0,
            role: .assistant,
            itemKind: .assistant,
            text: "I found a database connection pool issue in the configuration file"
        )
        let liveSpan = AgentTranscriptProviderResponseSpan(
            id: UUID(),
            lifecycle: .completed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_100),
            activities: [liveActivity]
        )
        let liveTurn = AgentTranscriptTurn(
            id: UUID(),
            responseSpans: [liveSpan],
            startedAt: Date(timeIntervalSince1970: 1_700_000_100),
            completedAt: Date(timeIntervalSince1970: 1_700_000_120)
        )

        let transcript = AgentTranscript(turns: [compactedTurn, liveTurn])
        let session = AgentSession(id: sessionID, name: "Search Session", transcript: transcript, itemCount: 2)
        try writeSessionFile(session, in: ws)

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "database connection pool"],
            scanner: scanner
        )

        XCTAssertEqual(result["total_matches"] as? Int, 2)
        XCTAssertEqual(result["truncated"] as? Bool, false)

        let results = result["results"] as? [[String: Any]]
        XCTAssertNotNil(results)
        XCTAssertEqual(results?.count, 2)

        // Verify sources are present — one from activity, one from summary
        let sources = results?.compactMap { $0["source"] as? String }
        // The live turn should have source "activity" and the compacted turn "summary"
        XCTAssertTrue(sources?.contains("activity") == true)
        XCTAssertTrue(sources?.contains("summary") == true)
    }

    func testSearch_dedup_whenQueryMatchesBothActivityAndSummary() async throws {
        let wsID = UUID()
        let sessionID = UUID()
        let ws = try createWorkspaceDir(name: "DedupProject", uuid: wsID)
        try writeWorkspaceJSON(in: ws, name: "DedupProject", id: wsID)
        try createAgentSessionsIndex(in: ws, records: [
            makeRecord(id: sessionID, name: "Dedup Session", savedAt: Date(timeIntervalSince1970: 1_700_000_100))
        ])

        // Build a turn with both an activity containing "unique_search_term_xyz"
        // and a summary compactConclusionText containing the same phrase
        let activity = AgentTranscriptActivity(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_110),
            sequenceIndex: 0,
            role: .assistant,
            itemKind: .assistant,
            text: "I resolved the unique_search_term_xyz problem by refactoring"
        )
        let span = AgentTranscriptProviderResponseSpan(
            id: UUID(),
            lifecycle: .completed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_100),
            activities: [activity]
        )
        let turn = AgentTranscriptTurn(
            id: UUID(),
            responseSpans: [span],
            summary: AgentTranscriptTurnSummary(
                requestText: nil,
                conclusionText: nil,
                compactConclusionText: "Fixed the unique_search_term_xyz issue",
                middleSummaryText: nil,
                toolCount: 1,
                notableToolNames: [],
                keyPaths: [],
                compactedActivityCount: 0,
                hadWarning: false,
                hadError: false
            ),
            startedAt: Date(timeIntervalSince1970: 1_700_000_100),
            completedAt: Date(timeIntervalSince1970: 1_700_000_120)
        )

        let transcript = AgentTranscript(turns: [turn])
        let session = AgentSession(id: sessionID, name: "Dedup Session", transcript: transcript, itemCount: 1)
        try writeSessionFile(session, in: ws)

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "unique_search_term_xyz"],
            scanner: scanner
        )

        // Should be only 1 match despite matching in both activity and summary
        XCTAssertEqual(result["total_matches"] as? Int, 1)

        let results = result["results"] as? [[String: Any]]
        XCTAssertEqual(results?.count, 1)

        // Activity takes priority for dedup
        XCTAssertEqual(results?.first?["source"] as? String, "activity")
    }

    // MARK: - 5. search snippet extraction

    func testSearch_snippetExtraction() async throws {
        let wsID = UUID()
        let sessionID = UUID()
        let ws = try createWorkspaceDir(name: "SnippetProject", uuid: wsID)
        try writeWorkspaceJSON(in: ws, name: "SnippetProject", id: wsID)
        try createAgentSessionsIndex(in: ws, records: [
            makeRecord(id: sessionID, name: "Snippet Session", savedAt: Date(timeIntervalSince1970: 1_700_000_100))
        ])

        // Create a long text where the match is in the middle
        let padding = String(repeating: "a", count: 300)
        let longText = "\(padding)FINDME_KEYWORD_12345\(padding)"
        let activity = AgentTranscriptActivity(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_110),
            sequenceIndex: 0,
            role: .assistant,
            itemKind: .assistant,
            text: longText
        )
        let span = AgentTranscriptProviderResponseSpan(
            id: UUID(),
            lifecycle: .completed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_100),
            activities: [activity]
        )
        let turn = AgentTranscriptTurn(
            id: UUID(),
            responseSpans: [span],
            startedAt: Date(timeIntervalSince1970: 1_700_000_100),
            completedAt: Date(timeIntervalSince1970: 1_700_000_120)
        )

        let transcript = AgentTranscript(turns: [turn])
        let session = AgentSession(id: sessionID, name: "Snippet Session", transcript: transcript, itemCount: 1)
        try writeSessionFile(session, in: ws)

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "FINDME_KEYWORD_12345"],
            scanner: scanner
        )

        let results = result["results"] as? [[String: Any]]
        XCTAssertEqual(results?.count, 1)

        let snippet = results?.first?["snippet"] as? String
        XCTAssertNotNil(snippet)

        // Snippet should be approximately 200 chars (±100 on each side of match)
        // The exact size depends on match position; verify it's in a reasonable range
        XCTAssertLessThanOrEqual(snippet?.count ?? 0, 250)
        XCTAssertGreaterThanOrEqual(snippet?.count ?? 0, 100)

        // Snippet must contain the search term
        XCTAssertTrue(snippet?.contains("FINDME_KEYWORD_12345") == true)
    }

    // MARK: - 6. time grouped by day

    func testTime_groupedByDay() async throws {
        let wsID = UUID()
        let ws = try createWorkspaceDir(name: "TimeProject", uuid: wsID)
        try writeWorkspaceJSON(in: ws, name: "TimeProject", id: wsID)

        // Day 1: two sessions with durations 120s and 180s
        // Day 2: one session with duration 300s
        // Use fixed calendar dates
        let gregorian = Calendar(identifier: .gregorian)
        let day1 = try XCTUnwrap(gregorian.date(from: DateComponents(year: 2026, month: 6, day: 8, hour: 10)))
        let day2 = try XCTUnwrap(gregorian.date(from: DateComponents(year: 2026, month: 6, day: 9, hour: 14)))

        try createAgentSessionsIndex(in: ws, records: [
            makeRecord(id: UUID(), name: "Day1-A", activeDurationSeconds: 120, savedAt: day1),
            makeRecord(id: UUID(), name: "Day1-B", activeDurationSeconds: 180, savedAt: day1),
            makeRecord(id: UUID(), name: "Day2-A", activeDurationSeconds: 300, savedAt: day2)
        ])

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "day"],
            scanner: scanner
        )

        XCTAssertEqual(result["total_sessions"] as? Int, 3)
        XCTAssertEqual(result["total_active_duration_seconds"] as? Int, 600)

        let groups = result["groups"] as? [[String: Any]]
        XCTAssertNotNil(groups)
        XCTAssertEqual(groups?.count, 2)

        // Groups sorted descending, so day2 first
        let day2Group = groups?.first { ($0["key"] as? String)?.hasPrefix("2026-06-09") == true }
        XCTAssertNotNil(day2Group)
        XCTAssertEqual(day2Group?["sessions"] as? Int, 1)
        XCTAssertEqual(day2Group?["active_duration_seconds"] as? Int, 300)

        let day1Group = groups?.first { ($0["key"] as? String)?.hasPrefix("2026-06-08") == true }
        XCTAssertNotNil(day1Group)
        XCTAssertEqual(day1Group?["sessions"] as? Int, 2)
        XCTAssertEqual(day1Group?["active_duration_seconds"] as? Int, 300) // 120 + 180
    }

    // MARK: - 7. time by workspace

    func testTime_groupedByWorkspace() async throws {
        let ws1ID = UUID()
        let ws2ID = UUID()
        let ws1 = try createWorkspaceDir(name: "Frontend", uuid: ws1ID)
        try writeWorkspaceJSON(in: ws1, name: "Frontend", id: ws1ID)
        try createAgentSessionsIndex(in: ws1, records: [
            makeRecord(id: UUID(), name: "FE-1", activeDurationSeconds: 200, savedAt: Date(timeIntervalSince1970: 1_700_000_100)),
            makeRecord(id: UUID(), name: "FE-2", activeDurationSeconds: 100, savedAt: Date(timeIntervalSince1970: 1_700_000_200))
        ])

        let ws2 = try createWorkspaceDir(name: "Backend", uuid: ws2ID)
        try writeWorkspaceJSON(in: ws2, name: "Backend", id: ws2ID)
        try createAgentSessionsIndex(in: ws2, records: [
            makeRecord(id: UUID(), name: "BE-1", activeDurationSeconds: 400, savedAt: Date(timeIntervalSince1970: 1_700_000_300))
        ])

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "workspace"],
            scanner: scanner
        )

        XCTAssertEqual(result["total_sessions"] as? Int, 3)
        XCTAssertEqual(result["total_active_duration_seconds"] as? Int, 700)

        let groups = result["groups"] as? [[String: Any]]
        XCTAssertNotNil(groups)
        XCTAssertEqual(groups?.count, 2)

        let backendGroup = groups?.first { $0["key"] as? String == "Backend" }
        XCTAssertNotNil(backendGroup)
        XCTAssertEqual(backendGroup?["sessions"] as? Int, 1)
        XCTAssertEqual(backendGroup?["active_duration_seconds"] as? Int, 400)

        let frontendGroup = groups?.first { $0["key"] as? String == "Frontend" }
        XCTAssertNotNil(frontendGroup)
        XCTAssertEqual(frontendGroup?["sessions"] as? Int, 2)
        XCTAssertEqual(frontendGroup?["active_duration_seconds"] as? Int, 300)
    }

    // MARK: - 8. Empty result set

    func testListSessions_emptyResultSet() async throws {
        let wsID = UUID()
        let ws = try createWorkspaceDir(name: "EmptyProject", uuid: wsID)
        try writeWorkspaceJSON(in: ws, name: "EmptyProject", id: wsID)
        // No sessions in this workspace

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "workspace": "NonExistent"],
            scanner: scanner
        )

        XCTAssertEqual(result["total_sessions"] as? Int, 0)
        XCTAssertEqual(result["truncated"] as? Bool, false)

        let sessions = result["sessions"] as? [[String: Any]]
        XCTAssertEqual(sessions?.count, 0)
    }

    func testSearch_emptyResultSet() async throws {
        let wsID = UUID()
        let ws = try createWorkspaceDir(name: "NoMatchProject", uuid: wsID)
        try writeWorkspaceJSON(in: ws, name: "NoMatchProject", id: wsID)
        try createAgentSessionsIndex(in: ws, records: [
            makeRecord(id: UUID(), name: "Session", savedAt: Date(timeIntervalSince1970: 1_700_000_100))
        ])

        // No session file written — transcript loading will fail and be skipped
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "this_query_matches_nothing_at_all"],
            scanner: scanner
        )

        XCTAssertEqual(result["total_matches"] as? Int, 0)
        XCTAssertEqual(result["truncated"] as? Bool, false)

        let results = result["results"] as? [[String: Any]]
        XCTAssertEqual(results?.count, 0)
    }

    // MARK: - Helpers

    private func createWorkspaceDir(name: String, uuid: UUID) throws -> URL {
        try FileManager.default.createDirectory(at: workspacesRoot, withIntermediateDirectories: true)
        let dirName = "Workspace-\(name)-\(uuid.uuidString)"
        let wsDir = workspacesRoot.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
        return wsDir
    }

    private func createAgentSessionsIndex(
        in workspaceDir: URL,
        records: [AgentSessionMetadataRecord]
    ) throws {
        let agentSessions = workspaceDir.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: agentSessions, withIntermediateDirectories: true)

        let index = AgentSessionMetadataIndex(
            schemaVersion: AgentSessionMetadataIndex.currentSchemaVersion,
            entries: records
        )
        let data = try encoder.encode(index)
        let indexFile = agentSessions.appendingPathComponent("AgentSessionIndex.json")
        try data.write(to: indexFile, options: .atomic)
    }

    private func writeWorkspaceJSON(in workspaceDir: URL, name: String, id: UUID) throws {
        let json: [String: Any] = ["name": name, "id": id.uuidString]
        let data = try JSONSerialization.data(withJSONObject: json)
        let file = workspaceDir.appendingPathComponent("workspace.json")
        try data.write(to: file, options: .atomic)
    }

    private func writeSessionFile(_ session: AgentSession, in workspaceDir: URL) throws {
        let agentSessions = workspaceDir.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: agentSessions, withIntermediateDirectories: true)
        let filename = "AgentSession-\(session.id.uuidString).json"
        let fileURL = agentSessions.appendingPathComponent(filename)
        let data = try encoder.encode(session)
        try data.write(to: fileURL, options: .atomic)
    }

    private func makeRecord(
        id: UUID = UUID(),
        name: String = "Test Session",
        agentKindRaw: String? = nil,
        agentModelRaw: String? = nil,
        keyPaths: Set<String> = [],
        activeDurationSeconds: Int = 0,
        savedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        itemCount: Int = 1,
        lastRunStateRaw: String? = nil
    ) -> AgentSessionMetadataRecord {
        AgentSessionMetadataRecord(
            id: id,
            filename: "AgentSession-\(id.uuidString).json",
            workspaceID: nil,
            composeTabID: nil,
            name: name,
            savedAt: savedAt,
            lastUserMessageAt: nil,
            itemCount: itemCount,
            transcriptProjectionCounts: nil,
            hasUnknownConversationContent: false,
            agentKindRaw: agentKindRaw,
            agentModelRaw: agentModelRaw,
            agentReasoningEffortRaw: nil,
            lastRunStateRaw: lastRunStateRaw,
            autoEditEnabled: true,
            parentSessionID: nil,
            isMCPOriginated: false,
            serializationVersion: nil,
            observedFileSize: nil,
            observedFileModificationDate: nil,
            lastIndexedAt: savedAt,
            keyPaths: keyPaths,
            activeDurationSeconds: activeDurationSeconds
        )
    }
}
