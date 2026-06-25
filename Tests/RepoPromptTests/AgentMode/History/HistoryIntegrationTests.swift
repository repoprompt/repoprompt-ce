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
        let listDTO = try listReply(listResult)
        XCTAssertEqual(listDTO.totalSessions, 3)
        let sessions = listDTO.sessions

        let toolRow = try session(sessions, named: "Raw Tool Execution Session")
        XCTAssertEqual(toolRow.filesTouched, ["src/api/register.ts", "src/logging/log.ts"])
        XCTAssertEqual(toolRow.activeDurationSeconds, HistoryTestFixture.rawToolExecutionFixture.expectedDurationSeconds)
        XCTAssertEqual(toolRow.toolCallCount, HistoryTestFixture.rawToolExecutionFixture.expectedToolCallCount)
        assertActivityBounds(
            toolRow,
            first: HistoryTestFixture.rawToolExecutionFixture.expectedFirstActivityAt,
            last: HistoryTestFixture.rawToolExecutionFixture.expectedLastActivityAt
        )

        let startedOnlyRow = try session(sessions, named: "Raw StartedAt Only Session")
        XCTAssertEqual(startedOnlyRow.filesTouched, [])
        XCTAssertEqual(startedOnlyRow.activeDurationSeconds, HistoryTestFixture.rawStartedAtOnlyFixture.expectedDurationSeconds)
        XCTAssertEqual(startedOnlyRow.toolCallCount, 0)
        assertActivityBounds(
            startedOnlyRow,
            first: HistoryTestFixture.rawStartedAtOnlyFixture.expectedFirstActivityAt,
            last: HistoryTestFixture.rawStartedAtOnlyFixture.expectedLastActivityAt
        )

        let summaryRow = try session(sessions, named: "Raw Compacted Summary Session")
        XCTAssertEqual(summaryRow.filesTouched, ["Sources/History/RawSummary.swift"])
        XCTAssertEqual(summaryRow.activeDurationSeconds, HistoryTestFixture.rawCompactedSummaryFixture.expectedDurationSeconds)
        XCTAssertEqual(summaryRow.toolCallCount, HistoryTestFixture.rawCompactedSummaryFixture.expectedToolCallCount)

        let activitySearch = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "raw persisted logging"],
            scanner: scanner
        )
        let activityDTO = try searchReply(activitySearch)
        XCTAssertEqual(activityDTO.totalMatches, 1)
        XCTAssertEqual(activityDTO.results.first?.source, "activity")

        let summarySearch = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "raw summary keyword"],
            scanner: scanner
        )
        let summarySearchDTO = try searchReply(summarySearch)
        XCTAssertEqual(summarySearchDTO.totalMatches, 1)
        XCTAssertEqual(summarySearchDTO.results.first?.source, "summary")

        let timeResult = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "workspace"],
            scanner: scanner
        )
        let timeDTO = try timeReply(timeResult)
        XCTAssertEqual(timeDTO.totalActiveDurationSeconds, 410)
        let rawGroup = try XCTUnwrap(timeDTO.groups.first { $0.key == "RawFixtureProject" })
        XCTAssertEqual(rawGroup.sessions, 3)
        XCTAssertEqual(rawGroup.toolCallCount, 6)
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
        let dto = try listReply(result)

        XCTAssertEqual(dto.totalSessions, 2)
        XCTAssertEqual(dto.truncated, false)
        XCTAssertEqual(Set(dto.sessions.map(\.workspaceName)), ["ProjectAlpha", "ProjectBeta"])
        XCTAssertEqual(try session(dto.sessions, named: "Alpha Session").sessionID, alphaSession.id.uuidString)
        XCTAssertEqual(try session(dto.sessions, named: "Beta Session").sessionID, betaSession.id.uuidString)
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
        let dto = try listReply(result)

        XCTAssertEqual(dto.totalSessions, 1)
        let row = try XCTUnwrap(dto.sessions.first)
        XCTAssertEqual(row.sessionName, "Directory Filter Match")
        XCTAssertEqual(row.workspaceName, "Display Name From Workspace JSON")
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
        let sessions = try listReply(result).sessions

        let editedRow = try session(sessions, named: "Edited Files")
        XCTAssertEqual(editedRow.filesTouched, ["Sources/Bar.swift", "Sources/Foo.swift"])
        XCTAssertEqual(editedRow.activeDurationSeconds, edited.expectedDurationSeconds)
        XCTAssertEqual(editedRow.toolCallCount, edited.expectedToolCallCount)
        assertActivityBounds(editedRow, first: edited.expectedFirstActivityAt, last: edited.expectedLastActivityAt)

        let compactedRow = try session(sessions, named: "Compacted Summary")
        XCTAssertEqual(compactedRow.filesTouched, ["Docs/History.md"])
        XCTAssertEqual(compactedRow.toolCallCount, compacted.expectedToolCallCount)

        let startedOnlyRow = try session(sessions, named: "StartedAt Only")
        XCTAssertEqual(startedOnlyRow.activeDurationSeconds, startedOnly.expectedDurationSeconds)
        assertActivityBounds(startedOnlyRow, first: startedOnly.expectedFirstActivityAt, last: startedOnly.expectedLastActivityAt)

        let failedRow = try session(sessions, named: "Failed Session")
        XCTAssertEqual(failedRow.lastRunState, "failed")
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
        let dto = try listReply(result)

        XCTAssertEqual(dto.totalSessions, 1)
        let row = try XCTUnwrap(dto.sessions.first)
        XCTAssertEqual(row.sessionName, "Match")
        XCTAssertEqual(row.filesTouched, ["Package.swift", "Sources/App.swift"])
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
        let dto = try searchReply(result)

        XCTAssertEqual(dto.totalMatches, 2)
        XCTAssertEqual(dto.truncated, false)
        XCTAssertEqual(Set(dto.results.map(\.source)), ["activity", "summary"])
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
        let dto = try searchReply(result)

        XCTAssertEqual(dto.totalMatches, 1)
        XCTAssertEqual(dto.results.first?.source, "activity")
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
        let dto = try searchReply(result)

        let snippet = try XCTUnwrap(dto.results.first?.snippet)
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
        let dto = try searchReply(result)

        XCTAssertEqual(dto.totalMatches, 0)
        XCTAssertEqual(dto.truncated, false)
        XCTAssertEqual(dto.results.count, 0)
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
        let dto = try timeReply(result)

        XCTAssertEqual(dto.totalSessions, 3)
        XCTAssertEqual(dto.totalActiveDurationSeconds, 600)
        XCTAssertEqual(dto.truncated, false)
        XCTAssertEqual(dto.groups.count, 2)

        let day2Group = try XCTUnwrap(dto.groups.first { $0.key.hasPrefix("2026-06-09") })
        XCTAssertEqual(day2Group.sessions, 1)
        XCTAssertEqual(day2Group.activeDurationSeconds, 300)
        XCTAssertEqual(day2Group.toolCallCount, 3)

        let day1Group = try XCTUnwrap(dto.groups.first { $0.key.hasPrefix("2026-06-08") })
        XCTAssertEqual(day1Group.sessions, 2)
        XCTAssertEqual(day1Group.activeDurationSeconds, 300)
        XCTAssertEqual(day1Group.toolCallCount, 3)
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
        let dto = try timeReply(result)

        XCTAssertEqual(dto.totalSessions, 3)
        XCTAssertEqual(dto.totalActiveDurationSeconds, 700)
        let groups = dto.groups

        let backendGroup = try XCTUnwrap(groups.first { $0.key == "Backend" })
        XCTAssertEqual(backendGroup.sessions, 1)
        XCTAssertEqual(backendGroup.activeDurationSeconds, 400)
        XCTAssertEqual(backendGroup.toolCallCount, 1)

        let frontendGroup = try XCTUnwrap(groups.first { $0.key == "Frontend" })
        XCTAssertEqual(frontendGroup.sessions, 2)
        XCTAssertEqual(frontendGroup.activeDurationSeconds, 300)
        XCTAssertEqual(frontendGroup.toolCallCount, 5)
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
                "session_id": .string(target.id.uuidString)
            ],
            scanner: scanner
        )
        let dto = try timeReply(result)

        XCTAssertEqual(dto.totalSessions, 1)
        XCTAssertEqual(dto.totalActiveDurationSeconds, 75)
        XCTAssertEqual(dto.groups.count, 1)
        let group = try XCTUnwrap(dto.groups.first)
        XCTAssertEqual(group.key, target.id.uuidString)
        XCTAssertEqual(group.toolCallCount, 2)
        let details = try XCTUnwrap(group.details)
        XCTAssertEqual(details.first?.sessionName, "Target")
    }

    func testListSessions_emptyResultSet() async throws {
        _ = try fixture.createWorkspace(name: "EmptyProject")

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "workspace": "NonExistent"],
            scanner: scanner
        )
        let dto = try listReply(result)

        XCTAssertEqual(dto.totalSessions, 0)
        XCTAssertEqual(dto.truncated, false)
        XCTAssertEqual(dto.sessions.count, 0)
    }

    // MARK: - Helpers

    private func listReply(_ reply: HistoryToolReply) throws -> HistoryListSessionsReply {
        if case let .listSessions(dto) = reply { return dto }
        return try XCTUnwrap(nil as HistoryListSessionsReply?, "expected .listSessions reply, got \(reply)")
    }

    private func searchReply(_ reply: HistoryToolReply) throws -> HistorySearchReply {
        if case let .search(dto) = reply { return dto }
        return try XCTUnwrap(nil as HistorySearchReply?, "expected .search reply, got \(reply)")
    }

    private func timeReply(_ reply: HistoryToolReply) throws -> HistoryTimeReply {
        if case let .time(dto) = reply { return dto }
        return try XCTUnwrap(nil as HistoryTimeReply?, "expected .time reply, got \(reply)")
    }

    private func session(_ sessions: [HistoryListSessionsReply.SessionDTO], named name: String) throws -> HistoryListSessionsReply.SessionDTO {
        try XCTUnwrap(sessions.first { $0.sessionName == name }, "no session named \(name)")
    }

    private func assertActivityBounds(_ session: HistoryListSessionsReply.SessionDTO, first: Date?, last: Date?) {
        let formatter = ISO8601DateFormatter()
        if let first {
            XCTAssertEqual(session.firstActivityAt, formatter.string(from: first))
        }
        if let last {
            XCTAssertEqual(session.lastActivityAt, formatter.string(from: last))
        }
    }

    private func localDate(year: Int, month: Int, day: Int, hour: Int) throws -> Date {
        let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour))
        return try XCTUnwrap(date)
    }
}
