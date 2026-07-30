import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

final class HistoryMCPToolServiceTests: XCTestCase {
    // MARK: - Test Infrastructure

    private var mockScanner: MockHistoryScanner!

    override func setUp() {
        super.setUp()
        mockScanner = MockHistoryScanner()
    }

    override func tearDown() {
        mockScanner = nil
        super.tearDown()
    }

    // MARK: - Error Cases

    func testExecute_invalidOpReturnsError() async throws {
        let cases: [([String: Value], String)] = [
            ([:], "Missing or empty required parameter 'op'"),
            (["op": ""], "Missing or empty required parameter 'op'"),
            (["op": "unknown"], "Unknown op 'unknown'. Valid ops: list_sessions, search, time, get_session")
        ]

        for (args, expected) in cases {
            let result = try await HistoryMCPToolService.execute(args: args, scanner: mockScanner)
            XCTAssertEqual(try errorReply(result), expected)
        }
    }

    // MARK: - list_sessions

    func testListSessions_emptyResults() async throws {
        mockScanner.scanResults = []
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions"],
            scanner: mockScanner
        )
        let dto = try listReply(result)
        XCTAssertEqual(dto.totalSessions, 0)
        XCTAssertEqual(dto.truncated, false)
        XCTAssertEqual(dto.sessions.count, 0)
    }

    func testListSessions_returnsAllFields() async throws {
        let record = makeRecord(name: "Test Session", agentKindRaw: "claudeCode", agentModelRaw: "claude-sonnet-4")
        mockScanner.scanResults = [makeScanResult(records: [record])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions"],
            scanner: mockScanner
        )
        let dto = try listReply(result)
        XCTAssertEqual(dto.sessions.count, 1)

        let session = try XCTUnwrap(dto.sessions.first)
        XCTAssertEqual(session.sessionID, record.id.uuidString)
        XCTAssertEqual(session.sessionName, "Test Session")
        XCTAssertEqual(session.workspaceName, "TestWorkspace")
        XCTAssertEqual(session.agentKind, "claudeCode")
        XCTAssertEqual(session.agentModel, "claude-sonnet-4")
        XCTAssertEqual(session.activeDurationSeconds, 0)
        XCTAssertEqual(session.turnCount, 1)
        XCTAssertEqual(session.toolCallCount, 0)
        XCTAssertEqual(session.hadErrors, false)
        XCTAssertFalse(session.firstActivityAt.isEmpty)
        XCTAssertFalse(session.lastActivityAt.isEmpty)
    }

    func testListSessions_truncation() async throws {
        let records = (0 ..< 50).map { makeRecord(name: "S\($0)") }
        mockScanner.scanResults = [makeScanResult(records: records)]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "limit": 20],
            scanner: mockScanner
        )
        let dto = try listReply(result)
        XCTAssertEqual(dto.totalSessions, 50)
        XCTAssertEqual(dto.truncated, true)
        XCTAssertEqual(dto.sessions.count, 20)
    }

    func testListSessions_sortByDuration() async throws {
        let r1 = makeRecord(name: "Short", activeDurationSeconds: 100)
        let r2 = makeRecord(name: "Long", activeDurationSeconds: 500)
        mockScanner.scanResults = [makeScanResult(records: [r1, r2])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "sort": "duration"],
            scanner: mockScanner
        )
        let dto = try listReply(result)
        XCTAssertEqual(dto.sessions[0].sessionName, "Long")
        XCTAssertEqual(dto.sessions[1].sessionName, "Short")
    }

    // MARK: - On-demand enrichment (stub-built records)

    /// A record rebuilt from a lightweight stub carries no transcript-derived fields.
    /// `list_sessions` must enrich it on demand via the scanner so duration / files_touched /
    /// tool_call_count reflect the transcript — guards the regression where stub-rebuilt
    /// sessions reported zero for everything.
    func testListSessions_enrichesStubBuiltRecordOnDemand() async throws {
        let stub = makeRecord(name: "Rebuilt") // defaults → lacksTranscriptDerivedFields == true
        mockScanner.scanResults = [makeScanResult(records: [stub])]

        let turn = AgentTranscriptTurn(
            summary: AgentTranscriptTurnSummary(
                requestText: nil,
                conclusionText: nil,
                compactConclusionText: nil,
                middleSummaryText: nil,
                toolCount: 3,
                notableToolNames: [],
                keyPaths: ["src/main.swift"],
                compactedActivityCount: 0,
                hadWarning: false,
                hadError: false
            ),
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 100)
        )
        mockScanner.transcriptProvider = { _ in AgentTranscript(turns: [turn]) }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions"],
            scanner: mockScanner
        )
        let dto = try listReply(result)
        XCTAssertEqual(dto.sessions.count, 1)
        XCTAssertEqual(dto.sessions[0].activeDurationSeconds, 100)
        XCTAssertEqual(dto.sessions[0].toolCallCount, 3)
        XCTAssertEqual(dto.sessions[0].filesTouched, ["src/main.swift"])
    }

    /// Non-calendar `time` grouping reads each record's stored duration; stub-built records must be
    /// enriched on demand so they contribute their real duration instead of zero.
    func testTime_groupBySession_enrichesStubBuiltRecordOnDemand() async throws {
        let stub = makeRecord(name: "Rebuilt")
        mockScanner.scanResults = [makeScanResult(records: [stub])]

        let turn = AgentTranscriptTurn(
            summary: AgentTranscriptTurnSummary(
                requestText: nil,
                conclusionText: nil,
                compactConclusionText: nil,
                middleSummaryText: nil,
                toolCount: 2,
                notableToolNames: [],
                keyPaths: [],
                compactedActivityCount: 0,
                hadWarning: false,
                hadError: false
            ),
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 100)
        )
        mockScanner.transcriptProvider = { _ in AgentTranscript(turns: [turn]) }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "session"],
            scanner: mockScanner
        )
        let dto = try timeReply(result)
        XCTAssertEqual(dto.totalActiveDurationSeconds, 100)
        XCTAssertEqual(dto.groups.count, 1)
        XCTAssertEqual(dto.groups[0].activeDurationSeconds, 100)
    }

    func testListSessions_touchedFileMatchesStubBuiltRecordAfterHydration() async throws {
        let stub = makeRecord(name: "StubWithFile")
        mockScanner.scanResults = [makeScanResult(records: [stub])]
        let turn = AgentTranscriptTurn(
            summary: AgentTranscriptTurnSummary(
                requestText: nil,
                conclusionText: nil,
                compactConclusionText: nil,
                middleSummaryText: nil,
                toolCount: 1,
                notableToolNames: [],
                keyPaths: ["Sources/App.swift"],
                compactedActivityCount: 0,
                hadWarning: false,
                hadError: false
            ),
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 10)
        )
        mockScanner.transcriptProvider = { _ in AgentTranscript(turns: [turn]) }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "touched_file": "App.swift"],
            scanner: mockScanner
        )
        let dto = try listReply(result)
        XCTAssertEqual(dto.sessions.map(\.sessionName), ["StubWithFile"])
        XCTAssertEqual(dto.sessions.first?.filesTouched, ["Sources/App.swift"])
    }

    /// Fully-indexed records (saved/loaded through the app) already carry v5 fields, so list_sessions
    /// must NOT load their transcripts — on-demand enrichment is only for stub-built records. Guards
    /// the steady-state perf property: normal queries over indexed sessions do no transcript I/O.
    func testListSessions_doesNotLoadTranscriptsForIndexedRecords() async throws {
        let indexed = makeRecord(name: "Indexed", keyPaths: ["a.swift"], activeDurationSeconds: 250, toolCallCount: 4)
        mockScanner.scanResults = [makeScanResult(records: [indexed, indexed, indexed])]

        var loads = 0
        mockScanner.transcriptProvider = { _ in
            loads += 1
            return .empty
        }

        let result = try await HistoryMCPToolService.execute(args: ["op": "list_sessions"], scanner: mockScanner)
        let dto = try listReply(result)
        XCTAssertEqual(dto.sessions.count, 3)
        XCTAssertEqual(dto.sessions[0].activeDurationSeconds, 250)
        XCTAssertEqual(loads, 0, "indexed records must not trigger transcript loads")
    }

    func testListSessions_surfacesAggregatedSkippedWorkspaceDiagnostics() async throws {
        let record = makeRecord(name: "OK", keyPaths: ["ok.swift"])
        mockScanner.scanResults = [
            makeScanResult(workspaceName: "OKWorkspace", records: [record]),
            makeScanResult(workspaceName: "Unreadable", indexReadFailed: true),
            makeScanResult(workspaceName: "Unreadable", indexReadFailed: true),
            makeScanResult(workspaceName: "Stale", indexSchemaVersion: 4),
            makeScanResult(workspaceName: "Stale", indexSchemaVersion: 4)
        ]

        let result = try await HistoryMCPToolService.execute(args: ["op": "list_sessions"], scanner: mockScanner)
        let dto = try listReply(result)
        XCTAssertEqual(dto.skippedWorkspaces, ["unreadable index: 2", "stale index schema v4: 2"])
    }

    func testHistoryPathMatchingAcceptsBasenameSuffixAndAbsoluteQueries() {
        let keyPath = "Sources/RepoPrompt/Features/AgentMode/History/HistoryMCPToolService.swift"
        XCTAssertTrue(HistoryMCPToolService.historyPath(keyPath, matches: "HistoryMCPToolService.swift"))
        XCTAssertTrue(HistoryMCPToolService.historyPath(keyPath, matches: "Features/AgentMode/History/HistoryMCPToolService.swift"))
        XCTAssertTrue(HistoryMCPToolService.historyPath(keyPath, matches: "/tmp/worktree/Sources/RepoPrompt/Features/AgentMode/History/HistoryMCPToolService.swift"))
        XCTAssertFalse(HistoryMCPToolService.historyPath(keyPath, matches: "HistorySessionScanner.swift"))
    }

    func testListSessions_invalidSort_returnsError() async throws {
        mockScanner.scanResults = []
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "sort": "bogus"],
            scanner: mockScanner
        )
        XCTAssertEqual(try errorReply(result), "Invalid 'sort' value 'bogus'. Valid values: last_activity, duration, turn_count")
    }

    func testListSessions_sortByTurnCount() async throws {
        let r1 = makeRecord(name: "Few", itemCount: 2)
        let r2 = makeRecord(name: "Many", itemCount: 10)
        mockScanner.scanResults = [makeScanResult(records: [r1, r2])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "sort": "turn_count"],
            scanner: mockScanner
        )
        let dto = try listReply(result)
        XCTAssertEqual(dto.sessions[0].sessionName, "Many")
        XCTAssertEqual(dto.sessions[1].sessionName, "Few")
    }

    func testListSessions_filesTouched() async throws {
        let record = makeRecord(name: "S1", keyPaths: ["src/main.swift", "lib/utils.swift"])
        mockScanner.scanResults = [makeScanResult(records: [record])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions"],
            scanner: mockScanner
        )
        let dto = try listReply(result)
        let session = try XCTUnwrap(dto.sessions.first)
        XCTAssertEqual(session.filesTouched, ["lib/utils.swift", "src/main.swift"]) // sorted
        XCTAssertEqual(session.filesTouchedCount, 2)
    }

    func testListSessions_capsFilesTouchedAndReportsCount() async throws {
        let paths = (0 ..< 25).map { String(format: "Sources/File%02d.swift", $0) }
        let record = makeRecord(name: "S1", keyPaths: Set(paths))
        mockScanner.scanResults = [makeScanResult(records: [record])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions"],
            scanner: mockScanner
        )
        let dto = try listReply(result)
        let session = try XCTUnwrap(dto.sessions.first)
        XCTAssertEqual(session.filesTouched.count, 20)
        XCTAssertEqual(session.filesTouchedCount, 25)
        XCTAssertEqual(session.filesTouched.first, "Sources/File00.swift")
        XCTAssertEqual(session.filesTouched.last, "Sources/File19.swift")
    }

    func testListSessions_lastRunState() async throws {
        let record = makeRecord(name: "S1", lastRunStateRaw: "completed")
        mockScanner.scanResults = [makeScanResult(records: [record])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions"],
            scanner: mockScanner
        )
        let dto = try listReply(result)
        XCTAssertEqual(dto.sessions.first?.lastRunState, "completed")
    }

    func testListSessions_defaultSortsByLastActivityDescending() async throws {
        let r1 = makeRecord(name: "Old", savedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let r2 = makeRecord(name: "New", savedAt: Date(timeIntervalSince1970: 1_700_001_000))
        mockScanner.scanResults = [makeScanResult(records: [r1, r2])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions"],
            scanner: mockScanner
        )
        let dto = try listReply(result)
        // Default sort is last_activity descending — newest first.
        XCTAssertEqual(dto.sessions[0].sessionName, "New")
        XCTAssertEqual(dto.sessions[1].sessionName, "Old")
    }

    func testListSessions_timestampsUseIndexedActivityBounds() async throws {
        let firstActivity = Date(timeIntervalSince1970: 1_700_000_000)
        let lastActivity = Date(timeIntervalSince1970: 1_700_000_120)
        let record = makeRecord(
            name: "S1",
            savedAt: Date(timeIntervalSince1970: 1_700_001_000),
            firstActivityAt: firstActivity,
            lastActivityAt: lastActivity
        )
        mockScanner.scanResults = [makeScanResult(records: [record])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions"],
            scanner: mockScanner
        )
        let dto = try listReply(result)
        let session = try XCTUnwrap(dto.sessions.first)
        let formatter = ISO8601DateFormatter()
        XCTAssertEqual(session.firstActivityAt, formatter.string(from: firstActivity))
        XCTAssertEqual(session.lastActivityAt, formatter.string(from: lastActivity))
    }

    func testListSessions_toolCallCountFromMetadata() async throws {
        let record = makeRecord(name: "S1", toolCallCount: 7)
        mockScanner.scanResults = [makeScanResult(records: [record])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions"],
            scanner: mockScanner
        )
        let dto = try listReply(result)
        XCTAssertEqual(dto.sessions.first?.toolCallCount, 7)
    }

    func testListSessions_hadErrorsTrue() async throws {
        let record = makeRecord(name: "S1", hasUnknownContent: true)
        mockScanner.scanResults = [makeScanResult(records: [record])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions"],
            scanner: mockScanner
        )
        let dto = try listReply(result)
        XCTAssertEqual(dto.sessions.first?.hadErrors, true)
    }

    func testListSessions_passesMetadataFiltersToScanner() async throws {
        let record = makeRecord(name: "S1", keyPaths: ["Sources/App.swift"])
        mockScanner.scanResults = [makeScanResult(records: [record])]

        let result = try await HistoryMCPToolService.execute(
            args: [
                "op": "list_sessions",
                "workspace": "FilterWorkspace",
                "agent_kind": "claude",
                "model": "sonnet",
                "touched_file": "Sources/App.swift",
                "date_from": "2026-06-10T12:00:00Z",
                "date_to": "2026-06-11T12:00:00Z"
            ],
            scanner: mockScanner
        )

        let dto = try listReply(result)
        XCTAssertEqual(dto.totalSessions, 1)
        let request = try XCTUnwrap(mockScanner.filterRequests.first)
        XCTAssertEqual(request.workspace, "FilterWorkspace")
        XCTAssertEqual(request.agentKind, "claude")
        XCTAssertEqual(request.model, "sonnet")
        XCTAssertNil(request.filePath, "touched_file is applied after bounded hydration so stub-built records with empty keyPaths are not missed")
        XCTAssertEqual(request.from, HistoryMCPToolService.parseDateBound("2026-06-10T12:00:00Z", isUpperBound: false))
        XCTAssertEqual(request.to, HistoryMCPToolService.parseDateBound("2026-06-11T12:00:00Z", isUpperBound: true))
    }

    // MARK: - search

    func testSearch_missingQuery_returnsError() async throws {
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search"],
            scanner: mockScanner
        )
        XCTAssertEqual(try errorReply(result), "Missing or empty required parameter 'query'")
    }

    func testSearch_emptyQuery_returnsError() async throws {
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": ""],
            scanner: mockScanner
        )
        XCTAssertEqual(try errorReply(result), "Missing or empty required parameter 'query'")
    }

    func testSearch_whitespaceOnlyQuery_returnsError() async throws {
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "   \t  "],
            scanner: mockScanner
        )
        XCTAssertEqual(try errorReply(result), "Missing or empty required parameter 'query'")
    }

    func testSearch_invalidSource_returnsError() async throws {
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "test", "source": "bogus"],
            scanner: mockScanner
        )
        XCTAssertEqual(try errorReply(result), "Invalid 'source' value 'bogus'. Valid values: activities, summaries, all")
    }

    func testSearch_noMatches() async throws {
        let record = makeRecord(name: "S1")
        mockScanner.scanResults = [makeScanResult(records: [record])]
        mockScanner.transcriptProvider = { _ in .empty }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "nonexistent"],
            scanner: mockScanner
        )
        let dto = try searchReply(result)
        XCTAssertEqual(dto.totalMatches, 0)
        XCTAssertEqual(dto.truncated, false)
        XCTAssertEqual(dto.results.count, 0)
    }

    func testSearch_matchesActivityText() async throws {
        let record = makeRecord(name: "S1")
        let scanResult = makeScanResult(records: [record])
        mockScanner.scanResults = [scanResult]

        let activity = AgentTranscriptActivity(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1000),
            sequenceIndex: 0,
            role: .assistant,
            itemKind: .assistant,
            text: "I found a regression test that needs updating",
            isStreaming: false,
            isSubstantiveAssistant: true,
            sealsAssistantBoundary: false
        )
        let turn = AgentTranscriptTurn(
            id: UUID(),
            responseSpans: [
                AgentTranscriptProviderResponseSpan(
                    id: UUID(),
                    startedAt: Date(timeIntervalSince1970: 1000),
                    activities: [activity]
                )
            ],
            startedAt: Date(timeIntervalSince1970: 1000)
        )
        mockScanner.transcriptProvider = { _ in AgentTranscript(turns: [turn]) }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "regression test"],
            scanner: mockScanner
        )
        let dto = try searchReply(result)
        XCTAssertEqual(dto.totalMatches, 1)
        XCTAssertEqual(dto.results.count, 1)
        XCTAssertEqual(dto.results[0].source, "activity")
        XCTAssertEqual(dto.results[0].role, "assistant")
        XCTAssertEqual(dto.results[0].turnIndex, 0)
    }

    func testSearch_matchesSummaryText_compactConclusion() async throws {
        let record = makeRecord(name: "S1")
        let scanResult = makeScanResult(records: [record])
        mockScanner.scanResults = [scanResult]

        // Simulates a compacted turn (summary/archived tier) where conclusionText
        // is nil and only compactConclusionText survives.
        let turn = AgentTranscriptTurn(
            id: UUID(),
            summary: AgentTranscriptTurnSummary(
                requestText: nil,
                conclusionText: nil,
                compactConclusionText: "Fixed the rate limiting bug in API handler",
                middleSummaryText: nil,
                toolCount: 1,
                notableToolNames: ["apply_edits"],
                keyPaths: [],
                compactedActivityCount: 3,
                hadWarning: false,
                hadError: false
            ),
            startedAt: Date(timeIntervalSince1970: 1000)
        )
        mockScanner.transcriptProvider = { _ in AgentTranscript(turns: [turn]) }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "rate limiting"],
            scanner: mockScanner
        )
        let dto = try searchReply(result)
        XCTAssertEqual(dto.totalMatches, 1)
        XCTAssertEqual(dto.results[0].source, "summary")
    }

    func testSearch_matchesConclusionText_beyondCompactTruncation() async throws {
        let record = makeRecord(name: "S1")
        let scanResult = makeScanResult(records: [record])
        mockScanner.scanResults = [scanResult]

        // Simulates a full/condensed turn where conclusionText exists and contains
        // searchable text beyond the 220-char compactConclusionText truncation.
        let longConclusion = String(repeating: "x ", count: 150) + "the critical regression test"
        let turn = AgentTranscriptTurn(
            id: UUID(),
            summary: AgentTranscriptTurnSummary(
                requestText: nil,
                conclusionText: longConclusion,
                compactConclusionText: String(longConclusion.prefix(220)),
                middleSummaryText: nil,
                toolCount: 1,
                notableToolNames: ["apply_edits"],
                keyPaths: [],
                compactedActivityCount: 3,
                hadWarning: false,
                hadError: false
            ),
            startedAt: Date(timeIntervalSince1970: 1000)
        )
        mockScanner.transcriptProvider = { _ in AgentTranscript(turns: [turn]) }

        // Query matches text in conclusionText but NOT in compactConclusionText
        // (which is truncated to the first 220 chars).
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "critical regression test"],
            scanner: mockScanner
        )
        let dto = try searchReply(result)
        XCTAssertEqual(dto.totalMatches, 1)
        XCTAssertEqual(dto.results[0].source, "summary")
        XCTAssertFalse(dto.results[0].snippet.isEmpty)
    }

    func testSearch_dedup_activityTakesPriority() async throws {
        // Both activity text and summary contain the query; activity should win.
        let record = makeRecord(name: "S1")
        let scanResult = makeScanResult(records: [record])
        mockScanner.scanResults = [scanResult]

        let activity = AgentTranscriptActivity(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1000),
            sequenceIndex: 0,
            role: .assistant,
            itemKind: .assistant,
            text: "The regression test is failing",
            isStreaming: false,
            isSubstantiveAssistant: true,
            sealsAssistantBoundary: false
        )
        let turn = AgentTranscriptTurn(
            id: UUID(),
            responseSpans: [
                AgentTranscriptProviderResponseSpan(
                    id: UUID(),
                    startedAt: Date(timeIntervalSince1970: 1000),
                    activities: [activity]
                )
            ],
            summary: AgentTranscriptTurnSummary(
                requestText: nil,
                conclusionText: nil,
                compactConclusionText: "Updated regression test",
                middleSummaryText: nil,
                toolCount: 0,
                notableToolNames: [],
                keyPaths: [],
                compactedActivityCount: 0,
                hadWarning: false,
                hadError: false
            ),
            startedAt: Date(timeIntervalSince1970: 1000)
        )
        mockScanner.transcriptProvider = { _ in AgentTranscript(turns: [turn]) }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "regression test"],
            scanner: mockScanner
        )
        let dto = try searchReply(result)
        XCTAssertEqual(dto.totalMatches, 1)
        XCTAssertEqual(dto.results[0].source, "activity")
    }

    func testSearch_sourceFiltersRestrictMatchedFields() async throws {
        let summaryOnly = makeRecord(name: "SummaryOnly")
        let activityOnly = makeRecord(name: "ActivityOnly")
        mockScanner.scanResults = [makeScanResult(records: [summaryOnly, activityOnly])]

        let summaryTurn = AgentTranscriptTurn(
            id: UUID(),
            summary: AgentTranscriptTurnSummary(
                requestText: nil,
                conclusionText: nil,
                compactConclusionText: "Fixed the rate limiting bug",
                middleSummaryText: nil,
                toolCount: 0,
                notableToolNames: [],
                keyPaths: [],
                compactedActivityCount: 0,
                hadWarning: false,
                hadError: false
            ),
            startedAt: Date(timeIntervalSince1970: 1000)
        )
        let activity = AgentTranscriptActivity(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1000),
            sequenceIndex: 0,
            role: .assistant,
            itemKind: .assistant,
            text: "The rate limiting config needs updating",
            isStreaming: false,
            isSubstantiveAssistant: true,
            sealsAssistantBoundary: false
        )
        let activityTurn = AgentTranscriptTurn(
            id: UUID(),
            responseSpans: [
                AgentTranscriptProviderResponseSpan(
                    id: UUID(),
                    startedAt: Date(timeIntervalSince1970: 1000),
                    activities: [activity]
                )
            ],
            startedAt: Date(timeIntervalSince1970: 1000)
        )
        mockScanner.transcriptProvider = { sessionID in
            sessionID == summaryOnly.id
                ? AgentTranscript(turns: [summaryTurn])
                : AgentTranscript(turns: [activityTurn])
        }

        let activitiesResult = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "rate limiting", "source": "activities"],
            scanner: mockScanner
        )
        let activitiesDTO = try searchReply(activitiesResult)
        XCTAssertEqual(activitiesDTO.totalMatches, 1)
        XCTAssertEqual(activitiesDTO.results.first?.sessionID, activityOnly.id.uuidString)
        XCTAssertEqual(activitiesDTO.results.first?.source, "activity")

        let summariesResult = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "rate limiting", "source": "summaries"],
            scanner: mockScanner
        )
        let summariesDTO = try searchReply(summariesResult)
        XCTAssertEqual(summariesDTO.totalMatches, 1)
        XCTAssertEqual(summariesDTO.results.first?.sessionID, summaryOnly.id.uuidString)
        XCTAssertEqual(summariesDTO.results.first?.source, "summary")
    }

    func testSearch_truncation() async throws {
        let record = makeRecord(name: "S1")
        let scanResult = makeScanResult(records: [record])
        mockScanner.scanResults = [scanResult]

        // Create 30 turns that all match.
        let turns = (0 ..< 30).map { i in
            AgentTranscriptTurn(
                id: UUID(),
                summary: AgentTranscriptTurnSummary(
                    requestText: "Request \(i) with special keyword unicorn",
                    conclusionText: nil,
                    compactConclusionText: nil,
                    middleSummaryText: nil,
                    toolCount: 0,
                    notableToolNames: [],
                    keyPaths: [],
                    compactedActivityCount: 0,
                    hadWarning: false,
                    hadError: false
                ),
                startedAt: Date(timeIntervalSince1970: Double(1000 + i))
            )
        }
        mockScanner.transcriptProvider = { _ in AgentTranscript(turns: turns) }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "unicorn", "limit": 10],
            scanner: mockScanner
        )
        let dto = try searchReply(result)
        XCTAssertEqual(dto.totalMatches, 30)
        XCTAssertEqual(dto.truncated, true)
        XCTAssertEqual(dto.results.count, 10)
        XCTAssertEqual(dto.results.first?.turnIndex, 29, "bounded retention should keep the newest match")
        XCTAssertEqual(dto.results.last?.turnIndex, 20, "bounded retention should evict older matches first")
    }

    func testSearch_scanCapBoundsTranscriptsScanned() async throws {
        // Defect: a broad query must not decode every filtered session transcript.
        // `limit` caps matches, not work; the scan cap bounds transcripts decoded and
        // surfaces `scan_truncated` when hit.
        let records = (0 ..< 250).map { index in
            makeRecord(
                name: "S\(index)",
                lastActivityAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        mockScanner.scanResults = [makeScanResult(records: records)]

        var loadedSessionIDs: [UUID] = []
        mockScanner.transcriptProvider = { sessionID in
            loadedSessionIDs.append(sessionID)
            return .empty
        }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "anything"],
            scanner: mockScanner
        )
        let dto = try searchReply(result)
        XCTAssertTrue(dto.scanTruncated, "scan_truncated must be set when the scan cap is reached")
        XCTAssertEqual(loadedSessionIDs.count, 200, "should decode at most maxSessionsScanned transcripts")
        XCTAssertEqual(loadedSessionIDs.first, records.last?.id, "search should scan newest sessions before applying the cap")
        XCTAssertFalse(loadedSessionIDs.contains(records[0].id), "oldest sessions should be outside the default scan cap")
    }

    func testSearch_scanCapNotHitWhenFewerSessions() async throws {
        // Under the cap, scan_truncated is false even if the match limit truncates.
        let record = makeRecord(name: "S1")
        mockScanner.scanResults = [makeScanResult(records: [record])]
        mockScanner.transcriptProvider = { _ in .empty }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "anything"],
            scanner: mockScanner
        )
        let dto = try searchReply(result)
        XCTAssertEqual(dto.scanTruncated, false)
    }

    func testSearch_bySessionID() async throws {
        let targetID = UUID()
        let otherID = UUID()
        let targetRecord = makeRecord(id: targetID, name: "Target")
        let otherRecord = makeRecord(id: otherID, name: "Other")
        mockScanner.scanResults = [makeScanResult(records: [targetRecord, otherRecord])]

        let targetTurn = AgentTranscriptTurn(
            id: UUID(),
            summary: AgentTranscriptTurnSummary(
                requestText: "Find the unicorn",
                conclusionText: nil,
                compactConclusionText: nil,
                middleSummaryText: nil,
                toolCount: 0,
                notableToolNames: [],
                keyPaths: [],
                compactedActivityCount: 0,
                hadWarning: false,
                hadError: false
            ),
            startedAt: Date(timeIntervalSince1970: 1000)
        )
        let otherTurn = AgentTranscriptTurn(
            id: UUID(),
            summary: AgentTranscriptTurnSummary(
                requestText: "Also has unicorn here",
                conclusionText: nil,
                compactConclusionText: nil,
                middleSummaryText: nil,
                toolCount: 0,
                notableToolNames: [],
                keyPaths: [],
                compactedActivityCount: 0,
                hadWarning: false,
                hadError: false
            ),
            startedAt: Date(timeIntervalSince1970: 1000)
        )

        var loadCount = 0
        mockScanner.transcriptProvider = { _ in
            loadCount += 1
            // Return the appropriate transcript based on load order.
            if loadCount == 1 {
                return AgentTranscript(turns: [targetTurn])
            } else {
                return AgentTranscript(turns: [otherTurn])
            }
        }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "unicorn", "session_id": .string(targetID.uuidString)],
            scanner: mockScanner
        )
        let dto = try searchReply(result)
        XCTAssertEqual(dto.totalMatches, 1)
        XCTAssertEqual(loadCount, 1, "Should only load transcript for the filtered session")
    }

    func testSearch_transcriptLoadError_skipsSession() async throws {
        let failRecord = makeRecord(id: UUID(), name: "FailSession")
        let okRecord = makeRecord(id: UUID(), name: "OKSession")
        mockScanner.scanResults = [makeScanResult(records: [failRecord, okRecord])]

        var loadCount = 0
        mockScanner.transcriptProvider = { id in
            loadCount += 1
            if id == failRecord.id {
                throw HistorySessionScannerError.transcriptDecodingFailed(
                    sessionID: id,
                    underlying: "test error"
                )
            }
            // OK session has a matching turn.
            let turn = AgentTranscriptTurn(
                id: UUID(),
                summary: AgentTranscriptTurnSummary(
                    requestText: nil,
                    conclusionText: nil,
                    compactConclusionText: "Found the magic keyword",
                    middleSummaryText: nil,
                    toolCount: 0,
                    notableToolNames: [],
                    keyPaths: [],
                    compactedActivityCount: 0,
                    hadWarning: false,
                    hadError: false
                ),
                startedAt: Date(timeIntervalSince1970: 1000)
            )
            return AgentTranscript(turns: [turn])
        }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "magic keyword"],
            scanner: mockScanner
        )
        // Failed session is skipped; OK session still returns its match.
        let dto = try searchReply(result)
        XCTAssertEqual(dto.totalMatches, 1)
        XCTAssertEqual(dto.results.count, 1)
        XCTAssertEqual(dto.results[0].sessionName, "OKSession")
    }

    // MARK: - search response fields

    func testSearch_includesTurnRequestText() async throws {
        let record = makeRecord(name: "S1")
        let scanResult = makeScanResult(records: [record])
        mockScanner.scanResults = [scanResult]

        // Turn with a request — turn_request_text should reflect it.
        let request = AgentTranscriptRequestAnchor(
            from: AgentChatItem(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: 999),
                kind: .user,
                text: "Find all rate limiting bugs",
                sequenceIndex: 0
            )
        )
        let activity = AgentTranscriptActivity(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1000),
            sequenceIndex: 1,
            role: .assistant,
            itemKind: .assistant,
            text: "I found a rate limiting bug",
            isStreaming: false,
            isSubstantiveAssistant: true,
            sealsAssistantBoundary: false
        )
        let turn = AgentTranscriptTurn(
            id: UUID(),
            request: request,
            responseSpans: [
                AgentTranscriptProviderResponseSpan(
                    id: UUID(),
                    startedAt: Date(timeIntervalSince1970: 1000),
                    activities: [activity]
                )
            ],
            startedAt: Date(timeIntervalSince1970: 1000)
        )
        mockScanner.transcriptProvider = { _ in AgentTranscript(turns: [turn]) }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "rate limiting bug", "include_turn_request_text": true],
            scanner: mockScanner
        )
        let dto = try searchReply(result)
        XCTAssertEqual(dto.results.count, 1)
        XCTAssertEqual(dto.results[0].turnRequestText, "Find all rate limiting bugs")
    }

    func testSearch_turnRequestTextOmittedByDefault() async throws {
        let record = makeRecord(name: "S1")
        let scanResult = makeScanResult(records: [record])
        mockScanner.scanResults = [scanResult]

        // Even with a request, turn_request_text is opt-in to keep default output compact.
        let activity = AgentTranscriptActivity(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1000),
            sequenceIndex: 0,
            role: .assistant,
            itemKind: .assistant,
            text: "I found a dragonfruit pattern",
            isStreaming: false,
            isSubstantiveAssistant: true,
            sealsAssistantBoundary: false
        )
        let request = AgentTranscriptRequestAnchor(
            from: AgentChatItem(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: 999),
                kind: .user,
                text: "Explain dragonfruit",
                sequenceIndex: 0
            )
        )
        let turn = AgentTranscriptTurn(
            id: UUID(),
            request: request,
            responseSpans: [
                AgentTranscriptProviderResponseSpan(
                    id: UUID(),
                    startedAt: Date(timeIntervalSince1970: 1000),
                    activities: [activity]
                )
            ],
            startedAt: Date(timeIntervalSince1970: 1000)
        )
        mockScanner.transcriptProvider = { _ in AgentTranscript(turns: [turn]) }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "dragonfruit"],
            scanner: mockScanner
        )
        let dto = try searchReply(result)
        XCTAssertEqual(dto.results.count, 1)
        XCTAssertEqual(dto.results[0].turnRequestText, nil)
    }

    // MARK: - get_session

    func testGetSession_requiresBoundedWindow() async throws {
        let record = makeRecord(name: "S1")
        mockScanner.scanResults = [makeScanResult(records: [record])]
        mockScanner.transcriptProvider = { _ in AgentTranscript(turns: [
            AgentTranscriptTurn(startedAt: Date(timeIntervalSince1970: 1000))
        ]) }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "get_session", "session_id": .string(record.id.uuidString)],
            scanner: mockScanner
        )
        XCTAssertEqual(
            try errorReply(result),
            "get_session requires around_turn from a search result, or turn_start/turn_end for a bounded range"
        )
    }

    func testGetSession_contextTurnsZeroReturnsOnlyTargetTurn() async throws {
        let record = makeRecord(name: "S1")
        mockScanner.scanResults = [makeScanResult(records: [record])]

        let base = Date(timeIntervalSince1970: 1000)
        let turns = (0 ..< 3).map { index in
            AgentTranscriptTurn(
                request: AgentTranscriptRequestAnchor(
                    from: AgentChatItem(
                        id: UUID(),
                        timestamp: base.addingTimeInterval(TimeInterval(index)),
                        kind: .user,
                        text: "Request \(index)",
                        sequenceIndex: index
                    )
                ),
                startedAt: base.addingTimeInterval(TimeInterval(index))
            )
        }
        mockScanner.transcriptProvider = { _ in AgentTranscript(turns: turns) }

        let result = try await HistoryMCPToolService.execute(
            args: [
                "op": "get_session",
                "session_id": .string(record.id.uuidString),
                "around_turn": .int(1),
                "context_turns": .int(0)
            ],
            scanner: mockScanner
        )

        let dto = try getSessionReply(result)
        XCTAssertEqual(dto.returnedTurnStart, 1)
        XCTAssertEqual(dto.returnedTurnEnd, 1)
        XCTAssertEqual(dto.turns.map(\.turnIndex), [1])
        XCTAssertEqual(dto.turns[0].requestText, "Request 1")
    }

    func testGetSession_returnsNoiseReducedWindowAroundTurn() async throws {
        let record = makeRecord(name: "S1")
        mockScanner.scanResults = [makeScanResult(records: [record])]

        let base = Date(timeIntervalSince1970: 1000)
        let toolExecution = AgentTranscriptToolExecution(
            stableExecutionID: "tool-1",
            toolName: "file_search",
            invocationID: UUID(),
            argsJSON: "{\"secret\":\"do-not-render\"}",
            resultJSON: "{\"huge\":\"do-not-render\"}",
            toolIsError: false,
            status: .success,
            summaryText: "8 matches"
        )
        let request = AgentTranscriptRequestAnchor(
            from: AgentChatItem(
                id: UUID(),
                timestamp: base,
                kind: .user,
                text: "Find unfiled issues",
                sequenceIndex: 0
            )
        )
        let turn = AgentTranscriptTurn(
            request: request,
            responseSpans: [
                AgentTranscriptProviderResponseSpan(
                    startedAt: base,
                    activities: [
                        AgentTranscriptActivity(
                            id: UUID(),
                            timestamp: base.addingTimeInterval(1),
                            sequenceIndex: 1,
                            role: .thinking,
                            itemKind: .assistant,
                            text: "private reasoning should not render"
                        ),
                        AgentTranscriptActivity(
                            id: UUID(),
                            timestamp: base.addingTimeInterval(2),
                            sequenceIndex: 2,
                            role: .toolExecution,
                            itemKind: .assistant,
                            text: "raw tool payload",
                            toolExecution: toolExecution
                        ),
                        AgentTranscriptActivity(
                            id: UUID(),
                            timestamp: base.addingTimeInterval(3),
                            sequenceIndex: 3,
                            role: .assistant,
                            itemKind: .assistant,
                            text: "Candidate issue: missing smoke coverage"
                        ),
                        AgentTranscriptActivity(
                            id: UUID(),
                            timestamp: base.addingTimeInterval(4),
                            sequenceIndex: 4,
                            role: .error,
                            itemKind: .assistant,
                            text: "Tool failed once"
                        ),
                        AgentTranscriptActivity(
                            id: UUID(),
                            timestamp: base.addingTimeInterval(5),
                            sequenceIndex: 5,
                            role: .progress,
                            itemKind: .assistant,
                            text: "progress noise should not render"
                        )
                    ]
                )
            ],
            startedAt: base
        )
        mockScanner.transcriptProvider = { _ in AgentTranscript(turns: [turn]) }

        let result = try await HistoryMCPToolService.execute(
            args: [
                "op": "get_session",
                "session_id": .string(record.id.uuidString),
                "around_turn": .int(0),
                "context_turns": .int(0)
            ],
            scanner: mockScanner
        )
        let dto = try getSessionReply(result)
        XCTAssertEqual(dto.sessionID, record.id.uuidString)
        XCTAssertEqual(dto.turns.count, 1)
        XCTAssertEqual(dto.turns[0].requestText, "Find unfiled issues")
        XCTAssertEqual(dto.turns[0].toolCallSummary, "file_search success")
        let renderedText = dto.turns[0].entries.map(\.text).joined(separator: "\n")
        XCTAssertTrue(renderedText.contains("Candidate issue: missing smoke coverage"))
        XCTAssertTrue(renderedText.contains("Tool failed once"))
        XCTAssertFalse(renderedText.contains("file_search"))
        XCTAssertFalse(renderedText.contains("do-not-render"))
        XCTAssertFalse(renderedText.contains("private reasoning"))
        XCTAssertFalse(renderedText.contains("progress noise"))
    }

    func testGetSession_budgetExhaustionKeepsReturnedRangeContiguous() async throws {
        // When the char budget exhausts mid-window, rendered turns must form a contiguous
        // block around the target so returned_turn_start/end never bracket an unrendered
        // hole. Regression for F8: the prior target-first-then-ascending order could
        // render {target, target-2} and report a range spanning a missing turn.
        let record = makeRecord(name: "S1")
        mockScanner.scanResults = [makeScanResult(records: [record])]
        let base = Date(timeIntervalSince1970: 1000)
        let turns = (0 ..< 5).map { index in
            // Target turn (2) is short so it renders cheaply; siblings are long so each
            // consumes the whole remaining budget, forcing exhaustion after one sibling.
            let text = index == 2 ? String(repeating: "x", count: 100) : String(repeating: "y", count: 2000)
            return AgentTranscriptTurn(
                request: AgentTranscriptRequestAnchor(
                    from: AgentChatItem(
                        id: UUID(),
                        timestamp: base.addingTimeInterval(TimeInterval(index)),
                        kind: .user,
                        text: text,
                        sequenceIndex: index
                    )
                ),
                startedAt: base.addingTimeInterval(TimeInterval(index))
            )
        }
        mockScanner.transcriptProvider = { _ in AgentTranscript(turns: turns) }

        let result = try await HistoryMCPToolService.execute(
            args: [
                "op": "get_session",
                "session_id": .string(record.id.uuidString),
                "around_turn": .int(2),
                "context_turns": .int(2),
                "max_chars": .int(1500)
            ],
            scanner: mockScanner
        )
        let dto = try getSessionReply(result)
        // The reported range must equal the rendered payload — no gap.
        let span = dto.returnedTurnEnd - dto.returnedTurnStart + 1
        XCTAssertEqual(span, dto.turns.count, "Returned turn range must be contiguous (no holes)")
        XCTAssertTrue(dto.turns.contains { $0.turnIndex == 2 }, "Target turn must render")
    }

    func testGetSession_resolvesFreshlySavedSessionViaRefreshOnCacheMiss() async throws {
        // F6: when a session id isn't in the (cached) inventory, get_session retries
        // with a fresh scan and resolves it. Models a session saved since the TTL
        // cache was populated. Without the retry this returns "No session found".
        let existing = makeRecord(name: "Existing")
        let fresh = makeRecord(name: "Fresh")
        mockScanner.scanResults = [makeScanResult(records: [existing])] // stale inventory
        mockScanner.refreshingScanResults = [makeScanResult(records: [existing, fresh])] // fresh inventory
        mockScanner.transcriptProvider = { _ in AgentTranscript(turns: [AgentTranscriptTurn(startedAt: Date(timeIntervalSince1970: 1000))]) }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "get_session", "session_id": .string(fresh.id.uuidString), "around_turn": .int(0)],
            scanner: mockScanner
        )
        let dto = try getSessionReply(result)
        XCTAssertEqual(dto.sessionID, fresh.id.uuidString)
    }

    func testGetSession_directResolutionAvoidsInventoryScans() async throws {
        let record = makeRecord(name: "Direct")
        let scan = makeScanResult(records: [record])
        mockScanner.directLookup = HistoryDirectSessionLookup(location: HistoryDirectSessionLocation(
            record: record,
            workspaceName: scan.workspaceName,
            workspaceDir: scan.workspaceDir
        ))
        mockScanner.transcriptProvider = { _ in
            AgentTranscript(turns: [AgentTranscriptTurn(startedAt: Date(timeIntervalSince1970: 1000))])
        }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "get_session", "session_id": .string(record.id.uuidString), "around_turn": .int(0)],
            scanner: mockScanner
        )

        XCTAssertEqual(try getSessionReply(result).sessionID, record.id.uuidString)
        XCTAssertEqual(mockScanner.locateSessionCallCount, 1)
        XCTAssertEqual(mockScanner.scanCallCount, 0)
        XCTAssertEqual(mockScanner.refreshingScanCallCount, 0)
    }

    func testGetSession_incompleteDirectLookupDoesNotRunFullFallback() async throws {
        let diagnostic = HistoryScanDiagnostic(
            kind: .elapsedTime,
            limit: 20000,
            consumed: 20000,
            unit: .milliseconds,
            phase: "direct_session_lookup"
        )
        mockScanner.directLookup = HistoryDirectSessionLookup(
            location: nil,
            diagnostics: [diagnostic],
            isComplete: false
        )

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "get_session", "session_id": .string(UUID().uuidString), "around_turn": .int(0)],
            scanner: mockScanner
        )

        guard case let .error(error) = result else {
            return XCTFail("Expected retryable incomplete lookup, got \(result)")
        }
        XCTAssertEqual(error.retryable, true)
        XCTAssertEqual(error.scanTruncated, true)
        XCTAssertEqual(error.scanDiagnostics, [diagnostic])
        XCTAssertTrue(error.suggestion?.contains("same get_session") == true)
        XCTAssertEqual(mockScanner.locateSessionCallCount, 1)
        XCTAssertEqual(mockScanner.refreshingScanCallCount, 0)
    }

    func testGetSession_sharedDeadlineWithInsufficientFallbackTimeIsNotAuthoritativeNotFound() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let now = HistoryTestNowProvider(instants: [start, start + .seconds(19)])

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "get_session", "session_id": .string(UUID().uuidString), "around_turn": .int(0)],
            scanner: mockScanner,
            budget: HistoryExecutionBudget(maxTurns: 100, maxElapsed: .seconds(20), yieldEveryTurns: 1),
            nowProvider: { now.next() }
        )

        guard case let .error(error) = result else {
            return XCTFail("Expected retryable deadline result, got \(result)")
        }
        XCTAssertEqual(error.retryable, true)
        XCTAssertFalse(error.error.contains("No history session found"))
        XCTAssertEqual(error.scanDiagnostics?.first?.phase, "get_session_refresh")
        XCTAssertEqual(mockScanner.refreshingScanCallCount, 0)
    }

    func testGetSession_singleSnapshotRefreshDecisionCannotRaceIntoAuthoritativeNotFound() async throws {
        let record = makeRecord(name: "Recovered at boundary")
        mockScanner.refreshingScanResults = [makeScanResult(records: [record])]
        mockScanner.transcriptProvider = { _ in
            AgentTranscript(turns: [AgentTranscriptTurn(startedAt: Date(timeIntervalSince1970: 1000))])
        }
        let clock = ContinuousClock()
        let start = clock.now
        // Under the old two-check implementation, +17s passed the first check and
        // +20s failed the second, silently skipping refresh. One snapshot must refresh.
        let now = HistoryTestNowProvider(instants: [
            start,
            start + .seconds(17),
            start + .seconds(20)
        ])

        let result = try await HistoryMCPToolService.execute(
            args: [
                "op": "get_session",
                "session_id": .string(record.id.uuidString),
                "around_turn": .int(0)
            ],
            scanner: mockScanner,
            budget: HistoryExecutionBudget(maxTurns: 100, maxElapsed: .seconds(20), yieldEveryTurns: 1),
            nowProvider: { now.next() }
        )

        XCTAssertEqual(try getSessionReply(result).sessionID, record.id.uuidString)
        XCTAssertEqual(mockScanner.refreshingScanCallCount, 1)
    }

    func testListSessions_failedStubEnrichmentPreservesStoredMetadataWithLowerBoundDiagnostics() async throws {
        let first = makeRecord(name: "First stub")
        let second = makeRecord(name: "Second stub")
        mockScanner.scanResults = [makeScanResult(records: [first, second])]
        mockScanner.transcriptProvider = { _ in
            throw NSError(domain: "HistoryMCPToolServiceTests", code: 1)
        }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions"],
            scanner: mockScanner
        )
        let dto = try listReply(result)

        XCTAssertEqual(dto.totalSessions, 2)
        XCTAssertEqual(dto.sessionsScanned, 0)
        XCTAssertEqual(Set(dto.sessions.map(\.sessionName)), Set(["First stub", "Second stub"]))
        XCTAssertTrue(dto.scanTruncated)
        XCTAssertEqual(dto.scanDiagnostics?.map(\.kind), [.transcriptReadFailure])
        XCTAssertEqual(dto.scanDiagnostics?.first?.count, 2)
    }

    func testListSessions_oversizedTranscriptPreservesStoredSessionMetadata() async throws {
        let record = makeRecord(name: "Stored oversize")
        mockScanner.scanResults = [makeScanResult(records: [record])]
        let diagnostic = HistoryScanDiagnostic(
            kind: .transcriptFileBytes,
            limit: 64,
            consumed: 128,
            unit: .bytes,
            retryable: false,
            phase: "transcript_read"
        )
        mockScanner.transcriptProvider = { _ in
            throw HistorySessionScannerError.workBudgetExceeded(diagnostic)
        }

        let dto = try await listReply(HistoryMCPToolService.execute(
            args: ["op": "list_sessions"],
            scanner: mockScanner
        ))

        XCTAssertEqual(dto.sessions.map(\.sessionName), ["Stored oversize"])
        XCTAssertEqual(dto.sessionsScanned, 0)
        XCTAssertEqual(dto.scanDiagnostics, [diagnostic])
        XCTAssertTrue(dto.scanTruncated)
    }

    func testListSessions_repeatedReadFailuresAggregateDiagnosticsWithoutHidingSessions() async throws {
        let records = (0 ..< 250).map { makeRecord(name: "Degraded \($0)") }
        mockScanner.scanResults = [makeScanResult(records: records)]
        mockScanner.transcriptProvider = { _ in
            throw NSError(domain: "HistoryMCPToolServiceTests", code: 2)
        }

        let dto = try await listReply(HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "max_sessions_scanned": .int(250)],
            scanner: mockScanner
        ))

        XCTAssertEqual(dto.sessionsScanned, 0)
        XCTAssertEqual(dto.scanDiagnostics?.count, 1)
        XCTAssertEqual(dto.scanDiagnostics?.first?.kind, .transcriptReadFailure)
        XCTAssertEqual(dto.scanDiagnostics?.first?.count, 250)
        XCTAssertEqual(dto.totalSessions, 250)
    }

    func testSearch_corruptTranscriptProducesTypedLowerBoundPartial() async throws {
        let record = makeRecord(name: "Corrupt search")
        mockScanner.scanResults = [makeScanResult(records: [record])]
        mockScanner.transcriptProvider = { id in
            throw HistorySessionScannerError.transcriptDecodingFailed(
                sessionID: id,
                underlying: "synthetic corruption"
            )
        }

        let dto = try await searchReply(HistoryMCPToolService.execute(
            args: ["op": "search", "query": "needle"],
            scanner: mockScanner
        ))

        XCTAssertEqual(dto.sessionsScanned, 0)
        XCTAssertTrue(dto.scanTruncated)
        XCTAssertEqual(dto.totalsAreLowerBounds, true)
        XCTAssertEqual(dto.scanDiagnostics?.first?.kind, .transcriptReadFailure)
        XCTAssertEqual(dto.scanDiagnostics?.first?.retryable, false)
    }

    func testTime_calendarCorruptTranscriptDisclosesIncompleteCoverage() async throws {
        let record = makeRecord(name: "Corrupt calendar")
        mockScanner.scanResults = [makeScanResult(records: [record])]
        mockScanner.transcriptProvider = { id in
            throw HistorySessionScannerError.transcriptDecodingFailed(
                sessionID: id,
                underlying: "synthetic corruption"
            )
        }

        let dto = try await timeReply(HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "day"],
            scanner: mockScanner
        ))

        XCTAssertEqual(dto.sessionsScanned, 0)
        XCTAssertTrue(dto.groups.isEmpty)
        XCTAssertTrue(dto.scanTruncated)
        XCTAssertEqual(dto.totalsAreLowerBounds, true)
        XCTAssertEqual(dto.scanDiagnostics?.first?.kind, .transcriptReadFailure)
        XCTAssertEqual(dto.scanDiagnostics?.first?.retryable, false)
    }

    func testListSessions_inventoryBudgetSurfacesTypedRetryableTruncation() async throws {
        let diagnostic = HistoryScanDiagnostic(
            kind: .workspaceCount,
            limit: 5000,
            consumed: 5000,
            unit: .workspaces
        )
        mockScanner.inventoryDiagnostics = [diagnostic]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions"],
            scanner: mockScanner
        )
        let dto = try listReply(result)

        XCTAssertTrue(dto.scanTruncated)
        XCTAssertEqual(dto.scanDiagnostics, [diagnostic])
        XCTAssertEqual(dto.scanDiagnostics?.first?.retryable, true)
    }

    func testSearch_turnBudgetReturnsTypedPartialResults() async throws {
        let record = makeRecord(name: "Budgeted")
        mockScanner.scanResults = [makeScanResult(records: [record])]
        let turns = (0 ..< 5).map { index in
            AgentTranscriptTurn(
                summary: AgentTranscriptTurnSummary(
                    requestText: "budget needle \(index)",
                    conclusionText: nil,
                    compactConclusionText: nil,
                    middleSummaryText: nil,
                    toolCount: 0,
                    notableToolNames: [],
                    keyPaths: [],
                    compactedActivityCount: 0,
                    hadWarning: false,
                    hadError: false
                ),
                startedAt: Date(timeIntervalSince1970: TimeInterval(1000 + index))
            )
        }
        mockScanner.transcriptProvider = { _ in AgentTranscript(turns: turns) }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "budget needle"],
            scanner: mockScanner,
            budget: HistoryExecutionBudget(maxTurns: 2, maxElapsed: .seconds(20), yieldEveryTurns: 1)
        )
        let dto = try searchReply(result)

        XCTAssertEqual(dto.totalMatches, 2)
        XCTAssertTrue(dto.scanTruncated)
        XCTAssertEqual(dto.scanDiagnostics?.map(\.kind), [.turnCount])
        XCTAssertEqual(dto.scanDiagnostics?.first?.consumed, 2)
        XCTAssertEqual(dto.sessionsScanned, 0)
        XCTAssertEqual(dto.totalsAreLowerBounds, true)
    }

    func testSearch_midTranscriptCancellationPropagates() async throws {
        let record = makeRecord(name: "Cancellation")
        mockScanner.scanResults = [makeScanResult(records: [record])]
        let probe = HistoryCancellationProbe()
        mockScanner.transcriptProvider = { _ in
            await probe.markStarted()
            while !Task.isCancelled {
                await Task.yield()
            }
            throw CancellationError()
        }

        let task = Task {
            try await HistoryMCPToolService.execute(
                args: ["op": "search", "query": "anything"],
                scanner: mockScanner
            )
        }
        while await !(probe.hasStarted) {
            await Task.yield()
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // Expected: transcript-load cancellation must not be swallowed as a skipped session.
        }
    }

    // MARK: - role mapping

    func testSearch_roleMapping_toolExecution() async throws {
        let record = makeRecord(name: "S1")
        mockScanner.scanResults = [makeScanResult(records: [record])]

        let activity = AgentTranscriptActivity(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1000),
            sequenceIndex: 0,
            role: .toolExecution,
            itemKind: .assistant,
            text: "Tool result with magic token",
            isStreaming: false,
            isSubstantiveAssistant: false,
            sealsAssistantBoundary: false
        )
        let turn = AgentTranscriptTurn(
            id: UUID(),
            responseSpans: [
                AgentTranscriptProviderResponseSpan(
                    id: UUID(),
                    startedAt: Date(timeIntervalSince1970: 1000),
                    activities: [activity]
                )
            ],
            startedAt: Date(timeIntervalSince1970: 1000)
        )
        mockScanner.transcriptProvider = { _ in AgentTranscript(turns: [turn]) }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "magic token"],
            scanner: mockScanner
        )
        let dto = try searchReply(result)
        XCTAssertEqual(dto.results[0].role, "tool")
    }

    func testSearch_caseInsensitive() async throws {
        let record = makeRecord(name: "S1")
        mockScanner.scanResults = [makeScanResult(records: [record])]

        let turn = AgentTranscriptTurn(
            id: UUID(),
            summary: AgentTranscriptTurnSummary(
                requestText: "Fix the RATE LIMITING handler",
                conclusionText: nil,
                compactConclusionText: nil,
                middleSummaryText: nil,
                toolCount: 0,
                notableToolNames: [],
                keyPaths: [],
                compactedActivityCount: 0,
                hadWarning: false,
                hadError: false
            ),
            startedAt: Date(timeIntervalSince1970: 1000)
        )
        mockScanner.transcriptProvider = { _ in AgentTranscript(turns: [turn]) }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "rate limiting"],
            scanner: mockScanner
        )
        let dto = try searchReply(result)
        XCTAssertEqual(dto.totalMatches, 1)
    }

    func testSearch_multipleTurnsInSession() async throws {
        let record = makeRecord(name: "S1")
        mockScanner.scanResults = [makeScanResult(records: [record])]

        let turns = (0 ..< 3).map { i in
            AgentTranscriptTurn(
                id: UUID(),
                summary: AgentTranscriptTurnSummary(
                    requestText: "Turn \(i) about dragonfruit",
                    conclusionText: nil,
                    compactConclusionText: nil,
                    middleSummaryText: nil,
                    toolCount: 0,
                    notableToolNames: [],
                    keyPaths: [],
                    compactedActivityCount: 0,
                    hadWarning: false,
                    hadError: false
                ),
                startedAt: Date(timeIntervalSince1970: Double(1000 + i))
            )
        }
        mockScanner.transcriptProvider = { _ in AgentTranscript(turns: turns) }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "dragonfruit"],
            scanner: mockScanner
        )
        let dto = try searchReply(result)
        XCTAssertEqual(dto.totalMatches, 3)
    }

    // MARK: - time

    func testSearch_passesDateFiltersToScanner() async throws {
        let record = makeRecord(name: "S1")
        mockScanner.scanResults = [makeScanResult(records: [record])]
        mockScanner.transcriptProvider = { _ in .empty }

        let result = try await HistoryMCPToolService.execute(
            args: [
                "op": "search",
                "query": "test",
                "date_from": "2026-01-15T00:00:00Z",
                "date_to": "2026-01-20T00:00:00Z"
            ],
            scanner: mockScanner
        )

        let dto = try searchReply(result)
        XCTAssertEqual(dto.totalMatches, 0)
        let request = try XCTUnwrap(mockScanner.filterRequests.first)
        XCTAssertEqual(request.from, HistoryMCPToolService.parseDateBound("2026-01-15T00:00:00Z", isUpperBound: false))
        XCTAssertEqual(request.to, HistoryMCPToolService.parseDateBound("2026-01-20T00:00:00Z", isUpperBound: true))
        // search passes nil for agentKind, model, filePath
        XCTAssertNil(request.agentKind)
        XCTAssertNil(request.model)
        XCTAssertNil(request.filePath)
    }

    func testSearch_passesWorkspaceFilterToScanner() async throws {
        let record = makeRecord(name: "S1")
        mockScanner.scanResults = [makeScanResult(records: [record])]
        mockScanner.transcriptProvider = { _ in .empty }

        let result = try await HistoryMCPToolService.execute(
            args: [
                "op": "search",
                "query": "test",
                "workspace": "MyProject"
            ],
            scanner: mockScanner
        )

        let dto = try searchReply(result)
        XCTAssertEqual(dto.totalMatches, 0)
        let request = try XCTUnwrap(mockScanner.filterRequests.first)
        XCTAssertEqual(request.workspace, "MyProject")
    }

    func testSearch_invalidSessionID_returnsError() async throws {
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "test", "session_id": "not-a-uuid"],
            scanner: mockScanner
        )
        XCTAssertEqual(try errorReply(result), "Invalid session_id: expected UUID format")
    }

    func testTime_missingGroupBy_returnsError() async throws {
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time"],
            scanner: mockScanner
        )
        XCTAssertEqual(try errorReply(result), "Missing or empty required parameter 'group_by'. Valid values: day, week, month, session, workspace")
    }

    func testTime_invalidGroupBy_returnsError() async throws {
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "year"],
            scanner: mockScanner
        )
        XCTAssertEqual(try errorReply(result), "Invalid 'group_by' value 'year'. Valid values: day, week, month, session, workspace")
    }

    func testTime_invalidSessionID_returnsError() async throws {
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "day", "session_id": "not-a-uuid"],
            scanner: mockScanner
        )
        XCTAssertEqual(try errorReply(result), "Invalid session_id: expected UUID format")
    }

    func testTime_emptyResults() async throws {
        mockScanner.scanResults = []
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "day"],
            scanner: mockScanner
        )
        let dto = try timeReply(result)
        XCTAssertEqual(dto.totalSessions, 0)
        XCTAssertEqual(dto.totalActiveDurationSeconds, 0)
        XCTAssertEqual(dto.groups.count, 0)
    }

    func testTime_groupByDay() async throws {
        let date1 = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14
        let date2 = Date(timeIntervalSince1970: 1_700_000_000 + 86400) // next day
        let r1 = makeRecord(name: "S1", activeDurationSeconds: 300, savedAt: date1)
        let r2 = makeRecord(name: "S2", activeDurationSeconds: 600, savedAt: date1)
        let r3 = makeRecord(name: "S3", activeDurationSeconds: 400, savedAt: date2)
        mockScanner.scanResults = [makeScanResult(records: [r1, r2, r3])]
        linkDefaultTranscripts()

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "day"],
            scanner: mockScanner
        )
        let dto = try timeReply(result)
        XCTAssertEqual(dto.totalSessions, 3)
        XCTAssertEqual(dto.totalActiveDurationSeconds, 1300)
        XCTAssertEqual(dto.groups.count, 2)

        // Find the group with 2 sessions (same day as date1).
        let twoSessionGroup = try XCTUnwrap(dto.groups.first { $0.sessions == 2 })
        XCTAssertEqual(twoSessionGroup.activeDurationSeconds, 900)
        XCTAssertEqual(twoSessionGroup.turnCount, 2) // 1 + 1 itemCount
    }

    func testTime_groupBySession() async throws {
        let r1 = makeRecord(name: "S1", activeDurationSeconds: 100, itemCount: 3)
        let r2 = makeRecord(name: "S2", activeDurationSeconds: 200, itemCount: 5)
        mockScanner.scanResults = [makeScanResult(records: [r1, r2])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "session"],
            scanner: mockScanner
        )
        let dto = try timeReply(result)
        XCTAssertEqual(dto.groups.count, 2)

        let s1Group = try XCTUnwrap(dto.groups.first { $0.key == r1.id.uuidString })
        XCTAssertEqual(s1Group.sessions, 1)
        XCTAssertEqual(s1Group.activeDurationSeconds, 100)
        XCTAssertEqual(s1Group.turnCount, 3)
    }

    func testTime_groupBySessionHonorsLimit() async throws {
        let r1 = makeRecord(name: "S1", activeDurationSeconds: 100, itemCount: 3)
        let r2 = makeRecord(name: "S2", activeDurationSeconds: 200, itemCount: 5)
        mockScanner.scanResults = [makeScanResult(records: [r1, r2])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "session", "limit": 1],
            scanner: mockScanner
        )
        let dto = try timeReply(result)
        XCTAssertEqual(dto.groups.count, 1)
        XCTAssertTrue(dto.truncated)
        XCTAssertEqual(dto.totalActiveDurationSeconds, 300)
    }

    func testTime_groupByWorkspace() async throws {
        let r1 = makeRecord(name: "S1", activeDurationSeconds: 100)
        let r2 = makeRecord(name: "S2", activeDurationSeconds: 200)
        let r3 = makeRecord(name: "S3", activeDurationSeconds: 300)
        mockScanner.scanResults = [
            makeScanResult(workspaceName: "Alpha", records: [r1, r2]),
            makeScanResult(workspaceName: "Beta", records: [r3])
        ]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "workspace"],
            scanner: mockScanner
        )
        let dto = try timeReply(result)
        XCTAssertEqual(dto.groups.count, 2)

        let alphaGroup = try XCTUnwrap(dto.groups.first { $0.key == "Alpha" })
        XCTAssertEqual(alphaGroup.sessions, 2)
        XCTAssertEqual(alphaGroup.activeDurationSeconds, 300)
    }

    func testTime_includeDetails() async throws {
        let r1 = makeRecord(name: "S1", activeDurationSeconds: 100, itemCount: 3)
        let r2 = makeRecord(name: "S2", activeDurationSeconds: 200, itemCount: 5)
        mockScanner.scanResults = [makeScanResult(records: [r1, r2])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "workspace", "include_details": true],
            scanner: mockScanner
        )
        let dto = try timeReply(result)
        let group = try XCTUnwrap(dto.groups.first)
        let details = try XCTUnwrap(group.details)
        XCTAssertEqual(details.count, 2)

        let detailNames = details.map(\.sessionName)
        XCTAssertEqual(detailNames.sorted(), ["S1", "S2"])
    }

    func testTime_withoutIncludeDetails() async throws {
        let r1 = makeRecord(name: "S1")
        mockScanner.scanResults = [makeScanResult(records: [r1])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "session"],
            scanner: mockScanner
        )
        let dto = try timeReply(result)
        XCTAssertNil(dto.groups.first?.details)
    }

    func testTime_groupByMonth() async throws {
        let jan = Date(timeIntervalSince1970: 1_700_000_000) // ~Nov 2023
        let feb = jan.addingTimeInterval(30 * 86400)
        let r1 = makeRecord(name: "S1", activeDurationSeconds: 100, savedAt: jan)
        let r2 = makeRecord(name: "S2", activeDurationSeconds: 200, savedAt: jan)
        let r3 = makeRecord(name: "S3", activeDurationSeconds: 300, savedAt: feb)
        mockScanner.scanResults = [makeScanResult(records: [r1, r2, r3])]
        linkDefaultTranscripts()

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "month"],
            scanner: mockScanner
        )
        let dto = try timeReply(result)
        XCTAssertEqual(dto.groups.count, 2)
    }

    func testTime_groupByWeek() async throws {
        // Two sessions in the same week, one in a different week.
        let week1Day = Date(timeIntervalSince1970: 1_700_000_000) // ~Nov 14, 2023 (Tuesday)
        let week1Day2 = week1Day.addingTimeInterval(86400) // same week
        let week2Day = week1Day.addingTimeInterval(7 * 86400) // next week
        let r1 = makeRecord(name: "S1", activeDurationSeconds: 100, savedAt: week1Day)
        let r2 = makeRecord(name: "S2", activeDurationSeconds: 200, savedAt: week1Day2)
        let r3 = makeRecord(name: "S3", activeDurationSeconds: 300, savedAt: week2Day)
        mockScanner.scanResults = [makeScanResult(records: [r1, r2, r3])]
        linkDefaultTranscripts()

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "week"],
            scanner: mockScanner
        )
        let dto = try timeReply(result)
        XCTAssertEqual(dto.totalSessions, 3)
        XCTAssertEqual(dto.totalActiveDurationSeconds, 600)
        XCTAssertEqual(dto.truncated, false)

        XCTAssertEqual(dto.groups.count, 2)

        // Find the group with 2 sessions (same week).
        let twoSessionGroup = try XCTUnwrap(dto.groups.first { $0.sessions == 2 })
        XCTAssertEqual(twoSessionGroup.activeDurationSeconds, 300)
        XCTAssertEqual(twoSessionGroup.toolCallCount, 0)
    }

    func testTime_sessionFilter() async throws {
        let targetID = UUID()
        let otherID = UUID()
        let r1 = makeRecord(id: targetID, name: "Target", activeDurationSeconds: 100)
        let r2 = makeRecord(id: otherID, name: "Other", activeDurationSeconds: 200)
        mockScanner.scanResults = [makeScanResult(records: [r1, r2])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "session", "session_id": .string(targetID.uuidString)],
            scanner: mockScanner
        )
        let dto = try timeReply(result)
        XCTAssertEqual(dto.totalSessions, 1)
        XCTAssertEqual(dto.totalActiveDurationSeconds, 100)
    }

    // MARK: - idle_threshold_minutes

    func testTime_idleThresholdChangesActiveDuration() async throws {
        // covered 200s with a 100s gap between merged intervals.
        let r = makeRecord(name: "S1", activeDurationSeconds: 200, gapSeconds: [100])
        mockScanner.scanResults = [makeScanResult(records: [r])]

        // Threshold 2 min (120s): 100s gap <= 120s -> active -> covered + gap = 300.
        let inclusive = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "session", "idle_threshold_minutes": 2],
            scanner: mockScanner
        )
        XCTAssertEqual(try timeReply(inclusive).totalActiveDurationSeconds, 300)

        // Threshold 1 min (60s): 100s gap > 60s -> idle -> covered only = 200.
        let exclusive = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "session", "idle_threshold_minutes": 1],
            scanner: mockScanner
        )
        XCTAssertEqual(try timeReply(exclusive).totalActiveDurationSeconds, 200)

        // Threshold 0: every positive gap is idle -> covered only = 200.
        let zero = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "session", "idle_threshold_minutes": 0],
            scanner: mockScanner
        )
        XCTAssertEqual(try timeReply(zero).totalActiveDurationSeconds, 200)
    }

    func testListSessions_idleThresholdApplied() async throws {
        let r = makeRecord(name: "S1", activeDurationSeconds: 200, gapSeconds: [100])
        mockScanner.scanResults = [makeScanResult(records: [r])]

        let tight = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "idle_threshold_minutes": 1],
            scanner: mockScanner
        )
        XCTAssertEqual(try listReply(tight).sessions.first?.activeDurationSeconds, 200)

        let loose = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "idle_threshold_minutes": 2],
            scanner: mockScanner
        )
        XCTAssertEqual(try listReply(loose).sessions.first?.activeDurationSeconds, 300)
    }

    func testTime_idleThresholdOutOfRangeReturnsError() async throws {
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "day", "idle_threshold_minutes": 2000],
            scanner: mockScanner
        )
        XCTAssertEqual(try errorReply(result), "idle_threshold_minutes must be between 0 and 1440")
    }

    func testListSessions_idleThresholdNonIntegerReturnsError() async throws {
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "idle_threshold_minutes": 10.5],
            scanner: mockScanner
        )
        XCTAssertEqual(try errorReply(result), "idle_threshold_minutes must be an integer")
    }

    func testIdleThreshold_settingsDefaultClampedToValidRange() throws {
        // An out-of-range stored default (e.g. via `defaults write`) must be clamped to
        // 0...1440, not trusted raw — the explicit-arg path validates that range, so the
        // default must too. Regression for F4.
        let key = HistoryMCPToolService.idleThresholdSettingsKey
        let prior = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(100_000, forKey: key)
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        XCTAssertEqual(try HistoryMCPToolService.resolveIdleThreshold(nil), 1440)
    }

    // MARK: - Snippet Extraction

    func testExtractSnippet_shortText() {
        let text = "Hello world"
        let snippet = HistoryMCPToolService.extractSnippet(text: text, query: "world")
        XCTAssertEqual(snippet, text)
    }

    func testExtractSnippet_longText() {
        let prefix = String(repeating: "x", count: 150)
        let suffix = String(repeating: "y", count: 150)
        let text = "\(prefix)FINDME\(suffix)"

        let snippet = HistoryMCPToolService.extractSnippet(text: text, query: "FINDME")
        XCTAssertTrue(snippet.contains("FINDME"))
        // Should be roughly 200 chars (±100 on each side of match).
        XCTAssertLessThanOrEqual(snippet.count, 210)
        XCTAssertGreaterThanOrEqual(snippet.count, 10) // At minimum contains FINDME
        // Must not be the full text — snippet should be truncated.
        XCTAssertNotEqual(snippet, text)
    }

    func testExtractSnippet_usesFirstOccurrence() {
        let prefix = String(repeating: "a", count: 40)
        let middle = String(repeating: "b", count: 260)
        let suffix = String(repeating: "c", count: 40)
        let text = "\(prefix)FINDME_FIRST\(middle)FINDME_SECOND\(suffix)"

        let snippet = HistoryMCPToolService.extractSnippet(text: text, query: "FINDME")
        XCTAssertTrue(snippet.contains("FINDME_FIRST"))
        XCTAssertFalse(snippet.contains("FINDME_SECOND"))
    }

    func testExtractSnippet_queryAtStart() {
        let suffix = String(repeating: "a", count: 200)
        let text = "FINDME\(suffix)"

        let snippet = HistoryMCPToolService.extractSnippet(text: text, query: "FINDME")
        XCTAssertTrue(snippet.hasPrefix("FINDME"))
    }

    func testExtractSnippet_queryAtEnd() {
        let prefix = String(repeating: "b", count: 200)
        let text = "\(prefix)FINDME"

        let snippet = HistoryMCPToolService.extractSnippet(text: text, query: "FINDME")
        XCTAssertTrue(snippet.hasSuffix("FINDME"))
    }

    func testExtractSnippet_caseInsensitive() {
        let text = "The Quick Brown Fox"
        let snippet = HistoryMCPToolService.extractSnippet(text: text, query: "quick brown")
        XCTAssertTrue(snippet.contains("Quick Brown"))
    }

    // MARK: - Role Mapping

    func testMapActivityRole_userFacingGroups() {
        let cases: [(AgentTranscriptActivityRole, String)] = [
            (.assistant, "assistant"),
            (.thinking, "assistant"),
            (.toolExecution, "tool"),
            (.progress, "system"),
            (.note, "system"),
            (.system, "system"),
            (.error, "system")
        ]

        for (role, expected) in cases {
            XCTAssertEqual(HistoryMCPToolService.mapActivityRole(role), expected, "role=\(role)")
        }
    }

    // MARK: - parseDateBound

    private static func utcMidnight(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    func testParseDateBound_acceptsISO8601WithAndWithoutFractionalSeconds() {
        for value in ["2026-06-10T12:00:00Z", "2026-06-10T12:00:00.123Z"] {
            XCTAssertNotNil(HistoryMCPToolService.parseDateBound(value, isUpperBound: false), value)
        }
    }

    func testParseDateBound_returnsNilForMissingOrInvalidValues() {
        for value in [nil, "", "not-a-date"] as [String?] {
            XCTAssertNil(HistoryMCPToolService.parseDateBound(value, isUpperBound: false), value ?? "nil")
        }
    }

    func testParseDateBound_dateOnlyLowerBoundIsStartOfDay() {
        let bound = HistoryMCPToolService.parseDateBound("2026-06-13", isUpperBound: false)
        XCTAssertEqual(bound, Self.utcMidnight("2026-06-13T00:00:00Z"))
    }

    func testParseDateBound_dateOnlyUpperBoundIsEndOfDay() throws {
        // Upper bound must include the named day (23:59:59), not midnight-start.
        let bound = try XCTUnwrap(HistoryMCPToolService.parseDateBound("2026-06-13", isUpperBound: true))
        XCTAssertEqual(bound, Self.utcMidnight("2026-06-13T00:00:00Z").addingTimeInterval(86399))
    }

    func testParseDateBound_isoDatetimeUsesExactInstantRegardlessOfDirection() {
        let iso = "2026-06-13T12:00:00Z"
        XCTAssertEqual(
            HistoryMCPToolService.parseDateBound(iso, isUpperBound: false),
            HistoryMCPToolService.parseDateBound(iso, isUpperBound: true)
        )
    }

    func testListSessions_dateToDateOnlyIsInclusiveOfNamedDay() async throws {
        // Two sessions: one on 2026-06-13, one on 2026-06-12. A date-only date_to of
        // 2026-06-13 must include the June 13 session (regression: it was excluded).
        let day12 = makeRecord(name: "Jun12", savedAt: Self.utcMidnight("2026-06-12T06:00:00Z"))
        let day13 = makeRecord(name: "Jun13", savedAt: Self.utcMidnight("2026-06-13T18:00:00Z"))
        mockScanner.scanResults = [makeScanResult(records: [day12, day13])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "date_to": "2026-06-13"],
            scanner: mockScanner
        )
        let dto = try listReply(result)
        let names = dto.sessions.map(\.sessionName)
        XCTAssertEqual(Set(names), ["Jun12", "Jun13"], "date_to date-only must include the named day")
    }

    // MARK: - resolveIdleThreshold

    func testResolveIdleThreshold_defaultsAndValidation() throws {
        let defaults = UserDefaults.standard
        let key = HistoryMCPToolService.idleThresholdSettingsKey
        let previousValue = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        // Omitted -> default threshold.
        XCTAssertEqual(
            try HistoryMCPToolService.resolveIdleThreshold(nil),
            AgentSessionMetadataRecord.defaultIdleThresholdMinutes
        )

        // Valid integers within range accepted.
        for valid in [0, 1, 10, 1440] {
            XCTAssertEqual(try HistoryMCPToolService.resolveIdleThreshold(.int(valid)), valid, "valid \(valid)")
        }

        // Invalid values throw the exact validation message (no clamping, no nil).
        XCTAssertThrowsError(try HistoryMCPToolService.resolveIdleThreshold(.int(1441))) { error in
            XCTAssertEqual(error.localizedDescription, "idle_threshold_minutes must be between 0 and 1440")
        }
        XCTAssertThrowsError(try HistoryMCPToolService.resolveIdleThreshold(.int(-1))) { error in
            XCTAssertEqual(error.localizedDescription, "idle_threshold_minutes must be between 0 and 1440")
        }
        XCTAssertThrowsError(try HistoryMCPToolService.resolveIdleThreshold(.double(10.5))) { error in
            XCTAssertEqual(error.localizedDescription, "idle_threshold_minutes must be an integer")
        }
    }

    // MARK: - clampLimit

    func testClampLimit_appliesDefaultBoundsAndMaximum() {
        let cases: [(value: Int?, expected: Int, label: String)] = [
            (nil, 30, "default"),
            (50, 50, "within range"),
            (200, 100, "maximum"),
            (0, 1, "zero lower bound"),
            (-5, 1, "negative lower bound")
        ]

        for testCase in cases {
            XCTAssertEqual(
                HistoryMCPToolService.clampLimit(testCase.value, default: 30, max: 100),
                testCase.expected,
                testCase.label
            )
        }
    }

    // MARK: - Reply Unwrapping Helpers

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

    private func getSessionReply(_ reply: HistoryToolReply) throws -> HistoryGetSessionReply {
        if case let .getSession(dto) = reply { return dto }
        return try XCTUnwrap(nil as HistoryGetSessionReply?, "expected .getSession reply, got \(reply)")
    }

    private func errorReply(_ reply: HistoryToolReply) throws -> String {
        if case let .error(dto) = reply { return dto.error }
        return try XCTUnwrap(nil as String?, "expected .error reply, got \(reply)")
    }

    // MARK: - Per-Day Attribution

    func testMalformedDateFiltersReturnToolErrorDTO() async throws {
        let list = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "date_from": "not-a-date"],
            scanner: mockScanner
        )
        XCTAssertEqual(try errorReply(list), "Invalid 'date_from' value 'not-a-date': expected ISO 8601 date or datetime")

        let search = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "x", "date_to": "bad"],
            scanner: mockScanner
        )
        XCTAssertEqual(try errorReply(search), "Invalid 'date_to' value 'bad': expected ISO 8601 date or datetime")

        let time = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "day", "date_from": "bad"],
            scanner: mockScanner
        )
        XCTAssertEqual(try errorReply(time), "Invalid 'date_from' value 'bad': expected ISO 8601 date or datetime")
    }

    func testTime_calendarGroupingAppliesDateBoundsPerTurn() async throws {
        let day1 = Self.utcMidnight("2026-06-12T10:00:00Z")
        let day2 = Self.utcMidnight("2026-06-13T10:00:00Z")
        let record = makeRecord(name: "MultiDay", firstActivityAt: day1, lastActivityAt: day2.addingTimeInterval(60))
        mockScanner.scanResults = [makeScanResult(records: [record])]
        mockScanner.transcriptProvider = { _ in
            AgentTranscript(turns: [
                AgentTranscriptTurn(startedAt: day1, completedAt: day1.addingTimeInterval(60)),
                AgentTranscriptTurn(startedAt: day2, completedAt: day2.addingTimeInterval(120))
            ])
        }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "day", "date_from": "2026-06-13", "date_to": "2026-06-13"],
            scanner: mockScanner
        )
        let dto = try timeReply(result)
        XCTAssertEqual(dto.groups.count, 1)
        XCTAssertEqual(dto.totalActiveDurationSeconds, 120)
        XCTAssertEqual(dto.groups.first?.turnCount, 1)
    }

    func testTime_groupByDay_attributedPerDay_noDoubleCounting() async throws {
        // A session with turns on TWO different days. time group_by:day must produce
        // TWO groups with per-day durations — no double counting. The overnight gap
        // (24h) is always idle (> any threshold), so each day only gets its own turns.
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let day2 = day1.addingTimeInterval(86400) // next calendar day

        let turn1 = AgentTranscriptTurn(
            responseSpans: [],
            startedAt: day1,
            completedAt: day1.addingTimeInterval(60)
        )
        let turn2 = AgentTranscriptTurn(
            responseSpans: [],
            startedAt: day2,
            completedAt: day2.addingTimeInterval(120)
        )
        let transcript = AgentTranscript(turns: [turn1, turn2])

        let record = makeRecord(name: "MultiDay")
        mockScanner.scanResults = [makeScanResult(records: [record])]
        mockScanner.transcriptProvider = { _ in transcript }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "day", "idle_threshold_minutes": 30],
            scanner: mockScanner
        )

        guard case let .time(reply) = result else {
            return XCTFail("Expected .time reply, got \(result)")
        }
        XCTAssertEqual(reply.groups.count, 2, "Should have one group per day")
        // Groups are sorted descending — day2 first.
        let groupsByDuration = reply.groups.sorted { $0.activeDurationSeconds < $1.activeDurationSeconds }
        XCTAssertEqual(groupsByDuration[0].activeDurationSeconds, 60, "Day 1: 60s")
        XCTAssertEqual(groupsByDuration[1].activeDurationSeconds, 120, "Day 2: 120s")
        XCTAssertEqual(reply.totalActiveDurationSeconds, 180, "Total: 60+120=180, no overnight gap counted")
    }

    func testTime_groupByDay_mergesOverlappingAndNestedTurnIntervals() async throws {
        // Same-day nested + overlapping turns must merge (no double counting), and the
        // gap after a nested turn must be measured against the merged interval end —
        // not the nested turn's earlier end. Regression for F1: the calendar path's
        // prior raw per-turn sum + prevEnd tracking double-counted overlaps and let
        // prevEnd regress on nested turns.
        let day = Self.utcMidnight("2026-06-12T10:00:00Z")
        // T1 10:00–11:00 (3600s), T2 10:30–10:45 nested inside T1, T3 11:05–11:20 (900s).
        let t1 = AgentTranscriptTurn(responseSpans: [], startedAt: day, completedAt: day.addingTimeInterval(3600))
        let t2 = AgentTranscriptTurn(responseSpans: [], startedAt: day.addingTimeInterval(1800), completedAt: day.addingTimeInterval(2700))
        let t3 = AgentTranscriptTurn(responseSpans: [], startedAt: day.addingTimeInterval(3900), completedAt: day.addingTimeInterval(4800))
        let record = makeRecord(name: "Overlap")
        mockScanner.scanResults = [makeScanResult(records: [record])]
        mockScanner.transcriptProvider = { _ in AgentTranscript(turns: [t1, t2, t3]) }

        // 5-min gap between merged [10:00–11:00] and [11:05–11:20] is ≤ 30-min threshold → active.
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "day", "idle_threshold_minutes": 30],
            scanner: mockScanner
        )
        guard case let .time(reply) = result else {
            return XCTFail("Expected .time reply, got \(result)")
        }
        XCTAssertEqual(reply.groups.count, 1, "All turns share one calendar day")
        XCTAssertEqual(reply.groups.first?.turnCount, 3)
        // Merged covered: 3600 (T1 absorbs nested T2) + 900 (T3) = 4500; active gap
        // 11:00–11:05 = 300s ≤ threshold → +300. Total = 4800. The old raw-sum +
        // prevEnd code returned 6600 (double-counted T2 and measured T3's gap from
        // T2's regressed end).
        XCTAssertEqual(reply.totalActiveDurationSeconds, 4800)
    }

    func testTime_groupBySession_recomputesStaleRecordFromLiveTranscript() async throws {
        // A full record carries STALE duration primitives (its transcript grew
        // post-save). `time group_by:session` must detect the staleness (session file
        // changed vs the observed signature) and recompute from the live transcript —
        // so its total agrees with group_by:day (which reloads transcripts for per-day
        // attribution). Regression for the calendar-vs-session total mismatch.
        let base = Date(timeIntervalSince1970: 1000)
        let transcript = AgentTranscript(turns: [
            AgentTranscriptTurn(startedAt: base, completedAt: base.addingTimeInterval(100)),
            AgentTranscriptTurn(startedAt: base.addingTimeInterval(200), completedAt: base.addingTimeInterval(400))
        ])
        // Stale stored primitives: claim 100s covered, no gaps (live is 300s + a 100s active gap).
        let record = makeRecord(name: "Stale", activeDurationSeconds: 100, gapSeconds: [])
        mockScanner.scanResults = [makeScanResult(records: [record])]
        mockScanner.transcriptProvider = { _ in transcript }
        mockScanner.transcriptStalenessProvider = { _ in true } // session file changed

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "session", "idle_threshold_minutes": 30],
            scanner: mockScanner
        )
        guard case let .time(reply) = result else {
            return XCTFail("Expected .time reply, got \(result)")
        }
        // Live: covered 300s + active gap 100s (≤30min) = 400s. NOT the stale 100.
        XCTAssertEqual(reply.totalActiveDurationSeconds, 400, "time must recompute stale records from the live transcript")
    }

    func testTime_groupBySession_emptyLiveTranscriptZerosDuration() async throws {
        // P1: a stale record whose live transcript is empty (deleted/sanitized turns)
        // must contribute ZERO, not fall back to its stale stored primitives — matching
        // the calendar path (which would also compute zero from the empty transcript).
        let record = makeRecord(name: "StaleNonEmpty", activeDurationSeconds: 100, gapSeconds: [10])
        mockScanner.scanResults = [makeScanResult(records: [record])]
        mockScanner.transcriptProvider = { _ in .empty } // live transcript is empty
        mockScanner.transcriptStalenessProvider = { _ in true }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "session"],
            scanner: mockScanner
        )
        guard case let .time(reply) = result else {
            return XCTFail("Expected .time reply, got \(result)")
        }
        XCTAssertEqual(reply.totalActiveDurationSeconds, 0, "An empty live transcript must contribute zero, not the stale stored primitives")
    }

    func testTime_groupByDay_clipsCrossMidnightTurnToAvoidDoubleCount() async throws {
        // A turn spanning midnight (day1 23:00 -> day2 01:00) overlaps a turn in the
        // next day (day2 00:30 -> 00:45). Without clipping, the long turn is fully
        // attributed to day1 (2h) AND the day2 turn is counted in day2 (15min) -> the
        // overlap is double-counted and day-total > session-total. Clipping the long
        // turn to [23:00, midnight] in day1 and [midnight, 01:00] in day2 lets the
        // overlap merge within day2, so day-total == session-total. Regression for the
        // day>session discrepancy found in live user testing.
        let cal = Calendar.current
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 6
        comps.day = 10
        comps.hour = 23
        comps.minute = 0
        let day1Late = try XCTUnwrap(cal.date(from: comps))
        let t1 = AgentTranscriptTurn(startedAt: day1Late, completedAt: day1Late.addingTimeInterval(2 * 3600)) // 23:00 -> 01:00 (crosses midnight)
        let t2 = AgentTranscriptTurn(startedAt: day1Late.addingTimeInterval(1.5 * 3600), completedAt: day1Late.addingTimeInterval(1.75 * 3600)) // 00:30 -> 00:45 (within T1's day2 tail)
        let record = makeRecord(name: "CrossMidnight")
        mockScanner.scanResults = [makeScanResult(records: [record])]
        mockScanner.transcriptProvider = { _ in AgentTranscript(turns: [t1, t2]) }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "day", "idle_threshold_minutes": 30],
            scanner: mockScanner
        )
        guard case let .time(reply) = result else {
            return XCTFail("Expected .time reply, got \(result)")
        }
        // Session: T1 covers 2h (T2 within it) = 7200s. Day (clipped): day1 = [23:00, midnight] (1h),
        // day2 = [midnight, 01:00] ∪ [00:30, 00:45] = 1h. Both 7200s.
        // Without clipping: day = 2h (T1 in day1) + 15min (T2 in day2) = 8100s.
        XCTAssertEqual(reply.totalActiveDurationSeconds, 7200, "Clipped day-total must equal the session-total (no overlap double-count)")
    }

    func testTime_groupByDayHonorsLimit() async throws {
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let day2 = day1.addingTimeInterval(86400)
        let transcript = AgentTranscript(turns: [
            AgentTranscriptTurn(responseSpans: [], startedAt: day1, completedAt: day1.addingTimeInterval(60)),
            AgentTranscriptTurn(responseSpans: [], startedAt: day2, completedAt: day2.addingTimeInterval(120))
        ])

        let record = makeRecord(name: "MultiDay")
        mockScanner.scanResults = [makeScanResult(records: [record])]
        mockScanner.transcriptProvider = { _ in transcript }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "day", "limit": 1],
            scanner: mockScanner
        )
        let dto = try timeReply(result)
        XCTAssertEqual(dto.groups.count, 1)
        XCTAssertTrue(dto.truncated)
        XCTAssertEqual(dto.totalActiveDurationSeconds, 180)
    }

    /// Synthesize a single-turn transcript for each record in scanResults, with duration
    /// = coveredTurnDurationSeconds on the record's savedAt day. This lets calendar-grouping
    /// tests (which load transcripts via the per-day attribution path) get non-empty data
    /// without manually constructing transcripts for every test.
    private func linkDefaultTranscripts() {
        let records = mockScanner.scanResults.flatMap(\.records)
        let recordMap = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        mockScanner.transcriptProvider = { sid in
            guard let r = recordMap[sid] else { return .empty }
            let dur = TimeInterval(max(1, r.coveredTurnDurationSeconds))
            let start = r.firstActivityAt ?? r.savedAt
            return AgentTranscript(turns: [
                AgentTranscriptTurn(responseSpans: [], startedAt: start, completedAt: start.addingTimeInterval(dur))
            ])
        }
    }

    // MARK: - Helpers

    private func makeRecord(
        id: UUID = UUID(),
        name: String = "Test Session",
        agentKindRaw: String? = nil,
        agentModelRaw: String? = nil,
        keyPaths: Set<String> = [],
        activeDurationSeconds: Int = 0,
        gapSeconds: [Int] = [],
        toolCallCount: Int = 0,
        savedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        firstActivityAt: Date? = nil,
        lastActivityAt: Date? = nil,
        itemCount: Int = 1,
        lastRunStateRaw: String? = nil,
        hasUnknownContent: Bool = false
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
            hasUnknownConversationContent: hasUnknownContent,
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
            firstActivityAt: firstActivityAt,
            lastActivityAt: lastActivityAt,
            keyPaths: keyPaths,
            coveredTurnDurationSeconds: activeDurationSeconds,
            interActiveIntervalGapSeconds: gapSeconds,
            toolCallCount: toolCallCount
        )
    }

    private func makeScanResult(
        workspaceName: String = "TestWorkspace",
        records: [AgentSessionMetadataRecord] = [],
        indexReadFailed: Bool = false,
        indexSchemaVersion: Int? = nil
    ) -> HistoryWorkspaceScanResult {
        HistoryWorkspaceScanResult(
            workspaceDir: URL(fileURLWithPath: "/tmp/Workspaces/Workspace-\(workspaceName)-\(UUID().uuidString)"),
            workspaceName: workspaceName,
            workspaceID: UUID(),
            records: records,
            indexReadFailed: indexReadFailed,
            indexSchemaVersion: indexSchemaVersion
        )
    }
}

// MARK: - Mock Scanner

private actor HistoryCancellationProbe {
    private(set) var hasStarted = false

    func markStarted() {
        hasStarted = true
    }
}

private final class HistoryTestNowProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let instants: [ContinuousClock.Instant]
    private var index = 0

    init(instants: [ContinuousClock.Instant]) {
        self.instants = instants
    }

    func next() -> ContinuousClock.Instant {
        lock.withLock {
            let instant = instants[min(index, instants.count - 1)]
            index += 1
            return instant
        }
    }
}

private struct FilterRequest: Equatable {
    let workspace: String?
    let agentKind: String?
    let model: String?
    let filePath: String?
    let from: Date?
    let to: Date?
}

private final class MockHistoryScanner: HistorySessionScanning {
    var scanResults: [HistoryWorkspaceScanResult] = []
    /// Optional fresh-scan results for `scanAllWorkspacesRefreshing()`; defaults to
    /// `scanResults` so tests that don't exercise the cache-bypass path are unaffected.
    var refreshingScanResults: [HistoryWorkspaceScanResult]?
    /// Per-session override for `transcriptDerivedFieldsAreStale`; nil → not stale.
    var transcriptStalenessProvider: ((UUID) -> Bool)?
    var filterRequests: [FilterRequest] = []
    var transcriptProvider: ((UUID) async throws -> AgentTranscript)?
    var inventoryDiagnostics: [HistoryScanDiagnostic] = []
    var directLookup: HistoryDirectSessionLookup?
    var scanCallCount = 0
    var refreshingScanCallCount = 0
    var locateSessionCallCount = 0

    func scanAllWorkspaces() async throws -> [HistoryWorkspaceScanResult] {
        scanResults
    }

    func scanAllWorkspacesRefreshing() async throws -> [HistoryWorkspaceScanResult] {
        refreshingScanResults ?? scanResults
    }

    func scanWorkspaces(matching _: String?) async throws -> HistoryInventoryScan {
        scanCallCount += 1
        return HistoryInventoryScan(workspaces: scanResults, diagnostics: inventoryDiagnostics)
    }

    func scanWorkspacesRefreshing(matching _: String?) async throws -> HistoryInventoryScan {
        refreshingScanCallCount += 1
        return HistoryInventoryScan(
            workspaces: refreshingScanResults ?? scanResults,
            diagnostics: inventoryDiagnostics
        )
    }

    func locateSession(sessionID _: UUID) async throws -> HistoryDirectSessionLookup {
        locateSessionCallCount += 1
        return directLookup ?? HistoryDirectSessionLookup(location: nil)
    }

    func sessionsMatchingFilters(
        _ records: [HistoryWorkspaceScanResult],
        workspace: String?,
        agentKind: String?,
        model: String?,
        filePath: String?,
        from: Date?,
        to: Date?
    ) -> [HistoryFilteredSessionRecord] {
        filterRequests.append(FilterRequest(
            workspace: workspace,
            agentKind: agentKind,
            model: model,
            filePath: filePath,
            from: from,
            to: to
        ))

        return records.flatMap { scan in
            scan.records.map { record in
                HistoryFilteredSessionRecord(
                    record: record,
                    workspaceName: scan.workspaceName,
                    workspaceDir: scan.workspaceDir
                )
            }
        }
    }

    func loadTranscriptForSearch(sessionID: UUID, workspaceDir: URL) async throws -> AgentTranscript {
        guard let provider = transcriptProvider else {
            return .empty
        }
        return try await provider(sessionID)
    }

    func loadSessionForHistory(sessionID: UUID, workspaceDir: URL) async throws -> HistoryLoadedSession {
        try await HistoryLoadedSession(
            name: nil,
            transcript: loadTranscriptForSearch(sessionID: sessionID, workspaceDir: workspaceDir)
        )
    }

    func transcriptDerivedFieldsAreStale(
        for record: AgentSessionMetadataRecord,
        sessionID: UUID,
        workspaceDir: URL
    ) async -> Bool {
        transcriptStalenessProvider?(sessionID) ?? false
    }
}
