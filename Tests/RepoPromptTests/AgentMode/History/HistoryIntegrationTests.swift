import Foundation
@testable import RepoPrompt
import XCTest

/// End-to-end history MCP tests against generated on-disk workspace/session fixtures.
///
/// These tests intentionally avoid hand-crafted `AgentSessionMetadataRecord` values.
/// Each fixture writes real `AgentSession` JSON, builds `AgentSessionIndex.json` through
/// `AgentSessionMetadataRecord.record(from:)`, then exercises `HistorySessionScanner`
/// and `HistoryMCPToolService` together.
final class HistoryIntegrationTests: XCTestCase {
    private var fixture: HistoryTestFixture!
    private var scanner: HistorySessionScanner!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture = try HistoryTestFixture()
        scanner = fixture.makeScanner()
    }

    override func tearDownWithError() throws {
        scanner = nil
        fixture = nil
        try super.tearDownWithError()
    }

    func testRawSessionFixtures_alignWithPersistedSessionJSONShapes() async throws {
        let workspace = try fixture.createWorkspace(name: "RawFixtureProject")
        _ = try fixture.installRawFixtures([
            HistoryTestFixture.rawToolExecutionFixture,
            HistoryTestFixture.rawStartedAtOnlyFixture,
            HistoryTestFixture.rawCompactedSummaryFixture
        ], in: workspace)

        let listResult = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "limit": 10],
            scanner: scanner
        )
        XCTAssertEqual(listResult["total_sessions"] as? Int, 3)
        let sessions = try sessionRows(listResult)

        let toolRow = try XCTUnwrap(row(named: "Raw Tool Execution Session", in: sessions))
        XCTAssertEqual(toolRow["files_touched"] as? [String], ["src/api/register.ts", "src/logging/log.ts"])
        XCTAssertEqual(toolRow["active_duration_seconds"] as? Int, HistoryTestFixture.rawToolExecutionFixture.expectedDurationSeconds)
        XCTAssertEqual(toolRow["tool_call_count"] as? Int, HistoryTestFixture.rawToolExecutionFixture.expectedToolCallCount)
        assertActivityBounds(
            toolRow,
            first: HistoryTestFixture.rawToolExecutionFixture.expectedFirstActivityAt,
            last: HistoryTestFixture.rawToolExecutionFixture.expectedLastActivityAt
        )

        let startedOnlyRow = try XCTUnwrap(row(named: "Raw StartedAt Only Session", in: sessions))
        XCTAssertEqual(startedOnlyRow["files_touched"] as? [String], [])
        XCTAssertEqual(startedOnlyRow["active_duration_seconds"] as? Int, HistoryTestFixture.rawStartedAtOnlyFixture.expectedDurationSeconds)
        XCTAssertEqual(startedOnlyRow["tool_call_count"] as? Int, 0)
        assertActivityBounds(
            startedOnlyRow,
            first: HistoryTestFixture.rawStartedAtOnlyFixture.expectedFirstActivityAt,
            last: HistoryTestFixture.rawStartedAtOnlyFixture.expectedLastActivityAt
        )

        let summaryRow = try XCTUnwrap(row(named: "Raw Compacted Summary Session", in: sessions))
        XCTAssertEqual(summaryRow["files_touched"] as? [String], ["Sources/History/RawSummary.swift"])
        XCTAssertEqual(summaryRow["active_duration_seconds"] as? Int, HistoryTestFixture.rawCompactedSummaryFixture.expectedDurationSeconds)
        XCTAssertEqual(summaryRow["tool_call_count"] as? Int, HistoryTestFixture.rawCompactedSummaryFixture.expectedToolCallCount)

        let activitySearch = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "raw persisted logging"],
            scanner: scanner
        )
        XCTAssertEqual(activitySearch["total_matches"] as? Int, 1)
        XCTAssertEqual(try searchRows(activitySearch).first?["source"] as? String, "activity")

        let summarySearch = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "raw summary keyword"],
            scanner: scanner
        )
        XCTAssertEqual(summarySearch["total_matches"] as? Int, 1)
        XCTAssertEqual(try searchRows(summarySearch).first?["source"] as? String, "summary")

        let timeResult = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "workspace"],
            scanner: scanner
        )
        XCTAssertEqual(timeResult["total_active_duration_seconds"] as? Int, 410)
        let groups = try groupRows(timeResult)
        let rawGroup = try XCTUnwrap(groups.first { $0["key"] as? String == "RawFixtureProject" })
        XCTAssertEqual(rawGroup["sessions"] as? Int, 3)
        XCTAssertEqual(rawGroup["tool_call_count"] as? Int, 6)
    }

    func testListSessions_crossWorkspace_readsGeneratedIndexes() async throws {
        let alpha = try fixture.createWorkspace(name: "ProjectAlpha")
        let beta = try fixture.createWorkspace(name: "ProjectBeta")
        let alphaSession = HistoryTestFixture.toolExecutionSession(
            name: "Alpha Session",
            files: ["Sources/Alpha.swift"],
            startedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let betaSession = HistoryTestFixture.toolExecutionSession(
            name: "Beta Session",
            files: ["Sources/Beta.swift"],
            startedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        try fixture.install([alphaSession], in: alpha)
        try fixture.install([betaSession], in: beta)

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions"],
            scanner: scanner
        )

        XCTAssertEqual(result["total_sessions"] as? Int, 2)
        XCTAssertEqual(result["truncated"] as? Bool, false)
        let sessions = try sessionRows(result)
        XCTAssertEqual(Set(sessions.compactMap { $0["workspace_name"] as? String }), ["ProjectAlpha", "ProjectBeta"])
        XCTAssertEqual(row(named: "Alpha Session", in: sessions)?["session_id"] as? String, alphaSession.id.uuidString)
        XCTAssertEqual(row(named: "Beta Session", in: sessions)?["session_id"] as? String, betaSession.id.uuidString)
    }

    func testListSessions_workspaceFilterMatchesDirectoryNameWhenMetadataNameDiffers() async throws {
        let workspace = try fixture.createWorkspace(
            name: "Display Name From Workspace JSON",
            directoryName: "Workspace-DirectoryOnlyProject-6E7C25B8-4F53-4BD2-B2B2-44B4FBE4C001"
        )
        let spec = HistoryTestFixture.toolExecutionSession(
            name: "Directory Filter Match",
            files: ["Sources/History.swift"]
        )
        try fixture.install([spec], in: workspace)

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "workspace": "DirectoryOnlyProject"],
            scanner: scanner
        )

        XCTAssertEqual(result["total_sessions"] as? Int, 1)
        let sessions = try sessionRows(result)
        XCTAssertEqual(sessions.first?["session_name"] as? String, "Directory Filter Match")
        XCTAssertEqual(sessions.first?["workspace_name"] as? String, "Display Name From Workspace JSON")
    }

    func testListSessions_metadataDerivedFromRealSessionFiles() async throws {
        let workspace = try fixture.createWorkspace(name: "FixtureProject")
        let edited = HistoryTestFixture.toolExecutionSession(
            name: "Edited Files",
            files: ["Sources/Foo.swift", "Sources/Bar.swift"],
            toolCount: 2,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 120
        )
        let compacted = HistoryTestFixture.compactedSummarySession(
            name: "Compacted Summary",
            files: ["Docs/History.md"],
            toolCount: 3,
            startedAt: Date(timeIntervalSince1970: 1_700_001_000),
            durationSeconds: 90
        )
        let startedOnly = HistoryTestFixture.startedAtOnlySession(
            name: "StartedAt Only",
            offsets: [0, 60, 120, 200],
            base: Date(timeIntervalSince1970: 1_700_002_000)
        )
        let failed = HistoryTestFixture.failedSession(
            name: "Failed Session",
            startedAt: Date(timeIntervalSince1970: 1_700_003_000),
            durationSeconds: 30
        )
        try fixture.install([edited, compacted, startedOnly, failed], in: workspace)

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "limit": 10],
            scanner: scanner
        )
        let sessions = try sessionRows(result)

        let editedRow = try XCTUnwrap(row(named: "Edited Files", in: sessions))
        XCTAssertEqual(editedRow["files_touched"] as? [String], ["Sources/Bar.swift", "Sources/Foo.swift"])
        XCTAssertEqual(editedRow["active_duration_seconds"] as? Int, edited.expectedDurationSeconds)
        XCTAssertEqual(editedRow["tool_call_count"] as? Int, edited.expectedToolCallCount)
        assertActivityBounds(editedRow, first: edited.expectedFirstActivityAt, last: edited.expectedLastActivityAt)

        let compactedRow = try XCTUnwrap(row(named: "Compacted Summary", in: sessions))
        XCTAssertEqual(compactedRow["files_touched"] as? [String], ["Docs/History.md"])
        XCTAssertEqual(compactedRow["tool_call_count"] as? Int, compacted.expectedToolCallCount)

        let startedOnlyRow = try XCTUnwrap(row(named: "StartedAt Only", in: sessions))
        XCTAssertEqual(startedOnlyRow["active_duration_seconds"] as? Int, startedOnly.expectedDurationSeconds)
        assertActivityBounds(startedOnlyRow, first: startedOnly.expectedFirstActivityAt, last: startedOnly.expectedLastActivityAt)

        let failedRow = try XCTUnwrap(row(named: "Failed Session", in: sessions))
        XCTAssertEqual(failedRow["last_run_state"] as? String, "failed")
    }

    func testListSessions_touchedFileFilterUsesIndexedToolExecutionKeyPaths() async throws {
        let workspace = try fixture.createWorkspace(name: "FilterProject")
        let matching = HistoryTestFixture.toolExecutionSession(
            name: "Match",
            files: ["Package.swift", "Sources/App.swift"],
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let nonMatching = HistoryTestFixture.toolExecutionSession(
            name: "No Match",
            files: ["README.md"],
            startedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try fixture.install([matching, nonMatching], in: workspace)

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "touched_file": "Package.swift"],
            scanner: scanner
        )

        XCTAssertEqual(result["total_sessions"] as? Int, 1)
        let sessions = try sessionRows(result)
        XCTAssertEqual(sessions.first?["session_name"] as? String, "Match")
        XCTAssertEqual(sessions.first?["files_touched"] as? [String], ["Package.swift", "Sources/App.swift"])
    }

    func testSearch_matchesActivityAndCompactedSummaryFromSessionFiles() async throws {
        let workspace = try fixture.createWorkspace(name: "SearchProject")
        let live = HistoryTestFixture.textSearchSession(
            name: "Live Activity",
            activityText: "I found a database connection pool issue in config"
        )
        let compacted = HistoryTestFixture.compactedSummarySession(
            name: "Compacted Hit",
            files: ["Sources/DB.swift"],
            summaryText: "Fixed the database connection pool timeout"
        )
        try fixture.install([live, compacted], in: workspace)

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "database connection pool"],
            scanner: scanner
        )

        XCTAssertEqual(result["total_matches"] as? Int, 2)
        XCTAssertEqual(result["truncated"] as? Bool, false)
        let results = try searchRows(result)
        XCTAssertEqual(Set(results.compactMap { $0["source"] as? String }), ["activity", "summary"])
    }

    func testSearch_dedupPrefersActivityWhenActivityAndSummaryMatchSameTurn() async throws {
        let workspace = try fixture.createWorkspace(name: "DedupProject")
        let spec = HistoryTestFixture.textSearchSession(
            name: "Dedup Session",
            activityText: "I resolved unique_search_term_xyz in the implementation",
            summaryText: "Fixed unique_search_term_xyz"
        )
        try fixture.install([spec], in: workspace)

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "unique_search_term_xyz"],
            scanner: scanner
        )

        XCTAssertEqual(result["total_matches"] as? Int, 1)
        let rows = try searchRows(result)
        XCTAssertEqual(rows.first?["source"] as? String, "activity")
    }

    func testSearch_snippetExtractionUsesBoundedContext() async throws {
        let workspace = try fixture.createWorkspace(name: "SnippetProject")
        let padding = String(repeating: "a", count: 300)
        let text = "\(padding)FINDME_KEYWORD_12345\(padding)"
        let spec = HistoryTestFixture.textSearchSession(name: "Snippet Session", activityText: text)
        try fixture.install([spec], in: workspace)

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "FINDME_KEYWORD_12345"],
            scanner: scanner
        )

        let rows = try searchRows(result)
        let snippet = try XCTUnwrap(rows.first?["snippet"] as? String)
        XCTAssertTrue(snippet.contains("FINDME_KEYWORD_12345"))
        XCTAssertLessThanOrEqual(snippet.count, 250)
        XCTAssertGreaterThanOrEqual(snippet.count, 100)
        XCTAssertNotEqual(snippet, text)
    }

    func testSearch_emptyResultSet() async throws {
        let workspace = try fixture.createWorkspace(name: "NoMatchProject")
        let spec = HistoryTestFixture.textSearchSession(name: "Session", activityText: "ordinary text")
        try fixture.install([spec], in: workspace)

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "this_query_matches_nothing_at_all"],
            scanner: scanner
        )

        XCTAssertEqual(result["total_matches"] as? Int, 0)
        XCTAssertEqual(result["truncated"] as? Bool, false)
        XCTAssertEqual(try searchRows(result).count, 0)
    }

    func testTime_groupedByDayAggregatesDurationAndToolCalls() async throws {
        let workspace = try fixture.createWorkspace(name: "TimeProject")
        let day1 = try localDate(year: 2026, month: 6, day: 8, hour: 12)
        let day2 = try localDate(year: 2026, month: 6, day: 9, hour: 12)
        let s1 = HistoryTestFixture.toolExecutionSession(name: "Day1-A", files: [], toolCount: 1, startedAt: day1, durationSeconds: 120)
        let s2 = HistoryTestFixture.toolExecutionSession(name: "Day1-B", files: [], toolCount: 2, startedAt: day1.addingTimeInterval(300), durationSeconds: 180)
        let s3 = HistoryTestFixture.toolExecutionSession(name: "Day2-A", files: [], toolCount: 3, startedAt: day2, durationSeconds: 300)
        try fixture.install([s1, s2, s3], in: workspace)

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "day"],
            scanner: scanner
        )

        XCTAssertEqual(result["total_sessions"] as? Int, 3)
        XCTAssertEqual(result["total_active_duration_seconds"] as? Int, 600)
        XCTAssertEqual(result["truncated"] as? Bool, false)
        let groups = try groupRows(result)
        XCTAssertEqual(groups.count, 2)

        let day2Group = try XCTUnwrap(groups.first { ($0["key"] as? String)?.hasPrefix("2026-06-09") == true })
        XCTAssertEqual(day2Group["sessions"] as? Int, 1)
        XCTAssertEqual(day2Group["active_duration_seconds"] as? Int, 300)
        XCTAssertEqual(day2Group["tool_call_count"] as? Int, 3)

        let day1Group = try XCTUnwrap(groups.first { ($0["key"] as? String)?.hasPrefix("2026-06-08") == true })
        XCTAssertEqual(day1Group["sessions"] as? Int, 2)
        XCTAssertEqual(day1Group["active_duration_seconds"] as? Int, 300)
        XCTAssertEqual(day1Group["tool_call_count"] as? Int, 3)
    }

    func testTime_groupedByWorkspaceAggregatesGeneratedMetadata() async throws {
        let frontend = try fixture.createWorkspace(name: "Frontend")
        let backend = try fixture.createWorkspace(name: "Backend")
        let fe1 = HistoryTestFixture.toolExecutionSession(name: "FE-1", files: [], toolCount: 2, durationSeconds: 200)
        let fe2 = HistoryTestFixture.compactedSummarySession(name: "FE-2", files: [], toolCount: 3, durationSeconds: 100)
        let be1 = HistoryTestFixture.toolExecutionSession(name: "BE-1", files: [], toolCount: 1, durationSeconds: 400)
        try fixture.install([fe1, fe2], in: frontend)
        try fixture.install([be1], in: backend)

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "workspace"],
            scanner: scanner
        )

        XCTAssertEqual(result["total_sessions"] as? Int, 3)
        XCTAssertEqual(result["total_active_duration_seconds"] as? Int, 700)
        let groups = try groupRows(result)

        let backendGroup = try XCTUnwrap(groups.first { $0["key"] as? String == "Backend" })
        XCTAssertEqual(backendGroup["sessions"] as? Int, 1)
        XCTAssertEqual(backendGroup["active_duration_seconds"] as? Int, 400)
        XCTAssertEqual(backendGroup["tool_call_count"] as? Int, 1)

        let frontendGroup = try XCTUnwrap(groups.first { $0["key"] as? String == "Frontend" })
        XCTAssertEqual(frontendGroup["sessions"] as? Int, 2)
        XCTAssertEqual(frontendGroup["active_duration_seconds"] as? Int, 300)
        XCTAssertEqual(frontendGroup["tool_call_count"] as? Int, 5)
    }

    func testTime_sessionFilterWithDetails() async throws {
        let workspace = try fixture.createWorkspace(name: "DetailsProject")
        let target = HistoryTestFixture.toolExecutionSession(name: "Target", files: [], toolCount: 2, durationSeconds: 75)
        let other = HistoryTestFixture.toolExecutionSession(name: "Other", files: [], toolCount: 1, durationSeconds: 50)
        try fixture.install([target, other], in: workspace)

        let result = try await HistoryMCPToolService.execute(
            args: [
                "op": "time",
                "group_by": "session",
                "include_details": true,
                "session_id": target.id.uuidString
            ],
            scanner: scanner
        )

        XCTAssertEqual(result["total_sessions"] as? Int, 1)
        XCTAssertEqual(result["total_active_duration_seconds"] as? Int, 75)
        let groups = try groupRows(result)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?["key"] as? String, target.id.uuidString)
        XCTAssertEqual(groups.first?["tool_call_count"] as? Int, 2)
        let details = try XCTUnwrap(groups.first?["details"] as? [[String: Any]])
        XCTAssertEqual(details.first?["session_name"] as? String, "Target")
    }

    func testListSessions_emptyResultSet() async throws {
        _ = try fixture.createWorkspace(name: "EmptyProject")

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "workspace": "NonExistent"],
            scanner: scanner
        )

        XCTAssertEqual(result["total_sessions"] as? Int, 0)
        XCTAssertEqual(result["truncated"] as? Bool, false)
        XCTAssertEqual(try sessionRows(result).count, 0)
    }

    // MARK: - Helpers

    private func sessionRows(_ result: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(result["sessions"] as? [[String: Any]])
    }

    private func searchRows(_ result: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(result["results"] as? [[String: Any]])
    }

    private func groupRows(_ result: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(result["groups"] as? [[String: Any]])
    }

    private func row(named name: String, in rows: [[String: Any]]) -> [String: Any]? {
        rows.first { $0["session_name"] as? String == name }
    }

    private func assertActivityBounds(_ row: [String: Any], first: Date?, last: Date?) {
        let formatter = ISO8601DateFormatter()
        if let first {
            XCTAssertEqual(row["first_activity_at"] as? String, formatter.string(from: first))
        }
        if let last {
            XCTAssertEqual(row["last_activity_at"] as? String, formatter.string(from: last))
        }
    }

    private func localDate(year: Int, month: Int, day: Int, hour: Int) throws -> Date {
        let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour))
        return try XCTUnwrap(date)
    }
}
